package com.luat.ota.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.luat.ota.config.MqttProperties;
import com.luat.ota.entity.OtaTask;
import com.luat.ota.entity.OtaTaskStatus;
import com.luat.ota.repository.OtaTaskRepository;
import org.springframework.context.annotation.Lazy;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

import java.time.Instant;
import java.util.*;

@Service
public class OtaTriggerService {

    private final MqttProperties mqttProperties;
    private final DeviceService deviceService;
    private final OtaTaskRepository taskRepository;
    private final ObjectMapper objectMapper;
    private final MqttOtaBridgeService mqttBridge;

    public OtaTriggerService(MqttProperties mqttProperties,
                             DeviceService deviceService,
                             OtaTaskRepository taskRepository,
                             ObjectMapper objectMapper,
                             @Lazy MqttOtaBridgeService mqttBridge) {
        this.mqttProperties = mqttProperties;
        this.deviceService = deviceService;
        this.taskRepository = taskRepository;
        this.objectMapper = objectMapper;
        this.mqttBridge = mqttBridge;
    }

    public record TriggerResult(String imei, String messageId, OtaTaskStatus status, String detail) {
    }

    public List<OtaTask> recentTasks() {
        return taskRepository.findTop100ByOrderByCreatedAtDesc();
    }

    @Transactional
    public List<TriggerResult> trigger(List<String> imeis, String targetVersion, String source) {
        if (!StringUtils.hasText(targetVersion)) {
            throw new IllegalArgumentException("targetVersion required");
        }
        if (imeis == null || imeis.isEmpty()) {
            throw new IllegalArgumentException("imeis required");
        }
        if (!mqttProperties.isEnabled()) {
            throw new IllegalStateException("MQTT bridge disabled (set luat.mqtt.enabled=true)");
        }

        List<TriggerResult> results = new ArrayList<>();
        String normalizedTarget = targetVersion.trim();

        for (String imei : imeis) {
            if (!StringUtils.hasText(imei)) {
                continue;
            }
            String trimmedImei = imei.trim();
            try {
                TriggerResult result = triggerOne(mqttBridge, trimmedImei, normalizedTarget, source);
                results.add(result);
            } catch (Exception ex) {
                results.add(new TriggerResult(trimmedImei, null, OtaTaskStatus.FAILED, ex.getMessage()));
            }
        }
        return results;
    }

    @Transactional
    public List<TriggerResult> triggerOutdated(String targetVersion, String source) {
        List<String> imeis = deviceService.findOutdatedDevices(targetVersion).stream()
                .map(d -> d.getImei())
                .toList();
        return trigger(imeis, targetVersion, source);
    }

    private TriggerResult triggerOne(MqttOtaBridgeService bridge, String imei,
                                     String targetVersion, String source) throws Exception {
        deviceService.markOtaPending(imei, targetVersion);

        String messageId = "ota-srv-" + UUID.randomUUID().toString().substring(0, 8);
        String otaUrl = mqttProperties.buildOtaUrl();

        OtaTask task = new OtaTask();
        task.setImei(imei);
        task.setMessageId(messageId);
        task.setTargetVersion(targetVersion);
        task.setOtaUrl(otaUrl);
        task.setTriggerSource(source != null ? source : "ADMIN");
        task.setStatus(OtaTaskStatus.PENDING);
        taskRepository.save(task);

        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("dataType", "2004");
        payload.put("action", "ota");
        payload.put("url", otaUrl);
        payload.put("version", targetVersion);
        payload.put("timeout", mqttProperties.getOtaTimeoutMs());
        payload.put("full_url", 0);
        payload.put("messageId", messageId);

        String json = objectMapper.writeValueAsString(payload);
        bridge.publishDownlink(imei, json);

        task.setStatus(OtaTaskStatus.PUBLISHED);
        taskRepository.save(task);

        return new TriggerResult(imei, messageId, OtaTaskStatus.PUBLISHED, "mqtt published");
    }

    @Transactional
    public void handleMqttUplink(String imei, Map<String, Object> body) {
        String dataType = stringVal(body.get("dataType"));
        if (!"1004".equals(dataType)) {
            return;
        }

        String messageId = stringVal(body.get("messageId"));
        String action = stringVal(body.get("action"));
        String stage = stringVal(body.get("stage"));
        Integer ret = intVal(body.get("ret"));
        String message = stringVal(body.get("message"));
        String currentVersion = stringVal(body.get("currentVersion"));
        String targetVersion = stringVal(body.get("targetVersion"));

        deviceService.updateFromMqttEvent(imei, stage, ret, message, currentVersion, targetVersion);

        OtaTask task = null;
        if (StringUtils.hasText(messageId)) {
            task = taskRepository.findByMessageId(messageId).orElse(null);
        }
        if (task == null) {
            task = taskRepository.findFirstByImeiAndStatusInOrderByCreatedAtDesc(imei, List.of(
                    OtaTaskStatus.PUBLISHED, OtaTaskStatus.ACCEPTED, OtaTaskStatus.IN_PROGRESS
            )).orElse(null);
        }
        if (task == null) {
            return;
        }

        if (body.containsKey("reply") && "ota".equalsIgnoreCase(action)) {
            task.setStatus(ret != null && ret == 0 ? OtaTaskStatus.ACCEPTED : OtaTaskStatus.FAILED);
            task.setLastRet(ret);
            task.setLastMessage(message);
            if (ret != null && ret != 0) {
                task.setErrorMessage(message);
                task.setCompletedAt(Instant.now());
            }
        }

        if (StringUtils.hasText(stage)) {
            task.setLastStage(stage);
            task.setLastRet(ret);
            task.setLastMessage(message);
            if ("starting".equals(stage) || "downloading".equals(stage) || "checking".equals(stage)) {
                task.setStatus(OtaTaskStatus.IN_PROGRESS);
            } else if ("success".equals(stage) && (ret == null || ret == 0)) {
                task.setStatus(OtaTaskStatus.SUCCESS);
                task.setCompletedAt(Instant.now());
            } else if ("failed".equals(stage) || (ret != null && ret < 0)) {
                task.setStatus(OtaTaskStatus.FAILED);
                task.setErrorMessage(message);
                task.setCompletedAt(Instant.now());
            }
        }
        taskRepository.save(task);
    }

    private static String stringVal(Object v) {
        return v == null ? null : String.valueOf(v);
    }

    private static Integer intVal(Object v) {
        if (v == null) {
            return null;
        }
        if (v instanceof Number n) {
            return n.intValue();
        }
        try {
            return Integer.parseInt(String.valueOf(v));
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
