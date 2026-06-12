package com.example.springpkcs11.client;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.CommandLineRunner;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Duration;

@Component
public class HelloClientRunner implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(HelloClientRunner.class);

    private final WebClient webClient;

    @Value("${client.server.hello-path:/hello}")
    private String helloPath;

    @Value("${client.server.request-timeout-seconds:15}")
    private long requestTimeoutSeconds;

    public HelloClientRunner(WebClient mtlsWebClient) {
        this.webClient = mtlsWebClient;
    }

    @Override
    public void run(String... args) {
        log.info("mTLS calling succeeded: GET {}", helloPath);
        String response = webClient.get()
                .uri(helloPath)
                .retrieve()
                .bodyToMono(String.class)
                .block(Duration.ofSeconds(requestTimeoutSeconds));

        log.info("mTLS call succeeded: GET {} -> {}", helloPath, response);
    }
}
