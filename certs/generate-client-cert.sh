#!/usr/bin/env bash
#
# generate-client-cert.sh
# -----------------------
# Issues a client certificate signed by the organizational CA:
#
#   1. Generate client private key
#   2. Create a Certificate Signing Request (CSR)
#   3. Sign the CSR with the CA → client certificate
#   4. Export PKCS#12 keystore for the client (includes CA chain)
#
# The server truststore is NOT updated per client — it already contains the CA
# certificate (see setup-ca.sh). Any client cert signed by that CA is accepted.
#
# Prerequisites:
#   ./certs/setup-ca.sh   (run once first)
#
# Usage:
#   ./certs/generate-client-cert.sh <client-name>
#   CLIENT_NAME=alice ./certs/generate-client-cert.sh
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLIENT_NAME="${1:-${CLIENT_NAME:-}}"
if [[ -z "$CLIENT_NAME" ]]; then
    echo "ERROR: client name is required."
    echo "Usage: $0 <client-name>"
    echo "Example: $0 alice"
    exit 1
fi

if [[ ! "$CLIENT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    echo "ERROR: client name must start with a letter or digit and contain only letters, digits, hyphens, or underscores."
    exit 1
fi

CA_DIR="$SCRIPT_DIR/ca"
CA_KEY="$CA_DIR/ca.key"
CA_CERT="$CA_DIR/ca.crt"
CA_SERIAL="$CA_DIR/ca.srl"

CLIENT_DIR="$SCRIPT_DIR/clients/$CLIENT_NAME"
CLIENT_KEY="$CLIENT_DIR/client.key"
CLIENT_CSR="$CLIENT_DIR/client.csr"
CLIENT_CERT="$CLIENT_DIR/client.crt"
CLIENT_P12="$CLIENT_DIR/client.p12"
CLIENT_EXT="$CLIENT_DIR/client.ext"

SERVER_TRUSTSTORE="${SERVER_TRUSTSTORE:-$REPO_ROOT/server/certs/truststore.p12}"

CLIENT_ALIAS="$CLIENT_NAME"
CERT_SUBJECT="${CERT_SUBJECT:-/CN=${CLIENT_NAME}/O=Example Client/C=US}"
CERT_DAYS="${CERT_DAYS:-365}"
P12_PASSWORD="${P12_PASSWORD:-123456}"

# ── Preflight checks ─────────────────────────────────────────────────────────
for cmd in openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found."
        exit 1
    fi
done

if [[ ! -f "$CA_KEY" || ! -f "$CA_CERT" ]]; then
    echo "ERROR: CA not found. Run ./certs/setup-ca.sh first."
    exit 1
fi

if [[ ! -f "$SERVER_TRUSTSTORE" ]]; then
    echo "ERROR: Server truststore not found at $SERVER_TRUSTSTORE"
    echo "  Run ./certs/setup-ca.sh first."
    exit 1
fi

mkdir -p "$CLIENT_DIR"

# ── Step 1: Generate client private key ──────────────────────────────────────
echo ""
echo "=== [1/4] Generating private key for client '$CLIENT_NAME' ==="
openssl genrsa -out "$CLIENT_KEY" 2048 2>/dev/null
echo "    Created: $CLIENT_KEY"

# ── Step 2: Create Certificate Signing Request ───────────────────────────────
echo ""
echo "=== [2/4] Creating certificate signing request ==="
openssl req -new \
    -key  "$CLIENT_KEY" \
    -out  "$CLIENT_CSR" \
    -subj "$CERT_SUBJECT" \
    -addext "subjectAltName=DNS:${CLIENT_NAME},DNS:localhost,IP:127.0.0.1"
echo "    Created: $CLIENT_CSR"

# ── Step 3: Sign CSR with CA ─────────────────────────────────────────────────
echo ""
echo "=== [3/4] Signing CSR with organizational CA ==="
cat > "$CLIENT_EXT" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=DNS:${CLIENT_NAME},DNS:localhost,IP:127.0.0.1
EOF

openssl x509 -req \
    -in       "$CLIENT_CSR" \
    -CA       "$CA_CERT" \
    -CAkey    "$CA_KEY" \
    -CAserial "$CA_SERIAL" \
    -CAcreateserial \
    -out      "$CLIENT_CERT" \
    -days     "$CERT_DAYS" \
    -sha256 \
    -extfile  "$CLIENT_EXT"
echo "    Created: $CLIENT_CERT"

# ── Step 4: Export PKCS#12 keystore (client key + cert + CA chain) ───────────
echo ""
echo "=== [4/4] Creating client PKCS#12 keystore ==="
openssl pkcs12 -export \
    -inkey    "$CLIENT_KEY" \
    -in       "$CLIENT_CERT" \
    -certfile "$CA_CERT" \
    -out      "$CLIENT_P12" \
    -name     "$CLIENT_ALIAS" \
    -passout  "pass:$P12_PASSWORD"
echo "    Created: $CLIENT_P12 (alias: $CLIENT_ALIAS)"

ISSUED_COUNT=$(find "$SCRIPT_DIR/clients" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo "============================================================"
echo " Client '$CLIENT_NAME' certificate material:"
echo "   Directory: $CLIENT_DIR"
echo "   CSR       : $CLIENT_CSR"
echo "   Cert      : $CLIENT_CERT  (signed by org CA)"
echo "   PKCS#12   : $CLIENT_P12  (password: $P12_PASSWORD)"
echo ""
echo " Server truststore unchanged (trusts CA-signed clients via org CA):"
echo "   $SERVER_TRUSTSTORE"
echo "   Issued client directories: $ISSUED_COUNT"
echo ""
echo " Issue another client:"
echo "   $0 <another-client-name>"
echo ""
echo " Inspect truststore:"
echo "   $REPO_ROOT/server/certs/list-truststore.sh"
echo "============================================================"
