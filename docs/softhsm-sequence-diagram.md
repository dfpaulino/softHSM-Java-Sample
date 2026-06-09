# SoftHSM2 Sequence Diagram

`setup-softhsm.sh` — Initialise → First-run import → Certificate rotation → Reload

## Flow

```mermaid
sequenceDiagram
    participant Script as setup-softhsm.sh
    participant OpenSSL
    participant HSM as SoftHSM<br/>(pkcs11-tool)
    participant Spring as Spring Boot<br/>/ Tomcat

    rect rgb(30, 40, 60)
        Note over Script,Spring: ① FIRST RUN — no existing canonical objects; application not yet started

        Script->>HSM: softhsm2-util --init-token --label springboot
        Note over HSM: [empty — token created, no PKCS#11 objects]

        Script->>OpenSSL: genrsa 2048 + req -x509 (PEM → DER)

        Script->>HSM: write-object privkey  label=mykey  ID=01
        Script->>HSM: write-object cert     label=mykey  ID=01
        Note over HSM: privkey  mykey  (ID=01)<br/>cert     mykey  (ID=01)
    end

    rect rgb(40, 30, 60)
        Note over Script,Spring: ② ROTATION — application running; TLS live on canonical mykey / ID=01

        Script->>OpenSSL: genrsa 2048 + req -x509 (new key + cert → DER)

        Script->>HSM: delete-object privkey+cert  ID=02  (cleanup leftover staging)
        Script->>HSM: write-object privkey  label=mykey-staging  ID=02
        Script->>HSM: write-object cert     label=mykey-staging  ID=02
        Note over HSM: privkey  mykey          (ID=01) ← canonical; Tomcat active; HTTPS live<br/>cert     mykey          (ID=01) ← canonical; Tomcat active; HTTPS live<br/>privkey  mykey-staging  (ID=02) ← new material; not yet active<br/>cert     mykey-staging  (ID=02) ← new material; not yet active

        Script->>Spring: POST /ssl/reload?alias=mykey-staging
        Spring->>Spring: loadKeyStore(provider) — KeyStore.load(null, pin)
        Spring->>Spring: buildBundle("mykey-staging") + updateBundle()
        Spring-->>Script: HTTP 200 — Tomcat live on mykey-staging (ID=02)

        Script->>HSM: delete-object privkey+cert  ID=01  (remove old canonical)
        Note over HSM: privkey  mykey-staging  (ID=02) ← Tomcat active<br/>cert     mykey-staging  (ID=02) ← Tomcat active

        Script->>HSM: write-object privkey  label=mykey  ID=01  (new cert)
        Script->>HSM: write-object cert     label=mykey  ID=01
        Note over HSM: privkey  mykey          (ID=01) ← new canonical (ready)<br/>cert     mykey          (ID=01) ← new canonical (ready)<br/>privkey  mykey-staging  (ID=02) ← Tomcat still active (zero-downtime gap)<br/>cert     mykey-staging  (ID=02) ← Tomcat still active (zero-downtime gap)

        Script->>Spring: POST /ssl/reload  (no alias → canonical "mykey")
        Spring->>Spring: loadKeyStore(provider) — KeyStore.load(null, pin)
        Spring->>Spring: buildBundle("mykey") + updateBundle()
        Spring-->>Script: HTTP 200 — Tomcat live on mykey (ID=01)

        Script->>HSM: delete-object privkey+cert  ID=02  (remove staging)
        Note over HSM: privkey  mykey  (ID=01)  ✓  active<br/>cert     mykey  (ID=01)  ✓  active
    end
```

## HSM Object States Summary

| Phase | HSM Objects |
|---|---|
| After `init-token` | *(empty)* |
| After first-run import | `privkey mykey (ID=01)`, `cert mykey (ID=01)` |
| After staging import | + `privkey mykey-staging (ID=02)`, `cert mykey-staging (ID=02)` |
| After reload #1 (→ staging) | Tomcat switches to `mykey-staging/ID=02` |
| After deleting old canonical | `privkey mykey-staging (ID=02)`, `cert mykey-staging (ID=02)` only |
| After re-importing canonical | + `privkey mykey (ID=01)`, `cert mykey (ID=01)` (new cert) |
| After reload #2 (→ canonical) | Tomcat switches back to `mykey/ID=01` |
| After removing staging | `privkey mykey (ID=01)`, `cert mykey (ID=01)` — rotation complete |

## Key design decisions

- **Dual-alias rolling swap** — the old alias stays active in Tomcat while the new material is imported under a staging alias, so HTTPS never drops.
- **Two reloads required** — reload #1 moves Tomcat off the old canonical (freeing ID=01 to be safely deleted); reload #2 moves Tomcat onto the freshly-written canonical (ID=01), after which staging (ID=02) can be safely removed.
- **Rollback on any failure** — if either reload returns a non-200 response, the script deletes the staging objects and leaves the original certificate untouched.
- **SunPKCS11 provider is persistent** — the JVM provider is registered once at startup; `loadKeyStore()` simply calls `KeyStore.load(null, pin)` which re-reads the token's current objects each time, so no provider restart is needed.
