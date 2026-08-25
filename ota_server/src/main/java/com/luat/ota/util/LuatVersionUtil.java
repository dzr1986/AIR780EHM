package com.luat.ota.util;

import org.springframework.util.StringUtils;

/**
 * 版本号工具（平台格式 2034.001.002 / 脚本格式 001.000.002）。
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

    /**
     * 是否允许从 from 升到 to。
     * 脚本 A.B.C：B 无意义；允许 (A2==A1 且 C2&gt;C1) 或 (A2&gt;A1 且 C2&gt;=C1)。
     * 平台格式 core.A.C：禁止 core 回退；core 升高且脚本不变视为仅升内核。
     */
    public static boolean canUpgrade(String from, String to) {
        if (!isValid(from) || !isValid(to)) {
            return false;
        }
        if (compare(to, from) <= 0) {
            return false;
        }
        int[] a = parseParts(from);
        int[] b = parseParts(to);
        if (a.length < 3 || b.length < 3) {
            return compare(to, from) > 0;
        }
        boolean iot = a[0] >= 1000 || b[0] >= 1000;
        int a1;
        int c1;
        int a2;
        int c2;
        int coreFrom = 0;
        int coreTo = 0;
        if (iot) {
            coreFrom = a[0];
            coreTo = b[0];
            a1 = a[1];
            c1 = a[2];
            a2 = b[1];
            c2 = b[2];
            if (coreTo < coreFrom) {
                return false;
            }
        } else {
            a1 = a[0];
            c1 = a[2];
            a2 = b[0];
            c2 = b[2];
        }
        boolean scriptOk = (a2 == a1 && c2 > c1) || (a2 > a1 && c2 >= c1);
        if (iot && coreTo > coreFrom && a2 == a1 && c2 == c1) {
            return true;
        }
        return scriptOk;
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
