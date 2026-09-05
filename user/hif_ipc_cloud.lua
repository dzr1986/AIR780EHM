-- ================================================================
-- Filename : hif_ipc_cloud.lua
-- Module   : IPC 云状态 / GB28181 / qryIpcCloudStat，由 hif_ipc.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- 云态缓存 / IPCSTAT 刷新 / 录像对账 reconcileRecord
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, H)
    local state, SYS_EVT, E = C.state, C.SYS_EVT, C.E
    local modCall = C.modCall
    local bizCall = C.bizCall
    local hostBusy = C.hostBusy
    local wledGet = C.wledGet
    local normIpcCloud = C.normIpcCloud
    local commitIpcStat = C.commitIpcStat
    local getCfg, hostQuery = H.getCfg, H.hostQuery
    local defineQuery = H.defineQuery
    local idCfgFn = H.idCfgFn
    local qryHostStat, qryHostRecord = H.qryHostStat, H.qryHostRecord
    local utils = C.utils
    local setRecActive = C.setRecActive
    local ipcReadyFrom = C.ipcReadyFrom -- hif_cmd.bind 已挂，单源 IPC 就绪判定

    local TMO_SHARED = C.TMO_SHARED
    local TIMEOUT = {
        gb28181Query = 3000,
        cloudStatQuery = TMO_SHARED.cloudStatQueryMs,
        statusRefreshCap = 1500,
        recordReconcile = 3500,
        cacheMaxAgeDefault = 90,
    }

    -- per-query 重入键 + 事务锁；破坏性会话统一看 state.uart_session（P3）
    local HU_BUSY_KEYS = {
        "uart_txn_busy", "encode_query_busy", "encode_set_busy",
        "record_query_busy", "recordtime_query_busy", "tf_card_query_busy",
        "ipc_status_query_busy", "ipc_cloud_stat_query_busy",
    }

    -- 云状态 9 键 + 上报序唯一真源（1003 IPCSTAT 载荷契约，勿随意增删/换序）：
    --   · 本文件 defaultCloudSkeleton 依此造骨架（0 兜底 + 计算键覆盖）；
    --   · ipc_supv 经 hostUart.cloudStatKeys() 取同一清单拼 1003 JSON。
    local CLOUD_STAT_KEYS = {
        "ipcReady", "gb28181Online", "tfPresent", "personDetectEnabled",
        "personDetectAvailable", "timeSynced", "recordingt31x", "wledEnable", "cat1Link",
    }

    ----------------------------------------------------------------
    -- GB28181
    ----------------------------------------------------------------

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

    local function liftFlag(snap, key, cond)
        if cond and (tonumber(snap[key]) or 0) == 0 then
            snap[key] = 1
        end
    end

    local function applyTfToCloud(cloud)
        local tf = state.host_tf_card
        if type(tf) ~= "table" or not tf.parsed then
            return cloud
        end
        cloud.tfPresent = utils.to01(tf.present)
        return cloud
    end

    local function applyRecordToCloud(cloud)
        local recActive = recActiveFlag(state.host_record)
        if recActive == nil then
            return cloud
        end
        setRecActive(recActive)
        return cloud
    end

    local function applyLiveOverlay(snap)
        if type(snap) ~= "table" then
            return snap
        end
        liftFlag(snap, "cat1Link", state.host_at_ready)
        local pst = modCall("t31x_ctrl", "getState")
        liftFlag(snap, "cat1Link", pst and pst.powered_on)
        liftFlag(snap, "ipcReady", state.host_ipc_status == "ready")
        if tonumber(state.t31x_rec_active) == 1 then
            snap.recordingt31x = 1
        end
        snap.wledEnable = wledGet()
        return snap
    end

    local function finalizeCloud(cloud)
        return applyLiveOverlay(applyTfToCloud(normIpcCloud(cloud)))
    end

    local function defaultCloudSkeleton()
        local life = state.host_ipc_status or "idle"
        local ipcReady = ipcReadyFrom(life)
        local cat1Link = (ipcReady == 1 or state.host_at_ready) and 1 or 0
        local sk = {}
        for i = 1, #CLOUD_STAT_KEYS do
            sk[CLOUD_STAT_KEYS[i]] = 0
        end
        sk.ipcReady = ipcReady
        sk.recordingt31x = (tonumber(state.t31x_rec_active) == 1) and 1 or 0
        sk.wledEnable = wledGet()
        sk.cat1Link = cat1Link
        return sk
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

    local function canQueryT31()
        if state.host_at_ready then
            return true
        end
        local st = modCall("t31x_ctrl", "getState")
        return st ~= nil and st.powered_on == true
    end

    local function needsIpcStatRefresh()
        local life = state.host_ipc_status
        if life == "ready" or life == "shutting_down" then
            return false
        end
        return canQueryT31()
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

    local function isCloudBusy()
        if state.uart_session then
            return true
        end
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
        local cached = snapCloud()
        return hostQuery(timeoutMs, {
            busyKey = "ipc_cloud_stat_query_busy",
            busyReturn = cached,
            policyTag = "host_ipc",
            cfg = getCfg("HOST_IPC_CFG"),
            waitBoot = false,
            atCmd = "AT+IPCSTAT?",
            ackEvent = SYS_EVT.IPCSTAT_ACK,
            defaultResult = cached,
            whenDisabled = function(cfg)
                if cfg.enabled == false then
                    return snapCloud()
                end
            end,
            onNotT31x = snapCloud,
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

    local function refCloudStat1003(timeoutMs, force)
        timeoutMs = tonumber(timeoutMs) or TIMEOUT.cloudStatQuery
        force = force == true
        mergeTfCloud()
        if not coroutine.running() then
            return cloudCacheReady()
        end
        if not canQueryT31() or isCloudBusy() then
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

    local function reconcileRecord(timeoutMs)
        if not bizCall("pirIsRecording") then
            return false
        end
        if not coroutine.running() or not state.host_at_ready then
            return false
        end
        if isCloudBusy() or not canQueryT31() then
            return false
        end
        local snap = qryHostRecord(timeoutMs or TIMEOUT.recordReconcile)
        if type(snap) ~= "table" or recActiveFlag(snap) == 1 then
            return false
        end
        local reason = snap.reason or state.t31x_last_reason or "sync_idle"
        if reason == "idle" or reason == "no_record" then
            reason = "sync_idle"
        end
        setRecActive(0)
        state.t31x_last_reason = reason
        local uploadMode, quality = bizCall("pirSyncStopT31x", reason)
        if not uploadMode then
            uploadMode, quality = "auto", "high"
        end
        sys.publish(E.T31X_RECORD_STOP, reason, uploadMode, quality)
        return true
    end

    return {
        qryGb28181 = qryGb28181,
        -- mqtt_dl_dev 查询超时后的缓存回退（P9 前该成员不存在 → nil 调用）
        getCachedHostGb28181Id = function() return state.host_gb28181_id end,
        isIpcCloudStatStale = isIpcCloudStatStale,
        getCloudStat = getCloudStat,
        canQueryT31 = canQueryT31,
        needsIpcStatRefresh = needsIpcStatRefresh,
        mergeTfCloud = mergeTfCloud,
        refCloudStat1003 = refCloudStat1003,
        isCloudBusy = isCloudBusy,
        reconcileRecord = reconcileRecord,
        qryIpcCloudStat = qryIpcCloudStat,
        -- 供 ipc_supv 取云状态键序拼 1003（单源，勿另立清单）
        cloudStatKeys = function()
            return CLOUD_STAT_KEYS
        end,
    }
end

return _M
