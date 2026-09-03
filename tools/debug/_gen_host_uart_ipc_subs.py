# -*- coding: utf-8 -*-
"""Generate hu_ipc submodules from hu_ipc.lua

WARN: 重新运行会覆盖手工调过的 bind 顺序与依赖注入；生成后必跑 _protocol_regression_check.py
"""
from pathlib import Path

from _gen_validate_lua import run_host_uart_regression, validate_bind_module, warn_regenerate

root = Path(__file__).resolve().parents[2] / "user"
lines = (root / "hu_ipc.lua").read_text(encoding="utf-8").splitlines()

SPECS = [
    {
        "file": "hu_ipc_cloud.lua",
        "title": "IPC 云状态 / GB28181 / qryIpcCloudStat",
        "start": 286,
        "end": 538,
        "bind_args": "C, H",
        "header_extra": "    local idCfgFn = H.idCfgFn\n    local qryHostStat, qryHostRecord = H.qryHostStat, H.qryHostRecord\n",
        "returns": """    return {
        cachedGb28181Id = cachedGb28181Id,
        qryGb28181 = qryGb28181,
        isIpcCloudStatStale = isIpcCloudStatStale,
        getCloudStat = getCloudStat,
        isT31HostQry = isT31HostQry,
        shouldQryIpcStat = shouldQryIpcStat,
        needsIpcStatRefresh = needsIpcStatRefresh,
        mergeTfCloud = mergeTfCloud,
        refCloudF1003 = refCloudF1003,
        isHuBusy = isHuBusy,
        recHostSess = recHostSess,
        qryIpcCloudStat = qryIpcCloudStat,
        cachedTfCard = cachedTfCard,
    }""",
    },
    {
        "file": "hu_ipc_rec.lua",
        "title": "UART 链路恢复 / qryHostStat / resetHostLink",
        "start": 540,
        "end": 663,
        "bind_args": "C, H",
        "header_extra": "",
        "returns": """    return {
        noteUartLinkOk = noteUartLinkOk,
        resetHostLink = resetHostLink,
        qryHostStat = qryHostStat,
    }""",
    },
    {
        "file": "hu_ipc_power.lua",
        "title": "hostIpcPowerOff / waitHostIpcReady",
        "start": 665,
        "end": 781,
        "bind_args": "C, H",
        "header_extra": "    local qryHostStat = H.qryHostStat\n",
        "returns": """    return {
        hostIpcPowerOff = hostIpcPowerOff,
        waitHostIpcReady = waitHostIpcReady,
    }""",
    },
    {
        "file": "hu_ipc_hostq.lua",
        "title": "RECORD/FRAMERATE/MIC/SOFTPHOTO/TFCARD query/set",
        "start": 782,
        "end": 1015,
        "bind_args": "C, H",
        "header_extra": """    local idCfgFn = H.idCfgFn
    local encodeCfgFn = H.encodeCfgFn
    local tfCardCfgFn = H.tfCardCfgFn
""",
        "returns": """    return {
        getT31xRecActive = getT31xRecActive,
        qryHostRecord = qryHostRecord,
        qryRecTime = qryRecTime,
        setRecTime = setRecTime,
        queryHostFramerate = queryHostFramerate,
        setHostFramerate = setHostFramerate,
        recordCtrlStart = recordCtrlStart,
        recordCtrlStop = recordCtrlStop,
        requestUploadVideo = requestUploadVideo,
        queryHostPersonDetect = queryHostPersonDetect,
        setHostPersonDetect = setHostPersonDetect,
        queryHostMic = queryHostMic,
        setHostMic = setHostMic,
        queryHostSoftPhoto = queryHostSoftPhoto,
        setHostSoftPhoto = setHostSoftPhoto,
        queryHostTfCard = queryHostTfCard,
    }""",
    },
    {
        "file": "hu_ipc_tffmt.lua",
        "title": "AT+TFFORMAT formatHostTfCard",
        "start": 1016,
        "end": 1097,
        "bind_args": "C, H",
        "header_extra": """    local ensT31xHost = H.ensT31xHost
    local hostBoot = H.hostBoot
""",
        "returns": """    return {
        formatHostTfCard = formatHostTfCard,
    }""",
    },
]

COMMON_HEADER = '''-- ================================================================
-- Filename : {file}
-- Module   : {title}，由 hu_ipc.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind({bind_args})
    local cfgm = require "config_manager"
    local state, SYS_EVT, E = C.state, C.SYS_EVT, C.E
    local uartAcquire, uartRelease = C.uartAcquire, C.uartRelease
    local waitHostIdle, hostBusy = C.waitHostIdle, C.hostBusy
    local uart_bridge, loader, utils = C.uart_bridge, C.loader, C.utils
    local modCall, t31xUartOff = C.modCall, C.t31xUartOff
    local usbInserted = C.usbInserted
    local hostNowMs = C.hostNowMs
    local noopIdle, noopFalse = C.noopIdle, C.noopFalse
    local wledGet = C.wledGet
    local normIpcCloud = C.normIpcCloud
    local patchCloud = C.patchCloud
    local commitIpcStat = C.commitIpcStat
    local getCfg = H.getCfg
    local hostQuery = H.hostQuery
    local hostSet = H.hostSet
    local defineQuery = H.defineQuery
    local defineSet = H.defineSet
    local function pushUsbIdle(...)
        return C.pushUsbIdle(...)
    end
{header_extra}
'''

COMMON_FOOTER = """
{returns}
end

return _M
"""


def extract(spec):
    return "\n".join(lines[spec["start"] - 1 : spec["end"]])


remove_idx = set()
for spec in SPECS:
    for i in range(spec["start"] - 1, spec["end"]):
        remove_idx.add(i)

for spec in SPECS:
    body = extract(spec)
    header = COMMON_HEADER.format(
        file=spec["file"],
        title=spec["title"],
        bind_args=spec["bind_args"],
        header_extra=spec.get("header_extra", ""),
    )
    footer = COMMON_FOOTER.format(returns=spec["returns"])
    (root / spec["file"]).write_text(header + body + footer, encoding="utf-8")
    print(spec["file"], len((header + body + footer).splitlines()), "lines")

# Patch ipc.lua: keep lines 0-284 (0-based), then insert binds, then 1098-end
keep_head = lines[:285]
keep_tail = lines[1097:]  # from enc bind (0-based 1097 = line 1098)

bind_block = [
    "    local H = {",
    "        getCfg = getCfg,",
    "        hostQuery = hostQuery,",
    "        hostSet = hostSet,",
    "        defineQuery = defineQuery,",
    "        defineSet = defineSet,",
    "        ensT31xHost = ensT31xHost,",
    "        hostBoot = hostBoot,",
    "        idCfgFn = idCfgFn,",
    "        encodeCfgFn = encodeCfgFn,",
    "        tfCardCfgFn = tfCardCfgFn,",
    "    }",
    '    local recovery = require("hu_ipc_rec").bind(C, H)',
    '    H.qryHostStat = recovery.qryHostStat',
    '    local hostq = require("hu_ipc_hostq").bind(C, H)',
    '    H.qryHostRecord = hostq.qryHostRecord',
    '    local cloud = require("hu_ipc_cloud").bind(C, H)',
    '    local power = require("hu_ipc_power").bind(C, H)',
    '    local tffmt = require("hu_ipc_tffmt").bind(C, H)',
]

new_tail = []
for ln in keep_tail:
    new_tail.append(ln)

text = "\n".join(keep_head + bind_block + new_tail)

# exp table replacements
replacements = {
    "cachedGb28181Id = cachedGb28181Id,": "cachedGb28181Id = cloud.cachedGb28181Id,",
    "qryGb28181 = qryGb28181,": "qryGb28181 = cloud.qryGb28181,",
    "isIpcCloudStatStale = isIpcCloudStatStale,": "isIpcCloudStatStale = cloud.isIpcCloudStatStale,",
    "isT31HostQry = isT31HostQry,": "isT31HostQry = cloud.isT31HostQry,",
    "shouldQryIpcStat = shouldQryIpcStat,": "shouldQryIpcStat = cloud.shouldQryIpcStat,",
    "needsIpcStatRefresh = needsIpcStatRefresh,": "needsIpcStatRefresh = cloud.needsIpcStatRefresh,",
    "mergeTfCloud = mergeTfCloud,": "mergeTfCloud = cloud.mergeTfCloud,",
    "refCloudF1003 = refCloudF1003,": "refCloudF1003 = cloud.refCloudF1003,",
    "isHuBusy = isHuBusy,": "isHuBusy = cloud.isHuBusy,",
    "recHostSess = recHostSess,": "recHostSess = cloud.recHostSess,",
    "qryIpcCloudStat = qryIpcCloudStat,": "qryIpcCloudStat = cloud.qryIpcCloudStat,",
    "cachedTfCard = cachedTfCard,": "cachedTfCard = cloud.cachedTfCard,",
    "resetHostLink = resetHostLink,": "resetHostLink = recovery.resetHostLink,",
    "qryHostRecord = qryHostRecord,": "qryHostRecord = hostq.qryHostRecord,",
    "qryRecTime = qryRecTime,": "qryRecTime = hostq.qryRecTime,",
    "setRecTime = setRecTime,": "setRecTime = hostq.setRecTime,",
    "queryHostFramerate = queryHostFramerate,": "queryHostFramerate = hostq.queryHostFramerate,",
    "setHostFramerate = setHostFramerate,": "setHostFramerate = hostq.setHostFramerate,",
    "queryHostPersonDetect = queryHostPersonDetect,": "queryHostPersonDetect = hostq.queryHostPersonDetect,",
    "setHostPersonDetect = setHostPersonDetect,": "setHostPersonDetect = hostq.setHostPersonDetect,",
    "queryHostMic = queryHostMic,": "queryHostMic = hostq.queryHostMic,",
    "setHostMic = setHostMic,": "setHostMic = hostq.setHostMic,",
    "queryHostSoftPhoto = queryHostSoftPhoto,": "queryHostSoftPhoto = hostq.queryHostSoftPhoto,",
    "setHostSoftPhoto = setHostSoftPhoto,": "setHostSoftPhoto = hostq.setHostSoftPhoto,",
    "queryHostTfCard = queryHostTfCard,": "queryHostTfCard = hostq.queryHostTfCard,",
    "formatHostTfCard = formatHostTfCard,": "formatHostTfCard = tffmt.formatHostTfCard,",
    "requestUploadVideo = requestUploadVideo,": "requestUploadVideo = hostq.requestUploadVideo,",
    "recordCtrlStart = recordCtrlStart,": "recordCtrlStart = hostq.recordCtrlStart,",
    "recordCtrlStop = recordCtrlStop,": "recordCtrlStop = hostq.recordCtrlStop,",
    "qryHostStat = qryHostStat,": "qryHostStat = recovery.qryHostStat,",
    "hostIpcPowerOff = hostIpcPowerOff,": "hostIpcPowerOff = power.hostIpcPowerOff,",
    "waitHostIpcReady = waitHostIpcReady,": "waitHostIpcReady = power.waitHostIpcReady,",
    "getCloudStat = getCloudStat,": "getCloudStat = cloud.getCloudStat,",
    "getT31xRecActive = getT31xRecActive,": "getT31xRecActive = hostq.getT31xRecActive,",
    "C.noteUartLinkOk = noteUartLinkOk": "C.noteUartLinkOk = recovery.noteUartLinkOk",
}

for old, new in replacements.items():
    text = text.replace(old, new)

(root / "hu_ipc.lua").write_text(text + "\n", encoding="utf-8")
print("hu_ipc.lua", len(text.splitlines()), "lines")

warn_regenerate()
for spec in SPECS:
    validate_bind_module(root / spec["file"])
run_host_uart_regression(Path(__file__).resolve().parent)
