-- ================================================================
-- Filename : config/host.lua
-- Module   : 主机（T31x）侧服务配置：SOUND/TIME_SYNC/IDENTITY/TFCARD/RECORD/ENCODE/IPC/WAKE
-- Arch     : 拆分自 config.lua。HOST_IPC_CFG 依赖 config.features 的 LOW_POWER_CFG。
-- ================================================================

-- ===== SOUND 提示音：冷启动/关机播放、超时、等待首条 AT =====
_G.SOUND_CFG = {
    enabled = true,
    boot_on_cold_start = true,
    boot_on_wake = false,
    shutdown_on_user_off = true,
    shutdown_on_low_power = false,
    shutdown_on_battery_off = false,
    boot_wait_host_ms = 120000,
    play_timeout_ms = 2500,
    t31x_power_wait_ms = 800,
}

-- ===== 时间同步：SNTP→AT+TIMESET、唤醒前对时、host_boot_wait =====
_G.TIME_SYNC_CFG = {
    enabled = true,
    min_valid_unix = 1704067200,
    sync_on_sntp = true,
    sync_before_wake = true,
    hostBootWaitMs = 1500,
    t31x_power_wait_ms = 800,
    ack_timeout_ms = 800,
    resync_skew_sec = 2,
}

-- ===== 设备标识：IMEI + GB28181（MQTT 2006→1006） =====
_G.HOST_IDENTITY_CFG = {
    enabled = true,
    auto_publish_on_ready = true,
    auto_publish_delay_ms = 500,
    query_timeout_ms = 3000,
    hostBootWaitMs = 1500,
    t31x_power_wait_ms = 800,
    publish_on_ipcinfo_query = false,
}

-- ===== TF 卡状态：AT+TFCARD? 查询、超时、缓存 =====
_G.HOST_TFCARD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    hostBootWaitMs = 1500,
    t31x_power_wait_ms = 800,
}

-- ===== TF 格式化：2009→AT+TFFORMAT 超时等待 =====
_G.HOST_TFCARD_FORMAT_CFG = {
    enabled = true,
    format_timeout_ms = 120000,
    record_stop_timeout_ms = 22000,
    pre_format_wait_ms = 500,
    reboot_after = false,
    publish_status_after = true,
    hostBootWaitMs = 1500,
    t31x_power_wait_ms = 800,
}
_G.HOST_RECORD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    -- T31x record_stop 等泵线程 join 最长约 15s；8s 会误报 timeout
    record_stop_timeout_ms = 22000,
    hostBootWaitMs = 1500,
    t31x_power_wait_ms = 800,
}

-- ===== HOST_ENCODE：2020/2021 query/set 超时 / runtimeApply =====
_G.HOST_ENCODE_CFG = {
    query_timeout_ms = 8000,
    hostBootWaitMs = 1500,
    t31x_power_wait_ms = 800,
}

-- ===== t31x IPC 电源：graceful_poweroff / IPCSTATUS? 轮询 / uart_recovery 看门狗 =====
_G.HOST_IPC_CFG = {
    enabled = _G.LOW_POWER_CFG.enabled and _G.LOW_POWER_CFG.graceful_ipc,
    graceful_poweroff = _G.LOW_POWER_CFG.graceful_ipc,
    poweroff_play_sound = true,
    poweroff_timeout_ms = 90000,
    poweroff_settle_ms = 500,
    status_query_timeout_ms = 2000,
    status_cache_max_age_sec = 90,
    ready_wait_timeout_ms = 120000,
    ready_poll_ms = 1000,
    t31x_power_wait_ms = 800,
    hostBootWaitMs = 1500,
    boot_sound_wait_ready = true,
    uart_recovery = {
        enabled = true,
        miss_threshold = 5,
        max_attempts = 3,
        cooldown_sec = 30,
        power_off_ms = 500,
        power_on_wait_ms = 800,
    },
}
_G.HOST_WAKE_CFG = {
    pulse_ms = 120,
    idle_level = 1,
    pulse_level = 0,
    default_sid = 1,
}
