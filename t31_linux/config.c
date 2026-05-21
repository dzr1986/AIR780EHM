#include <ctype.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "config.h"
#include "log.h"

static void copy_string(char *dst, size_t dst_size, const char *src)
{
    if (dst_size == 0) {
        return;
    }
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    snprintf(dst, dst_size, "%s", src);
}

static char *trim_in_place(char *text)
{
    char *end;

    while (*text != '\0' && isspace((unsigned char)*text)) {
        text++;
    }
    if (*text == '\0') {
        return text;
    }
    end = text + strlen(text) - 1;
    while (end >= text && isspace((unsigned char)*end)) {
        *end = '\0';
        end--;
    }
    return text;
}

static int parse_int_value(const char *value, int *out)
{
    char *end;
    long number;

    errno = 0;
    number = strtol(value, &end, 10);
    if (errno != 0 || end == value) {
        return -1;
    }
    while (*end != '\0') {
        if (!isspace((unsigned char)*end)) {
            return -1;
        }
        end++;
    }
    *out = (int)number;
    return 0;
}

static void apply_key_value(app_config_t *cfg, const char *key, const char *value)
{
    if (strcmp(key, "uart_dev") == 0) {
        copy_string(cfg->uart_dev, sizeof(cfg->uart_dev), value);
    } else if (strcmp(key, "baudrate") == 0) {
        (void)parse_int_value(value, &cfg->baudrate);
    } else if (strcmp(key, "wake_gpio") == 0) {
        (void)parse_int_value(value, &cfg->wake_gpio);
    } else if (strcmp(key, "read_timeout_ms") == 0) {
        (void)parse_int_value(value, &cfg->read_timeout_ms);
    } else if (strcmp(key, "wake_wait_timeout_ms") == 0) {
        (void)parse_int_value(value, &cfg->wake_wait_timeout_ms);
    } else if (strcmp(key, "sid") == 0) {
        (void)parse_int_value(value, &cfg->channel.sid);
    } else if (strcmp(key, "server_ip") == 0) {
        copy_string(cfg->channel.server_ip, sizeof(cfg->channel.server_ip), value);
    } else if (strcmp(key, "server_port") == 0) {
        (void)parse_int_value(value, &cfg->channel.server_port);
    } else if (strcmp(key, "login_hex") == 0) {
        copy_string(cfg->channel.login_hex, sizeof(cfg->channel.login_hex), value);
    } else if (strcmp(key, "login_rsp_hex") == 0) {
        copy_string(cfg->channel.login_rsp_hex, sizeof(cfg->channel.login_rsp_hex), value);
    } else if (strcmp(key, "heartbeat_hex") == 0) {
        copy_string(cfg->channel.heartbeat_hex, sizeof(cfg->channel.heartbeat_hex), value);
    } else if (strcmp(key, "heartbeat_sec") == 0) {
        (void)parse_int_value(value, &cfg->channel.heartbeat_sec);
    } else if (strcmp(key, "wake_hex") == 0) {
        copy_string(cfg->channel.wake_hex, sizeof(cfg->channel.wake_hex), value);
    } else if (strcmp(key, "critical_flag") == 0) {
        (void)parse_int_value(value, &cfg->channel.critical_flag);
    } else if (strcmp(key, "run_type") == 0) {
        (void)parse_int_value(value, &cfg->channel.run_type);
    } else if (strcmp(key, "mqtt_host") == 0) {
        copy_string(cfg->mqtt.host, sizeof(cfg->mqtt.host), value);
    } else if (strcmp(key, "mqtt_port") == 0) {
        (void)parse_int_value(value, &cfg->mqtt.port);
    } else if (strcmp(key, "mqtt_ssl") == 0) {
        (void)parse_int_value(value, &cfg->mqtt.ssl);
    } else if (strcmp(key, "mqtt_username") == 0) {
        copy_string(cfg->mqtt.username, sizeof(cfg->mqtt.username), value);
    } else if (strcmp(key, "mqtt_password") == 0) {
        copy_string(cfg->mqtt.password, sizeof(cfg->mqtt.password), value);
    } else if (strcmp(key, "mqtt_client_id") == 0) {
        copy_string(cfg->mqtt.client_id, sizeof(cfg->mqtt.client_id), value);
    }
}

static int read_all_text(const char *path, char **out_text)
{
    FILE *fp;
    long file_size;
    char *buf;

    fp = fopen(path, "rb");
    if (fp == NULL) {
        log_print("ERR", "open config failed: %s", path);
        return -1;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return -1;
    }
    file_size = ftell(fp);
    if (file_size < 0) {
        fclose(fp);
        return -1;
    }
    if (fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return -1;
    }

    buf = (char *)calloc((size_t)file_size + 1, 1);
    if (buf == NULL) {
        fclose(fp);
        return -1;
    }
    if (fread(buf, 1, (size_t)file_size, fp) != (size_t)file_size) {
        free(buf);
        fclose(fp);
        return -1;
    }

    fclose(fp);
    *out_text = buf;
    return 0;
}

static int load_ini_config(app_config_t *cfg, const char *path)
{
    FILE *fp;
    char line[512];

    fp = fopen(path, "r");
    if (fp == NULL) {
        return -1;
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        char *key;
        char *value;
        char *eq;

        key = trim_in_place(line);
        if (*key == '\0' || *key == '#' || *key == ';' || *key == '[') {
            continue;
        }
        eq = strchr(key, '=');
        if (eq == NULL) {
            continue;
        }
        *eq = '\0';
        value = trim_in_place(eq + 1);
        key = trim_in_place(key);
        apply_key_value(cfg, key, value);
    }

    fclose(fp);
    return 0;
}

static const char *skip_json_value_prefix(const char *text)
{
    while (*text != '\0' && (*text == ' ' || *text == '\t' || *text == '\r' || *text == '\n' || *text == ':')) {
        text++;
    }
    return text;
}

static bool json_get_string(const char *text, const char *key, char *out, size_t out_size)
{
    char pattern[64];
    const char *pos;
    size_t i = 0;

    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    pos = strstr(text, pattern);
    if (pos == NULL) {
        return false;
    }
    pos = skip_json_value_prefix(pos + strlen(pattern));
    if (*pos != '"') {
        return false;
    }
    pos++;
    while (*pos != '\0' && *pos != '"' && i + 1 < out_size) {
        if (*pos == '\\' && pos[1] != '\0') {
            pos++;
        }
        out[i++] = *pos++;
    }
    out[i] = '\0';
    return *pos == '"';
}

static bool json_get_int(const char *text, const char *key, int *out)
{
    char pattern[64];
    const char *pos;
    char number[32];
    size_t i = 0;

    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    pos = strstr(text, pattern);
    if (pos == NULL) {
        return false;
    }
    pos = skip_json_value_prefix(pos + strlen(pattern));
    if (*pos == '-' || isdigit((unsigned char)*pos)) {
        while ((*pos == '-' || isdigit((unsigned char)*pos)) && i + 1 < sizeof(number)) {
            number[i++] = *pos++;
        }
        number[i] = '\0';
        return parse_int_value(number, out) == 0;
    }
    return false;
}

static int load_json_config(app_config_t *cfg, const char *path)
{
    char *text = NULL;
    char value[FIELD_LEN];
    int number;

    if (read_all_text(path, &text) != 0) {
        return -1;
    }

    if (json_get_string(text, "uart_dev", value, sizeof(value))) {
        apply_key_value(cfg, "uart_dev", value);
    }
    if (json_get_int(text, "baudrate", &number)) {
        cfg->baudrate = number;
    }
    if (json_get_int(text, "wake_gpio", &number)) {
        cfg->wake_gpio = number;
    }
    if (json_get_int(text, "read_timeout_ms", &number)) {
        cfg->read_timeout_ms = number;
    }
    if (json_get_int(text, "wake_wait_timeout_ms", &number)) {
        cfg->wake_wait_timeout_ms = number;
    }
    if (json_get_int(text, "sid", &number)) {
        cfg->channel.sid = number;
    }
    if (json_get_string(text, "server_ip", value, sizeof(value))) {
        apply_key_value(cfg, "server_ip", value);
    }
    if (json_get_int(text, "server_port", &number)) {
        cfg->channel.server_port = number;
    }
    if (json_get_string(text, "login_hex", value, sizeof(value))) {
        apply_key_value(cfg, "login_hex", value);
    }
    if (json_get_string(text, "login_rsp_hex", value, sizeof(value))) {
        apply_key_value(cfg, "login_rsp_hex", value);
    }
    if (json_get_string(text, "heartbeat_hex", value, sizeof(value))) {
        apply_key_value(cfg, "heartbeat_hex", value);
    }
    if (json_get_int(text, "heartbeat_sec", &number)) {
        cfg->channel.heartbeat_sec = number;
    }
    if (json_get_string(text, "wake_hex", value, sizeof(value))) {
        apply_key_value(cfg, "wake_hex", value);
    }
    if (json_get_int(text, "critical_flag", &number)) {
        cfg->channel.critical_flag = number;
    }
    if (json_get_int(text, "run_type", &number)) {
        cfg->channel.run_type = number;
    }
    if (json_get_string(text, "mqtt_host", value, sizeof(value))) {
        apply_key_value(cfg, "mqtt_host", value);
    }
    if (json_get_int(text, "mqtt_port", &number)) {
        cfg->mqtt.port = number;
    }
    if (json_get_int(text, "mqtt_ssl", &number)) {
        cfg->mqtt.ssl = number;
    }
    if (json_get_string(text, "mqtt_username", value, sizeof(value))) {
        apply_key_value(cfg, "mqtt_username", value);
    }
    if (json_get_string(text, "mqtt_password", value, sizeof(value))) {
        apply_key_value(cfg, "mqtt_password", value);
    }
    if (json_get_string(text, "mqtt_client_id", value, sizeof(value))) {
        apply_key_value(cfg, "mqtt_client_id", value);
    }

    free(text);
    return 0;
}

void config_init_defaults(app_config_t *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    copy_string(cfg->uart_dev, sizeof(cfg->uart_dev), DEFAULT_UART_DEV);
    cfg->baudrate = DEFAULT_BAUDRATE;
    cfg->wake_gpio = DEFAULT_WAKE_GPIO;
    cfg->read_timeout_ms = DEFAULT_READ_TIMEOUT_MS;
    cfg->wake_wait_timeout_ms = DEFAULT_WAKE_WAIT_TIMEOUT_MS;

    cfg->channel.sid = 1;
    copy_string(cfg->channel.server_ip, sizeof(cfg->channel.server_ip), "192.168.1.10");
    cfg->channel.server_port = 8000;
    copy_string(cfg->channel.login_hex, sizeof(cfg->channel.login_hex), "313233");
    copy_string(cfg->channel.login_rsp_hex, sizeof(cfg->channel.login_rsp_hex), "313233");
    copy_string(cfg->channel.heartbeat_hex, sizeof(cfg->channel.heartbeat_hex), "313233");
    cfg->channel.heartbeat_sec = 60;
    copy_string(cfg->channel.wake_hex, sizeof(cfg->channel.wake_hex), "AA55");
    cfg->channel.critical_flag = 1;
    cfg->channel.run_type = 0;

    copy_string(cfg->mqtt.host, sizeof(cfg->mqtt.host), "112.86.146.218");
    cfg->mqtt.port = 2123;
    cfg->mqtt.ssl = 0;
    copy_string(cfg->mqtt.username, sizeof(cfg->mqtt.username), "fptop1");
    copy_string(cfg->mqtt.password, sizeof(cfg->mqtt.password), "fptop1.com2025@#$&");
    cfg->mqtt.client_id[0] = '\0';
}

int config_load(app_config_t *cfg, const char *path)
{
    FILE *fp;
    int first_char;
    int ret;

    if (path == NULL || path[0] == '\0') {
        return 0;
    }

    fp = fopen(path, "r");
    if (fp == NULL) {
        log_print("ERR", "config file not found: %s", path);
        return -1;
    }
    do {
        first_char = fgetc(fp);
    } while (first_char != EOF && isspace((unsigned char)first_char));
    fclose(fp);

    if (first_char == '{') {
        ret = load_json_config(cfg, path);
    } else {
        ret = load_ini_config(cfg, path);
    }

    if (ret == 0) {
        log_print("APP", "config loaded from %s", path);
    }
    return ret;
}