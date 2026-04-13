package com.auric.controller;

import com.auric.dto.Dtos;
import com.auric.model.CalcHistory;
import com.auric.repository.CalcHistoryRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;

@RestController
@RequestMapping("/api/calc")
@RequiredArgsConstructor
/**
 * Calculator history endpoints.
 *
 * Calculation itself is done in Flutter; this controller handles persistence,
 * filtering, and cleanup of user-specific history rows.
 */
public class CalcController {

    private final CalcHistoryRepository historyRepo;

    /** Resolve userId from JWT (protected endpoints require authentication). */
    private String resolveUserId(Jwt jwt) {
        String userId = jwt != null && jwt.getSubject() != null ? jwt.getSubject().trim() : "";
        if (userId.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Missing authenticated user");
        }
        return userId;
    }

    // Returns authenticated user's history (optionally filtered by date).
    @GetMapping("/history")
    public ResponseEntity<List<Dtos.CalcHistoryResponse>> getHistory(
            @AuthenticationPrincipal Jwt jwt,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate date) {

        String userId = resolveUserId(jwt);
        List<CalcHistory> items = date != null
                ? historyRepo.findByUserIdAndDate(userId,
                        date.atStartOfDay(),
                        date.plusDays(1).atStartOfDay())
                : historyRepo.findByUserIdOrderByTimestampDesc(userId);

        return ResponseEntity.ok(items.stream()
                .map(h -> Dtos.CalcHistoryResponse.builder()
                        .id(h.getId())
                        .equation(h.getEquation())
                        .result(h.getResult())
                        .timestamp(h.getTimestamp())
                        .build())
                .collect(Collectors.toList()));
    }

    // Saves one calculator result, with consecutive deduplication protection.
    @PostMapping("/history")
    public ResponseEntity<Map<String, Object>> addHistory(
            @AuthenticationPrincipal Jwt jwt,
            @RequestBody Dtos.CalcHistoryRequest request) {

        String userId = resolveUserId(jwt);
        String equation = request.getEquation() != null ? request.getEquation().trim() : "";
        String result = request.getResult() != null ? request.getResult().trim() : "";
        if (equation.isEmpty() || result.isEmpty()) {
            return ResponseEntity.badRequest().body(Map.of("error", "equation/result required"));
        }

        // Deduplicate only consecutive duplicates (auto-save + '=' of same calculation).
        // If another calculation happened in between, allow saving again.
        Optional<CalcHistory> latest = historyRepo.findTopByUserIdOrderByTimestampDesc(userId);
        if (latest.isPresent()) {
            String latestEq = latest.get().getEquation() != null ? latest.get().getEquation().trim() : "";
            String latestRes = latest.get().getResult() != null ? latest.get().getResult().trim() : "";
            if (latestEq.equals(equation) && latestRes.equals(result)) {
                return ResponseEntity.ok(Map.of("id", latest.get().getId(), "deduped", true));
            }
        }

        CalcHistory saved = historyRepo.save(CalcHistory.builder()
                .equation(equation)
                .result(result)
                .userId(userId)
                .build());

        return ResponseEntity.ok(Map.of("id", saved.getId()));
    }

    // Deletes a history row only if it belongs to current user.
    @DeleteMapping("/history/{id}")
    public ResponseEntity<Dtos.SuccessResponse> deleteHistory(
            @AuthenticationPrincipal Jwt jwt,
            @PathVariable Long id) {

        String userId = resolveUserId(jwt);
        historyRepo.findById(id).ifPresent(item -> {
            if (userId.equals(item.getUserId())) {
                historyRepo.deleteById(id);
            }
        });
        return ResponseEntity.ok(Dtos.SuccessResponse.builder()
                .success(true).message("Deleted").build());
    }

    /**
     * One-time cleanup utility: remove duplicate calculator history rows
     * for the authenticated user, keeping only the newest occurrence of each
     * (equation, result) pair.
     */
    @PostMapping("/history/deduplicate")
    @Transactional
    public ResponseEntity<Map<String, Object>> deduplicateHistory(
            @AuthenticationPrincipal Jwt jwt) {

        String userId = resolveUserId(jwt);
        List<CalcHistory> rows = historyRepo.findByUserIdOrderByTimestampDesc(userId);

        Set<String> seen = new HashSet<>();
        List<Long> duplicateIds = new ArrayList<>();

        for (CalcHistory row : rows) {
            String eq = row.getEquation() != null ? row.getEquation().trim() : "";
            String res = row.getResult() != null ? row.getResult().trim() : "";
            String key = eq + "==" + res;

            if (seen.contains(key)) {
                if (row.getId() != null) duplicateIds.add(row.getId());
            } else {
                seen.add(key);
            }
        }

        if (!duplicateIds.isEmpty()) {
            historyRepo.deleteAllByIdInBatch(duplicateIds);
        }

        return ResponseEntity.ok(Map.of(
                "removed", duplicateIds.size(),
                "remaining", seen.size()
        ));
    }
}
