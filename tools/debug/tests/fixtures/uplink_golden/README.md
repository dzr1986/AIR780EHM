# 上行 JSON 黄金样本（架构 G 条，需真机）

由 `python tools/debug/_uplink_golden_capture.py <秒数>` 在真机 `MQTT_CFG.golden_tap = true` 时采集，每个 `dataType` 一份 `<dataType>.json`。
`_uplink_schema_check.py` 会自动读取并校验「真机键集 ⊆ 代码可发字段」；P8 字段表序列化若实施，以此逐字节比对。

目录为空时护栏跳过样本比对（只打印提示）。采完请连同 VERSION 一起提交。
