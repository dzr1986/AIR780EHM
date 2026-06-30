--- Cat.1 侧 IPC 异常监督（镜像 app/cat1/ipc_supervision.*）
-- 专题：doc/modules/IPC_SUPERVISION_FLOW.md
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

--- 后台调度去重（1003 发布后 / ipc_alert 后各一条）
local ipc_stat_refresh_pending = false
local ipc_stat_refresh_force = false
local record_reconcile_pending = false

--- 由 net_mqtt 在模块加载完成后注入上行依赖
function bind(deps)
    if type(deps) == "table" then
        _deps = deps
    end
end

-- ---------------------------------------------------------------------------
-- 依赖与 host_uart 懒加载
-- ---------------------------------------------------------------------------

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

local function pirCtrlMod()
    local ok, pc = pcall(require, "pir_ctrl")
    if ok and type(pc) == "table" then
        return pc
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 1003 IPC 扩展状态（§6.2）
-- ---------------------------------------------------------------------------

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

function mergeHostIpcCloudCache()
    local hu = hostUartMod()
    if hu and hu.mergeTfRecordIntoCloudStat then
        hu.mergeTfRecordIntoCloudStat()
    end
end

--- 1003 发布前刷新（须在 coroutine/task 内才发 AT 查询；否则仅 merge 缓存）
function refreshIpcCloudStatBefore1003(timeoutMs, force)
    local hu = hostUartMod()
    if not hu then
        return false
    end
    if not coroutine.running() then
        mergeHostIpcCloudCache()
        return false
    end
    if hu.refreshIpcCloudStatFor1003 then
        return hu.refreshIpcCloudStatFor1003(timeoutMs, force) == true
    end
    mergeHostIpcCloudCache()
    return type(hu.getCachedHostIpcCloudStat and hu.getCachedHostIpcCloudStat()) == "table"
end

--- T3x 休眠/未上电时跳过后台 IPCSTAT 拉取（省电）
local function isT3xIdleForIpcRefresh()
    local hu = hostUartMod()
    if not hu or not hu.isT31StartedForHostQuery then
        return true
    end
    return hu.isT31StartedForHostQuery() ~= true
end

--- 1003 on_published(force=false) / ipc_alert 后(force=true) 调度 IPCSTAT 刷新
local function scheduleIpcCloudStatRefresh(force)
    force = force == true
    if force then
        ipc_stat_refresh_force = true
    elseif isT3xIdleForIpcRefresh() then
        log.info(L, "ipc_stat_skip", "t3x_idle")
        return
    end
    if ipc_stat_refresh_pending then
        return
    end
    ipc_stat_refresh_pending = true
    sys.taskInit(function()
        sys.wait(300)
        ipc_stat_refresh_pending = false
        local doForce = ipc_stat_refresh_force
        ipc_stat_refresh_force = false
        if not doForce and isT3xIdleForIpcRefresh() then
            log.info(L, "ipc_stat_skip", "t3x_idle")
            return
        end
        refreshIpcCloudStatBefore1003(2500, doForce)
    end)
end

-- ---------------------------------------------------------------------------
-- 录像会话对账（§4.3）
-- ---------------------------------------------------------------------------

local function canReconcileRecord()
    local pc = pirCtrlMod()
    if not pc or not pc.isRecording or not pc.isRecording() then
        return false
    end
    local hu = hostUartMod()
    if not hu then
        return false
    end
    if not hu.isT31StartedForHostQuery or not hu.isT31StartedForHostQuery() then
        return false
    end
    if hu.isHostUartQueryBusy and hu.isHostUartQueryBusy() then
        return false, "uart_busy"
    end
    return true
end

local function scheduleRecordReconcile()
    if record_reconcile_pending then
        return
    end
    record_reconcile_pending = true
    sys.taskInit(function()
        sys.wait(800)
        record_reconcile_pending = false
        local ok, reason = canReconcileRecord()
        if not ok then
            if reason then
                log.info(L, "record_reconcile_skip", reason)
            end
            return
        end
        local hu = hostUartMod()
        if hu and hu.reconcileHostRecordSession then
            hu.reconcileHostRecordSession(3500)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- IPCALERT 处理（§6.3）
-- ---------------------------------------------------------------------------

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

local function publishIpcAlertUplink(alertCode, alertDetail)
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
end

local function handleMap1011(alertCode)
    if not contract.shouldMap1011(alertCode) then
        return
    end
    local uploadMode, quality = "auto", "high"
    local pc = pirCtrlMod()
    if pc and pc.syncStopFromT3x then
        uploadMode, quality = pc.syncStopFromT3x(alertCode)
    end
    publishT3xRecordStop(alertCode, uploadMode, quality)
end

--- host_uart AT+IPCALERT 解析后或 app 事件总线入口
function onAlert(alertCode, alertDetail)
    publishAlert(alertCode, alertDetail)
end

--- T3x AT+IPCALERT → 1004 action=ipc_alert；部分码映射 1011（契约表）
function publishAlert(alertCode, alertDetail)
    alertCode = tostring(alertCode or "unknown")
    alertDetail = tostring(alertDetail or "")
    if not _deps.publish_uplink or not _deps.dt_ul_control then
        log.warn(L, "unbound")
        return
    end

    -- 1. 补丁 1003 缓存 → 2. 发 1004 → 3. 1011 / 对账 → 4. 强制 IPCSTAT
    patchCloudStatFromAlert(alertCode)
    publishIpcAlertUplink(alertCode, alertDetail)
    handleMap1011(alertCode)
    if contract.shouldReconcile(alertCode) then
        scheduleRecordReconcile()
    end
    scheduleIpcCloudStatRefresh(true)
end

function afterBatteryStatusPublished()
    scheduleRecordReconcile()
    scheduleIpcCloudStatRefresh(false)
end

return _M
