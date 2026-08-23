-- ================================================================
-- Filename : sound_prompt.lua
-- Module   : 提示音：冷启动/关机 AT+PLAYSOUND、等 +SOUNDACK
-- Arch     : doc/modules/SOUND_PROMPT_FLOW.md
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local cfgm = require "config_manager"
local loader = require "module_loader"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local ACK_EVENT = "SOUND_PROMPT_ACK"
local uart_bridge
local coldBootPlayed = false
local bootColdTaskStarted = false
local function enabled()
    if cfgm.get("SOUND_CFG").enabled == false then
        return false
    end
    if not loader.enabled("sound_prompt") then
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
    local c = cfgm.get("SOUND_CFG")
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
        uart_bridge = loader.load("uart_bridge")
    end
    return uart_bridge
end
local function t3xOn(extra)
    return utils.t3xOn("sound_prompt", extra, {
        t3x_power_wait_ms = tonumber(cfgm.get("SOUND_CFG").t3x_power_wait_ms) or 800,
    })
end

local function waitSoundAck(name, timeoutMs)
    return utils.waitT3xCmdAck(ACK_EVENT, timeoutMs, function(ackName)
        return ackName == name or ackName == nil
    end)
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
        return false
    end
    t3xOn()
    local timeoutMs = tonumber(cfgm.get("SOUND_CFG").play_timeout_ms) or 2500
    if scene == "boot_cold" then
        coldBootPlayed = true
    end
    ub.sendString("AT+PLAYSOUND=" .. name, true)
    local ok = waitSoundAck(name, timeoutMs)
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
        local timeoutMs = tonumber(cfgm.get("SOUND_CFG").boot_wait_host_ms)
            or tonumber(cfgm.get("SOUND_CFG").boot_delay_ms)
            or 60000
        if ipcCfg.enabled ~= false and ipcCfg.boot_sound_wait_ready ~= false then
            local ipc = loader.load("t3x_ctrl")
            if ipc and ipc.pwrOnReady then
                if not ipc.pwrOnReady({
                    ready_timeout_ms = timeoutMs,
                    poll_ms = ipcCfg.ready_poll_ms,
                }) then
                    return
                end
            else
                local evt = utils.appEvent("HOST_UART_FIRST_AT", "host_uart_first_at")
                if not sys.waitUntil(evt, timeoutMs) then
                    return
                end
            end
        end
        playBlocking("boot", "boot_cold")
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
    return true
end
return _M
