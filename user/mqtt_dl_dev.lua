-- ================================================================
-- Filename : mqtt_dl_dev.lua
-- Module   : MQTT 2002 rest / 2003 status / 2006 identity，由 mqtt_downlink.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================

require "sys"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, shared)
    local hostUart = C.hostUart
    local pub = C.pub
    local dlMsgId = shared.dlMsgId
    local ctrlMsg = shared.ctrlMsg
    local setStatIv = C.setStatIv

    local ID_DELAY_MS = 500

    ----------------------------------------------------------------
    -- 2006 设备身份
    ----------------------------------------------------------------

    local identityPublished = false
    local identityAutoHooked = false

    local function identityCfg()
        return cfgm.get("HOST_IDENTITY_CFG")
    end

    local function idEnabled()
        return identityCfg().enabled ~= false
    end

    local function refDevId(messageId)
        local cfg = identityCfg()
        local imei = C.getDeviceId()
        local gb28181Id
        local hu = hostUart()
        if hu then
            gb28181Id = hu.qryGb28181(cfg.query_timeout_ms)
                or hu.getCachedHostGb28181Id()
        end
        pub.pubDeviceId(imei, gb28181Id, messageId)
    end

    local function maybePubIdentity()
        local cfg = identityCfg()
        if not idEnabled() or cfg.auto_publish_on_ready == false then
            return
        end
        if identityPublished or not C.isConnected() then
            return
        end
        local hu = hostUart()
        if not hu or not hu.isHostAtReady() then
            return
        end
        identityPublished = true
        sys.taskInit(function()
            sys.wait(tonumber(cfg.auto_publish_delay_ms) or ID_DELAY_MS)
            refDevId(nil)
        end)
    end

    local function setupIdAutoPub()
        if identityAutoHooked or not idEnabled() then
            return
        end
        identityAutoHooked = true
        sys.subscribe(APP_EVENTS.MQTT_CONNECTED, function()
            maybePubIdentity()
        end)
    end

    ----------------------------------------------------------------
    -- 2002 rest / 2003 status
    ----------------------------------------------------------------

    local function resolveRestMode(data)
        local mode = data.lowPowerMode
        if mode == "enter" or mode == "exit" then
            return mode
        end
        local action = tonumber(data.action)
        if action == 1 then
            return "enter"
        end
        if action == 0 then
            return "exit"
        end
        return nil
    end

    local REST_SPEC = {
        enter = { reply = "rest_enter", event = APP_EVENTS.POWER_ENTER_REST },
        exit = { reply = "rest_exit", event = APP_EVENTS.POWER_EXIT_REST },
    }

    local function dlRest(data)
        local spec = REST_SPEC[resolveRestMode(data)]
        local messageId = dlMsgId(data)
        if spec then
            ctrlMsg(spec.reply, messageId, 0, "ok")
            sys.publish(spec.event)
        else
            ctrlMsg("rest", messageId, -1, "invalid_mode")
        end
    end

    local function handleUsbRecoveryReset(data)
        local hu = hostUart()
        local ok = hu and hu.rstUsbRecover() or false
        pub.pubStatus({
            messageId = dlMsgId(data),
            configRet = ok and 0 or -1,
            configMsg = ok and "usb_recovery_reset" or "usb_recovery_reset_fail",
        })
    end

    local function dlStatus(data)
        if data.usbRecoveryReset == 1 or data.action == "usbRecoveryReset" then
            handleUsbRecoveryReset(data)
            return
        end
        local configRet, configMsg = 0, "ok"
        if data.interval ~= nil and not setStatIv(data.interval, true) then
            configRet, configMsg = -1, "invalid_interval"
        end
        pub.pubStatus({
            messageId = dlMsgId(data),
            configRet = configRet,
            configMsg = configMsg,
        })
    end

    return {
        dlRest = dlRest,
        dlStatus = dlStatus,
        refDevId = refDevId,
        maybePubIdentity = maybePubIdentity,
        setupIdAutoPub = setupIdAutoPub,
        idEnabled = idEnabled,
    }
end

return _M
