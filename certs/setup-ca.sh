#!/usr/bin/env bash
#
# setup-ca.sh
# -----------
# Creates the organizational Certificate Authority used to issue:
#   - Server certificates (via setup-softhsm.sh → SoftHSM)
#   - Client certificates (via generate-client-cert.sh)
#
#   1. Generate CA private key
#   2. Create self-signed CA certificate
#   3. Import CA certificate into the server truststore (server/certs/truststore.p12)
#
# Run once before setup-softhsm.sh or issuing client certificates.
# Re-running replaces the CA and invalidates all previously issued certificates.
#
# Prerequisites:
#   apt install openssl   (keytool ships with the JDK)
#
# Usage:
#   ./certs/setup-ca.sh
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CA_DIR="$SCRIPT_DIR/ca"
CA_KEY="$CA_DIR/ca.key"
CA_CERT="$CA_DIR/ca.crt"
CA_SERIAL="$CA_DIR/ca.srl"

SERVER_CERTS_DIR="$REPO_ROOT/server/certs"
SERVER_TRUSTSTORE="${SERVER_TRUSTSTORE:-$SERVER_CERTS_DIR/truststore.p12}"

CA_ALIAS="${CA_ALIAS:-org-ca}"
CA_SUBJECT="${CA_SUBJECT:-/CN=Example Org CA/O=Example/C=US}"
CA_DAYS="${CA_DAYS:-3650}"
TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-123456}"

# ── Preflight checks ─────────────────────────────────────────────────────────
for cmd in openssl keytool; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found."
        [[ "$cmd" == "keytool" ]] && echo "  keytool is included with the JDK — ensure JAVA_HOME is set."
        exit 1
    fi
done

if [[ -f "$CA_CERT" && "${FORCE:-}" != "1" ]]; then
    echo "ERROR: CA already exists at $CA_CERT"
    echo "  Re-running replaces the CA and invalidates all issued client certificates."
    echo "  To recreate: FORCE=1 $0"
    exit 1
fi

mkdir -p "$CA_DIR" "$SERVER_CERTS_DIR"

# ── Step 1: Generate CA private key ──────────────────────────────────────────
echo ""
echo "=== [1/3] Generating CA private key ==="
openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
echo "    Created: $CA_KEY"

# ── Step 2: Create self-signed CA certificate ────────────────────────────────
echo ""
echo "=== [2/3] Creating self-signed CA certificate ==="
openssl req -new -x509 \
    -key  "$CA_KEY" \
    -out  "$CA_CERT" \
    -days "$CA_DAYS" \
    -sha256 \
    -subj "$CA_SUBJECT" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
echo "    Created: $CA_CERT"

# Reset serial file used when signing client CSRs
rm -f "$CA_SERIAL"

# ── Step 3: Import CA into server truststore ─────────────────────────────────
echo ""
echo "=== [3/3] Creating server truststore with CA certificate ==="
if [[ -f "$SERVER_TRUSTSTORE" ]]; then
    rm -f "$SERVER_TRUSTSTORE"
    echo "    Replaced existing truststore."
fi

keytool -importcert \
    -alias "$CA_ALIAS" \
    -file  "$CA_CERT" \
    -keystore "$SERVER_TRUSTSTORE" \
    -storetype PKCS12 \
    -storepass "$TRUSTSTORE_PASSWORD" \
    -noprompt
echo "    Created: $SERVER_TRUSTSTORE (alias: $CA_ALIAS)"

echo ""
echo "============================================================"
echo " Organizational CA ready:"
echo "   CA key  : $CA_KEY"
echo "   CA cert : $CA_CERT"
echo ""
echo " Server truststore (CA only — trusts all CA-signed client certs):"
echo "   $SERVER_TRUSTSTORE  (password: $TRUSTSTORE_PASSWORD)"
echo ""
 echo " Issue server + client certificates:"
 echo "   ./setup-softhsm.sh"
 echo "   ./certs/generate-client-cert.sh <client-name>"
echo "============================================================"
