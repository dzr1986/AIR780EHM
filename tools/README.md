# tools

**日常请只进 [`gui/`](gui/README.md)**，双击三个 bat 即可。

| 目录 | 用途 |
|------|------|
| **gui/** | 三个图形界面（流程检测 / Cat.1 烧录 / MQTT 测试） |
| **pack_mass_prod.py** | 量产交付：`python tools/pack_mass_prod.py 001.000.036` 生成 `{日期}_量产/`（固件 + 烧录工具） |
| t31x/ | 把编译好的 ipc 经 COM7 推到 T31 |
| debug/ | 静态护栏（`run_all_checks.py` 一键 10 项；词法器 `_luatok.py`；自测 `tests/`）+ 一次性串口/MQTT 脚本 |
| agentboot/ | 烧录用 AgentBoot |
| _logs/ | 检测软件会话日志 |
