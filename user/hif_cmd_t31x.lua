-- ================================================================
-- Filename : hif/cmd/hif_cmd_t31x.lua
-- Module   : t31x 上行 NOTIFY（RECORD/UPLOAD/IPCSTAT 等），由 hif_cmd.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local state, SYS_EVT, E = C.state, C.SYS_EVT, C.E
    local rspBody, rspFmt, rspLineOk = C.rspBody, C.rspFmt, C.rspLineOk
    local modCall = C.modCall
    local RSP_ERROR = C.RSP_ERROR
    local function parseIpcStat(...)
        return C.parseIpcStat(...)
    end
    local function parseTfCard(...)
        return C.parseTfCard(...)
    end
    local function commitIpcStat(...)
        return C.commitIpcStat(...)
    end
    local function patchCloud(...)
        return C.patchCloud(...)
    end
    local function setRecActive(...)
        return C.setRecActive(...)
    end
    local noteHostPush = C.noteHostPush

    local function ipcReadyFrom(st)
        return (st == "ready") and 1 or 0
    end

    -- AT+XXX= 体；空或未匹配一律 ERROR
    local function needArg(cmd, pat)
        local arg = cmd:match(pat)
        if not arg or arg == "" then
            return nil
        end
        return arg
    end

    local function ntfArg(cmd, pat)
        noteHostPush()
        return needArg(cmd, pat)
    end

    local function kvFromArg(arg, key)
        local v = arg:match(key .. "=([^,]+)")
        return v and v:gsub("^%s+", ""):gsub("%s+$", "") or ""
    end

    ----------------------------------------------------------------
    -- RECORD / PERSON / PIR / ALERT
    ----------------------------------------------------------------

    local function uartRecord(cmd)
        local arg = needArg(cmd, "^AT%+RECORD=(.+)$")
        if not arg then
            return RSP_ERROR
        end
        if arg == "1" or arg:match("^1,") then
            local reason = arg:match("reason=([^,]+)") or "active"
            state.t31x_last_reason = reason
            setRecActive(1)
            if reason ~= "allday_person" then
                sys.publish(E.T31X_RECORD_ACTIVE)
            end
            return rspBody("RECORD", "1,active=1")
        end
        local reason = arg:match("^0,reason=(.+)$") or "unknown"
        if reason == "allday_person_done" then
            -- 全天写盘未停，忽略 overlay 结束
            state.t31x_last_reason = reason
            return rspFmt("RECORD", "0,reason=%s,ignored=1", reason)
        end
        state.t31x_last_reason = reason
        setRecActive(0)
        local uploadMode, quality = modCall("pir_ctrl", "syncStopT31x", reason)
        sys.publish(E.T31X_RECORD_STOP, reason, uploadMode, quality)
        return rspFmt("RECORD", "0,reason=%s", reason)
    end

    local function uartPersonCnt(cmd)
        local cnt = needArg(cmd, "^AT%+PERSONCNT=(%d+)$")
        if not cnt then
            return RSP_ERROR
        end
        local n = tonumber(cnt) or 0
        sys.publish(E.T31X_PERSON_CNT, n)
        return rspFmt("PERSONCNT", "ok,count=%d", n)
    end

    local function uartPirMedia(cmd)
        local action = needArg(cmd, "^AT%+PIRMEDIA=(.+)$")
        if not action then
            return RSP_ERROR
        end
        modCall("pir_ctrl", "applyEffMedia", action)
        return rspFmt("PIRMEDIA", "ok,action=%s", action)
    end

    local function uartIpcAlert(cmd)
        local code, detail = cmd:match("^AT%+IPCALERT=([^,]+),?(.*)$")
        if not code or code == "" then
            return RSP_ERROR
        end
        sys.publish(E.T31X_IPC_ALERT, code, detail or "")
        return rspFmt("IPCALERT", "OK,code=%s", code)
    end

    ----------------------------------------------------------------
    -- UPLOAD / IPC notify
    ----------------------------------------------------------------

    local function uartUploadNeed(cmd)
        local arg = needArg(cmd, "^AT%+UPLOADNEED=(.+)$")
        if not arg then
            return RSP_ERROR
        end
        local need = tonumber(arg:match("^(%d+)")) or 1
        modCall("net_mqtt", "pubUploadNeed", {
            needUpload = need,
            action = "upload_video",
            reason = arg:match("reason=([^,]+)") or "record_done",
            recordPath = arg:match("path=([^,]+)") or "",
            pirStatus = arg:match("pirStatus=([^,]+)") or "t31x_active",
            source = "t31x",
        })
        return rspFmt("UPLOADNEED", "ok,need=%d", need)
    end

    local function uartUploadResult(cmd)
        local arg = needArg(cmd, "^AT%+UPLOADRESULT=(.+)$")
        if not arg then
            return RSP_ERROR
        end
        local ret = tonumber(kvFromArg(arg, "ret")) or -1
        modCall("net_mqtt", "pubUploadDone", ret, kvFromArg(arg, "msgId"), {
            videoType = tonumber(kvFromArg(arg, "type")) or 1,
            beginTs = tonumber(kvFromArg(arg, "start")) or 0,
            endTs = tonumber(kvFromArg(arg, "end")) or 0,
            uploadTs = kvFromArg(arg, "uploadTs"),
            fileName = kvFromArg(arg, "file"),
            httpPath = kvFromArg(arg, "httpPath"),
            reason = kvFromArg(arg, "reason"),
            message = kvFromArg(arg, "msg"),
            source = "t31x",
        })
        return rspFmt("UPLOADRESULT", "ok,ret=%d", ret)
    end

    local function uartIpcStatusNtf(cmd)
        local st = ntfArg(cmd, "^AT%+IPCSTATUS=(.+)$")
        if not st then
            return RSP_ERROR
        end
        state.host_ipc_status = st
        patchCloud({ ipcReady = ipcReadyFrom(st) })
        sys.publish(SYS_EVT.IPCSTATUS_ACK, st)
        return rspFmt("IPCSTATUS", "OK,status=%s", st)
    end

    local function uartIpcStatNtf(cmd)
        local body = ntfArg(cmd, "^AT%+IPCSTAT=(.+)$")
        if not body then
            return RSP_ERROR
        end
        local snap = parseIpcStat("+IPCSTAT:" .. body)
        if not snap then
            return RSP_ERROR
        end
        commitIpcStat(snap, true) -- 完整快照，允许唤醒等待中的 AT+IPCSTAT? 查询
        return rspLineOk("IPCSTAT")
    end

    local function uartTfCardNtf(cmd)
        local body = ntfArg(cmd, "^AT%+TFCARD=(.+)$")
        if not body then
            return RSP_ERROR
        end
        local snap = parseTfCard("+TFCARD:" .. body)
        if not snap.parsed then
            return RSP_ERROR
        end
        state.host_tf_card = snap
        patchCloud({ tfPresent = (tonumber(snap.present) or 0) == 1 and 1 or 0 })
        sys.publish(SYS_EVT.TFCARD_ACK, snap)
        return rspLineOk("TFCARD")
    end

    local function uartSnapshot(cmd)
        local path = needArg(cmd, "^AT%+SNAPSHOT=(.+)$")
        if not path then
            return RSP_ERROR
        end
        sys.publish(E.T31X_SNAPSHOT_DONE, path)
        return rspFmt("SNAPSHOT", "ok,path=%s", path)
    end

    return {
        ipcReadyFrom = ipcReadyFrom,
        uartRecord = uartRecord,
        uartPersonCnt = uartPersonCnt,
        uartPirMedia = uartPirMedia,
        uartIpcAlert = uartIpcAlert,
        uartUploadNeed = uartUploadNeed,
        uartUploadResult = uartUploadResult,
        uartIpcStatusNtf = uartIpcStatusNtf,
        uartIpcStatNtf = uartIpcStatNtf,
        uartTfCardNtf = uartTfCardNtf,
        uartSnapshot = uartSnapshot,
    }
end

return _M
