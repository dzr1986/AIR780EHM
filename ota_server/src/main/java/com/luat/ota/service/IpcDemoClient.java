package com.luat.ota.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.luat.ota.config.OtaProperties;
import org.springframework.stereotype.Service;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;

/** 调用云主机 x86demo 的 ipc_upgrade 接口。 */
@Service
public class IpcDemoClient {

    private final OtaProperties props;
    private final ObjectMapper mapper;
    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(8))
            .build();

    public IpcDemoClient(OtaProperties props, ObjectMapper mapper) {
        this.props = props;
        this.mapper = mapper;
    }

    public Map<String, Object> status() {
        return get("/status");
    }

    public Map<String, Object> health() {
        return get("/health");
    }

    public Map<String, Object> task(String sessionId) {
        return get("/api/tasks/" + sessionId);
    }

    public Map<String, Object> upgrade(Map<String, Object> body) {
        return post("/api/ipc_upgrade", body);
    }

    private Map<String, Object> get(String path) {
        try {
            HttpRequest req = HttpRequest.newBuilder(uri(path))
                    .timeout(Duration.ofSeconds(15))
                    .GET()
                    .build();
            HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
            return parse(resp);
        } catch (Exception e) {
            throw new IllegalStateException("ipc x86demo 不可达: " + e.getMessage(), e);
        }
    }

    private Map<String, Object> post(String path, Map<String, Object> body) {
        try {
            String json = mapper.writeValueAsString(body);
            HttpRequest req = HttpRequest.newBuilder(uri(path))
                    .timeout(Duration.ofSeconds(20))
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(json))
                    .build();
            HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
            return parse(resp);
        } catch (IllegalStateException e) {
            throw e;
        } catch (Exception e) {
            throw new IllegalStateException("ipc x86demo 下发失败: " + e.getMessage(), e);
        }
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> parse(HttpResponse<String> resp) {
        if (resp.statusCode() < 200 || resp.statusCode() >= 300) {
            throw new IllegalStateException("x86demo HTTP " + resp.statusCode() + " " + resp.body());
        }
        String raw = resp.body() == null || resp.body().isBlank() ? "{}" : resp.body();
        try {
            return mapper.readValue(raw, Map.class);
        } catch (Exception e) {
            throw new IllegalStateException("x86demo 返回非 JSON: " + raw, e);
        }
    }

    private URI uri(String path) {
        String base = props.getIpcDemoBase() == null ? "http://127.0.0.1:8010" : props.getIpcDemoBase();
        return URI.create(base.replaceAll("/+$", "") + path);
    }
}
