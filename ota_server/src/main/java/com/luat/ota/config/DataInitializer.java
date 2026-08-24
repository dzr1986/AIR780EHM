package com.luat.ota.config;

import com.luat.ota.entity.Device;
import com.luat.ota.entity.DeviceOtaStatus;
import com.luat.ota.entity.FirmwarePackage;
import com.luat.ota.entity.OtaProject;
import com.luat.ota.repository.DeviceRepository;
import com.luat.ota.repository.OtaProjectRepository;
import com.luat.ota.service.FirmwareRegistryService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.List;

/**
 * 启动时把默认项目 / 设备台账 / 模拟差分包写入 MySQL。
 * 已存在的 IMEI 不会覆盖（真机上报后的版本得以保留）。
 */
@Component
public class DataInitializer implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(DataInitializer.class);
    public static final String DEFAULT_KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x";
    public static final String DEFAULT_FW = "PANSHI_CAT1_LuatOS-SoC_Air780EHM";

    private final OtaProjectRepository projectRepo;
    private final DeviceRepository deviceRepo;
    private final FirmwareRegistryService registry;

    public DataInitializer(OtaProjectRepository projectRepo,
                           DeviceRepository deviceRepo,
                           FirmwareRegistryService registry) {
        this.projectRepo = projectRepo;
        this.deviceRepo = deviceRepo;
        this.registry = registry;
    }

    @Override
    public void run(ApplicationArguments args) throws Exception {
        OtaProject project = seedProject();
        seedDevices();
        seedFirmware(project);
        log.info("seed done: projects={} devices={}", projectRepo.count(), deviceRepo.count());
    }

    private OtaProject seedProject() {
        OtaProject p = projectRepo.findByProjectKey(DEFAULT_KEY).orElseGet(OtaProject::new);
        boolean created = p.getId() == null;
        p.setProjectKey(DEFAULT_KEY);
        p.setName("4G 标准模块");
        if (p.getDescription() == null || p.getDescription().isBlank()
                || looksMojibake(p.getDescription()) || p.getDescription().contains("合宙")) {
            p.setDescription("780EHM_PJ CAT1 默认项目");
        }
        if (p.getHidden() == null) {
            p.setHidden(false);
        }
        OtaProject saved = projectRepo.save(p);
        log.info("{} default project key={}", created ? "seed" : "repair", DEFAULT_KEY);
        return saved;
    }

    private static boolean looksMojibake(String text) {
        return text != null && (text.contains("Ã") || text.contains("å") || text.contains("\uFFFD"));
    }

    private void seedDevices() {
        List<SeedDevice> seeds = List.of(
                new SeedDevice("862323084073637", "2044.001.001", "0", at(2026, 7, 2, 0, 5, 22), "云端同步样机"),
                new SeedDevice("862323084068314", "2034.001.002", "0", at(2026, 6, 14, 14, 40, 50), "现场机"),
                new SeedDevice("862323084068124", "2034.001.002", "0", at(2026, 6, 3, 18, 11, 44), "文档样机"),
                new SeedDevice("862323084068999", "2044.001.002", "0", null, "模拟客户端")
        );
        for (SeedDevice s : seeds) {
            Device d = deviceRepo.findByImei(s.imei).orElseGet(Device::new);
            boolean created = d.getId() == null;
            d.setImei(s.imei);
            if (d.getDeviceName() == null || d.getDeviceName().isBlank()) {
                d.setDeviceName(s.imei);
            }
            if (d.getFirmwareName() == null || d.getFirmwareName().isBlank()) {
                d.setFirmwareName(DEFAULT_FW);
            }
            if (d.getCurrentVersion() == null || d.getCurrentVersion().isBlank()) {
                d.setCurrentVersion(s.version);
            }
            if (d.getCoreVersion() == null || d.getCoreVersion().isBlank()) {
                d.setCoreVersion(s.core);
            }
            if (d.getProjectKey() == null || d.getProjectKey().isBlank()) {
                d.setProjectKey(DEFAULT_KEY);
            }
            if (d.getOtaEnabled() == null) {
                d.setOtaEnabled(true);
            }
            if (d.getDebugEnabled() == null) {
                d.setDebugEnabled(false);
            }
            if (d.getOtaStatus() == null) {
                d.setOtaStatus(DeviceOtaStatus.IDLE);
            }
            if (d.getRemark() == null || d.getRemark().isBlank()
                    || looksMojibake(d.getRemark()) || d.getRemark().contains("合宙")) {
                d.setRemark(s.remark);
            }
            if (d.getLastSeenAt() == null) {
                d.setLastSeenAt(s.lastSeen);
                d.setLastOtaCheckAt(s.lastSeen);
            }
            deviceRepo.save(d);
            if (created) {
                log.info("seed device imei={} ver={}", s.imei, s.version);
            }
        }
    }

    private void seedFirmware(OtaProject project) throws Exception {
        if (registry.countPackages() > 0) {
            return;
        }
        String fileName = "seed_2044001001_to_2044001010.bin";
        String payload = "SEED-DFOTA 2044.001.001 -> 2044.001.010\n";
        FirmwarePackage meta = new FirmwarePackage();
        meta.setFirmwareName(DEFAULT_FW);
        meta.setVersion("2044.001.010");
        meta.setSourceVersion("2044.001.001");
        meta.setCoreVersion("0");
        meta.setProjectId(project.getId());
        meta.setAllowUpgrade(true);
        meta.setUpgradeAll(true);
        meta.setEnabled(true);
        meta.setRemark("启动种子包：默认差分固件");
        registry.createOrReplaceFile(fileName, payload.getBytes(StandardCharsets.UTF_8), meta, List.of());
        log.info("seed firmware {}", fileName);
    }

    private static Instant at(int y, int m, int d, int h, int min, int s) {
        return LocalDateTime.of(y, m, d, h, min, s).atZone(ZoneId.of("Asia/Shanghai")).toInstant();
    }

    private record SeedDevice(String imei, String version, String core, Instant lastSeen, String remark) {
    }
}
