-- ================================================================
-- Filename : module_loader.lua
-- Module   : 模块加载器：按需懒加载、依赖解耦、MODULE_FLAGS 裁剪开关
-- Arch     : 见 doc/overview/LUA_MODULES.md
-- ================================================================

require "config"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local cache = {}
local started = {}

function load(name)
    local m = cache[name]
    if m == nil then
        local ok, loaded = pcall(require, name)
        m = (ok and type(loaded) == "table") and loaded or false
        cache[name] = m
    end
    return m ~= false and m or nil
end

function enabled(flag)
    return cfgm.get("MODULE_FLAGS")[flag] ~= false
end

function opt(flag, name)
    if not enabled(flag) then return nil end
    return load(name or flag)
end

function start(mod, fn, opts)
    fn = fn or "start"
    if type(mod) == "string" then mod = load(mod) end
    if type(mod) ~= "table" or type(mod[fn]) ~= "function" then
        return false
    end
    local ok, ret = pcall(mod[fn], opts)
    if ok and ret ~= false then
        started[#started + 1] = mod
        return true
    end
    return false
end

function stopAll()
    for i = #started, 1, -1 do
        local mod = started[i]
        if type(mod.stop) == "function" then
            pcall(mod.stop)
        end
    end
    started = {}
end

return _M
