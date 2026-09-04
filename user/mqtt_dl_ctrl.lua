-- ================================================================
-- Filename : mqtt_dl_ctrl.lua
-- Module   : MQTT 2004 控制：reboot / off / ota / wled，由 mqtt_downlink.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local ACTION_ALIASES = {
    restart = "reboot",
    shutdown = "off",
    poweroff = "off",
    upgrade = "ota",
    fota = "ota",
}

local WLED_ON = { wled_on = 1, wled_off = 0 }
local WLED_QRY_MS = 2000
local DELAY_MS = 800

function bind(C, shared)
    local loader = C.loader
    local power = C.power
    local hostUart = C.hostUart
    local pubAppEvent = C.pubAppEvent
    local logInfo = C.logInfo
    local logWarn = C.logWarn
    local utils = C.utils
    local getWledState = C.getWledState
    local pubCtrlReply = C.pub.pubCtrlReply
    local dlMsgId = shared.dlMsgId

    local usbCharge

    local function usbBlocks4g()
        if usbCharge == nil then
            usbCharge = loader.load("usb_charge") or false
        end
        if usbCharge then
            return usbCharge.blocks4gRest()
        end
        return power.isUsbInserted()
    end

    local function makeReply(data)
        local action = data.action
        local mid = dlMsgId(data)
        return function(ret, msg, act, extra)
            local out = { messageId = mid }
            if type(extra) == "table" then
                for k, v in pairs(extra) do
                    out[k] = v
                end
            end
            pubCtrlReply(act or action, ret, msg, out)
        end
    end

    local function laterPub(evt)
        sys.timerStart(function()
            sys.publish(evt)
        end, DELAY_MS)
    end

    local function normAction(action)
        if action == nil then
            return action
        end
        return ACTION_ALIASES[tostring(action)] or tostring(action)
    end

    local function resolveAction(action, data)
        if action == "wled_query" or action == "wled?"
            or (action == "wled" and (data.query == 1 or data.query == true)) then
            return "wled_query"
        end
        if action == "wled" or action == "wled_on" or action == "wled_off" then
            return "wled_set"
        end
        return action
    end

    ----------------------------------------------------------------
    -- wled
    ----------------------------------------------------------------

    local function wledQuery(reply)
        sys.taskInit(function()
            local on = getWledState()
            local hif = hostUart()
            if hif and hif.isHostAtReady() then
                on = hif.qryHostWled(WLED_QRY_MS) or on
            end
            reply(0, "ok", "wled", { enable = on })
        end)
    end

    local function wledSet(reply, on)
        local hif = hostUart()
        if hif then
            hif.setWledState(on, { forward = false })
        else
            power.setWledOn(on)
        end
        reply(0, "ok", "wled", { enable = on })
        sys.taskInit(function()
            if hif then
                hif.setWledState(on)
            end
        end)
    end

    ----------------------------------------------------------------
    -- ota
    ----------------------------------------------------------------

    local function otaUrl(data)
        local url = data.url or data.otaUrl or data.firmwareUrl
        if url and url ~= "" then
            return url
        end
        local mode = string.lower(tostring(utils.optTable(_G.FOTA_CFG).server_mode or "self"))
        if mode == "self" or mode == "custom" then
            return _G.resFotaUrl()
        end
        return url
    end

    local function otaVerOk(data)
        local fn, v = _G.validateBuildVersion, data.version
        if not fn or not v or v == "" then
            return true
        end
        local ok = fn(tostring(v))
        if not ok then
            return false
        end
        data.version = ok
        logInfo("ota_version_valid", "version=" .. tostring(ok))
        return true
    end

    local function runOta(data, reply)
        data.url = otaUrl(data)
        logInfo("downlink_2004_ota",
            "action=ota version=" .. tostring(data.version or "")
            .. " url=" .. tostring(data.url or "")
            .. " product_key=" .. tostring(data.product_key or "")
            .. " messageId=" .. dlMsgId(data))
        if not otaVerOk(data) then
            logWarn("ota_invalid_version", "version=" .. tostring(data.version))
            reply(-1, "invalid_version_format", "ota")
            return
        end
        reply(0, "ota_accepted", "ota")
        logInfo("ota_accepted", "preparing OTA update")
        pubAppEvent("DEVICE_OTA_REQUEST", data)
    end

    ----------------------------------------------------------------
    -- 2004
    ----------------------------------------------------------------

    local CTRL = {
        reboot = function(_, reply)
            reply(0, "ok", "reboot")
            laterPub(APP_EVENTS.DEVICE_REBOOT_REQUEST)
        end,
        off = function(_, reply)
            if usbBlocks4g() then
                reply(-1, "usb_block", "off")
                return
            end
            reply(0, "ok", "off")
            laterPub(APP_EVENTS.DEVICE_POWER_OFF_REQUEST)
        end,
        ota = runOta,
        wled_query = function(_, reply)
            wledQuery(reply)
        end,
        wled_set = function(data, reply)
            local on = WLED_ON[data.action]
            if on == nil then
                on = tonumber(data.enable)
            end
            if on ~= 0 and on ~= 1 then
                reply(-1, "invalid_wled", "wled")
                return
            end
            wledSet(reply, on)
        end,
    }

    local function dlControl(data)
        data.action = normAction(data.action)
        local reply = makeReply(data)
        local fn = CTRL[resolveAction(data.action, data)]
        if fn then
            fn(data, reply)
            return
        end
        reply(-1, "unknown_action", data.action or "")
    end

    return { dlControl = dlControl }
end

return _M
