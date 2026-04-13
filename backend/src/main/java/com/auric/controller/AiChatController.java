package com.auric.controller;

import com.auric.dto.Dtos;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.auric.model.ChatMessage;
import com.auric.model.ChatSession;
import com.auric.repository.ChatMessageRepository;
import com.auric.repository.ChatSessionRepository;
import com.auric.service.OpenAiService;
import com.auric.service.TokenUsageService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.server.ResponseStatusException;
import org.springframework.web.bind.annotation.*;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import java.util.stream.Collectors;

@RestController
@RequestMapping("/api/ai")
@RequiredArgsConstructor
@Slf4j
/**
 * AI chat API surface.
 *
 * Provides session CRUD, message persistence, image listing, and streaming
 * chat responses over SSE.
 */
public class AiChatController {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String IMAGE_MARKER = "[Image attachment included in this message]";

    private final ChatSessionRepository sessionRepo;
    private final ChatMessageRepository messageRepo;
    private final OpenAiService openAiService;
    private final TokenUsageService tokenUsageService;

    private String resolveUserId(Jwt jwt) {
        String userId = jwt != null && jwt.getSubject() != null ? jwt.getSubject().trim() : "";
        if (userId.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Missing authenticated user");
        }
        return userId;
    }

    // ─── Sessions ────────────────────────────────────────────

    // Lists sessions for current user, with optional search/date filtering.
    @GetMapping("/sessions")
    public ResponseEntity<List<Dtos.SessionResponse>> getSessions(
            @AuthenticationPrincipal Jwt jwt,
            @RequestParam(required = false) String search,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate date) {

        String userId = resolveUserId(jwt);
        List<ChatSession> sessions;
        String q = search != null ? search.trim() : null;

        if (q != null && !q.isEmpty()) {
            sessions = sessionRepo.findByUserIdAndTitleContaining(userId, q);
        } else if (date != null) {
            sessions = sessionRepo.findByUserIdAndCreatedAtBetweenOrderByCreatedAtDesc(
                    userId, date.atStartOfDay(), date.plusDays(1).atStartOfDay());
        } else {
            sessions = sessionRepo.findByUserIdOrderByCreatedAtDesc(userId);
        }

        return ResponseEntity.ok(sessions.stream()
                .map(s -> Dtos.SessionResponse.builder()
                        .id(s.getId())
                        .title(s.getTitle() == null || s.getTitle().isBlank() ? "New Chat" : s.getTitle())
                        .createdAt(s.getCreatedAt() != null ? s.getCreatedAt() : LocalDateTime.now())
                        .build())
                .collect(Collectors.toList()));
    }

    @PostMapping("/sessions")
    public ResponseEntity<Map<String, String>> createSession(
            @AuthenticationPrincipal Jwt jwt,
            @RequestBody Dtos.CreateSessionRequest request) {

        String userId = resolveUserId(jwt);
        String id = (request.getId() != null && !request.getId().isBlank())
                ? request.getId().trim() : UUID.randomUUID().toString();

        // If the id conflicts with another user's session, generate a new one
        if (sessionRepo.existsById(id) && sessionRepo.findByIdAndUserId(id, userId).isEmpty()) {
            id = UUID.randomUUID().toString();
        }

        String title = request.getTitle() != null && !request.getTitle().isBlank()
                ? request.getTitle().trim() : "New Chat";
        sessionRepo.save(ChatSession.builder().id(id).title(title).userId(userId).build());
        return ResponseEntity.ok(Map.of("id", id));
    }

    @PatchMapping("/sessions/{id}")
    public ResponseEntity<Dtos.SuccessResponse> updateSession(
            @AuthenticationPrincipal Jwt jwt,
            @PathVariable String id,
            @RequestBody Dtos.UpdateSessionRequest request) {

        String userId = resolveUserId(jwt);
        sessionRepo.findByIdAndUserId(id, userId).ifPresent(s -> {
            String title = request.getTitle() != null ? request.getTitle().trim() : "";
            if (!title.isEmpty()) { s.setTitle(title); sessionRepo.save(s); }
        });
        return ResponseEntity.ok(Dtos.SuccessResponse.builder().success(true).build());
    }

    @Transactional
    @DeleteMapping("/sessions/{id}")
    public ResponseEntity<Dtos.SuccessResponse> deleteSession(
            @AuthenticationPrincipal Jwt jwt,
            @PathVariable String id) {

        String userId = resolveUserId(jwt);
        sessionRepo.findByIdAndUserId(id, userId).ifPresent(sessionRepo::delete);
        return ResponseEntity.ok(Dtos.SuccessResponse.builder().success(true).build());
    }

    // ─── Messages ────────────────────────────────────────────

    @GetMapping("/sessions/{id}/messages")
    public ResponseEntity<List<Dtos.MessageResponse>> getMessages(
            @AuthenticationPrincipal Jwt jwt,
            @PathVariable String id) {

        String userId = resolveUserId(jwt);
        ChatSession session = sessionRepo.findByIdAndUserId(id, userId)
                .orElseThrow(() -> new RuntimeException("Session not found"));

        return ResponseEntity.ok(
                messageRepo.findBySession_IdOrderByTimestampAsc(session.getId()).stream()
                        .map(m -> Dtos.MessageResponse.builder()
                                .id(m.getId())
                                .role(m.getRole())
                                .content(m.getContent() != null ? m.getContent() : "")
                                .imageData(m.getImageData())
                                .timestamp(m.getTimestamp() != null ? m.getTimestamp() : LocalDateTime.now())
                                .build())
                        .collect(Collectors.toList()));
    }

    @PostMapping("/sessions/{id}/messages")
    public ResponseEntity<Dtos.SuccessResponse> addMessage(
            @AuthenticationPrincipal Jwt jwt,
            @PathVariable String id,
            @RequestBody Dtos.MessageRequest request) {

        String userId = resolveUserId(jwt);
        ChatSession session = sessionRepo.findByIdAndUserId(id, userId)
                .orElseThrow(() -> new RuntimeException("Session not found"));

        messageRepo.save(ChatMessage.builder()
                .session(session)
                .role(request.getRole())
                .content(request.getContent())
                .imageData(request.getImageData())
                .build());
        return ResponseEntity.ok(Dtos.SuccessResponse.builder().success(true).build());
    }

    // ─── Streaming Chat  ──────────────────────────────────────
    //
    // SSE events emitted:
    //   data: {"type":"meta","sessionId":"...","title":"...","provider":"openai"}
    //   data: {"type":"token","content":"..."}   ← one per streamed word/chunk
    //   data: {"type":"title","title":"..."}     ← sent async when smart title is ready
    //   data: {"type":"done"}                    ← stream finished
    //
    // KEY DESIGN: title generation is NON-BLOCKING — the stream starts immediately
    // with "New Chat". When the AI title is ready (on a background thread), a
    // separate "title" SSE event is sent so Flutter can update the session list.

    // Main streaming endpoint consumed by Flutter chat screen.
    @PostMapping(value = "/chat", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public ResponseEntity<Flux<String>> chat(
            @AuthenticationPrincipal Jwt jwt,
            @RequestBody Dtos.AiChatRequest request) {

        // Anti-buffering headers — tokens reach the client the instant they're produced
        HttpHeaders headers = new HttpHeaders();
        headers.set("X-Accel-Buffering", "no");
        headers.set("Cache-Control", "no-cache");
        headers.set("Connection", "keep-alive");

        String userId = resolveUserId(jwt);
        String msg    = request.getMessage() != null ? request.getMessage().trim() : "";
        List<String> imageDataList = collectImageData(request);
        List<String> imageMimeTypeList = collectImageMimeTypes(request, imageDataList.size());
        boolean hasImage = !imageDataList.isEmpty();

        if (msg.isEmpty() && !hasImage) {
            return ResponseEntity.ok().headers(headers).body(Flux.just(
                jsonToken("Please type a message or attach an image."),
                jsonDone()
            ));
        }

        // ── 1. Resolve or create session instantly (no AI call yet) ──
        String requestedId = request.getSessionId() != null ? request.getSessionId().trim() : "";
        Optional<ChatSession> existing = requestedId.isEmpty()
                ? Optional.empty()
                : sessionRepo.findByIdAndUserId(requestedId, userId);

        final boolean isNewSession = existing.isEmpty();
        final ChatSession session;

        if (existing.isPresent()) {
            session = existing.get();
        } else {
            // Create immediately with "New Chat" — title updated async below
            session = sessionRepo.save(ChatSession.builder()
                    .id(UUID.randomUUID().toString())
                    .title("New Chat")
                    .userId(userId)
                    .build());
        }

        // ── 2. Build effective memory from persisted session history ──
        List<Dtos.HistoryMessage> effectiveHistory = buildEffectiveHistory(session.getId(), request.getHistory());

        int estimatedRequestTokens = estimatePromptTokens(msg, effectiveHistory, imageDataList.size());
        int estimatedReplyTokens = isDetailedMode(request.getResponseMode()) ? 1800 : 900;
        int estimatedTotalTokens = estimatedRequestTokens + estimatedReplyTokens;

        TokenUsageService.UsageDecision usageDecision = tokenUsageService.checkLimit(userId, estimatedTotalTokens);
        if (!usageDecision.isAllowed()) {
            String waitHint = formatRetryWait(usageDecision.getRetryAfterSeconds());
            String notice = "⚠️ Token limit reached for your current usage window. " +
                    "Remaining: " + usageDecision.getRemainingTokens() + ". " +
                    (waitHint.isEmpty() ? "Please try again later." : "Try again in about " + waitHint + ".");
            return ResponseEntity.ok().headers(headers).body(Flux.just(jsonToken(notice), jsonDone()));
        }

        // ── 3. Save user message ──────────────────────────────
        messageRepo.save(ChatMessage.builder()
                .session(session)
                .role("user")
                .content(msg)
                .imageData(serializeImageData(imageDataList))
                .build());

        // ── 4. Track which provider was chosen (filled from §PROVIDER signal) ──
        AtomicReference<String> chosenProvider = new AtomicReference<>("openai");
        StringBuilder fullReply = new StringBuilder();

        // ── 5. Build the full SSE stream ──────────────────────
        //    a) meta is emitted first  (provider filled in from first signal token)
        //    b) tokens stream live
        //    c) done saves reply + triggers title generation

        // We use a two-phase approach: buffer the first §PROVIDER token, emit meta,
        // then forward all real tokens.
        Flux<String> rawStream = openAiService.streamChat(
                msg,
                effectiveHistory,
                request.getImageData(),
                request.getImageMimeType(),
                imageDataList,
                imageMimeTypeList,
                request.getResponseMode());

        // Separate the synthetic provider signal from real content tokens
        AtomicReference<Boolean> metaSent = new AtomicReference<>(false);

        Flux<String> sseStream = rawStream.flatMap(token -> {
            if (token.startsWith("§PROVIDER:")) {
                // Extract provider, emit meta event
                chosenProvider.set(token.substring(10));
                metaSent.set(true);
                return Flux.just(jsonMeta(session.getId(), isNewSession ? "New Chat" : null,
                        chosenProvider.get()));
            }
            // Guard: ensure meta is sent even if signal was somehow skipped
            if (!metaSent.getAndSet(true)) {
                String meta = jsonMeta(session.getId(), isNewSession ? "New Chat" : null, "openai");
                fullReply.append(token);
                return Flux.just(meta, jsonTokenObj(token));
            }
            fullReply.append(token);
            return Flux.just(jsonTokenObj(token));
        });

        // Done signal: save reply, then async generate + emit smart title
        Flux<String> doneSignal = Flux.defer(() -> {
            String reply = fullReply.toString();
            int consumedTokens = estimatePromptTokens(msg, effectiveHistory, imageDataList.size()) + estimateOutputTokens(reply);
            tokenUsageService.recordUsage(userId, consumedTokens);

            if (!reply.isBlank()) {
                try {
                    messageRepo.save(ChatMessage.builder()
                            .session(session)
                            .role("assistant")
                            .content(reply)
                            .build());
                } catch (Exception e) {
                    log.error("Failed to save assistant message: {}", e.getMessage());
                }
            }

            if (isNewSession && !msg.isEmpty()) {
                // Generate and push title asynchronously — doesn't block the done event
                Flux<String> titleFlux = Mono.fromCallable(() -> openAiService.generateTitle(msg))
                        .subscribeOn(Schedulers.boundedElastic())
                        .doOnNext(title -> {
                            try {
                                sessionRepo.findById(session.getId()).ifPresent(s -> {
                                    s.setTitle(title);
                                    sessionRepo.save(s);
                                });
                            } catch (Exception e) {
                                log.warn("Could not save title: {}", e.getMessage());
                            }
                        })
                        .map(AiChatController::jsonTitleUpdate)
                        .flux()
                        .onErrorResume(e -> {
                            log.warn("Title generation failed: {}", e.getMessage());
                            return Flux.empty();
                        });

                return Flux.concat(
                        Flux.just(jsonDone()),
                        titleFlux
                );
            }
            return Flux.just(jsonDone());
        });

        Flux<String> body = Flux.concat(sseStream, doneSignal);
        return ResponseEntity.ok().headers(headers).body(body);
    }

    // ─── Images gallery ───────────────────────────────────────

    @GetMapping("/images")
    public ResponseEntity<List<Dtos.ImageMessageResponse>> getImages(
            @AuthenticationPrincipal Jwt jwt) {

        String userId = resolveUserId(jwt);
        return ResponseEntity.ok(
                messageRepo.findBySession_UserIdAndImageDataIsNotNullOrderByTimestampDesc(userId)
                        .stream()
                        .filter(m -> m.getImageData() != null && !m.getImageData().trim().isEmpty())
                        .map(m -> Dtos.ImageMessageResponse.builder()
                                .id(m.getId())
                                .role(m.getRole())
                                .content(m.getContent() != null ? m.getContent() : "")
                                .imageData(m.getImageData())
                                .timestamp(m.getTimestamp() != null ? m.getTimestamp() : LocalDateTime.now())
                                .sessionId(m.getSession().getId())
                                .build())
                        .collect(Collectors.toList()));
    }

    @GetMapping("/usage")
    public ResponseEntity<Dtos.UsageResponse> getUsage(
            @AuthenticationPrincipal Jwt jwt) {
        String userId = resolveUserId(jwt);
        TokenUsageService.UsageStatus status = tokenUsageService.getUsageStatus(userId);
        return ResponseEntity.ok(Dtos.UsageResponse.builder()
                .usedTokens(status.getUsedTokens())
                .limitTokens(status.getLimitTokens())
                .remainingTokens(status.getRemainingTokens())
                .windowHours(status.getWindowHours())
                .usagePercent(status.getUsagePercent())
                .retryAfterSeconds(status.getRetryAfterSeconds())
                .unlimited(status.isUnlimited())
                .build());
    }

    // ─── SSE JSON helpers ─────────────────────────────────────

    private static String jsonMeta(String sessionId, String title, String provider) {
        StringBuilder sb = new StringBuilder("{\"type\":\"meta\"");
        sb.append(",\"sessionId\":").append(jsonStr(sessionId));
        sb.append(",\"provider\":").append(jsonStr(provider));
        if (title != null) sb.append(",\"title\":").append(jsonStr(title));
        sb.append("}");
        return sb.toString();
    }

    private static String jsonTitleUpdate(String title) {
        return "{\"type\":\"title\",\"title\":" + jsonStr(title) + "}";
    }

    private static String jsonTokenObj(String content) {
        return "{\"type\":\"token\",\"content\":" + jsonStr(content) + "}";
    }

    private static String jsonToken(String content) {
        return jsonTokenObj(content);
    }

    private static String jsonDone() {
        return "{\"type\":\"done\"}";
    }

    private static List<String> collectImageData(Dtos.AiChatRequest request) {
        if (request.getImageDataList() != null && !request.getImageDataList().isEmpty()) {
            return request.getImageDataList().stream()
                    .filter(s -> s != null && !s.trim().isEmpty())
                    .map(String::trim)
                    .collect(Collectors.toList());
        }
        if (request.getImageData() != null && !request.getImageData().trim().isEmpty()) {
            return List.of(request.getImageData().trim());
        }
        return List.of();
    }

    private static List<String> collectImageMimeTypes(Dtos.AiChatRequest request, int size) {
        if (size <= 0) return List.of();
        if (request.getImageMimeTypeList() != null && !request.getImageMimeTypeList().isEmpty()) {
            return request.getImageMimeTypeList();
        }
        if (request.getImageMimeType() != null && !request.getImageMimeType().isBlank()) {
            return java.util.Collections.nCopies(size, request.getImageMimeType());
        }
        return List.of();
    }

    private static String serializeImageData(List<String> imageDataList) {
        if (imageDataList == null || imageDataList.isEmpty()) return null;
        if (imageDataList.size() == 1) return imageDataList.get(0);
        try {
            return MAPPER.writeValueAsString(imageDataList);
        } catch (JsonProcessingException e) {
            return imageDataList.get(0);
        }
    }

    private static String jsonStr(String s) {
        if (s == null) return "null";
        return "\"" + s
                .replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t") + "\"";
    }

    private List<Dtos.HistoryMessage> buildEffectiveHistory(String sessionId, List<Dtos.HistoryMessage> requestHistory) {
        List<ChatMessage> persistedDesc = messageRepo.findTop200BySession_IdOrderByTimestampDesc(sessionId);
        if (persistedDesc == null || persistedDesc.isEmpty()) {
            return requestHistory == null ? List.of() : requestHistory;
        }

        Collections.reverse(persistedDesc);
        List<Dtos.HistoryMessage> merged = new ArrayList<>(persistedDesc.size());
        for (ChatMessage m : persistedDesc) {
            if (m == null) continue;
            String role = m.getRole() == null || m.getRole().isBlank() ? "user" : m.getRole().trim();
            String content = m.getContent() == null ? "" : m.getContent().trim();
            if (m.getImageData() != null && !m.getImageData().isBlank()) {
                int imageCount = countImagesInSerializedData(m.getImageData());
                String marker = imageCount > 1
                        ? ("[Image attachments included in this message: " + imageCount + "]")
                        : IMAGE_MARKER;
                content = content.isEmpty() ? marker : (content + "\n" + marker);
            }
            if (content.isEmpty()) continue;
            merged.add(new Dtos.HistoryMessage(role, content));
        }
        return merged;
    }

    private int countImagesInSerializedData(String serialized) {
        if (serialized == null || serialized.isBlank()) return 0;
        String trimmed = serialized.trim();
        if (!trimmed.startsWith("[")) return 1;
        try {
            List<?> parsed = MAPPER.readValue(trimmed, List.class);
            return parsed == null ? 0 : Math.max(1, parsed.size());
        } catch (Exception ignored) {
            return 1;
        }
    }

    private static boolean isDetailedMode(String responseMode) {
        return responseMode != null && "detailed".equalsIgnoreCase(responseMode.trim());
    }

    private static int estimatePromptTokens(String message, List<Dtos.HistoryMessage> history, int imageCount) {
        int chars = message == null ? 0 : message.length();
        if (history != null) {
            for (Dtos.HistoryMessage h : history) {
                if (h != null && h.getContent() != null) chars += h.getContent().length();
            }
        }
        int textTokens = Math.max(1, chars / 4);
        int imageTokens = Math.max(0, imageCount) * 800;
        return textTokens + imageTokens;
    }

    private static int estimateOutputTokens(String content) {
        int chars = content == null ? 0 : content.length();
        return Math.max(1, chars / 4);
    }

    private static String formatRetryWait(long retryAfterSeconds) {
        if (retryAfterSeconds <= 0) return "";
        long mins = retryAfterSeconds / 60;
        long hrs = mins / 60;
        long remMins = mins % 60;
        if (hrs <= 0) return Math.max(1, mins) + " min";
        if (remMins == 0) return hrs + " hr";
        return hrs + " hr " + remMins + " min";
    }
}
