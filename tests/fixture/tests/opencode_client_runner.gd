extends SceneTree

const SSEParser := preload("res://addons/opencode_godot/client/sse_parser.gd")
const APIClient := preload("res://addons/opencode_godot/client/opencode_api_client.gd")
const OpenCodeDock := preload("res://addons/opencode_godot/ui/opencode_dock.gd")


class LifecycleFixture:
	extends RefCounted
	signal daemon_ready(base_url: String, password: String, generation: int)
	signal daemon_stopped(generation: int)
	signal state_changed(state: String, detail: String)
	signal diagnostic(category: String, message: String)

	var label := "fixture"

	func _init(value: String) -> void:
		label = value

	func get_status() -> Dictionary:
		return {"state": "ready", "detail": label, "integration_mode": "mcp", "requested_integration_mode": ""}

var failures: Array[String] = []
var assistant_events: Array[Dictionary] = []
var api_errors: Array[Dictionary] = []
var permission_events: Array[Dictionary] = []
var question_events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_fragmented_sse()
	var api: Node = APIClient.new()
	root.add_child(api)
	await process_frame
	var project := ProjectSettings.globalize_path("res://").replace("\\", "/").simplify_path()
	api.setup(project)
	api.assistant_output.connect(_on_assistant)
	api.api_error.connect(_on_api_error)
	api.permission_pending.connect(_on_permission)
	api.question_pending.connect(_on_question)
	_test_auth_and_endpoint(api, project)
	_test_session_scope_and_snapshot_gate(api, project)
	_test_durable_ordering(api)
	_test_request_correlation(api)
	_test_generation_and_event_isolation(api)
	_test_cross_stream_dedup_and_live_barrier(api)
	_test_transport_failure_recovery(api)
	await _test_dock_session_and_streaming(api)
	api.shutdown()
	api.queue_free()
	if failures.is_empty():
		print("OPENCODE_GODOT_CLIENT_OK")
		quit(0)
	else:
		for failure: String in failures:
			push_error("TEST FAILURE: " + failure)
		quit(1)


func _test_fragmented_sse() -> void:
	var parser: RefCounted = SSEParser.new()
	var wire := "id: 7\nevent: message\ndata: {\"text\":\"你好\"}\n\n".to_utf8_buffer()
	var frames: Array[Dictionary] = []
	# Feed deliberately tiny chunks; the ranges split both field names and a
	# multibyte UTF-8 code point.
	var offset := 0
	for size in [1, 8, 14, 3, wire.size()]:
		if offset >= wire.size():
			break
		var end := mini(offset + size, wire.size())
		frames.append_array(parser.feed(wire.slice(offset, end)))
		offset = end
	_expect(frames.size() == 1, "fragmented SSE emits exactly one complete frame")
	if frames.size() == 1:
		_expect(frames[0].get("id") == "7", "SSE event id is preserved")
		_expect(String(frames[0].get("data", "")).contains("你好"), "split UTF-8 data is preserved")


func _test_auth_and_endpoint(api: Node, project: String) -> void:
	var valid: Dictionary = api._parse_loopback_url("http://127.0.0.1:43123")
	_expect(valid.get("ok", false), "IPv4 loopback daemon URL is accepted")
	_expect(not api._parse_loopback_url("http://0.0.0.0:43123").get("ok", true), "non-loopback daemon URL is rejected")
	api._password = "01234567890123456789012345678901"
	var headers: PackedStringArray = api._request_headers("application/json")
	var authorization := ""
	var directory := ""
	for header in headers:
		if header.begins_with("Authorization: "):
			authorization = header.trim_prefix("Authorization: Basic ")
		if header.begins_with("x-opencode-directory: "):
			directory = header.trim_prefix("x-opencode-directory: ")
	_expect(Marshalls.base64_to_utf8(authorization) == "opencode:" + api._password, "Basic auth follows the pinned SDK username/password contract")
	_expect(directory == project.uri_encode(), "every instance request carries the once-encoded canonical directory binding expected by OpenCode")
	_expect((project + "/literal%20segment").uri_encode().uri_decode() == project + "/literal%20segment", "one server-side decode preserves literal percent path segments")
	_expect(api._project_probe_matches({"directory": project, "worktree": "/"}), "the instance path probe accepts a routed non-Git project whose Project.Info worktree is root")
	_expect(not api._project_probe_matches({"worktree": project}), "project worktree metadata is not mistaken for exact instance-directory proof")


func _test_session_scope_and_snapshot_gate(api: Node, project: String) -> void:
	api._rest_queue.clear()
	api._daemon_ready = true
	api._daemon_generation = 10
	api.list_sessions()
	_expect(api._rest_queue.size() == 1 and String(api._rest_queue[0].get("path", "")) == "/api/session?directory=" + project.uri_encode(), "session list explicitly scopes the v2 query to the canonical directory")
	api._rest_queue.clear()
	api._host = "127.0.0.1"
	api._port = 1
	api._handle_rest_success("compatibility", {"opencode_version": api.EXPECTED_OPENCODE_VERSION}, {})
	_expect(not api._live_stream.is_running_for(api._daemon_generation), "live events wait behind the authoritative session snapshot")
	api._handle_rest_success("project_probe", {"directory": project}, {})
	_expect(not api._live_stream.is_running_for(api._daemon_generation), "project verification alone does not bypass the session snapshot barrier")
	api._handle_rest_success("list_sessions", {"data": []}, {})
	_expect(api._live_stream.is_running_for(api._daemon_generation), "live events resume only after the directory-scoped session snapshot completes")
	api._live_stream.stop()
	api._rest_queue.clear()


func _test_generation_and_event_isolation(api: Node) -> void:
	api._daemon_ready = true
	api._daemon_generation = 11
	api.active_session_id = "ses_b"
	api.active_request = true
	api._active_request_session_id = "ses_b"
	api._active_request_generation = 11
	var outputs_before := assistant_events.size()
	api._apply_event({"type": "session.next.text.delta", "data": {"sessionID": "ses_a", "delta": "hidden"}})
	_expect(assistant_events.size() == outputs_before, "live output from a non-active session is isolated from the active transcript")
	api._history_recovery_pending["ses_b"] = true
	api._apply_event({"type": "session.next.text.delta", "data": {"sessionID": "ses_b", "delta": "stale"}})
	_expect(assistant_events.size() == outputs_before, "queued live frames cannot overtake the authoritative history snapshot")
	api._history_recovery_pending.erase("ses_b")
	api._apply_event({"type": "session.next.step.ended", "data": {"sessionID": "ses_a"}})
	_expect(api.active_request, "a terminal event from an old session cannot clear the selected request")
	api._apply_event({"type": "session.next.step.ended", "data": {"sessionID": "ses_b"}})
	_expect(not api.active_request, "the matching session terminal event completes the active request")
	var errors_before := api_errors.size()
	api._apply_event({"type": "session.next.text.delta", "data": "not-an-object"})
	_expect(api_errors.size() > errors_before, "malformed nested SSE event data produces a compatibility diagnostic")
	api._last_sequence_by_session["ses_a"] = 9
	api._history_recovery_pending["ses_a"] = true
	api._recent_event_ids["evt_old"] = true
	api._recent_event_order.append("evt_old")
	api.shutdown_transport()
	_expect(api._last_sequence_by_session.is_empty() and api._history_recovery_pending.is_empty() and api._recent_event_ids.is_empty(), "daemon shutdown clears generation-scoped cursor and recovery state")


func _test_cross_stream_dedup_and_live_barrier(api: Node) -> void:
	api._daemon_ready = true
	api._daemon_generation = 14
	api.active_session_id = "ses_cross"
	api._last_sequence_by_session.clear()
	api._recent_event_ids.clear()
	api._recent_event_order.clear()
	api._live_recovery_pending = false
	var outputs_before := assistant_events.size()
	var durable_first := {
		"id": "evt_cross_first",
		"type": "session.next.text.ended",
		"durable": {"aggregateID": "ses_cross", "seq": 0, "version": 1},
		"data": {"sessionID": "ses_cross", "text": "cross-first"},
	}
	api._apply_durable_event(durable_first, false)
	api._on_live_frame({"id": "evt_cross_first", "data": JSON.stringify(durable_first)}, 14)
	_expect(assistant_events.size() == outputs_before + 1, "the same durable/live event is rendered once when durable arrives first")
	var live_first := {
		"id": "evt_cross_second",
		"data": {"type": "session.next.text.ended", "data": {"sessionID": "ses_cross", "text": "cross-second"}},
	}
	api._on_live_frame({"data": JSON.stringify(live_first)}, 14)
	var durable_second: Dictionary = live_first["data"].duplicate(true)
	durable_second["id"] = "evt_cross_second"
	durable_second["durable"] = {"aggregateID": "ses_cross", "seq": 1, "version": 1}
	api._apply_durable_event(durable_second, false)
	_expect(assistant_events.size() == outputs_before + 2, "the same durable/live event is rendered once when live arrives first")
	var permissions_before := permission_events.size()
	api._live_recovery_pending = true
	api._on_live_frame({"id": "evt_stale_other", "data": JSON.stringify({"type": "permission.asked", "data": {"sessionID": "ses_other", "id": "per_stale"}})}, 14)
	_expect(permission_events.size() == permissions_before, "live recovery discards queued stale frames for non-current sessions too")
	api._live_recovery_pending = false


func _test_transport_failure_recovery(api: Node) -> void:
	api._daemon_ready = true
	api._daemon_generation = 12
	api.active_request = true
	api._active_request_session_id = "ses_auth"
	api._active_request_generation = 12
	api._history_recovery_pending["ses_retry"] = true
	api._rest_current = {"operation": "history", "context": {"session_id": "ses_retry"}, "generation": 12}
	api._finish_rest(false, "synthetic history failure")
	_expect(not api._history_recovery_pending.has("ses_retry"), "failed history reload clears its in-flight marker so the user can retry")
	api._authentication_failed("synthetic 401")
	_expect(not api._daemon_ready and api.active_session_id.is_empty() and not api.active_request, "authentication loss invalidates the complete transport and active session state")


func _test_durable_ordering(api: Node) -> void:
	api._daemon_ready = true
	api._daemon_generation = 9
	api.active_session_id = "ses_test"
	var first := {
		"id": "evt_1",
		"type": "session.next.text.ended",
		"durable": {"aggregateID": "ses_test", "seq": 0, "version": 1},
		"data": {"sessionID": "ses_test", "text": "first"},
	}
	api._apply_durable_event(first, false)
	api._apply_durable_event(first, false)
	_expect(assistant_events.size() == 1, "duplicate durable event is suppressed")
	var gap := first.duplicate(true)
	gap["id"] = "evt_3"
	gap["durable"]["seq"] = 2
	gap["data"]["text"] = "gap"
	api._apply_durable_event(gap, false)
	_expect(assistant_events.size() == 1, "event after a durable sequence gap is not applied")
	_expect(api._history_recovery_pending.has("ses_test"), "durable gap schedules authoritative history recovery")
	var wrong_project := first.duplicate(true)
	wrong_project["id"] = "evt_wrong"
	wrong_project["durable"]["seq"] = 1
	wrong_project["location"] = {"directory": "C:/different/project"}
	api._apply_durable_event(wrong_project, false)
	_expect(not api_errors.is_empty(), "event from a different project is rejected with a diagnostic")


func _test_request_correlation(api: Node) -> void:
	api._rest_queue.clear()
	api._daemon_ready = true
	api.active_session_id = "ses_selected"
	api.reply_permission("per_1", "once", "", "ses_origin")
	api.answer_question("que_1", [["answer"]], "ses_origin")
	api.reject_question("que_2", "ses_origin")
	_expect(api._rest_queue.size() == 3, "explicit permission and question responses are queued")
	if api._rest_queue.size() == 3:
		for request: Dictionary in api._rest_queue:
			_expect(String(request.get("path", "")).contains("/ses_origin/"), "pending response remains correlated with its originating session")
	api._handle_rest_success("permission_list", {"data": [{"id": "per_pending"}]}, {"session_id": "ses_origin"})
	api._handle_rest_success("question_list", {"data": [{"id": "que_pending", "questions": []}]}, {"session_id": "ses_origin"})
	_expect(not permission_events.is_empty() and String(permission_events.back().get("session_id", "")) == "ses_origin", "permission snapshot preserves the session that requested it")
	_expect(not question_events.is_empty() and String(question_events.back().get("session_id", "")) == "ses_origin", "question snapshot preserves the session that requested it")


func _test_dock_session_and_streaming(api: Node) -> void:
	api.shutdown_transport()
	api._rest_queue.clear()
	var dock = OpenCodeDock.new()
	root.add_child(dock)
	var first_lifecycle := LifecycleFixture.new("first")
	dock.setup(first_lifecycle, api, null)
	await process_frame
	first_lifecycle.diagnostic.emit("fixture", "first lifecycle")
	var diagnostic_count: int = dock._diagnostics.size()
	var second_lifecycle := LifecycleFixture.new("second")
	dock.setup(second_lifecycle, api, null)
	first_lifecycle.diagnostic.emit("fixture", "stale lifecycle")
	_expect(dock._diagnostics.size() == diagnostic_count, "dock disconnects the previous lifecycle during a mode restart")
	second_lifecycle.diagnostic.emit("fixture", "replacement lifecycle")
	_expect(dock._diagnostics.size() == diagnostic_count + 1, "dock binds the replacement lifecycle during a mode restart")
	dock._on_sessions_changed([{"id": "ses_first", "title": "First"}])
	_expect(api.active_session_id == "ses_first", "the first visible session becomes the client's active session")
	dock._reset_transcript()
	dock._on_assistant_output("ses_first", "hel", false)
	dock._on_assistant_output("ses_first", "lo", false)
	_expect(String(dock._transcript.text).contains("hello"), "assistant deltas render incrementally")
	dock._on_assistant_output("ses_first", "hello", true)
	_expect(String(dock._transcript.text).count("hello") == 1, "the durable final text replaces its streamed preview without duplication")
	dock._on_assistant_output("ses_other", "must-not-render", false)
	_expect(not String(dock._transcript.text).contains("must-not-render"), "dock ignores live output for a non-active session")
	dock._on_permission_pending("ses_first", {"id": "per_1", "action": "edit", "resources": []})
	dock._on_permission_pending("ses_other", {"id": "per_2", "action": "edit", "resources": []})
	_expect(dock._pending_permissions_by_key.size() == 2, "permission prompts queue by session and request identity")
	dock._on_interaction_response_completed("permission_reply", "ses_first", "per_1")
	_expect(dock._pending_permissions_by_key.size() == 1, "only a successful response clears its matching permission prompt")
	dock._on_permission_pending("ses_first", {"id": "per_1", "action": "edit", "resources": []})
	var permission_key := dock._interaction_key("ses_first", "per_1")
	var submitting_permission: Dictionary = dock._pending_permissions_by_key[permission_key]
	submitting_permission["_submitting"] = true
	dock._pending_permissions_by_key[permission_key] = submitting_permission
	dock._on_permission_pending("ses_first", {"id": "per_1", "action": "edit", "resources": []})
	_expect(bool(dock._pending_permissions_by_key[permission_key].get("_submitting", false)), "a permission snapshot does not reset the same in-flight submission")
	dock._on_question_pending("ses_first", {"id": "que_1", "questions": []})
	var question_key := dock._interaction_key("ses_first", "que_1")
	var submitting_question: Dictionary = dock._pending_questions_by_key[question_key]
	submitting_question["_submitting"] = true
	dock._pending_questions_by_key[question_key] = submitting_question
	dock._on_question_pending("ses_first", {"id": "que_1", "questions": []})
	_expect(bool(dock._pending_questions_by_key[question_key].get("_submitting", false)), "a question snapshot does not reset the same in-flight submission")
	dock._busy = true
	dock._cancel.disabled = false
	api._daemon_ready = true
	api._daemon_generation = 15
	api.active_session_id = "ses_first"
	api.active_request = true
	api._active_request_session_id = "ses_first"
	api._active_request_generation = 15
	api._on_live_failed(403, "synthetic 403", 15)
	_expect(not dock._busy and dock._cancel.disabled and dock._send.disabled, "403 invalidation resets busy, cancel, and send controls")
	_expect(dock._pending_permissions_by_key.is_empty() and dock._pending_questions_by_key.is_empty() and not dock._permission_panel.visible and not dock._question_panel.visible, "transport loss removes stale interaction controls instead of allowing offline submission")
	dock._on_permission_pending("ses_reconnected", {"id": "per_new", "action": "edit", "resources": []})
	dock._on_question_pending("ses_reconnected", {"id": "que_new", "questions": []})
	_expect(dock._pending_permissions_by_key.size() == 1 and dock._pending_questions_by_key.size() == 1 and not dock._pending_permissions_by_key.has(permission_key) and not dock._pending_questions_by_key.has(question_key), "only the replacement daemon's authoritative pending snapshots repopulate interaction queues")
	dock._busy = true
	dock._cancel.disabled = false
	dock._on_daemon_stopped(15)
	_expect(not dock._busy and dock._cancel.disabled and dock._send.disabled, "daemon stop resets busy, cancel, and send controls")
	dock.queue_free()


func _on_assistant(session_id: String, text: String, replace: bool) -> void:
	assistant_events.append({"session_id": session_id, "text": text, "replace": replace})


func _on_api_error(category: String, detail: String) -> void:
	api_errors.append({"category": category, "detail": detail})


func _on_permission(session_id: String, request: Dictionary) -> void:
	permission_events.append({"session_id": session_id, "request": request})


func _on_question(session_id: String, request: Dictionary) -> void:
	question_events.append({"session_id": session_id, "request": request})


func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
