package com.auric.dto;

import lombok.Data;
import lombok.Builder;
import lombok.NoArgsConstructor;
import lombok.AllArgsConstructor;
import java.time.LocalDateTime;
import java.util.List;

/**
 * Central DTO namespace used by backend controllers.
 *
 * Keeping request/response shapes here makes API contracts easy to scan.
 */
public class Dtos {

    // ─── Calculator ───────────────────────────────────────

    @Data
    @NoArgsConstructor
    @AllArgsConstructor
    public static class CalcHistoryRequest {
        private String equation;
        private String result;
    }

    @Data
    @Builder
    @NoArgsConstructor
    @AllArgsConstructor
    public static class CalcHistoryResponse {
        private Long id;
        private String equation;
        private String result;
        private LocalDateTime timestamp;
    }

    // ─── Chat Sessions ────────────────────────────────────

    @Data
    @NoArgsConstructor
    @AllArgsConstructor
    public static class CreateSessionRequest {
        private String id;
        private String title;
    }

    @Data
    @NoArgsConstructor
    @AllArgsConstructor
    public static class UpdateSessionRequest {
        private String title;
    }

    @Data
    @Builder
    @NoArgsConstructor
    @AllArgsConstructor
    public static class SessionResponse {
        private String id;
        private String title;
        private LocalDateTime createdAt;
    }

    // ─── Chat Messages ────────────────────────────────────

    @Data
    @NoArgsConstructor
    @AllArgsConstructor
    public static class MessageRequest {
        private String role;
        private String content;
        private String imageData;
    }

    @Data
    @Builder
    @NoArgsConstructor
    @AllArgsConstructor
    public static class MessageResponse {
        private Long id;
        private String role;
        private String content;
        private String imageData;
        private LocalDateTime timestamp;
    }

    /**
     * Extended message response used for the image gallery endpoint.
     * Includes the parent sessionId so the Flutter app can open the correct chat.
     */
    @Data
    @Builder
    @NoArgsConstructor
    @AllArgsConstructor
    public static class ImageMessageResponse {
        private Long id;
        private String role;
        private String content;
        private String imageData;
        private LocalDateTime timestamp;
        private String sessionId;   // The chat session this image belongs to
    }

    // ─── OpenAI Chat ──────────────────────────────────────

    @Data
    @NoArgsConstructor
    @AllArgsConstructor
    public static class AiChatRequest {
        private String message;
        private String imageData;
        private String imageMimeType;
        private List<String> imageDataList;
        private List<String> imageMimeTypeList;
        private String sessionId;
        private String responseMode;
        private List<HistoryMessage> history;
    }

    @Data
    @NoArgsConstructor
    @AllArgsConstructor
    public static class HistoryMessage {
        private String role;
        private String content;
    }

    @Data
    @Builder
    @NoArgsConstructor
    @AllArgsConstructor
    public static class AiChatResponse {
        private String content;
        private String sessionId;
        private String title;
    }

    @Data
    @Builder
    @NoArgsConstructor
    @AllArgsConstructor
    public static class UsageResponse {
        private long usedTokens;
        private long limitTokens;
        private long remainingTokens;
        private int windowHours;
        private double usagePercent;
        private long retryAfterSeconds;
        private boolean unlimited;
    }

    // ─── Auth ─────────────────────────────────────────────

    @Data
    @NoArgsConstructor
    @AllArgsConstructor
    public static class GoogleTokenRequest {
        private String idToken;
    }

    @Data
    @Builder
    @NoArgsConstructor
    @AllArgsConstructor
    public static class AuthResponse {
        private String userId;
        private String email;
        private String name;
        private String picture;
        private String accessToken;
    }

    // ─── Success ──────────────────────────────────────────

    @Data
    @Builder
    @NoArgsConstructor
    @AllArgsConstructor
    public static class SuccessResponse {
        private boolean success;
        private String message;
    }
}
