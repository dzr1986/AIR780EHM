package com.luat.ota.repository;

import com.luat.ota.entity.Device;
import com.luat.ota.entity.DeviceOtaStatus;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;
import java.util.Optional;

public interface DeviceRepository extends JpaRepository<Device, Long> {

    Optional<Device> findByImei(String imei);

    List<Device> findByOtaEnabledTrue();

    @Query("select d from Device d where d.otaEnabled = true and d.targetVersion is not null")
    List<Device> findUpgradeCandidates();

    long countByOtaStatus(DeviceOtaStatus status);
}
