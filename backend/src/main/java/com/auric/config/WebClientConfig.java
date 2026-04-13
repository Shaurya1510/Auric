package com.auric.config;

import io.netty.channel.ChannelOption;
import io.netty.handler.timeout.ReadTimeoutHandler;
import io.netty.handler.timeout.WriteTimeoutHandler;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.reactive.ReactorClientHttpConnector;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.netty.http.client.HttpClient;

import java.time.Duration;
import java.util.concurrent.TimeUnit;

/**
 * Produces a preconfigured WebClient for OpenAI API calls.
 *
 * Includes connect/read/write timeout tuning so long AI responses stream
 * reliably without hanging forever.
 */
@Configuration
public class WebClientConfig {

    // ─── OpenAI ──────────────────────────────────────────────
    @Value("${openai.api.key:}")
    private String openAiApiKey;

    @Value("${openai.base.url:https://api.openai.com/v1}")
    private String openAiBaseUrl;

    @Value("${openai.connect-timeout-ms:5000}")
    private int openAiConnectMs;

    @Value("${openai.response-timeout-sec:90}")
    private int openAiTimeoutSec;

    // Named bean used by OpenAiService.
    @Bean("openAiWebClient")
    public WebClient openAiWebClient() {
        return buildClient(openAiBaseUrl, openAiApiKey, openAiConnectMs, openAiTimeoutSec);
    }

    private WebClient buildClient(String baseUrl, String apiKey,
                                   int connectMs, int timeoutSec) {
        HttpClient httpClient = HttpClient.create()
                .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, connectMs)
                .responseTimeout(Duration.ofSeconds(timeoutSec))
                .doOnConnected(conn -> conn
                        .addHandlerLast(new ReadTimeoutHandler(timeoutSec, TimeUnit.SECONDS))
                        .addHandlerLast(new WriteTimeoutHandler(timeoutSec, TimeUnit.SECONDS)));

        return WebClient.builder()
                .baseUrl(baseUrl)
                .defaultHeader("Authorization", "Bearer " + apiKey)
                .defaultHeader("Content-Type", "application/json")
                .clientConnector(new ReactorClientHttpConnector(httpClient))
                .codecs(c -> c.defaultCodecs().maxInMemorySize(20 * 1024 * 1024))
                .build();
    }
}
