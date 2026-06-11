package com.luat.ota.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.luat.ota.config.OtaProperties;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;
import java.util.concurrent.ConcurrentLinkedDeque;

/** OTA 检查审计：内存环形缓冲 + 追加写入 logs/ota-audit.jsonl */
@Service
public class OtaAuditService {

    private static final Logger log = LoggerFactory.getLogger(OtaAuditService.class);
    private static final int MAX_MEMORY = 500;

    private final OtaProperties props;
    private final ObjectMapper objectMapper;
    private final Deque<OtaAuditRecord> recent = new ConcurrentLinkedDeque<>();

    public OtaAuditService(OtaProperties props, ObjectMapper objectMapper) {
        this.props = props;
        this.objectMapper = objectMapper;
    }

    @PostConstruct
    public void init() throws IOException {
        Path logFile = auditLogPath();
        Files.createDirectories(logFile.getParent());
        if (!Files.exists(logFile)) {
            Files.createFile(logFile);
        }
    }

    public void record(OtaAuditRecord record) {
        recent.addFirst(record);
        while (recent.size() > MAX_MEMORY) {
            recent.removeLast();
        }
        if (props.isAuditPersist()) {
            appendToFile(record);
        }
    }

    public List<OtaAuditRecord> recent(int limit) {
        int max = Math.max(1, Math.min(limit, MAX_MEMORY));
        List<OtaAuditRecord> list = new ArrayList<>();
        int count = 0;
        for (OtaAuditRecord r : recent) {
            list.add(r);
            if (++count >= max) {
                break;
            }
        }
        return list;
    }

    public OtaStats stats() {
        long upgrade = recent.stream().filter(r -> "UPGRADE".equals(r.decision())).count();
        long noUpdate = recent.stream().filter(r -> "NO_UPDATE".equals(r.decision())).count();
        long failed = recent.stream().filter(r -> "FORBIDDEN".equals(r.decision()) || "NOT_FOUND".equals(r.decision())).count();
        return new OtaStats(recent.size(), upgrade, noUpdate, failed);
    }

    public record OtaAuditRecord(
            Instant time,
            String deviceId,
            String imei,
            String firmwareName,
            String currentVersion,
            String targetVersion,
            String decision,
            String message,
            String clientIp
    ) {
    }

    public record OtaStats(long totalRecent, long upgrade, long noUpdate, long failed) {
    }

    private void appendToFile(OtaAuditRecord record) {
        try {
            String line = objectMapper.writeValueAsString(record) + System.lineSeparator();
            Files.writeString(auditLogPath(), line, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (IOException e) {
            log.warn("audit append failed", e);
        }
    }

    private Path auditLogPath() {
        return Paths.get(props.getAuditLogFile()).toAbsolutePath().normalize();
    }
}
