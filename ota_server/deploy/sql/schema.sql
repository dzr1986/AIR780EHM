CREATE DATABASE IF NOT EXISTS luat_ota DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE luat_ota;

CREATE TABLE IF NOT EXISTS devices (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    imei            VARCHAR(20)  NOT NULL,
    firmware_name   VARCHAR(128) NULL,
    current_version VARCHAR(32)  NULL,
    target_version  VARCHAR(32)  NULL,
    project_key     VARCHAR(64)  NULL,
    ota_enabled     TINYINT(1)   NOT NULL DEFAULT 1,
    ota_status      VARCHAR(32)  NOT NULL DEFAULT 'IDLE',
    remark          VARCHAR(255) NULL,
    last_seen_at    DATETIME(3)  NULL,
    last_ota_check_at DATETIME(3) NULL,
    last_ota_success_at DATETIME(3) NULL,
    created_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    UNIQUE KEY uk_devices_imei (imei),
    KEY idx_devices_target (target_version),
    KEY idx_devices_current (current_version)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS ota_tasks (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    imei            VARCHAR(20)  NOT NULL,
    message_id      VARCHAR(64)  NOT NULL,
    target_version  VARCHAR(32)  NOT NULL,
    ota_url         VARCHAR(512) NOT NULL,
    status          VARCHAR(32)  NOT NULL DEFAULT 'PENDING',
    trigger_source  VARCHAR(32)  NOT NULL DEFAULT 'ADMIN',
    last_stage      VARCHAR(64)  NULL,
    last_ret        INT          NULL,
    last_message    VARCHAR(255) NULL,
    error_message   VARCHAR(512) NULL,
    created_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    completed_at    DATETIME(3)  NULL,
    UNIQUE KEY uk_ota_tasks_message (message_id),
    KEY idx_ota_tasks_imei (imei),
    KEY idx_ota_tasks_status (status)
) ENGINE=InnoDB;

-- v2: 合宙 IoT 风格项目 + 固件（JPA ddl-auto=update 也会建表，此处供 Docker 初始化）
CREATE TABLE IF NOT EXISTS ota_projects (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(128) NOT NULL,
    project_key VARCHAR(64) NOT NULL,
    description VARCHAR(512) NULL,
    hidden TINYINT(1) NOT NULL DEFAULT 0,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    UNIQUE KEY uk_projects_key (project_key)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS firmware_packages (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    project_id BIGINT NULL,
    firmware_name VARCHAR(128) NOT NULL,
    version VARCHAR(32) NOT NULL,
    source_version VARCHAR(32) NULL,
    core_version VARCHAR(16) NOT NULL DEFAULT '0',
    file_name VARCHAR(255) NOT NULL,
    allow_upgrade TINYINT(1) NOT NULL DEFAULT 1,
    upgrade_all TINYINT(1) NOT NULL DEFAULT 0,
    remark VARCHAR(512) NULL,
    enabled TINYINT(1) NOT NULL DEFAULT 1,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    KEY idx_fw_name (firmware_name)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS firmware_device_assignments (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    firmware_id BIGINT NOT NULL,
    imei VARCHAR(20) NOT NULL,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    UNIQUE KEY uk_fw_imei (firmware_id, imei)
) ENGINE=InnoDB;

INSERT IGNORE INTO ota_projects (id, name, project_key, description)
VALUES (1, '合宙标准模块', 'ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x', '780EHM_PJ PANSHI_CAT1');
