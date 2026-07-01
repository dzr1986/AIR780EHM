PROJECT = "PANSHI_CAT1"
VERSION = "001.000.004"
PRODUCT_KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x"
local SCRIPT_VERSION_PATTERN = "^%d%d%d%.%d%d%d%.%d%d%d$"
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
	local x, _, z = v:match("^(%d%d%d)%.(%d%d%d)%.(%d%d%d)$")
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
	if coreInVer and core and coreInVer == core and ver:match("^%d+%.%d%d%d%.%d%d%d$") then
		return ver
	end
	return nil
end
if not validateBuildVersion(VERSION) then
	error("main: VERSION 须为 xxx.yyy.zzz 脚本版(如 001.000.002), 当前=" .. tostring(VERSION))
end
_G.validateBuildVersion = validateBuildVersion
_G.buildIotOtaVersion = buildIotOtaVersion
_G.resolveIotOtaVersion = resolveIotOtaVersion
_G.VERSION = VERSION
_G.PROJECT = PROJECT
_G.PRODUCT_KEY = PRODUCT_KEY
BUILD_TAG = "v20260614"
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
require "app_config"
require "key_config"
if _G.FEATURE_CFG then
	local okLp, lpw = pcall(require, "low_power_wakeup")
end
local app = require "app"
local peripheral = require "peripheral"
local net = require "net_mqtt"
local t3x_ctrl = require "t3x_ctrl"
if not isEntry then
	return app
end
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
	pm.power(pm.PWK_MODE, true)
end
if _G.MODULE_FLAGS and _G.MODULE_FLAGS.cellular ~= false then
	local okCell, cellular = pcall(require, "cellular_bootstrap")
	if okCell and type(cellular) == "table" and cellular.start then
		cellular.start()
	end
end
local function startNetworkBootstrap()
	if _G.MODULE_FLAGS and _G.MODULE_FLAGS.mqtt and net.bootstrapNetwork then
		net.bootstrapNetwork()
	end
end
if _G.MODULE_FLAGS and _G.MODULE_FLAGS.rndis then
	local okMod, usb_rndis = pcall(require, "usb_rndis")
	if okMod and type(usb_rndis) == "table" and usb_rndis.open then
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
