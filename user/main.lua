-- 780EHM_PJ 入口
-- 启动链: main → app.start(peripheral, net, t3x_ctrl) → sys.run()
--
-- LuatTools 只静态解析下面两行；VERSION 须脚本版 xxx.yyy.zzz（如 001.000.002）。
-- 工具打 .bin 时会自动拼内核号 → PANSHI_CAT1_2034.001.002_...；勿写 2034.001.002，否则会成 2034.2034.002。
-- 合宙 IoT OTA 请求用 buildIotOtaVersion(VERSION) 得到 2034.001.002。
PROJECT = "PANSHI_CAT1"
VERSION = "001.000.002"
-- 合宙 IoT OTA：FOTA_SERVER=iot 时 libfota2 使用此 project_key
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
BUILD_TAG = "v20260607"

local moduleName = ...
local isEntry = moduleName == nil

require "sys"
require "sysplus"

do
    local iotVer = buildIotOtaVersion(VERSION)
    if iotVer then
        _G.IOT_VERSION = iotVer
        log.info("main", "脚本版本", VERSION, "IoT/量产bin", iotVer)
    end
end

require "config"
require "app_config"
require "key_config"

if _G.FEATURE_CFG then
    log.info("main", "RNDIS", _G.FEATURE_CFG.rndis and "开" or "关")
    log.info("main", "低功耗", _G.FEATURE_CFG.low_power and "开" or "关")
    log.info("main", "休眠查询", _G.FEATURE_CFG.host_evt and "PIRSTAT.has_work 开" or "关")
    local okLp, lpw = pcall(require, "low_power_wakeup")
    if okLp and lpw and lpw.modeLabel then
        log.info("main", "低功耗唤醒通道", lpw.modeLabel())
    end
end

local app = require "app"
local peripheral = require "peripheral"
local net = require "net_mqtt"
local t3x_ctrl = require "t3x_ctrl"

if not isEntry then
    return app
end

log.info("main", "版本", BUILD_TAG, "core", rtos.version(), "project", PROJECT)

if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    -- 开启 PWRKEY 防抖：关机后需长按 K1 约 2s 才能再开机（见 doc/KEY_GPIO.md）
    pm.power(pm.PWK_MODE, true)
end

-- ① RNDIS：与 pwrkey_rndis_boot/main.lua 相同 sys.taskInit(rndis.open)
if _G.MODULE_FLAGS and _G.MODULE_FLAGS.rndis then
    local okMod, usb_rndis = pcall(require, "usb_rndis")
    if okMod and type(usb_rndis) == "table" and usb_rndis.open then
        sys.taskInit(usb_rndis.open)
        log.info("main", "RNDIS taskInit(open)")
    else
        log.warn("main", "usb_rndis 不可用，跳过 RNDIS")
    end
end

-- ② SIM/运营商/APN（须在 IP_READY 前，参考 SDK demo/mobile/mobile_test.lua）
if _G.MODULE_FLAGS and _G.MODULE_FLAGS.cellular ~= false then
    local okCell, cellular = pcall(require, "cellular_bootstrap")
    if okCell and type(cellular) == "table" and cellular.start then
        cellular.start()
    end
end

-- ③ 4G 拨号等 IP_READY（与 pwrkey_rndis_boot net.start 一致，RNDIS 共享此连接）
if _G.MODULE_FLAGS and _G.MODULE_FLAGS.mqtt and net.bootstrapNetwork then
    net.bootstrapNetwork()
end

app.start(peripheral, net, t3x_ctrl)

sys.run()
