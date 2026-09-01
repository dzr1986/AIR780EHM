-- ================================================================
-- Filename : hu_rx.lua
-- Module   : T3x UART URC/RX 行解析编排，由 host_uart 在 cmd.bind 后 bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- 云态 / TF·录制 / IPC / media 子模块 → tryHandlers 链
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local state = C.state
    local SYS_EVT = C.SYS_EVT
    local modCall = C.modCall
    local utils = C.utils

    local dsl = require("hu_rx_dsl").bind(C)
    local normLine = dsl.normLine

    ----------------------------------------------------------------
    -- 通用 helper
    ----------------------------------------------------------------

    local function asNum(v)
        return tonumber(v) or 0
    end

    local function binOnOff(v)
        return (asNum(v) ~= 0) and 1 or 0
    end

    local function noteLinkOk()
        if C.noteUartLinkOk then
            C.noteUartLinkOk()
        end
    end

    local function trimStr(s)
        if not s then
            return s
        end
        return s:gsub("^%s+", ""):gsub("%s+$", "")
    end

    ----------------------------------------------------------------
    -- IPC 云态
    ----------------------------------------------------------------

    local function normIpcCloud(snap)
        if type(snap) ~= "table" then
            return snap
        end
        if snap.cat1Link == nil and snap.hostLink ~= nil then
            snap.cat1Link = snap.hostLink
        end
        return snap
    end

    local function commitIpcStat(snap)
        if type(snap) ~= "table" or next(snap) == nil then
            return nil
        end
        snap = normIpcCloud(snap)
        state.host_ipc_cloud_stat = snap
        state.ipc_cloud_stat_ts = os.time()
        if snap.recordingT3x ~= nil then
            state.t3x_rec_active = asNum(snap.recordingT3x)
        end
        if snap.ipcReady == 1 and not state.host_ipc_status then
            state.host_ipc_status = "ready"
        end
        sys.publish(SYS_EVT.IPCSTAT_ACK, snap)
        return snap
    end

    local function patchCloud(fields)
        local cloud = state.host_ipc_cloud_stat
        if type(cloud) ~= "table" then
            cloud = {}
        end
        fields = utils.optTable(fields)
        for k, v in pairs(fields) do
            cloud[k] = v
        end
        return commitIpcStat(cloud)
    end

    local function parseIpcStat(line)
        local snap = {}
        if not line or not line:match("^%+IPCSTAT:") then
            return nil
        end
        for k, v in string.gmatch(line, "(%w+)=(%d+)") do
            snap[k] = asNum(v)
        end
        if next(snap) == nil then
            return nil
        end
        return normIpcCloud(snap)
    end

    ----------------------------------------------------------------
    -- MISC URC（sound / time / identity / wled）
    ----------------------------------------------------------------

    local function trySoundAck(line)
        if not line then
            return false
        end
        local name = line:match("^%+SOUNDACK:(%w+)$")
        if not name then
            return false
        end
        modCall("sound_prompt", "onSoundAck", name)
        return true
    end

    local function tryTimesetAck(line)
        if not line then
            return false
        end
        if line:match("^%+TIMESET:OK$") then
            modCall("time_sync", "onTimesetAck")
            return true
        end
        return false
    end

    local function tryGb28181(line)
        if not line then
            return false
        end
        local id = line:match("^%+GB28181:(.*)$")
        if id == nil then
            return false
        end
        id = trimStr(id)
        state.host_gb28181_id = id
        sys.publish(SYS_EVT.GB28181_ACK, id)
        return true
    end

    local function tryWledLine(line)
        if not line then
            return false
        end
        if line:match("^%+WLED:ERROR") then
            sys.publish(SYS_EVT.WLED_ACK, { ok = false })
            return true
        end
        local n = line:match("^%+WLED:(%d+)$")
        if n == nil then
            return false
        end
        n = binOnOff(n)
        C.wledState.on = n
        C.wledExport(n)
        patchCloud({ wledEnable = n })
        sys.publish(SYS_EVT.WLED_ACK, { ok = true, on = n })
        return true
    end

    ----------------------------------------------------------------
    -- TF CARD / TFFORMAT
    ----------------------------------------------------------------

    local function tryTfFormat(line)
        if not line then
            return false
        end
        if line:match("^%+TFFORMAT:ERROR") then
            local ret = line:match("ret=([^,%s]+)") or "error"
            sys.publish(SYS_EVT.TFFORMAT_ACK, { phase = "error", ret = ret })
            return true
        end
        if line:match("^%+TFFORMAT:STARTED") then
            sys.publish(SYS_EVT.TFFORMAT_ACK, { phase = "started" })
            return true
        end
        if line:match("^%+TFFORMAT:OK") then
            local reboot = line:match("reboot=(%d+)") or "0"
            sys.publish(SYS_EVT.TFFORMAT_ACK, { phase = "ok", reboot = asNum(reboot) })
            return true
        end
        return false
    end

    local function parseTfCard(line)
        local snap = {
            present = 0,
            totalMb = 0,
            usedMb = 0,
            freeMb = 0,
            parsed = false,
        }
        if not line then
            return snap
        end
        line = normLine(line):gsub("OK%s*$", "")
        local p, t, u, f = line:match("^%+TFCARD:present=(%d+),total_mb=(%d+),used_mb=(%d+),free_mb=(%d+)$")
        if not p then
            p, t, u, f = line:match("^%+TFCARD:(%d+),(%d+),(%d+),(%d+)$")
        end
        if p then
            snap.present = asNum(p)
            snap.totalMb = asNum(t)
            snap.usedMb = asNum(u)
            snap.freeMb = asNum(f)
            snap.parsed = true
        end
        return snap
    end

    local function tryTfCard(line)
        if not line or not line:match("^%+TFCARD:") then
            return false
        end
        local snap = parseTfCard(line)
        if not snap.parsed then
            return false
        end
        state.host_tf_card = snap
        patchCloud({ tfPresent = binOnOff(snap.present) })
        sys.publish(SYS_EVT.TFCARD_ACK, snap)
        return true
    end

    ----------------------------------------------------------------
    -- RECORD / RECORDTIME
    ----------------------------------------------------------------

    local function parseRecordLine(line)
        local snap = {
            running = 0,
            active = 0,
            ch = -1,
            reason = "idle",
            recording = 0,
        }
        if not line then
            return snap
        end
        local r, a, c, rs = line:match("^%+RECORD:running=(%d),active=(%d),ch=(%-?%d+),reason=(.+)$")
        if r then
            snap.running = asNum(r)
            snap.active = asNum(a)
            snap.ch = asNum(c)
            snap.reason = rs or "idle"
            snap.recording = snap.running
            return snap
        end
        local rec, reason, active = line:match("^%+RECORD:(%d+),reason=([^,]+),active=(%d+)$")
        if rec then
            snap.recording = asNum(rec)
            snap.running = snap.recording
            snap.reason = reason or "idle"
            snap.active = asNum(active)
            return snap
        end
        return snap
    end

    local function applyRecordState(snap)
        if snap.active == 1 or snap.running == 1 then
            state.t3x_rec_active = 1
        elseif snap.running == 0 and snap.active == 0 then
            state.t3x_rec_active = 0
        end
        if snap.reason and snap.reason ~= "" then
            state.t3x_last_reason = snap.reason
        end
    end

    local function parseRecTime(line)
        line = normLine(line)
        if not line or not line:match("^%+RECORDTIME:") then
            return nil
        end
        local min = line:match("^%+RECORDTIME:(%d+),min=")
        if min then
            return {
                parsed = true,
                ok = true,
                minutes = asNum(min),
                query = true,
            }
        end
        local okMin = line:match("^%+RECORDTIME:OK,(%d+)$")
        if okMin then
            return {
                parsed = true,
                ok = true,
                minutes = asNum(okMin),
                set = true,
            }
        end
        if line:match("^%+RECORDTIME:INVALID") then
            return { parsed = true, ok = false, invalid = true, set = true }
        end
        if line:match("^%+RECORDTIME:ERROR") then
            return { parsed = true, ok = false, error = true, set = true }
        end
        return nil
    end

    local function tryRecTime(line)
        local snap = parseRecTime(line)
        if not snap then
            return false
        end
        if snap.query then
            state.host_record_time = snap
            sys.publish(SYS_EVT.RECORDTIME_ACK, snap)
        elseif snap.set then
            sys.publish(SYS_EVT.RECORDTIME_SET, snap)
        end
        return true
    end

    local function tryRecord(line)
        if not line or not line:match("^%+RECORD:") then
            return false
        end
        local snap = parseRecordLine(line)
        state.host_record = snap
        applyRecordState(snap)
        sys.publish(SYS_EVT.RECORD_ACK, snap)
        return true
    end

    ----------------------------------------------------------------
    -- IPC STATUS / POWEROFF
    ----------------------------------------------------------------

    local function tryIpcStatCloud(line)
        local snap = parseIpcStat(line)
        if not snap then
            return false
        end
        commitIpcStat(snap)
        return true
    end

    local function tryIpcStatus(line)
        if not line then
            return false
        end
        local st = line:match("^%+IPCSTATUS:(%w+)$")
        if not st then
            return false
        end
        state.host_ipc_status = st
        patchCloud({ ipcReady = C.ipcReadyFrom(st) })
        noteLinkOk()
        sys.publish(SYS_EVT.IPCSTATUS_ACK, st)
        return true
    end

    local function logPowerOffRx(line)
        if log and log.info then
            log.info("host_uart", "ipcpoweroff_rx", "ERR", line)
        end
    end

    local function tryIpcPowerOff(line)
        if not line then
            return false
        end
        if line == "+IPCPOWEROFF:OK" then
            sys.publish(SYS_EVT.IPCPOWEROFF_ACK, { ok = true })
            return true
        end
        local stage = line:match("^%+IPCPOWEROFF:STAGE,([%w_]+)$")
        if stage then
            sys.publish(SYS_EVT.IPCPOWEROFF_ACK, { ok = false, stage = stage })
            return true
        end
        if line:match("^%+IPCPOWEROFF:BUSY") or line:match("^%+IPCPOWEROFF:ERROR")
            or line:match("^%+IPCPOWEROFF:NOT_SUPPORTED") then
            logPowerOffRx(line)
            sys.publish(SYS_EVT.IPCPOWEROFF_ACK, { ok = false, error = true, line = line })
            return true
        end
        return false
    end

    local media = require("hu_rx_media").bind(C, dsl)

    ----------------------------------------------------------------
    -- handler registry
    ----------------------------------------------------------------

    local RX_LINE_HANDLER_REGISTRY = {
        -- encode
        { name = "encode_uart_error", fn = media.tryEncodeUartErr },
        { name = "encode_ok_tail", fn = media.tryEncodeUartOk },
        -- misc
        { name = "sound_ack", fn = trySoundAck },
        { name = "timeset_ack", fn = tryTimesetAck },
        { name = "gb28181", fn = tryGb28181 },
        { name = "wled", fn = tryWledLine },
        -- storage
        { name = "tfformat", fn = tryTfFormat },
        { name = "tfcard", fn = tryTfCard },
        -- record
        { name = "recordtime", fn = tryRecTime },
        { name = "record", fn = tryRecord },
        { name = "recordctrl", fn = media.tryRecordCtrlLine },
        { name = "uploadvideo", fn = media.tryUploadLine },
        -- encode query/set（media）
        { name = "framerate", fn = media.tryFramerateLine },
        { name = "venc", fn = media.tryVencLine },
        { name = "vencset", fn = media.tryVencSetLine },
        { name = "audio", fn = media.tryAudioLine },
        { name = "audioset", fn = media.tryAudioSetLine },
        { name = "mic", fn = media.tryMicLine },
        { name = "micset", fn = media.tryMicSetLine },
        { name = "softphoto", fn = media.trySoftPhotoLine },
        { name = "softphotoset", fn = media.trySoftPhotoSetLine },
        { name = "persondet", fn = media.tryPersonDetLine },
        -- IPC
        { name = "ipcstat", fn = tryIpcStatCloud },
        { name = "ipcstatus", fn = tryIpcStatus },
        { name = "ipcpoweroff", fn = tryIpcPowerOff },
    }

    local tryHandlers = {}
    for i = 1, #RX_LINE_HANDLER_REGISTRY do
        tryHandlers[i] = RX_LINE_HANDLER_REGISTRY[i].fn
    end
    return {
        normLine = normLine,
        parseTfCard = parseTfCard,
        parseIpcStat = parseIpcStat,
        normIpcCloud = normIpcCloud,
        commitIpcStat = commitIpcStat,
        patchCloud = patchCloud,
        tryHandlers = tryHandlers,
    }
end

return _M
