-- ================================================================
-- Filename : config_manager.lua
-- Module   : 配置管理：JSON 持久化读写、默认值合并、配置热更新
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

-- config_manager: 统一配置访问框架
-- 替代各模块散落的 cfg() + 手工 merge 默认值逻辑
-- 约定见 doc/CAT1_MODULE_FRAMEWORK.md
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

-- 取全局配置表（如 "LED_CFG"）；不存在返回空表，不缓存以支持运行时覆盖
function get(name)
    local t = _G[name]
    return type(t) == "table" and t or {}
end

-- 数值配置：t 可为表或全局配置名
function num(t, key, default)
    if type(t) == "string" then
        t = get(t)
    end
    local v = tonumber(t and t[key])
    if v == nil then
        return default
    end
    return v
end

-- 布尔配置：nil 用默认值；false/0/"0" 为 false，其余为 true
function bool(t, key, default)
    if type(t) == "string" then
        t = get(t)
    end
    local v = t and t[key]
    if v == nil then
        return default
    end
    return v ~= false and v ~= 0 and v ~= "0"
end

-- 将 overrides 合并进 defaults 并返回 defaults
-- keys 给出白名单时仅合并这些键；否则全量合并（子表做一层浅合并）
function merge(defaults, overrides, keys)
    if type(overrides) == "string" then
        overrides = get(overrides)
    end
    if type(overrides) ~= "table" then
        return defaults
    end
    if keys then
        for _, k in ipairs(keys) do
            if overrides[k] ~= nil then
                defaults[k] = overrides[k]
            end
        end
        return defaults
    end
    for k, v in pairs(overrides) do
        if type(v) == "table" and type(defaults[k]) == "table" then
            for k2, v2 in pairs(v) do
                defaults[k][k2] = v2
            end
        else
            defaults[k] = v
        end
    end
    return defaults
end

return _M
