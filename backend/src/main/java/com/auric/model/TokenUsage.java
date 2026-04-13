package com.auric.model;

import jakarta.persistence.*;
import lombok.*;
import org.hibernate.annotations.CreationTimestamp;

import java.time.LocalDateTime;

@Entity
@Table(
        name = "token_usage",
        indexes = {
                @Index(name = "idx_token_usage_user_time", columnList = "user_id, created_at")
        }
)
@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class TokenUsage {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "user_id", nullable = false, length = 255)
    private String userId;

    @Column(nullable = false)
    private Integer tokens;

    @CreationTimestamp
    @Column(name = "created_at", updatable = false)
    private LocalDateTime createdAt;
}
