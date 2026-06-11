package com.luat.ota.entity;

import jakarta.persistence.*;
import java.time.Instant;

@Entity
@Table(name = "devices")
public class Device {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, unique = true, length = 20)
    private String imei;

    @Column(length = 128)
    private String firmwareName;

    @Column(length = 32)
    private String currentVersion;

    @Column(length = 32)
    private String targetVersion;

    @Column(length = 64)
    private String projectKey;

    @Column(nullable = false)
    private Boolean otaEnabled = true;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 32)
    private DeviceOtaStatus otaStatus = DeviceOtaStatus.IDLE;

    @Column(length = 255)
    private String remark;

    private Instant lastSeenAt;
    private Instant lastOtaCheckAt;
    private Instant lastOtaSuccessAt;

    @Column(nullable = false, updatable = false)
    private Instant createdAt;

    @Column(nullable = false)
    private Instant updatedAt;

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
    public String getFirmwareName() { return firmwareName; }
    public void setFirmwareName(String firmwareName) { this.firmwareName = firmwareName; }
    public String getCurrentVersion() { return currentVersion; }
    public void setCurrentVersion(String currentVersion) { this.currentVersion = currentVersion; }
    public String getTargetVersion() { return targetVersion; }
    public void setTargetVersion(String targetVersion) { this.targetVersion = targetVersion; }
    public String getProjectKey() { return projectKey; }
    public void setProjectKey(String projectKey) { this.projectKey = projectKey; }
    public Boolean getOtaEnabled() { return otaEnabled; }
    public void setOtaEnabled(Boolean otaEnabled) { this.otaEnabled = otaEnabled; }
    public DeviceOtaStatus getOtaStatus() { return otaStatus; }
    public void setOtaStatus(DeviceOtaStatus otaStatus) { this.otaStatus = otaStatus; }
    public String getRemark() { return remark; }
    public void setRemark(String remark) { this.remark = remark; }
    public Instant getLastSeenAt() { return lastSeenAt; }
    public void setLastSeenAt(Instant lastSeenAt) { this.lastSeenAt = lastSeenAt; }
    public Instant getLastOtaCheckAt() { return lastOtaCheckAt; }
    public void setLastOtaCheckAt(Instant lastOtaCheckAt) { this.lastOtaCheckAt = lastOtaCheckAt; }
    public Instant getLastOtaSuccessAt() { return lastOtaSuccessAt; }
    public void setLastOtaSuccessAt(Instant lastOtaSuccessAt) { this.lastOtaSuccessAt = lastOtaSuccessAt; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
}
