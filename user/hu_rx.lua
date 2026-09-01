-- ================================================================
-- Filename : hu_rx.lua
-- Module   : T3x UART URC/RX 行解析编排，由 host_uart 在 cmd.bind 后 bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- dsl（云态/TF/录制/IPC）+ media（编码行）→ tryHandlers 链
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local dsl = require("hu_rx_dsl").bind(C)
    local media = require("hu_rx_media").bind(C, dsl)

    ----------------------------------------------------------------
    -- handler registry
    ----------------------------------------------------------------

    local RX_LINE_HANDLER_REGISTRY = {
        media.tryEncodeUartErr,
        media.tryEncodeUartOk,
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
