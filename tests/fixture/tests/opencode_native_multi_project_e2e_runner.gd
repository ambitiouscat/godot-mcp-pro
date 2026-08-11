extends SceneTree

## Concurrent native-mode black-box runner.  Each copy runs in a distinct
## Godot project and invokes the packaged OpenCode *file plugin* through the
## daemon lifecycle, not through an MCP sidecar.

const Protocol := preload("res://addons/opencode_godot/engine_bridge/bridge_protocol_v1.gd")
const ProcessIdentity := preload("res://addons/opencode_godot/engine_bridge/bridge_process_identity.gd")
const SessionCoordinator := preload("res://addons/opencode_godot/engine_bridge/bridge_session_coordinator.gd")
const CommandRouter := preload("res://addons/opencode_godot/engine_bridge/command_router.gd")
const WebSocketServer := preload("res://addons/opencode_godot/engine_bridge/websocket_server.gd")
const TestLifecycle := preload("res://tests/opencode_native_e2e_test_lifecycle.gd")
const TestEditorPlugin := preload("res://tests/opencode_e2e_test_editor_plugin.gd")

const TOTAL_TIMEOUT_MS := 160_000
const REQUEST_TIMEOUT_MS := 90_000

var failures: Array[String] = []
var bridge: RefCounted
var command_router: Node
var websocket_server: Node
var lifecycle: RefCounted
var editor_plugin: EditorPlugin
var result_path := ""
var completed: Dictionary = {}
var completed_seen := false
var run_deadline_ms := 0
var snapshot: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	run_deadline_ms = Time.get_ticks_msec() + TOTAL_TIMEOUT_MS
	result_path = OS.get_environment("GODOT_NATIVE_E2E_RESULT_PATH")
	if OS.get_name() != "Windows":
		_expect(false, "native multi-project E2E requires Windows")
	if Engine.get_architecture_name().to_lower() != "x86_64":
		_expect(false, "native multi-project E2E requires x86_64")
	var cleanup_needed := false
	bridge = SessionCoordinator.new()
	if bridge.start_session():
		cleanup_needed = true
		await _setup()
		if failures.is_empty():
			await _exercise_native_file_plugin()
		_snapshot_before_cleanup()
	else:
		_expect(false, "bridge starts: %s" % bridge.last_error)
	if cleanup_needed:
		await _cleanup()
	_write_result()
	if failures.is_empty():
		print("OPENCODE_GODOT_NATIVE_MULTI_PROJECT_E2E_OK")
		quit(0)
	for failure: String in failures:
		push_error("TEST FAILURE: " + failure)
	quit(1)


func _setup() -> void:
	_expect(not bridge.project_path.is_empty(), "canonical bridge project is non-empty")
	_expect(bridge.project_path == Protocol.canonicalize_project_path(ProjectSettings.globalize_path("res://")), "bridge path is this fixture")
	command_router = CommandRouter.new()
	command_router.name = "OpenCodeGodotNativeE2ERouter"
	get_root().add_child(command_router)
	editor_plugin = TestEditorPlugin.new()
	editor_plugin.name = "OpenCodeGodotNativeE2EEditorPlugin"
	get_root().add_child(editor_plugin)
	websocket_server = WebSocketServer.new()
	websocket_server.name = "OpenCodeGodotNativeE2EBridgeClient"
	websocket_server.command_router = command_router
	websocket_server.session_coordinator = bridge
	get_root().add_child(websocket_server)
	await process_frame
	command_router.configure_bridge_context(bridge.project_path, websocket_server.is_session_ready, null)
	command_router.editor_plugin = editor_plugin
	websocket_server.command_completed.connect(_on_command_completed)
	websocket_server.start_server(bridge)
	lifecycle = TestLifecycle.new()
	lifecycle.setup(bridge, websocket_server)
	lifecycle.state_changed.connect(_on_lifecycle_state_changed)
	lifecycle.diagnostic.connect(_on_lifecycle_diagnostic)
	var selected: Dictionary = lifecycle.set_requested_integration_mode("native")
	_expect(selected.get("ok", false) and str(selected.get("mode", "")) == "native", "native mode is explicitly selected")
	var launch: Dictionary = lifecycle.start()
	_expect(launch.get("ok", false), "native OpenCode daemon launches: %s" % launch.get("error", ""))


func _exercise_native_file_plugin() -> void:
	if lifecycle.state == "error":
		return
	var ready := await _wait_for_ready()
	_expect(ready, "native OpenCode daemon and bridge become ready")
	if not ready:
		return
	_expect(lifecycle.get_integration_mode() == "native", "lifecycle remains in native mode")
	_expect(not lifecycle._payload.get("mcp_available", false), "native lifecycle does not expose an MCP sidecar")
	var config: Dictionary = lifecycle._build_owned_config()
	_expect(config.has("plugin") and not config.has("mcp"), "native daemon config contains file plugin and no mcp block")
	if config.has("plugin") and config["plugin"] is Array:
		var plugins: Array = config["plugin"]
		_expect(plugins.size() == 1 and plugins[0] is Array, "native config has one plugin registration")
		if plugins.size() == 1 and plugins[0] is Array:
			var registration: Array = plugins[0]
			_expect(registration.size() == 2 and str(registration[0]).begins_with("file:///"), "native plugin registration uses a file URL")
	_expect(not FileAccess.file_exists(lifecycle.runtime_dir.path_join("mcp-ownership-%s.json" % lifecycle.launch_nonce)), "native mode writes no MCP ownership record")
	var discovery: Variant = _read_json(bridge.discovery_path)
	_expect(discovery is Dictionary, "native file plugin publishes authenticated bridge discovery")
	if discovery is Dictionary:
		var record: Dictionary = discovery
		_expect(record.get("project_path") == bridge.project_path, "native discovery targets this project")
		_expect(record.get("owner_nonce") == bridge.owner_nonce, "native discovery binds this editor owner nonce")
		# The native plugin's bridge listener is parent-bound to the durable
		# Godot editor identity, not to an implementation-specific Bun worker.
		_expect(int(record.get("parent_pid", 0)) == bridge.coordinator_pid, "native discovery parent is this Godot editor")
		_expect(str(record.get("endpoint", "")).begins_with("ws://127.0.0.1:"), "native discovery endpoint is loopback websocket")
	var created := await _http_json(HTTPClient.METHOD_POST, "/session", {
		"title": "Native multi-project E2E",
		"permission": [
			{"permission": "*", "pattern": "*", "action": "deny"},
			{"permission": "godot_get_project_info", "pattern": "*", "action": "allow"},
			# Keep the complex registered tool enabled so the external provider can
			# verify its real OpenCode JSON Schema even though this flow invokes the
			# simpler read-only tool below.
			{"permission": "godot_set_input_action", "pattern": "*", "action": "allow"},
		],
	})
	_expect(created.get("ok", false), "native daemon creates authenticated session: %s" % created.get("error", ""))
	if not created.get("ok", false):
		return
	var parser := JSON.new()
	_expect(parser.parse(str(created.get("body", ""))) == OK and parser.data is Dictionary, "native session result is JSON")
	if not parser.data is Dictionary:
		return
	var session_id := str((parser.data as Dictionary).get("id", ""))
	_expect(not session_id.is_empty(), "native session has an id")
	if session_id.is_empty():
		return
	var submitted := await _http_json(HTTPClient.METHOD_POST, "/session/%s/message" % session_id.uri_encode(), {
		"model": {"providerID": "godot-e2e", "modelID": "tool-test"},
		"parts": [{"type": "text", "text": "Use godot_get_project_info exactly once."}],
	})
	_expect(submitted.get("ok", false), "native daemon accepts tool request: %s" % submitted.get("error", ""))
	if not submitted.get("ok", false):
		return
	var command_ready := await _wait_for_command()
	_expect(command_ready, "packaged native file plugin forwards the project command")
	if command_ready:
		_expect(completed.get("method") == "get_project_info", "native command router receives get_project_info")
		_expect(completed.get("success") == true, "native command succeeds")
		_expect(int(completed.get("source_port", 0)) == _bridge_port(), "native command source endpoint is this discovery endpoint")
		var response := JSON.new()
		_expect(response.parse(str(completed.get("response", ""))) == OK and response.data is Dictionary, "native project result is JSON")
		if response.data is Dictionary:
			var data: Dictionary = response.data
			_expect(str(data.get("project_name", "")) == str(ProjectSettings.get_setting("application/config/name", "")), "native result keeps this project's name")
			_expect(_same_path(str(data.get("project_path", "")), bridge.project_path), "native result keeps this project's canonical path")
	var history := await _wait_for_history(session_id)
	_expect(history, "native session history contains its completed Godot tool")


func _on_command_completed(method: String, success: bool, response: String, source_port: int) -> void:
	completed = {"method": method, "success": success, "response": response, "source_port": source_port}
	completed_seen = true


func _on_lifecycle_state_changed(state: String, detail: String) -> void:
	print("[native-e2e][lifecycle] %s: %s" % [state, detail])


func _on_lifecycle_diagnostic(category: String, message: String) -> void:
	print("[native-e2e][diagnostic][%s] %s" % [category, message])


func _wait_for_ready() -> bool:
	while Time.get_ticks_msec() < _deadline(REQUEST_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge_client()
		if lifecycle.state == "ready" and websocket_server.is_session_ready():
			return true
		if lifecycle.state == "error":
			_expect(false, "native lifecycle error: %s" % lifecycle.detail)
			return false
		await process_frame
	print("[native-e2e][timeout] lifecycle=%s detail=%s discovery=%s websocket=%s child=%s" % [lifecycle.state, lifecycle.detail, bridge.discovery_path, websocket_server.get_state_detail(), str(lifecycle._output_buffer).replace("\u0000", " ")])
	var discovery: Variant = _read_json(bridge.discovery_path)
	if discovery is Dictionary:
		print("[native-e2e][timeout-discovery] %s" % JSON.stringify(discovery))
	return false


func _wait_for_command() -> bool:
	while Time.get_ticks_msec() < _deadline(REQUEST_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge_client()
		if completed_seen:
			return true
		await process_frame
	return false


func _wait_for_history(session_id: String) -> bool:
	while Time.get_ticks_msec() < _deadline(REQUEST_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge_client()
		var response := await _http_json(HTTPClient.METHOD_GET, "/session/%s/message" % session_id.uri_encode(), null, 10_000)
		if response.get("ok", false) and _has_completed_tool(str(response.get("body", ""))):
			return true
		if not response.get("ok", false) and int(response.get("code", 0)) >= 400:
			return false
		await process_frame
	return false


func _has_completed_tool(body: String) -> bool:
	var parser := JSON.new()
	if parser.parse(body) != OK or not parser.data is Array:
		return false
	for message_value: Variant in parser.data:
		if not message_value is Dictionary:
			continue
		for part_value: Variant in (message_value as Dictionary).get("parts", []):
			if part_value is Dictionary:
				var part: Dictionary = part_value
				var state: Variant = part.get("state", {})
				if str(part.get("tool", "")) == "godot_get_project_info" and state is Dictionary and str((state as Dictionary).get("status", "")) == "completed":
					return true
	return false


func _http_json(method: HTTPClient.Method, request_path: String, payload: Variant = null, timeout_ms: int = REQUEST_TIMEOUT_MS) -> Dictionary:
	var port := int(str(lifecycle.base_url).get_slice(":", 2))
	if port < 1 or port > 65535:
		return {"ok": false, "error": "invalid native daemon URL"}
	var client := HTTPClient.new()
	if client.connect_to_host("127.0.0.1", port) != OK:
		return {"ok": false, "error": "could not connect to native daemon"}
	var authorization := Marshalls.utf8_to_base64("opencode:%s" % lifecycle.password)
	var headers := PackedStringArray([
		"Authorization: Basic %s" % authorization,
		"Accept: application/json",
		"Content-Type: application/json",
		"x-opencode-directory: %s" % bridge.project_path.uri_encode(),
	])
	var requested := false
	var code := 0
	var response_started := false
	var bytes := PackedByteArray()
	while Time.get_ticks_msec() < _deadline(timeout_ms):
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
					return {"ok": code >= 200 and code < 300, "code": code, "body": bytes.get_string_from_utf8(), "error": "HTTP %d" % code}
				if not requested:
					var requested_error := client.request(method, request_path, headers, JSON.stringify(payload) if payload != null else "")
					requested = true
					if requested_error != OK:
						client.close()
						return {"ok": false, "error": "HTTP request failed"}
				if client.has_response():
					code = client.get_response_code()
					response_started = true
			HTTPClient.STATUS_BODY:
				if code == 0 and client.has_response():
					code = client.get_response_code()
					response_started = true
				var chunk := client.read_response_body_chunk()
				if not chunk.is_empty():
					bytes.append_array(chunk)
				var expected := client.get_response_body_length()
				if expected >= 0 and bytes.size() >= expected:
					client.close()
					return {"ok": code >= 200 and code < 300, "code": code, "body": bytes.get_string_from_utf8(), "error": "HTTP %d" % code}
			HTTPClient.STATUS_DISCONNECTED:
				client.close()
				return {"ok": code >= 200 and code < 300, "code": code, "body": bytes.get_string_from_utf8(), "error": "HTTP %d" % code}
			HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
				client.close()
				return {"ok": false, "error": "native HTTP transport failed"}
		await process_frame
	client.close()
	return {"ok": false, "error": "native HTTP request timed out"}


func _snapshot_before_cleanup() -> void:
	var discovery: Variant = _read_json(bridge.discovery_path)
	snapshot = {
		"ok": failures.is_empty(),
		"project_name": str(ProjectSettings.get_setting("application/config/name", "")),
		"canonical_project": bridge.project_path,
		"session_path": bridge.session_path,
		"discovery_path": bridge.discovery_path,
		"owner_nonce": bridge.owner_nonce,
		"daemon_pid": lifecycle.daemon_pid if lifecycle != null else 0,
		"editor_pid": bridge.coordinator_pid,
		"launch_nonce": lifecycle.launch_nonce if lifecycle != null else "",
		"integration_mode": lifecycle.get_integration_mode() if lifecycle != null else "",
		"discovery_endpoint": str((discovery as Dictionary).get("endpoint", "")) if discovery is Dictionary else "",
		"discovery_parent_pid": int((discovery as Dictionary).get("parent_pid", 0)) if discovery is Dictionary else 0,
		"mcp_ownership_path": lifecycle.runtime_dir.path_join("mcp-ownership-%s.json" % lifecycle.launch_nonce) if lifecycle != null else "",
	}


func _cleanup() -> void:
	if lifecycle != null:
		lifecycle.stop()
	if websocket_server != null:
		websocket_server.stop_server()
	await process_frame
	if command_router != null:
		command_router.queue_free()
	if websocket_server != null:
		websocket_server.queue_free()
	if editor_plugin != null:
		editor_plugin.queue_free()
	if bridge != null:
		bridge.stop_session()
	await process_frame
	if not snapshot.is_empty():
		snapshot["cleanup"] = {
			"session_removed": not FileAccess.file_exists(str(snapshot.get("session_path", ""))),
			"discovery_removed": not FileAccess.file_exists(str(snapshot.get("discovery_path", ""))),
			"mcp_ownership_absent": not FileAccess.file_exists(str(snapshot.get("mcp_ownership_path", ""))),
		}


func _write_result() -> void:
	if result_path.is_empty():
		return
	if snapshot.is_empty():
		snapshot = {"ok": false}
	snapshot["ok"] = failures.is_empty()
	snapshot["failures"] = failures
	DirAccess.make_dir_recursive_absolute(result_path.get_base_dir())
	var file := FileAccess.open(result_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(snapshot))
		file.close()


func _bridge_port() -> int:
	return int(str(websocket_server.get_endpoint()).get_slice(":", 2))


func _tick_bridge_client() -> void:
	# In `--editor --script` headless runners Godot may provide zero process
	# delta while awaiting `process_frame`; explicitly tick the same Node method
	# with a bounded simulation delta so WebSocketPeer.poll advances exactly as
	# it does in a normal editor frame.
	if websocket_server != null and websocket_server.has_method("_process"):
		websocket_server._process(0.016)


func _read_json(path: String) -> Variant:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parser := JSON.new()
	var error := parser.parse(file.get_as_text())
	file.close()
	return parser.data if error == OK else null


func _same_path(left: String, right: String) -> bool:
	return left.replace("\\", "/").simplify_path().to_lower() == right.replace("\\", "/").simplify_path().to_lower()


func _deadline(timeout_ms: int) -> int:
	return mini(Time.get_ticks_msec() + timeout_ms, run_deadline_ms)


func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
