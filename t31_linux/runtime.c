#include <stdio.h>
#include <string.h>

#include "log.h"
#include "media_ops.h"
#include "runtime.h"

#define RUNTIME_WAKE_POLL_MS 1000

static void log_pir_stat(client_t *client)
{
    char pir_resp[MAX_RESP_SIZE];

    if (client_get_pir_stat(client, pir_resp, sizeof(pir_resp)) == 0) {
        log_print("APP", "4G PIRSTAT: %s", pir_resp);
    } else {
        log_print("WARN", "AT+PIRSTAT? failed");
    }
}

static void *runtime_worker_main(void *arg)
{
    t31_runtime_t *rt = (t31_runtime_t *)arg;
    client_t *client = &rt->client;

    log_print("APP", "runtime worker started");
    media_ops_bind_client(client);

    while (!rt->stop) {
        wake_event_t event;
        int ret = client_wait_wakeup(client, &event, rt->wake_poll_ms);

        if (rt->stop) {
            break;
        }
        if (ret < 0) {
            log_print("ERR", "wait wakeup failed");
            break;
        }
        if (ret == 0) {
            continue;
        }

        if (!event.valid) {
            log_print("APP", "wake gpio but WAKEVT empty");
            continue;
        }

        log_print("APP", "wake sid=%d evt=%d", event.sid, event.evt);
        log_pir_stat(client);

        if (event.evt == EVT_SERVER_DATA) {
            if (media_dispatch_wake_event(client, &event) != 0) {
                log_print("ERR", "media dispatch failed");
            }
        } else if (client_handle_event(client, &event) != 0) {
            log_print("ERR", "handle event failed");
        }

        log_print("APP", "wake cycle done");
    }

    log_print("APP", "runtime worker exit");
    return NULL;
}

int t31_runtime_start(t31_runtime_t *rt, const char *config_path)
{
    if (rt == NULL) {
        return -1;
    }
    memset(rt, 0, sizeof(*rt));
    rt->wake_poll_ms = RUNTIME_WAKE_POLL_MS;

    if (client_init(&rt->client, config_path) != 0) {
        return -1;
    }
    rt->initialized = true;
    media_ops_bind_client(&rt->client);

    if (pthread_create(&rt->worker, NULL, runtime_worker_main, rt) != 0) {
        log_print("ERR", "create runtime worker failed");
        client_shutdown(&rt->client);
        rt->initialized = false;
        return -1;
    }
    rt->worker_started = true;
    return 0;
}

void t31_runtime_request_stop(t31_runtime_t *rt)
{
    if (rt == NULL) {
        return;
    }
    rt->stop = true;
}

int t31_runtime_join(t31_runtime_t *rt)
{
    if (rt == NULL || !rt->worker_started) {
        return 0;
    }
    return pthread_join(rt->worker, NULL);
}

void t31_runtime_shutdown(t31_runtime_t *rt)
{
    if (rt == NULL) {
        return;
    }
    t31_runtime_request_stop(rt);
    t31_runtime_join(rt);
    if (rt->initialized) {
        client_shutdown(&rt->client);
        rt->initialized = false;
    }
}

client_t *t31_runtime_client(t31_runtime_t *rt)
{
    if (rt == NULL || !rt->initialized) {
        return NULL;
    }
    return &rt->client;
}

bool t31_runtime_is_running(const t31_runtime_t *rt)
{
    return rt != NULL && rt->worker_started && !rt->stop;
}
