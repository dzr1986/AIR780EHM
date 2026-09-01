-- ================================================================
-- Filename : hu_ipc_cloud.lua
-- Module   : IPC 云状态 / GB28181 / qryIpcCloudStat，由 hu_ipc.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- 云态缓存 / IPCSTAT 刷新 / 录像对账 recHostSess
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, H)
    local state, SYS_EVT, E = C.state, C.SYS_EVT, C.E
    local modCall = C.modCall
    local hostBusy = C.hostBusy
    local wledGet = C.wledGet
    local normIpcCloud = C.normIpcCloud
    local commitIpcStat = C.commitIpcStat
    local getCfg, hostQuery = H.getCfg, H.hostQuery
    local defineQuery = H.defineQuery
    local idCfgFn = H.idCfgFn
    local qryHostStat, qryHostRecord = H.qryHostStat, H.qryHostRecord

    local TIMEOUT = {
        gb28181Query = 3000,
        cloudStatQuery = 2500,
        statusRefreshCap = 1500,
        recordReconcile = 3500,
        cacheMaxAgeDefault = 90,
    }

    local HU_BUSY_KEYS = {
        "uart_txn_busy", "encode_query_busy", "encode_set_busy",
        "record_query_busy", "recordtime_query_busy", "tf_card_query_busy",
        "ipc_status_query_busy", "ipc_cloud_stat_query_busy",
        "ipc_poweroff_busy", "tfcard_format_busy", "uart_recovery_busy",
    }

    ----------------------------------------------------------------
    -- GB28181
    ----------------------------------------------------------------

    local function cachedGb28181Id()
        return state.host_gb28181_id
    end

    local qryGb28181 = defineQuery{
        busy = "gb28181_query_busy", cache = "host_gb28181_id",
        tag = "host_identity", cfg = idCfgFn, tmo = TIMEOUT.gb28181Query,
        at = "AT+GB28181?", ev = SYS_EVT.GB28181_ACK,
        rsp = function(got, id)
            if got and id ~= nil then
                state.host_gb28181_id = id
            end
            return state.host_gb28181_id
        end,
    }

    ----------------------------------------------------------------
    -- 云态合成
    ----------------------------------------------------------------

    local function recActiveFlag(rec)
        if type(rec) ~= "table" then
            return nil
        end
        if (tonumber(rec.running) or 0) == 1
            or (tonumber(rec.active) or 0) == 1
            or (tonumber(rec.recording) or 0) == 1 then
            return 1
        end
        return 0
    end

    local function applyTfToCloud(cloud)
        local tf = state.host_tf_card
        if type(tf) ~= "table" or not tf.parsed then
            return cloud
        end
        cloud.tfPresent = (tonumber(tf.present) or 0) == 1 and 1 or 0
        return cloud
    end

    local function applyRecordToCloud(cloud)
        local recActive = recActiveFlag(state.host_record)
        if recActive == nil then
            return cloud
        end
        cloud.recordingT3x = recActive
        state.t3x_rec_active = recActive
        return cloud
    end

    local function applyLiveOverlay(snap)
        if type(snap) ~= "table" then
            return snap
        end
        if state.host_at_ready and (tonumber(snap.cat1Link) or 0) == 0 then
            snap.cat1Link = 1
        end
        local pst = modCall("t3x_ctrl", "getState")
        if pst and pst.powered_on and (tonumber(snap.cat1Link) or 0) == 0 then
            snap.cat1Link = 1
        end
        if state.host_ipc_status == "ready" and (tonumber(snap.ipcReady) or 0) == 0 then
            snap.ipcReady = 1
        end
        if tonumber(state.t3x_rec_active) == 1 then
            snap.recordingT3x = 1
        end
        snap.wledEnable = wledGet()
        return snap
    end

    local function finalizeCloud(cloud)
        return applyLiveOverlay(applyTfToCloud(normIpcCloud(cloud)))
    end

    local function defaultCloudSkeleton()
        local life = state.host_ipc_status or "idle"
        local ipcReady = (life == "ready") and 1 or 0
        local cat1Link = (ipcReady == 1 or state.host_at_ready) and 1 or 0
        return {
            ipcReady = ipcReady,
            gb28181Online = 0,
            tfPresent = 0,
            personDetectEnabled = 0,
            personDetectAvailable = 0,
            timeSynced = 0,
            recordingT3x = (tonumber(state.t3x_rec_active) == 1) and 1 or 0,
            wledEnable = wledGet(),
            cat1Link = cat1Link,
        }
    end

    local function cloudCacheReady()
        return type(state.host_ipc_cloud_stat) == "table"
    end

    local function isIpcCloudStatStale()
        local cached = state.host_ipc_cloud_stat
        local ts = tonumber(state.ipc_cloud_stat_ts) or 0
        if type(cached) ~= "table" or next(cached) == nil or ts == 0 then
            return true
        end
        local maxAge = tonumber(getCfg("HOST_IPC_CFG").status_cache_max_age_sec)
            or TIMEOUT.cacheMaxAgeDefault
        return os.time() - ts > maxAge
    end

    local function getCloudStat()
        local cached = state.host_ipc_cloud_stat
        if type(cached) == "table" and next(cached) ~= nil then
            return finalizeCloud(cached)
        end
        return finalizeCloud(defaultCloudSkeleton())
    end

    local function isT31HostQry()
        if state.host_at_ready then
            return true
        end
        local st = modCall("t3x_ctrl", "getState")
        return st ~= nil and st.powered_on == true
    end

    local function shouldQryIpcStat()
        return isT31HostQry()
    end

    local function needsIpcStatRefresh()
        local life = state.host_ipc_status
        if life == "ready" or life == "shutting_down" then
            return false
        end
        return shouldQryIpcStat()
    end

    local function mergeTfCloud()
        local cloud = state.host_ipc_cloud_stat
        if type(cloud) ~= "table" then
            cloud = {}
            state.host_ipc_cloud_stat = cloud
        end
        applyTfToCloud(cloud)
        applyRecordToCloud(cloud)
        return cloud
    end

    local function isHuBusy()
        for i = 1, #HU_BUSY_KEYS do
            if state[HU_BUSY_KEYS[i]] then
                return true
            end
        end
        return hostBusy()
    end

    ----------------------------------------------------------------
    -- IPCSTAT 查询 / 1003 刷新
    ----------------------------------------------------------------

    local function qryIpcCloudStat(timeoutMs)
        local snapCloud = getCloudStat
        return hostQuery(timeoutMs, {
            busyKey = "ipc_cloud_stat_query_busy",
            busyReturn = snapCloud(),
            policyTag = "host_ipc",
            cfg = getCfg("HOST_IPC_CFG"),
            timeoutCfgKey = "status_query_timeout_ms",
            defaultTimeout = TIMEOUT.cloudStatQuery,
            waitBoot = false,
            atCmd = "AT+IPCSTAT?",
            ackEvent = SYS_EVT.IPCSTAT_ACK,
            defaultResult = snapCloud(),
            whenDisabled = function(cfg)
                if cfg.enabled == false then
                    return snapCloud()
                end
            end,
            onNoT3x = snapCloud,
            onNoUart = snapCloud,
            onResponse = function(got, snap)
                if got and type(snap) == "table" then
                    commitIpcStat(snap)
                    return snap
                end
                return snapCloud()
            end,
            onError = snapCloud,
        })
    end

    local function refCloudF1003(timeoutMs, force)
        timeoutMs = tonumber(timeoutMs) or TIMEOUT.cloudStatQuery
        force = force == true
        mergeTfCloud()
        if not coroutine.running() then
            return cloudCacheReady()
        end
        if not shouldQryIpcStat() or isHuBusy() then
            return cloudCacheReady()
        end
        if not force and not isIpcCloudStatStale() then
            return true
        end
        if needsIpcStatRefresh() and qryHostStat then
            qryHostStat(math.min(timeoutMs, TIMEOUT.statusRefreshCap))
        end
        qryIpcCloudStat(timeoutMs)
        mergeTfCloud()
        return cloudCacheReady()
    end

    ----------------------------------------------------------------
    -- PIR 录像对账
    ----------------------------------------------------------------

    local function recHostSess(timeoutMs)
        if not modCall("pir_ctrl", "isRecording") then
            return false
        end
        if not coroutine.running() or not state.host_at_ready then
            return false
        end
        if isHuBusy() or not isT31HostQry() then
            return false
        end
        local snap = qryHostRecord(timeoutMs or TIMEOUT.recordReconcile)
        if type(snap) ~= "table" or recActiveFlag(snap) == 1 then
            return false
        end
        local reason = snap.reason or state.t3x_last_reason or "sync_idle"
        if reason == "idle" or reason == "no_record" then
            reason = "sync_idle"
        end
        state.t3x_rec_active = 0
        state.t3x_last_reason = reason
        local uploadMode, quality = modCall("pir_ctrl", "syncStopT3x", reason)
        if not uploadMode then
            uploadMode, quality = "auto", "high"
        end
        sys.publish(E.T3X_RECORD_STOP, reason, uploadMode, quality)
        return true
    end

    local function cachedTfCard()
        return state.host_tf_card
    end

    return {
        cachedGb28181Id = cachedGb28181Id,
        qryGb28181 = qryGb28181,
        isIpcCloudStatStale = isIpcCloudStatStale,
        getCloudStat = getCloudStat,
        isT31HostQry = isT31HostQry,
        shouldQryIpcStat = shouldQryIpcStat,
        needsIpcStatRefresh = needsIpcStatRefresh,
        mergeTfCloud = mergeTfCloud,
        refCloudF1003 = refCloudF1003,
        isHuBusy = isHuBusy,
        recHostSess = recHostSess,
        qryIpcCloudStat = qryIpcCloudStat,
        cachedTfCard = cachedTfCard,
    }
end

return _M
