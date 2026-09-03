package com.luat.ota.entity;

import jakarta.persistence.*;
import java.time.Instant;

@Entity
@Table(name = "ota_projects")
public class OtaProject {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 128)
    private String name;

    @Column(nullable = false, unique = true, length = 64)
    private String projectKey;

    @Column(length = 512)
    private String description;

    @Column(nullable = false)
    private Boolean hidden = false;

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
    public String getName() { return name; }
    public void setName(String name) { this.name = name; }
    public String getProjectKey() { return projectKey; }
    public void setProjectKey(String projectKey) { this.projectKey = projectKey; }
    public String getDescription() { return description; }
    public void setDescription(String description) { this.description = description; }
    public Boolean getHidden() { return hidden; }
    public void setHidden(Boolean hidden) { this.hidden = hidden; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
}
