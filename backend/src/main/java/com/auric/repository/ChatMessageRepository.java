package com.auric.repository;

import com.auric.model.ChatMessage;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
/** Data access contract for chat message rows and image message lookups. */
public interface ChatMessageRepository extends JpaRepository<ChatMessage, Long> {
    List<ChatMessage> findBySession_IdOrderByTimestampAsc(String sessionId);
    List<ChatMessage> findTop200BySession_IdOrderByTimestampDesc(String sessionId);
    List<ChatMessage> findBySession_IdAndImageDataIsNotNullOrderByTimestampDesc(String sessionId);
    List<ChatMessage> findBySession_UserIdAndImageDataIsNotNullOrderByTimestampDesc(String userId);
}
