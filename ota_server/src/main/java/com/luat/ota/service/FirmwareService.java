package com.luat.ota.service;

import com.luat.ota.config.OtaProperties;
import com.luat.ota.entity.FirmwarePackage;
import com.luat.ota.model.FirmwareRelease;
import com.luat.ota.util.LuatVersionUtil;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.Resource;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.List;
import java.util.Optional;

@Service
public class FirmwareService {

    private static final Logger log = LoggerFactory.getLogger(FirmwareService.class);

    private final OtaProperties props;
    private final FirmwareCatalogService catalog;
    private final OtaAuditService auditService;
    private final DeviceService deviceService;
    private final FirmwareRegistryService registry;

    public FirmwareService(OtaProperties props, FirmwareCatalogService catalog,
                           OtaAuditService auditService, DeviceService deviceService,
                           FirmwareRegistryService registry) {
        this.props = props;
        this.catalog = catalog;
        this.auditService = auditService;
        this.deviceService = deviceService;
        this.registry = registry;
    }

    public record OtaRequest(
            String projectKey,
            String imei,
            String mac,
            String uid,
            String firmwareName,
            String version,
            String clientIp
    ) {
        public OtaRequest(String projectKey, String imei, String mac, String uid, String firmwareName, String version) {
            this(projectKey, imei, mac, uid, firmwareName, version, null);
        }

        public String deviceId() {
            if (StringUtils.hasText(imei)) {
                return imei;
            }
            if (StringUtils.hasText(mac)) {
                return mac;
            }
            if (StringUtils.hasText(uid)) {
                return uid;
            }
            return "unknown";
        }
    }

    public enum OtaDecision {
        UPGRADE,
        NO_UPDATE,
        FORBIDDEN,
        NOT_FOUND
    }

    public record OtaResult(
            OtaDecision decision,
            Resource resource,
            String message,
            String targetVersion,
            String releaseId
    ) {
    }

    public OtaResult evaluate(OtaRequest req) {
        if (!isDeviceAllowed(req)) {
            OtaResult result = new OtaResult(OtaDecision.FORBIDDEN, null, "imei not in whitelist", null, null);
            audit(req, result);
            return result;
        }

        String current = LuatVersionUtil.normalize(req.version());
        if (!StringUtils.hasText(current)) {
            OtaResult result = new OtaResult(OtaDecision.NO_UPDATE, null, "missing version", null, null);
            audit(req, result);
            return result;
        }

        Optional<FirmwareRegistryService.MatchResult> fromRegistry = registry.findUpgradePackage(
                req.projectKey(), req.firmwareName(), current, req.imei());
        if (fromRegistry.isPresent()) {
            FirmwarePackage pkg = fromRegistry.get().pkg();
            Path file = catalog.resolveFirmwareFile(pkg.getFileName());
            OtaResult result = new OtaResult(
                    OtaDecision.UPGRADE,
                    new FileSystemResource(file),
                    fromRegistry.get().reason(),
                    pkg.getVersion(),
                    "pkg-" + pkg.getId()
            );
            audit(req, result);
            return result;
        }

        if (registry.isDeviceDenied(req.projectKey(), req.firmwareName(), current, req.imei())) {
            OtaResult result = new OtaResult(OtaDecision.FORBIDDEN, null, "device not assigned to firmware", null, null);
            audit(req, result);
            return result;
        }

        Optional<FirmwareRelease> fromManifest = catalog.findRelease(req.deviceId(), req.firmwareName(), current);
        if (fromManifest.isPresent()) {
            FirmwareRelease release = fromManifest.get();
            Path file = catalog.resolveFirmwareFile(release.getFile());
            OtaResult result = new OtaResult(
                    OtaDecision.UPGRADE,
                    new FileSystemResource(file),
                    "manifest match " + release.getId(),
                    release.getTargetVersion(),
                    release.getId()
            );
            audit(req, result);
            return result;
        }

        OtaResult fallback = evaluateFallback(req, current);
        audit(req, fallback);
        return fallback;
    }

    private OtaResult evaluateFallback(OtaRequest req, String current) {
        Optional<String> latestOpt = catalog.resolveTargetVersion(req.deviceId());
        if (latestOpt.isEmpty()) {
            log.error("no target version configured");
            return new OtaResult(OtaDecision.NOT_FOUND, null, "no target version", null, null);
        }

        String latest = latestOpt.get();
        if (LuatVersionUtil.compare(current, latest) >= 0) {
            return new OtaResult(OtaDecision.NO_UPDATE, null, "already latest", latest, null);
        }

        Path firmwarePath = resolveLegacyFirmwarePath(req.firmwareName(), latest);
        if (!Files.isRegularFile(firmwarePath)) {
            log.error("firmware not found: {} (no manifest match for source={})", firmwarePath.toAbsolutePath(), current);
            return new OtaResult(OtaDecision.NOT_FOUND, null, "no dfota for source version " + current, latest, null);
        }

        return new OtaResult(
                OtaDecision.UPGRADE,
                new FileSystemResource(firmwarePath),
                "fallback legacy file",
                latest,
                "legacy"
        );
    }

    public HttpStatus noUpdateStatus() {
        int code = props.getNoUpdateStatus();
        if (code < 300) {
            code = 404;
        }
        return HttpStatus.valueOf(code);
    }

    public Optional<Resource> loadDirectFile(String filename) throws IOException {
        Path base = catalog.firmwareDir();
        Path file = base.resolve(filename).normalize();
        if (!file.startsWith(base) || !Files.isRegularFile(file)) {
            return Optional.empty();
        }
        return Optional.of(new FileSystemResource(file));
    }

    private boolean isDeviceAllowed(OtaRequest req) {
        List<String> whitelist = props.getAllowedImeis();
        if (whitelist == null || whitelist.isEmpty()) {
            return true;
        }
        return whitelist.contains(req.imei());
    }

    private Path resolveLegacyFirmwarePath(String firmwareName, String latestVersion) {
        String mapped = props.getFirmwareMap().get(firmwareName);
        if (StringUtils.hasText(mapped)) {
            return catalog.resolveFirmwareFile(mapped);
        }
        if (StringUtils.hasText(props.getFirmwareFile())) {
            return catalog.resolveFirmwareFile(props.getFirmwareFile());
        }
        Path versionFile = catalog.resolveFirmwareFile(latestVersion + ".bin");
        if (Files.isRegularFile(versionFile)) {
            return versionFile;
        }
        if (StringUtils.hasText(firmwareName)) {
            Path named = catalog.resolveFirmwareFile(firmwareName + "_" + latestVersion + ".bin");
            if (Files.isRegularFile(named)) {
                return named;
            }
        }
        return catalog.resolveFirmwareFile("update.bin");
    }

    private void audit(OtaRequest req, OtaResult result) {
        if (StringUtils.hasText(req.imei())) {
            deviceService.recordOtaCheck(req.imei(), req.firmwareName(), req.version(), req.projectKey());
        }
        if (props.isLogRequests()) {
            log.info("OTA device={} fw={} cur={} -> {} decision={} msg={}",
                    req.deviceId(), req.firmwareName(), req.version(), result.targetVersion(),
                    result.decision(), result.message());
        }
        auditService.record(new OtaAuditService.OtaAuditRecord(
                Instant.now(),
                req.deviceId(),
                req.imei(),
                req.firmwareName(),
                req.version(),
                result.targetVersion(),
                result.decision().name(),
                result.message(),
                req.clientIp()
        ));
    }
}
