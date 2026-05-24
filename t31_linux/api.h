#ifndef API_H
#define API_H

#include <stdbool.h>
#include <stddef.h>

#include "config.h"
#include "gpio.h"
#include "serial.h"

typedef struct client client_t;

typedef int (*event_callback_t)(client_t *client, const wake_event_t *event, void *user_data);

/* 旧式回调；evt=0 未设 on_server_data 时改走 media_ops（见 media_ops.h） */
typedef struct {
    event_callback_t on_server_data;
    event_callback_t on_record;
    event_callback_t on_snapshot;
    event_callback_t on_upload;
    event_callback_t on_talkback;
    void *user_data;
} business_callbacks_t;

struct client {
    app_config_t config;
    serial_port_t serial;
    gpio_monitor_t gpio;
    business_callbacks_t callbacks;
    bool initialized;
};

int client_register_callbacks(client_t *client, const business_callbacks_t *callbacks);
int client_init(client_t *client, const char *config_path);
int client_wait_wakeup(client_t *client, wake_event_t *event, int timeout_ms);
int client_handle_event(client_t *client, const wake_event_t *event);
int client_request(client_t *client, const char *cmd, char *resp, size_t resp_size);
int client_ping(client_t *client);
int client_get_version(client_t *client, char *resp, size_t resp_size);
int client_set_passthrough(client_t *client, bool enabled);
int client_get_runtime_config(client_t *client, char *resp, size_t resp_size);
int client_create_service(client_t *client);
int client_close_service(client_t *client, int sid);
/** 下发 [channel] → AT+SERVCREATE（TCP/低功耗业务通道模板） */
int client_push_tcp_channel(client_t *client);
/** 下发 [mqtt] → AT+MQTTCFG（MQTT Broker，4G 覆盖并重连） */
int client_push_mqtt_config(client_t *client);
int client_query_wakeup(client_t *client, wake_event_t *event);
int client_get_pir_stat(client_t *client, char *resp, size_t resp_size);
void client_shutdown(client_t *client);

#endif