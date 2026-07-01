require "sys"
local libfota2 = require "libfota2"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local L = "fota_svc"
local started = false
local busy = false
local lastResult = nil
local lastPayload = nil
local requestCount = 0
local lastRequestTime = 0
local config = {
	request_delay_ms = 500,
	network_wait_ms = 120000,
	callback_timeout_ms = 320000,
	timeout_ms = 300000,
	auto_reboot_on_success = true,
}
local handlers = { publishStatus = nil }
local function mergeConfig(newConfig)
	if type(newConfig) ~= "table" then return end
	for k, v in pairs(newConfig) do
		if v ~= nil and k ~= "publishStatus" and k ~= "custom" then
			config[k] = v
		end
	end
end
local function reportStatus(stage, retCode, message, extra)
	if handlers.publishStatus then
		handlers.publishStatus(stage, retCode, message, extra)
	end
end
local function waitNetworkReady(timeoutMs)
	timeoutMs = tonumber(timeoutMs) or 120000
	if socket and socket.localIP then
		local ip = socket.localIP()
		if ip and ip ~= "" and ip ~= "0.0.0.0" then return true, ip end
	end
	local ok = sys.waitUntil("IP_READY", timeoutMs)
	local ip = (socket and socket.localIP and socket.localIP()) or nil
	return ok and ip ~= nil and ip ~= "" and ip ~= "0.0.0.0", ip
end
local function resolveOtaVersion(ver)
	if _G.resolveIotOtaVersion then
		return _G.resolveIotOtaVersion(ver)
	end
	return ver
end
local function defaultFirmwareName()
	local bsp = rtos.bsp()
	if bsp:find("-") then bsp = bsp:sub(1, bsp:find("-") - 1) end
	return (_G.PROJECT or "PANSHI_CAT1") .. "_LuatOS-SoC_" .. bsp
end
local function defaultDeviceQuery()
	if mobile then return "imei=" .. mobile.imei() end
	if wlan and wlan.getMac then return "mac=" .. wlan.getMac() end
	return "uid=" .. mcu.unique_id():toHex()
end
local function buildIotOpts(data)
	data = type(data) == "table" and data or {}
	local url = data.url or data.otaUrl or data.firmwareUrl
	if url and url ~= "" then
		if data.url_no_query or data.full_url == true or data.full_url == 1 then
			url = "###" .. url
		end
		return {
			url = url,
			timeout = config.timeout_ms,
			custom = true,
		}
	end
	local opts = {
		project_key = (data.product_key or data.project_key or data.projectKey) or _G.PRODUCT_KEY,
		version = data.version or data.targetVersion or data.firmwareVersion
			or _G.IOT_VERSION or _G.VERSION,
		timeout = config.timeout_ms,
	}
	local fw = data.firmware_name or data.firmwareName
	if fw and fw ~= "" then opts.firmware_name = fw end
	local imei = data.imei or data.deviceId or data.device_id
	if imei and imei ~= "" then opts.imei = imei end
	opts.fota = true
	return opts
end
local function validateIotConfig(opts)
	if opts.url then return true end
	if not opts.project_key or opts.project_key == "" then return false, "missing_product_key" end
	if not opts.version or opts.version == "" then return false, "missing_version" end
	if not _G.PROJECT or _G.PROJECT == "" then return false, "missing_project" end
	return true
end
local FOTA_RET = {
	[0] = { "success", "download_ok", true },
	[1] = { "failed", "connect_failed" },
	[2] = { "failed", "url_error" },
	[3] = { "failed", "iot_rejected" },
	[4] = { "failed", "recv_error" },
	[5] = { "failed", "version_format_error" },
}
local function fota_cb(ret)
	busy = false
	lastResult = ret
	local row = FOTA_RET[ret] or { "failed", "unknown_ret_" .. tostring(ret) }
	reportStatus(row[1], ret, row[2], lastPayload)
	if ret == 0 and row[3] and config.auto_reboot_on_success ~= false then
		rtos.reboot()
	end
end
local function requestLibFota(opts, cbFnc)
	opts = opts or {}
	cbFnc = cbFnc or function() end
	if opts.custom then
		local url = opts.url
		if url:sub(1, 3) == "###" then
			url = url:sub(4)
		end
		libfota2.request(cbFnc, {
			url = url,
			timeout = opts.timeout,
		})
		return
	end
	-- 对齐 fota_test.lua：IOT 场景优先使用轻参数，让 libfota2 使用默认 imei/firmware_name 规则
	local req = {
		project_key = opts.project_key,
		version = opts.version,
		timeout = opts.timeout,
	}
	if opts.imei and opts.imei ~= "" then req.imei = opts.imei end
	if opts.firmware_name and opts.firmware_name ~= "" then req.firmware_name = opts.firmware_name end
	libfota2.request(cbFnc, req)
end
local function autoOta(data)
	sys.taskInit(function()
		if busy then
			reportStatus("busy", -1, "ota_in_progress", data)
			return
		end
		data = type(data) == "table" and data or {}
		lastPayload = data
		requestCount = requestCount + 1
		lastRequestTime = os.time()
	local logMsg = string.format("ota_start request_count=%d version=%s product_key=%s mqtt_pk=%s", requestCount, 
		tostring(data.version or ""), 
		tostring(data.product_key or _G.PRODUCT_KEY or ""),
		tostring(data.product_key or ""))
	if log and log.info then log.info(L, logMsg) end
		local netOk, ip = waitNetworkReady(config.network_wait_ms)
		if not netOk then
			if log and log.warn then log.warn(L, "ota_network_fail", "timeout=" .. tostring(config.network_wait_ms)) end
			reportStatus("failed", 1, "network_not_ready", data)
			return
		end
		if log and log.info then log.info(L, "ota_network_ok", "ip=" .. tostring(ip or "")) end
		local opts = buildIotOpts(data)
		local valid, err = validateIotConfig(opts)
		if not valid then
			if log and log.warn then log.warn(L, "ota_config_invalid", tostring(err or "")) end
			reportStatus("failed", 5, err, data)
			return
		end
		busy = true
		if log and log.info then log.info(L, "ota_checking", "url=" .. tostring(opts.url or "") .. " custom=" .. tostring(opts.custom == true)) end
		reportStatus("starting", 0, "check_upgrade", data)
		sys.wait(config.request_delay_ms or 500)
		local done = false
		local function wrapped_cb(ret)
			if done then return end
			done = true
			if log and log.info then 
				local retMsg = FOTA_RET[ret] or { "failed", "unknown_ret_" .. tostring(ret) }
				log.info(L, "ota_callback", "ret=" .. tostring(ret) .. " stage=" .. tostring(retMsg[1]) .. " msg=" .. tostring(retMsg[2]))
			end
			fota_cb(ret)
		end
		requestLibFota(opts, wrapped_cb)
		local timeoutMs = tonumber(config.callback_timeout_ms) or 320000
		sys.wait(timeoutMs)
		if not done then
			busy = false
			if log and log.warn then log.warn(L, "ota_callback_timeout", "timeout=" .. tostring(timeoutMs)) end
			reportStatus("failed", -1, "callback_timeout", data)
		end
	end)
end
function configure(newConfig)
	mergeConfig(newConfig)
	return config
end
function getConfig()
	return config
end
function request(data)
	autoOta(data)
	return true
end
function start(options)
	if started then return false end
	if _G.FOTA_CFG then mergeConfig(_G.FOTA_CFG) end
	if options and options.publishStatus then handlers.publishStatus = options.publishStatus end
	if options then mergeConfig(options) end
	local evt = (_G.APP_EVENTS and _G.APP_EVENTS.DEVICE_OTA_REQUEST) or "device_ota_request"
	sys.subscribe(evt, autoOta)
	sys.subscribe("REST_SEND_OTA", autoOta)
	started = true
	return true
end
function getState()
	return {
		started = started,
		busy = busy,
		request_count = requestCount,
		last_result = lastResult,
		product_key = _G.PRODUCT_KEY,
		iot_version = _G.IOT_VERSION,
	}
end
return _M
