-- ================================================================
-- Filename : hu_rx_media.lua
-- Module   : 媒体/编码 URC 行 handler（VENC/AUDIO/MIC/…），由 hu_rx.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- 结构：utils → parsers → uart tail → 各 URC 域 handler → export
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, dsl)
    local state, SYS_EVT = C.state, C.SYS_EVT

    -- DSL（来自 hu_rx_dsl）
    local normLine = dsl.normLine
    local pubAck = dsl.pubAck
    local matchFlag = dsl.matchFlag
    local matchPub = dsl.matchPub
    local rowsAppend = dsl.rowsAppend
    local rowsFlush = dsl.rowsFlush
    local rowsCollect = dsl.rowsCollect
    local lineMatch = dsl.lineMatch
    local normMatchers = dsl.normMatchers
    local drainRows = dsl.drainRows

    local ROW_KEY = {
        venc = "encode_venc_rows",
        audio = "encode_audio_rows",
        mic = "mic_rows",
        framerate = "framerate_rows",
    }

    local UART_ROW_ERROR = { __error = "uart_error" }

    ----------------------------------------------------------------
    -- utils / handler builders
    ----------------------------------------------------------------

    local function asNum(v)
        return tonumber(v) or 0
    end

    local function drainRowQueue(queue)
        for i = 1, #queue do
            local item = queue[i]
            if drainRows(item.key, item.ev, item.payload) then
                return true
            end
        end
        return false
    end

    -- 多行查询：END 刷新 + 逐行 collect
    local function buildRowCollectHandler(endMark, rowKey, ackEv, linePat, fields)
        return normMatchers(
            rowsFlush(endMark, rowKey, ackEv),
            rowsCollect(linePat, rowKey, fields))
    end

    -- 多行查询：END 刷新 + 自定义 parser append
    local function buildRowParseHandler(endMark, rowKey, ackEv, parseRow)
        return normMatchers(
            rowsFlush(endMark, rowKey, ackEv),
            function(line)
                return rowsAppend(rowKey, parseRow(line))
            end)
    end

    -- SET：ERROR + 若干 OK（lineMatch，不做 normLine）
    local function buildSetHandler(ev, cmd, okRules)
        local parts = { matchFlag("^%+" .. cmd .. ":ERROR", ev, { ok = false }) }
        for i = 1, #okRules do
            local rule = okRules[i]
            parts[#parts + 1] = matchPub(rule.pat, ev, rule.fields or {}, rule.tpl or { ok = true })
        end
        return lineMatch(table.unpack(parts))
    end

    ----------------------------------------------------------------
    -- parsers（URC 行 → row / snap）
    ----------------------------------------------------------------

    local function parseVencRow(line)
        line = normLine(line)
        local cam, stream, en, w, h, br, fps, rc, enc = line:match(
            "^%+VENC:(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)")
        if not cam then
            return nil
        end
        return {
            camera = asNum(cam), stream = asNum(stream), enable = asNum(en),
            width = asNum(w), height = asNum(h), bitrate = asNum(br),
            framerate = asNum(fps), rcmode = asNum(rc), encoder = asNum(enc),
        }
    end

    local function parseAudioRow(line)
        line = normLine(line)
        local cam, en, enc, sr, bw, sm, vol, gain = line:match(
            "^%+AUDIO:(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$")
        if not cam then
            return nil
        end
        return {
            camera = asNum(cam), enable = asNum(en), encoder = asNum(enc),
            samplerate = asNum(sr), bitwidth = asNum(bw), soundmode = asNum(sm),
            volume = asNum(vol), gain = asNum(gain),
        }
    end

    local function parsePersonDetSnap(line)
        local enable, available = line:match("^%+PERSONDET:(%d+),available=(%d+)$")
        if enable then
            return { enable = asNum(enable), available = asNum(available), parsed = true }
        end
        enable = line:match("^%+PERSONDET:(%d+)$")
        if not enable then
            return nil
        end
        return { enable = asNum(enable), parsed = true }
    end

    ----------------------------------------------------------------
    -- uart tail（裸 ERROR / OK，flush 进行中的 encode 查询）
    ----------------------------------------------------------------

    local function tryEncodeUartErr(line)
        if line ~= "ERROR" then
            return false
        end
        return drainRowQueue({
            { key = ROW_KEY.venc, ev = SYS_EVT.VENC_QUERY, payload = UART_ROW_ERROR },
            { key = ROW_KEY.audio, ev = SYS_EVT.AUDIO_QUERY, payload = UART_ROW_ERROR },
        })
    end

    local function tryEncodeUartOk(line)
        if line ~= "OK" then
            return false
        end
        return drainRowQueue({
            { key = ROW_KEY.venc, ev = SYS_EVT.VENC_QUERY },
            { key = ROW_KEY.audio, ev = SYS_EVT.AUDIO_QUERY },
            { key = ROW_KEY.mic, ev = SYS_EVT.MIC_QUERY },
        })
    end

    ----------------------------------------------------------------
    -- VENC / AUDIO
    ----------------------------------------------------------------

    local tryVencLine = buildRowParseHandler(
        "+VENC:END", ROW_KEY.venc, SYS_EVT.VENC_QUERY, parseVencRow)

    local tryVencSetLine = buildSetHandler(SYS_EVT.VENC_SET, "VENCSET", {
        {
            pat = "^%+VENCSET:OK,cam=(%d+),stream=(%d+),needReboot=(%d+),runtimeApply=(%d+)$",
            fields = { "camera", "stream", "!needReboot", "runtimeApply" },
        },
        {
            pat = "^%+VENCSET:OK,cam=(%d+),stream=(%d+),needReboot=(%d+)$",
            fields = { "camera", "stream", "!needReboot" },
        },
    })

    local tryAudioLine = buildRowParseHandler(
        "+AUDIO:END", ROW_KEY.audio, SYS_EVT.AUDIO_QUERY, parseAudioRow)

    local tryAudioSetLine = buildSetHandler(SYS_EVT.AUDIO_SET, "AUDIOSET", {
        {
            pat = "^%+AUDIOSET:OK,cam=(%d+),needReboot=(%d+)$",
            fields = { "camera", "!needReboot" },
        },
    })

    ----------------------------------------------------------------
    -- MIC / SOFTPHOTO
    ----------------------------------------------------------------

    local tryMicLine = buildRowCollectHandler(
        "+MIC:END", ROW_KEY.mic, SYS_EVT.MIC_QUERY,
        "^%+MIC:(%d+),(%d+),(%d+)$", { "camera", "volume", "gain" })

    local tryMicSetLine = buildSetHandler(SYS_EVT.MIC_SET, "MICSET", {
        {
            pat = "^%+MICSET:OK,cam=(%d+),runtimeApply=(%d+)$",
            fields = { "camera", "runtimeApply" },
        },
    })

    local trySoftPhotoSetLine = normMatchers(
        matchFlag("^%+SOFTPHOTOSET:OK", SYS_EVT.SOFTPHOTO_SET, { ok = true }),
        matchFlag("^%+SOFTPHOTOSET:ERROR", SYS_EVT.SOFTPHOTO_SET, { ok = false }))

    local trySoftPhotoLine = normMatchers(
        matchPub("^%+SOFTPHOTO:(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$",
            SYS_EVT.SOFTPHOTO_QUERY,
            { "enable", "nightModeThreshold", "dayModeThreshold", "dayModeAltThreshold",
                "gbGainThreshold", "gbGainRecordInit", "checkTime", "checkCount" },
            { parsed = true }),
        matchFlag("^%+SOFTPHOTO:ERROR", SYS_EVT.SOFTPHOTO_QUERY,
            { parsed = false, error = true }))

    ----------------------------------------------------------------
    -- FRAMERATE / RECORD / UPLOAD / PERSONDET
    ----------------------------------------------------------------

    local tryFramerateLine = normMatchers(
        rowsFlush("+FRAMERATE:END", ROW_KEY.framerate, SYS_EVT.FRAMERATE_QUERY),
        rowsCollect("^%+FRAMERATE:(%d+),(%d+),(%d+)$", ROW_KEY.framerate,
            { "camera", "stream", "framerate" }),
        matchPub("^%+FRAMERATE:OK,(%d+),(%d+),(%d+),runtimeApply=(%d+)$", SYS_EVT.FRAMERATE_SET,
            { "camera", "stream", "framerate", "runtimeApply" }, { ok = true }),
        matchPub("^%+FRAMERATE:OK,(%d+),(%d+),(%d+)$", SYS_EVT.FRAMERATE_SET,
            { "camera", "stream", "framerate" }, { ok = true, runtimeApply = 1 }),
        matchFlag("^%+FRAMERATE:ERROR", SYS_EVT.FRAMERATE_SET, { ok = false, error = true }))

    local tryRecordCtrlLine = normMatchers(
        matchPub("^%+RECORDCTRL:OK,1,max_sec=(%d+)$", SYS_EVT.RECORDCTRL_SET,
            { "max_sec" }, { ok = true, start = 1 }),
        matchPub("^%+RECORDCTRL:OK,0,reason=(.*)$", SYS_EVT.RECORDCTRL_SET,
            { "$reason" }, { ok = true, start = 0 }),
        matchPub("^%+RECORDCTRL:OK,0$", SYS_EVT.RECORDCTRL_SET,
            {}, { ok = true, start = 0, reason = "ok" }),
        matchFlag("^%+RECORDCTRL:ERROR", SYS_EVT.RECORDCTRL_SET,
            { ok = false, error = true }))

    local tryUploadLine = normMatchers(
        matchPub("^%+UPLOADVIDEO:OK,need=(%d+),type=(%d+),start=(%d+),end=(%d+),queued=(%d+)$",
            SYS_EVT.UPLOADVIDEO_SET,
            { "needUpload", "videoType", "start_ts", "end_ts", "queued" }, { ok = true }),
        matchPub("^%+UPLOADVIDEO:OK,need=(%d+),type=(%d+),start=(%d+),end=(%d+)$",
            SYS_EVT.UPLOADVIDEO_SET,
            { "needUpload", "videoType", "start_ts", "end_ts" }, { ok = true, queued = 1 }),
        matchFlag("^%+UPLOADVIDEO:ERROR", SYS_EVT.UPLOADVIDEO_SET,
            { ok = false, error = true }))

    local function handlePersonDetQuery(line)
        local snap = parsePersonDetSnap(line)
        if not snap then
            return false
        end
        state.host_person_detect = snap
        return pubAck(SYS_EVT.PERSONDET_ACK, snap)
    end

    local tryPersonDetLine = normMatchers(
        handlePersonDetQuery,
        matchPub("^%+PERSONDET:OK,(%d+)$", SYS_EVT.PERSONDET_SET, { "enable" }, { ok = true }),
        matchFlag("^%+PERSONDET:ERROR", SYS_EVT.PERSONDET_SET, { ok = false, error = true }))

    ----------------------------------------------------------------
    -- export
    ----------------------------------------------------------------

    return {
        tryEncodeUartErr = tryEncodeUartErr,
        tryFramerateLine = tryFramerateLine,
        tryRecordCtrlLine = tryRecordCtrlLine,
        tryUploadLine = tryUploadLine,
        tryPersonDetLine = tryPersonDetLine,
        tryVencLine = tryVencLine,
        tryVencSetLine = tryVencSetLine,
        tryAudioLine = tryAudioLine,
        tryAudioSetLine = tryAudioSetLine,
        tryMicLine = tryMicLine,
        tryMicSetLine = tryMicSetLine,
        trySoftPhotoLine = trySoftPhotoLine,
        trySoftPhotoSetLine = trySoftPhotoSetLine,
        tryEncodeUartOk = tryEncodeUartOk,
    }
end

return _M
