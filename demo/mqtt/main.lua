--[[
@module  main
@summary MQTT 消息订阅/发布示例 / MQTT pub/sub demo
@version 1.0
@date    2026.06.30
@usage
本 demo 演示 LuatOS MQTT 功能：
  - 等待网络就绪
  - 连接到公共 MQTT Broker
  - 订阅主题并每隔 5 秒发布一条消息
  - 收到消息后通过日志打印
]]

PROJECT = "AIR780EHM_mqtt"
VERSION = "001.999.001"

log.info("main", PROJECT, VERSION)

-- MQTT Broker 配置（使用公共测试 Broker，生产环境请替换为自己的 Broker）
local BROKER_HOST = "lbsmqtt.airm2m.com"
local BROKER_PORT = 1884
local CLIENT_ID   = "AIR780EHM_" .. (mcu.unique_id() and mcu.unique_id():toHex() or "demo")
local SUB_TOPIC   = "/air780ehm/sub"
local PUB_TOPIC   = "/air780ehm/pub"

sys.taskInit(function()
    -- 等待移动网络注册成功
    sys.waitUntil("IP_READY", 60000)
    log.info("mqtt", "network ready, connecting to broker...")

    local mqttc = mqtt.create(nil, BROKER_HOST, BROKER_PORT)
    mqttc:auth(CLIENT_ID)        -- 使用 Client ID 连接（无需用户名/密码）
    mqttc:keepalive(30)

    -- 注册事件回调
    mqttc:on(function(mqtt_client, event, data, payload)
        if event == "conack" then
            log.info("mqtt", "connected to broker")
            -- 连接成功后订阅主题
            mqtt_client:subscribe(SUB_TOPIC)
        elseif event == "recv" then
            log.info("mqtt", "received message on", data, "payload:", payload)
        elseif event == "sent" then
            log.info("mqtt", "message published")
        elseif event == "disconnect" then
            log.warn("mqtt", "disconnected from broker")
        end
    end)

    -- 连接 Broker
    mqttc:connect()

    -- 每隔 5 秒发布一条消息
    local count = 0
    while true do
        sys.wait(5000)
        count = count + 1
        local payload = string.format('{"device":"AIR780EHM","count":%d}', count)
        if mqttc:connected() then
            mqttc:publish(PUB_TOPIC, payload, 1)
            log.info("mqtt", "published:", payload)
        else
            log.warn("mqtt", "not connected, skipping publish")
        end
    end
end)

sys.run()
