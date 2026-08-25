#!/usr/bin/env python3
from pathlib import Path

HOST_AT = Path(
    "/home/powersys/work/T31/hu_du/hu_ipcapp/server_src/ipc_device_ini/app/host/host_at.c"
)


def main() -> None:
    t = HOST_AT.read_text()
    old = """static void ipc_stop_services(serial_port_t *serial)
{
    ipc_poweroff_stage(serial, "record");
    (void)cloud_remote_record_stop("poweroff");
"""
    new = """static volatile int g_ipc_record_stop_done = 0;

static void *ipc_poweroff_record_stop_thread(void *arg)
{
    (void)arg;
    (void)cloud_remote_record_stop("poweroff");
    g_ipc_record_stop_done = 1;
    return NULL;
}

static void ipc_stop_services(serial_port_t *serial)
{
    int wait_i;
    pthread_t rec_tid;

    ipc_poweroff_stage(serial, "record");
    /* all-day TS seal can deadlock the pump; bound it so later STAGE/OK can run */
    g_ipc_record_stop_done = 0;
    if (pthread_create(&rec_tid, NULL, ipc_poweroff_record_stop_thread, NULL) == 0) {
        pthread_detach(rec_tid);
        for (wait_i = 0; wait_i < 120; ++wait_i) {
            if (g_ipc_record_stop_done) {
                break;
            }
            usleep(100000);
        }
        if (!g_ipc_record_stop_done) {
            log_print("WARN", "IPCPOWEROFF record_stop timeout, continue shutdown");
        }
    } else {
        (void)cloud_remote_record_stop("poweroff");
        g_ipc_record_stop_done = 1;
    }
"""
    if old not in t:
        raise SystemExit("ipc_stop_services block not found")
    if "unistd.h" not in t:
        t = t.replace("#include <pthread.h>", "#include <pthread.h>\n#include <unistd.h>", 1)
        if "unistd.h" not in t:
            t = "#include <unistd.h>\n" + t
    t = t.replace(old, new, 1)
    leftover = """#if defined(WITH_RECORD_MP4) || defined(WITH_RECORD_AVI) || defined(WITH_RECORD_TS)
    {
        int i;
        for (i = 0; i < RECORD_MAX_CHANNELS; ++i) {
            if (record_is_running_ch(i)) {
                log_print("HOST", "IPCPOWEROFF stop leftover record ch=%d", i);
                record_stop_ch(i);
            }
        }
    }
#endif
"""
    leftover_new = """#if defined(WITH_RECORD_MP4) || defined(WITH_RECORD_AVI) || defined(WITH_RECORD_TS)
    if (g_ipc_record_stop_done) {
        int i;
        for (i = 0; i < RECORD_MAX_CHANNELS; ++i) {
            if (record_is_running_ch(i)) {
                log_print("HOST", "IPCPOWEROFF stop leftover record ch=%d", i);
                record_stop_ch(i);
            }
        }
    } else {
        log_print("WARN", "IPCPOWEROFF skip leftover record_stop_ch (seal still running)");
    }
#endif
"""
    if leftover not in t:
        raise SystemExit("leftover record_stop_ch block not found")
    HOST_AT.write_text(t.replace(leftover, leftover_new, 1))
    print("record_stop timeout patched")


if __name__ == "__main__":
    main()
