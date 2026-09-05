-- ================================================================
-- Filename : hif_ipc_tffmt.lua
-- Module   : AT+TFFORMAT formatHostTfCard，由 hif_ipc.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, H)
    local cfgm = require "config_manager"
    local state, SYS_EVT = C.state, C.SYS_EVT
    local waitHostIdle = C.waitHostIdle
    local uart_bridge = C.uart_bridge
    local utils = C.utils
    local t31xUartOff = C.t31xUartOff
    local hostNowMs = C.hostNowMs
    local uartAcquire, uartRelease = C.uartAcquire, C.uartRelease
    local enterSession, leaveSession = C.enterSession, C.leaveSession
    local ensT31xHost = H.ensT31xHost
    local hostBoot = H.hostBoot

    local TMO_SHARED = C.TMO_SHARED
    local TIMEOUT = {
        formatMs = 120000,
        startDeadlineMs = 8000,
        hostIdleMs = 2000,
        ackSliceMs = 5000,
        acquireCapMs = TMO_SHARED.acquireCapMs, -- 单源于 host_uart.TMO_SHARED
    }

    ----------------------------------------------------------------
    -- cfg / precheck
    ----------------------------------------------------------------

    local function formatCfg()
        return cfgm.get("HOST_TFCARD_FORMAT_CFG")
    end

    local function optsTable(opts)
        return utils.optTable(opts)
    end

    local function rebootFlag(opts, cfg)
        local reboot = opts.reboot
        if reboot == nil then
            reboot = cfg.reboot_after == true or cfg.reboot_after == 1
        end
        return utils.parseBool(reboot) and 1 or 0
    end

    local function buildFormatAt(reboot)
        return string.format("AT+TFFORMAT=1,reboot=%d", reboot)
    end

    -- 只做同步判定（不 yield）；ensT31xHost 可能 sys.wait，放到 busy 置位之后的 session 内，
    -- 否则两个并发 2009 会同时通过预检
    local function formatPrecheck(cfg)
        if cfg.enabled == false then
            return false, "disabled"
        end
        if state.uart_session then
            return false, "busy"
        end
        if t31xUartOff() then
            return false, "no_uart"
        end
        return true
    end

    ----------------------------------------------------------------
    -- format session
    ----------------------------------------------------------------

    -- 返回约定（refactor_plan P5）：命令类一律 `ok, reason[, detail]`，业务失败码不走 error()。
    -- reason 词表见 doc/mqtt/MQTT_REPLY_MESSAGES.md（1009 message 原样透传）。
    local function waitFormatAck(timeoutMs)
        local deadline = hostNowMs() + timeoutMs
        local startDeadline = hostNowMs() + TIMEOUT.startDeadlineMs
        local started = false
        while true do
            local t = hostNowMs()
            if t >= deadline then
                break
            end
            if not started and t >= startDeadline then
                return false, "no_started"
            end
            local remain = deadline - t
            if remain <= 0 then
                break
            end
            local slice = remain > TIMEOUT.ackSliceMs and TIMEOUT.ackSliceMs or remain
            local got, val = sys.waitUntil(SYS_EVT.TFFORMAT_ACK, slice)
            if got and type(val) == "table" then
                if val.phase == "started" then
                    started = true
                elseif val.phase == "ok" then
                    return true, nil, val
                elseif val.phase == "error" then
                    return false, tostring(val.ret or "ipc_error")
                end
            end
        end
        return false, started and "timeout" or "no_started"
    end

    -- 与 hostQuery / hostIpcPowerOff 同序：先拿串口事务锁 → 上电 → 等 boot/quiet → 发 AT → 等终态。
    -- 整段持锁（含最长 format_timeout_ms=120s 的等待）：格式化期间 T31x 本就不应被任何 AT 打扰；
    -- 1003 刷新不受影响——uart_session 期间 isCloudBusy 为真，refCloudStat1003 全程走缓存；
    -- 其它 hostQuery 在锁上等到自身 timeout 后走 fallback 缓存。
    local function runFormatSession(opts, cfg, reboot, timeoutMs)
        if not uartAcquire(math.min(timeoutMs, TIMEOUT.acquireCapMs)) then
            return false, "uart_busy"
        end
        if not ensT31xHost("host_tfcard_format", cfg) then
            return false, "t31x_unavailable"
        end
        if opts.waitBoot ~= false and not state.host_at_ready then
            sys.wait(hostBoot(cfg))
        end
        waitHostIdle(TIMEOUT.hostIdleMs)
        uart_bridge.sendString(buildFormatAt(reboot), true)
        return waitFormatAck(timeoutMs)
    end

    ----------------------------------------------------------------
    -- TFFORMAT
    ----------------------------------------------------------------

    local function formatHostTfCard(opts)
        opts = optsTable(opts)
        local cfg = formatCfg()
        local okPre, reason = formatPrecheck(cfg)
        if not okPre then
            return false, reason
        end
        local timeoutMs = tonumber(opts.timeoutMs) or tonumber(cfg.format_timeout_ms) or TIMEOUT.formatMs
        local reboot = rebootFlag(opts, cfg)
        if not enterSession("tfformat") then -- 预检后即刻进入会话（预检无 yield），后续 yield 前已互斥
            return false, "busy"
        end
        -- pcall 只兜 Lua 运行时异常（平台 API / 编程错误），业务失败经返回值传递
        local okRun, ok, reason, detail = pcall(runFormatSession, opts, cfg, reboot, timeoutMs)
        uartRelease() -- 唯一释放点（acquire 失败时非持有者调用为 no-op）
        leaveSession("tfformat")
        if not okRun then
            if log and log.warn then log.warn("host_uart", "tffmt_internal_error", tostring(ok)) end
            return false, "internal_error"
        end
        if ok then
            return true, detail
        end
        return false, reason or "unknown"
    end

    return {
        formatHostTfCard = formatHostTfCard,
    }
end

return _M
