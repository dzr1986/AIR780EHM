package com.luat.ota.util;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * 批量 IMEI：一行一个、逗号/空白分隔，只保留 15 位数字。
 */
public final class ImeiListParser {

    private static final Pattern SPLIT = Pattern.compile("[,;，、\\s]+");
    private static final Pattern IMEI = Pattern.compile("\\d{15}");

    private ImeiListParser() {
    }

    public record Result(List<String> valid, List<String> invalid) {
        public boolean isEmpty() {
            return valid.isEmpty();
        }
    }

    public static Result parseDetailed(Object raw) {
        Set<String> valid = new LinkedHashSet<>();
        List<String> invalid = new ArrayList<>();
        for (String token : tokens(raw)) {
            if (IMEI.matcher(token).matches()) {
                valid.add(token);
            } else {
                invalid.add(token);
            }
        }
        return new Result(List.copyOf(valid), List.copyOf(invalid));
    }

    public static List<String> parse(Object raw) {
        return parseDetailed(raw).valid();
    }

    public static List<String> requireValid(Object raw) {
        Result parsed = parseDetailed(raw);
        if (parsed.valid().isEmpty()) {
            String extra = parsed.invalid().isEmpty()
                    ? ""
                    : "，无效：" + String.join(", ", parsed.invalid());
            throw new IllegalArgumentException("没有合法的 15 位 IMEI" + extra);
        }
        return parsed.valid();
    }

    private static List<String> tokens(Object raw) {
        if (raw == null) {
            return List.of();
        }
        if (raw instanceof Collection<?> col) {
            List<String> out = new ArrayList<>();
            for (Object item : col) {
                if (item != null) {
                    out.addAll(tokens(String.valueOf(item)));
                }
            }
            return out;
        }
        String text = String.valueOf(raw).trim();
        if (text.isEmpty() || "null".equalsIgnoreCase(text)) {
            return List.of();
        }
        String[] parts = SPLIT.split(text);
        List<String> out = new ArrayList<>();
        for (String part : parts) {
            String token = part.trim();
            if (!token.isEmpty()) {
                out.add(token);
            }
        }
        return out;
    }
}
