package com.luat.ota.entity;

import jakarta.persistence.*;
import java.time.Instant;

@Entity
@Table(name = "firmware_device_assignments")
public class FirmwareDeviceAssignment {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "firmware_id", nullable = false)
    private Long firmwareId;

    @Column(nullable = false, length = 20)
    private String imei;

    @Column(nullable = false, updatable = false)
    private Instant createdAt;

    @PrePersist
    void prePersist() {
        createdAt = Instant.now();
    }

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }
    public Long getFirmwareId() { return firmwareId; }
    public void setFirmwareId(Long firmwareId) { this.firmwareId = firmwareId; }
    public String getImei() { return imei; }
    public void setImei(String imei) { this.imei = imei; }
    public Instant getCreatedAt() { return createdAt; }
}
