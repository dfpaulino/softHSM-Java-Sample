#!/usr/bin/env bash
#
# setup-client-softhsm.sh
# -----------------------
# Imports an issued client key/certificate into a dedicated SoftHSM token
# for JVM client-side mTLS (PKCS#11).
#
# Prerequisites:
#   ./certs/setup-ca.sh
#   ./certs/generate-client-cert.sh <client-name>
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

CLIENT_NAME="${1:-${CLIENT_NAME:-alice}}"
TOKEN_LABEL="${TOKEN_LABEL:-springboot-client}"
USER_PIN="${USER_PIN:-1234}"
SO_PIN="${SO_PIN:-0000}"
CLIENT_ALIAS="${CLIENT_ALIAS:-$CLIENT_NAME}"
CLIENT_ID="${CLIENT_ID:-11}"
SOFTHSM_LIB="${SOFTHSM_LIB:-/usr/lib/softhsm/libsofthsm2.so}"

CLIENT_DIR="$REPO_ROOT/certs/clients/$CLIENT_NAME"
CLIENT_KEY_PEM="$CLIENT_DIR/client.key"
CLIENT_CERT_PEM="$CLIENT_DIR/client.crt"

TMP_KEY_DER="/tmp/client_${CLIENT_NAME}_$$.key.der"
TMP_CERT_DER="/tmp/client_${CLIENT_NAME}_$$.crt.der"

cleanup() {
    rm -f "$TMP_KEY_DER" "$TMP_CERT_DER"
}
trap cleanup EXIT

for cmd in softhsm2-util pkcs11-tool openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' not found."
        echo "  apt install softhsm2 opensc openssl"
        exit 1
    fi
done

if [[ ! -f "$SOFTHSM_LIB" ]]; then
    echo "ERROR: SoftHSM library not found at '$SOFTHSM_LIB'."
    echo "Set SOFTHSM_LIB=/path/to/libsofthsm2.so and retry."
    exit 1
fi

if [[ ! -f "$CLIENT_KEY_PEM" || ! -f "$CLIENT_CERT_PEM" ]]; then
    echo "ERROR: client key/certificate not found for '$CLIENT_NAME'."
    echo "Expected:"
    echo "  $CLIENT_KEY_PEM"
    echo "  $CLIENT_CERT_PEM"
    echo "Run: ./certs/generate-client-cert.sh $CLIENT_NAME"
    exit 1
fi

echo ""
echo "=== [1/4] Ensure client token '$TOKEN_LABEL' exists ==="
if softhsm2-util --show-slots 2>/dev/null | grep -q "Label: *$TOKEN_LABEL"; then
    echo "    Token already exists."
else
    softhsm2-util --init-token --free \
        --label "$TOKEN_LABEL" \
        --pin "$USER_PIN" \
        --so-pin "$SO_PIN"
    echo "    Token initialised."
fi

echo ""
echo "=== [2/4] Convert client key/certificate to DER ==="
openssl pkcs8 -topk8 -nocrypt \
    -inform PEM -in "$CLIENT_KEY_PEM" \
    -outform DER -out "$TMP_KEY_DER"
openssl x509 -in "$CLIENT_CERT_PEM" -outform DER -out "$TMP_CERT_DER"
echo "    DER material prepared."

echo ""
echo "=== [3/4] Remove previous objects for ID=$CLIENT_ID (if present) ==="
pkcs11-tool --module "$SOFTHSM_LIB" --token-label "$TOKEN_LABEL" \
    --login --pin "$USER_PIN" \
    --delete-object --type privkey --id "$CLIENT_ID" 2>/dev/null \
    && echo "    Deleted previous private key." \
    || echo "    No previous private key."
pkcs11-tool --module "$SOFTHSM_LIB" --token-label "$TOKEN_LABEL" \
    --login --pin "$USER_PIN" \
    --delete-object --type cert --id "$CLIENT_ID" 2>/dev/null \
    && echo "    Deleted previous certificate." \
    || echo "    No previous certificate."

echo ""
echo "=== [4/4] Import client identity into token ==="
pkcs11-tool --module "$SOFTHSM_LIB" --token-label "$TOKEN_LABEL" \
    --login --pin "$USER_PIN" \
    --write-object "$TMP_KEY_DER" --type privkey --id "$CLIENT_ID" --label "$CLIENT_ALIAS"
pkcs11-tool --module "$SOFTHSM_LIB" --token-label "$TOKEN_LABEL" \
    --login --pin "$USER_PIN" \
    --write-object "$TMP_CERT_DER" --type cert --id "$CLIENT_ID" --label "$CLIENT_ALIAS"
echo "    Imported alias '$CLIENT_ALIAS' (ID=$CLIENT_ID)."

echo ""
echo "Current objects in token '$TOKEN_LABEL':"
pkcs11-tool --module "$SOFTHSM_LIB" --token-label "$TOKEN_LABEL" \
    --login --pin "$USER_PIN" \
    --list-objects

echo ""
echo "============================================================"
echo " Client identity imported to SoftHSM token:"
echo "   token label : $TOKEN_LABEL"
echo "   key alias   : $CLIENT_ALIAS"
echo "   object ID   : $CLIENT_ID"
echo ""
echo " Ensure client/src/main/resources/client-pkcs11.cfg points to"
echo " the matching slot for token '$TOKEN_LABEL'."
echo "============================================================"
