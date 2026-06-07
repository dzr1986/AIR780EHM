--- 模块功能：MQTT 下行命令与 PIR 事件上报库
-- @module mqttCommand
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"
module(..., package.seeall)

local started = false
local APP_MQTT_CONFIG = _G.APP_MQTT_CONFIG or {}
local APP_MQTT_FIELDS = APP_MQTT_CONFIG.FIELDS or {}
local MQTT_REPORT_TYPE = APP_MQTT_CONFIG.REPORT_TYPE or {}
local config = {
    client_getter = function() return nil end,
    default_qos = 1,
}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return config
    end

    for key, value in pairs(newConfig) do
        config[key] = value
    end
    return config
end

local function currentClient()
    local getter = config.client_getter
    if type(getter) == "function" then
        return getter()
    end
end

function configure(newConfig)
    return mergeConfig(newConfig)
end

function getConfig()
    return config
end

function setClientGetter(getter)
    if type(getter) == "function" then
        config.client_getter = getter
    end
end

function start(newConfig)
    if started then
        return false
    end

    mergeConfig(newConfig)
    started = true
    return true
end

function getState()
    local client = currentClient()
    return {
        started = started,
        hasClient = client ~= nil,
        ready = client and client:ready() or false,
    }
end

local function publishJson(payload, qos)
    local client = currentClient()
    if client and client:ready() then
        return client:publish(mqtt_pub_topic, json.encode(payload), qos or config.default_qos)
    end
end

function publishAck(template, dataType, repDataType, messageId, code, extra)
    local packet, result = json.decode(template)
    if result and type(packet) == "table" then
        packet.deviceNo = tostring(mobile.imei())
        packet.messageId = messageId
        packet.dataType = dataType
        packet.repDataType = repDataType
        packet.code = code
        if type(extra) == "table" then
            for key, value in pairs(extra) do
                packet[key] = value
            end
        end
        return publishJson(packet, 1)
    end
end

function decodeServerData(topic, payload)
    if topic ~= mqtt_sub_topic then
        return false
    end

    local data, result, errinfo = json.decode(payload)
    if not result or type(data) ~= "table" then
        log.info("mqttCommand.decode error", errinfo)
        return false
    end

    return true, {
        dataType = tostring(data[APP_MQTT_FIELDS.DATA_TYPE] or ""),
        messageId = data[APP_MQTT_FIELDS.MESSAGE_ID],
        payload = data,
        topic = topic,
    }
end

function publishPirStatus(status)
    local packet, result = json.decode(REPORT_DATA_TEMPLATE8)
    if result and type(packet) == "table" then
        packet.deviceNo = tostring(mobile.imei())
        packet.dataType = MQTT_REPORT_TYPE.PIR_STATUS
        packet.pirStatus = status
        packet.time = os.time()
        publishJson(packet, 1)
    end
end

function publishWakeup()
    publishPirStatus(1)
end

function publishRestdeep()
    publishPirStatus(0)
end
