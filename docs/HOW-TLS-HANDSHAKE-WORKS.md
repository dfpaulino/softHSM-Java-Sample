# How TLS Handshake Works with PKCS#11 / SoftHSM

This document explains what happens at application startup and during every TLS handshake
when the private key is stored in an HSM (or SoftHSM) via PKCS#11, and how the JVM,
Spring Boot, and `libsofthsm2.so` interact.

---

## Phase 1: Application Startup

### Step 1 — Provider registration

```java
Provider provider = Security.getProvider("SunPKCS11");
provider = provider.configure("/path/pkcs11.cfg");
Security.addProvider(provider);
```

- The JVM loads `libsofthsm2.so` into the process via JNI.
- `SunPKCS11` opens a **PKCS#11 session** with the SoftHSM token at the configured slot.
- No objects are read from the token yet — this is just a connection.

---

### Step 2 — `KeyStore.load(null, pin)`

```java
KeyStore keyStore = KeyStore.getInstance("PKCS11", provider);
keyStore.load(null, pin.toCharArray());
```

`SunPKCS11` now scans all objects in the token. For each object found:

| Token object type    | What the JVM receives                                      | Stored in Java heap?               |
|----------------------|------------------------------------------------------------|------------------------------------|
| `CKO_CERTIFICATE`    | Full DER bytes copied out of the token                     | **Yes** — full `X509Certificate`   |
| `CKO_PRIVATE_KEY`    | An opaque handle (`CKK_handle`, an integer ID) wrapped in a `P11Key` | **Yes, but only the handle** — key bytes never leave the HSM |
| `CKO_PUBLIC_KEY`     | Full key bytes copied out                                  | Yes                                |

After `keyStore.load()`:

```
Java Heap                           SoftHSM token (libsofthsm2.so)
─────────────────────────           ──────────────────────────────
X509Certificate (full DER)   ←───  CKO_CERTIFICATE  (bytes copied out at load time)
P11Key { handle = 0x0003 }   ←───  CKO_PRIVATE_KEY  (key bytes NEVER copied out)
```

> **The private key material never appears in the Java heap. Ever.**

---

### Step 3 — SslBundle registration

The `KeyStore` (holding the cert and the `P11Key` handle) is wrapped in a Spring Boot
`SslBundle` and registered with `SslBundleRegistry`. Tomcat builds an `SSLContext` from
it. The cert and key handle are now embedded in Tomcat's `KeyManagerFactory`.

---

## Phase 2: Every TLS Handshake

The following annotates a full TLS 1.3 handshake with which steps involve the HSM:

```
Client                      JVM / Tomcat                         libsofthsm2.so
──────                      ────────────                         ──────────────

ClientHello ───────────────→
                            ServerHello
                            (cipher suite negotiation)
                            ✗ No HSM call

                            Certificate message:
                            KeyManager.getCertificateChain()
                              → reads X509Certificate from heap
                            ✗ No HSM call
                            sends cert bytes ──────────────────────────────────────→

                            CertificateVerify message:
                            Need to sign the handshake transcript

                            KeyManager.getPrivateKey()
                              → returns P11Key handle
                            ✗ No HSM call yet

                            Signature.getInstance("SHA256withRSA")
                            signature.initSign(p11Key)
                            signature.update(handshakeTranscript)
                            signature.sign()
                              ↓
                              C_SignInit(session, mechanism, keyHandle) ──→ libsofthsm2
                              C_Sign(session, data, dataLen,            ──→ performs the
                                     sig, sigLen)                       ──→ RSA/ECDSA op
                              ← returns signature bytes only            ←──
                            ✓ HSM called (2 JNI calls)
                            sends CertificateVerify ────────────────────────────────→

                            Finished (HMAC computed in JVM)
                            ✗ No HSM call

Client verifies ───────────→
Handshake complete
```

### What crosses the JNI boundary into `libsofthsm2.so` on every handshake

| PKCS#11 call  | Data sent to HSM                                         | Data returned        |
|---------------|----------------------------------------------------------|----------------------|
| `C_SignInit`  | session handle, mechanism (e.g. `CKM_RSA_PKCS`), key handle | status           |
| `C_Sign`      | handshake transcript bytes (~100–200 bytes)              | the signature bytes  |

That is it — **two JNI calls per TLS handshake**. No certificate bytes, no key bytes.

---

## What Lives in Memory During Normal Operation

```
Java Heap (set at startup, remains for the lifetime of the application)
───────────────────────────────────────────────────────────────────────
┌─ KeyStore (PKCS11)
│   ├─ "mykey" cert entry  →  X509Certificate (full DER, ~1–2 KB)
│   └─ "mykey" key entry   →  P11Key { sessionHandle, objectHandle = 0x0003 }
└─ SSLContext (Tomcat)
    └─ SunX509KeyManagerImpl
        └─ references to the above cert and P11Key

Native memory (libsofthsm2.so, via JNI)
───────────────────────────────────────────────────────────────────────
- Open PKCS#11 session(s) with the token (kept alive by SunPKCS11 session pool)
- The actual private key material (RSA/EC private key bytes)
  → These NEVER appear in Java heap
```

---

## Summary Table

|                       | Loaded at startup    | Stays in memory         | HSM call per handshake                      |
|-----------------------|----------------------|-------------------------|---------------------------------------------|
| Certificate           | Yes (full DER bytes) | Yes — Java heap         | No                                          |
| Private key material  | No (never)           | No — handle only        | Yes — 2 JNI calls (`C_SignInit` + `C_Sign`) |
| PKCS#11 session       | Opened at startup    | Yes — native memory     | Reused (no reconnect per handshake)         |

---

## Implications for the Cert-on-Filesystem Design

When the certificate is loaded from the filesystem instead of from the HSM token, the
**runtime TLS handshake behavior is identical**:

- The cert is still read once at startup (or on reload) and cached in the Java heap.
- The private key still never leaves the HSM.
- Every handshake still makes the same two JNI calls into `libsofthsm2.so`.

The only difference is *where the cert bytes come from at load time* — filesystem vs HSM
token — which is a one-time event with no per-request impact.

### Hot-reload on certificate change

When the cert file changes on disk, the reload sequence is:

```
1. WatchService detects cert.pem changed
2. Load new X509Certificate from file (filesystem read, once)
3. Re-open PKCS#11 KeyStore  →  keyStore.load(null, pin)
4. Bind new cert to existing key handle:
       keyStore.setKeyEntry(alias, p11KeyHandle, pin, new Certificate[]{ newCert })
5. Build new SslBundle from the updated KeyStore
6. sslBundleRegistry.updateBundle(BUNDLE_NAME, newBundle)
   → Tomcat swaps SSLContext in-place, zero connection drops
```

The private key handle does not change. Only the cert object in the heap is replaced.
