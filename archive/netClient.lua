-- @module netClient

require "sys"
module(..., package.seeall)

local started = false
local monitorStarted = false
local lastDeviceId = nil
local config = {
    max_restart_attempts = 3,
    restart_delay = 30000,
    wait_timeout = 60000,
    wifi_ssid = "luatos1234",
    wifi_password = "12341234",
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

local function startMobileMonitor()
    if monitorStarted then
        return
    end

    monitorStarted = true
    sys.taskInit(function()
        while true do
            local netStatus = mobile.status()
            if netStatus == 1 then
                gpio.set(netstatus_io_number, 0)
            else
                local count = 0
                while count < 10 do
                    gpio.set(netstatus_io_number, 1)
                    sys.wait(100)
                    gpio.set(netstatus_io_number, 0)
                    sys.wait(100)
                    count = count + 1
                end
            end
            sys.wait(2000)
        end
    end)
end

local function networkTask(runtimeConfig)
    local deviceId = mcu.unique_id():toHex()
    local restartCount = 0
    local maxRestartAttempts = runtimeConfig.max_restart_attempts
    local restartDelay = runtimeConfig.restart_delay
    local waitTimeout = runtimeConfig.wait_timeout

    while restartCount < maxRestartAttempts do
        if wlan and wlan.connect then
            local ssid = runtimeConfig.wifi_ssid
            local password = runtimeConfig.wifi_password
            wlan.init()
            wlan.setMode(wlan.STATION)
            deviceId = wlan.getMac()
            wlan.connect(ssid, password, 1)
        elseif mobile then
            gpio.setup(netstatus_io_number, 0, gpio.PULLUP)
            deviceId = mobile.imei()
            Enable4Gflag = 1
            startMobileMonitor()
        elseif w5500 then
            w5500.init(spi.HSPI_0, 24000000, pin.PC14, pin.PC01, pin.PC00)
            w5500.config()
            w5500.bind(socket.ETH0)
        elseif socket or mqtt then
        else
            while true do
                sys.wait(1000)
                log.info("bsp", "本bsp可能未适配网络层, 请查证")
            end
        end

        local ret = sys.waitUntil("IP_READY", waitTimeout)
        if ret then
            Enable4Gflag = 1
            lastDeviceId = deviceId
            sys.publish("net_ready", deviceId)
            break
        end

        restartCount = restartCount + 1
        if restartCount < maxRestartAttempts then
            sys.wait(restartDelay)
            pm.reboot()
        else
            log.info("NETWORK", "已达到最大重启次数，停止尝试")
        end
    end
end

function start(newConfig)
    if started then
        return false
    end

    local runtimeConfig = mergeConfig(newConfig)
    started = true
    sys.taskInit(networkTask, runtimeConfig)
    return true
end

function getDeviceId()
    return lastDeviceId
end

function getState()
    return {
        started = started,
        monitorStarted = monitorStarted,
        deviceId = lastDeviceId,
    }
end
