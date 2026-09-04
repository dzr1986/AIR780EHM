-- ================================================================
-- Filename : mqtt_dl_tf.lua
-- Module   : MQTT 2007/2009 TF 卡查询与格式化，由 mqtt_downlink.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================
--
-- 2007 查询 refTfCard | 2009 格式化 dlTfFormat
--

require "sys"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, shared)
    local hostUart = C.hostUart
    local pirCtrl = C.pirCtrl
    local utils = C.utils
    local pubTfCard = C.pub.pubTfCard
    local pubTfFormat = C.pub.pubTfFormat
    local hostReady = shared.t31xHostReady
    local dlMsgId = shared.dlMsgId -- 与其它 dl_* 一致：messageId 或 msgId 都认

    local TIMEOUT = {
        queryRetryWait = 400,
        ipcReadyWait = 20000,
        ipcReadyPoll = 500,
        postFormatStatus = 1000,
        recordStopDefault = 15000,
        preFormatWaitDefault = 500,
    }

    local function tfCfg()
        return cfgm.get("HOST_TFCARD_CFG")
    end

    local function fmtCfg()
        return cfgm.get("HOST_TFCARD_FORMAT_CFG")
    end

    local function cfgEnabled(cfg)
        return cfg.enabled ~= false
    end

    ----------------------------------------------------------------
    -- 2007 查询
    ----------------------------------------------------------------

    local function publishEmptyTf(messageId, timeout)
        pubTfCard({
            present = 0, totalMb = 0, usedMb = 0, freeMb = 0,
            timeout = timeout or nil,
        }, messageId)
    end

    local function queryTfSnap(hif)
        local cfg = tfCfg()
        local snap = hif.queryHostTfCard(cfg.query_timeout_ms)
        if snap == nil then
            sys.wait(TIMEOUT.queryRetryWait)
            snap = hif.queryHostTfCard(cfg.query_timeout_ms)
                or hif.getCachedHostTfCard()
        end
        return snap
    end

    local function refTfCard(messageId)
        if not cfgEnabled(tfCfg()) then
            publishEmptyTf(messageId)
            return
        end
        local hif = hostUart()
        local snap = hif and queryTfSnap(hif) or nil
        if snap == nil then
            publishEmptyTf(messageId, true)
            return
        end
        pubTfCard(snap, messageId)
    end

    ----------------------------------------------------------------
    -- 2009 格式化
    ----------------------------------------------------------------

    local function stopRecordingBeforeFormat()
        local cfg = fmtCfg()
        pirCtrl.reqStopCloud({ messageId = "tf-fmt" })
        pirCtrl.suspend()
        local hif = hostUart()
        if hif and hostReady() then
            hif.recordCtrlStop({
                reason = "tfcard_format",
                timeoutMs = tonumber(cfg.record_stop_timeout_ms) or TIMEOUT.recordStopDefault,
            })
        end
        sys.wait(tonumber(cfg.pre_format_wait_ms) or TIMEOUT.preFormatWaitDefault)
    end

    local function waitHostIpcReady()
        local hif = hostUart()
        if hif then
            pcall(hif.waitHostIpcReady, TIMEOUT.ipcReadyWait, TIMEOUT.ipcReadyPoll)
        end
    end

    local function runFormatSession(messageId, reboot)
        local cfg = fmtCfg()
        if not cfgEnabled(cfg) then
            pubTfFormat(-1, "disabled", messageId, { reboot = reboot })
            return
        end
        local hif = hostUart()
        if not hif then
            pubTfFormat(-1, "no_uart", messageId, { reboot = reboot })
            return
        end
        stopRecordingBeforeFormat()
        waitHostIpcReady()
        local ok, detail = hif.formatHostTfCard({
            reboot = reboot,
            timeoutMs = cfg.format_timeout_ms,
        })
        if ok then
            local extra = type(detail) == "table" and detail or { reboot = reboot }
            pubTfFormat(0, "ok", messageId, extra)
            if cfg.publish_status_after ~= false and (extra.reboot or 0) == 0 then
                sys.wait(TIMEOUT.postFormatStatus)
                refTfCard(messageId)
            end
        else
            pubTfFormat(-1, tostring(detail or "error"), messageId, { reboot = reboot })
        end
    end

    local function parseRebootFlag(data, cfg)
        local reboot = data.reboot
        if reboot == nil then
            reboot = cfg.reboot_after == true or cfg.reboot_after == 1
        end
        return utils.parseBool(reboot) and 1 or 0
    end

    local function dlTfFormat(data)
        local cfg = fmtCfg()
        local action = data.action or "format"
        local messageId = dlMsgId(data)
        if action ~= "format" then
            pubTfFormat(-1, "unknown_action", messageId, {})
            return
        end
        local reboot = parseRebootFlag(data, cfg)
        sys.taskInit(function()
            runFormatSession(messageId, reboot)
            if pirCtrl.resume and reboot == 0 then
                pirCtrl.resume()
            end
        end)
    end

    return {
        refTfCard = refTfCard,
        dlTfFormat = dlTfFormat,
    }
end

return _M
