-- ================================================================
-- Filename : hu_ipc.lua
-- Module   : hostQuery / hostSet + 子模块编排，由 host_uart.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- 本文件只做两件事：UART 上 query/set 公共路径，再 bind
-- rec → hostq（查询挂 H）→ cloud → power → tffmt → encode
-- defineQuery/defineSet 字段与 hostQuery/hostSet 同名
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local cfgm = require "config_manager"
    local state = C.state
    local uartAcquire = C.uartAcquire
    local uartRelease = C.uartRelease
    local waitHostIdle = C.waitHostIdle
    local uart_bridge = C.uart_bridge
    local modCall = C.modCall
    local getCfg = cfgm.get

    local TMO = {
        retryWait = 200,
        retryCap = 4000,
        postQry = 300,
        quiet = 1500,
        qry = 3000,
        t3xWait = 800,
        bootWait = 1500,
    }

    ----------------------------------------------------------------
    -- 配置 / T3x
    ----------------------------------------------------------------

    local function idCfg()
        return getCfg("HOST_IDENTITY_CFG")
    end

    local function encodeCfg()
        return getCfg("HOST_ENCODE_CFG")
    end

    local function tfCfg()
        return getCfg("HOST_TFCARD_CFG")
    end

    local function cfgMs(hostCfg, key, fb)
        return tonumber(hostCfg[key])
            or tonumber(getCfg("TIME_SYNC_CFG")[key])
            or fb
    end

    local function ensT3xHost(policyTag, hostCfg)
        hostCfg = hostCfg or idCfg()
        return modCall("t3x_ctrl", "ensPowOn", policyTag or "host_identity", {
            t3xPowerWaitMs = cfgMs(hostCfg, "t3x_power_wait_ms", TMO.t3xWait),
        }) == true
    end

    local function hostBoot(hostCfg)
        return cfgMs(hostCfg, "hostBootWaitMs", TMO.bootWait)
    end

    ----------------------------------------------------------------
    -- query / set 公共：锁 → 上电 → 等静 → AT（失败再发一次）
    ----------------------------------------------------------------

    local function qryFallback(opts)
        if opts.cacheKey and state[opts.cacheKey] ~= nil then
            return state[opts.cacheKey]
        end
        if opts.busyReturn ~= nil then
            return opts.busyReturn
        end
        return opts.defaultResult
    end

    local function timeoutMs(hostCfg, opts)
        return tonumber(opts.timeoutMs)
            or tonumber(hostCfg[opts.timeoutCfgKey or "query_timeout_ms"])
            or opts.defaultTimeout
            or TMO.qry
    end

    local function waitBoot(hostCfg, spec)
        if spec.waitBoot == false or state.host_at_ready then
            return
        end
        sys.wait(hostBoot(spec.bootCfg or hostCfg))
    end

    local function sendAt(atCmd, ackEvent, waitMs, beforeSend)
        if beforeSend then
            beforeSend()
        end
        uart_bridge.sendString(atCmd, true)
        return sys.waitUntil(ackEvent, waitMs)
    end

    local function sendAtRetry(atCmd, ackEvent, waitMs, beforeSend)
        local got, val = sendAt(atCmd, ackEvent, waitMs, beforeSend)
        if got then
            return got, val
        end
        sys.wait(TMO.retryWait)
        return sendAt(atCmd, ackEvent, math.min(waitMs, TMO.retryCap), beforeSend)
    end

    -- T3x 在线后等 boot/quiet。失败返回 false（query 走 onNoT3x，set 回 t3x_unavailable）
    local function armHost(cfg, spec, waitMs)
        if not ensT3xHost(spec.policyTag, cfg) then
            return false
        end
        waitBoot(cfg, spec)
        if spec.skipQuiet ~= true then
            waitHostIdle(math.min(waitMs, TMO.quiet))
        end
        return true
    end

    local function hostQuery(waitMs, opts)
        opts.timeoutMs = waitMs
        if not coroutine.running() or state[opts.busyKey] then
            return qryFallback(opts)
        end
        local cfg = opts.cfg or idCfg()
        waitMs = timeoutMs(cfg, opts)
        if not uartAcquire(waitMs) then
            return qryFallback(opts)
        end
        state[opts.busyKey] = true
        local result = opts.defaultResult
        local ok, err = pcall(function()
            if opts.whenDisabled then
                local early = opts.whenDisabled(cfg)
                if early ~= nil then
                    result = early
                    return
                end
            end
            if not armHost(cfg, opts, waitMs) then
                if opts.onNoT3x then
                    result = opts.onNoT3x()
                end
                return
            end
            local got, val = sendAtRetry(opts.atCmd, opts.ackEvent, waitMs, opts.beforeSend)
            result = opts.onResponse(got, val, waitMs) or result
            if not got then
                sys.wait(TMO.postQry)
            end
        end)
        state[opts.busyKey] = false
        uartRelease()
        if not ok then
            if opts.onError then
                return opts.onError(err)
            end
            return opts.defaultResult
        end
        return result
    end

    local function hostSet(spec)
        spec = spec or {}
        local busy = spec.busyKey
        if busy and state[busy] then
            return false, "busy", nil
        end
        if busy then
            state[busy] = true
        end
        local okSet, msg, extra
        local ok, e = pcall(function()
            local cfg = spec.cfg or idCfg()
            local waitMs = timeoutMs(cfg, spec)
            if not uartAcquire(waitMs) then
                okSet, msg = false, "busy"
                return
            end
            local prepOk, prepMsg, atCmd = true, nil, spec.atCmd
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
            if not armHost(cfg, spec, waitMs) then
                okSet, msg = false, "t3x_unavailable"
                return
            end
            local got, rsp = sendAtRetry(atCmd, spec.ackEvent, waitMs)
            if not got or type(rsp) ~= "table" then
                okSet, msg = false, "timeout"
                return
            end
            if spec.parseRsp then
                okSet, msg, extra = spec.parseRsp(rsp, spec)
                return
            end
            if rsp.ok then
                okSet, msg, extra = true, "ok", rsp
                return
            end
            okSet, msg = false, "error"
        end)
        uartRelease()
        if busy then
            state[busy] = false
        end
        if not ok then
            return false, tostring(e), nil
        end
        return okSet, msg, extra
    end

    local function cacheRsp(cacheKey, needParsed)
        return function(got, snap)
            if got and type(snap) == "table" and (not needParsed or snap.parsed) then
                state[cacheKey] = snap
                return snap
            end
            return state[cacheKey]
        end
    end

    local function parseOk(rsp)
        if rsp and rsp.ok then
            return true, "ok", rsp
        end
        return false, "error", nil
    end

    local function cachedQry(waitMs, opts)
        opts = opts or {}
        if opts.cacheKey and opts.requireParsed ~= nil and not opts.onResponse then
            opts.onResponse = cacheRsp(opts.cacheKey, opts.requireParsed)
        end
        opts.requireParsed = nil
        return hostQuery(waitMs, opts)
    end

    ----------------------------------------------------------------
    -- 工厂：子模块用 hostQuery/hostSet 同名字段
    ----------------------------------------------------------------

    local function defineQuery(d)
        return function(arg)
            local opts = type(arg) == "table" and arg or nil
            local atCmd = d.atCmd
            if type(atCmd) == "function" then
                atCmd = atCmd(opts or {})
            end
            return cachedQry(opts and opts.timeoutMs or arg, {
                busyKey = d.busyKey,
                cacheKey = d.cacheKey,
                requireParsed = d.requireParsed,
                policyTag = d.policyTag,
                cfg = d.cfg(),
                defaultTimeout = d.timeout,
                atCmd = atCmd,
                ackEvent = d.ackEvent,
                whenDisabled = d.whenDisabled,
                beforeSend = d.beforeSend,
                onResponse = d.onResponse,
            })
        end
    end

    local function defineSet(d)
        return function(opts)
            opts = opts or {}
            return hostSet({
                busyKey = d.busyKey,
                policyTag = d.policyTag,
                cfg = d.cfg(),
                bootCfg = d.bootCfg and d.bootCfg() or nil,
                defaultTimeout = d.timeout,
                timeoutMs = opts.timeoutMs,
                ackEvent = d.ackEvent,
                skipQuiet = d.skipQuiet,
                prepare = function()
                    return d.prepare(opts)
                end,
                parseRsp = d.parseRsp or parseOk,
            })
        end
    end

    local H = {
        getCfg = getCfg,
        hostQuery = hostQuery,
        hostSet = hostSet,
        defineQuery = defineQuery,
        defineSet = defineSet,
        ensT3xHost = ensT3xHost,
        hostBoot = hostBoot,
        idCfgFn = idCfg,
        encodeCfgFn = encodeCfg,
        tfCardCfgFn = tfCfg,
    }

    ----------------------------------------------------------------
    -- 子模块：顺序不要改（先 rec/hostq，把查询挂上 H，再 cloud/power）
    ----------------------------------------------------------------

    local recovery = require("hu_ipc_rec").bind(C, H)
    H.qryHostStat = recovery.qryHostStat
    local hostq = require("hu_ipc_hostq").bind(C, H)
    H.qryHostRecord = hostq.qryHostRecord
    local cloud = require("hu_ipc_cloud").bind(C, H)
    local power = require("hu_ipc_power").bind(C, H)
    local tffmt = require("hu_ipc_tffmt").bind(C, H)
    local enc = require("hu_ipc_encode").bind(C, H)

    C.idCfg = idCfg
    C.hostQuery = hostQuery
    C.hostSet = hostSet
    C.noteUartLinkOk = recovery.noteUartLinkOk

    -- noteUartLinkOk 只挂 C；其余 return 表即 host_uart 对外 API
    C.M.resetHostLink = recovery.resetHostLink
    C.M.qryHostStat = recovery.qryHostStat
    local function hang(...)
        for i = 1, select("#", ...) do
            for k, fn in pairs((select(i, ...))) do
                C.M[k] = fn
            end
        end
    end
    hang(hostq, cloud, power, tffmt, enc)
    return _M
end

return _M
