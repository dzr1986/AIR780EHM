package com.luat.ota.controller;

import com.luat.ota.entity.Device;
import com.luat.ota.service.DeviceService;
import com.luat.ota.service.IpcDemoClient;
import com.luat.ota.service.IpcPackService;
import com.luat.ota.util.ImeiListParser;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** IPC 升级管理：按 IMEI 绑定 Cat.1 设备后上传、下发、看状态。 */
@RestController
@RequestMapping("/admin/api/ipc")
public class IpcAdminController {

    private final IpcPackService packService;
    private final IpcDemoClient demo;
    private final DeviceService deviceService;

    public IpcAdminController(IpcPackService packService, IpcDemoClient demo, DeviceService deviceService) {
        this.packService = packService;
        this.demo = demo;
        this.deviceService = deviceService;
    }

    @GetMapping("/status")
    public Map<String, Object> status(@RequestParam(value = "imei", required = false) String imei) throws Exception {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("ok", true);
        out.put("url", packService.publicTarUrl());
        out.put("jsonUrl", packService.publicJsonUrl());
        out.put("packages", packService.listPackages());
        out.put("devices", deviceService.listIpcViews());
        if (imei != null && !imei.isBlank()) {
            String id = ImeiListParser.requireValid(imei).get(0);
            Device device = deviceService.ensureByImei(id);
            out.put("selected", deviceService.ipcView(device));
        }
        try {
            out.put("demo", demo.status());
        } catch (Exception e) {
            out.put("deviceError", e.getMessage());
        }
        return out;
    }

    @GetMapping("/devices")
    public Map<String, Object> devices() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("devices", deviceService.listIpcViews());
        return out;
    }

    @PutMapping("/devices/{imei}/enabled")
    public Map<String, Object> setEnabled(@PathVariable String imei, @RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> req = body == null ? Map.of() : body;
        boolean enabled = Boolean.TRUE.equals(req.get("enabled")) || Boolean.TRUE.equals(req.get("ipcEnabled"));
        Device device = deviceService.setIpcEnabled(imei, enabled);
        return deviceService.ipcView(device);
    }

    @PostMapping("/devices/batch")
    public Map<String, Object> batch(@RequestBody Map<String, Object> body) {
        String action = String.valueOf(body == null ? "" : body.getOrDefault("action", "")).trim().toLowerCase();
        List<String> imeis = ImeiListParser.requireValid(body == null ? null : body.get("imeis"));
        if ("enable".equals(action) || "allow".equals(action)) {
            return deviceService.batchIpcEnabled(true, imeis);
        }
        if ("disable".equals(action) || "forbid".equals(action) || "deny".equals(action)) {
            return deviceService.batchIpcEnabled(false, imeis);
        }
        throw new IllegalArgumentException("action 须为 enable 或 disable");
    }

    @PostMapping(value = "/upload", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public Map<String, Object> upload(
            @RequestParam("file") MultipartFile file,
            @RequestParam(value = "version", required = false) String version,
            @RequestParam(value = "imei", required = false) String imei) throws Exception {
        Map<String, Object> pkg = packService.storeUpload(file, version);
        if (imei != null && !imei.isBlank()) {
            String id = ImeiListParser.requireValid(imei).get(0);
            deviceService.ensureByImei(id);
            pkg.put("imei", id);
        }
        return pkg;
    }

    @PostMapping("/upgrade")
    public Map<String, Object> upgrade(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> req = body == null ? new LinkedHashMap<>() : new LinkedHashMap<>(body);
        String version = String.valueOf(req.getOrDefault("version", "")).trim();
        if (version.isEmpty() || "null".equals(version)) {
            throw new IllegalArgumentException("version 必填");
        }
        String imei = ImeiListParser.requireValid(req.get("imei")).get(0);
        String url = String.valueOf(req.getOrDefault("url", "")).trim();
        if (url.isEmpty() || "null".equals(url)) {
            url = packService.publicTarUrl();
        }
        String sessionId = String.valueOf(req.getOrDefault("sessionId", "")).trim();
        if (sessionId.isEmpty() || "null".equals(sessionId)) {
            sessionId = "upg-web-" + UUID.randomUUID().toString().replace("-", "").substring(0, 8);
        }
        req.put("imei", imei);
        req.put("url", url);
        req.put("FileUrl", url);
        req.putIfAbsent("filename", "ipc.tar");
        req.putIfAbsent("deviceId", "T31-X86-DEMO");
        req.put("sessionId", sessionId);
        deviceService.markIpcPending(imei, version, sessionId);
        Map<String, Object> acc = demo.upgrade(req);
        acc.put("imei", imei);
        acc.put("sessionId", acc.getOrDefault("sessionId", sessionId));
        return acc;
    }

    @GetMapping("/tasks/{sessionId}")
    public Map<String, Object> task(
            @PathVariable String sessionId,
            @RequestParam(value = "imei", required = false) String imei
    ) {
        Map<String, Object> task = demo.task(sessionId);
        if (imei != null && !imei.isBlank()) {
            String id = ImeiListParser.requireValid(imei).get(0);
            String stage = String.valueOf(task.getOrDefault("stage", ""));
            String ver = String.valueOf(task.getOrDefault("deviceVersion",
                    task.getOrDefault("version", "")));
            if ("null".equals(ver)) {
                ver = "";
            }
            Device device = deviceService.markIpcResult(id, stage, ver);
            task.put("imei", id);
            task.put("deviceRecord", deviceService.ipcView(device));
        }
        return task;
    }

    @GetMapping("/file/{name}")
    public ResponseEntity<byte[]> download(@PathVariable String name) throws Exception {
        byte[] data = packService.readFile(name);
        MediaType type = "ipc.json".equals(name) ? MediaType.APPLICATION_JSON : MediaType.APPLICATION_OCTET_STREAM;
        return ResponseEntity.ok()
                .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"" + name + "\"")
                .contentType(type)
                .body(data);
    }
}
