--- 完整提示音（恢复：copy → user/sound_prompt.lua）
-- 见 doc/BOOT_SHUTDOWN_SOUND.md
require "sys"
require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "snd"
local ACK_EVENT = "SOUND_PROMPT_ACK"

local uart_bridge
local t3xModule
local coldBootPlayed = false
local bootColdTaskStarted = false

local function cfg()
    return _G.SOUND_CFG or {}
end

local function enabled()
    if cfg().enabled == false then
        return false
    end
    local flags = _G.MODULE_FLAGS
    if flags and flags.sound_prompt == false then
        return false
    end
    return true
end

local function isBurnActive()
    return _G.T3X_BURN_MODE_ACTIVE
end

function shouldPlay(scene)
    if not enabled() or isBurnActive() then
        return false
    end
    local c = cfg()
    if scene == "boot_cold" then
        return c.boot_on_cold_start ~= false and not coldBootPlayed
    elseif scene == "boot_wake" then
        return c.boot_on_wake == true
    elseif scene == "shutdown_user" then
        return c.shutdown_on_user_off ~= false
    elseif scene == "shutdown_low_power" then
        return c.shutdown_on_low_power == true
    elseif scene == "shutdown_battery" then
        return c.shutdown_on_battery_off == true
    end
    return false
end

local function getUart()
    if uart_bridge then
        return uart_bridge
    end
    uart_bridge = _G.uart_bridge
    if not uart_bridge then
        local ok, mod = pcall(require, "uart_bridge")
        if ok then
            uart_bridge = mod
        end
    end
    return uart_bridge
end

local ipcMod

local function t3xOn(extra)
    if ipcMod == nil then
        local ok, m = pcall(require, "t3x_ctrl")
        ipcMod = ok and m or false
    end
    if not ipcMod or not ipcMod.ensurePowered then
        return false
    end
    return ipcMod.ensurePowered("sound_prompt", extra or {
        t3x_power_wait_ms = tonumber(cfg().t3x_power_wait_ms) or 800,
    })
end

local function waitSoundAck(name, timeoutMs)
    local deadline = (mcu and mcu.ticks and mcu.ticks() or 0) + timeoutMs
    while true do
        local remain = timeoutMs
        if mcu and mcu.ticks then
            remain = deadline - mcu.ticks()
            if remain <= 0 then
                return false
            end
        end
        local got, ackName = sys.waitUntil(ACK_EVENT, remain)
        if got and (ackName == name or ackName == nil) then
            return true
        end
        if not mcu or not mcu.ticks then
            return false
        end
    end
end

function playBlocking(name, scene)
    if not name or name == "" then
        return false
    end
    if scene and not shouldPlay(scene) then
        return false
    end
    if not enabled() then
        return false
    end

    local ub = getUart()
    if not ub or not ub.sendString then
        log.warn(LOG_TAG, "noUb", name)
        return false
    end

    t3xOn()

    local timeoutMs = tonumber(cfg().play_timeout_ms) or 2500
    if scene == "boot_cold" then
        coldBootPlayed = true
    end
    log.info(LOG_TAG, "play", name, "sc", scene or "--")
    ub.sendString("AT+PLAYSOUND=" .. name, true)

    local ok = waitSoundAck(name, timeoutMs)
    if ok then
        log.info(LOG_TAG, "ok", name)
    else
        log.warn(LOG_TAG, "to", name, timeoutMs, "ms")
    end
    return ok
end

function onSoundAck(name)
    if name and name ~= "" then
        sys.publish(ACK_EVENT, name)
    end
end

function onAppStarted()
    if bootColdTaskStarted or not shouldPlay("boot_cold") then
        return
    end
    bootColdTaskStarted = true
    sys.taskInit(function()
        local ipcCfg = _G.HOST_IPC_CFG or {}
        local useIpcReady = ipcCfg.enabled ~= false and ipcCfg.boot_sound_wait_ready ~= false
        local timeoutMs = tonumber(cfg().boot_wait_host_ms)
            or tonumber(cfg().boot_delay_ms)
            or 60000
        local evt = (_G.APP_EVENTS and _G.APP_EVENTS.HOST_UART_FIRST_AT) or "APP_HOST_UART_FIRST_AT"
        local firstCmd

        if useIpcReady then
            local okIpc, ipc = pcall(require, "t3x_ctrl")
            if okIpc and type(ipc) == "table" and ipc.powerOnWaitReady then
                log.info(LOG_TAG, "wRd", timeoutMs, "ms")
                local ready = ipc.powerOnWaitReady({
                    ready_timeout_ms = timeoutMs,
                    poll_ms = ipcCfg.ready_poll_ms,
                })
                if not ready then
                    log.warn(LOG_TAG, "rdTo", timeoutMs, "ms")
                    return
                end
                log.info(LOG_TAG, "rdy")
            else
                useIpcReady = false
            end
        end

        if not useIpcReady then
            local okHu, hu = pcall(require, "host_uart")
            if okHu and hu and hu.isHostAtReady and hu.isHostAtReady() then
                firstCmd = hu.getHostFirstAt and hu.getHostFirstAt() or ""
                log.info(LOG_TAG, "1st", firstCmd or "")
            else
                log.info(LOG_TAG, "w1st", timeoutMs, "ms")
                local got
                got, firstCmd = sys.waitUntil(evt, timeoutMs)
                if not got then
                    log.warn(LOG_TAG, "1stTo", timeoutMs, "ms")
                    return
                end
                log.info(LOG_TAG, "got1st", firstCmd or "")
            end
        end

        if shouldPlay("boot_cold") then
            playBlocking("boot", "boot_cold")
        end
    end)
end

function onWakeFromLowPower()
    if not shouldPlay("boot_wake") then
        return
    end
    sys.taskInit(function()
        playBlocking("boot", "boot_wake")
    end)
end

function playShutdownThen(reason, callback)
    reason = reason or "user"
    local scene = "shutdown_user"
    if reason == "low_power" then
        scene = "shutdown_low_power"
    elseif reason == "battery" then
        scene = "shutdown_battery"
    end

    sys.taskInit(function()
        if shouldPlay(scene) then
            playBlocking("shutdown", scene)
        end
        if type(callback) == "function" then
            callback()
        end
    end)
end

function start(opts)
    if type(opts) == "table" and opts.t3x then
        t3xModule = opts.t3x
    end
    log.info(LOG_TAG, "on")
    return true
end

return _M
