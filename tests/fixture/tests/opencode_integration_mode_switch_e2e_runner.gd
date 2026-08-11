extends SceneTree

## Exercises the managed integration-mode handoff in one packaged Godot
## process. The platform wrappers run this project from an isolated copied
## addon and observe phase files to prove that a native listener never starts
## an MCP sidecar before the explicit native -> MCP restart.

const Protocol := preload("res://addons/opencode_godot/engine_bridge/bridge_protocol_v1.gd")
const ProcessIdentity := preload("res://addons/opencode_godot/engine_bridge/bridge_process_identity.gd")
const SessionCoordinator := preload("res://addons/opencode_godot/engine_bridge/bridge_session_coordinator.gd")
const CommandRouter := preload("res://addons/opencode_godot/engine_bridge/command_router.gd")
const WebSocketServer := preload("res://addons/opencode_godot/engine_bridge/websocket_server.gd")
const TestLifecycle := preload("res://tests/opencode_e2e_test_lifecycle.gd")
const TestEditorPlugin := preload("res://tests/opencode_e2e_test_editor_plugin.gd")

const TOTAL_TIMEOUT_MS := 180_000
const READY_TIMEOUT_MS := 75_000
const REQUEST_TIMEOUT_MS := 75_000

var failures: Array[String] = []
var bridge: RefCounted
var lifecycle: RefCounted
var websocket_server: Node
var command_router: Node
var editor_plugin: EditorPlugin
var old_owner_nonce := ""
var old_token_path := ""
var old_daemon_pid := 0
var old_daemon_started_at_ms := 0
var old_discovery_path := ""
var old_listener_pid := 0
var mcp_ownership_path := ""
var mcp_sidecar_pid := 0
var mcp_sidecar_started_at_ms := 0
var mcp_sidecar_executable := ""
var event_path := ""
var continue_path := ""
var result_path := ""
var deadline_ms := 0
var command_completed := false
var command_result: Dictionary = {}
var native_tool_completed := false
var mcp_tool_completed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	deadline_ms = Time.get_ticks_msec() + TOTAL_TIMEOUT_MS
	event_path = OS.get_environment("GODOT_MODE_SWITCH_EVENT_PATH")
	continue_path = OS.get_environment("GODOT_MODE_SWITCH_CONTINUE_PATH")
	result_path = OS.get_environment("GODOT_MODE_SWITCH_RESULT_PATH")
	var architecture := Engine.get_architecture_name().to_lower()
	if OS.get_name() not in ["Windows", "macOS", "Linux"] or architecture not in ["x86_64", "arm64", "aarch64"]:
		_expect(false, "mode-switch E2E requires a supported Windows/macOS/Linux x86_64 or arm64 editor")
	bridge = SessionCoordinator.new()
	if not bridge.start_session():
		_expect(false, "initial bridge session starts: %s" % bridge.last_error)
		_finish()
		return
	await _create_editor_components()
	await _start_native_phase()
	if failures.is_empty():
		await _switch_native_to_mcp()
	await _cleanup_everything()
	_finish()


func _create_editor_components() -> void:
	command_router = CommandRouter.new()
	command_router.name = "OpenCodeGodotModeSwitchRouter"
	get_root().add_child(command_router)
	editor_plugin = TestEditorPlugin.new()
	editor_plugin.name = "OpenCodeGodotModeSwitchEditorPlugin"
	get_root().add_child(editor_plugin)
	websocket_server = WebSocketServer.new()
	websocket_server.name = "OpenCodeGodotModeSwitchBridgeClient"
	websocket_server.command_router = command_router
	websocket_server.session_coordinator = bridge
	get_root().add_child(websocket_server)
	await process_frame
	command_router.configure_bridge_context(bridge.project_path, websocket_server.is_session_ready, null)
	command_router.editor_plugin = editor_plugin
	websocket_server.command_completed.connect(_on_command_completed)
	websocket_server.start_server(bridge)


func _start_native_phase() -> void:
	lifecycle = TestLifecycle.new()
	lifecycle.setup(bridge, websocket_server)
	var mode: Dictionary = lifecycle.set_requested_integration_mode("native")
	_expect(mode.get("ok", false), "explicit native mode persists")
	var started: Dictionary = lifecycle.start()
	_expect(started.get("ok", false), "native daemon starts: %s" % started.get("error", ""))
	if not started.get("ok", false):
		return
	_expect(await _wait_ready(), "native daemon and bridge are ready")
	if lifecycle.state != "ready":
		return
	_expect(lifecycle.get_integration_mode() == "native", "first generation is native")
	_expect(not lifecycle._payload.get("mcp_available", false), "native generation has no MCP payload ownership")
	_expect(not FileAccess.file_exists(_ownership_path()), "native generation publishes no MCP ownership file")
	# Exercise the same packaged provider/tool path before the mode switch.  The
	# wrapper holds its phase barrier only after this completes, so native mode
	# proves both a usable bridge and the absence of an MCP sidecar.
	command_completed = false
	command_result.clear()
	await _invoke_packaged_tool_once("native")
	native_tool_completed = failures.is_empty() and command_completed and command_result.get("method") == "get_project_info" and command_result.get("success") == true
	if not failures.is_empty(): return
	var discovery: Variant = _read_json(bridge.discovery_path)
	_expect(discovery is Dictionary, "native generation publishes discovery")
	if discovery is Dictionary:
		var record: Dictionary = discovery
		old_listener_pid = int(record.get("owner_pid", 0))
		_expect(old_listener_pid == lifecycle.daemon_pid, "native discovery owner is current daemon")
		_expect(int(record.get("owner_started_at_ms", 0)) == lifecycle.daemon_started_at_ms, "native discovery owner start identity is current daemon")
		_expect(int(record.get("parent_pid", 0)) == bridge.coordinator_pid, "native discovery parent is current Godot editor")
		var discovery_parent_started_at_ms := int(record.get("parent_started_at_ms", 0))
		_expect(
			discovery_parent_started_at_ms == bridge.coordinator_started_at_ms,
			"native discovery parent start identity is current Godot editor (record=%d coordinator=%d)" % [discovery_parent_started_at_ms, bridge.coordinator_started_at_ms]
		)
	old_owner_nonce = bridge.owner_nonce
	old_token_path = bridge.token_path
	old_discovery_path = bridge.discovery_path
	old_daemon_pid = lifecycle.daemon_pid
	old_daemon_started_at_ms = lifecycle.daemon_started_at_ms
	_publish_event("native_ready", {
		"daemon_pid": old_daemon_pid,
		"listener_pid": old_listener_pid,
		"owner_nonce": old_owner_nonce,
		"discovery_path": old_discovery_path,
		"token_path": old_token_path,
		"tool_call_completed": native_tool_completed,
	})
	_expect(await _wait_for_wrapper_continue(), "wrapper observed native phase before MCP switch")


func _switch_native_to_mcp() -> void:
	# This is the observable client cancellation seam: no stale WebSocket client
	# is allowed to survive into the new session/owner generation.
	websocket_server.stop_server()
	_expect(not websocket_server.is_session_ready(), "old bridge client is explicitly disabled before switching")
	lifecycle.stop()
	await _wait_process_stale(old_daemon_pid, old_daemon_started_at_ms, "old native daemon exits")
	_expect(not FileAccess.file_exists(old_discovery_path), "old native discovery is removed before session rotation")
	_expect(FileAccess.file_exists(old_token_path), "bridge coordinator retains its token until its session is explicitly stopped")
	bridge.stop_session()
	_expect(not FileAccess.file_exists(bridge.session_path), "old bridge session contract is removed")
	_expect(not FileAccess.file_exists(old_token_path), "old native bridge token is removed by session rotation")
	_expect(not FileAccess.file_exists(old_discovery_path), "old native discovery remains removed after session rotation")
	_expect(bridge.start_session(), "new bridge session starts after native cleanup: %s" % bridge.last_error)
	_expect(bridge.owner_nonce != old_owner_nonce, "bridge owner nonce rotates across mode switch")
	_expect(bridge.token_path != old_token_path and FileAccess.file_exists(bridge.token_path), "bridge token path rotates across mode switch")
	websocket_server.session_coordinator = bridge
	command_router.configure_bridge_context(bridge.project_path, websocket_server.is_session_ready, null)
	websocket_server.start_server(bridge)
	lifecycle.setup(bridge, websocket_server)
	var mode: Dictionary = lifecycle.set_requested_integration_mode("mcp")
	_expect(mode.get("ok", false), "explicit MCP mode persists")
	command_completed = false
	command_result.clear()
	var started: Dictionary = lifecycle.start()
	_expect(started.get("ok", false), "MCP daemon starts after native cleanup: %s" % started.get("error", ""))
	if not started.get("ok", false):
		return
	# OpenCode creates the MCP InstanceState lazily on its first authenticated
	# status/tools request. Waiting for the WebSocket bridge before /mcp would
	# deadlock the ownership publication the bridge is waiting to authenticate.
	_expect(await _wait_for_lifecycle_ready(), "MCP daemon reaches ready before bridge authentication")
	if lifecycle.state != "ready":
		return
	_expect(lifecycle.get_integration_mode() == "mcp", "second generation is MCP")
	var mcp_trigger := await _http_json(HTTPClient.METHOD_GET, "/mcp")
	_expect(mcp_trigger.get("ok", false), "authenticated MCP status request triggers the lazy child: %s" % mcp_trigger.get("error", ""))
	if not mcp_trigger.get("ok", false):
		return
	mcp_ownership_path = _ownership_path()
	var ownership: Variant = await _wait_for_mcp_ownership()
	_expect(ownership is Dictionary, "MCP generation publishes a complete nonce-bound ownership record before mcp_ready")
	if not ownership is Dictionary:
		return
	var record: Dictionary = ownership
	_expect(record.get("schema") == "opencode-godot-mcp-ownership" and int(record.get("schema_version", 0)) == 1, "MCP ownership schema is exact")
	_expect(record.get("canonical_project") == bridge.project_path, "MCP ownership is project-scoped")
	_expect(record.get("launch_nonce") == lifecycle.launch_nonce, "MCP ownership uses new launch nonce")
	_expect(int((record.get("opencode_parent", {}) as Dictionary).get("pid", 0)) == lifecycle.daemon_pid, "MCP ownership parent is new daemon")
	var sidecar: Dictionary = record.get("sidecar", {})
	mcp_sidecar_pid = int(sidecar.get("pid", 0))
	mcp_sidecar_started_at_ms = int(sidecar.get("started_at_ms", 0))
	mcp_sidecar_executable = str((record.get("executable", {}) as Dictionary).get("path", ""))
	_expect(mcp_sidecar_pid > 0 and mcp_sidecar_started_at_ms > 0, "MCP ownership names a durable sidecar identity")
	_expect(ProcessIdentity.inspect(mcp_sidecar_pid, mcp_sidecar_started_at_ms).get("matches", false), "MCP ownership sidecar identity is currently live")
	_expect(_same_path(mcp_sidecar_executable, str(lifecycle._payload.get("mcp_path", ""))), "MCP ownership executable is the fixture MCP payload")
	_expect(await _wait_for_bridge_ready(), "MCP bridge reaches READY after nonce-bound ownership publication")
	if not failures.is_empty():
		return
	var mcp_status := await _wait_for_mcp_connected_status()
	_expect(mcp_status.get("request_ok", false), "authenticated MCP status request succeeds after bridge READY: %s" % mcp_status.get("error", ""))
	if not mcp_status.get("request_ok", false):
		return
	_expect(mcp_status.get("connected", false), "authenticated MCP status reports the Godot child connected")
	if not failures.is_empty():
		return
	_publish_event("mcp_ready", {
		"daemon_pid": lifecycle.daemon_pid,
		"owner_nonce": bridge.owner_nonce,
		"launch_nonce": lifecycle.launch_nonce,
		"ownership_path": mcp_ownership_path,
		"discovery_path": bridge.discovery_path,
		"token_path": bridge.token_path,
		"sidecar_pid": mcp_sidecar_pid,
		"sidecar_started_at_ms": mcp_sidecar_started_at_ms,
		"sidecar_executable": mcp_sidecar_executable,
	})
	await _invoke_packaged_tool_once("MCP")
	mcp_tool_completed = failures.is_empty() and command_completed and command_result.get("method") == "get_project_info" and command_result.get("success") == true


func _invoke_packaged_tool_once(phase: String) -> void:
	var created := await _http_json(HTTPClient.METHOD_POST, "/session", {
		"title": "Integration mode switch E2E",
		"permission": [
			{"permission": "*", "pattern": "*", "action": "deny"},
			{"permission": "godot_get_project_info", "pattern": "*", "action": "allow"},
			{"permission": "godot_set_input_action", "pattern": "*", "action": "allow"},
		],
	})
	_expect(created.get("ok", false), "%s generation accepts an authenticated session" % phase)
	if not created.get("ok", false):
		return
	var parser := JSON.new()
	if parser.parse(str(created.get("body", ""))) != OK or not parser.data is Dictionary:
		_expect(false, "%s session response is JSON" % phase)
		return
	var session_id := str((parser.data as Dictionary).get("id", ""))
	_expect(not session_id.is_empty(), "%s session id is non-empty" % phase)
	if session_id.is_empty():
		return
	var submitted := await _http_json(HTTPClient.METHOD_POST, "/session/%s/message" % session_id.uri_encode(), {
		"model": {"providerID": "godot-e2e", "modelID": "tool-test"},
		"parts": [{"type": "text", "text": "Use godot_get_project_info exactly once."}],
	})
	_expect(submitted.get("ok", false), "%s generation invokes packaged tool flow" % phase)
	if submitted.get("ok", false):
		_expect(await _wait_command(), "%s command reaches bridge client" % phase)
		_expect(command_result.get("method") == "get_project_info" and command_result.get("success") == true, "%s bridge executes project info" % phase)
		var response := JSON.new()
		if response.parse(str(command_result.get("response", ""))) == OK and response.data is Dictionary:
			_expect(str((response.data as Dictionary).get("project_name", "")) == str(ProjectSettings.get_setting("application/config/name", "")), "%s get_project_info returns the fixture project" % phase)
		else:
			_expect(false, "%s get_project_info result is JSON" % phase)


func _on_command_completed(method: String, success: bool, response: String, _source_port: int) -> void:
	command_completed = true
	command_result = {"method": method, "success": success, "response": response}


func _wait_ready() -> bool:
	while Time.get_ticks_msec() < _deadline(READY_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge_client()
		if lifecycle.state == "ready" and websocket_server.is_session_ready():
			return true
		if lifecycle.state == "error":
			_print_lifecycle_snapshot("OPENCODE_GODOT_MODE_SWITCH_NATIVE_READY_ERROR")
			_expect(false, "lifecycle error: %s" % lifecycle.detail)
			return false
		await process_frame
	_print_lifecycle_snapshot("OPENCODE_GODOT_MODE_SWITCH_NATIVE_READY_TIMEOUT")
	return false


func _print_lifecycle_snapshot(marker: String) -> void:
	print("%s state=%s detail=%s pid=%d runtime=%s listen=%s ownership=%s output_bytes=%d redaction_tail_bytes=%d" % [
		marker,
		lifecycle.state,
		lifecycle.detail,
		lifecycle.daemon_pid,
		lifecycle.runtime_dir,
		FileAccess.file_exists(lifecycle.runtime_dir.path_join("listen-%s.json" % lifecycle.launch_nonce)),
		FileAccess.file_exists(lifecycle.runtime_dir.path_join("ownership.json")),
		lifecycle._output_buffer.length(),
		lifecycle._redaction_tail.length(),
	])
	print("%s_OUTPUT_TAIL %s" % [marker, JSON.stringify(_redacted_daemon_output_snapshot())])


func _redacted_daemon_output_snapshot() -> String:
	# Production withholds a tail so a credential split across pipe chunks cannot
	# leak. For a bounded timeout snapshot, join both parts and mask full secrets
	# plus any incomplete prefix/suffix that could sit at the snapshot boundary.
	var combined: String = lifecycle._output_buffer + lifecycle._redaction_tail
	for secret_value in [lifecycle.password, lifecycle.launch_nonce]:
		var secret := str(secret_value)
		if secret.is_empty():
			continue
		combined = combined.replace(secret, "[REDACTED]")
		for fragment_length in range(secret.length() - 1, 0, -1):
			var prefix := secret.left(fragment_length)
			if combined.ends_with(prefix):
				combined = combined.left(combined.length() - prefix.length()) + "[REDACTED_FRAGMENT]"
				break
		for fragment_length in range(secret.length() - 1, 0, -1):
			var suffix := secret.right(fragment_length)
			if combined.begins_with(suffix):
				combined = "[REDACTED_FRAGMENT]" + combined.substr(suffix.length())
				break
	return combined.right(2048)


func _wait_for_lifecycle_ready() -> bool:
	while Time.get_ticks_msec() < _deadline(READY_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge_client()
		if lifecycle.state == "ready":
			return true
		if lifecycle.state == "error":
			_print_lifecycle_snapshot("OPENCODE_GODOT_MODE_SWITCH_MCP_READY_ERROR")
			_expect(false, "lifecycle error: %s" % lifecycle.detail)
			return false
		await process_frame
	_print_lifecycle_snapshot("OPENCODE_GODOT_MODE_SWITCH_MCP_READY_TIMEOUT")
	return false


func _wait_for_bridge_ready() -> bool:
	while Time.get_ticks_msec() < _deadline(READY_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge_client()
		if websocket_server.is_session_ready():
			return true
		if lifecycle.state == "error":
			_expect(false, "lifecycle error while waiting for MCP bridge: %s" % lifecycle.detail)
			return false
		await process_frame
	return false


func _wait_command() -> bool:
	while Time.get_ticks_msec() < _deadline(REQUEST_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge_client()
		if command_completed:
			return true
		await process_frame
	return false


func _wait_for_mcp_ownership() -> Variant:
	while Time.get_ticks_msec() < _deadline(15_000):
		lifecycle.update()
		_tick_bridge_client()
		if lifecycle.state == "error":
			_expect(false, "lifecycle error while waiting for MCP ownership: %s" % lifecycle.detail)
			return null
		var record: Variant = _read_json(mcp_ownership_path)
		if record is Dictionary:
			var data: Dictionary = record
			if _is_complete_current_mcp_ownership(data):
				return data
		await process_frame
	_expect(false, "MCP ownership record did not become complete for the current nonce within 15 seconds")
	return null


func _wait_for_mcp_connected_status() -> Dictionary:
	# The trigger request creates OpenCode's MCP InstanceState. The sidecar then
	# publishes ownership and waits for the Godot bridge before its stdio MCP
	# transport can become connected, so this poll runs only after bridge READY.
	while Time.get_ticks_msec() < _deadline(READY_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge_client()
		if lifecycle.state == "error":
			return {"request_ok": false, "connected": false, "error": "lifecycle entered error while polling MCP status"}
		var response := await _http_json(HTTPClient.METHOD_GET, "/mcp")
		if not response.get("ok", false):
			return {"request_ok": false, "connected": false, "error": response.get("error", "MCP status request failed")}
		if _mcp_status_is_connected(response):
			return {"request_ok": true, "connected": true}
		var retry_at := Time.get_ticks_msec() + 100
		while Time.get_ticks_msec() < retry_at:
			lifecycle.update()
			_tick_bridge_client()
			await process_frame
	return {"request_ok": true, "connected": false, "error": "MCP status remained disconnected until the readiness deadline"}


func _is_complete_current_mcp_ownership(record: Dictionary) -> bool:
	var sidecar: Dictionary = record.get("sidecar", {})
	var executable: Dictionary = record.get("executable", {})
	var parent: Dictionary = record.get("opencode_parent", {})
	return record.get("schema") == "opencode-godot-mcp-ownership" \
		and int(record.get("schema_version", 0)) == 1 \
		and record.get("canonical_project") == bridge.project_path \
		and record.get("launch_nonce") == lifecycle.launch_nonce \
		and int(parent.get("pid", 0)) == lifecycle.daemon_pid \
		and int(sidecar.get("pid", 0)) > 0 \
		and int(sidecar.get("started_at_ms", 0)) > 0 \
		and not str(executable.get("path", "")).is_empty()


func _mcp_status_is_connected(response: Dictionary) -> bool:
	if int(response.get("code", 0)) != 200:
		return false
	var parser := JSON.new()
	if parser.parse(str(response.get("body", ""))) != OK or not parser.data is Dictionary:
		return false
	var statuses: Dictionary = parser.data
	var godot: Variant = statuses.get("godot")
	return godot is Dictionary and (godot as Dictionary).get("status") == "connected"


func _wait_process_stale(pid: int, started_at_ms: int, message: String) -> void:
	while Time.get_ticks_msec() < _deadline(15_000):
		if ProcessIdentity.inspect(pid, started_at_ms).get("stale", false):
			_expect(true, message)
			return
		await process_frame
	_expect(false, message)


func _http_json(method: HTTPClient.Method, request_path: String, payload: Variant = null) -> Dictionary:
	var port := int(str(lifecycle.base_url).get_slice(":", 2))
	if port < 1:
		return {"ok": false, "error": "invalid daemon port"}
	var client := HTTPClient.new()
	if client.connect_to_host("127.0.0.1", port) != OK:
		return {"ok": false, "error": "daemon connect failed"}
	var headers := PackedStringArray([
		"Authorization: Basic %s" % Marshalls.utf8_to_base64("opencode:%s" % lifecycle.password),
		"Accept: application/json", "Content-Type: application/json",
		"x-opencode-directory: %s" % bridge.project_path.uri_encode(),
	])
	var requested := false
	var code := 0
	var response_started := false
	var bytes := PackedByteArray()
	while Time.get_ticks_msec() < _deadline(REQUEST_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge_client()
		if client.poll() != OK:
			client.close()
			return {"ok": false, "error": "HTTP poll failed"}
		match client.get_status():
			HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING:
				pass
			HTTPClient.STATUS_CONNECTED:
				if requested and response_started:
					client.close()
					return {"ok": code >= 200 and code < 300, "code": code, "body": bytes.get_string_from_utf8()}
				if not requested:
					if client.request(method, request_path, headers, JSON.stringify(payload) if payload != null else "") != OK:
						client.close()
						return {"ok": false, "error": "HTTP request failed"}
					requested = true
				if client.has_response():
					code = client.get_response_code()
					response_started = true
			HTTPClient.STATUS_BODY:
				if code == 0 and client.has_response():
					code = client.get_response_code()
				var chunk := client.read_response_body_chunk()
				if not chunk.is_empty(): bytes.append_array(chunk)
				var expected := client.get_response_body_length()
				if expected >= 0 and bytes.size() >= expected:
					client.close()
					return {"ok": code >= 200 and code < 300, "code": code, "body": bytes.get_string_from_utf8()}
			HTTPClient.STATUS_DISCONNECTED:
				client.close()
				return {"ok": code >= 200 and code < 300, "code": code, "body": bytes.get_string_from_utf8()}
			HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
				client.close()
				return {"ok": false, "error": "HTTP transport failed"}
		await process_frame
	client.close()
	return {"ok": false, "error": "HTTP timeout"}


func _cleanup_everything() -> void:
	if lifecycle != null: lifecycle.stop()
	if mcp_sidecar_pid > 0 and mcp_sidecar_started_at_ms > 0:
		await _wait_process_stale(mcp_sidecar_pid, mcp_sidecar_started_at_ms, "saved MCP sidecar identity exits during final cleanup")
	if websocket_server != null: websocket_server.stop_server()
	if bridge != null: bridge.stop_session()
	await process_frame
	_expect(lifecycle == null or lifecycle.state == "stopped", "final lifecycle stops")
	_expect(bridge == null or not FileAccess.file_exists(bridge.session_path), "final bridge session is removed")
	_expect(bridge == null or not FileAccess.file_exists(bridge.discovery_path), "final discovery is removed")
	_expect(bridge == null or not FileAccess.file_exists(bridge.token_path), "final token is removed")
	_expect(mcp_ownership_path.is_empty() or not FileAccess.file_exists(mcp_ownership_path), "final MCP ownership is removed")
	_expect(mcp_ownership_path.is_empty() or not FileAccess.file_exists(mcp_ownership_path + ".bak"), "final MCP ownership backup is removed")


func _ownership_path() -> String:
	return lifecycle.runtime_dir.path_join("mcp-ownership-%s.json" % lifecycle.launch_nonce) if lifecycle != null else ""


func _tick_bridge_client() -> void:
	if websocket_server != null and websocket_server.has_method("_process"):
		websocket_server._process(0.016)


func _publish_event(phase: String, extra: Dictionary) -> void:
	if event_path.is_empty(): return
	var data := {"phase": phase, "project": bridge.project_path}
	for key: String in extra: data[key] = extra[key]
	DirAccess.make_dir_recursive_absolute(event_path.get_base_dir())
	var file := FileAccess.open(event_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data))
		file.close()


func _wait_for_wrapper_continue() -> bool:
	if continue_path.is_empty(): return true
	while Time.get_ticks_msec() < _deadline(15_000):
		if FileAccess.file_exists(continue_path): return true
		lifecycle.update()
		_tick_bridge_client()
		await process_frame
	return false


func _read_json(path: String) -> Variant:
	if path.is_empty() or not FileAccess.file_exists(path): return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return null
	var parser := JSON.new()
	var error := parser.parse(file.get_as_text())
	file.close()
	return parser.data if error == OK else null


func _same_path(left: String, right: String) -> bool:
	var normalized_left := left.replace("\\", "/").simplify_path()
	var normalized_right := right.replace("\\", "/").simplify_path()
	if OS.get_name() == "Windows":
		normalized_left = normalized_left.to_lower()
		normalized_right = normalized_right.to_lower()
	return not normalized_left.is_empty() and normalized_left == normalized_right


func _deadline(timeout_ms: int) -> int:
	return mini(Time.get_ticks_msec() + timeout_ms, deadline_ms)


func _expect(value: bool, message: String) -> void:
	if not value: failures.append(message)


func _finish() -> void:
	var result := {
		"ok": failures.is_empty(),
		"failures": failures,
		"host": {
			"os": OS.get_name(),
			"architecture": Engine.get_architecture_name().to_lower(),
			"path": OS.get_environment("PATH"),
		},
		"tool_calls": {"native": native_tool_completed, "mcp": mcp_tool_completed},
	}
	if not result_path.is_empty():
		DirAccess.make_dir_recursive_absolute(result_path.get_base_dir())
		var file := FileAccess.open(result_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(result))
			file.close()
	if failures.is_empty():
		print("OPENCODE_GODOT_INTEGRATION_MODE_SWITCH_E2E_OK")
		quit(0)
	for failure: String in failures: push_error("TEST FAILURE: " + failure)
	quit(1)
