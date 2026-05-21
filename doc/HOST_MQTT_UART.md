# T31 → 4G MQTT 配置（UART）

MQTT Broker 参数由 **t31_linux** 的 `client.ini` / `client.json` 维护，上电 `bootstrap` 时经串口下发给 Air780，4G 解析后更新 `_G.MQTT_CFG` 并启动/重启 MQTT。

两种产品策略（等 T31 / 上电自动连 + 覆盖）见 [MQTT_HOST_CONFIG_MODES.md](MQTT_HOST_CONFIG_MODES.md)。

## 命令格式

```text
AT+MQTTCFG=<host>;<port>;<ssl>;<username>;<password>;<client_id>
```

| 字段 | 说明 |
|------|------|
| host | Broker 地址 |
| port | 端口，默认 1883 |
| ssl | `0` 明文 / `1` TLS |
| username / password | 鉴权；**密码勿含 `;`** |
| client_id | 空则 4G 使用 IMEI |

成功应答：

```text
+MQTTCFG:OK
OK
```

## t31_linux 配置示例

`client.ini`：

```ini
[mqtt]
mqtt_host=112.86.146.218
mqtt_port=2123
mqtt_ssl=0
mqtt_username=fptop1
mqtt_password=your_password
mqtt_client_id=
```

## 4G 侧流程

1. `host_uart` 解析 `AT+MQTTCFG` → `on_mqtt_cfg`
2. `app` → `net.setMqttConfig` + `net.restart()`（已运行）或 `startMqtt()`
3. `net.mqttTask` 使用更新后的 `_G.MQTT_CFG` 连接

4G 上电使用 `config.lua` 的 `MQTT_CFG` **自动连接**；T31 在 `client.ini [mqtt]` 维护参数，`bootstrap` 或异常恢复时发 `AT+MQTTCFG` **覆盖** `_G.MQTT_CFG` 并 `net.restart()` 重连新 Broker。

## 唤醒重建

`evt=1/2/3`（TCP/MQTT 异常）时 t31_linux 会重建 `SERVCREATE` 并再次 `AT+MQTTCFG`。
