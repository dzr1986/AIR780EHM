package com.luat.ota.entity;

import jakarta.persistence.*;
import java.time.Instant;

@Entity
@Table(name = "ota_tasks")
public class OtaTask {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 20)
    private String imei;

    @Column(nullable = false, unique = true, length = 64)
    private String messageId;

    @Column(nullable = false, length = 32)
    private String targetVersion;

    @Column(nullable = false, length = 512)
    private String otaUrl;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 32)
    private OtaTaskStatus status = OtaTaskStatus.PENDING;

    @Column(nullable = false, length = 32)
    private String triggerSource = "ADMIN";

    @Column(length = 64)
    private String lastStage;

    private Integer lastRet;

    @Column(length = 255)
    private String lastMessage;

    @Column(length = 512)
    private String errorMessage;

    @Column(nullable = false, updatable = false)
    private Instant createdAt;

    @Column(nullable = false)
    private Instant updatedAt;

    private Instant completedAt;

    @PrePersist
    void prePersist() {
        Instant now = Instant.now();
        createdAt = now;
        updatedAt = now;
    }

    @PreUpdate
    void preUpdate() {
        updatedAt = Instant.now();
    }

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }
    public String getImei() { return imei; }
    public void setImei(String imei) { this.imei = imei; }
    public String getMessageId() { return messageId; }
    public void setMessageId(String messageId) { this.messageId = messageId; }
    public String getTargetVersion() { return targetVersion; }
    public void setTargetVersion(String targetVersion) { this.targetVersion = targetVersion; }
    public String getOtaUrl() { return otaUrl; }
    public void setOtaUrl(String otaUrl) { this.otaUrl = otaUrl; }
    public OtaTaskStatus getStatus() { return status; }
    public void setStatus(OtaTaskStatus status) { this.status = status; }
    public String getTriggerSource() { return triggerSource; }
    public void setTriggerSource(String triggerSource) { this.triggerSource = triggerSource; }
    public String getLastStage() { return lastStage; }
    public void setLastStage(String lastStage) { this.lastStage = lastStage; }
    public Integer getLastRet() { return lastRet; }
    public void setLastRet(Integer lastRet) { this.lastRet = lastRet; }
    public String getLastMessage() { return lastMessage; }
    public void setLastMessage(String lastMessage) { this.lastMessage = lastMessage; }
    public String getErrorMessage() { return errorMessage; }
    public void setErrorMessage(String errorMessage) { this.errorMessage = errorMessage; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
    public Instant getCompletedAt() { return completedAt; }
    public void setCompletedAt(Instant completedAt) { this.completedAt = completedAt; }
}
