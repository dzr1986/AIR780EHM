-- ================================================================
-- Filename : host_uart.lua
-- Module   : T3x AT 业务：UART 行协议解析、AT 表驱动、HOSTEVT/PIRSTAT、IPC 查询、USB 策略通知
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local uart_bridge = require "uart_bridge"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local LOG_TAG = "host_uart"
local CRLF = "\r\n"
local RSP_ERROR = CRLF .. "ERROR" .. CRLF
local SYS_EVT = {
    GB28181_ACK = "HOST_UART_GB28181_ACK",
    TFCARD_ACK = "HOST_UART_TFCARD_ACK",
    RECORD_ACK = "HOST_UART_RECORD_ACK",
    RECORDTIME_ACK = "HOST_UART_RECORDTIME_ACK",
    RECORDTIME_SET = "HOST_UART_RECORDTIME_SET_DONE",
    IPCSTATUS_ACK = "HOST_UART_IPCSTATUS_ACK",
    IPCSTAT_ACK = "HOST_UART_IPCSTAT_ACK",
    IPCPOWEROFF_ACK = "HOST_UART_IPCPOWEROFF_ACK",
    VENC_QUERY = "HOST_UART_VENC_QUERY_DONE",
    VENC_SET = "HOST_UART_VENC_SET_DONE",
    AUDIO_QUERY = "HOST_UART_AUDIO_QUERY_DONE",
    AUDIO_SET = "HOST_UART_AUDIO_SET_DONE",
    FRAMERATE_QUERY = "HOST_UART_FRAMERATE_QUERY_DONE",
    FRAMERATE_SET = "HOST_UART_FRAMERATE_SET_DONE",
    RECORDCTRL_SET = "HOST_UART_RECORDCTRL_SET_DONE",
    UPLOADVIDEO_SET = "HOST_UART_UPLOADVIDEO_SET_DONE",
    WLED_ACK = "HOST_UART_WLED_ACK",
    TFFORMAT_ACK = "HOST_UART_TFFORMAT_ACK",
    PERSONDET_ACK = "HOST_UART_PERSONDET_ACK",
    PERSONDET_SET = "HOST_UART_PERSONDET_SET_DONE",
    MIC_QUERY = "HOST_UART_MIC_QUERY_DONE",
    MIC_SET = "HOST_UART_MIC_SET_DONE",
    SOFTPHOTO_QUERY = "HOST_UART_SOFTPHOTO_QUERY_DONE",
    SOFTPHOTO_SET = "HOST_UART_SOFTPHOTO_SET_DONE",
}
local run_host_query
local host_query
local host_set
-- 动态模块守卫：模块或函数缺失时返回 nil
local function mod_call(name, fn, ...)
    local m = loader.load(name)
    if m and m[fn] then
        return m[fn](...)
    end
end

local function noop_idle()
    return "idle"
end

local function noop_false()
    return false
end
_M.EVT = {
    SERVER_DATA = 0,
    CONNECT_FAIL = 1,
    REGISTER_FAIL = 2,
    REGISTER_TIMEOUT = 3,
}
local hooks = {}
local state = {
    pending_sid = 0,
    pending_evt = -1,
    pending_valid = false,
    passthrough = false,
    channel = nil,
    last_command = nil,
    hex_report = false,
    host_at_ready = false,
    first_host_at = nil,
    host_ready_seen = false,
    host_gb28181_id = nil,
    p2p_uid = nil,
    p2p_product = nil,
    gb28181_password = nil,
    gb28181_imei = nil,
    gb28181_query_busy = false,
    gb28181_refresh_scheduled = false,
    host_tf_card = nil,
    tf_card_query_busy = false,
    host_record = nil,
    record_query_busy = false,
    host_record_time = nil,
    recordtime_query_busy = false,
    recordtime_set_busy = false,
    host_ipc_status = nil,
    host_ipc_cloud_stat = nil,
    ipc_status_query_busy = false,
    ipc_cloud_stat_query_busy = false,
    ipc_poweroff_busy = false,
    encode_venc_rows = nil,
    encode_audio_rows = nil,
    encode_query_busy = false,
    encode_set_busy = false,
    t3x_rec_active = 0,
    t3x_last_reason = "idle",
    tfcard_format_busy = false,
    ipc_uart_miss_streak = 0,
    uart_recovery_busy = false,
    uart_recovery_attempts = 0,
    uart_recovery_last_sec = 0,
    host_push_quiet_until = 0,
    uart_txn_busy = false,
}
local uartTxnOwnr = nil
local uartTxnDpth = 0
local started = false
local t3xModule = nil
local normalize_ipc_cloud_stat
local parse_ipcstat_line
local parse_tfcard_line
local note_uart_link_ok
local HOST_PUSH_QUIET_MS = 300
local host_now_ms = utils.nowMs
local function t3xSectOff()
    return not loader.enabled("t3x_app") or not loader.enabled("uart_bridge")
end

local function noteHostPush()
    state.host_push_quiet_until = host_now_ms() + HOST_PUSH_QUIET_MS
end

local function isHostInbn()
    local until_ms = tonumber(state.host_push_quiet_until) or 0
    if until_ms <= 0 then
        return false
    end
    return host_now_ms() < until_ms
end

local function waitHostQt(timeoutMs)
    timeoutMs = tonumber(timeoutMs) or 2000
    if timeoutMs < 0 then
        timeoutMs = 0
    end
    local deadline = host_now_ms() + timeoutMs
    while isHostInbn() do
        local now = host_now_ms()
        if now >= deadline then
            return false
        end
        local remain = (tonumber(state.host_push_quiet_until) or 0) - now + 20
        if remain < 20 then
            remain = 20
        end
        if now + remain > deadline then
            remain = deadline - now
        end
        if remain <= 0 then
            return false
        end
        sys.wait(remain)
    end
    return true
end

-- @desc AT 命令分发处理：uartTxnAcqu
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartTxnAcqu(timeoutMs)
    timeoutMs = tonumber(timeoutMs) or 8000
    local me = coroutine.running()
    if not me then
        return false
    end
    if uartTxnOwnr == me then
        uartTxnDpth = uartTxnDpth + 1
        return true
    end
    local deadline = host_now_ms() + timeoutMs
    while state.uart_txn_busy do
        local now = host_now_ms()
        if now >= deadline then
            return false
        end
        local remain = deadline - now
        if remain > 80 then
            remain = 80
        end
        if remain < 20 then
            remain = 20
        end
        sys.wait(remain)
    end
    state.uart_txn_busy = true
    uartTxnOwnr = me
    uartTxnDpth = 1
    return true
end

-- @desc AT 命令分发处理：uartTxnRele
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartTxnRele()
    local me = coroutine.running()
    if uartTxnOwnr ~= me then
        return
    end
    uartTxnDpth = uartTxnDpth - 1
    if uartTxnDpth <= 0 then
        uartTxnDpth = 0
        uartTxnOwnr = nil
        state.uart_txn_busy = false
    end
end

local function ok_tail()
    return CRLF .. "OK" .. CRLF
end

local function rsp_only(tag, body)
    return CRLF .. "+" .. tag .. ":" .. body .. CRLF
end

local function rsp_body(tag, body)
    return rsp_only(tag, body) .. ok_tail()
end

local function rsp_fmt(tag, fmt, ...)
    return string.format(CRLF .. "+" .. tag .. ":" .. fmt .. CRLF, ...) .. ok_tail()
end

local function rsp_line(tag, ok)
    return rsp_only(tag, ok and "OK" or "ERROR")
end

local function rspLineOk(tag)
    return rsp_line(tag, true) .. ok_tail()
end

local function encode_hex(data)
    if not data or #data == 0 then
        return ""
    end
    if data.toHex then
        return data:toHex()
    end
    if string.toHex then
        return string.toHex(data)
    end
    local out = {}
    for i = 1, #data do
        out[i] = string.format("%02X", string.byte(data, i))
    end
    return table.concat(out)
end

local function decode_hex(hex)
    hex = hex and hex:gsub("[%s]", "") or ""
    if hex == "" or (#hex % 2) ~= 0 then
        return nil
    end
    if string.fromHex then
        return string.fromHex(hex)
    end
    local parts = {}
    for i = 1, #hex, 2 do
        local n = tonumber(hex:sub(i, i + 1), 16)
        if n == nil then
            return nil
        end
        parts[#parts + 1] = string.char(n)
    end
    return table.concat(parts)
end

local function host_usb_cfg()
    return _G.HOST_USB_CFG or {}
end
local usbChrgCch
local function usbChrgMod()
    if usbChrgCch == nil then
        local mod = loader.load("usb_charge")
        usbChrgCch = mod or false
    end
    return usbChrgCch ~= false and usbChrgCch or nil
end

local function isUsbInse()
    local uc = usbChrgMod()
    if uc and uc.isUsbInserted then
        return uc.isUsbInserted()
    end
    local rt = _G.APP_RUNTIME or {}
    return tonumber(rt.power_status) == 1
end

local function usbBlocHost()
    local uc = usbChrgMod()
    if uc and uc.blocksHostIdle then
        return uc.blocksHostIdle()
    end
    return isUsbInse()
end

local function getCnfgSnps()
    local meta = _G.APP_META or {}
    local rt = _G.APP_RUNTIME or {}
    local tcp_extra = mod_call("low_power_wakeup", "appCfgFields") or ""
    local workmode = mod_call("runtime_power", "getWorkMode") or "person_detect"
    return {
        version = (_G.PROJECT or "780EHM") .. "_" .. (_G.VERSION or "2034.001.000"),
        online = rt.online_status or 0,
        power = rt.power_status or 0,
        lowpower = rt.low_power_mode or 0,
        battery = rt.battery_percent or "--",
        vbat = rt.battery_mv or "--",
        interval = rt.low_power_interval_sec or 0,
        devicemodel = meta.device_model or "",
        wled = rt.wled_on or 0,
        workmode = workmode,
        tcp_extra = tcp_extra,
    }
end

local function prsSrvcArgs(args)
    if args == nil or args == "" then
        return nil
    end
    local parts = {}
    for p in args:gmatch("[^,]+") do
        parts[#parts + 1] = p
    end
    if #parts < 10 then
        return nil
    end
    return {
        sid = tonumber(parts[1]) or 1,
        server_ip = parts[2],
        server_port = tonumber(parts[3]) or 0,
        login_hex = parts[4],
        login_rsp_hex = parts[5],
        heartbeat_hex = parts[6],
        heartbeat_sec = tonumber(parts[7]) or 60,
        wake_hex = parts[8],
        critical_flag = tonumber(parts[9]) or 0,
        run_type = tonumber(parts[10]) or 0,
    }
end

local function setPndnWake(sid, evt)
    state.pending_sid = tonumber(sid) or 1
    state.pending_evt = tonumber(evt) or 0
    state.pending_valid = true
end

function getHostEvtPending()
    if state.pending_valid then
        return true, state.pending_sid, state.pending_evt
    end
    return false, 0, -1
end

local function echoRxHexIf(data)
    if not state.hex_report or not hooks.uart_write or not data then
        return
    end
    hooks.uart_write(CRLF .. "+RXHEX:" .. encode_hex(data) .. CRLF)
end

-- @desc AT 命令分发处理：uart_at_ack
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_at_ack(_cmd)
    return ok_tail()
end

local function pirFldStr(pirBody, key, default)
    if not pirBody or pirBody == "" then
        return default
    end
    return pirBody:match(key .. "=([^,]+)") or default
end

local function pirFldInt(pirBody, key, default)
    local v = pirFldStr(pirBody, key, nil)
    return v and tonumber(v) or default
end

local function bldHstvMd(pirBody)
    if not pirBody or pirBody == "" then
        return ",recording=0,action=video,max_sec=60,last_stop=none"
    end
    return string.format(",recording=%d,action=%s,max_sec=%d,last_stop=%s,last=%s",
        pirFldInt(pirBody, "recording", 0),
        pirFldStr(pirBody, "action", "video"),
        pirFldInt(pirBody, "max_sec", 60),
        pirFldStr(pirBody, "last_stop", "none"),
        pirFldStr(pirBody, "last", "none"))
end

local function bldPirWake1()
    local pirBody = mod_call("pir_ctrl", "buildAtBod") or ""
    local wakeValid, wakeSid, wakeEvt = getHostEvtPending()
    local sum
    local he
    local heMod = loader.load("host_event")
    if heMod and heMod.summarize then
        he = heMod
        sum = heMod.summarize(pirBody, wakeValid, wakeSid, wakeEvt)
    end
    return pirBody, wakeValid, wakeSid, wakeEvt, sum, he
end

local function bldPirWake(hostevt)
    local pirBody, wakeValid, wakeSid, wakeEvt, sum, he = bldPirWake1()
    local media = bldHstvMd(pirBody)
    if hostevt then
        if sum then
            return string.format("has_event=%d,pending=%s,types=%s,sid=%d,evt=%d%s",
                sum.has_event, sum.pending, sum.types, sum.sid or 0, sum.evt or -1, media)
        end
        return "has_event=0,pending=none,types=,sid=0,evt=-1" .. media
    end
    local body = pirBody
    if wakeValid then
        body = body .. string.format(",pending_wake=1,pending_sid=%d,pending_evt=%d", wakeSid, wakeEvt)
    else
        body = body .. ",pending_wake=0"
    end
    if he and he.isEnabled and he.isEnabled() and sum then
        body = body .. string.format(",has_work=%d,work_types=%s,work_pending=%s,work_sid=%d,work_evt=%d",
            sum.has_event, sum.types, sum.pending, sum.sid or 0, sum.evt or -1)
    else
        body = body .. ",has_work=0,work_types=,work_pending=none,work_sid=0,work_evt=-1"
    end
    return body
end

function buildHostEvtBody()
    return bldPirWake(true)
end

-- @desc AT 命令分发处理：uart_hostevt_query
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartHstvQry(_cmd)
    return rsp_body("HOSTEVT", bldPirWake(true))
end

-- @desc AT 命令分发处理：uart_hostevt_clr
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartHstvClr(_cmd)
    state.pending_valid = false
    state.pending_evt = -1
    mod_call("pir_ctrl", "clearConsumableMarkers")
    return rsp_body("HOSTEVTCLR", "OK")
end

-- @desc AT 命令分发处理：uart_time_query
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartTimeQry(_cmd)
    local minTs = (_G.TIME_SYNC_CFG and _G.TIME_SYNC_CFG.min_valid_unix) or utils.MIN_VALID_UNIX
    local t = os.time()
    if t < minTs then
        return rsp_body("TIME", "0")
    end
    return rsp_fmt("TIME", "%d", t)
end

function getDeviceImei()
    return mod_call("device_id", "getImei")
end

-- @desc AT 命令分发处理：uart_imei
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_imei(_cmd)
    local imei = getDeviceImei()
    if not imei then
        return RSP_ERROR
    end
    return rsp_fmt("IMEI", "%s", imei)
end

local escIpcFld = utils.escKv

local function isVldP2P(product)
    return type(product) == "string"
        and #product >= 1 and #product <= 31
        and product:match("^[0-9]+$") ~= nil
end

local function isVldGb28181(id)
    return type(id) == "string"
        and #id >= 10 and #id <= 20
        and id:match("^[0-9]+$") ~= nil
end

local function prsGb28181(body)
    if not body or body == "" then
        return nil
    end
    local device_id, password, imei = body:match("^([^,]+),([^,]+),(%d+)$")
    if device_id and password and imei then
        return device_id, password, imei
    end
    device_id, password = body:match("^([^,]+),(.+)$")
    if device_id and password then
        return device_id, password, nil
    end
    return nil
end

-- @desc AT 命令分发处理：uart_p2pcfg
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_p2pcfg(cmd)
    local uid, product = cmd:match("^AT%+P2PCFG=([^,]+),([^,]+)$")
    if not uid or not product then
        return RSP_ERROR
    end
    if not (type(uid) == "string" and #uid == 8 and uid:match("^[A-Za-z0-9]+$") ~= nil) or not isVldP2P(product) then
        return RSP_ERROR
    end
    state.p2p_uid = uid
    state.p2p_product = product
    local E = _G.APP_EVENTS or {}
    sys.publish(E.HOST_NET_ID_P2P or "APP_HOST_NET_ID_P2P", uid, product)
    return rsp_fmt(
        "P2PCFG", "OK,uid=%s,product=%s",
        escIpcFld(uid), escIpcFld(product)
    )
end

-- @desc AT 命令分发处理：uart_gb28181cfg
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartGb28181(cmd)
    local body = cmd:match("^AT%+GB28181CFG=(.+)$")
    local device_id, password, imei = prsGb28181(body)
    if not device_id or not password then
        return RSP_ERROR
    end
    if not isVldGb28181(device_id)
            or not (type(password) == "string" and #password >= 1 and #password <= 63
            and password:match("^[%w%p]+$") ~= nil) then
        return RSP_ERROR
    end
    if imei and imei ~= "" and not (type(imei) == "string" and #imei == 15 and imei:match("^[0-9]+$") ~= nil) then
        return RSP_ERROR
    end
    state.host_gb28181_id = device_id
    state.gb28181_password = password
    state.gb28181_imei = (imei and imei ~= "") and imei or nil
    local E = _G.APP_EVENTS or {}
    sys.publish(
        E.HOST_NET_ID_GB28181 or "APP_HOST_NET_ID_GB28181",
        device_id, password, state.gb28181_imei
    )
    return rsp_fmt(
        "GB28181CFG", "OK,id=%s",
        escIpcFld(device_id)
    )
end

local function scheGb28Ref()
    if state.host_gb28181_id and state.host_gb28181_id ~= "" then
        return
    end
    if state.gb28181_refresh_scheduled then
        return
    end
    state.gb28181_refresh_scheduled = true
    sys.taskInit(function()
        queryHostGb28181(identity_cfg().query_timeout_ms)
        state.gb28181_refresh_scheduled = false
    end)
end

-- @desc AT 命令分发处理：uart_ipcinfo_query
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartIpcnQry(_cmd)
    local imei = getDeviceImei() or ""
    local gb28181Id = state.host_gb28181_id or ""
    scheGb28Ref()
    local body = string.format(
        "imei=%s,gb28181Id=%s",
        escIpcFld(imei),
        escIpcFld(gb28181Id)
    )
    local cfg = identity_cfg()
    if cfg.publish_on_ipcinfo_query == true then
        sys.taskInit(function()
            local net = loader.load("net_mqtt")
            if net and net.refPubDeviceId then
                if gb28181Id == "" then
                    queryHostGb28181(cfg.query_timeout_ms)
                end
                net.refPubDeviceId(nil)
            end
        end)
    end
    return rsp_body("IPCINFO", body)
end

-- @desc AT 命令分发处理：uart_mqttpub
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_mqttpub(cmd)
    local suffix, body = cmd:match("^AT%+MQTTPUB=([^;]+);(.+)$")
    if not suffix or not body or body == "" then
        return rsp_line("MQTTPUB", false)
    end
    local net = loader.load("net_mqtt")
    if not net or not net.publishRaw then
        return rsp_line("MQTTPUB", false)
    end
    if net.publishRaw(suffix, body, 1) then
        return rsp_line("MQTTPUB", true)
    end
    return rsp_line("MQTTPUB", false)
end

local function prsMqttBody(body)
    if not body or body == "" then
        return nil
    end
    local parts = {}
    local start = 1
    for i = 1, 5 do
        local pos = body:find(";", start, true)
        if not pos then
            return nil
        end
        parts[i] = body:sub(start, pos - 1)
        start = pos + 1
    end
    parts[6] = body:sub(start)
    if parts[1] == "" then
        return nil
    end
    return {
        host = parts[1],
        port = tonumber(parts[2]) or 1883,
        ssl = (tonumber(parts[3]) or 0) == 1,
        username = parts[4] or "",
        password = parts[5] or "",
        client_id = parts[6] or "",
    }
end

-- @desc AT 命令分发处理：uart_mqttcfg
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_mqttcfg(cmd)
    local cfg = prsMqttBody(cmd:match("^AT%+MQTTCFG=(.+)$"))
    if not cfg then
        return rsp_line("mqtt_config_uart", false)
    end
    if hooks.on_mqtt_cfg then
        hooks.on_mqtt_cfg(cfg)
    end
    return rsp_line("mqtt_config_uart", true) .. ok_tail()
end

-- @desc AT 命令分发处理：uart_servcreate
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartSrvcrt(cmd)
    local lpw = loader.load("low_power_wakeup")
    if lpw and lpw.allowTcpChannel and not lpw.allowTcpChannel() then
        return rsp_body("server_channel_add", "DISABLED")
    end
    local ch = prsSrvcArgs(cmd:match("^AT%+SERVCREATE=(.+)$"))
    if not ch then
        return RSP_ERROR
    end
    state.channel = ch
    if hooks.on_servcreate then
        hooks.on_servcreate(ch)
    end
    return rsp_fmt("SERVCREATE", "%d,OK", ch.sid)
end

-- @desc AT 命令分发处理：uart_servclose
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartSrvc(cmd)
    local sid = tonumber(cmd:match("^AT%+SERVCLOSE=(%d+)$"))
    if not sid then
        return RSP_ERROR
    end
    local lpw = loader.load("low_power_wakeup")
    if lpw and lpw.allowTcpChannel and not lpw.allowTcpChannel() then
        state.channel = nil
        return rsp_body("server_channel_remove", "DISABLED")
    end
    if hooks.on_servclose then
        hooks.on_servclose(sid)
    elseif lpw and lpw.closeTcpChannel then
        lpw.closeTcpChannel(sid)
    end
    state.channel = nil
    return rsp_fmt("SERVCLOSE", "%d", sid)
end

-- @desc AT 命令分发处理：uart_getcfg
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_getcfg(_cmd)
    local s = getCnfgSnps()
    return rsp_fmt(
        "GETCFG", "version=%s,online=%d,power=%d,lowpower=%d,battery=%s,vbat=%s,interval=%d,devicemodel=%s,wled=%d,workmode=%s%s",
        s.version, s.online, s.power, s.lowpower, s.battery, s.vbat, s.interval, s.devicemodel, s.wled or 0,
        s.workmode or "person_detect",
        s.tcp_extra or ""
    )
end

-- @desc AT 命令分发处理：uart_pirstat_query
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartPrstQry(_cmd)
    return rsp_body("PIRSTAT", bldPirWake(false))
end

-- @desc AT 命令分发处理：uart_hostidle
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartHstd(cmd)
    local fc = _G.FEATURE_CFG
    if fc and fc.host_evt == false then
        return rsp_only("HOSTIDLE", "NOT_SUPPORTED")
    end
    local heCfg = _G.HOST_EVT_CFG or {}
    if heCfg.allow_host_idle_sleep == false then
        return rsp_only("HOSTIDLE", "DISABLED")
    end
    if (cmd == "AT+HOSTIDLE=1" or cmd == "AT+HOSTIDLE=0") and usbBlocHost() then
        if cmd == "AT+HOSTIDLE=0" then
            return rsp_body("HOSTIDLE", "OK")
        end
        return rsp_only("HOSTIDLE", "USB")
    end
    local hostBody = bldPirWake(true)
    if hostBody:match("has_event=1") then
        return rsp_only("HOSTIDLE", "BUSY")
    end
    if cmd == "AT+HOSTIDLE?" then
        local rt = _G.APP_RUNTIME or {}
        local lp = tonumber(rt.low_power_mode) or 0
        local usb = isUsbInse() and 1 or 0
        local allow = 0
        if not usbBlocHost() and mod_call("battery_guard", "shdHostSleep") == true then
            allow = 1
        end
        return rsp_fmt(
            "HOSTIDLE", "lowpower=%d,usb=%d,host_idle_allow=%d",
            lp, usb, allow) .. ok_tail()
    end
    if cmd == "AT+HOSTIDLE=1" or cmd == "AT+HOSTIDLE=0" then
        if cmd == "AT+HOSTIDLE=0" then
            return rsp_body("HOSTIDLE", "OK")
        end
        if mod_call("battery_guard", "shdHostSleep") == false
            or mod_call("battery_guard", "canHostSleep") == false then
            return rsp_only("HOSTIDLE", "BUSY")
        end
        local t3x = loader.load("t3x_ctrl")
        if t3x and t3x.enterSleep then
            local lp = _G.LOW_POWER_CFG or {}
            sys.taskInit(function()
                t3x.enterSleep({
                    modemHibernate = lp.modem_hibernate == true,
                    reason = "host_idle",
                    skip_pending_work_check = true,
                })
            end)
            return rsp_body("HOSTIDLE", "OK")
        end
        return rsp_line("HOSTIDLE", false)
    end
    return nil
end

-- @desc AT 命令分发处理：uart_pirclr
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_pirclr(_cmd)
    local pir = loader.load("pir_ctrl")
    if pir and pir.resetCounters then
        pir.resetCounters()
        return rspLineOk("PIRCLR")
    end
    return rsp_line("PIRCLR", false)
end

-- @desc AT 命令分发处理：uart_record_notify
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartRcrd(cmd)
    local arg = cmd:match("^AT%+RECORD=(.+)$")
    if not arg or arg == "" then
        return RSP_ERROR
    end
    if arg == "1" or arg:match("^1,") then
        local reason = arg:match("reason=([^,]+)") or "active"
        state.t3x_rec_active = 1
        state.t3x_last_reason = reason
        if pchCloudStat then
            pchCloudStat({ recordingT3x = 1 })
        end
        -- 全天 overlay 不是开停录，不发 1012
        if reason == "allday_person" then
            return rsp_body("RECORD", "1,active=1")
        end
        local E = _G.APP_EVENTS or {}
        sys.publish(E.T3X_RECORD_ACTIVE or "APP_T3X_RECORD_ACTIVE")
        return rsp_body("RECORD", "1,active=1")
    end
    local reason = arg:match("^0,reason=(.+)$") or "unknown"
    if reason == "allday_person_done" then
        -- 全天写盘未停，忽略 overlay 结束
        state.t3x_rec_active = 1
        state.t3x_last_reason = reason
        return rsp_fmt("RECORD", "0,reason=%s,ignored=1", reason)
    end
    state.t3x_rec_active = 0
    state.t3x_last_reason = reason
    if pchCloudStat then
        pchCloudStat({ recordingT3x = 0 })
    end
    local uploadMode, quality = mod_call("pir_ctrl", "syncStopT3x", reason)
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_RECORD_STOP or "APP_T3X_RECORD_STOP", reason, uploadMode, quality)
    return rsp_fmt("RECORD", "0,reason=%s", reason)
end

-- @desc AT 命令分发处理：uart_person_cnt_notify
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartPrsnCnt(cmd)
    local cnt = cmd:match("^AT%+PERSONCNT=(%d+)$")
    if not cnt then
        return RSP_ERROR
    end
    local n = tonumber(cnt) or 0
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_PERSON_CNT or "APP_T3X_PERSON_CNT", n)
    -- 人数不上 MQTT；app.lua 对 T3X_PERSON_CNT 不再 publishPirToMqtt
    return rsp_fmt("PERSONCNT", "ok,count=%d", n)
end

-- @desc AT 命令分发处理：uart_pir_media_notify
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartPirMd(cmd)
    local action = cmd:match("^AT%+PIRMEDIA=(.+)$")
    if not action or action == "" then
        return RSP_ERROR
    end
    mod_call("pir_ctrl", "applEffMedia", action)
    return rsp_fmt("PIRMEDIA", "ok,action=%s", action)
end

-- @desc AT 命令分发处理：uart_ipc_alert_notify
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartIpcAlrt(cmd)
    local code, detail = cmd:match("^AT%+IPCALERT=([^,]+),?(.*)$")
    if not code or code == "" then
        return RSP_ERROR
    end
    detail = detail or ""
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_IPC_ALERT or "APP_T3X_IPC_ALERT", code, detail)
    return rsp_fmt("IPCALERT", "OK,code=%s", code)
end

-- @desc AT 命令分发处理：uart_uploadneed_notify
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartUpld(cmd)
    local arg = cmd:match("^AT%+UPLOADNEED=(.+)$")
    if not arg or arg == "" then
        return RSP_ERROR
    end
    local need = tonumber(arg:match("^(%d+)")) or 1
    local reason = arg:match("reason=([^,]+)") or "record_done"
    local path = arg:match("path=([^,]+)") or ""
    local pirStatus = arg:match("pirStatus=([^,]+)") or "t3x_active"
    mod_call("net_mqtt", "publishUploadVideoNeed", {
        needUpload = need,
        action = "upload_video",
        reason = reason,
        recordPath = path,
        pirStatus = pirStatus,
        source = "t3x",
    })
    return rsp_fmt("UPLOADNEED", "ok,need=%d", need)
end

-- @desc AT 命令分发处理：uart_uploadresult_notify
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartUpldrs(cmd)
    local arg = cmd:match("^AT%+UPLOADRESULT=(.+)$")
    if not arg or arg == "" then
        return RSP_ERROR
    end

    local function kv(key)
        local v = arg:match(key .. "=([^,]+)")
        return v and v:gsub("^%s+", ""):gsub("%s+$", "") or ""
    end
    local ret = tonumber(kv("ret")) or -1
    local vtype = tonumber(kv("type")) or 1
    local startTs = tonumber(kv("start")) or 0
    local endTs = tonumber(kv("end")) or 0
    mod_call("net_mqtt", "publishUploadVideoComplete", ret, kv("msgId"), {
        videoType = vtype,
        beginTs = startTs,
        endTs = endTs,
        uploadTs = kv("uploadTs"),
        fileName = kv("file"),
        httpPath = kv("httpPath"),
        reason = kv("reason"),
        message = kv("msg"),
        source = "t3x",
    })
    return rsp_fmt("UPLOADRESULT", "ok,ret=%d", ret)
end

local function ipcRdyFrom(st)
    return (st == "ready") and 1 or 0
end

function uart_ipcstatus_notify(cmd)
    noteHostPush()
    local st = cmd:match("^AT%+IPCSTATUS=(.+)$")
    if not st or st == "" then
        return RSP_ERROR
    end
    state.host_ipc_status = st
    if pchCloudStat then
        pchCloudStat({ ipcReady = ipcRdyFrom(st) })
    end
    sys.publish(SYS_EVT.IPCSTATUS_ACK, st)
    return rsp_fmt("IPCSTATUS", "OK,status=%s", st)
end

function uart_ipcstat_notify(cmd)
    noteHostPush()
    local body = cmd:match("^AT%+IPCSTAT=(.+)$")
    if not body or body == "" then
        return RSP_ERROR
    end
    if type(parse_ipcstat_line) ~= "function" then
        log.error(LOG_TAG, "ipcstat_push_no_parser", body)
        return RSP_ERROR
    end
    local snap = parse_ipcstat_line("+IPCSTAT:" .. body)
    if not snap then
        return RSP_ERROR
    end
    if commitHostIpcCloudStat then
        commitHostIpcCloudStat(snap)
    else
        state.host_ipc_cloud_stat = snap
    end
    return rspLineOk("IPCSTAT")
end

function uart_tfcard_notify(cmd)
    noteHostPush()
    local body = cmd:match("^AT%+TFCARD=(.+)$")
    if not body or body == "" then
        return RSP_ERROR
    end
    if type(parse_tfcard_line) ~= "function" then
        log.error(LOG_TAG, "tfcard_push_no_parser", body)
        return RSP_ERROR
    end
    local snap = parse_tfcard_line("+TFCARD:" .. body)
    if not snap.parsed then
        return RSP_ERROR
    end
    state.host_tf_card = snap
    if pchCloudStat then
        pchCloudStat({ tfPresent = (tonumber(snap.present) or 0) == 1 and 1 or 0 })
    end
    sys.publish(SYS_EVT.TFCARD_ACK, snap)
    return rspLineOk("TFCARD")
end

-- @desc AT 命令分发处理：uart_snapshot_notify
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartSnps(cmd)
    local path = cmd:match("^AT%+SNAPSHOT=(.+)$")
    if not path or path == "" then
        return RSP_ERROR
    end
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_SNAPSHOT_DONE or "APP_T3X_SNAPSHOT_DONE", path)
    return rsp_fmt("SNAPSHOT", "ok,path=%s", path)
end

-- @desc AT 命令分发处理：uart_record_query
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartRcrdQry(_cmd)
    local rec = 0
    if mod_call("pir_ctrl", "isRecording") then
        rec = 1
    end
    return rsp_fmt("RECORD", "%d,reason=%s,active=%d",
        rec, state.t3x_last_reason or "idle", state.t3x_rec_active or 0)
end

-- @desc AT 命令分发处理：uart_ati
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_ati(_cmd)
    return rsp_fmt("CGMR", "%s", getCnfgSnps().version)
end

-- @desc AT 命令分发处理：uart_ril
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_ril(cmd)
    local n = tonumber(cmd:match("^AT%+RIL=(%d+)$"))
    if n == nil then
        return RSP_ERROR
    end
    state.passthrough = (n == 1)
    return rsp_fmt("RIL_PERSONCNT", "%d", n)
end

-- @desc AT 命令分发处理：uart_sendstr
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_sendstr(cmd)
    local text = cmd:match("^AT%+SENDSTR=(.+)$")
    local ok = false
    if text and hooks.send_string then
        ok = hooks.send_string(text, true)
    end
    return rsp_line("SEND", ok)
end

-- @desc AT 命令分发处理：uart_sendhex
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_sendhex(cmd)
    local hex = cmd:match("^AT%+SENDHEX=(.+)$")
    local ok = false
    if hex and hooks.send_hex then
        ok = hooks.send_hex(hex)
    end
    return rsp_line("SEND", ok)
end

-- @desc AT 命令分发处理：uart_lowpower
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartLwpw(cmd)
    local fc = _G.FEATURE_CFG
    if fc and fc.low_power == false then
        return rsp_only("LOWPOWER", "NOT_SUPPORTED")
    end
    local rt = _G.APP_RUNTIME or {}
    if cmd == "AT+LOWPOWER=ENTER" then
        if (rt.low_power_mode or 0) == 0 then
            if hooks.on_enter_low_power then
                hooks.on_enter_low_power()
            end
            return rsp_only("LOWPOWER", "ENTERING")
        end
        return rsp_only("LOWPOWER", "BUSY")
    end
    if cmd == "AT+LOWPOWER=EXIT" then
        if (rt.low_power_mode or 0) == 1 then
            if hooks.on_exit_low_power then
                hooks.on_exit_low_power()
            end
            return rsp_only("LOWPOWER", "WAKEUP")
        end
        return rsp_only("LOWPOWER", "ALREADY_AWAKE")
    end
    return nil
end

-- @desc AT 命令分发处理：uart_timer_action
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartTmrActn(hook)
    if hook then
        sys.timerStart(hook, 500)
    end
end

-- @desc AT 命令分发处理：uart_reboot
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_reboot(_cmd)
    uartTmrActn(hooks.on_reboot)
    return rsp_line("REBOOT", true)
end

-- @desc AT 命令分发处理：uart_poweroff
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartPwrf(_cmd)
    uartTmrActn(hooks.on_power_off)
    return rsp_line("POWEROFF", true)
end
local wled_state = { on = 0, last_forward_ms = 0 }
local function wled_cfg()
    return _G.WLED_CFG or {}
end

local function wledExpRt(on)
    if _G.APP_RUNTIME then
        _G.APP_RUNTIME.wled_on = on
    end
end

local function wledEns3X()
    local ipc = loader.load("t3x_ctrl")
    if ipc and ipc.ensPowOn then
        local wc = wled_cfg()
        return ipc.ensPowOn("wled", {
            t3x_power_wait_ms = tonumber(wc.t3x_power_wait_ms) or 800,
        })
    end
    return false
end

local function wled_get()
    local rt = _G.APP_RUNTIME
    if rt and rt.wled_on ~= nil then
        return rt.wled_on == 1 and 1 or 0
    end
    return wled_state.on == 1 and 1 or 0
end

local function forwWledTo(on, timeoutMs)
    local wc = wled_cfg()
    if wc.forward_to_t3x == false then
        return true
    end
    if t3xSectOff() then
        return false
    end
    if not wledEns3X() then
        return false
    end
    timeoutMs = tonumber(timeoutMs) or tonumber(wc.ack_timeout_ms) or 3000
    local atCmd = string.format("AT+WLED=%d", on)
    local okFwd = host_query(timeoutMs, {
        busy_key = "wled_forward_busy",
        policy_tag = "wled",
        cfg = wc,
        timeout_cfg_key = "ack_timeout_ms",
        default_timeout = 3000,
        at_cmd = atCmd,
        ack_event = SYS_EVT.WLED_ACK,
        skip_quiet = true,
        on_response = function(got, val)
            return got and type(val) == "table" and val.ok == true
        end,
        on_no_t3x = noop_false,
    })
    return okFwd == true
end

function queryHostWled(timeoutMs)
    local wc = wled_cfg()
    if wc.forward_to_t3x == false then
        return wled_get()
    end
    if not wledEns3X() then
        return wled_get()
    end
    timeoutMs = tonumber(timeoutMs) or tonumber(wc.ack_timeout_ms) or 3000
    local val = host_query(timeoutMs, {
        busy_key = "wled_query_busy",
        policy_tag = "wled",
        cfg = wc,
        timeout_cfg_key = "ack_timeout_ms",
        default_timeout = 3000,
        at_cmd = "AT+WLED?",
        ack_event = SYS_EVT.WLED_ACK,
        skip_quiet = true,
        on_response = function(got, rsp)
            if got and type(rsp) == "table" and rsp.ok then
                return rsp.on
            end
            return wled_get()
        end,
        on_no_t3x = wled_get,
    })
    if val == 0 or val == 1 then
        return val
    end
    return wled_get()
end

local function wled_set(on, opts)
    opts = utils.optTable(opts)
    if not (wled_cfg().enabled ~= false) then
        on = on == 1 and 1 or 0
        wled_state.on = on
        wledExpRt(on)
        return false
    end
    on = (on == 1 or on == true) and 1 or 0
    wled_state.on = on
    wledExpRt(on)
    if opts.forward == false then
        return true
    end
    if opts.sync then
        if coroutine.running() then
            local ok = forwWledTo(on, opts.timeout_ms)
            wled_state.last_forward_ms = host_now_ms()
            return ok
        end
        return false
    end
    sys.taskInit(function()
        if forwWledTo(on, opts.timeout_ms) then
            wled_state.last_forward_ms = host_now_ms()
        end
    end)
    return true
end

function getWled()
    return wled_get()
end

function setWled(on, opts)
    return wled_set(on, opts)
end

-- @desc AT 命令分发处理：uart_wled
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_wled(cmd)
    if cmd == "AT+WLED?" or cmd == "AT+WLEDEN?" then
        return rsp_fmt("WLED", "%d", wled_get())
    end
    local n = tonumber(cmd:match("^AT%+WLED=(%d+)$"))
        or tonumber(cmd:match("^AT%+WLEDEN=(%d+)$"))
    if n == nil or (n ~= 0 and n ~= 1) then
        return RSP_ERROR
    end
    wled_set(n)
    return rsp_fmt("WLED", "%d", n)
end
local usbRcvrGrd = {
    busy = false,
    last_sec = 0,
    count = 0,
}
local function t3XRestBlck()
    local cfg = host_usb_cfg()
    if cfg.block_usb_reset_when_t3x_rest == false then
        return false
    end
    local rt = _G.APP_RUNTIME or {}
    if tonumber(rt.low_power_mode) ~= 1 then
        return false
    end
    local st = mod_call("t3x_ctrl", "getState")
    return st ~= nil and st.powered_on == false
end

local function usbRcvrAllw(cfg)
    if cfg.allow_t3x_usb_reset == false then
        return false, "DISABLED"
    end
    if usbRcvrGrd.busy then
        return false, "BUSY"
    end
    local min_iv = tonumber(cfg.usb_reset_min_interval_sec) or 60
    local now = os.time()
    if usbRcvrGrd.last_sec > 0 and (now - usbRcvrGrd.last_sec) < min_iv then
        return false, "BUSY"
    end
    if t3XRestBlck() then
        return false, "REST"
    end
    return true, nil
end

local function expUsbRcvr(st)
    local rt = _G.APP_RUNTIME or {}
    if st.state then
        rt.usb_recovery = st.state
    end
    if st.count ~= nil then
        rt.usb_recovery_count = st.count
    end
    if st.last_err ~= nil then
        rt.usb_recovery_last_err = st.last_err
    end
    if st.usb_logical ~= nil then
        rt.usb_logical = st.usb_logical
    end
    if st.usb_netdev ~= nil then
        rt.usb_netdev = st.usb_netdev
    end
end

local function pubUsbRcvr()
    local ev = (_G.APP_EVENTS or {}).MQTT_USB_RECOVERY_CHANGED or "mqtt_usb_recovery_changed"
    sys.publish(ev)
end

local function usbRcvrRun(tag, cfg, do_fn)
    usbRcvrGrd.busy = true
    expUsbRcvr({
        state = "recovering",
        usb_logical = isUsbInse() and 1 or 0,
        usb_netdev = 0,
        last_err = "",
    })
    pubUsbRcvr()
    sys.taskInit(function()
        local notify_ms = tonumber(cfg.usb_reset_notify_after_ms) or 800
        local ok = false
        local task_ok, task_err = pcall(function()
            if do_fn then
                ok = do_fn() and true or false
            end
        end)
        if not task_ok then
            log.error(LOG_TAG, tag, "task_crash", tostring(task_err))
            ok = false
        end
        if ok and cfg.notify_t3x_usb_state ~= false and isUsbInse() then
            sys.wait(notify_ms)
            pushUsbIdleSt(1)
        end
        usbRcvrGrd.busy = false
        usbRcvrGrd.last_sec = os.time()
        usbRcvrGrd.count = (usbRcvrGrd.count or 0) + 1
        if not ok then
            expUsbRcvr({
                state = "idle",
                count = usbRcvrGrd.count,
                last_err = "rebind_failed",
                usb_logical = isUsbInse() and 1 or 0,
                usb_netdev = 0,
            })
            pubUsbRcvr()
        end
    end)
end

-- @desc AT 命令分发处理：uart_usbreset
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartUsbr(cmd)
    local cfg = host_usb_cfg()
    if cmd == "AT+USBRESET?" then
        return string.format(
            CRLF .. "+USBRESET:busy=%d,count=%d,last=%d" .. CRLF,
            usbRcvrGrd.busy and 1 or 0,
            usbRcvrGrd.count or 0,
            usbRcvrGrd.last_sec or 0
        )
    end
    if cmd ~= "AT+USBRESET" then
        return RSP_ERROR
    end
    local allowed, deny = usbRcvrAllw(cfg)
    if not allowed then
        if deny == "REST" then
            expUsbRcvr({
                state = "blocked_rest",
                count = usbRcvrGrd.count or 0,
                last_err = "blocked_rest",
                usb_logical = isUsbInse() and 1 or 0,
                usb_netdev = 0,
            })
            pubUsbRcvr()
        end
        return rsp_only("USBRESET", deny)
    end
    local usb_rndis = loader.load("usb_rndis")
    if not usb_rndis then
        return rsp_line("USBRESET", false)
    end
    usbRcvrRun("USBRESET", cfg, function()
        local pulse_ms = 0
        local t3x = loader.load("t3x_ctrl")
        if t3x and t3x.pulseUsbDebugEn then
            local pok, _, pms = pcall(t3x.pulseUsbDebugEn, { high_ms = cfg.usb_debug_en_pulse_ms })
            if pok and pms then
                pulse_ms = tonumber(pms) or 0
            end
        end
        if pulse_ms > 0 then
            sys.wait(pulse_ms + 20)
        end
        if usb_rndis.rebind then
            local rok, rret = pcall(usb_rndis.rebind, { wait_ms = 500 })
            if not rok then
                log.error(LOG_TAG, "usb_rebind_crash", tostring(rret))
                return false
            end
            return rret
        end
        if usb_rndis.disable and usb_rndis.open then
            local dok = pcall(usb_rndis.disable)
            if not dok then
                return false
            end
            sys.wait(500)
            local ook, oret = pcall(usb_rndis.open)
            return ook and oret or false
        end
        return false
    end)
    return rsp_body("USBRESET", "OK")
end

-- @desc AT 命令分发处理：uart_usbrecovery
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartUsbrcv(cmd)
    local state, count = cmd:match("^AT%+USBRECOVERY=([^,]+),(%d+)$")
    if not state then
        state = cmd:match("^AT%+USBRECOVERY=(%w+)$")
        count = 0
    end
    state = state and state:upper() or "IDLE"
    count = tonumber(count) or 0
    local stateLower = state:lower()
    local lastErr = ""
    if stateLower == "exhausted" then
        lastErr = "netdev_missing"
    elseif stateLower == "ok" then
        lastErr = ""
    end
    expUsbRcvr({
        state = stateLower,
        count = count,
        usb_logical = 1,
        usb_netdev = stateLower == "ok" and 1 or 0,
        last_err = lastErr,
    })
    pubUsbRcvr()
    return rsp_body("USBRECOVERY", state)
end

function rstUsbRcvry()
    if t3xSectOff() then
        expUsbRcvr({
            state = "idle",
            count = 0,
            last_err = "",
            usb_logical = isUsbInse() and 1 or 0,
            usb_netdev = 0,
        })
        usbRcvrGrd.count = 0
        pubUsbRcvr()
        return false
    end
    uart_bridge.sendString("AT+USBRECOVERYRESET", true)
    expUsbRcvr({
        state = "idle",
        count = 0,
        last_err = "",
        usb_logical = isUsbInse() and 1 or 0,
        usb_netdev = 0,
    })
    usbRcvrGrd.count = 0
    pubUsbRcvr()
    return true
end

-- @desc AT 命令分发处理：uart_rndis
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_rndis(cmd)
    local usb_rndis = loader.load("usb_rndis")
    if not usb_rndis then
        return RSP_ERROR
    end
    if cmd == "AT+RNDIS?" or cmd == "AT+RNDIS" then
        local st = usb_rndis.getStatus and usb_rndis.getStatus() or {}
        return rsp_fmt(
            "RNDIS", "enabled=%d,mode=%s,status=%s,ip=%s,flymode=%s",
            st.enabled and 1 or 0,
            tostring(st.usb_ethernet_mode or "--"),
            tostring(st.status or "--"),
            tostring(st.ip or "--"),
            st.flymode == nil and "--" or (st.flymode and "1" or "0")
        )
    end
    local n = tonumber(cmd:match("^AT%+RNDIS=(%d+)$"))
    if n == 1 then
        sys.taskInit(function()
            if usb_rndis.open then
                usb_rndis.open()
            elseif usb_rndis.enable then
                usb_rndis.enable()
            end
        end)
        return rspLineOk("RNDIS")
    end
    if n == 0 then
        sys.taskInit(function()
            if usb_rndis.disable then
                usb_rndis.disable()
            end
        end)
        return rspLineOk("RNDIS")
    end
    return RSP_ERROR
end

-- @desc AT 命令分发处理：uart_ota
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_ota(_cmd)
    if hooks.on_ota then
        hooks.on_ota()
    else
        local E = _G.APP_EVENTS or {}
        if E.DEVICE_OTA_REQUEST then
            sys.publish(E.DEVICE_OTA_REQUEST, {})
        end
    end
    return rsp_only("OTA", "STARTING")
end

-- @desc AT 命令分发处理：uart_setcfg
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uart_setcfg(cmd)
    local key, val = cmd:match("^AT%+SETCFG=([^,]+),(.+)$")
    if not key or not val then
        return rsp_line("SETCFG", false)
    end
    local rt = _G.APP_RUNTIME
    local meta = _G.APP_META
    if key == "interval" and tonumber(val) and rt then
        local mqtt = loader.load("net_mqtt")
        if mqtt and mqtt.setStatIntv then
            if not mqtt.setStatIntv(tonumber(val), true) then
                return rsp_line("SETCFG", false)
            end
        else
            rt.low_power_interval_sec = tonumber(val)
            local ev = (_G.APP_EVENTS or {}).MQTT_STATUS_INTERVAL_CHANGED or "APP_MQTT_STATUS_INTERVAL_CHANGED"
            sys.publish(ev)
        end
        return rsp_line("SETCFG", true)
    elseif key == "devicemodel" and meta then
        meta.device_model = val
        return rsp_line("SETCFG", true)
    elseif key == "hexrpt" then
        state.hex_report = (val == "1" or val == "true" or val == "on")
        return rsp_line("SETCFG", true)
    end
    return rsp_line("SETCFG", false)
end

-- @desc AT 命令分发处理：uart_hex_line
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartHexLine(line)
    local hex = line:match("^[Hh][Ee][Xx]:(.*)$")
    if not hex or not hooks.uart_write then
        return rsp_line("HEX", false)
    end
    local bin = decode_hex(hex)
    if not bin then
        return rsp_line("HEX", false)
    end
    hooks.uart_write(bin)
    return rsp_line("HEX", true)
end

-- @desc AT 命令分发处理：uart_str_line
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartStrLine(line)
    local text = line:match("^[Ss][Tt][Rr]:(.*)$")
    local ok = false
    if text and hooks.send_string then
        ok = hooks.send_string(text, true)
    end
    return rsp_line("STR", ok)
end

-- @desc AT 命令分发处理：uartCmdEntr
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartCmdEntr(keys, prefix, handler)
    if prefix then
        return { match = "prefix", prefix = prefix, handler = handler }
    end
    keys = type(keys) == "table" and keys or { keys }
    return { match = "exact", keys = keys, handler = handler }
end
local AT_CMD_TABLE = {
    uartCmdEntr("AT", nil, uart_at_ack),
    uartCmdEntr({ "ATI", "AT+CGMR", "AT+GETVER" }, nil, uart_ati),
    uartCmdEntr("AT+GETCFG", nil, uart_getcfg),
    uartCmdEntr({ "AT+PIRSTAT", "AT+PIRSTAT?" }, nil, uartPrstQry),
    uartCmdEntr("AT+PIRCLR", nil, uart_pirclr),
    uartCmdEntr({ "AT+RECORD", "AT+RECORD?" }, nil, uartRcrdQry),
    uartCmdEntr(nil, "AT+RECORD=", uartRcrd),
    uartCmdEntr(nil, "AT+IPCSTATUS=", uart_ipcstatus_notify),
    uartCmdEntr(nil, "AT+IPCSTAT=", uart_ipcstat_notify),
    uartCmdEntr(nil, "AT+TFCARD=", uart_tfcard_notify),
    uartCmdEntr(nil, "AT+SNAPSHOT=", uartSnps),
    uartCmdEntr(nil, "AT+PIRMEDIA=", uartPirMd),
    uartCmdEntr(nil, "AT+PERSONCNT=", uartPrsnCnt),
    uartCmdEntr(nil, "AT+IPCALERT=", uartIpcAlrt),
    uartCmdEntr(nil, "AT+UPLOADNEED=", uartUpld),
    uartCmdEntr(nil, "AT+UPLOADRESULT=", uartUpldrs),
    uartCmdEntr({ "AT+HOSTEVT", "AT+HOSTEVT?" }, nil, uartHstvQry),
    uartCmdEntr("AT+HOSTEVTCLR", nil, uartHstvClr),
    uartCmdEntr("AT+TIME", nil, uartTimeQry),
    uartCmdEntr({ "AT+IMEI", "AT+IMEI?" }, nil, uart_imei),
    uartCmdEntr({ "AT+IPCINFO", "AT+IPCINFO?" }, nil, uartIpcnQry),
    uartCmdEntr(nil, "AT+MQTTPUB=", uart_mqttpub),
    uartCmdEntr({ "AT+WLED?", "AT+WLEDEN?" }, nil, uart_wled),
    uartCmdEntr(nil, "AT+WLED=", uart_wled),
    uartCmdEntr(nil, "AT+WLEDEN=", uart_wled),
    uartCmdEntr(nil, "AT+SERVCREATE=", uartSrvcrt),
    uartCmdEntr(nil, "AT+MQTTCFG=", uart_mqttcfg),
    uartCmdEntr(nil, "AT+P2PCFG=", uart_p2pcfg),
    uartCmdEntr(nil, "AT+GB28181CFG=", uartGb28181),
    uartCmdEntr(nil, "AT+SERVCLOSE=", uartSrvc),
    uartCmdEntr(nil, "AT+RIL=", uart_ril),
    uartCmdEntr(nil, "AT+SENDSTR=", uart_sendstr),
    uartCmdEntr(nil, "AT+SENDHEX=", uart_sendhex),
    uartCmdEntr(nil, "AT+LOWPOWER=", uartLwpw),
    uartCmdEntr({ "AT+HOSTIDLE", "AT+HOSTIDLE?" }, nil, uartHstd),
    uartCmdEntr(nil, "AT+HOSTIDLE=", uartHstd),
    uartCmdEntr({ "AT+RNDIS", "AT+RNDIS?" }, nil, uart_rndis),
    uartCmdEntr(nil, "AT+RNDIS=", uart_rndis),
    uartCmdEntr({ "AT+USBRESET", "AT+USBRESET?" }, nil, uartUsbr),
    uartCmdEntr(nil, "AT+USBRECOVERY=", uartUsbrcv),
    uartCmdEntr("AT+REBOOT", nil, uart_reboot),
    uartCmdEntr("AT+POWEROFF", nil, uartPwrf),
    uartCmdEntr({ "AT+OTA", "AT+OTACHECK" }, nil, uart_ota),
    uartCmdEntr(nil, "AT+SETCFG=", uart_setcfg),
}
local AT_EXACT, AT_PREFIX = {}, {}
for i = 1, #AT_CMD_TABLE do
    local e = AT_CMD_TABLE[i]
    if e.match == "exact" then
        for j = 1, #e.keys do
            AT_EXACT[e.keys[j]] = e.handler
        end
    else
        AT_PREFIX[#AT_PREFIX + 1] = e
    end
end
local LINE_HANDLERS = {
    HEX = uartHexLine,
    STR = uartStrLine,
}
-- @desc AT 命令分发处理：uart_dispatch_at
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartDsptAt(cmd)
    local exact = AT_EXACT[cmd]
    if exact then
        local rsp = exact(cmd)
        if rsp ~= nil then
            return rsp
        end
    end
    for i = 1, #AT_PREFIX do
        local e = AT_PREFIX[i]
        if cmd:sub(1, #e.prefix) == e.prefix then
            local rsp = e.handler(cmd)
            if rsp ~= nil then
                return rsp
            end
        end
    end
    if state.passthrough and hooks.modem_at then
        return hooks.modem_at(cmd)
    end
    return RSP_ERROR
end

local function hostPlnLine(line)
    if hooks.on_plain_line then
        hooks.on_plain_line(line)
        return
    end
    local E = _G.APP_EVENTS or {}
    if E.UART_RX_STRING then
        sys.publish(E.UART_RX_STRING, line)
    end
end

local function trySndAck(line)
    if not line then
        return false
    end
    local name = line:match("^%+SOUNDACK:(%w+)$")
    if not name then
        return false
    end
    mod_call("sound_prompt", "onSoundAck", name)
    return true
end

local function tryTmstAck(line)
    if not line then
        return false
    end
    if line:match("^%+TIMESET:OK$") then
        mod_call("time_sync", "onTimesetAck")
        return true
    end
    return false
end

local function tryGb28181(line)
    if not line then
        return false
    end
    local id = line:match("^%+GB28181:(.*)$")
    if id == nil then
        return false
    end
    id = id:gsub("^%s+", ""):gsub("%s+$", "")
    state.host_gb28181_id = id
    sys.publish(SYS_EVT.GB28181_ACK, id)
    return true
end

local function tryWledLine(line)
    if not line then
        return false
    end
    if line:match("^%+WLED:ERROR") then
        sys.publish(SYS_EVT.WLED_ACK, { ok = false })
        return true
    end
    local n = line:match("^%+WLED:(%d+)$")
    if n == nil then
        return false
    end
    n = tonumber(n) or 0
    if n ~= 0 then
        n = 1
    end
    wled_state.on = n
    wledExpRt(n)
    if pchCloudStat then
        pchCloudStat({ wledEnable = n })
    end
    sys.publish(SYS_EVT.WLED_ACK, { ok = true, on = n })
    return true
end

local function tryTffrLine(line)
    if not line then
        return false
    end
    if line:match("^%+TFFORMAT:ERROR") then
        local ret = line:match("ret=([^,%s]+)") or "error"
        sys.publish(SYS_EVT.TFFORMAT_ACK, { phase = "error", ret = ret })
        return true
    end
    if line:match("^%+TFFORMAT:STARTED") then
        sys.publish(SYS_EVT.TFFORMAT_ACK, { phase = "started" })
        return true
    end
    if line:match("^%+TFFORMAT:OK") then
        local reboot = line:match("reboot=(%d+)") or "0"
        sys.publish(SYS_EVT.TFFORMAT_ACK, { phase = "ok", reboot = tonumber(reboot) or 0 })
        return true
    end
    return false
end
parse_tfcard_line = function(line)
    local snap = {
        present = 0,
        total_mb = 0,
        used_mb = 0,
        free_mb = 0,
        parsed = false,
    }
    if not line then
        return snap
    end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    line = line:gsub("OK%s*$", "")
    local p, t, u, f = line:match("^%+TFCARD:present=(%d+),total_mb=(%d+),used_mb=(%d+),free_mb=(%d+)$")
    if not p then
        p, t, u, f = line:match("^%+TFCARD:(%d+),(%d+),(%d+),(%d+)$")
    end
    if p then
        snap.present = tonumber(p) or 0
        snap.total_mb = tonumber(t) or 0
        snap.used_mb = tonumber(u) or 0
        snap.free_mb = tonumber(f) or 0
        snap.parsed = true
    end
    return snap
end

local function tryTfcrLine(line)
    if not line or not line:match("^%+TFCARD:") then
        return false
    end
    local snap = parse_tfcard_line(line)
    if not snap.parsed then
        return false
    end
    state.host_tf_card = snap
    pchCloudStat({ tfPresent = (tonumber(snap.present) or 0) == 1 and 1 or 0 })
    sys.publish(SYS_EVT.TFCARD_ACK, snap)
    return true
end

local function prsRcrdLine(line)
    local snap = {
        running = 0,
        active = 0,
        ch = -1,
        reason = "idle",
        recording = 0,
    }
    if not line then
        return snap
    end
    local r, a, c, rs = line:match("^%+RECORD:running=(%d),active=(%d),ch=(%-?%d+),reason=(.+)$")
    if r then
        snap.running = tonumber(r) or 0
        snap.active = tonumber(a) or 0
        snap.ch = tonumber(c) or -1
        snap.reason = rs or "idle"
        snap.recording = snap.running
        return snap
    end
    local rec, reason, active = line:match("^%+RECORD:(%d+),reason=([^,]+),active=(%d+)$")
    if rec then
        snap.recording = tonumber(rec) or 0
        snap.running = snap.recording
        snap.reason = reason or "idle"
        snap.active = tonumber(active) or 0
        return snap
    end
    return snap
end

local function normHostLine(line)
    if not line then
        return line
    end
    return (line:match("^%s*(.-)%s*$") or line)
end

local function parse_recordtime_line(line)
    line = normHostLine(line)
    if not line or not line:match("^%+RECORDTIME:") then
        return nil
    end
    local min = line:match("^%+RECORDTIME:(%d+),min=")
    if min then
        return {
            parsed = true,
            ok = true,
            minutes = tonumber(min) or 0,
            query = true,
        }
    end
    local okMin = line:match("^%+RECORDTIME:OK,(%d+)$")
    if okMin then
        return {
            parsed = true,
            ok = true,
            minutes = tonumber(okMin) or 0,
            set = true,
        }
    end
    if line:match("^%+RECORDTIME:INVALID") then
        return { parsed = true, ok = false, invalid = true, set = true }
    end
    if line:match("^%+RECORDTIME:ERROR") then
        return { parsed = true, ok = false, error = true, set = true }
    end
    return nil
end

local function tryRcrdtmLine(line)
    local snap = parse_recordtime_line(line)
    if not snap then
        return false
    end
    if snap.query then
        state.host_record_time = snap
        sys.publish(SYS_EVT.RECORDTIME_ACK, snap)
    elseif snap.set then
        sys.publish(SYS_EVT.RECORDTIME_SET, snap)
    end
    return true
end

local function tryRcrdLine(line)
    if not line or not line:match("^%+RECORD:") then
        return false
    end
    local snap = prsRcrdLine(line)
    state.host_record = snap
    if (tonumber(snap.active) or 0) == 1 or (tonumber(snap.running) or 0) == 1 then
        state.t3x_rec_active = 1
    elseif (tonumber(snap.running) or 0) == 0 and (tonumber(snap.active) or 0) == 0 then
        state.t3x_rec_active = 0
    end
    if snap.reason and snap.reason ~= "" then
        state.t3x_last_reason = snap.reason
    end
    sys.publish(SYS_EVT.RECORD_ACK, snap)
    return true
end

local function parse_venc_row(line)
    line = normHostLine(line)
    local cam, stream, en, w, h, br, fps, rc, enc = line:match(
        "^%+VENC:(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)")
    if not cam then
        return nil
    end
    return {
        camera = tonumber(cam) or 0,
        stream = tonumber(stream) or 0,
        enable = tonumber(en) or 0,
        width = tonumber(w) or 0,
        height = tonumber(h) or 0,
        bitrate = tonumber(br) or 0,
        framerate = tonumber(fps) or 0,
        rcmode = tonumber(rc) or 0,
        encoder = tonumber(enc) or 0,
    }
end

local function parse_audio_row(line)
    line = normHostLine(line)
    local cam, en, enc, sr, bw, sm, vol, gain = line:match(
        "^%+AUDIO:(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$")
    if not cam then
        return nil
    end
    return {
        camera = tonumber(cam) or 0,
        enable = tonumber(en) or 0,
        encoder = tonumber(enc) or 0,
        samplerate = tonumber(sr) or 0,
        bitwidth = tonumber(bw) or 0,
        soundmode = tonumber(sm) or 0,
        volume = tonumber(vol) or 0,
        gain = tonumber(gain) or 0,
    }
end
-- 行解析 DSL：match_flag=固定应答、match_pub=字段捕获发布（!前缀转bool、$前缀保留字符串）、rows_*=多行收集
local function pub_ack(ev, t)
    sys.publish(ev, t)
    return true
end

local function match_flag(pat, ev, tpl)
    return function(line)
        if not line:match(pat) then
            return false
        end
        local t = {}
        for k, v in pairs(tpl) do t[k] = v end
        return pub_ack(ev, t)
    end
end

local function match_pub(pat, ev, names, tpl)
    return function(line)
        local caps = { line:match(pat) }
        if caps[1] == nil then
            return false
        end
        local t = {}
        if tpl then
            for k, v in pairs(tpl) do t[k] = v end
        end
        for i = 1, #names do
            local n = names[i]
            local mark = n:sub(1, 1)
            if mark == "!" then
                t[n:sub(2)] = (tonumber(caps[i]) or 0) == 1
            elseif mark == "$" then
                t[n:sub(2)] = caps[i]
            else
                t[n] = tonumber(caps[i]) or 0
            end
        end
        return pub_ack(ev, t)
    end
end

local function rows_append(key, row)
    if not row then
        return false
    end
    state[key] = state[key] or {}
    state[key][#state[key] + 1] = row
    return true
end

local function rowsEndFlus(endLine, key, ev)
    return function(line)
        if line ~= endLine then
            return false
        end
        if state[key] == nil then
            return false
        end
        local rows = state[key]
        if type(rows) ~= "table" or #rows == 0 then
            return false
        end
        state[key] = nil
        return pub_ack(ev, rows)
    end
end

local function rows_collect(pat, key, names)
    return function(line)
        local caps = { line:match(pat) }
        if caps[1] == nil then
            return false
        end
        local row = {}
        for i = 1, #names do
            row[names[i]] = tonumber(caps[i]) or 0
        end
        return rows_append(key, row)
    end
end

local function lineMtch(...)
    local fns = { ... }
    return function(line)
        if not line then
            return false
        end
        for i = 1, #fns do
            if fns[i](line) then
                return true
            end
        end
        return false
    end
end

local function norm_matchers(...)
    local m = lineMtch(...)
    return function(line)
        return m(normHostLine(line))
    end
end

local function try_encode_uart_error(line)
    if line ~= "ERROR" then
        return false
    end
    if type(state.encode_venc_rows) == "table" and #state.encode_venc_rows > 0 then
        state.encode_venc_rows = nil
        sys.publish(SYS_EVT.VENC_QUERY, { __error = "uart_error" })
        return true
    end
    if type(state.encode_audio_rows) == "table" and #state.encode_audio_rows > 0 then
        state.encode_audio_rows = nil
        sys.publish(SYS_EVT.AUDIO_QUERY, { __error = "uart_error" })
        return true
    end
    return false
end

local function tryEncdOk(line)
    if line ~= "OK" then
        return false
    end
    if type(state.encode_venc_rows) == "table" and #state.encode_venc_rows > 0 then
        local rows = state.encode_venc_rows
        state.encode_venc_rows = nil
        sys.publish(SYS_EVT.VENC_QUERY, rows)
        return true
    end
    if type(state.encode_audio_rows) == "table" and #state.encode_audio_rows > 0 then
        local rows = state.encode_audio_rows
        state.encode_audio_rows = nil
        sys.publish(SYS_EVT.AUDIO_QUERY, rows)
        return true
    end
    if type(state.mic_rows) == "table" and #state.mic_rows > 0 then
        local rows = state.mic_rows
        state.mic_rows = nil
        sys.publish(SYS_EVT.MIC_QUERY, rows)
        return true
    end
    return false
end
local try_venc_line = norm_matchers(
    rowsEndFlus("+VENC:END", "encode_venc_rows", SYS_EVT.VENC_QUERY),
    function(line)
        return rows_append("encode_venc_rows", parse_venc_row(line))
    end)
local try_vencset_line = lineMtch(
    match_flag("^%+VENCSET:ERROR", SYS_EVT.VENC_SET, { ok = false }),
    match_pub("^%+VENCSET:OK,cam=(%d+),stream=(%d+),needReboot=(%d+),runtimeApply=(%d+)$", SYS_EVT.VENC_SET,
        { "camera", "stream", "!needReboot", "runtimeApply" }, { ok = true }),
    match_pub("^%+VENCSET:OK,cam=(%d+),stream=(%d+),needReboot=(%d+)$", SYS_EVT.VENC_SET,
        { "camera", "stream", "!needReboot" }, { ok = true }))
local try_audioset_line = lineMtch(
    match_flag("^%+AUDIOSET:ERROR", SYS_EVT.AUDIO_SET, { ok = false }),
    match_pub("^%+AUDIOSET:OK,cam=(%d+),needReboot=(%d+)$", SYS_EVT.AUDIO_SET,
        { "camera", "!needReboot" }, { ok = true }))
local try_audio_line = norm_matchers(
    rowsEndFlus("+AUDIO:END", "encode_audio_rows", SYS_EVT.AUDIO_QUERY),
    function(line)
        return rows_append("encode_audio_rows", parse_audio_row(line))
    end)
local try_micset_line = lineMtch(
    match_flag("^%+MICSET:ERROR", SYS_EVT.MIC_SET, { ok = false }),
    match_pub("^%+MICSET:OK,cam=(%d+),runtimeApply=(%d+)$", SYS_EVT.MIC_SET,
        { "camera", "runtimeApply" }, { ok = true }))
local try_mic_line = norm_matchers(
    rowsEndFlus("+MIC:END", "mic_rows", SYS_EVT.MIC_QUERY),
    rows_collect("^%+MIC:(%d+),(%d+),(%d+)$", "mic_rows", { "camera", "volume", "gain" }))
local try_softphotoset_line = lineMtch(
    match_flag("^%+SOFTPHOTOSET:OK", SYS_EVT.SOFTPHOTO_SET, { ok = true }),
    match_flag("^%+SOFTPHOTOSET:ERROR", SYS_EVT.SOFTPHOTO_SET, { ok = false }))
local try_softphoto_line = norm_matchers(
    match_pub("^%+SOFTPHOTO:(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$", SYS_EVT.SOFTPHOTO_QUERY,
        { "enable", "nightModeThreshold", "dayModeThreshold", "dayModeAltThreshold",
            "gbGainThreshold", "gbGainRecordInit", "checkTime", "checkCount" }, { parsed = true }),
    match_flag("^%+SOFTPHOTO:ERROR", SYS_EVT.SOFTPHOTO_QUERY, { parsed = false, error = true }))
local try_framerate_line = norm_matchers(
    rowsEndFlus("+FRAMERATE:END", "framerate_rows", SYS_EVT.FRAMERATE_QUERY),
    rows_collect("^%+FRAMERATE:(%d+),(%d+),(%d+)$", "framerate_rows", { "camera", "stream", "framerate" }),
    match_pub("^%+FRAMERATE:OK,(%d+),(%d+),(%d+),runtimeApply=(%d+)$", SYS_EVT.FRAMERATE_SET,
        { "camera", "stream", "framerate", "runtimeApply" }, { ok = true }),
    match_pub("^%+FRAMERATE:OK,(%d+),(%d+),(%d+)$", SYS_EVT.FRAMERATE_SET,
        { "camera", "stream", "framerate" }, { ok = true, runtimeApply = 1 }),
    match_flag("^%+FRAMERATE:ERROR", SYS_EVT.FRAMERATE_SET, { ok = false, error = true }))
local try_recordctrl_line = norm_matchers(
    match_pub("^%+RECORDCTRL:OK,1,max_sec=(%d+)$", SYS_EVT.RECORDCTRL_SET, { "max_sec" }, { ok = true, start = 1 }),
    match_pub("^%+RECORDCTRL:OK,0,reason=(.*)$", SYS_EVT.RECORDCTRL_SET, { "$reason" }, { ok = true, start = 0 }),
    match_pub("^%+RECORDCTRL:OK,0$", SYS_EVT.RECORDCTRL_SET, {}, { ok = true, start = 0, reason = "ok" }),
    match_flag("^%+RECORDCTRL:ERROR", SYS_EVT.RECORDCTRL_SET, { ok = false, error = true }))
local tryUpldLine = norm_matchers(
    match_pub("^%+UPLOADVIDEO:OK,need=(%d+),type=(%d+),start=(%d+),end=(%d+),queued=(%d+)$",
        SYS_EVT.UPLOADVIDEO_SET,
        { "needUpload", "videoType", "start_ts", "end_ts", "queued" },
        { ok = true }),
    match_pub("^%+UPLOADVIDEO:OK,need=(%d+),type=(%d+),start=(%d+),end=(%d+)$",
        SYS_EVT.UPLOADVIDEO_SET,
        { "needUpload", "videoType", "start_ts", "end_ts" },
        { ok = true, queued = 1 }),
    match_flag("^%+UPLOADVIDEO:ERROR", SYS_EVT.UPLOADVIDEO_SET, { ok = false, error = true }))
local try_persondet_line = norm_matchers(
    function(line)
        local enable, available = line:match("^%+PERSONDET:(%d+),available=(%d+)$")
        if enable then
            state.host_person_detect = {
                enable = tonumber(enable) or 0,
                available = tonumber(available) or 0,
                parsed = true,
            }
        else
            enable = line:match("^%+PERSONDET:(%d+)$")
            if not enable then
                return false
            end
            state.host_person_detect = { enable = tonumber(enable) or 0, parsed = true }
        end
        return pub_ack(SYS_EVT.PERSONDET_ACK, state.host_person_detect)
    end,
    match_pub("^%+PERSONDET:OK,(%d+)$", SYS_EVT.PERSONDET_SET, { "enable" }, { ok = true }),
    match_flag("^%+PERSONDET:ERROR", SYS_EVT.PERSONDET_SET, { ok = false, error = true }))
normalize_ipc_cloud_stat = function(snap)
    if type(snap) ~= "table" then
        return snap
    end
    if snap.cat1Link == nil and snap.hostLink ~= nil then
        snap.cat1Link = snap.hostLink
    end
    return snap
end

function commitHostIpcCloudStat(snap)
    if type(snap) ~= "table" or next(snap) == nil then
        return nil
    end
    snap = normalize_ipc_cloud_stat(snap)
    state.host_ipc_cloud_stat = snap
    state.ipc_cloud_stat_ts = os.time()
    if snap.recordingT3x ~= nil then
        state.t3x_rec_active = tonumber(snap.recordingT3x) or 0
    end
    if snap.ipcReady == 1 and not state.host_ipc_status then
        state.host_ipc_status = "ready"
    end
    sys.publish(SYS_EVT.IPCSTAT_ACK, snap)
    return snap
end

function pchCloudStat(fields)
    local cloud = state.host_ipc_cloud_stat
    if type(cloud) ~= "table" then
        cloud = {}
    end
    fields = utils.optTable(fields)
    for k, v in pairs(fields) do
        cloud[k] = v
    end
    return commitHostIpcCloudStat(cloud)
end
parse_ipcstat_line = function(line)
    local snap = {}
    if not line or not line:match("^%+IPCSTAT:") then
        return nil
    end
    for k, v in string.gmatch(line, "(%w+)=(%d+)") do
        snap[k] = tonumber(v) or 0
    end
    if next(snap) == nil then
        return nil
    end
    return normalize_ipc_cloud_stat(snap)
end

local function tryIpcsLine(line)
    local snap = parse_ipcstat_line(line)
    if not snap then
        return false
    end
    commitHostIpcCloudStat(snap)
    return true
end

local function tryIpcsttLine(line)
    if not line then
        return false
    end
    local st = line:match("^%+IPCSTATUS:(%w+)$")
    if not st then
        return false
    end
    state.host_ipc_status = st
    pchCloudStat({ ipcReady = ipcRdyFrom(st) })
    note_uart_link_ok()
    sys.publish(SYS_EVT.IPCSTATUS_ACK, st)
    return true
end

local function tryIpcpLine(line)
    if not line then
        return false
    end
    if line == "+IPCPOWEROFF:OK" then
        sys.publish(SYS_EVT.IPCPOWEROFF_ACK, { ok = true })
        return true
    end
    local stage = line:match("^%+IPCPOWEROFF:STAGE,([%w_]+)$")
    if stage then
        sys.publish(SYS_EVT.IPCPOWEROFF_ACK, { ok = false, stage = stage })
        return true
    end
    if line:match("^%+IPCPOWEROFF:BUSY") or line:match("^%+IPCPOWEROFF:ERROR")
        or line:match("^%+IPCPOWEROFF:NOT_SUPPORTED") then
        if log and log.info then
            log.info("host_uart", "ipcpoweroff_rx", "ERR", line)
        end
        sys.publish(SYS_EVT.IPCPOWEROFF_ACK, { ok = false, error = true, line = line })
        return true
    end
    return false
end
local RX_LINE_HANDLER_REGISTRY = {
    { name = "encode_uart_error", fn = try_encode_uart_error },
    { name = "sound_ack", fn = trySndAck },
    { name = "timeset_ack", fn = tryTmstAck },
    { name = "gb28181", fn = tryGb28181 },
    { name = "wled", fn = tryWledLine },
    { name = "tfformat", fn = tryTffrLine },
    { name = "tfcard", fn = tryTfcrLine },
    { name = "recordtime", fn = tryRcrdtmLine },
    { name = "framerate", fn = try_framerate_line },
    { name = "recordctrl", fn = try_recordctrl_line },
    { name = "uploadvideo", fn = tryUpldLine },
    { name = "persondet", fn = try_persondet_line },
    { name = "record", fn = tryRcrdLine },
    { name = "venc", fn = try_venc_line },
    { name = "vencset", fn = try_vencset_line },
    { name = "audio", fn = try_audio_line },
    { name = "audioset", fn = try_audioset_line },
    { name = "mic", fn = try_mic_line },
    { name = "micset", fn = try_micset_line },
    { name = "softphoto", fn = try_softphoto_line },
    { name = "softphotoset", fn = try_softphotoset_line },
    { name = "ipcstat", fn = tryIpcsLine },
    { name = "ipcstatus", fn = tryIpcsttLine },
    { name = "ipcpoweroff", fn = tryIpcpLine },
    { name = "encode_ok_tail", fn = tryEncdOk },
}
local RX_LINE_TRY_HANDLERS = {}
for i = 1, #RX_LINE_HANDLER_REGISTRY do
    RX_LINE_TRY_HANDLERS[i] = RX_LINE_HANDLER_REGISTRY[i].fn
end

local function ntfyHost(cmd)
    if state.host_at_ready then
        return
    end
    state.host_at_ready = true
    state.first_host_at = cmd
    state.host_ready_seen = true
    note_uart_link_ok()
    state.uart_recovery_attempts = 0
    state.uart_recovery_last_sec = 0
    if pchCloudStat then
        pchCloudStat({ cat1Link = 1 })
    end
    sys.taskInit(function()
        sys.wait(300)
        if not isT31HostQry() then
            return
        end
        if queryHostIpcCloudStat then
            queryHostIpcCloudStat(2500)
        end
        if mrgTfCloudStat then
            mrgTfCloudStat()
        end
    end)
    sys.publish(utils.appEvent("HOST_UART_FIRST_AT", "APP_HOST_UART_FIRST_AT"), cmd or "")
end

local function hostPrcs(line)
    line = normHostLine(line)
    if not line or line == "" then
        return nil
    end
    for _, try_fn in ipairs(RX_LINE_TRY_HANDLERS) do
        if try_fn(line) then
            return nil
        end
    end
    if line:sub(1, 2) == "AT" then
        noteHostPush()
        ntfyHost(line)
        return uart_at_cmd(line)
    end
    if line:sub(4, 4) == ":" then
        local fn = LINE_HANDLERS[line:sub(1, 3):upper()]
        if fn then
            return fn(line)
        end
    end
    hostPlnLine(line)
    return nil
end

function uart_at_cmd(cmd)
    if not cmd or cmd == "" then
        return RSP_ERROR
    end
    state.last_command = cmd
    cmd = cmd:gsub("%?$", "")
    if hooks.on_at_ext then
        local extRsp = hooks.on_at_ext(cmd)
        if extRsp then
            return extRsp
        end
    end
    return uartDsptAt(cmd)
end

function on_rx_raw(data)
    echoRxHexIf(data)
end

local function dfltMdmAt(cmd)
    if mobile and mobile.at then
        return mobile.at(cmd .. CRLF, 5000)
    end
    return nil
end

local function on_uart_line(line)
    local rsp = hostPrcs(line)
    if rsp then
        uart_bridge.write(rsp)
    end
end

local function bindStrtHks(opts)
    hooks.on_servcreate = opts.on_servcreate
    hooks.on_servclose = opts.on_servclose
    hooks.on_mqtt_cfg = opts.on_mqtt_cfg
    hooks.on_at_ext = opts.on_at_ext
    hooks.on_enter_low_power = opts.on_enter_low_power
    hooks.on_exit_low_power = opts.on_exit_low_power
    hooks.on_reboot = opts.on_reboot
    hooks.on_power_off = opts.on_power_off
    hooks.on_ota = opts.on_ota
    hooks.on_plain_line = opts.on_plain_line
    hooks.uart_write = uart_bridge.write
    hooks.send_string = uart_bridge.sendString
    hooks.send_hex = function(hex)
        local bin = decode_hex(hex)
        return bin and uart_bridge.write(bin)
    end
    hooks.modem_at = opts.modem_at or dfltMdmAt
end

function isHostAtReady()
    return state.host_at_ready == true
end

local function identity_cfg()
    return _G.HOST_IDENTITY_CFG or {}
end

local function tf_card_cfg()
    return _G.HOST_TFCARD_CFG or {}
end

local function encode_cfg()
    return _G.HOST_ENCODE_CFG or {}
end

local function ipc_cfg()
    return _G.HOST_IPC_CFG or {}
end

local function ens3XHost(policy_tag, cfg)
    cfg = cfg or identity_cfg()
    local ipc = loader.load("t3x_ctrl")
    if ipc and ipc.ensPowOn then
        return ipc.ensPowOn(policy_tag or "host_identity", {
            t3x_power_wait_ms = tonumber(cfg.t3x_power_wait_ms)
                or tonumber((_G.TIME_SYNC_CFG or {}).t3x_power_wait_ms)
                or 800,
        })
    end
    return false
end

local function hostBoot(cfg)
    return tonumber(cfg.hostBootWaitMs)
        or tonumber((_G.TIME_SYNC_CFG or {}).hostBootWaitMs)
        or 1500
end
run_host_query = function(opts)
    if not coroutine.running() then
        if opts.cache_key and state[opts.cache_key] ~= nil then
            return state[opts.cache_key]
        end
        if opts.busy_return ~= nil then
            return opts.busy_return
        end
        return opts.default_result
    end
    if state[opts.busy_key] then
        if opts.busy_return ~= nil then
            return opts.busy_return
        end
        if opts.cache_key then
            return state[opts.cache_key]
        end
    end
    local cfg = opts.cfg or identity_cfg()
    local timeoutMs = tonumber(opts.timeout_ms)
        or tonumber(cfg[opts.timeout_cfg_key or "query_timeout_ms"])
        or opts.default_timeout
        or 3000
    if not uartTxnAcqu(timeoutMs) then
        if opts.cache_key and state[opts.cache_key] ~= nil then
            return state[opts.cache_key]
        end
        if opts.busy_return ~= nil then
            return opts.busy_return
        end
        return opts.default_result
    end
    state[opts.busy_key] = true
    local result = opts.default_result
    local ok, err = pcall(function()
        if opts.when_disabled then
            local early = opts.when_disabled(cfg)
            if early ~= nil then
                result = early
                return
            end
        end
        if not ens3XHost(opts.policy_tag, cfg) then
            if opts.on_no_t3x then
                result = opts.on_no_t3x()
            end
            return
        end
        if opts.wait_boot ~= false and not state.host_at_ready then
            sys.wait(hostBoot(cfg))
        end
        if not uart_bridge.sendString then
            if opts.on_no_uart then
                result = opts.on_no_uart()
            end
            return
        end
        if opts.skip_quiet ~= true then
            waitHostQt(math.min(timeoutMs, 1500))
        end
        if opts.before_send then
            opts.before_send()
        end
        uart_bridge.sendString(opts.at_cmd, true)
        local got, val = sys.waitUntil(opts.ack_event, timeoutMs)
        if not got then
            sys.wait(200)
            if opts.before_send then
                opts.before_send()
            end
            uart_bridge.sendString(opts.at_cmd, true)
            got, val = sys.waitUntil(opts.ack_event, math.min(timeoutMs, 4000))
        end
        result = opts.on_response(got, val, timeoutMs) or result
        if not got then
            sys.wait(300)
        end
    end)
    state[opts.busy_key] = false
    uartTxnRele()
    if not ok then
        if opts.on_error then
            return opts.on_error(err)
        end
        return opts.default_result
    end
    return result
end
host_query = function(timeoutMs, opts)
    opts.timeout_ms = timeoutMs
    return run_host_query(opts)
end
host_set = function(spec)
    spec = spec or {}
    local busyKey = spec.busy_key
    if busyKey and state[busyKey] then
        return false, "busy", nil
    end
    if busyKey then
        state[busyKey] = true
    end
    local okSet, msg, extra
    local ok, e = pcall(function()
        local cfg = spec.cfg or identity_cfg()
        local timeoutMs = tonumber(spec.timeout_ms)
            or tonumber(cfg[spec.timeout_cfg_key or "query_timeout_ms"])
            or spec.default_timeout
            or 8000
        if not uartTxnAcqu(timeoutMs) then
            okSet, msg = false, "busy"
            return
        end
        local prepOk, prepMsg, atCmd = true, nil, spec.at_cmd
        if spec.prepare then
            prepOk, prepMsg, atCmd = spec.prepare(spec)
        end
        if prepOk == false then
            okSet, msg = false, prepMsg or "invalid"
            return
        end
        if not atCmd or atCmd == "" then
            okSet, msg = false, "missing_at"
            return
        end
        if not ens3XHost(spec.policy_tag, cfg) then
            okSet, msg = false, "t3x_unavailable"
            return
        end
        if spec.wait_boot ~= false and not state.host_at_ready then
            sys.wait(hostBoot(spec.boot_cfg or cfg))
        end
        if not uart_bridge.sendString then
            okSet, msg = false, "no_uart"
            return
        end
        if spec.skip_quiet ~= true then
            waitHostQt(math.min(timeoutMs, 1500))
        end
        uart_bridge.sendString(atCmd, true)
        local got, rsp = sys.waitUntil(spec.ack_event, timeoutMs)
        if (not got or type(rsp) ~= "table") then
            sys.wait(200)
            uart_bridge.sendString(atCmd, true)
            got, rsp = sys.waitUntil(spec.ack_event, math.min(timeoutMs, 4000))
        end
        if not got or type(rsp) ~= "table" then
            okSet, msg = false, "timeout"
            return
        end
        if spec.parse_rsp then
            okSet, msg, extra = spec.parse_rsp(rsp, spec)
            return
        end
        if rsp.ok then
            okSet, msg, extra = true, "ok", rsp
            return
        end
        okSet, msg = false, "error"
    end)
    uartTxnRele()
    if busyKey then
        state[busyKey] = false
    end
    if not ok then
        return false, tostring(e), nil
    end
    return okSet, msg, extra
end

local function cchOnRspn(cache_key, require_parsed)
    return function(got, snap)
        if got and type(snap) == "table" and (not require_parsed or snap.parsed) then
            state[cache_key] = snap
            return snap
        end
        return state[cache_key]
    end
end

local function parse_ok_rsp(rsp)
    if rsp and rsp.ok then
        return true, "ok", rsp
    end
    return false, "error", nil
end

local function cached_host_query(timeoutMs, opts)
    opts = opts or {}
    if opts.cache_key and opts.require_parsed ~= nil and not opts.on_response then
        opts.on_response = cchOnRspn(opts.cache_key, opts.require_parsed)
    end
    opts.require_parsed = nil
    return host_query(timeoutMs, opts)
end
-- 查询/设置命令表驱动工厂：d.at 可为字符串或 function(opts)；生成函数兼容 (timeoutMs) 与 (opts) 两种签名
local function defineQuery(d)
    return function(arg)
        local opts = type(arg) == "table" and arg or nil
        return cached_host_query(opts and opts.timeout_ms or arg, {
            busy_key = d.busy,
            cache_key = d.cache,
            require_parsed = d.parsed,
            policy_tag = d.tag,
            cfg = d.cfg(),
            default_timeout = d.tmo,
            at_cmd = type(d.at) == "function" and d.at(opts or {}) or d.at,
            ack_event = d.ev,
            when_disabled = d.dis,
            before_send = d.pre,
            on_response = d.rsp,
        })
    end
end

local function defineSet(d)
    return function(opts)
        opts = opts or {}
        return host_set({
            busy_key = d.busy,
            policy_tag = d.tag,
            cfg = d.cfg(),
            boot_cfg = d.boot and d.boot() or nil,
            default_timeout = d.tmo,
            timeout_ms = opts.timeout_ms,
            ack_event = d.ev,
            skip_quiet = d.skip_quiet,
            prepare = function()
                return d.prep(opts)
            end,
            parse_rsp = d.parse or parse_ok_rsp,
        })
    end
end

function getCachedHostGb28181Id()
    return state.host_gb28181_id
end
queryHostGb28181 = defineQuery{
    busy = "gb28181_query_busy", cache = "host_gb28181_id",
    tag = "host_identity", cfg = identity_cfg, tmo = 3000,
    at = "AT+GB28181?", ev = SYS_EVT.GB28181_ACK,
    rsp = function(got, id)
        if got and id ~= nil then
            state.host_gb28181_id = id
        end
        return state.host_gb28181_id
    end,
}
local function t3XRecFrom(rec)
    if type(rec) ~= "table" then
        return nil
    end
    if (tonumber(rec.running) or 0) == 1
        or (tonumber(rec.active) or 0) == 1
        or (tonumber(rec.recording) or 0) == 1 then
        return 1
    end
    return 0
end

local function aplTfToCloud(cloud)
    local tf = state.host_tf_card
    if type(tf) ~= "table" or not tf.parsed then
        return cloud
    end
    cloud.tfPresent = (tonumber(tf.present) or 0) == 1 and 1 or 0
    return cloud
end

local function applRcrd(cloud)
    local recActive = t3XRecFrom(state.host_record)
    if recActive == nil then
        return cloud
    end
    cloud.recordingT3x = recActive
    state.t3x_rec_active = recActive
    return cloud
end

local function overLiveIpc(snap)
    if type(snap) ~= "table" then
        return snap
    end
    if state.host_at_ready and (tonumber(snap.cat1Link) or 0) == 0 then
        snap.cat1Link = 1
    end
    local pst = mod_call("t3x_ctrl", "getState")
    if pst and pst.powered_on and (tonumber(snap.cat1Link) or 0) == 0 then
        snap.cat1Link = 1
    end
    local life = state.host_ipc_status
    if life == "ready" and (tonumber(snap.ipcReady) or 0) == 0 then
        snap.ipcReady = 1
    end
    if tonumber(state.t3x_rec_active) == 1 then
        snap.recordingT3x = 1
    end
    snap.wledEnable = wled_get()
    return snap
end

function isIpcCloudStatStale()
    local cached = state.host_ipc_cloud_stat
    local ts = tonumber(state.ipc_cloud_stat_ts) or 0
    if type(cached) ~= "table" or next(cached) == nil then
        return true
    end
    if ts == 0 then
        return true
    end
    if os.time() - ts > (tonumber(ipc_cfg().status_cache_max_age_sec) or 90) then
        return true
    end
    return false
end

function getCloudStat()
    local cached = state.host_ipc_cloud_stat
    if type(cached) == "table" and next(cached) ~= nil then
        cached = normalize_ipc_cloud_stat(cached)
        aplTfToCloud(cached)
        cached = overLiveIpc(cached)
        return cached
    end
    local life = state.host_ipc_status or "idle"
    local ipcReady = (life == "ready") and 1 or 0
    local cat1Link = 0
    if ipcReady == 1 or state.host_at_ready then
        cat1Link = 1
    end
    return overLiveIpc(normalize_ipc_cloud_stat(aplTfToCloud({
        ipcReady = ipcReady,
        gb28181Online = 0,
        tfPresent = 0,
        personDetectEnabled = 0,
        personDetectAvailable = 0,
        timeSynced = 0,
        recordingT3x = (tonumber(state.t3x_rec_active) == 1) and 1 or 0,
        wledEnable = wled_get(),
        cat1Link = cat1Link,
    })))
end

function isT31HostQry()
    if state.host_at_ready then
        return true
    end
    local st = mod_call("t3x_ctrl", "getState")
    return st ~= nil and st.powered_on == true
end

function shouldQueryIpcCloudStat()
    return isT31HostQry()
end

function needsHostIpcStatusRefresh()
    local life = state.host_ipc_status
    if life == "ready" or life == "shutting_down" then
        return false
    end
    return shouldQueryIpcCloudStat()
end

function mrgTfCloudStat()
    local cloud = state.host_ipc_cloud_stat
    if type(cloud) ~= "table" then
        cloud = {}
        state.host_ipc_cloud_stat = cloud
    end
    aplTfToCloud(cloud)
    applRcrd(cloud)
    return cloud
end

function refCloudF1003(timeoutMs, force)
    timeoutMs = tonumber(timeoutMs) or 2500
    force = force == true
    mrgTfCloudStat()
    if not coroutine.running() then
        return type(state.host_ipc_cloud_stat) == "table"
    end
    if not shouldQueryIpcCloudStat() then
        return type(state.host_ipc_cloud_stat) == "table"
    end
    if isHUBusy() then
        return type(state.host_ipc_cloud_stat) == "table"
    end
    if not force and not isIpcCloudStatStale() then
        return true
    end
    if needsHostIpcStatusRefresh() and qryHostStat then
        qryHostStat(math.min(timeoutMs, 1500))
    end
    if queryHostIpcCloudStat then
        queryHostIpcCloudStat(timeoutMs)
    end
    mrgTfCloudStat()
    return type(state.host_ipc_cloud_stat) == "table"
end

function isHUBusy()
    return state.uart_txn_busy == true
        or state.encode_query_busy == true
        or state.encode_set_busy == true
        or state.record_query_busy == true
        or state.recordtime_query_busy == true
        or state.tf_card_query_busy == true
        or state.ipc_status_query_busy == true
        or state.ipc_cloud_stat_query_busy == true
        or state.ipc_poweroff_busy == true
        or state.tfcard_format_busy == true
        or state.uart_recovery_busy == true
        or isHostInbn()
end

function recHostSess(timeoutMs)
    if not mod_call("pir_ctrl", "isRecording") then
        return false
    end
    if not coroutine.running() then
        return false
    end
    if not state.host_at_ready then
        return false
    end
    if isHUBusy() then
        return false
    end
    if not isT31HostQry() then
        return false
    end
    local snap = queryHostRecord(timeoutMs or 3500)
    if type(snap) ~= "table" then
        return false
    end
    local t3xActive = (tonumber(snap.running) or 0) == 1
        or (tonumber(snap.active) or 0) == 1
        or (tonumber(snap.recording) or 0) == 1
    if t3xActive then
        return false
    end
    local reason = snap.reason or state.t3x_last_reason or "sync_idle"
    if reason == "idle" or reason == "no_record" then
        reason = "sync_idle"
    end
    state.t3x_rec_active = 0
    state.t3x_last_reason = reason
    local uploadMode, quality = "auto", "high"
    local pc = loader.load("pir_ctrl")
    if pc and pc.syncStopT3x then
        uploadMode, quality = pc.syncStopT3x(reason)
    end
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_RECORD_STOP or "APP_T3X_RECORD_STOP", reason, uploadMode, quality)
    return true
end

function queryHostIpcCloudStat(timeoutMs)
    local cached = getCloudStat
    return host_query(timeoutMs, {
        busy_key = "ipc_cloud_stat_query_busy",
        busy_return = cached(),
        policy_tag = "host_ipc",
        cfg = ipc_cfg(),
        timeout_cfg_key = "status_query_timeout_ms",
        default_timeout = 2500,
        wait_boot = false,
        at_cmd = "AT+IPCSTAT?",
        ack_event = SYS_EVT.IPCSTAT_ACK,
        default_result = cached(),
        when_disabled = cached,
        on_no_t3x = cached,
        on_no_uart = cached,
        on_response = function(got, snap)
            if got and type(snap) == "table" then
                commitHostIpcCloudStat(snap)
                return snap
            end
            return cached()
        end,
        on_error = cached,
    })
end

function getCachedHostTfCard()
    return state.host_tf_card
end

-- @desc AT 命令分发处理：uartRcvryCfg
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function uartRcvryCfg()
    local c = ipc_cfg()
    local r = c.uart_recovery
    if type(r) ~= "table" then
        r = {}
    end
    return {
        enabled = r.enabled ~= false and c.enabled ~= false,
        miss_threshold = tonumber(r.miss_threshold) or 5,
        max_attempts = tonumber(r.max_attempts) or 3,
        cooldown_sec = tonumber(r.cooldown_sec) or 30,
        power_off_ms = tonumber(r.power_off_ms) or 500,
        power_on_wait_ms = tonumber(r.power_on_wait_ms) or 800,
    }
end

-- @desc AT 命令分发处理：uart_recovery_enabled
-- @param cmd AT 命令字符串（已去除首尾空格）
-- @return 写入 UART 的应答字符串，或 nil 直接 +OK
local function rstUrtRcvr()
    state.ipc_uart_miss_streak = 0
end
note_uart_link_ok = function()
    rstUrtRcvr()
end

local function runUartPwr(attempt)
    local rc = uartRcvryCfg()
    local t3x = loader.load("t3x_ctrl")
    if not t3x then
        return false
    end
    local st = mod_call("t3x_ctrl", "getState")
    if st ~= nil and st.powered_on == true and t3x.powerOff then
        t3x.powerOff()
        sys.wait(rc.power_off_ms)
    end
    if t3x.powerOn then
        t3x.powerOn()
    end
    sys.wait(rc.power_on_wait_ms)
    if t3x.pulseMcuInt then
        t3x.pulseMcuInt()
    end
    if isUsbInse() then
        pushUsbIdleSt(true)
    end
    state.uart_recovery_last_sec = os.time()
    rstUrtRcvr()
    return true
end

local function mybUartRcvr(source)
    if not (uartRcvryCfg().enabled == true) then
        return
    end
    if state.host_ready_seen ~= true then
        return
    end
    if state.host_at_ready then
        return
    end
    if not isUsbInse() then
        rstUrtRcvr()
        return
    end
    if state.uart_recovery_busy then
        return
    end
    local rc = uartRcvryCfg()
    state.ipc_uart_miss_streak = (tonumber(state.ipc_uart_miss_streak) or 0) + 1
    if state.ipc_uart_miss_streak < rc.miss_threshold then
        return
    end
    if state.uart_recovery_attempts >= rc.max_attempts then
        return
    end
    local last = tonumber(state.uart_recovery_last_sec) or 0
    if last > 0 and (os.time() - last) < rc.cooldown_sec then
        return
    end
    state.uart_recovery_busy = true
    state.uart_recovery_attempts = state.uart_recovery_attempts + 1
    sys.taskInit(function()
        pcall(function()
            runUartPwr(state.uart_recovery_attempts)
        end)
        state.uart_recovery_busy = false
    end)
end

function resetHostLinkState()
    state.host_at_ready = false
    state.first_host_at = nil
    state.host_ipc_status = nil
    state.host_ipc_cloud_stat = nil
    rstUrtRcvr()
end

function qryHostStat(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "ipc_status_query_busy",
        busy_return = state.host_ipc_status or "idle",
        policy_tag = "host_ipc",
        cfg = ipc_cfg(),
        timeout_cfg_key = "status_query_timeout_ms",
        default_timeout = 2000,
        wait_boot = false,
        at_cmd = "AT+IPCSTATUS?",
        ack_event = SYS_EVT.IPCSTATUS_ACK,
        default_result = "idle",
        when_disabled = function(cfg)
            if cfg.enabled == false then
                return state.host_at_ready and "ready" or "idle"
            end
        end,
        on_no_t3x = noop_idle,
        on_no_uart = noop_idle,
        on_response = function(got, st)
            if got and st then
                note_uart_link_ok()
                state.host_ipc_status = st
                return st
            end
            state.host_ipc_status = "idle"
            mybUartRcvr("ipc_status")
            return "idle"
        end,
        on_error = noop_idle,
    })
end

function hostIpcPowerOff(playSound, timeoutMs)
    local cfg = ipc_cfg()
    timeoutMs = tonumber(timeoutMs) or tonumber(cfg.poweroff_timeout_ms) or 30000
    if timeoutMs < 5000 then
        timeoutMs = 5000
    end
    if state.ipc_poweroff_busy then
        local got, val = sys.waitUntil(SYS_EVT.IPCPOWEROFF_ACK, timeoutMs)
        return got == true and type(val) == "table" and val.ok == true
    end
    if cfg.enabled == false or not uart_bridge.sendString then
        return false
    end
    state.ipc_poweroff_busy = true
    local success = false
    local ok = pcall(function()
        if not uartTxnAcqu(math.min(timeoutMs, 8000)) then
            return
        end
        local waitBusy = host_now_ms() + math.min(timeoutMs, 3000)
        while host_now_ms() < waitBusy do
            if state.record_query_busy or state.ipc_status_query_busy
                or state.ipc_cloud_stat_query_busy or state.uart_recovery_busy then
                sys.wait(50)
            else
                break
            end
        end
        waitHostQt(math.min(timeoutMs, 2000))
        local cmd = (playSound == false) and "AT+IPCPOWEROFF=0" or "AT+IPCPOWEROFF=1"
        local deadline = host_now_ms() + timeoutMs
        local sends = 0
        local saw_stage = false
        local function tx_once()
            sends = sends + 1
            uart_bridge.sendString("", true)
            sys.wait(40)
            uart_bridge.sendString(cmd, true)
        end
        tx_once()
        local nextRetry = host_now_ms() + 2000
        while host_now_ms() < deadline do
            local remain = deadline - host_now_ms()
            if remain <= 0 then
                break
            end
            local slice = remain
            if (not saw_stage) and sends < 3 and (nextRetry - host_now_ms()) > 0 then
                slice = math.min(slice, nextRetry - host_now_ms())
            end
            if slice < 20 then
                slice = 20
            end
            local got, val = sys.waitUntil(SYS_EVT.IPCPOWEROFF_ACK, slice)
            if got then
                if val == true or (type(val) == "table" and val.ok == true) then
                    success = true
                    break
                end
                if type(val) == "table" and val.stage then
                    saw_stage = true
                elseif type(val) == "table" and val.error == true then
                    if saw_stage then
                        if log and log.info then
                            log.info("host_uart", "ipcpoweroff_rx", "ignore_err_after_stage", val.line or "error")
                        end
                    else
                        if log and log.info then
                            log.info("host_uart", "ipcpoweroff_rx", "abort", val.line or "error")
                        end
                        break
                    end
                end
            elseif (not saw_stage) and sends < 3 and host_now_ms() >= nextRetry then
                tx_once()
                nextRetry = host_now_ms() + 2000
            end
        end
    end)
    uartTxnRele()
    state.ipc_poweroff_busy = false
    if success then
        state.host_ipc_status = "idle"
        state.t3x_rec_active = 0
        if pchCloudStat then
            pchCloudStat({ recordingT3x = 0, ipcReady = 0 })
        end
    end
    if not ok then
        return false
    end
    return success
end

function waitHostIpcReady(timeoutMs, pollMs)
    local cfg = ipc_cfg()
    if cfg.enabled == false then
        return state.host_at_ready == true
    end
    timeoutMs = tonumber(timeoutMs) or tonumber(cfg.ready_wait_timeout_ms) or 120000
    pollMs = tonumber(pollMs) or tonumber(cfg.ready_poll_ms) or 1000
    local deadline = (mcu and mcu.ticks and (mcu.ticks() + timeoutMs)) or nil
    local start = os.time()
    while true do
        local st = qryHostStat(tonumber(cfg.status_query_timeout_ms) or 2000)
        if st == "ready" then
            return true
        end
        if deadline and mcu and mcu.ticks then
            if mcu.ticks() >= deadline then
                return false
            end
        elseif (os.time() - start) * 1000 >= timeoutMs then
            return false
        end
        sys.wait(pollMs)
    end
end

local function record_cfg()
    return _G.HOST_RECORD_CFG or {}
end

function getT3xRecActive()
    if tonumber(state.t3x_rec_active) == 1 then
        return 1
    end
    local cloud = state.host_ipc_cloud_stat
    if type(cloud) == "table" and tonumber(cloud.recordingT3x) == 1 then
        return 1
    end
    return 0
end
queryHostRecord = defineQuery{
    busy = "record_query_busy", cache = "host_record",
    tag = "host_record", cfg = record_cfg, tmo = 3000,
    at = "AT+RECORD?", ev = SYS_EVT.RECORD_ACK,
    dis = function(cfg)
        if cfg.enabled == false then
            return state.host_record
        end
    end,
    rsp = function(got, snap)
        if got and type(snap) == "table" then
            state.host_record = snap
            return snap
        end
        return nil
    end,
}
queryHostRecordTime = defineQuery{
    busy = "recordtime_query_busy", cache = "host_record_time", parsed = true,
    tag = "host_recordtime", cfg = record_cfg, tmo = 3000,
    at = "AT+RECORDTIME?", ev = SYS_EVT.RECORDTIME_ACK,
    dis = function(cfg)
        if cfg.enabled == false then
            return state.host_record_time
        end
    end,
}
setHostRecordTime = defineSet{
    busy = "recordtime_set_busy", tag = "host_recordtime_set",
    cfg = record_cfg, tmo = 3000, ev = SYS_EVT.RECORDTIME_SET,
    prep = function(o)
        local min = tonumber(o.minutes or o.recTime or o.recordTimeMin)
        if min == nil then
            return false, "missing_min"
        end
        return true, nil, string.format("AT+RECORDTIME=%d", min)
    end,
    parse = function(rsp)
        if rsp.ok then
            state.host_record_time = rsp
            return true, "ok", { minutes = rsp.minutes }
        end
        if rsp.invalid then
            return false, "invalid_minute", nil
        end
        return false, "error", nil
    end,
}
queryHostFramerate = defineQuery{
    busy = "framerate_query_busy", cache = "host_framerate",
    tag = "host_framerate", cfg = encode_cfg, tmo = 5000,
    ev = SYS_EVT.FRAMERATE_QUERY,
    at = function(o)
        local cam, stream = tonumber(o.camera), tonumber(o.stream)
        if cam and stream then
            return string.format("AT+FRAMERATE?=%d,%d", cam, stream)
        end
        if cam then
            return string.format("AT+FRAMERATE?=%d", cam)
        end
        return "AT+FRAMERATE?"
    end,
    pre = function()
        state.framerate_rows = {}
    end,
    rsp = function(got, rows)
        if got and type(rows) == "table" then
            state.host_framerate = rows
            return rows
        end
        return state.host_framerate
    end,
}
setHostFramerate = defineSet{
    busy = "framerate_set_busy", tag = "host_framerate_set",
    cfg = encode_cfg, tmo = 8000, ev = SYS_EVT.FRAMERATE_SET,
    prep = function(o)
        local fps = tonumber(o.framerate or o.fps)
        if fps == nil then
            return false, "missing_framerate"
        end
        return true, nil, string.format("AT+FRAMERATE=%d,%d,%d",
            tonumber(o.camera) or 0, tonumber(o.stream) or 0, fps)
    end,
}
recordCtrlStart = defineSet{
    tag = "host_recordctrl_start", cfg = identity_cfg, boot = record_cfg,
    tmo = 8000, ev = SYS_EVT.RECORDCTRL_SET, skip_quiet = true,
    prep = function(o)
        return true, nil, string.format("AT+RECORDCTRL=1,%d",
            tonumber(o.max_sec or o.videoMaxDurationSec) or 60)
    end,
    parse = function(rsp)
        if rsp.ok and rsp.start == 1 then
            return true, "ok", rsp
        end
        return false, "error", rsp
    end,
}
recordCtrlStop = defineSet{
    tag = "host_recordctrl_stop", cfg = identity_cfg, boot = record_cfg,
    tmo = 22000, ev = SYS_EVT.RECORDCTRL_SET, skip_quiet = true,
    prep = function(o)
        return true, nil, string.format("AT+RECORDCTRL=0,%s", tostring(o.reason or "cloud"))
    end,
    parse = function(rsp)
        if rsp.ok and rsp.start == 0 then
            return true, "ok", rsp
        end
        return false, "error", rsp
    end,
}
requestUploadVideo = defineSet{
    tag = "host_uploadvideo", cfg = identity_cfg, boot = record_cfg,
    tmo = 12000, ev = SYS_EVT.UPLOADVIDEO_SET, skip_quiet = true,
    prep = function(o)
        local need = tonumber(o.needUpload or o.need) or 1
        need = (need == 0) and 0 or 1
        local vtype = tonumber(o.videoType or o.vtype) or 2
        if vtype ~= 1 then
            vtype = 2
        end
        local startTs = tonumber(o.start_ts or o.beginTs) or 0
        local endTs = tonumber(o.end_ts or o.endTs) or 0
        local maxSec = tonumber(o.max_sec or o.videoMaxDurationSec) or 0
        local mid = tostring(o.messageId or o.msgid or ""):gsub("[^%w%-_]", "")
        if #mid > 40 then
            mid = mid:sub(1, 40)
        end
        return true, nil, string.format("AT+UPLOADVIDEO=%d,%d,%d,%d,%d,%s",
            need, vtype, startTs, endTs, maxSec, mid)
    end,
    parse = function(rsp)
        if rsp and rsp.ok then
            return true, "ok", rsp
        end
        return false, "error", rsp
    end,
}
queryHostPersonDetect = defineQuery{
    busy = "persondet_query_busy", cache = "host_person_detect", parsed = true,
    tag = "host_persondet", cfg = identity_cfg, tmo = 5000,
    at = "AT+PERSONDET?", ev = SYS_EVT.PERSONDET_ACK,
}
setHostPersonDetect = defineSet{
    busy = "persondet_set_busy", tag = "host_persondet_set",
    cfg = identity_cfg, tmo = 5000, ev = SYS_EVT.PERSONDET_SET,
    prep = function(o)
        local enable = tonumber(o.enable)
        if enable == nil or (enable ~= 0 and enable ~= 1) then
            return false, "invalid_enable"
        end
        return true, nil, string.format("AT+PERSONDET=%d", enable)
    end,
}
queryHostMic = defineQuery{
    busy = "mic_query_busy", cache = "host_mic", parsed = false,
    tag = "host_mic", cfg = identity_cfg, tmo = 8000,
    ev = SYS_EVT.MIC_QUERY,
    at = function(o)
        local cam = tonumber(o.camera)
        return cam and string.format("AT+MIC?=%d", cam) or "AT+MIC?"
    end,
    pre = function()
        state.mic_rows = {}
    end,
}
setHostMic = defineSet{
    busy = "mic_set_busy", tag = "host_mic_set",
    cfg = identity_cfg, tmo = 8000, ev = SYS_EVT.MIC_SET,
    prep = function(o)
        local volume, gain = tonumber(o.volume), tonumber(o.gain)
        if volume == nil or gain == nil then
            return false, "missing_params"
        end
        return true, nil, string.format("AT+MICSET=%d,%d,%d", tonumber(o.camera) or 0, volume, gain)
    end,
}
queryHostSoftPhoto = defineQuery{
    busy = "softphoto_query_busy", cache = "host_softphoto", parsed = true,
    tag = "host_softphoto", cfg = identity_cfg, tmo = 8000,
    at = "AT+SOFTPHOTO?", ev = SYS_EVT.SOFTPHOTO_QUERY,
}
setHostSoftPhoto = defineSet{
    busy = "softphoto_set_busy", tag = "host_softphoto_set",
    cfg = identity_cfg, tmo = 8000, ev = SYS_EVT.SOFTPHOTO_SET,
    prep = function(o)
        local fields = {
            tonumber(o.enable),
            tonumber(o.nightModeThreshold or o.night_mode_threshold),
            tonumber(o.dayModeThreshold or o.day_mode_threshold),
            tonumber(o.dayModeAltThreshold or o.day_mode_alt_threshold),
            tonumber(o.gbGainThreshold or o.gb_gain_threshold),
            tonumber(o.gbGainRecordInit or o.gb_gain_record_init),
            tonumber(o.checkTime or o.check_time),
            tonumber(o.checkCount or o.check_count),
        }
        for i = 1, 8 do
            if fields[i] == nil then
                return false, "missing_params"
            end
        end
        return true, nil, string.format(
            "AT+SOFTPHOTOSET=%d,%d,%d,%d,%d,%d,%d,%d",
            fields[1], fields[2], fields[3], fields[4],
            fields[5], fields[6], fields[7], fields[8])
    end,
}
queryHostTfCard = defineQuery{
    busy = "tf_card_query_busy", cache = "host_tf_card",
    tag = "host_tfcard", cfg = tf_card_cfg, tmo = 3000,
    at = "AT+TFCARD?", ev = SYS_EVT.TFCARD_ACK,
    rsp = function(got, snap)
        if got and type(snap) == "table" and snap.parsed then
            state.host_tf_card = snap
            return snap
        end
        return nil
    end,
}
local function nrmlLuaErrr(err)
    local s = tostring(err or "error")
    local tail = s:match(": ([^:]+)$")
    if tail and tail ~= "" then
        return tail
    end
    return s
end

function formatHostTfCard(opts)
    opts = utils.optTable(opts)
    local cfg = _G.HOST_TFCARD_FORMAT_CFG or {}
    if cfg.enabled == false then
        return false, "disabled"
    end
    if state.tfcard_format_busy then
        return false, "busy"
    end
    if t3xSectOff() then
        return false, "no_uart"
    end
    if not ens3XHost("host_tfcard_format", cfg) then
        return false, "t3x_unavailable"
    end
    local timeoutMs = tonumber(opts.timeout_ms) or tonumber(cfg.format_timeout_ms) or 120000
    local reboot = opts.reboot
    if reboot == nil then
        reboot = cfg.reboot_after == true or cfg.reboot_after == 1
    end
    reboot = utils.parseBoolLike(reboot) and 1 or 0
    state.tfcard_format_busy = true
    local outcome = { ok = false, reason = "unknown" }
    local okRun, errRun = pcall(function()
        if opts.wait_boot ~= false and not state.host_at_ready then
            sys.wait(hostBoot(cfg))
        end
        if not uart_bridge.sendString then
            error("no_uart")
        end
        waitHostQt(2000)
        local atCmd = string.format("AT+TFFORMAT=1,reboot=%d", reboot)
        uart_bridge.sendString(atCmd, true)
        local deadline = (os.time() * 1000) + timeoutMs
        local strtDdln = (os.time() * 1000) + 8000
        local started = false
        while (os.time() * 1000) < deadline do
            if not started and (os.time() * 1000) >= strtDdln then
                error("no_started")
            end
            local remain = deadline - (os.time() * 1000)
            if remain <= 0 then
                break
            end
            local slice = remain > 5000 and 5000 or remain
            local got, val = sys.waitUntil(SYS_EVT.TFFORMAT_ACK, slice)
            if got and type(val) == "table" then
                if val.phase == "started" then
                    started = true
                elseif val.phase == "ok" then
                    outcome.ok = true
                    outcome.detail = val
                    return
                elseif val.phase == "error" then
                    error(tostring(val.ret or "ipc_error"))
                end
            end
        end
        if not started then
            error("no_started")
        end
        error("timeout")
    end)
    state.tfcard_format_busy = false
    if outcome.ok then
        return true, outcome.detail
    end
    if not okRun then
        return false, nrmlLuaErrr(errRun)
    end
    return false, outcome.reason
end
-- 以下编码相关函数不用 local：本文件顶层 local 已贴 LuatOS 200 上限
function encode_timeout_ms(opts)
    opts = opts or {}
    local cfg = encode_cfg()
    return tonumber(opts.timeout_ms) or tonumber(cfg.query_timeout_ms) or 8000
end

function encode_rows_valid(rows, isAudio)
    if type(rows) ~= "table" or rows.__error then
        return false
    end
    if #rows == 0 then
        return false
    end
    for _, row in ipairs(rows) do
        if type(row) == "table" then
            return true
        end
    end
    return false
end

function finish_encode_query(rows, isAudio)
    if type(rows) == "table" and rows.__error then
        return nil, rows.__error
    end
    if not encode_rows_valid(rows, isAudio) then
        return nil, "empty_encode"
    end
    if isAudio then
        return { audio = rows }, nil
    end
    return { video = rows }, nil
end

function build_encode_query_cmd(opts)
    opts = opts or {}
    if opts.scope == "audio" then
        if opts.camera ~= nil then
            return "AT+AUDIO?=" .. tonumber(opts.camera)
        end
        return "AT+AUDIO?"
    end
    if opts.camera ~= nil and opts.stream ~= nil then
        return string.format("AT+VENC?=%d,%d", tonumber(opts.camera), tonumber(opts.stream))
    end
    if opts.camera ~= nil then
        return "AT+VENC?=" .. tonumber(opts.camera)
    end
    return "AT+VENC?"
end

function queryHostEncodeInner(opts)
    opts = opts or {}
    local isAudio = opts.scope == "audio"
    local cfg = encode_cfg()
    local at_cmd = build_encode_query_cmd(opts)
    local ack_event = isAudio and SYS_EVT.AUDIO_QUERY or SYS_EVT.VENC_QUERY
    local last_err = "timeout"
    local function reset_rows()
        if isAudio then
            state.encode_audio_rows = {}
        else
            state.encode_venc_rows = {}
        end
    end
    local result = host_query(opts.timeout_ms, {
        busy_key = "encode_query_busy",
        policy_tag = "host_encode",
        cfg = cfg,
        timeout_cfg_key = "query_timeout_ms",
        default_timeout = 8000,
        at_cmd = at_cmd,
        ack_event = ack_event,
        before_send = reset_rows,
        on_response = function(got, val)
            if not got then
                last_err = "timeout"
                return nil
            end
            local body, err = finish_encode_query(val, isAudio)
            if body then
                return body
            end
            last_err = err or "empty_encode"
            return nil
        end,
    })
    if result then
        return result, nil
    end
    return nil, last_err
end

function queryHostEncode(opts)
    local result, err = queryHostEncodeInner(opts)
    if result then
        return result, err
    end
    return nil, err or "query_fail"
end

function setHostEncode(scope, opts)
    opts = opts or {}
    local timeoutMs = encode_timeout_ms(opts)
    local isAudio = scope == "audio"
    return host_set({
        busy_key = "encode_set_busy",
        policy_tag = "host_encode_set",
        cfg = identity_cfg(),
        boot_cfg = encode_cfg(),
        default_timeout = 8000,
        timeout_ms = timeoutMs,
        ack_event = isAudio and SYS_EVT.AUDIO_SET or SYS_EVT.VENC_SET,
        prepare = function()
            local cam = tonumber(opts.camera) or 0
            local cur
            if isAudio then
                if opts.encoder == nil or opts.samplerate == nil then
                    local q, qerr = queryHostEncodeInner({ scope = "audio", camera = cam, timeout_ms = timeoutMs })
                    if q and q.audio and q.audio[1] then
                        cur = q.audio[1]
                    elseif qerr then
                        return false, qerr
                    end
                end
                cur = cur or {}
                local en = opts.enable
                if en == nil then en = cur.enable or 1 end
                return true, nil, string.format("AT+AUDIOSET=%d,%d,%d,%d,%d,%d,%d,%d",
                    cam, (en == true or en == 1) and 1 or 0,
                    tonumber(opts.encoder or cur.encoder) or 4,
                    tonumber(opts.samplerate or cur.samplerate) or 8000,
                    tonumber(opts.bitwidth or cur.bitwidth) or 16,
                    tonumber(opts.soundmode or cur.soundmode) or 1,
                    tonumber(opts.volume or cur.volume) or 80,
                    tonumber(opts.gain or cur.gain) or 28)
            end
            local stream = tonumber(opts.stream) or 0
            if opts.width == nil or opts.height == nil or opts.bitrate == nil then
                local q, qerr = queryHostEncodeInner({ camera = cam, stream = stream, timeout_ms = timeoutMs })
                if q and q.video and q.video[1] then
                    cur = q.video[1]
                elseif qerr then
                    return false, qerr
                end
            end
            cur = cur or {}
            local en = opts.enable
            if en == nil then en = cur.enable or 1 end
            return true, nil, string.format("AT+VENCSET=%d,%d,%d,%d,%d,%d,%d,%d,%d",
                cam, stream, (en == true or en == 1) and 1 or 0,
                tonumber(opts.width or cur.width) or 1920,
                tonumber(opts.height or cur.height) or 1080,
                tonumber(opts.bitrate or cur.bitrate) or 1200,
                tonumber(opts.framerate or cur.framerate) or 25,
                tonumber(opts.rcmode or cur.rcmode) or 2,
                tonumber(opts.encoder or cur.encoder) or 4)
        end,
    })
end

function setHostVideoEncode(opts)
    return setHostEncode("video", opts)
end

function setHostAudioEncode(opts)
    return setHostEncode("audio", opts)
end

function start(opts)
    if started then
        return true
    end
    opts = opts or {}
    t3xModule = opts.t3x or require "t3x_ctrl"
    state.host_at_ready = false
    state.first_host_at = nil
    bindStrtHks(opts)
    uart_bridge.setOnLine(on_uart_line)
    started = true
    return true
end

function stop()
    if not started then
        return false
    end
    uart_bridge.setOnLine(nil)
    started = false
    return true
end

local function wrt3XNtf(tpl, val)
    local writeFn = hooks.uart_write
    if not writeFn and package.loaded.uart_bridge then
        writeFn = package.loaded.uart_bridge.write
    end
    if not writeFn then
        return false
    end
    local line = string.format(tpl, val and 1 or 0)
    if not line:find("\r\n", 1, true) then
        line = line .. CRLF
    end
    writeFn(line)
    return true
end

function pushUsbIdleSt(inserted)
    local cfg = host_usb_cfg()
    if cfg.notify_t3x_usb_state == false then
        return false
    end
    return wrt3XNtf(cfg.t3x_usb_ursp or "+CAT1:USB,%d", inserted)
end

function isUsbInserted()
    return isUsbInse()
end

function pushNetLedSt(online)
    local cfg = _G.LED_CFG or {}
    if cfg.notify_t3x_net_led ~= true then
        return false
    end
    return wrt3XNtf(cfg.t3x_net_ursp or "+CAT1:MQTT,%d", online)
end

function notify_host(sid, evt)
    local cfg = _G.HOST_WAKE_CFG or {}
    sid = sid or cfg.default_sid or 1
    evt = evt or _M.EVT.SERVER_DATA
    if mod_call("t3x_policy", "mayPowerT3x", "notify_host") == false then
        return false
    end
    setPndnWake(sid, evt)
    if not t3xModule then
        t3xModule = require "t3x_ctrl"
    end
    if t3xModule.getState and not t3xModule.getState().powered_on and t3xModule.powerOn then
        t3xModule.powerOn()
    end
    mod_call("battery_guard", "markT3xWoken")
    if t3xModule.pulseMcuInt then
        return t3xModule.pulseMcuInt()
    end
    return false
end

function getState()
    return {
        started = started,
        host = {
            pending_valid = state.pending_valid,
            pending_sid = state.pending_sid,
            pending_evt = state.pending_evt,
            passthrough = state.passthrough,
            channel = state.channel,
            last_command = state.last_command,
            hex_report = state.hex_report,
        },
        uart = uart_bridge.getState(),
    }
end
return _M
