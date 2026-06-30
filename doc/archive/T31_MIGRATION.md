# T31 → T3X 文档迁移索引

协处理器系列已从 **T31** 统一更名为 **T3X**（见 [T3X_NAMING.md](../T3X_NAMING.md)）。  
根目录下的 `T31_*.md` 重定向桩**已删除**；书签或外部链接请改用下表「现行文档」。

| 旧文档名 | 现行文档 |
|----------|----------|
| `T31_BURN_MODE.md` | [T3X_BURN_MODE.md](../T3X_BURN_MODE.md) |
| `T31_CAT1_GPIO.md` | [T3X_CAT1_GPIO.md](../T3X_CAT1_GPIO.md) |
| `T31_4G_FRAMEWORK.md` | [T3X_4G_FRAMEWORK.md](../T3X_4G_FRAMEWORK.md) |
| `T31_4G_AT_INTERACTION.md` | [T3X_4G_AT_INTERACTION.md](../T3X_4G_AT_INTERACTION.md) |
| `T31_CAT1_AT_COMMAND_SPEC.md` | [T3X_CAT1_AT_COMMAND_SPEC.md](../T3X_CAT1_AT_COMMAND_SPEC.md) |
| `T31_WAKE_PROTOCOL.md` | [T3X_HOSTEVT_PROTOCOL.md](../T3X_HOSTEVT_PROTOCOL.md) |

代码与 `require` 统一使用 **snake_case**：`t3x_ctrl`、`t3x_policy`（原 `t3x_ipc` 已合并进 `t3x_ctrl`）。
