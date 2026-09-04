# T31 → T31X 文档迁移索引

根目录下的 `T31_*.md` 重定向桩**已删除**；书签或外部链接请改用下表「现行文档」。
命名沿革：`T31` → `T3X`（本索引旧版）→ 统一为 **`T31X`**；现行写法与代码真名以
[T31X_NAMING.md](../overview/T31X_NAMING.md) 为准。

| 旧文档名 | 现行文档 |
|----------|----------|
| `T31_BURN_MODE.md` | [T31X_BURN_MODE.md](../hardware/T31X_BURN_MODE.md) |
| `T31_CAT1_GPIO.md` | [T31X_CAT1_GPIO.md](../hardware/T31X_CAT1_GPIO.md) |
| `T31_4G_FRAMEWORK.md` | [T31X_4G_FRAMEWORK.md](../t31x/T31X_4G_FRAMEWORK.md) |
| `T31_4G_AT_INTERACTION.md` | [T31X_4G_AT_INTERACTION.md](../t31x/T31X_4G_AT_INTERACTION.md) |
| `T31_CAT1_AT_COMMAND_SPEC.md` | [T31X_CAT1_AT_COMMAND_SPEC.md](../t31x/T31X_CAT1_AT_COMMAND_SPEC.md) |
| `T31_WAKE_PROTOCOL.md` | [T31X_HOSTEVT_PROTOCOL.md](../t31x/T31X_HOSTEVT_PROTOCOL.md) |

代码与 `require` 统一使用 **snake_case** 系列名：`t31x_ctrl`、`t31x_policy`
（`t3x` 平台/芯片语境与 `t31x_*` 系列模块的边界见命名文档 §3）。
