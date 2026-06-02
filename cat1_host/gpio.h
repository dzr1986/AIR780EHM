#ifndef GPIO_H
#define GPIO_H

#include <pthread.h>
#include <stdbool.h>

typedef struct {
    int gpio_num;
    int fd;
    int epoll_fd;
    pthread_t thread;
    bool thread_started;
    pthread_mutex_t lock;
    pthread_cond_t cond;
    bool stop;
    unsigned int pending_count;
} gpio_monitor_t;

int gpio_start(gpio_monitor_t *gpio, int gpio_num);
void gpio_stop(gpio_monitor_t *gpio);
int gpio_wait_event(gpio_monitor_t *gpio, int timeout_ms);

#endif