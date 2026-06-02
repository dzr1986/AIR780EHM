# T31 媒体业务接口（media_ops）

拍照、录像、上传等与 4G AT **解耦**，可在任意模块调用；默认实现为日志桩，产品层通过 `media_ops_register` 替换。

## 线程模型

```text
serial.c   → UART 接收线程（epoll）
gpio.c     → GPIO 唤醒监听线程（epoll）
runtime.c  → 业务工作线程（等唤醒 → WAKEVT → 分发）
main       → 主线程（信号、注册 ops、可调用 media_*）
```

## 对外 API（`media_ops.h`）

| 函数 | 说明 |
|------|------|
| `media_ops_register(impl)` | 注册产品实现（snapshot/record/upload…） |
| `media_snapshot(opts)` | 拍照 |
| `media_record_start(opts)` | 开始录像 |
| `media_record_stop(reason)` | 停止录像 |
| `media_upload(opts)` | 上传文件 |
| `media_talkback(opts)` | 对讲（预留） |
| `media_dispatch_wake_event(client, event)` | 读 `AT+PIRSTAT?` 按 action 自动分发 |

## 运行时（`runtime.h`）

| 函数 | 说明 |
|------|------|
| `t31_runtime_start(rt, ini)` | 初始化 4G 链路 + 启动工作线程 |
| `t31_runtime_client(rt)` | 取 `client_t*`（发 AT） |
| `t31_runtime_request_stop` / `shutdown` | 停止并回收 |

## 产品层接入示例

```c
#include "media_ops.h"
#include "runtime.h"

static int my_snapshot(client_t *c, const media_capture_opts_t *o, const wake_event_t *e) {
    (void)c; (void)e;
    /* 调君正 IMP 拍照 */
    return 0;
}

int app_main(void) {
    t31_runtime_t rt;
    media_ops_impl_t ops = { .snapshot = my_snapshot };
    media_ops_register(&ops);
    t31_runtime_start(&rt, "client.ini");

    /* 其他线程/UI 也可直接： */
    media_snapshot(NULL);

    t31_runtime_shutdown(&rt);
    return 0;
}
```

## 唤醒自动分发

`evt=0` 时工作线程调用 `media_dispatch_wake_event`：

1. `AT+PIRSTAT?` 读 `action=`、`recording=`
2. `recording=1` → `media_record_stop("pir_retrigger")`
3. `action=video` → `media_record_start`
4. `action=both` → 先 snapshot 再 record
5. 默认 → `media_snapshot`

仍可通过 `client_register_callbacks` 的 `on_server_data` **完全接管** evt=0。
