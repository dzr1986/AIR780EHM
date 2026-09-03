package com.luat.ota.repository;

import com.luat.ota.entity.OtaProject;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

public interface OtaProjectRepository extends JpaRepository<OtaProject, Long> {

    Optional<OtaProject> findByProjectKey(String projectKey);
}
