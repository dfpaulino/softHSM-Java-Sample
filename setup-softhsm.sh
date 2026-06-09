#!/usr/bin/env bash
#
# setup-softhsm.sh
# ----------------
# One-time initialisation script:
#   1. Initialises a SoftHSM2 token.
#   2. Generates an RSA-2048 private key and a self-signed certificate.
#   3. Imports both into the HSM token using pkcs11-tool.
#
# Prerequisites:
#   apt install softhsm2 opensc openssl
#
# After running this script, start the Spring Boot app with:
#   ./mvnw spring-boot:run
# or
#   java -jar target/spring-pkcs11-1.0.0-SNAPSHOT.jar
# ---------------------------------------------------------------------------

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
TOKEN_LABEL="springboot"
USER_PIN="1234"
SO_PIN="0000"
KEY_ALIAS="mykey"
KEY_ID="02"             # hex object ID used in the HSM
CERT_SUBJECT="/CN=localhost/O=Example/C=US"
CERT_DAYS=365

# Adjust to your distro's SoftHSM library path:
#   Debian/Ubuntu (x86-64): /usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so
#   Debian/Ubuntu (alt):    /usr/lib/softhsm/libsofthsm2.so
#   RHEL/Fedora:            /usr/lib64/pkcs11/libsofthsm2.soS
SOFTHSM_LIB="${SOFTHSM_LIB:-/usr/lib/softhsm/libsofthsm2.so}"

TMP_KEY="/tmp/server_$$.key"
TMP_KEY_DER="/tmp/server_$$.key.der"
TMP_CERT="/tmp/server_$$.crt"
TMP_CERT_DER="/tmp/server_$$.crt.der"

cleanup() {
    rm -f "$TMP_KEY" "$TMP_KEY_DER" "$TMP_CERT" "$TMP_CERT_DER"
}
trap cleanup EXIT

# ── Preflight checks ─────────────────────────────────────────────────────────
for cmd in softhsm2-util pkcs11-tool openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found. Install it and re-run."
        echo "  apt install softhsm2 opensc openssl"
        exit 1
    fi
done

if [[ ! -f "$SOFTHSM_LIB" ]]; then
    echo "ERROR: SoftHSM library not found at '$SOFTHSM_LIB'."
    echo "  Set SOFTHSM_LIB=/path/to/libsofthsm2.so and re-run."
    exit 1
fi

# ── Step 1: Initialise SoftHSM token ────────────────────────────────────────
echo ""
echo "=== [1/4] Initialising SoftHSM token '$TOKEN_LABEL' ==="
if softhsm2-util --show-slots 2>/dev/null | grep -q "Label: *$TOKEN_LABEL"; then
    echo "    Token '$TOKEN_LABEL' already exists — skipping init."
    echo "    To reinitialise, run: softhsm2-util --delete-token --token '$TOKEN_LABEL'"
else
    softhsm2-util --init-token --free \
        --label  "$TOKEN_LABEL" \
        --pin    "$USER_PIN" \
        --so-pin "$SO_PIN"
    echo "    Token initialised."
fi

# ── Step 2: Generate RSA key + self-signed certificate ──────────────────────
echo ""
echo "=== [2/4] Generating RSA-2048 private key and self-signed certificate ==="
openssl genrsa -out "$TMP_KEY" 2048 2>/dev/null
openssl req -new -x509 \
    -key  "$TMP_KEY" \
    -out  "$TMP_CERT" \
    -days "$CERT_DAYS" \
    -subj "$CERT_SUBJECT" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
echo "    Key and certificate generated."

# Convert to DER (pkcs11-tool requires DER format)
# Private key → PKCS#8 DER (unencrypted)
openssl pkcs8 -topk8 -nocrypt \
    -inform PEM -in "$TMP_KEY" \
    -outform DER -out "$TMP_KEY_DER"

openssl x509 -in "$TMP_CERT" -outform DER -out "$TMP_CERT_DER"

# ── Step 3: Import private key ───────────────────────────────────────────────
echo ""
echo "=== [3/4] Importing private key into SoftHSM (label='$KEY_ALIAS', id=$KEY_ID) ==="
pkcs11-tool \
    --module       "$SOFTHSM_LIB" \
    --token-label  "$TOKEN_LABEL" \
    --login        --pin "$USER_PIN" \
    --write-object "$TMP_KEY_DER" \
    --type         privkey \
    --id           "$KEY_ID" \
    --label        "$KEY_ALIAS"
echo "    Private key imported."

# ── Step 4: Import certificate ───────────────────────────────────────────────
echo ""
echo "=== [4/4] Importing certificate into SoftHSM (label='$KEY_ALIAS', id=$KEY_ID) ==="
pkcs11-tool \
    --module       "$SOFTHSM_LIB" \
    --token-label  "$TOKEN_LABEL" \
    --login        --pin "$USER_PIN" \
    --write-object "$TMP_CERT_DER" \
    --type         cert \
    --id           "$KEY_ID" \
    --label        "$KEY_ALIAS"
echo "    Certificate imported."

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " SoftHSM setup complete!"
echo "  Token label : $TOKEN_LABEL"
echo "  User PIN    : $USER_PIN"
echo "  Key alias   : $KEY_ALIAS"
echo ""
echo " Verify with:"
echo "   softhsm2-util --show-slots"
echo "   pkcs11-tool --module $SOFTHSM_LIB --token-label $TOKEN_LABEL --list-objects"
echo ""
echo " Update src/main/resources/pkcs11.cfg if your library path differs:"
echo "   library = $SOFTHSM_LIB"
echo ""
echo " Then start the application:"
echo "   ./mvnw spring-boot:run"
echo " and test with:"
echo "   curl -k https://localhost:8443/hello"
echo "============================================================"
