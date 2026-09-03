package com.luat.ota.controller;

import com.luat.ota.entity.FirmwarePackage;
import com.luat.ota.entity.OtaProject;
import com.luat.ota.service.DeviceService;
import com.luat.ota.service.FirmwareRegistryService;
import com.luat.ota.util.ImeiListParser;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** 项目与固件管理接口。 */
@RestController
@RequestMapping("/admin/api")
public class FirmwareAdminController {

    private final FirmwareRegistryService registry;
    private final DeviceService deviceService;

    public FirmwareAdminController(FirmwareRegistryService registry, DeviceService deviceService) {
        this.registry = registry;
        this.deviceService = deviceService;
    }

    @GetMapping("/projects")
    public List<Map<String, Object>> listProjects() {
        return registry.listProjectViews().stream().map(this::withDeviceCount).toList();
    }

    @GetMapping("/projects/{id}")
    public ResponseEntity<Map<String, Object>> getProject(@PathVariable Long id) {
        return registry.findProject(id)
                .map(p -> ResponseEntity.ok(withDeviceCount(registry.toProjectView(p))))
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @PostMapping("/projects")
    public OtaProject createProject(@RequestBody OtaProject project) {
        return registry.saveProject(project);
    }

    @PutMapping("/projects/{id}")
    public Map<String, Object> updateProject(@PathVariable Long id, @RequestBody OtaProject project) {
        return withDeviceCount(registry.toProjectView(registry.updateProject(id, project)));
    }

    @DeleteMapping("/projects/{id}")
    public ResponseEntity<Void> deleteProject(@PathVariable Long id) {
        registry.deleteProject(id);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/firmware-packages")
    public List<Map<String, Object>> listPackages(@RequestParam(required = false) Long projectId) {
        List<FirmwarePackage> list = projectId == null
                ? registry.listFirmware()
                : registry.listFirmware().stream()
                .filter(p -> projectId.equals(p.getProjectId()))
                .toList();
        return list.stream().map(this::toView).toList();
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
            @RequestParam(value = "firmwareName", required = false) String firmwareName,
            @RequestParam(value = "version", required = false) String version,
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
        List<String> imeiList = ImeiListParser.parse(imeis);
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
                ? ImeiListParser.parse(body.get("imeis")) : null;
        try {
            return ResponseEntity.ok(toView(registry.update(id, patch, imeis)));
        } catch (IllegalArgumentException ex) {
            return ResponseEntity.notFound().build();
        }
    }

    @GetMapping("/firmware-packages/{id}/devices")
    public ResponseEntity<Map<String, Object>> listAssignedDevices(@PathVariable Long id) {
        return registry.findById(id)
                .map(p -> {
                    List<String> imeis = registry.listAssignedImeis(id);
                    Map<String, Object> body = new LinkedHashMap<>();
                    body.put("id", id);
                    body.put("firmwareName", p.getFirmwareName());
                    body.put("version", p.getVersion());
                    body.put("upgradeAll", p.getUpgradeAll());
                    body.put("assignedImeis", imeis);
                    body.put("total", imeis.size());
                    return ResponseEntity.ok(body);
                })
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @PutMapping("/firmware-packages/{id}/devices")
    public ResponseEntity<Map<String, Object>> replaceDevices(
            @PathVariable Long id,
            @RequestBody Map<String, Object> body
    ) {
        FirmwarePackage patch = new FirmwarePackage();
        List<String> imeis = ImeiListParser.parse(body.get("imeis"));
        try {
            return ResponseEntity.ok(assignmentView(registry.update(id, patch, imeis), List.of(), List.of()));
        } catch (IllegalArgumentException ex) {
            return ResponseEntity.notFound().build();
        }
    }

    @PostMapping("/firmware-packages/{id}/devices")
    public ResponseEntity<Map<String, Object>> addDevices(
            @PathVariable Long id,
            @RequestBody Map<String, Object> body
    ) {
        ImeiListParser.Result parsed = ImeiListParser.parseDetailed(body.get("imeis"));
        if (parsed.valid().isEmpty()) {
            throw new IllegalArgumentException("没有合法的 15 位 IMEI"
                    + (parsed.invalid().isEmpty() ? "" : "，无效：" + String.join(", ", parsed.invalid())));
        }
        try {
            List<String> before = registry.listAssignedImeis(id);
            FirmwarePackage saved = registry.addAssignments(id, parsed.valid());
            List<String> added = parsed.valid().stream().filter(imei -> !before.contains(imei)).toList();
            List<String> skipped = parsed.valid().stream().filter(before::contains).toList();
            Map<String, Object> view = assignmentView(saved, parsed.invalid(), skipped);
            view.put("added", added);
            view.put("addedCount", added.size());
            return ResponseEntity.ok(view);
        } catch (IllegalArgumentException ex) {
            if ("firmware not found".equals(ex.getMessage())) {
                return ResponseEntity.notFound().build();
            }
            throw ex;
        }
    }

    @DeleteMapping("/firmware-packages/{id}/devices")
    public ResponseEntity<Map<String, Object>> removeDevices(
            @PathVariable Long id,
            @RequestBody(required = false) Map<String, Object> body,
            @RequestParam(value = "imei", required = false) String imei
    ) {
        Object raw = body == null ? imei : (body.containsKey("imeis") ? body.get("imeis") : imei);
        List<String> imeis = ImeiListParser.requireValid(raw);
        try {
            return ResponseEntity.ok(assignmentView(registry.removeAssignments(id, imeis), List.of(), List.of()));
        } catch (IllegalArgumentException ex) {
            if ("firmware not found".equals(ex.getMessage())) {
                return ResponseEntity.notFound().build();
            }
            throw ex;
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

    private Map<String, Object> assignmentView(FirmwarePackage p, List<String> invalid, List<String> skipped) {
        Map<String, Object> m = toView(p);
        m.put("invalid", invalid);
        m.put("skipped", skipped);
        return m;
    }

    private Map<String, Object> withDeviceCount(Map<String, Object> view) {
        Object key = view.get("projectKey");
        view.put("deviceCount", key == null ? 0 : deviceService.countByProjectKey(String.valueOf(key)));
        return view;
    }
}
