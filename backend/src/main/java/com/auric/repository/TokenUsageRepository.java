package com.auric.repository;

import com.auric.model.TokenUsage;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.Optional;

@Repository
public interface TokenUsageRepository extends JpaRepository<TokenUsage, Long> {

    @Query("select coalesce(sum(t.tokens), 0) from TokenUsage t where t.userId = :userId and t.createdAt >= :since")
    long sumTokensSince(@Param("userId") String userId, @Param("since") LocalDateTime since);

    Optional<TokenUsage> findFirstByUserIdAndCreatedAtAfterOrderByCreatedAtAsc(String userId, LocalDateTime since);
}
