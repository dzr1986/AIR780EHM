package com.luat.ota.service;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class MqttOtaBridgeServiceTest {

    @Test
    void extractImeiFromPanshiTopic() {
        assertEquals("862323084068124",
                MqttOtaBridgeService.extractImei("/panshi/app/862323084068124/event"));
    }

    @Test
    void extractImeiReturnsNullForUnknownTopic() {
        assertNull(MqttOtaBridgeService.extractImei("/other/topic"));
    }
}
