-- ================================================================
-- Filename : main.lua
-- Module   : 固件入口：版本校验、蜂窝/RNDIS 引导、app.start 编排、sys.run 主循环
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

PROJECT = "PANSHI_CAT1"
-- ===== 第 1 段：VERSION 格式校验 & 全局 OTA 版本函数 =====
VERSION = "001.000.002"
PRODUCT_KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x"
local SCRIPT_VERSION_PATTERN = "^%d+%.%d+%.%d+$"
local function valBuildVer(ver)
    if type(ver) ~= "string" or not ver:match(SCRIPT_VERSION_PATTERN) then
        return nil
    end
    return ver
end

local function coreVrsn()
    local coreVer = rtos and rtos.version and rtos.version()
    if (not coreVer or coreVer == "") and rtos and rtos.get_version then
        local full = rtos.get_version() or ""
        coreVer = full:match("[Vv](%d+)")
        if coreVer then
            return coreVer
        end
    end
    if not coreVer or coreVer == "" then
        return nil
    end
    return coreVer:sub(1, 1) == "V" and coreVer:sub(2) or coreVer
end

local function bldIotOtaVer(scriptVer)
    local v = valBuildVer(scriptVer)
    if not v then
        return nil
    end
    local core = coreVrsn()
    if not core then
        return nil
    end
    local x, _, z = v:match("^(%d+)%.(%d+)%.(%d+)$")
    if x == core then
        return v
    end
    return core .. "." .. x .. "." .. z
end

local function resIotOtaVer(ver)
    if ver == nil or ver == "" then
        ver = _G.VERSION
    end
    return bldIotOtaVer(tostring(ver))
end
if not valBuildVer(VERSION) then
    error("main: VERSION 须为 nnn.nnn.nnn 脚本版(如 001.000.020), 当前=" .. tostring(VERSION))
end
_G.valBuildVer = valBuildVer
_G.bldIotOtaVer = bldIotOtaVer
_G.resIotOtaVer = resIotOtaVer
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
    local iotVer = bldIotOtaVer(VERSION)
    if iotVer then
        _G.IOT_VERSION = iotVer
    end
    if log and log.info then
        log.info("main", string.format("project=%s version=%s firmwareVersion=%s",
            tostring(PROJECT), tostring(VERSION), tostring(_G.IOT_VERSION or "-")))
    end
end
-- ===== 第 2 段：核心依赖 require 链（config → 子模块）=====
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
    require "usb_vuart"
    require "vbat"
end
if _G.FEATURE_CFG then
    loader.load("low_power_wakeup")
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
do
    local usb_vuart = loader.load("usb_vuart")
    if usb_vuart and usb_vuart.start then
        usb_vuart.start()
    end
end
if loader.enabled("cellular") then
    local cellular = loader.load("cellular_bootstrap")
    if cellular and cellular.start then
        cellular.start()
    end
end

local function strtNetw()
    -- ===== 第 4 段：MQTT 网络引导 + app.start 编排子系统（battery/uart/pir/mqtt/t3x）=====
    if loader.enabled("mqtt") and net.bootstrapNetwork then
        net.bootstrapNetwork()
    end
end
if loader.enabled("rndis") then
    -- ===== 第 3 段：蜂窝 SIM/APN 引导 + 可选 USB RNDIS 异步 open =====
    local usb_rndis = loader.load("usb_rndis")
    if usb_rndis and usb_rndis.open then
        sys.taskInit(function()
            usb_rndis.open()
            strtNetw()
        end)
    else
        strtNetw()
    end
else
    strtNetw()
end
app.start(peripheral, net, t3x_ctrl)
-- ===== 第 5 段：进入 sys.run() 事件主循环 =====
sys.run()
