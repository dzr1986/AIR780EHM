--- 主机串口：AT/HEX/STR 协议 + uart_bridge + GPIO 唤醒
-- 分发：AT_CMD_TABLE / RX_LINE_HANDLER_REGISTRY
--       见 doc/modules/HOST_UART_AT_DISPATCH.md
-- @module host_uart

require "sys"
require "config"

local uart_bridge = require "uart_bridge"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "host_uart"
local CRLF = "\r\n"
local RSP_ERROR = CRLF .. "ERROR" .. CRLF
local RSP_SETCFG_OK = CRLF .. "+SETCFG:OK" .. CRLF
local RSP_SETCFG_ERR = CRLF .. "+SETCFG:ERROR" .. CRLF
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
}

local started = false
local t3xModule = nil

--- 前向声明（notify handler 在文件前部，解析函数在后部）
local normalize_ipc_cloud_stat
local parse_ipcstat_line
local parse_tfcard_line
local note_uart_link_ok

local HOST_PUSH_QUIET_MS = 1500

local function host_now_ms()
    if mcu and mcu.ticks then
        return mcu.ticks()
    end
    return os.time() * 1000
end

local function note_host_inbound_push()
    state.host_push_quiet_until = host_now_ms() + HOST_PUSH_QUIET_MS
end

local function isHostInboundQuiet()
    local until_ms = tonumber(state.host_push_quiet_until) or 0
    if until_ms <= 0 then
        return false
    end
    return host_now_ms() < until_ms
end

-- ---------------------------------------------------------------------------
-- 应答与工具
-- ---------------------------------------------------------------------------

local function ok_tail()
    return CRLF .. "OK" .. CRLF
end

local function rsp_body(tag, body)
    return CRLF .. "+" .. tag .. ":" .. body .. CRLF .. ok_tail()
end

local function rsp_fmt(tag, fmt, ...)
    return string.format(CRLF .. "+" .. tag .. ":" .. fmt .. CRLF, ...) .. ok_tail()
end

local function rsp_line(tag, ok)
    if ok then
        return CRLF .. "+" .. tag .. ":OK" .. CRLF
    end
    return CRLF .. "+" .. tag .. ":ERROR" .. CRLF
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

local usbPolicyCache
local function usb_policy_mod()
    if usbPolicyCache == nil then
        local ok, mod = pcall(require, "usb_policy")
        usbPolicyCache = ok and type(mod) == "table" and mod or false
    end
    return usbPolicyCache ~= false and usbPolicyCache or nil
end

local function is_usb_inserted()
    local up = usb_policy_mod()
    if up and up.isUsbInserted then
        return up.isUsbInserted()
    end
    local rt = _G.APP_RUNTIME or {}
    return tonumber(rt.power_status) == 1
end

local function usb_blocks_host_idle()
    local up = usb_policy_mod()
    if up and up.blocksHostIdle then
        return up.blocksHostIdle()
    end
    return is_usb_inserted()
end

local function get_config_snapshot()
    local meta = _G.APP_META or {}
    local rt = _G.APP_RUNTIME or {}
    local tcp_extra = ""
    local okLp, lpw = pcall(require, "low_power_wakeup")
    if okLp and lpw and lpw.appendGetCfgFields then
        tcp_extra = lpw.appendGetCfgFields()
    end
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
        tcp_extra = tcp_extra,
    }
end

local function parse_servcreate_args(args)
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

-- ---------------------------------------------------------------------------
-- 唤醒 pending
-- ---------------------------------------------------------------------------

local function set_pending_wake(sid, evt)
    state.pending_sid = tonumber(sid) or 1
    state.pending_evt = tonumber(evt) or 0
    state.pending_valid = true
    log.info(LOG_TAG, "pending_evt", state.pending_sid, state.pending_evt)
end

local function clear_pending_wake()
    state.pending_valid = false
    state.pending_evt = -1
end

--- 供 host_event / PIRSTAT 读取 pending HOSTEVT（不清除；消费走 AT+HOSTEVT? + AT+HOSTEVTCLR）
function getHostEvtPending()
    if state.pending_valid then
        return true, state.pending_sid, state.pending_evt
    end
    return false, 0, -1
end

local function echo_rx_hex_if_enabled(data)
    if not state.hex_report or not hooks.uart_write or not data then
        return
    end
    hooks.uart_write(CRLF .. "+RXHEX:" .. encode_hex(data) .. CRLF)
end

-- ---------------------------------------------------------------------------
-- AT / 简写行处理
-- ---------------------------------------------------------------------------

local function uart_at_ack(_cmd)
    return ok_tail()
end

local function pir_field_str(pirBody, key, default)
    if not pirBody or pirBody == "" then
        return default
    end
    return pirBody:match(key .. "=([^,]+)") or default
end

local function pir_field_int(pirBody, key, default)
    local v = pir_field_str(pirBody, key, nil)
    return v and tonumber(v) or default
end

--- 从 pir_runtime body 提取 T3x media_dispatch 所需字段（与 PIRSTAT 同源）
local function build_hostevt_media_suffix(pirBody)
    if not pirBody or pirBody == "" then
        return ",recording=0,action=video,max_sec=60,last_stop=none"
    end
    return string.format(",recording=%d,action=%s,max_sec=%d,last_stop=%s,last=%s",
        pir_field_int(pirBody, "recording", 0),
        pir_field_str(pirBody, "action", "video"),
        pir_field_int(pirBody, "max_sec", 60),
        pir_field_str(pirBody, "last_stop", "none"),
        pir_field_str(pirBody, "last", "none"))
end

local function build_pir_wake_context()
    local pirBody = ""
    local ok, pir = pcall(require, "pir_ctrl")
    if ok and pir and pir.buildAtBody then
        pirBody = pir.buildAtBody()
    end
    local wakeValid, wakeSid, wakeEvt = getHostEvtPending()
    local sum
    local he
    local okHe, heMod = pcall(require, "host_event")
    if okHe and heMod and heMod.summarize then
        he = heMod
        sum = heMod.summarize(pirBody, wakeValid, wakeSid, wakeEvt)
    end
    return pirBody, wakeValid, wakeSid, wakeEvt, sum, he
end

local function build_pir_wake_body(hostevt)
    local pirBody, wakeValid, wakeSid, wakeEvt, sum, he = build_pir_wake_context()
    local media = build_hostevt_media_suffix(pirBody)
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

local function build_hostevt_body()
    return build_pir_wake_body(true)
end

function buildHostEvtBody()
    return build_hostevt_body()
end

local function uart_hostevt_query(_cmd)
    return rsp_body("HOSTEVT", build_hostevt_body())
end

local function uart_hostevt_clr(_cmd)
    clear_pending_wake()
    local ok, pir = pcall(require, "pir_ctrl")
    if ok and pir and pir.clearConsumableMarkers then
        pir.clearConsumableMarkers()
    end
    return rsp_body("HOSTEVTCLR", "OK")
end

local DEFAULT_MIN_UNIX = 1704067200

local function uart_time_query(_cmd)
    local minTs = (_G.TIME_SYNC_CFG and _G.TIME_SYNC_CFG.min_valid_unix) or DEFAULT_MIN_UNIX
    local t = os.time()
    if t < minTs then
        return CRLF .. "+TIME:0" .. CRLF .. ok_tail()
    end
    return string.format(CRLF .. "+TIME:%d" .. CRLF, t) .. ok_tail()
end

local function get_device_imei()
    local ok, did = pcall(require, "device_id")
    if ok and type(did) == "table" and did.getImei then
        return did.getImei()
    end
    return nil
end

function getDeviceImei()
    return get_device_imei()
end

local function uart_imei(_cmd)
    local imei = get_device_imei()
    if not imei then
        return RSP_ERROR
    end
    return rsp_fmt("IMEI", "%s", imei)
end

local function esc_ipc_field(s)
    s = tostring(s or "")
    return (s:gsub(",", "_"):gsub("=", "_"))
end

--- P2P UID：固定 8 位，允许大小写字母与数字（如 DDDDDDDD、JFZTQ5U5）
local function is_valid_p2p_uid(uid)
    return type(uid) == "string" and #uid == 8 and uid:match("^[A-Za-z0-9]+$") ~= nil
end

--- P2P product：1~31 位数字（如 2025001），按字符串保存，不做数值上界截断
local function is_valid_p2p_product(product)
    return type(product) == "string"
        and #product >= 1 and #product <= 31
        and product:match("^[0-9]+$") ~= nil
end

local function is_valid_gb28181_device_id(id)
    return type(id) == "string"
        and #id >= 10 and #id <= 20
        and id:match("^[0-9]+$") ~= nil
end

local function is_valid_gb28181_password(pwd)
    return type(pwd) == "string" and #pwd >= 1 and #pwd <= 63
        and pwd:match("^[%w%p]+$") ~= nil
end

local function is_valid_imei(imei)
    return type(imei) == "string" and #imei == 15 and imei:match("^[0-9]+$") ~= nil
end

local function parse_gb28181cfg_body(body)
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

--- T3x 下发 P2P 身份：AT+P2PCFG=<uid>,<product>
local function uart_p2pcfg(cmd)
    local uid, product = cmd:match("^AT%+P2PCFG=([^,]+),([^,]+)$")
    if not uid or not product then
        return RSP_ERROR
    end
    if not is_valid_p2p_uid(uid) or not is_valid_p2p_product(product) then
        log.warn(LOG_TAG, "p2pcfg_invalid", uid or "", product or "")
        return RSP_ERROR
    end
    state.p2p_uid = uid
    state.p2p_product = product
    log.info(LOG_TAG, "p2pcfg_ok", uid, product)
    local E = _G.APP_EVENTS or {}
    sys.publish(E.HOST_NET_ID_P2P or "APP_HOST_NET_ID_P2P", uid, product)
    return string.format(
        CRLF .. "+P2PCFG:OK,uid=%s,product=%s" .. CRLF,
        esc_ipc_field(uid), esc_ipc_field(product)
    ) .. ok_tail()
end

--- T3x 下发 GB28181 身份：AT+GB28181CFG=<device_id>,<password>[,<imei>]
local function uart_gb28181cfg(cmd)
    local body = cmd:match("^AT%+GB28181CFG=(.+)$")
    local device_id, password, imei = parse_gb28181cfg_body(body)
    if not device_id or not password then
        return RSP_ERROR
    end
    if not is_valid_gb28181_device_id(device_id)
            or not is_valid_gb28181_password(password) then
        log.warn(LOG_TAG, "gb28181cfg_invalid", device_id or "")
        return RSP_ERROR
    end
    if imei and imei ~= "" and not is_valid_imei(imei) then
        log.warn(LOG_TAG, "gb28181cfg_imei_invalid", imei)
        return RSP_ERROR
    end
    state.host_gb28181_id = device_id
    state.gb28181_password = password
    state.gb28181_imei = (imei and imei ~= "") and imei or nil
    log.info(LOG_TAG, "gb28181cfg_ok", device_id, imei or "")
    local E = _G.APP_EVENTS or {}
    sys.publish(
        E.HOST_NET_ID_GB28181 or "APP_HOST_NET_ID_GB28181",
        device_id, password, state.gb28181_imei
    )
    return string.format(
        CRLF .. "+GB28181CFG:OK,id=%s" .. CRLF,
        esc_ipc_field(device_id)
    ) .. ok_tail()
end

local function schedule_gb28181_refresh_if_needed()
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

local function uart_ipcinfo_query(_cmd)
    local imei = get_device_imei() or ""
    local gb28181Id = state.host_gb28181_id or ""
    schedule_gb28181_refresh_if_needed()
    local body = string.format(
        "imei=%s,gb28181Id=%s",
        esc_ipc_field(imei),
        esc_ipc_field(gb28181Id)
    )
    local cfg = identity_cfg()
    if cfg.publish_on_ipcinfo_query == true then
        sys.taskInit(function()
            local ok, net = pcall(require, "net_mqtt")
            if ok and net and net.refreshAndPublishDeviceIdentity then
                if gb28181Id == "" then
                    queryHostGb28181(cfg.query_timeout_ms)
                end
                net.refreshAndPublishDeviceIdentity(nil)
            end
        end)
    end
    return rsp_body("IPCINFO", body)
end

local function uart_mqttpub(cmd)
    local suffix, body = cmd:match("^AT%+MQTTPUB=([^;]+);(.+)$")
    if not suffix or not body or body == "" then
        return CRLF .. "+MQTTPUB:ERROR" .. CRLF
    end
    local ok, net = pcall(require, "net_mqtt")
    if not ok or type(net) ~= "table" or not net.publishRaw then
        return CRLF .. "+MQTTPUB:ERROR" .. CRLF
    end
    if net.publishRaw(suffix, body, 1) then
        return CRLF .. "+MQTTPUB:OK" .. CRLF
    end
    return CRLF .. "+MQTTPUB:ERROR" .. CRLF
end

--- AT+MQTTCFG=host;port;ssl;user;password;client_id（字段以 ; 分隔，密码勿含 ;）
local function parse_mqttcfg_body(body)
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

local function uart_mqttcfg(cmd)
    local cfg = parse_mqttcfg_body(cmd:match("^AT%+MQTTCFG=(.+)$"))
    if not cfg then
        return rsp_line("mqtt_config_uart", false)
    end
    log.info(LOG_TAG, "mqtt_config_uart", cfg.host, cfg.port, cfg.ssl and 1 or 0)
    if hooks.on_mqtt_cfg then
        hooks.on_mqtt_cfg(cfg)
    end
    return rsp_line("mqtt_config_uart", true) .. ok_tail()
end

local function uart_servcreate(cmd)
    local okLp, lpw = pcall(require, "low_power_wakeup")
    if okLp and lpw and lpw.allowTcpChannel and not lpw.allowTcpChannel() then
        log.info(LOG_TAG, "server_channel_disabled")
        return rsp_body("server_channel_add", "DISABLED")
    end
    local ch = parse_servcreate_args(cmd:match("^AT%+SERVCREATE=(.+)$"))
    if not ch then
        return RSP_ERROR
    end
    state.channel = ch
    log.info(LOG_TAG, "server_channel_add", ch.sid, ch.server_ip, ch.server_port)
    if hooks.on_servcreate then
        hooks.on_servcreate(ch)
    elseif okLp and lpw and lpw.applyTcpChannel then
        lpw.applyTcpChannel(ch)
    end
    return string.format(CRLF .. "+SERVCREATE:%d,OK" .. CRLF, ch.sid) .. ok_tail()
end

local function uart_servclose(cmd)
    local sid = tonumber(cmd:match("^AT%+SERVCLOSE=(%d+)$"))
    if not sid then
        return RSP_ERROR
    end
    local okLp, lpw = pcall(require, "low_power_wakeup")
    if okLp and lpw and lpw.allowTcpChannel and not lpw.allowTcpChannel() then
        log.info(LOG_TAG, "server_channel_link_disabled", sid)
        state.channel = nil
        return rsp_body("server_channel_remove", "DISABLED")
    end
    log.info(LOG_TAG, "server_channel_remove", sid)
    if hooks.on_servclose then
        hooks.on_servclose(sid)
    elseif okLp and lpw and lpw.closeTcpChannel then
        lpw.closeTcpChannel(sid)
    end
    state.channel = nil
    return string.format(CRLF .. "+SERVCLOSE:%d" .. CRLF, sid) .. ok_tail()
end

local function uart_getcfg(_cmd)
    local s = get_config_snapshot()
    return string.format(
        CRLF .. "+GETCFG:version=%s,online=%d,power=%d,lowpower=%d,battery=%s,vbat=%s,interval=%d,devicemodel=%s,wled=%d%s" .. CRLF,
        s.version, s.online, s.power, s.lowpower, s.battery, s.vbat, s.interval, s.devicemodel, s.wled or 0,
        s.tcp_extra or ""
    ) .. ok_tail()
end

local function build_pirstat_body()
    return build_pir_wake_body(false)
end

local function uart_pirstat_query(_cmd)
    return rsp_body("PIRSTAT", build_pirstat_body())
end

--- 与 AT+PIRSTAT? 同源（t3x_ctrl 休眠前门禁用）
function buildPirstatBody()
    return build_pirstat_body()
end

--- T3x 无待处理业务时请求 4G 对 T3x 断电（先由 AT+PIRSTAT? 看 has_work / pending_wake）
local function uart_hostidle(cmd)
    local fc = _G.FEATURE_CFG
    if fc and fc.host_evt == false then
        return CRLF .. "+HOSTIDLE:NOT_SUPPORTED" .. CRLF
    end
    local heCfg = _G.HOST_EVT_CFG or {}
    if heCfg.allow_host_idle_sleep == false then
        return CRLF .. "+HOSTIDLE:DISABLED" .. CRLF
    end
    if (cmd == "AT+HOSTIDLE=1" or cmd == "AT+HOSTIDLE=0") and usb_blocks_host_idle() then
        if cmd == "AT+HOSTIDLE=0" then
            return rsp_body("HOSTIDLE", "OK")
        end
        log.info(LOG_TAG, "host_idle_usb_block")
        return CRLF .. "+HOSTIDLE:USB" .. CRLF
    end
    local hostBody = build_hostevt_body()
    if hostBody:match("has_event=1") then
        return CRLF .. "+HOSTIDLE:BUSY" .. CRLF
    end
    if cmd == "AT+HOSTIDLE?" then
        local rt = _G.APP_RUNTIME or {}
        local lp = tonumber(rt.low_power_mode) or 0
        local usb = is_usb_inserted() and 1 or 0
        local allow = 1
        if usb_blocks_host_idle() then
            allow = 0
        end
        return string.format(
            CRLF .. "+HOSTIDLE:lowpower=%d,usb=%d,host_idle_allow=%d" .. CRLF,
            lp, usb, allow) .. ok_tail()
    end
    if cmd == "AT+HOSTIDLE=1" or cmd == "AT+HOSTIDLE=0" then
        if cmd == "AT+HOSTIDLE=0" then
            return rsp_body("HOSTIDLE", "OK")
        end
        local okBg, bg = pcall(require, "battery_guard")
        if okBg and type(bg) == "table" and bg.shouldAllowHostIdleSleep
            and bg.shouldAllowHostIdleSleep() == false then
            return CRLF .. "+HOSTIDLE:BUSY" .. CRLF
        end
        if okBg and type(bg) == "table" and bg.canAcceptHostIdleSleep
            and bg.canAcceptHostIdleSleep() == false then
            return CRLF .. "+HOSTIDLE:BUSY" .. CRLF
        end
        local okCtrl, t3x = pcall(require, "t3x_ctrl")
        if okCtrl and t3x and t3x.enterSleep then
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
        return CRLF .. "+HOSTIDLE:ERROR" .. CRLF
    end
    return nil
end

local function uart_pirclr(_cmd)
    local ok, pir = pcall(require, "pir_ctrl")
    if ok and pir and pir.resetCounters then
        pir.resetCounters()
        return rsp_line("PIRCLR", true) .. ok_tail()
    end
    return rsp_line("PIRCLR", false)
end

--- T3x 上报录像状态：AT+RECORD=1 / AT+RECORD=0,reason=...
local function uart_record_notify(cmd)
    local arg = cmd:match("^AT%+RECORD=(.+)$")
    if not arg or arg == "" then
        return RSP_ERROR
    end
    if arg == "1" then
        state.t3x_rec_active = 1
        state.t3x_last_reason = "active"
        log.info(LOG_TAG, "record_start")
        if patchHostIpcCloudStat then
            patchHostIpcCloudStat({ recordingT3x = 1 })
        end
        local E = _G.APP_EVENTS or {}
        sys.publish(E.T3X_RECORD_ACTIVE or "APP_T3X_RECORD_ACTIVE")
        return CRLF .. "+RECORD:1,active=1" .. CRLF .. ok_tail()
    end
    local reason = arg:match("^0,reason=(.+)$") or "unknown"
    state.t3x_rec_active = 0
    state.t3x_last_reason = reason
    log.info(LOG_TAG, "record_stop", reason)
    if patchHostIpcCloudStat then
        patchHostIpcCloudStat({ recordingT3x = 0 })
    end
    local uploadMode, quality
    local ok_pc, pir_ctrl = pcall(require, "pir_ctrl")
    if ok_pc and pir_ctrl and pir_ctrl.syncStopFromT3x then
        uploadMode, quality = pir_ctrl.syncStopFromT3x(reason)
    end
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_RECORD_STOP or "APP_T3X_RECORD_STOP", reason, uploadMode, quality)
    return string.format(CRLF .. "+RECORD:0,reason=%s" .. CRLF, reason) .. ok_tail()
end

--- T3x IVS 人形个数：AT+PERSONCNT=N（PIR 录像会话内）
local function uart_person_cnt_notify(cmd)
    local cnt = cmd:match("^AT%+PERSONCNT=(%d+)$")
    if not cnt then
        return RSP_ERROR
    end
    local n = tonumber(cnt) or 0
    log.info(LOG_TAG, "person_count", n)
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_PERSON_CNT or "APP_T3X_PERSON_CNT", n)
    return string.format(CRLF .. "+PERSONCNT:ok,count=%d" .. CRLF, n) .. ok_tail()
end

--- T3x 归一化 PIR action：AT+PIRMEDIA=photo|video|both
local function uart_pir_media_notify(cmd)
    local action = cmd:match("^AT%+PIRMEDIA=(.+)$")
    if not action or action == "" then
        return RSP_ERROR
    end
    local ok_pc, pir_ctrl = pcall(require, "pir_ctrl")
    if ok_pc and pir_ctrl and pir_ctrl.applyEffectiveMediaAction then
        pir_ctrl.applyEffectiveMediaAction(action)
    end
    return string.format(CRLF .. "+PIRMEDIA:ok,action=%s" .. CRLF, action) .. ok_tail()
end

--- T3x §6.3 事件：AT+IPCALERT=code[,detail]
local function uart_ipc_alert_notify(cmd)
    local code, detail = cmd:match("^AT%+IPCALERT=([^,]+),?(.*)$")
    if not code or code == "" then
        return RSP_ERROR
    end
    detail = detail or ""
    log.info(LOG_TAG, "ipc_alert_uart", code, detail)
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_IPC_ALERT or "APP_T3X_IPC_ALERT", code, detail)
    return string.format(CRLF .. "+IPCALERT:OK,code=%s" .. CRLF, code) .. ok_tail()
end

local function ipc_ready_from_lifecycle(st)
    return (st == "ready") and 1 or 0
end

--- T3x 主动推送 IPC 生命周期：AT+IPCSTATUS=ready|idle|shutting_down
function uart_ipcstatus_notify(cmd)
    note_host_inbound_push()
    local st = cmd:match("^AT%+IPCSTATUS=(.+)$")
    if not st or st == "" then
        return RSP_ERROR
    end
    state.host_ipc_status = st
    log.info(LOG_TAG, "ipcstatus_push", st)
    if patchHostIpcCloudStat then
        patchHostIpcCloudStat({ ipcReady = ipc_ready_from_lifecycle(st) })
    end
    sys.publish(SYS_EVT.IPCSTATUS_ACK, st)
    return string.format(CRLF .. "+IPCSTATUS:OK,status=%s" .. CRLF, st) .. ok_tail()
end

--- T3x 主动推送扩展状态：AT+IPCSTAT=ipcReady=1,...
function uart_ipcstat_notify(cmd)
    note_host_inbound_push()
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
        log.warn(LOG_TAG, "ipcstat_push_parse_fail", body)
        return RSP_ERROR
    end
    log.info(LOG_TAG, "ipcstat_push",
        snap.ipcReady, snap.tfPresent, snap.recordingT3x, snap.cat1Link)
    if commitHostIpcCloudStat then
        commitHostIpcCloudStat(snap)
    else
        state.host_ipc_cloud_stat = snap
    end
    return rsp_line("IPCSTAT", true) .. ok_tail()
end

--- T3x 主动推送 TF 卡：AT+TFCARD=present=1,total_mb=...
function uart_tfcard_notify(cmd)
    note_host_inbound_push()
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
        log.warn(LOG_TAG, "tfcard_push_parse_fail", body)
        return RSP_ERROR
    end
    state.host_tf_card = snap
    log.info(LOG_TAG, "tfcard_push", snap.present)
    if patchHostIpcCloudStat then
        patchHostIpcCloudStat({ tfPresent = (tonumber(snap.present) or 0) == 1 and 1 or 0 })
    end
    sys.publish(SYS_EVT.TFCARD_ACK, snap)
    return rsp_line("TFCARD", true) .. ok_tail()
end

--- T3x 抓拍完成：AT+SNAPSHOT=/mnt/sdcard/snap/...
local function uart_snapshot_notify(cmd)
    local path = cmd:match("^AT%+SNAPSHOT=(.+)$")
    if not path or path == "" then
        return RSP_ERROR
    end
    log.info(LOG_TAG, "snapshot_done", path)
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_SNAPSHOT_DONE or "APP_T3X_SNAPSHOT_DONE", path)
    return string.format(CRLF .. "+SNAPSHOT:ok,path=%s" .. CRLF, path) .. ok_tail()
end

local function uart_record_query(_cmd)
    local rec = 0
    local ok_pc, pir_ctrl = pcall(require, "pir_ctrl")
    if ok_pc and pir_ctrl and pir_ctrl.isRecording and pir_ctrl.isRecording() then
        rec = 1
    end
    return string.format(CRLF .. "+RECORD:%d,reason=%s,active=%d" .. CRLF,
        rec, state.t3x_last_reason or "idle", state.t3x_rec_active or 0) .. ok_tail()
end

local function uart_ati(_cmd)
    return rsp_fmt("CGMR", "%s", get_config_snapshot().version)
end

local function uart_ril(cmd)
    local n = tonumber(cmd:match("^AT%+RIL=(%d+)$"))
    if n == nil then
        return RSP_ERROR
    end
    state.passthrough = (n == 1)
    log.info(LOG_TAG, "runtime_ivs", n)
    return rsp_fmt("RIL_PERSONCNT", "%d", n)
end

local function uart_sendstr(cmd)
    local text = cmd:match("^AT%+SENDSTR=(.+)$")
    local ok = false
    if text and hooks.send_string then
        ok = hooks.send_string(text, true)
    end
    return rsp_line("SEND", ok)
end

local function uart_sendhex(cmd)
    local hex = cmd:match("^AT%+SENDHEX=(.+)$")
    local ok = false
    if hex and hooks.send_hex then
        ok = hooks.send_hex(hex)
    end
    return rsp_line("SEND", ok)
end

local function uart_lowpower(cmd)
    local fc = _G.FEATURE_CFG
    if fc and fc.low_power == false then
        return CRLF .. "+LOWPOWER:NOT_SUPPORTED" .. CRLF
    end
    local rt = _G.APP_RUNTIME or {}
    if cmd == "AT+LOWPOWER=ENTER" then
        local up = usb_policy_mod()
        if up and up.blocks4gRest and up.blocks4gRest() then
            log.info(LOG_TAG, "lowpower_usb_block")
            return CRLF .. "+LOWPOWER:USB" .. CRLF
        end
        if (rt.power_status or 0) == 0 and (rt.low_power_mode or 0) == 0 then
            if hooks.on_enter_low_power then
                hooks.on_enter_low_power()
            end
            return CRLF .. "+LOWPOWER:ENTERING" .. CRLF
        end
        return CRLF .. "+LOWPOWER:BUSY" .. CRLF
    end
    if cmd == "AT+LOWPOWER=EXIT" then
        if (rt.low_power_mode or 0) == 1 then
            if hooks.on_exit_low_power then
                hooks.on_exit_low_power()
            end
            return CRLF .. "+LOWPOWER:WAKEUP" .. CRLF
        end
        return CRLF .. "+LOWPOWER:ALREADY_AWAKE" .. CRLF
    end
    return nil
end

local function uart_timer_action(hook)
    if hook then
        sys.timerStart(hook, 500)
    end
end

local function uart_reboot(_cmd)
    uart_timer_action(hooks.on_reboot)
    return CRLF .. "+REBOOT:OK" .. CRLF
end

local function uart_poweroff(_cmd)
    uart_timer_action(hooks.on_power_off)
    return CRLF .. "+POWEROFF:OK" .. CRLF
end

-- ---------------------------------------------------------------------------
-- 白光灯 WLED（4G 状态 + UART 转发 T3x）；见 doc/UART_PROTOCOL.md · MQTT 2004
-- ---------------------------------------------------------------------------

local wled_state = { on = 0, last_forward_ms = 0 }

local function wled_cfg()
    return _G.WLED_CFG or {}
end

local function wled_enabled()
    return wled_cfg().enabled ~= false
end

local function wled_export_runtime(on)
    if _G.APP_RUNTIME then
        _G.APP_RUNTIME.wled_on = on
    end
end

local function wled_ensure_t3x_powered()
    local ok, ipc = pcall(require, "t3x_ctrl")
    if ok and type(ipc) == "table" and ipc.ensurePowered then
        local wc = wled_cfg()
        return ipc.ensurePowered("wled", {
            t3x_power_wait_ms = tonumber(wc.t3x_power_wait_ms) or 800,
        })
    end
    return false
end

--- 须在 task 内调用；向 T3x 发 AT+WLED=0|1 并等待 +WLED:
local function forward_wled_to_host(on, timeoutMs)
    local wc = wled_cfg()
    if wc.forward_to_t3x == false then
        return true
    end
    if _G.MODULE_FLAGS and (_G.MODULE_FLAGS.t3x_app == false or _G.MODULE_FLAGS.uart_bridge == false) then
        log.warn(LOG_TAG, "wled_no_uart")
        return false
    end
    if not wled_ensure_t3x_powered() then
        log.warn(LOG_TAG, "wled_no_policy")
        return false
    end
    timeoutMs = tonumber(timeoutMs) or tonumber(wc.ack_timeout_ms) or 3000
    local atCmd = string.format("AT+WLED=%d", on)
    local okFwd = host_query(timeoutMs, {
        busy_key = "wled_forward_busy",
        busy_log = "wled_busy",
        policy_tag = "wled",
        cfg = wc,
        timeout_cfg_key = "ack_timeout_ms",
        default_timeout = 3000,
        at_cmd = atCmd,
        ack_event = SYS_EVT.WLED_ACK,
        no_uart_log = "wled_no_uart",
        err_log = "wled_error",
        on_response = function(got, val, tmo)
            if got and type(val) == "table" and val.ok then
                log.info(LOG_TAG, "wled_fwd_ok", val.on or on)
                return true
            end
            if got and type(val) == "table" and val.ok == false then
                log.warn(LOG_TAG, "wled_ipc_error")
                return false
            end
            log.warn(LOG_TAG, "wled_timeout", tmo)
            return false
        end,
        on_no_t3x = function()
            log.warn(LOG_TAG, "wled_no_policy")
            return false
        end,
    })
    return okFwd == true
end

--- 须在 task 内调用；向 T3x 发 AT+WLED? 并同步 4G 缓存
function queryHostWled(timeoutMs)
    local wc = wled_cfg()
    if wc.forward_to_t3x == false then
        return wled_get()
    end
    if not wled_ensure_t3x_powered() then
        return wled_get()
    end
    timeoutMs = tonumber(timeoutMs) or tonumber(wc.ack_timeout_ms) or 3000
    local val = host_query(timeoutMs, {
        busy_key = "wled_query_busy",
        busy_log = "wled_busy",
        policy_tag = "wled",
        cfg = wc,
        timeout_cfg_key = "ack_timeout_ms",
        default_timeout = 3000,
        at_cmd = "AT+WLED?",
        ack_event = SYS_EVT.WLED_ACK,
        no_uart_log = "wled_no_uart",
        err_log = "wled_error",
        on_response = function(got, rsp, tmo)
            if got and type(rsp) == "table" and rsp.ok then
                return rsp.on
            end
            if got == false then
                log.warn(LOG_TAG, "wled_query_timeout", tmo)
            end
            return wled_get()
        end,
        on_no_t3x = function()
            return wled_get()
        end,
    })
    if val == 0 or val == 1 then
        return val
    end
    return wled_get()
end

local function wled_get()
    local rt = _G.APP_RUNTIME
    if rt and rt.wled_on ~= nil then
        return rt.wled_on == 1 and 1 or 0
    end
    return wled_state.on == 1 and 1 or 0
end

local function wled_set(on, opts)
    opts = type(opts) == "table" and opts or {}
    if not wled_enabled() then
        on = on == 1 and 1 or 0
        wled_state.on = on
        wled_export_runtime(on)
        return false
    end
    on = (on == 1 or on == true) and 1 or 0
    wled_state.on = on
    wled_export_runtime(on)
    if opts.forward == false then
        return true
    end
    if opts.sync then
        if coroutine.running() then
            local ok = forward_wled_to_host(on, opts.timeout_ms)
            wled_state.last_forward_ms = mcu and mcu.ticks and mcu.ticks() or 0
            return ok
        end
        log.warn(LOG_TAG, "wled_sync_not_in_task")
        return false
    end
    sys.taskInit(function()
        if forward_wled_to_host(on, opts.timeout_ms) then
            wled_state.last_forward_ms = mcu and mcu.ticks and mcu.ticks() or 0
            log.info(LOG_TAG, "wled_state", on)
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

local function uart_wled(cmd)
    if cmd == "AT+WLED?" or cmd == "AT+WLEDEN?" then
        return string.format(CRLF .. "+WLED:%d" .. CRLF, wled_get()) .. ok_tail()
    end
    local n = tonumber(cmd:match("^AT%+WLED=(%d+)$"))
        or tonumber(cmd:match("^AT%+WLEDEN=(%d+)$"))
    if n == nil or (n ~= 0 and n ~= 1) then
        return RSP_ERROR
    end
    wled_set(n)
    return string.format(CRLF .. "+WLED:%d" .. CRLF, n) .. ok_tail()
end

local usb_recovery_guard = {
    busy = false,
    last_sec = 0,
    count = 0,
}

--- 防御：4G rest 且 T3x 已断电时不 rebind（正常 rest 下 T3x 不会发 AT+USBRESET）
local function t3x_rest_blocks_usb_reset()
    local cfg = host_usb_cfg()
    if cfg.block_usb_reset_when_t3x_rest == false then
        return false
    end
    local rt = _G.APP_RUNTIME or {}
    if tonumber(rt.low_power_mode) ~= 1 then
        return false
    end
    local ok, t3x = pcall(require, "t3x_ctrl")
    if not ok or type(t3x) ~= "table" or not t3x.getState then
        return false
    end
    local st = t3x.getState()
    return st ~= nil and st.powered_on == false
end

local function usb_recovery_allowed(cfg)
    if cfg.allow_t3x_usb_reset == false then
        return false, "DISABLED"
    end
    if usb_recovery_guard.busy then
        return false, "BUSY"
    end
    local min_iv = tonumber(cfg.usb_reset_min_interval_sec) or 60
    local now = os.time()
    if usb_recovery_guard.last_sec > 0 and (now - usb_recovery_guard.last_sec) < min_iv then
        return false, "BUSY"
    end
    if t3x_rest_blocks_usb_reset() then
        log.info(LOG_TAG, "usb_block_host_idle")
        return false, "REST"
    end
    return true, nil
end

local function export_usb_recovery_runtime(st)
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

local function publish_usb_recovery_changed()
    local ev = (_G.APP_EVENTS or {}).MQTT_USB_RECOVERY_CHANGED or "mqtt_usb_recovery_changed"
    sys.publish(ev)
end

local function usb_recovery_run_async(tag, cfg, do_fn)
    usb_recovery_guard.busy = true
    export_usb_recovery_runtime({
        state = "recovering",
        usb_logical = is_usb_inserted() and 1 or 0,
        usb_netdev = 0,
        last_err = "",
    })
    publish_usb_recovery_changed()
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
        if ok and cfg.notify_t3x_usb_state ~= false and is_usb_inserted() then
            sys.wait(notify_ms)
            push_usb_host_idle_state(1)
        end
        usb_recovery_guard.busy = false
        usb_recovery_guard.last_sec = os.time()
        usb_recovery_guard.count = (usb_recovery_guard.count or 0) + 1
        log.info(LOG_TAG, tag, ok and "ok" or "fail", "count", usb_recovery_guard.count)
        if not ok then
            export_usb_recovery_runtime({
                state = "idle",
                count = usb_recovery_guard.count,
                last_err = "rebind_failed",
                usb_logical = is_usb_inserted() and 1 or 0,
                usb_netdev = 0,
            })
            publish_usb_recovery_changed()
        end
    end)
end

local function uart_usbreset(cmd)
    local cfg = host_usb_cfg()
    if cmd == "AT+USBRESET?" then
        return string.format(
            CRLF .. "+USBRESET:busy=%d,count=%d,last=%d" .. CRLF,
            usb_recovery_guard.busy and 1 or 0,
            usb_recovery_guard.count or 0,
            usb_recovery_guard.last_sec or 0
        ) .. ok_tail()
    end
    if cmd ~= "AT+USBRESET" then
        return RSP_ERROR
    end
    local allowed, deny = usb_recovery_allowed(cfg)
    if not allowed then
        if deny == "REST" then
            export_usb_recovery_runtime({
                state = "blocked_rest",
                count = usb_recovery_guard.count or 0,
                last_err = "blocked_rest",
                usb_logical = is_usb_inserted() and 1 or 0,
                usb_netdev = 0,
            })
            publish_usb_recovery_changed()
        end
        return CRLF .. "+USBRESET:" .. deny .. CRLF
    end

    local okMod, usb_rndis = pcall(require, "usb_rndis")
    if not okMod or type(usb_rndis) ~= "table" then
        return CRLF .. "+USBRESET:ERROR" .. CRLF
    end

    usb_recovery_run_async("USBRESET", cfg, function()
        local pulse_ms = 0
        local okCtrl, t3x = pcall(require, "t3x_ctrl")
        if okCtrl and type(t3x) == "table" and t3x.pulseUsbDebugEn then
            local pok, pret, pms = pcall(t3x.pulseUsbDebugEn, { high_ms = cfg.usb_debug_en_pulse_ms })
            if pok and pms then
                pulse_ms = tonumber(pms) or 0
            elseif not pok then
                log.warn(LOG_TAG, "usb_pulse_fail", tostring(pret))
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
    return CRLF .. "+USBRESET:OK" .. CRLF .. ok_tail()
end

local function uart_usbrecovery(cmd)
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
    export_usb_recovery_runtime({
        state = stateLower,
        count = count,
        usb_logical = 1,
        usb_netdev = stateLower == "ok" and 1 or 0,
        last_err = lastErr,
    })
    log.info(LOG_TAG, "usb_recovery", stateLower, count)
    publish_usb_recovery_changed()
    return CRLF .. "+USBRECOVERY:" .. state .. CRLF .. ok_tail()
end

function resetUsbRecoveryFromCloud()
    if _G.MODULE_FLAGS and (_G.MODULE_FLAGS.t3x_app == false or _G.MODULE_FLAGS.uart_bridge == false) then
        export_usb_recovery_runtime({
            state = "idle",
            count = 0,
            last_err = "",
            usb_logical = is_usb_inserted() and 1 or 0,
            usb_netdev = 0,
        })
        usb_recovery_guard.count = 0
        publish_usb_recovery_changed()
        return false
    end
    uart_bridge.sendString("AT+USBRECOVERYRESET", true)
    export_usb_recovery_runtime({
        state = "idle",
        count = 0,
        last_err = "",
        usb_logical = is_usb_inserted() and 1 or 0,
        usb_netdev = 0,
    })
    usb_recovery_guard.count = 0
    publish_usb_recovery_changed()
    log.info(LOG_TAG, "usb_recovery_reset")
    return true
end

local function uart_rndis(cmd)
    local okMod, usb_rndis = pcall(require, "usb_rndis")
    if not okMod or type(usb_rndis) ~= "table" then
        return RSP_ERROR
    end

    if cmd == "AT+RNDIS?" or cmd == "AT+RNDIS" then
        local st = usb_rndis.getStatus and usb_rndis.getStatus() or {}
        return string.format(
            CRLF .. "+RNDIS:enabled=%d,mode=%s,status=%s,ip=%s,flymode=%s" .. CRLF,
            st.enabled and 1 or 0,
            tostring(st.usb_ethernet_mode or "--"),
            tostring(st.status or "--"),
            tostring(st.ip or "--"),
            st.flymode == nil and "--" or (st.flymode and "1" or "0")
        ) .. ok_tail()
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
        return rsp_line("RNDIS", true) .. ok_tail()
    end
    if n == 0 then
        sys.taskInit(function()
            if usb_rndis.disable then
                usb_rndis.disable()
            end
        end)
        return rsp_line("RNDIS", true) .. ok_tail()
    end
    return RSP_ERROR
end

local function uart_ota(_cmd)
    if hooks.on_ota then
        hooks.on_ota()
    else
        local E = _G.APP_EVENTS or {}
        if E.DEVICE_OTA_REQUEST then
            sys.publish(E.DEVICE_OTA_REQUEST, {})
        end
    end
    return CRLF .. "+OTA:STARTING" .. CRLF
end

local function uart_setcfg(cmd)
    local key, val = cmd:match("^AT%+SETCFG=([^,]+),(.+)$")
    if not key or not val then
        return RSP_SETCFG_ERR
    end
    local rt = _G.APP_RUNTIME
    local meta = _G.APP_META
    if key == "interval" and tonumber(val) and rt then
        local okMqtt, mqtt = pcall(require, "net_mqtt")
        if okMqtt and type(mqtt) == "table" and mqtt.setStatusIntervalSec then
            if not mqtt.setStatusIntervalSec(tonumber(val), true) then
                return RSP_SETCFG_ERR
            end
        else
            rt.low_power_interval_sec = tonumber(val)
            local ev = (_G.APP_EVENTS or {}).MQTT_STATUS_INTERVAL_CHANGED or "APP_MQTT_STATUS_INTERVAL_CHANGED"
            sys.publish(ev)
        end
        return RSP_SETCFG_OK
    elseif key == "devicemodel" and meta then
        meta.device_model = val
        return RSP_SETCFG_OK
    elseif key == "hexrpt" then
        state.hex_report = (val == "1" or val == "true" or val == "on")
        return RSP_SETCFG_OK
    end
    return RSP_SETCFG_ERR
end

local function uart_hex_line(line)
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

local function uart_str_line(line)
    local text = line:match("^[Ss][Tt][Rr]:(.*)$")
    local ok = false
    if text and hooks.send_string then
        ok = hooks.send_string(text, true)
    end
    return rsp_line("STR", ok)
end

-- ---------------------------------------------------------------------------
-- 表驱动分发（文档：doc/modules/HOST_UART_AT_DISPATCH.md §2）
-- ---------------------------------------------------------------------------

local function uart_cmd_entry(keys, prefix, handler)
    if prefix then
        return { match = "prefix", prefix = prefix, handler = handler }
    end
    keys = type(keys) == "table" and keys or { keys }
    return { match = "exact", keys = keys, handler = handler }
end

local AT_CMD_TABLE = {
    -- 握手 / 版本
    uart_cmd_entry("AT", nil, uart_at_ack),
    uart_cmd_entry({ "ATI", "AT+CGMR", "AT+GETVER" }, nil, uart_ati),
    -- 状态查询
    uart_cmd_entry("AT+GETCFG", nil, uart_getcfg),
    uart_cmd_entry({ "AT+PIRSTAT", "AT+PIRSTAT?" }, nil, uart_pirstat_query),
    uart_cmd_entry("AT+PIRCLR", nil, uart_pirclr),
    uart_cmd_entry({ "AT+RECORD", "AT+RECORD?" }, nil, uart_record_query),
    uart_cmd_entry(nil, "AT+RECORD=", uart_record_notify),
    uart_cmd_entry(nil, "AT+IPCSTATUS=", uart_ipcstatus_notify),
    uart_cmd_entry(nil, "AT+IPCSTAT=", uart_ipcstat_notify),
    uart_cmd_entry(nil, "AT+TFCARD=", uart_tfcard_notify),
    uart_cmd_entry(nil, "AT+SNAPSHOT=", uart_snapshot_notify),
    uart_cmd_entry(nil, "AT+PIRMEDIA=", uart_pir_media_notify),
    uart_cmd_entry(nil, "AT+PERSONCNT=", uart_person_cnt_notify),
    uart_cmd_entry(nil, "AT+IPCALERT=", uart_ipc_alert_notify),
    uart_cmd_entry({ "AT+HOSTEVT", "AT+HOSTEVT?" }, nil, uart_hostevt_query),
    uart_cmd_entry("AT+HOSTEVTCLR", nil, uart_hostevt_clr),
    uart_cmd_entry("AT+TIME", nil, uart_time_query),
    uart_cmd_entry({ "AT+IMEI", "AT+IMEI?" }, nil, uart_imei),
    uart_cmd_entry({ "AT+IPCINFO", "AT+IPCINFO?" }, nil, uart_ipcinfo_query),
    -- 链路 / 通道配置
    uart_cmd_entry(nil, "AT+MQTTPUB=", uart_mqttpub),
    uart_cmd_entry({ "AT+WLED?", "AT+WLEDEN?" }, nil, uart_wled),
    uart_cmd_entry(nil, "AT+WLED=", uart_wled),
    uart_cmd_entry(nil, "AT+WLEDEN=", uart_wled),
    uart_cmd_entry(nil, "AT+SERVCREATE=", uart_servcreate),
    uart_cmd_entry(nil, "AT+MQTTCFG=", uart_mqttcfg),
    uart_cmd_entry(nil, "AT+P2PCFG=", uart_p2pcfg),
    uart_cmd_entry(nil, "AT+GB28181CFG=", uart_gb28181cfg),
    uart_cmd_entry(nil, "AT+SERVCLOSE=", uart_servclose),
    uart_cmd_entry(nil, "AT+RIL=", uart_ril),
    uart_cmd_entry(nil, "AT+SENDSTR=", uart_sendstr),
    uart_cmd_entry(nil, "AT+SENDHEX=", uart_sendhex),
    -- 低功耗 / 休眠
    uart_cmd_entry(nil, "AT+LOWPOWER=", uart_lowpower),
    uart_cmd_entry({ "AT+HOSTIDLE", "AT+HOSTIDLE?" }, nil, uart_hostidle),
    uart_cmd_entry(nil, "AT+HOSTIDLE=", uart_hostidle),
    uart_cmd_entry({ "AT+RNDIS", "AT+RNDIS?" }, nil, uart_rndis),
    uart_cmd_entry(nil, "AT+RNDIS=", uart_rndis),
    uart_cmd_entry({ "AT+USBRESET", "AT+USBRESET?" }, nil, uart_usbreset),
    uart_cmd_entry(nil, "AT+USBRECOVERY=", uart_usbrecovery),
    -- 电源 / OTA
    uart_cmd_entry("AT+REBOOT", nil, uart_reboot),
    uart_cmd_entry("AT+POWEROFF", nil, uart_poweroff),
    uart_cmd_entry({ "AT+OTA", "AT+OTACHECK" }, nil, uart_ota),
    uart_cmd_entry(nil, "AT+SETCFG=", uart_setcfg),
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
    HEX = uart_hex_line,
    STR = uart_str_line,
}

local function uart_dispatch_at(cmd)
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

local function host_plain_line(line)
    if hooks.on_plain_line then
        hooks.on_plain_line(line)
        return
    end
    local E = _G.APP_EVENTS or {}
    if E.UART_RX_STRING then
        sys.publish(E.UART_RX_STRING, line)
    end
end

local function try_sound_ack_line(line)
    if not line then
        return false
    end
    local name = line:match("^%+SOUNDACK:(%w+)$")
    if not name then
        return false
    end
    local ok, sp = pcall(require, "sound_prompt")
    if ok and type(sp) == "table" and sp.onSoundAck then
        sp.onSoundAck(name)
    end
    return true
end

local function try_timeset_ack_line(line)
    if not line then
        return false
    end
    if line:match("^%+TIMESET:OK$") then
        local ok, ts = pcall(require, "time_sync")
        if ok and type(ts) == "table" and ts.onTimesetAck then
            ts.onTimesetAck()
        end
        return true
    end
    return false
end

local function try_gb28181_line(line)
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

local function try_wled_line(line)
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
    wled_export_runtime(n)
    sys.publish(SYS_EVT.WLED_ACK, { ok = true, on = n })
    return true
end

local function try_tfformat_line(line)
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

local function try_tfcard_line(line)
    if not line or not line:match("^%+TFCARD:") then
        return false
    end
    local snap = parse_tfcard_line(line)
    if not snap.parsed then
        log.warn(LOG_TAG, "tfcard_parse_fail", line)
        return false
    end
    state.host_tf_card = snap
    patchHostIpcCloudStat({ tfPresent = (tonumber(snap.present) or 0) == 1 and 1 or 0 })
    sys.publish(SYS_EVT.TFCARD_ACK, snap)
    return true
end

local function parse_record_line(line)
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

local function normalize_host_line(line)
    if not line then
        return line
    end
    return (line:match("^%s*(.-)%s*$") or line)
end

local function parse_recordtime_line(line)
    line = normalize_host_line(line)
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

local function try_recordtime_line(line)
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

local function try_record_line(line)
    if not line or not line:match("^%+RECORD:") then
        return false
    end
    local snap = parse_record_line(line)
    state.host_record = snap
    if snap.active == 1 then
        state.t3x_rec_active = 1
    elseif snap.running == 0 then
        state.t3x_rec_active = 0
    end
    if snap.reason and snap.reason ~= "" then
        state.t3x_last_reason = snap.reason
    end
    sys.publish(SYS_EVT.RECORD_ACK, snap)
    return true
end

local function parse_venc_row(line)
    line = normalize_host_line(line)
    local cam, stream, en, w, h, br, fps, rc, enc = line:match(
        "^%+VENC:(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$")
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
    line = normalize_host_line(line)
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

local function try_encode_uart_error(line)
    if line ~= "ERROR" then
        return false
    end
    if state.encode_venc_rows ~= nil then
        state.encode_venc_rows = nil
        sys.publish(SYS_EVT.VENC_QUERY, { __error = "uart_error" })
        return true
    end
    if state.encode_audio_rows ~= nil then
        state.encode_audio_rows = nil
        sys.publish(SYS_EVT.AUDIO_QUERY, { __error = "uart_error" })
        return true
    end
    return false
end

local function try_encode_ok_tail(line)
    if line ~= "OK" then
        return false
    end
    if state.encode_venc_rows ~= nil then
        local rows = state.encode_venc_rows
        state.encode_venc_rows = nil
        sys.publish(SYS_EVT.VENC_QUERY, rows)
        return true
    end
    if state.encode_audio_rows ~= nil then
        local rows = state.encode_audio_rows
        state.encode_audio_rows = nil
        sys.publish(SYS_EVT.AUDIO_QUERY, rows)
        return true
    end
    if state.mic_rows ~= nil then
        local rows = state.mic_rows
        state.mic_rows = nil
        sys.publish(SYS_EVT.MIC_QUERY, rows)
        return true
    end
    return false
end

local function try_venc_line(line)
    line = normalize_host_line(line)
    if line == "+VENC:END" then
        local rows = state.encode_venc_rows or {}
        state.encode_venc_rows = nil
        sys.publish(SYS_EVT.VENC_QUERY, rows)
        return true
    end
    local row = parse_venc_row(line)
    if not row then
        return false
    end
    state.encode_venc_rows = state.encode_venc_rows or {}
    state.encode_venc_rows[#state.encode_venc_rows + 1] = row
    return true
end

local function try_vencset_line(line)
    if line and line:match("^%+VENCSET:ERROR") then
        sys.publish(SYS_EVT.VENC_SET, { ok = false })
        return true
    end
    local cam, stream, reboot, runtimeApply = line:match("^%+VENCSET:OK,cam=(%d+),stream=(%d+),needReboot=(%d+),runtimeApply=(%d+)$")
    if cam then
        sys.publish(SYS_EVT.VENC_SET, {
            ok = true,
            camera = tonumber(cam) or 0,
            stream = tonumber(stream) or 0,
            needReboot = (tonumber(reboot) or 0) == 1,
            runtimeApply = tonumber(runtimeApply) or 0,
        })
        return true
    end
    cam, stream, reboot = line:match("^%+VENCSET:OK,cam=(%d+),stream=(%d+),needReboot=(%d+)$")
    if not cam then
        return false
    end
    sys.publish(SYS_EVT.VENC_SET, {
        ok = true,
        camera = tonumber(cam) or 0,
        stream = tonumber(stream) or 0,
        needReboot = (tonumber(reboot) or 0) == 1,
    })
    return true
end

local function try_audioset_line(line)
    if line and line:match("^%+AUDIOSET:ERROR") then
        sys.publish(SYS_EVT.AUDIO_SET, { ok = false })
        return true
    end
    local cam, reboot = line:match("^%+AUDIOSET:OK,cam=(%d+),needReboot=(%d+)$")
    if not cam then
        return false
    end
    sys.publish(SYS_EVT.AUDIO_SET, {
        ok = true,
        camera = tonumber(cam) or 0,
        needReboot = (tonumber(reboot) or 0) == 1,
    })
    return true
end

local function try_audio_line(line)
    line = normalize_host_line(line)
    if line == "+AUDIO:END" then
        local rows = state.encode_audio_rows or {}
        state.encode_audio_rows = nil
        sys.publish(SYS_EVT.AUDIO_QUERY, rows)
        return true
    end
    local row = parse_audio_row(line)
    if not row then
        return false
    end
    state.encode_audio_rows = state.encode_audio_rows or {}
    state.encode_audio_rows[#state.encode_audio_rows + 1] = row
    return true
end

local function try_micset_line(line)
    if line and line:match("^%+MICSET:ERROR") then
        sys.publish(SYS_EVT.MIC_SET, { ok = false })
        return true
    end
    local cam, runtimeApply = line:match("^%+MICSET:OK,cam=(%d+),runtimeApply=(%d+)$")
    if cam then
        sys.publish(SYS_EVT.MIC_SET, {
            ok = true,
            camera = tonumber(cam) or 0,
            runtimeApply = tonumber(runtimeApply) or 0,
        })
        return true
    end
    return false
end

local function try_mic_line(line)
    line = normalize_host_line(line)
    if line == "+MIC:END" then
        local rows = state.mic_rows or {}
        state.mic_rows = nil
        sys.publish(SYS_EVT.MIC_QUERY, rows)
        return true
    end
    local cam, vol, gain = line:match("^%+MIC:(%d+),(%d+),(%d+)$")
    if cam then
        state.mic_rows = state.mic_rows or {}
        state.mic_rows[#state.mic_rows + 1] = {
            camera = tonumber(cam) or 0,
            volume = tonumber(vol) or 0,
            gain = tonumber(gain) or 0,
        }
        return true
    end
    return false
end

local function try_softphotoset_line(line)
    if line and line:match("^%+SOFTPHOTOSET:OK") then
        sys.publish(SYS_EVT.SOFTPHOTO_SET, { ok = true })
        return true
    end
    if line and line:match("^%+SOFTPHOTOSET:ERROR") then
        sys.publish(SYS_EVT.SOFTPHOTO_SET, { ok = false })
        return true
    end
    return false
end

local function try_softphoto_line(line)
    line = normalize_host_line(line)
    if not line or not line:match("^%+SOFTPHOTO:") then
        return false
    end
    local en, night, day, dayAlt, gbGain, gbInit, checkTime, checkCount =
        line:match("^%+SOFTPHOTO:(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$")
    if en then
        sys.publish(SYS_EVT.SOFTPHOTO_QUERY, {
            enable = tonumber(en) or 0,
            nightModeThreshold = tonumber(night) or 0,
            dayModeThreshold = tonumber(day) or 0,
            dayModeAltThreshold = tonumber(dayAlt) or 0,
            gbGainThreshold = tonumber(gbGain) or 0,
            gbGainRecordInit = tonumber(gbInit) or 0,
            checkTime = tonumber(checkTime) or 0,
            checkCount = tonumber(checkCount) or 0,
            parsed = true,
        })
        return true
    end
    if line:match("^%+SOFTPHOTO:ERROR") then
        sys.publish(SYS_EVT.SOFTPHOTO_QUERY, { parsed = false, error = true })
        return true
    end
    return false
end

local function try_framerate_line(line)
    line = normalize_host_line(line)
    if line == "+FRAMERATE:END" then
        local rows = state.framerate_rows or {}
        state.framerate_rows = nil
        sys.publish(SYS_EVT.FRAMERATE_QUERY, rows)
        return true
    end
    local cam, stream, fps = line:match("^%+FRAMERATE:(%d+),(%d+),(%d+)$")
    if cam then
        state.framerate_rows = state.framerate_rows or {}
        state.framerate_rows[#state.framerate_rows + 1] = {
            camera = tonumber(cam) or 0,
            stream = tonumber(stream) or 0,
            framerate = tonumber(fps) or 0,
        }
        return true
    end
    local okCam, okStream, okFps, runtimeApply = line:match("^%+FRAMERATE:OK,(%d+),(%d+),(%d+),runtimeApply=(%d+)$")
    if okCam then
        sys.publish(SYS_EVT.FRAMERATE_SET, {
            ok = true,
            camera = tonumber(okCam) or 0,
            stream = tonumber(okStream) or 0,
            framerate = tonumber(okFps) or 0,
            runtimeApply = tonumber(runtimeApply) or 0,
        })
        return true
    end
    okCam, okStream, okFps = line:match("^%+FRAMERATE:OK,(%d+),(%d+),(%d+)$")
    if okCam then
        sys.publish(SYS_EVT.FRAMERATE_SET, {
            ok = true,
            camera = tonumber(okCam) or 0,
            stream = tonumber(okStream) or 0,
            framerate = tonumber(okFps) or 0,
            runtimeApply = 1,
        })
        return true
    end
    if line:match("^%+FRAMERATE:ERROR") then
        sys.publish(SYS_EVT.FRAMERATE_SET, { ok = false, error = true })
        return true
    end
    return false
end

local function try_recordctrl_line(line)
    line = normalize_host_line(line)
    if not line or not line:match("^%+RECORDCTRL:") then
        return false
    end
    local ok1, maxSec = line:match("^%+RECORDCTRL:OK,1,max_sec=(%d+)$")
    if ok1 then
        sys.publish(SYS_EVT.RECORDCTRL_SET, { ok = true, start = 1, max_sec = tonumber(maxSec) or 60 })
        return true
    end
    local ok0, reason = line:match("^%+RECORDCTRL:OK,0,reason=(.+)$")
    if ok0 then
        sys.publish(SYS_EVT.RECORDCTRL_SET, { ok = true, start = 0, reason = reason or "cloud" })
        return true
    end
    if line:match("^%+RECORDCTRL:ERROR") then
        sys.publish(SYS_EVT.RECORDCTRL_SET, { ok = false, error = true })
        return true
    end
    return false
end

local function try_persondet_line(line)
    line = normalize_host_line(line)
    if not line or not line:match("^%+PERSONDET:") then
        return false
    end
    local enable, available = line:match("^%+PERSONDET:(%d+),available=(%d+)$")
    if enable then
        state.host_person_detect = {
            enable = tonumber(enable) or 0,
            available = tonumber(available) or 0,
            parsed = true,
        }
        sys.publish(SYS_EVT.PERSONDET_ACK, state.host_person_detect)
        return true
    end
    enable = line:match("^%+PERSONDET:(%d+)$")
    if enable then
        state.host_person_detect = { enable = tonumber(enable) or 0, parsed = true }
        sys.publish(SYS_EVT.PERSONDET_ACK, state.host_person_detect)
        return true
    end
    local okEn = line:match("^%+PERSONDET:OK,(%d+)$")
    if okEn then
        sys.publish(SYS_EVT.PERSONDET_SET, { ok = true, enable = tonumber(okEn) or 0 })
        return true
    end
    if line:match("^%+PERSONDET:ERROR") then
        sys.publish(SYS_EVT.PERSONDET_SET, { ok = false, error = true })
        return true
    end
    return false
end

normalize_ipc_cloud_stat = function(snap)
    if type(snap) ~= "table" then
        return snap
    end
    if snap.cat1Link == nil and snap.hostLink ~= nil then
        snap.cat1Link = snap.hostLink
    end
    return snap
end

--- T3x 推送 / 本地 patch 写入 1003 扩展状态缓存
function commitHostIpcCloudStat(snap)
    if type(snap) ~= "table" or next(snap) == nil then
        return nil
    end
    snap = normalize_ipc_cloud_stat(snap)
    state.host_ipc_cloud_stat = snap
    state.ipc_cloud_stat_ts = os.time()
    if snap.ipcReady == 1 and not state.host_ipc_status then
        state.host_ipc_status = "ready"
    end
    sys.publish(SYS_EVT.IPCSTAT_ACK, snap)
    return snap
end

function patchHostIpcCloudStat(fields)
    local cloud = state.host_ipc_cloud_stat
    if type(cloud) ~= "table" then
        cloud = {}
    end
    fields = type(fields) == "table" and fields or {}
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

local function try_ipcstat_line(line)
    local snap = parse_ipcstat_line(line)
    if not snap then
        return false
    end
    commitHostIpcCloudStat(snap)
    return true
end

local function try_ipcstatus_line(line)
    if not line then
        return false
    end
    local st = line:match("^%+IPCSTATUS:(%w+)$")
    if not st then
        return false
    end
    state.host_ipc_status = st
    patchHostIpcCloudStat({ ipcReady = ipc_ready_from_lifecycle(st) })
    note_uart_link_ok()
    sys.publish(SYS_EVT.IPCSTATUS_ACK, st)
    return true
end

local function try_ipcpoweroff_line(line)
    if line == "+IPCPOWEROFF:OK" then
        sys.publish(SYS_EVT.IPCPOWEROFF_ACK, true)
        return true
    end
    return false
end

--- T3x 上行应答行注册表（按序尝试，命中即消费；文档见 doc/modules/HOST_UART_AT_DISPATCH.md）
local RX_LINE_HANDLER_REGISTRY = {
    { name = "encode_uart_error", fn = try_encode_uart_error },
    { name = "sound_ack", fn = try_sound_ack_line },
    { name = "timeset_ack", fn = try_timeset_ack_line },
    { name = "gb28181", fn = try_gb28181_line },
    { name = "wled", fn = try_wled_line },
    { name = "tfformat", fn = try_tfformat_line },
    { name = "tfcard", fn = try_tfcard_line },
    { name = "recordtime", fn = try_recordtime_line },
    { name = "framerate", fn = try_framerate_line },
    { name = "recordctrl", fn = try_recordctrl_line },
    { name = "persondet", fn = try_persondet_line },
    { name = "record", fn = try_record_line },
    { name = "venc", fn = try_venc_line },
    { name = "vencset", fn = try_vencset_line },
    { name = "audio", fn = try_audio_line },
    { name = "audioset", fn = try_audioset_line },
    { name = "mic", fn = try_mic_line },
    { name = "micset", fn = try_micset_line },
    { name = "softphoto", fn = try_softphoto_line },
    { name = "softphotoset", fn = try_softphotoset_line },
    { name = "ipcstat", fn = try_ipcstat_line },
    { name = "ipcstatus", fn = try_ipcstatus_line },
    { name = "ipcpoweroff", fn = try_ipcpoweroff_line },
    { name = "encode_ok_tail", fn = try_encode_ok_tail },
}

local RX_LINE_TRY_HANDLERS = {}
for i = 1, #RX_LINE_HANDLER_REGISTRY do
    RX_LINE_TRY_HANDLERS[i] = RX_LINE_HANDLER_REGISTRY[i].fn
end

local function hostFirstAtEvent()
    return (_G.APP_EVENTS and _G.APP_EVENTS.HOST_UART_FIRST_AT) or "APP_HOST_UART_FIRST_AT"
end

local function notify_host_first_at(cmd)
    if state.host_at_ready then
        return
    end
    state.host_at_ready = true
    state.first_host_at = cmd
    note_uart_link_ok()
    state.uart_recovery_attempts = 0
    state.uart_recovery_last_sec = 0
    log.info(LOG_TAG, "first_at", cmd or "")
    if patchHostIpcCloudStat then
        patchHostIpcCloudStat({ cat1Link = 1 })
    end
    sys.taskInit(function()
        sys.wait(300)
        if not isT31StartedForHostQuery() then
            log.info(LOG_TAG, "first_at_skip_ipcstat", "t31_off")
            return
        end
        if queryHostIpcCloudStat then
            queryHostIpcCloudStat(2500)
        end
        if mergeTfRecordIntoCloudStat then
            mergeTfRecordIntoCloudStat()
        end
    end)
    sys.publish(hostFirstAtEvent(), cmd or "")
end

local function host_process_line(line)
    line = normalize_host_line(line)
    if not line or line == "" then
        return nil
    end
    for _, try_fn in ipairs(RX_LINE_TRY_HANDLERS) do
        if try_fn(line) then
            return nil
        end
    end
    if line:sub(1, 2) == "AT" then
        notify_host_first_at(line)
        return uart_at_cmd(line)
    end
    if line:sub(4, 4) == ":" then
        local fn = LINE_HANDLERS[line:sub(1, 3):upper()]
        if fn then
            return fn(line)
        end
    end
    host_plain_line(line)
    return nil
end

-- ---------------------------------------------------------------------------
-- 对外 API
-- ---------------------------------------------------------------------------

function uart_at_cmd(cmd)
    if not cmd or cmd == "" then
        return RSP_ERROR
    end
    log.info(LOG_TAG, "uart_at_tx", cmd)
    state.last_command = cmd
    cmd = cmd:gsub("%?$", "")
    if hooks.on_at_ext then
        local extRsp = hooks.on_at_ext(cmd)
        if extRsp then
            return extRsp
        end
    end
    return uart_dispatch_at(cmd)
end

function on_rx_raw(data)
    echo_rx_hex_if_enabled(data)
end

local function default_modem_at(cmd)
    if mobile and mobile.at then
        return mobile.at(cmd .. CRLF, 5000)
    end
    return nil
end

local function on_uart_line(line)
    local rsp = host_process_line(line)
    if rsp then
        uart_bridge.write(rsp)
    end
end

local function bind_start_hooks(opts)
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
    hooks.modem_at = opts.modem_at or default_modem_at
end

function isHostAtReady()
    return state.host_at_ready == true
end

function getHostFirstAt()
    return state.first_host_at
end

local function identity_cfg()
    return _G.HOST_IDENTITY_CFG or {}
end

local function tf_card_cfg()
    return _G.HOST_TFCARD_CFG or {}
end

local function ipc_cfg()
    return _G.HOST_IPC_CFG or {}
end

local function ensure_t3x_for_host_query(policy_tag, cfg)
    cfg = cfg or identity_cfg()
    local ok, ipc = pcall(require, "t3x_ctrl")
    if ok and type(ipc) == "table" and ipc.ensurePowered then
        return ipc.ensurePowered(policy_tag or "host_identity", {
            t3x_power_wait_ms = tonumber(cfg.t3x_power_wait_ms)
                or tonumber((_G.TIME_SYNC_CFG or {}).t3x_power_wait_ms)
                or 800,
        })
    end
    return false
end

local function host_boot_wait_ms(cfg)
    return tonumber(cfg.host_boot_wait_ms)
        or tonumber((_G.TIME_SYNC_CFG or {}).host_boot_wait_ms)
        or 1500
end

--- 通用 T3x AT 查询（须在 task 内调用）
run_host_query = function(opts)
    if not coroutine.running() then
        if opts.err_log then
            log.warn(LOG_TAG, "host_query_skip", "no_task", opts.at_cmd or "")
        end
        if opts.cache_key and state[opts.cache_key] ~= nil then
            return state[opts.cache_key]
        end
        if opts.busy_return ~= nil then
            return opts.busy_return
        end
        return opts.default_result
    end
    if isHostInboundQuiet() then
        if opts.err_log then
            log.info(LOG_TAG, "host_query_skip", "push_quiet", opts.at_cmd or "")
        end
        if opts.cache_key and state[opts.cache_key] ~= nil then
            return state[opts.cache_key]
        end
        if opts.busy_return ~= nil then
            return opts.busy_return
        end
        return opts.default_result
    end
    if state[opts.busy_key] then
        if opts.busy_log then
            log.warn(LOG_TAG, opts.busy_log)
        end
        if opts.busy_return ~= nil then
            return opts.busy_return
        end
        if opts.cache_key then
            return state[opts.cache_key]
        end
    end
    state[opts.busy_key] = true

    local cfg = opts.cfg or identity_cfg()
    local result = opts.default_result
    local ok, err = pcall(function()
        local timeoutMs = tonumber(opts.timeout_ms)
            or tonumber(cfg[opts.timeout_cfg_key or "query_timeout_ms"])
            or opts.default_timeout
            or 3000
        if opts.when_disabled then
            local early = opts.when_disabled(cfg)
            if early ~= nil then
                result = early
                return
            end
        end
        if not ensure_t3x_for_host_query(opts.policy_tag, cfg) then
            if opts.on_no_t3x then
                result = opts.on_no_t3x()
            end
            return
        end
        if opts.wait_boot ~= false and not state.host_at_ready then
            sys.wait(host_boot_wait_ms(cfg))
        end
        if not uart_bridge.sendString then
            if opts.no_uart_log then
                log.warn(LOG_TAG, opts.no_uart_log)
            end
            if opts.on_no_uart then
                result = opts.on_no_uart()
            end
            return
        end
        log.info(LOG_TAG, opts.at_cmd, timeoutMs, opts.log_extra or "")
        if opts.before_send then
            opts.before_send()
        end
        uart_bridge.sendString(opts.at_cmd, true)
        local got, val = sys.waitUntil(opts.ack_event, timeoutMs)
        result = opts.on_response(got, val, timeoutMs) or result
    end)

    state[opts.busy_key] = false
    if not ok then
        if opts.err_log then
            log.warn(LOG_TAG, opts.err_log, err)
        end
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

--- T3x AT 设置公共模板（busy → 上电 → sendString → waitUntil → parse_rsp）
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
        if not ensure_t3x_for_host_query(spec.policy_tag, cfg) then
            okSet, msg = false, "t3x_unavailable"
            return
        end
        if spec.wait_boot ~= false and not state.host_at_ready then
            sys.wait(host_boot_wait_ms(spec.boot_cfg or cfg))
        end
        if not uart_bridge.sendString then
            okSet, msg = false, "no_uart"
            return
        end
        if spec.log_tag then
            log.info(LOG_TAG, spec.log_tag, atCmd, timeoutMs)
        end
        uart_bridge.sendString(atCmd, true)
        local got, rsp = sys.waitUntil(spec.ack_event, timeoutMs)
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
    if busyKey then
        state[busyKey] = false
    end
    if not ok then
        return false, tostring(e), nil
    end
    return okSet, msg, extra
end

local function noop_nil()
    return nil
end

local function noop_idle()
    return "idle"
end

function getCachedHostGb28181Id()
    return state.host_gb28181_id
end

function getCachedP2pCfg()
    if not state.p2p_uid or state.p2p_uid == "" then
        return nil
    end
    return {
        uid = state.p2p_uid,
        product = state.p2p_product or "",
    }
end

function getCachedGb28181Cfg()
    if not state.host_gb28181_id or state.host_gb28181_id == "" then
        return nil
    end
    return {
        device_id = state.host_gb28181_id,
        password = state.gb28181_password or "",
        imei = state.gb28181_imei,
    }
end

--- 须在 task 内调用；向 T3x 发 AT+GB28181? 并等待 +GB28181:
function queryHostGb28181(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "gb28181_query_busy",
        cache_key = "host_gb28181_id",
        busy_log = "gb28181_busy",
        policy_tag = "host_identity",
        cfg = identity_cfg(),
        timeout_cfg_key = "query_timeout_ms",
        default_timeout = 3000,
        at_cmd = "AT+GB28181?",
        ack_event = SYS_EVT.GB28181_ACK,
        no_uart_log = "gb28181_no_uart",
        err_log = "gb28181_error",
        on_response = function(got, id, tmo)
            if got and id ~= nil then
                state.host_gb28181_id = id
                log.info(LOG_TAG, "gb28181_id", id ~= "" and id or "")
                return state.host_gb28181_id
            end
            log.warn(LOG_TAG, "gb28181_timeout", tmo)
            return state.host_gb28181_id
        end,
        on_error = noop_nil,
    })
end

function getCachedHostIpcStatus()
    return state.host_ipc_status
end

local function t3x_recording_from_record_snap(rec)
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

local function apply_cached_tf_to_cloud(cloud)
    local tf = state.host_tf_card
    if type(tf) ~= "table" or not tf.parsed then
        return cloud
    end
    cloud.tfPresent = (tonumber(tf.present) or 0) == 1 and 1 or 0
    return cloud
end

local function apply_record_snap_to_cloud(cloud)
    local recActive = t3x_recording_from_record_snap(state.host_record)
    if recActive == nil then
        return cloud
    end
    cloud.recordingT3x = recActive
    state.t3x_rec_active = recActive
    return cloud
end

--- §6.2 状态缓存（T3x 推送 + 过期时单条 AT+IPCSTAT? 兜底）
local function ipc_cloud_stat_max_age_sec()
    local cfg = ipc_cfg()
    return tonumber(cfg.status_cache_max_age_sec) or 90
end

local function overlay_live_ipc_hints(snap)
    if type(snap) ~= "table" then
        return snap
    end
    if state.host_at_ready and (tonumber(snap.cat1Link) or 0) == 0 then
        snap.cat1Link = 1
    end
    local ok, t3x = pcall(require, "t3x_ctrl")
    if ok and type(t3x) == "table" and t3x.getState then
        local pst = t3x.getState()
        if pst and pst.powered_on and (tonumber(snap.cat1Link) or 0) == 0 then
            snap.cat1Link = 1
        end
    end
    local life = state.host_ipc_status
    if life == "ready" and (tonumber(snap.ipcReady) or 0) == 0 then
        snap.ipcReady = 1
    end
    if tonumber(state.t3x_rec_active) == 1 then
        snap.recordingT3x = 1
    end
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
    if os.time() - ts > ipc_cloud_stat_max_age_sec() then
        return true
    end
    return false
end

function getCachedHostIpcCloudStat()
    local cached = state.host_ipc_cloud_stat
    if type(cached) == "table" and next(cached) ~= nil then
        cached = normalize_ipc_cloud_stat(cached)
        apply_cached_tf_to_cloud(cached)
        cached = overlay_live_ipc_hints(cached)
        return cached
    end
    local life = state.host_ipc_status or "idle"
    local ipcReady = (life == "ready") and 1 or 0
    local cat1Link = 0
    if ipcReady == 1 or state.host_at_ready then
        cat1Link = 1
    end
    return overlay_live_ipc_hints(normalize_ipc_cloud_stat(apply_cached_tf_to_cloud({
        ipcReady = ipcReady,
        gb28181Online = 0,
        tfPresent = 0,
        personDetectEnabled = 0,
        personDetectAvailable = 0,
        timeSynced = 0,
        recordingT3x = (tonumber(state.t3x_rec_active) == 1) and 1 or 0,
        cat1Link = cat1Link,
    })))
end

--- T31(T3x) 是否已上电/运行（GPIO 上电 或 UART 已收到 T3x 来 AT）
function isT31StartedForHostQuery()
    if state.host_at_ready then
        return true
    end
    local ok, t3x = pcall(require, "t3x_ctrl")
    if ok and type(t3x) == "table" and t3x.getState then
        local st = t3x.getState()
        return st ~= nil and st.powered_on == true
    end
    return false
end

--- T3x 已上电或 UART 已通时值得查 IPCSTAT
function shouldQueryIpcCloudStat()
    return isT31StartedForHostQuery()
end

--- 无 IPCSTATUS 缓存但 T3x 可能已运行时，先查 AT+IPCSTATUS?
function needsHostIpcStatusRefresh()
    local life = state.host_ipc_status
    if life == "ready" or life == "shutting_down" then
        return false
    end
    return shouldQueryIpcCloudStat()
end

--- 将 AT+TFCARD? / AT+RECORD? 缓存合并进 host_ipc_cloud_stat（1003 字段源）
function mergeTfRecordIntoCloudStat()
    local cloud = state.host_ipc_cloud_stat
    if type(cloud) ~= "table" then
        cloud = {}
        state.host_ipc_cloud_stat = cloud
    end
    apply_cached_tf_to_cloud(cloud)
    apply_record_snap_to_cloud(cloud)
    return cloud
end

--- 1003 发布前：合并本地缓存；须在 task/coroutine 内才单查 AT+IPCSTAT?
--- @param force boolean|nil ipc_alert 后强制拉取，忽略缓存新鲜度
function refreshIpcCloudStatFor1003(timeoutMs, force)
    timeoutMs = tonumber(timeoutMs) or 2500
    force = force == true
    mergeTfRecordIntoCloudStat()
    if not coroutine.running() then
        log.info(LOG_TAG, "ipc_stat_skip", "no_coroutine")
        return type(state.host_ipc_cloud_stat) == "table"
    end
    if not shouldQueryIpcCloudStat() then
        log.info(LOG_TAG, "ipc_stat_skip", "t31_off")
        return type(state.host_ipc_cloud_stat) == "table"
    end
    if not force and not isIpcCloudStatStale() then
        return true
    end
    if needsHostIpcStatusRefresh() and queryHostIpcStatus then
        queryHostIpcStatus(math.min(timeoutMs, 1500))
    end
    if queryHostIpcCloudStat then
        queryHostIpcCloudStat(timeoutMs)
    end
    mergeTfRecordIntoCloudStat()
    log.info(LOG_TAG, "ipc_cloud_stat_refresh",
        isIpcCloudStatStale() and "stale_after_query" or "ok",
        force and "force" or "normal")
    return type(state.host_ipc_cloud_stat) == "table"
end

--- §4.3：4G 会话 recording 与 T3x AT+RECORD? 对账；须在 task 内调用
function isHostUartQueryBusy()
    return state.record_query_busy == true
        or state.recordtime_query_busy == true
        or state.tf_card_query_busy == true
        or state.ipc_status_query_busy == true
        or state.ipc_cloud_stat_query_busy == true
        or state.ipc_poweroff_busy == true
        or state.tfcard_format_busy == true
        or state.uart_recovery_busy == true
        or isHostInboundQuiet()
end

function reconcileHostRecordSession(timeoutMs)
    local ok_pc, pir_ctrl = pcall(require, "pir_ctrl")
    if not ok_pc or not pir_ctrl or not pir_ctrl.isRecording then
        return false
    end
    if not pir_ctrl.isRecording() then
        return false
    end
    if not coroutine.running() then
        log.info(LOG_TAG, "record_reconcile_skip", "no_task")
        return false
    end
    if not state.host_at_ready then
        log.info(LOG_TAG, "record_reconcile_skip", "no_at")
        return false
    end
    if isHostUartQueryBusy() then
        local reason = isHostInboundQuiet() and "push_quiet" or "uart_busy"
        log.info(LOG_TAG, "record_reconcile_skip", reason)
        return false
    end
    if not isT31StartedForHostQuery() then
        log.info(LOG_TAG, "record_reconcile_skip", "t31_off")
        return false
    end
    local snap = queryHostRecord(timeoutMs or 3500)
    if type(snap) ~= "table" then
        log.info(LOG_TAG, "record_reconcile_skip", "query_fail")
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
    if pir_ctrl.syncStopFromT3x then
        uploadMode, quality = pir_ctrl.syncStopFromT3x(reason)
    end
    log.info(LOG_TAG, "record_sync_stop", reason)
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_RECORD_STOP or "APP_T3X_RECORD_STOP", reason, uploadMode, quality)
    return true
end

--- 须在 task 内调用；向 T3x 发 AT+IPCSTAT?（§6.2 扩展状态）
function queryHostIpcCloudStat(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "ipc_cloud_stat_query_busy",
        busy_log = "ipc_cloud_stat_busy",
        busy_return = getCachedHostIpcCloudStat(),
        policy_tag = "host_ipc",
        cfg = ipc_cfg(),
        timeout_cfg_key = "status_query_timeout_ms",
        default_timeout = 2500,
        wait_boot = false,
        at_cmd = "AT+IPCSTAT?",
        ack_event = SYS_EVT.IPCSTAT_ACK,
        default_result = getCachedHostIpcCloudStat(),
        no_uart_log = "ipc_cloud_stat_no_uart",
        err_log = "ipc_cloud_stat_error",
        when_disabled = function()
            return getCachedHostIpcCloudStat()
        end,
        on_no_t3x = function()
            return getCachedHostIpcCloudStat()
        end,
        on_no_uart = function()
            return getCachedHostIpcCloudStat()
        end,
        on_response = function(got, snap)
            if got and type(snap) == "table" then
                commitHostIpcCloudStat(snap)
                log.info(LOG_TAG, "ipc_cloud_stat_ok")
                return snap
            end
            return getCachedHostIpcCloudStat()
        end,
        on_error = function()
            return getCachedHostIpcCloudStat()
        end,
    })
end

function getCachedHostTfCard()
    return state.host_tf_card
end

local function uart_recovery_cfg()
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

local function uart_recovery_enabled()
    return uart_recovery_cfg().enabled == true
end

local function reset_uart_recovery_miss()
    state.ipc_uart_miss_streak = 0
end

note_uart_link_ok = function()
    reset_uart_recovery_miss()
end

local function is_t3x_powered_on()
    local ok, t3x = pcall(require, "t3x_ctrl")
    if ok and type(t3x) == "table" and t3x.getState then
        local st = t3x.getState()
        return st ~= nil and st.powered_on == true
    end
    return false
end

local function run_uart_power_cycle_recovery(attempt)
    local rc = uart_recovery_cfg()
    local ok, t3x = pcall(require, "t3x_ctrl")
    if not ok or type(t3x) ~= "table" then
        return false
    end
    log.info(LOG_TAG, "uart_recovery_cycle", attempt or 0,
        "off_ms", rc.power_off_ms, "on_ms", rc.power_on_wait_ms)
    if is_t3x_powered_on() and t3x.powerOff then
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
    if is_usb_inserted() then
        push_usb_host_idle_state(true)
    end
    state.uart_recovery_last_sec = os.time()
    reset_uart_recovery_miss()
    return true
end

local function maybe_uart_recovery_after_miss(source)
    if not uart_recovery_enabled() then
        return
    end
    if state.host_at_ready then
        return
    end
    if not is_usb_inserted() then
        reset_uart_recovery_miss()
        return
    end
    if state.uart_recovery_busy then
        return
    end
    local rc = uart_recovery_cfg()
    state.ipc_uart_miss_streak = (tonumber(state.ipc_uart_miss_streak) or 0) + 1
    if state.ipc_uart_miss_streak < rc.miss_threshold then
        return
    end
    if state.uart_recovery_attempts >= rc.max_attempts then
        log.warn(LOG_TAG, "uart_recovery_exhausted",
            state.uart_recovery_attempts, source or "")
        return
    end
    local last = tonumber(state.uart_recovery_last_sec) or 0
    if last > 0 and (os.time() - last) < rc.cooldown_sec then
        return
    end
    state.uart_recovery_busy = true
    state.uart_recovery_attempts = state.uart_recovery_attempts + 1
    log.info(LOG_TAG, "uart_recovery_sched", state.uart_recovery_attempts,
        source or "", "miss", state.ipc_uart_miss_streak)
    sys.taskInit(function()
        local okRun, errRun = pcall(function()
            run_uart_power_cycle_recovery(state.uart_recovery_attempts)
        end)
        state.uart_recovery_busy = false
        if not okRun then
            log.warn(LOG_TAG, "uart_recovery_fail", tostring(errRun))
        end
    end)
end

function resetHostLinkState()
    state.host_at_ready = false
    state.first_host_at = nil
    state.host_ipc_status = nil
    state.host_ipc_cloud_stat = nil
    reset_uart_recovery_miss()
    log.info(LOG_TAG, "link_reset")
end

--- 须在 task 内调用；向 T3x 发 AT+IPCSTATUS?，超时视为 idle（T3x 未上电或无应答）
function queryHostIpcStatus(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "ipc_status_query_busy",
        busy_log = "ipc_status_busy",
        busy_return = state.host_ipc_status or "idle",
        policy_tag = "host_ipc",
        cfg = ipc_cfg(),
        timeout_cfg_key = "status_query_timeout_ms",
        default_timeout = 2000,
        wait_boot = false,
        at_cmd = "AT+IPCSTATUS?",
        ack_event = SYS_EVT.IPCSTATUS_ACK,
        default_result = "idle",
        no_uart_log = "ipc_status_no_uart",
        err_log = "ipc_status_error",
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
                log.info(LOG_TAG, "ipc_status", st)
                return st
            end
            state.host_ipc_status = "idle"
            log.info(LOG_TAG, "ipc_status_no_response")
            maybe_uart_recovery_after_miss("ipc_status")
            return "idle"
        end,
        on_error = noop_idle,
    })
end

--- 须在 task 内调用；T3x 在线时发 AT+IPCPOWEROFF，等待 +IPCPOWEROFF:OK
function hostIpcPowerOff(playSound, timeoutMs)
    if state.ipc_poweroff_busy then
        log.warn(LOG_TAG, "ipcstatus_busy")
        return false
    end
    state.ipc_poweroff_busy = true

    local success = false
    local cfg = ipc_cfg()
    local ok, err = pcall(function()
        timeoutMs = tonumber(timeoutMs) or tonumber(cfg.poweroff_timeout_ms) or 15000
        if cfg.enabled == false then
            return
        end
        if not uart_bridge.sendString then
            log.warn(LOG_TAG, "ipcstatus_no_uart")
            return
        end

        local cmd
        if playSound == false then
            cmd = "AT+IPCPOWEROFF=0"
        else
            cmd = "AT+IPCPOWEROFF=1"
        end
        log.info(LOG_TAG, cmd, timeoutMs)
        uart_bridge.sendString(cmd, true)
        local got = sys.waitUntil(SYS_EVT.IPCPOWEROFF_ACK, timeoutMs)
        if got then
            success = true
            state.host_ipc_status = "idle"
            log.info(LOG_TAG, "ipcstatus_done")
        else
            log.warn(LOG_TAG, "ipcstatus_timeout", timeoutMs)
        end
    end)

    state.ipc_poweroff_busy = false
    if not ok then
        log.warn(LOG_TAG, "ipcstatus_error", err)
        return false
    end
    return success
end

--- 须在 task 内调用；轮询 AT+IPCSTATUS? 直到 ready 或超时
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
        local st = queryHostIpcStatus(tonumber(cfg.status_query_timeout_ms) or 2000)
        if st == "ready" then
            return true
        end
        if st == "shutting_down" then
            log.info(LOG_TAG, "power_off_ack")
        end

        if deadline and mcu and mcu.ticks then
            if mcu.ticks() >= deadline then
                log.warn(LOG_TAG, "ready_timeout", timeoutMs)
                return false
            end
        elseif (os.time() - start) * 1000 >= timeoutMs then
            log.warn(LOG_TAG, "ready_timeout", timeoutMs)
            return false
        end
        sys.wait(pollMs)
    end
end

--- 须在 task 内调用；向 T3x 发 AT+TFCARD? 并等待 +TFCARD:
local function record_cfg()
    return _G.HOST_RECORD_CFG or {}
end

--- T3x 是否正在/曾写盘（AT+RECORD=1/0 维护）
function getT3xRecActive()
    return tonumber(state.t3x_rec_active) or 0
end

--- 须在 task 内调用；向 T3x 发 AT+RECORD? 查询真实写盘状态
function queryHostRecord(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "record_query_busy",
        cache_key = "host_record",
        policy_tag = "host_record",
        cfg = record_cfg(),
        default_timeout = 3000,
        at_cmd = "AT+RECORD?",
        ack_event = SYS_EVT.RECORD_ACK,
        log_extra = "mqtt_start",
        no_uart_log = "record_query_no_uart",
        err_log = "record_query_error",
        when_disabled = function(cfg)
            if cfg.enabled == false then
                return state.host_record
            end
        end,
        on_response = function(got, snap, tmo)
            if got and type(snap) == "table" then
                state.host_record = snap
                log.info(LOG_TAG, "record_query",
                    snap.running, snap.active, snap.ch, snap.reason)
                return state.host_record
            end
            log.warn(LOG_TAG, "record_query_timeout", tmo)
            return nil
        end,
        on_error = noop_nil,
    })
end

--- 须在 task 内调用；向 T3x 发 AT+RECORDTIME? 查询录像时长档位（分钟）
function queryHostRecordTime(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "recordtime_query_busy",
        cache_key = "host_record_time",
        policy_tag = "host_recordtime",
        cfg = record_cfg(),
        default_timeout = 3000,
        at_cmd = "AT+RECORDTIME?",
        ack_event = SYS_EVT.RECORDTIME_ACK,
        log_extra = "mqtt_start",
        no_uart_log = "recordtime_no_uart",
        err_log = "recordtime_error",
        when_disabled = function(cfg)
            if cfg.enabled == false then
                return state.host_record_time
            end
        end,
        on_response = function(got, snap, tmo)
            if got and type(snap) == "table" and snap.parsed then
                state.host_record_time = snap
                log.info(LOG_TAG, "recordtime_query", snap.minutes)
                return state.host_record_time
            end
            log.warn(LOG_TAG, "recordtime_timeout", tmo)
            return state.host_record_time
        end,
        on_error = noop_nil,
    })
end

function getCachedHostRecordTime()
    return state.host_record_time
end

--- 须在 task 内调用；向 T3x 发 AT+RECORDTIME=<min>（固定档位 5/10/15/20/30/45/60）
function setHostRecordTime(opts)
    opts = opts or {}
    return host_set({
        busy_key = "recordtime_set_busy",
        policy_tag = "host_recordtime_set",
        cfg = record_cfg(),
        default_timeout = 3000,
        timeout_ms = opts.timeout_ms,
        ack_event = SYS_EVT.RECORDTIME_SET,
        log_tag = "recordtime_set",
        prepare = function()
            local min = tonumber(opts.minutes or opts.recTime or opts.recordTimeMin)
            if min == nil then
                return false, "missing_min"
            end
            return true, nil, string.format("AT+RECORDTIME=%d", min)
        end,
        parse_rsp = function(rsp)
            if rsp.ok then
                state.host_record_time = rsp
                return true, "ok", { minutes = rsp.minutes }
            end
            if rsp.invalid then
                return false, "invalid_minute", nil
            end
            return false, "error", nil
        end,
    })
end

--- MQTT 2024/2025：查询 T3x 帧率（AT+FRAMERATE?）
function queryHostFramerate(opts)
    opts = opts or {}
    local cam = tonumber(opts.camera)
    local stream = tonumber(opts.stream)
    local at_cmd = "AT+FRAMERATE?"
    if cam ~= nil then
        at_cmd = string.format("AT+FRAMERATE?=%d", cam)
        if stream ~= nil then
            at_cmd = string.format("AT+FRAMERATE?=%d,%d", cam, stream)
        end
    end
    return host_query(opts.timeout_ms, {
        busy_key = "framerate_query_busy",
        cache_key = "host_framerate",
        policy_tag = "host_framerate",
        cfg = encode_cfg(),
        default_timeout = 5000,
        at_cmd = at_cmd,
        ack_event = SYS_EVT.FRAMERATE_QUERY,
        before_send = function()
            state.framerate_rows = {}
        end,
        log_extra = "fpsQ",
        no_uart_log = "framerate_no_uart",
        err_log = "framerate_error",
        on_response = function(got, rows, tmo)
            if got and type(rows) == "table" then
                state.host_framerate = rows
                return rows
            end
            log.warn(LOG_TAG, "framerate_timeout", tmo)
            return state.host_framerate
        end,
        on_error = noop_nil,
    })
end

--- MQTT 2025：设置 T3x 帧率（AT+FRAMERATE=cam,stream,fps）
function setHostFramerate(opts)
    opts = opts or {}
    return host_set({
        busy_key = "framerate_set_busy",
        policy_tag = "host_framerate_set",
        cfg = encode_cfg(),
        default_timeout = 8000,
        timeout_ms = opts.timeout_ms,
        ack_event = SYS_EVT.FRAMERATE_SET,
        prepare = function()
            local cam = tonumber(opts.camera) or 0
            local stream = tonumber(opts.stream) or 0
            local fps = tonumber(opts.framerate or opts.fps)
            if fps == nil then
                return false, "missing_framerate"
            end
            return true, nil, string.format("AT+FRAMERATE=%d,%d,%d", cam, stream, fps)
        end,
        parse_rsp = function(rsp)
            if rsp.ok then
                return true, "ok", rsp
            end
            return false, "error", nil
        end,
    })
end

--- MQTT 2012 直连：T3x 已在线时 AT+RECORDCTRL=1[,max_sec]
function recordCtrlStart(opts)
    opts = opts or {}
    local maxSec = tonumber(opts.max_sec or opts.videoMaxDurationSec) or 60
    return host_set({
        policy_tag = "host_recordctrl_start",
        cfg = identity_cfg(),
        boot_cfg = record_cfg(),
        default_timeout = 8000,
        timeout_ms = opts.timeout_ms,
        ack_event = SYS_EVT.RECORDCTRL_SET,
        prepare = function()
            return true, nil, string.format("AT+RECORDCTRL=1,%d", maxSec)
        end,
        parse_rsp = function(rsp)
            if rsp.ok and rsp.start == 1 then
                return true, "ok", rsp
            end
            return false, "error", rsp
        end,
    })
end

--- MQTT 2011 直连：T3x 已在线时 AT+RECORDCTRL=0[,reason]
function recordCtrlStop(opts)
    opts = opts or {}
    local reason = tostring(opts.reason or "cloud")
    return host_set({
        policy_tag = "host_recordctrl_stop",
        cfg = identity_cfg(),
        boot_cfg = record_cfg(),
        default_timeout = 8000,
        timeout_ms = opts.timeout_ms,
        ack_event = SYS_EVT.RECORDCTRL_SET,
        prepare = function()
            return true, nil, string.format("AT+RECORDCTRL=0,%s", reason)
        end,
        parse_rsp = function(rsp)
            if rsp.ok and rsp.start == 0 then
                return true, "ok", rsp
            end
            return false, "error", rsp
        end,
    })
end

--- MQTT 2026/2027：查询/设置人形检测（AT+PERSONDET? / AT+PERSONDET=）
function queryHostPersonDetect(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "persondet_query_busy",
        cache_key = "host_person_detect",
        policy_tag = "host_persondet",
        cfg = identity_cfg(),
        default_timeout = 5000,
        at_cmd = "AT+PERSONDET?",
        ack_event = SYS_EVT.PERSONDET_ACK,
        log_extra = "pdQ",
        no_uart_log = "persondet_no_uart",
        err_log = "persondet_error",
        on_response = function(got, snap, tmo)
            if got and type(snap) == "table" and snap.parsed then
                state.host_person_detect = snap
                return snap
            end
            log.warn(LOG_TAG, "persondet_timeout", tmo)
            return state.host_person_detect
        end,
        on_error = noop_nil,
    })
end

function setHostPersonDetect(opts)
    opts = opts or {}
    return host_set({
        busy_key = "persondet_set_busy",
        policy_tag = "host_persondet_set",
        cfg = identity_cfg(),
        default_timeout = 5000,
        timeout_ms = opts.timeout_ms,
        ack_event = SYS_EVT.PERSONDET_SET,
        prepare = function()
            local enable = tonumber(opts.enable)
            if enable == nil or (enable ~= 0 and enable ~= 1) then
                return false, "invalid_enable"
            end
            return true, nil, string.format("AT+PERSONDET=%d", enable)
        end,
        parse_rsp = function(rsp)
            if rsp.ok then
                return true, "ok", rsp
            end
            return false, "error", nil
        end,
    })
end

--- MQTT 2028/2029：查询/设置麦克风 AI 音量增益（AT+MIC? / AT+MICSET=）
function queryHostMic(opts)
    opts = opts or {}
    local cam = tonumber(opts.camera)
    local at_cmd = "AT+MIC?"
    if cam ~= nil then
        at_cmd = string.format("AT+MIC?=%d", cam)
    end
    return host_query(opts.timeout_ms, {
        busy_key = "mic_query_busy",
        cache_key = "host_mic",
        policy_tag = "host_mic",
        cfg = identity_cfg(),
        default_timeout = 8000,
        at_cmd = at_cmd,
        ack_event = SYS_EVT.MIC_QUERY,
        before_send = function()
            state.mic_rows = {}
        end,
        log_extra = "micQ",
        no_uart_log = "mic_no_uart",
        err_log = "mic_error",
        on_response = function(got, rows, tmo)
            if got and type(rows) == "table" then
                state.host_mic = rows
                return rows
            end
            log.warn(LOG_TAG, "mic_timeout", tmo)
            return state.host_mic
        end,
        on_error = noop_nil,
    })
end

function setHostMic(opts)
    opts = opts or {}
    return host_set({
        busy_key = "mic_set_busy",
        policy_tag = "host_mic_set",
        cfg = identity_cfg(),
        default_timeout = 8000,
        timeout_ms = opts.timeout_ms,
        ack_event = SYS_EVT.MIC_SET,
        prepare = function()
            local cam = tonumber(opts.camera) or 0
            local volume = tonumber(opts.volume)
            local gain = tonumber(opts.gain)
            if volume == nil or gain == nil then
                return false, "missing_params"
            end
            return true, nil, string.format("AT+MICSET=%d,%d,%d", cam, volume, gain)
        end,
        parse_rsp = function(rsp)
            if rsp.ok then
                return true, "ok", rsp
            end
            return false, "error", nil
        end,
    })
end

--- MQTT 2030/2031：查询/设置软光敏（AT+SOFTPHOTO? / AT+SOFTPHOTOSET=）
function queryHostSoftPhoto(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "softphoto_query_busy",
        cache_key = "host_softphoto",
        policy_tag = "host_softphoto",
        cfg = identity_cfg(),
        default_timeout = 8000,
        at_cmd = "AT+SOFTPHOTO?",
        ack_event = SYS_EVT.SOFTPHOTO_QUERY,
        log_extra = "spQ",
        no_uart_log = "softphoto_no_uart",
        err_log = "softphoto_error",
        on_response = function(got, snap, tmo)
            if got and type(snap) == "table" and snap.parsed then
                state.host_softphoto = snap
                return snap
            end
            log.warn(LOG_TAG, "softphoto_timeout", tmo)
            return state.host_softphoto
        end,
        on_error = noop_nil,
    })
end

function setHostSoftPhoto(opts)
    opts = opts or {}
    return host_set({
        busy_key = "softphoto_set_busy",
        policy_tag = "host_softphoto_set",
        cfg = identity_cfg(),
        default_timeout = 8000,
        timeout_ms = opts.timeout_ms,
        ack_event = SYS_EVT.SOFTPHOTO_SET,
        prepare = function()
            local fields = {
                tonumber(opts.enable),
                tonumber(opts.nightModeThreshold or opts.night_mode_threshold),
                tonumber(opts.dayModeThreshold or opts.day_mode_threshold),
                tonumber(opts.dayModeAltThreshold or opts.day_mode_alt_threshold),
                tonumber(opts.gbGainThreshold or opts.gb_gain_threshold),
                tonumber(opts.gbGainRecordInit or opts.gb_gain_record_init),
                tonumber(opts.checkTime or opts.check_time),
                tonumber(opts.checkCount or opts.check_count),
            }
            for i = 1, #fields do
                if fields[i] == nil then
                    return false, "missing_params"
                end
            end
            return true, nil, string.format(
                "AT+SOFTPHOTOSET=%d,%d,%d,%d,%d,%d,%d,%d",
                fields[1], fields[2], fields[3], fields[4],
                fields[5], fields[6], fields[7], fields[8])
        end,
        parse_rsp = function(rsp)
            if rsp.ok then
                return true, "ok", rsp
            end
            return false, "error", nil
        end,
    })
end

function queryHostTfCard(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "tf_card_query_busy",
        cache_key = "host_tf_card",
        busy_log = "tfcard_busy",
        policy_tag = "host_tfcard",
        cfg = tf_card_cfg(),
        default_timeout = 3000,
        at_cmd = "AT+TFCARD?",
        ack_event = SYS_EVT.TFCARD_ACK,
        log_extra = "mqtt_start",
        no_uart_log = "tfcard_no_uart",
        err_log = "tfcard_error",
        on_response = function(got, snap, tmo)
            if got and type(snap) == "table" and snap.parsed then
                state.host_tf_card = snap
                log.info(LOG_TAG, "tfcard_query",
                    snap.present, snap.total_mb, snap.used_mb, snap.free_mb)
                return state.host_tf_card
            end
            log.warn(LOG_TAG, "tfcard_timeout", tmo)
            return nil
        end,
        on_error = noop_nil,
    })
end

local function tfcard_format_cfg()
    return _G.HOST_TFCARD_FORMAT_CFG or {}
end

--- 须在 task 内调用：停录→umount→格式化→mount（T3x AT+TFFORMAT=1[,reboot=0|1]）
function formatHostTfCard(opts)
    opts = type(opts) == "table" and opts or {}
    local cfg = tfcard_format_cfg()
    if cfg.enabled == false then
        return false, "disabled"
    end
    if state.tfcard_format_busy then
        return false, "busy"
    end
    if _G.MODULE_FLAGS and (_G.MODULE_FLAGS.t3x_app == false or _G.MODULE_FLAGS.uart_bridge == false) then
        return false, "no_uart"
    end
    if not ensure_t3x_for_host_query("host_tfcard_format", cfg) then
        return false, "t3x_unavailable"
    end
    local timeoutMs = tonumber(opts.timeout_ms) or tonumber(cfg.format_timeout_ms) or 120000
    local reboot = opts.reboot
    if reboot == nil then
        reboot = cfg.reboot_after == true or cfg.reboot_after == 1
    end
    reboot = (reboot == 1 or reboot == true) and 1 or 0
    state.tfcard_format_busy = true
    local outcome = { ok = false, reason = "unknown" }
    local okRun, errRun = pcall(function()
        if opts.wait_boot ~= false and not state.host_at_ready then
            sys.wait(host_boot_wait_ms(cfg))
        end
        if not uart_bridge.sendString then
            error("no_uart")
        end
        local atCmd = string.format("AT+TFFORMAT=1,reboot=%d", reboot)
        log.info(LOG_TAG, "tfformat_tx", atCmd, timeoutMs)
        uart_bridge.sendString(atCmd, true)
        local deadline = (os.time() * 1000) + timeoutMs
        local started = false
        while (os.time() * 1000) < deadline do
            local remain = deadline - (os.time() * 1000)
            if remain <= 0 then
                break
            end
            local slice = remain > 5000 and 5000 or remain
            local got, val = sys.waitUntil(SYS_EVT.TFFORMAT_ACK, slice)
            if got and type(val) == "table" then
                if val.phase == "started" then
                    started = true
                    log.info(LOG_TAG, "tfformat_started")
                elseif val.phase == "ok" then
                    log.info(LOG_TAG, "tfformat_ok", val.reboot or 0)
                    outcome.ok = true
                    outcome.detail = val
                    return
                elseif val.phase == "error" then
                    log.warn(LOG_TAG, "tfformat_ipc_error", val.ret or "error")
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
        log.warn(LOG_TAG, "tfformat_fail", tostring(errRun))
        return false, tostring(errRun)
    end
    return false, outcome.reason
end

function isHostTfFormatBusy()
    return state.tfcard_format_busy == true
end

--- 供 MQTT 2006 / 唤醒前设置 PIRSTAT：action=devinfo,recording=0,max_sec=0
function setPirActionDevinfo()
    local ok, pc = pcall(require, "pir_ctrl")
    if ok and type(pc) == "table" and pc.setMediaConfig then
        pc.setMediaConfig({ action = "devinfo" })
        log.info(LOG_TAG, "pir_defer")
        return true
    end
    return false
end

local function encode_cfg()
    return _G.HOST_ENCODE_CFG or {}
end

local function encode_timeout_ms(opts)
    opts = opts or {}
    local cfg = encode_cfg()
    return tonumber(opts.timeout_ms) or tonumber(cfg.query_timeout_ms) or 8000
end

local function encode_rows_valid(rows, isAudio)
    if type(rows) ~= "table" or rows.__error then
        return false
    end
    if #rows == 0 then
        return false
    end
    for _, row in ipairs(rows) do
        if isAudio then
            if (row.enable or 0) ~= 0 or (row.samplerate or 0) > 0 or (row.encoder or 0) > 0 then
                return true
            end
        else
            if (row.enable or 0) ~= 0
                or (row.width or 0) > 0
                or (row.height or 0) > 0
                or (row.bitrate or 0) > 0 then
                return true
            end
        end
    end
    return false
end

local function finish_encode_query(rows, isAudio)
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

local function build_encode_query_cmd(opts)
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

local function queryHostEncodeInner(opts)
    opts = opts or {}
    local isAudio = opts.scope == "audio"
    local cfg = encode_cfg()
    local at_cmd = build_encode_query_cmd(opts)
    local ack_event = isAudio and SYS_EVT.AUDIO_QUERY or SYS_EVT.VENC_QUERY

    if isAudio then
        state.encode_audio_rows = {}
    else
        state.encode_venc_rows = {}
    end

    local result = host_query(opts.timeout_ms, {
        busy_key = "encode_query_busy",
        busy_log = "encode_busy",
        policy_tag = "host_encode",
        cfg = cfg,
        timeout_cfg_key = "query_timeout_ms",
        default_timeout = 8000,
        at_cmd = at_cmd,
        ack_event = ack_event,
        log_extra = isAudio and "audio" or "video",
        no_uart_log = "encode_no_uart",
        err_log = "encode_error",
        on_response = function(got, val, tmo)
            if got then
                local body, err = finish_encode_query(val, isAudio)
                if body then
                    log.info(LOG_TAG, "encode_query", isAudio and "audio" or "video", #(val or {}))
                    return body
                end
                log.warn(LOG_TAG, "encode_bad_response", err or "bad", tmo)
                return nil
            end
            log.warn(LOG_TAG, "encode_timeout", tmo)
            return nil
        end,
        on_error = noop_nil,
    })

    if result then
        return result, nil
    end
    return nil, "timeout"
end

--- 查询 T3x 编码参数（video / audio）；须在 task 内调用
function queryHostEncode(opts)
    local result, err = queryHostEncodeInner(opts)
    if result then
        return result, err
    end
    return nil, err or "query_fail"
end

local function await_encode_set(event, timeoutMs)
    local got, rsp = sys.waitUntil(event, timeoutMs)
    if not got or type(rsp) ~= "table" then
        return false, "timeout", nil
    end
    if rsp.ok then
        return true, "ok", rsp
    end
    return false, "error", rsp
end

local function setHostEncode(scope, opts)
    if state.encode_set_busy then
        return false, "busy", nil
    end
    state.encode_set_busy = true
    local okSet, msg, extra
    local ok, e = pcall(function()
        opts = opts or {}
        local timeoutMs = encode_timeout_ms(opts)
        local cam = tonumber(opts.camera) or 0
        if not ensure_t3x_for_host_query("host_encode_set", identity_cfg()) then
            okSet, msg = false, "t3x_unavailable"
            return
        end
        if not state.host_at_ready then
            sys.wait(host_boot_wait_ms(encode_cfg()))
        end
        local cur
        if scope == "audio" then
            if opts.encoder == nil or opts.samplerate == nil then
                local q, qerr = queryHostEncodeInner({ scope = "audio", camera = cam, timeout_ms = timeoutMs })
                if q and q.audio and q.audio[1] then
                    cur = q.audio[1]
                elseif qerr then
                    okSet, msg = false, qerr
                    return
                end
            end
            cur = cur or {}
            local en = opts.enable
            if en == nil then en = cur.enable or 1 end
            local cmd = string.format("AT+AUDIOSET=%d,%d,%d,%d,%d,%d,%d,%d",
                cam, (en == true or en == 1) and 1 or 0,
                tonumber(opts.encoder or cur.encoder) or 4,
                tonumber(opts.samplerate or cur.samplerate) or 8000,
                tonumber(opts.bitwidth or cur.bitwidth) or 16,
                tonumber(opts.soundmode or cur.soundmode) or 1,
                tonumber(opts.volume or cur.volume) or 80,
                tonumber(opts.gain or cur.gain) or 28)
            uart_bridge.sendString(cmd, true)
            local got, m, rsp = await_encode_set(SYS_EVT.AUDIO_SET, timeoutMs)
            okSet, msg, extra = got, m, rsp
            return
        end
        local stream = tonumber(opts.stream) or 0
        if opts.width == nil or opts.height == nil or opts.bitrate == nil then
            local q, qerr = queryHostEncodeInner({ camera = cam, stream = stream, timeout_ms = timeoutMs })
            if q and q.video and q.video[1] then
                cur = q.video[1]
            elseif qerr then
                okSet, msg = false, qerr
                return
            end
        end
        cur = cur or {}
        local en = opts.enable
        if en == nil then en = cur.enable or 1 end
        local cmd = string.format("AT+VENCSET=%d,%d,%d,%d,%d,%d,%d,%d,%d",
            cam, stream, (en == true or en == 1) and 1 or 0,
            tonumber(opts.width or cur.width) or 1920,
            tonumber(opts.height or cur.height) or 1080,
            tonumber(opts.bitrate or cur.bitrate) or 1200,
            tonumber(opts.framerate or cur.framerate) or 25,
            tonumber(opts.rcmode or cur.rcmode) or 2,
            tonumber(opts.encoder or cur.encoder) or 4)
        uart_bridge.sendString(cmd, true)
        local got, m, rsp = await_encode_set(SYS_EVT.VENC_SET, timeoutMs)
        okSet, msg, extra = got, m, rsp
    end)
    state.encode_set_busy = false
    if not ok then
        return false, tostring(e), nil
    end
    return okSet, msg, extra
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
    bind_start_hooks(opts)
    uart_bridge.setOnLine(on_uart_line)
    started = true
    log.info(LOG_TAG, "host_uart_on")
    return true
end

function stop()
    if not started then
        return false
    end
    uart_bridge.setOnLine(nil)
    started = false
    log.info(LOG_TAG, "host_uart_off")
    return true
end

--- USB 拔插时通知 T3x：禁止/允许 HOSTIDLE 休眠轮询（+CAT1:USB,1/0）；见 HOST_USB_CFG
function push_usb_host_idle_state(inserted)
    local cfg = host_usb_cfg()
    local notify = cfg.notify_t3x_usb_state
    if notify == false then
        return false
    end
    local writeFn = hooks.uart_write
    if not writeFn and package.loaded.uart_bridge then
        writeFn = package.loaded.uart_bridge.write
    end
    if not writeFn then
        return false
    end
    local tpl = cfg.t3x_usb_ursp or "+CAT1:USB,%d"
    local line = string.format(tpl, inserted and 1 or 0)
    if not line:find("\r\n", 1, true) then
        line = line .. CRLF
    end
    writeFn(line)
    log.info(LOG_TAG, "usb_host_idle", inserted and "block" or "allow")
    return true
end

function isUsbInserted()
    return is_usb_inserted()
end

--- 可选：MQTT 联网态变化时通知 T3x 驱动 NET_STAT_LED（PB17）；见 LED_CFG.notify_t3x_net_led
function push_net_led_state(online)
    local cfg = _G.LED_CFG or {}
    local notify = cfg.notify_t3x_net_led
    if notify ~= true then
        return false
    end
    local writeFn = hooks.uart_write
    if not writeFn and package.loaded.uart_bridge then
        writeFn = package.loaded.uart_bridge.write
    end
    if not writeFn then
        return false
    end
    local tpl = cfg.t3x_net_ursp or "+CAT1:MQTT,%d"
    local line = string.format(tpl, online and 1 or 0)
    if not line:find("\r\n", 1, true) then
        line = line .. CRLF
    end
    writeFn(line)
    log.info(LOG_TAG, "net_status_led", online and "1" or "0")
    return true
end

function notify_host(sid, evt)
    local cfg = _G.HOST_WAKE_CFG or {}
    sid = sid or cfg.default_sid or 1
    evt = evt or _M.EVT.SERVER_DATA

    local okPol, policy = pcall(require, "t3x_policy")
    if okPol and type(policy) == "table" and policy.mayPowerT3x
        and not policy.mayPowerT3x("notify_host") then
        log.info(LOG_TAG, "net_host_skip", policy.getDenyReason and policy.getDenyReason() or "")
        return false
    end

    set_pending_wake(sid, evt)
    if not t3xModule then
        t3xModule = require "t3x_ctrl"
    end
    if t3xModule.getState and not t3xModule.getState().powered_on and t3xModule.powerOn then
        t3xModule.powerOn()
    end
    local okBg, bg = pcall(require, "battery_guard")
    if okBg and type(bg) == "table" and bg.markT3xWoken then
        bg.markT3xWoken()
    end
    if t3xModule.pulseMcuInt then
        return t3xModule.pulseMcuInt()
    end
    log.warn(LOG_TAG, "pulse_net_no_policy")
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
