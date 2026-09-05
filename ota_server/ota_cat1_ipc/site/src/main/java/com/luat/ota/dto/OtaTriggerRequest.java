package com.luat.ota.dto;

import java.util.List;

public class OtaTriggerRequest {

    private List<String> imeis;
    private String targetVersion;

    public List<String> getImeis() {
        return imeis;
    }

    public void setImeis(List<String> imeis) {
        this.imeis = imeis;
    }

    public String getTargetVersion() {
        return targetVersion;
    }

    public void setTargetVersion(String targetVersion) {
        this.targetVersion = targetVersion;
    }
}
