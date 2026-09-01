-- ================================================================
-- Filename : mqtt_dispatch.lua
-- Module   : 下行 JSON 分发 + HOSTEVT/USB 订阅钩子，由 net_mqtt.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================
--
-- 结构：JSON 解析 → handler 表驱动 → 订阅钩子（首 AT / USB 恢复）
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local isDlTopic = C.isDlTopic
    local getHandlers = C.getDownlinkHandlers
    local pubAppEvent = C.pubAppEvent
    local callbacks = C.callbacks
    local mqttInfo = C.mqttInfo
    local mqttWarn = C.mqttWarn
    local mqttError = C.mqttError
    local flags = C.flags
    local state = C.state
    local isConnected = C.isConnected
    local pubStatus = C.pubStatus
    local drainHostQueue = C.drainHostQueue
    local maybePubIdentity = C.maybePubIdentity

    local TIMEOUT = {
        hostDrainWait = 500,
    }

    local EVT = APP_EVENTS

    ----------------------------------------------------------------
    -- 下行 JSON
    ----------------------------------------------------------------

    local function decodeDownlink(payload)
        local ok, data = pcall(json.decode, payload)
        if not ok then
            mqttError("json_decode_error", data)
            return nil
        end
        return data
    end

    local function downlinkDataType(data)
        if type(data) ~= "table" or data.dataType == nil then
            return nil
        end
        return tostring(data.dataType)
    end

    local function runDownlinkHandler(dataType, data)
        if not dataType then
            mqttWarn("downlink_missing_datatype")
            return
        end
        local handlers = getHandlers()
        local handler = handlers and handlers[dataType]
        if handler then
            handler(data)
        else
            mqttWarn("downlink_unknown_datatype", dataType)
        end
    end

    local function notifyDownlinkObservers(topic, payload, data)
        pubAppEvent("MQTT_SERVER_DATA", data, payload)
        if callbacks.onMessage then
            callbacks.onMessage(topic, payload)
        end
    end

    local function dispatchDl(topic, payload)
        if not isDlTopic(topic) then
            return
        end
        local data = decodeDownlink(payload)
        if not data then
            return
        end
        local dataType = downlinkDataType(data)
        mqttInfo("downlink", dataType or "nil", topic)
        runDownlinkHandler(dataType, data)
        notifyDownlinkObservers(topic, payload, data)
    end

    local function onServerMsg(topic, payload)
        sys.taskInit(function()
            dispatchDl(topic, payload)
        end)
    end

    ----------------------------------------------------------------
    -- 订阅钩子
    ----------------------------------------------------------------

    local function onHostFirstAt()
        if maybePubIdentity then
            maybePubIdentity()
        end
        sys.taskInit(function()
            sys.wait(TIMEOUT.hostDrainWait)
            drainHostQueue()
        end)
    end

    local function hookHostDrain()
        if flags.hostDrainHooked then
            return
        end
        flags.hostDrainHooked = true
        sys.subscribe(EVT.HOST_UART_FIRST_AT, onHostFirstAt)
    end

    local function hookUsbRec()
        if state.usb_rec_subd then
            return
        end
        state.usb_rec_subd = true
        sys.subscribe(EVT.MQTT_USB_RECOVERY_CHANGED, function()
            if isConnected() then
                sys.taskInit(function()
                    pubStatus()
                end)
            end
        end)
    end

    return {
        dispatchDl = dispatchDl,
        onServerMsg = onServerMsg,
        hookHostDrain = hookHostDrain,
        hookUsbRec = hookUsbRec,
    }
end

return _M
