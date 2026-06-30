package com.luat.ota.entity;

import jakarta.persistence.*;
import java.time.Instant;

/** 合宙 IoT 风格固件条目（对应 iot.openluat.com「我的固件」） */
@Entity
@Table(name = "firmware_packages")
public class FirmwarePackage {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "project_id")
    private Long projectId;

    @Column(nullable = false, length = 128)
    private String firmwareName;

    /** 目标版本（合宙 IoT 版本号 xxx.xxx.xxx） */
    @Column(nullable = false, length = 32)
    private String version;

    /** dfota 源版本；null 表示 legacy 不限源版本 */
    @Column(length = 32)
    private String sourceVersion;

    @Column(nullable = false, length = 16)
    private String coreVersion = "0";

    @Column(nullable = false, length = 255)
    private String fileName;

    @Column(nullable = false)
    private Boolean allowUpgrade = true;

    /** false = 仅指定 IMEI 可升级（合宙「指定设备」） */
    @Column(nullable = false)
    private Boolean upgradeAll = false;

    @Column(length = 512)
    private String remark;

    @Column(nullable = false)
    private Boolean enabled = true;

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
    public Long getProjectId() { return projectId; }
    public void setProjectId(Long projectId) { this.projectId = projectId; }
    public String getFirmwareName() { return firmwareName; }
    public void setFirmwareName(String firmwareName) { this.firmwareName = firmwareName; }
    public String getVersion() { return version; }
    public void setVersion(String version) { this.version = version; }
    public String getSourceVersion() { return sourceVersion; }
    public void setSourceVersion(String sourceVersion) { this.sourceVersion = sourceVersion; }
    public String getCoreVersion() { return coreVersion; }
    public void setCoreVersion(String coreVersion) { this.coreVersion = coreVersion; }
    public String getFileName() { return fileName; }
    public void setFileName(String fileName) { this.fileName = fileName; }
    public Boolean getAllowUpgrade() { return allowUpgrade; }
    public void setAllowUpgrade(Boolean allowUpgrade) { this.allowUpgrade = allowUpgrade; }
    public Boolean getUpgradeAll() { return upgradeAll; }
    public void setUpgradeAll(Boolean upgradeAll) { this.upgradeAll = upgradeAll; }
    public String getRemark() { return remark; }
    public void setRemark(String remark) { this.remark = remark; }
    public Boolean getEnabled() { return enabled; }
    public void setEnabled(Boolean enabled) { this.enabled = enabled; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
}
