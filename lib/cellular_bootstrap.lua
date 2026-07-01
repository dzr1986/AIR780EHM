require "sys"
require "config"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local LOG_TAG = "cellular_bootstrap"
local started = false
local apnApplied = false
local cellInfoRefreshStarted = false
local servingOperatorCache = { op = nil, name = nil }
local CELL_INFO_REQ_SEC = 15
local CELL_INFO_REFRESH_MS = 60000
local lastState = {
    operator = "unknown",
    operator_name = "未知",
    apn = "",
    sim_present = nil,
    ip = nil,
    ip_ready = false,
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
    { "46011", "telecom" },
    { "46012", "telecom" },
    { "46010", "unicom" },
    { "46009", "unicom" },
    { "46013", "mobile" },
    { "46008", "mobile" },
    { "46007", "mobile" },
    { "46006", "unicom" },
    { "46005", "telecom" },
    { "46004", "mobile" },
    { "46003", "telecom" },
    { "46002", "mobile" },
    { "46001", "unicom" },
    { "46000", "mobile" },
}
local APN_HINTS = {
    unicom = { "3gnet", "scuiot", "wonet", "uniwap", "unim2m", "ltem2m" },
    mobile = { "cmnet", "cmiot", "cmwap", "cmmtm", "cmcc" },
    telecom = { "ctnet", "ctiot", "ctwap", "ctm2m", "ctlte" },
}
local function operatorName(op)
    return OPERATOR_NAMES[op] or OPERATOR_NAMES.unknown
end
local function matchIccidOperator(iccid)
    iccid = tostring(iccid or "")
    if #iccid < 6 then
        return nil
    end
    local head6 = iccid:sub(1, 6)
    for op, prefixes in pairs(ICCID_PREFIXES) do
        for i = 1, #prefixes do
            if head6 == prefixes[i] then
                return op
            end
        end
    end
    return nil
end
local function matchImsiOperator(imsi)
    imsi = tostring(imsi or "")
    if #imsi < 5 then
        return nil
    end
    for i = 1, #IMSI_PREFIX_RULES do
        local rule = IMSI_PREFIX_RULES[i]
        local prefix = rule[1]
        if imsi:sub(1, #prefix) == prefix then
            return rule[2]
        end
    end
    return nil
end
local function matchApnOperator(apn)
    apn = tostring(apn or ""):lower()
    if apn == "" then
        return nil
    end
    for op, hints in pairs(APN_HINTS) do
        for i = 1, #hints do
            if apn:find(hints[i], 1, true) then
                return op
            end
        end
    end
    return nil
end
local function operatorFromPlmn5(plmn5)
    return plmn5 and matchImsiOperator(plmn5) or nil
end
local function buildPlmn5(mcc, mnc)
    mcc = tonumber(mcc)
    mnc = tonumber(mnc)
    if mcc ~= 460 or mnc == nil then
        return nil
    end
    if mnc >= 0 and mnc <= 9 then
        return string.format("4600%d", mnc)
    end
    if mnc >= 10 and mnc <= 99 then
        return string.format("460%02d", mnc)
    end
    return nil
end
local function cfg()
    return _G.CELLULAR_CFG or {}
end
local function exportRuntime()
    local rt = _G.APP_RUNTIME
    if not rt then
        return
    end
    rt.sim_operator = lastState.operator
    rt.sim_operator_name = lastState.operator_name
    rt.cellular_apn = lastState.apn
    if lastState.sim_present ~= nil then
        rt.sim_present = lastState.sim_present and 1 or 0
    end
end
local function syncOperatorRuntime(operator)
    if not operator or operator == "" or operator == "unknown" then
        return
    end
    lastState.operator = operator
    lastState.operator_name = operatorName(operator)
    exportRuntime()
end
local function enabled()
    if cfg().enabled == false then
        return false
    end
    local flags = _G.MODULE_FLAGS
    if flags and flags.cellular == false then
        return false
    end
    return mobile ~= nil
end
local function operatorOverride()
    local override = cfg().sim_operator_override
    if type(override) == "string" and override ~= "" and override ~= "unknown" then
        return override
    end
end
local function matchOperator(imsi, iccid, apn)
    local op = matchImsiOperator(imsi)
    if op then
        return op, "imsi"
    end
    op = matchIccidOperator(iccid)
    if op then
        return op, "iccid"
    end
    op = matchApnOperator(apn)
    if op then
        return op, "apn"
    end
    return "unknown", "none"
end
function detectOperator(imsi, iccid, apn)
    return operatorOverride() or matchOperator(imsi, iccid, apn)
end
function resolveOperator(imsi, iccid, apn)
    local override = operatorOverride()
    if override then
        syncOperatorRuntime(override)
        return override, operatorName(override), "override"
    end
    local op, src = matchOperator(imsi, iccid, apn)
    local name = operatorName(op)
    if op ~= "unknown" then
        syncOperatorRuntime(op)
    end
    return op, name, src
end
local function parseServingFromCells(cells)
    if type(cells) ~= "table" or #cells == 0 then
        return nil, nil
    end
    local c = cells[1]
    if not c or c.mnc == nil then
        return nil, nil
    end
    local plmn5 = buildPlmn5(c.mcc, c.mnc)
    local op = operatorFromPlmn5(plmn5)
    if op then
        return op, operatorName(op)
    end
    return nil, nil
end
local function refreshServingOperatorCache()
    if not mobile or not mobile.getCellInfo then
        return nil, nil
    end
    local ok, cells = pcall(mobile.getCellInfo)
    if not ok then
        return nil, nil
    end
    local op, name = parseServingFromCells(cells)
    if op then
        servingOperatorCache.op = op
        servingOperatorCache.name = name
    end
    return op, name
end
local function requestCellInfo(timeoutSec)
    if not mobile or not mobile.reqCellInfo then
        return false
    end
    timeoutSec = tonumber(timeoutSec) or CELL_INFO_REQ_SEC
    if timeoutSec < 5 then
        timeoutSec = 5
    elseif timeoutSec > 60 then
        timeoutSec = 60
    end
    mobile.reqCellInfo(timeoutSec)
    return true
end
local function cellInfoRefreshWanted()
    if _G.MODULE_FLAGS and _G.MODULE_FLAGS.mobile_info == true then
        return true
    end
    return cfg().cell_info_refresh_on_start == true
end
local function startCellInfoRefresh()
    if cellInfoRefreshStarted or not mobile or not mobile.getCellInfo or not mobile.reqCellInfo then
        return
    end
    cellInfoRefreshStarted = true
    sys.subscribe("CELL_INFO_UPDATE", function()
        refreshServingOperatorCache()
    end)
    sys.taskInit(function()
        while true do
            requestCellInfo(CELL_INFO_REQ_SEC)
            sys.waitUntil("CELL_INFO_UPDATE", (CELL_INFO_REQ_SEC + 1) * 1000)
            sys.wait(CELL_INFO_REFRESH_MS)
        end
    end)
end
function detectServingOperator()
    startCellInfoRefresh()
    if servingOperatorCache.op then
        return servingOperatorCache.op, servingOperatorCache.name
    end
    return nil, nil
end
local function readCurrentApn()
    if not mobile or not mobile.apn then
        return ""
    end
    local ok, apn = pcall(mobile.apn, 0, 1)
    if ok and apn then
        return tostring(apn)
    end
    return ""
end
local function shouldForceExplicitApn(operator)
    local force = cfg().force_explicit_apn
    if type(force) == "table" then
        return force[operator] == true
    end
    return operator == "unicom"
end
local function resolveApnName(operator)
    local byOp = cfg().apn_by_operator or {}
    return byOp[operator]
end
local function applyApnAuto()
    if not mobile or not mobile.apn then
        return false, ""
    end
    mobile.apn(0, 1, "", "", "", nil, 0)
    return true, "auto"
end
local function applyApnExplicit(apnName)
    if not mobile or not mobile.apn or not apnName or apnName == "" then
        return false, ""
    end
    mobile.apn(0, 1, apnName, "", "", nil, 0)
    return true, apnName
end
function applyApnForSim()
    if not enabled() then
        return false, "disabled"
    end
    local imsi = mobile.imsi and mobile.imsi() or ""
    local iccid = mobile.iccid and mobile.iccid() or ""
    local apnNow = readCurrentApn()
    local operator = detectOperator(imsi, iccid, apnNow)
    lastState.operator = operator
    lastState.operator_name = operatorName(operator)
    local ok, apnMode
    local apnName = resolveApnName(operator)
    local useAuto = cfg().apn_auto ~= false and not shouldForceExplicitApn(operator)
    if useAuto and (operator == "unknown" or not apnName or apnName == "") then
        ok, apnMode = applyApnAuto()
    elseif apnName and apnName ~= "" then
        ok, apnMode = applyApnExplicit(apnName)
    else
        ok, apnMode = applyApnAuto()
    end
    apnApplied = ok
    lastState.apn = readCurrentApn()
    if lastState.apn == "" then
        lastState.apn = apnMode or ""
    end
    exportRuntime()
    return ok, operator
end
local function waitSimInfo(timeoutMs)
    timeoutMs = timeoutMs or tonumber(cfg().sim_wait_ms) or 30000
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
            if remain <= 0 then
                return false
            end
        end
        sys.wait(math.min(1000, remain))
        if not mcu or not mcu.ticks then
            return false
        end
    end
end
local function onSimInd(status, value)
    if status == "RDY" then
        lastState.sim_present = true
        exportRuntime()
        if not apnApplied then
            sys.taskInit(function()
                sys.wait(500)
                applyApnForSim()
            end)
        end
    elseif status == "NORDY" then
        lastState.sim_present = false
        apnApplied = false
        exportRuntime()
    end
end
local function setupSetAuto()
    if not mobile or not mobile.setAuto then
        return
    end
    local c = cfg()
    mobile.setAuto(
        tonumber(c.set_auto_interval_ms) or 10000,
        tonumber(c.cell_search_ms) or 30000,
        tonumber(c.set_auto_count) or 5
    )
end
function waitForNetwork()
    if not enabled() then
        local ip = socket and socket.localIP and socket.localIP() or nil
        return ip ~= nil and ip ~= "", ip
    end
    local maxAttempts = tonumber(cfg().max_reset_attempts) or 3
    local timeoutMs = tonumber(cfg().bootstrap_timeout_ms) or 60000
    local resetDelayMs = tonumber(cfg().reset_delay_ms) or 30000
    waitSimInfo()
    applyApnForSim()
    for attempt = 1, maxAttempts do
        local ret = sys.waitUntil("IP_READY", timeoutMs)
        local ip = socket and socket.localIP and socket.localIP() or nil
        if ret and ip and ip ~= "" and ip ~= "0.0.0.0" then
            lastState.ip = ip
            lastState.ip_ready = true
            lastState.apn = readCurrentApn()
            exportRuntime()
            return true, ip
        end
        if attempt < maxAttempts then
            if attempt == 1 and lastState.operator == "unicom" then
                local fallback = cfg().unicom_apn_fallback
                if fallback and fallback ~= "" and fallback ~= resolveApnName("unicom") then
                    applyApnExplicit(fallback)
                    lastState.apn = fallback
                end
            end
            sys.wait(resetDelayMs)
            if mobile.reset then
                mobile.reset()
            end
            sys.wait(5000)
            applyApnForSim()
        end
    end
    lastState.ip_ready = false
    exportRuntime()
    return false, nil
end
function start()
    if started or not enabled() then
        return false
    end
    started = true
    if cellInfoRefreshWanted() then
        startCellInfoRefresh()
    end
    sys.subscribe("SIM_IND", onSimInd)
    setupSetAuto()
    sys.taskInit(function()
        sys.wait(800)
        local ok = waitSimInfo()
        if ok then
            applyApnForSim()
        else
            applyApnAuto()
        end
    end)
    return true
end
function getLastState()
    return lastState
end
function getOperatorName()
    return lastState.operator_name, lastState.operator
end
return _M
