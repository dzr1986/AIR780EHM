-- ================================================================
-- Filename : host.lua（config 片段，user/ 顶层；由 config.lua 编排 require）
-- Module   : 主机（T31x）侧服务配置：SOUND/TIME_SYNC/IDENTITY/TFCARD/RECORD/ENCODE/IPC/WAKE
-- Arch     : 拆分自 config.lua。HOST_IPC_CFG 依赖 config.features 的 LOW_POWER_CFG。
-- ================================================================

-- ===== 通用主机侧等待参数模板（各 *_CFG 块统一引用，改值只改此处） =====
local HOST_BOOT_WAIT_MS = 1500   -- T31x host 就绪等待上限
local T31X_POWER_WAIT_MS = 800   -- T31x 上电后供电稳定等待

-- ===== 跨族协议超时单源（架构 F 条）：host_uart 族与 net_mqtt 族共用的 T31x 协议等待时长 =====
-- 同一协议语义只在此定义一次；host_uart.TMO_SHARED / net_mqtt.TMO_SHARED / hif_ipc_hostq / mqtt_dl_pir 均引用此表。
_G.HOST_PROTO_TMO = {
    ipcstat_query_ms = 2500,   -- AT+IPCSTAT? 单次超时 = MQTT 侧 refCloudStat 刷新等待（1003 前 / PIR 云状态）
    record_stop_ms = 22000,    -- AT+RECORD=0 停录等待（hostq recOff = dl_pir 2011 stopDefault；T31x 收尾写盘 + 封装）
    qry_default_ms = 3000,     -- 通用 AT 查询默认（cloud gb28181 / power busyClear / hostq rec / dl_pir recordIdleCheck；与 TMO_SHARED.qryDefaultMs 同值）
    record_query_ms = 3500,    -- AT+RECORD? / 录像对账（cloud reconcile / dl_pir recordQuery）
    t31x_power_wait_ms = T31X_POWER_WAIT_MS, -- ensT31xHost 上电稳定（各 *_CFG.t31x_power_wait_ms 缺省）
}

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
    t31x_power_wait_ms = T31X_POWER_WAIT_MS,
}

-- ===== 时间同步：SNTP→AT+TIMESET、唤醒前对时、host_boot_wait =====
_G.TIME_SYNC_CFG = {
    enabled = true,
    min_valid_unix = 1704067200,   -- 须与 lib/utils.lua MIN_VALID_UNIX 同值（config 片段禁 require lib，见 audit §14）
    sync_on_sntp = true,
    sync_before_wake = true,
    hostBootWaitMs = HOST_BOOT_WAIT_MS,
    t31x_power_wait_ms = T31X_POWER_WAIT_MS,
    ack_timeout_ms = 800,
    resync_skew_sec = 2,
}

-- ===== 设备标识：IMEI + GB28181（MQTT 2006→1006） =====
_G.HOST_IDENTITY_CFG = {
    enabled = true,
    auto_publish_on_ready = true,
    auto_publish_delay_ms = 500,
    query_timeout_ms = 3000,
    hostBootWaitMs = HOST_BOOT_WAIT_MS,
    t31x_power_wait_ms = T31X_POWER_WAIT_MS,
    publish_on_ipcinfo_query = false,
}

-- ===== TF 卡状态：AT+TFCARD? 查询、超时、缓存 =====
_G.HOST_TFCARD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    hostBootWaitMs = HOST_BOOT_WAIT_MS,
    t31x_power_wait_ms = T31X_POWER_WAIT_MS,
}

-- ===== TF 格式化：2009→AT+TFFORMAT 超时等待 =====
_G.HOST_TFCARD_FORMAT_CFG = {
    enabled = true,
    format_timeout_ms = 120000,
    record_stop_timeout_ms = 22000,
    pre_format_wait_ms = 500,
    reboot_after = false,
    publish_status_after = true,
    hostBootWaitMs = HOST_BOOT_WAIT_MS,
    t31x_power_wait_ms = T31X_POWER_WAIT_MS,
}
_G.HOST_RECORD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    -- T31x record_stop 等泵线程 join 最长约 15s；8s 会误报 timeout
    record_stop_timeout_ms = 22000,
    hostBootWaitMs = HOST_BOOT_WAIT_MS,
    t31x_power_wait_ms = T31X_POWER_WAIT_MS,
}

-- ===== HOST_ENCODE：2020/2021 query/set 超时 / runtimeApply =====
_G.HOST_ENCODE_CFG = {
    query_timeout_ms = 8000,
    hostBootWaitMs = HOST_BOOT_WAIT_MS,
    t31x_power_wait_ms = T31X_POWER_WAIT_MS,
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
    t31x_power_wait_ms = T31X_POWER_WAIT_MS,
    hostBootWaitMs = HOST_BOOT_WAIT_MS,
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
