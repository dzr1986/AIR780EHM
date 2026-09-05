package com.luat.ota.service;

import com.luat.ota.config.OtaProperties;
import com.luat.ota.entity.FirmwareDeviceAssignment;
import com.luat.ota.entity.FirmwarePackage;
import com.luat.ota.entity.OtaProject;
import com.luat.ota.repository.FirmwareDeviceAssignmentRepository;
import com.luat.ota.repository.FirmwarePackageRepository;
import com.luat.ota.repository.OtaProjectRepository;
import com.luat.ota.util.LuatFilenameParser;
import com.luat.ota.util.LuatVersionUtil;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.SecureRandom;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * 固件库：固件名、版本号、允许升级、升级全部或指定设备。
 */
@Service
public class FirmwareRegistryService {

    private static final Logger log = LoggerFactory.getLogger(FirmwareRegistryService.class);
    private static final String KEY_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    private static final SecureRandom RNG = new SecureRandom();

    private final FirmwarePackageRepository firmwareRepo;
    private final FirmwareDeviceAssignmentRepository assignmentRepo;
    private final OtaProjectRepository projectRepo;
    private final FirmwareCatalogService catalog;

    public FirmwareRegistryService(FirmwarePackageRepository firmwareRepo,
                                   FirmwareDeviceAssignmentRepository assignmentRepo,
                                   OtaProjectRepository projectRepo,
                                   FirmwareCatalogService catalog) {
        this.firmwareRepo = firmwareRepo;
        this.assignmentRepo = assignmentRepo;
        this.projectRepo = projectRepo;
        this.catalog = catalog;
    }

    public record MatchResult(FirmwarePackage pkg, String reason) {
    }

    public List<OtaProject> listProjects() {
        return projectRepo.findAll();
    }

    public List<Map<String, Object>> listProjectViews() {
        return projectRepo.findAll().stream().map(this::toProjectView).toList();
    }

    public Optional<OtaProject> findProject(Long id) {
        return projectRepo.findById(id);
    }

    public Optional<OtaProject> findProjectByKey(String projectKey) {
        if (!StringUtils.hasText(projectKey)) {
            return Optional.empty();
        }
        return projectRepo.findByProjectKey(projectKey.trim());
    }

    public boolean projectKeyExists(String projectKey) {
        return findProjectByKey(projectKey).isPresent();
    }

    public boolean hasFirmwareName(String firmwareName) {
        return StringUtils.hasText(firmwareName) && firmwareRepo.existsByFirmwareName(firmwareName);
    }

    @Transactional
    public OtaProject saveProject(OtaProject project) {
        if (!StringUtils.hasText(project.getName())) {
            throw new IllegalArgumentException("项目名称必填");
        }
        if (!StringUtils.hasText(project.getProjectKey())) {
            project.setProjectKey(newProjectKey());
        }
        if (project.getHidden() == null) {
            project.setHidden(false);
        }
        return projectRepo.save(project);
    }

    @Transactional
    public OtaProject updateProject(Long id, OtaProject patch) {
        OtaProject existing = projectRepo.findById(id)
                .orElseThrow(() -> new IllegalArgumentException("项目不存在"));
        if (StringUtils.hasText(patch.getName())) {
            existing.setName(patch.getName());
        }
        if (patch.getDescription() != null) {
            existing.setDescription(patch.getDescription());
        }
        if (patch.getHidden() != null) {
            existing.setHidden(patch.getHidden());
        }
        return projectRepo.save(existing);
    }

    @Transactional
    public void deleteProject(Long id) {
        OtaProject existing = projectRepo.findById(id)
                .orElseThrow(() -> new IllegalArgumentException("项目不存在"));
        for (FirmwarePackage pkg : firmwareRepo.findByProjectIdOrderByCreatedAtDesc(id)) {
            delete(pkg.getId());
        }
        projectRepo.delete(existing);
    }

    public Map<String, Object> toProjectView(OtaProject p) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", p.getId());
        m.put("name", p.getName());
        m.put("projectKey", p.getProjectKey());
        m.put("description", p.getDescription());
        m.put("hidden", p.getHidden());
        m.put("createdAt", p.getCreatedAt());
        m.put("updatedAt", p.getUpdatedAt());
        m.put("firmwareCount", firmwareRepo.countByProjectId(p.getId()));
        return m;
    }

    public static String newProjectKey() {
        StringBuilder sb = new StringBuilder(32);
        for (int i = 0; i < 32; i++) {
            sb.append(KEY_CHARS.charAt(RNG.nextInt(KEY_CHARS.length())));
        }
        return sb.toString();
    }

    public List<FirmwarePackage> listFirmware() {
        return firmwareRepo.findAllByOrderByCreatedAtDesc();
    }

    public Optional<FirmwarePackage> findById(Long id) {
        return firmwareRepo.findById(id);
    }

    @Transactional
    public FirmwarePackage createFromUpload(MultipartFile file, FirmwarePackage meta, List<String> imeis)
            throws IOException {
        applyParsedFilename(file.getOriginalFilename(), meta);
        validatePackageMeta(meta);
        String safeName = sanitizeFileName(file.getOriginalFilename());
        Path dest = catalog.resolveFirmwareFile(safeName);
        Files.createDirectories(dest.getParent());
        Files.copy(file.getInputStream(), dest, StandardCopyOption.REPLACE_EXISTING);

        meta.setFileName(safeName);
        if (meta.getAllowUpgrade() == null) {
            meta.setAllowUpgrade(true);
        }
        if (meta.getUpgradeAll() == null) {
            meta.setUpgradeAll(false);
        }
        if (meta.getEnabled() == null) {
            meta.setEnabled(true);
        }
        if (!StringUtils.hasText(meta.getCoreVersion())) {
            meta.setCoreVersion("0");
        }
        FirmwarePackage saved = firmwareRepo.save(meta);
        replaceAssignments(saved.getId(), imeis, Boolean.TRUE.equals(saved.getUpgradeAll()));
        log.info("firmware created id={} name={} ver={} src={}", saved.getId(),
                saved.getFirmwareName(), saved.getVersion(), saved.getSourceVersion());
        return saved;
    }

    @Transactional
    public FirmwarePackage createOrReplaceFile(String fileName, byte[] content, FirmwarePackage meta, List<String> imeis)
            throws IOException {
        validatePackageMeta(meta);
        String safeName = sanitizeFileName(fileName);
        Path dest = catalog.resolveFirmwareFile(safeName);
        Files.createDirectories(dest.getParent());
        Files.write(dest, content);

        FirmwarePackage existing = firmwareRepo.findFirstByFileName(safeName).orElseGet(FirmwarePackage::new);
        existing.setFirmwareName(meta.getFirmwareName());
        existing.setVersion(meta.getVersion());
        existing.setSourceVersion(meta.getSourceVersion());
        existing.setCoreVersion(StringUtils.hasText(meta.getCoreVersion()) ? meta.getCoreVersion() : "0");
        existing.setProjectId(meta.getProjectId());
        existing.setFileName(safeName);
        existing.setAllowUpgrade(meta.getAllowUpgrade() == null || meta.getAllowUpgrade());
        existing.setUpgradeAll(Boolean.TRUE.equals(meta.getUpgradeAll()));
        existing.setEnabled(meta.getEnabled() == null || meta.getEnabled());
        existing.setRemark(meta.getRemark());
        FirmwarePackage saved = firmwareRepo.save(existing);
        replaceAssignments(saved.getId(), imeis, Boolean.TRUE.equals(saved.getUpgradeAll()));
        log.info("firmware file upsert id={} file={}", saved.getId(), safeName);
        return saved;
    }

    @Transactional
    public FirmwarePackage update(Long id, FirmwarePackage patch, List<String> imeis) {
        FirmwarePackage existing = firmwareRepo.findById(id)
                .orElseThrow(() -> new IllegalArgumentException("firmware not found"));
        if (patch.getAllowUpgrade() != null) {
            existing.setAllowUpgrade(patch.getAllowUpgrade());
        }
        if (patch.getUpgradeAll() != null) {
            existing.setUpgradeAll(patch.getUpgradeAll());
        }
        if (patch.getEnabled() != null) {
            existing.setEnabled(patch.getEnabled());
        }
        if (patch.getRemark() != null) {
            existing.setRemark(patch.getRemark());
        }
        if (patch.getVersion() != null) {
            existing.setVersion(patch.getVersion());
        }
        if (patch.getSourceVersion() != null) {
            existing.setSourceVersion(patch.getSourceVersion());
        }
        FirmwarePackage saved = firmwareRepo.save(existing);
        if (imeis != null) {
            replaceAssignments(saved.getId(), imeis, Boolean.TRUE.equals(saved.getUpgradeAll()));
        }
        return saved;
    }

    @Transactional
    public void delete(Long id) {
        assignmentRepo.deleteByFirmwareId(id);
        firmwareRepo.deleteById(id);
    }

    public List<String> listAssignedImeis(Long firmwareId) {
        return assignmentRepo.findByFirmwareId(firmwareId).stream()
                .map(FirmwareDeviceAssignment::getImei)
                .toList();
    }

    @Transactional
    public FirmwarePackage addAssignments(Long firmwareId, List<String> imeis) {
        FirmwarePackage existing = firmwareRepo.findById(firmwareId)
                .orElseThrow(() -> new IllegalArgumentException("firmware not found"));
        if (imeis == null || imeis.isEmpty()) {
            return existing;
        }
        existing.setUpgradeAll(false);
        firmwareRepo.save(existing);
        for (String imei : imeis) {
            if (!assignmentRepo.existsByFirmwareIdAndImei(firmwareId, imei)) {
                FirmwareDeviceAssignment a = new FirmwareDeviceAssignment();
                a.setFirmwareId(firmwareId);
                a.setImei(imei);
                assignmentRepo.save(a);
            }
        }
        return existing;
    }

    @Transactional
    public FirmwarePackage removeAssignments(Long firmwareId, List<String> imeis) {
        FirmwarePackage existing = firmwareRepo.findById(firmwareId)
                .orElseThrow(() -> new IllegalArgumentException("firmware not found"));
        if (imeis != null && !imeis.isEmpty()) {
            assignmentRepo.deleteByFirmwareIdAndImeiIn(firmwareId, imeis);
        }
        return existing;
    }

    /**
     * 按项目固件库匹配差分包（优先于 manifest）。
     */
    public Optional<MatchResult> findUpgradePackage(String projectKey, String firmwareName,
                                                    String currentVersion, String imei) {
        if (!StringUtils.hasText(firmwareName) || !StringUtils.hasText(currentVersion)) {
            return Optional.empty();
        }
        String current = LuatVersionUtil.normalize(currentVersion);
        Long projectId = resolveProjectId(projectKey);

        List<FirmwarePackage> candidates = firmwareRepo.findCandidates(firmwareName, projectId).stream()
                .filter(fp -> matchesSourceVersion(fp, current))
                .filter(fp -> LuatVersionUtil.canUpgrade(current, fp.getVersion()))
                .filter(fp -> catalog.resolveFirmwareFile(fp.getFileName()).toFile().exists())
                .filter(fp -> isDeviceAllowed(fp, imei))
                .sorted(Comparator.comparing(FirmwarePackage::getVersion, LuatVersionUtil::compare).reversed())
                .toList();

        if (candidates.isEmpty()) {
            return Optional.empty();
        }
        FirmwarePackage best = candidates.get(0);
        return Optional.of(new MatchResult(best, "registry match id=" + best.getId()));
    }

    /**
     * 存在匹配固件但 IMEI 不在指定列表时返回 true（应响应 403）。
     */
    public boolean isDeviceDenied(String projectKey, String firmwareName,
                                  String currentVersion, String imei) {
        if (!StringUtils.hasText(firmwareName) || !StringUtils.hasText(currentVersion)) {
            return false;
        }
        String current = LuatVersionUtil.normalize(currentVersion);
        Long projectId = resolveProjectId(projectKey);

        List<FirmwarePackage> matched = firmwareRepo.findCandidates(firmwareName, projectId).stream()
                .filter(fp -> matchesSourceVersion(fp, current))
                .filter(fp -> LuatVersionUtil.canUpgrade(current, fp.getVersion()))
                .filter(fp -> catalog.resolveFirmwareFile(fp.getFileName()).toFile().exists())
                .toList();

        if (matched.isEmpty()) {
            return false;
        }
        return matched.stream().noneMatch(fp -> isDeviceAllowed(fp, imei));
    }

    public long countPackages() {
        return firmwareRepo.count();
    }

    private Long resolveProjectId(String projectKey) {
        if (!StringUtils.hasText(projectKey)) {
            return null;
        }
        return projectRepo.findByProjectKey(projectKey).map(OtaProject::getId).orElse(null);
    }

    private boolean matchesSourceVersion(FirmwarePackage fp, String current) {
        if (!StringUtils.hasText(fp.getSourceVersion())) {
            return true;
        }
        return LuatVersionUtil.normalize(fp.getSourceVersion()).equals(current);
    }

    private boolean isDeviceAllowed(FirmwarePackage fp, String imei) {
        if (Boolean.TRUE.equals(fp.getUpgradeAll())) {
            return true;
        }
        if (!StringUtils.hasText(imei)) {
            return false;
        }
        return assignmentRepo.existsByFirmwareIdAndImei(fp.getId(), imei);
    }

    private void replaceAssignments(Long firmwareId, List<String> imeis, boolean upgradeAll) {
        assignmentRepo.deleteByFirmwareId(firmwareId);
        assignmentRepo.flush();
        if (upgradeAll || imeis == null) {
            return;
        }
        for (String imei : imeis) {
            if (StringUtils.hasText(imei)) {
                FirmwareDeviceAssignment a = new FirmwareDeviceAssignment();
                a.setFirmwareId(firmwareId);
                a.setImei(imei.trim());
                assignmentRepo.save(a);
            }
        }
    }

    private void applyParsedFilename(String original, FirmwarePackage meta) {
        LuatFilenameParser.parse(original).ifPresent(parsed -> {
            if (!StringUtils.hasText(meta.getFirmwareName())) {
                meta.setFirmwareName(parsed.firmwareName());
            }
            if (!StringUtils.hasText(meta.getVersion())) {
                meta.setVersion(parsed.version());
            }
            if (!StringUtils.hasText(meta.getCoreVersion()) || "0".equals(meta.getCoreVersion())) {
                meta.setCoreVersion(parsed.coreVersion());
            }
            if (!StringUtils.hasText(meta.getRemark())) {
                meta.setRemark(original);
            }
        });
    }

    private void validatePackageMeta(FirmwarePackage meta) {
        if (!StringUtils.hasText(meta.getFirmwareName())) {
            throw new IllegalArgumentException("firmware_name required");
        }
        if (!StringUtils.hasText(meta.getVersion())) {
            throw new IllegalArgumentException("version required");
        }
        if (!LuatVersionUtil.isValid(meta.getVersion())) {
            throw new IllegalArgumentException("version format must be xxx.xxx.xxx");
        }
        if (StringUtils.hasText(meta.getSourceVersion()) && !LuatVersionUtil.isValid(meta.getSourceVersion())) {
            throw new IllegalArgumentException("source_version format invalid");
        }
        if (meta.getFirmwareName().contains(",")) {
            throw new IllegalArgumentException("firmware_name must not contain comma");
        }
    }

    private static String sanitizeFileName(String original) {
        if (!StringUtils.hasText(original) || !original.endsWith(".bin")) {
            throw new IllegalArgumentException("only .bin allowed");
        }
        return original.replaceAll("[^a-zA-Z0-9._-]", "_");
    }
}
