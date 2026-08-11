@tool
extends Node

signal daemon_state_changed(ready: bool, detail: String)
signal sessions_changed(sessions: Array)
signal session_changed(session_id: String)
signal history_reloaded(session_id: String, events: Array)
signal assistant_output(session_id: String, text: String, replace: bool)
signal tool_activity(session_id: String, activity: Dictionary)
signal permission_pending(session_id: String, request: Dictionary)
signal question_pending(session_id: String, request: Dictionary)
signal request_state_changed(session_id: String, active: bool, detail: String)
signal request_completed(session_id: String, state: String)
signal interaction_response_completed(operation: String, session_id: String, request_id: String)
signal interaction_response_failed(operation: String, session_id: String, request_id: String, detail: String)
signal api_error(category: String, detail: String)
signal diagnostic(category: String, detail: String)

const HTTPSSEStream := preload("res://addons/opencode_godot/client/http_sse_stream.gd")
const EXPECTED_OPENCODE_VERSION := "1.17.18"
const MAX_REST_BODY_BYTES := 8 * 1024 * 1024
const MAX_RECENT_EVENT_IDS := 256

var project_path := ""
var active_session_id := ""
var active_request := false
var _active_request_session_id := ""
var _active_request_generation := -1
var _active_request_admission_id := ""
var _interrupt_pending := false

var _host := ""
var _port := 0
var _password := ""
var _daemon_generation := 0
var _daemon_ready := false

var _rest_client: HTTPClient
var _rest_queue: Array[Dictionary] = []
var _rest_current: Dictionary = {}
var _rest_phase := "idle"
var _rest_code := 0
var _rest_body := PackedByteArray()

var _durable_stream: Node
var _live_stream: Node
var _last_sequence_by_session: Dictionary = {}
var _recent_event_ids: Dictionary = {}
var _recent_event_order: Array[String] = []
var _history_recovery_pending: Dictionary = {}
var _live_recovery_pending := false
var _project_probe_verified := false
var _sessions_snapshot_loaded := false


func _ready() -> void:
	_durable_stream = HTTPSSEStream.new()
	_durable_stream.name = "DurableSessionEvents"
	add_child(_durable_stream)
	_durable_stream.frame_received.connect(_on_durable_frame)
	_durable_stream.stream_failed.connect(_on_durable_failed)
	_durable_stream.stream_state_changed.connect(_on_stream_state.bind("durable"))

	_live_stream = HTTPSSEStream.new()
	_live_stream.name = "ProjectLiveEvents"
	add_child(_live_stream)
	_live_stream.frame_received.connect(_on_live_frame)
	_live_stream.stream_failed.connect(_on_live_failed)
	_live_stream.stream_state_changed.connect(_on_stream_state.bind("live"))


func setup(canonical_project_path: String) -> void:
	project_path = canonical_project_path.replace("\\", "/").simplify_path()


func configure_daemon(base_url: String, password: String, generation: int) -> bool:
	shutdown_transport()
	var endpoint := _parse_loopback_url(base_url)
	if not endpoint.get("ok", false):
		api_error.emit("security", endpoint.get("error", "Invalid daemon endpoint"))
		return false
	if password.to_utf8_buffer().size() < 32:
		api_error.emit("authentication", "Managed daemon credential is missing or too short")
		return false
	if project_path.is_empty() or not project_path.is_absolute_path():
		api_error.emit("project", "Canonical project directory is unavailable")
		return false
	_host = endpoint["host"]
	_port = endpoint["port"]
	_password = password
	_daemon_generation = generation
	_daemon_ready = true
	_project_probe_verified = false
	_sessions_snapshot_loaded = false
	daemon_state_changed.emit(true, "Checking OpenCode %s compatibility" % EXPECTED_OPENCODE_VERSION)
	_enqueue("compatibility", HTTPClient.METHOD_GET, "/global/godot-health")
	# `/project/current` reports worktree `/` for a valid non-Git project. The
	# authenticated `/path` endpoint exposes the exact routed instance directory.
	_enqueue("project_probe", HTTPClient.METHOD_GET, "/path")
	return true


func shutdown() -> void:
	shutdown_transport()
	project_path = ""


func shutdown_transport() -> void:
	var interrupted_session := _active_request_session_id
	var was_active := active_request
	_daemon_ready = false
	_daemon_generation = -1
	active_request = false
	active_session_id = ""
	_active_request_session_id = ""
	_active_request_generation = -1
	_active_request_admission_id = ""
	_interrupt_pending = false
	_rest_queue.clear()
	_rest_current.clear()
	_rest_phase = "idle"
	if _rest_client != null:
		_rest_client.close()
	_rest_client = null
	if is_instance_valid(_durable_stream):
		_durable_stream.stop()
	if is_instance_valid(_live_stream):
		_live_stream.stop()
	_live_recovery_pending = false
	_project_probe_verified = false
	_sessions_snapshot_loaded = false
	_last_sequence_by_session.clear()
	_recent_event_ids.clear()
	_recent_event_order.clear()
	_history_recovery_pending.clear()
	_password = ""
	_host = ""
	_port = 0
	daemon_state_changed.emit(false, "OpenCode daemon unavailable")
	request_state_changed.emit(interrupted_session, false, "Disconnected")
	if was_active:
		request_completed.emit(interrupted_session, "interrupted")


func list_sessions() -> void:
	_enqueue("list_sessions", HTTPClient.METHOD_GET, "/api/session?directory=" + project_path.uri_encode())


func create_session() -> void:
	_enqueue("create_session", HTTPClient.METHOD_POST, "/api/session", {"location": {"directory": project_path}})


func select_session(session_id: String) -> void:
	if session_id.is_empty():
		return
	active_session_id = session_id
	session_changed.emit(session_id)
	_recover_session(session_id, "Session selected")


func send_prompt(text: String) -> void:
	var prompt := text.strip_edges()
	if not _daemon_ready:
		api_error.emit("lifecycle", "OpenCode daemon is not ready")
		return
	if active_session_id.is_empty():
		api_error.emit("session", "Create or select a session before sending a prompt")
		return
	if prompt.is_empty() or active_request:
		return
	active_request = true
	_active_request_session_id = active_session_id
	_active_request_generation = _daemon_generation
	_active_request_admission_id = ""
	_interrupt_pending = false
	request_state_changed.emit(active_session_id, true, "Submitting prompt")
	_enqueue(
		"prompt",
		HTTPClient.METHOD_POST,
		"/api/session/%s/prompt" % active_session_id.uri_encode(),
		{"prompt": {"text": prompt}},
		{"session_id": active_session_id, "request_generation": _daemon_generation}
	)


func cancel_active() -> void:
	if not _daemon_ready or _active_request_session_id.is_empty() or not active_request or _interrupt_pending:
		return
	_interrupt_pending = true
	_enqueue(
		"interrupt",
		HTTPClient.METHOD_POST,
		"/api/session/%s/interrupt" % _active_request_session_id.uri_encode(),
		{},
		{"session_id": _active_request_session_id, "request_generation": _active_request_generation, "admission_id": _active_request_admission_id}
	)
	request_state_changed.emit(_active_request_session_id, true, "Cancelling active request")


func reply_permission(request_id: String, reply: String, message: String = "", session_id: String = "") -> void:
	if not reply in ["once", "always", "reject"]:
		api_error.emit("permission", "Permission reply must be once, always, or reject")
		return
	var target_session := session_id if not session_id.is_empty() else active_session_id
	if target_session.is_empty() or request_id.is_empty():
		api_error.emit("permission", "Permission reply is missing its session or request identity")
		return
	var body := {"reply": reply}
	if not message.is_empty():
		body["message"] = message
	_enqueue(
		"permission_reply",
		HTTPClient.METHOD_POST,
		"/api/session/%s/permission/%s/reply" % [target_session.uri_encode(), request_id.uri_encode()],
		body,
		{"session_id": target_session, "request_id": request_id}
	)


func answer_question(request_id: String, answers: Array, session_id: String = "") -> void:
	var target_session := session_id if not session_id.is_empty() else active_session_id
	if target_session.is_empty() or request_id.is_empty():
		api_error.emit("question", "Question reply is missing its session or request identity")
		return
	var ordered: Array = []
	for answer in answers:
		if not answer is Array:
			api_error.emit("question", "Question answers must be ordered arrays")
			return
		ordered.append(answer)
	_enqueue(
		"question_reply",
		HTTPClient.METHOD_POST,
		"/api/session/%s/question/%s/reply" % [target_session.uri_encode(), request_id.uri_encode()],
		{"answers": ordered},
		{"session_id": target_session, "request_id": request_id}
	)


func reject_question(request_id: String, session_id: String = "") -> void:
	var target_session := session_id if not session_id.is_empty() else active_session_id
	if target_session.is_empty() or request_id.is_empty():
		api_error.emit("question", "Question rejection is missing its session or request identity")
		return
	_enqueue(
		"question_reject",
		HTTPClient.METHOD_POST,
		"/api/session/%s/question/%s/reject" % [target_session.uri_encode(), request_id.uri_encode()],
		{},
		{"session_id": target_session, "request_id": request_id}
	)


func _process(_delta: float) -> void:
	_process_rest()


func _enqueue(operation: String, method: int, path: String, payload: Variant = null, context: Dictionary = {}) -> void:
	if not _daemon_ready:
		api_error.emit("lifecycle", "Cannot call OpenCode while the daemon is unavailable")
		return
	_rest_queue.append({
		"operation": operation,
		"method": method,
		"path": path,
		"payload": payload,
		"context": context,
		"generation": _daemon_generation,
	})


func _process_rest() -> void:
	if _rest_current.is_empty():
		if _rest_queue.is_empty() or not _daemon_ready:
			return
		_start_rest(_rest_queue.pop_front())
		return
	if int(_rest_current.get("generation", -1)) != _daemon_generation:
		_finish_rest(false, "Daemon was replaced")
		return
	var poll_error := _rest_client.poll()
	if poll_error != OK:
		_finish_rest(false, "HTTP transport poll failed: %s" % error_string(poll_error))
		return
	var status := _rest_client.get_status()
	match status:
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_REQUESTING:
			return
		HTTPClient.STATUS_CONNECTED:
			if _rest_phase == "connecting":
				_send_rest_request()
				return
			if _rest_phase == "body":
				_finish_rest_response()
				return
			if _rest_client.has_response():
				_capture_rest_response()
				if _rest_client.get_response_body_length() == 0:
					_finish_rest_response()
		HTTPClient.STATUS_BODY:
			_capture_rest_response()
			_rest_phase = "body"
			var chunk := _rest_client.read_response_body_chunk()
			if not chunk.is_empty():
				_rest_body.append_array(chunk)
				if _rest_body.size() > MAX_REST_BODY_BYTES:
					_finish_rest(false, "OpenCode response exceeds the bounded client buffer")
		HTTPClient.STATUS_DISCONNECTED, HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			_finish_rest(false, "HTTP connection unavailable (status %d)" % status)


func _start_rest(request: Dictionary) -> void:
	_rest_current = request
	_rest_client = HTTPClient.new()
	_rest_phase = "connecting"
	_rest_code = 0
	_rest_body.clear()
	var connect_error := _rest_client.connect_to_host(_host, _port)
	if connect_error != OK:
		_finish_rest(false, "Could not connect to OpenCode: %s" % error_string(connect_error))


func _send_rest_request() -> void:
	var payload: Variant = _rest_current.get("payload")
	var body := ""
	if payload != null:
		body = JSON.stringify(payload)
	var headers := _request_headers("application/json")
	if not body.is_empty():
		headers.append("Content-Type: application/json")
		headers.append("Content-Length: %d" % body.to_utf8_buffer().size())
	var request_error := _rest_client.request(
		int(_rest_current["method"]),
		String(_rest_current["path"]),
		headers,
		body
	)
	if request_error != OK:
		_finish_rest(false, "OpenCode request failed: %s" % error_string(request_error))
		return
	_rest_phase = "requesting"


func _capture_rest_response() -> void:
	if _rest_code == 0 and _rest_client.has_response():
		_rest_code = _rest_client.get_response_code()


func _finish_rest_response() -> void:
	_capture_rest_response()
	var body_text := _rest_body.get_string_from_utf8()
	if _rest_code == 401 or _rest_code == 403:
		_authentication_failed("OpenCode rejected the managed credential (HTTP %d)" % _rest_code)
		return
	if _rest_code < 200 or _rest_code >= 300:
		_finish_rest(false, "OpenCode returned HTTP %d: %s" % [_rest_code, body_text.left(512)])
		return
	var data: Variant = null
	if not body_text.strip_edges().is_empty():
		var json := JSON.new()
		if json.parse(body_text) != OK:
			_finish_rest(false, "OpenCode returned malformed JSON")
			return
		data = json.data
	_handle_rest_success(String(_rest_current["operation"]), data, _rest_current.get("context", {}))
	_finish_rest(true, "")


func _finish_rest(success: bool, detail: String) -> void:
	var operation := String(_rest_current.get("operation", "request"))
	var context: Dictionary = _rest_current.get("context", {})
	var request_generation := int(_rest_current.get("generation", -1))
	if _rest_client != null:
		_rest_client.close()
	_rest_client = null
	_rest_current.clear()
	_rest_phase = "idle"
	_rest_code = 0
	_rest_body.clear()
	if not success:
		if operation in ["prompt", "interrupt"] and _active_request_matches(context, request_generation):
			_complete_active_request("failed", "Request failed")
		if operation == "history":
			var history_session := String(context.get("session_id", ""))
			_history_recovery_pending.erase(history_session)
			diagnostic.emit("history", "History reload failed; select or refresh the session to retry")
		if operation in ["permission_reply", "question_reply", "question_reject"]:
			var response_session := String(context.get("session_id", ""))
			var response_id := String(context.get("request_id", ""))
			interaction_response_failed.emit(operation, response_session, response_id, detail)
			if _daemon_ready and request_generation == _daemon_generation and not response_session.is_empty():
				_restore_pending_requests(response_session)
		api_error.emit(operation, detail)


func _handle_rest_success(operation: String, response: Variant, context: Dictionary) -> void:
	match operation:
		"compatibility":
			if not response is Dictionary or response.get("opencode_version") != EXPECTED_OPENCODE_VERSION:
				_daemon_ready = false
				daemon_state_changed.emit(false, "OpenCode/client contract mismatch")
				api_error.emit("compatibility", "Expected OpenCode %s managed-health contract" % EXPECTED_OPENCODE_VERSION)
				return
			daemon_state_changed.emit(true, "OpenCode %s authenticated" % EXPECTED_OPENCODE_VERSION)
			list_sessions()
		"project_probe":
			if not _project_probe_matches(response):
				_daemon_ready = false
				daemon_state_changed.emit(false, "OpenCode project routing mismatch")
				api_error.emit("project", "Directory-bound probe did not target the active Godot project")
				return
			_project_probe_verified = true
			_maybe_start_live_stream()
		"list_sessions":
			var sessions := _unwrap_array(response)
			_sessions_snapshot_loaded = true
			sessions_changed.emit(sessions)
			_maybe_start_live_stream()
		"create_session":
			var session := _unwrap_dictionary(response)
			var session_id := String(session.get("id", ""))
			if session_id.is_empty():
				api_error.emit("session", "Create-session response did not contain an id")
				return
			list_sessions()
			select_session(session_id)
		"history":
			var session_id := String(context.get("session_id", ""))
			var events: Array = context.get("events", [])
			var page := _unwrap_array(response)
			events.append_array(page)
			if response is Dictionary and response.get("hasMore", false) and not page.is_empty():
				var tail: Dictionary = page[page.size() - 1] if page[page.size() - 1] is Dictionary else {}
				var durable: Dictionary = tail.get("durable", {})
				var after := int(durable.get("seq", -1))
				if after >= 0:
					_enqueue(
						"history",
						HTTPClient.METHOD_GET,
						"/api/session/%s/history?limit=100&after=%d" % [session_id.uri_encode(), after],
						null,
						{"session_id": session_id, "events": events}
					)
					return
			_history_recovery_pending.erase(session_id)
			_last_sequence_by_session[session_id] = -1
			for event in events:
				if event is Dictionary:
					_apply_durable_event(event, true)
			history_reloaded.emit(session_id, events)
			if session_id == active_session_id:
				_start_durable_stream(session_id)
				_restore_pending_requests(session_id)
				_maybe_start_live_stream()
		"prompt":
			var admitted := _unwrap_dictionary(response)
			var admitted_session := String(admitted.get("sessionID", ""))
			if admitted_session != String(context.get("session_id", "")) or admitted_session.is_empty():
				api_error.emit("prompt", "OpenCode admitted a prompt for an unexpected session")
				if _active_request_matches(context, _daemon_generation):
					_complete_active_request("failed", "Request admission mismatch")
				return
			if _active_request_matches(context, _daemon_generation):
				_active_request_admission_id = String(admitted.get("id", ""))
				request_state_changed.emit(admitted_session, true, "OpenCode is working")
		"interrupt":
			if _active_request_matches(context, _daemon_generation):
				_complete_active_request("cancelled", "Cancelled")
		"permission_list":
			var permission_session := String(context.get("session_id", active_session_id))
			for request in _unwrap_array(response):
				if request is Dictionary:
					permission_pending.emit(String(request.get("sessionID", permission_session)), request)
		"question_list":
			var question_session := String(context.get("session_id", active_session_id))
			for request in _unwrap_array(response):
				if request is Dictionary:
					question_pending.emit(String(request.get("sessionID", question_session)), request)
		"permission_reply", "question_reply", "question_reject":
			interaction_response_completed.emit(operation, String(context.get("session_id", "")), String(context.get("request_id", "")))
			diagnostic.emit(operation, "Response accepted")


func _recover_session(session_id: String, reason: String) -> void:
	if session_id.is_empty() or _history_recovery_pending.has(session_id):
		return
	_history_recovery_pending[session_id] = true
	if is_instance_valid(_durable_stream):
		_durable_stream.stop()
	if is_instance_valid(_live_stream):
		_live_stream.stop()
	_live_recovery_pending = true
	diagnostic.emit("stream", "%s; reloading authoritative history" % reason)
	_enqueue(
		"history",
		HTTPClient.METHOD_GET,
		"/api/session/%s/history?limit=100" % session_id.uri_encode(),
		null,
		{"session_id": session_id, "events": []}
	)


func _restore_pending_requests(session_id: String) -> void:
	_enqueue(
		"permission_list",
		HTTPClient.METHOD_GET,
		"/api/session/%s/permission" % session_id.uri_encode(),
		null,
		{"session_id": session_id}
	)
	_enqueue(
		"question_list",
		HTTPClient.METHOD_GET,
		"/api/session/%s/question" % session_id.uri_encode(),
		null,
		{"session_id": session_id}
	)


func _start_durable_stream(session_id: String) -> void:
	var after := int(_last_sequence_by_session.get(session_id, -1))
	var path := "/api/session/%s/event" % session_id.uri_encode()
	if after >= 0:
		path += "?after=%d" % after
	_durable_stream.start(_host, _port, path, _request_headers("text/event-stream"), _daemon_generation)


func _start_live_stream() -> void:
	var path := "/event"
	_live_stream.start(_host, _port, path, _request_headers("text/event-stream"), _daemon_generation)


func _maybe_start_live_stream() -> void:
	if not _daemon_ready or not _project_probe_verified or not _sessions_snapshot_loaded:
		return
	if not active_session_id.is_empty() and _history_recovery_pending.has(active_session_id):
		return
	if is_instance_valid(_live_stream) and _live_stream.is_running_for(_daemon_generation):
		return
	_live_recovery_pending = false
	_start_live_stream()


func _on_durable_frame(frame: Dictionary, generation: int) -> void:
	if generation != _daemon_generation:
		return
	var event := _decode_sse_json(frame)
	if event.is_empty():
		return
	# The durable endpoint can carry its event id as the SSE frame id instead of
	# duplicating it in the JSON payload. Preserve it so the live stream and the
	# durable cursor share one deduplication domain.
	if not event.has("id") and not String(frame.get("id", "")).is_empty():
		event["id"] = String(frame.get("id", ""))
	_apply_durable_event(event, false)


func _apply_durable_event(event: Dictionary, from_snapshot: bool) -> void:
	var normalized := _unwrap_event(event)
	if not normalized.has("id") and event.has("id"):
		normalized = normalized.duplicate(true)
		normalized["id"] = event["id"]
	if normalized.is_empty() or not _event_targets_project(normalized):
		return
	var data := _event_data(normalized, String(normalized.get("type", "")))
	if data.is_empty():
		return
	var session_id := String(data.get("sessionID", ""))
	if session_id.is_empty():
		api_error.emit("compatibility", "Durable OpenCode event is missing session identity")
		return
	var raw_durable: Variant = normalized.get("durable", {})
	if not raw_durable is Dictionary:
		api_error.emit("compatibility", "Durable OpenCode event has malformed cursor metadata")
		return
	var durable: Dictionary = raw_durable
	var sequence := int(durable.get("seq", -1))
	var last := int(_last_sequence_by_session.get(session_id, -1))
	if sequence >= 0:
		if sequence <= last:
			return
		if not from_snapshot and sequence > last + 1:
			_recover_session(session_id, "Durable event gap %d -> %d" % [last, sequence])
			return
		_last_sequence_by_session[session_id] = sequence
	if _remember_event_id(String(normalized.get("id", ""))):
		return
	_apply_event(normalized)


func _on_live_frame(frame: Dictionary, generation: int) -> void:
	if generation != _daemon_generation:
		return
	# Stopping an HTTPClient cannot retract frames that were already parsed in
	# the same engine tick. A recovery snapshot is the invalidation barrier for
	# *every* session, so discard those stale live frames before inspecting them.
	if _live_recovery_pending:
		return
	var decoded := _decode_sse_json(frame)
	if decoded.is_empty():
		return
	var event := _unwrap_event(decoded)
	if not event.has("id"):
		var source_id := String(decoded.get("id", frame.get("id", "")))
		if not source_id.is_empty():
			event = event.duplicate(true)
			event["id"] = source_id
	if event.is_empty() or not _event_targets_project(event):
		return
	var event_id := String(event.get("id", frame.get("id", "")))
	if _remember_event_id(event_id):
		return
	_apply_event(event)


func _apply_event(event: Dictionary) -> void:
	var event_type := String(event.get("type", ""))
	var data := _event_data(event, event_type)
	if data.is_empty():
		return
	var session_id := String(data.get("sessionID", data.get("session_id", "")))
	if session_id.is_empty():
		api_error.emit("compatibility", "OpenCode event %s is missing session identity" % event_type)
		return
	# Streams are stopped before a history snapshot, but a frame already queued by
	# the engine can still arrive. The snapshot is authoritative until it finishes.
	if _history_recovery_pending.has(session_id):
		return
	var visible_session := session_id == active_session_id
	match event_type:
		"session.next.text.delta":
			if visible_session:
				assistant_output.emit(session_id, String(data.get("delta", "")), false)
		"session.next.text.ended":
			if visible_session:
				assistant_output.emit(session_id, String(data.get("text", "")), true)
		"session.next.step.ended":
			_complete_active_request_if_matching(session_id, "completed", "Completed")
		"session.next.step.failed":
			if _complete_active_request_if_matching(session_id, "failed", "Failed"):
				api_error.emit("conversation", JSON.stringify(data.get("error", {})))
		"permission.v2.asked", "permission.asked":
			permission_pending.emit(session_id, data)
		"permission.v2.replied", "permission.replied":
			interaction_response_completed.emit("permission_event", session_id, String(data.get("requestID", "")))
		"question.v2.asked", "question.asked":
			question_pending.emit(session_id, data)
		"question.v2.replied", "question.replied", "question.v2.rejected", "question.rejected":
			interaction_response_completed.emit("question_event", session_id, String(data.get("requestID", "")))
		_:
			if visible_session and (event_type.begins_with("session.next.tool") or event_type.begins_with("tool.")):
				tool_activity.emit(session_id, {"type": event_type, "data": data})
			elif visible_session and event_type == "message.part.updated":
				_apply_legacy_part_update(session_id, data)


func _apply_legacy_part_update(session_id: String, data: Dictionary) -> void:
	var raw_part: Variant = data.get("part", {})
	if not raw_part is Dictionary:
		api_error.emit("compatibility", "OpenCode legacy message part is malformed")
		return
	var part: Dictionary = raw_part
	if part.get("type") == "text":
		var delta := String(data.get("delta", ""))
		assistant_output.emit(session_id, delta if not delta.is_empty() else String(part.get("text", "")), delta.is_empty())
	elif part.get("type") == "tool":
		tool_activity.emit(session_id, {"type": "message.part.updated", "data": data})


func _on_durable_failed(status_code: int, detail: String, generation: int) -> void:
	if generation != _daemon_generation:
		return
	if status_code == 401 or status_code == 403:
		_authentication_failed(detail)
		return
	_recover_session(active_session_id, "Durable cursor could not resume (HTTP %d)" % status_code)


func _on_live_failed(status_code: int, detail: String, generation: int) -> void:
	if generation != _daemon_generation:
		return
	if status_code == 401 or status_code == 403:
		_authentication_failed(detail)
		return
	# Project/global streams are non-durable. Refresh snapshots before using
	# their replacement connection as an invalidation barrier.
	_live_stream.stop()
	_live_recovery_pending = true
	_sessions_snapshot_loaded = false
	list_sessions()
	if not active_session_id.is_empty():
		_recover_session(active_session_id, "Live stream reconnected")


func _on_stream_state(state: String, detail: String, generation: int, stream_name: String) -> void:
	if generation == _daemon_generation:
		diagnostic.emit("%s_stream" % stream_name, "%s: %s" % [state, detail])


func _authentication_failed(detail: String) -> void:
	shutdown_transport()
	api_error.emit("authentication", detail)


func _remember_event_id(event_id: String) -> bool:
	if event_id.is_empty():
		return false
	if _recent_event_ids.has(event_id):
		return true
	_recent_event_ids[event_id] = true
	_recent_event_order.append(event_id)
	if _recent_event_order.size() > MAX_RECENT_EVENT_IDS:
		_recent_event_ids.erase(_recent_event_order.pop_front())
	return false


func _decode_sse_json(frame: Dictionary) -> Dictionary:
	var json := JSON.new()
	if json.parse(String(frame.get("data", ""))) != OK or not json.data is Dictionary:
		api_error.emit("compatibility", "Malformed OpenCode SSE event")
		return {}
	return json.data


func _unwrap_event(event: Dictionary) -> Dictionary:
	if event.get("data") is Dictionary and not event.has("type") and event["data"].get("type") is String:
		return event["data"]
	return event


func _event_data(event: Dictionary, event_type: String) -> Dictionary:
	var raw: Variant = event.get("data", event.get("properties", {}))
	if raw is Dictionary:
		return raw
	api_error.emit("compatibility", "OpenCode event %s has malformed nested data" % event_type)
	return {}


func _active_request_matches(context: Dictionary, request_generation: int) -> bool:
	return active_request \
		and request_generation == _daemon_generation \
		and _active_request_generation == _daemon_generation \
		and String(context.get("session_id", "")) == _active_request_session_id


func _complete_active_request_if_matching(session_id: String, state: String, detail: String) -> bool:
	if not active_request or _active_request_generation != _daemon_generation or session_id != _active_request_session_id:
		return false
	_complete_active_request(state, detail)
	return true


func _complete_active_request(state: String, detail: String) -> void:
	var completed_session := _active_request_session_id
	active_request = false
	_active_request_session_id = ""
	_active_request_generation = -1
	_active_request_admission_id = ""
	_interrupt_pending = false
	request_state_changed.emit(completed_session, false, detail)
	request_completed.emit(completed_session, state)


func _event_targets_project(event: Dictionary) -> bool:
	var location: Variant = event.get("location")
	if location != null and not location is Dictionary:
		api_error.emit("compatibility", "OpenCode event has malformed location metadata")
		return false
	if location is Dictionary:
		if not location.has("directory") or not location.get("directory") is String:
			api_error.emit("compatibility", "OpenCode event location is missing a directory")
			return false
		var incoming := String(location["directory"]).replace("\\", "/").simplify_path()
		if incoming != project_path:
			api_error.emit("project", "Rejected an event routed to a different project")
			return false
	return true


func _request_headers(accept: String) -> PackedStringArray:
	var credentials := Marshalls.utf8_to_base64("opencode:%s" % _password)
	return PackedStringArray([
		"Authorization: Basic %s" % credentials,
		"Accept: %s" % accept,
		"Cache-Control: no-cache",
		# OpenCode decodes this header exactly once before loading an instance.
		# Encoding preserves spaces, non-ASCII text, and literal percent escapes.
		"x-opencode-directory: %s" % project_path.uri_encode(),
	])


func _parse_loopback_url(base_url: String) -> Dictionary:
	var value := base_url.strip_edges().trim_suffix("/")
	if not value.begins_with("http://127.0.0.1:"):
		return {"ok": false, "error": "Managed OpenCode must report an IPv4 loopback URL"}
	var authority := value.substr("http://".length())
	if authority.contains("/"):
		return {"ok": false, "error": "Managed OpenCode URL must not contain a path"}
	var port_text := authority.get_slice(":", 1)
	if not port_text.is_valid_int():
		return {"ok": false, "error": "Managed OpenCode URL has an invalid port"}
	var port := int(port_text)
	if port <= 0 or port > 65535:
		return {"ok": false, "error": "Managed OpenCode port is out of range"}
	return {"ok": true, "host": "127.0.0.1", "port": port}


func _unwrap_array(response: Variant) -> Array:
	if response is Dictionary and response.get("data") is Array:
		return response["data"]
	return response if response is Array else []


func _unwrap_dictionary(response: Variant) -> Dictionary:
	if response is Dictionary and response.get("data") is Dictionary:
		return response["data"]
	return response if response is Dictionary else {}


func _project_probe_matches(response: Variant) -> bool:
	var instance_path := _unwrap_dictionary(response)
	var directory := instance_path.get("directory", "")
	if not directory is String or directory.is_empty():
		return false
	return String(directory).replace("\\", "/").simplify_path() == project_path
