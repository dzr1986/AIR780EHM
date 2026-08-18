#!/usr/bin/env python3
from pathlib import Path

HOST_AT = Path(
    "/home/powersys/work/T31/hu_du/hu_ipcapp/server_src/ipc_device_ini/app/host/host_at.c"
)
HOST_REMOTE = Path(
    "/home/powersys/work/T31/hu_du/hu_ipcapp/server_src/ipc_device_ini/app/host/host_remote.c"
)


def main() -> None:
    t = HOST_AT.read_text()
    old = """    g_ipc_shutting_down = 1;
    ipc_supervision_push_state(host_module_session());

    ctx = (ipc_power_off_ctx_t *)calloc(1, sizeof(*ctx));
    if (ctx == NULL) {
        g_ipc_shutting_down = 0;
        return -1;
    }
    ctx->serial = serial;
    ctx->play_sound = play_sound ? 1 : 0;

    host_at_uart_reply_ok(serial);
"""
    new = """    g_ipc_shutting_down = 1;

    ctx = (ipc_power_off_ctx_t *)calloc(1, sizeof(*ctx));
    if (ctx == NULL) {
        g_ipc_shutting_down = 0;
        return -1;
    }
    ctx->serial = serial;
    ctx->play_sound = play_sound ? 1 : 0;

    /* Reply on RX thread only. Never push_state here: it sends AT+IPCSTATUS
     * and waits for Host ack on the same UART → deadlock, no STAGE/OK. */
    ipc_poweroff_stage(serial, "record");
"""
    if old not in t:
        raise SystemExit("host_at.c request block not found")
    t = t.replace(old, new, 1)
    old2 = """static void *ipc_power_off_thread(void *arg)
{
    ipc_power_off_ctx_t *ctx = (ipc_power_off_ctx_t *)arg;
    int ret;

    if (ctx->play_sound) {
"""
    new2 = """static void *ipc_power_off_thread(void *arg)
{
    ipc_power_off_ctx_t *ctx = (ipc_power_off_ctx_t *)arg;
    int ret;

    ipc_supervision_push_state(host_module_session());
    if (ctx->play_sound) {
"""
    if old2 not in t:
        raise SystemExit("host_at.c thread block not found")
    HOST_AT.write_text(t.replace(old2, new2, 1))
    print("host_at.c patched")

    t2 = HOST_REMOTE.read_text()
    if "#include <pthread.h>" not in t2:
        if "#include <string.h>" not in t2:
            raise SystemExit("host_remote.c missing string.h include")
        t2 = t2.replace("#include <string.h>", "#include <string.h>\n#include <pthread.h>", 1)
    helper = """
static void *cloud_remote_record_stop_thread(void *arg)
{
	char *why = (char *)arg;
	int ret = cloud_remote_record_stop(why);
	if (ret != 0) {
		(void)ipc_supervision_alert(host_module_session(), IPC_ALERT_RECORDCTRL_FAIL, "stop");
	}
	free(why);
	return NULL;
}

"""
    if "cloud_remote_record_stop_thread" not in t2:
        idx = t2.find("int cloud_remote_handle_record_ctrl")
        if idx < 0:
            raise SystemExit("handle_record_ctrl not found")
        t2 = t2[:idx] + helper + t2[idx:]
    old3 = """	host_at_uart_write(serial, frame);
	ret = cloud_remote_record_stop(reason);
	if (ret != 0) {
		(void)ipc_supervision_alert(host_module_session(), IPC_ALERT_RECORDCTRL_FAIL, "stop");
	}
	return ret;
"""
    new3 = """	host_at_uart_write(serial, frame);
	{
		pthread_t tid;
		char *why = strdup((reason != NULL && reason[0] != '\\0') ? reason : "cloud");
		if (why != NULL && pthread_create(&tid, NULL, cloud_remote_record_stop_thread, why) == 0) {
			pthread_detach(tid);
			return 0;
		}
		free(why);
	}
	ret = cloud_remote_record_stop(reason);
	if (ret != 0) {
		(void)ipc_supervision_alert(host_module_session(), IPC_ALERT_RECORDCTRL_FAIL, "stop");
	}
	return ret;
"""
    if old3 not in t2:
        raise SystemExit("host_remote.c stop block not found")
    HOST_REMOTE.write_text(t2.replace(old3, new3, 1))
    print("host_remote.c patched")


if __name__ == "__main__":
    main()
