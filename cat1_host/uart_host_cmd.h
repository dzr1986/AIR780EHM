#ifndef UART_HOST_CMD_H
#define UART_HOST_CMD_H

#include "serial.h"

/* 4G → T31 下行 AT（非 T31 主动 request 响应路径） */
void uart_host_cmd_reset(void);
void uart_host_cmd_feed(serial_port_t *serial, const char *data, size_t len);

#endif
