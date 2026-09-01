-- ================================================================
-- Filename : hu_ipc.lua
-- Module   : hostQuery/hostSet 核心 + 子模块编排，由 host_uart.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- hostQuery / hostSet / defineQuery / defineSet → recovery/hostq/cloud/power/tffmt/encode
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

    local TIMEOUT = {
        atRetryWait = 200,
        atRetryCap = 4000,
        postQueryWait = 300,
        quietCap = 1500,
        defaultQuery = 3000,
        t3xPowerWait = 800,
        hostBootWait = 1500,
    }

    ----------------------------------------------------------------
    -- 配置
    ----------------------------------------------------------------

    local function getCfg(key)
        return cfgm.get(key)
    end

    local function idCfgFn()
        return getCfg("HOST_IDENTITY_CFG")
    end

    local function encodeCfgFn()
        return getCfg("HOST_ENCODE_CFG")
    end

    local function tfCardCfgFn()
        return getCfg("HOST_TFCARD_CFG")
    end

    local function t3xPowerWaitMs(hostCfg)
        return tonumber(hostCfg.t3x_power_wait_ms)
            or tonumber(getCfg("TIME_SYNC_CFG").t3x_power_wait_ms)
            or TIMEOUT.t3xPowerWait
    end

    local function hostBootWaitMs(hostCfg)
        return tonumber(hostCfg.hostBootWaitMs)
            or tonumber(getCfg("TIME_SYNC_CFG").hostBootWaitMs)
            or TIMEOUT.hostBootWait
    end

    local function ensT3xHost(policyTag, hostCfg)
        hostCfg = hostCfg or idCfgFn()
        return modCall("t3x_ctrl", "ensPowOn", policyTag or "host_identity", {
            t3xPowerWaitMs = t3xPowerWaitMs(hostCfg),
        }) == true
    end

    local function hostBoot(hostCfg)
        return hostBootWaitMs(hostCfg)
    end

    ----------------------------------------------------------------
    -- query / set 公共
    ----------------------------------------------------------------

    local function queryFallback(opts)
        if opts.cacheKey and state[opts.cacheKey] ~= nil then
            return state[opts.cacheKey]
        end
        if opts.busyReturn ~= nil then
            return opts.busyReturn
        end
        return opts.defaultResult
    end

    local function resolveTimeout(hostCfg, opts)
        return tonumber(opts.timeoutMs)
            or tonumber(hostCfg[opts.timeoutCfgKey or "query_timeout_ms"])
            or opts.defaultTimeout
            or TIMEOUT.defaultQuery
    end

    local function waitHostQuiet(timeoutMs)
        waitHostIdle(math.min(timeoutMs, TIMEOUT.quietCap))
    end

    local function waitHostBootIfNeeded(hostCfg, spec)
        if spec.waitBoot == false or state.host_at_ready then
            return
        end
        sys.wait(hostBoot(spec.bootCfg or hostCfg))
    end

    local function sendAtRetry(atCmd, ackEvent, timeoutMs, beforeSend)
        if beforeSend then
            beforeSend()
        end
        uart_bridge.sendString(atCmd, true)
        local got, val = sys.waitUntil(ackEvent, timeoutMs)
        if got then
            return got, val
        end
        sys.wait(TIMEOUT.atRetryWait)
        if beforeSend then
            beforeSend()
        end
        uart_bridge.sendString(atCmd, true)
        return sys.waitUntil(ackEvent, math.min(timeoutMs, TIMEOUT.atRetryCap))
    end

    local function runHostQuery(opts)
        if not coroutine.running() then
            return queryFallback(opts)
        end
        if state[opts.busyKey] then
            return queryFallback(opts)
        end
        local hostCfg = opts.cfg or idCfgFn()
        local timeoutMs = resolveTimeout(hostCfg, opts)
        if not uartAcquire(timeoutMs) then
            return queryFallback(opts)
        end
        state[opts.busyKey] = true
        local result = opts.defaultResult
        local ok, err = pcall(function()
            if opts.whenDisabled then
                local early = opts.whenDisabled(hostCfg)
                if early ~= nil then
                    result = early
                    return
                end
            end
            if not ensT3xHost(opts.policyTag, hostCfg) then
                if opts.onNoT3x then
                    result = opts.onNoT3x()
                end
                return
            end
            waitHostBootIfNeeded(hostCfg, opts)
            if opts.skipQuiet ~= true then
                waitHostQuiet(timeoutMs)
            end
            local got, val = sendAtRetry(opts.atCmd, opts.ackEvent, timeoutMs, opts.beforeSend)
            result = opts.onResponse(got, val, timeoutMs) or result
            if not got then
                sys.wait(TIMEOUT.postQueryWait)
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

    local function hostQuery(timeoutMs, opts)
        opts.timeoutMs = timeoutMs
        return runHostQuery(opts)
    end

    local function hostSet(spec)
        spec = spec or {}
        local busyKey = spec.busyKey
        if busyKey and state[busyKey] then
            return false, "busy", nil
        end
        if busyKey then
            state[busyKey] = true
        end
        local okSet, msg, extra
        local ok, e = pcall(function()
            local cfg = spec.cfg or idCfgFn()
            local timeoutMs = resolveTimeout(cfg, spec)
            if not uartAcquire(timeoutMs) then
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
            if not ensT3xHost(spec.policyTag, cfg) then
                okSet, msg = false, "t3x_unavailable"
                return
            end
            waitHostBootIfNeeded(cfg, spec)
            if spec.skipQuiet ~= true then
                waitHostQuiet(timeoutMs)
            end
            local got, rsp = sendAtRetry(atCmd, spec.ackEvent, timeoutMs)
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
        if busyKey then
            state[busyKey] = false
        end
        if not ok then
            return false, tostring(e), nil
        end
        return okSet, msg, extra
    end

    local function cacheOnResponse(cacheKey, requireParsed)
        return function(got, snap)
            if got and type(snap) == "table" and (not requireParsed or snap.parsed) then
                state[cacheKey] = snap
                return snap
            end
            return state[cacheKey]
        end
    end

    local function parseOkRsp(rsp)
        if rsp and rsp.ok then
            return true, "ok", rsp
        end
        return false, "error", nil
    end

    local function cachedHostQuery(timeoutMs, opts)
        opts = opts or {}
        if opts.cacheKey and opts.requireParsed ~= nil and not opts.onResponse then
            opts.onResponse = cacheOnResponse(opts.cacheKey, opts.requireParsed)
        end
        opts.requireParsed = nil
        return hostQuery(timeoutMs, opts)
    end

    ----------------------------------------------------------------
    -- defineQuery / defineSet 工厂
    ----------------------------------------------------------------

    local function defineQuery(d)
        return function(arg)
            local opts = type(arg) == "table" and arg or nil
            return cachedHostQuery(opts and opts.timeoutMs or arg, {
                busyKey = d.busy,
                cacheKey = d.cache,
                requireParsed = d.parsed,
                policyTag = d.tag,
                cfg = d.cfg(),
                defaultTimeout = d.tmo,
                atCmd = type(d.at) == "function" and d.at(opts or {}) or d.at,
                ackEvent = d.ev,
                whenDisabled = d.dis,
                beforeSend = d.pre,
                onResponse = d.rsp,
            })
        end
    end

    local function defineSet(d)
        return function(opts)
            opts = opts or {}
            return hostSet({
                busyKey = d.busy,
                policyTag = d.tag,
                cfg = d.cfg(),
                bootCfg = d.boot and d.boot() or nil,
                defaultTimeout = d.tmo,
                timeoutMs = opts.timeoutMs,
                ackEvent = d.ev,
                skipQuiet = d.skipQuiet,
                prepare = function()
                    return d.prep(opts)
                end,
                parseRsp = d.parse or parseOkRsp,
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
        idCfgFn = idCfgFn,
        encodeCfgFn = encodeCfgFn,
        tfCardCfgFn = tfCardCfgFn,
    }

    ----------------------------------------------------------------
    -- 子模块编排
    ----------------------------------------------------------------

    local recovery = require("hu_ipc_rec").bind(C, H)
    local hostq = require("hu_ipc_hostq").bind(C, H)
    local cloud = require("hu_ipc_cloud").bind(C, H, recovery, hostq)
    local power = require("hu_ipc_power").bind(C, H, recovery)
    local tffmt = require("hu_ipc_tffmt").bind(C, H)
    local enc = require("hu_ipc_encode").bind(C, {
        defineSet = defineSet,
        hostQuery = hostQuery,
        getCfg = getCfg,
    })

    C.idCfg = idCfgFn
    C.hostQuery = hostQuery
    C.hostSet = hostSet
    C.noteUartLinkOk = recovery.noteUartLinkOk

    local exp = {
        cachedGb28181Id = cloud.cachedGb28181Id,
        qryGb28181 = cloud.qryGb28181,
        isIpcCloudStatStale = cloud.isIpcCloudStatStale,
        isT31HostQry = cloud.isT31HostQry,
        shouldQryIpcStat = cloud.shouldQryIpcStat,
        needsIpcStatRefresh = cloud.needsIpcStatRefresh,
        mergeTfCloud = cloud.mergeTfCloud,
        refCloudF1003 = cloud.refCloudF1003,
        isHuBusy = cloud.isHuBusy,
        recHostSess = cloud.recHostSess,
        qryIpcCloudStat = cloud.qryIpcCloudStat,
        cachedTfCard = cloud.cachedTfCard,
        resetHostLink = recovery.resetHostLink,
        qryHostRecord = hostq.qryHostRecord,
        qryRecTime = hostq.qryRecTime,
        setRecTime = hostq.setRecTime,
        queryHostFramerate = hostq.queryHostFramerate,
        setHostFramerate = hostq.setHostFramerate,
        queryHostPersonDetect = hostq.queryHostPersonDetect,
        setHostPersonDetect = hostq.setHostPersonDetect,
        queryHostMic = hostq.queryHostMic,
        setHostMic = hostq.setHostMic,
        queryHostSoftPhoto = hostq.queryHostSoftPhoto,
        setHostSoftPhoto = hostq.setHostSoftPhoto,
        queryHostTfCard = hostq.queryHostTfCard,
        queryHostEncode = enc.queryHostEncode,
        setHostVideoEncode = enc.setHostVideoEncode,
        setHostAudioEncode = enc.setHostAudioEncode,
        setHostEncode = enc.setHostEncode,
        formatHostTfCard = tffmt.formatHostTfCard,
        requestUploadVideo = hostq.requestUploadVideo,
        recordCtrlStart = hostq.recordCtrlStart,
        recordCtrlStop = hostq.recordCtrlStop,
        qryHostStat = recovery.qryHostStat,
        hostIpcPowerOff = power.hostIpcPowerOff,
        waitHostIpcReady = power.waitHostIpcReady,
        getCloudStat = cloud.getCloudStat,
        getT3xRecActive = hostq.getT3xRecActive,
    }
    for k, fn in pairs(exp) do
        C.M[k] = fn
    end
    return _M
end

return _M
