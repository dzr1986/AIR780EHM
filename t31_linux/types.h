#ifndef TYPES_H
#define TYPES_H

#include <stdbool.h>

#define PATH_LEN 128
#define FIELD_LEN 256
#define MAX_RESP_SIZE 8192

#define DEFAULT_UART_DEV "/dev/ttyS1"
#define DEFAULT_BAUDRATE 115200
/* T31 PB27：Linux sysfs 编号 = 32 + 27 = 59（君正 PB 组基址 + 脚位） */
#define DEFAULT_WAKE_GPIO 59
#define DEFAULT_READ_TIMEOUT_MS 2000
#define DEFAULT_WAKE_WAIT_TIMEOUT_MS -1

typedef enum {
    EVT_SERVER_DATA = 0,
    EVT_CONNECT_FAIL = 1,
    EVT_REGISTER_FAIL = 2,
    EVT_REGISTER_TIMEOUT = 3,
} evt_code_t;

typedef struct {
    int sid;
    char server_ip[FIELD_LEN];
    int server_port;
    char login_hex[FIELD_LEN];
    char login_rsp_hex[FIELD_LEN];
    char heartbeat_hex[FIELD_LEN];
    int heartbeat_sec;
    char wake_hex[FIELD_LEN];
    int critical_flag;
    int run_type;
} channel_config_t;

/* 4G 侧 MQTT Broker（经 UART AT+MQTTCFG 下发，字段以 ; 分隔，密码勿含 ;） */
typedef struct {
    char host[FIELD_LEN];
    int port;
    int ssl;
    char username[FIELD_LEN];
    char password[FIELD_LEN];
    char client_id[FIELD_LEN];
} mqtt_config_t;

typedef struct {
    char uart_dev[PATH_LEN];
    int baudrate;
    int wake_gpio;
    int read_timeout_ms;
    int wake_wait_timeout_ms;
    channel_config_t channel;
    mqtt_config_t mqtt;
} app_config_t;

typedef struct {
    int sid;
    int evt;
    bool valid;
} wake_event_t;

#endif