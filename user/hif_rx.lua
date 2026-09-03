-- ================================================================
-- Filename : hif_rx.lua
-- Module   : URC/RX 行解析编排（L1），由 host_uart 在 cmd.bind 之后 bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- 绑定契约：bind(C) 返回 { normLine, parseTfCard, parseIpcStat,
--   normIpcCloud, commitIpcStat, patchCloud, tryHandlers }；
--   前 6 个由 host_uart 回填到 ctx（其他编排器复用），tryHandlers
--   作为 URC 行处理链交 host_uart 按顺序逐条尝试。
--
-- 组成：dsl（云态/TF/录制/IPC 状态）+ media（编码/麦克风/软光敏行）。
-- tryHandlers 顺序敏感：更具体前缀先匹配；裸 "OK"/"ERROR" 仅 flush 编码查询。
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local dsl = require("hif_rx_dsl").bind(C)
    local media = require("hif_rx_media").bind(C, dsl)

    ----------------------------------------------------------------
    -- handler registry
    ----------------------------------------------------------------

    -- 顺序：更具体的前缀先匹配；裸 OK/ERROR 只 flush 进行中的 encode 查询
    local RX_LINE_HANDLER_REGISTRY = {
        media.tryEncodeUartErr,   -- 裸 ERROR
        media.tryEncodeUartOk,    -- 裸 OK
        dsl.trySoundAck,
        dsl.tryTimesetAck,
        dsl.tryGb28181,
        dsl.tryWledLine,
        dsl.tryTfFormat,
        dsl.tryTfCard,
        dsl.tryRecTime,
        dsl.tryRecord,
        media.tryRecordCtrlLine,
        media.tryUploadLine,
        media.tryFramerateLine,
        media.tryVencLine,
        media.tryVencSetLine,
        media.tryAudioLine,
        media.tryAudioSetLine,
        media.tryMicLine,
        media.tryMicSetLine,
        media.trySoftPhotoLine,
        media.trySoftPhotoSetLine,
        media.tryPersonDetLine,
        dsl.tryIpcStatCloud,
        dsl.tryIpcStatus,
        dsl.tryIpcPowerOff,
    }

    return {
        normLine = dsl.normLine,
        parseTfCard = dsl.parseTfCard,
        parseIpcStat = dsl.parseIpcStat,
        normIpcCloud = dsl.normIpcCloud,
        commitIpcStat = dsl.commitIpcStat,
        patchCloud = dsl.patchCloud,
        tryHandlers = RX_LINE_HANDLER_REGISTRY,
    }
end

return _M
