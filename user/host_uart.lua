-- ================================================================
-- Filename : host_uart.lua
-- Module   : CAT1 ↔ T31x 协处理器 UART/AT 协议核心（L0）
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- ── 分层（bind(C) 注入共享上下文，自底向上组合）──────────────────
--   L0  host_uart        : 事务锁 / AT 响应格式化 / RX 行分发 / start·stop·ntfHost
--   L1  hif_cmd          : AT 命令分发（cmd 编排 + 内联 handler）
--       hif_ipc          : query/set 公共路径 + defineQuery/defineSet 工厂
--       hif_rx           : URC/RX 行解析（dsl + media 两条匹配链）
--   L2  hif_cmd_*        : usb / link / pir / t31x / wled 各 AT handler
--       hif_ipc_*        : rec / hostq / cloud / power / tffmt / encode
--       hif_rx_*         : dsl（云态/TF/录制/IPC）/ media（编码行）
--   hif_at               : 声明式 AT 命令表（精确/前缀）→ 编译为查表
--
-- ── 契约（所有 hif_* 模块统一）──────────────────────────────────
--   · bind(C[, H]) 接收共享上下文 C；叶子模块返回 {fn,...} 表。
--   · host_uart 把对外 API 挂在 C.M（即本模块 _M）；跨编排器复用的
--     helper 挂在 C（如 C.hostQuery / C.idCfg / C.parseIpcStat）。
--   · hif_ipc 额外构建 H（hostQuery/hostSet/defineQuery/defineSet/
--     ensT31xHost/cfg 读取），仅传给 hif_ipc_* 叶子。
--
-- ── 数据流 ─────────────────────────────────────────────────────
--   onUartLine → processLine
--     · 行以 "AT" 开头 → runAtDispatch → AT_EXACT / AT_PREFIX（hif_at.compile）
--     · 行以 "HEX:"/"STR:" → LINE_HANDLERS
--     · 其余 URC        → RX_LINE_TRY_HANDLERS（hif_rx，顺序敏感）
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local cfgm = require "config_manager"
local uart_bridge = require "uart_bridge"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "host_uart"
local CRLF = "\r\n"
local RSP_ERROR = CRLF .. "ERROR" .. CRLF
local HOST_PUSH_QUIET_MS = 300

-- host_uart 族共享超时（refactor_plan P2a）：同一语义只在此定义一次，子模块经 ctx.TMO_SHARED 读取。
-- 各子模块本地 TIMEOUT/TMO 只保留模块特有值（如 tffmt.formatMs / hostq.recOff）。
-- 已知同义不同值（本阶段不改数值，登记待定）：quiet 静默期 hif_ipc.TMO.quiet=1500 vs
-- hif_ipc_power.hostIdleCapMs=2000 / hif_ipc_tffmt.hostIdleMs=2000，见 HOST_UART_AT_DISPATCH.md「超时常量真源」。
local TMO_SHARED = {
    acquireCapMs = 8000,      -- 拿串口事务锁最多等待（power / tffmt）
    statusQueryMs = 2000,     -- AT+IPCSTATUS? 单次超时（rec / power）
    cloudStatQueryMs = _G.HOST_PROTO_TMO.ipcstat_query_ms,  -- AT+IPCSTAT? 单次超时（cloud / 首条 AT 后刷新）；跨族单源 config host.lua
    qryDefaultMs = _G.HOST_PROTO_TMO.qry_default_ms,      -- 通用 AT 查询默认超时（hif_ipc.hostQuery / cmd_wled AT+WLED?）
    t31xWaitMs = _G.HOST_PROTO_TMO.t31x_power_wait_ms,   -- ensT31xHost 上电后等待默认值（配置 t31x_power_wait_ms 缺省时）
}

local TIMEOUT = {
    firstAtCloudWait = 300,
    txnWaitSlice = 80,
    txnWaitMin = 20,
    hostIdleSliceMin = 20,
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
    encode_venc_rows = nil,
    encode_audio_rows = nil,
    encode_query_busy = false,
    encode_set_busy = false,
    t31x_rec_active = 0,
    t31x_last_reason = "idle",
    ipc_uart_miss_streak = 0,
    uart_session = nil,        -- 破坏性串口会话：nil | "tfformat" | "poweroff" | "usb_recovery"（P3）
    uart_recovery_attempts = 0,
    uart_recovery_last_sec = 0,
    host_push_quiet_until = 0,
    uart_txn_busy = false,
}

local E = cfgm.get("APP_EVENTS")
local uartTxnOwner = nil
local uartTxnDepth = 0
local started = false
local t31xModule = nil
local t31xFallback = nil
local usbChargeCache = nil

local hostNowMs = utils.nowMs

----------------------------------------------------------------
-- 小工具
----------------------------------------------------------------

local function modCall(name, fn, ...)
    local m = loader.load(name)
    if m then
        return m[fn](...)
    end
end

local function rp(fn)
    return modCall("runtime_power", fn)
end

-- 业务 provider（refactor A 条 / _layer_check R4）：AT 协议层不再 modCall 业务模块（pir_ctrl / net_mqtt /
-- battery_guard / t31x_policy / lp_wakeup / host_event / time_sync / sound_prompt），改由 app.start 经
-- host_uart.start{ biz = {...} } 注入显式函数表；未注入（模块被裁剪）时返回 nil，与 modCall 对未加载模块的语义一致。
-- 键名清单真源：user/app.lua buildBizProviders；_ref_name_check 规则 F 校验 bizCall("x") 的 x ∈ 该表。
----------------------------------------------------------------
-- state 语义键 setter（架构 C 条）：host_ipc_status / host_at_ready / host_tf_card / host_ipc_cloud_stat
-- 只能经这里写（_protocol_regression_check SINGLE_WRITERS 守护）；缓存/计数键仍可直写。
-- setHostIpcStatus(st, syncCloud=true) 同步 cloud.ipcReady（cmd_t31x / rx_dsl 两条 IPCSTATUS 路径原各自 patchCloud）。
----------------------------------------------------------------
local ctx -- 前向声明：setter 需运行期取 ctx.ipcReadyFrom / ctx.patchCloud（子模块 bind 后回填）

local function setHostIpcStatus(st, syncCloud)
    state.host_ipc_status = st
    if syncCloud and ctx and ctx.patchCloud and ctx.ipcReadyFrom then
        ctx.patchCloud({ ipcReady = ctx.ipcReadyFrom(st) })
    end
    return st
end

local function setHostAtReady(v)
    state.host_at_ready = v == true
    return state.host_at_ready
end

local function setHostTfCard(snap)
    state.host_tf_card = snap
    return snap
end

local function setHostCloudStat(snap)
    state.host_ipc_cloud_stat = snap
    return snap
end

local function bizCall(name, ...)
    local biz = hooks.biz
    local f = biz and biz[name]
    if f then
        return f(...)
    end
end

local function noopIdle()
    return "idle"
end

local function t31xUartOff()
    return not loader.enabled("t31x_app") or not loader.enabled("uart_bridge")
end

local function noteHostPush()
    state.host_push_quiet_until = hostNowMs() + HOST_PUSH_QUIET_MS
end

-- IPCPOWEROFF 收包日志（rx_dsl URC 路径 / ipc_power 阶段路径共用，P9 单源）
local function logPowerOffRx(tag, line)
    if log and log.info then
        log.info(LOG_TAG, "ipcpoweroff_rx", tag, line or "error")
    end
end

local function hostBusy()
    local untilMs = tonumber(state.host_push_quiet_until) or 0
    return untilMs > 0 and hostNowMs() < untilMs
end

local function waitHostIdle(timeoutMs)
    timeoutMs = math.max(0, tonumber(timeoutMs) or 2000)
    local deadline = hostNowMs() + timeoutMs
    while hostBusy() do
        local now = hostNowMs()
        local remain = deadline - now
        if remain <= 0 then
            return false
        end
        local quietUntil = tonumber(state.host_push_quiet_until) or 0
        local slice = quietUntil - now + TIMEOUT.hostIdleSliceMin
        if slice < TIMEOUT.hostIdleSliceMin then
            slice = TIMEOUT.hostIdleSliceMin
        end
        if slice > remain then
            slice = remain
        end
        sys.wait(slice)
    end
    return true
end

----------------------------------------------------------------
-- UART 事务锁（可重入）
----------------------------------------------------------------

local function uartAcquire(timeoutMs)
    timeoutMs = tonumber(timeoutMs) or 8000
    local me = coroutine.running()
    if not me then
        return false
    end
    if uartTxnOwner == me then
        uartTxnDepth = uartTxnDepth + 1
        return true
    end
    local deadline = hostNowMs() + timeoutMs
    while state.uart_txn_busy do
        local now = hostNowMs()
        if now >= deadline then
            return false
        end
        local slice = deadline - now
        if slice > TIMEOUT.txnWaitSlice then
            slice = TIMEOUT.txnWaitSlice
        elseif slice < TIMEOUT.txnWaitMin then
            slice = TIMEOUT.txnWaitMin
        end
        sys.wait(slice)
    end
    state.uart_txn_busy = true
    uartTxnOwner = me
    uartTxnDepth = 1
    return true
end

-- 破坏性会话持有协程（P3；声明须先于 resetUartTxn，否则那里的赋值会落成全局——2026-09-05 评审修复）
local uartSessionOwner = nil

-- stop 时（及冷启动首次 start）复位事务锁：持有者协程若在 stop 期间被丢弃，锁会永久 busy，
-- 之后所有 hostQuery/hostSet 只能等超时走 fallback；复位后原持有者的 uartRelease 变 no-op。
-- 运行中重入 start 不复位——否则会把仍在等 ACK 的持有者手里的锁放给第二个协程
local function resetUartTxn()
    uartTxnOwner = nil
    uartTxnDepth = 0
    state.uart_txn_busy = false
    state.uart_session = nil
    uartSessionOwner = nil
end

----------------------------------------------------------------
-- 破坏性串口会话（refactor_plan P3）：格式化 / 断电 / USB 恢复期间，
-- 除会话持有协程外，所有 hostQuery 走 fallback、hostSet 回 busy、1003 刷新走缓存。
-- 与事务锁的分工：锁 = 「同时只有一个请求在飞」；会话 = 「T31x 处于不可打扰状态」。
----------------------------------------------------------------

local function enterSession(name)
    if state.uart_session then
        return false
    end
    state.uart_session = name
    uartSessionOwner = coroutine.running()
    return true
end

local function leaveSession(name)
    if state.uart_session == name then
        state.uart_session = nil
        uartSessionOwner = nil
    end
end

-- 当前协程是否被会话拦截（会话持有者自己可继续发查询）
local function sessionBlocks()
    return state.uart_session ~= nil and uartSessionOwner ~= coroutine.running()
end

local function uartRelease()
    local me = coroutine.running()
    if uartTxnOwner ~= me then
        return
    end
    uartTxnDepth = uartTxnDepth - 1
    if uartTxnDepth <= 0 then
        uartTxnDepth = 0
        uartTxnOwner = nil
        state.uart_txn_busy = false
    end
end

----------------------------------------------------------------
-- AT 应答格式
----------------------------------------------------------------

local RSP_OK = CRLF .. "OK" .. CRLF
local function okTail()
    return RSP_OK
end

local function rspOnly(tag, body)
    return CRLF .. "+" .. tag .. ":" .. body .. CRLF
end

local function rspBody(tag, body)
    return rspOnly(tag, body) .. okTail()
end

local function rspFmt(tag, fmt, ...)
    return string.format(CRLF .. "+" .. tag .. ":" .. fmt .. CRLF, ...) .. okTail()
end

local function rspLine(tag, ok)
    return rspOnly(tag, ok and "OK" or "ERROR")
end

local function rspLineOk(tag)
    return rspLine(tag, true) .. okTail()
end

----------------------------------------------------------------
-- USB / 配置快照
----------------------------------------------------------------

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
    return rp("isUsbInserted") == true
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
        online = rp("isOnline") and 1 or 0,
        power = rp("getPowerStatus") or 0,
        lowpower = rp("isLowPowerMode") and 1 or 0,
        battery = rp("getBatteryPercent") or "--",
        vbat = rp("getBatteryMv") or "--",
        interval = rp("getLowPowerInterval") or 0,
        devicemodel = meta.device_model or "",
        wled = rp("getWledOn") or 0,
        workmode = rp("getWorkMode") or "person_detect",
        tcp_extra = bizCall("lpAppCfgFields") or "",
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
    hooks.uartWrite(CRLF .. "+RXHEX:" .. utils.encodeHex(data) .. CRLF)
end

local function writeT31xNotify(tpl, val)
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
    if cfg.notify_t31x_usb_state == false then
        return false
    end
    return writeT31xNotify(cfg.t31x_usb_ursp or "+CAT1:USB,%d", inserted)
end

function pushNetLedSt(online)
    local cfg = cfgm.get("LED_CFG")
    if cfg.notify_t31x_net_led ~= true then
        return false
    end
    return writeT31xNotify(cfg.t31x_net_ursp or "+CAT1:MQTT,%d", online)
end

----------------------------------------------------------------
-- 模块装配（唯一装配点）
--   各编排器 bind(C) 返回自身对外 API / 共享 helper；host_uart 在此
--   把 api 合并进 _M（= ctx.M），把共享 helper 回填进 ctx。
--   · cmd / ipc 的 api → _M（host_uart 对外公开函数）
--   · rx 的解析能力 + 各编排器回填到 ctx 的 helper → ctx（跨编排器复用）
----------------------------------------------------------------

----------------------------------------------------------------
-- 共享上下文 ctx：注入给所有 hif_* 子模块（bind(C)）
--   上半：host_uart 提供（子模块只读）
--   下半：子模块在 bind 时回填（见各编排器末尾的“注册”段）
----------------------------------------------------------------

ctx = {
    -- 运行时引用
    M = _M,
    state = state,
    hooks = hooks,
    SYS_EVT = SYS_EVT,
    TMO_SHARED = TMO_SHARED,
    E = E,
    LOG_TAG = LOG_TAG,
    hostNowMs = hostNowMs,

    -- AT 响应格式化
    rspOnly = rspOnly,
    rspBody = rspBody,
    rspFmt = rspFmt,
    rspLine = rspLine,
    rspLineOk = rspLineOk,
    okTail = okTail,
    CRLF = CRLF,
    RSP_ERROR = RSP_ERROR,

    -- 模块工具
    modCall = modCall,
    bizCall = bizCall,
    setHostIpcStatus = setHostIpcStatus,
    setHostAtReady = setHostAtReady,
    setHostTfCard = setHostTfCard,
    setHostCloudStat = setHostCloudStat,
    loader = loader,
    utils = utils,
    uart_bridge = uart_bridge,

    -- 业务 helper（host_uart 提供）
    setPendingWake = setPendingWake,
    getHostEvtPending = getHostEvtPending,
    noopIdle = noopIdle,
    usbInserted = usbInserted,
    usbBlockHost = usbBlockHost,
    configSnap = configSnap,
    hostUsbCfg = hostUsbCfg,
    t31xUartOff = t31xUartOff,
    waitHostIdle = waitHostIdle,
    uartAcquire = uartAcquire,
    uartRelease = uartRelease,
    enterSession = enterSession,
    leaveSession = leaveSession,
    sessionBlocks = sessionBlocks,
    hostBusy = hostBusy,
    logPowerOffRx = logPowerOffRx,
    noteHostPush = noteHostPush,
    parseSvcArgs = parseSvcArgs,
    pushUsbIdle = pushUsbIdle,

    -- 以下由子模块在 bind 时回填到 ctx（跨编排器复用点）：
    --   hif_rx   → parseTfCard / parseIpcStat / normIpcCloud / commitIpcStat / patchCloud
    --   hif_ipc  → idCfg / hostQuery / hostSet / noteUartLinkOk
    --   hif_cmd  → wledState / wledExport / wledGet / ipcReadyFrom
}

local cmd = require("hif_cmd").bind(ctx)
local AT_EXACT, AT_PREFIX = require("hif_at").compile(cmd.at)
-- 装配 hif_cmd 对外 API → _M（唯一装配点）
for k, fn in pairs(cmd.api) do _M[k] = fn end
local LINE_HANDLERS = {
    HEX = cmd.hexLine,
    STR = cmd.strLine,
}

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

local rx = require("hif_rx").bind(ctx)
-- 回填 hif_rx 提供的解析能力到 ctx（供 hif_cmd_t31x 等复用）
ctx.parseTfCard = rx.parseTfCard
ctx.parseIpcStat = rx.parseIpcStat
ctx.normIpcCloud = rx.normIpcCloud
ctx.commitIpcStat = rx.commitIpcStat
ctx.patchCloud = rx.patchCloud
local normLine = rx.normLine
local RX_LINE_TRY_HANDLERS = rx.tryHandlers

local ipc = require("hif_ipc").bind(ctx)
-- 装配 hif_ipc 对外 API → _M（唯一装配点）
for k, fn in pairs(ipc) do _M[k] = fn end
-- 外部模块（ipc_supv）经 host_uart._M 使用的本文件 local / rx 能力：显式导出，否则为 nil 调用（P9 成员校验）
_M.hostBusy = hostBusy
_M.getUartSession = function() return state.uart_session end -- t31x_ctrl.blockSleep 仲裁用（P3 会话）
_M.patchCloud = rx.patchCloud -- 仅限非 recordingt31x 的云状态补丁（recordingt31x 走 setRecActive，护栏守护）

----------------------------------------------------------------
-- RX 行处理
----------------------------------------------------------------

local function onFirstHostAt(atLine)
    if state.host_at_ready then
        return
    end
    setHostAtReady(true)
    state.first_host_at = atLine
    state.host_ready_seen = true
    if ctx.noteUartLinkOk then
        ctx.noteUartLinkOk()
    end
    state.uart_recovery_attempts = 0
    state.uart_recovery_last_sec = 0
    ctx.patchCloud({ cat1Link = 1 })
    sys.taskInit(function()
        sys.wait(TIMEOUT.firstAtCloudWait)
        if not ctx.M.canQueryT31() then
            return
        end
        ctx.M.qryIpcCloudStat(TMO_SHARED.cloudStatQueryMs)
        ctx.M.mergeTfCloud()
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
    if log and log.info then
        log.info(LOG_TAG, "uart_rx", line)
    end
    for i = 1, #RX_LINE_TRY_HANDLERS do
        if RX_LINE_TRY_HANDLERS[i](line) then
            return nil
        end
    end
    if line:sub(1, 2) == "AT" then
        noteHostPush()
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

local START_HOOK_KEYS = {
    "onServCreate", "onServClose", "onMqttCfg", "onAtExt",
    "onEnterLowPower", "onExitLowPower", "onReboot", "onPowerOff",
    "onOta", "onPlainLine", "biz",
}

local function bindStartHooks(opts)
    for i = 1, #START_HOOK_KEYS do
        local k = START_HOOK_KEYS[i]
        hooks[k] = opts[k]
    end
    hooks.uartWrite = uart_bridge.write
    hooks.sendString = uart_bridge.sendString
    hooks.sendHex = function(hex)
        local bin = utils.decodeHex(hex)
        return bin and uart_bridge.write(bin)
    end
    hooks.modemAt = opts.modemAt or defaultModemAt
end

function isHostAtReady()
    return state.host_at_ready == true
end

function start(opts)
    opts = opts or {}
    -- require 兜底仅兼容裸启动/独立单测；产品路径必经 app.start 显式注入（见 FUNCTIONAL_ARCHITECTURE §7.2 S2）
    t31xModule = opts.t31x or require "t31x_ctrl"
    t31xFallback = t31xModule
    setHostAtReady(false)
    state.first_host_at = nil
    if not started then resetUartTxn() end
    bindStartHooks(opts)
    uart_bridge.setOnLine(onUartLine)
    started = true
    return true
end

function stop()
    uart_bridge.setOnLine(nil)
    resetUartTxn()
    started = false
    return true
end

function ntfHost(sid, evt)
    local cfg = cfgm.get("HOST_WAKE_CFG")
    sid = sid or cfg.default_sid or 1
    evt = evt or _M.EVT.SERVER_DATA
    if bizCall("mayPowerT31x", "ntfHost") == false then
        return false
    end
    setPendingWake(sid, evt)
    if not t31xModule then
        t31xModule = t31xFallback
    end
    if not t31xModule then
        return false
    end
    local t31xSt = t31xModule.getState()
    if t31xSt and (not t31xSt.powered_on or t31xSt.in_boot_mode) then
        t31xModule.ensNormalPwrOn("ntfHost")
    end
    bizCall("markT31xWoken")
    return t31xModule.pulseMcuInt()
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
