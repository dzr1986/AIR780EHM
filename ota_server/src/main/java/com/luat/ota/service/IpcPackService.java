package com.luat.ota.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.luat.ota.config.OtaProperties;
import com.luat.ota.util.IpcTarWriter;
import org.springframework.stereotype.Service;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** 把上传文件写成 /downloads/ipc.tar + ipc.json。 */
@Service
public class IpcPackService {

    private final OtaProperties props;
    private final ObjectMapper mapper;

    public IpcPackService(OtaProperties props, ObjectMapper mapper) {
        this.props = props;
        this.mapper = mapper.copy().enable(SerializationFeature.INDENT_OUTPUT);
    }

    public Path fileDir() throws IOException {
        Path dir = Path.of(props.getIpcFileDir()).toAbsolutePath();
        Files.createDirectories(dir);
        return dir;
    }

    public String publicTarUrl() {
        String base = props.getIpcPublicDownloadBase();
        if (base == null || base.isBlank()) {
            base = "http://43.136.55.143:8008";
        }
        return base.replaceAll("/+$", "") + "/downloads/ipc.tar";
    }

    public String publicJsonUrl() {
        return publicTarUrl().replace("ipc.tar", "ipc.json");
    }

    public Map<String, Object> storeUpload(MultipartFile file, String version) throws Exception {
        if (file == null || file.isEmpty()) {
            throw new IllegalArgumentException("请选择 IPC 文件");
        }
        String ver = (version == null || version.isBlank()) ? "1.0.30" : version.trim();
        String original = file.getOriginalFilename() == null ? "payload.bin" : file.getOriginalFilename();
        byte[] raw = file.getBytes();
        byte[] tarBytes;
        String lower = original.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".tar") || IpcTarWriter.looksLikeTar(raw)) {
            tarBytes = raw;
        } else {
            tarBytes = IpcTarWriter.wrapSingleFile(original, raw);
        }
        Path dir = fileDir();
        Path tar = dir.resolve("ipc.tar");
        Files.write(tar, tarBytes);
        String md5 = md5Hex(tarBytes);
        Map<String, Object> manifest = new LinkedHashMap<>();
        manifest.put("name", "ipc");
        manifest.put("version", ver);
        manifest.put("url", publicTarUrl());
        manifest.put("file", "ipc.tar");
        manifest.put("md5", md5);
        manifest.put("size", tarBytes.length);
        Files.writeString(dir.resolve("ipc.json"), mapper.writeValueAsString(manifest) + "\n");
        Map<String, Object> out = new LinkedHashMap<>(manifest);
        out.put("filename", "ipc.tar");
        out.put("url8008", publicTarUrl());
        out.put("url80", publicTarUrl().replace(":8008", ""));
        out.put("jsonUrl", publicJsonUrl());
        out.put("sourceName", original);
        return out;
    }

    public List<Map<String, Object>> listPackages() throws IOException {
        List<Map<String, Object>> files = new ArrayList<>();
        Path dir = fileDir();
        if (!Files.isDirectory(dir)) {
            return files;
        }
        try (var stream = Files.list(dir)) {
            stream.filter(Files::isRegularFile)
                    .filter(p -> !".gitkeep".equals(p.getFileName().toString()))
                    .sorted()
                    .forEach(p -> {
                        Map<String, Object> row = new LinkedHashMap<>();
                        row.put("filename", p.getFileName().toString());
                        try {
                            row.put("size", Files.size(p));
                        } catch (IOException e) {
                            row.put("size", 0);
                        }
                        files.add(row);
                    });
        }
        return files;
    }

    public byte[] readFile(String name) throws IOException {
        if (!"ipc.tar".equals(name) && !"ipc.json".equals(name)) {
            throw new IllegalArgumentException("只允许下载 ipc.tar / ipc.json");
        }
        Path path = fileDir().resolve(name);
        if (!Files.exists(path)) {
            throw new IllegalArgumentException(name + " 还不存在，请先上传");
        }
        return Files.readAllBytes(path);
    }

    public static String md5Hex(byte[] data) throws Exception {
        byte[] digest = MessageDigest.getInstance("MD5").digest(data);
        return HexFormat.of().formatHex(digest);
    }
}
