#include <errno.h>
#include <stdio.h>
#include <sys/time.h>
#include <time.h>

#include "log.h"
#include "time_sync.h"

bool time_sync_is_valid(time_t t)
{
    return t >= TIME_SYNC_MIN_VALID;
}

int time_sync_apply_unix(time_t unix_sec)
{
    struct timeval tv;
    struct tm tm_buf;
    char buf[32];

    if (!time_sync_is_valid(unix_sec)) {
        log_print("ERR", "time_sync invalid unix=%ld", (long)unix_sec);
        return -1;
    }

    tv.tv_sec = unix_sec;
    tv.tv_usec = 0;
    if (settimeofday(&tv, NULL) != 0) {
        log_print("ERR", "settimeofday failed errno=%d", errno);
        return -1;
    }

    if (gmtime_r(&unix_sec, &tm_buf) != NULL &&
        strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S UTC", &tm_buf) > 0) {
        log_print("APP", "time synced unix=%ld %s", (long)unix_sec, buf);
    } else {
        log_print("APP", "time synced unix=%ld", (long)unix_sec);
    }
    return 0;
}

time_t time_sync_now(void)
{
    return time(NULL);
}
