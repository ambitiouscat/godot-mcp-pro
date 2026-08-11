extends SceneTree

const ProcessIdentity := preload("res://addons/godot_mcp/bridge_process_identity.gd")


func _initialize() -> void:
	if OS.get_name() != "Linux":
		print("LINUX_PROCESS_IDENTITY_STABILITY_SKIPPED")
		quit(0)
		return
	var pid := OS.create_process("sh", PackedStringArray(["-c", "sleep 50"]))
	if pid <= 0:
		push_error("TEST FAILURE: unable to start Linux identity probe child")
		quit(1)
		return
	var started_at := ProcessIdentity.started_at_ms(pid)
	if started_at <= 0:
		OS.kill(pid)
		push_error("TEST FAILURE: probe child has no Linux process identity")
		quit(1)
		return
	if started_at < ProcessIdentity.IDENTITY_V1_BASE or started_at > ProcessIdentity.IDENTITY_V1_MAX:
		OS.kill(pid)
		push_error("TEST FAILURE: Linux v1 identity is outside the safe version-tagged range")
		quit(1)
		return
	var legacy_status := ProcessIdentity.inspect(pid, ProcessIdentity.IDENTITY_V1_BASE - 1)
	if legacy_status.get("matches", false) or legacy_status.get("stale", true):
		OS.kill(pid)
		push_error("TEST FAILURE: legacy Linux epoch identity was not UNKNOWN")
		quit(1)
		return
	await create_timer(41.0).timeout
	if not ProcessIdentity.inspect(pid, started_at).get("matches", false):
		OS.kill(pid)
		push_error("TEST FAILURE: Linux process identity drifted across 41 seconds")
		quit(1)
		return
	OS.kill(pid)
	await create_timer(0.5).timeout
	if not ProcessIdentity.inspect(pid, started_at).get("stale", false):
		push_error("TEST FAILURE: stopped Linux probe child was not stale")
		quit(1)
		return
	if not ProcessIdentity.inspect(pid, ProcessIdentity.IDENTITY_V1_BASE - 1).get("stale", false):
		push_error("TEST FAILURE: stopped probe child kept a legacy identity UNKNOWN")
		quit(1)
		return
	print("LINUX_PROCESS_IDENTITY_STABILITY_OK")
	quit(0)
