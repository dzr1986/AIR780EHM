-- ================================================================
-- Filename : hu_ipc_power.lua
-- Module   : hostIpcPowerOff / waitHostIpcReady，由 hu_ipc.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, H)
    local state, SYS_EVT = C.state, C.SYS_EVT
    local uartAcquire, uartRelease = C.uartAcquire, C.uartRelease
    local waitHostIdle = C.waitHostIdle
    local uart_bridge = C.uart_bridge
    local hostNowMs = C.hostNowMs
    local patchCloud = C.patchCloud
    local getCfg = H.getCfg
    local qryHostStat = H.qryHostStat

    local TIMEOUT = {
        powerOffFloorMs = 5000,
        acquireCapMs = 8000,
        busyClearCapMs = 3000,
        hostIdleCapMs = 2000,
        pollSliceMs = 50,
        sendGapMs = 40,
        retryGapMs = 2000,
        sliceFloorMs = 20,
        readyDefaultMs = 120000,
        readyPollMs = 1000,
        statusQueryMs = 2000,
    }

    ----------------------------------------------------------------
    -- cfg / busy gate
    ----------------------------------------------------------------

    local function ipcCfg()
        return getCfg("HOST_IPC_CFG")
    end

    local function clampTimeout(ms, fallback, floorMs)
        ms = tonumber(ms) or tonumber(fallback) or floorMs
        if ms < floorMs then
            ms = floorMs
        end
        return ms
    end

    local function buildPowerOffAt(playSound)
        return (playSound == false) and "AT+IPCPOWEROFF=0" or "AT+IPCPOWEROFF=1"
    end

    local function ipcQueryBusy()
        return state.record_query_busy or state.ipc_status_query_busy
            or state.ipc_cloud_stat_query_busy or state.uart_recovery_busy
    end

    local function powerOffAckOk(val)
        return val == true or (type(val) == "table" and val.ok == true)
    end

    local function applyPowerOffSuccess()
        state.host_ipc_status = "idle"
        state.t3x_rec_active = 0
        patchCloud({ recordingT3x = 0, ipcReady = 0 })
    end

    local function waitBusyClear(deadlineMs)
        local untilMs = hostNowMs() + deadlineMs
        while hostNowMs() < untilMs do
            if ipcQueryBusy() then
                sys.wait(TIMEOUT.pollSliceMs)
            else
                break
            end
        end
    end

    local function logPowerOffRx(tag, line)
        if log and log.info then
            log.info("host_uart", "ipcpoweroff_rx", tag, line or "error")
        end
    end

    ----------------------------------------------------------------
    -- IPCPOWEROFF
    ----------------------------------------------------------------

    local function runPowerOffAt(cmd, timeoutMs)
        local deadline = hostNowMs() + timeoutMs
        local sends = 0
        local sawStage = false
        local function sendOnce()
            sends = sends + 1
            uart_bridge.sendString("", true)
            sys.wait(TIMEOUT.sendGapMs)
            uart_bridge.sendString(cmd, true)
        end
        sendOnce()
        local nextRetry = hostNowMs() + TIMEOUT.retryGapMs
        while hostNowMs() < deadline do
            local remain = deadline - hostNowMs()
            if remain <= 0 then
                break
            end
            local slice = remain
            if (not sawStage) and sends < 3 and (nextRetry - hostNowMs()) > 0 then
                slice = math.min(slice, nextRetry - hostNowMs())
            end
            if slice < TIMEOUT.sliceFloorMs then
                slice = TIMEOUT.sliceFloorMs
            end
            local got, val = sys.waitUntil(SYS_EVT.IPCPOWEROFF_ACK, slice)
            if got then
                if powerOffAckOk(val) then
                    return true
                end
                if type(val) == "table" and val.stage then
                    sawStage = true
                elseif type(val) == "table" and val.error == true then
                    if sawStage then
                        logPowerOffRx("ignore_err_after_stage", val.line)
                    else
                        logPowerOffRx("abort", val.line)
                        break
                    end
                end
            elseif (not sawStage) and sends < 3 and hostNowMs() >= nextRetry then
                sendOnce()
                nextRetry = hostNowMs() + TIMEOUT.retryGapMs
            end
        end
        return false
    end

    local function hostIpcPowerOff(playSound, timeoutMs)
        local cfg = ipcCfg()
        timeoutMs = clampTimeout(timeoutMs, cfg.poweroff_timeout_ms, TIMEOUT.powerOffFloorMs)
        if state.ipc_poweroff_busy then
            local got, val = sys.waitUntil(SYS_EVT.IPCPOWEROFF_ACK, timeoutMs)
            return got == true and powerOffAckOk(val)
        end
        if cfg.enabled == false or not uart_bridge.sendString then
            return false
        end
        state.ipc_poweroff_busy = true
        local success = false
        local ok = pcall(function()
            if not uartAcquire(math.min(timeoutMs, TIMEOUT.acquireCapMs)) then
                return
            end
            waitBusyClear(math.min(timeoutMs, TIMEOUT.busyClearCapMs))
            waitHostIdle(math.min(timeoutMs, TIMEOUT.hostIdleCapMs))
            success = runPowerOffAt(buildPowerOffAt(playSound), timeoutMs)
        end)
        uartRelease()
        state.ipc_poweroff_busy = false
        if success then
            applyPowerOffSuccess()
        end
        if not ok then
            return false
        end
        return success
    end

    ----------------------------------------------------------------
    -- HOST READY POLL
    ----------------------------------------------------------------

    local function readyTimedOut(deadline, startSec, timeoutMs)
        if deadline and mcu and mcu.ticks then
            return mcu.ticks() >= deadline
        end
        return (os.time() - startSec) * 1000 >= timeoutMs
    end

    local function waitHostIpcReady(timeoutMs, pollMs)
        local cfg = ipcCfg()
        if cfg.enabled == false then
            return state.host_at_ready == true
        end
        timeoutMs = tonumber(timeoutMs) or tonumber(cfg.ready_wait_timeout_ms) or TIMEOUT.readyDefaultMs
        pollMs = tonumber(pollMs) or tonumber(cfg.ready_poll_ms) or TIMEOUT.readyPollMs
        local deadline = (mcu and mcu.ticks and (mcu.ticks() + timeoutMs)) or nil
        local startSec = os.time()
        while true do
            local st = qryHostStat(tonumber(cfg.status_query_timeout_ms) or TIMEOUT.statusQueryMs)
            if st == "ready" then
                return true
            end
            if readyTimedOut(deadline, startSec, timeoutMs) then
                return false
            end
            sys.wait(pollMs)
        end
    end

    return {
        hostIpcPowerOff = hostIpcPowerOff,
        waitHostIpcReady = waitHostIpcReady,
    }
end

return _M
