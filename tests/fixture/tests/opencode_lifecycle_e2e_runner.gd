extends SceneTree

## End-to-end lifecycle runner for the packaged OpenCode for Godot addon.
##
## The PowerShell launcher copies this fixture and the complete unified addon
## into a fresh project.  This runner intentionally constructs the three
## editor-owned objects itself: one bridge coordinator, one command router,
## and one WebSocket client.  That keeps duplicate ownership observable while
## still exercising the exact addon scripts and packaged daemon/sidecar.

const Protocol := preload("res://addons/opencode_godot/engine_bridge/bridge_protocol_v1.gd")
const ProcessIdentity := preload("res://addons/opencode_godot/engine_bridge/bridge_process_identity.gd")
const SessionCoordinator := preload("res://addons/opencode_godot/engine_bridge/bridge_session_coordinator.gd")
const CommandRouter := preload("res://addons/opencode_godot/engine_bridge/command_router.gd")
const WebSocketServer := preload("res://addons/opencode_godot/engine_bridge/websocket_server.gd")
const TestLifecycle := preload("res://tests/opencode_e2e_test_lifecycle.gd")
const TestEditorPlugin := preload("res://tests/opencode_e2e_test_editor_plugin.gd")

const STARTUP_TIMEOUT_MS := 90_000
const MCP_REQUEST_TIMEOUT_MS := 90_000
const BRIDGE_TIMEOUT_MS := 60_000
const STOP_TIMEOUT_MS := 15_000
const TOTAL_TIMEOUT_MS := 180_000
const SENTINEL_TEXT := "unrelated-test-state-must-survive"

var failures: Array[String] = []
var bridge: RefCounted
var command_router: Node
var websocket_server: Node
var lifecycle: RefCounted
var test_editor_plugin: EditorPlugin
var descriptor_path := ""
var listen_record_path := ""
var mcp_ownership_path := ""
var bridge_sentinel_path := ""
var daemon_sentinel_path := ""
var external_sentinel_path := ""
var descriptor_observed := false
var listen_record_observed := false
var discovery_observed := false
var mcp_ownership_observed := false
var daemon_pid := 0
var sidecar_pid := 0
var startup_diagnostics_captured := false
var project_probe_diagnostic_done := false
var run_deadline_ms := 0
var stage_log_path := ""
var completed_command: Dictionary = {}
var completed_command_seen := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	run_deadline_ms = Time.get_ticks_msec() + TOTAL_TIMEOUT_MS
	stage_log_path = OS.get_environment("GODOT_MCP_E2E_STAGE_LOG")
	_stage("runner-start")
	var expected_path := OS.get_environment("GODOT_MCP_E2E_EXPECTED_PATH")
	if not expected_path.is_empty():
		_expect(OS.get_environment("PATH") == expected_path, "child process PATH is restricted to the explicit system tool directories")
		print("[E2E][path] restricted child PATH verified")
	if OS.get_name() != "Windows":
		_expect(false, "lifecycle E2E requires Windows")
	if Engine.get_architecture_name().to_lower() != "x86_64":
		_expect(false, "lifecycle E2E requires a Windows x86_64 Godot process")

	var cleanup_needed := false
	_stage("bridge-start")
	bridge = SessionCoordinator.new()
	if bridge.start_session():
		cleanup_needed = true
		_stage("components-start")
		await _setup_owned_components()
		_stage("lifecycle-flow-start")
		await _run_lifecycle_flow()
	else:
		_expect(false, "bridge coordinator starts: %s" % bridge.last_error)

	# Cleanup is deliberately reached for both success and assertion failures.
	# A malformed/parse failure aborts before this script runs and is handled by
	# the PowerShell wrapper, which also kills only processes carrying this
	# fixture's path.
	if cleanup_needed:
		_stage("cleanup-start")
		await _stop_owned_components()
		_stage("cleanup-finished")

	if failures.is_empty():
		_stage("success")
		print("OPENCODE_GODOT_LIFECYCLE_E2E_OK")
		quit(0)
	else:
		for failure: String in failures:
			push_error("TEST FAILURE: " + failure)
		_stage("failure")
		quit(1)


func _setup_owned_components() -> void:
	var canonical_project: String = str(bridge.project_path)
	_expect(not canonical_project.is_empty(), "bridge publishes a canonical project path")
	_expect(canonical_project == Protocol.canonicalize_project_path(ProjectSettings.globalize_path("res://")), "bridge project identity matches the fixture")
	print("[E2E][project] canonical=%s encoded=%s" % [canonical_project, canonical_project.uri_encode()])
	var configured_session := OS.get_environment("GODOT_MCP_SESSION_FILE").replace("\\", "/").simplify_path()
	_expect(bridge.session_path == configured_session, "managed session path is isolated to the fixture")

	var bridge_runtime: String = str(bridge.runtime_dir)
	bridge_sentinel_path = bridge_runtime.path_join("e2e-unrelated-sentinel.txt")
	_write_sentinel(bridge_sentinel_path)
	external_sentinel_path = OS.get_environment("GODOT_MCP_E2E_EXTERNAL_SENTINEL")
	_expect(not external_sentinel_path.is_empty(), "wrapper supplied an external sentinel path")

	# The command router is intentionally created exactly once. The packaged tool
	# test supplies an actual in-tree EditorPlugin, so its command execution uses
	# the same EditorPlugin-shaped context as the installed addon.
	test_editor_plugin = TestEditorPlugin.new()
	test_editor_plugin.name = "OpenCodeGodotE2ETestEditorPlugin"
	get_root().add_child(test_editor_plugin)
	command_router = CommandRouter.new()
	command_router.name = "OpenCodeGodotCommandRouter"
	get_root().add_child(command_router)
	websocket_server = WebSocketServer.new()
	websocket_server.name = "OpenCodeGodotWebSocketServer"
	websocket_server.command_router = command_router
	websocket_server.session_coordinator = bridge
	get_root().add_child(websocket_server)
	await process_frame
	command_router.configure_bridge_context(bridge.project_path, websocket_server.is_session_ready, null)
	command_router.editor_plugin = test_editor_plugin
	websocket_server.start_server(bridge)
	websocket_server.command_completed.connect(_on_command_completed)

	lifecycle = TestLifecycle.new()
	lifecycle.setup(bridge, websocket_server)
	lifecycle.diagnostic.connect(_on_lifecycle_diagnostic)
	lifecycle.state_changed.connect(_on_lifecycle_state_changed)
	var daemon_runtime: String = str(lifecycle.runtime_dir)
	daemon_sentinel_path = daemon_runtime.path_join("e2e-unrelated-sentinel.txt")
	_write_sentinel(daemon_sentinel_path)

	var router_count := _count_named_nodes(get_root(), "OpenCodeGodotCommandRouter")
	var websocket_count := _count_named_nodes(get_root(), "OpenCodeGodotWebSocketServer")
	_expect(router_count == 1, "exactly one embedded command router is owned by the fixture")
	_expect(websocket_count == 1, "exactly one embedded WebSocket client is owned by the fixture")
	_expect(command_router.get_available_methods().size() > 0, "the unified command catalog is registered")

	var result: Dictionary = lifecycle.start()
	_stage("daemon-launched")
	_expect(result.get("ok", false), "managed OpenCode daemon launch succeeds: %s" % result.get("error", ""))
	if not result.get("ok", false):
		return
	daemon_pid = lifecycle.daemon_pid
	descriptor_path = lifecycle.runtime_dir.path_join("launch-%s.json" % lifecycle.launch_nonce)
	listen_record_path = lifecycle.runtime_dir.path_join("listen-%s.json" % lifecycle.launch_nonce)
	mcp_ownership_path = lifecycle.runtime_dir.path_join("mcp-ownership-%s.json" % lifecycle.launch_nonce)
	_expect(daemon_pid > 0, "daemon PID is durable")
	if FileAccess.file_exists(descriptor_path):
		descriptor_observed = true
		_assert_launch_descriptor(descriptor_path)


func _run_lifecycle_flow() -> void:
	if lifecycle == null or lifecycle.state == "error":
		return
	var ready := await _wait_for_daemon_ready()
	if not ready:
		return
	_stage("daemon-ready")
	_expect(not FileAccess.file_exists(descriptor_path), "one-time launch descriptor is consumed before daemon readiness")
	_assert_listen_record()
	_stage("mcp-status-start")
	var response := await _get_mcp_status()
	if not response.get("ok", false):
		_expect(false, "authenticated /mcp status request succeeds: %s" % response.get("error", ""))
		return
	_assert_mcp_status(response)
	_stage("mcp-status-verified")
	_stage("sidecar-ownership-start")
	if not await _wait_for_sidecar_ownership():
		return
	_stage("sidecar-ownership-verified")
	_stage("bridge-ready-start")
	var bridge_ready := await _wait_for_bridge_ready()
	_expect(bridge_ready, "embedded bridge reaches READY after the configured MCP child starts")
	if bridge_ready:
		_assert_sidecar_ownership()
		_stage("bridge-ready")
		await _run_packaged_tool_flow()


func _on_command_completed(method: String, success: bool, response: String, source_port: int) -> void:
	completed_command = {"method": method, "success": success, "response": response, "source_port": source_port}
	completed_command_seen = true
	print("[E2E][command-completed] method=%s success=%s source_port=%d" % [method, success, source_port])


func _run_packaged_tool_flow() -> void:
	_stage("tool-session-create")
	var created := await _authenticated_json(HTTPClient.METHOD_POST, "/session", {
		"title": "Packaged Godot tool E2E",
		# Keep the mock provider strictly two-turn: deny every default tool, then
		# allow only the one MCP action (last-match permission precedence).
		"permission": [
			{"permission": "*", "pattern": "*", "action": "deny"},
			{"permission": "godot_get_project_info", "pattern": "*", "action": "allow"},
		],
	})
	_expect(created.get("ok", false), "authenticated v2 /session creation succeeds: %s" % created.get("error", ""))
	if not created.get("ok", false):
		return
	var parsed := JSON.new()
	_expect(parsed.parse(str(created.get("body", ""))) == OK and parsed.data is Dictionary, "v2 /session creation returns JSON")
	if not parsed.data is Dictionary:
		return
	var session_id := str((parsed.data as Dictionary).get("id", ""))
	_expect(not session_id.is_empty(), "v2 /session creates a session id")
	if session_id.is_empty():
		return

	_stage("tool-message-submit")
	var prompt := await _authenticated_json(HTTPClient.METHOD_POST, "/session/%s/message" % session_id.uri_encode(), {
		"model": {"providerID": "godot-e2e", "modelID": "tool-test"},
		"parts": [{"type": "text", "text": "Use the Godot project info tool exactly once, then summarize it."}],
	})
	_expect(prompt.get("ok", false), "authenticated v2 /session/:id/message submission succeeds: %s" % prompt.get("error", ""))
	if not prompt.get("ok", false):
		return

	_stage("tool-command-completed")
	var command_ready := await _wait_for_command_completed()
	_expect(command_ready, "packaged MCP forwards one Godot project-info command to the editor bridge")
	if command_ready:
		_expect(completed_command.get("method") == "get_project_info", "bridge command keeps raw get_project_info method")
		_expect(completed_command.get("success") == true, "bridge command completes successfully")
		_expect(int(completed_command.get("source_port", 0)) == _bridge_source_port(), "bridge command source port matches the sidecar discovery endpoint")
		var response_parser := JSON.new()
		var response_text := str(completed_command.get("response", ""))
		_expect(response_parser.parse(response_text) == OK and response_parser.data is Dictionary, "bridge command result is JSON")
		if response_parser.data is Dictionary:
			var result: Dictionary = response_parser.data
			_expect(str(result.get("project_name", "")) == "Godot MCP Bridge Test", "bridge project-info result carries the fixture project name")
			_expect(_same_path(str(result.get("project_path", "")), bridge.project_path), "bridge project-info result carries the fixture project path")

	_stage("tool-history")
	var history := await _wait_for_tool_history(session_id)
	_expect(history.get("ok", false), "v2 message history contains the completed Godot tool result: %s" % history.get("error", ""))
	if history.get("ok", false):
		print("OPENCODE_GODOT_TOOL_E2E_OK")


func _bridge_source_port() -> int:
	var endpoint := str(websocket_server.get_endpoint())
	return int(endpoint.get_slice(":", 2))


func _wait_for_command_completed() -> bool:
	var deadline := _stage_deadline(MCP_REQUEST_TIMEOUT_MS)
	while Time.get_ticks_msec() < deadline:
		lifecycle.update()
		if completed_command_seen:
			return true
		await process_frame
	return false


func _wait_for_tool_history(session_id: String) -> Dictionary:
	var deadline := _stage_deadline(MCP_REQUEST_TIMEOUT_MS)
	while Time.get_ticks_msec() < deadline:
		lifecycle.update()
		var history := await _authenticated_json(HTTPClient.METHOD_GET, "/session/%s/message" % session_id.uri_encode(), null, 10_000)
		if history.get("ok", false) and _history_has_completed_godot_tool(str(history.get("body", ""))):
			return {"ok": true}
		if not history.get("ok", false) and int(history.get("code", 0)) >= 400:
			return history
		await process_frame
	return {"ok": false, "error": "timed out waiting for completed godot_get_project_info tool history"}


func _history_has_completed_godot_tool(body: String) -> bool:
	var parser := JSON.new()
	if parser.parse(body) != OK or not parser.data is Array:
		return false
	for message_value: Variant in parser.data:
		if not message_value is Dictionary:
			continue
		var parts: Variant = (message_value as Dictionary).get("parts", [])
		if not parts is Array:
			continue
		for part_value: Variant in parts:
			if not part_value is Dictionary:
				continue
			var part: Dictionary = part_value
			if str(part.get("tool", "")) != "godot_get_project_info":
				continue
			var state: Variant = part.get("state", {})
			if state is Dictionary and str((state as Dictionary).get("status", "")) == "completed":
				var output := JSON.stringify((state as Dictionary).get("output", ""))
				return output.contains("Godot MCP Bridge Test") and output.contains("project_path")
	return false


func _authenticated_json(method: HTTPClient.Method, request_path: String, payload: Variant = null, timeout_ms: int = MCP_REQUEST_TIMEOUT_MS) -> Dictionary:
	var base := str(lifecycle.base_url)
	var port := int(base.get_slice(":", 2))
	if port < 1 or port > 65535:
		return {"ok": false, "error": "managed daemon URL is invalid"}
	var client := HTTPClient.new()
	var connect_error := client.connect_to_host("127.0.0.1", port)
	if connect_error != OK:
		return {"ok": false, "error": "HTTP connect failed: %s" % error_string(connect_error)}
	var authorization := Marshalls.utf8_to_base64("opencode:%s" % lifecycle.password)
	var headers := PackedStringArray([
		"Authorization: Basic %s" % authorization,
		"Accept: application/json",
		"Content-Type: application/json",
		"x-opencode-directory: %s" % bridge.project_path.uri_encode(),
	])
	var body_text := JSON.stringify(payload) if payload != null else ""
	var requested := false
	var response_code := 0
	var response_started := false
	var response_body := PackedByteArray()
	var deadline := _stage_deadline(timeout_ms)
	while Time.get_ticks_msec() < deadline:
		lifecycle.update()
		var poll_error := client.poll()
		if poll_error != OK:
			client.close()
			return {"ok": false, "error": "HTTP poll failed: %s" % error_string(poll_error)}
		match client.get_status():
			HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING:
				pass
			HTTPClient.STATUS_CONNECTED:
				# Chunked keep-alive responses transition BODY -> CONNECTED rather
				# than DISCONNECTED. Once a response was observed, that transition
				# is the complete body boundary for this one-request client.
				if requested and response_started:
					client.close()
					return {"ok": response_code >= 200 and response_code < 300, "code": response_code, "body": response_body.get_string_from_utf8(), "error": "HTTP %d" % response_code}
				if not requested:
					var request_error := client.request(method, request_path, headers, body_text)
					requested = true
					if request_error != OK:
						client.close()
						return {"ok": false, "error": "HTTP request failed: %s" % error_string(request_error)}
				if client.has_response():
					response_code = client.get_response_code()
					response_started = true
			HTTPClient.STATUS_BODY:
				if response_code == 0 and client.has_response():
					response_code = client.get_response_code()
					response_started = true
				var chunk := client.read_response_body_chunk()
				if not chunk.is_empty():
					response_body.append_array(chunk)
				var expected_length := client.get_response_body_length()
				if expected_length >= 0 and response_body.size() >= expected_length:
					client.close()
					return {"ok": response_code >= 200 and response_code < 300, "code": response_code, "body": response_body.get_string_from_utf8(), "error": "HTTP %d" % response_code}
			HTTPClient.STATUS_DISCONNECTED:
				client.close()
				return {"ok": response_code >= 200 and response_code < 300, "code": response_code, "body": response_body.get_string_from_utf8(), "error": "HTTP %d" % response_code}
			HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
				client.close()
				return {"ok": false, "error": "HTTP transport status %d" % client.get_status()}
		await process_frame
	client.close()
	return {"ok": false, "error": "timed out waiting for %s" % request_path}


func _on_lifecycle_diagnostic(category: String, message: String) -> void:
	print("[E2E][lifecycle][%s] %s" % [category, message])


func _on_lifecycle_state_changed(state: String, detail: String) -> void:
	print("[E2E][lifecycle][state] %s: %s" % [state, detail])


func _wait_for_daemon_ready() -> bool:
	var deadline := _stage_deadline(STARTUP_TIMEOUT_MS)
	while Time.get_ticks_msec() < deadline:
		if not project_probe_diagnostic_done and lifecycle.state == "probing" and int(lifecycle._listen_record.get("port", 0)) > 0:
			project_probe_diagnostic_done = true
			await _capture_project_probe_diagnostic()
		if not startup_diagnostics_captured and lifecycle.daemon_pid > 0:
			var preflight_identity: Dictionary = ProcessIdentity.inspect(lifecycle.daemon_pid, lifecycle.daemon_started_at_ms)
			if preflight_identity.get("stale", false):
				await _capture_startup_diagnostics()
		lifecycle.update()
		if lifecycle.state == "starting" and lifecycle.daemon_pid > 0:
			var identity: Dictionary = ProcessIdentity.inspect(lifecycle.daemon_pid, lifecycle.daemon_started_at_ms)
			if identity.get("stale", false):
				print("[E2E][lifecycle][identity] %s" % JSON.stringify(identity))
		if FileAccess.file_exists(descriptor_path):
			descriptor_observed = true
		if FileAccess.file_exists(listen_record_path):
			listen_record_observed = true
		if lifecycle.state == "ready":
			return true
		if lifecycle.state == "error":
			var child_output: String = str(lifecycle._output_buffer).replace("\u0000", " ")
			print("[E2E][lifecycle][child-output] %s" % child_output)
			print("[E2E][lifecycle][child-output-hex] %s" % child_output.to_utf8_buffer().hex_encode())
			_expect(false, "daemon lifecycle reaches ready: %s" % lifecycle.detail)
			return false
		await process_frame
	_expect(false, "daemon lifecycle reaches ready before the bounded timeout")
	return false


func _capture_startup_diagnostics() -> void:
	startup_diagnostics_captured = true
	for entry in [lifecycle._control_lease, lifecycle._stderr_pipe]:
		var pipe: FileAccess = entry as FileAccess
		if pipe == null or not pipe.is_open():
			continue
		var available := pipe.get_length()
		if available > 0:
			var bytes := pipe.get_buffer(mini(available, 64 * 1024))
			var text := bytes.get_string_from_utf8().replace("\u0000", " ")
			print("[E2E][lifecycle][raw-child-output] %s" % text)
			print("[E2E][lifecycle][raw-child-output-hex] %s" % bytes.hex_encode())
	# Closed Windows pipes can otherwise make the production bounded drain emit
	# one error per frame while it is classifying the dead child.
	lifecycle._control_lease = null
	lifecycle._stderr_pipe = null


func _capture_project_probe_diagnostic() -> void:
	var port := int(lifecycle._listen_record.get("port", 0))
	var client := HTTPClient.new()
	var connect_error := client.connect_to_host("127.0.0.1", port)
	if connect_error != OK:
		print("[E2E][probe-diagnostic] connect failed: %s" % error_string(connect_error))
		return
	var authorization := Marshalls.utf8_to_base64("opencode:%s" % lifecycle.password)
	var encoded_project: String = bridge.project_path.uri_encode()
	var headers := PackedStringArray([
		"Authorization: Basic %s" % authorization,
		"Accept: application/json",
		"x-opencode-directory: %s" % encoded_project,
	])
	var request_started := false
	var response_code := 0
	var body := PackedByteArray()
	var deadline := Time.get_ticks_msec() + 5_000
	while Time.get_ticks_msec() < deadline:
		var poll_error := client.poll()
		if poll_error != OK:
			print("[E2E][probe-diagnostic] poll failed: %s" % error_string(poll_error))
			return
		match client.get_status():
			HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING:
				pass
			HTTPClient.STATUS_CONNECTED:
				if not request_started:
					var request_error := client.request(HTTPClient.METHOD_GET, "/path", headers)
					request_started = true
					if request_error != OK:
						print("[E2E][probe-diagnostic] request failed: %s" % error_string(request_error))
						return
				if client.has_response():
					response_code = client.get_response_code()
			HTTPClient.STATUS_BODY:
				if response_code == 0 and client.has_response():
					response_code = client.get_response_code()
				var chunk := client.read_response_body_chunk()
				if not chunk.is_empty():
					body.append_array(chunk)
				var expected_body_length := client.get_response_body_length()
				if expected_body_length >= 0 and body.size() >= expected_body_length:
					client.close()
					print("[E2E][probe-diagnostic] code=%d header=%s body=%s" % [response_code, encoded_project, body.get_string_from_utf8()])
					return
			HTTPClient.STATUS_DISCONNECTED:
				client.close()
				print("[E2E][probe-diagnostic] code=%d header=%s body=%s" % [response_code, encoded_project, body.get_string_from_utf8()])
				return
			HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
				print("[E2E][probe-diagnostic] transport status=%d" % client.get_status())
				return
		await process_frame
	client.close()
	print("[E2E][probe-diagnostic] timed out code=%d header=%s body=%s" % [response_code, encoded_project, body.get_string_from_utf8()])


func _get_mcp_status() -> Dictionary:
	var base_url := str(lifecycle.base_url)
	var port := int(base_url.get_slice(":", 2))
	if port <= 0 or port > 65535:
		return {"ok": false, "error": "invalid managed daemon URL: %s" % base_url}
	var client := HTTPClient.new()
	var connect_error := client.connect_to_host("127.0.0.1", port)
	if connect_error != OK:
		return {"ok": false, "error": "HTTP connect failed: %s" % error_string(connect_error)}
	var authorization := Marshalls.utf8_to_base64("opencode:%s" % lifecycle.password)
	var headers := PackedStringArray([
		"Authorization: Basic %s" % authorization,
		"Accept: application/json",
		# OpenCode decodes this once in its instance-context middleware.  Keeping
		# the percent-encoded value is important for fixture paths containing a
		# literal '%' or spaces; a second directory query would decode it twice.
		"x-opencode-directory: %s" % bridge.project_path.uri_encode(),
	])
	var expected_header := "x-opencode-directory: %s" % bridge.project_path.uri_encode()
	var header_seen := false
	for header: String in headers:
		if header == expected_header:
			header_seen = true
	_expect(header_seen, "MCP request carries the encoded x-opencode-directory header")
	var request_path := "/mcp"
	var request_error := -1
	var request_started := false
	var response_code := 0
	var body := PackedByteArray()
	var deadline := _stage_deadline(MCP_REQUEST_TIMEOUT_MS)
	while Time.get_ticks_msec() < deadline:
		lifecycle.update()
		var poll_error := client.poll()
		if poll_error != OK:
			return {"ok": false, "error": "HTTP poll failed: %s" % error_string(poll_error)}
		match client.get_status():
			HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING:
				pass
			HTTPClient.STATUS_CONNECTED:
				if not request_started:
					request_error = client.request(HTTPClient.METHOD_GET, request_path, headers)
					request_started = true
					if request_error != OK:
						return {"ok": false, "error": "HTTP request failed: %s" % error_string(request_error)}
				if client.has_response():
					response_code = client.get_response_code()
					if client.get_response_body_length() == 0:
						client.close()
						return {"ok": response_code >= 200 and response_code < 300, "code": response_code, "body": ""}
			HTTPClient.STATUS_BODY:
				if response_code == 0 and client.has_response():
					response_code = client.get_response_code()
				var chunk := client.read_response_body_chunk()
				if not chunk.is_empty():
					body.append_array(chunk)
				var expected_body_length := client.get_response_body_length()
				if expected_body_length >= 0 and body.size() >= expected_body_length:
					client.close()
					return {"ok": response_code >= 200 and response_code < 300, "code": response_code, "body": body.get_string_from_utf8()}
			HTTPClient.STATUS_DISCONNECTED:
				client.close()
				return {"ok": response_code >= 200 and response_code < 300, "code": response_code, "body": body.get_string_from_utf8()}
			HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
				return {"ok": false, "error": "HTTP transport status %d" % client.get_status()}
		await process_frame
	client.close()
	return {"ok": false, "error": "timed out waiting for /mcp response"}


func _wait_for_bridge_ready() -> bool:
	var deadline := _stage_deadline(BRIDGE_TIMEOUT_MS)
	while Time.get_ticks_msec() < deadline:
		lifecycle.update()
		if lifecycle.state == "error":
			_expect(false, "embedded bridge remains reachable while waiting for READY: %s" % lifecycle.detail)
			return false
		if websocket_server.is_session_ready():
			return true
		await process_frame
	_expect(false, "embedded bridge reaches READY before the bounded timeout")
	return false


func _wait_for_sidecar_ownership() -> bool:
	var deadline := _stage_deadline(BRIDGE_TIMEOUT_MS)
	while Time.get_ticks_msec() < deadline:
		lifecycle.update()
		if lifecycle.state == "error":
			_expect(false, "MCP sidecar ownership becomes observable: %s" % lifecycle.detail)
			return false
		if FileAccess.file_exists(bridge.discovery_path) and FileAccess.file_exists(mcp_ownership_path):
			_assert_sidecar_ownership()
			return true
		await process_frame
	_expect(false, "MCP sidecar publishes ownership and discovery before the bounded timeout")
	return false


func _assert_launch_descriptor(path: String) -> void:
	var descriptor: Variant = _read_json(path)
	_expect(descriptor is Dictionary, "launch descriptor is valid JSON")
	if not descriptor is Dictionary:
		return
	var data: Dictionary = descriptor
	var keys := data.keys()
	keys.sort()
	var expected := ["canonical_project", "config", "editor", "hostname", "launch_nonce", "listen_record_path", "opencode", "password", "port", "project_hash", "schema", "schema_version"]
	expected.sort()
	_expect(keys == expected, "launch descriptor contains only the exact daemon contract fields")
	_expect(data.get("schema") == "opencode-godot-launch", "launch descriptor schema is pinned")
	_expect(data.get("hostname") == "127.0.0.1" and int(data.get("port", -1)) == 0, "daemon launch is loopback and asks for an ephemeral port")
	_expect(data.get("canonical_project") == bridge.project_path, "descriptor is bound to the fixture project")
	_expect(data.get("project_hash") == Protocol.project_hash(bridge.project_path), "descriptor project hash matches the canonical path")
	_expect(str(data.get("password", "")).length() >= 32, "descriptor carries high-entropy Basic-auth material")
	_expect(not str(data.get("config", "")).is_empty(), "descriptor carries the daemon config in memory")
	_expect(str(data.get("config", "")).contains("GODOT_MCP_SESSION_FILE"), "descriptor config passes the bridge session contract to the MCP child")
	_expect(not str(data.get("config", "")).contains(str(data.get("password", ""))), "daemon password is not copied into MCP config")


func _assert_listen_record() -> void:
	_expect(listen_record_observed or FileAccess.file_exists(listen_record_path), "daemon publishes a listen record")
	var record: Variant = _read_json(listen_record_path)
	_expect(record is Dictionary, "listen record is valid JSON")
	if not record is Dictionary:
		return
	var data: Dictionary = record
	_expect(data.get("schema") == "opencode-godot-listen", "listen record schema is pinned")
	_expect(data.get("hostname") == "127.0.0.1", "listen record is loopback-only")
	_expect(int(data.get("port", 0)) == int(lifecycle._listen_record.get("port", 0)), "listen record port is adopted by the lifecycle")
	_expect(int(data.get("pid", 0)) == lifecycle.daemon_pid, "listen record owner PID is the launched daemon")
	_expect(data.get("project_hash") == Protocol.project_hash(bridge.project_path), "listen record is project-bound")
	_expect(data.get("launch_nonce") == lifecycle.launch_nonce, "listen record is nonce-bound")
	_expect(not data.has("password") and not data.has("token") and not data.has("token_file"), "listen record contains no authentication secret")


func _assert_mcp_status(response: Dictionary) -> void:
	_expect(int(response.get("code", 0)) == 200, "MCP status endpoint returns HTTP 200")
	var parser := JSON.new()
	var text := str(response.get("body", ""))
	_expect(parser.parse(text) == OK and parser.data is Dictionary, "MCP status response is JSON")
	if parser.data is Dictionary:
		var statuses: Dictionary = parser.data
		_expect(statuses.has("godot"), "configured Godot MCP child is present in status")
		if statuses.has("godot") and statuses["godot"] is Dictionary:
			_expect((statuses["godot"] as Dictionary).get("status") == "connected", "configured Godot MCP child reaches connected status")


func _assert_sidecar_ownership() -> void:
	var discovery_path: String = str(bridge.discovery_path)
	if FileAccess.file_exists(discovery_path):
		discovery_observed = true
	var discovery: Variant = _read_json(discovery_path)
	_expect(discovery is Dictionary, "MCP sidecar publishes a valid discovery record")
	if discovery is Dictionary:
		var data: Dictionary = discovery
		_expect(data.get("schema") == "godot-ai-bridge-discovery", "sidecar discovery schema is pinned")
		_expect(data.get("project_path") == bridge.project_path, "sidecar discovery is bound to the fixture")
		_expect(int(data.get("parent_pid", 0)) == daemon_pid, "sidecar discovery records the managed daemon parent")
		_expect(not data.has("token") and not data.has("token_file"), "sidecar discovery contains no bridge secret")

	if FileAccess.file_exists(mcp_ownership_path):
		mcp_ownership_observed = true
	var ownership: Variant = _read_json(mcp_ownership_path)
	_expect(ownership is Dictionary, "MCP sidecar publishes a valid ownership record")
	if ownership is Dictionary:
		var data: Dictionary = ownership
		sidecar_pid = int((data.get("sidecar", {}) as Dictionary).get("pid", 0))
		_expect(data.get("schema") == "opencode-godot-mcp-ownership", "MCP ownership schema is pinned")
		_expect(data.get("canonical_project") == bridge.project_path, "MCP ownership is project-bound")
		_expect(data.get("launch_nonce") == lifecycle.launch_nonce, "MCP ownership is daemon-launch-bound")
		_expect((data.get("opencode_parent", {}) as Dictionary).get("pid") == daemon_pid, "MCP ownership records the daemon parent")
		_expect(_same_path(str(data.get("bridge_discovery_path", "")), str(bridge.discovery_path)), "MCP ownership points to the sidecar discovery record")


func _stop_owned_components() -> void:
	# Closing the daemon's retained stdio lease first cascades EOF to its MCP
	# child.  Then stop the editor-owned WebSocket and bridge session.
	if lifecycle != null and lifecycle.state != "stopped":
		lifecycle.stop()
	if websocket_server != null:
		websocket_server.stop_server()
	if command_router != null:
		command_router.queue_free()
	if websocket_server != null:
		websocket_server.queue_free()
	await _wait_for_owned_process_cleanup()
	if bridge != null:
		bridge.stop_session()

	_expect(lifecycle == null or lifecycle.state == "stopped", "normal stop reaches the stopped lifecycle state")
	_expect(not FileAccess.file_exists(descriptor_path), "normal stop removes the owned launch descriptor")
	_expect(not FileAccess.file_exists(listen_record_path), "normal stop removes the owned listen record")
	_expect(not FileAccess.file_exists(mcp_ownership_path), "normal stop removes the managed MCP ownership record")
	_expect(bridge == null or not FileAccess.file_exists(bridge.discovery_path), "normal stop removes sidecar discovery")
	_expect(bridge == null or not FileAccess.file_exists(bridge.session_path), "normal stop removes the bridge session contract")
	_expect(bridge == null or not FileAccess.file_exists(bridge.token_path), "normal stop removes the bridge token file")
	_expect(FileAccess.file_exists(bridge_sentinel_path), "bridge runtime preserves unrelated external state")
	_expect(FileAccess.file_exists(daemon_sentinel_path), "daemon runtime preserves unrelated external state")
	if not external_sentinel_path.is_empty():
		_expect(FileAccess.file_exists(external_sentinel_path), "normal stop preserves the wrapper-owned external sentinel")
		if FileAccess.file_exists(external_sentinel_path):
			var file := FileAccess.open(external_sentinel_path, FileAccess.READ)
			_expect(file != null and file.get_as_text() == SENTINEL_TEXT, "external sentinel contents are unchanged")
			if file != null:
				file.close()


func _wait_for_owned_process_cleanup() -> void:
	var deadline := _stage_deadline(STOP_TIMEOUT_MS)
	while Time.get_ticks_msec() < deadline:
		var daemon_alive: bool = lifecycle != null and lifecycle.daemon_pid > 0 and not ProcessIdentity.inspect(lifecycle.daemon_pid, lifecycle.daemon_started_at_ms).get("stale", false)
		if not daemon_alive and not FileAccess.file_exists(mcp_ownership_path) and not FileAccess.file_exists(bridge.discovery_path):
			return
		await process_frame


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parser := JSON.new()
	var error := parser.parse(file.get_as_text())
	file.close()
	return parser.data if error == OK else null


func _write_sentinel(path: String) -> void:
	if path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(SENTINEL_TEXT)
		file.close()


func _count_named_nodes(node: Node, target: String) -> int:
	var count := 1 if node.name == target else 0
	for child: Node in node.get_children():
		count += _count_named_nodes(child, target)
	return count


func _same_path(left: String, right: String) -> bool:
	var normalized_left := left.replace("\\", "/").simplify_path()
	var normalized_right := right.replace("\\", "/").simplify_path()
	if OS.get_name() == "Windows":
		normalized_left = normalized_left.to_lower()
		normalized_right = normalized_right.to_lower()
	return not normalized_left.is_empty() and normalized_left == normalized_right


func _expect(value: bool, message: String) -> void:
	if not value and not message.is_empty():
		failures.append(message)


func _stage(name: String) -> void:
	var marker := "[E2E][stage] %s t=%d" % [name, Time.get_ticks_msec()]
	print(marker)
	if stage_log_path.is_empty():
		return
	var mode := FileAccess.READ_WRITE if FileAccess.file_exists(stage_log_path) else FileAccess.WRITE_READ
	var file := FileAccess.open(stage_log_path, mode)
	if file == null:
		return
	file.seek_end()
	file.store_line(marker)
	file.flush()
	file.close()


func _stage_deadline(stage_timeout_ms: int) -> int:
	var deadline := Time.get_ticks_msec() + stage_timeout_ms
	if run_deadline_ms > 0:
		deadline = mini(deadline, run_deadline_ms)
	return deadline
