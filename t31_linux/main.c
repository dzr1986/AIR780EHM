#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "api.h"
#include "log.h"
#include "media_ops.h"
#include "runtime.h"

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

static void print_usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [config.ini|config.json]\n"
            "Example: %s client.ini\n",
            prog, prog);
}

/*
 * 产品层可在此实现真实拍照/录像，并 media_ops_register()。
 * 其他模块也可在运行时直接调用 media_snapshot() / media_record_start() 等。
 */
static int product_snapshot(client_t *client, const media_capture_opts_t *opts, const wake_event_t *event)
{
    (void)client;
    (void)event;
    log_print("PRODUCT", "ISP capture action=%d quality=%d", (int)opts->action, (int)opts->quality);
    return 0;
}

static int product_record_start(client_t *client, const media_record_opts_t *opts, const wake_event_t *event)
{
    (void)client;
    (void)event;
    log_print("PRODUCT", "VENC record %d sec", opts->duration_sec);
    return 0;
}

int main(int argc, char **argv)
{
    const char *config_path = "client.ini";
    t31_runtime_t rt;
    char version_resp[MAX_RESP_SIZE];
    char config_resp[MAX_RESP_SIZE];
    const media_ops_impl_t product_ops = {
        .snapshot = product_snapshot,
        .record_start = product_record_start,
    };

    if (argc > 2) {
        print_usage(argv[0]);
        return EXIT_FAILURE;
    }
    if (argc == 2) {
        config_path = argv[1];
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    media_ops_register(&product_ops);

    if (t31_runtime_start(&rt, config_path) != 0) {
        return EXIT_FAILURE;
    }

    if (client_get_version(t31_runtime_client(&rt), version_resp, sizeof(version_resp)) == 0) {
        log_print("APP", "luat version rsp: %s", version_resp);
    }
    if (client_get_runtime_config(t31_runtime_client(&rt), config_resp, sizeof(config_resp)) == 0) {
        log_print("APP", "luat cfg rsp: %s", config_resp);
    }
    if (client_get_pir_stat(t31_runtime_client(&rt), config_resp, sizeof(config_resp)) == 0) {
        log_print("APP", "boot PIRSTAT: %s", config_resp);
    }

    log_print("APP", "runtime running (gpio/uart threads + worker); Ctrl+C to exit");
    while (!g_stop) {
        /* 示例：其他业务线程也可调用 media_snapshot(NULL) */
        sleep(1);
    }

    t31_runtime_shutdown(&rt);
    media_ops_unregister();
    return EXIT_SUCCESS;
}
