package com.luat.ota.util;

import org.springframework.util.StringUtils;

/**
 * 合宙 Luat 版本号工具（IoT 格式 2034.001.002 / 脚本格式 001.000.002）。
 */
public final class LuatVersionUtil {

    private LuatVersionUtil() {
    }

    public static String normalize(String version) {
        if (!StringUtils.hasText(version)) {
            return "";
        }
        String v = version.trim();
        if (v.startsWith("V") || v.startsWith("v")) {
            v = v.substring(1);
        }
        return v;
    }

    /** @return 负数 a&lt;b，0 相等，正数 a&gt;b */
    public static int compare(String a, String b) {
        int[] pa = parseParts(a);
        int[] pb = parseParts(b);
        int len = Math.max(pa.length, pb.length);
        for (int i = 0; i < len; i++) {
            int va = i < pa.length ? pa[i] : 0;
            int vb = i < pb.length ? pb[i] : 0;
            if (va != vb) {
                return Integer.compare(va, vb);
            }
        }
        return 0;
    }

    public static boolean isValid(String version) {
        String normalized = normalize(version);
        if (!StringUtils.hasText(normalized)) {
            return false;
        }
        return normalized.matches("\\d+(\\.\\d+)*");
    }

    private static int[] parseParts(String version) {
        String normalized = normalize(version);
        if (!isValid(normalized)) {
            throw new IllegalArgumentException("invalid version: " + version);
        }
        String[] tokens = normalized.split("\\.");
        int[] parts = new int[tokens.length];
        for (int i = 0; i < tokens.length; i++) {
            parts[i] = Integer.parseInt(tokens[i]);
        }
        return parts;
    }
}
