-- ================================================================
-- Filename : hif_ipc_encode.lua
-- Module   : VENC/AUDIO 编码 query/set，由 hif_ipc.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- AT+VENC? / AT+AUDIO? 查询；AT+VENCSET / AT+AUDIOSET 设置
-- 设置缺 width/height/bitrate（视频）或 encoder/samplerate（音频）时先 query 当前行
--

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, H)
    local state, SYS_EVT = C.state, C.SYS_EVT
    local utils = C.utils
    local getCfg, hostQuery = H.getCfg, H.hostQuery
    local defineSet = H.defineSet

    local QUERY_MS = 8000

    local function encodeCfg()
        return getCfg("HOST_ENCODE_CFG")
    end

    local optTable = utils.optTable

    local function isAudio(opts)
        return opts.scope == "audio"
    end

    local function asEnable01(v, fallback)
        if v == nil then
            v = fallback
        end
        return (v == true or v == 1) and 1 or 0
    end

    local function num(v, fallback)
        return tonumber(v) or fallback
    end

    ----------------------------------------------------------------
    -- 查询
    ----------------------------------------------------------------

    local function packRows(rows, audio)
        if type(rows) == "table" and rows.__error then
            return nil, rows.__error
        end
        if type(rows) ~= "table" or #rows == 0 or type(rows[1]) ~= "table" then
            return nil, "empty_encode"
        end
        if audio then
            return { audio = rows }
        end
        return { video = rows }
    end

    local function queryAtCmd(opts)
        opts = optTable(opts)
        local cam, stream = opts.camera, opts.stream
        if isAudio(opts) then
            return cam ~= nil and ("AT+AUDIO?=" .. tonumber(cam)) or "AT+AUDIO?"
        end
        if cam ~= nil and stream ~= nil then
            return string.format("AT+VENC?=%d,%d", tonumber(cam), tonumber(stream))
        end
        if cam ~= nil then
            return "AT+VENC?=" .. tonumber(cam)
        end
        return "AT+VENC?"
    end

    local function clearEncodeRows(audio)
        state[audio and "encode_audio_rows" or "encode_venc_rows"] = {}
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
            defaultTimeout = QUERY_MS,
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
    -- 设置：缺关键字段时先 query 当前行再拼 AT
    ----------------------------------------------------------------

    local function queryTimeoutMs(opts)
        return tonumber(opts.timeoutMs)
            or tonumber(encodeCfg().query_timeout_ms)
            or QUERY_MS
    end

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
        local rows = q and (audio and q.audio or q.video)
        if rows and rows[1] then
            return rows[1], nil
        end
        return nil, qerr
    end

    local function buildSetAt(opts, audio)
        opts = optTable(opts)
        local cam = num(opts.camera, 0)
        local stream = num(opts.stream, 0)
        local needQuery
        if audio then
            needQuery = opts.encoder == nil or opts.samplerate == nil
        else
            needQuery = opts.width == nil or opts.height == nil or opts.bitrate == nil
        end
        local cur, qerr = fetchCurrentRow(audio, cam, stream, queryTimeoutMs(opts), needQuery)
        if qerr and not cur then
            return false, qerr
        end
        cur = cur or {}
        if audio then
            return true, nil, string.format(
                "AT+AUDIOSET=%d,%d,%d,%d,%d,%d,%d,%d",
                cam, asEnable01(opts.enable, cur.enable or 1),
                num(opts.encoder or cur.encoder, 4),
                num(opts.samplerate or cur.samplerate, 8000),
                num(opts.bitwidth or cur.bitwidth, 16),
                num(opts.soundmode or cur.soundmode, 1),
                num(opts.volume or cur.volume, 80),
                num(opts.gain or cur.gain, 28))
        end
        return true, nil, string.format(
            "AT+VENCSET=%d,%d,%d,%d,%d,%d,%d,%d,%d",
            cam, stream, asEnable01(opts.enable, cur.enable or 1),
            num(opts.width or cur.width, 1920),
            num(opts.height or cur.height, 1080),
            num(opts.bitrate or cur.bitrate, 1200),
            num(opts.framerate or cur.framerate, 25),
            num(opts.rcmode or cur.rcmode, 2),
            num(opts.encoder or cur.encoder, 4))
    end

    local function encodeSet(ev, audio)
        return defineSet{
            busy = "encode_set_busy",
            tag = "host_encode_set",
            cfg = encodeCfg,
            boot = encodeCfg,
            tmo = QUERY_MS,
            ev = ev,
            prep = function(o)
                return buildSetAt(o, audio)
            end,
        }
    end

    local setHostVideoEncode = encodeSet(SYS_EVT.VENC_SET, false)
    local setHostAudioEncode = encodeSet(SYS_EVT.AUDIO_SET, true)

    return {
        queryHostEncode = queryHostEncode,
        setHostVideoEncode = setHostVideoEncode,
        setHostAudioEncode = setHostAudioEncode,
    }
end

return _M
