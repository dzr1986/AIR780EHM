package com.luat.videoupload.service;

import com.luat.videoupload.config.UploadProperties;
import org.springframework.stereotype.Service;

import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Map;

/**
 * type 字段：明文 1/2，或 AES-256-ECB PKCS7 + Base64（与 T31x / Python 一致）。
 */
@Service
public class TypeCipherService {

    public static final String TYPE_DETECT = "1";
    public static final String TYPE_PLAYBACK = "2";

    static final Map<String, String> KNOWN_TYPE_B64 = Map.of(
            "E/06stPxcWJoF8IkMn0xYw==", TYPE_DETECT,
            "F8Wslm2+Dd3VlowtNJ5BTg==", TYPE_PLAYBACK
    );

    static final Map<String, String> TYPE_DIR = Map.of(
            TYPE_DETECT, "dynamic",
            TYPE_PLAYBACK, "playback"
    );

    private final UploadProperties properties;

    public TypeCipherService(UploadProperties properties) {
        this.properties = properties;
    }

    public String decryptType(String raw) {
        if (raw == null) {
            return null;
        }
        String text = raw.trim();
        if (text.isEmpty()) {
            return null;
        }
        if (TYPE_DETECT.equals(text) || TYPE_PLAYBACK.equals(text)) {
            return text;
        }
        String mapped = KNOWN_TYPE_B64.get(text);
        if (mapped != null) {
            return mapped;
        }
        try {
            byte[] data = Base64.getDecoder().decode(text);
            byte[] key = properties.getAesKey().getBytes(StandardCharsets.UTF_8);
            Cipher cipher = Cipher.getInstance("AES/ECB/PKCS5Padding");
            cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"));
            String plain = new String(cipher.doFinal(data), StandardCharsets.UTF_8).trim();
            if (TYPE_DETECT.equals(plain) || TYPE_PLAYBACK.equals(plain)) {
                return plain;
            }
        } catch (Exception ignored) {
            // 解不出则 unknown
        }
        return null;
    }

    public String subdirFor(String videoType) {
        return TYPE_DIR.getOrDefault(videoType, "unknown");
    }
}
