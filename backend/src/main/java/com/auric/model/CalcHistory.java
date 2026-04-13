package com.auric.model;

import jakarta.persistence.*;
import lombok.Data;
import lombok.NoArgsConstructor;
import lombok.AllArgsConstructor;
import lombok.Builder;
import org.hibernate.annotations.CreationTimestamp;

import java.time.LocalDateTime;

@Entity
@Table(name = "calc_history")
@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
/** JPA entity for persisted calculator history rows. */
public class CalcHistory {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false)
    private String equation;

    @Column(nullable = false)
    private String result;

    @Column(name = "user_id")
    private String userId;

    @CreationTimestamp
    @Column(name = "timestamp", updatable = false)
    private LocalDateTime timestamp;
}
