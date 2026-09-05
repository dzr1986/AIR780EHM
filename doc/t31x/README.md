# t31x — T31x ↔ 4G 协作 / 监督

> **唯一入口**：[doc/README.md](../README.md)；本页为 t31x 二级索引（2026-09-04 分层）。
> **读者**：固件 / 联调 / 平台。写法规范见 [T31X_NAMING.md](../overview/T31X_NAMING.md)。
> **工作流位置**：[TECH_WORKFLOWS W3](../overview/TECH_WORKFLOWS.md#w3-t31x-供电串口握手与云状态同步)（供电门禁 → 首条 AT → IPCSTAT → HOSTIDLE/HOSTEVT）· W10（IPC 告警对账）。

## 协作框架与 AT（先读 📌）

| 文档 | 说明 |
|------|------|
| [T31X_4G_FRAMEWORK.md](T31X_4G_FRAMEWORK.md) 📌 | 协作框架简图（建议先读） |
| [T31X_4G_AT_INTERACTION.md](T31X_4G_AT_INTERACTION.md) | AT 全量交互 |
| [T31X_CAT1_AT_COMMAND_SPEC.md](T31X_CAT1_AT_COMMAND_SPEC.md) | T31x → 4G AT 规范（MQTT + TCP） |
| [T31X_IPC_4G_INTERACTION.md](T31X_IPC_4G_INTERACTION.md) | 分层、PIR / 录像 / rest 流程 |
| [T31X_IPC_CAT1_COMM_COMPLETENESS.md](T31X_IPC_CAT1_COMM_COMPLETENESS.md) | 双向 AT 对照与缺口 |

## HOSTEVT / 唤醒

| 文档 | 说明 |
|------|------|
| [T31X_HOSTEVT_PROTOCOL.md](T31X_HOSTEVT_PROTOCOL.md) | GPIO29 低脉冲与 HOSTEVT |
| [T31X_HOSTEVT_SLEEP.md](T31X_HOSTEVT_SLEEP.md) | HOSTEVT 四条 AT 汇总 |

## IPC 异常监督 / alertCode

| 文档 | 说明 |
|------|------|
| [T31X_IPC_ALERT_CONTRACT.md](T31X_IPC_ALERT_CONTRACT.md) 🟢 | IPC ↔ Cat.1 `alertCode` 共享契约（`ipc_alert_contract.h` 真源） |
| [T31X_IPC_SUPERVISION_MODULE.md](T31X_IPC_SUPERVISION_MODULE.md) | IPC ↔ Cat.1 监督模块架构（两侧独立 + 契约对齐） |
| [T31X_IPC_CAT1_SUPERVISION.md](T31X_IPC_CAT1_SUPERVISION.md) | Cat.1 ↔ IPC 联合异常监督机制 |
| [T31X_IPC_EXCEPTION_MQTT_UPLINK.md](T31X_IPC_EXCEPTION_MQTT_UPLINK.md) | IPC 异常 → MQTT 后台上行协议与恢复态 |
| [T31X_IPC_ALERT_CODE_INDEX.md](T31X_IPC_ALERT_CODE_INDEX.md) | IPC_ALERT / `alertCode` 源码行号速查 |
