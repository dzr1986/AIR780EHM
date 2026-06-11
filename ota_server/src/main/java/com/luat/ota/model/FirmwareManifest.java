package com.luat.ota.model;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class FirmwareManifest {

    private List<FirmwareRelease> releases = new ArrayList<>();
    /** 按 IMEI 指定目标版本（灰度/单设备升级） */
    private Map<String, String> deviceTargets = new HashMap<>();

    public List<FirmwareRelease> getReleases() {
        return releases;
    }

    public void setReleases(List<FirmwareRelease> releases) {
        this.releases = releases;
    }

    public Map<String, String> getDeviceTargets() {
        return deviceTargets;
    }

    public void setDeviceTargets(Map<String, String> deviceTargets) {
        this.deviceTargets = deviceTargets;
    }
}
