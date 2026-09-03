package com.luat.ota.util;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ImeiListParserTest {

    @Test
    void parsesOnePerLineAndComma() {
        ImeiListParser.Result r = ImeiListParser.parseDetailed(
                "862323084068231\n862323084068124, 862323084068231\n8623");
        assertEquals(List.of("862323084068231", "862323084068124"), r.valid());
        assertEquals(List.of("8623"), r.invalid());
    }

    @Test
    void acceptsCollection() {
        List<String> got = ImeiListParser.parse(List.of("862323084068231", "bad", "862323084068124"));
        assertEquals(List.of("862323084068231", "862323084068124"), got);
    }

    @Test
    void requireValidThrowsWhenEmpty() {
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
                () -> ImeiListParser.requireValid("abc,12"));
        assertTrue(ex.getMessage().contains("没有合法的 15 位 IMEI"));
    }
}
