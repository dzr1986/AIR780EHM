#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include "audio_prompt.h"
#include "log.h"
#include "time_sync.h"
#include "uart_host_cmd.h"

#define HOST_CMD_BUF_SIZE 512

static char g_line_buf[HOST_CMD_BUF_SIZE];
static size_t g_line_len;

typedef struct {
    serial_port_t *serial;
    char name[32];
} sound_ack_ctx_t;

static void trim_crlf(char *s)
{
    size_t n;

    if (s == NULL) {
        return;
    }
    n = strlen(s);
    while (n > 0 && (s[n - 1] == '\r' || s[n - 1] == '\n' || s[n - 1] == ' ')) {
        s[n - 1] = '\0';
        n--;
    }
}

static int serial_write_locked(serial_port_t *serial, const char *data)
{
    size_t len;
    ssize_t n;

    if (serial == NULL || data == NULL || serial->fd < 0) {
        return -1;
    }
    len = strlen(data);
    pthread_mutex_lock(&serial->tx_lock);
    n = write(serial->fd, data, len);
    if (n >= 0) {
        tcdrain(serial->fd);
    }
    pthread_mutex_unlock(&serial->tx_lock);
    return (n == (ssize_t)len) ? 0 : -1;
}

static void *sound_ack_thread(void *arg)
{
    sound_ack_ctx_t *ctx = (sound_ack_ctx_t *)arg;
    char frame[96];

    audio_prompt_play(ctx->name);
    snprintf(frame, sizeof(frame), "\r\n+SOUNDACK:%s\r\nOK\r\n", ctx->name);
    serial_write_locked(ctx->serial, frame);
    free(ctx);
    return NULL;
}

static void start_sound_play(serial_port_t *serial, const char *name)
{
    sound_ack_ctx_t *ctx;
    pthread_t tid;

    serial_write_locked(serial, "\r\nOK\r\n");

    ctx = (sound_ack_ctx_t *)calloc(1, sizeof(*ctx));
    if (ctx == NULL) {
        log_print("ERR", "sound ack alloc failed");
        return;
    }
    ctx->serial = serial;
    snprintf(ctx->name, sizeof(ctx->name), "%s", name);

    if (pthread_create(&tid, NULL, sound_ack_thread, ctx) != 0) {
        log_print("ERR", "sound ack thread failed");
        free(ctx);
        return;
    }
    pthread_detach(tid);
}

static void handle_host_line(serial_port_t *serial, char *line)
{
    char status[64];
    char frame[128];
    const char *name;

    trim_crlf(line);
    if (line[0] == '\0') {
        return;
    }

    log_print("HOST", "RX %s", line);

    if (strcmp(line, "AT") == 0) {
        serial_write_locked(serial, "\r\nOK\r\n");
        return;
    }

    if (strncmp(line, "AT+PLAYSOUND=", 13) == 0) {
        name = line + 13;
        trim_crlf((char *)name);
        if (name[0] == '\0') {
            serial_write_locked(serial, "\r\nERROR\r\n");
            return;
        }
        start_sound_play(serial, name);
        return;
    }

    if (strcmp(line, "AT+PLAYSOUND?") == 0) {
        audio_prompt_get_status(status, sizeof(status));
        snprintf(frame, sizeof(frame), "\r\n+PLAYSOUND:%s\r\nOK\r\n", status);
        serial_write_locked(serial, frame);
        return;
    }

    if (strncmp(line, "AT+TIMESET=", 11) == 0) {
        char *end = NULL;
        long unix_sec = strtol(line + 11, &end, 10);

        if (end == line + 11 || (end != NULL && *end != '\0')) {
            serial_write_locked(serial, "\r\nERROR\r\n");
            return;
        }
        if (time_sync_apply_unix((time_t)unix_sec) == 0) {
            serial_write_locked(serial, "\r\n+TIMESET:OK\r\nOK\r\n");
        } else {
            serial_write_locked(serial, "\r\n+TIMESET:ERROR\r\nERROR\r\n");
        }
        return;
    }

    serial_write_locked(serial, "\r\nERROR\r\n");
}

void uart_host_cmd_reset(void)
{
    g_line_len = 0;
    g_line_buf[0] = '\0';
}

void uart_host_cmd_feed(serial_port_t *serial, const char *data, size_t len)
{
    size_t i;

    if (serial == NULL || data == NULL || len == 0) {
        return;
    }

    for (i = 0; i < len; ++i) {
        char c = data[i];

        if (c == '\r') {
            continue;
        }
        if (c == '\n') {
            g_line_buf[g_line_len] = '\0';
            handle_host_line(serial, g_line_buf);
            g_line_len = 0;
            g_line_buf[0] = '\0';
            continue;
        }
        if (g_line_len + 1 >= HOST_CMD_BUF_SIZE) {
            g_line_len = 0;
            g_line_buf[0] = '\0';
            continue;
        }
        g_line_buf[g_line_len++] = c;
    }
}
