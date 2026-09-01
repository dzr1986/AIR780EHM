-- ================================================================
-- Filename : hu_ipc_encode.lua
-- Module   : VENC/AUDIO 编码 query/set，由 hu_ipc.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- AT+VENC? / AT+AUDIO? 查询；AT+VENCSET / AT+AUDIOSET 设置
--

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, shared)
    local state = C.state
    local SYS_EVT = C.SYS_EVT
    local hostQuery = shared.hostQuery
    local getCfg = shared.getCfg
    local defineSet = shared.defineSet

    local DEFAULT_TIMEOUT = 8000

    local function encodeCfg()
        return getCfg("HOST_ENCODE_CFG")
    end

    local function optTable(opts)
        return type(opts) == "table" and opts or {}
    end

    local function isAudio(opts)
        return opts.scope == "audio"
    end

    local function asEnable01(v, fallback)
        if v == nil then
            v = fallback
        end
        return (v == true or v == 1) and 1 or 0
    end

    ----------------------------------------------------------------
    -- 查询解析
    ----------------------------------------------------------------

    local function rowsValid(rows)
        if type(rows) ~= "table" or rows.__error or #rows == 0 then
            return false
        end
        for _, row in ipairs(rows) do
            if type(row) == "table" then
                return true
            end
        end
        return false
    end

    local function packRows(rows, audio)
        if type(rows) == "table" and rows.__error then
            return nil, rows.__error
        end
        if not rowsValid(rows) then
            return nil, "empty_encode"
        end
        if audio then
            return { audio = rows }, nil
        end
        return { video = rows }, nil
    end

    local function queryAtCmd(opts)
        opts = optTable(opts)
        if isAudio(opts) then
            if opts.camera ~= nil then
                return "AT+AUDIO?=" .. tonumber(opts.camera)
            end
            return "AT+AUDIO?"
        end
        if opts.camera ~= nil and opts.stream ~= nil then
            return string.format("AT+VENC?=%d,%d", tonumber(opts.camera), tonumber(opts.stream))
        end
        if opts.camera ~= nil then
            return "AT+VENC?=" .. tonumber(opts.camera)
        end
        return "AT+VENC?"
    end

    local function clearEncodeRows(audio)
        if audio then
            state.encode_audio_rows = {}
        else
            state.encode_venc_rows = {}
        end
    end

    local function queryHostEncode(opts)
        opts = optTable(opts)
        local audio = isAudio(opts)
        local lastErr = "timeout"
        local result = hostQuery(opts.timeoutMs, {
            busyKey = "encode_query_busy",
            policyTag = "host_encode",
            cfg = encodeCfg(),
            timeoutCfgKey = "query_timeout_ms",
            defaultTimeout = DEFAULT_TIMEOUT,
            atCmd = queryAtCmd(opts),
            ackEvent = audio and SYS_EVT.AUDIO_QUERY or SYS_EVT.VENC_QUERY,
            beforeSend = function()
                clearEncodeRows(audio)
            end,
            onResponse = function(got, val)
                if not got then
                    lastErr = "timeout"
                    return nil
                end
                local body, err = packRows(val, audio)
                if body then
                    return body
                end
                lastErr = err or "empty_encode"
                return nil
            end,
        })
        if result then
            return result, nil
        end
        return nil, lastErr
    end

    ----------------------------------------------------------------
    -- 设置：缺字段时先 query 当前行
    ----------------------------------------------------------------

    local function fetchCurrentRow(audio, cam, stream, timeoutMs, needQuery)
        if not needQuery then
            return nil, nil
        end
        local qopts = { camera = cam, timeoutMs = timeoutMs }
        if audio then
            qopts.scope = "audio"
        else
            qopts.stream = stream
        end
        local q, qerr = queryHostEncode(qopts)
        if audio then
            if q and q.audio and q.audio[1] then
                return q.audio[1], nil
            end
        elseif q and q.video and q.video[1] then
            return q.video[1], nil
        end
        return nil, qerr
    end

    local function queryTimeoutMs(opts)
        return tonumber(opts.timeoutMs)
            or tonumber(encodeCfg().query_timeout_ms)
            or DEFAULT_TIMEOUT
    end

    local function audioSetAtCmd(opts)
        opts = optTable(opts)
        local timeoutMs = queryTimeoutMs(opts)
        local cam = tonumber(opts.camera) or 0
        local cur, qerr = fetchCurrentRow(true, cam, nil, timeoutMs,
            opts.encoder == nil or opts.samplerate == nil)
        if qerr and not cur then
            return false, qerr
        end
        cur = cur or {}
        return true, nil, string.format("AT+AUDIOSET=%d,%d,%d,%d,%d,%d,%d,%d",
            cam, asEnable01(opts.enable, cur.enable or 1),
            tonumber(opts.encoder or cur.encoder) or 4,
            tonumber(opts.samplerate or cur.samplerate) or 8000,
            tonumber(opts.bitwidth or cur.bitwidth) or 16,
            tonumber(opts.soundmode or cur.soundmode) or 1,
            tonumber(opts.volume or cur.volume) or 80,
            tonumber(opts.gain or cur.gain) or 28)
    end

    local function videoSetAtCmd(opts)
        opts = optTable(opts)
        local timeoutMs = queryTimeoutMs(opts)
        local cam = tonumber(opts.camera) or 0
        local stream = tonumber(opts.stream) or 0
        local cur, qerr = fetchCurrentRow(false, cam, stream, timeoutMs,
            opts.width == nil or opts.height == nil or opts.bitrate == nil)
        if qerr and not cur then
            return false, qerr
        end
        cur = cur or {}
        return true, nil, string.format("AT+VENCSET=%d,%d,%d,%d,%d,%d,%d,%d,%d",
            cam, stream, asEnable01(opts.enable, cur.enable or 1),
            tonumber(opts.width or cur.width) or 1920,
            tonumber(opts.height or cur.height) or 1080,
            tonumber(opts.bitrate or cur.bitrate) or 1200,
            tonumber(opts.framerate or cur.framerate) or 25,
            tonumber(opts.rcmode or cur.rcmode) or 2,
            tonumber(opts.encoder or cur.encoder) or 4)
    end

    local function setAtCmd(opts, audio)
        if audio then
            return audioSetAtCmd(opts)
        end
        return videoSetAtCmd(opts)
    end

    local setHostVideoEncode = defineSet{
        busy = "encode_set_busy", tag = "host_encode_set",
        cfg = encodeCfg, boot = encodeCfg, tmo = DEFAULT_TIMEOUT, ev = SYS_EVT.VENC_SET,
        prep = function(o)
            return setAtCmd(o, false)
        end,
    }
    local setHostAudioEncode = defineSet{
        busy = "encode_set_busy", tag = "host_encode_set",
        cfg = encodeCfg, boot = encodeCfg, tmo = DEFAULT_TIMEOUT, ev = SYS_EVT.AUDIO_SET,
        prep = function(o)
            return setAtCmd(o, true)
        end,
    }

    local function setHostEncode(scope, opts)
        if scope == "audio" then
            return setHostAudioEncode(opts)
        end
        return setHostVideoEncode(opts)
    end

    return {
        queryHostEncode = queryHostEncode,
        setHostVideoEncode = setHostVideoEncode,
        setHostAudioEncode = setHostAudioEncode,
        setHostEncode = setHostEncode,
    }
end

return _M
