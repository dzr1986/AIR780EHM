--- t3x AT+SERVCREATE / SERVCLOSE 对应：TCP 长连接、登录、心跳、wake_hex 唤醒 t3x
-- 与 MQTT（AT+MQTTCFG / net_mqtt.lua）独立
-- @module net_tcp

require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "net_tcp"
local EVT_CONNECT_FAIL = 1
local EVT_REGISTER_FAIL = 2
local EVT_REGISTER_TIMEOUT = 3
local EVT_SERVER_DATA = 0

local state = {
    channel = nil,
    sock = nil,
    task_started = false,
    running = false,
    connected = false,
    logged_in = false,
    stop_req = false,
    last_error = "",
}

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

local function notify_t3x(evt)
    local ch = state.channel
    if not ch then
        return
    end
    local host_uart = package.loaded.host_uart
    if host_uart and host_uart.notify_host then
        host_uart.notify_host(ch.sid, evt)
    end
end

local function close_sock()
    if state.sock then
        pcall(function()
            if state.sock.close then
                state.sock:close()
            end
        end)
        state.sock = nil
    end
    state.connected = false
    state.logged_in = false
end

local function wait_for_ip(timeout_ms)
    if socket and socket.adapter and socket.dft and socket.adapter(socket.dft()) then
        return true
    end
    return sys.waitUntil("IP_READY", timeout_ms or 120000)
end

local function tcp_connect(ch)
    if not socket or not socket.tcp then
        state.last_error = "socket.tcp unavailable"
        return false
    end
    local sock = socket.tcp()
    if not sock then
        state.last_error = "tcp create failed"
        return false
    end
    local ok, err = sock:connect(ch.server_ip, ch.server_port)
    if not ok then
        pcall(function() sock:close() end)
        state.last_error = tostring(err or "connect failed")
        return false
    end
    state.sock = sock
    state.connected = true
    return true
end

local function tcp_send(bin)
    if not state.sock or not bin or #bin == 0 then
        return false
    end
    if state.sock.send then
        return state.sock:send(bin)
    end
    if state.sock.tx then
        return state.sock:tx(bin)
    end
    return false
end

local function tcp_recv(max_len, timeout_ms)
    if not state.sock then
        return nil
    end
    max_len = max_len or 1024
    timeout_ms = timeout_ms or 3000
    if state.sock.recv then
        return state.sock:recv(max_len, timeout_ms)
    end
    if state.sock.rx then
        local ok, data = state.sock:rx(max_len, timeout_ms)
        if ok and data then
            return data
        end
        return nil
    end
    if state.sock.read then
        return state.sock:read(max_len)
    end
    return nil
end

local function payload_has_pattern(payload, pattern)
    if not payload or not pattern or #pattern == 0 then
        return false
    end
    if type(payload) == "string" and payload:find(pattern, 1, true) then
        return true
    end
    return false
end

local function try_login(ch)
    local login = decode_hex(ch.login_hex)
    local expect = decode_hex(ch.login_rsp_hex)
    if not login then
        state.last_error = "login_hex invalid"
        return false
    end
    if not tcp_send(login) then
        state.last_error = "login send failed"
        return false
    end
    local deadline = os.time() + 15
    while os.time() < deadline and state.running do
        local data = tcp_recv(512, 2000)
        if data and #data > 0 then
            if not expect or #expect == 0 or payload_has_pattern(data, expect) then
                state.logged_in = true
                log.info(LOG_TAG, "login ok")
                return true
            end
        end
        sys.wait(200)
    end
    state.last_error = "login timeout"
    return false
end

local function channel_loop(ch)
    local hb_bin = decode_hex(ch.heartbeat_hex)
    local wake_pat = decode_hex(ch.wake_hex)
    local hb_sec = tonumber(ch.heartbeat_sec) or 60
    if hb_sec < 5 then
        hb_sec = 5
    end
    local next_hb = os.time() + hb_sec

    while state.running and not state.stop_req do
        if os.time() >= next_hb and hb_bin and #hb_bin > 0 then
            tcp_send(hb_bin)
            next_hb = os.time() + hb_sec
        end
        local data = tcp_recv(1024, 1500)
        if data and #data > 0 then
            if wake_pat and #wake_pat > 0 and payload_has_pattern(data, wake_pat) then
                log.info(LOG_TAG, "wake_hex hit, notify t3x evt=0")
                notify_t3x(EVT_SERVER_DATA)
            end
        end
        sys.wait(100)
    end
end

local function tcp_task()
    state.running = true
    state.stop_req = false
    state.last_error = ""

    while not state.stop_req do
        local ch = state.channel
        if not ch or not ch.server_ip or ch.server_ip == "" then
            log.warn(LOG_TAG, "no channel config, idle")
            sys.wait(2000)
        else
            close_sock()
            if not wait_for_ip(120000) then
                log.warn(LOG_TAG, "no IP, retry")
                notify_t3x(EVT_CONNECT_FAIL)
                sys.wait(5000)
            elseif not tcp_connect(ch) then
                log.warn(LOG_TAG, "connect fail", state.last_error)
                notify_t3x(EVT_CONNECT_FAIL)
                sys.wait(5000)
            elseif not try_login(ch) then
                log.warn(LOG_TAG, "login fail", state.last_error)
                if state.last_error:find("timeout") then
                    notify_t3x(EVT_REGISTER_TIMEOUT)
                else
                    notify_t3x(EVT_REGISTER_FAIL)
                end
                close_sock()
                sys.wait(5000)
            else
                channel_loop(ch)
                close_sock()
            end
        end
        if not state.stop_req and state.channel then
            sys.wait(1000)
        end
    end

    close_sock()
    state.running = false
    log.info(LOG_TAG, "task exit")
end

local function ensure_task()
    if state.task_started then
        return
    end
    state.task_started = true
    sys.taskInit(tcp_task)
end

--- t3x AT+SERVCREATE：保存参数并（重）启 TCP 任务
function applyChannel(ch)
    if not ch or not ch.server_ip then
        return false
    end
    state.channel = ch
    _G.NET_TCP_CHANNEL = ch
    state.stop_req = false
    ensure_task()
    close_sock()
    log.info(LOG_TAG, "applyChannel", ch.sid, ch.server_ip, ch.server_port)
    return true
end

--- t3x AT+SERVCLOSE：停止 TCP 任务
function closeChannel(sid)
    log.info(LOG_TAG, "closeChannel", sid or "?")
    state.stop_req = true
    close_sock()
    if state.channel and sid and state.channel.sid == sid then
        state.channel = nil
        _G.NET_TCP_CHANNEL = nil
    end
    return true
end

function getState()
    local ch = state.channel
    return {
        configured = ch ~= nil,
        sid = ch and ch.sid or 0,
        server_ip = ch and ch.server_ip or "",
        server_port = ch and ch.server_port or 0,
        running = state.running,
        connected = state.connected,
        logged_in = state.logged_in,
        last_error = state.last_error,
    }
end

--- 供 host_uart GETCFG 追加字段
function appendGetCfgFields()
    local s = getState()
    return string.format(",tcp_sid=%d,tcp_on=%d,tcp_login=%d",
        s.sid or 0, (s.connected and 1 or 0), (s.logged_in and 1 or 0))
end

return _M
