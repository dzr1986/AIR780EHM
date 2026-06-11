package com.luat.ota.config;

import com.luat.ota.entity.OtaProject;
import com.luat.ota.repository.OtaProjectRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

/** 初始化默认项目（对齐 780EHM_PJ main.lua PRODUCT_KEY） */
@Component
public class DataInitializer implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(DataInitializer.class);
    private static final String DEFAULT_KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x";

    private final OtaProjectRepository projectRepo;

    public DataInitializer(OtaProjectRepository projectRepo) {
        this.projectRepo = projectRepo;
    }

    @Override
    public void run(ApplicationArguments args) {
        if (projectRepo.findByProjectKey(DEFAULT_KEY).isEmpty()) {
            OtaProject p = new OtaProject();
            p.setName("合宙标准模块");
            p.setProjectKey(DEFAULT_KEY);
            p.setDescription("780EHM_PJ PANSHI_CAT1 默认项目");
            projectRepo.save(p);
            log.info("seed default project key={}", DEFAULT_KEY);
        }
    }
}
