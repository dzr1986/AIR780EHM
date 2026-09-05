-- ================================================================
-- Filename : hif_rx_dsl.lua
-- Module   : URC 匹配 DSL + 云态/TF/录制/IPC 行解析，由 hif_rx.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local state, SYS_EVT = C.state, C.SYS_EVT
    local modCall = C.modCall
    local bizCall = C.bizCall
    local utils = C.utils

    local function noteLinkOk()
        if C.noteUartLinkOk then
            C.noteUartLinkOk()
        end
    end

    ----------------------------------------------------------------
    -- line / field copy
    ----------------------------------------------------------------

    local function normLine(line)
        if not line then
            return line
        end
        return (line:match("^%s*(.-)%s*$") or line)
    end

    local function copyFields(dst, src)
        if src then
            for k, v in pairs(src) do
                dst[k] = v
            end
        end
        return dst
    end

    local function publishAck(ev, payload)
        sys.publish(ev, payload)
        return true
    end

    local function asNum(v)
        return tonumber(v) or 0
    end

    ----------------------------------------------------------------
    -- capture → row
    ----------------------------------------------------------------

    local function assignCaptureField(row, name, cap)
        local mark = name:sub(1, 1)
        if mark == "!" then
            row[name:sub(2)] = (tonumber(cap) or 0) == 1
        elseif mark == "$" then
            row[name:sub(2)] = cap
        else
            row[name] = tonumber(cap) or 0
        end
    end

    local function fillFromCaptures(row, names, caps)
        for i = 1, #names do
            assignCaptureField(row, names[i], caps[i])
        end
    end

    ----------------------------------------------------------------
    -- pattern matchers
    ----------------------------------------------------------------

    local function matchFlag(pat, ev, tpl)
        return function(line)
            if not line:match(pat) then
                return false
            end
            return publishAck(ev, copyFields({}, tpl))
        end
    end

    local function matchPub(pat, ev, names, tpl)
        return function(line)
            local caps = { line:match(pat) }
            if caps[1] == nil then
                return false
            end
            local row = copyFields({}, tpl)
            fillFromCaptures(row, names, caps)
            return publishAck(ev, row)
        end
    end

    ----------------------------------------------------------------
    -- row collection
    ----------------------------------------------------------------

    local function rowsAppend(stateKey, row)
        if not row then
            return false
        end
        state[stateKey] = state[stateKey] or {}
        state[stateKey][#state[stateKey] + 1] = row
        return true
    end

    local function rowsFlush(endMarker, stateKey, ackEvent)
        return function(line)
            if line ~= endMarker then
                return false
            end
            local rows = state[stateKey]
            if type(rows) ~= "table" or #rows == 0 then
                return false
            end
            state[stateKey] = nil
            return publishAck(ackEvent, rows)
        end
    end

    local function rowsCollect(pat, stateKey, fieldNames)
        return function(line)
            local caps = { line:match(pat) }
            if caps[1] == nil then
                return false
            end
            local row = {}
            for i = 1, #fieldNames do
                row[fieldNames[i]] = tonumber(caps[i]) or 0
            end
            return rowsAppend(stateKey, row)
        end
    end

    local function drainRows(stateKey, ackEvent, payload)
        local rows = state[stateKey]
        if type(rows) == "table" and #rows > 0 then
            state[stateKey] = nil
            sys.publish(ackEvent, payload or rows)
            return true
        end
        return false
    end

    ----------------------------------------------------------------
    -- composition
    ----------------------------------------------------------------

    local function lineMatch(...)
        local handlers = { ... }
        return function(line)
            if not line then
                return false
            end
            for i = 1, #handlers do
                if handlers[i](line) then
                    return true
                end
            end
            return false
        end
    end

    local function normMatchers(...)
        local matcher = lineMatch(...)
        return function(line)
            return matcher(normLine(line))
        end
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

    -- notify=true 仅用于 T31x 完整快照（+IPCSTAT: 应答 / AT+IPCSTAT= 主动上报）；
    -- patchCloud 局部补丁（WLED/RECORD/TFCARD/IPCSTATUS/poweroff…）不得发 IPCSTAT_ACK，
    -- 否则会抢答正在 waitUntil(IPCSTAT_ACK) 的 qryIpcCloudStat，使 AT+IPCSTAT? 误判成功早退
    -- keepTs=true：局部补丁不把缓存标为「新鲜」，isIpcCloudStatStale 仍按上次完整 +IPCSTAT: 快照计时
    local function commitIpcStat(snap, notify, keepTs)
        if type(snap) ~= "table" or next(snap) == nil then
            return nil
        end
        snap = normIpcCloud(snap)
        C.setHostCloudStat(snap)
        if keepTs ~= true then
            state.ipc_cloud_stat_ts = os.time()
        end
        if snap.recordingt31x ~= nil then
            state.t31x_rec_active = asNum(snap.recordingt31x)
        end
        if snap.ipcReady == 1 and not state.host_ipc_status then
            C.setHostIpcStatus("ready")
        end
        if notify == true then
            sys.publish(SYS_EVT.IPCSTAT_ACK, snap)
        end
        return snap
    end

    local function patchCloud(fields, keepTs)
        local cloud = state.host_ipc_cloud_stat
        if type(cloud) ~= "table" then
            cloud = {}
        end
        fields = utils.optTable(fields)
        for k, v in pairs(fields) do
            cloud[k] = v
        end
        return commitIpcStat(cloud, nil, keepTs)
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
        local name = line and line:match("^%+SOUNDACK:(%w+)$")
        if not name then
            return false
        end
        bizCall("onSoundAck", name)
        return true
    end

    local function tryTimesetAck(line)
        if not line or not line:match("^%+TIMESET:OK$") then
            return false
        end
        bizCall("onTimesetAck")
        return true
    end

    local function tryGb28181(line)
        local id = line and line:match("^%+GB28181:(.*)$")
        if id == nil then
            return false
        end
        id = normLine(id)
        state.host_gb28181_id = id
        sys.publish(SYS_EVT.GB28181_ACK, id)
        return true
    end

    local function tryWledLine(line)
        if not line then
            return false
        end
        if line:match("^%+WLED:ERROR") then
            return publishAck(SYS_EVT.WLED_ACK, { ok = false })
        end
        local n = line:match("^%+WLED:(%d+)$")
        if n == nil then
            return false
        end
        n = utils.to01(n)
        C.wledState.on = n
        C.wledExport(n)
        patchCloud({ wledEnable = n })
        return publishAck(SYS_EVT.WLED_ACK, { ok = true, on = n })
    end

    ----------------------------------------------------------------
    -- TF CARD / TFFORMAT
    ----------------------------------------------------------------

    local function tryTfFormat(line)
        if not line then
            return false
        end
        if line:match("^%+TFFORMAT:ERROR") then
            return publishAck(SYS_EVT.TFFORMAT_ACK, {
                phase = "error", ret = line:match("ret=([^,%s]+)") or "error" })
        end
        if line:match("^%+TFFORMAT:STARTED") then
            return publishAck(SYS_EVT.TFFORMAT_ACK, { phase = "started" })
        end
        if line:match("^%+TFFORMAT:OK") then
            return publishAck(SYS_EVT.TFFORMAT_ACK, {
                phase = "ok", reboot = asNum(line:match("reboot=(%d+)") or "0") })
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
        C.setHostTfCard(snap)
        patchCloud({ tfPresent = utils.to01(snap.present) })
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
        -- 与 parseTfCard 同口径：去首尾空白并剥掉粘连的行尾 OK，避免 `\r`/`OK` 让两种格式都不中
        line = normLine(line):gsub("%s*OK%s*$", "")
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
        -- 两种已知格式都不匹配（畸形/空字段/未知变体）：返回 nil，由调用方忽略。
        -- 若此处回落默认 running=0/active=0，会把「解析失败」当成「已停录」清掉 t31x_rec_active
        return nil
    end

    local function applyRecordState(snap)
        if snap.active == 1 or snap.running == 1 then
            C.setRecActive(1)
        elseif snap.running == 0 and snap.active == 0 then
            C.setRecActive(0)
        end
        if snap.reason and snap.reason ~= "" then
            state.t31x_last_reason = snap.reason
        end
    end

    local function recTimeRow(ok, kind, extra)
        extra = extra or {}
        extra.parsed = true
        extra.ok = ok
        extra[kind] = true
        return extra
    end

    local function parseRecTime(line)
        line = normLine(line)
        if not line or not line:match("^%+RECORDTIME:") then
            return nil
        end
        local min = line:match("^%+RECORDTIME:(%d+),min=")
            or line:match("^%+RECORDTIME:(%d+)$")
        if min then
            return recTimeRow(true, "query", { minutes = asNum(min) })
        end
        local okMin = line:match("^%+RECORDTIME:OK,(%d+)$")
        if okMin then
            return recTimeRow(true, "set", { minutes = asNum(okMin) })
        end
        if line:match("^%+RECORDTIME:INVALID") then
            return recTimeRow(false, "set", { invalid = true })
        end
        if line:match("^%+RECORDTIME:ERROR") then
            return recTimeRow(false, "set", { error = true })
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

    local recordParseWarned = false
    local function tryRecord(line)
        if not line or not line:match("^%+RECORD:") then
            return false
        end
        local snap = parseRecordLine(line)
        if not snap then
            -- 已确认是 +RECORD: 行但格式未知：不改录像态；发 false 作 nack，让 AT+RECORD? 的
            -- 等待方立刻走缓存（saveSnap 对非 table 返回 nil → defaultResult），而不是烧满 TMO.rec 并持锁
            if not recordParseWarned then
                recordParseWarned = true
                log.warn("host_uart", "record_line_unparsed", line:sub(1, 64))
            end
            sys.publish(SYS_EVT.RECORD_ACK, false)
            return true
        end
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
        commitIpcStat(snap, true)
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
        C.setHostIpcStatus(st, true) -- 含 cloud.ipcReady 同步
        noteLinkOk()
        sys.publish(SYS_EVT.IPCSTATUS_ACK, st)
        return true
    end

    local function tryIpcPowerOff(line)
        if not line then
            return false
        end
        if line == "+IPCPOWEROFF:OK" then
            return publishAck(SYS_EVT.IPCPOWEROFF_ACK, { ok = true })
        end
        local stage = line:match("^%+IPCPOWEROFF:STAGE,([%w_]+)$")
        if stage then
            return publishAck(SYS_EVT.IPCPOWEROFF_ACK, { ok = false, stage = stage })
        end
        if line:match("^%+IPCPOWEROFF:BUSY") or line:match("^%+IPCPOWEROFF:ERROR")
            or line:match("^%+IPCPOWEROFF:NOT_SUPPORTED") then
            C.logPowerOffRx("ERR", line)
            return publishAck(SYS_EVT.IPCPOWEROFF_ACK, { ok = false, error = true, line = line })
        end
        return false
    end

    return {
        normLine = normLine,
        asNum = asNum,
        pubAck = publishAck,
        matchFlag = matchFlag,
        matchPub = matchPub,
        rowsAppend = rowsAppend,
        rowsFlush = rowsFlush,
        rowsCollect = rowsCollect,
        lineMatch = lineMatch,
        normMatchers = normMatchers,
        drainRows = drainRows,
        parseTfCard = parseTfCard,
        parseIpcStat = parseIpcStat,
        normIpcCloud = normIpcCloud,
        commitIpcStat = commitIpcStat,
        patchCloud = patchCloud,
        trySoundAck = trySoundAck,
        tryTimesetAck = tryTimesetAck,
        tryGb28181 = tryGb28181,
        tryWledLine = tryWledLine,
        tryTfFormat = tryTfFormat,
        tryTfCard = tryTfCard,
        tryRecTime = tryRecTime,
        tryRecord = tryRecord,
        tryIpcStatCloud = tryIpcStatCloud,
        tryIpcStatus = tryIpcStatus,
        tryIpcPowerOff = tryIpcPowerOff,
    }
end

return _M
