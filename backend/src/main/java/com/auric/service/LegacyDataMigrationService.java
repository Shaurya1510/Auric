package com.auric.service;

import com.auric.repository.CalcHistoryRepository;
import com.auric.repository.ChatSessionRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

@Service
@RequiredArgsConstructor
@Slf4j
/**
 * Migrates pre-auth legacy rows (blank user id) to the current authenticated user.
 *
 * Triggered opportunistically and guarded so each user migrates only once per run.
 */
public class LegacyDataMigrationService {

    private final ChatSessionRepository chatSessionRepository;
    private final CalcHistoryRepository calcHistoryRepository;

    // Avoid repeating migration work on every request.
    private final Set<String> migratedUsers = ConcurrentHashMap.newKeySet();

    @Transactional
    public void migrateLegacyDataIfNeeded(String userId) {
        if (userId == null || userId.isBlank()) {
            return;
        }

        if (!migratedUsers.add(userId)) {
            return;
        }

        int movedSessions = 0;
        int movedCalcRows = 0;

        movedSessions += chatSessionRepository.migrateBlankUserIds(userId);

        movedCalcRows += calcHistoryRepository.migrateBlankUserIds(userId);

        if (movedSessions > 0 || movedCalcRows > 0) {
            log.info("Migrated legacy data for user {}: sessions={}, calc_rows={}",
                    userId, movedSessions, movedCalcRows);
        }
    }
}
