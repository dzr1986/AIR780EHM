package com.luat.ota.repository;

import com.luat.ota.entity.OtaTask;
import com.luat.ota.entity.OtaTaskStatus;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface OtaTaskRepository extends JpaRepository<OtaTask, Long> {

    Optional<OtaTask> findByMessageId(String messageId);

    List<OtaTask> findTop100ByOrderByCreatedAtDesc();

    List<OtaTask> findByImeiOrderByCreatedAtDesc(String imei);

    Optional<OtaTask> findFirstByImeiAndStatusInOrderByCreatedAtDesc(String imei, List<OtaTaskStatus> statuses);
}
