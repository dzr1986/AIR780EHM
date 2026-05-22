#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#include "api.h"
#include "log.h"

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

static int on_record(client_t *client, const wake_event_t *event, void *user_data)
{
    (void)client;
    (void)event;
    (void)user_data;
    log_print("APP", "custom callback: start record");
    return 0;
}

static int on_snapshot(client_t *client, const wake_event_t *event, void *user_data)
{
    (void)client;
    (void)event;
    (void)user_data;
    log_print("APP", "custom callback: capture snapshot");
    return 0;
}

static int on_upload(client_t *client, const wake_event_t *event, void *user_data)
{
    (void)client;
    (void)event;
    (void)user_data;
    log_print("APP", "custom callback: upload media");
    return 0;
}

static void log_pir_stat(client_t *client)
{
    char pir_resp[MAX_RESP_SIZE];

    if (client_get_pir_stat(client, pir_resp, sizeof(pir_resp)) == 0) {
        log_print("APP", "4G PIRSTAT: %s", pir_resp);
    } else {
        log_print("WARN", "AT+PIRSTAT? failed");
    }
}

int main(int argc, char **argv)
{
    const char *config_path = "client.ini";
    client_t client;
    char version_resp[MAX_RESP_SIZE];
    char config_resp[MAX_RESP_SIZE];
    const business_callbacks_t callbacks = {
        .on_record = on_record,
        .on_snapshot = on_snapshot,
        .on_upload = on_upload,
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

    if (client_init(&client, config_path) != 0) {
        return EXIT_FAILURE;
    }
    if (client_register_callbacks(&client, &callbacks) != 0) {
        client_shutdown(&client);
        return EXIT_FAILURE;
    }

    if (client_get_version(&client, version_resp, sizeof(version_resp)) == 0) {
        log_print("APP", "luat version rsp: %s", version_resp);
    }
    if (client_get_runtime_config(&client, config_resp, sizeof(config_resp)) == 0) {
        log_print("APP", "luat cfg rsp: %s", config_resp);
    }
    log_pir_stat(&client);

    log_print("APP", "T31 enter sleep and wait gpio wakeup");
    while (!g_stop) {
        wake_event_t event;
        int ret = client_wait_wakeup(&client, &event, 1000);
        if (ret < 0) {
            log_print("ERR", "wait wakeup failed");
            break;
        }
        if (ret == 0) {
            continue;
        }

        if (!event.valid) {
            log_print("APP", "wake gpio triggered but WAKEVT is empty");
            continue;
        }

        log_print("APP", "wake event sid=%d evt=%d", event.sid, event.evt);
        log_pir_stat(&client);
        if (client_handle_event(&client, &event) != 0) {
            log_print("ERR", "handle event failed");
        }
        log_print("APP", "T31 business finished and re-enter sleep");
    }

    client_shutdown(&client);
    return EXIT_SUCCESS;
}