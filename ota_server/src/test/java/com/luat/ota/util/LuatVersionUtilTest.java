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
    void isValid() {
        assertTrue(LuatVersionUtil.isValid("2034.001.002"));
        assertFalse(LuatVersionUtil.isValid(""));
        assertFalse(LuatVersionUtil.isValid("abc"));
    }
}
