package com.luat.ota.service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.luat.ota.config.MqttProperties;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.eclipse.paho.client.mqttv3.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * MQTT 桥接：订阅设备 1004 OTA 上行，下发 2004 OTA 触发（panshi 协议）。
 */
@Service
@ConditionalOnProperty(prefix = "luat.mqtt", name = "enabled", havingValue = "true")
public class MqttOtaBridgeService implements MqttCallback {

    private static final Logger log = LoggerFactory.getLogger(MqttOtaBridgeService.class);
    private static final Pattern IMEI_FROM_TOPIC = Pattern.compile("/panshi/app/([^/]+)/");

    private final MqttProperties props;
    private final ObjectMapper objectMapper;
    private final OtaTriggerService otaTriggerService;
    private MqttClient client;

    public MqttOtaBridgeService(MqttProperties props,
                                ObjectMapper objectMapper,
                                OtaTriggerService otaTriggerService) {
        this.props = props;
        this.objectMapper = objectMapper;
        this.otaTriggerService = otaTriggerService;
    }

    @PostConstruct
    public void start() {
        try {
            client = new MqttClient(props.brokerUri(), props.getClientId(), null);
            client.setCallback(this);
            client.connect(buildOptions());
            for (String topic : props.getSubscribeTopics()) {
                client.subscribe(topic, props.getQos());
                log.info("MQTT subscribed: {}", topic);
            }
            log.info("MQTT bridge connected: {}", props.brokerUri());
        } catch (Exception e) {
            log.error("MQTT bridge start failed", e);
        }
    }

    @PreDestroy
    public void stop() {
        if (client != null && client.isConnected()) {
            try {
                client.disconnect();
                client.close();
            } catch (Exception e) {
                log.warn("MQTT disconnect error", e);
            }
        }
    }

    public void publishDownlink(String imei, String jsonPayload) throws MqttException {
        ensureConnected();
        String topic = props.buildDownlinkTopic(imei);
        MqttMessage message = new MqttMessage(jsonPayload.getBytes(StandardCharsets.UTF_8));
        message.setQos(props.getQos());
        client.publish(topic, message);
        log.info("MQTT downlink imei={} topic={} payload={}", imei, topic, jsonPayload);
    }

    public boolean isConnected() {
        return client != null && client.isConnected();
    }

    @Override
    public void connectionLost(Throwable cause) {
        log.warn("MQTT connection lost: {}", cause != null ? cause.getMessage() : "unknown");
    }

    @Override
    public void messageArrived(String topic, MqttMessage message) {
        try {
            String payload = new String(message.getPayload(), StandardCharsets.UTF_8);
            String imei = extractImei(topic);
            if (imei == null) {
                log.debug("skip topic without imei: {}", topic);
                return;
            }
            Map<String, Object> body = objectMapper.readValue(payload, new TypeReference<>() {});
            otaTriggerService.handleMqttUplink(imei, body);
        } catch (Exception e) {
            log.warn("MQTT message handle failed topic={}", topic, e);
        }
    }

    @Override
    public void deliveryComplete(IMqttDeliveryToken token) {
        // no-op
    }

    private MqttConnectOptions buildOptions() {
        MqttConnectOptions options = new MqttConnectOptions();
        options.setAutomaticReconnect(true);
        options.setCleanSession(true);
        options.setConnectionTimeout(props.getConnectionTimeoutSec());
        options.setKeepAliveInterval(props.getKeepAliveSec());
        if (props.getUsername() != null && !props.getUsername().isBlank()) {
            options.setUserName(props.getUsername());
        }
        if (props.getPassword() != null && !props.getPassword().isBlank()) {
            options.setPassword(props.getPassword().toCharArray());
        }
        return options;
    }

    private void ensureConnected() throws MqttException {
        if (client == null) {
            throw new MqttException(MqttException.REASON_CODE_CLIENT_NOT_CONNECTED);
        }
        if (!client.isConnected()) {
            client.connect(buildOptions());
        }
    }

    static String extractImei(String topic) {
        Matcher m = IMEI_FROM_TOPIC.matcher(topic);
        return m.find() ? m.group(1) : null;
    }
}
