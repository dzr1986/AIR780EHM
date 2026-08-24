package com.luat.ota.util;

import org.springframework.util.StringUtils;

import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 创建固件时按文件名自动识别固件名、版本号。
 * <p>
 * Luatools 量产/差分常见文件名：
 * {@code PANSHI_CAT1_001.000.010_LuatOS-SoC_V2044_Air780EHM.bin}
 * 对应平台固件名 {@code PANSHI_CAT1_LuatOS-SoC_Air780EHM}，
 * IoT 版本 {@code 2044.001.010}（内核.脚本首段.脚本末段）。
 */
public final class LuatFilenameParser {

    private static final Pattern LUATOOLS = Pattern.compile(
            "^(.+?)_(\\d+\\.\\d+\\.\\d+)_LuatOS-SoC_V?(\\d+)_(Air[A-Za-z0-9]+)",
            Pattern.CASE_INSENSITIVE);
    /** 量产脚本包：PANSHI_CAT1_2044.001.004_LuatOS-SoC_Air780EHM.bin */
    private static final Pattern IOT_BIN = Pattern.compile(
            "^(.+?)_(\\d+\\.\\d+\\.\\d+)_LuatOS-SoC_(Air[A-Za-z0-9]+)",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern NAME_VERSION = Pattern.compile(
            "^(.*)_(\\d+\\.\\d+\\.\\d+)\\.(?:bin|soc|fota)$",
            Pattern.CASE_INSENSITIVE);

    private LuatFilenameParser() {
    }

    public record ParsedFirmware(String firmwareName, String version, String scriptVersion, String coreVersion) {
    }

    public static Optional<ParsedFirmware> parse(String filename) {
        if (!StringUtils.hasText(filename)) {
            return Optional.empty();
        }
        String base = filename.replace('\\', '/');
        int slash = base.lastIndexOf('/');
        if (slash >= 0) {
            base = base.substring(slash + 1);
        }

        Matcher luatools = LUATOOLS.matcher(base);
        if (luatools.find()) {
            String project = luatools.group(1);
            String script = luatools.group(2);
            String core = luatools.group(3);
            String bsp = luatools.group(4);
            String firmwareName = project + "_LuatOS-SoC_" + bsp;
            String iotVersion = toIotVersion(core, script);
            return Optional.of(new ParsedFirmware(firmwareName, iotVersion, script, core));
        }

        Matcher iotBin = IOT_BIN.matcher(base);
        if (iotBin.find()) {
            String project = iotBin.group(1);
            String iotVersion = iotBin.group(2);
            String bsp = iotBin.group(3);
            String firmwareName = project + "_LuatOS-SoC_" + bsp;
            String core = iotVersion.contains(".") ? iotVersion.substring(0, iotVersion.indexOf('.')) : iotVersion;
            return Optional.of(new ParsedFirmware(firmwareName, iotVersion, iotVersion, core));
        }

        Matcher simple = NAME_VERSION.matcher(base);
        if (simple.matches()) {
            String name = simple.group(1);
            String ver = simple.group(2);
            String core = ver.contains(".") ? ver.substring(0, ver.indexOf('.')) : "";
            return Optional.of(new ParsedFirmware(name, ver, ver, core));
        }
        return Optional.empty();
    }

    /** 脚本 001.000.010 + 内核 2044 → IoT 2044.001.010 */
    public static String toIotVersion(String core, String scriptVersion) {
        String script = LuatVersionUtil.normalize(scriptVersion);
        String[] parts = script.split("\\.");
        if (parts.length < 3 || !StringUtils.hasText(core)) {
            return script;
        }
        return core + "." + parts[0] + "." + parts[2];
    }
}
