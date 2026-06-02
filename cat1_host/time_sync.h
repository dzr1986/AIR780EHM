#ifndef TIME_SYNC_H
#define TIME_SYNC_H

#include <stdbool.h>
#include <time.h>

/* 低于此阈值视为未同步（1970 等） */
#define TIME_SYNC_MIN_VALID 1704067200L /* 2024-01-01 UTC */

bool time_sync_is_valid(time_t t);
int time_sync_apply_unix(time_t unix_sec);
time_t time_sync_now(void);

#endif
