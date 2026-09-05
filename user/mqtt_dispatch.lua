-- ================================================================
-- Filename : mqtt_dispatch.lua
-- Module   : 下行 JSON 分发 + HOSTEVT/USB 钩子，由 net_mqtt.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local isDownTopic = C.isDownTopic
    local handlers = C.handlers
    local pubAppEvent = C.pubAppEvent
    local callbacks = C.callbacks
    local logInfo = C.logInfo
    local logWarn = C.logWarn
    local logError = C.logError
    local flags = C.flags
    local state = C.state
    local isConnected = C.isConnected
    local pubStatus = C.pubStatus
    local drainHostQueue = C.drainHostQueue
    local maybePubIdentity = C.maybePubIdentity

    local HOST_DRAIN_WAIT = 500
    local EVT = APP_EVENTS

    ----------------------------------------------------------------
    -- 下行 JSON
    ----------------------------------------------------------------

    local function dispatchDl(topic, payload)
        if not isDownTopic(topic) then
            return
        end
        local ok, data = pcall(json.decode, payload)
        if not ok then
            logError("json_decode_error", data)
            return
        end
        local dataType
        if type(data) == "table" and data.dataType ~= nil then
            dataType = tostring(data.dataType)
        end
        logInfo("downlink", dataType or "nil", topic)
        if not dataType then
            logWarn("downlink_missing_datatype")
        else
            local handler = handlers and handlers[dataType]
            if handler then
                handler(data)
            else
                logWarn("downlink_unknown_datatype", dataType)
            end
        end
        pubAppEvent("MQTT_SERVER_DATA", data, payload)
        if callbacks.onMessage then
            callbacks.onMessage(topic, payload)
        end
    end

    local function onServerMsg(topic, payload)
        sys.taskInit(function()
            dispatchDl(topic, payload)
        end)
    end

    ----------------------------------------------------------------
    -- 订阅钩子（只挂一次）
    ----------------------------------------------------------------

    local function hookOnce(holder, key, event, fn)
        if holder[key] then
            return
        end
        holder[key] = true
        sys.subscribe(event, fn)
    end

    local function hookHostDrain()
        hookOnce(flags, "hostDrainHooked", EVT.HOST_UART_FIRST_AT, function()
            maybePubIdentity()
            sys.taskInit(function()
                sys.wait(HOST_DRAIN_WAIT)
                drainHostQueue()
            end)
        end)
    end

    local function hookUsbRec()
        hookOnce(state, "usb_rec_subd", EVT.MQTT_USB_RECOVERY_CHANGED, function()
            if isConnected() then
                sys.taskInit(pubStatus)
            end
        end)
    end

    return {
        -- 分发
        dispatchDl = dispatchDl,
        onServerMsg = onServerMsg,
        -- 钩子
        hookHostDrain = hookHostDrain,
        hookUsbRec = hookUsbRec,
    }
end

return _M
