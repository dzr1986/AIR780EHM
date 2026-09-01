-- ================================================================
-- Filename : ipc_supv.lua
-- Module   : IPC 监管：AT+IPCALERT→1004、1011 映射、录像对账、1003 IPCSTAT 刷新调度
-- Arch     : doc/modules/IPC_SUPERVISION_FLOW.md
-- ================================================================

require "sys"
local utils = require "utils"
local hostUart = require "host_uart"
local pirCtrl = require "pir_ctrl"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

-- net_mqtt.bind 注入上行发布回调
local deps = {}

local TIMEOUT = {
    cloudDebounce = 300,
    cloudQuery = 2500,
    reconcileDebounce = 800,
    reconcileQuery = 3500,
}

-- IPC_ALERT：map1011=是否走 1011 停录；reconcile=告警后是否 SCHED 录像对账
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
    encode_runtime_fail   = { map1011 = false, reconcile = false },
}

local ALERT_CLOUD_PATCH = {
    tf_mount_fail = { tfPresent = 0 },
    time_sync_fail = { timeSynced = 0 },
    time_invalid = { timeSynced = 0 },
    gb28181_register_fail = { gb28181Online = 0 },
}

local CLOUD_STAT_KEYS = {
    "ipcReady", "gb28181Online", "tfPresent", "personDetectEnabled",
    "personDetectAvailable", "timeSynced", "recordingT3x", "wledEnable", "cat1Link",
}

local cloudRefreshBusy = false
local cloudRefreshForce = false
local recordReconcileBusy = false

----------------------------------------------------------------
-- host / 云态
----------------------------------------------------------------

local function hostReady()
    return hostUart.isT31HostQry() == true
end

local function cloudInt(stat, key)
    return tonumber(stat[key]) or 0
end

function bind(injected)
    if type(injected) == "table" then
        deps = injected
    end
end

function ipcCloudStatFields()
    local stat = hostUart.getCloudStat() or {}
    local vals = {}
    for i = 1, #CLOUD_STAT_KEYS do
        vals[i] = cloudInt(stat, CLOUD_STAT_KEYS[i])
    end
    return string.format(
        ',"ipcReady":%d,"gb28181Online":%d,"tfPresent":%d,"personDetectEnabled":%d,"personDetectAvailable":%d,"timeSynced":%d,"recordingT3x":%d,"wledEnable":%d,"cat1Link":%d',
        vals[1], vals[2], vals[3], vals[4], vals[5], vals[6], vals[7], vals[8], vals[9])
end

function mergeHostCache()
    hostUart.mergeTfCloud()
end

function refCloudStat(timeoutMs, force)
    if not utils.inSysTask() then
        hostUart.mergeTfCloud()
        return false
    end
    return hostUart.refCloudF1003(timeoutMs, force) == true
end

----------------------------------------------------------------
-- 调度：云态刷新 / 录像对账
----------------------------------------------------------------

local function scheduleCloudRefresh(force)
    if force then
        cloudRefreshForce = true
    end
    if cloudRefreshBusy or (not force and not hostReady()) then
        return
    end
    cloudRefreshBusy = true
    sys.taskInit(function()
        sys.wait(TIMEOUT.cloudDebounce)
        local mustForce = cloudRefreshForce
        cloudRefreshBusy = false
        cloudRefreshForce = false
        if (mustForce or hostReady()) and not hostUart.isHuBusy() then
            refCloudStat(TIMEOUT.cloudQuery, mustForce)
        end
    end)
end

local function scheduleRecordReconcile()
    if recordReconcileBusy then
        return
    end
    recordReconcileBusy = true
    sys.taskInit(function()
        sys.wait(TIMEOUT.reconcileDebounce)
        recordReconcileBusy = false
        if pirCtrl.isRecording() and hostReady() and not hostUart.isHuBusy() then
            hostUart.recHostSess(TIMEOUT.reconcileQuery)
        end
    end)
end

----------------------------------------------------------------
-- 1004 ipc_alert
----------------------------------------------------------------

local function publishAlertUplink(alertCode, alertDetail)
    deps.pubUplink({
        suffix = "event",
        dataType = deps.dtUlControl,
        fields = string.format(
            ',"reply":0,"action":"ipc_alert","alertCode":"%s","alertDetail":"%s","ret":0,"message":"ok"',
            utils.escJson(alertCode),
            utils.escJson(alertDetail)),
    })
end

local function applyAlertSideEffects(alertCode, rule)
    if rule.map1011 then
        local uploadMode, quality = pirCtrl.syncStopT3x(alertCode)
        if deps.pubT3xStop then
            deps.pubT3xStop(alertCode, uploadMode, quality)
        end
    end
    if rule.reconcile and not recordReconcileBusy then
        scheduleRecordReconcile()
    end
end

function pubAlert(alertCode, alertDetail)
    alertCode = tostring(alertCode or "unknown")
    alertDetail = tostring(alertDetail or "")
    if not deps.pubUplink or not deps.dtUlControl then
        return
    end
    local patch = ALERT_CLOUD_PATCH[alertCode]
    if patch then
        hostUart.patchCloud(patch)
    end
    publishAlertUplink(alertCode, alertDetail)
    local rule = IPC_ALERT[alertCode]
    if rule then
        applyAlertSideEffects(alertCode, rule)
    end
    scheduleCloudRefresh(true)
end

function afterBatteryStatusPublished()
    if not recordReconcileBusy then
        scheduleRecordReconcile()
    end
    scheduleCloudRefresh(false)
end

return _M
