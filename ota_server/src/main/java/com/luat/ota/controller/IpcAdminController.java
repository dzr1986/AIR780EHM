package com.luat.ota.controller;

import com.luat.ota.service.IpcDemoClient;
import com.luat.ota.service.IpcPackService;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/** IPC 升级管理：登录后上传、下发、看状态。 */
@RestController
@RequestMapping("/admin/api/ipc")
public class IpcAdminController {

    private final IpcPackService packService;
    private final IpcDemoClient demo;

    public IpcAdminController(IpcPackService packService, IpcDemoClient demo) {
        this.packService = packService;
        this.demo = demo;
    }

    @GetMapping("/status")
    public Map<String, Object> status() throws Exception {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("ok", true);
        out.put("url", packService.publicTarUrl());
        out.put("jsonUrl", packService.publicJsonUrl());
        out.put("packages", packService.listPackages());
        try {
            out.put("device", demo.status());
        } catch (Exception e) {
            out.put("deviceError", e.getMessage());
        }
        return out;
    }

    @PostMapping(value = "/upload", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public Map<String, Object> upload(
            @RequestParam("file") MultipartFile file,
            @RequestParam(value = "version", required = false) String version) throws Exception {
        return packService.storeUpload(file, version);
    }

    @PostMapping("/upgrade")
    public Map<String, Object> upgrade(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> req = body == null ? new LinkedHashMap<>() : new LinkedHashMap<>(body);
        String version = String.valueOf(req.getOrDefault("version", "")).trim();
        if (version.isEmpty() || "null".equals(version)) {
            throw new IllegalArgumentException("version 必填");
        }
        String url = String.valueOf(req.getOrDefault("url", "")).trim();
        if (url.isEmpty() || "null".equals(url)) {
            url = packService.publicTarUrl();
        }
        req.put("url", url);
        req.put("FileUrl", url);
        req.putIfAbsent("filename", "ipc.tar");
        req.putIfAbsent("deviceId", "T31-X86-DEMO");
        req.putIfAbsent("sessionId", "upg-web-" + UUID.randomUUID().toString().replace("-", "").substring(0, 8));
        return demo.upgrade(req);
    }

    @GetMapping("/tasks/{sessionId}")
    public Map<String, Object> task(@PathVariable String sessionId) {
        return demo.task(sessionId);
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
