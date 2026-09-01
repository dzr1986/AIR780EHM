-- ================================================================
-- Filename : host_uart.lua
-- Module   : T3x AT 核心：互斥、分发、RX 行解析、start/notify；handler 见 hu_cmd/ipc
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
--
-- 数据流：uart_bridge → processLine → [URC tryHandlers | AT dispatch | STR/HEX]
-- 子模块绑定顺序：cmd（AT 下行）→ rx（URC 上行）→ ipc（query/set）
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local cfgm = require "config_manager"
local uart_bridge = require "uart_bridge"
local huRsp = require "hu_rsp"
local huUartTxn = require "hu_uart_txn"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "host_uart"
local CRLF = huRsp.CRLF
local RSP_ERROR = huRsp.RSP_ERROR

local TIMEOUT = {
    firstAtCloudWait = 300,
    firstAtCloudQuery = 2500,
}

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

local E = cfgm.get("APP_EVENTS")
local started = false
local t3xModule = nil
local usbChargeCache = nil
local hostNowMs = utils.nowMs

local txn = huUartTxn.bind(state, hostNowMs)

----------------------------------------------------------------
-- 小工具
----------------------------------------------------------------

local function modCall(name, fn, ...)
    local m = loader.load(name)
    if m then
        return m[fn](...)
    end
end

local function noopIdle()
    return "idle"
end

local function noopFalse()
    return false
end

local function t3xSecOff()
    return not loader.enabled("t3x_app") or not loader.enabled("uart_bridge")
end

local function encodeHex(data)
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

local function decodeHex(hex)
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

local function hostUsbCfg()
    return cfgm.get("HOST_USB_CFG")
end

local function getUsbChargeMod()
    if usbChargeCache == nil then
        usbChargeCache = loader.load("usb_charge") or false
    end
    if usbChargeCache == false then
        return nil
    end
    return usbChargeCache
end

local function usbInserted()
    return modCall("runtime_power", "isUsbInserted") == true
end

local function usbBlockHost()
    local charge = getUsbChargeMod()
    if charge then
        return charge.blocksHostIdle()
    end
    return usbInserted()
end

local function configSnap()
    local meta = cfgm.get("APP_META")
    return {
        version = (_G.PROJECT or "780EHM") .. "_" .. (_G.VERSION or "2034.001.000"),
        online = modCall("runtime_power", "isOnline") and 1 or 0,
        power = modCall("runtime_power", "getPowerStatus") or 0,
        lowpower = modCall("runtime_power", "isLowPowerMode") and 1 or 0,
        battery = modCall("runtime_power", "getBatteryPercent") or "--",
        vbat = modCall("runtime_power", "getBatteryMv") or "--",
        interval = modCall("runtime_power", "getLowPowerInterval") or 0,
        devicemodel = meta.device_model or "",
        wled = modCall("runtime_power", "getWledOn") or 0,
        workmode = modCall("runtime_power", "getWorkMode") or "person_detect",
        tcp_extra = modCall("lp_wakeup", "appCfgFields") or "",
    }
end

local function parseSvcArgs(args)
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

local function setPendingWake(sid, evt)
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

local function echoRxHex(data)
    if not state.hex_report or not hooks.uartWrite or not data then
        return
    end
    hooks.uartWrite(CRLF .. "+RXHEX:" .. encodeHex(data) .. CRLF)
end

----------------------------------------------------------------
-- ctx：子模块共享上下文（rx 绑定前用 late 延迟挂载）
----------------------------------------------------------------

local late = {}

local function lateField(name)
    return function(...)
        return late[name](...)
    end
end

local ctx = {
    M = _M,
    state = state,
    hooks = hooks,
    SYS_EVT = SYS_EVT,
    E = E,
    rspOnly = huRsp.rspOnly,
    rspBody = huRsp.rspBody,
    rspFmt = huRsp.rspFmt,
    rspLine = huRsp.rspLine,
    rspLineOk = huRsp.rspLineOk,
    okTail = huRsp.okTail,
    modCall = modCall,
    loader = loader,
    utils = utils,
    uart_bridge = uart_bridge,
    CRLF = CRLF,
    RSP_ERROR = RSP_ERROR,
    LOG_TAG = LOG_TAG,
    setPndWake = setPendingWake,
    getHostEvtPending = getHostEvtPending,
    noopFalse = noopFalse,
    noopIdle = noopIdle,
    usbInserted = usbInserted,
    usbBlockHost = usbBlockHost,
    configSnap = configSnap,
    hostUsbCfg = hostUsbCfg,
    encodeHex = encodeHex,
    decodeHex = decodeHex,
    hostNowMs = hostNowMs,
    t3xSecOff = t3xSecOff,
    waitHostIdle = txn.waitHostIdle,
    uartAcquire = txn.uartAcquire,
    uartRelease = txn.uartRelease,
    hostBusy = txn.hostBusy,
    noteHostPush = txn.noteHostPush,
    parseSvcArgs = parseSvcArgs,
    parseIpcStat = lateField("parseIpcStat"),
    parseTfCard = lateField("parseTfCard"),
}

local function mountLate(rxFields)
    for k, v in pairs(rxFields) do
        late[k] = v
        ctx[k] = v
    end
end

----------------------------------------------------------------
-- 子模块绑定：cmd → at 表 → rx → ipc
----------------------------------------------------------------

local function bindPipeline()
    local cmd = require("hu_cmd").bind(ctx)
    ctx.wledGet = cmd.wledGet

    local AT_EXACT, AT_PREFIX = require("hu_at").compile(cmd.at)
    local LINE_HANDLERS = {
        HEX = cmd.hexLine,
        STR = cmd.strLine,
    }

    local rx = require("hu_rx").bind(ctx)
    mountLate({
        parseTfCard = rx.parseTfCard,
        parseIpcStat = rx.parseIpcStat,
        normIpcCloud = rx.normIpcCloud,
        commitIpcStat = rx.commitIpcStat,
        patchCloud = rx.patchCloud,
    })

    require("hu_ipc").bind(ctx)

    return AT_EXACT, AT_PREFIX, LINE_HANDLERS, rx
end

local AT_EXACT, AT_PREFIX, LINE_HANDLERS, rx = bindPipeline()
local normLine = rx.normLine
local RX_LINE_TRY_HANDLERS = rx.tryHandlers

----------------------------------------------------------------
-- AT 分发
----------------------------------------------------------------

local function runAtDispatch(atCmd)
    local exact = AT_EXACT[atCmd]
    if exact then
        local rsp = exact(atCmd)
        if rsp ~= nil then
            return rsp
        end
    end
    for i = 1, #AT_PREFIX do
        local entry = AT_PREFIX[i]
        if atCmd:sub(1, #entry.prefix) == entry.prefix then
            local rsp = entry.handler(atCmd)
            if rsp ~= nil then
                return rsp
            end
        end
    end
    if state.passthrough and hooks.modemAt then
        return hooks.modemAt(atCmd)
    end
    return RSP_ERROR
end

----------------------------------------------------------------
-- RX 行处理
----------------------------------------------------------------

local function onFirstHostAt(atLine)
    if state.host_at_ready then
        return
    end
    state.host_at_ready = true
    state.first_host_at = atLine
    state.host_ready_seen = true
    if ctx.noteUartLinkOk then
        ctx.noteUartLinkOk()
    end
    state.uart_recovery_attempts = 0
    state.uart_recovery_last_sec = 0
    late.patchCloud({ cat1Link = 1 })
    sys.taskInit(function()
        sys.wait(TIMEOUT.firstAtCloudWait)
        if not _M.isT31HostQry() then
            return
        end
        _M.qryIpcCloudStat(TIMEOUT.firstAtCloudQuery)
        _M.mergeTfCloud()
    end)
    sys.publish(E.HOST_UART_FIRST_AT, atLine or "")
end

local function plainLine(line)
    if hooks.onPlainLine then
        hooks.onPlainLine(line)
        return
    end
    if E.UART_RX_STRING then
        sys.publish(E.UART_RX_STRING, line)
    end
end

local function processLine(line)
    line = normLine(line)
    if not line or line == "" then
        return nil
    end
    for i = 1, #RX_LINE_TRY_HANDLERS do
        if RX_LINE_TRY_HANDLERS[i](line) then
            return nil
        end
    end
    if line:sub(1, 2) == "AT" then
        txn.noteHostPush()
        onFirstHostAt(line)
        return uartAtCmd(line)
    end
    if line:sub(4, 4) == ":" then
        local handler = LINE_HANDLERS[line:sub(1, 3):upper()]
        if handler then
            return handler(line)
        end
    end
    plainLine(line)
    return nil
end

function uartAtCmd(cmd)
    if not cmd or cmd == "" then
        return RSP_ERROR
    end
    state.last_command = cmd
    -- 仅在查询形式（含 ?）未注册时才剥除尾部 ?；
    -- 否则 AT+USBRESET? 会被剥成 AT+USBRESET 误执行真正的 USB 复位
    if not AT_EXACT[cmd] then
        cmd = cmd:gsub("%?$", "")
    end
    if hooks.onAtExt then
        local extRsp = hooks.onAtExt(cmd)
        if extRsp then
            return extRsp
        end
    end
    return runAtDispatch(cmd)
end

function onRxRaw(data)
    echoRxHex(data)
end

local function defaultModemAt(cmd)
    if mobile and mobile.at then
        return mobile.at(cmd .. CRLF, 5000)
    end
    return nil
end

local function onUartLine(line)
    local rsp = processLine(line)
    if rsp then
        uart_bridge.write(rsp)
    end
end

local function bindStartHooks(opts)
    hooks.onServCreate = opts.onServCreate
    hooks.onServClose = opts.onServClose
    hooks.onMqttCfg = opts.onMqttCfg
    hooks.onAtExt = opts.onAtExt
    hooks.onEnterLowPower = opts.onEnterLowPower
    hooks.onExitLowPower = opts.onExitLowPower
    hooks.onReboot = opts.onReboot
    hooks.onPowerOff = opts.onPowerOff
    hooks.onOta = opts.onOta
    hooks.onPlainLine = opts.onPlainLine
    hooks.uartWrite = uart_bridge.write
    hooks.sendString = uart_bridge.sendString
    hooks.sendHex = function(hex)
        local bin = decodeHex(hex)
        return bin and uart_bridge.write(bin)
    end
    hooks.modemAt = opts.modemAt or defaultModemAt
end

function isHostAtReady()
    return state.host_at_ready == true
end

function start(opts)
    opts = opts or {}
    t3xModule = opts.t3x or require "t3x_ctrl"
    state.host_at_ready = false
    state.first_host_at = nil
    bindStartHooks(opts)
    uart_bridge.setOnLine(onUartLine)
    started = true
    return true
end

function stop()
    uart_bridge.setOnLine(nil)
    started = false
    return true
end

local function writeT3xNotify(tpl, val)
    local writeFn = hooks.uartWrite
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

function pushUsbIdle(inserted)
    local cfg = hostUsbCfg()
    if cfg.notify_t3x_usb_state == false then
        return false
    end
    return writeT3xNotify(cfg.t3x_usb_ursp or "+CAT1:USB,%d", inserted)
end

function pushNetLedSt(online)
    local cfg = cfgm.get("LED_CFG")
    if cfg.notify_t3x_net_led ~= true then
        return false
    end
    return writeT3xNotify(cfg.t3x_net_ursp or "+CAT1:MQTT,%d", online)
end

function ntfHost(sid, evt)
    local cfg = cfgm.get("HOST_WAKE_CFG")
    sid = sid or cfg.default_sid or 1
    evt = evt or _M.EVT.SERVER_DATA
    if modCall("t3x_policy", "mayPowerT3x", "ntfHost") == false then
        return false
    end
    setPendingWake(sid, evt)
    if not t3xModule then
        t3xModule = require "t3x_ctrl"
    end
    local t3xSt = t3xModule.getState()
    if t3xSt and (not t3xSt.powered_on or t3xSt.in_boot_mode) then
        t3xModule.ensNormalPwrOn("ntfHost")
    end
    modCall("battery_guard", "markT3xWoken")
    return t3xModule.pulseMcuInt()
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

ctx.pushUsbIdle = pushUsbIdle
return _M
