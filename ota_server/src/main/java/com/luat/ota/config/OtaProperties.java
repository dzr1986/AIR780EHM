package com.luat.ota.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@ConfigurationProperties(prefix = "luat.ota")
public class OtaProperties {

    private String firmwareDir = "./firmware";
    private String latestVersion = "2034.001.002";
    private String firmwareFile = "";
    private int noUpdateStatus = 404;
    private boolean logRequests = true;
    private boolean auditPersist = true;
    private String auditLogFile = "./logs/ota-audit.jsonl";
    private String adminToken = "changeme";
    private List<String> allowedImeis = new ArrayList<>();
    private Map<String, String> firmwareMap = new HashMap<>();

    public String getFirmwareDir() {
        return firmwareDir;
    }

    public void setFirmwareDir(String firmwareDir) {
        this.firmwareDir = firmwareDir;
    }

    public String getLatestVersion() {
        return latestVersion;
    }

    public void setLatestVersion(String latestVersion) {
        this.latestVersion = latestVersion;
    }

    public String getFirmwareFile() {
        return firmwareFile;
    }

    public void setFirmwareFile(String firmwareFile) {
        this.firmwareFile = firmwareFile;
    }

    public int getNoUpdateStatus() {
        return noUpdateStatus;
    }

    public void setNoUpdateStatus(int noUpdateStatus) {
        this.noUpdateStatus = noUpdateStatus;
    }

    public boolean isLogRequests() {
        return logRequests;
    }

    public void setLogRequests(boolean logRequests) {
        this.logRequests = logRequests;
    }

    public boolean isAuditPersist() {
        return auditPersist;
    }

    public void setAuditPersist(boolean auditPersist) {
        this.auditPersist = auditPersist;
    }

    public String getAuditLogFile() {
        return auditLogFile;
    }

    public void setAuditLogFile(String auditLogFile) {
        this.auditLogFile = auditLogFile;
    }

    public String getAdminToken() {
        return adminToken;
    }

    public void setAdminToken(String adminToken) {
        this.adminToken = adminToken;
    }

    public List<String> getAllowedImeis() {
        return allowedImeis;
    }

    public void setAllowedImeis(List<String> allowedImeis) {
        this.allowedImeis = allowedImeis;
    }

    public Map<String, String> getFirmwareMap() {
        return firmwareMap;
    }

    public void setFirmwareMap(Map<String, String> firmwareMap) {
        this.firmwareMap = firmwareMap;
    }
}
