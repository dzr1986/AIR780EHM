package com.luat.videoupload;

import com.luat.videoupload.config.UploadProperties;
import com.luat.videoupload.service.VideoStorageService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.core.env.Environment;

@SpringBootApplication
@EnableConfigurationProperties(UploadProperties.class)
public class VideoUploadApplication {

    private static final Logger LOG = LoggerFactory.getLogger(VideoUploadApplication.class);

    public static void main(String[] args) {
        SpringApplication.run(VideoUploadApplication.class, args);
    }

    @Bean
    ApplicationRunner logListen(Environment env, VideoStorageService storage) {
        return args -> LOG.info(
                "uploadVideo listening on http://{}:{}/admin/api/v1/uploadVideo dir={}",
                env.getProperty("server.address", "0.0.0.0"),
                env.getProperty("server.port", "7003"),
                storage.incomingRoot());
    }
}

