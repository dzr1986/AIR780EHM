package com.luat.ota.controller;

import com.luat.ota.config.OtaProperties;
import com.luat.ota.model.FirmwareManifest;
import com.luat.ota.model.FirmwareRelease;
import com.luat.ota.service.FirmwareCatalogService;
import com.luat.ota.service.FirmwareCatalogService.FirmwareFileInfo;
import com.luat.ota.service.FirmwareRegistryService;
import com.luat.ota.service.OtaAuditService;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.util.StringUtils;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/admin/api")
public class AdminController {

    private final FirmwareCatalogService catalog;
    private final OtaAuditService auditService;
    private final OtaProperties props;
    private final FirmwareRegistryService registry;

    public AdminController(FirmwareCatalogService catalog, OtaAuditService auditService,
                           OtaProperties props, FirmwareRegistryService registry) {
        this.catalog = catalog;
        this.auditService = auditService;
        this.props = props;
        this.registry = registry;
    }

    @GetMapping("/status")
    public Map<String, Object> status() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("latestVersion", props.getLatestVersion());
        body.put("firmwareDir", catalog.firmwareDir().toString());
        body.put("manifestReleases", catalog.listReleases().size());
        body.put("firmwarePackages", registry.countPackages());
        body.put("stats", auditService.stats());
        return body;
    }

    @GetMapping("/manifest")
    public FirmwareManifest manifest() {
        return catalog.getManifest();
    }

    @PutMapping("/manifest")
    public ResponseEntity<Void> saveManifest(@RequestBody FirmwareManifest manifest) throws IOException {
        catalog.save(manifest);
        return ResponseEntity.ok().build();
    }

    @GetMapping("/releases")
    public List<FirmwareRelease> releases() {
        return catalog.listReleases();
    }

    @PostMapping("/releases")
    public ResponseEntity<FirmwareRelease> addRelease(@RequestBody FirmwareRelease release) throws IOException {
        if (!StringUtils.hasText(release.getId())) {
            release.setId(UUID.randomUUID().toString().substring(0, 8));
        }
        catalog.addRelease(release);
        return ResponseEntity.status(HttpStatus.CREATED).body(release);
    }

    @DeleteMapping("/releases/{id}")
    public ResponseEntity<Void> deleteRelease(@PathVariable String id) throws IOException {
        return catalog.removeRelease(id)
                ? ResponseEntity.noContent().build()
                : ResponseEntity.notFound().build();
    }

    @GetMapping("/firmware")
    public List<FirmwareFileInfo> listFiles() throws IOException {
        return catalog.listFirmwareFiles();
    }

    @PostMapping(value = "/firmware/upload", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public Map<String, Object> uploadFirmware(
            @RequestParam("file") MultipartFile file,
            @RequestParam(value = "sourceVersion", required = false) String sourceVersion,
            @RequestParam(value = "targetVersion", required = false) String targetVersion,
            @RequestParam(value = "firmwareName", required = false) String firmwareName,
            @RequestParam(value = "autoRelease", defaultValue = "true") boolean autoRelease
    ) throws IOException {
        if (file.isEmpty()) {
            throw new IllegalArgumentException("empty file");
        }
        String original = file.getOriginalFilename();
        if (original == null || !original.endsWith(".bin")) {
            throw new IllegalArgumentException("only .bin allowed");
        }
        String safeName = original.replaceAll("[^a-zA-Z0-9._-]", "_");
        Path dest = catalog.resolveFirmwareFile(safeName);
        Files.createDirectories(dest.getParent());
        Files.copy(file.getInputStream(), dest, StandardCopyOption.REPLACE_EXISTING);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("filename", safeName);
        result.put("sizeBytes", Files.size(dest));

        if (autoRelease && StringUtils.hasText(sourceVersion) && StringUtils.hasText(targetVersion)) {
            FirmwareRelease release = new FirmwareRelease();
            release.setId(safeName.replace(".bin", ""));
            release.setFile(safeName);
            release.setSourceVersion(sourceVersion);
            release.setTargetVersion(targetVersion);
            release.setFirmwareName(StringUtils.hasText(firmwareName) ? firmwareName : "*");
            release.setEnabled(true);
            release.setComment("uploaded via admin");
            catalog.addRelease(release);
            result.put("release", release);
        }
        return result;
    }

    @GetMapping("/logs")
    public List<OtaAuditService.OtaAuditRecord> logs(@RequestParam(defaultValue = "100") int limit) {
        return auditService.recent(limit);
    }

    @PostMapping("/manifest/reload")
    public ResponseEntity<Void> reloadManifest() throws IOException {
        catalog.reload();
        return ResponseEntity.ok().build();
    }
}
