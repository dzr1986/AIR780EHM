package com.luat.videoupload.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.luat.videoupload.config.UploadProperties;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.Resource;
import org.springframework.stereotype.Service;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.stream.Stream;

@Service
public class VideoStorageService {

    private static final ZoneId TZ_CN = ZoneId.of("Asia/Shanghai");
    private static final DateTimeFormatter STAMP = DateTimeFormatter.ofPattern("yyyyMMddHHmmss");

    private final UploadProperties properties;
    private final TypeCipherService typeCipher;
    private final ObjectMapper objectMapper;

    public VideoStorageService(
            UploadProperties properties,
            TypeCipherService typeCipher,
            ObjectMapper objectMapper) {
        this.properties = properties;
        this.typeCipher = typeCipher;
        this.objectMapper = objectMapper;
    }

    public Path incomingRoot() {
        return Path.of(properties.getDir()).toAbsolutePath().normalize();
    }

    public Map<String, Object> save(String typeField, MultipartFile file, String clientIp) throws IOException {
        if (file == null || file.isEmpty()) {
            throw new IllegalArgumentException("missing file");
        }
        long declared = file.getSize();
        if (declared > properties.getMaxBytes()) {
            throw new IllegalStateException("file too large");
        }

        String videoType = typeCipher.decryptType(typeField);
        if (videoType == null) {
            videoType = "unknown";
        }
        String subdir = typeCipher.subdirFor(videoType);
        String orig = safeFilename(file.getOriginalFilename());
        String stamp = OffsetDateTime.now(TZ_CN).format(STAMP)
                + String.format(Locale.ROOT, "%03d", System.currentTimeMillis() % 1000);
        int dot = orig.lastIndexOf('.');
        String stem = dot > 0 ? orig.substring(0, dot) : orig;
        String ext = dot > 0 ? orig.substring(dot) : ".ts";
        String realName = stem + "-" + stamp + ext;

        Path destDir = incomingRoot().resolve(subdir);
        Files.createDirectories(destDir);
        Path dest = destDir.resolve(realName);

        long size = 0;
        try (InputStream in = file.getInputStream();
             OutputStream out = Files.newOutputStream(dest)) {
            byte[] buf = new byte[1024 * 1024];
            int n;
            while ((n = in.read(buf)) >= 0) {
                if (n == 0) {
                    continue;
                }
                size += n;
                if (size > properties.getMaxBytes()) {
                    out.close();
                    Files.deleteIfExists(dest);
                    throw new IllegalStateException("file too large");
                }
                out.write(buf, 0, n);
            }
        }
        if (size <= 0) {
            Files.deleteIfExists(dest);
            throw new IllegalArgumentException("empty file");
        }

        String relPath = "/apps/video/" + subdir + "/" + realName;
        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("realName", realName);
        meta.put("origName", orig);
        meta.put("type", videoType);
        meta.put("typeCipher", typeField);
        meta.put("path", relPath);
        meta.put("sizeBytes", size);
        meta.put("size", humanSize(size));
        meta.put("client", clientIp);
        meta.put("savedAt", OffsetDateTime.now(TZ_CN).toString());
        Path sidecar = dest.resolveSibling(dest.getFileName().toString() + ".json");
        objectMapper.writerWithDefaultPrettyPrinter().writeValue(sidecar.toFile(), meta);

        Map<String, Object> data = new LinkedHashMap<>();
        data.put("realName", realName);
        data.put("path", relPath);
        data.put("size", humanSize(size));
        data.put("type", videoType);
        return data;
    }

    public List<Map<String, Object>> list(int limit, String typeFilter, String begin, String end) throws IOException {
        int cap = Math.min(200, Math.max(1, limit));
        Path root = incomingRoot();
        if (!Files.isDirectory(root)) {
            return List.of();
        }
        List<Path> files;
        try (Stream<Path> walk = Files.walk(root)) {
            files = walk
                    .filter(Files::isRegularFile)
                    .filter(p -> !p.getFileName().toString().endsWith(".json"))
                    .sorted(Comparator.comparingLong((Path p) -> p.toFile().lastModified()).reversed())
                    .toList();
        }
        List<Map<String, Object>> items = new ArrayList<>();
        for (Path f : files) {
            String rel = "/" + root.relativize(f).toString().replace('\\', '/');
            String vtype = rel.startsWith("/playback/") ? "2"
                    : rel.startsWith("/dynamic/") ? "1" : "";
            if (("1".equals(typeFilter) || "2".equals(typeFilter)) && !typeFilter.equals(vtype)) {
                continue;
            }
            OffsetDateTime mtime = OffsetDateTime.ofInstant(
                    Files.getLastModifiedTime(f).toInstant(), TZ_CN);
            if (!inRange(mtime, begin, end)) {
                continue;
            }
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("name", f.getFileName().toString());
            item.put("path", "/apps/video" + rel);
            item.put("size", humanSize(Files.size(f)));
            item.put("mtime", mtime.toString());
            item.put("type", vtype.isEmpty() ? "unknown" : vtype);
            items.add(item);
            if (items.size() >= cap) {
                break;
            }
        }
        return items;
    }

    public Resource openPublicPath(String publicPath) throws IOException {
        String rel = publicPath;
        if (rel.startsWith("/apps/video/")) {
            rel = rel.substring("/apps/video/".length());
        }
        rel = rel.replace('\\', '/');
        while (rel.startsWith("/")) {
            rel = rel.substring(1);
        }
        Path root = incomingRoot();
        Path target = root.resolve(rel).normalize();
        if (!target.startsWith(root) || !Files.isRegularFile(target)
                || target.getFileName().toString().endsWith(".json")) {
            return null;
        }
        return new FileSystemResource(target);
    }

    private static boolean inRange(OffsetDateTime mtime, String begin, String end) {
        if (begin != null && !begin.isBlank()) {
            try {
                if (mtime.isBefore(parseWall(begin))) {
                    return false;
                }
            } catch (Exception ignored) {
            }
        }
        if (end != null && !end.isBlank()) {
            try {
                if (mtime.isAfter(parseWall(end))) {
                    return false;
                }
            } catch (Exception ignored) {
            }
        }
        return true;
    }

    private static OffsetDateTime parseWall(String text) {
        String iso = text.trim().replace(' ', 'T');
        if (iso.length() == 10) {
            iso = iso + "T00:00:00";
        }
        if (iso.endsWith("Z") || iso.contains("+")) {
            return OffsetDateTime.parse(iso);
        }
        return LocalDateTime.parse(iso).atZone(TZ_CN).toOffsetDateTime();
    }

    static String safeFilename(String name) {
        String base = name == null ? "" : name.replace('\\', '/');
        int slash = base.lastIndexOf('/');
        if (slash >= 0) {
            base = base.substring(slash + 1);
        }
        base = base.replaceAll("[^A-Za-z0-9._-]+", "_");
        if (base.isEmpty() || ".".equals(base) || "..".equals(base)) {
            base = "clip.ts";
        }
        if (base.length() > 160) {
            int dot = base.lastIndexOf('.');
            String ext = dot > 0 ? base.substring(dot) : ".ts";
            String stem = dot > 0 ? base.substring(0, dot) : base;
            base = stem.substring(0, Math.min(140, stem.length())) + ext;
        }
        return base;
    }

    static String humanSize(long n) {
        double mb = n / (1024.0 * 1024.0);
        if (mb >= 0.01) {
            return String.format(Locale.ROOT, "%.2fMB", mb);
        }
        return n + "B";
    }
}
