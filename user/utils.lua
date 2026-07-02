-- 通用工具函数模块
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

-- 布尔值解析函数（支持多种格式：true/false/1/0/"true"/"1"/"yes"/"on"等）
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

-- 日志函数工厂：创建带标签的日志函数三元组
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

-- 获取 host_uart 模块（支持全局缓存）
local hostUartMod
function getHostUart()
	if hostUartMod == nil then
		if _G.host_uart then
			hostUartMod = _G.host_uart
		else
			local ok, m = pcall(require, "host_uart")
			hostUartMod = ok and m or false
		end
	end
	return hostUartMod or nil
end

return _M
