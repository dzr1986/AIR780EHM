--- 主机串口：AT/HEX/STR 协议 + uart_bridge + GPIO 唤醒
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
}

local started = false
local t3xModule = nil

-- ---------------------------------------------------------------------------
-- 应答与工具
-- ---------------------------------------------------------------------------

local function ok_tail()
    return CRLF .. "OK" .. CRLF
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

local function get_config_snapshot()
    local meta = _G.APP_META or {}
    local rt = _G.APP_RUNTIME or {}
    local tcp_extra = ""
    local ok, net_tcp = pcall(require, "net_tcp")
    if ok and net_tcp and net_tcp.appendGetCfgFields then
        tcp_extra = net_tcp.appendGetCfgFields()
    end
    return {
        version = (_G.PROJECT or "780EHM") .. "_" .. (_G.VERSION or "1.0.0"),
        online = rt.online_status or 0,
        power = rt.power_status or 0,
        lowpower = rt.low_power_mode or 0,
        battery = rt.battery_percent or "--",
        vbat = rt.battery_mv or "--",
        interval = rt.low_power_interval_sec or 0,
        devicemodel = meta.device_model or "",
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
    log.info(LOG_TAG, "pending WAKEVT", state.pending_sid, state.pending_evt)
end

local function clear_pending_wake()
    state.pending_valid = false
    state.pending_evt = -1
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

local function uart_wakevt_query(_cmd)
    if not state.pending_valid then
        return CRLF .. "+WAKEVT:" .. CRLF .. ok_tail()
    end
    local sid, evt = state.pending_sid, state.pending_evt
    clear_pending_wake()
    return string.format(CRLF .. "+WAKEVT:%d,%d" .. CRLF, sid, evt) .. ok_tail()
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
        return rsp_line("MQTTCFG", false)
    end
    log.info(LOG_TAG, "MQTTCFG", cfg.host, cfg.port, cfg.ssl and 1 or 0)
    if hooks.on_mqtt_cfg then
        hooks.on_mqtt_cfg(cfg)
    end
    return rsp_line("MQTTCFG", true) .. ok_tail()
end

local function uart_servcreate(cmd)
    local ch = parse_servcreate_args(cmd:match("^AT%+SERVCREATE=(.+)$"))
    if not ch then
        return RSP_ERROR
    end
    state.channel = ch
    log.info(LOG_TAG, "SERVCREATE", ch.sid, ch.server_ip, ch.server_port)
    if hooks.on_servcreate then
        hooks.on_servcreate(ch)
    else
        local ok, net_tcp = pcall(require, "net_tcp")
        if ok and net_tcp and net_tcp.applyChannel then
            net_tcp.applyChannel(ch)
        end
    end
    return string.format(CRLF .. "+SERVCREATE:%d,OK" .. CRLF, ch.sid) .. ok_tail()
end

local function uart_servclose(cmd)
    local sid = tonumber(cmd:match("^AT%+SERVCLOSE=(%d+)$"))
    if not sid then
        return RSP_ERROR
    end
    log.info(LOG_TAG, "SERVCLOSE", sid)
    if hooks.on_servclose then
        hooks.on_servclose(sid)
    else
        local ok, net_tcp = pcall(require, "net_tcp")
        if ok and net_tcp and net_tcp.closeChannel then
            net_tcp.closeChannel(sid)
        end
    end
    state.channel = nil
    return string.format(CRLF .. "+SERVCLOSE:%d" .. CRLF, sid) .. ok_tail()
end

local function uart_getcfg(_cmd)
    local s = get_config_snapshot()
    return string.format(
        CRLF .. "+GETCFG:version=%s,online=%d,power=%d,lowpower=%d,battery=%s,vbat=%s,interval=%d,devicemodel=%s%s" .. CRLF,
        s.version, s.online, s.power, s.lowpower, s.battery, s.vbat, s.interval, s.devicemodel,
        s.tcp_extra or ""
    ) .. ok_tail()
end

local function uart_pirstat_query(_cmd)
    local body = ""
    local ok, pir_runtime = pcall(require, "pir_runtime")
    if ok and pir_runtime and pir_runtime.buildAtBody then
        body = pir_runtime.buildAtBody()
    end
    if state.pending_valid then
        body = body .. string.format(",pending_wake=1,pending_sid=%d,pending_evt=%d",
            state.pending_sid, state.pending_evt)
    else
        body = body .. ",pending_wake=0"
    end
    return CRLF .. "+PIRSTAT:" .. body .. CRLF .. ok_tail()
end

local function uart_pirclr(_cmd)
    local ok, pir_runtime = pcall(require, "pir_runtime")
    if ok and pir_runtime and pir_runtime.resetCounters then
        pir_runtime.resetCounters()
        return rsp_line("PIRCLR", true) .. ok_tail()
    end
    return rsp_line("PIRCLR", false)
end

local function uart_ati(_cmd)
    return string.format(CRLF .. "+CGMR:%s" .. CRLF, get_config_snapshot().version) .. ok_tail()
end

local function uart_ril(cmd)
    local n = tonumber(cmd:match("^AT%+RIL=(%d+)$"))
    if n == nil then
        return RSP_ERROR
    end
    state.passthrough = (n == 1)
    log.info(LOG_TAG, "RIL", n)
    return string.format(CRLF .. "+RIL:%d" .. CRLF, n) .. ok_tail()
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
    local rt = _G.APP_RUNTIME or {}
    if cmd == "AT+LOWPOWER=ENTER" then
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
        rt.low_power_interval_sec = tonumber(val)
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
-- 表驱动分发
-- ---------------------------------------------------------------------------

local function uart_cmd_entry(keys, prefix, handler)
    if prefix then
        return { match = "prefix", prefix = prefix, handler = handler }
    end
    keys = type(keys) == "table" and keys or { keys }
    return { match = "exact", keys = keys, handler = handler }
end

local AT_CMD_TABLE = {
    uart_cmd_entry("AT", nil, uart_at_ack),
    uart_cmd_entry({ "ATI", "AT+CGMR", "AT+GETVER" }, nil, uart_ati),
    uart_cmd_entry("AT+GETCFG", nil, uart_getcfg),
    uart_cmd_entry("AT+PIRSTAT", nil, uart_pirstat_query),
    uart_cmd_entry("AT+PIRCLR", nil, uart_pirclr),
    uart_cmd_entry("AT+WAKEVT", nil, uart_wakevt_query),
    uart_cmd_entry(nil, "AT+SERVCREATE=", uart_servcreate),
    uart_cmd_entry(nil, "AT+MQTTCFG=", uart_mqttcfg),
    uart_cmd_entry(nil, "AT+SERVCLOSE=", uart_servclose),
    uart_cmd_entry(nil, "AT+RIL=", uart_ril),
    uart_cmd_entry(nil, "AT+SENDSTR=", uart_sendstr),
    uart_cmd_entry(nil, "AT+SENDHEX=", uart_sendhex),
    uart_cmd_entry(nil, "AT+LOWPOWER=", uart_lowpower),
    uart_cmd_entry("AT+REBOOT", nil, uart_reboot),
    uart_cmd_entry("AT+POWEROFF", nil, uart_poweroff),
    uart_cmd_entry({ "AT+OTA", "AT+OTACHECK" }, nil, uart_ota),
    uart_cmd_entry(nil, "AT+SETCFG=", uart_setcfg),
}

local LINE_HANDLERS = {
    HEX = uart_hex_line,
    STR = uart_str_line,
}

local function uart_dispatch_at(cmd)
    for i = 1, #AT_CMD_TABLE do
        local e = AT_CMD_TABLE[i]
        local matched = false
        if e.match == "exact" then
            for j = 1, #e.keys do
                if cmd == e.keys[j] then
                    matched = true
                    break
                end
            end
        else
            matched = (cmd:sub(1, #e.prefix) == e.prefix)
        end
        if matched then
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

local function host_process_line(line)
    if not line or line == "" then
        return nil
    end
    if line:sub(1, 2) == "AT" then
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
    log.info(LOG_TAG, "AT", cmd)
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

function start(opts)
    if started then
        return true
    end
    opts = opts or {}
    t3xModule = opts.t3x or require "t3x_ctrl"
    bind_start_hooks(opts)
    uart_bridge.setOnLine(on_uart_line)
    started = true
    log.info(LOG_TAG, "已启动")
    return true
end

function stop()
    if not started then
        return false
    end
    uart_bridge.setOnLine(nil)
    started = false
    log.info(LOG_TAG, "已停止")
    return true
end

function notify_host(sid, evt)
    local cfg = _G.HOST_WAKE_CFG or {}
    sid = sid or cfg.default_sid or 1
    evt = evt or _M.EVT.SERVER_DATA
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
    log.warn(LOG_TAG, "脉冲不可用")
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
