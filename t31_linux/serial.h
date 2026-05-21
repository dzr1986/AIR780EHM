#ifndef SERIAL_H
#define SERIAL_H

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "types.h"

typedef struct {
    int fd;
    int epoll_fd;
    pthread_t thread;
    bool thread_started;
    pthread_mutex_t lock;
    pthread_mutex_t tx_lock;
    pthread_cond_t cond;
    bool stop;
    bool awaiting;
    bool response_ready;
    uint64_t last_rx_ms;
    char rx_buf[MAX_RESP_SIZE];
    size_t rx_len;
} serial_port_t;

int serial_start(serial_port_t *serial, const char *dev, int baudrate);
void serial_stop(serial_port_t *serial);
int serial_request(serial_port_t *serial, const char *cmd, char *resp, size_t resp_size, int timeout_ms);

#endif