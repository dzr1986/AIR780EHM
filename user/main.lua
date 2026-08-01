PROJECT = "PANSHI_CAT1"
VERSION = "001.000.004"
PRODUCT_KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x"
local SCRIPT_VERSION_PATTERN = "^%d+%.%d+%.%d+$"
local function validateBuildVersion(ver)
	if type(ver) ~= "string" or not ver:match(SCRIPT_VERSION_PATTERN) then
		return nil
	end
	return ver
end
local function buildIotOtaVersion(scriptVer)
	local v = validateBuildVersion(scriptVer)
	if not v then
		return nil
	end
	local x, _, z = v:match("^(%d+)%.(%d+)%.(%d+)$")
	local coreVer = rtos and rtos.version and rtos.version()
	if not coreVer or coreVer == "" then
		return nil
	end
	local core = coreVer:sub(1, 1) == "V" and coreVer:sub(2) or coreVer
	return core .. "." .. x .. "." .. z
end
local function resolveIotOtaVersion(ver)
	if ver == nil or ver == "" then
		ver = _G.VERSION
	end
	ver = tostring(ver)
	if validateBuildVersion(ver) then
		return buildIotOtaVersion(ver)
	end
	local coreInVer = ver:match("^(%d+)%.")
	local core = rtos.version()
	if core and core ~= "" then
		core = core:sub(1, 1) == "V" and core:sub(2) or core
	end
	if coreInVer and core and coreInVer == core and ver:match("^%d+%.%d+%.%d+$") then
		return ver
	end
	return nil
end
if not validateBuildVersion(VERSION) then
	error("main: VERSION 须为 nnn.nnn.nnn 脚本版(如 2044.001.003), 当前=" .. tostring(VERSION))
end
_G.validateBuildVersion = validateBuildVersion
_G.buildIotOtaVersion = buildIotOtaVersion
_G.resolveIotOtaVersion = resolveIotOtaVersion
_G.VERSION = VERSION
_G.PROJECT = PROJECT
_G.PRODUCT_KEY = PRODUCT_KEY
BUILD_TAG = "v20260730"
_G.BUILD_TAG = BUILD_TAG
local moduleName = ...
local isEntry = moduleName == nil
require "sys"
require "sysplus"
do
	local iotVer = buildIotOtaVersion(VERSION)
	if iotVer then
		_G.IOT_VERSION = iotVer
	end
end
require "config"
local loader = require "module_loader"
-- Luatools 静态扫描锚点：以下模块仅经 loader.load 动态加载，需静态 require 才会被打包；永不执行
if _G.__LUATOOLS_SCAN_ANCHOR__ then
	require "cellular_bootstrap"
	require "device_id"
	require "fota_svc"
	require "host_event"
	require "libfota2"
	require "net_tcp"
	require "runtime_power"
	require "sound_prompt"
	require "t3x_notify"
	require "t3x_policy"
	require "time_sync"
	require "usb_charge"
	require "usb_rndis"
	require "vbat"
end
if _G.FEATURE_CFG then
	pcall(require, "low_power_wakeup")
end
local app = require "app"
local peripheral = require "peripheral"
local net = require "net_mqtt"
local t3x_ctrl = require "t3x_ctrl"
if not isEntry then
	return app
end
if log and log.info then
	log.info("main", "project=" .. tostring(PROJECT), "version=" .. tostring(VERSION))
end
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
	pm.power(pm.PWK_MODE, true)
end
if _G.MODULE_FLAGS and _G.MODULE_FLAGS.cellular ~= false then
	local cellular = loader.load("cellular_bootstrap")
	if cellular and cellular.start then
		cellular.start()
	end
end
local function startNetworkBootstrap()
	if _G.MODULE_FLAGS and _G.MODULE_FLAGS.mqtt and net.bootstrapNetwork then
		net.bootstrapNetwork()
	end
end
if _G.MODULE_FLAGS and _G.MODULE_FLAGS.rndis then
	local usb_rndis = loader.load("usb_rndis")
	if usb_rndis and usb_rndis.open then
		sys.taskInit(function()
			usb_rndis.open()
			startNetworkBootstrap()
		end)
	else
		startNetworkBootstrap()
	end
else
	startNetworkBootstrap()
end
app.start(peripheral, net, t3x_ctrl)
sys.run()
