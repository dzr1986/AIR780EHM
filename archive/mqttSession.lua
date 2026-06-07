-- @module mqttSession

require "sys"
module(..., package.seeall)

local started = false
local client
local downlinkHandler
local config = {
    reconnect_delay = 3000,
    offline_event = (_G.APP_EVENTS and _G.APP_EVENTS.MQTT_OFFLINE) or "APP_MQTT_OFFLINE",
    downlink_event = (_G.APP_EVENTS and _G.APP_EVENTS.MQTT_SERVER_DATA) or "APP_MQTT_SERVER_DATA",
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

local function publishEvent(name, ...)
    if name and name ~= "" then
        sys.publish(name, ...)
    end
end

function configure(newConfig)
    return mergeConfig(newConfig)
end

function getConfig()
    return config
end

function setDownlinkHandler(handler)
    downlinkHandler = handler
end

function getClient()
    return client
end

local function onMessage(topic, payload, runtimeConfig)
    if downlinkHandler then
        downlinkHandler(topic, payload)
    else
        publishEvent(runtimeConfig.downlink_event, topic, payload)
    end
end

local function mqttTask(runtimeConfig)
    local _, deviceId = sys.waitUntil("net_ready")
    mqtt_client_id = deviceId

    if mqtt == nil then
        while true do
            sys.wait(1000)
            log.info("bsp", "本bsp未适配mqtt库, 请查证")
        end
    end

    client = mqtt.create(nil, mqtt_host, mqtt_port, mqtt_isssl)
    client:auth(mqtt_client_id, mqtt_user_name, mqtt_password)
    client:autoreconn(true, runtimeConfig.reconnect_delay)

    client:on(function(mqttClient, event, data, payload)
        log.info("mqtt", "event", event, mqttClient, data, payload)
        if event == "conack" then
            OnlineStatus = 1
            sys.publish("mqtt_conack")
            mqttClient:subscribe(mqtt_sub_topic)
        elseif event == "recv" then
            onMessage(data, payload, runtimeConfig)
        elseif event == "disconnect" then
            OnlineStatus = 0
            publishEvent(runtimeConfig.offline_event)
        end
    end)

    client:connect()
    sys.waitUntil("mqtt_conack")

    while true do
        local ret, topic, data, qos = sys.waitUntil("mqtt_pub", 300000)
        if ret then
            if topic == "close" then
                break
            end
            client:publish(topic, data, qos)
        end
    end

    client:close()
    client = nil
end

function start(newConfig)
    if started then
        return false
    end

    local runtimeConfig = mergeConfig(newConfig)
    started = true
    sys.taskInit(mqttTask, runtimeConfig)
    return true
end

function getState()
    return {
        started = started,
        hasClient = client ~= nil,
        ready = client and client:ready() or false,
    }
end
