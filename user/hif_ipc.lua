-- ================================================================
-- Filename : hif_ipc.lua
-- Module   : query/set 公共路径 + 子模块编排（L1），由 host_uart.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- 绑定契约：bind(C) 构建 H（hostQuery/hostSet/defineQuery/defineSet/
--   ensT31xHost/cfg 读取）传给 hif_ipc_*；并把跨编排器复用的 helper 挂到
--   C（idCfg/hostQuery/hostSet/noteUartLinkOk），对外 API 收集进 api
--   表返回（由 host_uart 合并到 _M）。
--
-- 公共路径：uartAcquire → ensT31xHost（上电 T31x）→ waitBoot/quiet
--   → sendAtRetry → onResponse；失败回退 onNotT31x。
--   子模块绑定顺序（勿改）：rec → hostq（先挂查询到 H）→ cloud → power → tffmt → encode
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
        t31xWait = 800,
        bootWait = 1500,
    }

    ----------------------------------------------------------------
    -- 配置 / t31x
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

    local function ensT31xHost(policyTag, hostCfg)
        hostCfg = hostCfg or idCfg()
        return modCall("t31x_ctrl", "ensPowOn", policyTag or "host_identity", {
            t31xPowerWaitMs = cfgMs(hostCfg, "t31x_power_wait_ms", TMO.t31xWait),
        }) == true
    end

    local function hostBoot(hostCfg)
        return cfgMs(hostCfg, "hostBootWaitMs", TMO.bootWait)
    end

    ----------------------------------------------------------------
    -- query / set 公共：锁 → 上电 → 等静 → AT（失败再发一次）
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

    -- t31x 在线后等 boot/quiet。失败返回 false（query 走 onNotT31x，set 回 t31x_unavailable）
    local function armHost(cfg, spec, waitMs)
        if not ensT31xHost(spec.policyTag, cfg) then
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
            return queryFallback(opts)
        end
        local cfg = opts.cfg or idCfg()
        waitMs = timeoutMs(cfg, opts)
        if not uartAcquire(waitMs) then
            return queryFallback(opts)
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
                if opts.onNotT31x then
                    result = opts.onNotT31x()
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
                okSet, msg = false, "t31x_unavailable"
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
    -- 工厂：子模块用短字段 busy/tag/tmo/at/ev/dis/pre/rsp/prep
    ----------------------------------------------------------------

    local function defineQuery(d)
        return function(arg)
            local opts = type(arg) == "table" and arg or nil
            return cachedQry(opts and opts.timeoutMs or arg, {
                busyKey = d.busy,
                cacheKey = d.cache,
                requireParsed = d.parsed,
                policyTag = d.tag,
                cfg = d.cfg(),
                defaultTimeout = d.tmo,
                atCmd = type(d.at) == "function" and d.at(opts or {}) or d.at,
                ackEvent = d.ev,
                -- 与 defineSet 对齐：spec 的 skipQuiet/waitBoot 须透传，否则 hif_cmd_wled
                -- QRY_WLED_D.skipQuiet=true 为死字段，查询仍多等一段 quiet
                skipQuiet = d.skipQuiet,
                waitBoot = d.waitBoot,
                whenDisabled = d.dis,
                beforeSend = d.pre,
                onResponse = d.rsp,
                defaultResult = d.def,
                onNotT31x = d.onNotT31x,
                onError = d.err,
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
                parseRsp = d.parse or parseOk,
            })
        end
    end

    local H = {
        getCfg = getCfg,
        hostQuery = hostQuery,
        hostSet = hostSet,
        defineQuery = defineQuery,
        defineSet = defineSet,
        ensT31xHost = ensT31xHost,
        hostBoot = hostBoot,
        idCfgFn = idCfg,
        encodeCfgFn = encodeCfg,
        tfCardCfgFn = tfCfg,
    }

    ----------------------------------------------------------------
    -- 录制态单一写入点：同步 state.t31x_rec_active 与 cloud.recordingt31x
    --   commitIpcStat 以 cloud.recordingt31x 回填 t31x_rec_active，故以
    --   cloud 为准；统一此处避免散写导致快照与影子态不一致。
    --   不触发 publish：patchCloud/commitIpcStat 局部补丁路径亦不发 IPCSTAT_ACK
    --   （仅 +IPCSTAT: 完整快照 notify=true），避免抢答 qryIpcCloudStat
    ----------------------------------------------------------------
    local function setRecActive(flag)
        flag = (tonumber(flag) == 1) and 1 or 0
        state.t31x_rec_active = flag
        local cloud = state.host_ipc_cloud_stat
        if type(cloud) == "table" then
            cloud.recordingt31x = flag
        end
    end
    C.setRecActive = setRecActive

    ----------------------------------------------------------------
    -- 子模块：顺序不要改（先 rec/hostq，把查询挂上 H，再 cloud/power）
    ----------------------------------------------------------------

    local recovery = require("hif_ipc_rec").bind(C, H)
    H.qryHostStat = recovery.qryHostStat
    local hostq = require("hif_ipc_hostq").bind(C, H)
    H.qryHostRecord = hostq.qryHostRecord
    local cloud = require("hif_ipc_cloud").bind(C, H)
    local power = require("hif_ipc_power").bind(C, H)
    local tffmt = require("hif_ipc_tffmt").bind(C, H)
    local enc = require("hif_ipc_encode").bind(C, H)

    ----------------------------------------------------------------
    -- 共享 helper 留在 ctx（供跨编排器复用，非 host_uart 公开 API）
    --   · C.idCfg / hostQuery / hostSet / noteUartLinkOk
    ----------------------------------------------------------------
    C.idCfg = idCfg
    C.hostQuery = hostQuery
    C.hostSet = hostSet
    C.noteUartLinkOk = recovery.noteUartLinkOk
    -- 工厂：供 wled 等跨编排器模块复用（运行期经 C 取用）
    C.defineQuery = defineQuery
    C.defineSet = defineSet

    ----------------------------------------------------------------
    -- 对外 API：收集到 api 表返回，由 host_uart 在单一处合并到 _M（C.M）
    --   · resetHostLink / qryHostStat（来自 recovery）
    --   · hang(...)：合并全部子模块导出（hostq/cloud/power/tffmt/enc）
    ----------------------------------------------------------------
    local api = {
        resetHostLink = recovery.resetHostLink,
        qryHostStat = recovery.qryHostStat,
    }
    local function hang(...)
        for i = 1, select("#", ...) do
            for k, fn in pairs((select(i, ...))) do
                api[k] = fn
            end
        end
    end
    hang(hostq, cloud, power, tffmt, enc)
    return api
end

return _M
