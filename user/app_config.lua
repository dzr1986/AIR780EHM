--- 应用编排：功能开关、事件名（非硬件引脚）
-- 在 config.lua 之后加载（main.lua）
-- @module app_config
-- @release 2026.5.20

module(..., package.seeall)
_G[_modname or (...)] = _M

_G.MODULE_FLAGS = {
    watchdog = true,
    uart_bridge = true,
    t3x_app = true,
    t3x_wakeup = true,
    t3x_policy = true,
    gpio = true,
    pmd_runtime = false,
    charge = true,
    mqtt = true,
    battery = true,
    battery_guard = true,
    sound_prompt = true,
    time_sync = true,
    sntp = true,
    mobile_info = false,  -- 门球默认关周期采集；MQTT 2005 由 net_mqtt 按需查 SIM
    cellular = true,
    fota = true,
    rndis = (_G.FEATURE_CFG and _G.FEATURE_CFG.rndis) == true,
    low_power = (_G.FEATURE_CFG and _G.FEATURE_CFG.low_power) ~= false,
    host_evt = (_G.FEATURE_CFG and _G.FEATURE_CFG.host_evt) ~= false,
}

_G.APP_EVENTS = {
    PIR_HW_TRIGGERED = "APP_PIR_HW_TRIGGERED",
    GPIO_PIR_TRIGGERED = "APP_GPIO_PIR_TRIGGERED",
    GPIO_VBUS_CHANGED = "APP_GPIO_VBUS_CHANGED",
    GPIO_USB_DET_CHANGED = "APP_GPIO_USB_DET_CHANGED",
    GPIO_CHG_STATE_CHANGED = "APP_GPIO_CHG_STATE_CHANGED",
    GPIO_PWRKEY_SHORT = "APP_GPIO_PWRKEY_SHORT",
    GPIO_PWRKEY_LONG = "APP_GPIO_PWRKEY_LONG",
    GPIO_BOOTKEY_SHORT = "APP_GPIO_BOOTKEY_SHORT",
    GPIO_BOOTKEY_LONG = "APP_GPIO_BOOTKEY_LONG",
    GPIO_COPROC_READY = "APP_GPIO_COPROC_READY",
    POWER_ENTER_REST = "APP_POWER_ENTER_REST",
    POWER_EXIT_REST = "APP_POWER_EXIT_REST",
    POWER_ENTERED_REST = "APP_POWER_ENTERED_REST",
    POWER_EXITED_REST = "APP_POWER_EXITED_REST",
    MQTT_SERVER_DATA = "APP_MQTT_SERVER_DATA",
    MQTT_PUBLISH_WAKEUP = "APP_MQTT_PUBLISH_WAKEUP",
    MQTT_PUBLISH_REST = "APP_MQTT_PUBLISH_REST",
    MQTT_OFFLINE = "APP_MQTT_OFFLINE",
    MQTT_CONNECTED = "APP_MQTT_CONNECTED",
    MQTT_STATUS_INTERVAL_CHANGED = "APP_MQTT_STATUS_INTERVAL_CHANGED",
    DEVICE_OTA_REQUEST = "APP_DEVICE_OTA_REQUEST",
    MQTT_OTA_STATUS = "APP_MQTT_OTA_STATUS",
    DEVICE_REBOOT_REQUEST = "APP_DEVICE_REBOOT_REQUEST",
    DEVICE_POWER_OFF_REQUEST = "APP_DEVICE_POWER_OFF_REQUEST",
    --- 一次 PIR 业务 → 一次 GPIO 唤醒 T3x（action=photo|video|both）
    PIR_WAKE_T3X = "APP_PIR_WAKE_T3X",
    PIR_REQUEST_T3X_STOP = "APP_PIR_REQUEST_T3X_STOP",
    T3X_SNAPSHOT_DONE = "APP_T3X_SNAPSHOT_DONE",
    PIR_TAKE_PHOTO = "APP_PIR_TAKE_PHOTO",   -- 已废弃，仅保留常量兼容
    PIR_RECORD_VIDEO = "APP_PIR_RECORD_VIDEO", -- 已废弃，仅保留常量兼容
    PIR_STOP_RECORDING = "APP_PIR_STOP_RECORDING",
    T3X_RECORD_ACTIVE = "APP_T3X_RECORD_ACTIVE",
    T3X_RECORD_STOP = "APP_T3X_RECORD_STOP",
    PIR_TIMER_EXPIRED = "APP_PIR_TIMER_EXPIRED",
    UART_RX_RAW = "APP_UART_RX_RAW",
    UART_RX_STRING = "APP_UART_RX_STRING",
    UART_RX_HEX = "APP_UART_RX_HEX",
    HOST_UART_FIRST_AT = "APP_HOST_UART_FIRST_AT",
}

return _M
