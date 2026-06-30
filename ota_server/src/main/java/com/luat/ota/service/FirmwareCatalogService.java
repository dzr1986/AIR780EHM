package com.luat.ota.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.luat.ota.config.OtaProperties;
import com.luat.ota.model.FirmwareManifest;
import com.luat.ota.model.FirmwareRelease;
import com.luat.ota.util.LuatVersionUtil;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;

/**
 * 读取/维护 firmware/manifest.json，按源版本匹配 dfota 差分包。
 */
@Service
public class FirmwareCatalogService {

    private static final Logger log = LoggerFactory.getLogger(FirmwareCatalogService.class);

    private final OtaProperties props;
    private final ObjectMapper objectMapper;
    private final DeviceService deviceService;
    private volatile FirmwareManifest manifest = new FirmwareManifest();

    public FirmwareCatalogService(OtaProperties props, ObjectMapper objectMapper, DeviceService deviceService) {
        this.props = props;
        this.objectMapper = objectMapper;
        this.deviceService = deviceService;
    }

    @PostConstruct
    public void init() throws IOException {
        reload();
    }

    public synchronized void reload() throws IOException {
        Path manifestPath = manifestPath();
        if (Files.isRegularFile(manifestPath)) {
            manifest = objectMapper.readValue(manifestPath.toFile(), FirmwareManifest.class);
            log.info("loaded manifest: {} releases", manifest.getReleases().size());
        } else {
            manifest = new FirmwareManifest();
            log.warn("manifest not found: {}, using fallback config", manifestPath.toAbsolutePath());
        }
    }

    public synchronized void save(FirmwareManifest updated) throws IOException {
        manifest = updated;
        Path manifestPath = manifestPath();
        Files.createDirectories(manifestPath.getParent());
        objectMapper.writerWithDefaultPrettyPrinter().writeValue(manifestPath.toFile(), manifest);
    }

    public FirmwareManifest getManifest() {
        return manifest;
    }

    public List<FirmwareRelease> listReleases() {
        return new ArrayList<>(manifest.getReleases());
    }

    public Optional<FirmwareRelease> findRelease(String deviceId, String firmwareName, String currentVersion) {
        String current = LuatVersionUtil.normalize(currentVersion);
        if (!StringUtils.hasText(current)) {
            return Optional.empty();
        }

        String targetHint = resolveTargetHint(deviceId);
        List<FirmwareRelease> candidates = manifest.getReleases().stream()
                .filter(FirmwareRelease::isEnabled)
                .filter(r -> matchesFirmwareName(r, firmwareName))
                .filter(r -> LuatVersionUtil.normalize(r.getSourceVersion()).equals(current))
                .filter(r -> LuatVersionUtil.compare(r.getTargetVersion(), current) > 0)
                .filter(r -> targetHint == null || LuatVersionUtil.compare(r.getTargetVersion(), targetHint) <= 0)
                .filter(r -> fileExists(r.getFile()))
                .sorted(Comparator.comparing(FirmwareRelease::getTargetVersion, LuatVersionUtil::compare).reversed())
                .toList();

        return candidates.stream().findFirst();
    }

    public Optional<String> resolveTargetVersion(String deviceId) {
        String hint = resolveTargetHint(deviceId);
        if (hint != null) {
            return Optional.of(hint);
        }
        if (StringUtils.hasText(props.getLatestVersion())) {
            return Optional.of(LuatVersionUtil.normalize(props.getLatestVersion()));
        }
        return manifest.getReleases().stream()
                .filter(FirmwareRelease::isEnabled)
                .map(FirmwareRelease::getTargetVersion)
                .max(LuatVersionUtil::compare);
    }

    public void addRelease(FirmwareRelease release) throws IOException {
        FirmwareManifest copy = copyManifest();
        copy.getReleases().removeIf(r -> r.getId() != null && r.getId().equals(release.getId()));
        copy.getReleases().add(release);
        save(copy);
    }

    public boolean removeRelease(String id) throws IOException {
        FirmwareManifest copy = copyManifest();
        boolean removed = copy.getReleases().removeIf(r -> id.equals(r.getId()));
        if (removed) {
            save(copy);
        }
        return removed;
    }

    public Path firmwareDir() {
        return Paths.get(props.getFirmwareDir()).toAbsolutePath().normalize();
    }

    public Path manifestPath() {
        return firmwareDir().resolve("manifest.json");
    }

    public Path resolveFirmwareFile(String filename) {
        return firmwareDir().resolve(filename).normalize();
    }

    public List<FirmwareFileInfo> listFirmwareFiles() throws IOException {
        Path dir = firmwareDir();
        if (!Files.isDirectory(dir)) {
            return List.of();
        }
        List<FirmwareFileInfo> list = new ArrayList<>();
        try (var stream = Files.list(dir)) {
            stream.filter(p -> Files.isRegularFile(p) && p.getFileName().toString().endsWith(".bin"))
                    .forEach(p -> {
                        try {
                            list.add(new FirmwareFileInfo(
                                    p.getFileName().toString(),
                                    Files.size(p),
                                    Files.getLastModifiedTime(p).toMillis()
                            ));
                        } catch (IOException e) {
                            log.warn("read file info failed: {}", p, e);
                        }
                    });
        }
        list.sort(Comparator.comparing(FirmwareFileInfo::filename));
        return list;
    }

    public record FirmwareFileInfo(String filename, long sizeBytes, long lastModifiedMs) {
    }

    private String resolveTargetHint(String deviceId) {
        if (!StringUtils.hasText(deviceId)) {
            return null;
        }
        Optional<String> fromDb = deviceService.resolveTargetVersion(deviceId);
        if (fromDb.isPresent()) {
            return fromDb.get();
        }
        String fromManifest = manifest.getDeviceTargets().get(deviceId);
        if (StringUtils.hasText(fromManifest)) {
            return LuatVersionUtil.normalize(fromManifest);
        }
        return null;
    }

    private boolean matchesFirmwareName(FirmwareRelease release, String firmwareName) {
        String expected = release.getFirmwareName();
        if (!StringUtils.hasText(expected) || "*".equals(expected)) {
            return true;
        }
        return expected.equals(firmwareName);
    }

    private boolean fileExists(String filename) {
        if (!StringUtils.hasText(filename)) {
            return false;
        }
        Path file = resolveFirmwareFile(filename);
        return Files.isRegularFile(file);
    }

    private FirmwareManifest copyManifest() throws IOException {
        return objectMapper.readValue(objectMapper.writeValueAsBytes(manifest), FirmwareManifest.class);
    }
}
