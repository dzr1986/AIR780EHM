-- ================================================================
-- Filename : runtime_power.lua
-- Module   : 工作模式 + USB/充电/电量/在线访问器（嵌套 APP_RUNTIME 唯一读写入口）
-- Arch     : 见 doc/LUA_MODULES.md、doc/USER_LIB_OPTIMIZATION_NEXT.md
-- ================================================================

require "config"
local loader = require "module_loader"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local WORK_PERSON_DETECT = "person_detect"
local WORK_PIR_WATCH = "pir_watch"

local function copyTbl(src)
    local dst = {}
    if type(src) ~= "table" then return dst end
    for k, v in pairs(src) do
        dst[k] = type(v) == "table" and copyTbl(v) or v
    end
    return dst
end

local function asFlag(v)
    return (v == true or tonumber(v) == 1) and 1 or 0
end

local rt = copyTbl(cfgm.get("APP_RUNTIME_DEFAULTS"))
if type(rt.net) ~= "table" then rt.net = { online = 0 } end
if type(rt.power) ~= "table" then rt.power = { status = 0, rest = 0, interval_sec = 30, wled_on = 0 } end
if type(rt.work) ~= "table" then rt.work = { mode = WORK_PERSON_DETECT } end
if type(rt.battery) ~= "table" then rt.battery = { rate = "0", dynamic_rest = 0 } end
if type(rt.cellular) ~= "table" then rt.cellular = { operator = "unknown", operator_name = "未知", present = 0, apn = "" } end
if type(rt.usb) ~= "table" then rt.usb = {} end
_G.APP_RUNTIME = rt

local function sub(name)
    local t = rt[name]
    if type(t) ~= "table" then
        t = {}
        rt[name] = t
    end
    return t
end

function getWorkMode()
    return sub("work").mode == WORK_PIR_WATCH and WORK_PIR_WATCH or WORK_PERSON_DETECT
end

function setWorkMode(mode)
    sub("work").mode = (mode == WORK_PIR_WATCH) and WORK_PIR_WATCH or WORK_PERSON_DETECT
    return sub("work").mode
end

function isPirWatch()
    return getWorkMode() == WORK_PIR_WATCH
end

function isLowPowerMode()
    return tonumber(sub("power").rest) == 1
end

function setLowPowerMode(on)
    local p = sub("power")
    local v = on and 1 or 0
    if tonumber(p.rest) == v then return false end
    p.rest = v
    return true
end

function setLastRestReason(reason)
    sub("power").last_rest_reason = reason
end

function getLastRestReason()
    return sub("power").last_rest_reason
end

function isBatDynRest()
    return tonumber(sub("battery").dynamic_rest) == 1
end

function setBatDynRest(on)
    sub("battery").dynamic_rest = asFlag(on)
end

function setBatteryTier(tier)
    if tier then sub("battery").tier = tier end
end

function getBatteryPercent()
    return tonumber(sub("battery").percent)
end

function getBatteryMv()
    return tonumber(sub("battery").mv)
end

function setBattery(pct, mv, rate)
    local b = sub("battery")
    if pct ~= nil then b.percent = pct end
    if mv ~= nil then b.mv = mv end
    if rate ~= nil then b.rate = tostring(rate) end
end

function isOnline()
    return tonumber(sub("net").online) == 1
end

function setOnline(on)
    sub("net").online = on and 1 or 0
end

function getPowerStatus()
    return tonumber(sub("power").status) or 0
end

function setPowerStatus(v)
    v = asFlag(v)
    sub("power").status = v
    return v
end

function getWledOn()
    local v = sub("power").wled_on
    if v == nil then return nil end
    return tonumber(v) == 1 and 1 or 0
end

function setWledOn(on)
    local v = asFlag(on)
    sub("power").wled_on = v
    return v
end

function setLowPowerInterval(sec)
    sec = tonumber(sec)
    if sec then sub("power").interval_sec = sec end
    return sec
end

function getLowPowerInterval()
    return tonumber(sub("power").interval_sec)
end

function setUsbRecovery(st)
    if type(st) ~= "table" then return end
    local u = sub("usb")
    if st.state then u.recovery = st.state end
    if st.count ~= nil then u.count = st.count end
    if st.last_err ~= nil then u.last_err = st.last_err end
    if st.usb_logical ~= nil then u.logical = st.usb_logical end
    if st.usb_netdev ~= nil then u.netdev = st.usb_netdev end
end

function getUsbRecovery()
    local u = sub("usb")
    return u.recovery, u.count, u.last_err, u.logical, u.netdev
end

function setCellular(st)
    if type(st) ~= "table" then return end
    local c = sub("cellular")
    if st.operator ~= nil then c.operator = st.operator end
    if st.operator_name ~= nil then c.operator_name = st.operator_name end
    if st.apn ~= nil then c.apn = st.apn end
    if st.sim_present ~= nil then c.present = st.sim_present and 1 or 0 end
end

function getCellular()
    local c = sub("cellular")
    return c.operator, c.operator_name, c.apn, c.present
end

local function usbCharge()
    return loader.load("usb_charge")
end

function isUsbInserted()
    local uc = usbCharge()
    if uc then return uc.isUsbInserted() == true end
    return getPowerStatus() == 1
end

function isCharging()
    local uc = usbCharge()
    local v = uc and uc.isCharging()
    return v == 1 or v == true
end

return _M
