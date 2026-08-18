package com.luat.ota.util;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class LuatVersionUtilTest {

    @Test
    void compareIotVersion() {
        assertTrue(LuatVersionUtil.compare("2034.001.002", "2034.001.003") < 0);
        assertTrue(LuatVersionUtil.compare("2034.001.003", "2034.001.002") > 0);
        assertEquals(0, LuatVersionUtil.compare("2034.001.002", "2034.001.002"));
    }

    @Test
    void normalizeStripsVPrefix() {
        assertEquals("2034.001.002", LuatVersionUtil.normalize("V2034.001.002"));
    }

    @Test
    void canUpgradeScriptRules() {
        assertTrue(LuatVersionUtil.canUpgrade("001.000.000", "001.000.001"));
        assertTrue(LuatVersionUtil.canUpgrade("001.000.001", "002.000.200"));
        assertTrue(LuatVersionUtil.canUpgrade("001.000.001", "002.000.001"));
        assertFalse(LuatVersionUtil.canUpgrade("001.000.200", "002.000.001"));
        assertFalse(LuatVersionUtil.canUpgrade("001.000.002", "001.000.002"));
        assertFalse(LuatVersionUtil.canUpgrade("001.000.002", "001.000.001"));
    }

    @Test
    void canUpgradeIotVersion() {
        assertTrue(LuatVersionUtil.canUpgrade("2044.001.002", "2044.001.010"));
        assertTrue(LuatVersionUtil.canUpgrade("2034.001.002", "2044.001.010"));
        assertTrue(LuatVersionUtil.canUpgrade("2044.001.002", "2045.001.002"));
        assertFalse(LuatVersionUtil.canUpgrade("2044.001.010", "2044.001.002"));
        assertFalse(LuatVersionUtil.canUpgrade("2045.001.010", "2044.001.010"));
        assertFalse(LuatVersionUtil.canUpgrade("2044.001.010", "2044.002.001"));
    }
}
