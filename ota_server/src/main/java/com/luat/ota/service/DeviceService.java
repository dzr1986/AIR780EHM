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

    private final DeviceRepository deviceRepository;

    public DeviceService(DeviceRepository deviceRepository) {
        this.deviceRepository = deviceRepository;
    }

    public List<Device> listAll() {
        return deviceRepository.findAll();
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
        if (input.getRemark() != null) {
            device.setRemark(input.getRemark());
        }
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
        if (StringUtils.hasText(projectKey)) {
            device.setProjectKey(projectKey);
        }
        device.setLastOtaCheckAt(Instant.now());
        device.setLastSeenAt(Instant.now());
        return deviceRepository.save(device);
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
            device.setCurrentVersion(LuatVersionUtil.normalize(currentVersion));
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
        } else if (stage != null && (ret != null && ret < 0)) {
            device.setOtaStatus(DeviceOtaStatus.FAILED);
        } else if (stage != null) {
            device.setOtaStatus(DeviceOtaStatus.IN_PROGRESS);
        }
        deviceRepository.save(device);
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
}
