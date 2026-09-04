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
local t31xPolicy = require "t31x_policy"
local t31xCtrl = require "t31x_ctrl"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local ACK_EVENT = "SOUND_PROMPT_ACK"
local coldBootPlayed = false
local bootColdScheduled = false

-- optIn=true：配置须显式 true；optIn=false：默认开，仅 false 关
local SCENES = {
    boot_cold = {
        key = "boot_on_cold_start", optIn = false,
        guard = function() return not coldBootPlayed end,
    },
    boot_wake = { key = "boot_on_wake", optIn = true },
    shutdown_user = { key = "shutdown_on_user_off", optIn = false },
    shutdown_low_power = { key = "shutdown_on_low_power", optIn = true },
    shutdown_battery = { key = "shutdown_on_battery_off", optIn = true },
}

local SHUTDOWN_SCENES = {
    low_power = "shutdown_low_power",
    battery = "shutdown_battery",
}

local function soundCfg()
    return cfgm.get("SOUND_CFG")
end

local function enabled()
    return soundCfg().enabled ~= false and loader.enabled("sound_prompt")
end

local function cfgEnabled(rule, value)
    if rule.optIn then return value == true end
    return value ~= false
end

function shouldPlay(scene)
    if not enabled() or t31xPolicy.isBurnActive() then return false end
    local rule = SCENES[scene]
    if not rule then return false end
    if not cfgEnabled(rule, soundCfg()[rule.key]) then return false end
    return not rule.guard or rule.guard()
end

local function ensT31xPower(extra)
    return utils.t31xOn("sound_prompt", extra, {
        t31xPowerWaitMs = tonumber(soundCfg().t31x_power_wait_ms) or 800,
    })
end

function playBlocking(name, scene)
    if not name or name == ""
        or (scene and not shouldPlay(scene))
        or (not scene and not enabled()) then
        return false
    end
    local ub = utils.uartBridge()
    if not ub then return false end
    ensT31xPower()
    if scene == "boot_cold" then coldBootPlayed = true end
    ub.sendString("AT+PLAYSOUND=" .. name, true)
    local timeoutMs = tonumber(soundCfg().play_timeout_ms) or 2500
    return utils.waitT31xAck(ACK_EVENT, timeoutMs, function(ackName)
        return ackName == name or ackName == nil
    end)
end

function onSoundAck(name)
    if name and name ~= "" then sys.publish(ACK_EVENT, name) end
end

local function bootHostTimeoutMs(sound)
    return tonumber(sound.boot_wait_host_ms)
        or tonumber(sound.boot_delay_ms)
        or 60000
end

local function waitHostForBootSound(ipc, sound)
    if ipc.enabled == false or ipc.boot_sound_wait_ready == false then
        return true
    end
    return t31xCtrl.pwrOnReady({
        readyTimeoutMs = bootHostTimeoutMs(sound),
        pollMs = ipc.ready_poll_ms,
    })
end

function onAppStarted()
    if bootColdScheduled or not shouldPlay("boot_cold") then return end
    bootColdScheduled = true
    sys.taskInit(function()
        local ipc = cfgm.get("HOST_IPC_CFG")
        local sound = soundCfg()
        if not waitHostForBootSound(ipc, sound) then return end
        playBlocking("boot", "boot_cold")
    end)
end

function onWakeFromLowPower()
    if not shouldPlay("boot_wake") then return end
    sys.taskInit(function() playBlocking("boot", "boot_wake") end)
end

function playShutdownThen(reason, callback)
    local scene = SHUTDOWN_SCENES[reason or "user"] or "shutdown_user"
    sys.taskInit(function()
        if shouldPlay(scene) then playBlocking("shutdown", scene) end
        if type(callback) == "function" then callback() end
    end)
end

function start(_opts)
    return true
end

return _M
