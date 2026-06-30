-- v2: 合宙 IoT 风格项目 + 固件管理（在 schema.sql 之后执行或合并全新安装）

CREATE TABLE IF NOT EXISTS ota_projects (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    name            VARCHAR(128) NOT NULL,
    project_key     VARCHAR(64)  NOT NULL,
    description     VARCHAR(512) NULL,
    hidden          TINYINT(1)   NOT NULL DEFAULT 0,
    created_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    UNIQUE KEY uk_projects_key (project_key)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS firmware_packages (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    project_id      BIGINT       NULL,
    firmware_name   VARCHAR(128) NOT NULL,
    version         VARCHAR(32)  NOT NULL,
    source_version  VARCHAR(32)  NULL COMMENT 'dfota 源版本，空表示不限/legacy',
    core_version    VARCHAR(16)  NOT NULL DEFAULT '0',
    file_name       VARCHAR(255) NOT NULL,
    allow_upgrade   TINYINT(1)   NOT NULL DEFAULT 1,
    upgrade_all     TINYINT(1)   NOT NULL DEFAULT 0,
    remark          VARCHAR(512) NULL,
    enabled         TINYINT(1)   NOT NULL DEFAULT 1,
    created_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    KEY idx_fw_name (firmware_name),
    KEY idx_fw_version (version),
    KEY idx_fw_source (source_version),
    CONSTRAINT fk_fw_project FOREIGN KEY (project_id) REFERENCES ota_projects(id) ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS firmware_device_assignments (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    firmware_id     BIGINT       NOT NULL,
    imei            VARCHAR(20)  NOT NULL,
    created_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    UNIQUE KEY uk_fw_imei (firmware_id, imei),
    KEY idx_assign_imei (imei),
    CONSTRAINT fk_assign_firmware FOREIGN KEY (firmware_id) REFERENCES firmware_packages(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- 默认项目（780EHM_PJ main.lua PRODUCT_KEY）
INSERT IGNORE INTO ota_projects (id, name, project_key, description)
VALUES (1, '合宙标准模块', 'ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x', '780EHM_PJ PANSHI_CAT1');
