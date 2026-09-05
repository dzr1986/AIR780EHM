-- ================================================================
-- Filename : runtime_power.lua
-- Module   : 工作模式 + USB/充电/电量/在线访问器（嵌套 APP_RUNTIME 唯一读写入口）
--            + 电源状态机 PSM（refactor_plan P6a）：rest 态唯一写点 requestRest / requestNormal
-- Arch     : 见 doc/overview/LUA_MODULES.md、doc/modules/LOW_POWER_WAKEUP.md §PSM、
--            doc/overview/ARCHITECTURE_REVIEW_POWER_PSM.md（R1 主案）
-- Note     : 转移门禁（低功耗开关 / USB 拦截 / 烧录态）由 app 经 bindPowerGates 注入；
--            副作用（T31x 断电、1002、提示音、lp_wakeup 钩子）留在 app，本模块只裁决与改状态。
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

-- rest 位唯一写点（P6a 起不再导出；业务只能经 requestRest/requestNormal）
local function writeLowPowerMode(on)
    local p = sub("power")
    local v = on and 1 or 0
    if tonumber(p.rest) == v then return false end
    p.rest = v
    return true
end

----------------------------------------------------------------
-- PSM：Normal ⇄ Rest 转移表
--   入口 reason 分两类：用户明确要求（USER_CUT：2002 / AT+LOWPOWER）与策略触发（usb_remove / battery / …）。
--   门禁：gates.enabled()（MODULE_FLAGS.low_power）对所有进入生效；gates.usbBlocks() 只拦策略触发；
--   gates.blocked() 供烧录态等临时锁死。退出 rest 无门禁（对称性：任何退出请求都放行，只是 changed 可能为 false）。
----------------------------------------------------------------
local USER_CUT = { mqtt_2002 = true, at = true }
local gates = {}
-- PSM 副作用表（架构 E 条）：rest 位翻转后的副作用（T31 断电/上电、MQTT 1002、lp_wakeup、提示音）由 app 注入，
-- PSM 在 requestRest/requestNormal 内统一触发；app 不再在 PSM 外自己编排"先改态再副作用"。
--   onEnterRest(reason, changed, userCut)  仅在 requestRest 放行后调用
--   onExitRest(reason, changed)            requestNormal 每次都调用（changed=false 时 app 仍需给 T31 正常上电）
local powerHooks = {}

function bindPowerGates(g)
    gates = type(g) == "table" and g or {}
end

function bindPowerHooks(h)
    powerHooks = type(h) == "table" and h or {}
end

local function fireHook(name, ...)
    local fn = powerHooks[name]
    if type(fn) == "function" then
        fn(...)
    end
end

local function gate(name)
    local fn = gates[name]
    return type(fn) == "function" and fn() == true
end

function isUserCut(reason)
    return USER_CUT[reason] == true
end

-- 进入 rest 的门禁裁决（不改状态）；供 app 在播关机音之前预判，避免「响了却没进」
function canRest(reason)
    if gates.enabled and not gate("enabled") then return false, "low_power_disabled" end
    if gate("blocked") then return false, "blocked" end
    if not isUserCut(reason) and gate("usbBlocks") then return false, "usb_block" end
    return true
end

-- 请求进入 rest：返回 ok, changed, why
--   ok=false 表示被门禁拦或（策略触发）已在 rest；ok=true 时 changed 表示 rest 位是否真的翻转
--   USER_CUT 即使已在 rest 也返回 ok=true（用户要求必须重放副作用：断 T31x / 1002）
function requestRest(reason)
    reason = reason or "unknown"
    local ok, why = canRest(reason)
    if not ok then return false, false, why end
    local userCut = isUserCut(reason)
    if userCut then setWorkMode(WORK_PIR_WATCH) end
    local changed = writeLowPowerMode(true)
    if not userCut and not changed then return false, false, "already_rest" end
    setLastRestReason(reason)
    if sys and sys.publish and _G.APP_EVENTS and _G.APP_EVENTS.POWER_ENTERED_REST then
        sys.publish(_G.APP_EVENTS.POWER_ENTERED_REST, reason)
    end
    fireHook("onEnterRest", reason, changed, userCut)
    return true, changed
end

-- 请求回到 Normal：总是放行；changed 表示 rest 位是否真的翻转
function requestNormal(reason)
    reason = reason or "unknown"
    setWorkMode(WORK_PERSON_DETECT)
    local changed = writeLowPowerMode(false)
    setLastRestReason(nil)
    if changed and sys and sys.publish and _G.APP_EVENTS and _G.APP_EVENTS.POWER_EXITED_REST then
        sys.publish(_G.APP_EVENTS.POWER_EXITED_REST, reason)
    end
    fireHook("onExitRest", reason, changed)
    return true, changed
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
