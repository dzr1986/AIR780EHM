require "sys"
require "config"
local utils = require "utils"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local logFuncs = utils.createLogFunctions("time_sync")
local tsInfo = logFuncs.info
local tsWarn = logFuncs.warn
local ACK_EVENT = "TIME_SYNC_ACK"
local DEFAULT_MIN_UNIX = 1704067200 -- 2024-01-01 UTC
local uart_bridge
local host_uart
local lastPushedUnix = 0
local function cfg()
	return _G.TIME_SYNC_CFG or {}
end
local function enabled()
	if cfg().enabled == false then
		return false
	end
	local flags = _G.MODULE_FLAGS
	if flags and flags.time_sync == false then
		return false
	end
	return true
end
function isTimeValid(t)
	t = tonumber(t) or os.time()
	local minTs = tonumber(cfg().min_valid_unix) or DEFAULT_MIN_UNIX
	return t >= minTs
end
function getCat1Unix()
	return os.time()
end
local function getUart()
	if uart_bridge then
		return uart_bridge
	end
	uart_bridge = _G.uart_bridge
	if not uart_bridge then
		local ok, mod = pcall(require, "uart_bridge")
		if ok then
			uart_bridge = mod
		end
	end
	return uart_bridge
end
local function getHostUart()
	return utils.getHostUart()
end
local function hostFirstAtEvent()
	return (_G.APP_EVENTS and _G.APP_EVENTS.HOST_UART_FIRST_AT) or "APP_HOST_UART_FIRST_AT"
end
local function waitHostReady(timeoutMs)
	local hu = getHostUart()
	if hu and hu.isHostAtReady and hu.isHostAtReady() then
		return true
	end
	timeoutMs = tonumber(timeoutMs) or tonumber(cfg().host_boot_wait_ms) or 1500
	if timeoutMs <= 0 then
		return false
	end
	local got = sys.waitUntil(hostFirstAtEvent(), timeoutMs)
	if not got then
		return false
	end
	hu = getHostUart()
	return hu and hu.isHostAtReady and hu.isHostAtReady() or false
end
local ipcMod
local function t3xOn(extra)
	if ipcMod == nil then
		local ok, m = pcall(require, "t3x_ctrl")
		ipcMod = ok and m or false
	end
	if not ipcMod or not ipcMod.ensurePowered then
		return false
	end
	extra = extra or {
		t3x_power_wait_ms = tonumber(cfg().t3x_power_wait_ms) or 800,
		log_skip = "低功耗/低电量，跳过 T3x 上电",
	}
	return ipcMod.ensurePowered("time_sync", extra)
end
local function waitTimesetAck(timeoutMs)
	local deadline = (mcu and mcu.ticks and mcu.ticks() or 0) + timeoutMs
	while true do
		local remain = timeoutMs
		if mcu and mcu.ticks then
			remain = deadline - mcu.ticks()
			if remain <= 0 then
				return false
			end
		end
		local got = sys.waitUntil(ACK_EVENT, remain)
		if got then
			return true
		end
		if not mcu or not mcu.ticks then
			return false
		end
	end
end
function pushToHost(force)
	if not enabled() then
		tsWarn("sync_disabled")
		return false
	end
	local t = os.time()
	if not isTimeValid(t) then
		tsWarn("time_invalid", tostring(t))
		return false
	end
	if not force then
		local skew = tonumber(cfg().resync_skew_sec) or 2
		if lastPushedUnix > 0 and math.abs(t - lastPushedUnix) < skew then
			return true
		end
	end
	local ub = getUart()
	if not ub or not ub.sendString then
		tsWarn("uart_unavailable")
		return false
	end
	tsInfo("sync_push", t, force == true and 1 or 0)
	t3xOn()
	if not waitHostReady(tonumber(cfg().host_boot_wait_ms) or 1500) then
		tsWarn("host_not_ready")
		return false
	end
	ub.sendString("AT+TIMESET=" .. t, true)
	local timeoutMs = tonumber(cfg().ack_timeout_ms) or 800
	local ok = waitTimesetAck(timeoutMs)
	if ok then
		lastPushedUnix = t
		tsInfo("sync_ack_ok", t)
	else
		tsWarn("sync_ack_timeout", timeoutMs)
	end
	return ok
end
function pushToHostAsync(force)
	sys.taskInit(function()
		pushToHost(force)
	end)
end
function onTimesetAck()
	sys.publish(ACK_EVENT, true)
end
function onSntpSuccess(unix, server)
	if not enabled() or cfg().sync_on_sntp == false then
		return
	end
	tsInfo("sntp_ok", tostring(server or ""), tostring(unix or ""))
	pushToHostAsync(true)
end
function onT3xWake()
	if not enabled() or cfg().sync_on_wake == false then
		return
	end
	pushToHostAsync(false)
end
function pushBeforeNotify(sid, evt)
	local okPol, policy = pcall(require, "t3x_policy")
	if okPol and type(policy) == "table" and policy.requestT3xWake then
		if not policy.mayPowerT3x("time_sync_notify") then
			return
		end
	end
	if not enabled() or cfg().sync_before_wake == false then
		local hu = getHostUart()
		if hu and hu.notify_host then
			hu.notify_host(sid, evt)
		end
		return
	end
	if isTimeValid() and t3xOn() then
		pushToHost(false)
	end
	local hu = getHostUart()
	if hu and hu.notify_host then
		hu.notify_host(sid, evt)
	end
end
function pushBeforeNotifyAsync(sid, evt)
	sys.taskInit(function()
		pushBeforeNotify(sid, evt)
	end)
end
function start(opts)
	if cfg().sync_on_sntp ~= false then
		sys.subscribe("SNTP_SYNC_SUCCESS", function(unix, server)
			onSntpSuccess(unix, server)
		end)
	end
	return true
end
local sntpCfg = {
	task_name = "sntp_task",
	ok_wait = 3600000,
	fail_wait = 10000,
	timeout = 30000,
	ip_wait_timeout = 1000,
	retry_wait = 1000,
	success_event = "SNTP_SYNC_SUCCESS",
	servers = {
		"ntp.aliyun.com",
		"time1.cloud.tencent.com",
		"cn.pool.ntp.org",
	},
}
local sntpStarted = false
local function sntpTrySync(runtimeConfig)
	for _, server in ipairs(runtimeConfig.servers) do
		socket.sntp(server)
		if sys.waitUntil("NTP_UPDATE", runtimeConfig.timeout) then
			local t = os.time()
			tsInfo("sntp_update", server, t)
			sys.publish(runtimeConfig.success_event, t, server)
			return true
		end
		tsWarn("sntp_timeout", server)
		sys.wait(runtimeConfig.retry_wait)
	end
	return false
end
local function sntpWaitIp(interval)
	while not socket.adapter(socket.dft()) do
		sys.waitUntil("IP_READY", interval or sntpCfg.ip_wait_timeout)
	end
end
local function sntpTask(runtimeConfig)
	while true do
		sntpWaitIp(runtimeConfig.ip_wait_timeout)
		if sntpTrySync(runtimeConfig) then
			sys.wait(runtimeConfig.ok_wait)
		else
			sys.wait(runtimeConfig.fail_wait)
		end
	end
end
function startSntp(newConfig)
	if sntpStarted then return false end
	if type(newConfig) == "table" then
		if type(newConfig.servers) == "table" and #newConfig.servers > 0 then
			sntpCfg.servers = newConfig.servers
		end
		for k, v in pairs(newConfig) do
			if k ~= "servers" and v ~= nil then sntpCfg[k] = v end
		end
	end
	sntpStarted = true
	sys.taskInit(sntpTask, sntpCfg)
	return true
end
return _M
