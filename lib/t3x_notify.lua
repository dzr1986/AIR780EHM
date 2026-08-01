require "sys"
local loader = require "module_loader"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local function notifyViaTimeSync(sid, evt)
	local time_sync = loader.load("time_sync")
	if not time_sync or not time_sync.pushBeforeNotifyAsync then
		return false
	end
	if _G.MODULE_FLAGS and _G.MODULE_FLAGS.time_sync == false then
		return false
	end
	time_sync.pushBeforeNotifyAsync(sid, evt)
	return true
end

local function notifyViaHostUart(sid, evt)
	local hu = _G.host_uart
	if not hu then
		local mod = loader.load("host_uart")
		hu = mod or nil
	end
	if hu and hu.notify_host then
		return hu.notify_host(sid, evt) ~= false
	end
	return false
end

local function fallbackGpioWake(onDone)
	local t3x = _G.t3x_ctrl
	if not t3x then
		local mod = loader.load("t3x_ctrl")
		t3x = mod or nil
	end
	if not t3x or not t3x.wake then
		return false
	end
	sys.taskInit(function()
		t3x.wake()
		if onDone then
			onDone()
		end
	end)
	return true
end

function wakeHost(sid, evt, opts)
	opts = type(opts) == "table" and opts or {}
	sid = sid or (_G.HOST_WAKE_CFG and _G.HOST_WAKE_CFG.default_sid) or 1
	evt = evt or 0
	local onDone = opts.on_done
	if not (_G.MODULE_FLAGS and _G.MODULE_FLAGS.t3x_wakeup
		and (_G.MODULE_FLAGS.t3x_app ~= false)) then
		return fallbackGpioWake(onDone)
	end
	if notifyViaTimeSync(sid, evt) then
		if onDone then
			onDone()
		end
		return true
	end
	if notifyViaHostUart(sid, evt) then
		if onDone then
			onDone()
		end
		return true
	end
	return fallbackGpioWake(onDone)
end

function ensurePowered(tag, opts)
	local t3x = _G.t3x_ctrl
	if not t3x then
		local mod = loader.load("t3x_ctrl")
		t3x = mod or nil
	end
	if t3x and t3x.ensurePowered then
		return t3x.ensurePowered(tag, opts)
	end
	return false
end

return _M
