package com.auric.service;

import com.auric.model.TokenUsage;
import com.auric.repository.TokenUsageRepository;
import lombok.Builder;
import lombok.Getter;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.LocalDateTime;

@Service
@RequiredArgsConstructor
public class TokenUsageService {

    private final TokenUsageRepository tokenUsageRepository;

    @Value("${ai.usage.limit.tokens:20000}")
    private int tokenLimitPerWindow;

    @Value("${ai.usage.window.hours:6}")
    private int usageWindowHours;

    public UsageDecision checkLimit(String userId, int estimatedTokens) {
        if (tokenLimitPerWindow <= 0) {
            return UsageDecision.builder()
                    .allowed(true)
                    .usedTokens(0)
                    .remainingTokens(Integer.MAX_VALUE)
                    .retryAfterSeconds(0)
                    .build();
        }

        LocalDateTime since = LocalDateTime.now().minusHours(Math.max(1, usageWindowHours));
        long used = tokenUsageRepository.sumTokensSince(userId, since);
        long remaining = Math.max(0, (long) tokenLimitPerWindow - used);
        boolean allowed = estimatedTokens <= remaining;

        long retryAfterSeconds = 0;
        if (!allowed) {
            retryAfterSeconds = tokenUsageRepository
                    .findFirstByUserIdAndCreatedAtAfterOrderByCreatedAtAsc(userId, since)
                    .map(first -> Duration.between(LocalDateTime.now(), first.getCreatedAt().plusHours(Math.max(1, usageWindowHours))).getSeconds())
                    .map(sec -> Math.max(0, sec))
                    .orElse(0L);
        }

        return UsageDecision.builder()
                .allowed(allowed)
                .usedTokens(used)
                .remainingTokens(remaining)
                .retryAfterSeconds(retryAfterSeconds)
                .build();
    }

    public UsageStatus getUsageStatus(String userId) {
        if (tokenLimitPerWindow <= 0) {
            return UsageStatus.builder()
                    .usedTokens(0)
                    .limitTokens(0)
                    .remainingTokens(Long.MAX_VALUE)
                    .windowHours(Math.max(1, usageWindowHours))
                    .usagePercent(0)
                    .retryAfterSeconds(0)
                    .unlimited(true)
                    .build();
        }

        int window = Math.max(1, usageWindowHours);
        LocalDateTime since = LocalDateTime.now().minusHours(window);
        long used = tokenUsageRepository.sumTokensSince(userId, since);
        long limit = Math.max(1, tokenLimitPerWindow);
        long remaining = Math.max(0, limit - used);

        long retryAfterSeconds = tokenUsageRepository
                .findFirstByUserIdAndCreatedAtAfterOrderByCreatedAtAsc(userId, since)
                .map(first -> Duration.between(LocalDateTime.now(), first.getCreatedAt().plusHours(window)).getSeconds())
                .map(sec -> Math.max(0, sec))
                .orElse(0L);

        double usagePercent = Math.min(100.0, (used * 100.0) / limit);

        return UsageStatus.builder()
                .usedTokens(used)
                .limitTokens(limit)
                .remainingTokens(remaining)
                .windowHours(window)
                .usagePercent(usagePercent)
                .retryAfterSeconds(retryAfterSeconds)
                .unlimited(false)
                .build();
    }

    @Transactional
    public void recordUsage(String userId, int tokens) {
        if (tokenLimitPerWindow <= 0 || tokens <= 0) return;
        tokenUsageRepository.save(TokenUsage.builder()
                .userId(userId)
                .tokens(tokens)
                .build());
    }

    @Getter
    @Builder
    public static class UsageDecision {
        private boolean allowed;
        private long usedTokens;
        private long remainingTokens;
        private long retryAfterSeconds;
    }

    @Getter
    @Builder
    public static class UsageStatus {
        private long usedTokens;
        private long limitTokens;
        private long remainingTokens;
        private int windowHours;
        private double usagePercent;
        private long retryAfterSeconds;
        private boolean unlimited;
    }
}
