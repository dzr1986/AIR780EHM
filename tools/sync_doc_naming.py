#!/usr/bin/env python3
"""Sync doc/*.md API names to 001.000.134 naming. Skips LuaTools/."""

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
    ("t31x_power_wait_ms", "t31xPowerWaitMs"),
    ("publish_stop", "publishStop"),
    ("wait_ip_ready", "waitIpReady"),
    ("force_flymode", "forceFlymode"),
    ("high_ms", "highMs"),
    ("app_event", "appEvent"),
    ("boot_gpio", "bootGpio"),
    # 151 批：旧短名 → 新真名（与 doc/CAT1_API_NAMING.md §4 同步）
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


def sub_text(text: str) -> tuple[str, int]:
    total = 0
    for src, dst in REPLACEMENTS:
        pattern = re.compile(re.escape(src))
        text, n = pattern.subn(dst, text)
        total += n
    return text, total


def main() -> None:
    total = 0
    files = 0
    for path in sorted(DOC.rglob("*.md")):
        if path.name in SKIP_FILES:
            continue
        raw = path.read_text(encoding="utf-8")
        new, n = sub_text(raw)
        if n and new != raw:
            path.write_text(new, encoding="utf-8")
            print(f"{path.relative_to(ROOT)}: {n}")
            total += n
            files += 1
    print(f"done: {files} files, {total} replacements")


if __name__ == "__main__":
    main()
