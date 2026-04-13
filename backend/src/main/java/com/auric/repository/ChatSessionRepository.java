package com.auric.repository;

import com.auric.model.ChatSession;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

@Repository
/** Data access contract for chat session rows. */
public interface ChatSessionRepository extends JpaRepository<ChatSession, String> {

    List<ChatSession> findByUserIdOrderByCreatedAtDesc(String userId);

    @Query("SELECT s FROM ChatSession s WHERE s.userId = :userId AND LOWER(s.title) LIKE LOWER(CONCAT('%',:search,'%')) ORDER BY s.createdAt DESC")
    List<ChatSession> findByUserIdAndTitleContaining(@Param("userId") String userId, @Param("search") String search);

    List<ChatSession> findByUserIdAndCreatedAtBetweenOrderByCreatedAtDesc(
            String userId,
            LocalDateTime start,
            LocalDateTime end);

    Optional<ChatSession> findByIdAndUserId(String id, String userId);

    @Modifying
    @Query("UPDATE ChatSession s SET s.userId = :targetUserId WHERE s.userId = :sourceUserId")
    int migrateUserId(@Param("sourceUserId") String sourceUserId,
                      @Param("targetUserId") String targetUserId);

    @Modifying
    @Query("UPDATE ChatSession s SET s.userId = :targetUserId WHERE s.userId IS NULL OR TRIM(s.userId) = ''")
    int migrateBlankUserIds(@Param("targetUserId") String targetUserId);
}
