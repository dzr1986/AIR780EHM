-- ================================================================
-- Filename : config/events.lua
-- Module   : APP_EVENTS 事件名常量
-- Arch     : 拆分自 config.lua。
-- ================================================================

-- ===== APP_EVENTS 事件名常量：GPIO / USB / BATTERY / POWER / t31x / MQTT / DEVICE =====
_G.APP_EVENTS = {
    PIR_HW_TRIGGERED = "pir_hw_triggered",
    GPIO_PIR_TRIGGERED = "gpio_pir_triggered",
    GPIO_VBUS_CHANGED = "gpio_vbus_changed",
    GPIO_USB_DET_CHANGED = "gpio_usb_det_changed",
    GPIO_CHG_STATE_CHANGED = "gpio_chg_state_changed",
    GPIO_PWRKEY_SHORT = "gpio_pwrkey_short",
    GPIO_PWRKEY_LONG = "gpio_pwrkey_long",
    GPIO_BOOTKEY_SHORT = "gpio_bootkey_short",
    GPIO_BOOTKEY_LONG = "gpio_bootkey_long",
    GPIO_COPROC_READY = "gpio_coproc_ready",
    POWER_ENTER_REST = "power_enter_rest",
    POWER_EXIT_REST = "power_exit_rest",
    POWER_ENTERED_REST = "power_entered_rest",
    POWER_EXITED_REST = "power_exited_rest",
    MQTT_SERVER_DATA = "mqtt_server_data",
    MQTT_PUBLISH_WAKEUP = "mqtt_publish_wakeup",
    MQTT_PUBLISH_REST = "mqtt_publish_rest",
    MQTT_OFFLINE = "mqtt_offline",
    MQTT_CONNECTED = "mqtt_connected",
    MQTT_STATUS_INTERVAL_CHANGED = "mqtt_status_interval_changed",
    MQTT_USB_RECOVERY_CHANGED = "mqtt_usb_recovery_changed",
    DEVICE_OTA_REQUEST = "device_ota_request",
    MQTT_OTA_STATUS = "mqtt_ota_status",
    DEVICE_REBOOT_REQUEST = "device_reboot_request",
    DEVICE_POWER_OFF_REQUEST = "device_power_off_request",
    PIR_WAKE_t31x = "pir_wake_t31x",
    PIR_MEDIA_EFFECTIVE = "pir_media_effective",
    PIR_REQUEST_t31x_STOP = "pir_request_t31x_stop",
    t31x_SNAPSHOT_DONE = "t31x_snapshot_done",
    PIR_STOP_RECORDING = "pir_stop_recording",
    t31x_RECORD_ACTIVE = "t31x_record_active",
    t31x_RECORD_STOP = "t31x_record_stop",
    t31x_IPC_ALERT = "t31x_ipc_alert",
    t31x_PERSON_CNT = "t31x_person_cnt",
    PIR_TIMER_EXPIRED = "pir_timer_expired",
    BATTERY_UPDATE = "BATTERY_UPDATE",
    UART_RX_STRING = "uart_rx_string",
    HOST_UART_FIRST_AT = "host_uart_first_at",
    HOST_NET_ID_P2P = "host_net_id_p2p",
    HOST_NET_ID_GB28181 = "host_net_id_gb28181",
}
