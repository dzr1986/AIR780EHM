package com.luat.ota.service;

import com.luat.ota.entity.FirmwarePackage;
import com.luat.ota.repository.FirmwareDeviceAssignmentRepository;
import com.luat.ota.repository.FirmwarePackageRepository;
import com.luat.ota.repository.OtaProjectRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.api.io.TempDir;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class FirmwareRegistryServiceTest {

    @TempDir
    Path tempDir;

    @Mock
    private FirmwarePackageRepository firmwareRepo;
    @Mock
    private FirmwareDeviceAssignmentRepository assignmentRepo;
    @Mock
    private OtaProjectRepository projectRepo;
    @Mock
    private FirmwareCatalogService catalog;

    private FirmwareRegistryService registry;

    @BeforeEach
    void setUp() {
        registry = new FirmwareRegistryService(firmwareRepo, assignmentRepo, projectRepo, catalog);
    }

    @Test
    void findUpgradeWhenDeviceAssigned() throws Exception {
        Path bin = tempDir.resolve("test.bin");
        Files.writeString(bin, "fw");

        FirmwarePackage pkg = buildPkg(1L, "2034.001.002", "2034.001.003", false);
        when(firmwareRepo.findCandidates(anyString(), isNull())).thenReturn(List.of(pkg));
        when(catalog.resolveFirmwareFile("test.bin")).thenReturn(bin);
        when(assignmentRepo.existsByFirmwareIdAndImei(1L, "862323084068124")).thenReturn(true);

        Optional<FirmwareRegistryService.MatchResult> result = registry.findUpgradePackage(
                null, "PANSHI_CAT1_LuatOS-SoC_Air780EHM", "2034.001.002", "862323084068124");

        assertTrue(result.isPresent());
        assertEquals("2034.001.003", result.get().pkg().getVersion());
    }

    @Test
    void denyWhenNotAssignedAndNotUpgradeAll() throws Exception {
        Path bin = tempDir.resolve("test.bin");
        Files.writeString(bin, "fw");

        FirmwarePackage pkg = buildPkg(2L, "2034.001.002", "2034.001.003", false);
        when(firmwareRepo.findCandidates(anyString(), isNull())).thenReturn(List.of(pkg));
        when(catalog.resolveFirmwareFile("test.bin")).thenReturn(bin);
        when(assignmentRepo.existsByFirmwareIdAndImei(2L, "862323084068124")).thenReturn(false);

        assertTrue(registry.findUpgradePackage(null, "PANSHI_CAT1_LuatOS-SoC_Air780EHM",
                "2034.001.002", "862323084068124").isEmpty());
        assertTrue(registry.isDeviceDenied(null, "PANSHI_CAT1_LuatOS-SoC_Air780EHM",
                "2034.001.002", "862323084068124"));
    }

    @Test
    void upgradeAllSkipsAssignmentCheck() throws Exception {
        Path bin = tempDir.resolve("test.bin");
        Files.writeString(bin, "fw");

        FirmwarePackage pkg = buildPkg(3L, "2034.001.002", "2034.001.003", true);
        when(firmwareRepo.findCandidates(anyString(), isNull())).thenReturn(List.of(pkg));
        when(catalog.resolveFirmwareFile("test.bin")).thenReturn(bin);

        assertTrue(registry.findUpgradePackage(null, "PANSHI_CAT1_LuatOS-SoC_Air780EHM",
                "2034.001.002", "999999999999999").isPresent());
        assertFalse(registry.isDeviceDenied(null, "PANSHI_CAT1_LuatOS-SoC_Air780EHM",
                "2034.001.002", "999999999999999"));
    }

    @Test
    void addAssignmentsSkipsExistingAndClearsUpgradeAll() {
        FirmwarePackage pkg = buildPkg(4L, "2034.001.002", "2034.001.003", true);
        when(firmwareRepo.findById(4L)).thenReturn(Optional.of(pkg));
        when(firmwareRepo.save(pkg)).thenReturn(pkg);
        when(assignmentRepo.existsByFirmwareIdAndImei(4L, "862323084068231")).thenReturn(false);
        when(assignmentRepo.existsByFirmwareIdAndImei(4L, "862323084068124")).thenReturn(true);

        FirmwarePackage saved = registry.addAssignments(4L,
                List.of("862323084068231", "862323084068124"));

        assertFalse(Boolean.TRUE.equals(saved.getUpgradeAll()));
        verify(assignmentRepo).save(argThat(a -> a != null && "862323084068231".equals(a.getImei())));
    }

    @Test
    void removeAssignmentsDeletesSelected() {
        FirmwarePackage pkg = buildPkg(5L, "2034.001.002", "2034.001.003", false);
        when(firmwareRepo.findById(5L)).thenReturn(Optional.of(pkg));

        registry.removeAssignments(5L, List.of("862323084068231"));

        verify(assignmentRepo).deleteByFirmwareIdAndImeiIn(5L, List.of("862323084068231"));
    }

    private static FirmwarePackage buildPkg(Long id, String src, String ver, boolean upgradeAll) {
        FirmwarePackage pkg = new FirmwarePackage();
        pkg.setId(id);
        pkg.setFirmwareName("PANSHI_CAT1_LuatOS-SoC_Air780EHM");
        pkg.setSourceVersion(src);
        pkg.setVersion(ver);
        pkg.setFileName("test.bin");
        pkg.setAllowUpgrade(true);
        pkg.setUpgradeAll(upgradeAll);
        pkg.setEnabled(true);
        return pkg;
    }
}
