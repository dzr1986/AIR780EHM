#include <stdarg.h>
#include <stdio.h>
#include <time.h>

#include "log.h"

void log_print(const char *level, const char *fmt, ...)
{
    time_t now = time(NULL);
    struct tm tm_now;
    char ts[32] = {0};
    va_list args;

    localtime_r(&now, &tm_now);
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm_now);

    fprintf(stdout, "[%s] [%s] ", ts, level);
    va_start(args, fmt);
    vfprintf(stdout, fmt, args);
    va_end(args);
    fputc('\n', stdout);
    fflush(stdout);
}