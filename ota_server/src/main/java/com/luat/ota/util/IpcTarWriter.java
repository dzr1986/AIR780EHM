package com.luat.ota.util;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** 把单个文件打成 ustar，对齐 pack_tool 的 ipc.tar。 */
public final class IpcTarWriter {

    private IpcTarWriter() {
    }

    public static boolean looksLikeTar(byte[] data) {
        if (data == null || data.length < 265) {
            return false;
        }
        String magic = new String(data, 257, 5, StandardCharsets.US_ASCII);
        return "ustar".equals(magic);
    }

    public static byte[] wrapSingleFile(String fileName, byte[] payload) {
        byte[] body = payload == null ? new byte[0] : payload;
        String name = fileName == null || fileName.isBlank() ? "payload.bin" : fileName;
        int slash = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
        if (slash >= 0) {
            name = name.substring(slash + 1);
        }
        if (name.length() > 100) {
            name = name.substring(0, 100);
        }
        int dataBlocks = (body.length + 511) / 512;
        byte[] out = new byte[512 + dataBlocks * 512 + 1024];
        byte[] hdr = new byte[512];
        putString(hdr, 0, 100, name);
        putOctal(hdr, 100, 8, 0644);
        putOctal(hdr, 108, 8, 0);
        putOctal(hdr, 116, 8, 0);
        putOctal(hdr, 124, 12, body.length);
        putOctal(hdr, 136, 12, System.currentTimeMillis() / 1000);
        Arrays.fill(hdr, 148, 156, (byte) ' ');
        hdr[156] = '0';
        putString(hdr, 257, 6, "ustar");
        hdr[263] = '0';
        hdr[264] = '0';
        int sum = 0;
        for (byte b : hdr) {
            sum += b & 0xff;
        }
        putOctal(hdr, 148, 7, sum);
        hdr[155] = ' ';
        System.arraycopy(hdr, 0, out, 0, 512);
        System.arraycopy(body, 0, out, 512, body.length);
        return out;
    }

    private static void putString(byte[] buf, int off, int len, String value) {
        byte[] raw = value.getBytes(StandardCharsets.US_ASCII);
        System.arraycopy(raw, 0, buf, off, Math.min(raw.length, len - 1));
    }

    private static void putOctal(byte[] buf, int off, int len, long value) {
        String s = Long.toOctalString(value);
        int digits = len - 1;
        Arrays.fill(buf, off, off + len, (byte) '0');
        if (s.length() > digits) {
            s = s.substring(s.length() - digits);
        }
        int start = off + digits - s.length();
        for (int i = 0; i < s.length(); i++) {
            buf[start + i] = (byte) s.charAt(i);
        }
        buf[off + len - 1] = 0;
    }
}
