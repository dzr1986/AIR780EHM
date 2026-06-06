--- T3x 电源：AT+IPCSTATUS? / AT+IPCPOWEROFF + GPIO22
-- 推荐流程见 doc/UART_AT_COMMANDS.md §3.4
-- @module t3x_ipc

require "sys"
require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "t3x_ipc"
local t3xModule

local function cfg()
    return _G.HOST_IPC_CFG or {}
end

local function enabled()
    return cfg().enabled ~= false
end

local function getT3x()
    if t3xModule then
        return t3xModule
    end
    local ok, mod = pcall(require, "t3x_ctrl")
    if ok then
        t3xModule = mod
    end
    return t3xModule
end

local function getHostUart()
    local ok, mod = pcall(require, "host_uart")
    if ok then
        return mod
    end
    return nil
end

local function inTask()
    return coroutine.running() ~= nil
end

--- 关机（T3x 在线）：IPCSTATUS=ready → IPCPOWEROFF → GPIO22 断电
function gracefulPowerOff(opts)
    opts = type(opts) == "table" and opts or {}
    local t3x = getT3x()
    if not t3x or not t3x.powerOff then
        log.warn(LOG_TAG, "t3x_ctrl 不可用")
        return false
    end
    if not inTask() then
        log.warn(LOG_TAG, "非 task 上下文，直接 GPIO 断电")
        t3x.powerOff()
        local hu = getHostUart()
        if hu and hu.resetHostLinkState then
            hu.resetHostLinkState()
        end
        return true
    end

    local hu = getHostUart()
    local playSound = opts.play_sound
    if playSound == nil then
        playSound = cfg().poweroff_play_sound ~= false
    end

    if enabled() and hu then
        local st = hu.queryHostIpcStatus and hu.queryHostIpcStatus(opts.status_timeout_ms)
        if st == "ready" or st == "shutting_down" then
            if hu.hostIpcPowerOff then
                hu.hostIpcPowerOff(playSound, opts.poweroff_timeout_ms)
            end
        elseif st == "idle" then
            log.info(LOG_TAG, "T3x 已 idle，跳过 IPCPOWEROFF")
        end
    end

    t3x.powerOff()
    if hu and hu.resetHostLinkState then
        hu.resetHostLinkState()
    end
    log.info(LOG_TAG, "GPIO 断电完成")
    return true
end

--- 开机（T3x 未在线）：GPIO22 上电 → 轮询 +IPCSTATUS:ready
function powerOnWaitReady(opts)
    opts = type(opts) == "table" and opts or {}
    if not inTask() then
        log.warn(LOG_TAG, "powerOnWaitReady 须在 task 内调用")
        return false
    end

    local t3x = getT3x()
    local hu = getHostUart()
    if not t3x or not t3x.powerOn then
        return false
    end

    local st
    if enabled() and hu and hu.queryHostIpcStatus then
        st = hu.queryHostIpcStatus(opts.status_timeout_ms)
        if st == "ready" then
            log.info(LOG_TAG, "T3x 已 ready")
            return true
        end
    end

    if not t3x.getState or not t3x.getState().powered_on then
        t3x.powerOn()
        sys.wait(tonumber(opts.power_wait_ms)
            or tonumber(cfg().t3x_power_wait_ms)
            or tonumber((_G.TIME_SYNC_CFG or {}).t3x_power_wait_ms)
            or 800)
    end

    if enabled() and hu and hu.waitHostIpcReady then
        return hu.waitHostIpcReady(opts.ready_timeout_ms, opts.poll_ms)
    end

    sys.wait(tonumber(cfg().host_boot_wait_ms)
        or tonumber((_G.TIME_SYNC_CFG or {}).host_boot_wait_ms)
        or 1500)
    return hu and hu.isHostAtReady and hu.isHostAtReady() or true
end

log.info(LOG_TAG, "loaded")
return _M
