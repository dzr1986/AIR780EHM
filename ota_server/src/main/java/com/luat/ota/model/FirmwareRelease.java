package com.luat.ota.model;

/**
 * 差分包发布条目（manifest.json）。
 * dfota 差分包必须与设备当前版本 sourceVersion 精确匹配。
 */
public class FirmwareRelease {

    private String id = "";
    /** 留空或 * 表示任意 firmware_name */
    private String firmwareName = "";
    /** 设备当前版本（差分起点） */
    private String sourceVersion = "";
    /** 升级目标版本 */
    private String targetVersion = "";
    /** firmware 目录下文件名 */
    private String file = "";
    private boolean enabled = true;
    private String comment = "";

    public String getId() {
        return id;
    }

    public void setId(String id) {
        this.id = id;
    }

    public String getFirmwareName() {
        return firmwareName;
    }

    public void setFirmwareName(String firmwareName) {
        this.firmwareName = firmwareName;
    }

    public String getSourceVersion() {
        return sourceVersion;
    }

    public void setSourceVersion(String sourceVersion) {
        this.sourceVersion = sourceVersion;
    }

    public String getTargetVersion() {
        return targetVersion;
    }

    public void setTargetVersion(String targetVersion) {
        this.targetVersion = targetVersion;
    }

    public String getFile() {
        return file;
    }

    public void setFile(String file) {
        this.file = file;
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getComment() {
        return comment;
    }

    public void setComment(String comment) {
        this.comment = comment;
    }
}
