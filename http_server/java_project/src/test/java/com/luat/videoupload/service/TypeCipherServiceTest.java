package com.luat.videoupload.service;

import com.luat.videoupload.config.UploadProperties;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class TypeCipherServiceTest {

    @Test
    void knownCipherAndPlain() {
        UploadProperties props = new UploadProperties();
        TypeCipherService svc = new TypeCipherService(props);
        assertEquals("1", svc.decryptType("1"));
        assertEquals("2", svc.decryptType("2"));
        assertEquals("1", svc.decryptType("E/06stPxcWJoF8IkMn0xYw=="));
        assertEquals("2", svc.decryptType("F8Wslm2+Dd3VlowtNJ5BTg=="));
        assertEquals("dynamic", svc.subdirFor("1"));
        assertEquals("playback", svc.subdirFor("2"));
        assertEquals("unknown", svc.subdirFor("x"));
        assertNull(svc.decryptType(""));
    }
}
