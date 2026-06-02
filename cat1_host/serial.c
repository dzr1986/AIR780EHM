#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "log.h"
#include "serial.h"
#include "uart_host_cmd.h"

#define SERIAL_IDLE_MS 150

static uint64_t now_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static void realtime_deadline(struct timespec *ts, int timeout_ms)
{
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_sec += timeout_ms / 1000;
    ts->tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (ts->tv_nsec >= 1000000000L) {
        ts->tv_sec++;
        ts->tv_nsec -= 1000000000L;
    }
}

static speed_t baud_to_termios(int baudrate)
{
    switch (baudrate) {
    case 9600:
        return B9600;
    case 19200:
        return B19200;
    case 38400:
        return B38400;
    case 57600:
        return B57600;
    case 115200:
        return B115200;
    default:
        return B115200;
    }
}

static int write_all(int fd, const char *buf, size_t len)
{
    size_t sent = 0;

    while (sent < len) {
        ssize_t n = write(fd, buf + sent, len - sent);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        sent += (size_t)n;
    }
    return 0;
}

static void append_rx_buffer(serial_port_t *serial, const char *data, size_t len)
{
    size_t writable = sizeof(serial->rx_buf) - 1 - serial->rx_len;

    if (len > writable) {
        len = writable;
    }
    if (len == 0) {
        return;
    }

    memcpy(serial->rx_buf + serial->rx_len, data, len);
    serial->rx_len += len;
    serial->rx_buf[serial->rx_len] = '\0';
    serial->last_rx_ms = now_ms();
}

static void *serial_thread_main(void *arg)
{
    serial_port_t *serial = (serial_port_t *)arg;
    struct epoll_event events[2];

    while (!serial->stop) {
        int count = epoll_wait(serial->epoll_fd, events, 2, 100);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            log_print("ERR", "epoll_wait uart failed: %s", strerror(errno));
            return NULL;
        }

        for (int i = 0; i < count; ++i) {
            if (events[i].events & (EPOLLIN | EPOLLERR | EPOLLHUP)) {
                for (;;) {
                    char chunk[512];
                    ssize_t n = read(serial->fd, chunk, sizeof(chunk) - 1);
                    if (n < 0) {
                        if (errno == EINTR) {
                            continue;
                        }
                        if (errno == EAGAIN || errno == EWOULDBLOCK) {
                            break;
                        }
                        log_print("ERR", "read uart failed: %s", strerror(errno));
                        return NULL;
                    }
                    if (n == 0) {
                        break;
                    }

                    chunk[n] = '\0';
                    pthread_mutex_lock(&serial->lock);
                    if (serial->awaiting) {
                        append_rx_buffer(serial, chunk, (size_t)n);
                    } else {
                        uart_host_cmd_feed(serial, chunk, (size_t)n);
                    }
                    pthread_mutex_unlock(&serial->lock);
                }
            }
        }

        pthread_mutex_lock(&serial->lock);
        if (serial->awaiting && !serial->response_ready && serial->rx_len > 0 &&
            now_ms() - serial->last_rx_ms >= SERIAL_IDLE_MS) {
            serial->response_ready = true;
            pthread_cond_signal(&serial->cond);
        }
        pthread_mutex_unlock(&serial->lock);
    }

    pthread_mutex_lock(&serial->lock);
    pthread_cond_broadcast(&serial->cond);
    pthread_mutex_unlock(&serial->lock);
    return NULL;
}

int serial_start(serial_port_t *serial, const char *dev, int baudrate)
{
    struct termios tio;
    struct epoll_event event;

    memset(serial, 0, sizeof(*serial));
    serial->fd = -1;
    serial->epoll_fd = -1;
    serial->fd = open(dev, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (serial->fd < 0) {
        log_print("ERR", "open uart failed: %s (%s)", dev, strerror(errno));
        return -1;
    }

    if (tcgetattr(serial->fd, &tio) != 0) {
        log_print("ERR", "tcgetattr failed: %s", strerror(errno));
        close(serial->fd);
        serial->fd = -1;
        return -1;
    }

    cfmakeraw(&tio);
    tio.c_cflag |= CLOCAL | CREAD;
    tio.c_cflag &= ~CSTOPB;
    tio.c_cflag &= ~CRTSCTS;
    tio.c_cflag &= ~PARENB;
    tio.c_cflag &= ~CSIZE;
    tio.c_cflag |= CS8;
    tio.c_iflag &= ~(IXON | IXOFF | IXANY);
    tio.c_cc[VMIN] = 0;
    tio.c_cc[VTIME] = 1;
    cfsetispeed(&tio, baud_to_termios(baudrate));
    cfsetospeed(&tio, baud_to_termios(baudrate));

    if (tcsetattr(serial->fd, TCSANOW, &tio) != 0) {
        log_print("ERR", "tcsetattr failed: %s", strerror(errno));
        close(serial->fd);
        serial->fd = -1;
        return -1;
    }

    serial->epoll_fd = epoll_create1(0);
    if (serial->epoll_fd < 0) {
        log_print("ERR", "epoll_create1 uart failed: %s", strerror(errno));
        close(serial->fd);
        serial->fd = -1;
        return -1;
    }

    pthread_mutex_init(&serial->lock, NULL);
    pthread_mutex_init(&serial->tx_lock, NULL);
    pthread_cond_init(&serial->cond, NULL);

    memset(&event, 0, sizeof(event));
    event.events = EPOLLIN | EPOLLERR | EPOLLHUP;
    event.data.fd = serial->fd;
    if (epoll_ctl(serial->epoll_fd, EPOLL_CTL_ADD, serial->fd, &event) != 0) {
        log_print("ERR", "epoll_ctl uart failed: %s", strerror(errno));
        serial_stop(serial);
        return -1;
    }

    if (pthread_create(&serial->thread, NULL, serial_thread_main, serial) != 0) {
        log_print("ERR", "create uart thread failed");
        serial_stop(serial);
        return -1;
    }
    serial->thread_started = true;
    tcflush(serial->fd, TCIOFLUSH);
    uart_host_cmd_reset();
    return 0;
}

void serial_stop(serial_port_t *serial)
{
    if (serial->fd < 0 && serial->epoll_fd < 0) {
        return;
    }

    serial->stop = true;
    pthread_mutex_lock(&serial->lock);
    pthread_cond_broadcast(&serial->cond);
    pthread_mutex_unlock(&serial->lock);

    if (serial->thread_started) {
        pthread_join(serial->thread, NULL);
    }
    if (serial->epoll_fd >= 0) {
        close(serial->epoll_fd);
    }
    if (serial->fd >= 0) {
        close(serial->fd);
    }
    pthread_mutex_destroy(&serial->lock);
    pthread_mutex_destroy(&serial->tx_lock);
    pthread_cond_destroy(&serial->cond);
    memset(serial, 0, sizeof(*serial));
    serial->fd = -1;
    serial->epoll_fd = -1;
}

int serial_request(serial_port_t *serial, const char *cmd, char *resp, size_t resp_size, int timeout_ms)
{
    char frame[1024];
    int frame_len;
    struct timespec deadline;
    int wait_ret = 0;

    if (resp != NULL && resp_size > 0) {
        resp[0] = '\0';
    }
    if (timeout_ms <= 0) {
        timeout_ms = DEFAULT_READ_TIMEOUT_MS;
    }

    pthread_mutex_lock(&serial->tx_lock);
    pthread_mutex_lock(&serial->lock);
    serial->awaiting = true;
    serial->response_ready = false;
    serial->rx_len = 0;
    serial->rx_buf[0] = '\0';
    serial->last_rx_ms = 0;
    pthread_mutex_unlock(&serial->lock);

    frame_len = snprintf(frame, sizeof(frame), "%s\r\n", cmd);
    if (frame_len < 0 || frame_len >= (int)sizeof(frame)) {
        pthread_mutex_lock(&serial->lock);
        serial->awaiting = false;
        pthread_mutex_unlock(&serial->lock);
        pthread_mutex_unlock(&serial->tx_lock);
        return -1;
    }

    tcflush(serial->fd, TCIFLUSH);
    log_print("TX", "%s", cmd);
    if (write_all(serial->fd, frame, (size_t)frame_len) != 0 || tcdrain(serial->fd) != 0) {
        log_print("ERR", "write uart failed: %s", strerror(errno));
        pthread_mutex_lock(&serial->lock);
        serial->awaiting = false;
        pthread_mutex_unlock(&serial->lock);
        pthread_mutex_unlock(&serial->tx_lock);
        return -1;
    }

    realtime_deadline(&deadline, timeout_ms);
    pthread_mutex_lock(&serial->lock);
    while (!serial->stop && !serial->response_ready) {
        wait_ret = pthread_cond_timedwait(&serial->cond, &serial->lock, &deadline);
        if (wait_ret == ETIMEDOUT) {
            break;
        }
    }

    if (resp != NULL && resp_size > 0 && serial->rx_len > 0) {
        size_t copy_len = serial->rx_len;
        if (copy_len >= resp_size) {
            copy_len = resp_size - 1;
        }
        memcpy(resp, serial->rx_buf, copy_len);
        resp[copy_len] = '\0';
        log_print("RX", "%s", resp);
    }

    serial->awaiting = false;
    serial->response_ready = false;
    pthread_mutex_unlock(&serial->lock);
    pthread_mutex_unlock(&serial->tx_lock);

    if (wait_ret == ETIMEDOUT) {
        log_print("ERR", "uart response timeout for %s", cmd);
        return -1;
    }
    return 0;
}