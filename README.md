# Spring Boot PKCS#11 / SoftHSM Demo

A multi-module Maven project with a Spring Boot server that serves HTTPS using
a private key stored in a software HSM (Hardware Security Module) via the
PKCS#11 standard. The key never leaves the HSM — the JVM's built-in
`SunPKCS11` provider delegates all crypto operations to SoftHSM2.

Bonus feature: the TLS certificate can be **hot-reloaded** without restarting
the application.

## Modules

| Module | Artifact | Description |
|---|---|---|
| `server` | `spring-pkcs11-server` | PKCS#11 HTTPS server with hot-reload |
| `client` | `spring-pkcs11-client` | Spring Boot WebClient mTLS caller (PKCS#11 identity) |

The parent POM (`spring-pkcs11`) centralises the Spring Boot version and
shared dependency versions for both modules.

---

## Prerequisites

| Requirement | Version |
|---|---|
| Java | 21+ |
| Maven | 3.9+ |
| SoftHSM2 | 2.x |
| OpenSC (`pkcs11-tool`) | any recent |
| OpenSSL | any recent |

---

## 1. Install SoftHSM2 and OpenSC

### Ubuntu / Debian

```bash
sudo apt-get install -y softhsm2 libsofthsm2 opensc openssl
```

> **Note:** On Ubuntu 24.04 and later the old `softhsm` / `libsofthsm` packages
> no longer exist. Always use the `softhsm2` / `libsofthsm2` variants.

### RHEL / Fedora

```bash
sudo dnf install -y softhsm opensc openssl
```

---

## 2. Configure SoftHSM2 for your user

SoftHSM2 needs a config file and a writable directory for its token database.
Run the following **once** as the user that will execute the application (no
`sudo` needed):

```bash
mkdir -p ~/.config/softhsm2
mkdir -p ~/.local/share/softhsm2/tokens

cat > ~/.config/softhsm2/softhsm2.conf <<'EOF'
directories.tokendir = /home/$USER/.local/share/softhsm2/tokens/
objectstore.backend = file
log.level = ERROR
EOF
```

Verify SoftHSM2 picks it up:

```bash
softhsm2-util --show-slots
# Expected: "Available slots: ..."
```

If you still see `Could not load the SoftHSM configuration`, force the path
with an environment variable:

```bash
export SOFTHSM2_CONF=~/.config/softhsm2/softhsm2.conf
```

---

## 3. Find the SoftHSM2 library path

The PKCS#11 config (`server/src/main/resources/pkcs11.cfg`) and the setup script both
need the path to `libsofthsm2.so`. Common locations:

| Distro | Path |
|---|---|
| Ubuntu/Debian (x86-64) | `/usr/lib/softhsm/libsofthsm2.so` |
| Ubuntu/Debian (alternate) | `/usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so` |
| RHEL / Fedora | `/usr/lib64/pkcs11/libsofthsm2.so` |

Find the actual path on your machine:

```bash
find /usr -name libsofthsm2.so 2>/dev/null
```

---

## 4. Create the organizational CA and initialise the HSM

Create the shared org CA first (signs both server and client certificates):

```bash
chmod +x certs/setup-ca.sh
./certs/setup-ca.sh
```

Then initialise SoftHSM and import a **CA-signed** server key + certificate:

```bash
chmod +x setup-softhsm.sh
./setup-softhsm.sh
```

The script performs these steps automatically:

1. Initialises a SoftHSM2 token labelled `springboot` (skipped if it already exists).
2. Generates an RSA-2048 server key and CSR, signed by the org CA.
3. Imports the private key into the HSM token as `mykey`.
4. Imports the CA-signed certificate into the HSM token as `mykey`.

Issue client certificates for mTLS (one per client):

```bash
./certs/generate-client-cert.sh alice
```

Import the client certificate/private key into a **separate client token**:

```bash
chmod +x setup-client-softhsm.sh
./setup-client-softhsm.sh alice
```

This keeps the client identity in HSM too (not in a file keystore at runtime).

If your `libsofthsm2.so` is not at the default path, override it:

```bash
SOFTHSM_LIB=/usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so ./setup-softhsm.sh
```

Verify the objects were imported correctly:

```bash
softhsm2-util --show-slots

pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
    --token-label springboot --list-objects
```

---

## 5. Adjust the PKCS#11 config (if needed)

Open `server/src/main/resources/pkcs11.cfg` and confirm the `library` path matches
your system:

```
name = SoftHSM
library = /usr/lib/softhsm/libsofthsm2.so
slotListIndex = 0
```

Change `library` if your path differs (see table in step 3).

---

## 6. Run the server

```bash
mvn -pl server spring-boot:run
```

Or build a JAR first:

```bash
mvn -pl server package -DskipTests
java -jar server/target/spring-pkcs11-server-1.0.0-SNAPSHOT.jar
```

The server starts two listeners:

| Port | Protocol | Purpose |
|---|---|---|
| `8443` | HTTPS (TLS via SoftHSM) | Main application |
| `8080` | HTTP | Management (SSL reload only) |

---

## 7. Test the endpoints

### Hello endpoint (HTTPS + mTLS)

```bash
curl --cacert certs/ca/ca.crt \
     --cert certs/clients/alice/client.crt \
     --key certs/clients/alice/client.key \
     https://localhost:8443/hello
# Response: Hello, World!
```

The server presents a CA-signed certificate from SoftHSM. Clients must present
a certificate signed by the same org CA (`client-auth: need`).

### Java WebClient module (HTTPS + mTLS via PKCS#11)

The `client` module mirrors the server SSL-bundle methodology:
- registers a PKCS#11-backed `SslBundle` in `SslBundleRegistry`,
- applies that bundle to `WebClient` via `WebClientSsl.fromBundle(...)`.

Before running the client module:
1. Make sure the client token/alias exists (`./setup-client-softhsm.sh alice`).
2. Confirm `client/src/main/resources/client-pkcs11.cfg` points to the correct
   SoftHSM slot (`softhsm2-util --show-slots`).
3. Ensure `client.ssl.truststore-file` points to a truststore containing the org CA.

Run:

```bash
mvn -pl client spring-boot:run
```

Expected log:

```text
mTLS call succeeded: GET /hello -> Hello, World!
```

### Hot-reload TLS certificate

Rotate the key/certificate in SoftHSM and reload without restarting:

```bash
# 1. Replace the key and certificate in SoftHSM
./setup-softhsm.sh

# 2. Tell the running application to pick up the new objects
curl -X POST http://localhost:8080/ssl/reload
# Response: SSL bundle 'pkcs11-bundle' reloaded from HSM
```

> The reload endpoint is intentionally only accessible on the plain HTTP
> management port (`8080`) so it remains reachable even while the HTTPS key is
> temporarily absent during rotation.

---

## Configuration reference

Server settings live in `server/src/main/resources/application.yml`:

| Property | Default | Description |
|---|---|---|
| `pkcs11.config-file` | `src/main/resources/pkcs11.cfg` | Path to the SunPKCS11 provider config |
| `pkcs11.pin` | `1234` | User PIN set when the token was initialised |
| `pkcs11.key-alias` | `mykey` | Label of the private key object in the HSM |
| `pkcs11.management-port` | `8080` | Plain HTTP port for the `/ssl/reload` endpoint |
| `server.port` | `8443` | HTTPS port |

Client settings live in `client/src/main/resources/application.yml`:

| Property | Default | Description |
|---|---|---|
| `client.server.base-url` | `https://localhost:8443` | Server base URL for outgoing calls |
| `client.server.hello-path` | `/hello` | Endpoint path called by `HelloClientRunner` |
| `client.pkcs11.config-file` | `client/src/main/resources/client-pkcs11.cfg` | Path to client SunPKCS11 config |
| `client.pkcs11.provider-name` | `SunPKCS11-SoftHSMClient` | Expected JVM provider name after configuration |
| `client.pkcs11.pin` | `1234` | Client token user PIN |
| `client.pkcs11.key-alias` | `alice` | Client key alias in HSM token |
| `client.ssl.truststore-file` | `server/certs/truststore.p12` | Truststore containing org CA to validate server cert |
| `client.ssl.truststore-password` | `123456` | Truststore password |

---

## Project structure

```
pom.xml                                   Parent POM (Spring Boot version, modules)

server/
├── pom.xml
└── src/main/java/com/example/springpkcs11/
    ├── SpringPkcs11Application.java      Server entry point
    ├── config/
    │   └── Pkcs11SslConfig.java          Registers SunPKCS11 provider, builds
    │                                     SslBundle, wires Tomcat
    └── controller/
        ├── HelloController.java          GET /hello
        └── SslReloadController.java      POST /ssl/reload (hot-reload TLS)
└── src/main/resources/
    ├── application.yml                   Server configuration
    └── pkcs11.cfg                        SunPKCS11 provider configuration

client/
├── pom.xml
└── src/main/java/com/example/springpkcs11/client/
    ├── SpringPkcs11ClientApplication.java   Client entry point
    ├── HelloClientRunner.java               Calls GET /hello over mTLS
    └── config/
        ├── ClientPkcs11SslConfig.java       Registers client SSL bundle (PKCS#11 + truststore)
        └── ClientWebClientConfig.java       Builds WebClient from registered SSL bundle
└── src/main/resources/
    ├── application.yml                       Client configuration
    └── client-pkcs11.cfg                     Client SunPKCS11 provider configuration

setup-softhsm.sh                          One-time HSM initialisation script
setup-client-softhsm.sh                   Client token import helper
```

---

## Troubleshooting

### `Could not load the SoftHSM configuration`

The SoftHSM2 config file is missing. Follow step 2 above to create it.

### `CKR_GENERAL_ERROR` from `pkcs11-tool`

The token directory does not exist or is not writable. Check that
`~/.local/share/softhsm2/tokens/` exists and belongs to your user.

### Wrong library path

Run `find /usr -name libsofthsm2.so` to locate the correct path, then update
`pkcs11.cfg` and the `SOFTHSM_LIB` variable in `setup-softhsm.sh`.

### `SunPKCS11-SoftHSM provider not found`

The application was not started with the correct PKCS#11 config, or the token
was initialised after the JVM started. Restart the application after running
`setup-softhsm.sh`.
