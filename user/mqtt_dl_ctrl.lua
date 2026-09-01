-- ================================================================
-- Filename : mqtt_dl_ctrl.lua
-- Module   : MQTT 2004 下行控制，由 mqtt_downlink.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================
--
-- reboot / off / ota / wled_query / wled_set
--

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

function bind(C, shared)
    local loader = C.loader
    local rntmPwr = C.rntmPwr
    local hostUart = C.hostUart
    local pubAppEvent = C.pubAppEvent
    local mqttInfo = C.mqttInfo
    local mqttWarn = C.mqttWarn
    local utils = C.utils
    local getWledState = C.getWledState
    local pubCtrlReply = C.M.pubCtrlReply
    local dlMsgId = shared.dlMsgId

    local TIMEOUT = {
        wledQuery = 2000,
        rebootDelay = 800,
        powerOffDelay = 800,
    }

    ----------------------------------------------------------------
    -- 通用
    ----------------------------------------------------------------

    local function usbBlocks4g()
        local uc = loader.load("usb_charge")
        if uc then
            return uc.blocks4gRest()
        end
        return rntmPwr.isUsbInserted()
    end

    local function buildReply(data)
        local action = data.action
        local messageId = dlMsgId(data)
        return function(ret, msg, act, extraFields)
            local extra = { messageId = messageId }
            if type(extraFields) == "table" then
                for k, v in pairs(extraFields) do
                    extra[k] = v
                end
            end
            pubCtrlReply(act or action, ret, msg, extra)
        end
    end

    local function normAction(action)
        if action == nil then
            return action
        end
        return ACTION_ALIASES[tostring(action)] or tostring(action)
    end

    local function resolveAction(action, data)
        if action == "wled_query" or action == "wled?" then
            return "wled_query"
        end
        if action == "wled" and (data.query == 1 or data.query == true) then
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

    local function parseWledEnable(action, data)
        if action == "wled_on" then
            return 1
        end
        if action == "wled_off" then
            return 0
        end
        return tonumber(data.enable)
    end

    local function runWledQuery(reply)
        sys.taskInit(function()
            local on = getWledState()
            local hu = hostUart()
            if hu and hu.isHostAtReady() then
                on = hu.qryHostWled(TIMEOUT.wledQuery) or on
            end
            reply(0, "ok", "wled", { enable = on })
        end)
    end

    local function runWledSet(reply, on)
        local hu = hostUart()
        if hu then
            hu.setWledState(on, { forward = false })
        else
            rntmPwr.setWledOn(on)
        end
        reply(0, "ok", "wled", { enable = on })
        sys.taskInit(function()
            if hu then
                hu.setWledState(on)
            end
        end)
    end

    ----------------------------------------------------------------
    -- ota
    ----------------------------------------------------------------

    local function resolveOtaUrl(data)
        local url = data.url or data.otaUrl or data.firmwareUrl
        if url and url ~= "" then
            return url
        end
        local cfg = utils.optTable(_G.FOTA_CFG)
        local mode = string.lower(tostring(cfg.server_mode or "self"))
        if mode == "self" or mode == "custom" then
            return _G.resFotaUrl()
        end
        return url
    end

    local function validateOtaVersion(data)
        if not _G.valBuildVer then
            return true
        end
        local v = data.version
        if not v or v == "" then
            return true
        end
        local ok = _G.valBuildVer(tostring(v))
        if not ok then
            return false
        end
        data.version = ok
        mqttInfo("ota_version_valid", "version=" .. tostring(ok))
        return true
    end

    local function runOta(data, reply)
        data.url = resolveOtaUrl(data)
        mqttInfo("downlink_2004_ota",
            "action=ota version=" .. tostring(data.version or "")
            .. " url=" .. tostring(data.url or "")
            .. " product_key=" .. tostring(data.product_key or "")
            .. " messageId=" .. dlMsgId(data))
        if not validateOtaVersion(data) then
            mqttWarn("ota_invalid_version", "version=" .. tostring(data.version))
            reply(-1, "invalid_version_format", "ota")
            return
        end
        reply(0, "ota_accepted", "ota")
        mqttInfo("ota_accepted", "preparing OTA update")
        pubAppEvent("DEVICE_OTA_REQUEST", data)
    end

    ----------------------------------------------------------------
    -- 2004 handlers
    ----------------------------------------------------------------

    local CTRL_ACTIONS = {
        reboot = function(_data, reply)
            reply(0, "ok", "reboot")
            sys.timerStart(function()
                sys.publish(APP_EVENTS.DEVICE_REBOOT_REQUEST)
            end, TIMEOUT.rebootDelay)
        end,
        off = function(_data, reply)
            if usbBlocks4g() then
                reply(-1, "usb_block", "off")
                return
            end
            reply(0, "ok", "off")
            sys.timerStart(function()
                sys.publish(APP_EVENTS.DEVICE_POWER_OFF_REQUEST)
            end, TIMEOUT.powerOffDelay)
        end,
        ota = runOta,
        wled_query = function(_data, reply)
            runWledQuery(reply)
        end,
        wled_set = function(data, reply)
            local on = parseWledEnable(data.action, data)
            if on ~= 0 and on ~= 1 then
                reply(-1, "invalid_wled", "wled")
                return
            end
            runWledSet(reply, on)
        end,
    }

    local function dlControl(data)
        data.action = normAction(data.action)
        local reply = buildReply(data)
        local fn = CTRL_ACTIONS[resolveAction(data.action, data)]
        if fn then
            fn(data, reply)
            return
        end
        reply(-1, "unknown_action", data.action or "")
    end

    return { dlControl = dlControl }
end

return _M
