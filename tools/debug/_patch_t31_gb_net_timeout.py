#!/usr/bin/env python3
from pathlib import Path

HOST_AT = Path(
    "/home/powersys/work/T31/hu_du/hu_ipcapp/server_src/ipc_device_ini/app/host/host_at.c"
)


def main() -> None:
    t = HOST_AT.read_text()
    old = """#if defined(WITH_GB28181)
    ipc_poweroff_stage(serial, "gb28181");
    gb28181_dev_exit();
#endif

#if defined(WITH_CAT1)
    ipc_poweroff_stage(serial, "net");
    net_link_manager_deinit();
#endif
"""
    new = """#if defined(WITH_GB28181)
    ipc_poweroff_stage(serial, "gb28181");
    {
        pthread_t tid;
        int wait_i;
        g_ipc_record_stop_done = 0;
        if (pthread_create(&tid, NULL, ipc_poweroff_gb_exit_thread, NULL) == 0) {
            pthread_detach(tid);
            for (wait_i = 0; wait_i < 50; ++wait_i) {
                if (g_ipc_record_stop_done) {
                    break;
                }
                usleep(100000);
            }
            if (!g_ipc_record_stop_done) {
                log_print("WARN", "IPCPOWEROFF gb28181_dev_exit timeout, continue");
            }
        } else {
            gb28181_dev_exit();
        }
    }
#endif

#if defined(WITH_CAT1)
    ipc_poweroff_stage(serial, "net");
    {
        pthread_t tid;
        int wait_i;
        g_ipc_record_stop_done = 0;
        if (pthread_create(&tid, NULL, ipc_poweroff_net_exit_thread, NULL) == 0) {
            pthread_detach(tid);
            for (wait_i = 0; wait_i < 50; ++wait_i) {
                if (g_ipc_record_stop_done) {
                    break;
                }
                usleep(100000);
            }
            if (!g_ipc_record_stop_done) {
                log_print("WARN", "IPCPOWEROFF net_link_manager_deinit timeout, continue");
            }
        } else {
            net_link_manager_deinit();
        }
    }
#endif
"""
    if old not in t:
        raise SystemExit("gb/net block not found")
    helper = """
static void *ipc_poweroff_gb_exit_thread(void *arg)
{
    (void)arg;
#if defined(WITH_GB28181)
    gb28181_dev_exit();
#endif
    g_ipc_record_stop_done = 1;
    return NULL;
}

static void *ipc_poweroff_net_exit_thread(void *arg)
{
    (void)arg;
#if defined(WITH_CAT1)
    net_link_manager_deinit();
#endif
    g_ipc_record_stop_done = 1;
    return NULL;
}

"""
    if "ipc_poweroff_gb_exit_thread" not in t:
        mark = "static void ipc_stop_services(serial_port_t *serial)"
        if mark not in t:
            raise SystemExit("ipc_stop_services not found")
        t = t.replace(mark, helper + mark, 1)
    HOST_AT.write_text(t.replace(old, new, 1))
    print("gb/net timeout patched")


if __name__ == "__main__":
    main()
