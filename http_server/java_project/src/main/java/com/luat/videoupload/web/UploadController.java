package com.luat.videoupload.web;

import com.luat.videoupload.service.VideoStorageService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.Resource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.servlet.HandlerMapping;

import jakarta.servlet.http.HttpServletRequest;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@RestController
public class UploadController {

    private static final Logger LOG = LoggerFactory.getLogger(UploadController.class);
    private static final MediaType TS = MediaType.parseMediaType("video/MP2T");

    private final VideoStorageService storage;

    public UploadController(VideoStorageService storage) {
        this.storage = storage;
    }

    @GetMapping({"/health", "/admin/api/v1/health"})
    public Map<String, Object> health() {
        return ok("ok", Map.of("service", "uploadVideo"));
    }

    @GetMapping(value = {"/", "/admin", "/admin/api/v1"}, produces = MediaType.TEXT_HTML_VALUE)
    public String index() {
        return "<html><body><h3>uploadVideo</h3>"
                + "<p>POST /admin/api/v1/uploadVideo</p>"
                + "<p><a href='/admin/api/v1/videos'>list</a></p>"
                + "</body></html>";
    }

    @GetMapping("/admin/api/v1/videos")
    public Map<String, Object> videos(
            @RequestParam(name = "limit", defaultValue = "50") int limit,
            @RequestParam(name = "type", required = false, defaultValue = "") String type,
            @RequestParam(name = "begin", required = false, defaultValue = "") String begin,
            @RequestParam(name = "end", required = false, defaultValue = "") String end)
            throws Exception {
        List<Map<String, Object>> items = storage.list(limit, type, begin, end);
        return ok("操作成功", items);
    }

    @GetMapping("/apps/video/**")
    public ResponseEntity<?> download(HttpServletRequest request) throws Exception {
        String rest = (String) request.getAttribute(HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE);
        Resource resource = storage.openPublicPath(rest);
        if (resource == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(fail(404, "not found"));
        }
        String name = resource.getFilename() == null ? "clip.ts" : resource.getFilename();
        MediaType ctype = name.toLowerCase().endsWith(".ts") || name.toLowerCase().endsWith(".m2ts")
                ? TS : MediaType.APPLICATION_OCTET_STREAM;
        return ResponseEntity.ok()
                .contentType(ctype)
                .header(HttpHeaders.CONTENT_DISPOSITION, "inline; filename=\"" + name + "\"")
                .contentLength(resource.contentLength())
                .body(resource);
    }

    @PostMapping(value = "/admin/api/v1/uploadVideo", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<Map<String, Object>> upload(
            @RequestParam(name = "type", required = false, defaultValue = "") String type,
            @RequestParam(name = "file", required = false) MultipartFile file,
            HttpServletRequest request) {
        try {
            if (file == null) {
                return ResponseEntity.badRequest().body(fail(400, "missing file"));
            }
            String ip = request.getRemoteAddr();
            Map<String, Object> data = storage.save(type, file, ip);
            LOG.info("saved {} type={} size={} from={}",
                    data.get("path"), data.get("type"), data.get("size"), ip);
            return ResponseEntity.ok(ok("操作成功", data));
        } catch (IllegalArgumentException ex) {
            return ResponseEntity.badRequest().body(fail(400, ex.getMessage()));
        } catch (IllegalStateException ex) {
            return ResponseEntity.status(HttpStatus.PAYLOAD_TOO_LARGE).body(fail(413, ex.getMessage()));
        } catch (Exception ex) {
            LOG.error("upload error", ex);
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(fail(500, "upload failed"));
        }
    }

    private static Map<String, Object> ok(String msg, Object data) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("code", 200);
        body.put("msg", msg);
        body.put("data", data);
        return body;
    }

    private static Map<String, Object> fail(int code, String msg) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("code", code);
        body.put("msg", msg);
        return body;
    }
}
