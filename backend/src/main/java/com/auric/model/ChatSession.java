package com.auric.model;

import jakarta.persistence.*;
import lombok.Data;
import lombok.NoArgsConstructor;
import lombok.AllArgsConstructor;
import lombok.Builder;
import org.hibernate.annotations.CreationTimestamp;

import java.time.LocalDateTime;
import java.util.List;

@Entity
@Table(
    name = "chat_sessions",
    indexes = {
        @Index(name = "idx_chat_sessions_user_created", columnList = "user_id, created_at")
    }
)
@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
/** Parent chat thread entity owned by one authenticated user. */
public class ChatSession {

    @Id
    private String id;

    @Column(nullable = false)
    private String title;

    @Column(name = "user_id")
    private String userId;

    @CreationTimestamp
    @Column(name = "created_at", updatable = false)
    private LocalDateTime createdAt;

    @OneToMany(mappedBy = "session", cascade = CascadeType.ALL, orphanRemoval = true)
    private List<ChatMessage> messages;
}
