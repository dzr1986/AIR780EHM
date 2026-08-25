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
    public ResponseEntity<?> firmwareUpgrade(
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
            case UPGRADE -> binaryPackage(result, request);
            case NO_UPDATE -> ResponseEntity.status(firmwareService.noUpdateStatus()).build();
            case FORBIDDEN -> ResponseEntity.status(HttpStatus.FORBIDDEN)
                    .header("X-Ota-Error-Code", "25")
                    .build();
            case INVALID_PROJECT -> ResponseEntity.status(HttpStatus.BAD_REQUEST)
                    .header("X-Ota-Error-Code", "26")
                    .build();
            case INVALID_FIRMWARE -> ResponseEntity.status(HttpStatus.BAD_REQUEST)
                    .header("X-Ota-Error-Code", "27")
                    .build();
            case NOT_FOUND -> ResponseEntity.status(HttpStatus.NOT_FOUND).build();
        };
    }

    @GetMapping("/firmware/{filename}")
    public ResponseEntity<Resource> directDownload(@PathVariable String filename) throws IOException {
        var loaded = firmwareService.loadDirectFile(filename);
        if (loaded.isEmpty() || loaded.get().contentLength() <= 0) {
            return ResponseEntity.notFound().build();
        }
        Resource resource = loaded.get();
        return ResponseEntity.ok()
                .header(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_OCTET_STREAM_VALUE)
                .header(HttpHeaders.CONTENT_LENGTH, String.valueOf(resource.contentLength()))
                .header(HttpHeaders.ACCEPT_RANGES, "bytes")
                .body(resource);
    }

    @GetMapping("/health")
    public ResponseEntity<String> health() {
        return ResponseEntity.ok("ok");
    }

    private ResponseEntity<?> binaryPackage(OtaResult result, HttpServletRequest request) throws IOException {
        Resource resource = result.resource();
        long length = resource == null ? -1 : resource.contentLength();
        if (resource == null || length <= 0) {
            return ResponseEntity.status(firmwareService.noUpdateStatus()).build();
        }
        HttpHeaders headers = new HttpHeaders();
        headers.set(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_OCTET_STREAM_VALUE);
        headers.set(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"update.bin\"");
        headers.set(HttpHeaders.ACCEPT_RANGES, "bytes");
        headers.set("X-Ota-Target-Version", result.targetVersion() != null ? result.targetVersion() : "");
        headers.set("X-Ota-Release-Id", result.releaseId() != null ? result.releaseId() : "");

        String rangeHeader = request.getHeader(HttpHeaders.RANGE);
        if (rangeHeader != null && rangeHeader.startsWith("bytes=")) {
            long[] range = parseRange(rangeHeader.substring(6), length);
            if (range == null) {
                headers.set(HttpHeaders.CONTENT_RANGE, "bytes */" + length);
                return ResponseEntity.status(HttpStatus.REQUESTED_RANGE_NOT_SATISFIABLE).headers(headers).build();
            }
            long start = range[0];
            long end = range[1];
            long size = end - start + 1;
            headers.set(HttpHeaders.CONTENT_RANGE, "bytes " + start + "-" + end + "/" + length);
            headers.setContentLength(size);
            try (var in = resource.getInputStream()) {
                in.skipNBytes(start);
                byte[] buf = in.readNBytes((int) size);
                return ResponseEntity.status(HttpStatus.PARTIAL_CONTENT)
                        .headers(headers)
                        .body(buf);
            }
        }
        headers.setContentLength(length);
        return new ResponseEntity<>(resource, headers, HttpStatus.OK);
    }

    private static long[] parseRange(String spec, long length) {
        try {
            String first = spec.split(",", 2)[0].trim();
            int dash = first.indexOf('-');
            if (dash < 0) {
                return null;
            }
            String startText = first.substring(0, dash);
            String endText = first.substring(dash + 1);
            long start;
            long end;
            if (startText.isEmpty()) {
                long suffix = Long.parseLong(endText);
                if (suffix <= 0) {
                    return null;
                }
                start = Math.max(0, length - suffix);
                end = length - 1;
            } else {
                start = Long.parseLong(startText);
                end = endText.isEmpty() ? length - 1 : Long.parseLong(endText);
            }
            if (start < 0 || start >= length || end < start) {
                return null;
            }
            return new long[]{start, Math.min(end, length - 1)};
        } catch (NumberFormatException ex) {
            return null;
        }
    }

    private static String clientIp(HttpServletRequest request) {
        String forwarded = request.getHeader("X-Forwarded-For");
        if (forwarded != null && !forwarded.isBlank()) {
            return forwarded.split(",")[0].trim();
        }
        return request.getRemoteAddr();
    }
}
