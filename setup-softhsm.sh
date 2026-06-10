#!/usr/bin/env bash
#
# setup-softhsm.sh
# ----------------
# Initialises a SoftHSM2 token (first run) or performs a zero-downtime
# certificate rotation (subsequent runs) using a dual-alias rolling swap:
#
#   First run  — imports key+cert directly as the canonical alias (mykey / ID=01).
#                No application needs to be running.
#
#   Rotation   — imports new key+cert under a staging alias (mykey-staging / ID=02)
#                while the old canonical alias is still active in Tomcat (HTTPS live).
#                Calls POST https://<host>:<port>/ssl/reload?alias=mykey-staging.
#                On success: promotes staging → canonical, removes old objects.
#                On failure: rolls back by removing staging objects; old cert stays active.
#
# Prerequisites:
#   apt install softhsm2 opensc openssl curl
# ---------------------------------------------------------------------------

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
TOKEN_LABEL="springboot"
USER_PIN="1234"
SO_PIN="0000"

CANONICAL_ALIAS="mykey"
CANONICAL_ID="01"
STAGING_ALIAS="mykey-staging"
STAGING_ID="02"

CERT_SUBJECT="/CN=localhost/O=Example/C=US"
CERT_DAYS=365

APP_HOST="localhost"
APP_PORT="8443"

SOFTHSM_LIB="${SOFTHSM_LIB:-/usr/lib/softhsm/libsofthsm2.so}"

TMP_KEY="/tmp/server_$$.key"
TMP_KEY_DER="/tmp/server_$$.key.der"
TMP_CERT="/tmp/server_$$.crt"
TMP_CERT_DER="/tmp/server_$$.crt.der"
TMP_RELOAD_OUT="/tmp/reload_out_$$"

cleanup() {
    rm -f "$TMP_KEY" "$TMP_KEY_DER" "$TMP_CERT" "$TMP_CERT_DER" "$TMP_RELOAD_OUT"
}
trap cleanup EXIT

# ── Preflight checks ─────────────────────────────────────────────────────────
for cmd in softhsm2-util pkcs11-tool openssl curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found."
        echo "  apt install softhsm2 opensc openssl curl"
        exit 1
    fi
done

if [[ ! -f "$SOFTHSM_LIB" ]]; then
    echo "ERROR: SoftHSM library not found at '$SOFTHSM_LIB'."
    echo "  Set SOFTHSM_LIB=/path/to/libsofthsm2.so and re-run."
    exit 1
fi

# ── Helper: delete HSM objects by ID (silently ignores missing objects) ───────
delete_hsm_objects() {
    local id="$1"
    pkcs11-tool --module "$SOFTHSM_LIB" --token-label "$TOKEN_LABEL" \
        --login --pin "$USER_PIN" \
        --delete-object --type privkey --id "$id" 2>/dev/null \
        && echo "    Deleted private key ID=$id" || echo "    No private key ID=$id — skipping."
    pkcs11-tool --module "$SOFTHSM_LIB" --token-label "$TOKEN_LABEL" \
        --login --pin "$USER_PIN" \
        --delete-object --type cert --id "$id" 2>/dev/null \
        && echo "    Deleted certificate ID=$id" || echo "    No certificate ID=$id — skipping."
}

# ── Helper: import key+cert DER files into the HSM ───────────────────────────
import_hsm_objects() {
    local id="$1"
    local label="$2"
    pkcs11-tool --module "$SOFTHSM_LIB" --token-label "$TOKEN_LABEL" \
        --login --pin "$USER_PIN" \
        --write-object "$TMP_KEY_DER" --type privkey --id "$id" --label "$label"
    pkcs11-tool --module "$SOFTHSM_LIB" --token-label "$TOKEN_LABEL" \
        --login --pin "$USER_PIN" \
        --write-object "$TMP_CERT_DER" --type cert --id "$id" --label "$label"
}

# ── Helper: check whether canonical objects (ID=01) exist in the HSM ─────────
canonical_exists() {
    pkcs11-tool --module "$SOFTHSM_LIB" --token-label "$TOKEN_LABEL" \
        --login --pin "$USER_PIN" \
        --list-objects --type privkey 2>/dev/null \
        | grep -q "ID:.*${CANONICAL_ID}"
}

# ── Step 1: Initialise SoftHSM token ─────────────────────────────────────────
echo ""
echo "=== [1/5] Checking SoftHSM token '$TOKEN_LABEL' ==="
if softhsm2-util --show-slots 2>/dev/null | grep -q "Label: *$TOKEN_LABEL"; then
    echo "    Token already exists — skipping init."
else
    softhsm2-util --init-token --free \
        --label  "$TOKEN_LABEL" \
        --pin    "$USER_PIN" \
        --so-pin "$SO_PIN"
    echo "    Token initialised."
fi

# ── Step 2: Generate RSA-2048 key + self-signed certificate ──────────────────
echo ""
echo "=== [2/5] Generating new RSA-2048 key and self-signed certificate ==="
openssl genrsa -out "$TMP_KEY" 2048 2>/dev/null
openssl req -new -x509 \
    -key  "$TMP_KEY" \
    -out  "$TMP_CERT" \
    -days "$CERT_DAYS" \
    -subj "$CERT_SUBJECT" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
# Convert to DER (pkcs11-tool requires DER format)
openssl pkcs8 -topk8 -nocrypt \
    -inform PEM -in "$TMP_KEY" \
    -outform DER -out "$TMP_KEY_DER"
openssl x509 -in "$TMP_CERT" -outform DER -out "$TMP_CERT_DER"
echo "    Key and certificate generated."

# ── Decide: first run or rotation? ───────────────────────────────────────────
if ! canonical_exists; then

    # ════════════════════════════════════════════════════════════════════════
    # FIRST RUN — no existing canonical objects, import directly
    # ════════════════════════════════════════════════════════════════════════
    echo ""
    echo "=== [3/5] First run: importing directly as canonical ($CANONICAL_ALIAS / ID=$CANONICAL_ID) ==="
    import_hsm_objects "$CANONICAL_ID" "$CANONICAL_ALIAS"
    echo "    Done."

    echo ""
    echo "============================================================"
    echo " SoftHSM initialised with key alias '$CANONICAL_ALIAS'."
    echo ""
    echo " Start the application:"
    echo "   ./mvnw spring-boot:run"
    echo " then test with:"
    echo "   curl -k https://localhost:8443/hello"
    echo "============================================================"

else

    # ════════════════════════════════════════════════════════════════════════
    # ROTATION — old canonical exists and Tomcat is presumably running.
    # Use dual-alias rolling swap to avoid any HTTPS downtime.
    # ════════════════════════════════════════════════════════════════════════

    # Step 3: Clean up any leftover staging objects from a previous failed rotation
    echo ""
    echo "=== [3/5] Cleaning up any leftover staging objects (ID=$STAGING_ID) ==="
    delete_hsm_objects "$STAGING_ID"

    # Step 4: Import new key+cert under the staging alias
    echo ""
    echo "=== [4/5] Importing new key+cert as staging ($STAGING_ALIAS / ID=$STAGING_ID) ==="
    echo "    Old canonical ($CANONICAL_ALIAS) remains active — HTTPS stays live."
    import_hsm_objects "$STAGING_ID" "$STAGING_ALIAS"
    echo "    Staging objects imported."

    # Step 5: Tell Tomcat to reload using the staging alias
    echo ""
    echo "=== [5/5] Calling reload endpoint: POST https://$APP_HOST:$APP_PORT/ssl/reload?alias=$STAGING_ALIAS ==="
    HTTP_CODE=$(curl -k -s \
        -o "$TMP_RELOAD_OUT" \
        -w "%{http_code}" \
        -X POST "https://$APP_HOST:$APP_PORT/ssl/reload?alias=$STAGING_ALIAS")

    RELOAD_BODY=$(cat "$TMP_RELOAD_OUT" 2>/dev/null || true)

    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "    Reload succeeded (HTTP 200): $RELOAD_BODY"
        echo "    Tomcat is now using staging alias '$STAGING_ALIAS' (ID=$STAGING_ID)."

        # ── Promotion ──────────────────────────────────────────────────────
        # IMPORTANT: do NOT delete staging yet — Tomcat still holds a PKCS#11
        # handle to ID=02. Deleting it now would break TLS immediately.
        # Order:
        #   1. Delete old canonical (ID=01)
        #   2. Re-import new material as canonical (ID=01 / mykey)
        #   3. Reload Tomcat → it moves to canonical alias (ID=02 still present, TLS stays live)
        #   4. Only then delete staging (ID=02)
        echo ""
        echo "    Promoting: replacing canonical objects (ID=$CANONICAL_ID / $CANONICAL_ALIAS)..."
        delete_hsm_objects "$CANONICAL_ID"
        import_hsm_objects "$CANONICAL_ID" "$CANONICAL_ALIAS"
        echo "    Canonical objects imported. Staging still present for live TLS."

        echo ""
        echo "    Calling second reload with canonical alias '$CANONICAL_ALIAS'..."
        HTTP_CODE2=$(curl -k -s \
            -o "$TMP_RELOAD_OUT" \
            -w "%{http_code}" \
            -X POST "https://$APP_HOST:$APP_PORT/ssl/reload")
        RELOAD_BODY2=$(cat "$TMP_RELOAD_OUT" 2>/dev/null || true)

        if [[ "$HTTP_CODE2" == "200" ]]; then
            echo "    Second reload succeeded (HTTP 200): $RELOAD_BODY2"
            echo "    Tomcat is now using canonical alias '$CANONICAL_ALIAS'. Safe to remove staging."
            delete_hsm_objects "$STAGING_ID"

            echo ""
            echo "============================================================"
            echo " Certificate rotation complete — zero downtime."
            echo "  Active alias : $CANONICAL_ALIAS (ID=$CANONICAL_ID)"
            echo ""
            echo " Verify the new certificate:"
            echo "   curl -kv https://$APP_HOST:$APP_PORT/hello 2>&1 | grep 'subject\\|issuer\\|expire'"
            echo "============================================================"
        else
            echo "    WARNING: second reload (canonical) failed (HTTP $HTTP_CODE2): $RELOAD_BODY2"
            echo "    Staging objects (ID=$STAGING_ID) left in place — Tomcat still uses them."
            echo "    Investigate and re-run the script to retry, or restart the application."
            exit 1
        fi
    else
        echo "    ERROR: Reload failed (HTTP $HTTP_CODE): $RELOAD_BODY"
        echo ""
        echo "    Rolling back: removing staging objects..."
        delete_hsm_objects "$STAGING_ID"
        echo "    Old certificate '$CANONICAL_ALIAS' is still active. No changes made."
        exit 1
    fi

fi
