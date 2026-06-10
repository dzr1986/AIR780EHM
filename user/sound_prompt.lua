--- 提示音编排：4G 发 AT+PLAYSOUND，T3x 播放（见 t3x_linux/audio_prompt.c）
-- 冷启动：收到 T3x 首条 AT 后再 AT+PLAYSOUND=boot（非固定延时）
-- @module sound_prompt
-- @release v1_20260529

require "sys"
require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "sound_prompt"
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

--- scene: boot_cold | boot_wake | shutdown_user | shutdown_low_power | shutdown_battery
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

local function ensureT3xPowered()
    local ok, ipc = pcall(require, "t3x_ipc")
    if ok and type(ipc) == "table" and ipc.ensurePowered then
        return ipc.ensurePowered("sound_prompt", {
            t3x_power_wait_ms = tonumber(cfg().t3x_power_wait_ms) or 800,
        })
    end
    return false
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

--- 须在 task 内调用；name: boot | shutdown
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
        log.warn(LOG_TAG, "uart_bridge 不可用，跳过", name)
        return false
    end

    ensureT3xPowered()

    local timeoutMs = tonumber(cfg().play_timeout_ms) or 2500
    if scene == "boot_cold" then
        coldBootPlayed = true
    end
    log.info(LOG_TAG, "AT+PLAYSOUND", name, "scene", scene or "--")
    ub.sendString("AT+PLAYSOUND=" .. name, true)

    local ok = waitSoundAck(name, timeoutMs)
    if ok then
        log.info(LOG_TAG, "播放完成", name)
    else
        log.warn(LOG_TAG, "播放超时", name, timeoutMs, "ms")
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
            local okIpc, ipc = pcall(require, "t3x_ipc")
            if okIpc and type(ipc) == "table" and ipc.powerOnWaitReady then
                log.info(LOG_TAG, "等待 T3x +IPCSTATUS:ready", timeoutMs, "ms")
                local ready = ipc.powerOnWaitReady({
                    ready_timeout_ms = timeoutMs,
                    poll_ms = ipcCfg.ready_poll_ms,
                })
                if not ready then
                    log.warn(LOG_TAG, "等待 T3x ready 超时，跳过开机音", timeoutMs, "ms")
                    return
                end
                log.info(LOG_TAG, "T3x ready")
            else
                useIpcReady = false
            end
        end

        if not useIpcReady then
            local okHu, hu = pcall(require, "host_uart")
            if okHu and hu and hu.isHostAtReady and hu.isHostAtReady() then
                firstCmd = hu.getHostFirstAt and hu.getHostFirstAt() or ""
                log.info(LOG_TAG, "T3x 已发首条 AT", firstCmd or "")
            else
                log.info(LOG_TAG, "等待 T3x 首条 AT", timeoutMs, "ms")
                local got
                got, firstCmd = sys.waitUntil(evt, timeoutMs)
                if not got then
                    log.warn(LOG_TAG, "等待 T3x 首条 AT 超时，跳过开机音", timeoutMs, "ms")
                    return
                end
                log.info(LOG_TAG, "收到 T3x 首条 AT", firstCmd or "")
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

--- 关机类提示；reason: user | mqtt | low_power | battery
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
    log.info(LOG_TAG, "已启动",
        "boot_cold", cfg().boot_on_cold_start ~= false,
        "boot_wake", cfg().boot_on_wake == true,
        "off_user", cfg().shutdown_on_user_off ~= false)
    return true
end

log.info(LOG_TAG, "loaded")
return _M
