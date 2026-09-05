-- ================================================================
-- Filename : main.lua
-- Module   : 固件入口：版本校验、蜂窝/RNDIS 引导、app.start 编排、sys.run 主循环
-- Arch     : 见 doc/overview/LUA_MODULES.md
-- ================================================================

PROJECT = "PANSHI_CAT1"
-- ===== 第 1 段：VERSION 格式校验 & 全局 OTA 版本函数 =====
VERSION = "001.000.158"
PRODUCT_KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x"
local SCRIPT_VERSION_PATTERN = "^%d+%.%d+%.%d+$"
local function validateBuildVersion(ver)
    if type(ver) ~= "string" or not ver:match(SCRIPT_VERSION_PATTERN) then
        return nil
    end
    return ver
end

local function coreVersion()
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

local function buildIotOtaVersion(scriptVer)
    local v = validateBuildVersion(scriptVer)
    if not v then
        return nil
    end
    local core = coreVersion()
    if not core then
        return nil
    end
    local x, _, z = v:match("^(%d+)%.(%d+)%.(%d+)$")
    if x == core then
        return v
    end
    return core .. "." .. x .. "." .. z
end

local function resolveIotOtaVersion(ver)
    if ver == nil or ver == "" then
        ver = _G.VERSION
    end
    return buildIotOtaVersion(tostring(ver))
end
if not validateBuildVersion(VERSION) then
    error("main: VERSION 须为 nnn.nnn.nnn 脚本版(如 001.000.020), 当前=" .. tostring(VERSION))
end
-- OTA 版本工具 _G 导出族（LUA_MODULES.md §3.1 登记，P3-3 复核=有意保留）：
--   validateBuildVersion / resolveIotOtaVersion 被 mqtt_uplink/mqtt_dl_ctrl/fota_svc 经 _G 消费（活）；
--   buildIotOtaVersion 为纯内部构造函数，_G 导出与兄弟同族，留作 Luat 调试台/工具链统一入口
--   （零仓内消费；撤销条件=工具链接入点迁移后可与同族一并摘除）。
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
    if log and log.info then
        log.info("main", string.format("project=%s version=%s firmwareVersion=%s",
            tostring(PROJECT), tostring(VERSION), tostring(_G.IOT_VERSION or "-")))
    end
end
-- ===== 第 2 段：核心依赖 require 链（config → 子模块）=====
require "config"
local loader = require "module_loader"
-- Luatools 静态扫描锚点：动态 loader.load 与 config.lua 内嵌 require 均不被递归扫描，需在此挂名才会打包；永不执行
if _G.__LUATOOLS_SCAN_ANCHOR__ then
    -- config.lua 片段（见 user/config.lua 加载顺序）
    require "features"
    require "cellular"
    require "t31x_burn"
    require "gpio_cfg"
    require "led_pir"
    require "battery"
    require "host"
    require "net"
    require "flags"
    require "events"
    require "cell_boot"
    require "device_id"
    require "fota_svc"
    require "host_event"
    require "hif_at"
    require "hif_cmd"
    require "hif_ipc"
    require "libfota2"
    require "mqtt_downlink"
    require "mqtt_hproto"
    require "mqtt_uplink"
    require "net_tcp"
    require "runtime_power"
    require "sound_prompt"
    require "svc"
    require "t31x_notify"
    require "t31x_policy"
    require "time_sync"
    require "usb_charge"
    require "usb_rndis"
    require "usb_vuart"
    require "vbat"
end
if _G.FEATURE_CFG then
    loader.load("lp_wakeup")
end
local app = require "app"
local peripheral = require "peripheral"
local net = require "net_mqtt"
local t31xCtrl = require "t31x_ctrl"
if not isEntry then
    return app
end
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, true)
end
do
    local usb_vuart = loader.load("usb_vuart")
    if usb_vuart then
        usb_vuart.start()
    end
end
if loader.enabled("cellular") then
    local cellular = loader.load("cell_boot")
    if cellular then
        cellular.start()
    end
end

local function startNetwork()
    -- ===== 第 4 段：MQTT 网络引导 + app.start 编排子系统（battery/uart/pir/mqtt/t31x）=====
    if loader.enabled("mqtt") then
        net.bootstrapNet()
    end
end
if loader.enabled("rndis") then
    -- ===== 第 3 段：蜂窝 SIM/APN 引导 + 可选 USB RNDIS 异步 open =====
    local usb_rndis = loader.load("usb_rndis")
    if usb_rndis then
        sys.taskInit(function()
            usb_rndis.open()
            startNetwork()
        end)
    else
        startNetwork()
    end
else
    startNetwork()
end
app.start(peripheral, net, t31xCtrl)
-- ===== 第 5 段：进入 sys.run() 事件主循环 =====
sys.run()
