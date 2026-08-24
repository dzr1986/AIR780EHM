package com.luat.ota.controller;

import com.luat.ota.dto.LoopTestRequest;
import com.luat.ota.service.LoopTestService;
import com.luat.ota.service.OtaTriggerService;
import org.springframework.http.MediaType;
import org.springframework.util.StringUtils;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

@RestController
@RequestMapping("/admin/api")
public class LoopTestController {

    private final LoopTestService loopTestService;
    private final OtaTriggerService triggerService;

    public LoopTestController(LoopTestService loopTestService, OtaTriggerService triggerService) {
        this.loopTestService = loopTestService;
        this.triggerService = triggerService;
    }

    @PostMapping("/loop-test/prepare")
    public Map<String, Object> prepare(@RequestBody(required = false) LoopTestRequest request) throws IOException {
        return loopTestService.prepare(request == null ? new LoopTestRequest() : request);
    }

    @PostMapping(value = "/loop-test/prepare-upload", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public Map<String, Object> prepareUpload(
            @RequestParam("file") MultipartFile file,
            @RequestParam(required = false) String imei,
            @RequestParam(required = false) String projectKey,
            @RequestParam(required = false) String firmwareName,
            @RequestParam(required = false) String sourceVersion,
            @RequestParam(required = false) String targetVersion
    ) throws IOException {
        LoopTestRequest request = new LoopTestRequest();
        request.setFirmwareName(null);
        request.setSourceVersion(null);
        request.setTargetVersion(null);
        if (StringUtils.hasText(imei)) {
            request.setImei(imei);
        }
        if (StringUtils.hasText(projectKey)) {
            request.setProjectKey(projectKey);
        }
        if (StringUtils.hasText(firmwareName)) {
            request.setFirmwareName(firmwareName);
        }
        if (StringUtils.hasText(sourceVersion)) {
            request.setSourceVersion(sourceVersion);
        }
        if (StringUtils.hasText(targetVersion)) {
            request.setTargetVersion(targetVersion);
        }
        return loopTestService.prepareFromUpload(request, file);
    }

    @GetMapping("/loop-test/status")
    public Map<String, Object> status(@RequestParam(required = false) String imei) {
        return loopTestService.status(imei);
    }

    /**
     * 模拟设备 MQTT 1004 上行（与 Broker 订阅同一套处理）。
     */
    @PostMapping("/ota/uplink")
    public Map<String, Object> uplink(@RequestBody Map<String, Object> body) {
        Object imeiObj = body.get("imei");
        String imei = imeiObj == null ? null : String.valueOf(imeiObj);
        if (!StringUtils.hasText(imei)) {
            throw new IllegalArgumentException("imei required");
        }
        triggerService.handleMqttUplink(imei.trim(), body);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("ok", true);
        result.put("imei", imei.trim());
        return result;
    }
}
