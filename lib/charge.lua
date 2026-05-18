--- 模块功能：充电状态检测库
-- @module charge
-- @author GitHub Copilot
-- @release 2026.5.13

local _modname = ...
local _G_direct = _ENV
_G_direct[_modname] = _G_direct[_modname] or {}
module(_modname, package.seeall)
_G[_modname] = _M

local started = false

local function resolve(value)
    if type(value) == "function" then
        return value()
    end
    return value
end

local config = {
    pin = function()
        return _G.netstatus_io_number or 27
    end,
    mode = "in",
}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return config
    end

    for key, value in pairs(newConfig) do
        if value ~= nil then
            config[key] = value
        end
    end
    return config
end

--- 配置充电检测参数
-- @param newConfig table 支持 pin、mode
-- @return table 当前配置
function configure(newConfig)
    return mergeConfig(newConfig)
end

--- 获取当前配置
-- @return table 当前配置
function getConfig()
    return config
end

function init(pin)
    if pin ~= nil then
        config.pin = pin
    end
    gpio.setup(resolve(config.pin), config.mode)
    started = true
    return true
end

function start(newConfig)
    mergeConfig(newConfig)
    return init(resolve(config.pin))
end

function getLevel()
    return gpio.get(resolve(config.pin))
end

function isCharging()
    return getLevel() == 1 and 1 or 0
end

--- 获取当前状态
-- @return table 当前运行状态
function getState()
    return {
        started = started,
        pin = resolve(config.pin),
        level = getLevel(),
        charging = isCharging(),
    }
end
if type(_M) == "table" then _G[_modname] = _M end
return _M
