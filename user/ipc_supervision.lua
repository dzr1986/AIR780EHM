--- Cat.1 侧 IPC 异常监督模块（与 IPC app/cat1/ipc_supervision.* 对称）
-- 契约：ipc_alert_contract.lua ↔ ipc_alert_contract.h
-- @module ipc_supervision

require "sys"

local contract = require "ipc_alert_contract"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local L = "ipc_sup"
local _deps = {}

--- IPCALERT → 1003 扩展字段增量 patch（T3x 主动推送为主，alert 作补充）
local ALERT_CLOUD_PATCH = {
    tf_mount_fail = { tfPresent = 0 },
    time_sync_fail = { timeSynced = 0 },
    time_invalid = { timeSynced = 0 },
    gb28181_register_fail = { gb28181Online = 0 },
}

--- 由 net_mqtt 在模块加载完成后注入上行依赖
function bind(deps)
    if type(deps) == "table" then
        _deps = deps
    end
end

local function publishUplink(opts)
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

local function publishT3xRecordStop(reason, uploadMode, quality)
    if _deps.publish_t3x_record_stop then
        return _deps.publish_t3x_record_stop(reason, uploadMode, quality)
    end
end

local function hostUartMod()
    local ok, hu = pcall(require, "host_uart")
    if ok and type(hu) == "table" then
        return hu
    end
    return nil
end

function ipcCloudStatFields()
    local hu = hostUartMod()
    if not hu or not hu.getCachedHostIpcCloudStat then
        return ""
    end
    local s = hu.getCachedHostIpcCloudStat() or {}
    return string.format(
        ',"ipcReady":%d,"gb28181Online":%d,"tfPresent":%d,"personDetectEnabled":%d,"personDetectAvailable":%d,"timeSynced":%d,"recordingT3x":%d,"cat1Link":%d',
        tonumber(s.ipcReady) or 0,
        tonumber(s.gb28181Online) or 0,
        tonumber(s.tfPresent) or 0,
        tonumber(s.personDetectEnabled) or 0,
        tonumber(s.personDetectAvailable) or 0,
        tonumber(s.timeSynced) or 0,
        tonumber(s.recordingT3x) or 0,
        tonumber(s.cat1Link) or 0)
end

--- 1003 发布前刷新（须在 coroutine/task 内才发 AT 查询；否则仅 merge 缓存）
function refreshIpcCloudStatBefore1003(timeoutMs)
    local hu = hostUartMod()
    if not hu then
        return false
    end
    if not coroutine.running() then
        if hu.mergeTfRecordIntoCloudStat then
            hu.mergeTfRecordIntoCloudStat()
        end
        return false
    end
    if hu.refreshIpcCloudStatFor1003 then
        return hu.refreshIpcCloudStatFor1003(timeoutMs) == true
    end
    return false
end

function mergeHostIpcCloudCache()
    local hu = hostUartMod()
    if hu and hu.mergeTfRecordIntoCloudStat then
        hu.mergeTfRecordIntoCloudStat()
    end
end

local record_reconcile_pending = false

local function scheduleRecordReconcile()
    if record_reconcile_pending then
        return
    end
    record_reconcile_pending = true
    sys.taskInit(function()
        sys.wait(800)
        record_reconcile_pending = false
        local ok_pc, pir_ctrl = pcall(require, "pir_ctrl")
        if not ok_pc or not pir_ctrl or not pir_ctrl.isRecording or not pir_ctrl.isRecording() then
            return
        end
        local hu = hostUartMod()
        if not hu or not hu.isT31StartedForHostQuery or not hu.isT31StartedForHostQuery() then
            return
        end
        if hu.isHostUartQueryBusy and hu.isHostUartQueryBusy() then
            log.info(L, "record_reconcile_skip", "uart_busy")
            return
        end
        if hu.reconcileHostRecordSession then
            hu.reconcileHostRecordSession(3500)
        end
    end)
end

local function patchCloudStatFromAlert(alertCode)
    local patch = ALERT_CLOUD_PATCH[tostring(alertCode or "")]
    if not patch then
        return
    end
    local hu = hostUartMod()
    if hu and hu.patchHostIpcCloudStat then
        pcall(hu.patchHostIpcCloudStat, patch)
    end
end

--- host_uart AT+IPCALERT 解析后或 app 事件总线入口
function onAlert(alertCode, alertDetail)
    publishAlert(alertCode, alertDetail)
end

--- §6.3：T3x AT+IPCALERT → 1004 action=ipc_alert；部分码映射 1011（契约表）
function publishAlert(alertCode, alertDetail)
    alertCode = tostring(alertCode or "unknown")
    alertDetail = tostring(alertDetail or "")
    if not _deps.publish_uplink or not _deps.dt_ul_control then
        log.warn(L, "unbound")
        return
    end
    patchCloudStatFromAlert(alertCode)
    publishUplink({
        suffix = "event",
        dataType = _deps.dt_ul_control,
        no_conn = _deps.nc,
        fields = string.format(
            ',"reply":0,"action":"ipc_alert","alertCode":"%s","alertDetail":"%s","ret":0,"message":"ok"',
            escJson(alertCode),
            escJson(alertDetail)),
        log = "p4ipc",
        log_args = { alertCode, alertDetail },
    })
    if contract.shouldMap1011(alertCode) then
        local uploadMode, quality = "auto", "high"
        local ok_pc, pir_ctrl = pcall(require, "pir_ctrl")
        if ok_pc and pir_ctrl and pir_ctrl.syncStopFromT3x then
            uploadMode, quality = pir_ctrl.syncStopFromT3x(alertCode)
        end
        publishT3xRecordStop(alertCode, uploadMode, quality)
    end
    if contract.shouldReconcile(alertCode) then
        scheduleRecordReconcile()
    end
end

function afterBatteryStatusPublished()
    scheduleRecordReconcile()
end

return _M
