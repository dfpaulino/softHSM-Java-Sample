package com.example.springpkcs11.controller;

import com.example.springpkcs11.config.Pkcs11SslConfig;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.ssl.SslBundle;
import org.springframework.boot.ssl.SslBundleRegistry;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.security.KeyStore;
import java.security.Provider;
import java.security.Security;

/**
 * Exposes POST /ssl/reload to hot-reload the TLS certificate and private key
 * from SoftHSM without restarting the application.
 *
 * Rolling rotation workflow (no HTTPS downtime):
 *   1. setup-softhsm.sh imports the new key+cert under the staging alias
 *      while the old canonical alias is still active in Tomcat.
 *   2. The script calls POST https://localhost:8443/ssl/reload?alias=mykey-staging
 *      — HTTPS still works because the old key is untouched.
 *   3. Tomcat hot-reloads using the staging alias.
 *   4. The script promotes the staging alias to the canonical one and
 *      removes the old objects from the HSM.
 *
 * Emergency fallback (when HTTPS is unavailable):
 *   curl -X POST http://localhost:8080/ssl/reload
 *   (plain HTTP management port, loopback-only)
 */
@RestController
public class SslReloadController {

    @Autowired
    private SslBundleRegistry sslBundleRegistry;

    @Autowired
    private Pkcs11SslConfig pkcs11SslConfig;

    /**
     * @param alias optional key alias to use for the reload.
     *              If omitted, falls back to {@code pkcs11.key-alias} (the canonical alias).
     *              Pass the staging alias during rolling rotation.
     */
    @PostMapping("/ssl/reload")
    public ResponseEntity<String> reload(
            @RequestParam(value = "alias", required = false) String alias) {

        // The SunPKCS11 provider was registered at startup and persists in the JVM.
        // SoftHSM names it "SunPKCS11-" + the 'name' field in pkcs11.cfg.
        Provider provider = Security.getProvider("SunPKCS11-SoftHSM");
        if (provider == null) {
            return ResponseEntity.internalServerError()
                    .body("SunPKCS11-SoftHSM provider not found — was the application started correctly?");
        }

        String effectiveAlias = (alias != null && !alias.isBlank()) ? alias : pkcs11SslConfig.keyAlias;

        KeyStore keyStore = pkcs11SslConfig.loadKeyStore(provider);
        SslBundle newBundle = pkcs11SslConfig.buildBundle(keyStore, effectiveAlias);

        // updateBundle() fires Tomcat's change listener → SslConnectorCustomizer.update()
        // → in-place SSL context reload, no connection drops.
        sslBundleRegistry.updateBundle(Pkcs11SslConfig.BUNDLE_NAME, newBundle);

        return ResponseEntity.ok("SSL bundle '" + Pkcs11SslConfig.BUNDLE_NAME
                + "' reloaded from HSM using alias '" + effectiveAlias + "'");
    }
}
