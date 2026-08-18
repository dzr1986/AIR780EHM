package com.luat.ota.dto;

public class LoopTestRequest {

    private String imei = "862323084068999";
    private String projectKey = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x";
    private String firmwareName = "PANSHI_CAT1_LuatOS-SoC_Air780EHM";
    private String sourceVersion = "2044.001.002";
    private String targetVersion = "2044.001.010";

    public String getImei() { return imei; }
    public void setImei(String imei) { this.imei = imei; }
    public String getProjectKey() { return projectKey; }
    public void setProjectKey(String projectKey) { this.projectKey = projectKey; }
    public String getFirmwareName() { return firmwareName; }
    public void setFirmwareName(String firmwareName) { this.firmwareName = firmwareName; }
    public String getSourceVersion() { return sourceVersion; }
    public void setSourceVersion(String sourceVersion) { this.sourceVersion = sourceVersion; }
    public String getTargetVersion() { return targetVersion; }
    public void setTargetVersion(String targetVersion) { this.targetVersion = targetVersion; }
}
