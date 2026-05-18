-- @module mqttReport

require "sys"
module(..., package.seeall)

local started = false
local getClient = function() return nil end
local config = {
    interval_factor = 2,
    initial_delay = 10000,
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

function configure(newConfig)
    return mergeConfig(newConfig)
end

function getConfig()
    return config
end

function setClientGetter(getter)
    if type(getter) == "function" then
        getClient = getter
    end
end

local function buildPacket(template, fill)
    local packet, result = json.decode(template)
    if result and type(packet) == "table" then
        fill(packet)
        return packet
    end
end

function publishStatusOnce()
    local client = getClient()
    if not (client and client:ready()) then
        return false
    end

    local reportTime = os.time()
    local packet = buildPacket(REPORT_DATA_TEMPLATE1, function(data)
        data.deviceNo = tostring(mobile.imei())
        data.dataType = "1001"
        data.status = tostring(OnlineStatus) .. tostring(lowPowerModeStatus) .. "0"
        PowerStatus = gpio.get(gpio.VBUS)
        data.powerStatus = PowerStatus
        data.remainPower = _G.electricity
        data.remainStorageSize = rtos.meminfo()
        data.time = reportTime
        data.deviceVer = VERSION
    end)

    if packet then
        client:publish(mqtt_pub_topic, json.encode(packet), 1)
        return true
    end

    return false
end

function start(newConfig)
    if started then
        return false
    end

    local runtimeConfig = mergeConfig(newConfig)
    started = true

    sys.taskInit(function()
        sys.wait(runtimeConfig.initial_delay)
        while true do
            sys.wait(LowPowerInterval * 1000 * runtimeConfig.interval_factor)
            publishStatusOnce()
        end
    end)

    return true
end

function startPeriodic(intervalFactor)
    return start({interval_factor = intervalFactor or config.interval_factor})
end

function getState()
    return {
        started = started,
    }
end
