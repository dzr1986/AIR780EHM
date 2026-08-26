-- ================================================================
-- Filename : module_loader.lua
-- Module   : 模块加载器：按需懒加载、依赖解耦、MODULE_FLAGS 裁剪开关
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

-- module_loader: 统一模块加载框架
-- 合并原 app.lua optMod() 与 utils.lazyRequire() 两套实现，单一缓存
-- 约定见 doc/CAT1_MODULE_FRAMEWORK.md
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local cache = {}

-- 安全 require（带缓存）；失败或返回非 table 时得 nil，不重复尝试
function load(name)
    local m = cache[name]
    if m == nil then
        local ok, loaded = pcall(require, name)
        m = (ok and type(loaded) == "table") and loaded or false
        cache[name] = m
    end
    return m ~= false and m or nil
end

-- 读取模块开关：MODULE_FLAGS[flag] == false 视为关闭，nil 视为开启
function enabled(flag)
    local flags = _G.MODULE_FLAGS
    return not (flags and flags[flag] == false)
end

-- 按 MODULE_FLAGS 条件加载：flag 关闭时返回 nil（等价原 optMod）
function opt(flag, name)
    if not enabled(flag) then
        return nil
    end
    return load(name or flag)
end

-- 安全调用生命周期方法（默认 "start"）
function start(mod, fn, opts)
    fn = fn or "start"
    if type(mod) == "string" then
        mod = load(mod)
    end
    if type(mod) ~= "table" or type(mod[fn]) ~= "function" then
        return false
    end
    local ok, ret = pcall(mod[fn], opts)
    return ok and ret ~= false
end

return _M
