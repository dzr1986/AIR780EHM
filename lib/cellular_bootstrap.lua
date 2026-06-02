--- 蜂窝入网引导：运营商识别、APN 配置、SIM 状态、IP_READY 重试
-- 参考 v2026.03.24.12/demo/mobile/mobile_test.lua、pwrkey_rndis_boot/net.lua
-- @module cellular_bootstrap
-- @release v1_20260529

require "sys"
require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "cellular"

local started = false
local apnApplied = false
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

local function cfg()
    return _G.CELLULAR_CFG or {}
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

--- 根据 IMSI / ICCID 识别运营商（mobile / telecom / unicom / unknown）
function detectOperator(imsi, iccid)
    imsi = tostring(imsi or "")
    iccid = tostring(iccid or "")

    if iccid:sub(1, 6) == "898601" then
        return "unicom"
    end
    if iccid:sub(1, 6) == "898603" then
        return "telecom"
    end
    if iccid:sub(1, 6) == "898600" then
        return "mobile"
    end

    local plmn5 = imsi:sub(1, 5)
    if plmn5 == "46001" or plmn5 == "46006" or plmn5 == "46009" then
        return "unicom"
    end
    if plmn5 == "46003" or plmn5 == "46011" then
        return "telecom"
    end
    if plmn5 == "46000" or plmn5 == "46002" or plmn5 == "46004"
        or plmn5 == "46007" or plmn5 == "46008" then
        return "mobile"
    end
    return "unknown"
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

--- 按当前 SIM 识别运营商并配置 APN（须在 IP_READY 前调用）
function applyApnForSim()
    if not enabled() then
        return false, "disabled"
    end

    local imsi = mobile.imsi and mobile.imsi() or ""
    local iccid = mobile.iccid and mobile.iccid() or ""
    local operator = detectOperator(imsi, iccid)
    lastState.operator = operator
    lastState.operator_name = OPERATOR_NAMES[operator] or OPERATOR_NAMES.unknown

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

    log.info(LOG_TAG, "运营商", lastState.operator_name, operator,
        "imsi", imsi ~= "" and imsi or "--",
        "iccid", iccid ~= "" and iccid:sub(1, 10) .. "..." or "--",
        "apn", lastState.apn ~= "" and lastState.apn or apnMode or "--")
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
    log.info(LOG_TAG, "SIM_IND", status, value or "")
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
    log.info(LOG_TAG, "setAuto 已配置")
end

--- 等待 IP_READY，失败时 mobile.reset 重试（参考 pwrkey_rndis_boot/net.lua）
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
        if socket and socket.localIP then
            local curIp = socket.localIP()
            if curIp and curIp ~= "" and curIp ~= "0.0.0.0" then
                lastState.ip = curIp
                lastState.ip_ready = true
                lastState.apn = readCurrentApn()
                exportRuntime()
                log.info(LOG_TAG, "已有 IP", curIp, "operator", lastState.operator_name)
                return true, curIp
            end
        end

        log.info(LOG_TAG, "等待 IP_READY", attempt, "/", maxAttempts,
            "operator", lastState.operator_name)
        local ret = sys.waitUntil("IP_READY", timeoutMs)
        local ip = socket and socket.localIP and socket.localIP() or nil
        if ret and ip and ip ~= "" and ip ~= "0.0.0.0" then
            lastState.ip = ip
            lastState.ip_ready = true
            lastState.apn = readCurrentApn()
            exportRuntime()
            log.info(LOG_TAG, "IP_READY", ip, "apn", lastState.apn or "--")
            return true, ip
        end

        log.warn(LOG_TAG, "入网失败", "attempt", attempt,
            "status", mobile.status and mobile.status() or "?",
            "csq", mobile.csq and mobile.csq() or "?",
            "apn", readCurrentApn())

        if attempt < maxAttempts then
            if attempt == 1 and lastState.operator == "unicom" then
                local fallback = cfg().unicom_apn_fallback
                if fallback and fallback ~= "" and fallback ~= resolveApnName("unicom") then
                    log.info(LOG_TAG, "联通 APN 回退", fallback)
                    applyApnExplicit(fallback)
                    lastState.apn = fallback
                end
            end
            log.info(LOG_TAG, resetDelayMs / 1000, "s 后 mobile.reset")
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

    sys.subscribe("SIM_IND", onSimInd)
    setupSetAuto()

    sys.taskInit(function()
        sys.wait(800)
        local ok = waitSimInfo()
        if ok then
            applyApnForSim()
        else
            log.warn(LOG_TAG, "SIM 信息超时，仍尝试自动 APN")
            applyApnAuto()
        end
    end)

    log.info(LOG_TAG, "已启动")
    return true
end

function getLastState()
    return lastState
end

function getOperatorName()
    return lastState.operator_name, lastState.operator
end

log.info(LOG_TAG, "loaded")
return _M
