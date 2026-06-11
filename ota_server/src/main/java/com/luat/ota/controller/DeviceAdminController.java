package com.luat.ota.controller;

import com.luat.ota.config.MqttProperties;
import com.luat.ota.dto.OtaTriggerRequest;
import com.luat.ota.entity.Device;
import com.luat.ota.entity.OtaTask;
import com.luat.ota.service.DeviceService;
import com.luat.ota.service.OtaTriggerService;
import com.luat.ota.service.OtaTriggerService.TriggerResult;
import org.springframework.http.ResponseEntity;
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
    public List<Device> listDevices() {
        return deviceService.listAll();
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
    public List<OtaTask> otaTasks() {
        return otaTriggerService.recentTasks();
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
