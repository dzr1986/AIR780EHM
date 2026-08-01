-- module_loader: 统一模块加载框架
-- 合并原 app.lua optMod() 与 utils.lazyRequire() 两套实现，单一缓存
-- 约定见 doc/CAT1_MODULE_FRAMEWORK.md
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local cache = {}
local startedList = {}

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

-- 安全调用生命周期方法（默认 "start"），成功 start 的模块登记供 stopAll
function start(mod, fn, opts)
	fn = fn or "start"
	if type(mod) == "string" then
		mod = load(mod)
	end
	if type(mod) ~= "table" or type(mod[fn]) ~= "function" then
		return false
	end
	local ok, ret = pcall(mod[fn], opts)
	if ok and ret ~= false and fn == "start" then
		startedList[#startedList + 1] = mod
	end
	return ok and ret ~= false
end

-- 逆序停止所有已登记模块（模块有 stop() 才调用）
function stopAll()
	for i = #startedList, 1, -1 do
		local mod = startedList[i]
		if type(mod.stop) == "function" then
			pcall(mod.stop)
		end
		startedList[i] = nil
	end
end

return _M
