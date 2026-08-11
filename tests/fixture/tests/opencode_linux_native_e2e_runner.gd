extends SceneTree

## Linux x86_64 copied-addon black-box runner.  This deliberately uses the
## packaged OpenCode file plugin and a real authenticated bridge; no Node/Bun
## executable is available to this Godot process or its daemon child.

const Protocol := preload("res://addons/opencode_godot/engine_bridge/bridge_protocol_v1.gd")
const SessionCoordinator := preload("res://addons/opencode_godot/engine_bridge/bridge_session_coordinator.gd")
const CommandRouter := preload("res://addons/opencode_godot/engine_bridge/command_router.gd")
const WebSocketServer := preload("res://addons/opencode_godot/engine_bridge/websocket_server.gd")
const TestLifecycle := preload("res://tests/opencode_native_e2e_test_lifecycle.gd")
const TestEditorPlugin := preload("res://tests/opencode_e2e_test_editor_plugin.gd")

const TOTAL_TIMEOUT_MS := 150_000
const REQUEST_TIMEOUT_MS := 80_000

var failures: Array[String] = []
var bridge: RefCounted
var lifecycle: RefCounted
var command_router: Node
var websocket_server: Node
var editor_plugin: EditorPlugin
var result_path := ""
var ready_path := ""
var deadline_ms := 0
var command_done := false
var command: Dictionary = {}
var snapshot: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	deadline_ms = Time.get_ticks_msec() + TOTAL_TIMEOUT_MS
	result_path = OS.get_environment("GODOT_LINUX_NATIVE_E2E_RESULT_PATH")
	ready_path = OS.get_environment("GODOT_LINUX_NATIVE_E2E_READY_PATH")
	_expect(OS.get_name() == "Linux", "runner requires Linux")
	_expect(Engine.get_architecture_name().to_lower() == "x86_64", "runner requires x86_64 Godot")
	bridge = SessionCoordinator.new()
	if bridge.start_session():
		await _setup()
		if failures.is_empty():
			await _exercise()
		_snapshot()
	else:
		_expect(false, "bridge starts: %s" % bridge.last_error)
	await _cleanup()
	_write_result()
	if failures.is_empty():
		print("OPENCODE_GODOT_LINUX_NATIVE_COPIED_ADDON_E2E_OK")
		quit(0)
	for failure: String in failures:
		push_error("TEST FAILURE: " + failure)
	quit(1)


func _setup() -> void:
	_expect(bridge.project_path == Protocol.canonicalize_project_path(ProjectSettings.globalize_path("res://")), "canonical project is fixture")
	command_router = CommandRouter.new()
	get_root().add_child(command_router)
	editor_plugin = TestEditorPlugin.new()
	get_root().add_child(editor_plugin)
	websocket_server = WebSocketServer.new()
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
	var mode: Dictionary = lifecycle.set_requested_integration_mode("native")
	_expect(mode.get("ok", false) and mode.get("mode", "") == "native", "native mode explicitly selected")
	var started: Dictionary = lifecycle.start()
	_expect(started.get("ok", false), "bundled OpenCode launches: %s" % started.get("error", ""))


func _exercise() -> void:
	var ready := await _wait_ready()
	_expect(ready, "HMAC-authenticated bridge reaches READY with native daemon")
	if not ready:
		return
	_expect(lifecycle.get_integration_mode() == "native", "lifecycle remains native")
	_expect(not lifecycle._payload.get("mcp_available", false), "native payload does not activate MCP sidecar")
	var config: Dictionary = lifecycle._build_owned_config()
	_expect(config.has("plugin") and not config.has("mcp"), "native config has packaged file plugin and no MCP server")
	var plugins: Array = config.get("plugin", [])
	_expect(plugins.size() == 1 and plugins[0] is Array and (plugins[0] as Array).size() == 2 and str((plugins[0] as Array)[0]).begins_with("file:///"), "native config registers one file URL plugin")
	_expect(not FileAccess.file_exists(lifecycle.runtime_dir.path_join("mcp-ownership-%s.json" % lifecycle.launch_nonce)), "native launch creates no MCP ownership record")
	var discovery: Variant = _read_json(bridge.discovery_path)
	_expect(discovery is Dictionary, "native daemon publishes bridge discovery")
	if discovery is Dictionary:
		var record: Dictionary = discovery
		_expect(record.get("project_path") == bridge.project_path, "discovery is project-scoped")
		_expect(record.get("owner_nonce") == bridge.owner_nonce, "discovery carries session owner nonce")
		_expect(int(record.get("parent_pid", 0)) == bridge.coordinator_pid, "discovery parent is Godot")
		_expect(str(record.get("endpoint", "")).begins_with("ws://127.0.0.1:"), "discovery endpoint is loopback")
	_publish_ready()
	var created := await _http_json(HTTPClient.METHOD_POST, "/session", {
		"title": "Linux native copied-addon E2E",
		"permission": [
			{"permission": "*", "pattern": "*", "action": "deny"},
			{"permission": "godot_get_project_info", "pattern": "*", "action": "allow"},
			{"permission": "godot_set_input_action", "pattern": "*", "action": "allow"},
		],
	})
	_expect(created.get("ok", false), "daemon accepts authenticated session: %s" % created.get("error", ""))
	if not created.get("ok", false):
		return
	var parser := JSON.new()
	if parser.parse(str(created.get("body", ""))) != OK or not parser.data is Dictionary:
		_expect(false, "session response is JSON")
		return
	var session_id := str((parser.data as Dictionary).get("id", ""))
	_expect(not session_id.is_empty(), "session id is non-empty")
	if session_id.is_empty():
		return
	var sent := await _http_json(HTTPClient.METHOD_POST, "/session/%s/message" % session_id.uri_encode(), {
		"model": {"providerID": "godot-e2e", "modelID": "tool-test"},
		"parts": [{"type": "text", "text": "Use godot_get_project_info exactly once."}],
	})
	_expect(sent.get("ok", false), "daemon accepts native file-plugin tool request: %s" % sent.get("error", ""))
	if sent.get("ok", false):
		_expect(await _wait_command(), "native file plugin forwards get_project_info over bridge")
		_expect(command.get("method") == "get_project_info" and command.get("success") == true, "native get_project_info succeeds")
		var response := JSON.new()
		if response.parse(str(command.get("response", ""))) == OK and response.data is Dictionary:
			_expect(str((response.data as Dictionary).get("project_name", "")) == str(ProjectSettings.get_setting("application/config/name", "")), "tool returns fixture project info")
		else:
			_expect(false, "get_project_info result is JSON")


func _on_command_completed(method: String, success: bool, response: String, _source_port: int) -> void:
	command = {"method": method, "success": success, "response": response}
	command_done = true


func _wait_ready() -> bool:
	while Time.get_ticks_msec() < _deadline(REQUEST_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge()
		if lifecycle.state == "ready" and websocket_server.is_session_ready():
			return true
		if lifecycle.state == "error":
			_expect(false, "lifecycle error: %s" % lifecycle.detail)
			return false
		await process_frame
	return false


func _wait_command() -> bool:
	while Time.get_ticks_msec() < _deadline(REQUEST_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge()
		if command_done:
			return true
		await process_frame
	return false


func _http_json(method: HTTPClient.Method, request_path: String, payload: Variant = null) -> Dictionary:
	var port := int(str(lifecycle.base_url).get_slice(":", 2))
	if port < 1 or port > 65535:
		return {"ok": false, "error": "invalid daemon URL"}
	var client := HTTPClient.new()
	if client.connect_to_host("127.0.0.1", port) != OK:
		return {"ok": false, "error": "could not connect to daemon"}
	var headers := PackedStringArray([
		"Authorization: Basic %s" % Marshalls.utf8_to_base64("opencode:%s" % lifecycle.password),
		"Accept: application/json", "Content-Type: application/json",
		"x-opencode-directory: %s" % bridge.project_path.uri_encode(),
	])
	var requested := false
	var code := 0
	var started := false
	var bytes := PackedByteArray()
	while Time.get_ticks_msec() < _deadline(REQUEST_TIMEOUT_MS):
		lifecycle.update()
		_tick_bridge()
		if client.poll() != OK:
			client.close()
			return {"ok": false, "error": "HTTP poll failed"}
		match client.get_status():
			HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING:
				pass
			HTTPClient.STATUS_CONNECTED:
				if requested and started:
					client.close()
					return {"ok": code >= 200 and code < 300, "code": code, "body": bytes.get_string_from_utf8(), "error": "HTTP %d" % code}
				if not requested:
					if client.request(method, request_path, headers, JSON.stringify(payload) if payload != null else "") != OK:
						client.close()
						return {"ok": false, "error": "HTTP request failed"}
					requested = true
				if client.has_response():
					code = client.get_response_code()
					started = true
			HTTPClient.STATUS_BODY:
				if code == 0 and client.has_response():
					code = client.get_response_code()
					started = true
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
				return {"ok": false, "error": "HTTP transport failed"}
		await process_frame
	client.close()
	return {"ok": false, "error": "HTTP timeout"}


func _snapshot() -> void:
	var discovery: Variant = _read_json(bridge.discovery_path)
	snapshot = {
		"ok": failures.is_empty(),
		"project": bridge.project_path,
		"session_path": bridge.session_path,
		"discovery_path": bridge.discovery_path,
		"daemon_pid": lifecycle.daemon_pid if lifecycle != null else 0,
		"integration_mode": lifecycle.get_integration_mode() if lifecycle != null else "",
		"discovery_endpoint": str((discovery as Dictionary).get("endpoint", "")) if discovery is Dictionary else "",
		"mcp_ownership_path": lifecycle.runtime_dir.path_join("mcp-ownership-%s.json" % lifecycle.launch_nonce) if lifecycle != null else "",
	}


func _publish_ready() -> void:
	if ready_path.is_empty() or not failures.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(ready_path.get_base_dir())
	var file := FileAccess.open(ready_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"mode": lifecycle.get_integration_mode(), "daemon_pid": lifecycle.daemon_pid, "project": bridge.project_path}))
		file.close()


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


func _tick_bridge() -> void:
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


func _deadline(timeout_ms: int) -> int:
	return mini(Time.get_ticks_msec() + timeout_ms, deadline_ms)


func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
