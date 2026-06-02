#ifndef RUNTIME_H
#define RUNTIME_H

#include <stdbool.h>
#include <pthread.h>

#include "api.h"

/**
 * T31 主运行时：GPIO/串口已在独立线程；本模块再启「业务工作线程」
 * 循环等待 4G 唤醒 → WAKEVT → 分发（media_ops / client_handle_event）。
 */
typedef struct {
    client_t client;
    pthread_t worker;
    bool worker_started;
    volatile bool stop;
    bool initialized;
    int wake_poll_ms;
} t31_runtime_t;

int t31_runtime_start(t31_runtime_t *rt, const char *config_path);
void t31_runtime_request_stop(t31_runtime_t *rt);
int t31_runtime_join(t31_runtime_t *rt);
void t31_runtime_shutdown(t31_runtime_t *rt);

client_t *t31_runtime_client(t31_runtime_t *rt);
bool t31_runtime_is_running(const t31_runtime_t *rt);

#endif
