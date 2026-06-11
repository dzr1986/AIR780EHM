package com.luat.ota.repository;

import com.luat.ota.entity.FirmwarePackage;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;

public interface FirmwarePackageRepository extends JpaRepository<FirmwarePackage, Long> {

    List<FirmwarePackage> findByFirmwareNameOrderByCreatedAtDesc(String firmwareName);

    List<FirmwarePackage> findAllByOrderByCreatedAtDesc();

    @Query("""
            SELECT fp FROM FirmwarePackage fp
            WHERE fp.enabled = true AND fp.allowUpgrade = true
              AND fp.firmwareName = :firmwareName
              AND (:projectId IS NULL OR fp.projectId IS NULL OR fp.projectId = :projectId)
            """)
    List<FirmwarePackage> findCandidates(@Param("firmwareName") String firmwareName,
                                         @Param("projectId") Long projectId);
}
