package com.luat.ota.service;

import com.luat.ota.entity.Device;
import com.luat.ota.entity.DeviceOtaStatus;
import com.luat.ota.repository.DeviceRepository;
import com.luat.ota.util.LuatVersionUtil;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

import java.time.Instant;
import java.util.List;
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

    private static void clearLoopProtection(Device device) {
        device.setOtaLoopCount(0);
        device.setOtaBanReason(null);
        device.setLastOfferedVersion(null);
        device.setLastOfferedFromVersion(null);
    }
}
