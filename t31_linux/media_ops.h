#ifndef MEDIA_OPS_H
#define MEDIA_OPS_H

#include <stdbool.h>
#include <stddef.h>

#include "api.h"

/* 媒体动作（与 4G pirMediaConfig.action 对齐） */
typedef enum {
    MEDIA_ACTION_PHOTO = 0,
    MEDIA_ACTION_VIDEO,
    MEDIA_ACTION_BOTH,
} media_action_t;

typedef enum {
    MEDIA_UPLOAD_AUTO = 0,
    MEDIA_UPLOAD_MANUAL,
} media_upload_mode_t;

typedef enum {
    MEDIA_QUALITY_HIGH = 0,
    MEDIA_QUALITY_LOW,
} media_quality_t;

typedef struct {
    media_action_t action;
    media_upload_mode_t upload_mode;
    media_quality_t quality;
    int max_duration_sec;
} media_capture_opts_t;

typedef struct {
    char local_path[256];
    media_upload_mode_t upload_mode;
} media_upload_opts_t;

typedef struct {
    int duration_sec;
    media_upload_mode_t upload_mode;
    media_quality_t quality;
} media_record_opts_t;

typedef struct {
    char stream_url[256];
    int timeout_sec;
} media_talkback_opts_t;

/**
 * 业务实现钩子：由产品层（录像/ISP/存储）实现并注册。
 * 未注册时使用 media_ops.c 内默认桩（仅打日志）。
 */
typedef struct {
    int (*snapshot)(client_t *client, const media_capture_opts_t *opts, const wake_event_t *event);
    int (*record_start)(client_t *client, const media_record_opts_t *opts, const wake_event_t *event);
    int (*record_stop)(client_t *client, const char *reason, const wake_event_t *event);
    int (*upload)(client_t *client, const media_upload_opts_t *opts, const wake_event_t *event);
    int (*talkback)(client_t *client, const media_talkback_opts_t *opts, const wake_event_t *event);
    void *user_data;
} media_ops_impl_t;

void media_ops_bind_client(client_t *client);
int media_ops_register(const media_ops_impl_t *impl);
void media_ops_unregister(void);

/* 可在任意线程/模块调用（内部串行化由实现负责；UART 仍走 client_request 互斥） */
int media_snapshot(const media_capture_opts_t *opts);
int media_record_start(const media_record_opts_t *opts);
int media_record_stop(const char *reason);
int media_upload(const media_upload_opts_t *opts);
int media_talkback(const media_talkback_opts_t *opts);

/** GPIO 唤醒 evt=0 时：读 4G PIRSTAT 并按 action 分发（runtime 工作线程调用） */
int media_dispatch_wake_event(client_t *client, const wake_event_t *event);

#endif
