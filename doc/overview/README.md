# overview — 术语 / 总览 / 架构 / 配置 / 治理

> **唯一入口**：[doc/README.md](../README.md)；本页为 overview 二级索引（2026-09-04 分层）。
> **徽标**：🟢 现行真源 · 📌 建议先读 · 📋 计划（冻结观察期 ~09-14）· 🗒 记录 / 账本 · ⚠ 历史
> **代码真源**：`user/config.lua`（编排）、`user/events.lua`（`APP_EVENTS`）。API 命名见下方 CAT1_API_NAMING。

## 命名与模块树（先读，真源）

| 文档 | 说明 |
|------|------|
| [CAT1_API_NAMING.md](CAT1_API_NAMING.md) 🟢 | **Lua API 命名真源**（前缀 `pub*`/`dl*`/`snap*`/…，对齐代码 001.000.160，151 批 rename 后无 API 变更） |
| [T31X_NAMING.md](T31X_NAMING.md) 🟢 | 协处理器写法规范（`t31x` 代码 / `T31x` 行文 / `T31X` 常量·文件名） |
| [LUA_MODULES.md](LUA_MODULES.md) 🟢 | **模块树真源**（user 59 + lib 15 = 74，config 片段族、设计原则） |

## 架构与现状（入口先读 📌）

| 文档 | 说明 |
|------|------|
| [SYSTEM_ARCHITECTURE.md](SYSTEM_ARCHITECTURE.md) 📌 | **系统级总览**：子系统 / 核心模块 / 数据流（建议先读） |
| [TECH_WORKFLOWS.md](TECH_WORKFLOWS.md) 📌 | **技术工作流总图**：按设备生命周期 W0–W10 串起模块/协议/门禁/观测点/真源（运行时视角，排障入口） |
| [CODE_LAYERING_ARCHITECTURE.md](CODE_LAYERING_ARCHITECTURE.md) 🟢 | **分层架构真源**：`lib/`（L0–L2）与 `user/`（L3–L4）切割 |
| [CONFIG.md](CONFIG.md) 🟢 | **配置索引**：`GPIO_IN`/`GPIO_OUT`、Air780 GPIO 编号、`config.mk` 宏对照 |
| [CAT1_MODULE_FRAMEWORK.md](CAT1_MODULE_FRAMEWORK.md) | 模块框架：`module_loader`/`config_manager`、生命周期/日志/事件约定 |
| [CALL_GRAPH.md](CALL_GRAPH.md) | 启动顺序、require、事件流（`app.start` 真序、dataType↔函数表，2026-09-04 对齐 155） |
| [PROJECT_DOC.md](PROJECT_DOC.md) | 模块职责、业务流程、调试 |
| [CODE_ANALYSIS.md](CODE_ANALYSIS.md) | 架构与风险分析 |
| [FUNCTIONAL_ARCHITECTURE.md](FUNCTIONAL_ARCHITECTURE.md) | 功能架构：特性域 → 层 → 模块 |
| [TIME_SYNC.md](TIME_SYNC.md) | SNTP + `AT+TIMESET` 时间同步 |
| [CAT1_LOG_TAGS.md](CAT1_LOG_TAGS.md) | Cat.1 日志标签说明（`/mnt/share/user/` 镜像） |

## 优化计划 / 体检（冻结观察期 ~2026-09-14）

| 文档 | 说明 |
|------|------|
| [ARCHITECTURE_REVIEW_POWER_PSM.md](ARCHITECTURE_REVIEW_POWER_PSM.md) 📋 | **电源/低功耗架构评审 + 电源状态机(PSM)设计稿**（2026-09-04，R1 主案 + R2–R4；衔接 PWR_BUDGET，落地前不改码） |
| [ARCHITECTURE_REVIEW_20260903.md](ARCHITECTURE_REVIEW_20260903.md) 📋 | **架构体检报告与四主题裁决**（2026-09-03，冻结观察期至约 09-14） |
| [USER_LIB_CODE_AUDIT_20260904.md](USER_LIB_CODE_AUDIT_20260904.md) 📋 | **user/lib 代码审计与死代码清理**（2026-09-04，5 组只读审查 + 零行为清理 6 处；P0/P1/P2/P3 分级清单） |
| [SERVER_CODE_AUDIT_20260904.md](SERVER_CODE_AUDIT_20260904.md) 📋 | **云侧服务端只读体检**（2026-09-04，ota/patch/http/video 四服务 + 全仓凭据扫描；P0/P1/P2/P3 分级，未改码） |
| [USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md](USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md) 📋 | **user/lib 框架优化计划书**（拆分后治理版，08-31 冻结，阶段 C 进行中） |
| [OPTIMIZATION_PLAN.md](OPTIMIZATION_PLAN.md) 📋 | 逻辑架构优化计划（阶段 0–3 已落地；阶段 4 冻结） |
| [USER_LIB_OPTIMIZATION_NEXT.md](USER_LIB_OPTIMIZATION_NEXT.md) | 068 之后计划（074 拆分残留收口，活文档） |

## 记录 / 账本

| 文档 | 说明 |
|------|------|
| [USER_LIB_OPTIMIZATION_PLAN_20260830.md](USER_LIB_OPTIMIZATION_PLAN_20260830.md) 🗒 | 050–068 已做记录（访问器、事件表、去包装） |
| [CODE_SIZE_OPTIMIZATION.md](CODE_SIZE_OPTIMIZATION.md) 🗒 | 体积/表驱动瘦身记录（量产约 342KB/512KB） |
| [CODE_DOC_AUDIT.md](CODE_DOC_AUDIT.md) 🗒 | 代码↔文档核验流程与修订记录 |

> 历史缩写实验记录（旧符号）：见 `_audit/FUNCTION_NAME_MAP.md`（⚠ 只读，新符号引用上方 CAT1_API_NAMING）。
