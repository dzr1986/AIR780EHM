package com.luat.ota.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.luat.ota.config.OtaProperties;
import com.luat.ota.model.FirmwareManifest;
import com.luat.ota.model.FirmwareRelease;
import com.luat.ota.service.DeviceService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class FirmwareCatalogServiceTest {

    @TempDir
    Path tempDir;

    private FirmwareCatalogService catalog;
    private OtaProperties props;

    @BeforeEach
    void setUp() throws Exception {
        props = new OtaProperties();
        props.setFirmwareDir(tempDir.toString());
        DeviceService deviceService = mock(DeviceService.class);
        when(deviceService.resolveTargetVersion(anyString())).thenReturn(java.util.Optional.empty());
        catalog = new FirmwareCatalogService(props, new ObjectMapper(), deviceService);

        Path bin = tempDir.resolve("dfota_001002_to_001003.bin");
        Files.writeString(bin, "fake-firmware");

        FirmwareManifest manifest = new FirmwareManifest();
        FirmwareRelease release = new FirmwareRelease();
        release.setId("test");
        release.setFirmwareName("PANSHI_CAT1_LuatOS-SoC_Air780EHM");
        release.setSourceVersion("2034.001.002");
        release.setTargetVersion("2034.001.003");
        release.setFile("dfota_001002_to_001003.bin");
        release.setEnabled(true);
        manifest.getReleases().add(release);

        new ObjectMapper().writerWithDefaultPrettyPrinter()
                .writeValue(tempDir.resolve("manifest.json").toFile(), manifest);
        catalog.reload();
    }

    @Test
    void findReleaseBySourceVersion() {
        var found = catalog.findRelease("862323084068124",
                "PANSHI_CAT1_LuatOS-SoC_Air780EHM", "2034.001.002");
        assertTrue(found.isPresent());
        assertEquals("2034.001.003", found.get().getTargetVersion());
    }

    @Test
    void noReleaseWhenSourceMismatch() {
        var found = catalog.findRelease("862323084068124",
                "PANSHI_CAT1_LuatOS-SoC_Air780EHM", "2034.001.001");
        assertTrue(found.isEmpty());
    }
}
