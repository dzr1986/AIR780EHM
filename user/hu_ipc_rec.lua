-- ================================================================
-- Filename : hu_ipc_rec.lua
-- Module   : UART 链路恢复 / qryHostStat / resetHostLink，由 hu_ipc.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, H)
    local state, SYS_EVT = C.state, C.SYS_EVT
    local loader = C.loader
    local modCall = C.modCall
    local usbInserted = C.usbInserted
    local noopIdle = C.noopIdle
    local getCfg = H.getCfg
    local hostQuery = H.hostQuery
    local pushUsbIdle = C.pushUsbIdle

    local TIMEOUT = {
        powerOffMs = 500,
        powerOnWaitMs = 800,
        statusQueryMs = 2000,
    }

    local LIMITS = {
        missThreshold = 5,
        maxAttempts = 3,
        cooldownSec = 30,
    }

    ----------------------------------------------------------------
    -- cfg / miss streak
    ----------------------------------------------------------------

    local function ipcCfg()
        return getCfg("HOST_IPC_CFG")
    end

    local function recoveryCfg()
        local c = ipcCfg()
        local r = c.uart_recovery
        if type(r) ~= "table" then
            r = {}
        end
        return {
            enabled = r.enabled ~= false and c.enabled ~= false,
            miss_threshold = tonumber(r.miss_threshold) or LIMITS.missThreshold,
            max_attempts = tonumber(r.max_attempts) or LIMITS.maxAttempts,
            cooldown_sec = tonumber(r.cooldown_sec) or LIMITS.cooldownSec,
            power_off_ms = tonumber(r.power_off_ms) or TIMEOUT.powerOffMs,
            power_on_wait_ms = tonumber(r.power_on_wait_ms) or TIMEOUT.powerOnWaitMs,
        }
    end

    local function clearMissStreak()
        state.ipc_uart_miss_streak = 0
    end
    local noteUartLinkOk = clearMissStreak

    ----------------------------------------------------------------
    -- power cycle / UART recovery
    ----------------------------------------------------------------

    local function powerCycleHost()
        local rc = recoveryCfg()
        local t3x = loader.load("t3x_ctrl")
        if not t3x then
            return false
        end
        local st = modCall("t3x_ctrl", "getState")
        if st ~= nil and st.powered_on == true then
            t3x.powerOff()
            sys.wait(rc.power_off_ms)
        end
        t3x.powerOn()
        sys.wait(rc.power_on_wait_ms)
        t3x.pulseMcuInt()
        if usbInserted() then
            pushUsbIdle(true)
        end
        state.uart_recovery_last_sec = os.time()
        clearMissStreak()
        return true
    end

    local function recoveryCooldownActive(rc)
        local last = tonumber(state.uart_recovery_last_sec) or 0
        return last > 0 and (os.time() - last) < rc.cooldown_sec
    end

    local function tryUartRecovery(_source)
        local rc = recoveryCfg()
        if rc.enabled ~= true then
            return
        end
        if state.host_ready_seen ~= true then
            return
        end
        if state.host_at_ready then
            return
        end
        if not usbInserted() then
            clearMissStreak()
            return
        end
        if state.uart_recovery_busy then
            return
        end
        state.ipc_uart_miss_streak = (tonumber(state.ipc_uart_miss_streak) or 0) + 1
        if state.ipc_uart_miss_streak < rc.miss_threshold then
            return
        end
        if state.uart_recovery_attempts >= rc.max_attempts then
            return
        end
        if recoveryCooldownActive(rc) then
            return
        end
        state.uart_recovery_busy = true
        state.uart_recovery_attempts = state.uart_recovery_attempts + 1
        sys.taskInit(function()
            pcall(powerCycleHost)
            state.uart_recovery_busy = false
        end)
    end

    local function resetHostLink()
        state.host_at_ready = false
        state.first_host_at = nil
        state.host_ipc_status = nil
        state.host_ipc_cloud_stat = nil
        clearMissStreak()
    end

    local function onIpcStatusResponse(got, st)
        if got and st then
            noteUartLinkOk()
            state.host_ipc_status = st
            return st
        end
        state.host_ipc_status = "idle"
        tryUartRecovery("ipc_status")
        return "idle"
    end

    ----------------------------------------------------------------
    -- IPC STATUS QUERY
    ----------------------------------------------------------------

    local function qryHostStat(timeoutMs)
        return hostQuery(timeoutMs, {
            busyKey = "ipc_status_query_busy",
            busyReturn = state.host_ipc_status or "idle",
            policyTag = "host_ipc",
            cfg = ipcCfg(),
            timeoutCfgKey = "status_query_timeout_ms",
            defaultTimeout = TIMEOUT.statusQueryMs,
            waitBoot = false,
            atCmd = "AT+IPCSTATUS?",
            ackEvent = SYS_EVT.IPCSTATUS_ACK,
            defaultResult = "idle",
            whenDisabled = function(cfg)
                if cfg.enabled == false then
                    return state.host_at_ready and "ready" or "idle"
                end
            end,
            onNoT3x = noopIdle,
            onNoUart = noopIdle,
            onResponse = onIpcStatusResponse,
            onError = noopIdle,
        })
    end

    return {
        noteUartLinkOk = noteUartLinkOk,
        resetHostLink = resetHostLink,
        qryHostStat = qryHostStat,
    }
end

return _M
