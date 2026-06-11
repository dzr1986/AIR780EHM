package com.luat.ota.controller;

import com.luat.ota.entity.FirmwarePackage;
import com.luat.ota.entity.OtaProject;
import com.luat.ota.service.FirmwareRegistryService;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** 合宙 IoT 风格：项目 + 固件 CRUD（对应 iot.openluat.com 我的项目/我的固件） */
@RestController
@RequestMapping("/admin/api")
public class FirmwareAdminController {

    private final FirmwareRegistryService registry;

    public FirmwareAdminController(FirmwareRegistryService registry) {
        this.registry = registry;
    }

    @GetMapping("/projects")
    public List<OtaProject> listProjects() {
        return registry.listProjects();
    }

    @PostMapping("/projects")
    public OtaProject createProject(@RequestBody OtaProject project) {
        return registry.saveProject(project);
    }

    @GetMapping("/firmware-packages")
    public List<Map<String, Object>> listPackages() {
        return registry.listFirmware().stream().map(this::toView).toList();
    }

    @GetMapping("/firmware-packages/{id}")
    public ResponseEntity<Map<String, Object>> getPackage(@PathVariable Long id) {
        return registry.findById(id)
                .map(p -> ResponseEntity.ok(toView(p)))
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @PostMapping(value = "/firmware-packages/upload", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public Map<String, Object> uploadPackage(
            @RequestParam("file") MultipartFile file,
            @RequestParam("firmwareName") String firmwareName,
            @RequestParam("version") String version,
            @RequestParam(value = "sourceVersion", required = false) String sourceVersion,
            @RequestParam(value = "coreVersion", defaultValue = "0") String coreVersion,
            @RequestParam(value = "projectId", required = false) Long projectId,
            @RequestParam(value = "allowUpgrade", defaultValue = "true") boolean allowUpgrade,
            @RequestParam(value = "upgradeAll", defaultValue = "false") boolean upgradeAll,
            @RequestParam(value = "remark", required = false) String remark,
            @RequestParam(value = "imeis", required = false) String imeis
    ) throws IOException {
        FirmwarePackage meta = new FirmwarePackage();
        meta.setFirmwareName(firmwareName);
        meta.setVersion(version);
        meta.setSourceVersion(sourceVersion);
        meta.setCoreVersion(coreVersion);
        meta.setProjectId(projectId);
        meta.setAllowUpgrade(allowUpgrade);
        meta.setUpgradeAll(upgradeAll);
        meta.setRemark(remark);
        List<String> imeiList = parseImeis(imeis);
        FirmwarePackage saved = registry.createFromUpload(file, meta, imeiList);
        return toView(saved);
    }

    @PutMapping("/firmware-packages/{id}")
    public ResponseEntity<Map<String, Object>> updatePackage(
            @PathVariable Long id,
            @RequestBody Map<String, Object> body
    ) {
        FirmwarePackage patch = new FirmwarePackage();
        if (body.containsKey("allowUpgrade")) {
            patch.setAllowUpgrade(Boolean.TRUE.equals(body.get("allowUpgrade")));
        }
        if (body.containsKey("upgradeAll")) {
            patch.setUpgradeAll(Boolean.TRUE.equals(body.get("upgradeAll")));
        }
        if (body.containsKey("enabled")) {
            patch.setEnabled(Boolean.TRUE.equals(body.get("enabled")));
        }
        if (body.containsKey("remark")) {
            patch.setRemark(String.valueOf(body.get("remark")));
        }
        if (body.containsKey("version")) {
            patch.setVersion(String.valueOf(body.get("version")));
        }
        if (body.containsKey("sourceVersion")) {
            patch.setSourceVersion(String.valueOf(body.get("sourceVersion")));
        }
        List<String> imeis = body.containsKey("imeis")
                ? parseImeis(String.valueOf(body.get("imeis"))) : null;
        try {
            return ResponseEntity.ok(toView(registry.update(id, patch, imeis)));
        } catch (IllegalArgumentException ex) {
            return ResponseEntity.notFound().build();
        }
    }

    @PutMapping("/firmware-packages/{id}/devices")
    public ResponseEntity<Map<String, Object>> assignDevices(
            @PathVariable Long id,
            @RequestBody Map<String, String> body
    ) {
        FirmwarePackage patch = new FirmwarePackage();
        List<String> imeis = parseImeis(body.get("imeis"));
        try {
            return ResponseEntity.ok(toView(registry.update(id, patch, imeis)));
        } catch (IllegalArgumentException ex) {
            return ResponseEntity.notFound().build();
        }
    }

    @DeleteMapping("/firmware-packages/{id}")
    public ResponseEntity<Void> deletePackage(@PathVariable Long id) {
        registry.delete(id);
        return ResponseEntity.noContent().build();
    }

    private Map<String, Object> toView(FirmwarePackage p) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", p.getId());
        m.put("projectId", p.getProjectId());
        m.put("firmwareName", p.getFirmwareName());
        m.put("version", p.getVersion());
        m.put("sourceVersion", p.getSourceVersion());
        m.put("coreVersion", p.getCoreVersion());
        m.put("fileName", p.getFileName());
        m.put("allowUpgrade", p.getAllowUpgrade());
        m.put("upgradeAll", p.getUpgradeAll());
        m.put("remark", p.getRemark());
        m.put("enabled", p.getEnabled());
        m.put("createdAt", p.getCreatedAt());
        m.put("assignedImeis", registry.listAssignedImeis(p.getId()));
        m.put("downloadUrl", "/firmware/" + p.getFileName());
        return m;
    }

    private static List<String> parseImeis(String raw) {
        if (raw == null || raw.isBlank()) {
            return List.of();
        }
        return Arrays.stream(raw.split("[,\\s]+"))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .toList();
    }
}
