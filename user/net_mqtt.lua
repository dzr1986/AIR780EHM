--- MQTT 低功耗长连接（LOW_POWER_WAKEUP_CFG.mode="mqtt" 时为唤醒主通道）
-- 与 net_tcp.lua 二选一；策略见 lib/low_power_wakeup.lua
-- 协议：下行 200x ↔ 上行 100x，见 doc/MQTT_PROTOCOL.md
-- 分发：DOWNLINK_HANDLERS / DL2004_ACTIONS / HOST_UART_QUERY_SET_SPECS
--       见 doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- @module net_mqtt
-- @release 2026.5.19

require "sys"
require "config"
local pir_ctrl = require "pir_ctrl"
local ipc_sup = require "ipc_supervision"
local hostUartMod
local function getHostUart()
    if hostUartMod == nil then
        if _G.host_uart then
            hostUartMod = _G.host_uart
        else
            local ok, m = pcall(require, "host_uart")
            hostUartMod = ok and m or false
        end
    end
    return hostUartMod or nil
end
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local NC = "mqtt_not_connected"
local L = "net_mqtt"

-- 协议编号（200x 下行 ↔ 100x 上行）
local DT = {
    UL_WAKEUP = "1001",
    UL_REST = "1002",
    UL_STATUS = "1003",
    UL_CONTROL = "1004",
    UL_SIM = "1005",
    UL_DEVICE_ID = "1006",
    UL_TF_CARD = "1007",
    UL_TF_FORMAT = "1009",
    UL_PIR_DETECT = "1010",
    UL_PIR_STOP = "1011",
    UL_PIR_START = "1012",
    UL_ENCODE_SET = "1021",
    UL_ENCODE_QUERY = "1020",
    UL_RECORD_TIME_QUERY = "1022",
    UL_RECORD_TIME_SET = "1023",
    UL_FRAMERATE_QUERY = "1024",
    UL_FRAMERATE_SET = "1025",
    UL_PERSON_DETECT_QUERY = "1026",
    UL_PERSON_DETECT_SET = "1027",
    UL_MIC_QUERY = "1028",
    UL_MIC_SET = "1029",
    UL_SOFTPHOTO_QUERY = "1030",
    UL_SOFTPHOTO_SET = "1031",
    DL_WAKEUP = "2001",
    DL_REST = "2002",
    DL_STATUS = "2003",
    DL_CONTROL = "2004",
    DL_SIM = "2005",
    DL_DEVICE_ID = "2006",
    DL_TF_CARD = "2007",
    DL_TF_FORMAT = "2009",
    DL_PIR_CFG = "2010",
    DL_PIR_STOP = "2011",
    DL_PIR_START = "2012",   -- → UL 1012 event
    DL_ENCODE_SET = "2021",  -- → UL 1021 encode（AT+VENCSET/AUDIOSET）
    DL_ENCODE_QUERY = "2020", -- → UL 1020 encode（AT+VENC?/AUDIO?）
    DL_RECORD_TIME_QUERY = "2022", -- → UL 1022 recordTime（AT+RECORDTIME?）
    DL_RECORD_TIME_SET = "2023",   -- → UL 1023 recordTime（AT+RECORDTIME=）
    DL_FRAMERATE_QUERY = "2024", -- → UL 1024 framerate（AT+FRAMERATE?）
    DL_FRAMERATE_SET = "2025",   -- → UL 1025 framerate（AT+FRAMERATE=）
    DL_PERSON_DETECT_QUERY = "2026", -- → UL 1026 personDetect（AT+PERSONDET?）
    DL_PERSON_DETECT_SET = "2027",   -- → UL 1027 personDetect（AT+PERSONDET=）
    DL_MIC_QUERY = "2028",           -- → UL 1028 mic（AT+MIC?）
    DL_MIC_SET = "2029",             -- → UL 1029 mic（AT+MICSET=）
    DL_SOFTPHOTO_QUERY = "2030",     -- → UL 1030 softPhoto（AT+SOFTPHOTO?）
    DL_SOFTPHOTO_SET = "2031",       -- → UL 1031 softPhoto（AT+SOFTPHOTOSET=）
}

-- 模块状态
local started = false
local mqttClient = nil
local isConnected = false
local batteryStatusSubscribed = false
local lastBatteryStatusPublishSec = 0
local statusReportTimerStarted = false
local identityPublished = false
local identityAutoHooked = false

local callbacks = {
    onOffline = nil,
    onMessage = nil,
}

local state = {
    last_event = nil,
    reconnect_count = 0,
    last_publish_topic = nil,
}

--- 需 T3x 在线才能完成的下行（T3x 休眠时入队，hasPendingHostWork 阻塞休眠）
local pendingHostQueue = {}
local pendingHostDrainHooked = false
local HOST_DL_NEEDS_T3X = {
    [DT.DL_DEVICE_ID] = true,
    [DT.DL_TF_CARD] = true,
    [DT.DL_TF_FORMAT] = true,
    [DT.DL_RECORD_TIME_QUERY] = true,
    [DT.DL_RECORD_TIME_SET] = true,
    [DT.DL_FRAMERATE_QUERY] = true,
    [DT.DL_FRAMERATE_SET] = true,
    [DT.DL_PERSON_DETECT_QUERY] = true,
    [DT.DL_PERSON_DETECT_SET] = true,
    [DT.DL_MIC_QUERY] = true,
    [DT.DL_MIC_SET] = true,
    [DT.DL_SOFTPHOTO_QUERY] = true,
    [DT.DL_SOFTPHOTO_SET] = true,
}
local DOWNLINK_HANDLERS

-- ============================================================
-- MQTT工具函数
-- ============================================================

local function getDeviceId()
    local ok, did = pcall(require, "device_id")
    if ok and type(did) == "table" and did.getDeviceId then
        return did.getDeviceId()
    end
    return "unknown_device"
end

local function getPubTopic() return "/panshi/app/" .. getDeviceId() .. "/" end
local function getSubTopic() return "/panshi/device/" .. getDeviceId() .. "/" end

local function publishAppEvent(eventKey, ...)
    local name = APP_EVENTS and APP_EVENTS[eventKey]
    if name then
        sys.publish(name, ...)
    end
end

local function escJson(s)
    return tostring(s or ""):gsub('"', '\\"')
end

local function msgIdPart(messageId)
    if messageId and messageId ~= "" then
        return string.format(',"messageId":"%s"', escJson(tostring(messageId)))
    end
    return ""
end

local function mqttTimestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

--- @param fields string 以逗号开头的扩展字段，如 ',"powerStatus":1'
local function formatUplink(dataType, fields)
    fields = fields or ""
    return string.format(
        '{"deviceNo":"%s","dataType":"%s"%s,"time":"%s"}',
        getDeviceId(), dataType, fields, mqttTimestamp())
end

local function publishUplink(opts)
    opts = opts or {}
    if not isConnected then
        if opts.warn ~= false then
            log.warn(L, opts.no_conn or NC)
        end
        return false
    end
    local topic = getPubTopic() .. (opts.suffix or "event")
    local payload = opts.payload or formatUplink(opts.dataType, opts.fields)
    mqttClient:publish(topic, payload, opts.qos or 1)
    if opts.log then
        log.info(L, opts.log, topic, table.unpack(opts.log_args or {}))
    end
    if opts.app_event_fn then
        opts.app_event_fn(topic, payload)
    elseif opts.app_event then
        publishAppEvent(opts.app_event, topic, payload)
    end
    if opts.on_published then
        opts.on_published(topic, payload)
    end
    return true
end

-- ============================================================
-- 蜂窝入网
-- ============================================================

local netReadyPublished = false
local bootstrapStarted = false

local function getWledState()
    local hu = getHostUart()
    if hu and hu.getWled then
        return hu.getWled() == 1 and 1 or 0
    end
    if _G.APP_RUNTIME and _G.APP_RUNTIME.wled_on ~= nil then
        return _G.APP_RUNTIME.wled_on == 1 and 1 or 0
    end
    return 0
end

local function getCellular()
    local ok, mod = pcall(require, "cellular_bootstrap")
    if ok then
        return mod
    end
    return nil
end

function bootstrapNetwork()
    if bootstrapStarted then
        return false
    end
    bootstrapStarted = true
    sys.taskInit(function()
        local cellular = getCellular()
        local ipOk, ip

        if cellular and cellular.waitForNetwork and (_G.MODULE_FLAGS.cellular ~= false) then
            log.info(L, "cellular_ready")
            ipOk, ip = cellular.waitForNetwork()
        else
            log.info(L, "wait_ip")
            ipOk = sys.waitUntil("IP_READY", 300000)
            ip = (socket and socket.localIP and socket.localIP()) or nil
        end

        if ipOk and ip then
            log.info(L, "got_ip", ip)
        else
            log.warn(L, "ip_timeout", ip or "nil",
                "status", mobile and mobile.status and mobile.status() or "?",
                "csq", mobile and mobile.csq and mobile.csq() or "?",
                "operator", _G.APP_RUNTIME and _G.APP_RUNTIME.sim_operator_name or "?")
        end
        if not netReadyPublished then
            netReadyPublished = true
            local id = getDeviceId()
            log.info(L, "device_id", id)
            log.info(L, "net_register", id, ipOk and ip ~= nil)
            sys.publish("net_ready", id, ipOk and ip ~= nil)
        end
    end)
    return true
end

--- 等待蜂窝就绪（避免 net_ready 已发布而 mqttTask 后启动导致永远等不到）
local function waitForNetworkReady()
    if netReadyPublished then
        log.info(L, "net_register_ok")
        return true, getDeviceId()
    end
    if socket and socket.localIP then
        local ip = socket.localIP()
        if ip and ip ~= "" and ip ~= "0.0.0.0" then
            log.info(L, "net_register_skip", ip)
            return true, getDeviceId()
        end
    end
    log.info(L, "wait_net_register")
    local gotReady, deviceId = sys.waitUntil("net_ready", 300000)
    if not gotReady then
        gotReady = sys.waitUntil("IP_READY", 120000)
    end
    if not deviceId or deviceId == "" then
        deviceId = getDeviceId()
    end
    return gotReady ~= false and gotReady ~= nil, deviceId
end

-- ============================================================
-- 下行解析
-- ============================================================

local function normalizeDataType(data)
    if type(data) ~= "table" or data.dataType == nil then
        return nil
    end
    return tostring(data.dataType)
end


local function collectSimSnapshot()
    local snap = {
        imei = mobile.imei() or "",
        imsi = mobile.imsi() or "",
        iccid = mobile.iccid() or "",
        status = mobile.status and mobile.status() or "",
        csq = mobile.csq and mobile.csq() or "",
        rssi = mobile.rssi and mobile.rssi() or "",
        rsrq = mobile.rsrq and mobile.rsrq() or "",
        rsrp = mobile.rsrp and mobile.rsrp() or "",
        snr = mobile.snr and mobile.snr() or "",
        simid = mobile.simid and mobile.simid() or "",
        ip = socket and socket.localIP and socket.localIP() or "",
        operator = "",
        operator_name = "",
    }
    local okApn, apn = pcall(mobile.apn, 0, 1)
    if okApn and apn then
        snap.apn = apn
    end
    local okCell, cellular = pcall(require, "cellular_bootstrap")
    if okCell and cellular and cellular.resolveOperator then
        snap.operator, snap.operator_name = cellular.resolveOperator(snap.imsi, snap.iccid, snap.apn)
    end
    local rt = _G.APP_RUNTIME
    if snap.operator == "unknown" and rt and rt.sim_operator and rt.sim_operator ~= "" and rt.sim_operator ~= "unknown" then
        snap.operator = rt.sim_operator
        snap.operator_name = rt.sim_operator_name or snap.operator_name
    end
    if not snap.apn and rt and rt.cellular_apn then
        snap.apn = rt.cellular_apn
    end
    return snap
end

local function collectBatterySnapshot()
    local rt = _G.APP_RUNTIME or {}
    local snap = {
        power_status = tonumber(rt.power_status) or 0,
        battery_percent = rt.battery_percent or "--",
        battery_mv = rt.battery_mv or "--",
        low_power_mode = (rt.low_power_mode == 1) and "rest" or "normal",
        usb_inserted = 0,
        charging = 0,
    }
    snap.usb_inserted = snap.power_status == 1 and 1 or 0

    local ok, uc = pcall(require, "usb_charge")
    if ok and type(uc) == "table" then
        if type(uc.isUsbInserted) == "function" then
            snap.usb_inserted = uc.isUsbInserted() and 1 or 0
            snap.power_status = snap.usb_inserted
        end
        if type(uc.isCharging) == "function" then
            snap.charging = uc.isCharging() and 1 or 0
        end
    end
    -- 与 usbInserted 联动：未插 USB 时 charging 必为 0（防 GPIO17 悬空误报）
    if snap.usb_inserted ~= 1 then
        snap.charging = 0
    end
    return snap
end

local IV_CFG = (_G.APP_PERSIST_CFG and _G.APP_PERSIST_CFG.mqtt_status)
    or "/mqtt_status_cfg.json"
local IV_SCHEMA = (_G.APP_PERSIST_CFG and _G.APP_PERSIST_CFG.mqtt_status_schema) or 1
local IV_MIN, IV_MAX = 10, 86400

local function clampIv(v)
    v = tonumber(v)
    if not v then
        return nil
    end
    v = math.floor(v)
    if v < IV_MIN then
        return IV_MIN
    end
    if v > IV_MAX then
        return IV_MAX
    end
    return v
end

local function syncIv(sec)
    local rt, lp = _G.APP_RUNTIME, _G.LOW_POWER_CFG
    if rt then
        rt.low_power_interval_sec = sec
    end
    if lp then
        lp.rest_mqtt_interval_sec = sec
    end
end

local function saveIvCfg(sec)
    local payload = json.encode({
        schemaVersion = IV_SCHEMA,
        status_interval_sec = sec,
        updated_at = os.time(),
    })
    if not payload then
        log.warn(L, "iv_config_encode_fail")
        return false
    end
    local wf = io.open(IV_CFG, "w")
    if not wf then
        log.warn(L, "iv_config_save_fail", IV_CFG)
        return false
    end
    wf:write(payload)
    wf:close()
    log.info(L, "iv_config_saved", IV_CFG, sec)
    return true
end

local function loadIvCfg()
    local f = io.open(IV_CFG, "r")
    if not f then
        return
    end
    local s = f:read("*a")
    f:close()
    if not s or s == "" then
        log.warn(L, "iv_config_empty", IV_CFG)
        return
    end
    local ok, d = pcall(json.decode, s)
    if not ok or type(d) ~= "table" then
        log.warn(L, "iv_config_decode_fail", IV_CFG)
        return
    end
    local sec = clampIv(d.status_interval_sec)
    if sec then
        syncIv(sec)
        log.info(L, "iv_config_loaded", IV_CFG, sec,
            tonumber(d.schemaVersion) or 0)
    else
        log.warn(L, "iv_config_bad_section", IV_CFG)
    end
end

local function notifyStatusReportIntervalChanged()
    local ev = (_G.APP_EVENTS or {}).MQTT_STATUS_INTERVAL_CHANGED or "APP_MQTT_STATUS_INTERVAL_CHANGED"
    sys.publish(ev)
end

function setStatusIntervalSec(sec, persist)
    sec = clampIv(sec)
    if not sec then
        return false, "invalid_interval"
    end
    syncIv(sec)
    if persist and not saveIvCfg(sec) then
        notifyStatusReportIntervalChanged()
        return false, "persist_fail"
    end
    notifyStatusReportIntervalChanged()
    return true
end

--- 1003 周期（秒）：持久化 → APP_RUNTIME → LOW_POWER_CFG → BATTERY 回退
local function getStatusReportIntervalSec()
    local sec = clampIv((_G.APP_RUNTIME or {}).low_power_interval_sec)
    if sec then
        return sec
    end
    sec = clampIv((_G.LOW_POWER_CFG or {}).rest_mqtt_interval_sec)
    if sec then
        return sec
    end
    return clampIv((_G.BATTERY_CFG or {}).mqtt_report_interval_sec) or 30
end

local function startStatusReportTimer()
    if statusReportTimerStarted then
        return
    end
    statusReportTimerStarted = true
    sys.taskInit(function()
        while true do
            local intervalSec = getStatusReportIntervalSec()
            local changed = sys.waitUntil(
                (_G.APP_EVENTS or {}).MQTT_STATUS_INTERVAL_CHANGED or "APP_MQTT_STATUS_INTERVAL_CHANGED",
                intervalSec * 1000)
            if not changed and isConnected then
                publishStatus()
            end
        end
    end)
end

local function setupBatteryStatusReport()
    if batteryStatusSubscribed then
        return
    end
    batteryStatusSubscribed = true
    sys.subscribe("BATTERY_UPDATE", function()
        if not isConnected then
            return
        end
        local intervalSec = getStatusReportIntervalSec()
        local minSec = tonumber((_G.BATTERY_CFG or {}).mqtt_battery_report_min_sec) or 30
        if intervalSec > minSec then
            minSec = intervalSec
        end
        local now = os.time()
        if now - lastBatteryStatusPublishSec < minSec then
            return
        end
        lastBatteryStatusPublishSec = now
        sys.taskInit(function()
            publishStatus()
        end)
    end)
end

-- [2001] 唤醒查询 → 1001
local function handleDownlink2001(data)
    log.info(L, "downlink_2001")
    if data.messageId then
        log.info(L, "downlink_2001_msg", data.messageId)
    end
    publishWakeup()
end

-- [2002] 休眠/低功耗 → 1002（enter/exit 成功后由 app 上报 rest 主题）
local function usbBlocks4gRest()
    local ok, up = pcall(require, "usb_policy")
    if ok and type(up) == "table" and up.blocks4gRest then
        return up.blocks4gRest()
    end
    return (_G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.power_status) == 1) or false
end

local function handleDownlink2002(data)
    if data.lowPowerMode == "enter" then
        if usbBlocks4gRest() then
            log.info(L, "downlink_2002_unknown")
            return
        end
        log.info(L, "downlink_2002_enter")
        sys.publish(APP_EVENTS.POWER_ENTER_REST)
    elseif data.lowPowerMode == "exit" then
        log.info(L, "downlink_2002_exit")
        sys.publish(APP_EVENTS.POWER_EXIT_REST)
    else
        log.warn(L, "downlink_2002_invalid", data.lowPowerMode)
    end
end

-- [2003] 状态/配置 → 1003（带 interval 时落盘并回显同一 interval）
local function handleDownlink2003(data)
    if data.usbRecoveryReset == 1 or data.action == "usbRecoveryReset" then
        log.info(L, "downlink_2003_usb_refresh")
        local hu = getHostUart()
        local ok = false
        if hu and hu.resetUsbRecoveryFromCloud then
            ok = hu.resetUsbRecoveryFromCloud()
        end
        publishStatus({
            messageId = data.messageId or "",
            configRet = ok and 0 or -1,
            configMsg = ok and "usb_recovery_reset" or "usb_recovery_reset_fail",
        })
        return
    end
    if data.interval ~= nil then
        log.info(L, "downlink_2003_interval", data.interval)
    else
        log.info(L, "downlink_2003_query")
    end
    local messageId = data.messageId or ""
    local configRet = 0
    local configMsg = "ok"
    if data.interval ~= nil then
        if setStatusIntervalSec(data.interval, true) then
            log.info(L, "downlink_2003_ok", getStatusReportIntervalSec())
        else
            configRet = -1
            configMsg = "invalid_interval"
            log.warn(L, "downlink_2003_invalid", data.interval)
        end
    end
    publishStatus({
        messageId = messageId,
        configRet = configRet,
        configMsg = configMsg,
    })
end

-- [2004] 电源/OTA 控制 → 1004(reply) + OTA 过程 1004(stage)
local function fetchWledFromHost()
    local on = getWledState()
    local hu = getHostUart()
    if hu and hu.queryHostWled and hu.isHostAtReady and hu.isHostAtReady() then
        on = hu.queryHostWled() or on
    end
    return on
end

local function makeDownlink2004Reply(data)
    local action = data.action
    local messageId = data.messageId or ""
    return function(ret, msg, act, extraFields)
        local extra = { messageId = messageId }
        if type(extraFields) == "table" then
            for k, v in pairs(extraFields) do
                extra[k] = v
            end
        end
        publishControlReply(act or action, ret, msg, extra)
    end
end

local function runWledQuery2004(reply)
    sys.taskInit(function()
        local on = fetchWledFromHost()
        log.info(L, "downlink_2004_wled_query", on)
        reply(0, "ok", "wled", { enable = on })
    end)
end

local function runWledSet2004(reply, on)
    sys.taskInit(function()
        log.info(L, "downlink_2004_wled", on)
        local hu = getHostUart()
        local ok = true
        if hu and hu.setWled then
            ok = hu.setWled(on, { sync = true }) == true
        elseif _G.APP_RUNTIME then
            _G.APP_RUNTIME.wled_on = on
        end
        if ok then
            reply(0, "ok", "wled", { enable = on })
        else
            reply(-1, "wled_forward_fail", "wled", { enable = getWledState() })
        end
    end)
end

local function resolve2004Action(action, data)
    if action == "wled_query" or action == "wled?" then
        return "wled_query"
    end
    if action == "wled" and (data.query == 1 or data.query == true) then
        return "wled_query"
    end
    if action == "wled" or action == "wled_on" or action == "wled_off" then
        return "wled_set"
    end
    return action
end

local function parse2004WledEnable(action, data)
    if action == "wled_on" then
        return 1
    end
    if action == "wled_off" then
        return 0
    end
    return tonumber(data.enable)
end

local DL2004_ACTIONS = {
    reboot = function(_data, reply)
        log.info(L, "downlink_2004_reboot")
        reply(0, "ok", "reboot")
        sys.publish(APP_EVENTS.DEVICE_REBOOT_REQUEST)
    end,
    off = function(_data, reply)
        log.info(L, "downlink_2004_poweroff")
        reply(0, "ok", "off")
        sys.publish(APP_EVENTS.DEVICE_POWER_OFF_REQUEST)
    end,
    ota = function(data, reply)
        log.info(L, "downlink_2004_ota")
        if _G.validateBuildVersion then
            local v = data.version
            if v and v ~= "" then
                local ok = _G.validateBuildVersion(tostring(v))
                if not ok then
                    log.warn(L, "downlink_2004_version_bad", v)
                    reply(-1, "invalid_version_format", "ota")
                    return
                end
                data.version = ok
            end
        end
        reply(0, "ota_accepted", "ota")
        publishAppEvent("DEVICE_OTA_REQUEST", data)
    end,
    wled_query = function(_data, reply)
        runWledQuery2004(reply)
    end,
}

local function handleDownlink2004(data)
    local reply = makeDownlink2004Reply(data)
    local resolved = resolve2004Action(data.action, data)
    if resolved == "wled_set" then
        local on = parse2004WledEnable(data.action, data)
        if on ~= 0 and on ~= 1 then
            log.warn(L, "downlink_2004_wled_error", tostring(on))
            reply(-1, "invalid_wled", "wled")
            return
        end
        runWledSet2004(reply, on)
        return
    end
    local fn = DL2004_ACTIONS[resolved]
    if fn then
        fn(data, reply)
        return
    end
    log.warn(L, "downlink_2004_unknown", data.action)
    reply(-1, "unknown_action", data.action or "")
end

-- [2005] SIM 查询 → 1005
local function handleDownlink2005(data)
    log.info(L, "downlink_2005")
    if data.messageId then
        log.info(L, "downlink_2005_msg", data.messageId)
    end
    publishSimInfo()
end

local function identityCfg()
    return _G.HOST_IDENTITY_CFG or {}
end

local function identityEnabled()
    if identityCfg().enabled == false then
        return false
    end
    return true
end

local function refreshDeviceIdentity(messageId)
    local imei = getDeviceId()
    local gb28181Id
    local hu = getHostUart()
    if hu and hu.queryHostGb28181 then
        gb28181Id = hu.queryHostGb28181(identityCfg().query_timeout_ms)
    elseif hu and hu.getCachedHostGb28181Id then
        gb28181Id = hu.getCachedHostGb28181Id()
    end
    publishDeviceIdentity(imei, gb28181Id, messageId)
end

local function isT3xHostReady()
    local hu = getHostUart()
    if hu and hu.isHostAtReady then
        return hu.isHostAtReady() == true
    end
    local ok, t3x = pcall(require, "t3x_ctrl")
    if ok and t3x and t3x.getState then
        local st = t3x.getState()
        return st and st.powered_on == true
    end
    return false
end

local function enqueuePendingHostWork(dtype, data)
    pendingHostQueue[#pendingHostQueue + 1] = {
        dtype = dtype,
        data = data,
        ts = os.time(),
    }
    log.info(L, "host_queue_push", dtype, #pendingHostQueue)
end

local function wakeT3xForPendingHost()
    sys.taskInit(function()
        local ok, ts = pcall(require, "time_sync")
        if ok and ts and ts.pushBeforeNotifyAsync then
            ts.pushBeforeNotifyAsync((_G.HOST_WAKE_CFG or {}).default_sid or 1, 0)
        else
            local hu = getHostUart()
            if hu and hu.notify_host then
                hu.notify_host((_G.HOST_WAKE_CFG or {}).default_sid or 1, 0)
            end
        end
    end)
end

function drainPendingHostWork()
    if #pendingHostQueue == 0 then
        return 0
    end
    if not isT3xHostReady() then
        return 0
    end
    local batch = pendingHostQueue
    pendingHostQueue = {}
    log.info(L, "host_queue_pop", #batch)
    for _, item in ipairs(batch) do
        local handler = DOWNLINK_HANDLERS[item.dtype]
        if handler and item.data then
            handler(item.data)
        end
    end
    return #batch
end

local function handleHostDownlink(dtype, data, runFn)
    if HOST_DL_NEEDS_T3X[dtype] and not isT3xHostReady() then
        enqueuePendingHostWork(dtype, data)
        wakeT3xForPendingHost()
        return
    end
    runFn()
end

local function downlinkMessageId(data)
    return data.messageId or data.msgId or ""
end

--- 100x reply 上行公共骨架（各业务通过 appendFields 扩展 body）
local function publishReplyBase(opts)
    local fields = string.format(
        ',"reply":1,"messageId":"%s","ret":%s,"message":"%s"',
        escJson(opts.messageId or ""),
        tostring(opts.retCode ~= nil and opts.retCode or -1),
        escJson(opts.message or ""))
    if opts.appendFields then
        fields = fields .. opts.appendFields(opts.body)
    end
    publishUplink({
        suffix = opts.suffix,
        dataType = opts.dataType,
        no_conn = NC,
        fields = fields,
        log = opts.log,
        log_args = opts.log_args or { opts.dataType, opts.retCode, opts.message },
    })
end

--- 需 T3x 在线的 query/set 下行包装（2022–2031 等）
local function wrapHostDownlink(dlType, handler, isQuery)
    return function(data)
        handleHostDownlink(dlType, data, function()
            handler(data, isQuery)
        end)
    end
end

-- [2006] IMEI + GB28181 查询 → 1006
local function handleDownlink2006(data)
    log.info(L, "downlink_2006")
    if data.messageId then
        log.info(L, "downlink_2006_msg", data.messageId)
    end
    handleHostDownlink(DT.DL_DEVICE_ID, data, function()
        sys.taskInit(function()
            refreshDeviceIdentity(data.messageId)
        end)
    end)
end

local function tfCardCfg()
    return _G.HOST_TFCARD_CFG or {}
end

local function tfCardEnabled()
    if tfCardCfg().enabled == false then
        return false
    end
    return true
end

local function refreshTfCardStatus(messageId)
    if not tfCardEnabled() then
        log.warn(L, "downlink_2007_disabled")
        publishTfCardStatus({ present = 0, total_mb = 0, used_mb = 0, free_mb = 0 }, messageId)
        return
    end
    local hu = getHostUart()
    local snap
    if hu and hu.queryHostTfCard then
        snap = hu.queryHostTfCard(tfCardCfg().query_timeout_ms)
    elseif hu and hu.getCachedHostTfCard then
        snap = hu.getCachedHostTfCard()
    end
    if snap == nil then
        log.warn(L, "downlink_2007_timeout")
        publishTfCardStatus({ present = 0, total_mb = 0, used_mb = 0, free_mb = 0, timeout = true }, messageId)
        return
    end
    publishTfCardStatus(snap, messageId)
end

-- [2007] TF/SD 卡状态查询 → 1007
local function handleDownlink2007(data)
    log.info(L, "downlink_2007")
    if data.messageId then
        log.info(L, "downlink_2007_msg", data.messageId)
    end
    handleHostDownlink(DT.DL_TF_CARD, data, function()
        sys.taskInit(function()
            refreshTfCardStatus(data.messageId)
        end)
    end)
end

local function tfFormatCfg()
    return _G.HOST_TFCARD_FORMAT_CFG or {}
end

local function tfFormatEnabled()
    return tfFormatCfg().enabled ~= false
end

--- 格式化前：停 4G PIR 会话 + T3x AT+RECORDCTRL=0（T3x 侧仍会 FIFO 停录双保险）
local function stopRecordingBeforeTfFormat()
    if pir_ctrl.suspend then
        pir_ctrl.suspend()
    end
    local hu = getHostUart()
    if hu and hu.recordCtrlStop and isT3xHostReady() then
        local rok, rmsg = hu.recordCtrlStop({
            reason = "tfcard_format",
            timeout_ms = tonumber(tfFormatCfg().record_stop_timeout_ms) or 15000,
        })
        log.info(L, "downlink_2009_recordctrl", rok and 1 or 0, rmsg or "")
    end
    sys.wait(tonumber(tfFormatCfg().pre_format_wait_ms) or 500)
end

local function runTfCardFormat(messageId, reboot)
    if not tfFormatEnabled() then
        log.warn(L, "downlink_2009_disabled")
        publishTfFormatResult(-1, "disabled", messageId, { reboot = reboot })
        return
    end
    local hu = getHostUart()
    if not hu or not hu.formatHostTfCard then
        log.warn(L, "downlink_2009_no_fn")
        publishTfFormatResult(-1, "no_uart", messageId, { reboot = reboot })
        return
    end
    stopRecordingBeforeTfFormat()
    local ok, detail = hu.formatHostTfCard({
        reboot = reboot,
        timeout_ms = tfFormatCfg().format_timeout_ms,
    })
    if ok then
        local extra = type(detail) == "table" and detail or { reboot = reboot }
        publishTfFormatResult(0, "ok", messageId, extra)
        if tfFormatCfg().publish_status_after ~= false
            and (extra.reboot or 0) == 0 then
            sys.wait(1000)
            refreshTfCardStatus(messageId)
        end
    else
        publishTfFormatResult(-1, tostring(detail or "error"), messageId, { reboot = reboot })
    end
end

-- [2009] TF/SD 卡格式化 → 1009
local function handleDownlink2009(data)
    log.info(L, "downlink_2009")
    if data.messageId then
        log.info(L, "downlink_2009_msg", data.messageId)
    end
    local action = data.action or "format"
    if action ~= "format" then
        log.warn(L, "downlink_2009_unknown", action)
        publishTfFormatResult(-1, "unknown_action", data.messageId, {})
        return
    end
    local reboot = data.reboot
    if reboot == nil then
        reboot = tfFormatCfg().reboot_after == true or tfFormatCfg().reboot_after == 1
    end
    reboot = (reboot == 1 or reboot == true) and 1 or 0
    handleHostDownlink(DT.DL_TF_FORMAT, data, function()
        sys.taskInit(function()
            runTfCardFormat(data.messageId, reboot)
            if pir_ctrl.resume and (reboot or 0) == 0 then
                pir_ctrl.resume()
            end
        end)
    end)
end

local function maybeAutoPublishIdentity()
    if not identityEnabled() or identityCfg().auto_publish_on_ready == false then
        return
    end
    if identityPublished or not isConnected then
        return
    end
    local hu = getHostUart()
    if not hu or not hu.isHostAtReady or not hu.isHostAtReady() then
        return
    end
    identityPublished = true
    sys.taskInit(function()
        sys.wait(tonumber(identityCfg().auto_publish_delay_ms) or 500)
        refreshDeviceIdentity(nil)
    end)
end

local function setupIdentityAutoPublish()
    if identityAutoHooked or not identityEnabled() then
        return
    end
    identityAutoHooked = true
    local evt = (_G.APP_EVENTS and _G.APP_EVENTS.HOST_UART_FIRST_AT) or "APP_HOST_UART_FIRST_AT"
    sys.subscribe(evt, function()
        maybeAutoPublishIdentity()
    end)
    sys.subscribe("APP_MQTT_CONNECTED", function()
        maybeAutoPublishIdentity()
    end)
end

local function buildPirDetectExtra(pirStatus, action, uploadMode, quality, recording)
    local st = pir_ctrl.getState()
    local media = st.mediaConfig or {}
    return {
        status = pirStatus or "detected",
        action = action or media.action or "",
        uploadMode = uploadMode or media.uploadMode or "",
        quality = quality or media.quality or "",
        recording = recording ~= nil and recording or (st.recording and 1 or 0),
    }
end

local function handleDownlink2010(data)
    if data.action == "query" then
        log.info(L, "downlink_2010_query")
        publishPirDetect(buildPirDetectExtra("query", nil, nil, nil, nil))
        return
    end

    local hasCfg = data.action or data.uploadMode or data.quality
        or data.videoMaxDurationSec
        or data.stopOnSecondPir ~= nil or data.stopOnCloud ~= nil
        or data.startOnCloud ~= nil
    if hasCfg then
        pir_ctrl.setMediaConfig({
            action = data.action,
            uploadMode = data.uploadMode,
            quality = data.quality,
        })
        pir_ctrl.setRecordPolicy({
            maxDurationSec = data.videoMaxDurationSec,
            stopOnSecondPir = data.stopOnSecondPir,
            stopOnCloud = data.stopOnCloud,
            startOnCloud = data.startOnCloud,
        })
        local pirState = pir_ctrl.getState()
        log.info(L, "downlink_2010_config",
            json.encode(pirState.mediaConfig),
            json.encode(pirState.recordPolicy))
        local media = pirState.mediaConfig or {}
        publishPirFromState({
            pirStatus = "config_ok",
            action = media.action or "video",
        })
    else
        log.warn(L, "downlink_2010_invalid")
        publishPirFromState({
            pirStatus = "config_rejected",
            status = "config_rejected",
        })
    end
end

local function handleDownlink2011(data)
    local messageId = data.messageId or ""
    if messageId ~= "" then
        log.info(L, "downlink_2011_msg", messageId)
    else
        log.info(L, "downlink_2011_stop")
    end
    local ok, err = pir_ctrl.requestStopFromCloud({ messageId = messageId })
    if ok then
        publishControlReply("pir_stop", 0, "ok", { messageId = messageId })
        if isT3xHostReady() then
            local hu = getHostUart()
            if hu and hu.recordCtrlStop then
                sys.taskInit(function()
                    local rok, rmsg = hu.recordCtrlStop({ reason = "cloud", timeout_ms = 8000 })
                    log.info(L, "downlink_2011_recordctrl", rok and 1 or 0, rmsg or "")
                end)
            end
        end
    else
        local st = pir_ctrl.getState()
        local pol = st.recordPolicy or {}
        err = err or "rejected"
        log.warn(L, "downlink_2011_error", err, "rec", st.recording and 1 or 0,
            "cloud", pol.stopOnCloud and 1 or 0)
        publishControlReply("pir_stop", -1, err, { messageId = messageId })
    end
end

--- 2012 平台开录（TF 卡）→ 1012（event）；T3x 写盘后另有 1010 t3x_active（pir）
local function handleDownlink2012(data)
    sys.taskInit(function()
        if data.messageId then
            log.info(L, "downlink_2012_msg", data.messageId)
        else
            log.info(L, "downlink_2012_start")
        end
        if not pir_ctrl.requestStartFromCloud then
            log.warn(L, "downlink_2012_error", "no_fn")
            return
        end
        local messageId = downlinkMessageId(data)
        local ok, result = pir_ctrl.requestStartFromCloud({
            action = data.action,
            uploadMode = data.uploadMode,
            quality = data.quality,
            videoMaxDurationSec = data.videoMaxDurationSec,
        })
        if ok then
            publishControlReply("pir_start", 0, "ok", { messageId = messageId })
            local media = type(result) == "table" and result or {}
            local st = pir_ctrl.getState()
            publishPirRecordStart(
                media.action or (st.mediaConfig and st.mediaConfig.action) or "video",
                media.uploadMode or st.uploadMode or "auto",
                media.quality or st.quality or "high",
                { source = "4g", messageId = messageId }
            )
            if isT3xHostReady() then
                local hu = getHostUart()
                if hu and hu.recordCtrlStart then
                    sys.taskInit(function()
                        local maxSec = tonumber(data.videoMaxDurationSec) or 90
                        local rok, rmsg = hu.recordCtrlStart({
                            max_sec = maxSec,
                            timeout_ms = 10000,
                        })
                        log.info(L, "downlink_2012_recordctrl", rok and 1 or 0, rmsg or "")
                        if not rok then
                            publishIpcAlert("recordctrl_fail", rmsg or "start")
                        end
                    end)
                end
            end
        else
            local err = result or "rejected"
            log.warn(L, "downlink_2012_error", err)
            publishControlReply("pir_start", -1, err, { messageId = messageId })
        end
    end)
end

local function publishEncodeReply(dlType, retCode, message, body, messageId)
    local ulType = (dlType == DT.DL_ENCODE_QUERY) and DT.UL_ENCODE_QUERY or DT.UL_ENCODE_SET
    publishReplyBase({
        dataType = ulType,
        suffix = "encode",
        log = "publish_encode",
        retCode = retCode,
        message = message,
        messageId = messageId,
        body = body,
        appendFields = function(b)
            local extra = ""
            if type(b) == "table" then
                if b.needReboot ~= nil then
                    extra = extra .. string.format(',"needReboot":%s',
                        (b.needReboot == true or b.needReboot == 1) and "1" or "0")
                end
                if b.runtimeApply ~= nil then
                    extra = extra .. string.format(',"runtimeApply":%d', tonumber(b.runtimeApply) or 0)
                end
                local ok, encoded = pcall(json.encode, b)
                if ok and encoded then
                    extra = extra .. ',"body":' .. encoded
                end
            end
            return extra
        end,
    })
end

local function handleDownlinkEncode(data, isQuery)
    sys.taskInit(function()
        local hu = getHostUart()
        local dlType = isQuery and DT.DL_ENCODE_QUERY or DT.DL_ENCODE_SET
        if not hu then
            publishEncodeReply(dlType, -1, "no_host_uart", nil, data.messageId)
            return
        end
        if isQuery then
            if not hu.queryHostEncode then
                publishEncodeReply(dlType, -1, "no_host_uart", nil, data.messageId)
                return
            end
            local encCfg = _G.HOST_ENCODE_CFG or {}
            local timeoutMs = tonumber(data.timeoutMs) or tonumber(data.timeout_ms)
                or tonumber(encCfg.query_timeout_ms) or 12000
            local result, err = hu.queryHostEncode({
                scope = data.scope,
                camera = data.camera,
                stream = data.stream,
                timeout_ms = timeoutMs,
            })
            if result then
                publishEncodeReply(dlType, 0, "ok", result, data.messageId)
            else
                log.warn(L, "downlink_2020_fail", err or "query_fail")
                publishEncodeReply(dlType, -1, err or "query_fail", nil, data.messageId)
            end
            return
        end
        local ok, msg, extra
        if data.scope == "audio" and hu.setHostAudioEncode then
            ok, msg, extra = hu.setHostAudioEncode(data)
        elseif hu.setHostVideoEncode then
            ok, msg, extra = hu.setHostVideoEncode(data)
        else
            ok, msg, extra = false, "unsupported", nil
        end
        local body = extra or {}
        if ok and extra and extra.needReboot ~= nil then
            body.needReboot = extra.needReboot
        end
        if ok and extra and extra.runtimeApply ~= nil then
            body.runtimeApply = extra.runtimeApply
        end
        publishEncodeReply(dlType, ok and 0 or -1, msg or (ok and "ok" or "fail"), body, data.messageId)
        if ok and extra and tonumber(extra.runtimeApply) == 0 and not extra.needReboot then
            publishIpcAlert("encode_runtime_fail", data.scope or "video")
        end
    end)
end

local function handleDownlink2021(data)
    handleDownlinkEncode(data, false)
end

local function handleDownlink2020(data)
    handleDownlinkEncode(data, true)
end


local RECORD_TIME_ALLOWED = "5|10|15|20|30|45|60"

--- 2022–2031：T3x UART query/set 下行公共工厂
local function makeQuerySetReplyPublisher(spec)
    return function(dlType, retCode, message, body, messageId)
        local ulType = (dlType == spec.queryDl) and spec.ulQuery or spec.ulSet
        publishReplyBase({
            dataType = ulType,
            suffix = spec.suffix,
            log = spec.log,
            retCode = retCode,
            message = message,
            messageId = messageId,
            body = body,
            appendFields = spec.appendFields,
        })
    end
end

local function makeHostQuerySetHandler(spec)
    local publishReply = makeQuerySetReplyPublisher(spec)
    return function(data, isQuery)
        sys.taskInit(function()
            local hu = getHostUart()
            local dlType = isQuery and spec.queryDl or spec.setDl
            local messageId = downlinkMessageId(data)
            local timeoutMs = tonumber(data.timeoutMs) or tonumber(data.timeout_ms)
                or spec.defaultTimeoutMs or 12000
            if not hu then
                publishReply(dlType, -1, "no_host_uart", nil, messageId)
                return
            end
            if isQuery then
                local qfn = spec.queryFn
                if not qfn then
                    publishReply(dlType, -1, "no_host_uart", nil, messageId)
                    return
                end
                local body, err, failBody = qfn(hu, data, timeoutMs)
                if body then
                    publishReply(dlType, 0, "ok", body, messageId)
                else
                    if spec.queryFailLog then
                        log.warn(L, spec.queryFailLog, err or "query_fail")
                    end
                    publishReply(dlType, -1, err or "query_fail", failBody, messageId)
                end
                return
            end
            local sfn = spec.setFn
            if not sfn then
                publishReply(dlType, -1, "no_host_uart", nil, messageId)
                return
            end
            local ok, msg, extra, failBody = sfn(hu, data, timeoutMs)
            if ok then
                publishReply(dlType, 0, "ok", extra, messageId)
                if spec.onSetSuccess then
                    spec.onSetSuccess(extra, data)
                end
            else
                if spec.setFailLog then
                    log.warn(L, spec.setFailLog, msg or "fail")
                end
                publishReply(dlType, -1, msg or "fail", failBody or extra, messageId)
            end
        end)
    end
end

local HOST_UART_QUERY_SET_SPECS = {
    recordTime = {
        queryDl = DT.DL_RECORD_TIME_QUERY,
        setDl = DT.DL_RECORD_TIME_SET,
        ulQuery = DT.UL_RECORD_TIME_QUERY,
        ulSet = DT.UL_RECORD_TIME_SET,
        suffix = "record",
        log = "publish_recordtime",
        defaultTimeoutMs = 12000,
        queryFailLog = "downlink_2022_fail",
        setFailLog = "downlink_2023_fail",
        appendFields = function(b)
            local extra = ""
            if type(b) == "table" then
                if b.minutes ~= nil then
                    extra = extra .. string.format(',"recordTimeMin":%d', tonumber(b.minutes) or 0)
                end
                if b.allowedMin then
                    extra = extra .. string.format(',"allowedMin":"%s"', escJson(b.allowedMin))
                end
            end
            return extra
        end,
        queryFn = function(hu, _data, timeoutMs)
            if not hu.queryHostRecordTime then
                return nil
            end
            local snap = hu.queryHostRecordTime(timeoutMs)
            if snap and snap.parsed then
                return {
                    minutes = snap.minutes,
                    allowedMin = RECORD_TIME_ALLOWED,
                }
            end
            return nil, "query_fail", { allowedMin = RECORD_TIME_ALLOWED }
        end,
        setFn = function(hu, data, timeoutMs)
            if not hu.setHostRecordTime then
                return false, "no_host_uart"
            end
            local min = tonumber(data.recordTimeMin or data.recTime or data.minutes or data.min)
            if min == nil then
                return false, "missing_min", nil, { allowedMin = RECORD_TIME_ALLOWED }
            end
            local ok, msg, extra = hu.setHostRecordTime({
                minutes = min,
                timeout_ms = timeoutMs,
            })
            if ok then
                return true, "ok", {
                    minutes = extra and extra.minutes or min,
                    allowedMin = RECORD_TIME_ALLOWED,
                }
            end
            return false, msg or "fail", nil, { allowedMin = RECORD_TIME_ALLOWED }
        end,
    },
    framerate = {
        queryDl = DT.DL_FRAMERATE_QUERY,
        setDl = DT.DL_FRAMERATE_SET,
        ulQuery = DT.UL_FRAMERATE_QUERY,
        ulSet = DT.UL_FRAMERATE_SET,
        suffix = "framerate",
        log = "publish_framerate",
        defaultTimeoutMs = 12000,
        appendFields = function(b)
            local extra = ""
            if type(b) == "table" then
                if b.runtimeApply ~= nil then
                    extra = extra .. string.format(',"runtimeApply":%d', tonumber(b.runtimeApply) or 0)
                end
                local ok, encoded = pcall(json.encode, b)
                if ok and encoded then
                    extra = extra .. ',"body":' .. encoded
                end
            end
            return extra
        end,
        queryFn = function(hu, data, timeoutMs)
            if not hu.queryHostFramerate then
                return nil
            end
            local rows = hu.queryHostFramerate({
                camera = data.camera,
                stream = data.stream,
                timeout_ms = timeoutMs,
            })
            if type(rows) == "table" then
                return { streams = rows }
            end
            return nil, "query_fail"
        end,
        setFn = function(hu, data, timeoutMs)
            if not hu.setHostFramerate then
                return false, "no_host_uart"
            end
            local ok, msg, extra = hu.setHostFramerate({
                camera = data.camera,
                stream = data.stream,
                framerate = data.framerate or data.fps,
                timeout_ms = timeoutMs,
            })
            if ok then
                return true, "ok", extra
            end
            return false, msg or "fail"
        end,
        onSetSuccess = function(extra)
            if extra and tonumber(extra.runtimeApply) == 0 then
                publishIpcAlert("encode_runtime_fail", "framerate")
            end
        end,
    },
    personDetect = {
        queryDl = DT.DL_PERSON_DETECT_QUERY,
        setDl = DT.DL_PERSON_DETECT_SET,
        ulQuery = DT.UL_PERSON_DETECT_QUERY,
        ulSet = DT.UL_PERSON_DETECT_SET,
        suffix = "personDetect",
        log = "publish_persondet",
        defaultTimeoutMs = 8000,
        appendFields = function(b)
            local extra = ""
            if type(b) == "table" and b.enable ~= nil then
                extra = extra .. string.format(',"enable":%d', tonumber(b.enable) or 0)
            end
            if type(b) == "table" and b.personDetectAvailable ~= nil then
                extra = extra .. string.format(',"personDetectAvailable":%d',
                    tonumber(b.personDetectAvailable) or 0)
            end
            return extra
        end,
        queryFn = function(hu, _data, timeoutMs)
            if not hu.queryHostPersonDetect then
                return nil
            end
            local snap = hu.queryHostPersonDetect(timeoutMs)
            if snap and snap.parsed then
                return {
                    enable = snap.enable,
                    personDetectAvailable = snap.available,
                }
            end
            return nil, "query_fail"
        end,
        setFn = function(hu, data, timeoutMs)
            if not hu.setHostPersonDetect then
                return false, "no_host_uart"
            end
            local enable = tonumber(data.enable)
            if enable == nil or (enable ~= 0 and enable ~= 1) then
                return false, "invalid_enable"
            end
            local ok, msg, extra = hu.setHostPersonDetect({
                enable = enable,
                timeout_ms = timeoutMs,
            })
            if ok then
                return true, "ok", {
                    enable = extra and extra.enable or enable,
                }
            end
            return false, msg or "fail"
        end,
    },
    mic = {
        queryDl = DT.DL_MIC_QUERY,
        setDl = DT.DL_MIC_SET,
        ulQuery = DT.UL_MIC_QUERY,
        ulSet = DT.UL_MIC_SET,
        suffix = "mic",
        log = "publish_mic",
        defaultTimeoutMs = 8000,
        appendFields = function(b)
            local extra = ""
            if type(b) == "table" then
                if b.camera ~= nil then
                    extra = extra .. string.format(',"camera":%d', tonumber(b.camera) or 0)
                end
                if b.volume ~= nil then
                    extra = extra .. string.format(',"volume":%d', tonumber(b.volume) or 0)
                end
                if b.gain ~= nil then
                    extra = extra .. string.format(',"gain":%d', tonumber(b.gain) or 0)
                end
                if b.runtimeApply ~= nil then
                    extra = extra .. string.format(',"runtimeApply":%d', tonumber(b.runtimeApply) or 0)
                end
                if b.mics and json and json.encode then
                    local ok, encoded = pcall(json.encode, b.mics)
                    if ok and encoded then
                        extra = extra .. ',"mics":' .. encoded
                    end
                end
            end
            return extra
        end,
        queryFn = function(hu, data, timeoutMs)
            if not hu.queryHostMic then
                return nil
            end
            local rows = hu.queryHostMic({
                camera = data.camera,
                timeout_ms = timeoutMs,
            })
            if type(rows) ~= "table" or #rows == 0 then
                return nil, "query_fail"
            end
            local cam = tonumber(data.camera)
            local row = rows[1]
            if cam ~= nil then
                for _, r in ipairs(rows) do
                    if tonumber(r.camera) == cam then
                        row = r
                        break
                    end
                end
            end
            return {
                camera = row.camera,
                volume = row.volume,
                gain = row.gain,
                mics = rows,
            }
        end,
        setFn = function(hu, data, timeoutMs)
            if not hu.setHostMic then
                return false, "no_host_uart"
            end
            local volume = tonumber(data.volume)
            local gain = tonumber(data.gain)
            if volume == nil or gain == nil then
                return false, "missing_params"
            end
            local ok, msg, extra = hu.setHostMic({
                camera = data.camera,
                volume = volume,
                gain = gain,
                timeout_ms = timeoutMs,
            })
            if ok then
                return true, "ok", {
                    camera = extra and extra.camera or tonumber(data.camera) or 0,
                    volume = volume,
                    gain = gain,
                    runtimeApply = extra and extra.runtimeApply or 0,
                }
            end
            return false, msg or "fail"
        end,
    },
    softPhoto = {
        queryDl = DT.DL_SOFTPHOTO_QUERY,
        setDl = DT.DL_SOFTPHOTO_SET,
        ulQuery = DT.UL_SOFTPHOTO_QUERY,
        ulSet = DT.UL_SOFTPHOTO_SET,
        suffix = "softPhoto",
        log = "publish_softphoto",
        defaultTimeoutMs = 8000,
        appendFields = function(b)
            local extra = ""
            local keys = {
                "enable", "nightModeThreshold", "dayModeThreshold", "dayModeAltThreshold",
                "gbGainThreshold", "gbGainRecordInit", "checkTime", "checkCount",
            }
            if type(b) == "table" then
                for _, k in ipairs(keys) do
                    if b[k] ~= nil then
                        extra = extra .. string.format(',"%s":%d', k, tonumber(b[k]) or 0)
                    end
                end
            end
            return extra
        end,
        queryFn = function(hu, _data, timeoutMs)
            if not hu.queryHostSoftPhoto then
                return nil
            end
            local snap = hu.queryHostSoftPhoto(timeoutMs)
            if snap and snap.parsed then
                return snap
            end
            return nil, "query_fail"
        end,
        setFn = function(hu, data, timeoutMs)
            if not hu.setHostSoftPhoto then
                return false, "no_host_uart"
            end
            local ok, msg, extra = hu.setHostSoftPhoto({
                enable = data.enable,
                nightModeThreshold = data.nightModeThreshold or data.night_mode_threshold,
                dayModeThreshold = data.dayModeThreshold or data.day_mode_threshold,
                dayModeAltThreshold = data.dayModeAltThreshold or data.day_mode_alt_threshold,
                gbGainThreshold = data.gbGainThreshold or data.gb_gain_threshold,
                gbGainRecordInit = data.gbGainRecordInit or data.gb_gain_record_init,
                checkTime = data.checkTime or data.check_time,
                checkCount = data.checkCount or data.check_count,
                timeout_ms = timeoutMs,
            })
            if ok then
                return true, "ok", {
                    enable = data.enable,
                    nightModeThreshold = data.nightModeThreshold or data.night_mode_threshold,
                    dayModeThreshold = data.dayModeThreshold or data.day_mode_threshold,
                    dayModeAltThreshold = data.dayModeAltThreshold or data.day_mode_alt_threshold,
                    gbGainThreshold = data.gbGainThreshold or data.gb_gain_threshold,
                    gbGainRecordInit = data.gbGainRecordInit or data.gb_gain_record_init,
                    checkTime = data.checkTime or data.check_time,
                    checkCount = data.checkCount or data.check_count,
                }
            end
            return false, msg or "fail", extra
        end,
    },
}

local HOST_UART_QUERY_SET_ORDER = {
    "recordTime", "framerate", "personDetect", "mic", "softPhoto",
}

local function registerHostQuerySetHandlers(map)
    for i = 1, #HOST_UART_QUERY_SET_ORDER do
        local spec = HOST_UART_QUERY_SET_SPECS[HOST_UART_QUERY_SET_ORDER[i]]
        local handler = makeHostQuerySetHandler(spec)
        map[spec.queryDl] = wrapHostDownlink(spec.queryDl, handler, true)
        map[spec.setDl] = wrapHostDownlink(spec.setDl, handler, false)
    end
end

DOWNLINK_HANDLERS = {
    [DT.DL_WAKEUP] = handleDownlink2001,
    [DT.DL_REST] = handleDownlink2002,
    [DT.DL_STATUS] = handleDownlink2003,
    [DT.DL_CONTROL] = handleDownlink2004,
    [DT.DL_SIM] = handleDownlink2005,
    [DT.DL_DEVICE_ID] = handleDownlink2006,
    [DT.DL_TF_CARD] = handleDownlink2007,
    [DT.DL_TF_FORMAT] = handleDownlink2009,
    [DT.DL_PIR_CFG] = handleDownlink2010,
    [DT.DL_PIR_STOP] = handleDownlink2011,
    [DT.DL_PIR_START] = handleDownlink2012,
    [DT.DL_ENCODE_SET] = handleDownlink2021,
    [DT.DL_ENCODE_QUERY] = handleDownlink2020,
}
registerHostQuerySetHandlers(DOWNLINK_HANDLERS)

local function handleServerMessage(topic, payload)
    log.info(L, "mqtt_rx", topic, payload)

    local ok, data = pcall(json.decode, payload)
    if not ok then
        log.error(L, "json_decode_error", data)
        return
    end

    local dataType = normalizeDataType(data)
    local handler = dataType and DOWNLINK_HANDLERS[dataType]

    if handler then
        handler(data)
    elseif dataType then
        log.warn(L, "unknown_data_type", dataType)
    else
        log.warn(L, "no_data_type")
    end

    publishAppEvent("MQTT_SERVER_DATA", data, payload)
    if callbacks.onMessage then
        callbacks.onMessage(topic, payload)
    end
end

-- ============================================================
-- MQTT 配置（t3x 经 AT+MQTTCFG 下发后覆盖 _G.MQTT_CFG）
-- ============================================================

local function normMqttCfg(cfg)
    if not cfg or not cfg.host or cfg.host == "" then
        return nil
    end
    local cid = cfg.client_id
    if cid == nil or cid == "" then
        cid = nil
    end
    return {
        host = cfg.host,
        port = tonumber(cfg.port) or 1883,
        ssl = cfg.ssl == true or cfg.ssl == 1,
        username = cfg.username or "",
        password = cfg.password or "",
        client_id = cid,
    }
end

--- 与当前 _G.MQTT_CFG 是否一致（T3x bootstrap 同参 MQTTCFG 时跳过重连）
function isSameMqttConfig(cfg)
    local nextCfg = normMqttCfg(cfg)
    local cur = normMqttCfg(_G.MQTT_CFG or {})
    if not nextCfg or not cur then
        return false
    end
    return nextCfg.host == cur.host
        and nextCfg.port == cur.port
        and nextCfg.ssl == cur.ssl
        and nextCfg.username == cur.username
        and nextCfg.password == cur.password
        and nextCfg.client_id == cur.client_id
end

function setMqttConfig(cfg)
    local normalized = normMqttCfg(cfg)
    if not normalized then
        return false
    end
    _G.MQTT_CFG = normalized
    log.info(L, "mqtt_config", _G.MQTT_CFG.host, _G.MQTT_CFG.port)
    return true
end

function getMqttConfig()
    return _G.MQTT_CFG
end

function restart()
    sys.taskInit(function()
        log.info(L, "mqtt_restart")
        stop()
        sys.wait(800)
        start()
    end)
    return true
end

-- ============================================================
-- MQTT任务
-- ============================================================

local function mqttTask()
    local gotReady, deviceId = waitForNetworkReady()
    if not gotReady then
        log.warn(L, "cellular_not_ready")
    end
    local mcfg = _G.MQTT_CFG or {}
    if not mcfg.host or mcfg.host == "" then
        log.error(L, "mqtt_no_host_config")
        return
    end
    local clientId = (mcfg.client_id and mcfg.client_id ~= "") and mcfg.client_id
        or (deviceId or getDeviceId())

    if not mqtt or not mqtt.create then
        log.error(L, "mqtt_no_login_config")
        return
    end

    log.info(L, "mqtt_start")
    log.info(L, "client_id", tostring(clientId))
    log.info(L, "mqtt_server", mcfg.host, mcfg.port)

    if socket and socket.adapter and socket.dft then
        local waitIp = 0
        while not socket.adapter(socket.dft()) and waitIp < 120 do
            log.info(L, "wait_adapter", waitIp)
            sys.waitUntil("IP_READY", 5000)
            waitIp = waitIp + 1
        end
        if not socket.adapter(socket.dft()) then
            log.warn(L, "no_adapter",
                socket.localIP and socket.localIP() or "nil")
        end
    end

    mqttClient = mqtt.create(nil, mcfg.host, mcfg.port, mcfg.ssl)
    mqttClient:auth(clientId, mcfg.username, mcfg.password)
    mqttClient:autoreconn(true, 3000)

    sys.subscribe("IP_READY", function()
        if mqttClient and not isConnected then
            log.info(L, "ip_ready")
            pcall(function() mqttClient:connect() end)
        end
    end)

    mqttClient:on(function(client, event, data, payload)
        log.info(L, "mqtt_event", event, data or "")

        if event == "conack" then
            isConnected = true
            _G.APP_RUNTIME.online_status = 1
            state.reconnect_count = 0
            log.info(L, "mqtt_connected")
            client:subscribe(getSubTopic())
            local ev = (_G.APP_EVENTS or {}).MQTT_CONNECTED or "APP_MQTT_CONNECTED"
            sys.publish(ev)
            pcall(function()
                local hu = getHostUart()
                if hu and hu.push_net_led_state then
                    hu.push_net_led_state(true)
                end
            end)
            publishConnectUplink()
            maybeAutoPublishIdentity()

        elseif event == "recv" then
            handleServerMessage(data, payload)

        elseif event == "disconnect" then
            isConnected = false
            _G.APP_RUNTIME.online_status = 0
            state.reconnect_count = (state.reconnect_count or 0) + 1
            log.warn(L, "mqtt_disconnect", "reconn", state.reconnect_count)
            publishAppEvent("MQTT_OFFLINE")
            pcall(function()
                local hu = getHostUart()
                if hu and hu.push_net_led_state then
                    hu.push_net_led_state(false)
                end
            end)
            if callbacks.onOffline then callbacks.onOffline() end

        elseif event == "error" or event == "connect" then
            if payload then
                log.warn(L, "mqtt", event, payload)
            end
        end
    end)

    mqttClient:connect()
    setupBatteryStatusReport()
    local conOk = sys.waitUntil("APP_MQTT_CONNECTED", 90000)
    if not conOk then
        log.warn(L, "connect_timeout_90s")
    end

    startStatusReportTimer()

    while true do
        local ret, topic, data, qos = sys.waitUntil("mqtt_pub", 300000)
        if ret then
            if topic == "close" then break end
            if isConnected then mqttClient:publish(topic, data, qos) end
        end
    end

    if mqttClient then mqttClient:close(); mqttClient = nil end
    isConnected = false
end

-- ============================================================
-- 上行发布（100x）
-- ============================================================

--- host_event：mqtt 类待处理（2006/2007/2009 入队 + 2011 停录待 T3x 同步 1011）
function hasPendingHostWork()
    if #pendingHostQueue > 0 then
        return true
    end
    local st = pir_ctrl.getState()
    if st.last_stop_reason == "device" and st.stop_mqtt_published ~= true then
        return true
    end
    return false
end

--- 1001 唤醒
function publishWakeup()
    publishUplink({
        suffix = "wakeup",
        dataType = DT.UL_WAKEUP,
        log = "publish_1001_wakeup",
        app_event = "MQTT_PUBLISH_WAKEUP",
    })
end

--- 1002 rest 事件（enter: opts.source=enter|reconnect；exit: opts.lowPowerMode=exit）
function publishRest(opts)
    opts = type(opts) == "table" and opts or {}
    local mode = opts.lowPowerMode or "enter"
    if mode == "exit" then
        local reason = opts.reason or "unknown"
        publishUplink({
            suffix = "rest",
            dataType = DT.UL_REST,
            fields = string.format(
                ',"lowPowerMode":"exit","reason":"%s"',
                escJson(reason)),
            log = "publish_1002_rest",
            log_args = { "exit", reason },
            app_event = "MQTT_PUBLISH_REST",
        })
        return
    end
    local rt = _G.APP_RUNTIME or {}
    local reason = opts.reason or rt.last_rest_reason or "unknown"
    local source = opts.source or "enter"
    publishUplink({
        suffix = "rest",
        dataType = DT.UL_REST,
        fields = string.format(
            ',"lowPowerMode":"enter","reason":"%s","source":"%s"',
            escJson(reason), escJson(source)),
        log = "publish_1002_rest",
        log_args = { reason, source },
        app_event = "MQTT_PUBLISH_REST",
    })
end

--- 1003 状态（电量 / USB / 充电 / 低功耗 / interval 与周期定时一致）
function publishStatus(opts)
    opts = type(opts) == "table" and opts or {}
    local snap = collectBatterySnapshot()
    local rt = _G.APP_RUNTIME or {}
    local intervalSec = getStatusReportIntervalSec()
    local usbLogical = tonumber(rt.usb_logical)
    if usbLogical == nil then
        usbLogical = snap.usb_inserted
    end
    local usbNetdev = tonumber(rt.usb_netdev) or 0
    local usbRecovery = rt.usb_recovery or "idle"
    local usbRecoveryCount = tonumber(rt.usb_recovery_count) or 0
    local usbRecoveryLastErr = rt.usb_recovery_last_err or ""
    local extra = ""
    if opts.messageId and opts.messageId ~= "" then
        extra = extra .. string.format(',"messageId":"%s"', escJson(tostring(opts.messageId)))
    end
    if opts.configRet ~= nil then
        extra = extra .. string.format(
            ',"ret":%d,"message":"%s"',
            tonumber(opts.configRet) or 0,
            escJson(opts.configMsg or "ok"))
    end
    if opts.skip_ipc_stat_refresh ~= true and ipc_sup.refreshIpcCloudStatBefore1003 then
        if coroutine.running() then
            ipc_sup.refreshIpcCloudStatBefore1003(2500)
        elseif ipc_sup.mergeHostIpcCloudCache then
            ipc_sup.mergeHostIpcCloudCache()
        end
    end
    publishUplink({
        suffix = "status",
        dataType = DT.UL_STATUS,
        warn = false,
        fields = string.format(
            ',"usbInserted":%d,"charging":%d,"remainPower":"%s","batteryMv":"%s","lowPowerMode":"%s","interval":%d,"usbLogical":%d,"usbNetdev":%d,"usbRecovery":"%s","usbRecoveryCount":%d,"usbRecoveryLastErr":"%s"%s%s',
            snap.usb_inserted,
            snap.charging,
            escJson(tostring(snap.battery_percent)),
            escJson(tostring(snap.battery_mv)),
            escJson(snap.low_power_mode),
            intervalSec,
            usbLogical,
            usbNetdev,
            escJson(usbRecovery),
            usbRecoveryCount,
            escJson(usbRecoveryLastErr),
            extra,
            ipc_sup.ipcCloudStatFields()),
        log = "publish_1003_status",
        log_args = {
            "usb", snap.usb_inserted, "chg", snap.charging,
            "bat", snap.battery_percent, "interval", intervalSec,
            "usb_recovery", usbRecovery,
        },
        on_published = function()
            lastBatteryStatusPublishSec = os.time()
            ipc_sup.afterBatteryStatusPublished()
        end,
    })
end

--- MQTT 连接成功后的首条上行：rest 发 1002+1003，常电发 1001
function publishConnectUplink()
    local rt = _G.APP_RUNTIME or {}
    if tonumber(rt.low_power_mode) == 1 then
        log.info(L, "reconnect_count_23")
        publishRest({ reason = rt.last_rest_reason or "unknown", source = "reconnect" })
        publishStatus()
    else
        publishWakeup()
    end
end

--- 1005 SIM 信息（应答 2005）
function publishSimInfo()
    local snap = collectSimSnapshot()
    publishUplink({
        suffix = "sim",
        dataType = DT.UL_SIM,
        no_conn = NC,
        fields = string.format(
            ',"imei":"%s","imsi":"%s","iccid":"%s","operator":"%s","operatorName":"%s","status":"%s","csq":"%s","rssi":"%s","rsrp":"%s","snr":"%s","simid":"%s","ip":"%s","apn":"%s"',
            escJson(snap.imei),
            escJson(snap.imsi),
            escJson(snap.iccid),
            escJson(snap.operator),
            escJson(snap.operator_name),
            escJson(snap.status),
            escJson(snap.csq),
            escJson(snap.rssi),
            escJson(snap.rsrp),
            escJson(snap.snr),
            escJson(snap.simid),
            escJson(snap.ip),
            escJson(snap.apn)),
        log = "publish_1005_sim",
        log_args = { snap.operator_name, snap.iccid },
    })
end

--- 1006 设备标识（Cat.1 IMEI + T3x GB28181 ID，应答 2006）
function publishDeviceIdentity(imei, gb28181Id, messageId)
    local deviceNo = getDeviceId()
    imei = imei or deviceNo
    gb28181Id = gb28181Id or ""
    local ret = (gb28181Id ~= "") and 0 or -1
    publishUplink({
        suffix = "identity",
        dataType = DT.UL_DEVICE_ID,
        no_conn = NC,
        fields = string.format(
            ',"imei":"%s","gb28181Id":"%s","ret":%d%s',
            escJson(imei), escJson(gb28181Id), ret, msgIdPart(messageId)),
        log = "publish_1006_identity",
        log_args = { imei, gb28181Id, ret },
    })
end

function refreshAndPublishDeviceIdentity(messageId)
    if not identityEnabled() then
        log.warn(L, "identity_missing")
        return
    end
    sys.taskInit(function()
        refreshDeviceIdentity(messageId)
    end)
end

--- 1007 TF/SD 卡状态（应答 2007）
function publishTfCardStatus(snap, messageId)
    snap = type(snap) == "table" and snap or {}
    local present = (snap.present == 1 or snap.present == true) and 1 or 0
    local totalMb = tonumber(snap.total_mb) or 0
    local usedMb = tonumber(snap.used_mb) or 0
    local freeMb = tonumber(snap.free_mb) or 0
    local ret = snap.timeout and -1 or 0
    publishUplink({
        suffix = "tfcard",
        dataType = DT.UL_TF_CARD,
        no_conn = NC,
        fields = string.format(
            ',"tfPresent":%d,"totalMb":%d,"usedMb":%d,"freeMb":%d,"ret":%d%s',
            present, totalMb, usedMb, freeMb, ret, msgIdPart(messageId)),
        log = "publish_1007_tfcard",
        log_args = { "present", present, "totalMb", totalMb, "usedMb", usedMb, "freeMb", freeMb, "ret", ret },
    })
end

function refreshAndPublishTfCardStatus(messageId)
    if not tfCardEnabled() then
        log.warn(L, "downlink_2007_fail")
        return
    end
    sys.taskInit(function()
        refreshTfCardStatus(messageId)
    end)
end

--- 1009 TF/SD 卡格式化结果（应答 2009）
function publishTfFormatResult(retCode, message, messageId, extra)
    extra = type(extra) == "table" and extra or {}
    local rebootField = ""
    if extra.reboot ~= nil then
        rebootField = string.format(',"reboot":%d', (extra.reboot == 1 or extra.reboot == true) and 1 or 0)
    end
    publishUplink({
        suffix = "tfcard_format",
        dataType = DT.UL_TF_FORMAT,
        no_conn = NC,
        fields = string.format(
            ',"ret":%s,"message":"%s"%s%s',
            tostring(retCode ~= nil and retCode or -1),
            escJson(message),
            rebootField,
            msgIdPart(messageId)),
        log = "publish_1009_tfcard_format",
        log_args = { retCode, message },
    })
end

--- §6.2：从 host_uart 缓存取 IPC 扩展状态字段 JSON 片段（实现见 ipc_supervision.lua）

--- §6.3：T3x AT+IPCALERT → 1004 action=ipc_alert（实现见 ipc_supervision.lua）
function publishIpcAlert(alertCode, alertDetail)
    return ipc_sup.publishAlert(alertCode, alertDetail)
end

--- 1004 控制回复（应答 2004；reply=1，与 OTA stage 区分）
function publishControlReply(action, retCode, message, extra)
    extra = type(extra) == "table" and extra or {}
    local enableField = ""
    if extra.enable ~= nil then
        local en = (extra.enable == 1 or extra.enable == true) and 1 or 0
        enableField = string.format(',"enable":%s', tostring(en))
    end
    local mid = extra.messageId
    publishUplink({
        suffix = "event",
        dataType = DT.UL_CONTROL,
        no_conn = NC,
        fields = string.format(
            ',"reply":1,"messageId":"%s","action":"%s","ret":%s,"message":"%s"%s',
            escJson(mid),
            escJson(action),
            tostring(retCode ~= nil and retCode or -1),
            escJson(message),
            enableField),
        log = "publish_1004_control",
        log_args = { action, retCode, message },
    })
end

local POWEROFF_NOTIFY_MSG = {
    battery = "low_battery_shutdown",
    user = "user_shutdown",
    mqtt = "ok",
    low_power = "low_power_shutdown",
}

--- 关机前通知 MQTT 后台（低电量等）：尽量连上 → 1004 off + 1003 → 再 callback
function notifyPowerOff(reason, callback)
    sys.taskInit(function()
        reason = reason or "unknown"
        local guardCfg = (_G.BATTERY_CFG and _G.BATTERY_CFG.guard) or {}
        local waitMs = tonumber(guardCfg.shutdown_mqtt_wait_ms) or 8000
        local graceMs = tonumber(guardCfg.shutdown_mqtt_grace_ms) or 800
        if not isConnected then
            log.info(L, "poweroff_mqtt_wait", waitMs, reason)
            if mqttClient and mqttClient.connect then
                pcall(function() mqttClient:connect() end)
            end
            sys.waitUntil("APP_MQTT_CONNECTED", waitMs)
        end
        if isConnected then
            if reason ~= "mqtt" then
                local msg = POWEROFF_NOTIFY_MSG[reason] or ("shutdown_" .. tostring(reason))
                publishControlReply("off", 0, msg, {})
            end
            publishStatus({ skip_ipc_stat_refresh = true, warn = false })
            log.info(L, "poweroff_mqtt_sent", reason)
            sys.wait(graceMs)
        else
            log.warn(L, "poweroff_mqtt_skip", reason)
        end
        if type(callback) == "function" then
            callback()
        end
    end)
end

--- 1004 OTA 进度/结果（stage 字段，无 reply）
local function mqttBuildVersion(ver)
    if ver == nil or ver == "" then
        return ""
    end
    ver = tostring(ver)
    if _G.validateBuildVersion then
        return _G.validateBuildVersion(ver) or ver
    end
    return ver
end

function publishOtaStatus(stage, retCode, message, extra)
    extra = type(extra) == "table" and extra or {}
    publishUplink({
        suffix = "event",
        dataType = DT.UL_CONTROL,
        no_conn = NC,
        fields = string.format(
            ',"stage":"%s","ret":%s,"message":"%s","currentVersion":"%s","targetVersion":"%s"',
            escJson(stage),
            tostring(retCode ~= nil and retCode or -1),
            escJson(message),
            escJson(mqttBuildVersion(VERSION or _G.version or "")),
            escJson(mqttBuildVersion(extra.version or extra.targetVersion or ""))),
        log = "publish_ota",
        log_args = { stage, retCode },
        app_event_fn = function()
            publishAppEvent("MQTT_OTA_STATUS", stage, retCode, message, extra)
        end,
    })
end

--- 1010 PIR 检测状态（2010 策略生效后硬件触发，或 2010 query；T3x 写盘确认时 pirStatus=t3x_active）
local function publishPirFromState(overrides)
    if not isConnected then
        log.warn(L, NC)
        return
    end
    local st = pir_ctrl.getState()
    local media = st.mediaConfig or {}
    overrides = type(overrides) == "table" and overrides or buildPirDetectExtra("detected")
    publishPirDetect({
        status = overrides.status or "1",
        pirStatus = overrides.pirStatus,
        recording = overrides.recording ~= nil and overrides.recording or (st.recording and 1 or 0),
        active = overrides.active,
        action = overrides.action or media.action or "photo",
        uploadMode = overrides.uploadMode or st.uploadMode or media.uploadMode or "auto",
        quality = overrides.quality or st.quality or media.quality or "high",
        snapshotPath = overrides.snapshotPath,
        personCount = overrides.personCount,
    })
end

--- 1010 统一入口（app / 2010 配置等）
function publishPirEvent(overrides)
    publishPirFromState(overrides)
end

function publishPirDetect(extra)
    extra = type(extra) == "table" and extra or buildPirDetectExtra("detected")
    local rec = (extra.recording == 1 or extra.recording == true) and 1 or 0
    local activeJson = ""
    if extra.active ~= nil then
        local active = (extra.active == 1 or extra.active == true) and 1 or 0
        activeJson = string.format(',"active":%d', active)
    end
    local pathJson = ""
    if extra.snapshotPath and extra.snapshotPath ~= "" then
        pathJson = string.format(',"snapshotPath":"%s"', escJson(extra.snapshotPath))
    end
    local personJson = ""
    if extra.personCount ~= nil then
        personJson = string.format(',"personCount":%d', tonumber(extra.personCount) or 0)
    end
    publishUplink({
        suffix = "pir",
        dataType = DT.UL_PIR_DETECT,
        no_conn = NC,
        fields = string.format(
            ',"status":"%s","pirStatus":"%s","recording":%s,"action":"%s","uploadMode":"%s","quality":"%s"%s%s%s',
            escJson(extra.status or "detected"),
            escJson(extra.pirStatus or extra.status or "detected"),
            tostring(rec),
            escJson(extra.action),
            escJson(extra.uploadMode),
            escJson(extra.quality),
            activeJson,
            pathJson,
            personJson),
        log = "publish_1010_pir",
        log_args = { extra.pirStatus or extra.status },
    })
end

--- T3x JPEG 已写入 SD → 1010（pirStatus=snapshot_saved，附 snapshotPath，不传图内容）
function publishPirSnapshotDone(path)
    publishPirFromState({
        pirStatus = "snapshot_saved",
        action = nil,
        snapshotPath = path,
    })
end

--- T3x 首个 I 帧写盘确认 → 1010（pirStatus=t3x_active, active=1）
function publishPirRecordActive()
    publishPirFromState({
        pirStatus = "t3x_active",
        recording = 1,
        active = 1,
        action = "video",
    })
end

--- 1012 PIR 录像开始（2012 平台开 TF 卡录受理，source=4g 表调度侧非上云）
function publishPirRecordStart(action, uploadMode, quality, opts)
    if not isConnected then
        log.warn(L, NC)
        return
    end
    opts = type(opts) == "table" and opts or {}
    local source = opts.source or "4g"
    local mid = opts.messageId
    local midField = mid and string.format(',"messageId":"%s"', escJson(mid)) or ""
    publishUplink({
        suffix = "event",
        dataType = DT.UL_PIR_START,
        no_conn = NC,
        fields = string.format(
            ',"reason":"device","source":"%s","action":"%s","uploadMode":"%s","quality":"%s","recording":1%s',
            escJson(source), escJson(action or "video"),
            escJson(uploadMode or "auto"), escJson(quality or "high"), midField),
        log = "publish_1012_pir_start",
        log_args = { action or "video", source },
    })
end

--- 1011 PIR 录像停止（4G 定时/2011 设备停录，或 T3x AT+RECORD=0）
function publishPirRecordStop(reason, uploadMode, quality, opts)
    if not isConnected then
        log.warn(L, NC)
        return
    end
    if pir_ctrl.canPublishStopMqtt and not pir_ctrl.canPublishStopMqtt() then
        opts = type(opts) == "table" and opts or {}
        log.info(L, "record_stop_duplicate", reason, opts.source or "4g")
        return
    end
    if pir_ctrl.markStopMqttPublished then
        pir_ctrl.markStopMqttPublished()
    end
    opts = type(opts) == "table" and opts or {}
    local source = opts.source or "4g"
    local mid = opts.messageId
    if not mid and pir_ctrl.getCloudStopMessageId then
        mid = pir_ctrl.getCloudStopMessageId()
    end
    local midField = ""
    if mid and mid ~= "" then
        midField = string.format(',"messageId":"%s"', escJson(tostring(mid)))
    end
    publishUplink({
        suffix = "event",
        dataType = DT.UL_PIR_STOP,
        no_conn = NC,
        fields = string.format(
            ',"reason":"%s","source":"%s","uploadMode":"%s","quality":"%s"%s',
            escJson(reason), escJson(source), escJson(uploadMode), escJson(quality), midField),
        log = "publish_1011_record_stop",
        log_args = { reason, source },
    })
end

--- T3x AT+RECORD=0 → 1011（reason 为 T3x 原值，source=t3x）
function publishT3xRecordStop(reason, uploadMode, quality)
    local st = pir_ctrl.getState()
    publishPirRecordStop(
        reason or "unknown",
        uploadMode or st.uploadMode or "auto",
        quality or st.quality or "high",
        { source = "t3x" }
    )
end

function publish(topic, data, qos)
    sys.publish("mqtt_pub", topic, data, qos or 1)
end

--- T3x 经 AT+MQTTPUB=<suffix>;<json> 委托 4G 发布；suffix 拼在 getPubTopic() 后
function publishRaw(topicSuffix, payload, qos)
    if not isConnected or not mqttClient then
        log.warn(L, "not_connected_raw", topicSuffix)
        return false
    end
    if not topicSuffix or topicSuffix == "" or not payload or payload == "" then
        return false
    end
    local topic
    if topicSuffix:sub(1, 1) == "/" then
        topic = topicSuffix
    else
        topic = getPubTopic() .. topicSuffix
    end
    mqttClient:publish(topic, payload, qos or 1)
    log.info(L, "mqtt_publish_raw", topic, #payload)
    return true
end

function start(options)
    if started then log.warn(L, "already_started"); return false end
    if options then
        if options.onOffline then callbacks.onOffline = options.onOffline end
        if options.onMessage then callbacks.onMessage = options.onMessage end
    end

    log.info(L, "net_start")
    setupIdentityAutoPublish()
    if not pendingHostDrainHooked then
        pendingHostDrainHooked = true
        local evt = (_G.APP_EVENTS and _G.APP_EVENTS.HOST_UART_FIRST_AT) or "APP_HOST_UART_FIRST_AT"
        sys.subscribe(evt, function()
            sys.taskInit(function()
                sys.wait(500)
                drainPendingHostWork()
            end)
        end)
    end
    local usbRecEvt = (_G.APP_EVENTS or {}).MQTT_USB_RECOVERY_CHANGED or "mqtt_usb_recovery_changed"
    sys.subscribe(usbRecEvt, function()
        if isConnected then
            sys.taskInit(function()
                publishStatus()
            end)
        end
    end)
    bootstrapNetwork()
    sys.taskInit(mqttTask)
    started = true
    return true
end

--- 关停 MQTT 与发布任务（t3x 烧录前由 app 调用）
function stop()
    if not started and not mqttClient then
        return false
    end
    log.info(L, "mqtt_stop")
    local rt = _G.APP_RUNTIME or {}
    if isConnected and mqttClient and publishRest and tonumber(rt.low_power_mode) == 1 then
        pcall(publishRest, {
            reason = rt.last_rest_reason or "unknown",
            source = "reconnect",
        })
        sys.wait(300)
    end
    if mqttClient then
        pcall(function()
            mqttClient:autoreconn(false)
        end)
        sys.publish("mqtt_pub", "close", "", 0)
        sys.wait(500)
        pcall(function()
            mqttClient:close()
        end)
        mqttClient = nil
    end
    isConnected = false
    _G.APP_RUNTIME.online_status = 0
    started = false
    log.info(L, "mqtt_off")
    return true
end

function getState()
    return {
        started = started,
        connected = isConnected,
        client = mqttClient ~= nil,
        last_event = state.last_event,
        reconnect_count = state.reconnect_count,
        last_publish_topic = state.last_publish_topic,
    }
end

loadIvCfg()

ipc_sup.bind({
    publish_uplink = publishUplink,
    esc_json = escJson,
    dt_ul_control = DT.UL_CONTROL,
    nc = NC,
    publish_t3x_record_stop = publishT3xRecordStop,
})

return _M
