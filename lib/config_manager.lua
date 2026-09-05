-- ================================================================
-- Filename : config_manager.lua
-- Module   : 配置管理：JSON 持久化读写、默认值合并、配置热更新
-- Arch     : 见 doc/overview/LUA_MODULES.md
-- ================================================================

-- config_manager: 统一配置访问框架
-- 替代各模块散落的 cfg() + 手工 merge 默认值逻辑
-- 约定见 doc/overview/CAT1_MODULE_FRAMEWORK.md
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

-- 取全局配置表（如 "LED_CFG"）；不存在返回空表，不缓存以支持运行时覆盖。
-- 键名大小写敏感，须精确等于 config 片段注册的 _G.<键>（例：battery.lua 注册 t31x_POLICY_CFG，
-- 若读 "T31X_POLICY_CFG" 会静默空表——见 doc/overview/USER_LIB_CODE_AUDIT §12）。未注册键仅告警一次。
local warnOnce = {}
function get(name)
    local t = _G[name]
    if type(t) ~= "table" then
        if not warnOnce[name] then
            warnOnce[name] = true
            if log and log.warn then
                log.warn("config_manager", "unknown cfg key '" .. tostring(name) .. "', fallback {} (check config fragment _G registration & case)")
            end
        end
        return {}
    end
    return t
end

-- 解析配置来源：t 可为全局配置名或直接配置表
local function resolve(t)
    return type(t) == "string" and get(t) or (type(t) == "table" and t or {})
end

-- 取数值配置：t 为全局配置名或表；缺失/非数值用 default
function num(t, key, default)
    local v = resolve(t)[key]
    return type(v) == "number" and v or default
end

-- 取布尔配置：t 为全局配置名或表；nil 用 default；false/0/"0" 为 false。
-- 语义与 lib/utils.lua parseBoolDef 等价；因 utils→module_loader→本模块 require 环禁 require utils 复用，
-- 两处须同步维护（见 doc/overview/USER_LIB_CODE_AUDIT_20260904.md §14）。
function bool(t, key, default)
    local v = resolve(t)[key]
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
