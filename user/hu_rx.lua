-- ================================================================
-- Filename : hu_rx.lua
-- Module   : T3x UART URC/RX 行解析编排，由 host_uart 在 cmd.bind 后 bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- dsl（云态/TF/录制/IPC）+ media（编码行）→ tryHandlers 链
-- 注册表：更具体的 handler 放前面；encode 错/OK 尾必须先于通用行
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
        -- encode
        { name = "encode_uart_error", fn = media.tryEncodeUartErr },
        { name = "encode_ok_tail", fn = media.tryEncodeUartOk },
        -- misc
        { name = "sound_ack", fn = dsl.trySoundAck },
        { name = "timeset_ack", fn = dsl.tryTimesetAck },
        { name = "gb28181", fn = dsl.tryGb28181 },
        { name = "wled", fn = dsl.tryWledLine },
        -- storage
        { name = "tfformat", fn = dsl.tryTfFormat },
        { name = "tfcard", fn = dsl.tryTfCard },
        -- record
        { name = "recordtime", fn = dsl.tryRecTime },
        { name = "record", fn = dsl.tryRecord },
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
        { name = "ipcstat", fn = dsl.tryIpcStatCloud },
        { name = "ipcstatus", fn = dsl.tryIpcStatus },
        { name = "ipcpoweroff", fn = dsl.tryIpcPowerOff },
    }

    local tryHandlers = {}
    for i = 1, #RX_LINE_HANDLER_REGISTRY do
        tryHandlers[i] = RX_LINE_HANDLER_REGISTRY[i].fn
    end
    return {
        normLine = dsl.normLine,
        parseTfCard = dsl.parseTfCard,
        parseIpcStat = dsl.parseIpcStat,
        normIpcCloud = dsl.normIpcCloud,
        commitIpcStat = dsl.commitIpcStat,
        patchCloud = dsl.patchCloud,
        tryHandlers = tryHandlers,
    }
end

return _M
