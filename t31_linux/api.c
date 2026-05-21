#include <stdio.h>
#include <string.h>

#include "api.h"
#include "log.h"

static bool response_contains(const char *resp, const char *keyword)
{
    return resp != NULL && keyword != NULL && strstr(resp, keyword) != NULL;
}

static int send_expect(client_t *client, const char *cmd, const char *expected);
static int send_expect_ok(client_t *client, const char *cmd);
static int create_channel(client_t *client);
static int close_channel(client_t *client, int sid);
static int dump_config(client_t *client);
static int query_wake_event(client_t *client, wake_event_t *event);
static int bootstrap(client_t *client);
static int run_business_callbacks(client_t *client, const wake_event_t *event);

int client_request(client_t *client, const char *cmd, char *resp, size_t resp_size)
{
    if (client == NULL || cmd == NULL || client->serial.fd < 0) {
        return -1;
    }
    return serial_request(&client->serial, cmd, resp, resp_size, client->config.read_timeout_ms);
}

int client_ping(client_t *client)
{
    return send_expect_ok(client, "AT");
}

int client_get_version(client_t *client, char *resp, size_t resp_size)
{
    char local_resp[MAX_RESP_SIZE];
    char *out_resp = resp;
    size_t out_size = resp_size;

    if (out_resp == NULL || out_size == 0) {
        out_resp = local_resp;
        out_size = sizeof(local_resp);
    }

    if (client_request(client, "ATI", out_resp, out_size) != 0) {
        return -1;
    }
    return response_contains(out_resp, "+CGMR:") ? 0 : -1;
}

int client_set_passthrough(client_t *client, bool enabled)
{
    char cmd[32];
    char expect[16];

    snprintf(cmd, sizeof(cmd), "AT+RIL=%d", enabled ? 1 : 0);
    snprintf(expect, sizeof(expect), "+RIL:%d", enabled ? 1 : 0);
    return send_expect(client, cmd, expect);
}

int client_get_runtime_config(client_t *client, char *resp, size_t resp_size)
{
    char local_resp[MAX_RESP_SIZE];
    char *out_resp = resp;
    size_t out_size = resp_size;

    if (out_resp == NULL || out_size == 0) {
        out_resp = local_resp;
        out_size = sizeof(local_resp);
    }

    if (client_request(client, "AT+GETCFG?", out_resp, out_size) != 0) {
        return -1;
    }
    return response_contains(out_resp, "+GETCFG:") ? 0 : -1;
}

int client_create_service(client_t *client)
{
    return create_channel(client);
}

int client_close_service(client_t *client, int sid)
{
    return close_channel(client, sid);
}

int client_query_wakeup(client_t *client, wake_event_t *event)
{
    return query_wake_event(client, event);
}

static int send_expect(client_t *client, const char *cmd, const char *expected)
{
    char resp[MAX_RESP_SIZE];

    if (serial_request(&client->serial, cmd, resp, sizeof(resp), client->config.read_timeout_ms) != 0) {
        return -1;
    }
    if (!response_contains(resp, expected)) {
        log_print("ERR", "unexpected response for [%s]", cmd);
        return -1;
    }
    return 0;
}

static int send_expect_ok(client_t *client, const char *cmd)
{
    char resp[MAX_RESP_SIZE];

    if (serial_request(&client->serial, cmd, resp, sizeof(resp), client->config.read_timeout_ms) != 0) {
        return -1;
    }
    if (!response_contains(resp, "OK")) {
        log_print("ERR", "expected OK for [%s]", cmd);
        return -1;
    }
    return 0;
}

static int create_channel(client_t *client)
{
    char cmd[1024];
    char expect[64];

    snprintf(cmd, sizeof(cmd),
             "AT+SERVCREATE=%d,%s,%d,%s,%s,%s,%d,%s,%d,%d",
             client->config.channel.sid,
             client->config.channel.server_ip,
             client->config.channel.server_port,
             client->config.channel.login_hex,
             client->config.channel.login_rsp_hex,
             client->config.channel.heartbeat_hex,
             client->config.channel.heartbeat_sec,
             client->config.channel.wake_hex,
             client->config.channel.critical_flag,
             client->config.channel.run_type);
    snprintf(expect, sizeof(expect), "+SERVCREATE:%d,OK", client->config.channel.sid);
    return send_expect(client, cmd, expect);
}

static int close_channel(client_t *client, int sid)
{
    char cmd[64];
    char expect[64];

    snprintf(cmd, sizeof(cmd), "AT+SERVCLOSE=%d", sid);
    snprintf(expect, sizeof(expect), "+SERVCLOSE:%d", sid);
    return send_expect(client, cmd, expect);
}

static int dump_config(client_t *client)
{
    char resp[MAX_RESP_SIZE];

    if (serial_request(&client->serial, "AT+GETCFG?", resp, sizeof(resp), client->config.read_timeout_ms) != 0) {
        return -1;
    }
    if (!response_contains(resp, "+GETCFG:")) {
        log_print("ERR", "GETCFG response invalid");
        return -1;
    }
    return 0;
}

static int query_wake_event(client_t *client, wake_event_t *event)
{
    char resp[MAX_RESP_SIZE];
    const char *prefix;

    memset(event, 0, sizeof(*event));
    if (serial_request(&client->serial, "AT+WAKEVT?", resp, sizeof(resp), client->config.read_timeout_ms) != 0) {
        return -1;
    }

    prefix = strstr(resp, "+WAKEVT:");
    if (prefix == NULL) {
        log_print("ERR", "WAKEVT response missing prefix");
        return -1;
    }
    prefix += strlen("+WAKEVT:");
    while (*prefix == ' ' || *prefix == '\r' || *prefix == '\n') {
        prefix++;
    }
    if (*prefix == '\0') {
        event->valid = false;
        return 0;
    }
    if (sscanf(prefix, "%d,%d", &event->sid, &event->evt) == 2) {
        event->valid = true;
        return 0;
    }

    log_print("ERR", "parse WAKEVT failed: %s", prefix);
    return -1;
}

static int bootstrap(client_t *client)
{
    if (client_ping(client) != 0) {
        return -1;
    }
    if (client_get_version(client, NULL, 0) != 0) {
        return -1;
    }
    if (client_set_passthrough(client, false) != 0) {
        return -1;
    }
    if (client_create_service(client) != 0) {
        return -1;
    }
    if (dump_config(client) != 0) {
        return -1;
    }
    return 0;
}

static int run_business_callbacks(client_t *client, const wake_event_t *event)
{
    const business_callbacks_t *callbacks = &client->callbacks;

    if (callbacks->on_server_data != NULL) {
        return callbacks->on_server_data(client, event, callbacks->user_data);
    }
    if (callbacks->on_record != NULL && callbacks->on_record(client, event, callbacks->user_data) != 0) {
        return -1;
    }
    if (callbacks->on_snapshot != NULL && callbacks->on_snapshot(client, event, callbacks->user_data) != 0) {
        return -1;
    }
    if (callbacks->on_upload != NULL && callbacks->on_upload(client, event, callbacks->user_data) != 0) {
        return -1;
    }
    if (callbacks->on_talkback != NULL && callbacks->on_talkback(client, event, callbacks->user_data) != 0) {
        return -1;
    }
    if (callbacks->on_record == NULL && callbacks->on_snapshot == NULL &&
        callbacks->on_upload == NULL && callbacks->on_talkback == NULL) {
        log_print("APP", "evt=0: no business callbacks registered");
    }
    return 0;
}

int client_register_callbacks(client_t *client, const business_callbacks_t *callbacks)
{
    if (client == NULL) {
        return -1;
    }
    if (callbacks == NULL) {
        memset(&client->callbacks, 0, sizeof(client->callbacks));
        return 0;
    }

    client->callbacks = *callbacks;
    return 0;
}

int client_init(client_t *client, const char *config_path)
{
    memset(client, 0, sizeof(*client));
    config_init_defaults(&client->config);
    if (config_load(&client->config, config_path) != 0) {
        return -1;
    }

    if (serial_start(&client->serial, client->config.uart_dev, client->config.baudrate) != 0) {
        return -1;
    }
    if (gpio_start(&client->gpio, client->config.wake_gpio) != 0) {
        serial_stop(&client->serial);
        return -1;
    }
    if (bootstrap(client) != 0) {
        client_shutdown(client);
        return -1;
    }

    client->initialized = true;
    log_print("APP", "client initialized uart=%s gpio=%d sid=%d",
              client->config.uart_dev,
              client->config.wake_gpio,
              client->config.channel.sid);
    return 0;
}

int client_wait_wakeup(client_t *client, wake_event_t *event, int timeout_ms)
{
    int wait_ms = timeout_ms;
    int ret;

    if (!client->initialized) {
        return -1;
    }
    if (wait_ms < 0) {
        wait_ms = client->config.wake_wait_timeout_ms;
    }

    ret = gpio_wait_event(&client->gpio, wait_ms);
    if (ret <= 0) {
        return ret;
    }
    if (query_wake_event(client, event) != 0) {
        return -1;
    }
    return 1;
}

int client_handle_event(client_t *client, const wake_event_t *event)
{
    if (!client->initialized || event == NULL) {
        return -1;
    }
    if (!event->valid) {
        return 0;
    }

    switch (event->evt) {
    case EVT_SERVER_DATA:
        return run_business_callbacks(client, event);
    case EVT_CONNECT_FAIL:
        log_print("APP", "evt=1: TCP connect fail, rebuild channel");
        break;
    case EVT_REGISTER_FAIL:
        log_print("APP", "evt=2: login/register fail, rebuild channel");
        break;
    case EVT_REGISTER_TIMEOUT:
        log_print("APP", "evt=3: register timeout, rebuild channel");
        break;
    default:
        log_print("ERR", "unknown wake event: %d", event->evt);
        return -1;
    }

    if (close_channel(client, client->config.channel.sid) != 0) {
        return -1;
    }
    return create_channel(client);
}

void client_shutdown(client_t *client)
{
    if (client == NULL) {
        return;
    }
    gpio_stop(&client->gpio);
    serial_stop(&client->serial);
    client->initialized = false;
}