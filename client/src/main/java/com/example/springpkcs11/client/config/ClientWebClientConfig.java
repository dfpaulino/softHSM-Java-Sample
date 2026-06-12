package com.example.springpkcs11.client.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.webclient.autoconfigure.WebClientSsl;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.reactive.function.client.WebClient;

@Configuration
public class ClientWebClientConfig {

    @Value("${client.server.base-url:https://localhost:8443}")
    private String baseUrl;

    @Bean
    public WebClient mtlsWebClient(
            WebClient.Builder webClientBuilder,
            WebClientSsl ssl,
            ClientPkcs11SslConfig clientPkcs11SslConfig) {

        // Ensure the client PKCS#11 bundle is present before WebClient binds to it.
        clientPkcs11SslConfig.ensureBundleRegistered();

        return webClientBuilder
                .baseUrl(baseUrl)
                .apply(ssl.fromBundle(ClientPkcs11SslConfig.BUNDLE_NAME))
                .build();
    }
}
