package com.luat.ota.config;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@EnableConfigurationProperties({OtaProperties.class, MqttProperties.class})
public class OtaConfig {
}
