require "sys"
require "config"

local uart_bridge = require "uart_bridge"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "hu"
local CRLF = "\r\n"
local RSP_ERROR = CRLF .. "ERROR" .. CRLF
local RSP_SETCFG_OK = CRLF .. "+SETCFG:OK" .. CRLF
local RSP_SETCFG_ERR = CRLF .. "+SETCFG:ERROR" .. CRLF
local GB28181_ACK_EVENT = "HOST_UART_GB28181_ACK"
local TFCARD_ACK_EVENT = "HOST_UART_TFCARD_ACK"
local RECORD_ACK_EVENT = "HOST_UART_RECORD_ACK"
local IPCSTATUS_ACK_EVENT = "HOST_UART_IPCSTATUS_ACK"
local IPCPOWEROFF_ACK_EVENT = "HOST_UART_IPCPOWEROFF_ACK"
local VENC_QUERY_DONE = "HOST_UART_VENC_QUERY_DONE"
local VENC_SET_DONE = "HOST_UART_VENC_SET_DONE"
local AUDIO_QUERY_DONE = "HOST_UART_AUDIO_QUERY_DONE"
local AUDIO_SET_DONE = "HOST_UART_AUDIO_SET_DONE"

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
    gb28181_query_busy = false,
    gb28181_refresh_scheduled = false,
    host_tf_card = nil,
    tf_card_query_busy = false,
    host_record = nil,
    record_query_busy = false,
    host_ipc_status = nil,
    ipc_status_query_busy = false,
    ipc_poweroff_busy = false,
    encode_venc_rows = nil,
    encode_audio_rows = nil,
    encode_query_busy = false,
    encode_set_busy = false,
    t3x_rec_active = 0,
    t3x_last_reason = "idle",
}

local started = false
local t3xModule = nil

local function traceLine(s)
    s = tostring(s or "")
    s = s:gsub("\r", "\\r"):gsub("\n", "\\n")
    if #s > 240 then
        s = s:sub(1, 240) .. "..."
    end
    return s
end

local function writeToT3x(data, tag)
    if data == nil then
        return false
    end
    local ok = uart_bridge.write(data)
    log.info(LOG_TAG, tag or "tx", traceLine(data))
    return ok
end

local function sendToT3x(cmd, appendCrLf, tag)
    log.info(LOG_TAG, tag or "tx", traceLine(cmd))
    return uart_bridge.sendString(cmd, appendCrLf)
end

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
-- 鍞ら啋 pending
-- ---------------------------------------------------------------------------

local function set_pending_wake(sid, evt)
    state.pending_sid = tonumber(sid) or 1
    state.pending_evt = tonumber(evt) or 0
    state.pending_valid = true
end

local function clear_pending_wake()
    state.pending_valid = false
    state.pending_evt = -1
end

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
-- AT / 绠€鍐欒澶勭悊
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
        return rsp_body("TIME", "0")
    end
    return rsp_fmt("TIME", "%d", t)
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
        return rsp_line("mcfg", false)
    end
    if hooks.on_mqtt_cfg then
        hooks.on_mqtt_cfg(cfg)
    end
    return rsp_line("mcfg", true) .. ok_tail()
end

local function uart_servcreate(cmd)
    local okLp, lpw = pcall(require, "low_power_wakeup")
    if okLp and lpw and lpw.allowTcpChannel and not lpw.allowTcpChannel() then
        return rsp_body("sc+", "DISABLED")
    end
    local ch = parse_servcreate_args(cmd:match("^AT%+SERVCREATE=(.+)$"))
    if not ch then
        return RSP_ERROR
    end
    state.channel = ch
    if hooks.on_servcreate then
        hooks.on_servcreate(ch)
    elseif okLp and lpw and lpw.applyTcpChannel then
        lpw.applyTcpChannel(ch)
    end
    return rsp_fmt("SERVCREATE", "%d,OK", ch.sid)
end

local function uart_servclose(cmd)
    local sid = tonumber(cmd:match("^AT%+SERVCLOSE=(%d+)$"))
    if not sid then
        return RSP_ERROR
    end
    local okLp, lpw = pcall(require, "low_power_wakeup")
    if okLp and lpw and lpw.allowTcpChannel and not lpw.allowTcpChannel() then
        state.channel = nil
        return rsp_body("sc-", "DISABLED")
    end
    if hooks.on_servclose then
        hooks.on_servclose(sid)
    elseif okLp and lpw and lpw.closeTcpChannel then
        lpw.closeTcpChannel(sid)
    end
    state.channel = nil
    return rsp_fmt("SERVCLOSE", "%d", sid)
end

local function uart_getcfg(_cmd)
    local s = get_config_snapshot()
    return rsp_fmt(
        "GETCFG",
        "version=%s,online=%d,power=%d,lowpower=%d,battery=%s,vbat=%s,interval=%d,devicemodel=%s,wled=%d%s",
        s.version, s.online, s.power, s.lowpower, s.battery, s.vbat, s.interval, s.devicemodel, s.wled or 0,
        s.tcp_extra or ""
    )
end

local function build_pirstat_body()
    return build_pir_wake_body(false)
end

local function uart_pirstat_query(_cmd)
    return rsp_body("PIRSTAT", build_pirstat_body())
end

function buildPirstatBody()
    return build_pirstat_body()
end

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
        return rsp_fmt("HOSTIDLE", "lowpower=%d,usb=%d,host_idle_allow=%d", lp, usb, allow)
    end
    if cmd == "AT+HOSTIDLE=1" or cmd == "AT+HOSTIDLE=0" then
        if cmd == "AT+HOSTIDLE=0" then
            return rsp_body("HOSTIDLE", "OK")
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

local function uart_record_notify(cmd)
    local arg = cmd:match("^AT%+RECORD=(.+)$")
    if not arg or arg == "" then
        return RSP_ERROR
    end
    if arg == "1" then
        state.t3x_rec_active = 1
        state.t3x_last_reason = "active"
        local E = _G.APP_EVENTS or {}
        sys.publish(E.T3X_RECORD_ACTIVE or "APP_T3X_RECORD_ACTIVE")
        return rsp_body("RECORD", "1,active=1")
    end
    local reason = arg:match("^0,reason=(.+)$") or "unknown"
    state.t3x_rec_active = 0
    state.t3x_last_reason = reason
    local uploadMode, quality
    local ok_pc, pir_ctrl = pcall(require, "pir_ctrl")
    if ok_pc and pir_ctrl and pir_ctrl.syncStopFromT3x then
        uploadMode, quality = pir_ctrl.syncStopFromT3x(reason)
    end
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_RECORD_STOP or "APP_T3X_RECORD_STOP", reason, uploadMode, quality)
    return rsp_fmt("RECORD", "0,reason=%s", reason)
end

local function uart_person_cnt_notify(cmd)
    local cnt = cmd:match("^AT%+PERSONCNT=(%d+)$")
    if not cnt then
        return RSP_ERROR
    end
    local n = tonumber(cnt) or 0
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_PERSON_CNT or "APP_T3X_PERSON_CNT", n)
    return rsp_fmt("PERSONCNT", "ok,count=%d", n)
end

local function uart_pir_media_notify(cmd)
    local action = cmd:match("^AT%+PIRMEDIA=(.+)$")
    if not action or action == "" then
        return RSP_ERROR
    end
    local ok_pc, pir_ctrl = pcall(require, "pir_ctrl")
    if ok_pc and pir_ctrl and pir_ctrl.applyEffectiveMediaAction then
        pir_ctrl.applyEffectiveMediaAction(action)
    end
    return rsp_fmt("PIRMEDIA", "ok,action=%s", action)
end

local function uart_snapshot_notify(cmd)
    local path = cmd:match("^AT%+SNAPSHOT=(.+)$")
    if not path or path == "" then
        return RSP_ERROR
    end
    local E = _G.APP_EVENTS or {}
    sys.publish(E.T3X_SNAPSHOT_DONE or "APP_T3X_SNAPSHOT_DONE", path)
    return rsp_fmt("SNAPSHOT", "ok,path=%s", path)
end

local function uart_record_query(_cmd)
    local rec = 0
    local ok_pc, pir_ctrl = pcall(require, "pir_ctrl")
    if ok_pc and pir_ctrl and pir_ctrl.isRecording and pir_ctrl.isRecording() then
        rec = 1
    end
    return rsp_fmt("RECORD", "%d,reason=%s,active=%d",
        rec, state.t3x_last_reason or "idle", state.t3x_rec_active or 0)
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
    return rsp_fmt("ril", "%d", n)
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
-- 鐧藉厜鐏?WLED锛?G 鐘舵€?+ UART 杞彂 T3x锛夛紱瑙?doc/UART_PROTOCOL.md 路 MQTT 2004
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
        return ipc.ensurePowered("wled", { power_wait_ms = 0 })
    end
    return false
end

local function wled_forward_to_t3x(on)
    local wc = wled_cfg()
    if wc.forward_to_t3x == false then
        return false
    end
    if _G.MODULE_FLAGS and (_G.MODULE_FLAGS.t3x_app == false or _G.MODULE_FLAGS.uart_bridge == false) then
        return false
    end
    if not wled_ensure_t3x_powered() then
        return false
    end
    local waitMs = tonumber(wled_cfg().t3x_power_wait_ms) or 800
    if waitMs > 0 then
        sys.wait(waitMs)
    end
    sendToT3x(string.format("AT+WLED=%d", on), true)
    wled_state.last_forward_ms = mcu and mcu.ticks and mcu.ticks() or 0
    return true
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
    if opts.async ~= false then
        sys.taskInit(function()
            wled_forward_to_t3x(on)
        end)
    else
        wled_forward_to_t3x(on)
    end
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

local usb_recovery_guard = {
    busy = false,
    last_sec = 0,
    count = 0,
}

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
        log.warn(LOG_TAG, "usbRstD", "REST")
        return false, "REST"
    end
    return true, nil
end

local function net_mqtt_mod()
    local mod = package and package.loaded and package.loaded["net_mqtt"] or nil
    if mod then
        return mod
    end
    local ok, loaded = pcall(require, "net_mqtt")
    if ok and type(loaded) == "table" then
        return loaded
    end
end

local function usb_recovery_run_async(tag, cfg, do_fn)
    usb_recovery_guard.busy = true
    sys.taskInit(function()
        local notify_ms = tonumber(cfg.usb_reset_notify_after_ms) or 800
        local ok = false
        if do_fn then
            ok = do_fn() and true or false
        end
        if ok and cfg.notify_t3x_usb_state ~= false and is_usb_inserted() then
            sys.wait(notify_ms)
            push_usb_host_idle_state(1)
        end
        usb_recovery_guard.busy = false
        usb_recovery_guard.last_sec = os.time()
        usb_recovery_guard.count = (usb_recovery_guard.count or 0) + 1
        log.info(LOG_TAG, "usbRstR", tag, ok and 1 or 0, usb_recovery_guard.count)
    end)
end

local function uart_usbreset(cmd)
    local cfg = host_usb_cfg()
    if cmd == "AT+USBRESET?" then
        return rsp_fmt(
            "USBRESET",
            "busy=%d,count=%d,last=%d",
            usb_recovery_guard.busy and 1 or 0,
            usb_recovery_guard.count or 0,
            usb_recovery_guard.last_sec or 0
        )
    end
    if cmd ~= "AT+USBRESET" then
        return RSP_ERROR
    end
    local allowed, deny = usb_recovery_allowed(cfg)
    if not allowed then
        log.warn(LOG_TAG, "usbRstD", deny)
        return CRLF .. "+USBRESET:" .. deny .. CRLF
    end

    local okMod, usb_rndis = pcall(require, "usb_rndis")
    if not okMod or type(usb_rndis) ~= "table" then
        log.warn(LOG_TAG, "usbRstE", "no_rndis")
        return CRLF .. "+USBRESET:ERROR" .. CRLF
    end

    log.info(LOG_TAG, "usbRstS")

    usb_recovery_run_async("USBRESET", cfg, function()
        local okCtrl, t3x = pcall(require, "t3x_ctrl")
        if okCtrl and type(t3x) == "table" and t3x.pulseUsbDebugEn then
            t3x.pulseUsbDebugEn({ high_ms = cfg.usb_debug_en_pulse_ms })
        end
        if usb_rndis.rebind then
            return usb_rndis.rebind({ wait_ms = 500 })
        end
        if usb_rndis.disable and usb_rndis.open then
            usb_rndis.disable()
            sys.wait(500)
            return usb_rndis.open()
        end
        return false
    end)
    return rsp_body("USBRESET", "OK")
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
    sendToT3x("AT+USBRECOVERYRESET", true)
    export_usb_recovery_runtime({
        state = "idle",
        count = 0,
        last_err = "",
        usb_logical = is_usb_inserted() and 1 or 0,
        usb_netdev = 0,
    })
    usb_recovery_guard.count = 0
    publish_usb_recovery_changed()
    return true
end

local function uart_rndis(cmd)
    local okMod, usb_rndis = pcall(require, "usb_rndis")
    if not okMod or type(usb_rndis) ~= "table" then
        return RSP_ERROR
    end

    if cmd == "AT+RNDIS?" or cmd == "AT+RNDIS" then
        local st = usb_rndis.getStatus and usb_rndis.getStatus() or {}
        return rsp_fmt(
            "RNDIS",
            "enabled=%d,mode=%s,status=%s,ip=%s,flymode=%s",
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

local AT_EXACT = {
    ["AT"] = uart_at_ack,
    ["ATI"] = uart_ati,
    ["AT+CGMR"] = uart_ati,
    ["AT+GETVER"] = uart_ati,
    ["AT+GETCFG"] = uart_getcfg,
    ["AT+PIRSTAT"] = uart_pirstat_query,
    ["AT+PIRSTAT?"] = uart_pirstat_query,
    ["AT+PIRCLR"] = uart_pirclr,
    ["AT+RECORD"] = uart_record_query,
    ["AT+RECORD?"] = uart_record_query,
    ["AT+HOSTEVT"] = uart_hostevt_query,
    ["AT+HOSTEVT?"] = uart_hostevt_query,
    ["AT+HOSTEVTCLR"] = uart_hostevt_clr,
    ["AT+TIME"] = uart_time_query,
    ["AT+IMEI"] = uart_imei,
    ["AT+IMEI?"] = uart_imei,
    ["AT+IPCINFO"] = uart_ipcinfo_query,
    ["AT+IPCINFO?"] = uart_ipcinfo_query,
    ["AT+WLED?"] = uart_wled,
    ["AT+WLEDEN?"] = uart_wled,
    ["AT+HOSTIDLE"] = uart_hostidle,
    ["AT+HOSTIDLE?"] = uart_hostidle,
    ["AT+RNDIS"] = uart_rndis,
    ["AT+RNDIS?"] = uart_rndis,
    ["AT+USBRESET"] = uart_usbreset,
    ["AT+USBRESET?"] = uart_usbreset,
    ["AT+REBOOT"] = uart_reboot,
    ["AT+POWEROFF"] = uart_poweroff,
    ["AT+OTA"] = uart_ota,
    ["AT+OTACHECK"] = uart_ota,
}

local AT_PREFIX = {
    { prefix = "AT+RECORD=", handler = uart_record_notify },
    { prefix = "AT+SNAPSHOT=", handler = uart_snapshot_notify },
    { prefix = "AT+PIRMEDIA=", handler = uart_pir_media_notify },
    { prefix = "AT+PERSONCNT=", handler = uart_person_cnt_notify },
    { prefix = "AT+MQTTPUB=", handler = uart_mqttpub },
    { prefix = "AT+WLED=", handler = uart_wled },
    { prefix = "AT+WLEDEN=", handler = uart_wled },
    { prefix = "AT+SERVCREATE=", handler = uart_servcreate },
    { prefix = "AT+MQTTCFG=", handler = uart_mqttcfg },
    { prefix = "AT+SERVCLOSE=", handler = uart_servclose },
    { prefix = "AT+RIL=", handler = uart_ril },
    { prefix = "AT+SENDSTR=", handler = uart_sendstr },
    { prefix = "AT+SENDHEX=", handler = uart_sendhex },
    { prefix = "AT+LOWPOWER=", handler = uart_lowpower },
    { prefix = "AT+HOSTIDLE=", handler = uart_hostidle },
    { prefix = "AT+RNDIS=", handler = uart_rndis },
    { prefix = "AT+USBRECOVERY=", handler = uart_usbrecovery },
    { prefix = "AT+SETCFG=", handler = uart_setcfg },
}

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
    sys.publish(GB28181_ACK_EVENT, id)
    return true
end

local function parse_tfcard_line(line)
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
        return false
    end
    state.host_tf_card = snap
    sys.publish(TFCARD_ACK_EVENT, snap)
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
    sys.publish(RECORD_ACK_EVENT, snap)
    return true
end

local function normalize_host_line(line)
    if not line then
        return line
    end
    return (line:match("^%s*(.-)%s*$") or line)
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
        sys.publish(VENC_QUERY_DONE, { __error = "uart_error" })
        return true
    end
    if state.encode_audio_rows ~= nil then
        state.encode_audio_rows = nil
        sys.publish(AUDIO_QUERY_DONE, { __error = "uart_error" })
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
        sys.publish(VENC_QUERY_DONE, rows)
        return true
    end
    if state.encode_audio_rows ~= nil then
        local rows = state.encode_audio_rows
        state.encode_audio_rows = nil
        sys.publish(AUDIO_QUERY_DONE, rows)
        return true
    end
    return false
end

local function try_venc_line(line)
    line = normalize_host_line(line)
    if line == "+VENC:END" then
        local rows = state.encode_venc_rows or {}
        state.encode_venc_rows = nil
        sys.publish(VENC_QUERY_DONE, rows)
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
        sys.publish(VENC_SET_DONE, { ok = false })
        return true
    end
    local cam, stream, reboot = line:match("^%+VENCSET:OK,cam=(%d+),stream=(%d+),needReboot=(%d+)$")
    if not cam then
        return false
    end
    sys.publish(VENC_SET_DONE, {
        ok = true,
        camera = tonumber(cam) or 0,
        stream = tonumber(stream) or 0,
        needReboot = (tonumber(reboot) or 0) == 1,
    })
    return true
end

local function try_audioset_line(line)
    if line and line:match("^%+AUDIOSET:ERROR") then
        sys.publish(AUDIO_SET_DONE, { ok = false })
        return true
    end
    local cam, reboot = line:match("^%+AUDIOSET:OK,cam=(%d+),needReboot=(%d+)$")
    if not cam then
        return false
    end
    sys.publish(AUDIO_SET_DONE, {
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
        sys.publish(AUDIO_QUERY_DONE, rows)
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

local function try_ipcstatus_line(line)
    if not line then
        return false
    end
    local st = line:match("^%+IPCSTATUS:(%w+)$")
    if not st then
        return false
    end
    state.host_ipc_status = st
    sys.publish(IPCSTATUS_ACK_EVENT, st)
    return true
end

local function try_ipcpoweroff_line(line)
    if line == "+IPCPOWEROFF:OK" then
        sys.publish(IPCPOWEROFF_ACK_EVENT, true)
        return true
    end
    return false
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
    log.info(LOG_TAG, "atRdy", cmd or "")
    sys.publish(hostFirstAtEvent(), cmd or "")
end

local HOST_LINE_TRYERS = {
    try_encode_uart_error,
    try_sound_ack_line,
    try_timeset_ack_line,
    try_gb28181_line,
    try_tfcard_line,
    try_record_line,
    try_venc_line,
    try_vencset_line,
    try_audio_line,
    try_audioset_line,
    try_ipcstatus_line,
    try_ipcpoweroff_line,
    try_encode_ok_tail,
}

local function host_process_line(line)
    line = normalize_host_line(line)
    if not line or line == "" then
        return nil
    end
    for i = 1, #HOST_LINE_TRYERS do
        if HOST_LINE_TRYERS[i](line) then
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
-- 瀵瑰 API
-- ---------------------------------------------------------------------------

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
    log.info(LOG_TAG, "rx", traceLine(line))
    local rsp = host_process_line(line)
    if rsp then
        writeToT3x(rsp)
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
    hooks.uart_write = function(data)
        return writeToT3x(data)
    end
    hooks.send_string = function(cmd, appendCrLf)
        return sendToT3x(cmd, appendCrLf)
    end
    hooks.send_hex = function(hex)
        local bin = decode_hex(hex)
        return bin and writeToT3x(bin, "txHex")
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

local function run_host_query(opts)
    if state[opts.busy_key] then
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
            if opts.on_no_uart then
                result = opts.on_no_uart()
            end
            return
        end
        sendToT3x(opts.at_cmd, true)
        local got, val = sys.waitUntil(opts.ack_event, timeoutMs)
        result = opts.on_response(got, val, timeoutMs) or result
    end)

    state[opts.busy_key] = false
    if not ok then
        if opts.on_error then
            return opts.on_error(err)
        end
        return opts.default_result
    end
    return result
end

local function host_query(timeoutMs, opts)
    opts.timeout_ms = timeoutMs
    return run_host_query(opts)
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

function queryHostGb28181(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "gb28181_query_busy",
        cache_key = "host_gb28181_id",
        policy_tag = "host_identity",
        cfg = identity_cfg(),
        timeout_cfg_key = "query_timeout_ms",
        default_timeout = 3000,
        at_cmd = "AT+GB28181?",
        ack_event = GB28181_ACK_EVENT,
        on_response = function(got, id, tmo)
            if got and id ~= nil then
                state.host_gb28181_id = id
                return state.host_gb28181_id
            end
            return state.host_gb28181_id
        end,
        on_error = noop_nil,
    })
end

function getCachedHostTfCard()
    return state.host_tf_card
end

function getCachedHostIpcStatus()
    return state.host_ipc_status
end

function resetHostLinkState()
    state.host_at_ready = false
    state.first_host_at = nil
    state.host_ipc_status = nil
end

function queryHostIpcStatus(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "ipc_status_query_busy",
        busy_return = state.host_ipc_status or "idle",
        policy_tag = "host_ipc",
        cfg = ipc_cfg(),
        timeout_cfg_key = "status_query_timeout_ms",
        default_timeout = 2000,
        wait_boot = false,
        at_cmd = "AT+IPCSTATUS?",
        ack_event = IPCSTATUS_ACK_EVENT,
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
                state.host_ipc_status = st
                return st
            end
            state.host_ipc_status = "idle"
            return "idle"
        end,
        on_error = noop_idle,
    })
end

function hostIpcPowerOff(playSound, timeoutMs)
    if state.ipc_poweroff_busy then
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
            return
        end

        local cmd
        if playSound == false then
            cmd = "AT+IPCPOWEROFF=0"
        else
            cmd = "AT+IPCPOWEROFF=1"
        end
        sendToT3x(cmd, true)
        local got = sys.waitUntil(IPCPOWEROFF_ACK_EVENT, timeoutMs)
        if got then
            success = true
            state.host_ipc_status = "idle"
        end
    end)

    state.ipc_poweroff_busy = false
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
        local st = queryHostIpcStatus(tonumber(cfg.status_query_timeout_ms) or 2000)
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
    return tonumber(state.t3x_rec_active) or 0
end

function queryHostRecord(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "record_query_busy",
        cache_key = "host_record",
        policy_tag = "host_record",
        cfg = record_cfg(),
        default_timeout = 3000,
        at_cmd = "AT+RECORD?",
        ack_event = RECORD_ACK_EVENT,
        when_disabled = function(cfg)
            if cfg.enabled == false then
                return state.host_record
            end
        end,
        on_response = function(got, snap, tmo)
            if got and type(snap) == "table" then
                state.host_record = snap
                return state.host_record
            end
            return state.host_record
        end,
        on_error = noop_nil,
    })
end

function queryHostTfCard(timeoutMs)
    return host_query(timeoutMs, {
        busy_key = "tf_card_query_busy",
        cache_key = "host_tf_card",
        policy_tag = "host_tfcard",
        cfg = tf_card_cfg(),
        default_timeout = 3000,
        at_cmd = "AT+TFCARD?",
        ack_event = TFCARD_ACK_EVENT,
        on_response = function(got, snap, tmo)
            if got and type(snap) == "table" and snap.parsed then
                state.host_tf_card = snap
                return state.host_tf_card
            end
            return nil
        end,
        on_error = noop_nil,
    })
end

function setPirActionDevinfo()
    local ok, pc = pcall(require, "pir_ctrl")
    if ok and type(pc) == "table" and pc.setMediaConfig then
        pc.setMediaConfig({ action = "devinfo" })
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
    local ack_event = isAudio and AUDIO_QUERY_DONE or VENC_QUERY_DONE

    if isAudio then
        state.encode_audio_rows = {}
    else
        state.encode_venc_rows = {}
    end

    local result = host_query(opts.timeout_ms, {
        busy_key = "encode_query_busy",
        policy_tag = "host_encode",
        cfg = cfg,
        timeout_cfg_key = "query_timeout_ms",
        default_timeout = 8000,
        at_cmd = at_cmd,
        ack_event = ack_event,
        on_response = function(got, val, tmo)
            if got then
                local body, err = finish_encode_query(val, isAudio)
                if body then
                    return body
                end
                return nil
            end
            return nil
        end,
        on_error = noop_nil,
    })

    if result then
        return result, nil
    end
    return nil, "timeout"
end

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
            sendToT3x(cmd, true)
            local got, m, rsp = await_encode_set(AUDIO_SET_DONE, timeoutMs)
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
        sendToT3x(cmd, true)
        local got, m, rsp = await_encode_set(VENC_SET_DONE, timeoutMs)
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
    log.info(LOG_TAG, "on")
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
    return true
end

function isUsbInserted()
    return is_usb_inserted()
end

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
    return true
end

function notify_host(sid, evt)
    local cfg = _G.HOST_WAKE_CFG or {}
    sid = sid or cfg.default_sid or 1
    evt = evt or _M.EVT.SERVER_DATA

    local okPol, policy = pcall(require, "t3x_policy")
    if okPol and type(policy) == "table" and policy.mayPowerT3x
        and not policy.mayPowerT3x("notify_host") then
        return false
    end

    set_pending_wake(sid, evt)
    if not t3xModule then
        t3xModule = require "t3x_ctrl"
    end
    if t3xModule.getState and not t3xModule.getState().powered_on and t3xModule.powerOn then
        t3xModule.powerOn()
    end
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
