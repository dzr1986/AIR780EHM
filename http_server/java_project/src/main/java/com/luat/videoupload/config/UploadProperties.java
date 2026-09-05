package com.luat.videoupload.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "video.upload")
public class UploadProperties {

    /** 落盘根目录，下分 dynamic / playback */
    private String dir = "incoming";
    private String aesKey = "7f3A9c82D1e64B5F90a7C3d8E2F6b410";
    private long maxBytes = 400L * 1024 * 1024;

    public String getDir() {
        return dir;
    }

    public void setDir(String dir) {
        this.dir = dir;
    }

    public String getAesKey() {
        return aesKey;
    }

    public void setAesKey(String aesKey) {
        this.aesKey = aesKey;
    }

    public long getMaxBytes() {
        return maxBytes;
    }

    public void setMaxBytes(long maxBytes) {
        this.maxBytes = maxBytes;
    }
}
