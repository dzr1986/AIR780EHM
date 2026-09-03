package com.luat.ota.repository;

import com.luat.ota.entity.FirmwareDeviceAssignment;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface FirmwareDeviceAssignmentRepository extends JpaRepository<FirmwareDeviceAssignment, Long> {

    List<FirmwareDeviceAssignment> findByFirmwareId(Long firmwareId);

    boolean existsByFirmwareIdAndImei(Long firmwareId, String imei);

    void deleteByFirmwareId(Long firmwareId);
}
