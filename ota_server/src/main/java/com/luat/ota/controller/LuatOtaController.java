package com.luat.ota.controller;

import com.luat.ota.service.FirmwareService;
import com.luat.ota.service.FirmwareService.OtaRequest;
import com.luat.ota.service.FirmwareService.OtaResult;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.core.io.Resource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;

@RestController
public class LuatOtaController {

    private final FirmwareService firmwareService;

    public LuatOtaController(FirmwareService firmwareService) {
        this.firmwareService = firmwareService;
    }

    @GetMapping({"/api/site/firmware_upgrade", "/luat/update"})
    public ResponseEntity<Resource> firmwareUpgrade(
            @RequestParam(value = "project_key", required = false) String projectKey,
            @RequestParam(value = "imei", required = false) String imei,
            @RequestParam(value = "mac", required = false) String mac,
            @RequestParam(value = "uid", required = false) String uid,
            @RequestParam(value = "firmware_name", required = false) String firmwareName,
            @RequestParam(value = "version", required = false) String version,
            @RequestParam(value = "need_oss_url", required = false) Integer needOssUrl,
            HttpServletRequest request
    ) throws IOException {
        OtaRequest otaRequest = new OtaRequest(
                projectKey, imei, mac, uid, firmwareName, version, clientIp(request));
        OtaResult result = firmwareService.evaluate(otaRequest);

        return switch (result.decision()) {
            case UPGRADE -> ResponseEntity.ok()
                    .header(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_OCTET_STREAM_VALUE)
                    .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"update.bin\"")
                    .header("X-Ota-Target-Version", result.targetVersion() != null ? result.targetVersion() : "")
                    .header("X-Ota-Release-Id", result.releaseId() != null ? result.releaseId() : "")
                    .body(result.resource());
            case NO_UPDATE -> ResponseEntity.status(firmwareService.noUpdateStatus()).build();
            case FORBIDDEN -> ResponseEntity.status(HttpStatus.FORBIDDEN).build();
            case NOT_FOUND -> ResponseEntity.status(HttpStatus.NOT_FOUND).build();
        };
    }

    @GetMapping("/firmware/{filename}")
    public ResponseEntity<Resource> directDownload(@PathVariable String filename) throws IOException {
        return firmwareService.loadDirectFile(filename)
                .map(resource -> ResponseEntity.ok()
                        .header(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_OCTET_STREAM_VALUE)
                        .body(resource))
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @GetMapping("/health")
    public ResponseEntity<String> health() {
        return ResponseEntity.ok("ok");
    }

    private static String clientIp(HttpServletRequest request) {
        String forwarded = request.getHeader("X-Forwarded-For");
        if (forwarded != null && !forwarded.isBlank()) {
            return forwarded.split(",")[0].trim();
        }
        return request.getRemoteAddr();
    }
}
