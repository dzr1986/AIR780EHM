-- ================================================================
-- Filename : hu_cmd_usb.lua
-- Module   : AT+USBRESET/RNDIS/USBRECOVERY handler，由 hu_cmd.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local E = C.E
    local rspOnly, rspBody, rspFmt, rspLine, rspLineOk = C.rspOnly, C.rspBody, C.rspFmt, C.rspLine, C.rspLineOk
    local modCall, loader = C.modCall, C.loader
    local uart_bridge, CRLF = C.uart_bridge, C.CRLF
    local hostUsbCfg, usbInserted = C.hostUsbCfg, C.usbInserted
    local t3xSecOff = C.t3xSecOff
    local RSP_ERROR, LOG_TAG = C.RSP_ERROR, C.LOG_TAG
    local pushUsbIdle = C.pushUsbIdle

    local LIMITS = {
        bootGuardSec = 180,
        minIntervalSec = 120,
    }
    local TIMEOUT = {
        notifyAfterMs = 800,
        pulsePadMs = 20,
        rebindWaitMs = 500,
    }

    local usbRcvrGrd = {
        busy = false,
        last_sec = 0,
        count = 0,
    }

    ----------------------------------------------------------------
    -- guard / recovery state
    ----------------------------------------------------------------

    local function recoverSnap(st, extra)
        extra = extra or {}
        return {
            state = st,
            count = extra.count or usbRcvrGrd.count or 0,
            last_err = extra.err or "",
            usb_logical = extra.logical ~= nil and extra.logical or (usbInserted() and 1 or 0),
            usb_netdev = extra.netdev or 0,
        }
    end

    local function t3xRestBlock()
        local cfg = hostUsbCfg()
        if cfg.block_usb_reset_when_t3x_rest == false then
            return false
        end
        if not modCall("runtime_power", "isLowPowerMode") then
            return false
        end
        local st = modCall("t3x_ctrl", "getState")
        return st ~= nil and st.powered_on == false
    end

    local function usbRcvrAllow(cfg)
        if cfg.allow_t3x_usb_reset == false then
            return false, "DISABLED"
        end
        if usbRcvrGrd.busy then
            return false, "BUSY"
        end
        -- 开机保护：未 stable 或上电未满 guard 秒，禁止 USBRESET
        if modCall("usb_rndis", "isBootStable") == false then
            return false, "BOOT"
        end
        local guard = tonumber(cfg.usb_reset_boot_guard_sec) or LIMITS.bootGuardSec
        if guard > 0 and mcu and mcu.ticks then
            local ticks = tonumber(mcu.ticks()) or 0
            if ticks < (guard * 1000) then
                return false, "BOOT"
            end
        end
        local min_iv = tonumber(cfg.usb_reset_min_interval_sec) or LIMITS.minIntervalSec
        local now = os.time()
        if usbRcvrGrd.last_sec > 0 and (now - usbRcvrGrd.last_sec) < min_iv then
            return false, "BUSY"
        end
        if t3xRestBlock() then
            return false, "REST"
        end
        return true, nil
    end

    local function pushRecover(st, extra)
        modCall("runtime_power", "setUsbRecovery", recoverSnap(st, extra))
        sys.publish(E.MQTT_USB_RECOVERY_CHANGED)
    end

    local function usbRcvrExec(tag, cfg, do_fn)
        usbRcvrGrd.busy = true
        pushRecover("recovering")
        sys.taskInit(function()
            local notify_ms = tonumber(cfg.usb_reset_notify_after_ms) or TIMEOUT.notifyAfterMs
            local ok = false
            local task_ok, task_err = pcall(function()
                if do_fn then
                    ok = do_fn() and true or false
                end
            end)
            if not task_ok then
                log.error(LOG_TAG, tag, "task_crash", tostring(task_err))
                ok = false
            end
            if ok and cfg.notify_t3x_usb_state ~= false and usbInserted() then
                sys.wait(notify_ms)
                pushUsbIdle(1)
            end
            usbRcvrGrd.busy = false
            usbRcvrGrd.last_sec = os.time()
            usbRcvrGrd.count = (usbRcvrGrd.count or 0) + 1
            if not ok then
                pushRecover("idle", { err = "rebind_failed" })
            end
        end)
    end

    ----------------------------------------------------------------
    -- AT+USBRESET / AT+USBRECOVERY / AT+RNDIS
    ----------------------------------------------------------------

    local function uartUsbReset(cmd)
        local cfg = hostUsbCfg()
        if cmd == "AT+USBRESET?" then
            return string.format(
                CRLF .. "+USBRESET:busy=%d,count=%d,last=%d" .. CRLF,
                usbRcvrGrd.busy and 1 or 0,
                usbRcvrGrd.count or 0,
                usbRcvrGrd.last_sec or 0
            )
        end
        if cmd ~= "AT+USBRESET" then
            return RSP_ERROR
        end
        local allowed, deny = usbRcvrAllow(cfg)
        if not allowed then
            if deny == "REST" then
                pushRecover("blocked_rest", { err = "blocked_rest" })
            end
            return rspOnly("USBRESET", deny)
        end
        local usb_rndis = loader.load("usb_rndis")
        if not usb_rndis then
            return rspLine("USBRESET", false)
        end
        usbRcvrExec("USBRESET", cfg, function()
            local pulse_ms = 0
            local t3x = loader.load("t3x_ctrl")
            if t3x then
                local pok, _, pms = pcall(t3x.pulseUsbDebugEn, { highMs = cfg.usb_debug_en_pulse_ms })
                if pok and pms then
                    pulse_ms = tonumber(pms) or 0
                end
            end
            if pulse_ms > 0 then
                sys.wait(pulse_ms + TIMEOUT.pulsePadMs)
            end
            local rok, rret = pcall(usb_rndis.rebind, { waitMs = TIMEOUT.rebindWaitMs })
            if not rok then
                log.error(LOG_TAG, "usb_rebind_crash", tostring(rret))
                return false
            end
            return rret
        end)
        return rspBody("USBRESET", "OK")
    end

    local function uartUsbRecover(cmd)
        local state, count = cmd:match("^AT%+USBRECOVERY=([^,]+),(%d+)$")
        if not state then
            state = cmd:match("^AT%+USBRECOVERY=(%w+)$")
            count = 0
        end
        state = state and state:upper() or "IDLE"
        count = tonumber(count) or 0
        local stateLower = state:lower()
        local lastErr = (stateLower == "exhausted") and "netdev_missing" or ""
        pushRecover(stateLower, {
            count = count,
            logical = 1,
            netdev = stateLower == "ok" and 1 or 0,
            err = lastErr,
        })
        return rspBody("USBRECOVERY", state)
    end

    local function markIdleRecover()
        pushRecover("idle", { count = 0 })
        usbRcvrGrd.count = 0
    end

    local function rstUsbRecover()
        if t3xSecOff() then
            markIdleRecover()
            return false
        end
        uart_bridge.sendString("AT+USBRECOVERYRESET", true)
        markIdleRecover()
        return true
    end

    local function uartRndis(cmd)
        local usb_rndis = loader.load("usb_rndis")
        if not usb_rndis then
            return RSP_ERROR
        end
        if cmd == "AT+RNDIS?" or cmd == "AT+RNDIS" then
            local st = usb_rndis.getStatus and usb_rndis.getStatus() or {}
            return rspFmt(
                "RNDIS", "enabled=%d,mode=%s,status=%s,ip=%s,flymode=%s",
                st.enabled and 1 or 0,
                tostring(st.usb_ethernet_mode or "--"),
                tostring(st.status or "--"),
                tostring(st.ip or "--"),
                st.flymode == nil and "--" or (st.flymode and "1" or "0")
            )
        end
        local n = tonumber(cmd:match("^AT%+RNDIS=(%d+)$"))
        if n ~= 0 and n ~= 1 then
            return RSP_ERROR
        end
        sys.taskInit(function()
            if n == 1 then
                local fn = usb_rndis.open or usb_rndis.enable
                if fn then
                    fn()
                end
            elseif usb_rndis.disable then
                usb_rndis.disable()
            end
        end)
        return rspLineOk("RNDIS")
    end
    return {
        uartUsbReset = uartUsbReset,
        uartUsbRecover = uartUsbRecover,
        uartRndis = uartRndis,
        rstUsbRecover = rstUsbRecover,
    }
end

return _M
