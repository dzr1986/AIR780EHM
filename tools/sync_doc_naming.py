#!/usr/bin/env python3
"""Sync doc/*.md API names to truth names (converges historical aliases to current).

REPLACEMENTS 含历批 rename 映射；「151 批」段（bldAtBody->buildStatBody、ntfHostIdle->
notifyHostIdle、shdHostSleep->shouldHostSleep、setStatIv->setStatInterval 等 30 组）已于
2026-09-04 在代码实施（doc/overview/CAT1_API_NAMING.md §4），本脚本恢复启用。
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "doc"

REPLACEMENTS: list[tuple[str, str]] = [
    ("publishUplink", "pubUplink"),
    ("publishStatus", "pubStatus"),
    ("publishRest", "pubRest"),
    ("publishConnect", "pubConnect"),
    ("publishWakeup", "pubWakeup"),
    ("publishDeviceIdRef", "pubDeviceIdRef"),
    ("publishDeviceId", "pubDeviceId"),
    ("publishTfCard", "pubTfCard"),
    ("publishTfFormat", "pubTfFormat"),
    ("publishIpcAlert", "pubIpcAlert"),
    ("publishCtrlReply", "pubCtrlReply"),
    ("publishOtaStatus", "pubOtaStatus"),
    ("publishPirFromState", "pubPirFromSt"),
    ("publishPirEvent", "pubPirEvent"),
    ("publishPirDetect", "pubPirDetect"),
    ("publishPirRecordActive", "pubRecActive"),
    ("publishPirRecordStart", "pubPirStart"),
    ("publishPirRecordStop", "pubPirStop"),
    ("publishPirSnapshotDone", "pubSnapDone"),
    ("publishUploadReply", "pubUploadReply"),
    ("publishUploadDone", "pubUploadDone"),
    ("publishUploadNeed", "pubUploadNeed"),
    ("publishBootStable", "pubBootStab"),
    ("publishSimInfo", "pubSimInfo"),
    ("publishVersion", "pubVersion"),
    ("publishActionEvents", "pubActEvents"),
    ("publishAppEvent", "pubAppEvent"),
    ("publishRaw", "pubRaw"),
    ("subscribeDownlink", "subDownlink"),
    ("setStatusReportIntervalSec", "setStatInterval"),
    ("setStatusInterval", "setStatInterval"),
    ("notifyStatusReportIntervalChanged", "notifyIntervalChanged"),
    ("notify_host_first_at", "onFirstHostAt"),
    ("queryHostIpcCloudStat", "qryIpcCloudStat"),
    ("mergeTfRecordIntoCloudStat", "mergeTfCloud"),
    ("mrgTfCloudStat", "mergeTfCloud"),
    ("drainPendingHostWork", "drainHostQueue"),
    ("hasPendingHostWork", "hasHostQueue"),
    ("collectBatterySnapshot", "snapBattery"),
    ("collectRadioSnapshot", "snapRadio"),
    ("collectSimSnapshot", "snapSim"),
    ("patchHostIpcCloudStat", "patchCloud"),
    ("commitHostIpcCloudStat", "commitIpcStat"),
    ("refCloudB1003", "refCloudStat"),
    ("bootstrapNetwork", "bootstrapNet"),
    ("isSameMqttConfig", "sameMqttCfg"),
    ("setMqttConfig", "setMqttCfg"),
    ("notifyT31xUsbHostIdlePolicy", "notifyUsbIdle"),
    ("push_usb_host_idle_state", "pushUsbIdle"),
    ("canAcceptHostIdleSleep", "canHostSleep"),
    ("noteT31xAwakeForHostIdle", "notifyHostIdle"),
    ("ensureNormalPowerOn", "ensNormalPwrOn"),
    ("setup_input_entry", "setupInputEntry"),
    ("setup_input", "setupInput"),
    ("setup_output", "setupOutput"),
    ("getHostUart", "hostUart"),
    ("getUartBridge", "uartBridge"),
    ("buildAtBod", "buildStatBody"),
    ("buildAtBody", "buildStatBody"),
    ("noteHostIdle", "notifyHostIdle"),
    ("host_now_ms", "hostNowMs"),
    ("mod_call", "modCall"),
    ("on_rx_raw", "onRxRaw"),
    ("isHUBusy", "isHuBusy"),
    ("pchCloudStat", "patchCloud"),
    ("notify_host", "ntfHost"),
    ("handleDownlink", "dispatchDl"),
    ("handleHostProto", "dispatchHostProto"),
    ("applyUsbInsertState", "applyUsbPower"),
    ("shouldAllowHostIdleSleep", "shouldHostSleep"),
    ("createLogFunctions", "mkLogFns"),
    ("maybeAutoPublishIdentity", "maybeAutoPubId"),
    ("app_event_fn", "appEventFn"),
    ("on_published", "onPublished"),
    ("skip_ipc_stat_refresh", "skipIpcStatRefresh"),
    ("push_before_notify", "pushBeforeNotify"),
    ("wake_host", "wakeHost"),
    ("ensure_powered", "ensPowOn"),
    ("on_enter_low_power", "onEnterLowPower"),
    ("on_exit_low_power", "onExitLowPower"),
    ("on_power_off", "onPowerOff"),
    ("skip_pending_work_check", "skipPendingWorkCheck"),
    ("ready_timeout_ms", "readyTimeoutMs"),
    ("poll_ms", "pollMs"),
    ("publish_stop", "publishStop"),
    ("wait_ip_ready", "waitIpReady"),
    ("force_flymode", "forceFlymode"),
    ("high_ms", "highMs"),
    ("app_event", "appEvent"),
    ("boot_gpio", "bootGpio"),
    # 151 批（与 doc/overview/CAT1_API_NAMING.md §4 同步；2026-09-04 起代码已实施，可安全运行）
    ("bldReqOpts", "buildReqOpts"),
    ("refCloudF1003", "refCloudStat1003"),
    ("setStatIv", "setStatInterval"),
    ("getStatIv", "getStatInterval"),
    ("loadStatIvCfg", "loadStatCfg"),
    ("bldAtBody", "buildStatBody"),
    ("ntfHostIdle", "notifyHostIdle"),
    ("shdHostSleep", "shouldHostSleep"),
    ("ntfT31xUsbIdle", "notifyUsbIdle"),
    ("ntfStatIv", "notifyIntervalChanged"),
    ("normPirMCfg", "normMediaCfg"),
    ("normPirRPol", "normRecPolicy"),
    ("clrEffMedia", "clearEffMedia"),
    ("applEffMedia", "applyEffMedia"),
    ("pubActEvents", "pubActionEvents"),
    ("markStMqtt", "markStopPublished"),
    ("isT31HostQry", "canQueryT31"),
    ("recHostSess", "reconcileRecord"),
    ("t31xSecOff", "t31xUartOff"),
    ("setPndWake", "setPendingWake"),
    ("usbRcvrGrd", "usbRecoveryGuard"),
    ("usbRcvrAllow", "checkUsbReset"),
    ("usbRcvrExec", "execUsbReset"),
    ("wledEnsPow", "wledEnsurePower"),
    ("fwdWledTo", "forwardWled"),
    ("escIpcFld", "escIpcField"),
    ("qryFallback", "queryFallback"),
    ("onUsbRm", "onUsbRemove"),
    ("cancelShutdownTmr", "cancelShutdownTimer"),
    ("useSelfSrv", "useSelfServer"),
    ("selfSrvUrl", "selfServerUrl"),
]

SKIP_FILES = {
    "FUNCTION_NAME_MAP.md",
    "CAT1_API_NAMING.md",
}
# 历史留档目录：事故记录/审计账本里会原文引用旧名（如 DOC_HEALTH_REPORT 记录的 `poll_ms→pollMs` 事故本身），
# 收敛脚本一律不碰，否则会把证据改掉
SKIP_DIRS = {"_audit", "archive"}


# 2026-09-04 事故：旧实现无词边界 + 含配置键规则 → 把 CONFIG.md 等 8 处配置键
# `t31x_power_wait_ms` 改成 `t31xPowerWaitMs`、`ready_poll_ms` 改成 `ready_pollMs`（照抄进 host.lua 即死字段）。
# 现约束：① 仅整词替换；② src 若与任一 config 片段的字段名重合则拒绝运行（API 名与配置键是两套命名）。
CONFIG_FRAGMENTS = (
    "features", "cellular", "t31x_burn", "gpio_cfg", "led_pir", "battery", "host", "net", "flags", "events",
)
_IDENT = re.compile(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])")


def config_field_names() -> set[str]:
    names: set[str] = set()
    for frag in CONFIG_FRAGMENTS:
        f = ROOT / "user" / f"{frag}.lua"
        if not f.exists():
            continue
        for line in f.read_text(encoding="utf-8", errors="ignore").splitlines():
            code = line.split("--", 1)[0]
            for m in re.finditer(r"(?<![\w.])([A-Za-z_]\w*)\s*=", code):
                names.add(m.group(1))
    return names


def guard_rules() -> None:
    fields = config_field_names()
    clash = sorted(src for src, _ in REPLACEMENTS if src in fields)
    if clash:
        raise SystemExit(
            "拒绝运行：以下规则 src 与 config 片段字段同名，会把文档中的配置键改坏 → 从 REPLACEMENTS 移除或改名：\n  "
            + "\n  ".join(clash)
        )


def sub_text(text: str) -> tuple[str, int]:
    total = 0
    for src, dst in REPLACEMENTS:
        pattern = re.compile(_IDENT.pattern % re.escape(src))
        text, n = pattern.subn(dst, text)
        total += n
    return text, total


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description="doc/ 内 API 历史别名 → 真名 收敛（整词替换；配置键规则被拒）")
    ap.add_argument("--dry-run", action="store_true", help="只报告命中，不写文件")
    args = ap.parse_args()
    guard_rules()
    total = 0
    files = 0
    for path in sorted(DOC.rglob("*.md")):
        if path.name in SKIP_FILES or (path.relative_to(DOC).parts[0] in SKIP_DIRS):
            continue
        raw = path.read_text(encoding="utf-8")
        new, n = sub_text(raw)
        if n and new != raw:
            if not args.dry_run:
                path.write_text(new, encoding="utf-8")
            print(f"{path.relative_to(ROOT)}: {n}" + ("  (dry-run)" if args.dry_run else ""))
            total += n
            files += 1
    print(f"done: {files} files, {total} replacements" + ("  (dry-run, 未写入)" if args.dry_run else ""))


if __name__ == "__main__":
    main()
