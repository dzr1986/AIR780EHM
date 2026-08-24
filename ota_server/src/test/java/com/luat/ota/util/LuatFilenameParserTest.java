package com.luat.ota.util;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class LuatFilenameParserTest {

    @Test
    void parseLuatoolsSocName() {
        var parsed = LuatFilenameParser.parse(
                "PANSHI_CAT1_001.000.010_LuatOS-SoC_V2044_Air780EHM.bin").orElseThrow();
        assertEquals("PANSHI_CAT1_LuatOS-SoC_Air780EHM", parsed.firmwareName());
        assertEquals("2044.001.010", parsed.version());
        assertEquals("001.000.010", parsed.scriptVersion());
        assertEquals("2044", parsed.coreVersion());
    }

    @Test
    void parseMassProdIotBin() {
        var parsed = LuatFilenameParser.parse(
                "PANSHI_CAT1_2044.001.004_LuatOS-SoC_Air780EHM.bin").orElseThrow();
        assertEquals("PANSHI_CAT1_LuatOS-SoC_Air780EHM", parsed.firmwareName());
        assertEquals("2044.001.004", parsed.version());
        assertEquals("2044", parsed.coreVersion());
    }

    @Test
    void parseNameVersionFallback() {
        var parsed = LuatFilenameParser.parse("fotademo_LuatOS-SoC_AIR601_1.2.99.bin").orElseThrow();
        assertEquals("fotademo_LuatOS-SoC_AIR601", parsed.firmwareName());
        assertEquals("1.2.99", parsed.version());
    }

    @Test
    void emptyName() {
        assertTrue(LuatFilenameParser.parse("").isEmpty());
        assertTrue(LuatFilenameParser.parse("readme.txt").isEmpty());
    }
}
