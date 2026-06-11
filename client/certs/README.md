Client certificates are issued from the shared PKI scripts at the repo root:

```bash
./certs/setup-ca.sh                        # once: create org CA + server truststore
./setup-softhsm.sh                         # server key+cert (CA-signed) → SoftHSM
./certs/generate-client-cert.sh <name>     # per client: key → CSR → CA-signed cert → .p12
```

Issued client material is stored under `certs/clients/<name>/`.
The server presents a CA-signed certificate from SoftHSM (see `setup-softhsm.sh`).
