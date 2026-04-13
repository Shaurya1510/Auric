package com.auric.controller;

import com.auric.dto.Dtos;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.google.api.client.googleapis.auth.oauth2.GoogleIdToken;
import com.google.api.client.googleapis.auth.oauth2.GoogleIdTokenVerifier;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Arrays;
import java.util.Base64;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Instant;

@RestController
@RequestMapping("/api/auth")
@Slf4j
/**
 * Authentication endpoints.
 *
 * Validates Google ID tokens sent by Flutter and returns normalized profile data.
 */
public class AuthController {
    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();
    private static final HttpClient HTTP_CLIENT = HttpClient.newHttpClient();
    private static final Set<String> VALID_ISSUERS = Set.of("accounts.google.com", "https://accounts.google.com");

    @Value("${google.client.id}")
    private String googleClientId;

    @Value("${google.client.ids:${google.client.id}}")
    private String googleClientIds;

    /**
     * Verifies a Google ID token from the Flutter app and returns user info.
     * The Flutter app should store this info and pass the Google ID token
     * as a Bearer token in subsequent requests.
     *
     * NOTE: For full JWT auth, you would generate your own JWT here.
     * For simplicity, we accept Google's ID token directly as the Bearer token,
     * which Spring Security verifies via the Google JWK endpoint.
     */
    @PostMapping("/google")
    public ResponseEntity<?> googleSignIn(@RequestBody Dtos.GoogleTokenRequest request) {
        if (request == null || request.getIdToken() == null || request.getIdToken().isBlank()) {
            return ResponseEntity.badRequest().body(Map.of("error", "idToken is required"));
        }

        try {
            List<String> audiences = Arrays.stream(googleClientIds.split(","))
                    .map(String::trim)
                    .filter(id -> !id.isBlank())
                    .distinct()
                    .collect(Collectors.toList());

            if (audiences.isEmpty() && googleClientId != null && !googleClientId.isBlank()) {
                audiences = Collections.singletonList(googleClientId.trim());
            }

            if (audiences.isEmpty()) {
                log.error("Google sign-in rejected: no configured client IDs");
                return ResponseEntity.internalServerError()
                        .body(Map.of("error", "Google auth is not configured on backend"));
            }

            GoogleIdTokenVerifier verifier = new GoogleIdTokenVerifier.Builder(
                    new NetHttpTransport(), GsonFactory.getDefaultInstance())
                    .setAudience(audiences)
                    .build();

            String rawToken = request.getIdToken().trim();
            GoogleIdToken idToken = verifier.verify(rawToken);
            if (idToken == null) {
                Map<String, Object> tokenInfoPayload = verifyWithGoogleTokenInfo(rawToken, audiences);
                if (tokenInfoPayload != null) {
                    String userId = asString(tokenInfoPayload.get("sub"));
                    String email = asString(tokenInfoPayload.get("email"));
                    String name = asString(tokenInfoPayload.get("name"));
                    String picture = asString(tokenInfoPayload.get("picture"));

                    log.info("Google sign-in success (tokeninfo fallback): sub={}, aud={}",
                            maskUserId(userId), tokenInfoPayload.get("aud"));

                    return ResponseEntity.ok(Dtos.AuthResponse.builder()
                            .userId(userId)
                            .email(email)
                            .name(name)
                            .picture(picture)
                            .accessToken(rawToken)
                            .build());
                }

                Map<String, Object> unverifiedPayload = decodeUnverifiedJwtPayload(rawToken);
                log.warn("Google sign-in rejected: token verification failed for configured audiences {}, token aud={}, azp={}, iss={}, exp={}",
                        audiences,
                        unverifiedPayload.get("aud"),
                        unverifiedPayload.get("azp"),
                        unverifiedPayload.get("iss"),
                        unverifiedPayload.get("exp"));
                return ResponseEntity.badRequest().body(Map.of("error", "Invalid ID token"));
            }

            GoogleIdToken.Payload payload = idToken.getPayload();
            String userId = payload.getSubject();
            log.info("Google sign-in success: sub={}, aud={}",
                    maskUserId(userId), payload.getAudience());

            return ResponseEntity.ok(Dtos.AuthResponse.builder()
                    .userId(userId)
                    .email(payload.getEmail())
                    .name((String) payload.get("name"))
                    .picture((String) payload.get("picture"))
                    .accessToken(rawToken) // Use Google's token directly
                    .build());

        } catch (Exception e) {
            log.error("Google sign-in failed", e);
            return ResponseEntity.internalServerError()
                    .body(Map.of("error", "Authentication failed"));
        }
    }

    // Simple health endpoint for auth module checks.
    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of("status", "ok", "service", "auric-backend"));
    }

    private Map<String, Object> decodeUnverifiedJwtPayload(String jwt) {
        try {
            if (jwt == null || jwt.isBlank()) return Collections.emptyMap();
            String[] parts = jwt.split("\\.");
            if (parts.length < 2) return Collections.emptyMap();
            byte[] decoded = Base64.getUrlDecoder().decode(parts[1]);
            return OBJECT_MAPPER.readValue(decoded, Map.class);
        } catch (Exception ignored) {
            return Collections.emptyMap();
        }
    }

    private Map<String, Object> verifyWithGoogleTokenInfo(String idToken, List<String> audiences) {
        try {
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create("https://oauth2.googleapis.com/tokeninfo?id_token=" + idToken))
                    .GET()
                    .build();

            HttpResponse<String> response = HTTP_CLIENT.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() != 200) {
                log.warn("Google tokeninfo fallback failed with status {}", response.statusCode());
                return null;
            }

            Map<String, Object> payload = OBJECT_MAPPER.readValue(response.body(), Map.class);
            String aud = asString(payload.get("aud"));
            String iss = asString(payload.get("iss"));
            String exp = asString(payload.get("exp"));

            if (aud == null || !audiences.contains(aud)) return null;
            if (iss == null || !VALID_ISSUERS.contains(iss)) return null;
            if (exp != null) {
                long expEpoch = Long.parseLong(exp);
                if (Instant.now().getEpochSecond() >= expEpoch) return null;
            }
            return payload;
        } catch (Exception e) {
            log.warn("Google tokeninfo fallback error: {}", e.getMessage());
            return null;
        }
    }

    private String asString(Object value) {
        if (value == null) return null;
        String s = value.toString().trim();
        return s.isEmpty() ? null : s;
    }

    private String maskUserId(String userId) {
        if (userId == null || userId.isBlank()) return "unknown";
        int keep = Math.min(6, userId.length());
        return userId.substring(0, keep) + "***";
    }
}
