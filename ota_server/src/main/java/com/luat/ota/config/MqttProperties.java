package com.luat.ota.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.ArrayList;
import java.util.List;

@ConfigurationProperties(prefix = "luat.mqtt")
public class MqttProperties {

    private boolean enabled = false;
    private String host = "127.0.0.1";
    private int port = 1883;
    private boolean ssl = false;
    private String username = "";
    private String password = "";
    private String clientId = "ota-server-bridge";
    private int connectionTimeoutSec = 30;
    private int keepAliveSec = 60;
    private int qos = 1;
    /** 订阅设备上行，默认 panshi 协议 /panshi/app/{imei}/event */
    private List<String> subscribeTopics = new ArrayList<>(List.of("/panshi/app/+/event"));
    /** 下行模板，{imei} 占位 */
    private String downlinkTopicTemplate = "/panshi/device/{imei}/";
    /** 设备访问 OTA 的公网 HTTPS 基址，如 https://ota.example.com */
    private String otaPublicBaseUrl = "http://127.0.0.1:8080";
    /** libfota2 拼参路径 */
    private String otaPath = "/api/site/firmware_upgrade?";
    private long otaTimeoutMs = 300000;

    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }
    public String getHost() { return host; }
    public void setHost(String host) { this.host = host; }
    public int getPort() { return port; }
    public void setPort(int port) { this.port = port; }
    public boolean isSsl() { return ssl; }
    public void setSsl(boolean ssl) { this.ssl = ssl; }
    public String getUsername() { return username; }
    public void setUsername(String username) { this.username = username; }
    public String getPassword() { return password; }
    public void setPassword(String password) { this.password = password; }
    public String getClientId() { return clientId; }
    public void setClientId(String clientId) { this.clientId = clientId; }
    public int getConnectionTimeoutSec() { return connectionTimeoutSec; }
    public void setConnectionTimeoutSec(int connectionTimeoutSec) { this.connectionTimeoutSec = connectionTimeoutSec; }
    public int getKeepAliveSec() { return keepAliveSec; }
    public void setKeepAliveSec(int keepAliveSec) { this.keepAliveSec = keepAliveSec; }
    public int getQos() { return qos; }
    public void setQos(int qos) { this.qos = qos; }
    public List<String> getSubscribeTopics() { return subscribeTopics; }
    public void setSubscribeTopics(List<String> subscribeTopics) { this.subscribeTopics = subscribeTopics; }
    public String getDownlinkTopicTemplate() { return downlinkTopicTemplate; }
    public void setDownlinkTopicTemplate(String downlinkTopicTemplate) { this.downlinkTopicTemplate = downlinkTopicTemplate; }
    public String getOtaPublicBaseUrl() { return otaPublicBaseUrl; }
    public void setOtaPublicBaseUrl(String otaPublicBaseUrl) { this.otaPublicBaseUrl = otaPublicBaseUrl; }
    public String getOtaPath() { return otaPath; }
    public void setOtaPath(String otaPath) { this.otaPath = otaPath; }
    public long getOtaTimeoutMs() { return otaTimeoutMs; }
    public void setOtaTimeoutMs(long otaTimeoutMs) { this.otaTimeoutMs = otaTimeoutMs; }

    public String buildOtaUrl() {
        String base = otaPublicBaseUrl.endsWith("/")
                ? otaPublicBaseUrl.substring(0, otaPublicBaseUrl.length() - 1)
                : otaPublicBaseUrl;
        return base + otaPath;
    }

    public String buildDownlinkTopic(String imei) {
        return downlinkTopicTemplate.replace("{imei}", imei);
    }

    public String brokerUri() {
        return (ssl ? "ssl://" : "tcp://") + host + ":" + port;
    }
}
