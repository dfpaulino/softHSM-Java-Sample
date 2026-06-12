package com.example.springpkcs11.client.config;

import jakarta.annotation.PostConstruct;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ssl.SslBundle;
import org.springframework.boot.ssl.SslBundleKey;
import org.springframework.boot.ssl.SslBundleRegistry;
import org.springframework.boot.ssl.SslStoreBundle;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.security.KeyStore;
import java.security.Provider;
import java.security.Security;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Mirrors the server's SSL-bundle methodology for outbound mTLS:
 * register a PKCS#11-backed SslBundle in SslBundleRegistry, then let
 * Spring Boot WebClient SSL support consume it by bundle name.
 */
@Component
public class ClientPkcs11SslConfig {

    public static final String BUNDLE_NAME = "client-pkcs11-bundle";

    @Value("${client.pkcs11.config-file:client-pkcs11.cfg}")
    private String configFile;

    @Value("${client.pkcs11.provider-name:SunPKCS11-SoftHSMClient}")
    private String providerName;

    @Value("${client.pkcs11.pin}")
    private String pin;

    @Value("${client.pkcs11.key-alias}")
    private String keyAlias;

    @Value("${client.ssl.truststore-file}")
    private String truststoreFile;

    @Value("${client.ssl.truststore-password}")
    private String truststorePassword;

    @Autowired
    private SslBundleRegistry sslBundleRegistry;

    private final AtomicBoolean bundleRegistered = new AtomicBoolean(false);

    @PostConstruct
    public void initializeBundle() {
        ensureBundleRegistered();
    }

    /**
     * Registers once, updates on subsequent invocations.
     */
    public synchronized void ensureBundleRegistered() {
        Provider provider = registerProvider();
        KeyStore keyStore = loadKeyStore(provider);
        validateAliasExists(keyStore, keyAlias);
        SslBundle bundle = buildBundle(keyStore, keyAlias);

        if (bundleRegistered.compareAndSet(false, true)) {
            sslBundleRegistry.registerBundle(BUNDLE_NAME, bundle);
        } else {
            sslBundleRegistry.updateBundle(BUNDLE_NAME, bundle);
        }
    }

    Provider registerProvider() {
        try {
            String absoluteConfigPath = resolveConfigFilePath();
            Provider existing = Security.getProvider(providerName);
            if (existing != null) {
                return existing;
            }
            Provider baseProvider = Security.getProvider("SunPKCS11");
            if (baseProvider == null) {
                throw new IllegalStateException("SunPKCS11 base provider not found in JVM");
            }
            Provider configuredProvider = baseProvider.configure(absoluteConfigPath);
            Security.addProvider(configuredProvider);
            return configuredProvider;
        } catch (IOException e) {
            throw new IllegalStateException("Cannot resolve client PKCS#11 config file", e);
        }
    }

    KeyStore loadKeyStore(Provider provider) {
        try {
            KeyStore keyStore = KeyStore.getInstance("PKCS11", provider);
            keyStore.load(null, pin.toCharArray());
            return keyStore;
        } catch (Exception e) {
            throw new IllegalStateException("Failed to load PKCS#11 client KeyStore from HSM", e);
        }
    }

    KeyStore loadTrustStore() {
        try {
            Path path = resolveResourcePath(truststoreFile);
            KeyStore trustStore = KeyStore.getInstance("PKCS12");
            try (InputStream in = Files.newInputStream(path)) {
                trustStore.load(in, truststorePassword.toCharArray());
            }
            return trustStore;
        } catch (Exception e) {
            throw new IllegalStateException("Failed to load client truststore: " + truststoreFile, e);
        }
    }

    SslBundle buildBundle(KeyStore keyStore, String alias) {
        SslStoreBundle stores = SslStoreBundle.of(keyStore, pin, loadTrustStore());
        SslBundleKey key = SslBundleKey.of(pin, alias);
        return SslBundle.of(stores, key);
    }

    private void validateAliasExists(KeyStore keyStore, String alias) {
        try {
            if (keyStore.containsAlias(alias)) {
                return;
            }
            Enumeration<String> aliases = keyStore.aliases();
            List<String> available = new ArrayList<>();
            while (aliases.hasMoreElements()) {
                available.add(aliases.nextElement());
            }
            throw new IllegalStateException(
                    "Client key alias '" + alias + "' not found in HSM token. Available aliases: " + available
            );
        } catch (Exception e) {
            if (e instanceof IllegalStateException) {
                throw (IllegalStateException) e;
            }
            throw new IllegalStateException("Failed to inspect PKCS#11 aliases in client token", e);
        }
    }

    private Path resolveResourcePath(String location) throws IOException {
        Path path = Paths.get(location);
        if (Files.exists(path)) {
            return path.toAbsolutePath();
        }

        ClassPathResource resource = new ClassPathResource(location);
        if (resource.exists()) {
            File tempFile = File.createTempFile("client-pkcs11-resource-", ".tmp");
            tempFile.deleteOnExit();
            Files.copy(resource.getInputStream(), tempFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
            return tempFile.toPath();
        }

        throw new FileNotFoundException("Resource not found: " + location);
    }

    private String resolveConfigFilePath() throws IOException {
        return resolveResourcePath(configFile).toString();
    }
}
