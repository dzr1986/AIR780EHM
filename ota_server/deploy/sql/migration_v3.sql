ALTER TABLE devices
    ADD COLUMN IF NOT EXISTS device_name VARCHAR(64) NULL AFTER imei,
    ADD COLUMN IF NOT EXISTS core_version VARCHAR(16) NULL DEFAULT '0' AFTER current_version,
    ADD COLUMN IF NOT EXISTS debug_enabled TINYINT(1) NOT NULL DEFAULT 0 AFTER ota_enabled;

UPDATE devices SET device_name = imei WHERE device_name IS NULL OR device_name = '';
UPDATE devices SET core_version = '0' WHERE core_version IS NULL OR core_version = '';
