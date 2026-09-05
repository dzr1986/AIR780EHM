-- ================================================================
-- Filename : cell_boot.lua
-- Module   : 蜂窝网络引导：SIM/APN 探测、IP_READY 等待、运营商映射，main 与 net_mqtt 共用
-- Arch     : doc/modules/CELLULAR_BOOTSTRAP.md
-- ================================================================

require "sys"
require "config"
local loader = require "module_loader"
local cfgm = require "config_manager"
local rntmPwr = require "runtime_power"
local utils = require "utils"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local started = false
local apnApplied = false
local cellInfoRefreshActive = false

local CELL_INFO_REQ_SEC = 15
local CELL_INFO_REFRESH_MS = 60000

local lastState = {
    operator = "unknown",
    operator_name = "未知",
    apn = "",
    sim_present = nil,
}

local OPERATOR_NAMES = {
    mobile = "移动",
    telecom = "电信",
    unicom = "联通",
    unknown = "未知",
}

local ICCID_PREFIXES = {
    unicom = { "898601", "898606", "898609" },
    mobile = { "898600", "898602", "898604", "898607", "898608" },
    telecom = { "898603", "898611" },
}

local IMSI_PREFIX_RULES = {
    { "46011", "telecom" }, { "46012", "telecom" },
    { "46010", "unicom" }, { "46009", "unicom" },
    { "46013", "mobile" }, { "46008", "mobile" }, { "46007", "mobile" },
    { "46006", "unicom" }, { "46005", "telecom" },
    { "46004", "mobile" }, { "46003", "telecom" },
    { "46002", "mobile" }, { "46001", "unicom" },
    { "46000", "mobile" },
}

local APN_HINTS = {
    unicom = { "3gnet", "scuiot", "wonet", "uniwap", "unim2m", "ltem2m" },
    mobile = { "cmnet", "cmiot", "cmwap", "cmmtm", "cmcc" },
    telecom = { "ctnet", "ctiot", "ctwap", "ctm2m", "ctlte" },
}

local function cellularCfg()
    return cfgm.get("CELLULAR_CFG")
end

local function operatorName(op)
    return OPERATOR_NAMES[op] or OPERATOR_NAMES.unknown
end

local function matchIccid(iccid)
    iccid = tostring(iccid or "")
    if #iccid < 6 then return nil end
    local head6 = iccid:sub(1, 6)
    for op, prefixes in pairs(ICCID_PREFIXES) do
        for i = 1, #prefixes do
            if head6 == prefixes[i] then return op end
        end
    end
    return nil
end

local function matchImsi(imsi)
    imsi = tostring(imsi or "")
    if #imsi < 5 then return nil end
    for i = 1, #IMSI_PREFIX_RULES do
        local rule = IMSI_PREFIX_RULES[i]
        if imsi:sub(1, #rule[1]) == rule[1] then return rule[2] end
    end
    return nil
end

local function matchApnOp(apn)
    apn = tostring(apn or ""):lower()
    if apn == "" then return nil end
    for op, hints in pairs(APN_HINTS) do
        for i = 1, #hints do
            if apn:find(hints[i], 1, true) then return op end
        end
    end
    return nil
end

local function buildPlmn5(mcc, mnc)
    mcc = tonumber(mcc)
    mnc = tonumber(mnc)
    if mcc ~= 460 or mnc == nil then return nil end
    if mnc >= 0 and mnc <= 9 then return string.format("4600%d", mnc) end
    if mnc >= 10 and mnc <= 99 then return string.format("460%02d", mnc) end
    return nil
end

local function syncRt()
    rntmPwr.setCellular({
        operator = lastState.operator,
        operator_name = lastState.operator_name,
        apn = lastState.apn,
        sim_present = lastState.sim_present,
    })
end

local function syncOperator(operator)
    if not operator or operator == "" or operator == "unknown" then return end
    lastState.operator = operator
    lastState.operator_name = operatorName(operator)
    syncRt()
end

local function enabled()
    return cellularCfg().enabled ~= false and loader.enabled("cellular") and mobile ~= nil
end

local function opOverride()
    local override = cellularCfg().sim_operator_override
    if type(override) == "string" and override ~= "" and override ~= "unknown" then
        return override
    end
end

local function matchOp(imsi, iccid, apn)
    local op = matchImsi(imsi)
    if op then return op, "imsi" end
    op = matchIccid(iccid)
    if op then return op, "iccid" end
    op = matchApnOp(apn)
    if op then return op, "apn" end
    return "unknown", "none"
end

function detectOperator(imsi, iccid, apn)
    return opOverride() or matchOp(imsi, iccid, apn)
end

function resolveOperator(imsi, iccid, apn)
    local override = opOverride()
    if override then
        syncOperator(override)
        return override, operatorName(override), "override"
    end
    local op, src = matchOp(imsi, iccid, apn)
    if op ~= "unknown" then syncOperator(op) end
    return op, operatorName(op), src
end

local function parseServing(cells)
    if type(cells) ~= "table" or #cells == 0 then return nil, nil end
    local c = cells[1]
    if not c or c.mnc == nil then return nil, nil end
    local plmn5 = buildPlmn5(c.mcc, c.mnc)
    local op = plmn5 and matchImsi(plmn5) or nil
    if op then return op, operatorName(op) end
    return nil, nil
end

local function refServing()
    if not mobile or not mobile.getCellInfo then return nil, nil end
    local ok, cells = pcall(mobile.getCellInfo)
    if not ok then return nil, nil end
    return parseServing(cells)
end

local function reqCellInfo(timeoutSec)
    if not mobile or not mobile.reqCellInfo then return false end
    timeoutSec = tonumber(timeoutSec) or CELL_INFO_REQ_SEC
    if timeoutSec < 5 then
        timeoutSec = 5
    elseif timeoutSec > 60 then
        timeoutSec = 60
    end
    mobile.reqCellInfo(timeoutSec)
    return true
end

local function startCellRef()
    if not mobile or not mobile.getCellInfo or not mobile.reqCellInfo then return end
    cellInfoRefreshActive = true
    sys.subscribe("CELL_INFO_UPDATE", function()
        refServing()
    end)
    sys.taskInit(function()
        while true do
            reqCellInfo(CELL_INFO_REQ_SEC)
            sys.waitUntil("CELL_INFO_UPDATE", (CELL_INFO_REQ_SEC + 1) * 1000)
            sys.wait(CELL_INFO_REFRESH_MS)
        end
    end)
end

local function readApn()
    if not mobile or not mobile.apn then return "" end
    local ok, apn = pcall(mobile.apn, 0, 1)
    return ok and apn and tostring(apn) or ""
end

local function forceExplicitApn(operator)
    local force = cellularCfg().force_explicit_apn
    if type(force) == "table" then return force[operator] == true end
    return operator == "unicom"
end

local function resolveApn(operator)
    return (cellularCfg().apn_by_operator or {})[operator]
end

local function apnAuto()
    if not mobile or not mobile.apn then return false, "" end
    mobile.apn(0, 1, "", "", "", nil, 0)
    return true, "auto"
end

local function apnExplicit(apnName)
    if not mobile or not mobile.apn or not apnName or apnName == "" then
        return false, ""
    end
    mobile.apn(0, 1, apnName, "", "", nil, 0)
    return true, apnName
end

function applyApnForSim()
    if not enabled() then return false, "disabled" end
    local imsi = mobile.imsi and mobile.imsi() or ""
    local iccid = mobile.iccid and mobile.iccid() or ""
    local apnNow = readApn()
    local operator = detectOperator(imsi, iccid, apnNow)
    lastState.operator = operator
    lastState.operator_name = operatorName(operator)
    local apnName = resolveApn(operator)
    local useAuto = cellularCfg().apn_auto ~= false and not forceExplicitApn(operator)
    local ok, apnMode
    if apnName and apnName ~= "" and not (useAuto and operator == "unknown") then
        ok, apnMode = apnExplicit(apnName)
    else
        ok, apnMode = apnAuto()
    end
    apnApplied = ok
    lastState.apn = readApn()
    if lastState.apn == "" then lastState.apn = apnMode or "" end
    syncRt()
    return ok, operator
end

local function waitSim(timeoutMs)
    timeoutMs = timeoutMs or tonumber(cellularCfg().sim_wait_ms) or 30000
    local deadline = (mcu and mcu.ticks and mcu.ticks() or 0) + timeoutMs
    while true do
        local imsi = mobile.imsi and mobile.imsi() or ""
        local iccid = mobile.iccid and mobile.iccid() or ""
        if imsi ~= "" or iccid ~= "" then
            return true, imsi, iccid
        end
        local remain = timeoutMs
        if mcu and mcu.ticks then
            remain = deadline - mcu.ticks()
            if remain <= 0 then return false end
        end
        sys.wait(math.min(1000, remain))
        if not mcu or not mcu.ticks then return false end
    end
end

local function onSimInd(status, value)
    if status == "RDY" then
        lastState.sim_present = true
        syncRt()
        if not apnApplied then
            sys.taskInit(function()
                sys.wait(500)
                applyApnForSim()
            end)
        end
    elseif status == "NORDY" then
        lastState.sim_present = false
        apnApplied = false
        syncRt()
    end
end

local function setupAutoApn()
    if not mobile or not mobile.setAuto then return end
    local c = cellularCfg()
    mobile.setAuto(
        tonumber(c.set_auto_interval_ms) or 10000,
        tonumber(c.cell_search_ms) or 30000,
        tonumber(c.set_auto_count) or 5
    )
end

function waitForNetwork()
    if not enabled() then
        local ip = utils.localIp()
        return ip ~= nil, ip
    end
    local cfg = cellularCfg()
    local maxAttempts = tonumber(cfg.max_reset_attempts) or 3
    local timeoutMs = tonumber(cfg.bootstrap_timeout_ms) or 60000
    local resetDelayMs = tonumber(cfg.reset_delay_ms) or 30000
    waitSim()
    applyApnForSim()
    for attempt = 1, maxAttempts do
        local ip = utils.waitLocalIp(timeoutMs)
        if ip then
            lastState.apn = readApn()
            syncRt()
            return true, ip
        end
        if attempt < maxAttempts then
            if attempt == 1 and lastState.operator == "unicom" then
                local fallback = cfg.unicom_apn_fallback
                if fallback and fallback ~= "" and fallback ~= resolveApn("unicom") then
                    apnExplicit(fallback)
                    lastState.apn = fallback
                end
            end
            sys.wait(resetDelayMs)
            if mobile.reset then mobile.reset() end
            sys.wait(5000)
            applyApnForSim()
        end
    end
    syncRt()
    return false, nil
end

function start()
    if not enabled() then return false end
    if started then return true end
    started = true
    if cellularCfg().cell_info_refresh_on_start == true and not cellInfoRefreshActive then
        startCellRef()
    end
    sys.unsubscribe("SIM_IND", onSimInd)
    sys.subscribe("SIM_IND", onSimInd)
    setupAutoApn()
    sys.taskInit(function()
        sys.wait(800)
        if waitSim() then
            applyApnForSim()
        else
            apnAuto()
        end
    end)
    return true
end

return _M
