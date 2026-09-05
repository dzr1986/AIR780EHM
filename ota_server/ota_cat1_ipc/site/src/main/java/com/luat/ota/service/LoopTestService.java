package com.luat.ota.service;

import com.luat.ota.dto.LoopTestRequest;
import com.luat.ota.entity.Device;
import com.luat.ota.entity.FirmwarePackage;
import com.luat.ota.entity.OtaProject;
import com.luat.ota.entity.OtaTask;
import com.luat.ota.util.LuatFilenameParser;
import com.luat.ota.util.LuatVersionUtil;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 闭环测试：准备模拟差分包，并查询设备、任务、审计日志。
 */
@Service
public class LoopTestService {

    public static final String DEFAULT_IMEI = "862323084068999";
    public static final String DEFAULT_KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x";
    public static final String DEFAULT_FW = "PANSHI_CAT1_LuatOS-SoC_Air780EHM";

    private final FirmwareRegistryService registry;
    private final DeviceService deviceService;
    private final OtaTriggerService triggerService;
    private final OtaAuditService auditService;

    public LoopTestService(FirmwareRegistryService registry,
                           DeviceService deviceService,
                           OtaTriggerService triggerService,
                           OtaAuditService auditService) {
        this.registry = registry;
        this.deviceService = deviceService;
        this.triggerService = triggerService;
        this.auditService = auditService;
    }

    public Map<String, Object> prepare(LoopTestRequest req) throws IOException {
        String imei = text(req.getImei(), DEFAULT_IMEI);
        String projectKey = text(req.getProjectKey(), DEFAULT_KEY);
        String firmwareName = text(req.getFirmwareName(), DEFAULT_FW);
        String source = text(req.getSourceVersion(), "2044.001.002");
        String target = text(req.getTargetVersion(), "2044.001.010");

        OtaProject project = registry.findProjectByKey(projectKey)
                .orElseThrow(() -> new IllegalArgumentException("项目不存在: " + projectKey));

        String fileName = "sim_loop_" + imei + ".bin";
        String payload = "SIM-DFOTA " + source + " -> " + target + " imei=" + imei + "\n";
        FirmwarePackage meta = new FirmwarePackage();
        meta.setFirmwareName(firmwareName);
        meta.setVersion(target);
        meta.setSourceVersion(source);
        meta.setCoreVersion("2044");
        meta.setProjectId(project.getId());
        meta.setAllowUpgrade(true);
        meta.setUpgradeAll(false);
        meta.setEnabled(true);
        meta.setRemark("闭环测试差分包");
        FirmwarePackage pkg = registry.createOrReplaceFile(
                fileName, payload.getBytes(StandardCharsets.UTF_8), meta, List.of(imei));
        exclusiveForImei(pkg.getId(), imei);
        bindSimDevice(imei, projectKey, firmwareName, source, target);
        return resultBody(imei, projectKey, firmwareName, source, target, pkg);
    }

    /**
     * 用本地量产 .bin 准备闭环：写入固件库、绑定模拟 IMEI、设备当前版本=源版本。
     */
    public Map<String, Object> prepareFromUpload(LoopTestRequest req, MultipartFile file) throws IOException {
        if (file == null || file.isEmpty()) {
            throw new IllegalArgumentException("请选择本地量产 .bin");
        }
        String original = file.getOriginalFilename() == null ? "" : file.getOriginalFilename();
        String lower = original.toLowerCase();
        if (lower.endsWith(".soc") || lower.endsWith(".binpkg")) {
            throw new IllegalArgumentException("OTA 只接受量产脚本 .bin，.soc / .binpkg 用于本地烧录");
        }
        if (!lower.endsWith(".bin")) {
            throw new IllegalArgumentException("只支持 .bin 量产包");
        }

        String imei = text(req.getImei(), DEFAULT_IMEI);
        String projectKey = text(req.getProjectKey(), DEFAULT_KEY);
        OtaProject project = registry.findProjectByKey(projectKey)
                .orElseThrow(() -> new IllegalArgumentException("项目不存在: " + projectKey));

        FirmwarePackage meta = new FirmwarePackage();
        LuatFilenameParser.parse(original).ifPresent(parsed -> {
            meta.setFirmwareName(parsed.firmwareName());
            meta.setVersion(parsed.version());
            meta.setCoreVersion(parsed.coreVersion());
        });
        if (StringUtils.hasText(req.getFirmwareName())) {
            meta.setFirmwareName(req.getFirmwareName().trim());
        }
        if (StringUtils.hasText(req.getTargetVersion())) {
            meta.setVersion(req.getTargetVersion().trim());
        }
        if (!StringUtils.hasText(meta.getFirmwareName())) {
            meta.setFirmwareName(DEFAULT_FW);
        }
        if (!StringUtils.hasText(meta.getVersion())) {
            throw new IllegalArgumentException("无法从文件名识别版本号，请填写目标版本");
        }
        String source = StringUtils.hasText(req.getSourceVersion())
                ? req.getSourceVersion().trim()
                : suggestSource(meta.getVersion());
        if (!LuatVersionUtil.canUpgrade(source, meta.getVersion())) {
            throw new IllegalArgumentException("源版本 " + source + " 无法升到 " + meta.getVersion()
                    + "，请把设备当前版本填低一些");
        }
        meta.setSourceVersion(source);
        meta.setProjectId(project.getId());
        meta.setAllowUpgrade(true);
        meta.setUpgradeAll(false);
        meta.setEnabled(true);
        meta.setRemark("量产闭环 " + original);
        if (!StringUtils.hasText(meta.getCoreVersion())) {
            String ver = meta.getVersion();
            meta.setCoreVersion(ver.contains(".") ? ver.substring(0, ver.indexOf('.')) : "0");
        }

        String firmwareName = meta.getFirmwareName();
        String target = meta.getVersion();
        String storedName = "loop_" + imei + "_" + target.replace('.', '_') + ".bin";
        byte[] bytes = file.getBytes();
        if (bytes.length == 0) {
            throw new IllegalArgumentException("量产文件是空的");
        }
        FirmwarePackage pkg = registry.createOrReplaceFile(storedName, bytes, meta, List.of(imei));
        exclusiveForImei(pkg.getId(), imei);
        bindSimDevice(imei, projectKey, firmwareName, source, target);
        Map<String, Object> body = resultBody(imei, projectKey, firmwareName, source, target, pkg);
        body.put("originalFile", original);
        body.put("sizeBytes", bytes.length);
        return body;
    }

    private void exclusiveForImei(Long keepId, String imei) {
        for (FirmwarePackage other : registry.listFirmware()) {
            if (keepId.equals(other.getId())) {
                continue;
            }
            String file = other.getFileName() == null ? "" : other.getFileName();
            boolean loopFile = file.startsWith("loop_" + imei) || file.startsWith("sim_loop_" + imei);
            List<String> assigned = registry.listAssignedImeis(other.getId());
            boolean onlyThis = assigned.size() == 1 && imei.equals(assigned.get(0));
            if (loopFile || onlyThis) {
                FirmwarePackage patch = new FirmwarePackage();
                patch.setAllowUpgrade(false);
                registry.update(other.getId(), patch, null);
            }
        }
    }

    private void bindSimDevice(String imei, String projectKey, String firmwareName,
                               String source, String target) {
        Device device = new Device();
        device.setImei(imei);
        device.setFirmwareName(firmwareName);
        device.setCurrentVersion(source);
        device.setTargetVersion(target);
        device.setProjectKey(projectKey);
        device.setOtaEnabled(true);
        device.setRemark("模拟客户端");
        deviceService.upsert(device);
        deviceService.resetLoopProtection(imei);
    }

    private static Map<String, Object> resultBody(String imei, String projectKey, String firmwareName,
                                                  String source, String target, FirmwarePackage pkg) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("imei", imei);
        body.put("projectKey", projectKey);
        body.put("firmwareName", firmwareName);
        body.put("sourceVersion", source);
        body.put("targetVersion", target);
        body.put("packageId", pkg.getId());
        body.put("fileName", pkg.getFileName());
        body.put("pullUrl", "/api/site/firmware_upgrade?imei=" + imei
                + "&project_key=" + projectKey
                + "&firmware_name=" + firmwareName
                + "&version=" + source);
        return body;
    }

    static String suggestSource(String target) {
        String[] parts = LuatVersionUtil.normalize(target).split("\\.");
        if (parts.length < 3) {
            return "2044.001.002";
        }
        try {
            int last = Integer.parseInt(parts[parts.length - 1]);
            int next = last >= 2 ? last - 2 : Math.max(0, last - 1);
            parts[parts.length - 1] = String.format("%03d", next);
            return String.join(".", parts);
        } catch (NumberFormatException ex) {
            return "2044.001.002";
        }
    }

    public Map<String, Object> status(String imei) {
        String id = text(imei, DEFAULT_IMEI);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("imei", id);
        body.put("device", deviceService.findByImei(id).orElse(null));
        List<OtaTask> tasks = triggerService.recentTasks(id);
        body.put("latestTask", tasks.isEmpty() ? null : tasks.get(0));
        body.put("tasks", tasks);
        body.put("logs", auditService.recent(20, id));
        return body;
    }

    private static String text(String value, String fallback) {
        return StringUtils.hasText(value) ? value.trim() : fallback;
    }
}
