require "sys"
require "config"
local pir_ctrl = require "pir_ctrl"
local ipc_sup = require "ipc_supervision"
local hostUartMod
local function getHostUart()
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
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local NC = "mqtt_not_connected"
local L = "net_mqtt"
local function mqttLogEnabled()
	return _G.APP_META and _G.APP_META.log_enabled == true
end
local function mqttInfo(...)
	if log and log.info then
		log.info(L, ...)
	end
end
local function mqttWarn(...)
	if log and log.warn then
		log.warn(L, ...)
	elseif log and log.info then
		log.info(L, ...)
	end
end
local function mqttError(...)
	if log and log.error then
		log.error(L, ...)
	end
end
local DT = {
	UL_WAKEUP = "1001",
	UL_REST = "1002",
	UL_STATUS = "1003",
	UL_CONTROL = "1004",
	UL_SIM = "1005",
	UL_DEVICE_ID = "1006",
	UL_TF_CARD = "1007",
	UL_TF_FORMAT = "1009",
	UL_VERSION_QUERY = "1008",
	UL_PIR_DETECT = "1010",
	UL_PIR_STOP = "1011",
	UL_PIR_START = "1012",
	UL_ENCODE_SET = "1021",
	UL_ENCODE_QUERY = "1020",
	UL_RECORD_TIME_QUERY = "1022",
	UL_RECORD_TIME_SET = "1023",
	UL_FRAMERATE_QUERY = "1024",
	UL_FRAMERATE_SET = "1025",
	UL_PERSON_DETECT_QUERY = "1026",
	UL_PERSON_DETECT_SET = "1027",
	UL_MIC_QUERY = "1028",
	UL_MIC_SET = "1029",
	UL_SOFTPHOTO_QUERY = "1030",
	UL_SOFTPHOTO_SET = "1031",
	DL_WAKEUP = "2001",
	DL_REST = "2002",
	DL_STATUS = "2003",
	DL_CONTROL = "2004",
	DL_SIM = "2005",
	DL_DEVICE_ID = "2006",
	DL_TF_CARD = "2007",
	DL_TF_FORMAT = "2009",
	DL_VERSION_QUERY = "2008",
	DL_PIR_CFG = "2010",
	DL_PIR_STOP = "2011",
	DL_PIR_START = "2012",   -- → UL 1012 event
	DL_ENCODE_SET = "2021",  -- → UL 1021 encode（AT+VENCSET/AUDIOSET）
	DL_ENCODE_QUERY = "2020", -- → UL 1020 encode（AT+VENC?/AUDIO?）
	DL_RECORD_TIME_QUERY = "2022", -- → UL 1022 recordTime（AT+RECORDTIME?）
	DL_RECORD_TIME_SET = "2023",   -- → UL 1023 recordTime（AT+RECORDTIME=）
	DL_FRAMERATE_QUERY = "2024", -- → UL 1024 framerate（AT+FRAMERATE?）
	DL_FRAMERATE_SET = "2025",   -- → UL 1025 framerate（AT+FRAMERATE=）
	DL_PERSON_DETECT_QUERY = "2026", -- → UL 1026 personDetect（AT+PERSONDET?）
	DL_PERSON_DETECT_SET = "2027",   -- → UL 1027 personDetect（AT+PERSONDET=）
	DL_MIC_QUERY = "2028",           -- → UL 1028 mic（AT+MIC?）
	DL_MIC_SET = "2029",             -- → UL 1029 mic（AT+MICSET=）
	DL_SOFTPHOTO_QUERY = "2030",     -- → UL 1030 softPhoto（AT+SOFTPHOTO?）
	DL_SOFTPHOTO_SET = "2031",       -- → UL 1031 softPhoto（AT+SOFTPHOTOSET=）
}
local started = false
local mqttClient = nil
local isConnected = false
local batteryStatusSubscribed = false
local lastBatteryStatusPublishSec = 0
local statusReportTimerStarted = false
local identityPublished = false
local identityAutoHooked = false
local callbacks = {
	onOffline = nil,
	onMessage = nil,
}
local state = {
	last_event = nil,
	reconnect_count = 0,
	last_publish_topic = nil,
}
local pendingHostQueue = {}
local pendingHostDrainHooked = false
local HOST_DL_NEEDS_T3X = {
	[DT.DL_DEVICE_ID] = true,
	[DT.DL_TF_CARD] = true,
	[DT.DL_TF_FORMAT] = true,
	[DT.DL_ENCODE_QUERY] = true,
	[DT.DL_ENCODE_SET] = true,
	[DT.DL_RECORD_TIME_QUERY] = true,
	[DT.DL_RECORD_TIME_SET] = true,
	[DT.DL_FRAMERATE_QUERY] = true,
	[DT.DL_FRAMERATE_SET] = true,
	[DT.DL_PERSON_DETECT_QUERY] = true,
	[DT.DL_PERSON_DETECT_SET] = true,
	[DT.DL_MIC_QUERY] = true,
	[DT.DL_MIC_SET] = true,
	[DT.DL_SOFTPHOTO_QUERY] = true,
	[DT.DL_SOFTPHOTO_SET] = true,
}
local DOWNLINK_HANDLERS
local function getDeviceId()
	local ok, did = pcall(require, "device_id")
	if ok and type(did) == "table" and did.getDeviceId then
		return did.getDeviceId()
	end
	return "unknown_device"
end
local function getPubTopic() return "/panshi/app/" .. getDeviceId() .. "/" end
local function getSubTopic() return "/panshi/device/" .. getDeviceId() .. "/" end
local function mqttConnectedEvent()
	return (_G.APP_EVENTS or {}).MQTT_CONNECTED or "mqtt_connected"
end
local function getSubTopicFilter()
	return "/panshi/device/" .. getDeviceId() .. "/#"
end
local function subscribeDownlink(client)
	local filter = getSubTopicFilter()
	local pkgid = client:subscribe(filter, 1)
	if pkgid then
		mqttInfo("subscribe_downlink", filter, pkgid)
	else
		mqttWarn("subscribe_downlink_failed", filter)
	end
	return pkgid ~= nil
end
local function isDownlinkTopic(topic)
	if type(topic) ~= "string" or topic == "" then
		return true
	end
	local prefix = "/panshi/device/" .. getDeviceId()
	if topic == prefix or topic == prefix .. "/" then
		return true
	end
	return topic:sub(1, #prefix + 1) == prefix .. "/"
end
local function publishAppEvent(eventKey, ...)
	local name = APP_EVENTS and APP_EVENTS[eventKey]
	if name then
		sys.publish(name, ...)
	end
end
local function escJson(s)
	return tostring(s or ""):gsub('"', '\\"')
end
local function msgIdPart(messageId)
	if messageId and messageId ~= "" then
		return string.format(',"messageId":"%s"', escJson(tostring(messageId)))
	end
	return ""
end
local function mqttTimestamp()
	return os.date("%Y-%m-%d %H:%M:%S")
end
local function formatUplink(dataType, fields)
	fields = fields or ""
	return string.format(
		'{"deviceNo":"%s","dataType":"%s"%s,"time":"%s"}',
		getDeviceId(), dataType, fields, mqttTimestamp())
end
local function publishUplink(opts)
	opts = opts or {}
	if not isConnected then
		mqttWarn("publish_skip_not_connected", opts.dataType or "", opts.suffix or "")
		return false
	end
	local topic = getPubTopic() .. (opts.suffix or "event")
	local payload = opts.payload or formatUplink(opts.dataType, opts.fields)
	if opts.dataType ~= DT.UL_STATUS or mqttLogEnabled() then
		mqttInfo("uplink", opts.dataType or "", topic)
	end
	sys.publish("mqtt_pub", topic, payload, opts.qos or 1)
	if opts.app_event_fn then
		opts.app_event_fn(topic, payload)
	elseif opts.app_event then
		publishAppEvent(opts.app_event, topic, payload)
	end
	if opts.on_published then
		opts.on_published(topic, payload)
	end
	return true
end
local netReadyPublished = false
local bootstrapStarted = false
local function getWledState()
	local hu = getHostUart()
	if hu and hu.getWled then
		return hu.getWled() == 1 and 1 or 0
	end
	if _G.APP_RUNTIME and _G.APP_RUNTIME.wled_on ~= nil then
		return _G.APP_RUNTIME.wled_on == 1 and 1 or 0
	end
	return 0
end
local function getCellular()
	local ok, mod = pcall(require, "cellular_bootstrap")
	if ok then
		return mod
	end
	return nil
end
function bootstrapNetwork()
	if bootstrapStarted then
		return false
	end
	bootstrapStarted = true
	sys.taskInit(function()
		local cellular = getCellular()
		local ipOk, ip
		if cellular and cellular.waitForNetwork and (_G.MODULE_FLAGS.cellular ~= false) then
			ipOk, ip = cellular.waitForNetwork()
		else
			ipOk = sys.waitUntil("IP_READY", 300000)
			ip = (socket and socket.localIP and socket.localIP()) or nil
		end
		if ipOk and ip then
		else
		end
		if not netReadyPublished then
			netReadyPublished = true
			local id = getDeviceId()
			sys.publish("net_ready", id, ipOk and ip ~= nil)
		end
	end)
	return true
end
local function waitForNetworkReady()
	if netReadyPublished then
		return true, getDeviceId()
	end
	if socket and socket.localIP then
		local ip = socket.localIP()
		if ip and ip ~= "" and ip ~= "0.0.0.0" then
			return true, getDeviceId()
		end
	end
	local gotReady, deviceId = sys.waitUntil("net_ready", 300000)
	if not gotReady then
		gotReady = sys.waitUntil("IP_READY", 120000)
	end
	if not deviceId or deviceId == "" then
		deviceId = getDeviceId()
	end
	return gotReady ~= false and gotReady ~= nil, deviceId
end
local function normalizeDataType(data)
	if type(data) ~= "table" or data.dataType == nil then
		return nil
	end
	return tostring(data.dataType)
end
local function collectSimSnapshot()
	local snap = {
		imei = mobile.imei() or "",
		imsi = mobile.imsi() or "",
		iccid = mobile.iccid() or "",
		status = mobile.status and mobile.status() or "",
		csq = mobile.csq and mobile.csq() or "",
		rssi = mobile.rssi and mobile.rssi() or "",
		rsrq = mobile.rsrq and mobile.rsrq() or "",
		rsrp = mobile.rsrp and mobile.rsrp() or "",
		snr = mobile.snr and mobile.snr() or "",
		simid = mobile.simid and mobile.simid() or "",
		ip = socket and socket.localIP and socket.localIP() or "",
		operator = "",
		operator_name = "",
	}
	local okApn, apn = pcall(mobile.apn, 0, 1)
	if okApn and apn then
		snap.apn = apn
	end
	local okCell, cellular = pcall(require, "cellular_bootstrap")
	if okCell and cellular and cellular.resolveOperator then
		snap.operator, snap.operator_name = cellular.resolveOperator(snap.imsi, snap.iccid, snap.apn)
	end
	local rt = _G.APP_RUNTIME
	if snap.operator == "unknown" and rt and rt.sim_operator and rt.sim_operator ~= "" and rt.sim_operator ~= "unknown" then
		snap.operator = rt.sim_operator
		snap.operator_name = rt.sim_operator_name or snap.operator_name
	end
	if not snap.apn and rt and rt.cellular_apn then
		snap.apn = rt.cellular_apn
	end
	return snap
end
local function collectBatterySnapshot()
	local rt = _G.APP_RUNTIME or {}
	local snap = {
		power_status = tonumber(rt.power_status) or 0,
		battery_percent = rt.battery_percent or "--",
		battery_mv = rt.battery_mv or "--",
		low_power_mode = (rt.low_power_mode == 1) and "rest" or "normal",
		usb_inserted = 0,
		charging = 0,
	}
	snap.usb_inserted = snap.power_status == 1 and 1 or 0
	local ok, uc = pcall(require, "usb_charge")
	if ok and type(uc) == "table" then
		if type(uc.isUsbInserted) == "function" then
			snap.usb_inserted = uc.isUsbInserted() and 1 or 0
			snap.power_status = snap.usb_inserted
		end
		if type(uc.isCharging) == "function" then
			snap.charging = uc.isCharging() and 1 or 0
		end
	end
	if snap.usb_inserted ~= 1 then
		snap.charging = 0
	end
	return snap
end
local IV_CFG = (_G.APP_PERSIST_CFG and _G.APP_PERSIST_CFG.mqtt_status)
	or "/mqtt_status_cfg.json"
local IV_SCHEMA = (_G.APP_PERSIST_CFG and _G.APP_PERSIST_CFG.mqtt_status_schema) or 1
local IV_MIN, IV_MAX = 10, 86400
local function clampIv(v)
	v = tonumber(v)
	if not v then
		return nil
	end
	v = math.floor(v)
	if v < IV_MIN then
		return IV_MIN
	end
	if v > IV_MAX then
		return IV_MAX
	end
	return v
end
local function syncIv(sec)
	local rt, lp = _G.APP_RUNTIME, _G.LOW_POWER_CFG
	if rt then
		rt.low_power_interval_sec = sec
	end
	if lp then
		lp.rest_mqtt_interval_sec = sec
	end
end
local function saveIvCfg(sec)
	local payload = json.encode({
		schemaVersion = IV_SCHEMA,
		status_interval_sec = sec,
		updated_at = os.time(),
	})
	if not payload then
		return false
	end
	local wf = io.open(IV_CFG, "w")
	if not wf then
		return false
	end
	wf:write(payload)
	wf:close()
	return true
end
local function loadIvCfg()
	local f = io.open(IV_CFG, "r")
	if not f then
		return
	end
	local s = f:read("*a")
	f:close()
	if not s or s == "" then
		return
	end
	local ok, d = pcall(json.decode, s)
	if not ok or type(d) ~= "table" then
		return
	end
	local sec = clampIv(d.status_interval_sec)
	if sec then
		syncIv(sec)
	else
	end
end
local function notifyStatusReportIntervalChanged()
	local ev = (_G.APP_EVENTS or {}).MQTT_STATUS_INTERVAL_CHANGED or "APP_MQTT_STATUS_INTERVAL_CHANGED"
	sys.publish(ev)
end
function setStatusIntervalSec(sec, persist)
	sec = clampIv(sec)
	if not sec then
		return false, "invalid_interval"
	end
	syncIv(sec)
	if persist and not saveIvCfg(sec) then
		notifyStatusReportIntervalChanged()
		return false, "persist_fail"
	end
	notifyStatusReportIntervalChanged()
	return true
end
local function getStatusReportIntervalSec()
	local sec = clampIv((_G.APP_RUNTIME or {}).low_power_interval_sec)
	if sec then
		return sec
	end
	sec = clampIv((_G.LOW_POWER_CFG or {}).rest_mqtt_interval_sec)
	if sec then
		return sec
	end
	return clampIv((_G.BATTERY_CFG or {}).mqtt_report_interval_sec) or 30
end
local function startStatusReportTimer()
	if statusReportTimerStarted then
		return
	end
	statusReportTimerStarted = true
	sys.taskInit(function()
		while true do
			local intervalSec = getStatusReportIntervalSec()
			local changed = sys.waitUntil(
				(_G.APP_EVENTS or {}).MQTT_STATUS_INTERVAL_CHANGED or "APP_MQTT_STATUS_INTERVAL_CHANGED",
				intervalSec * 1000)
			if not changed and isConnected then
				publishStatus()
			end
		end
	end)
end
local function setupBatteryStatusReport()
	if batteryStatusSubscribed then
		return
	end
	batteryStatusSubscribed = true
	sys.subscribe("BATTERY_UPDATE", function()
		if not isConnected then
			return
		end
		local intervalSec = getStatusReportIntervalSec()
		local minSec = tonumber((_G.BATTERY_CFG or {}).mqtt_battery_report_min_sec) or 30
		if intervalSec > minSec then
			minSec = intervalSec
		end
		local now = os.time()
		if now - lastBatteryStatusPublishSec < minSec then
			return
		end
		lastBatteryStatusPublishSec = now
		sys.taskInit(function()
			publishStatus()
		end)
	end)
end
local function handleDownlink2001(data)
	publishWakeup()
end
local function resolve2002Mode(data)
	local mode = data.lowPowerMode
	if mode == "enter" or mode == "exit" then
		return mode
	end
	local action = tonumber(data.action)
	if action == 1 then
		return "enter"
	end
	if action == 0 then
		return "exit"
	end
	return nil
end
local function usbBlocks4gRest()
	local ok, up = pcall(require, "usb_policy")
	if ok and type(up) == "table" and up.blocks4gRest then
		return up.blocks4gRest()
	end
	return (_G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.power_status) == 1) or false
end
local function handleDownlink2002(data)
	local mode = resolve2002Mode(data)
	if mode == "enter" then
		if usbBlocks4gRest() then
			return
		end
		sys.publish(APP_EVENTS.POWER_ENTER_REST)
	elseif mode == "exit" then
		sys.publish(APP_EVENTS.POWER_EXIT_REST)
	else
	end
end
local function handleDownlink2003(data)
	if data.usbRecoveryReset == 1 or data.action == "usbRecoveryReset" then
		local hu = getHostUart()
		local ok = false
		if hu and hu.resetUsbRecoveryFromCloud then
			ok = hu.resetUsbRecoveryFromCloud()
		end
		publishStatus({
			messageId = data.messageId or "",
			configRet = ok and 0 or -1,
			configMsg = ok and "usb_recovery_reset" or "usb_recovery_reset_fail",
		})
		return
	end
	if data.interval ~= nil then
	else
	end
	local messageId = data.messageId or ""
	local configRet = 0
	local configMsg = "ok"
	if data.interval ~= nil then
		if setStatusIntervalSec(data.interval, true) then
		else
			configRet = -1
			configMsg = "invalid_interval"
		end
	end
	publishStatus({
		messageId = messageId,
		configRet = configRet,
		configMsg = configMsg,
	})
end
local function fetchWledFromHost()
	local on = getWledState()
	local hu = getHostUart()
	if hu and hu.queryHostWled and hu.isHostAtReady and hu.isHostAtReady() then
		on = hu.queryHostWled() or on
	end
	return on
end
local function makeDownlink2004Reply(data)
	local action = data.action
	local messageId = data.messageId or ""
	return function(ret, msg, act, extraFields)
		local extra = { messageId = messageId }
		if type(extraFields) == "table" then
			for k, v in pairs(extraFields) do
				extra[k] = v
			end
		end
		publishControlReply(act or action, ret, msg, extra)
	end
end
local function runWledQuery2004(reply)
	sys.taskInit(function()
		local on = fetchWledFromHost()
		reply(0, "ok", "wled", { enable = on })
	end)
end
local function runWledSet2004(reply, on)
	sys.taskInit(function()
		local hu = getHostUart()
		local ok = true
		if hu and hu.setWled then
			ok = hu.setWled(on, { sync = true }) == true
		elseif _G.APP_RUNTIME then
			_G.APP_RUNTIME.wled_on = on
		end
		if ok then
			reply(0, "ok", "wled", { enable = on })
		else
			reply(-1, "wled_forward_fail", "wled", { enable = getWledState() })
		end
	end)
end
local function normalize2004Action(action)
	if action == nil then
		return action
	end
	action = tostring(action)
	local aliases = {
		restart = "reboot",
		shutdown = "off",
		poweroff = "off",
		upgrade = "ota",
		fota = "ota",
	}
	return aliases[action] or action
end
local function resolve2004Action(action, data)
	if action == "wled_query" or action == "wled?" then
		return "wled_query"
	end
	if action == "wled" and (data.query == 1 or data.query == true) then
		return "wled_query"
	end
	if action == "wled" or action == "wled_on" or action == "wled_off" then
		return "wled_set"
	end
	return action
end
local function parse2004WledEnable(action, data)
	if action == "wled_on" then
		return 1
	end
	if action == "wled_off" then
		return 0
	end
	return tonumber(data.enable)
end
local DL2004_ACTIONS = {
	reboot = function(_data, reply)
		reply(0, "ok", "reboot")
		sys.publish(APP_EVENTS.DEVICE_REBOOT_REQUEST)
	end,
	off = function(_data, reply)
		reply(0, "ok", "off")
		sys.publish(APP_EVENTS.DEVICE_POWER_OFF_REQUEST)
	end,
	ota = function(data, reply)
		if _G.validateBuildVersion then
			local v = data.version
			if v and v ~= "" then
				local ok = _G.validateBuildVersion(tostring(v))
				if not ok then
					reply(-1, "invalid_version_format", "ota")
					return
				end
				data.version = ok
			end
		end
		reply(0, "ota_accepted", "ota")
		publishAppEvent("DEVICE_OTA_REQUEST", data)
	end,
	wled_query = function(_data, reply)
		runWledQuery2004(reply)
	end,
}
local function handleDownlink2004(data)
	data.action = normalize2004Action(data.action)
	local reply = makeDownlink2004Reply(data)
	local resolved = resolve2004Action(data.action, data)
	if resolved == "wled_set" then
		local on = parse2004WledEnable(data.action, data)
		if on ~= 0 and on ~= 1 then
			reply(-1, "invalid_wled", "wled")
			return
		end
		runWledSet2004(reply, on)
		return
	end
	local fn = DL2004_ACTIONS[resolved]
	if fn then
		fn(data, reply)
		return
	end
	reply(-1, "unknown_action", data.action or "")
end
local function handleDownlink2005(data)
	publishSimInfo()
end
local function identityCfg()
	return _G.HOST_IDENTITY_CFG or {}
end
local function identityEnabled()
	if identityCfg().enabled == false then
		return false
	end
	return true
end
local function refreshDeviceIdentity(messageId)
	local imei = getDeviceId()
	local gb28181Id
	local hu = getHostUart()
	if hu and hu.queryHostGb28181 then
		gb28181Id = hu.queryHostGb28181(identityCfg().query_timeout_ms)
	elseif hu and hu.getCachedHostGb28181Id then
		gb28181Id = hu.getCachedHostGb28181Id()
	end
	publishDeviceIdentity(imei, gb28181Id, messageId)
end
local function isT3xHostReady()
	local hu = getHostUart()
	if hu and hu.isHostAtReady then
		return hu.isHostAtReady() == true
	end
	local ok, t3x = pcall(require, "t3x_ctrl")
	if ok and t3x and t3x.getState then
		local st = t3x.getState()
		return st and st.powered_on == true
	end
	return false
end
local function enqueuePendingHostWork(dtype, data)
	pendingHostQueue[#pendingHostQueue + 1] = {
		dtype = dtype,
		data = data,
		ts = os.time(),
	}
end
local function wakeT3xForPendingHost()
	sys.taskInit(function()
		local ok, ts = pcall(require, "time_sync")
		if ok and ts and ts.pushBeforeNotifyAsync then
			ts.pushBeforeNotifyAsync((_G.HOST_WAKE_CFG or {}).default_sid or 1, 0)
		else
			local hu = getHostUart()
			if hu and hu.notify_host then
				hu.notify_host((_G.HOST_WAKE_CFG or {}).default_sid or 1, 0)
			end
		end
	end)
end
function drainPendingHostWork()
	if #pendingHostQueue == 0 then
		return 0
	end
	if not isT3xHostReady() then
		return 0
	end
	local batch = pendingHostQueue
	pendingHostQueue = {}
	for _, item in ipairs(batch) do
		local handler = DOWNLINK_HANDLERS[item.dtype]
		if handler and item.data then
			handler(item.data)
		end
	end
	return #batch
end
local function handleHostDownlink(dtype, data, runFn)
	if HOST_DL_NEEDS_T3X[dtype] and not isT3xHostReady() then
		enqueuePendingHostWork(dtype, data)
		wakeT3xForPendingHost()
		return
	end
	runFn()
end
local function downlinkMessageId(data)
	return data.messageId or data.msgId or ""
end
local function publishReplyBase(opts)
	local fields = string.format(
		',"reply":1,"messageId":"%s","ret":%s,"message":"%s"',
		escJson(opts.messageId or ""),
		tostring(opts.retCode ~= nil and opts.retCode or -1),
		escJson(opts.message or ""))
	if opts.appendFields then
		fields = fields .. opts.appendFields(opts.body)
	end
	publishUplink({
		suffix = opts.suffix,
		dataType = opts.dataType,
		no_conn = NC,
		fields = fields
	})
end
local function wrapHostDownlink(dlType, handler, isQuery)
	return function(data)
		handleHostDownlink(dlType, data, function()
			handler(data, isQuery)
		end)
	end
end
local function handleDownlink2006(data)
	handleHostDownlink(DT.DL_DEVICE_ID, data, function()
		sys.taskInit(function()
			refreshDeviceIdentity(data.messageId)
		end)
	end)
end
local function tfCardCfg()
	return _G.HOST_TFCARD_CFG or {}
end
local function tfCardEnabled()
	if tfCardCfg().enabled == false then
		return false
	end
	return true
end
local function refreshTfCardStatus(messageId)
	if not tfCardEnabled() then
		publishTfCardStatus({ present = 0, total_mb = 0, used_mb = 0, free_mb = 0 }, messageId)
		return
	end
	local hu = getHostUart()
	local snap
	if hu and hu.queryHostTfCard then
		snap = hu.queryHostTfCard(tfCardCfg().query_timeout_ms)
	elseif hu and hu.getCachedHostTfCard then
		snap = hu.getCachedHostTfCard()
	end
	if snap == nil then
		publishTfCardStatus({ present = 0, total_mb = 0, used_mb = 0, free_mb = 0, timeout = true }, messageId)
		return
	end
	publishTfCardStatus(snap, messageId)
end
local function handleDownlink2007(data)
	handleHostDownlink(DT.DL_TF_CARD, data, function()
		sys.taskInit(function()
			refreshTfCardStatus(data.messageId)
		end)
	end)
end
local function collectVersionSnapshot(messageId)
	local scriptVersion = tostring(_G.VERSION or "")
	local firmwareVersion = ""
	if _G.resolveIotOtaVersion then
		firmwareVersion = _G.resolveIotOtaVersion(scriptVersion) or ""
	elseif _G.IOT_VERSION then
		firmwareVersion = tostring(_G.IOT_VERSION)
	end
	local coreVersion = ""
	if rtos and rtos.version then
		local raw = rtos.version() or ""
		if raw:sub(1, 1) == "V" or raw:sub(1, 1) == "v" then
			raw = raw:sub(2)
		end
		coreVersion = raw:match("^(%d+)") or raw
	end
	return {
		scriptVersion = scriptVersion,
		firmwareVersion = firmwareVersion,
		coreVersion = coreVersion,
		project = tostring(_G.PROJECT or ""),
		buildTag = tostring(_G.BUILD_TAG or ""),
		productKey = tostring(_G.PRODUCT_KEY or ""),
		messageId = messageId,
	}
end
function publishVersion(opts)
	opts = type(opts) == "table" and opts or {}
	local snap = collectVersionSnapshot(opts.messageId)
	local mid = ""
	if snap.messageId and snap.messageId ~= "" then
		mid = string.format(',"messageId":"%s"', escJson(tostring(snap.messageId)))
	end
	publishUplink({
		suffix = "version",
		dataType = DT.UL_VERSION_QUERY,
		fields = string.format(
			',"scriptVersion":"%s","firmwareVersion":"%s","coreVersion":"%s","project":"%s","buildTag":"%s","productKey":"%s"%s',
			escJson(snap.scriptVersion),
			escJson(snap.firmwareVersion),
			escJson(snap.coreVersion),
			escJson(snap.project),
			escJson(snap.buildTag),
			escJson(snap.productKey),
			mid)
	})
end
local function handleDownlink2008(data)
	publishVersion({ messageId = downlinkMessageId(data) })
end
local function tfFormatCfg()
	return _G.HOST_TFCARD_FORMAT_CFG or {}
end
local function tfFormatEnabled()
	return tfFormatCfg().enabled ~= false
end
local function stopRecordingBeforeTfFormat()
	if pir_ctrl.suspend then
		pir_ctrl.suspend()
	end
	local hu = getHostUart()
	if hu and hu.recordCtrlStop and isT3xHostReady() then
		local rok, rmsg = hu.recordCtrlStop({
			reason = "tfcard_format",
			timeout_ms = tonumber(tfFormatCfg().record_stop_timeout_ms) or 15000,
		})
	end
	sys.wait(tonumber(tfFormatCfg().pre_format_wait_ms) or 500)
end
local function runTfCardFormat(messageId, reboot)
	if not tfFormatEnabled() then
		publishTfFormatResult(-1, "disabled", messageId, { reboot = reboot })
		return
	end
	local hu = getHostUart()
	if not hu or not hu.formatHostTfCard then
		publishTfFormatResult(-1, "no_uart", messageId, { reboot = reboot })
		return
	end
	stopRecordingBeforeTfFormat()
	local ok, detail = hu.formatHostTfCard({
		reboot = reboot,
		timeout_ms = tfFormatCfg().format_timeout_ms,
	})
	if ok then
		local extra = type(detail) == "table" and detail or { reboot = reboot }
		publishTfFormatResult(0, "ok", messageId, extra)
		if tfFormatCfg().publish_status_after ~= false
			and (extra.reboot or 0) == 0 then
			sys.wait(1000)
			refreshTfCardStatus(messageId)
		end
	else
		publishTfFormatResult(-1, tostring(detail or "error"), messageId, { reboot = reboot })
	end
end
local function handleDownlink2009(data)
	local action = data.action or "format"
	if action ~= "format" then
		publishTfFormatResult(-1, "unknown_action", data.messageId, {})
		return
	end
	local reboot = data.reboot
	if reboot == nil then
		reboot = tfFormatCfg().reboot_after == true or tfFormatCfg().reboot_after == 1
	end
	reboot = (reboot == 1 or reboot == true) and 1 or 0
	handleHostDownlink(DT.DL_TF_FORMAT, data, function()
		sys.taskInit(function()
			runTfCardFormat(data.messageId, reboot)
			if pir_ctrl.resume and (reboot or 0) == 0 then
				pir_ctrl.resume()
			end
		end)
	end)
end
local function maybeAutoPublishIdentity()
	if not identityEnabled() or identityCfg().auto_publish_on_ready == false then
		return
	end
	if identityPublished or not isConnected then
		return
	end
	local hu = getHostUart()
	if not hu or not hu.isHostAtReady or not hu.isHostAtReady() then
		return
	end
	identityPublished = true
	sys.taskInit(function()
		sys.wait(tonumber(identityCfg().auto_publish_delay_ms) or 500)
		refreshDeviceIdentity(nil)
	end)
end
local function setupIdentityAutoPublish()
	if identityAutoHooked or not identityEnabled() then
		return
	end
	identityAutoHooked = true
	local evt = (_G.APP_EVENTS and _G.APP_EVENTS.HOST_UART_FIRST_AT) or "APP_HOST_UART_FIRST_AT"
	sys.subscribe(evt, function()
		maybeAutoPublishIdentity()
	end)
	sys.subscribe(mqttConnectedEvent(), function()
		maybeAutoPublishIdentity()
	end)
end
local function buildPirDetectExtra(pirStatus, action, uploadMode, quality, recording)
	local st = pir_ctrl.getState()
	local media = st.mediaConfig or {}
	return {
		status = pirStatus or "detected",
		action = action or media.action or "",
		uploadMode = uploadMode or media.uploadMode or "",
		quality = quality or media.quality or "",
		recording = recording ~= nil and recording or (st.recording and 1 or 0),
	}
end
local function is2010Query(data)
	if data.query == 1 or data.query == true then
		return true
	end
	local act = data.action
	return act == "query" or act == "status"
end
local function handleDownlink2010(data)
	if is2010Query(data) then
		publishPirDetect(buildPirDetectExtra("query", nil, nil, nil, nil))
		return
	end
	local hasCfg = data.action or data.uploadMode or data.quality
		or data.videoMaxDurationSec
		or data.stopOnSecondPir ~= nil or data.stopOnCloud ~= nil
		or data.startOnCloud ~= nil
	if hasCfg then
		pir_ctrl.setMediaConfig({
			action = data.action,
			uploadMode = data.uploadMode,
			quality = data.quality,
		})
		pir_ctrl.setRecordPolicy({
			maxDurationSec = data.videoMaxDurationSec,
			stopOnSecondPir = data.stopOnSecondPir,
			stopOnCloud = data.stopOnCloud,
			startOnCloud = data.startOnCloud,
		})
		local pirState = pir_ctrl.getState()
		local media = pirState.mediaConfig or {}
		publishPirFromState({
			pirStatus = "config_ok",
			action = media.action or "video",
		})
	else
		publishPirFromState({
			pirStatus = "config_rejected",
			status = "config_rejected",
		})
	end
end
local function handleDownlink2011(data)
	local messageId = data.messageId or ""
	if messageId ~= "" then
	else
	end
	local ok, err = pir_ctrl.requestStopFromCloud({ messageId = messageId })
	if ok then
		publishControlReply("pir_stop", 0, "ok", { messageId = messageId })
		if isT3xHostReady() then
			local hu = getHostUart()
			if hu and hu.recordCtrlStop then
				sys.taskInit(function()
					local rok, rmsg = hu.recordCtrlStop({ reason = "cloud", timeout_ms = 8000 })
				end)
			end
		end
	else
		local st = pir_ctrl.getState()
		local pol = st.recordPolicy or {}
		err = err or "rejected"
		publishControlReply("pir_stop", -1, err, { messageId = messageId })
	end
end
local function handleDownlink2012(data)
	sys.taskInit(function()
		local messageId = downlinkMessageId(data)
		if data.messageId then
		else
		end
		if not pir_ctrl.requestStartFromCloud then
			publishControlReply("pir_start", -1, "no_fn", { messageId = messageId })
			return
		end
		local ok, result = pir_ctrl.requestStartFromCloud({
			action = data.action,
			uploadMode = data.uploadMode,
			quality = data.quality,
			videoMaxDurationSec = data.videoMaxDurationSec,
		})
		if ok then
			publishControlReply("pir_start", 0, "ok", { messageId = messageId })
			local media = type(result) == "table" and result or {}
			local st = pir_ctrl.getState()
			publishPirRecordStart(
				media.action or (st.mediaConfig and st.mediaConfig.action) or "video",
				media.uploadMode or st.uploadMode or "auto",
				media.quality or st.quality or "high",
				{ source = "4g", messageId = messageId }
			)
			if isT3xHostReady() then
				local hu = getHostUart()
				if hu and hu.recordCtrlStart then
					sys.taskInit(function()
						local maxSec = tonumber(data.videoMaxDurationSec) or 90
						local rok, rmsg = hu.recordCtrlStart({
							max_sec = maxSec,
							timeout_ms = 10000,
						})
						if not rok then
							publishIpcAlert("recordctrl_fail", rmsg or "start")
						end
					end)
				end
			end
		else
			local err = result or "rejected"
			publishControlReply("pir_start", -1, err, { messageId = messageId })
		end
	end)
end
local function publishEncodeReply(dlType, retCode, message, body, messageId)
	local ulType = (dlType == DT.DL_ENCODE_QUERY) and DT.UL_ENCODE_QUERY or DT.UL_ENCODE_SET
	publishReplyBase({
		dataType = ulType,
		suffix = "encode",
		retCode = retCode,
		message = message,
		messageId = messageId,
		body = body,
		appendFields = function(b)
			local extra = ""
			if type(b) == "table" then
				if b.needReboot ~= nil then
					extra = extra .. string.format(',"needReboot":%s',
						(b.needReboot == true or b.needReboot == 1) and "1" or "0")
				end
				if b.runtimeApply ~= nil then
					extra = extra .. string.format(',"runtimeApply":%d', tonumber(b.runtimeApply) or 0)
				end
				local ok, encoded = pcall(json.encode, b)
				if ok and encoded then
					extra = extra .. ',"body":' .. encoded
				end
			end
			return extra
		end,
	})
end
local function handleDownlinkEncode(data, isQuery)
	sys.taskInit(function()
		local hu = getHostUart()
		local dlType = isQuery and DT.DL_ENCODE_QUERY or DT.DL_ENCODE_SET
		if not hu then
			publishEncodeReply(dlType, -1, "no_host_uart", nil, data.messageId)
			return
		end
		if isQuery then
			if not hu.queryHostEncode then
				publishEncodeReply(dlType, -1, "no_host_uart", nil, data.messageId)
				return
			end
			local encCfg = _G.HOST_ENCODE_CFG or {}
			local timeoutMs = tonumber(data.timeoutMs) or tonumber(data.timeout_ms)
				or tonumber(encCfg.query_timeout_ms) or 12000
			local result, err = hu.queryHostEncode({
				scope = data.scope,
				camera = data.camera,
				stream = data.stream,
				timeout_ms = timeoutMs,
			})
			if result then
				publishEncodeReply(dlType, 0, "ok", result, data.messageId)
			else
				publishEncodeReply(dlType, -1, err or "query_fail", nil, data.messageId)
			end
			return
		end
		local ok, msg, extra
		if data.scope == "audio" and hu.setHostAudioEncode then
			ok, msg, extra = hu.setHostAudioEncode(data)
		elseif hu.setHostVideoEncode then
			ok, msg, extra = hu.setHostVideoEncode(data)
		else
			ok, msg, extra = false, "unsupported", nil
		end
		local body = extra or {}
		if ok and extra and extra.needReboot ~= nil then
			body.needReboot = extra.needReboot
		end
		if ok and extra and extra.runtimeApply ~= nil then
			body.runtimeApply = extra.runtimeApply
		end
		publishEncodeReply(dlType, ok and 0 or -1, msg or (ok and "ok" or "fail"), body, data.messageId)
		if ok and extra and tonumber(extra.runtimeApply) == 0 and not extra.needReboot then
			publishIpcAlert("encode_runtime_fail", data.scope or "video")
		end
	end)
end
local function handleDownlink2021(data)
	handleDownlinkEncode(data, false)
end
local function handleDownlink2020(data)
	handleDownlinkEncode(data, true)
end
local RECORD_TIME_ALLOWED = "5|10|15|20|30|45|60"
local RECORD_TIME_ALLOWED_JSON = "[5,10,15,20,30,45,60]"
local function makeQuerySetReplyPublisher(spec)
	return function(dlType, retCode, message, body, messageId)
		local ulType = (dlType == spec.queryDl) and spec.ulQuery or spec.ulSet
		publishReplyBase({
			dataType = ulType,
			suffix = spec.suffix,
			retCode = retCode,
			message = message,
			messageId = messageId,
			body = body,
			appendFields = spec.appendFields,
		})
	end
end
local function makeHostQuerySetHandler(spec)
	local publishReply = makeQuerySetReplyPublisher(spec)
	return function(data, isQuery)
		sys.taskInit(function()
			local hu = getHostUart()
			local dlType = isQuery and spec.queryDl or spec.setDl
			local messageId = downlinkMessageId(data)
			local timeoutMs = tonumber(data.timeoutMs) or tonumber(data.timeout_ms)
				or spec.defaultTimeoutMs or 12000
			if not hu then
				publishReply(dlType, -1, "no_host_uart", nil, messageId)
				return
			end
			if isQuery then
				local qfn = spec.queryFn
				if not qfn then
					publishReply(dlType, -1, "no_host_uart", nil, messageId)
					return
				end
				local body, err, failBody = qfn(hu, data, timeoutMs)
				if body then
					publishReply(dlType, 0, "ok", body, messageId)
				else
					publishReply(dlType, -1, err or "query_fail", failBody, messageId)
				end
				return
			end
			local sfn = spec.setFn
			if not sfn then
				publishReply(dlType, -1, "no_host_uart", nil, messageId)
				return
			end
			local ok, msg, extra, failBody = sfn(hu, data, timeoutMs)
			if ok then
				publishReply(dlType, 0, "ok", extra, messageId)
				if spec.onSetSuccess then
					spec.onSetSuccess(extra, data)
				end
			else
				publishReply(dlType, -1, msg or "fail", failBody or extra, messageId)
			end
		end)
	end
end
local HOST_UART_QUERY_SET_SPECS = {
	recordTime = {
		queryDl = DT.DL_RECORD_TIME_QUERY,
		setDl = DT.DL_RECORD_TIME_SET,
		ulQuery = DT.UL_RECORD_TIME_QUERY,
		ulSet = DT.UL_RECORD_TIME_SET,
		suffix = "record",
		defaultTimeoutMs = 12000,
		appendFields = function(b)
			local extra = ""
			if type(b) == "table" then
				if b.minutes ~= nil then
					extra = extra .. string.format(',"recordTimeMin":%d', tonumber(b.minutes) or 0)
				end
				if b.allowedMin then
					extra = extra .. ',"allowedMin":' .. RECORD_TIME_ALLOWED_JSON
				end
			end
			return extra
		end,
		queryFn = function(hu, _data, timeoutMs)
			if not hu.queryHostRecordTime then
				return nil
			end
			local snap = hu.queryHostRecordTime(timeoutMs)
			if snap and snap.parsed then
				return {
					minutes = snap.minutes,
					allowedMin = RECORD_TIME_ALLOWED,
				}
			end
			return nil, "query_fail", { allowedMin = RECORD_TIME_ALLOWED }
		end,
		setFn = function(hu, data, timeoutMs)
			if not hu.setHostRecordTime then
				return false, "no_host_uart"
			end
			local min = tonumber(data.recordTimeMin or data.recTime or data.minutes or data.min)
			if min == nil then
				return false, "missing_min", nil, { allowedMin = RECORD_TIME_ALLOWED }
			end
			local ok, msg, extra = hu.setHostRecordTime({
				minutes = min,
				timeout_ms = timeoutMs,
			})
			if ok then
				return true, "ok", {
					minutes = extra and extra.minutes or min,
					allowedMin = RECORD_TIME_ALLOWED,
				}
			end
			return false, msg or "fail", nil, { allowedMin = RECORD_TIME_ALLOWED }
		end,
	},
	framerate = {
		queryDl = DT.DL_FRAMERATE_QUERY,
		setDl = DT.DL_FRAMERATE_SET,
		ulQuery = DT.UL_FRAMERATE_QUERY,
		ulSet = DT.UL_FRAMERATE_SET,
		suffix = "framerate",
		defaultTimeoutMs = 12000,
		appendFields = function(b)
			local extra = ""
			if type(b) == "table" then
				if b.runtimeApply ~= nil then
					extra = extra .. string.format(',"runtimeApply":%d', tonumber(b.runtimeApply) or 0)
				end
				local ok, encoded = pcall(json.encode, b)
				if ok and encoded then
					extra = extra .. ',"body":' .. encoded
				end
			end
			return extra
		end,
		queryFn = function(hu, data, timeoutMs)
			if not hu.queryHostFramerate then
				return nil
			end
			local rows = hu.queryHostFramerate({
				camera = data.camera,
				stream = data.stream,
				timeout_ms = timeoutMs,
			})
			if type(rows) == "table" then
				return { video = rows }
			end
			return nil, "query_fail"
		end,
		setFn = function(hu, data, timeoutMs)
			if not hu.setHostFramerate then
				return false, "no_host_uart"
			end
			local ok, msg, extra = hu.setHostFramerate({
				camera = data.camera,
				stream = data.stream,
				framerate = data.framerate or data.fps,
				timeout_ms = timeoutMs,
			})
			if ok then
				return true, "ok", extra
			end
			return false, msg or "fail"
		end,
		onSetSuccess = function(extra)
			if extra and tonumber(extra.runtimeApply) == 0 then
				publishIpcAlert("encode_runtime_fail", "framerate")
			end
		end,
	},
	personDetect = {
		queryDl = DT.DL_PERSON_DETECT_QUERY,
		setDl = DT.DL_PERSON_DETECT_SET,
		ulQuery = DT.UL_PERSON_DETECT_QUERY,
		ulSet = DT.UL_PERSON_DETECT_SET,
		suffix = "personDetect",
		defaultTimeoutMs = 8000,
		appendFields = function(b)
			local extra = ""
			if type(b) == "table" and b.enable ~= nil then
				extra = extra .. string.format(',"enable":%d', tonumber(b.enable) or 0)
			end
			if type(b) == "table" and b.personDetectAvailable ~= nil then
				extra = extra .. string.format(',"personDetectAvailable":%d',
					tonumber(b.personDetectAvailable) or 0)
			end
			return extra
		end,
		queryFn = function(hu, _data, timeoutMs)
			if not hu.queryHostPersonDetect then
				return nil
			end
			local snap = hu.queryHostPersonDetect(timeoutMs)
			if snap and snap.parsed then
				return {
					enable = snap.enable,
					personDetectAvailable = snap.available,
				}
			end
			return nil, "query_fail"
		end,
		setFn = function(hu, data, timeoutMs)
			if not hu.setHostPersonDetect then
				return false, "no_host_uart"
			end
			local enable = tonumber(data.enable)
			if enable == nil or (enable ~= 0 and enable ~= 1) then
				return false, "invalid_enable"
			end
			local ok, msg, extra = hu.setHostPersonDetect({
				enable = enable,
				timeout_ms = timeoutMs,
			})
			if ok then
				return true, "ok", {
					enable = extra and extra.enable or enable,
				}
			end
			return false, msg or "fail"
		end,
	},
	mic = {
		queryDl = DT.DL_MIC_QUERY,
		setDl = DT.DL_MIC_SET,
		ulQuery = DT.UL_MIC_QUERY,
		ulSet = DT.UL_MIC_SET,
		suffix = "mic",
		defaultTimeoutMs = 8000,
		appendFields = function(b)
			local extra = ""
			if type(b) == "table" then
				if b.camera ~= nil then
					extra = extra .. string.format(',"camera":%d', tonumber(b.camera) or 0)
				end
				if b.volume ~= nil then
					extra = extra .. string.format(',"volume":%d', tonumber(b.volume) or 0)
				end
				if b.gain ~= nil then
					extra = extra .. string.format(',"gain":%d', tonumber(b.gain) or 0)
				end
				if b.runtimeApply ~= nil then
					extra = extra .. string.format(',"runtimeApply":%d', tonumber(b.runtimeApply) or 0)
				end
				if b.mics and json and json.encode then
					local ok, encoded = pcall(json.encode, b.mics)
					if ok and encoded then
						extra = extra .. ',"mics":' .. encoded
					end
				end
			end
			return extra
		end,
		queryFn = function(hu, data, timeoutMs)
			if not hu.queryHostMic then
				return nil
			end
			local rows = hu.queryHostMic({
				camera = data.camera,
				timeout_ms = timeoutMs,
			})
			if type(rows) ~= "table" or #rows == 0 then
				return nil, "query_fail"
			end
			local cam = tonumber(data.camera)
			local row = rows[1]
			if cam ~= nil then
				for _, r in ipairs(rows) do
					if tonumber(r.camera) == cam then
						row = r
						break
					end
				end
			end
			return {
				camera = row.camera,
				volume = row.volume,
				gain = row.gain,
				mics = rows,
			}
		end,
		setFn = function(hu, data, timeoutMs)
			if not hu.setHostMic then
				return false, "no_host_uart"
			end
			local volume = tonumber(data.volume)
			local gain = tonumber(data.gain)
			if volume == nil or gain == nil then
				return false, "missing_params"
			end
			local ok, msg, extra = hu.setHostMic({
				camera = data.camera,
				volume = volume,
				gain = gain,
				timeout_ms = timeoutMs,
			})
			if ok then
				return true, "ok", {
					camera = extra and extra.camera or tonumber(data.camera) or 0,
					volume = volume,
					gain = gain,
					runtimeApply = extra and extra.runtimeApply or 0,
				}
			end
			return false, msg or "fail"
		end,
	},
	softPhoto = {
		queryDl = DT.DL_SOFTPHOTO_QUERY,
		setDl = DT.DL_SOFTPHOTO_SET,
		ulQuery = DT.UL_SOFTPHOTO_QUERY,
		ulSet = DT.UL_SOFTPHOTO_SET,
		suffix = "softPhoto",
		defaultTimeoutMs = 8000,
		appendFields = function(b)
			local extra = ""
			local keys = {
				"enable", "nightModeThreshold", "dayModeThreshold", "dayModeAltThreshold",
				"gbGainThreshold", "gbGainRecordInit", "checkTime", "checkCount",
			}
			if type(b) == "table" then
				for _, k in ipairs(keys) do
					if b[k] ~= nil then
						extra = extra .. string.format(',"%s":%d', k, tonumber(b[k]) or 0)
					end
				end
			end
			return extra
		end,
		queryFn = function(hu, _data, timeoutMs)
			if not hu.queryHostSoftPhoto then
				return nil
			end
			local snap = hu.queryHostSoftPhoto(timeoutMs)
			if snap and snap.parsed then
				return snap
			end
			return nil, "query_fail"
		end,
		setFn = function(hu, data, timeoutMs)
			if not hu.setHostSoftPhoto then
				return false, "no_host_uart"
			end
			local ok, msg, extra = hu.setHostSoftPhoto({
				enable = data.enable,
				nightModeThreshold = data.nightModeThreshold or data.night_mode_threshold,
				dayModeThreshold = data.dayModeThreshold or data.day_mode_threshold,
				dayModeAltThreshold = data.dayModeAltThreshold or data.day_mode_alt_threshold,
				gbGainThreshold = data.gbGainThreshold or data.gb_gain_threshold,
				gbGainRecordInit = data.gbGainRecordInit or data.gb_gain_record_init,
				checkTime = data.checkTime or data.check_time,
				checkCount = data.checkCount or data.check_count,
				timeout_ms = timeoutMs,
			})
			if ok then
				return true, "ok", {
					enable = data.enable,
					nightModeThreshold = data.nightModeThreshold or data.night_mode_threshold,
					dayModeThreshold = data.dayModeThreshold or data.day_mode_threshold,
					dayModeAltThreshold = data.dayModeAltThreshold or data.day_mode_alt_threshold,
					gbGainThreshold = data.gbGainThreshold or data.gb_gain_threshold,
					gbGainRecordInit = data.gbGainRecordInit or data.gb_gain_record_init,
					checkTime = data.checkTime or data.check_time,
					checkCount = data.checkCount or data.check_count,
				}
			end
			return false, msg or "fail", extra
		end,
	},
}
local HOST_UART_QUERY_SET_ORDER = {
	"recordTime", "framerate", "personDetect", "mic", "softPhoto",
}
local function registerHostQuerySetHandlers(map)
	for i = 1, #HOST_UART_QUERY_SET_ORDER do
		local spec = HOST_UART_QUERY_SET_SPECS[HOST_UART_QUERY_SET_ORDER[i]]
		local handler = makeHostQuerySetHandler(spec)
		map[spec.queryDl] = wrapHostDownlink(spec.queryDl, handler, true)
		map[spec.setDl] = wrapHostDownlink(spec.setDl, handler, false)
	end
end
DOWNLINK_HANDLERS = {
	[DT.DL_WAKEUP] = handleDownlink2001,
	[DT.DL_REST] = handleDownlink2002,
	[DT.DL_STATUS] = handleDownlink2003,
	[DT.DL_CONTROL] = handleDownlink2004,
	[DT.DL_SIM] = handleDownlink2005,
	[DT.DL_DEVICE_ID] = handleDownlink2006,
	[DT.DL_TF_CARD] = handleDownlink2007,
	[DT.DL_TF_FORMAT] = handleDownlink2009,
	[DT.DL_VERSION_QUERY] = handleDownlink2008,
	[DT.DL_PIR_CFG] = handleDownlink2010,
	[DT.DL_PIR_STOP] = handleDownlink2011,
	[DT.DL_PIR_START] = handleDownlink2012,
	[DT.DL_ENCODE_SET] = function(data)
		handleHostDownlink(DT.DL_ENCODE_SET, data, function()
			handleDownlinkEncode(data, false)
		end)
	end,
	[DT.DL_ENCODE_QUERY] = function(data)
		handleHostDownlink(DT.DL_ENCODE_QUERY, data, function()
			handleDownlinkEncode(data, true)
		end)
	end,
}
registerHostQuerySetHandlers(DOWNLINK_HANDLERS)
local function dispatchDownlink(topic, payload)
	if not isDownlinkTopic(topic) then
		return
	end
	local ok, data = pcall(json.decode, payload)
	if not ok then
		mqttError("json_decode_error", data)
		return
	end
	local dataType = normalizeDataType(data)
	mqttInfo("downlink", dataType or "nil", topic)
	local handler = dataType and DOWNLINK_HANDLERS[dataType]
	if handler then
		handler(data)
	elseif dataType then
		mqttWarn("downlink_unknown_datatype", dataType)
	else
		mqttWarn("downlink_missing_datatype")
	end
	publishAppEvent("MQTT_SERVER_DATA", data, payload)
	if callbacks.onMessage then
		callbacks.onMessage(topic, payload)
	end
end
local function handleServerMessage(topic, payload)
	sys.taskInit(function()
		dispatchDownlink(topic, payload)
	end)
end
local function normMqttCfg(cfg)
	if not cfg or not cfg.host or cfg.host == "" then
		return nil
	end
	local cid = cfg.client_id
	if cid == nil or cid == "" then
		cid = nil
	end
	return {
		host = cfg.host,
		port = tonumber(cfg.port) or 1883,
		ssl = cfg.ssl == true or cfg.ssl == 1,
		username = cfg.username or "",
		password = cfg.password or "",
		client_id = cid,
	}
end
function isSameMqttConfig(cfg)
	local nextCfg = normMqttCfg(cfg)
	local cur = normMqttCfg(_G.MQTT_CFG or {})
	if not nextCfg or not cur then
		return false
	end
	return nextCfg.host == cur.host
		and nextCfg.port == cur.port
		and nextCfg.ssl == cur.ssl
		and nextCfg.username == cur.username
		and nextCfg.password == cur.password
		and nextCfg.client_id == cur.client_id
end
function setMqttConfig(cfg)
	local normalized = normMqttCfg(cfg)
	if not normalized then
		return false
	end
	_G.MQTT_CFG = normalized
	return true
end
function getMqttConfig()
	return _G.MQTT_CFG
end
function restart()
	sys.taskInit(function()
		stop()
		sys.wait(800)
		start()
	end)
	return true
end
local function mqttTask()
	local gotReady, deviceId = waitForNetworkReady()
	local mcfg = _G.MQTT_CFG or {}
	if not mcfg.host or mcfg.host == "" then
		mqttError("mqtt_no_host_config")
		return
	end
	local clientId = (mcfg.client_id and mcfg.client_id ~= "") and mcfg.client_id
		or (deviceId or getDeviceId())
	if not mqtt or not mqtt.create then
		mqttError("mqtt_no_login_config")
		return
	end
	if socket and socket.adapter and socket.dft then
		local waitIp = 0
		while not socket.adapter(socket.dft()) and waitIp < 120 do
			sys.waitUntil("IP_READY", 5000)
			waitIp = waitIp + 1
		end
	end
	mqttClient = mqtt.create(nil, mcfg.host, mcfg.port, mcfg.ssl)
	mqttClient:auth(clientId, mcfg.username, mcfg.password)
	mqttClient:autoreconn(true, 3000)
	mqttInfo("mqtt_connecting", mcfg.host, tonumber(mcfg.port) or 1883, clientId)
	sys.subscribe("IP_READY", function()
		if mqttClient and not isConnected then
			pcall(function() mqttClient:connect() end)
		end
	end)
	mqttClient:on(function(client, event, data, payload)
		if event == "conack" then
			mqttInfo("mqtt_conack", getSubTopicFilter())
			isConnected = true
			_G.APP_RUNTIME.online_status = 1
			state.reconnect_count = 0
			subscribeDownlink(client)
			sys.publish(mqttConnectedEvent())
			pcall(function()
				local hu = getHostUart()
				if hu and hu.push_net_led_state then
					hu.push_net_led_state(true)
				end
			end)
			publishConnectUplink()
			maybeAutoPublishIdentity()
		elseif event == "recv" then
			handleServerMessage(data, payload)
		elseif event == "disconnect" then
			isConnected = false
			_G.APP_RUNTIME.online_status = 0
			state.reconnect_count = (state.reconnect_count or 0) + 1
			mqttWarn("mqtt_disconnect", state.reconnect_count)
			publishAppEvent("MQTT_OFFLINE")
			pcall(function()
				local hu = getHostUart()
				if hu and hu.push_net_led_state then
					hu.push_net_led_state(false)
				end
			end)
			if callbacks.onOffline then callbacks.onOffline() end
		elseif event == "error" or event == "connect" then
			if event == "error" then
				mqttWarn("mqtt_error", tostring(data or ""))
			elseif mqttLogEnabled() then
				mqttInfo("mqtt_event_connect")
			end
		end
	end)
	mqttClient:connect()
	setupBatteryStatusReport()
	local conOk = sys.waitUntil(mqttConnectedEvent(), 90000)
	startStatusReportTimer()
	while true do
		local ret, topic, data, qos = sys.waitUntil("mqtt_pub", 300000)
		if ret then
			if topic == "close" then break end
			if isConnected then mqttClient:publish(topic, data, qos) end
		end
	end
	if mqttClient then mqttClient:close(); mqttClient = nil end
	isConnected = false
end
function hasPendingHostWork()
	if #pendingHostQueue > 0 then
		return true
	end
	local st = pir_ctrl.getState()
	if st.last_stop_reason == "device" and st.stop_mqtt_published ~= true then
		return true
	end
	return false
end
function publishWakeup()
	publishUplink({
		suffix = "wakeup",
		dataType = DT.UL_WAKEUP,
		app_event = "MQTT_PUBLISH_WAKEUP"
	})
end
function publishRest(opts)
	opts = type(opts) == "table" and opts or {}
	local mode = opts.lowPowerMode or "enter"
	if mode == "exit" then
		local reason = opts.reason or "unknown"
		publishUplink({
			suffix = "rest",
			dataType = DT.UL_REST,
			fields = string.format(
				',"lowPowerMode":"exit","reason":"%s"',
				escJson(reason)),
			app_event = "MQTT_PUBLISH_REST"
	})
		return
	end
	local rt = _G.APP_RUNTIME or {}
	local reason = opts.reason or rt.last_rest_reason or "unknown"
	local source = opts.source or "enter"
	publishUplink({
		suffix = "rest",
		dataType = DT.UL_REST,
		fields = string.format(
			',"lowPowerMode":"enter","reason":"%s","source":"%s"',
			escJson(reason), escJson(source)),
		app_event = "MQTT_PUBLISH_REST"
	})
end
function publishStatus(opts)
	opts = type(opts) == "table" and opts or {}
	local snap = collectBatterySnapshot()
	local rt = _G.APP_RUNTIME or {}
	local intervalSec = getStatusReportIntervalSec()
	local usbLogical = tonumber(rt.usb_logical)
	if usbLogical == nil then
		usbLogical = snap.usb_inserted
	end
	local usbNetdev = tonumber(rt.usb_netdev) or 0
	local usbRecovery = rt.usb_recovery or "idle"
	local usbRecoveryCount = tonumber(rt.usb_recovery_count) or 0
	local usbRecoveryLastErr = rt.usb_recovery_last_err or ""
	local extra = ""
	if opts.messageId and opts.messageId ~= "" then
		extra = extra .. string.format(',"messageId":"%s"', escJson(tostring(opts.messageId)))
	end
	if opts.configRet ~= nil then
		extra = extra .. string.format(
			',"ret":%d,"message":"%s"',
			tonumber(opts.configRet) or 0,
			escJson(opts.configMsg or "ok"))
	end
	if opts.skip_ipc_stat_refresh ~= true and ipc_sup.refreshIpcCloudStatBefore1003 then
		if coroutine.running() then
			ipc_sup.refreshIpcCloudStatBefore1003(2500)
		elseif ipc_sup.mergeHostIpcCloudCache then
			ipc_sup.mergeHostIpcCloudCache()
		end
	end
	publishUplink({
		suffix = "status",
		dataType = DT.UL_STATUS,
		warn = false,
		fields = string.format(
			',"usbInserted":%d,"charging":%d,"remainPower":"%s","batteryMv":"%s","lowPowerMode":"%s","interval":%d,"usbLogical":%d,"usbNetdev":%d,"usbRecovery":"%s","usbRecoveryCount":%d,"usbRecoveryLastErr":"%s"%s%s',
			snap.usb_inserted,
			snap.charging,
			escJson(tostring(snap.battery_percent)),
			escJson(tostring(snap.battery_mv)),
			escJson(snap.low_power_mode),
			intervalSec,
			usbLogical,
			usbNetdev,
			escJson(usbRecovery),
			usbRecoveryCount,
			escJson(usbRecoveryLastErr),
			extra,
			ipc_sup.ipcCloudStatFields()),
		on_published = function()
			lastBatteryStatusPublishSec = os.time()
			ipc_sup.afterBatteryStatusPublished()
		end,
	})
end
function publishConnectUplink()
	local rt = _G.APP_RUNTIME or {}
	if tonumber(rt.low_power_mode) == 1 then
		publishRest({ reason = rt.last_rest_reason or "unknown", source = "reconnect" })
		publishStatus()
	else
		publishWakeup()
	end
end
function publishSimInfo()
	local snap = collectSimSnapshot()
	publishUplink({
		suffix = "sim",
		dataType = DT.UL_SIM,
		no_conn = NC,
		fields = string.format(
			',"imei":"%s","imsi":"%s","iccid":"%s","operator":"%s","operatorName":"%s","status":"%s","csq":"%s","rssi":"%s","rsrp":"%s","snr":"%s","simid":"%s","ip":"%s","apn":"%s"',
			escJson(snap.imei),
			escJson(snap.imsi),
			escJson(snap.iccid),
			escJson(snap.operator),
			escJson(snap.operator_name),
			escJson(snap.status),
			escJson(snap.csq),
			escJson(snap.rssi),
			escJson(snap.rsrp),
			escJson(snap.snr),
			escJson(snap.simid),
			escJson(snap.ip),
			escJson(snap.apn))
	})
end
function publishDeviceIdentity(imei, gb28181Id, messageId)
	local deviceNo = getDeviceId()
	imei = imei or deviceNo
	gb28181Id = gb28181Id or ""
	local ret = (gb28181Id ~= "") and 0 or -1
	publishUplink({
		suffix = "identity",
		dataType = DT.UL_DEVICE_ID,
		no_conn = NC,
		fields = string.format(
			',"imei":"%s","gb28181Id":"%s","ret":%d%s',
			escJson(imei), escJson(gb28181Id), ret, msgIdPart(messageId))
	})
end
function refreshAndPublishDeviceIdentity(messageId)
	if not identityEnabled() then
		return
	end
	sys.taskInit(function()
		refreshDeviceIdentity(messageId)
	end)
end
function publishTfCardStatus(snap, messageId)
	snap = type(snap) == "table" and snap or {}
	local present = (snap.present == 1 or snap.present == true) and 1 or 0
	local totalMb = tonumber(snap.total_mb) or 0
	local usedMb = tonumber(snap.used_mb) or 0
	local freeMb = tonumber(snap.free_mb) or 0
	local ret = snap.timeout and -1 or 0
	publishUplink({
		suffix = "tfcard",
		dataType = DT.UL_TF_CARD,
		no_conn = NC,
		fields = string.format(
			',"tfPresent":%d,"totalMb":%d,"usedMb":%d,"freeMb":%d,"ret":%d%s',
			present, totalMb, usedMb, freeMb, ret, msgIdPart(messageId))
	})
end
function refreshAndPublishTfCardStatus(messageId)
	if not tfCardEnabled() then
		return
	end
	sys.taskInit(function()
		refreshTfCardStatus(messageId)
	end)
end
function publishTfFormatResult(retCode, message, messageId, extra)
	extra = type(extra) == "table" and extra or {}
	local rebootField = ""
	if extra.reboot ~= nil then
		rebootField = string.format(',"reboot":%d', (extra.reboot == 1 or extra.reboot == true) and 1 or 0)
	end
	publishUplink({
		suffix = "tfcard_format",
		dataType = DT.UL_TF_FORMAT,
		no_conn = NC,
		fields = string.format(
			',"ret":%s,"message":"%s"%s%s',
			tostring(retCode ~= nil and retCode or -1),
			escJson(message),
			rebootField,
			msgIdPart(messageId))
	})
end
function publishIpcAlert(alertCode, alertDetail)
	return ipc_sup.publishAlert(alertCode, alertDetail)
end
function publishControlReply(action, retCode, message, extra)
	extra = type(extra) == "table" and extra or {}
	local enableField = ""
	if extra.enable ~= nil then
		local en = (extra.enable == 1 or extra.enable == true) and 1 or 0
		enableField = string.format(',"enable":%s', tostring(en))
	end
	local mid = extra.messageId
	publishUplink({
		suffix = "event",
		dataType = DT.UL_CONTROL,
		no_conn = NC,
		fields = string.format(
			',"reply":1,"messageId":"%s","action":"%s","ret":%s,"message":"%s"%s',
			escJson(mid),
			escJson(action),
			tostring(retCode ~= nil and retCode or -1),
			escJson(message),
			enableField)
	})
end
local POWEROFF_NOTIFY_MSG = {
	battery = "low_battery_shutdown",
	user = "user_shutdown",
	mqtt = "ok",
	low_power = "low_power_shutdown",
}
function notifyPowerOff(reason, callback)
	sys.taskInit(function()
		reason = reason or "unknown"
		local guardCfg = (_G.BATTERY_CFG and _G.BATTERY_CFG.guard) or {}
		local waitMs = tonumber(guardCfg.shutdown_mqtt_wait_ms) or 8000
		local graceMs = tonumber(guardCfg.shutdown_mqtt_grace_ms) or 800
		if not isConnected then
			if mqttClient and mqttClient.connect then
				pcall(function() mqttClient:connect() end)
			end
			sys.waitUntil(mqttConnectedEvent(), waitMs)
		end
		if isConnected then
			if reason ~= "mqtt" then
				local msg = POWEROFF_NOTIFY_MSG[reason] or ("shutdown_" .. tostring(reason))
				publishControlReply("off", 0, msg, {})
			end
			publishStatus({ skip_ipc_stat_refresh = true, warn = false })
			sys.wait(graceMs)
		else
		end
		if type(callback) == "function" then
			callback()
		end
	end)
end
local function mqttBuildVersion(ver)
	if ver == nil or ver == "" then
		return ""
	end
	ver = tostring(ver)
	if _G.validateBuildVersion then
		return _G.validateBuildVersion(ver) or ver
	end
	return ver
end
function publishOtaStatus(stage, retCode, message, extra)
	extra = type(extra) == "table" and extra or {}
	publishUplink({
		suffix = "event",
		dataType = DT.UL_CONTROL,
		no_conn = NC,
		fields = string.format(
			',"stage":"%s","ret":%s,"message":"%s","currentVersion":"%s","targetVersion":"%s"',
			escJson(stage),
			tostring(retCode ~= nil and retCode or -1),
			escJson(message),
			escJson(mqttBuildVersion(VERSION or _G.version or "")),
			escJson(mqttBuildVersion(extra.version or extra.targetVersion or ""))),
		app_event_fn = function()
			publishAppEvent("MQTT_OTA_STATUS", stage, retCode, message, extra)
		end
	})
end
local function publishPirFromState(overrides)
	if not isConnected then
		return
	end
	local st = pir_ctrl.getState()
	local media = st.mediaConfig or {}
	overrides = type(overrides) == "table" and overrides or buildPirDetectExtra("detected")
	publishPirDetect({
		status = overrides.status or "1",
		pirStatus = overrides.pirStatus,
		recording = overrides.recording ~= nil and overrides.recording or (st.recording and 1 or 0),
		active = overrides.active,
		action = overrides.action or media.action or "photo",
		uploadMode = overrides.uploadMode or st.uploadMode or media.uploadMode or "auto",
		quality = overrides.quality or st.quality or media.quality or "high",
		snapshotPath = overrides.snapshotPath,
		personCount = overrides.personCount,
	})
end
function publishPirEvent(overrides)
	publishPirFromState(overrides)
end
function publishPirDetect(extra)
	extra = type(extra) == "table" and extra or buildPirDetectExtra("detected")
	local rec = (extra.recording == 1 or extra.recording == true) and 1 or 0
	local activeJson = ""
	if extra.active ~= nil then
		local active = (extra.active == 1 or extra.active == true) and 1 or 0
		activeJson = string.format(',"active":%d', active)
	end
	local pathJson = ""
	if extra.snapshotPath and extra.snapshotPath ~= "" then
		pathJson = string.format(',"snapshotPath":"%s"', escJson(extra.snapshotPath))
	end
	local personJson = ""
	if extra.personCount ~= nil then
		personJson = string.format(',"personCount":%d', tonumber(extra.personCount) or 0)
	end
	publishUplink({
		suffix = "pir",
		dataType = DT.UL_PIR_DETECT,
		no_conn = NC,
		fields = string.format(
			',"status":"%s","pirStatus":"%s","recording":%s,"action":"%s","uploadMode":"%s","quality":"%s"%s%s%s',
			escJson(extra.status or "detected"),
			escJson(extra.pirStatus or extra.status or "detected"),
			tostring(rec),
			escJson(extra.action),
			escJson(extra.uploadMode),
			escJson(extra.quality),
			activeJson,
			pathJson,
			personJson)
	})
end
function publishPirSnapshotDone(path)
	publishPirFromState({
		pirStatus = "snapshot_saved",
		action = nil,
		snapshotPath = path,
	})
end
function publishPirRecordActive()
	publishPirFromState({
		pirStatus = "t3x_active",
		recording = 1,
		active = 1,
		action = "video",
	})
end
function publishPirRecordStart(action, uploadMode, quality, opts)
	if not isConnected then
		return
	end
	opts = type(opts) == "table" and opts or {}
	local source = opts.source or "4g"
	local mid = opts.messageId
	local midField = mid and string.format(',"messageId":"%s"', escJson(mid)) or ""
	publishUplink({
		suffix = "event",
		dataType = DT.UL_PIR_START,
		no_conn = NC,
		fields = string.format(
			',"reason":"device","source":"%s","action":"%s","uploadMode":"%s","quality":"%s","recording":1%s',
			escJson(source), escJson(action or "video"),
			escJson(uploadMode or "auto"), escJson(quality or "high"), midField)
	})
end
function publishPirRecordStop(reason, uploadMode, quality, opts)
	if not isConnected then
		return
	end
	if pir_ctrl.canPublishStopMqtt and not pir_ctrl.canPublishStopMqtt() then
		opts = type(opts) == "table" and opts or {}
		return
	end
	if pir_ctrl.markStopMqttPublished then
		pir_ctrl.markStopMqttPublished()
	end
	opts = type(opts) == "table" and opts or {}
	local source = opts.source or "4g"
	local mid = opts.messageId
	if not mid and pir_ctrl.getCloudStopMessageId then
		mid = pir_ctrl.getCloudStopMessageId()
	end
	local midField = ""
	if mid and mid ~= "" then
		midField = string.format(',"messageId":"%s"', escJson(tostring(mid)))
	end
	publishUplink({
		suffix = "event",
		dataType = DT.UL_PIR_STOP,
		no_conn = NC,
		fields = string.format(
			',"reason":"%s","source":"%s","uploadMode":"%s","quality":"%s"%s',
			escJson(reason), escJson(source), escJson(uploadMode), escJson(quality), midField)
	})
end
function publishT3xRecordStop(reason, uploadMode, quality)
	local st = pir_ctrl.getState()
	publishPirRecordStop(
		reason or "unknown",
		uploadMode or st.uploadMode or "auto",
		quality or st.quality or "high",
		{ source = "t3x" }
	)
end
function publish(topic, data, qos)
	sys.publish("mqtt_pub", topic, data, qos or 1)
end
function publishRaw(topicSuffix, payload, qos)
	if not isConnected or not mqttClient then
		return false
	end
	if not topicSuffix or topicSuffix == "" or not payload or payload == "" then
		return false
	end
	local topic
	if topicSuffix:sub(1, 1) == "/" then
		topic = topicSuffix
	else
		topic = getPubTopic() .. topicSuffix
	end
	sys.publish("mqtt_pub", topic, payload, qos or 1)
	return true
end
function start(options)
	if started then return false end
	if options then
		if options.onOffline then callbacks.onOffline = options.onOffline end
		if options.onMessage then callbacks.onMessage = options.onMessage end
	end
	setupIdentityAutoPublish()
	if not pendingHostDrainHooked then
		pendingHostDrainHooked = true
		local evt = (_G.APP_EVENTS and _G.APP_EVENTS.HOST_UART_FIRST_AT) or "APP_HOST_UART_FIRST_AT"
		sys.subscribe(evt, function()
			sys.taskInit(function()
				sys.wait(500)
				drainPendingHostWork()
			end)
		end)
	end
	local usbRecEvt = (_G.APP_EVENTS or {}).MQTT_USB_RECOVERY_CHANGED or "mqtt_usb_recovery_changed"
	sys.subscribe(usbRecEvt, function()
		if isConnected then
			sys.taskInit(function()
				publishStatus()
			end)
		end
	end)
	bootstrapNetwork()
	sys.taskInit(mqttTask)
	started = true
	return true
end
function stop()
	if not started and not mqttClient then
		return false
	end
	local rt = _G.APP_RUNTIME or {}
	if isConnected and mqttClient and publishRest and tonumber(rt.low_power_mode) == 1 then
		pcall(publishRest, {
			reason = rt.last_rest_reason or "unknown",
			source = "reconnect",
		})
		sys.wait(300)
	end
	if mqttClient then
		pcall(function()
			mqttClient:autoreconn(false)
		end)
		sys.publish("mqtt_pub", "close", "", 0)
		sys.wait(500)
		pcall(function()
			mqttClient:close()
		end)
		mqttClient = nil
	end
	isConnected = false
	_G.APP_RUNTIME.online_status = 0
	started = false
	return true
end
function getState()
	return {
		started = started,
		connected = isConnected,
		client = mqttClient ~= nil,
		last_event = state.last_event,
		reconnect_count = state.reconnect_count,
		last_publish_topic = state.last_publish_topic,
	}
end
loadIvCfg()
ipc_sup.bind({
	publish_uplink = publishUplink,
	esc_json = escJson,
	dt_ul_control = DT.UL_CONTROL,
	nc = NC,
	publish_t3x_record_stop = publishT3xRecordStop,
})
return _M
