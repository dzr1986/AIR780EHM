package com.luat.ota.config;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.servlet.HandlerInterceptor;

@Component
public class AdminAuthInterceptor implements HandlerInterceptor {

    private final OtaProperties props;

    public AdminAuthInterceptor(OtaProperties props) {
        this.props = props;
    }

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) throws Exception {
        String configured = props.getAdminToken();
        if (!StringUtils.hasText(configured)) {
            response.sendError(HttpStatus.SERVICE_UNAVAILABLE.value(), "admin api disabled (set luat.ota.admin-token)");
            return false;
        }
        String token = request.getHeader("X-Admin-Token");
        if (!configured.equals(token)) {
            response.sendError(HttpStatus.UNAUTHORIZED.value(), "invalid admin token");
            return false;
        }
        return true;
    }
}
