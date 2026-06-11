#!/usr/bin/env bash
#
# list-truststore.sh
# ------------------
# Shows CA certificate(s) in the server truststore and lists issued client
# certificate directories under certs/clients/.
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SERVER_TRUSTSTORE="${SERVER_TRUSTSTORE:-$SCRIPT_DIR/truststore.p12}"
TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-123456}"
CLIENTS_DIR="$REPO_ROOT/certs/clients"

if ! command -v keytool &>/dev/null; then
    echo "ERROR: 'keytool' not found — ensure the JDK is installed."
    exit 1
fi

echo "=== Server truststore ==="
if [[ ! -f "$SERVER_TRUSTSTORE" ]]; then
    echo "No truststore found at: $SERVER_TRUSTSTORE"
    echo "Run: ./certs/setup-ca.sh"
else
    echo "Location: $SERVER_TRUSTSTORE"
    echo ""
    keytool -list \
        -keystore "$SERVER_TRUSTSTORE" \
        -storetype PKCS12 \
        -storepass "$TRUSTSTORE_PASSWORD"
fi

echo ""
echo "=== Issued client certificates (signed by org CA) ==="
if [[ ! -d "$CLIENTS_DIR" ]] || [[ -z "$(ls -A "$CLIENTS_DIR" 2>/dev/null)" ]]; then
    echo "No client certificates issued yet."
    echo "Run: ./certs/generate-client-cert.sh <client-name>"
else
    for client_dir in "$CLIENTS_DIR"/*; do
        [[ -d "$client_dir" ]] || continue
        name="$(basename "$client_dir")"
        if [[ -f "$client_dir/client.crt" ]]; then
            subject=$(openssl x509 -in "$client_dir/client.crt" -noout -subject 2>/dev/null | sed 's/subject=//')
            expiry=$(openssl x509 -in "$client_dir/client.crt" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
            echo "  $name — $subject (expires: $expiry)"
        else
            echo "  $name — (incomplete — missing client.crt)"
        fi
    done
fi
