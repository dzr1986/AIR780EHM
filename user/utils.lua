local _modname = ...
local loader = require "module_loader"
module(_modname, package.seeall)
_G[_modname] = _M

MIN_VALID_UNIX = 1704067200

function parseBoolLike(v)
	if v == true or v == 1 then
		return true
	end
	if type(v) == "string" then
		local s = string.lower(v)
		return s == "1" or s == "true" or s == "yes" or s == "on"
	end
	return false
end

-- Lua 5.3 主调度里 coroutine.running() 也非 nil，不能用来判断能否 sys.wait。
function inSysTask()
	if coroutine.isyieldable then
		return coroutine.isyieldable() == true
	end
	local co, isMain = coroutine.running()
	if co == nil or isMain == true then
		return false
	end
	return true
end

function parseBoolDefault(v, default)
	if v == nil then
		return default
	end
	if v == false or v == 0 or v == "0" then
		return false
	end
	return true
end

function createLogFunctions(tag)
	local funcs = {}
	funcs.info = function(...)
		if log and log.info then
			log.info(tag, ...)
		end
	end
	funcs.warn = function(...)
		if log and log.warn then
			log.warn(tag, ...)
		elseif log and log.info then
			log.info(tag, ...)
		end
	end
	funcs.error = function(...)
		if log and log.error then
			log.error(tag, ...)
		end
	end
	return funcs
end

-- 委托 module_loader，保持全项目单一 require 缓存
function lazyRequire(name)
	return loader.load(name)
end

local hostUartMod
function getHostUart()
	if hostUartMod == nil then
		if _G.host_uart then
			hostUartMod = _G.host_uart
		else
			hostUartMod = lazyRequire("host_uart") or false
		end
	end
	return hostUartMod or nil
end

return _M
