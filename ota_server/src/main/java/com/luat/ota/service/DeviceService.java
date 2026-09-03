package com.luat.ota.service;

import com.luat.ota.entity.Device;
import com.luat.ota.entity.DeviceOtaStatus;
import com.luat.ota.repository.DeviceRepository;
import com.luat.ota.util.ImeiListParser;
import com.luat.ota.util.LuatVersionUtil;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;

@Service
public class DeviceService {

    public static final int LOOP_BAN_THRESHOLD = 6;

    private final DeviceRepository deviceRepository;

    public DeviceService(DeviceRepository deviceRepository) {
        this.deviceRepository = deviceRepository;
    }

    public List<Device> listAll() {
        return deviceRepository.findAll();
    }

    public List<Device> list(String imei, String projectKey, Boolean otaEnabled) {
        List<Device> all = StringUtils.hasText(imei)
                ? deviceRepository.findByImeiContaining(imei.trim())
                : StringUtils.hasText(projectKey)
                ? deviceRepository.findByProjectKey(projectKey.trim())
                : deviceRepository.findAll();
        if (StringUtils.hasText(projectKey) && StringUtils.hasText(imei)) {
            all = all.stream()
                    .filter(d -> projectKey.trim().equals(d.getProjectKey()))
                    .toList();
        }
        if (otaEnabled != null) {
            all = all.stream()
                    .filter(d -> otaEnabled.equals(d.getOtaEnabled()))
                    .toList();
        }
        return all;
    }

    public long countByProjectKey(String projectKey) {
        if (!StringUtils.hasText(projectKey)) {
            return 0;
        }
        return deviceRepository.countByProjectKey(projectKey.trim());
    }

    @Transactional
    public Device setOtaEnabled(String imei, boolean enabled) {
        Device device = deviceRepository.findByImei(imei)
                .orElseThrow(() -> new IllegalArgumentException("设备不存在: " + imei));
        device.setOtaEnabled(enabled);
        if (enabled) {
            clearLoopProtection(device);
        }
        return deviceRepository.save(device);
    }

    /**
     * IMEI 首次请求自动归属当前项目；已属其他项目则冲突（25 无权限）。
     * @return false 表示项目冲突
     */
    @Transactional
    public boolean bindProjectIfAbsent(String imei, String projectKey) {
        if (!StringUtils.hasText(imei) || !StringUtils.hasText(projectKey)) {
            return true;
        }
        Device device = deviceRepository.findByImei(imei).orElseGet(Device::new);
        device.setImei(imei);
        if (!StringUtils.hasText(device.getProjectKey())) {
            device.setProjectKey(projectKey.trim());
            deviceRepository.save(device);
            return true;
        }
        return device.getProjectKey().equals(projectKey.trim());
    }

    public Optional<Device> findByImei(String imei) {
        return deviceRepository.findByImei(imei);
    }

    @Transactional
    public Device upsert(Device input) {
        Device device = deviceRepository.findByImei(input.getImei()).orElseGet(Device::new);
        device.setImei(input.getImei());
        if (input.getFirmwareName() != null) {
            device.setFirmwareName(input.getFirmwareName());
        }
        if (input.getCurrentVersion() != null) {
            device.setCurrentVersion(input.getCurrentVersion());
        }
        if (input.getTargetVersion() != null) {
            device.setTargetVersion(input.getTargetVersion());
        }
        if (input.getProjectKey() != null) {
            device.setProjectKey(input.getProjectKey());
        }
        if (input.getOtaEnabled() != null) {
            device.setOtaEnabled(input.getOtaEnabled());
        }
        if (input.getDebugEnabled() != null) {
            device.setDebugEnabled(input.getDebugEnabled());
        }
        if (input.getDeviceName() != null) {
            device.setDeviceName(input.getDeviceName());
        }
        if (input.getCoreVersion() != null) {
            device.setCoreVersion(input.getCoreVersion());
        }
        if (input.getRemark() != null) {
            device.setRemark(input.getRemark());
        }
        if (!StringUtils.hasText(device.getDeviceName())) {
            device.setDeviceName(device.getImei());
        }
        if (!StringUtils.hasText(device.getCoreVersion())) {
            device.setCoreVersion("0");
        }
        if (device.getDebugEnabled() == null) {
            device.setDebugEnabled(false);
        }
        return deviceRepository.save(device);
    }

    @Transactional
    public Device setDebugEnabled(String imei, boolean enabled) {
        Device device = deviceRepository.findByImei(imei)
                .orElseThrow(() -> new IllegalArgumentException("设备不存在: " + imei));
        device.setDebugEnabled(enabled);
        return deviceRepository.save(device);
    }

    @Transactional
    public void deleteByImei(String imei) {
        deviceRepository.findByImei(imei).ifPresent(deviceRepository::delete);
    }

    @Transactional
    public Map<String, Object> batch(String action, List<String> imeis, String projectKey) {
        if (imeis == null || imeis.isEmpty()) {
            throw new IllegalArgumentException("请填写 IMEI");
        }
        if (!StringUtils.hasText(action)) {
            throw new IllegalArgumentException("action required");
        }
        String act = action.trim().toLowerCase(Locale.ROOT).replace('-', '_');
        int ok = 0;
        int missing = 0;
        List<String> errors = new ArrayList<>();
        for (String imei : imeis) {
            try {
                switch (act) {
                    case "unban", "enable_ota" -> setOtaEnabled(imei, true);
                    case "ban", "disable_ota" -> setOtaEnabled(imei, false);
                    case "debug_on" -> setDebugEnabled(imei, true);
                    case "debug_off" -> setDebugEnabled(imei, false);
                    case "delete" -> {
                        if (deviceRepository.findByImei(imei).isEmpty()) {
                            missing++;
                            continue;
                        }
                        deleteByImei(imei);
                    }
                    case "transfer" -> {
                        if (!StringUtils.hasText(projectKey)) {
                            throw new IllegalArgumentException("转移需要目标项目 Key");
                        }
                        Device device = deviceRepository.findByImei(imei)
                                .orElseThrow(() -> new IllegalArgumentException("设备不存在: " + imei));
                        device.setProjectKey(projectKey.trim());
                        deviceRepository.save(device);
                    }
                    case "create", "upsert" -> {
                        Device input = new Device();
                        input.setImei(imei);
                        if (StringUtils.hasText(projectKey)) {
                            input.setProjectKey(projectKey.trim());
                        }
                        input.setOtaEnabled(true);
                        upsert(input);
                    }
                    default -> throw new IllegalArgumentException("unknown batch action: " + action);
                }
                ok++;
            } catch (IllegalArgumentException ex) {
                String msg = ex.getMessage() == null ? "" : ex.getMessage();
                if (msg.startsWith("unknown batch action")) {
                    throw ex;
                }
                if (msg.startsWith("设备不存在")) {
                    missing++;
                } else {
                    errors.add(imei + ": " + msg);
                }
            }
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("action", act);
        body.put("ok", ok);
        body.put("missing", missing);
        body.put("errors", errors);
        body.put("total", imeis.size());
        return body;
    }

    public Optional<String> resolveTargetVersion(String imei) {
        return deviceRepository.findByImei(imei)
                .filter(d -> Boolean.TRUE.equals(d.getOtaEnabled()))
                .map(Device::getTargetVersion)
                .filter(StringUtils::hasText)
                .map(LuatVersionUtil::normalize);
    }

    @Transactional
    public Device recordOtaCheck(String imei, String firmwareName, String currentVersion, String projectKey) {
        Device device = deviceRepository.findByImei(imei).orElseGet(Device::new);
        device.setImei(imei);
        if (StringUtils.hasText(firmwareName)) {
            device.setFirmwareName(firmwareName);
        }
        if (StringUtils.hasText(currentVersion)) {
            device.setCurrentVersion(LuatVersionUtil.normalize(currentVersion));
        }
        if (StringUtils.hasText(projectKey) && !StringUtils.hasText(device.getProjectKey())) {
            device.setProjectKey(projectKey);
        }
        device.setLastOtaCheckAt(Instant.now());
        device.setLastSeenAt(Instant.now());
        return deviceRepository.save(device);
    }

    @Transactional
    public void markOtaInProgress(String imei, String targetVersion) {
        Device device = deviceRepository.findByImei(imei).orElseGet(Device::new);
        device.setImei(imei);
        if (StringUtils.hasText(targetVersion)) {
            device.setTargetVersion(LuatVersionUtil.normalize(targetVersion));
        }
        device.setOtaStatus(DeviceOtaStatus.IN_PROGRESS);
        device.setLastOtaCheckAt(Instant.now());
        device.setLastSeenAt(Instant.now());
        deviceRepository.save(device);
    }

    @Transactional
    public void markOtaPending(String imei, String targetVersion) {
        Device device = deviceRepository.findByImei(imei).orElseGet(Device::new);
        device.setImei(imei);
        device.setTargetVersion(LuatVersionUtil.normalize(targetVersion));
        device.setOtaStatus(DeviceOtaStatus.PENDING);
        device.setLastSeenAt(Instant.now());
        deviceRepository.save(device);
    }

    @Transactional
    public void updateFromMqttEvent(String imei, String stage, Integer ret, String message,
                                    String currentVersion, String targetVersion) {
        Device device = deviceRepository.findByImei(imei).orElseGet(Device::new);
        device.setImei(imei);
        device.setLastSeenAt(Instant.now());
        if (StringUtils.hasText(currentVersion)) {
            String nv = LuatVersionUtil.normalize(currentVersion);
            String old = device.getCurrentVersion();
            if (!(isScriptStyle(nv) && isIotStyle(old))) {
                device.setCurrentVersion(nv);
            }
        }
        if (StringUtils.hasText(targetVersion)) {
            device.setTargetVersion(LuatVersionUtil.normalize(targetVersion));
        }

        if ("success".equalsIgnoreCase(stage) && (ret == null || ret == 0)) {
            if (StringUtils.hasText(targetVersion)) {
                device.setCurrentVersion(LuatVersionUtil.normalize(targetVersion));
            }
            device.setOtaStatus(DeviceOtaStatus.SUCCESS);
            device.setLastOtaSuccessAt(Instant.now());
            clearLoopProtection(device);
        } else if ("failed".equalsIgnoreCase(stage) || (ret != null && ret != 0 && !isProgressStage(stage))) {
            device.setOtaStatus(DeviceOtaStatus.FAILED);
        } else if (stage != null) {
            device.setOtaStatus(DeviceOtaStatus.IN_PROGRESS);
        }
        deviceRepository.save(device);
    }

    private static boolean isProgressStage(String stage) {
        if (stage == null) {
            return false;
        }
        String s = stage.toLowerCase();
        return "starting".equals(s) || "downloading".equals(s) || "checking".equals(s);
    }

    private static boolean isIotStyle(String version) {
        return firstSegment(version) >= 1000;
    }

    private static boolean isScriptStyle(String version) {
        int n = firstSegment(version);
        return n >= 0 && n < 1000;
    }

    private static int firstSegment(String version) {
        if (!StringUtils.hasText(version)) {
            return -1;
        }
        int dot = version.indexOf('.');
        String head = dot < 0 ? version : version.substring(0, dot);
        try {
            return Integer.parseInt(head);
        } catch (NumberFormatException ex) {
            return -1;
        }
    }

    public List<Device> findOutdatedDevices(String targetVersion) {
        String target = LuatVersionUtil.normalize(targetVersion);
        return deviceRepository.findByOtaEnabledTrue().stream()
                .filter(d -> {
                    String cur = d.getCurrentVersion();
                    return !StringUtils.hasText(cur) || LuatVersionUtil.compare(cur, target) < 0;
                })
                .toList();
    }

    /**
     * 记录一次准备下发。同一源版本连续拿到同一目标达到 6 次则禁止升级。
     * @return false 表示已触发循环保护，不要再返回 200
     */
    @Transactional
    public boolean noteUpgradeOffered(String imei, String reportedVersion, String targetVersion) {
        if (!StringUtils.hasText(imei) || !StringUtils.hasText(targetVersion)) {
            return true;
        }
        Device device = deviceRepository.findByImei(imei).orElseGet(Device::new);
        device.setImei(imei);
        String reported = LuatVersionUtil.normalize(reportedVersion);
        String target = LuatVersionUtil.normalize(targetVersion);
        boolean sameLoop = target.equals(device.getLastOfferedVersion())
                && reported.equals(device.getLastOfferedFromVersion());
        int count = sameLoop ? (device.getOtaLoopCount() == null ? 0 : device.getOtaLoopCount()) + 1 : 1;
        device.setOtaLoopCount(count);
        device.setLastOfferedVersion(target);
        device.setLastOfferedFromVersion(reported);
        if (count >= LOOP_BAN_THRESHOLD) {
            device.setOtaEnabled(false);
            device.setOtaBanReason("循环升级保护：连续 " + count + " 次下发 " + target + " 且设备仍报 " + reported);
            device.setOtaStatus(DeviceOtaStatus.FAILED);
            deviceRepository.save(device);
            return false;
        }
        deviceRepository.save(device);
        return true;
    }

    @Transactional
    public void resetLoopProtection(String imei) {
        deviceRepository.findByImei(imei).ifPresent(device -> {
            clearLoopProtection(device);
            deviceRepository.save(device);
        });
    }

    @Transactional
    public Device ensureByImei(String rawImei) {
        String imei = ImeiListParser.requireValid(rawImei).get(0);
        return deviceRepository.findByImei(imei).orElseGet(() -> {
            Device device = new Device();
            device.setImei(imei);
            device.setDeviceName(imei);
            device.setOtaEnabled(true);
            device.setDebugEnabled(false);
            device.setIpcStatus("IDLE");
            device.setIpcEnabled(false);
            return deviceRepository.save(device);
        });
    }

    public static boolean isIpcUpgradeAllowed(Device device) {
        return device != null && Boolean.TRUE.equals(device.getIpcEnabled());
    }

    @Transactional
    public Device setIpcEnabled(String rawImei, boolean enabled) {
        Device device = ensureByImei(rawImei);
        device.setIpcEnabled(enabled);
        device.setLastSeenAt(Instant.now());
        return deviceRepository.save(device);
    }

    @Transactional
    public Map<String, Object> batchIpcEnabled(boolean enabled, List<String> imeis) {
        int updated = 0;
        for (String imei : imeis) {
            setIpcEnabled(imei, enabled);
            updated++;
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("ok", true);
        out.put("action", enabled ? "enable" : "disable");
        out.put("updated", updated);
        return out;
    }

    public Device requireIpcAllowed(String rawImei) {
        Device device = ensureByImei(rawImei);
        if (!isIpcUpgradeAllowed(device)) {
            throw new IllegalArgumentException("IMEI " + device.getImei() + " 未允许 IPC 升级，请先点「允许」");
        }
        return device;
    }

    @Transactional
    public Device markIpcPending(String rawImei, String version, String sessionId) {
        Device device = requireIpcAllowed(rawImei);
        device.setIpcTargetVersion(version);
        device.setIpcStatus("PENDING");
        device.setIpcSessionId(sessionId);
        device.setLastSeenAt(Instant.now());
        return deviceRepository.save(device);
    }

    @Transactional
    public Device markIpcResult(String rawImei, String stage, String version) {
        Device device = ensureByImei(rawImei);
        String st = stage == null ? "" : stage.trim().toLowerCase(Locale.ROOT);
        if ("success".equals(st) || "ok".equals(st)) {
            if (StringUtils.hasText(version)) {
                device.setIpcVersion(version.trim());
            } else if (StringUtils.hasText(device.getIpcTargetVersion())) {
                device.setIpcVersion(device.getIpcTargetVersion());
            }
            device.setIpcStatus("SUCCESS");
            device.setLastIpcUpgradeAt(Instant.now());
        } else if ("failed".equals(st) || "fail".equals(st) || "error".equals(st)) {
            device.setIpcStatus("FAILED");
        } else if (StringUtils.hasText(st) && !"idle".equals(st)) {
            device.setIpcStatus("IN_PROGRESS");
        }
        device.setLastSeenAt(Instant.now());
        return deviceRepository.save(device);
    }

    public Map<String, Object> ipcView(Device device) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("imei", device.getImei());
        m.put("deviceName", device.getDeviceName());
        m.put("firmwareName", device.getFirmwareName());
        m.put("currentVersion", device.getCurrentVersion());
        m.put("ipcVersion", device.getIpcVersion());
        m.put("ipcTargetVersion", device.getIpcTargetVersion());
        m.put("ipcEnabled", isIpcUpgradeAllowed(device));
        m.put("ipcStatus", device.getIpcStatus() == null ? "IDLE" : device.getIpcStatus());
        m.put("ipcSessionId", device.getIpcSessionId());
        m.put("lastIpcUpgradeAt", device.getLastIpcUpgradeAt());
        m.put("lastSeenAt", device.getLastSeenAt());
        return m;
    }

    public List<Map<String, Object>> listIpcViews() {
        return listAll().stream().map(this::ipcView).toList();
    }

    private static void clearLoopProtection(Device device) {
        device.setOtaLoopCount(0);
        device.setOtaBanReason(null);
        device.setLastOfferedVersion(null);
        device.setLastOfferedFromVersion(null);
    }
}
