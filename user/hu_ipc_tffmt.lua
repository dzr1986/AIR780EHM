-- ================================================================
-- Filename : hu_ipc_tffmt.lua
-- Module   : AT+TFFORMAT formatHostTfCard，由 hu_ipc.bind
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
    local t3xSecOff = C.t3xSecOff
    local hostNowMs = C.hostNowMs
    local ensT3xHost = H.ensT3xHost
    local hostBoot = H.hostBoot

    local TIMEOUT = {
        formatMs = 120000,
        startDeadlineMs = 8000,
        hostIdleMs = 2000,
        ackSliceMs = 5000,
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

    local function normalizeLuaErr(err)
        local s = tostring(err or "error")
        local tail = s:match(": ([^:]+)$")
        if tail and tail ~= "" then
            return tail
        end
        return s
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

    local function formatPrecheck(cfg)
        if cfg.enabled == false then
            return false, "disabled"
        end
        if state.tfcard_format_busy then
            return false, "busy"
        end
        if t3xSecOff() then
            return false, "no_uart"
        end
        if not ensT3xHost("host_tfcard_format", cfg) then
            return false, "t3x_unavailable"
        end
        return true
    end

    ----------------------------------------------------------------
    -- format session
    ----------------------------------------------------------------

    local function waitFormatAck(timeoutMs, outcome)
        local deadline = hostNowMs() + timeoutMs
        local startDeadline = hostNowMs() + TIMEOUT.startDeadlineMs
        local started = false
        while true do
            local t = hostNowMs()
            if t >= deadline then
                break
            end
            if not started and t >= startDeadline then
                error("no_started")
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
                    outcome.ok = true
                    outcome.detail = val
                    return
                elseif val.phase == "error" then
                    error(tostring(val.ret or "ipc_error"))
                end
            end
        end
        if not started then
            error("no_started")
        end
        error("timeout")
    end

    local function runFormatSession(opts, cfg, reboot, timeoutMs, outcome)
        if opts.waitBoot ~= false and not state.host_at_ready then
            sys.wait(hostBoot(cfg))
        end
        waitHostIdle(TIMEOUT.hostIdleMs)
        uart_bridge.sendString(buildFormatAt(reboot), true)
        waitFormatAck(timeoutMs, outcome)
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
        state.tfcard_format_busy = true
        local outcome = { ok = false, reason = "unknown" }
        local okRun, errRun = pcall(runFormatSession, opts, cfg, reboot, timeoutMs, outcome)
        state.tfcard_format_busy = false
        if outcome.ok then
            return true, outcome.detail
        end
        if not okRun then
            return false, normalizeLuaErr(errRun)
        end
        return false, outcome.reason
    end

    return {
        formatHostTfCard = formatHostTfCard,
    }
end

return _M
