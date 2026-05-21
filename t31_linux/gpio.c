#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <time.h>
#include <unistd.h>

#include "gpio.h"
#include "log.h"

/* PB27：3.3V 输入，监听 Cat.1 GPIO29 低电平脉冲（下降沿）。
 * 硬件建议 PB27 上拉至 3.3V；4G 侧 1.8V 高电平可能达不到 VIH，低电平脉冲更可靠。 */

static int write_text_file(const char *path, const char *value)
{
    int fd = open(path, O_WRONLY);
    ssize_t len = (ssize_t)strlen(value);

    if (fd < 0) {
        return -1;
    }
    if (write(fd, value, len) != len) {
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

static int gpio_prepare_sysfs(int gpio)
{
    char path[128];
    char value[32];

    snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/value", gpio);
    if (access(path, F_OK) != 0) {
        snprintf(value, sizeof(value), "%d", gpio);
        if (write_text_file("/sys/class/gpio/export", value) != 0 && errno != EBUSY) {
            log_print("ERR", "export gpio%d failed", gpio);
            return -1;
        }
    }

    snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/direction", gpio);
    if (write_text_file(path, "in") != 0) {
        log_print("ERR", "set gpio%d direction failed", gpio);
        return -1;
    }

    snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/edge", gpio);
    if (write_text_file(path, "falling") != 0) {
        log_print("ERR", "set gpio%d edge failed", gpio);
        return -1;
    }

    snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/value", gpio);
    return open(path, O_RDONLY | O_NONBLOCK);
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

static void *gpio_thread_main(void *arg)
{
    gpio_monitor_t *gpio = (gpio_monitor_t *)arg;
    struct epoll_event events[2];

    while (!gpio->stop) {
        int count = epoll_wait(gpio->epoll_fd, events, 2, 500);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            log_print("ERR", "epoll_wait gpio failed: %s", strerror(errno));
            return NULL;
        }
        for (int i = 0; i < count; ++i) {
            if (events[i].events & (EPOLLPRI | EPOLLERR)) {
                char buf[8];
                lseek(gpio->fd, 0, SEEK_SET);
                (void)read(gpio->fd, buf, sizeof(buf));

                pthread_mutex_lock(&gpio->lock);
                gpio->pending_count++;
                pthread_cond_signal(&gpio->cond);
                pthread_mutex_unlock(&gpio->lock);
            }
        }
    }

    pthread_mutex_lock(&gpio->lock);
    pthread_cond_broadcast(&gpio->cond);
    pthread_mutex_unlock(&gpio->lock);
    return NULL;
}

int gpio_start(gpio_monitor_t *gpio, int gpio_num)
{
    struct epoll_event event;
    char buf[8];

    memset(gpio, 0, sizeof(*gpio));
    gpio->fd = -1;
    gpio->epoll_fd = -1;
    gpio->gpio_num = gpio_num;
    gpio->fd = gpio_prepare_sysfs(gpio_num);
    if (gpio->fd < 0) {
        return -1;
    }

    gpio->epoll_fd = epoll_create1(0);
    if (gpio->epoll_fd < 0) {
        log_print("ERR", "epoll_create1 gpio failed: %s", strerror(errno));
        close(gpio->fd);
        gpio->fd = -1;
        return -1;
    }

    pthread_mutex_init(&gpio->lock, NULL);
    pthread_cond_init(&gpio->cond, NULL);

    lseek(gpio->fd, 0, SEEK_SET);
    (void)read(gpio->fd, buf, sizeof(buf));

    memset(&event, 0, sizeof(event));
    event.events = EPOLLPRI | EPOLLERR;
    event.data.fd = gpio->fd;
    if (epoll_ctl(gpio->epoll_fd, EPOLL_CTL_ADD, gpio->fd, &event) != 0) {
        log_print("ERR", "epoll_ctl gpio failed: %s", strerror(errno));
        gpio_stop(gpio);
        return -1;
    }

    if (pthread_create(&gpio->thread, NULL, gpio_thread_main, gpio) != 0) {
        log_print("ERR", "create gpio thread failed");
        gpio_stop(gpio);
        return -1;
    }
    gpio->thread_started = true;
    return 0;
}

void gpio_stop(gpio_monitor_t *gpio)
{
    if (gpio->fd < 0 && gpio->epoll_fd < 0) {
        return;
    }

    gpio->stop = true;
    pthread_mutex_lock(&gpio->lock);
    pthread_cond_broadcast(&gpio->cond);
    pthread_mutex_unlock(&gpio->lock);

    if (gpio->thread_started) {
        pthread_join(gpio->thread, NULL);
    }
    if (gpio->epoll_fd >= 0) {
        close(gpio->epoll_fd);
    }
    if (gpio->fd >= 0) {
        close(gpio->fd);
    }
    pthread_mutex_destroy(&gpio->lock);
    pthread_cond_destroy(&gpio->cond);
    memset(gpio, 0, sizeof(*gpio));
    gpio->fd = -1;
    gpio->epoll_fd = -1;
}

int gpio_wait_event(gpio_monitor_t *gpio, int timeout_ms)
{
    int ret = 0;

    pthread_mutex_lock(&gpio->lock);
    while (!gpio->stop && gpio->pending_count == 0) {
        if (timeout_ms < 0) {
            pthread_cond_wait(&gpio->cond, &gpio->lock);
        } else {
            struct timespec deadline;
            realtime_deadline(&deadline, timeout_ms);
            ret = pthread_cond_timedwait(&gpio->cond, &gpio->lock, &deadline);
            if (ret == ETIMEDOUT) {
                pthread_mutex_unlock(&gpio->lock);
                return 0;
            }
        }
    }
    if (gpio->stop) {
        pthread_mutex_unlock(&gpio->lock);
        return -1;
    }
    gpio->pending_count--;
    pthread_mutex_unlock(&gpio->lock);
    return 1;
}