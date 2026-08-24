package com.luat.ota.repository;

import com.luat.ota.entity.OtaTask;
import com.luat.ota.entity.OtaTaskStatus;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface OtaTaskRepository extends JpaRepository<OtaTask, Long> {

    Optional<OtaTask> findByMessageId(String messageId);

    List<OtaTask> findTop100ByOrderByCreatedAtDesc();

    List<OtaTask> findByImeiOrderByCreatedAtDesc(String imei);

    List<OtaTask> findByImeiContainingOrderByCreatedAtDesc(String imei);

    Page<OtaTask> findAllByOrderByCreatedAtDesc(Pageable pageable);

    Page<OtaTask> findByImeiContainingOrderByCreatedAtDesc(String imei, Pageable pageable);

    Page<OtaTask> findByStatusOrderByCreatedAtDesc(OtaTaskStatus status, Pageable pageable);

    Page<OtaTask> findByImeiContainingAndStatusOrderByCreatedAtDesc(String imei, OtaTaskStatus status, Pageable pageable);

    Optional<OtaTask> findFirstByImeiAndStatusInOrderByCreatedAtDesc(String imei, List<OtaTaskStatus> statuses);
}
