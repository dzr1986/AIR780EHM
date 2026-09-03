# -*- coding: utf-8 -*-
"""Generate hu_cmd submodules from hu_cmd.lua

WARN: 重新运行会覆盖手工调过的文件；生成后必跑 _protocol_regression_check.py
"""
from pathlib import Path

from _gen_validate_lua import run_host_uart_regression, validate_bind_module, warn_regenerate

root = Path(__file__).resolve().parents[2] / "user"
lines = (root / "hu_cmd.lua").read_text(encoding="utf-8").splitlines()

SPECS = [
    {
        "file": "hu_cmd_link.lua",
        "title": "P2P/GB28181/MQTT/SERV 链路 AT handler",
        "start": 151,  # escIpcFld (1-based)
        "end": 340,    # uartServClose end (inclusive)
        "header_extra": "",
        "returns": """    return {
        uartP2pCfg = uartP2pCfg,
        uartGb28181 = uartGb28181,
        uartIpcInfoQry = uartIpcInfoQry,
        uartMqttPub = uartMqttPub,
        uartMqttCfg = uartMqttCfg,
        uartServCreate = uartServCreate,
        uartServClose = uartServClose,
    }""",
    },
    {
        "file": "hu_cmd_pir.lua",
        "title": "HOSTEVT/PIRSTAT 组装与 handler",
        "ranges": [(52, 128), (352, 354), (406, 409)],
        "header_extra": """    local getHostEvtPending = C.getHostEvtPending
""",
        "returns": """    return {
        bldHostEvtBody = bldHostEvtBody,
        bldPirWake = bldPirWake,
        uartHostEvtQry = uartHostEvtQry,
        uartHostEvtClr = uartHostEvtClr,
        uartPirStatQry = uartPirStatQry,
        uartPirClr = uartPirClr,
    }""",
    },
    {
        "file": "hu_cmd_t31x.lua",
        "title": "T31x 上行 NOTIFY（RECORD/UPLOAD/IPCSTAT 等）",
        "ranges": [(411, 519), (521, 574)],
        "header_extra": "",
        "returns": """    return {
        ipcReadyFrom = ipcReadyFrom,
        uartRecord = uartRecord,
        uartPersonCnt = uartPersonCnt,
        uartPirMedia = uartPirMedia,
        uartIpcAlert = uartIpcAlert,
        uartUploadNeed = uartUploadNeed,
        uartUploadResult = uartUploadResult,
        uartIpcStatusNtf = uartIpcStatusNtf,
        uartIpcStatNtf = uartIpcStatNtf,
        uartTfCardNtf = uartTfCardNtf,
        uartSnapshot = uartSnapshot,
    }""",
    },
    {
        "file": "hu_cmd_wled.lua",
        "title": "WLED AT handler 与转发",
        "start": 657,
        "end": 792,
        "header_extra": """    local noopFalse = C.noopFalse
    local function hostQuery(...)
        return C.hostQuery(...)
    end
""",
        "returns": """    return {
        wledState = wledState,
        wledExport = wledExport,
        wledGet = wledGet,
        qryHostWled = qryHostWled,
        setWledState = setWledState,
        uartWled = uartWled,
    }""",
    },
]

COMMON_HEADER = '''-- ================================================================
-- Filename : {file}
-- Module   : {title}，由 hu_cmd.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local cfgm = require "config_manager"
    local state, hooks, SYS_EVT, E = C.state, C.hooks, C.SYS_EVT, C.E
    local rspOnly, rspBody, rspFmt = C.rspOnly, C.rspBody, C.rspFmt
    local rspLine, rspLineOk, okTail = C.rspLine, C.rspLineOk, C.okTail
    local modCall, loader, utils = C.modCall, C.loader, C.utils
    local hostNowMs, t31xUartOff = C.hostNowMs, C.t31xUartOff
    local RSP_ERROR = C.RSP_ERROR
    local function parseSvcArgs(...)
        return C.parseSvcArgs(...)
    end
    local function parseIpcStat(...)
        return C.parseIpcStat(...)
    end
    local function parseTfCard(...)
        return C.parseTfCard(...)
    end
    local function commitIpcStat(...)
        return C.commitIpcStat(...)
    end
    local function patchCloud(...)
        return C.patchCloud(...)
    end
    local function noteHostPush(...)
        return C.noteHostPush(...)
    end
    local function idCfg(...)
        return C.idCfg(...)
    end
    local function qryGb28181(...)
        return C.M.qryGb28181(...)
    end
{header_extra}
'''

COMMON_FOOTER = """
{returns}
end

return _M
"""


def extract(spec):
    if "ranges" in spec:
        parts = []
        for s, e in spec["ranges"]:
            parts.extend(lines[s - 1 : e])
        text = "\n".join(parts)
    else:
        text = "\n".join(lines[spec["start"] - 1 : spec["end"]])
    if spec["file"] == "hu_cmd_link.lua":
        text = "    local escIpcFld = utils.escKv\n\n" + text
        text = (
            "    local function devImei()\n"
            "        return modCall(\"device_id\", \"getImei\")\n"
            "    end\n\n"
            + text
        )
    if spec["file"] == "hu_cmd_pir.lua":
        text = text.replace("function bldHostEvtBody()", "local function bldHostEvtBody()")
    if spec["file"] == "hu_cmd_t31x.lua":
        pass  # keep function uartIpc* as exported handlers
    if "post_process" in spec:
        text = spec["post_process"](text)
    return text


def strip_ranges(ranges):
    """Return line indices (0-based) to remove, sorted descending."""
    out = set()
    for s, e in ranges:
        for i in range(s - 1, e):
            out.add(i)
    return sorted(out, reverse=True)


# Collect all ranges to remove from cmd
remove_idx = set()
for spec in SPECS:
    if "ranges" in spec:
        for s, e in spec["ranges"]:
            for i in range(s - 1, e):
                remove_idx.add(i)
    else:
        for i in range(spec["start"] - 1, spec["end"]):
            remove_idx.add(i)

for spec in SPECS:
    body = extract(spec)
    header = COMMON_HEADER.format(
        file=spec["file"],
        title=spec["title"],
        header_extra=spec.get("header_extra", ""),
    )
    footer = COMMON_FOOTER.format(returns=spec["returns"])
    (root / spec["file"]).write_text(header + body + footer, encoding="utf-8")
    print(spec["file"], len((header + body + footer).splitlines()), "lines")

# Patch cmd.lua
new_lines = [ln for i, ln in enumerate(lines) if i not in remove_idx]

# Insert submodule binds after usbCmd line
insert_at = None
for i, ln in enumerate(new_lines):
    if "local usbCmd = require" in ln:
        insert_at = i + 1
        break
bind_lines = [
    '    local linkCmd = require("hu_cmd_link").bind(C)',
    '    local pirCmd = require("hu_cmd_pir").bind(C)',
    '    local t31xCmd = require("hu_cmd_t31x").bind(C)',
    '    local wledCmd = require("hu_cmd_wled").bind(C)',
]
if insert_at:
    new_lines[insert_at:insert_at] = bind_lines

text = "\n".join(new_lines)

# at table replacements
replacements = {
    "pirstat = uartPirStatQry,": "pirstat = pirCmd.uartPirStatQry,",
    "pirclr = uartPirClr,": "pirclr = pirCmd.uartPirClr,",
    "record = uartRecord,": "record = t31xCmd.uartRecord,",
    "ipcstatus = uartIpcStatusNtf,": "ipcstatus = t31xCmd.uartIpcStatusNtf,",
    "ipcstat = uartIpcStatNtf,": "ipcstat = t31xCmd.uartIpcStatNtf,",
    "tfcard = uartTfCardNtf,": "tfcard = t31xCmd.uartTfCardNtf,",
    "snapshot = uartSnapshot,": "snapshot = t31xCmd.uartSnapshot,",
    "pirmedia = uartPirMedia,": "pirmedia = t31xCmd.uartPirMedia,",
    "personcnt = uartPersonCnt,": "personcnt = t31xCmd.uartPersonCnt,",
    "ipcalert = uartIpcAlert,": "ipcalert = t31xCmd.uartIpcAlert,",
    "uploadneed = uartUploadNeed,": "uploadneed = t31xCmd.uartUploadNeed,",
    "uploadresult = uartUploadResult,": "uploadresult = t31xCmd.uartUploadResult,",
    "hostevt = uartHostEvtQry,": "hostevt = pirCmd.uartHostEvtQry,",
    "hostevtclr = uartHostEvtClr,": "hostevtclr = pirCmd.uartHostEvtClr,",
    "ipcinfo = uartIpcInfoQry,": "ipcinfo = linkCmd.uartIpcInfoQry,",
    "mqttpub = uartMqttPub,": "mqttpub = linkCmd.uartMqttPub,",
    "wled = uartWled,": "wled = wledCmd.uartWled,",
    "servcreate = uartServCreate,": "servcreate = linkCmd.uartServCreate,",
    "mqttcfg = uartMqttCfg,": "mqttcfg = linkCmd.uartMqttCfg,",
    "p2pcfg = uartP2pCfg,": "p2pcfg = linkCmd.uartP2pCfg,",
    "gb28181 = uartGb28181,": "gb28181 = linkCmd.uartGb28181,",
    "servclose = uartServClose,": "servclose = linkCmd.uartServClose,",
    "C.wledState = wledState": "C.wledState = wledCmd.wledState",
    "C.wledExport = wledExport": "C.wledExport = wledCmd.wledExport",
    "C.wledGet = wledGet": "C.wledGet = wledCmd.wledGet",
    "C.ipcReadyFrom = ipcReadyFrom": "C.ipcReadyFrom = t31xCmd.ipcReadyFrom",
    "wledState = wledState,": "wledState = wledCmd.wledState,",
    "setWledState = setWledState,": "setWledState = wledCmd.setWledState,",
    "qryHostWled = qryHostWled,": "qryHostWled = wledCmd.qryHostWled,",
    "bldHostEvtBody = bldHostEvtBody,": "bldHostEvtBody = pirCmd.bldHostEvtBody,",
    "wledGet = wledGet,": "wledGet = wledCmd.wledGet,",
    "uartIpcStatusNtf = uartIpcStatusNtf,": "uartIpcStatusNtf = t31xCmd.uartIpcStatusNtf,",
    "uartIpcStatNtf = uartIpcStatNtf,": "uartIpcStatNtf = t31xCmd.uartIpcStatNtf,",
    "uartTfCardNtf = uartTfCardNtf,": "uartTfCardNtf = t31xCmd.uartTfCardNtf,",
}

for old, new in replacements.items():
    text = text.replace(old, new)

# hostidle uses bldPirWake
text = text.replace("local hostBody = bldPirWake(true)", "local hostBody = pirCmd.bldPirWake(true)")

(root / "hu_cmd.lua").write_text(text + "\n", encoding="utf-8")
print("hu_cmd.lua", len(text.splitlines()), "lines")

warn_regenerate()
for spec in SPECS:
    validate_bind_module(root / spec["file"])
run_host_uart_regression(Path(__file__).resolve().parent)
