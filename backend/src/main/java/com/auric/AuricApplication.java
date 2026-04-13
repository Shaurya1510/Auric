package com.auric;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
/**
 * Backend entry point.
 *
 * Starts the Spring context and exposes Auric REST APIs.
 */
public class AuricApplication {
    public static void main(String[] args) {
        SpringApplication.run(AuricApplication.class, args);
    }
}
