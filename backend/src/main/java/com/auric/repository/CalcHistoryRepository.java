package com.auric.repository;

import com.auric.model.CalcHistory;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

@Repository
/** Data access contract for calculator history records. */
public interface CalcHistoryRepository extends JpaRepository<CalcHistory, Long> {

    List<CalcHistory> findByUserIdOrderByTimestampDesc(String userId);

    Optional<CalcHistory> findTopByUserIdOrderByTimestampDesc(String userId);

    Optional<CalcHistory> findTopByUserIdAndEquationAndResultOrderByTimestampDesc(
            String userId,
            String equation,
            String result);

    /**
     * Fetch all calculations for a user on a specific calendar day.
     * Uses a BETWEEN range (midnight → end of day) so it works reliably
     * with any JPA/DB without relying on string-cast date formatting.
     */
    @Query("SELECT c FROM CalcHistory c " +
           "WHERE c.userId = :userId " +
           "AND c.timestamp >= :startOfDay " +
           "AND c.timestamp < :endOfDay " +
           "ORDER BY c.timestamp DESC")
    List<CalcHistory> findByUserIdAndDate(
            @Param("userId")     String userId,
            @Param("startOfDay") LocalDateTime startOfDay,
            @Param("endOfDay")   LocalDateTime endOfDay);

    @Modifying
    @Query("UPDATE CalcHistory c SET c.userId = :targetUserId WHERE c.userId = :sourceUserId")
    int migrateUserId(@Param("sourceUserId") String sourceUserId,
                      @Param("targetUserId") String targetUserId);

    @Modifying
    @Query("UPDATE CalcHistory c SET c.userId = :targetUserId WHERE c.userId IS NULL OR TRIM(c.userId) = ''")
    int migrateBlankUserIds(@Param("targetUserId") String targetUserId);
}
