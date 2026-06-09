package com.example.springpkcs11.controller;

import com.example.springpkcs11.config.Pkcs11SslConfig;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.ssl.SslBundle;
import org.springframework.boot.ssl.SslBundleRegistry;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

import java.security.KeyStore;
import java.security.Provider;
import java.security.Security;

/**
 * Exposes POST /ssl/reload to hot-reload the TLS certificate and private key
 * from SoftHSM without restarting the application.
 *
 * The endpoint is intentionally restricted to the plain HTTP management port
 * (default 8080) so it remains reachable even while the HTTPS private key is
 * temporarily absent during certificate rotation.
 *
 * Renewal workflow:
 *   1. ./setup-softhsm.sh              — replace key + cert in SoftHSM
 *   2. curl -X POST http://localhost:8080/ssl/reload   — hot-reload Tomcat SSL
 */
@RestController
public class SslReloadController {

    @Autowired
    private SslBundleRegistry sslBundleRegistry;

    @Autowired
    private Pkcs11SslConfig pkcs11SslConfig;

    @PostMapping("/ssl/reload")
    public ResponseEntity<String> reload(HttpServletRequest request) {
        // Guard: only allow calls arriving on the plain HTTP management port.
        if (request.getLocalPort() != pkcs11SslConfig.managementPort) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN)
                    .body("This endpoint is only accessible on the management port ("
                            + pkcs11SslConfig.managementPort + ")");
        }

        // The SunPKCS11 provider was registered at startup and stays in the JVM.
        // SoftHSM appends its token name to "SunPKCS11-", giving "SunPKCS11-SoftHSM".
        Provider provider = Security.getProvider("SunPKCS11-SoftHSM");
        if (provider == null) {
            return ResponseEntity.internalServerError()
                    .body("SunPKCS11-SoftHSM provider not found — was the application started correctly?");
        }

        KeyStore keyStore = pkcs11SslConfig.loadKeyStore(provider);
        SslBundle newBundle = pkcs11SslConfig.buildBundle(keyStore);

        // updateBundle() fires Tomcat's change listener → SslConnectorCustomizer.update()
        // → in-place SSL context reload with no connection drops.
        sslBundleRegistry.updateBundle(Pkcs11SslConfig.BUNDLE_NAME, newBundle);

        return ResponseEntity.ok("SSL bundle '" + Pkcs11SslConfig.BUNDLE_NAME + "' reloaded from HSM");
    }
}
