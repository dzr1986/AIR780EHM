local M = {}
M.IPC_ALERT = {
	tf_mount_fail         = { map1011 = false, reconcile = false },
	uart_notify_fail      = { map1011 = false, reconcile = true },
	snapshot_failed       = { map1011 = true,  reconcile = false },
	gb28181_register_fail = { map1011 = false, reconcile = true },
	defer_record_failed   = { map1011 = true,  reconcile = false },
	hostevt_read_fail     = { map1011 = false, reconcile = false },
	no_person             = { map1011 = true,  reconcile = false },
	dispatch_failed       = { map1011 = false, reconcile = true },
	runtime_wakeup_fail   = { map1011 = false, reconcile = false },
	time_sync_fail        = { map1011 = true,  reconcile = false },
	time_invalid          = { map1011 = true,  reconcile = false },
	usb_recovery_fail     = { map1011 = false, reconcile = true },
	recordctrl_fail       = { map1011 = true,  reconcile = false },
	ipcpoweroff_busy      = { map1011 = false, reconcile = false },
}
M.CAT1_ONLY = {
	encode_runtime_fail = { map1011 = false, reconcile = false },
}
function M.lookup(code)
	code = tostring(code or "")
	return M.IPC_ALERT[code] or M.CAT1_ONLY[code]
end
function M.shouldMap1011(code)
	local e = M.lookup(code)
	return e and e.map1011 == true
end
function M.shouldReconcile(code)
	local e = M.lookup(code)
	return e and e.reconcile == true
end
return M
