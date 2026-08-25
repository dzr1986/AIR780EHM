package com.luat.ota.controller;

import com.luat.ota.config.MqttProperties;
import com.luat.ota.dto.OtaTriggerRequest;
import com.luat.ota.entity.Device;
import com.luat.ota.entity.OtaTask;
import com.luat.ota.entity.OtaTaskStatus;
import com.luat.ota.service.DeviceService;
import com.luat.ota.service.OtaTriggerService;
import com.luat.ota.service.OtaTriggerService.TriggerResult;
import org.springframework.data.domain.Page;
import org.springframework.http.ResponseEntity;
import org.springframework.util.StringUtils;
import org.springframework.web.bind.annotation.*;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

@RestController
@RequestMapping("/admin/api")
public class DeviceAdminController {

    private final DeviceService deviceService;
    private final OtaTriggerService otaTriggerService;
    private final MqttProperties mqttProperties;
    private final Optional<com.luat.ota.service.MqttOtaBridgeService> mqttBridge;

    public DeviceAdminController(DeviceService deviceService,
                                 OtaTriggerService otaTriggerService,
                                 MqttProperties mqttProperties,
                                 Optional<com.luat.ota.service.MqttOtaBridgeService> mqttBridge) {
        this.deviceService = deviceService;
        this.otaTriggerService = otaTriggerService;
        this.mqttProperties = mqttProperties;
        this.mqttBridge = mqttBridge;
    }

    @GetMapping("/devices")
    public List<Device> listDevices(
            @RequestParam(required = false) String imei,
            @RequestParam(required = false) String projectKey,
            @RequestParam(required = false) Boolean otaEnabled
    ) {
        return deviceService.list(imei, projectKey, otaEnabled);
    }

    @PutMapping("/devices/{imei}/ota-enabled")
    public Device setOtaEnabled(@PathVariable String imei, @RequestBody Map<String, Object> body) {
        boolean enabled = true;
        if (body.containsKey("enabled")) {
            enabled = Boolean.TRUE.equals(body.get("enabled"));
        } else if (body.containsKey("otaEnabled")) {
            enabled = Boolean.TRUE.equals(body.get("otaEnabled"));
        }
        return deviceService.setOtaEnabled(imei, enabled);
    }

    @PutMapping("/devices/{imei}/debug")
    public Device setDebugEnabled(@PathVariable String imei, @RequestBody Map<String, Object> body) {
        boolean enabled = Boolean.TRUE.equals(body.get("enabled")) || Boolean.TRUE.equals(body.get("debugEnabled"));
        return deviceService.setDebugEnabled(imei, enabled);
    }

    @GetMapping("/devices/{imei}")
    public ResponseEntity<Device> getDevice(@PathVariable String imei) {
        return deviceService.findByImei(imei)
                .map(ResponseEntity::ok)
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @PostMapping("/devices")
    public Device createOrUpdate(@RequestBody Device device) {
        return deviceService.upsert(device);
    }

    @DeleteMapping("/devices/{imei}")
    public ResponseEntity<Void> deleteDevice(@PathVariable String imei) {
        deviceService.deleteByImei(imei);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/ota/tasks")
    public Map<String, Object> otaTasks(
            @RequestParam(required = false) String imei,
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size
    ) {
        OtaTaskStatus parsed = null;
        if (StringUtils.hasText(status)) {
            try {
                parsed = OtaTaskStatus.valueOf(status.trim().toUpperCase());
            } catch (IllegalArgumentException ex) {
                throw new IllegalArgumentException("unknown task status: " + status);
            }
        }
        Page<OtaTask> result = otaTriggerService.pageTasks(imei, parsed, page, size);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("content", result.getContent());
        body.put("page", result.getNumber());
        body.put("size", result.getSize());
        body.put("totalElements", result.getTotalElements());
        body.put("totalPages", result.getTotalPages());
        return body;
    }

    @GetMapping("/mqtt/status")
    public Map<String, Object> mqttStatus() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("enabled", mqttProperties.isEnabled());
        body.put("broker", mqttProperties.brokerUri());
        body.put("connected", mqttBridge.map(com.luat.ota.service.MqttOtaBridgeService::isConnected).orElse(false));
        body.put("otaPublicUrl", mqttProperties.buildOtaUrl());
        return body;
    }

    @PostMapping("/ota/trigger")
    public List<TriggerResult> triggerOta(@RequestBody OtaTriggerRequest request) {
        return otaTriggerService.trigger(request.getImeis(), request.getTargetVersion(), "ADMIN");
    }

    @PostMapping("/ota/trigger/outdated")
    public List<TriggerResult> triggerOutdated(@RequestBody OtaTriggerRequest request) {
        return otaTriggerService.triggerOutdated(request.getTargetVersion(), "BATCH");
    }
}
