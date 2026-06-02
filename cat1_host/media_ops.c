/**
 * T31 媒体业务：拍照 / 录像 / 上传 / 对讲
 * - 对外：media_snapshot、media_record_* 等（任意模块可调用）
 * - 对内：invoke_* 转产品层 media_ops_register 钩子，未注册则用 default_* 桩
 * - 唤醒：media_dispatch_wake_event 读 4G AT+PIRSTAT? 后自动分支
 * 说明见 MEDIA_OPS.md
 */
#include <stdio.h>
#include <string.h>

#include "api.h"
#include "log.h"
#include "media_ops.h"
#include "time_sync.h"

static client_t *g_client;           /* runtime 绑定，供无 client 参数的 media_* 使用 */
static media_ops_impl_t g_impl;      /* 产品层注册的 ISP/VENC 实现 */
static bool g_impl_registered;

/* 构造默认拍照参数（action=photo, 自动上传, 高画质, 最长 60s） */
static media_capture_opts_t default_capture_opts(void)
{
    media_capture_opts_t opts;
    memset(&opts, 0, sizeof(opts));
    opts.action = MEDIA_ACTION_PHOTO;
    opts.upload_mode = MEDIA_UPLOAD_AUTO;
    opts.quality = MEDIA_QUALITY_HIGH;
    opts.max_duration_sec = 60;
    return opts;
}

/* 默认桩：拍照（产品未实现 snapshot 时仅打日志） */
static int default_snapshot(client_t *client, const media_capture_opts_t *opts, const wake_event_t *event)
{
    (void)client;
    (void)event;
    log_print("MEDIA", "snapshot action=%d upload=%d quality=%d",
              (int)opts->action, (int)opts->upload_mode, (int)opts->quality);
    return 0;
}

/* 默认桩：开始录像 */
static int default_record_start(client_t *client, const media_record_opts_t *opts, const wake_event_t *event)
{
    (void)client;
    (void)event;
    log_print("MEDIA", "record_start duration=%d upload=%d quality=%d",
              opts->duration_sec, (int)opts->upload_mode, (int)opts->quality);
    return 0;
}

/* 默认桩：停止录像（reason 如 pir_retrigger / timer / manual） */
static int default_record_stop(client_t *client, const char *reason, const wake_event_t *event)
{
    (void)client;
    (void)event;
    log_print("MEDIA", "record_stop reason=%s", reason ? reason : "");
    return 0;
}

/* 默认桩：上传本地文件到云端/存储 */
static int default_upload(client_t *client, const media_upload_opts_t *opts, const wake_event_t *event)
{
    (void)client;
    (void)event;
    log_print("MEDIA", "upload path=%s mode=%d", opts->local_path, (int)opts->upload_mode);
    return 0;
}

/* 默认桩：语音对讲拉流（预留） */
static int default_talkback(client_t *client, const media_talkback_opts_t *opts, const wake_event_t *event)
{
    (void)client;
    (void)event;
    log_print("MEDIA", "talkback url=%s timeout=%d", opts->stream_url, opts->timeout_sec);
    return 0;
}

void media_ops_bind_client(client_t *client)
{
    g_client = client;
}

int media_ops_register(const media_ops_impl_t *impl)
{
    if (impl == NULL) {
        memset(&g_impl, 0, sizeof(g_impl));
        g_impl_registered = false;
        return 0;
    }
    g_impl = *impl;
    g_impl_registered = true;
    return 0;
}

/* 注销产品实现，等价 media_ops_register(NULL) */
void media_ops_unregister(void)
{
    media_ops_register(NULL);
}

/* 内部：拍照，优先 g_impl.snapshot，否则 default_snapshot */
static int invoke_snapshot(const media_capture_opts_t *opts, const wake_event_t *event)
{
    if (g_client == NULL) {
        return -1;
    }
    if (g_impl_registered && g_impl.snapshot != NULL) {
        return g_impl.snapshot(g_client, opts, event);
    }
    return default_snapshot(g_client, opts, event);
}

/* 内部：开始录像 */
static int invoke_record_start(const media_record_opts_t *opts, const wake_event_t *event)
{
    if (g_client == NULL) {
        return -1;
    }
    if (g_impl_registered && g_impl.record_start != NULL) {
        return g_impl.record_start(g_client, opts, event);
    }
    return default_record_start(g_client, opts, event);
}

static int invoke_record_stop(const char *reason, const wake_event_t *event)
{
    if (g_client == NULL) {
        return -1;
    }
    if (g_impl_registered && g_impl.record_stop != NULL) {
        return g_impl.record_stop(g_client, reason, event);
    }
    return default_record_stop(g_client, reason, event);
}

/**
 * 对外：触发拍照。opts=NULL 用默认参数；可在主线程/业务线程任意时刻调用。
 * @return 0 成功，-1 未 bind client 或产品实现失败
 */
int media_snapshot(const media_capture_opts_t *opts)
{
    media_capture_opts_t local = default_capture_opts();
    wake_event_t dummy;

    memset(&dummy, 0, sizeof(dummy));
    if (opts != NULL) {
        local = *opts;
    }
    return invoke_snapshot(&local, &dummy);
}

/**
 * 对外：开始录像。opts=NULL 时默认 60s、自动上传、高画质。
 */
int media_record_start(const media_record_opts_t *opts)
{
    media_record_opts_t local;
    wake_event_t dummy;

    memset(&dummy, 0, sizeof(dummy));
    memset(&local, 0, sizeof(local));
    local.duration_sec = 60;
    local.upload_mode = MEDIA_UPLOAD_AUTO;
    local.quality = MEDIA_QUALITY_HIGH;
    if (opts != NULL) {
        local = *opts;
    }
    return invoke_record_start(&local, &dummy);
}

/**
 * 对外：停止当前录像会话。reason 用于日志/统计（如 pir_retrigger）。
 */
int media_record_stop(const char *reason)
{
    wake_event_t dummy;
    memset(&dummy, 0, sizeof(dummy));
    return invoke_record_stop(reason, &dummy);
}

int media_upload(const media_upload_opts_t *opts)
{
    media_upload_opts_t local;
    wake_event_t dummy;

    if (opts == NULL) {
        return -1;
    }
    memset(&dummy, 0, sizeof(dummy));
    local = *opts;
    if (g_client == NULL) {
        return -1;
    }
    if (g_impl_registered && g_impl.upload != NULL) {
        return g_impl.upload(g_client, &local, &dummy);
    }
    return default_upload(g_client, &local, &dummy);
}

/**
 * 对外：语音对讲（拉流/推流 URL）。opts 必填。
 */
int media_talkback(const media_talkback_opts_t *opts)
{
    media_talkback_opts_t local;
    wake_event_t dummy;

    if (opts == NULL) {
        return -1;
    }
    memset(&dummy, 0, sizeof(dummy));
    local = *opts;
    if (g_client == NULL) {
        return -1;
    }
    if (g_impl_registered && g_impl.talkback != NULL) {
        return g_impl.talkback(g_client, &local, &dummy);
    }
    return default_talkback(g_client, &local, &dummy);
}

/* 从 +PIRSTAT: 应答体解析 key=整数，失败返回 default_val */
static int parse_pir_field_int(const char *body, const char *key, int default_val)
{
    char pattern[64];
    const char *pos;
    int value;

    snprintf(pattern, sizeof(pattern), "%s=", key);
    pos = strstr(body, pattern);
    if (pos == NULL) {
        return default_val;
    }
    pos += strlen(pattern);
    if (sscanf(pos, "%d", &value) == 1) {
        return value;
    }
    return default_val;
}

static int parse_pir_action(const char *body, media_action_t *action)
{
    const char *pos = strstr(body, "action=");
    char word[16];

    if (pos == NULL || action == NULL) {
        return -1;
    }
    pos += strlen("action=");
    if (sscanf(pos, "%15[^,]", word) != 1) {
        return -1;
    }
    if (strcmp(word, "video") == 0) {
        *action = MEDIA_ACTION_VIDEO;
    } else if (strcmp(word, "both") == 0) {
        *action = MEDIA_ACTION_BOTH;
    } else {
        *action = MEDIA_ACTION_PHOTO;
    }
    return 0;
}

/**
 * GPIO 唤醒且 evt=0 时由 runtime 调用：
 * 1) AT+PIRSTAT? 读 4G 侧 PIR 状态
 * 2) recording=1 → 停录（二次 PIR）
 * 3) action=video → 仅录像；both → 拍照+录像；否则拍照
 * PIRSTAT 失败则降级为 media_snapshot(NULL)。
 */
int media_dispatch_wake_event(client_t *client, const wake_event_t *event)
{
    char pir_resp[MAX_RESP_SIZE];
    media_capture_opts_t cap;
    media_record_opts_t rec;
    media_action_t action = MEDIA_ACTION_PHOTO;
    int recording;
    int max_sec;

    if (client == NULL || event == NULL || !event->valid) {
        return -1;
    }
    media_ops_bind_client(client);

    if (!time_sync_is_valid(time_sync_now())) {
        if (client_sync_time_from_cat1(client) != 0) {
            log_print("WARN", "system time invalid before media, recording may use wrong timestamp");
        }
    }

    if (client_get_pir_stat(client, pir_resp, sizeof(pir_resp)) != 0) {
        log_print("WARN", "PIRSTAT failed, fallback snapshot");
        return media_snapshot(NULL);
    }

    recording = parse_pir_field_int(pir_resp, "recording", 0);
    max_sec = parse_pir_field_int(pir_resp, "max_sec", 60);
    (void)parse_pir_action(pir_resp, &action);

    memset(&cap, 0, sizeof(cap));
    cap.action = action;
    cap.upload_mode = MEDIA_UPLOAD_AUTO;
    cap.quality = MEDIA_QUALITY_HIGH;
    cap.max_duration_sec = max_sec;

    memset(&rec, 0, sizeof(rec));
    rec.duration_sec = max_sec;
    rec.upload_mode = MEDIA_UPLOAD_AUTO;
    rec.quality = MEDIA_QUALITY_HIGH;

    if (recording) {
        log_print("APP", "PIR retrigger/stop path");
        return invoke_record_stop("pir_retrigger", event);
    }

    if (action == MEDIA_ACTION_VIDEO) {
        return invoke_record_start(&rec, event);
    }
    if (action == MEDIA_ACTION_BOTH) {
        if (invoke_snapshot(&cap, event) != 0) {
            return -1;
        }
        return invoke_record_start(&rec, event);
    }
    return invoke_snapshot(&cap, event);
}
