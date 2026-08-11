@tool
extends Node

## Discovery-driven WebSocket client for one authenticated agent session.
## The historical filename is kept so existing addon references do not break.

signal client_connected()
signal client_disconnected()
signal message_received(text: String)
signal command_executed(method: String, success: bool)
signal command_completed(method: String, success: bool, response: String, source_port: int)
signal state_changed(state: String, detail: String)

const Protocol := preload("res://addons/opencode_godot/engine_bridge/bridge_protocol_v1.gd")

const BUFFER_SIZE := 16 * 1024 * 1024
const INITIAL_RETRY_SECONDS := 0.25
const MAX_RETRY_SECONDS := 5.0
const STABLE_READY_RESET_SECONDS := 30.0
const PING_INTERVAL_SECONDS := 5.0
const INACTIVITY_TIMEOUT_SECONDS := 30.0

enum BridgeState {
	STOPPED,
	DISCOVERING,
	CONNECTING,
	HANDSHAKING,
	READY,
	CLOSING,
	BACKOFF,
}

var command_router: Node
var session_coordinator: RefCounted

var _peer: WebSocketPeer
var _state := BridgeState.STOPPED
var _state_detail := "Stopped"
var _running := false
var _generation := 0
var _endpoint := ""
var _endpoint_port := 0
var _handshake_stage := ""
var _handshake_request_id := ""
var _authenticate_request_id := ""
var _client_nonce := ""
var _server_nonce := ""
var _handshake_elapsed := 0.0
var _ready_elapsed := 0.0
var _idle_elapsed := 0.0
var _ping_elapsed := 0.0
var _retry_delay := INITIAL_RETRY_SECONDS
var _retry_remaining := 0.0
var _was_ready := false
var _last_close_code := 0


func start_server(coordinator: RefCounted = null) -> void:
	if coordinator != null:
		session_coordinator = coordinator
	if session_coordinator == null or not session_coordinator.has_method("read_valid_discovery"):
		push_error("[MCP] Cannot start bridge client without a session coordinator")
		_transition(BridgeState.STOPPED, "Session coordinator unavailable")
		return
	_running = true
	_retry_delay = INITIAL_RETRY_SECONDS
	_retry_remaining = 0.0
	_transition(BridgeState.DISCOVERING, "Waiting for agent discovery")
	print("[MCP] Waiting for a project-scoped authenticated bridge endpoint")


func stop_server() -> void:
	if not _running and _state == BridgeState.STOPPED:
		return
	_running = false
	_generation += 1
	var notify_disconnect := _state == BridgeState.READY
	if _peer != null:
		_peer.close(1000, "Plugin shutting down")
		_peer.poll()
	_peer = null
	_clear_connection_state()
	_transition(BridgeState.STOPPED, "Plugin stopped")
	if notify_disconnect:
		client_disconnected.emit()
	print("[MCP] WebSocket client stopped")


func get_client_count() -> int:
	return 1 if _state == BridgeState.READY else 0


func get_connected_ports() -> Array[int]:
	var ports: Array[int] = []
	if _state == BridgeState.READY and _endpoint_port > 0:
		ports.append(_endpoint_port)
	return ports


func get_port_connect_time(port: int) -> float:
	return _ready_elapsed if port == _endpoint_port and _state == BridgeState.READY else -1.0


func get_port_idle_time(port: int) -> float:
	return _idle_elapsed if port == _endpoint_port and _state == BridgeState.READY else -1.0


func is_port_stale(port: int) -> bool:
	return port == _endpoint_port and _state == BridgeState.BACKOFF and _was_ready


func get_state_name() -> String:
	return String(BridgeState.keys()[_state])


func get_state_detail() -> String:
	return _state_detail


func get_endpoint() -> String:
	return _endpoint


func get_retry_seconds() -> float:
	return maxf(_retry_remaining, 0.0)


func get_session_generation() -> int:
	return _generation


func is_session_ready(generation: int = -1) -> bool:
	if generation >= 0 and generation != _generation:
		return false
	return _running and _state == BridgeState.READY and _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN


func send_message(text: String) -> void:
	if not is_session_ready():
		return
	var error := _peer.send_text(text)
	if error != OK:
		push_error("[MCP] Failed to send bridge message: %s" % error_string(error))


func _process(delta: float) -> void:
	if not _running:
		return
	if _peer == null:
		_retry_remaining -= delta
		if _retry_remaining <= 0.0:
			_try_connect_from_discovery()
		return

	_peer.poll()
	var socket_state := _peer.get_ready_state()
	match socket_state:
		WebSocketPeer.STATE_CONNECTING:
			_handshake_elapsed += delta
			if _handshake_elapsed >= Protocol.HANDSHAKE_TIMEOUT_SECONDS:
				_fail_connection("WebSocket connection timed out", Protocol.CLOSE_PROTOCOL_ERROR)
		WebSocketPeer.STATE_OPEN:
			if _state == BridgeState.CONNECTING:
				_begin_handshake()
			if _state != BridgeState.CLOSING:
				_drain_packets()
			if _state == BridgeState.HANDSHAKING:
				_handshake_elapsed += delta
				if _handshake_elapsed >= Protocol.HANDSHAKE_TIMEOUT_SECONDS:
					_handle_handshake_timeout()
			elif _state == BridgeState.READY:
				_tick_ready(delta)
			elif _state == BridgeState.CLOSING:
				_handshake_elapsed += delta
				if _handshake_elapsed >= Protocol.HANDSHAKE_TIMEOUT_SECONDS:
					_schedule_reconnect("Socket close timed out")
		WebSocketPeer.STATE_CLOSING:
			_handshake_elapsed += delta
			if _handshake_elapsed >= Protocol.HANDSHAKE_TIMEOUT_SECONDS:
				_schedule_reconnect("Socket close timed out")
		WebSocketPeer.STATE_CLOSED:
			_schedule_reconnect("Agent connection closed")


func _handle_handshake_timeout() -> void:
	_send_error(null, Protocol.ERROR_HANDSHAKE_TIMEOUT, "bridge_handshake_timeout")
	_fail_connection("Authenticated handshake timed out", Protocol.CLOSE_POLICY_VIOLATION)


func _try_connect_from_discovery() -> void:
	_transition(BridgeState.DISCOVERING, "Reading project discovery")
	var result: Dictionary = session_coordinator.read_valid_discovery()
	if not result.get("ok", false):
		_schedule_reconnect(result.get("error", "Waiting for agent discovery"))
		return
	var record: Dictionary = result["record"]
	_endpoint = record["endpoint"]
	_endpoint_port = int(_endpoint.get_slice(":", 2))
	_peer = WebSocketPeer.new()
	_peer.outbound_buffer_size = BUFFER_SIZE
	_peer.inbound_buffer_size = BUFFER_SIZE
	var connect_error := _peer.connect_to_url(_endpoint)
	if connect_error != OK:
		_peer = null
		_schedule_reconnect("Could not connect to discovered endpoint: %s" % error_string(connect_error))
		return
	_generation += 1
	_handshake_elapsed = 0.0
	_transition(BridgeState.CONNECTING, "Connecting to %s" % _endpoint)


func _begin_handshake() -> void:
	_client_nonce = _fresh_client_nonce()
	_server_nonce = ""
	_handshake_stage = "server_proof"
	_handshake_request_id = "bridge-handshake-%s" % Protocol.random_base64url(12)
	_authenticate_request_id = ""
	_handshake_elapsed = 0.0
	_transition(BridgeState.HANDSHAKING, "Authenticating project bridge")
	if not _send_json({
		"jsonrpc": "2.0",
		"id": _handshake_request_id,
		"method": "bridge.handshake",
		"params": {
			"protocol_version": Protocol.PROTOCOL_VERSION,
			"project_path": session_coordinator.project_path,
			"owner_nonce": session_coordinator.owner_nonce,
			"client_nonce": _client_nonce,
		},
	}):
		_fail_connection("Could not send bridge handshake", Protocol.CLOSE_PROTOCOL_ERROR)


func _fresh_client_nonce() -> String:
	return Protocol.random_base64url(16)


func _drain_packets() -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		if not _peer.was_string_packet():
			_fail_connection("Binary bridge packets are not supported", Protocol.CLOSE_PROTOCOL_ERROR)
			return
		_idle_elapsed = 0.0
		_handle_message(packet.get_string_from_utf8())


func _handle_message(text: String) -> void:
	message_received.emit(text)
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		_send_error(null, -32700, "Parse error")
		if _state == BridgeState.HANDSHAKING:
			_fail_connection("Malformed JSON during bridge authentication", Protocol.CLOSE_PROTOCOL_ERROR)
		return
	var message: Dictionary = json.data
	if message.get("jsonrpc") != "2.0":
		_send_error(message.get("id"), -32600, "jsonrpc must be '2.0'")
		if _state == BridgeState.HANDSHAKING:
			_fail_connection("Malformed JSON-RPC handshake response", Protocol.CLOSE_PROTOCOL_ERROR)
		return
	if _state == BridgeState.HANDSHAKING:
		_handle_handshake_message(message)
		return
	if _state != BridgeState.READY:
		if message.has("method"):
			_send_error(message.get("id"), Protocol.ERROR_NOT_READY, "bridge_not_ready")
		return
	_handle_ready_message(message)


func _handle_handshake_message(message: Dictionary) -> void:
	if message.has("method"):
		_send_error(message.get("id"), Protocol.ERROR_NOT_READY, "bridge_not_ready")
		return
	var response_id: Variant = message.get("id")
	if not response_id is String:
		_fail_connection("Handshake response id must be a string", Protocol.CLOSE_PROTOCOL_ERROR)
		return
	if message.has("error"):
		var error_data: Variant = message.get("error")
		var error_code := 0
		if error_data is Dictionary:
			var raw_error_code: Variant = (error_data as Dictionary).get("code")
			if raw_error_code is int or (raw_error_code is float and floor(raw_error_code as float) == raw_error_code as float):
				error_code = int(raw_error_code)
		_fail_connection(
			"Agent rejected bridge authentication",
			Protocol.CLOSE_PROTOCOL_ERROR if error_code == Protocol.ERROR_UNSUPPORTED_PROTOCOL else Protocol.CLOSE_POLICY_VIOLATION
		)
		return
	var result: Variant = message.get("result")
	if not result is Dictionary:
		_fail_connection("Malformed handshake response", Protocol.CLOSE_PROTOCOL_ERROR)
		return
	var data: Dictionary = result
	if _handshake_stage == "server_proof" and response_id == _handshake_request_id:
		if not data.get("server_nonce") is String or not data.get("server_proof") is String:
			_fail_connection("Handshake proof fields must be strings", Protocol.CLOSE_PROTOCOL_ERROR)
			return
		_server_nonce = data["server_nonce"]
		var supplied_proof: String = data["server_proof"]
		if not Protocol.validate_nonce(_server_nonce, 16):
			_fail_connection("Agent server nonce is invalid", Protocol.CLOSE_PROTOCOL_ERROR)
			return
		if not Protocol.validate_proof(supplied_proof):
			_fail_connection("Agent proof encoding is invalid", Protocol.CLOSE_PROTOCOL_ERROR)
			return
		var expected := Protocol.hmac_proof(
			session_coordinator.token_bytes,
			"server",
			session_coordinator.project_path,
			session_coordinator.owner_nonce,
			_client_nonce,
			_server_nonce
		)
		if expected.is_empty() or not Protocol.constant_time_equal(expected, supplied_proof):
			_fail_connection("Agent proof validation failed", Protocol.CLOSE_POLICY_VIOLATION)
			return
		var client_proof := Protocol.hmac_proof(
			session_coordinator.token_bytes,
			"client",
			session_coordinator.project_path,
			session_coordinator.owner_nonce,
			_client_nonce,
			_server_nonce
		)
		_authenticate_request_id = "bridge-authenticate-%s" % Protocol.random_base64url(12)
		_handshake_stage = "client_proof"
		if not _send_json({
			"jsonrpc": "2.0",
			"id": _authenticate_request_id,
			"method": "bridge.authenticate",
			"params": {"client_proof": client_proof},
		}):
			_fail_connection("Could not send client authentication proof", Protocol.CLOSE_PROTOCOL_ERROR)
		return
	if _handshake_stage == "client_proof" and response_id == _authenticate_request_id:
		if data.get("authenticated") != true:
			_fail_connection("Agent did not confirm authentication", Protocol.CLOSE_POLICY_VIOLATION)
			return
		_handshake_stage = ""
		_handshake_elapsed = 0.0
		_ready_elapsed = 0.0
		_idle_elapsed = 0.0
		_ping_elapsed = 0.0
		_was_ready = true
		_transition(BridgeState.READY, "Authenticated to %s" % _endpoint)
		client_connected.emit()
		print("[MCP] Authenticated bridge READY at %s" % _endpoint)
		return
	_fail_connection("Unexpected handshake response", Protocol.CLOSE_PROTOCOL_ERROR)


func _handle_ready_message(message: Dictionary) -> void:
	var raw_method: Variant = message.get("method")
	if raw_method == null:
		# Responses are not expected here; the editor is the command responder.
		return
	if not raw_method is String or (raw_method as String).is_empty():
		_send_error(message.get("id"), -32600, "Missing or non-string method")
		return
	var method: String = raw_method
	if method == "ping":
		if message.get("id") == null:
			_send_json({"jsonrpc": "2.0", "method": "pong", "params": {}})
		else:
			_send_response(message.get("id"), {"pong": true}, null)
		return
	if method == "pong":
		return
	if method.begins_with("bridge."):
		_send_error(message.get("id"), Protocol.ERROR_NOT_READY, "bridge_handshake_already_complete")
		return
	var raw_params: Variant = message.get("params", {})
	if raw_params == null:
		raw_params = {}
	if not raw_params is Dictionary:
		_send_error(message.get("id"), -32602, "params must be an object")
		return
	var generation := _generation
	if message.get("id") == null:
		_execute_notification.call_deferred(generation, method, raw_params)
	else:
		_execute_command.call_deferred(generation, message.get("id"), method, raw_params)


func _execute_notification(generation: int, method: String, params: Dictionary) -> void:
	if not is_session_ready(generation) or not is_instance_valid(command_router):
		return
	var command_result: Dictionary = await command_router.execute(method, params, generation)
	if not is_session_ready(generation):
		return
	command_executed.emit(method, not command_result.has("error"))


func _execute_command(generation: int, id: Variant, method: String, params: Dictionary) -> void:
	if not is_session_ready(generation):
		return
	if not is_instance_valid(command_router):
		_send_error(id, -32603, "Editor command router is unavailable", generation)
		return
	var command_result: Dictionary = await command_router.execute(method, params, generation)
	# Never deliver an old completion to a replacement peer/session.
	if not is_session_ready(generation):
		return
	var ok := not command_result.has("error")
	var response_text := ""
	if ok:
		var result_data: Variant = command_result.get("result", {})
		_send_response(id, result_data, null, generation)
		response_text = JSON.stringify(result_data)
	else:
		var error_data: Variant = command_result["error"]
		_send_response(id, null, error_data, generation)
		response_text = JSON.stringify(error_data)
	command_executed.emit(method, ok)
	command_completed.emit(method, ok, response_text, _endpoint_port)


func _tick_ready(delta: float) -> void:
	_ready_elapsed += delta
	_idle_elapsed += delta
	_ping_elapsed += delta
	if _ready_elapsed >= STABLE_READY_RESET_SECONDS:
		_retry_delay = INITIAL_RETRY_SECONDS
	if _idle_elapsed >= INACTIVITY_TIMEOUT_SECONDS:
		_fail_connection("Agent heartbeat timed out", 4000)
		return
	if _ping_elapsed >= PING_INTERVAL_SECONDS:
		_ping_elapsed = 0.0
		_send_json({"jsonrpc": "2.0", "method": "ping", "params": {}})


func _send_error(id: Variant, code: int, message: String, generation: int = -1) -> void:
	_send_response(id, null, {"code": code, "message": message}, generation)


func _send_response(id: Variant, result: Variant, error: Variant, generation: int = -1) -> void:
	if generation >= 0 and generation != _generation:
		return
	var response := {"jsonrpc": "2.0", "id": id}
	if error != null:
		response["error"] = error
	else:
		response["result"] = result if result != null else {}
	_send_json(response)


func _send_json(message: Dictionary) -> bool:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var error := _peer.send_text(JSON.stringify(message))
	if error != OK:
		push_error("[MCP] Failed to send bridge packet: %s" % error_string(error))
		return false
	return true


func _fail_connection(reason: String, close_code: int) -> void:
	_last_close_code = close_code
	var notify_disconnect := _state == BridgeState.READY
	_generation += 1
	_clear_connection_state()
	if notify_disconnect:
		client_disconnected.emit()
	if _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_peer.close(close_code, reason.left(120))
		_handshake_elapsed = 0.0
		_transition(BridgeState.CLOSING, reason)
		return
	_schedule_reconnect(reason)


func _schedule_reconnect(reason: String, increase_backoff: bool = true) -> void:
	var notify_disconnect := _state == BridgeState.READY
	_generation += 1
	if _peer != null:
		_peer = null
	_clear_connection_state()
	if not _running:
		_transition(BridgeState.STOPPED, reason)
		return
	var jitter := randf_range(0.8, 1.2)
	_retry_remaining = _retry_delay * jitter
	if increase_backoff:
		_retry_delay = minf(_retry_delay * 2.0, MAX_RETRY_SECONDS)
	_transition(BridgeState.BACKOFF, "%s; retrying in %.2fs" % [reason, _retry_remaining])
	if notify_disconnect:
		client_disconnected.emit()


func _clear_connection_state() -> void:
	_handshake_stage = ""
	_handshake_request_id = ""
	_authenticate_request_id = ""
	_client_nonce = ""
	_server_nonce = ""
	_handshake_elapsed = 0.0
	_ready_elapsed = 0.0
	_idle_elapsed = 0.0
	_ping_elapsed = 0.0


func _transition(next_state: int, detail: String) -> void:
	_state = next_state
	_state_detail = detail
	if OS.has_environment("GODOT_MCP_TRACE_BRIDGE") and OS.get_environment("GODOT_MCP_TRACE_BRIDGE") == "1":
		print("[MCP TRACE] %s: %s" % [get_state_name(), detail])
	state_changed.emit(get_state_name(), detail)
