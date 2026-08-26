-- ================================================================
-- Filename : ipc_supervision.lua
-- Module   : IPC 监管：AT+IPCALERT→1004、1011 映射、录像对账、1003 IPCSTAT 刷新调度
-- Arch     : doc/modules/IPC_SUPERVISION_FLOW.md
-- ================================================================

require "sys"
local loader = require "module_loader"
local utils = require "utils"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local _deps = {}
local IPC_ALERT = {
    tf_mount_fail         = { map1011 = false, reconcile = false },
    uart_notify_fail      = { map1011 = false, reconcile = true },
    snapshot_failed       = { map1011 = true,  reconcile = false },
    gb28181_register_fail = { map1011 = false, reconcile = true },
    defer_record_failed   = { map1011 = true,  reconcile = false },
    hostevt_read_fail     = { map1011 = false, reconcile = false },
    no_person             = { map1011 = true,  reconcile = false },
    dispatch_failed       = { map1011 = false, reconcile = true },
    runtime_wakeup_fail   = { map1011 = false, reconcile = false },
    time_sync_fail        = { map1011 = true,  reconcile = false },
    time_invalid          = { map1011 = true,  reconcile = false },
    usb_recovery_fail     = { map1011 = false, reconcile = true },
    recordctrl_fail       = { map1011 = true,  reconcile = false },
    ipcpoweroff_busy      = { map1011 = false, reconcile = false },
}
local CAT1_ONLY = {
    encode_runtime_fail = { map1011 = false, reconcile = false },
}
local function alertLookup(code)
    code = tostring(code or "")
    return IPC_ALERT[code] or CAT1_ONLY[code]
end

local function shldRcnc(code)
    local e = alertLookup(code)
    return e and e.reconcile == true
end
local ALERT_CLOUD_PATCH = {
    tf_mount_fail = { tfPresent = 0 },
    time_sync_fail = { timeSynced = 0 },
    time_invalid = { timeSynced = 0 },
    gb28181_register_fail = { gb28181Online = 0 },
}
local ipcStatRfrsh = false
local ipcStatRfrs = false
local rcrdRcnc = false
function bind(deps)
    if type(deps) == "table" then
        _deps = deps
    end
end

local function pblsUpln(opts)
    if _deps.publish_uplink then
        return _deps.publish_uplink(opts)
    end
end

local function escJson(s)
    if _deps.esc_json then
        return _deps.esc_json(s)
    end
    return tostring(s or "")
end

local function pubT3xStop(reason, uploadMode, quality)
    if _deps.publish_t3x_record_stop then
        return _deps.publish_t3x_record_stop(reason, uploadMode, quality)
    end
end

local function hostUartMod()
    return loader.load("host_uart")
end

local function pirCtrlMod()
    return loader.load("pir_ctrl")
end

function ipcCloudStatFields()
    local hu = hostUartMod()
    if not hu or not hu.getCloudStat then
        return ""
    end
    local s = hu.getCloudStat() or {}
    return string.format(
        ',"ipcReady":%d,"gb28181Online":%d,"tfPresent":%d,"personDetectEnabled":%d,"personDetectAvailable":%d,"timeSynced":%d,"recordingT3x":%d,"wledEnable":%d,"cat1Link":%d',
        tonumber(s.ipcReady) or 0,
        tonumber(s.gb28181Online) or 0,
        tonumber(s.tfPresent) or 0,
        tonumber(s.personDetectEnabled) or 0,
        tonumber(s.personDetectAvailable) or 0,
        tonumber(s.timeSynced) or 0,
        tonumber(s.recordingT3x) or 0,
        tonumber(s.wledEnable) or 0,
        tonumber(s.cat1Link) or 0)
end

function mrgHostCache()
    local hu = hostUartMod()
    if hu and hu.mrgTfCloudStat then
        hu.mrgTfCloudStat()
    end
end

function refCloudB1003(timeoutMs, force)
    local hu = hostUartMod()
    if not hu then
        return false
    end
    -- Lua 5.3 主调度里 coroutine.running() 非 nil，须用 inSysTask 判断能否 sys.wait
    if not utils.inSysTask() then
        mrgHostCache()
        return false
    end
    if hu.refCloudF1003 then
        return hu.refCloudF1003(timeoutMs, force) == true
    end
    mrgHostCache()
    return type(hu.getCloudStat and hu.getCloudStat()) == "table"
end

local function is3XIdleFor()
    local hu = hostUartMod()
    if not hu or not hu.isT31HostQry then
        return true
    end
    return hu.isT31HostQry() ~= true
end

local function scheIpcClou(force)
    force = force == true
    if force then
        ipcStatRfrs = true
    elseif is3XIdleFor() then
        return
    end
    if ipcStatRfrsh then
        return
    end
    ipcStatRfrsh = true
    sys.taskInit(function()
        sys.wait(300)
        ipcStatRfrsh = false
        local doForce = ipcStatRfrs
        ipcStatRfrs = false
        if not doForce and is3XIdleFor() then
            return
        end
        local hu = hostUartMod()
        if hu and hu.isHUBusy and hu.isHUBusy() then
            return
        end
        refCloudB1003(2500, doForce)
    end)
end

local function canRcncRcrd()
    local pc = pirCtrlMod()
    if not pc or not pc.isRecording or not pc.isRecording() then
        return false
    end
    local hu = hostUartMod()
    if not hu then
        return false
    end
    if not hu.isT31HostQry or not hu.isT31HostQry() then
        return false
    end
    if hu.isHUBusy and hu.isHUBusy() then
        return false, "uart_busy"
    end
    return true
end

local function scheRecRec()
    if rcrdRcnc then
        return
    end
    rcrdRcnc = true
    sys.taskInit(function()
        sys.wait(800)
        rcrdRcnc = false
        local ok = canRcncRcrd()
        if not ok then
            return
        end
        local hu = hostUartMod()
        if hu and hu.recHostSess then
            hu.recHostSess(3500)
        end
    end)
end

local function ptchCldStat(alertCode)
    local patch = ALERT_CLOUD_PATCH[tostring(alertCode or "")]
    if not patch then
        return
    end
    local hu = hostUartMod()
    if hu and hu.pchCloudStat then
        pcall(hu.pchCloudStat, patch)
    end
end

local function pblsIpcAlrt(alertCode, alertDetail)
    pblsUpln({
        suffix = "event",
        dataType = _deps.dt_ul_control,
        fields = string.format(
            ',"reply":0,"action":"ipc_alert","alertCode":"%s","alertDetail":"%s","ret":0,"message":"ok"',
            escJson(alertCode),
            escJson(alertDetail))
    })
end

local function hndlMap1011(alertCode)
    local e = alertLookup(alertCode)
    if not (e and e.map1011 == true) then
        return
    end
    local uploadMode, quality = "auto", "high"
    local pc = pirCtrlMod()
    if pc and pc.syncStopT3x then
        uploadMode, quality = pc.syncStopT3x(alertCode)
    end
    pubT3xStop(alertCode, uploadMode, quality)
end

function onAlert(alertCode, alertDetail)
    publishAlert(alertCode, alertDetail)
end

function publishAlert(alertCode, alertDetail)
    alertCode = tostring(alertCode or "unknown")
    alertDetail = tostring(alertDetail or "")
    if not _deps.publish_uplink or not _deps.dt_ul_control then
        return
    end
    ptchCldStat(alertCode)
    pblsIpcAlrt(alertCode, alertDetail)
    hndlMap1011(alertCode)
    if shldRcnc(alertCode) then
        scheRecRec()
    end
    scheIpcClou(true)
end

function afterBatteryStatusPublished()
    scheRecRec()
    scheIpcClou(false)
end
return _M
