-- ================================================================
-- Filename : hif_cmd.lua
-- Module   : AT 命令分发编排（L1），子模块见 hif_cmd_*
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- 绑定契约：bind(C) 返回 { at, hexLine, strLine, wledGet, api }；
--   · at        → 交给 hif_at.compile 生成查表（host_uart 用于分发）
--   · hexLine / strLine → "HEX:" / "STR:" 行 handler
--   · 对外 API 返回 api 表，由 host_uart 在单一处合并到 _M（C.M）
--
-- 子模块：usb / link / pir / t31x / wled；其余 AT 在主文件内联
-- （TIME / IMEI / GETCFG / HOSTIDLE / LOWPOWER / REBOOT / …）。
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local cfgm = require "config_manager"
    local state = C.state
    local hooks = C.hooks
    local E = C.E
    local rspOnly = C.rspOnly
    local rspBody = C.rspBody
    local rspFmt = C.rspFmt
    local rspLine = C.rspLine
    local okTail = C.okTail
    local modCall = C.modCall
    local utils = C.utils
    local usbInserted = C.usbInserted
    local usbBlockHost = C.usbBlockHost
    local configSnap = C.configSnap
    local decodeHex = utils.decodeHex
    local RSP_ERROR = C.RSP_ERROR

    local TIMEOUT = {
        hookDefer = 500,
    }

    local HOST_IDLE = {
        enter = "AT+HOSTIDLE=1",
        exit = "AT+HOSTIDLE=0",
        query = "AT+HOSTIDLE?",
    }

    ----------------------------------------------------------------
    -- 子模块
    ----------------------------------------------------------------

    local usb = require("hif_cmd_usb").bind(C)
    local link = require("hif_cmd_link").bind(C)
    local pir = require("hif_cmd_pir").bind(C)
    local t31x = require("hif_cmd_t31x").bind(C)
    local wled = require("hif_cmd_wled").bind(C)

    ----------------------------------------------------------------
    -- 通用 helper
    ----------------------------------------------------------------

    local function devImei()
        return modCall("device_id", "getImei")
    end

    local function scheduleHook(hook)
        if hook then
            sys.timerStart(hook, TIMEOUT.hookDefer)
        end
    end

    local function hostIdleOk()
        return rspBody("HOSTIDLE", "OK")
    end

    local function hostIdleAllowed()
        return not usbBlockHost() and modCall("battery_guard", "shouldHostSleep") == true
    end

    local function checkHostIdleGate()
        if cfgm.get("FEATURE_CFG").host_evt == false then
            return rspOnly("HOSTIDLE", "NOT_SUPPORTED")
        end
        if cfgm.get("HOST_EVT_CFG").allow_host_idle_sleep == false then
            return rspOnly("HOSTIDLE", "DISABLED")
        end
        return nil
    end

    ----------------------------------------------------------------
    -- 内联 AT handler
    ----------------------------------------------------------------

    local function atAck(_cmd)
        return okTail()
    end

    local function atTime(_cmd)
        local minTs = (_G.TIME_SYNC_CFG and _G.TIME_SYNC_CFG.min_valid_unix) or utils.MIN_VALID_UNIX
        local t = os.time()
        if t < minTs then
            return rspBody("TIME", "0")
        end
        return rspFmt("TIME", "%d", t)
    end

    local function atImei(_cmd)
        local imei = devImei()
        if not imei then
            return RSP_ERROR
        end
        return rspFmt("IMEI", "%s", imei)
    end

    local function atGetCfg(_cmd)
        local s = configSnap()
        return rspFmt(
            "GETCFG",
            "version=%s,online=%d,power=%d,lowpower=%d,battery=%s,vbat=%s,interval=%d,devicemodel=%s,wled=%d,workmode=%s%s",
            s.version, s.online, s.power, s.lowpower, s.battery, s.vbat, s.interval,
            s.devicemodel, s.wled or 0, s.workmode or "person_detect", s.tcp_extra or "")
    end

    local function atHostIdle(cmd)
        local blocked = checkHostIdleGate()
        if blocked then
            return blocked
        end
        local isSet = cmd == HOST_IDLE.enter or cmd == HOST_IDLE.exit
        if isSet and usbBlockHost() then
            return cmd == HOST_IDLE.exit and hostIdleOk() or rspOnly("HOSTIDLE", "USB")
        end
        if pir.bldPirWake(true):match("has_event=1") then
            return rspOnly("HOSTIDLE", "BUSY")
        end
        if cmd == HOST_IDLE.query then
            return rspFmt(
                "HOSTIDLE", "lowpower=%d,usb=%d,host_idle_allow=%d",
                modCall("runtime_power", "isLowPowerMode") and 1 or 0,
                usbInserted() and 1 or 0,
                hostIdleAllowed() and 1 or 0) .. okTail()
        end
        if not isSet then
            return nil
        end
        if cmd == HOST_IDLE.exit then
            return hostIdleOk()
        end
        if modCall("battery_guard", "shouldHostSleep") == false
            or modCall("battery_guard", "canHostSleep") == false then
            return rspOnly("HOSTIDLE", "BUSY")
        end
        local lp = cfgm.get("LOW_POWER_CFG")
        sys.taskInit(function()
            modCall("t31x_ctrl", "enterSleep", {
                modemHibernate = lp.modem_hibernate == true,
                reason = "host_idle",
                skipPendingWorkCheck = true,
            })
        end)
        return hostIdleOk()
    end

    local function atRecordQry(_cmd)
        local rec = modCall("pir_ctrl", "isRecording") and 1 or 0
        return rspFmt("RECORD", "%d,reason=%s,active=%d",
            rec, state.t31x_last_reason or "idle", state.t31x_rec_active or 0)
    end

    local function atVersion(_cmd)
        return rspFmt("CGMR", "%s", configSnap().version)
    end

    local function atRil(cmd)
        local n = tonumber(cmd:match("^AT%+RIL=(%d+)$"))
        if n == nil then
            return RSP_ERROR
        end
        state.passthrough = (n == 1)
        return rspFmt("RIL_PERSONCNT", "%d", n)
    end

    local function atSend(cmd, pat, fn, extra)
        local payload = cmd:match(pat)
        if not payload or not fn then
            return rspLine("SEND", false)
        end
        local ok
        if extra then
            ok = fn(payload, extra)
        else
            ok = fn(payload)
        end
        return rspLine("SEND", ok and true or false)
    end

    local function atSendStr(cmd)
        return atSend(cmd, "^AT%+SENDSTR=(.+)$", hooks.sendString, true)
    end

    local function atSendHex(cmd)
        return atSend(cmd, "^AT%+SENDHEX=(.+)$", hooks.sendHex)
    end

    local function atLowPower(cmd)
        local fc = _G.FEATURE_CFG
        if fc and fc.low_power == false then
            return rspOnly("LOWPOWER", "NOT_SUPPORTED")
        end
        local inLp = modCall("runtime_power", "isLowPowerMode")
        if cmd == "AT+LOWPOWER=ENTER" then
            if inLp then
                return rspOnly("LOWPOWER", "BUSY")
            end
            if hooks.onEnterLowPower then
                hooks.onEnterLowPower()
            end
            return rspOnly("LOWPOWER", "ENTERING")
        end
        if cmd == "AT+LOWPOWER=EXIT" then
            if not inLp then
                return rspOnly("LOWPOWER", "ALREADY_AWAKE")
            end
            if hooks.onExitLowPower then
                hooks.onExitLowPower()
            end
            return rspOnly("LOWPOWER", "WAKEUP")
        end
        return nil
    end

    local function atReboot(_cmd)
        scheduleHook(hooks.onReboot)
        return rspLine("REBOOT", true)
    end

    local function atPowerOff(_cmd)
        scheduleHook(hooks.onPowerOff)
        return rspLine("POWEROFF", true)
    end

    local function atOta(_cmd)
        if hooks.onOta then
            hooks.onOta()
        else
            sys.publish(E.DEVICE_OTA_REQUEST, {})
        end
        return rspOnly("OTA", "STARTING")
    end

    local function atSetCfg(cmd)
        local key, val = cmd:match("^AT%+SETCFG=([^,]+),(.+)$")
        if not key or not val then
            return rspLine("SETCFG", false)
        end
        if key == "interval" and tonumber(val) then
            local ok = modCall("net_mqtt", "setStatInterval", tonumber(val), true)
            if ok == nil then
                modCall("runtime_power", "setLowPowerInterval", tonumber(val))
                sys.publish(E.MQTT_STATUS_INTERVAL_CHANGED)
            elseif not ok then
                return rspLine("SETCFG", false)
            end
            return rspLine("SETCFG", true)
        end
        if key == "devicemodel" and _G.APP_META then
            _G.APP_META.device_model = val
            return rspLine("SETCFG", true)
        end
        if key == "hexrpt" then
            state.hex_report = (val == "1" or val == "true" or val == "on")
            return rspLine("SETCFG", true)
        end
        return rspLine("SETCFG", false)
    end

    ----------------------------------------------------------------
    -- HEX/STR 行 handler
    ----------------------------------------------------------------

    local function hexLine(line)
        local hex = line:match("^[Hh][Ee][Xx]:(.*)$")
        if not hex or not hooks.uartWrite then
            return rspLine("HEX", false)
        end
        local bin = decodeHex(hex)
        if not bin then
            return rspLine("HEX", false)
        end
        hooks.uartWrite(bin)
        return rspLine("HEX", true)
    end

    local function strLine(line)
        local text = line:match("^[Ss][Tt][Rr]:(.*)$")
        local ok = text and hooks.sendString and hooks.sendString(text, true) or false
        return rspLine("STR", ok)
    end

    ----------------------------------------------------------------
    -- AT 表 + export
    ----------------------------------------------------------------

    ----------------------------------------------------------------
    -- 跨编排器共享状态（留 ctx，供 hif_rx 等复用；非 host_uart 公开 API）
    --   · C.wled*        ：wled 运行时状态/接口
    --   · C.ipcReadyFrom ：t31x IPC 就绪判定
    ----------------------------------------------------------------
    C.wledState = wled.wledRt
    C.wledExport = wled.wledExport
    C.wledGet = wled.wledGet
    C.ipcReadyFrom = t31x.ipcReadyFrom

    -- AT 命令表：命令名 → handler（来自内联或子模块），交 hif_at.compile 生成查表
    local at = {
        at_ack = atAck,
        ati = atVersion,
        getcfg = atGetCfg,
        pirstat = pir.uartPirStatQry,
        pirclr = pir.uartPirClr,
        record_qry = atRecordQry,
        record = t31x.uartRecord,
        ipcstatus = t31x.uartIpcStatusNtf,
        ipcstat = t31x.uartIpcStatNtf,
        tfcard = t31x.uartTfCardNtf,
        snapshot = t31x.uartSnapshot,
        pirmedia = t31x.uartPirMedia,
        personcnt = t31x.uartPersonCnt,
        ipcalert = t31x.uartIpcAlert,
        uploadneed = t31x.uartUploadNeed,
        uploadresult = t31x.uartUploadResult,
        hostevt = pir.uartHostEvtQry,
        hostevtclr = pir.uartHostEvtClr,
        time = atTime,
        imei = atImei,
        ipcinfo = link.uartIpcInfoQry,
        mqttpub = link.uartMqttPub,
        wled = wled.uartWled,
        servcreate = link.uartServCreate,
        mqttcfg = link.uartMqttCfg,
        p2pcfg = link.uartP2pCfg,
        gb28181 = link.uartGb28181,
        servclose = link.uartServClose,
        ril = atRil,
        sendstr = atSendStr,
        sendhex = atSendHex,
        lowpower = atLowPower,
        hostidle = atHostIdle,
        rndis = usb.uartRndis,
        usbreset = usb.uartUsbReset,
        usbrecovery = usb.uartUsbRecover,
        reboot = atReboot,
        poweroff = atPowerOff,
        ota = atOta,
        setcfg = atSetCfg,
    }

    -- 对外 API：返回 api 表，由 host_uart 在单一处合并到 _M（C.M）
    local pub = {
        devImei = devImei,
        bldHostEvtBody = pir.bldHostEvtBody,
        getHostEvtPending = C.getHostEvtPending,
        wledState = wled.wledState,
        setWledState = wled.setWledState,
        qryHostWled = wled.qryHostWled,
        rstUsbRecover = usb.rstUsbRecover,
        uartIpcStatusNtf = t31x.uartIpcStatusNtf,
        uartIpcStatNtf = t31x.uartIpcStatNtf,
        uartTfCardNtf = t31x.uartTfCardNtf,
    }

    return {
        at = at,
        hexLine = hexLine,
        strLine = strLine,
        wledGet = wled.wledGet,
        api = pub,
    }
end

return _M
