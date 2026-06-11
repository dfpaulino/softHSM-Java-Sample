package com.example.springpkcs11.config;

import org.apache.catalina.connector.Connector;
import org.apache.coyote.http11.Http11NioProtocol;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ssl.SslBundle;
import org.springframework.boot.ssl.SslBundleKey;
import org.springframework.boot.ssl.SslBundleRegistry;
import org.springframework.boot.ssl.SslStoreBundle;
import org.springframework.boot.tomcat.servlet.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.Ssl;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.net.InetAddress;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.security.KeyStore;
import java.security.Provider;
import java.security.Security;

/**
 * Registers the SunPKCS11 JCA provider backed by SoftHSM, wraps the PKCS#11
 * KeyStore in a Spring Boot SslBundle, and wires it into the embedded Tomcat
 * server. Spring Boot automatically registers a change listener on the bundle
 * so that calling SslBundleRegistry.updateBundle() hot-reloads TLS without
 * restarting the application.
 */
@Component
public class Pkcs11SslConfig implements WebServerFactoryCustomizer<TomcatServletWebServerFactory> {

    public static final String BUNDLE_NAME = "pkcs11-bundle";

    @Value("${pkcs11.config-file:pkcs11.cfg}")
    private String configFile;

    @Value("${pkcs11.pin}")
    String pin;

    @Value("${pkcs11.key-alias:mykey}")
    public String keyAlias;

    @Value("${pkcs11.management-port:8080}")
    public int managementPort;

    @Autowired
    private SslBundleRegistry sslBundleRegistry;

    @Override
    public void customize(TomcatServletWebServerFactory factory) {
        Provider provider = registerProvider();
        KeyStore keyStore = loadKeyStore(provider);

        sslBundleRegistry.registerBundle(BUNDLE_NAME, buildBundle(keyStore));

        // Telling the factory which bundle to use causes Spring Boot to wire the
        // Tomcat connector AND register a listener that calls
        // SslConnectorCustomizer.update() whenever updateBundle() is invoked.
        Ssl ssl = new Ssl();
        ssl.setBundle(BUNDLE_NAME);
        factory.setSsl(ssl);

        // Plain HTTP connector bound to loopback, used as a management fallback
        // (e.g. emergency reload if HTTPS becomes unavailable for any reason).
        factory.addAdditionalConnectors(createManagementConnector(managementPort));
    }

    private Connector createManagementConnector(int port) {
        Connector connector = new Connector(Http11NioProtocol.class.getName());
        connector.setScheme("http");
        connector.setPort(port);
        connector.setSecure(false);
        ((Http11NioProtocol) connector.getProtocolHandler())
                .setAddress(InetAddress.getLoopbackAddress());
        return connector;
    }

    /**
     * Instantiates and registers the SunPKCS11 provider configured for SoftHSM.
     * Safe to call multiple times — returns the already-registered instance if present.
     */
    Provider registerProvider() {
        try {
            String absoluteConfigPath = resolveConfigFilePath();
            Provider existing = Security.getProvider("SunPKCS11-SoftHSM");
            if (existing != null) {
                return existing;
            }
            Provider provider = Security.getProvider("SunPKCS11");
            provider = provider.configure(absoluteConfigPath);
            Security.addProvider(provider);
            return provider;
        } catch (IOException e) {
            throw new IllegalStateException("Cannot resolve PKCS#11 config file", e);
        }
    }

    /**
     * Loads the PKCS#11 KeyStore from the HSM token.
     * The HSM is the backing store — load(null, pin) connects to the token and
     * reads the current objects. A new KeyStore instance always reflects the
     * current state of the HSM (keys present at load time).
     */
    public KeyStore loadKeyStore(Provider provider) {
        try {
            KeyStore keyStore = KeyStore.getInstance("PKCS11", provider);
            keyStore.load(null, pin.toCharArray());
            return keyStore;
        } catch (Exception e) {
            throw new IllegalStateException("Failed to load PKCS#11 KeyStore from HSM", e);
        }
    }

    /**
     * Builds a Spring Boot SslBundle using the configured default key alias.
     * Called at startup.
     */
    public SslBundle buildBundle(KeyStore keyStore) {
        return buildBundle(keyStore, keyAlias);
    }

    /**
     * Builds a Spring Boot SslBundle using an explicit key alias.
     * Used during rolling rotation to target a staging alias before it is
     * promoted to the canonical alias.
     */
    public SslBundle buildBundle(KeyStore keyStore, String alias) {
        SslStoreBundle stores = SslStoreBundle.of(keyStore, pin, null);
        SslBundleKey key = SslBundleKey.of(pin, alias);
        return SslBundle.of(stores, key);
    }

    private String resolveConfigFilePath() throws IOException {
        Path path = Paths.get(configFile);
        if (Files.exists(path)) {
            return path.toAbsolutePath().toString();
        }

        ClassPathResource resource = new ClassPathResource(configFile);
        if (resource.exists()) {
            File tempFile = File.createTempFile("pkcs11-", ".cfg");
            tempFile.deleteOnExit();
            Files.copy(resource.getInputStream(), tempFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
            return tempFile.getAbsolutePath();
        }

        throw new FileNotFoundException("PKCS#11 config file not found: " + configFile);
    }
}
