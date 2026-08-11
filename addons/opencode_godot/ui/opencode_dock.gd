@tool
extends VBoxContainer

signal integration_mode_requested(mode: String)

var _lifecycle: RefCounted
var _api: Node
var _bridge: Node
var _bound := false
var _busy := false
var _pending_permission: Dictionary = {}
var _pending_question: Dictionary = {}
var _pending_permissions_by_key: Dictionary = {}
var _pending_questions_by_key: Dictionary = {}
var _question_lists: Array[ItemList] = []
var _question_custom: Array[LineEdit] = []

var _summary: Label
var _tabs: TabContainer
var _sessions: OptionButton
var _new_session: Button
var _refresh_sessions: Button
var _transcript: RichTextLabel
var _prompt: TextEdit
var _send: Button
var _cancel: Button
var _permission_panel: VBoxContainer
var _permission_text: Label
var _question_panel: VBoxContainer
var _question_text: Label
var _question_inputs: VBoxContainer
var _status_text: RichTextLabel
var _integration_mode: OptionButton
var _apply_integration_mode: Button
var _daemon_status := "Daemon: unavailable"
var _bridge_status := "Bridge: unavailable"
var _tools_status := "Godot tools: unavailable"
var _diagnostics: Array[String] = []
var _transcript_content := ""
var _streaming_assistant_text := ""
var _streaming_assistant_session := ""


func _ready() -> void:
	_build_ui()
	_bind_sources()


func setup(lifecycle: RefCounted, api_client: Node, bridge: Node) -> void:
	_unbind_sources()
	_lifecycle = lifecycle
	_api = api_client
	_bridge = bridge
	_bind_sources()


func set_lifecycle_state(state: String, detail: String) -> void:
	_daemon_status = "Daemon: %s — %s" % [state, detail]
	if state != "ready" and _prompt != null:
		_set_chat_enabled(false)
	_refresh_status()


func show_diagnostic(category: String, message: String) -> void:
	_append_status("[%s] %s" % [category, message])
	if _summary != null and category in ["preflight", "payload", "security", "daemon"]:
		_summary.text = message
		_summary.tooltip_text = message


func _process(_delta: float) -> void:
	if is_instance_valid(_bridge) and _bridge.has_method("get_state_name"):
		var state := String(_bridge.get_state_name())
		var detail := String(_bridge.get_state_detail()) if _bridge.has_method("get_state_detail") else ""
		_bridge_status = "Bridge: %s%s" % [state, " — " + detail if not detail.is_empty() else ""]
		_tools_status = "Godot tools: ready" if _bridge.has_method("is_session_ready") and _bridge.is_session_ready() else "Godot tools: waiting for authenticated bridge"
	if _integration_mode != null and _lifecycle != null and _lifecycle.has_method("get_status"):
		var lifecycle_status: Dictionary = _lifecycle.get_status()
		var active_mode := String(lifecycle_status.get("integration_mode", "mcp"))
		var wanted_mode := String(lifecycle_status.get("requested_integration_mode", ""))
		var selected := 1 if (wanted_mode if not wanted_mode.is_empty() else active_mode) == "native" else 0
		if _integration_mode.selected != selected:
			_integration_mode.select(selected)
	_refresh_status()


func _build_ui() -> void:
	if _tabs != null:
		return
	custom_minimum_size = Vector2(340, 420)
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_summary = Label.new()
	_summary.text = "OpenCode is starting…"
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_summary)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_tabs)
	_build_chat_tab()
	_build_status_tab()


func _build_chat_tab() -> void:
	var chat := VBoxContainer.new()
	chat.name = "Chat"
	chat.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(chat)

	var session_row := HBoxContainer.new()
	chat.add_child(session_row)
	_sessions = OptionButton.new()
	_sessions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sessions.disabled = true
	_sessions.item_selected.connect(_on_session_selected)
	session_row.add_child(_sessions)
	_new_session = Button.new()
	_new_session.text = "New"
	_new_session.disabled = true
	_new_session.pressed.connect(_on_new_session)
	session_row.add_child(_new_session)
	_refresh_sessions = Button.new()
	_refresh_sessions.text = "↻"
	_refresh_sessions.tooltip_text = "Refresh sessions"
	_refresh_sessions.disabled = true
	_refresh_sessions.pressed.connect(_on_refresh_sessions)
	session_row.add_child(_refresh_sessions)

	_transcript = RichTextLabel.new()
	_transcript.bbcode_enabled = true
	_transcript.selection_enabled = true
	_transcript.scroll_following = true
	_transcript.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_transcript.custom_minimum_size.y = 180
	chat.add_child(_transcript)

	_permission_panel = VBoxContainer.new()
	_permission_panel.visible = false
	chat.add_child(_permission_panel)
	_permission_text = Label.new()
	_permission_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_permission_panel.add_child(_permission_text)
	var permission_actions := HBoxContainer.new()
	_permission_panel.add_child(permission_actions)
	for choice: String in ["once", "always", "reject"]:
		var button := Button.new()
		button.text = {"once": "Allow once", "always": "Always allow", "reject": "Reject"}[choice]
		button.pressed.connect(_on_permission_reply.bind(choice))
		permission_actions.add_child(button)

	_question_panel = VBoxContainer.new()
	_question_panel.visible = false
	chat.add_child(_question_panel)
	_question_text = Label.new()
	_question_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_question_panel.add_child(_question_text)
	_question_inputs = VBoxContainer.new()
	_question_panel.add_child(_question_inputs)
	var question_actions := HBoxContainer.new()
	_question_panel.add_child(question_actions)
	var answer_button := Button.new()
	answer_button.text = "Answer"
	answer_button.pressed.connect(_on_question_answer)
	question_actions.add_child(answer_button)
	var reject_button := Button.new()
	reject_button.text = "Reject"
	reject_button.pressed.connect(_on_question_reject)
	question_actions.add_child(reject_button)

	_prompt = TextEdit.new()
	_prompt.placeholder_text = "Ask OpenCode about this Godot project…"
	_prompt.custom_minimum_size.y = 76
	_prompt.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_prompt.editable = false
	chat.add_child(_prompt)
	var action_row := HBoxContainer.new()
	chat.add_child(action_row)
	_send = Button.new()
	_send.text = "Send"
	_send.disabled = true
	_send.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_send.pressed.connect(_on_send)
	action_row.add_child(_send)
	_cancel = Button.new()
	_cancel.text = "Cancel"
	_cancel.disabled = true
	_cancel.pressed.connect(_on_cancel)
	action_row.add_child(_cancel)


func _build_status_tab() -> void:
	var status := VBoxContainer.new()
	status.name = "Status"
	status.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(status)
	_status_text = RichTextLabel.new()
	_status_text.bbcode_enabled = true
	_status_text.selection_enabled = true
	_status_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	status.add_child(_status_text)
	var mode_row := HBoxContainer.new()
	status.add_child(mode_row)
	var mode_label := Label.new()
	mode_label.text = "Godot tools mode"
	mode_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_row.add_child(mode_label)
	_integration_mode = OptionButton.new()
	_integration_mode.add_item("MCP compatibility", 0)
	_integration_mode.add_item("Native plugin", 1)
	_integration_mode.tooltip_text = "Native mode requires an attested bundled plugin. MCP remains the explicit rollback mode."
	mode_row.add_child(_integration_mode)
	_apply_integration_mode = Button.new()
	_apply_integration_mode.text = "Restart"
	_apply_integration_mode.tooltip_text = "Cancel local requests, stop the current owner, rotate bridge credentials, and restart in the selected mode."
	_apply_integration_mode.pressed.connect(_on_apply_integration_mode)
	mode_row.add_child(_apply_integration_mode)
	_refresh_status()


func _on_apply_integration_mode() -> void:
	if _integration_mode == null:
		return
	integration_mode_requested.emit("native" if _integration_mode.selected == 1 else "mcp")


func _bind_sources() -> void:
	if _bound or not is_node_ready() or not is_instance_valid(_api):
		return
	_bound = true
	_connect_if_present(_api, "daemon_state_changed", _on_daemon_state_changed)
	_connect_if_present(_api, "sessions_changed", _on_sessions_changed)
	_connect_if_present(_api, "session_changed", _on_session_changed)
	_connect_if_present(_api, "history_reloaded", _on_history_reloaded)
	_connect_if_present(_api, "assistant_output", _on_assistant_output)
	_connect_if_present(_api, "tool_activity", _on_tool_activity)
	_connect_if_present(_api, "permission_pending", _on_permission_pending)
	_connect_if_present(_api, "question_pending", _on_question_pending)
	_connect_if_present(_api, "request_state_changed", _on_request_state_changed)
	_connect_if_present(_api, "request_completed", _on_request_completed)
	_connect_if_present(_api, "interaction_response_completed", _on_interaction_response_completed)
	_connect_if_present(_api, "interaction_response_failed", _on_interaction_response_failed)
	_connect_if_present(_api, "api_error", _on_api_error)
	_connect_if_present(_api, "diagnostic", show_diagnostic)
	if _lifecycle != null:
		_connect_if_present(_lifecycle, "daemon_ready", _on_daemon_ready)
		_connect_if_present(_lifecycle, "daemon_stopped", _on_daemon_stopped)
		_connect_if_present(_lifecycle, "state_changed", set_lifecycle_state)
		_connect_if_present(_lifecycle, "diagnostic", show_diagnostic)
		if _lifecycle.has_method("get_status"):
			var status: Dictionary = _lifecycle.get_status()
			set_lifecycle_state(String(status.get("state", "unknown")), String(status.get("detail", "")))


func _unbind_sources() -> void:
	if not _bound:
		return
	_disconnect_if_present(_api, "daemon_state_changed", _on_daemon_state_changed)
	_disconnect_if_present(_api, "sessions_changed", _on_sessions_changed)
	_disconnect_if_present(_api, "session_changed", _on_session_changed)
	_disconnect_if_present(_api, "history_reloaded", _on_history_reloaded)
	_disconnect_if_present(_api, "assistant_output", _on_assistant_output)
	_disconnect_if_present(_api, "tool_activity", _on_tool_activity)
	_disconnect_if_present(_api, "permission_pending", _on_permission_pending)
	_disconnect_if_present(_api, "question_pending", _on_question_pending)
	_disconnect_if_present(_api, "request_state_changed", _on_request_state_changed)
	_disconnect_if_present(_api, "request_completed", _on_request_completed)
	_disconnect_if_present(_api, "interaction_response_completed", _on_interaction_response_completed)
	_disconnect_if_present(_api, "interaction_response_failed", _on_interaction_response_failed)
	_disconnect_if_present(_api, "api_error", _on_api_error)
	_disconnect_if_present(_api, "diagnostic", show_diagnostic)
	_disconnect_if_present(_lifecycle, "daemon_ready", _on_daemon_ready)
	_disconnect_if_present(_lifecycle, "daemon_stopped", _on_daemon_stopped)
	_disconnect_if_present(_lifecycle, "state_changed", set_lifecycle_state)
	_disconnect_if_present(_lifecycle, "diagnostic", show_diagnostic)
	_bound = false


func _connect_if_present(source: Object, signal_name: StringName, target: Callable) -> void:
	if source.has_signal(signal_name) and not source.is_connected(signal_name, target):
		source.connect(signal_name, target)


func _disconnect_if_present(source: Object, signal_name: StringName, target: Callable) -> void:
	if is_instance_valid(source) and source.has_signal(signal_name) and source.is_connected(signal_name, target):
		source.disconnect(signal_name, target)


func _on_daemon_ready(base_url: String, password: String, generation: int) -> void:
	if _api.configure_daemon(base_url, password, generation):
		_summary.text = "Authenticating OpenCode…"


func _on_daemon_stopped(_generation: int) -> void:
	if is_instance_valid(_api) and _api.has_method("shutdown_transport"):
		_api.shutdown_transport()
	_set_chat_enabled(false)
	_reset_transport_interaction_state()


func _on_daemon_state_changed(ready: bool, detail: String) -> void:
	_summary.text = detail
	_set_chat_enabled(ready)
	if not ready:
		_reset_transport_interaction_state()


func _on_sessions_changed(sessions: Array) -> void:
	var selected_id := String(_api.active_session_id) if is_instance_valid(_api) else ""
	if _sessions.selected >= 0:
		var visible_id := String(_sessions.get_item_metadata(_sessions.selected))
		if selected_id.is_empty():
			selected_id = visible_id
	_sessions.clear()
	var selected_index := -1
	for session in sessions:
		if not session is Dictionary:
			continue
		var session_id := String(session.get("id", ""))
		if session_id.is_empty():
			continue
		var title := String(session.get("title", session_id))
		_sessions.add_item(title if not title.is_empty() else session_id)
		var index := _sessions.item_count - 1
		_sessions.set_item_metadata(index, session_id)
		if session_id == selected_id:
			selected_index = index
	if selected_index < 0 and _sessions.item_count > 0:
		selected_index = 0
	if selected_index >= 0:
		_sessions.select(selected_index)
		var resolved_id := String(_sessions.get_item_metadata(selected_index))
		if is_instance_valid(_api) and String(_api.active_session_id) != resolved_id:
			_api.select_session(resolved_id)
	_sessions.disabled = _sessions.item_count == 0


func _on_session_changed(session_id: String) -> void:
	for index in range(_sessions.item_count):
		if String(_sessions.get_item_metadata(index)) == session_id:
			_sessions.select(index)
			break
	_reset_transcript("[color=gray]Loading session history...[/color]\n")
	_busy = bool(_api.active_request) and String(_api._active_request_session_id) == session_id
	_cancel.disabled = not _busy
	_send.disabled = _busy or not _prompt.editable
	_render_next_permission()
	_render_next_question()


func _on_history_reloaded(session_id: String, events: Array) -> void:
	if not is_instance_valid(_api) or session_id != String(_api.active_session_id):
		return
	_reset_transcript()
	for event in events:
		if not event is Dictionary:
			continue
		var data: Dictionary = event.get("data", {})
		match String(event.get("type", "")):
			"session.next.prompted", "session.next.prompt.admitted":
				var prompt: Dictionary = data.get("prompt", {})
				_append_message("You", String(prompt.get("text", "")), "8ecae6")
			"session.next.text.ended":
				_append_message("OpenCode", String(data.get("text", "")), "a6e3a1")
			_:
				if String(event.get("type", "")).begins_with("session.next.tool"):
					_on_tool_activity(String(data.get("sessionID", "")), {"type": event.get("type", "tool"), "data": data})



func _on_assistant_output(session_id: String, text: String, replace: bool) -> void:
	if not is_instance_valid(_api) or session_id != String(_api.active_session_id):
		return
	if text.is_empty():
		return
	if replace:
		_streaming_assistant_text = ""
		_streaming_assistant_session = ""
		_append_message("OpenCode", text, "a6e3a1")
	else:
		if not _streaming_assistant_session.is_empty() and _streaming_assistant_session != session_id:
			_commit_streaming_assistant()
		_streaming_assistant_session = session_id
		_streaming_assistant_text += text
		_render_transcript()


func _on_tool_activity(session_id: String, activity: Dictionary) -> void:
	if not is_instance_valid(_api) or session_id != String(_api.active_session_id):
		return
	_commit_streaming_assistant()
	var data: Dictionary = activity.get("data", {})
	var tool_name := String(data.get("tool", data.get("name", "tool")))
	var activity_type := String(activity.get("type", "tool"))
	var state := activity_type.get_slice(".", activity_type.get_slice_count(".") - 1)
	_transcript_content += "\n[color=gray]Tool %s - %s[/color]\n" % [_escape_bbcode(tool_name), _escape_bbcode(state)]
	_render_transcript()


func _on_permission_pending(session_id: String, request: Dictionary) -> void:
	var request_id := String(request.get("id", ""))
	if request_id.is_empty() or session_id.is_empty():
		show_diagnostic("permission", "Ignored a permission prompt without session/request identity")
		return
	var pending := request.duplicate(true)
	pending["_session_id"] = session_id
	pending["_key"] = _interaction_key(session_id, request_id)
	# Snapshot recovery may repeat the same prompt while its reply is in flight.
	# Keep that state so a second UI action cannot submit a duplicate answer.
	if _pending_permissions_by_key.has(pending["_key"]):
		pending["_submitting"] = bool(_pending_permissions_by_key[pending["_key"]].get("_submitting", false))
	else:
		pending["_submitting"] = false
	_pending_permissions_by_key[pending["_key"]] = pending
	_render_next_permission()


func _on_question_pending(session_id: String, request: Dictionary) -> void:
	var request_id := String(request.get("id", ""))
	if request_id.is_empty() or session_id.is_empty():
		show_diagnostic("question", "Ignored a question prompt without session/request identity")
		return
	var pending := request.duplicate(true)
	pending["_session_id"] = session_id
	pending["_key"] = _interaction_key(session_id, request_id)
	if _pending_questions_by_key.has(pending["_key"]):
		pending["_submitting"] = bool(_pending_questions_by_key[pending["_key"]].get("_submitting", false))
	else:
		pending["_submitting"] = false
	_pending_questions_by_key[pending["_key"]] = pending
	_render_next_question()


func _render_next_permission() -> void:
	_pending_permission = _next_interaction(_pending_permissions_by_key)
	if _pending_permission.is_empty():
		_permission_panel.visible = false
		return
	var resources: Array[String] = []
	for resource in _pending_permission.get("resources", []):
		resources.append(String(resource))
	_permission_text.text = "OpenCode requests permission: %s\n%s" % [_pending_permission.get("action", _pending_permission.get("permission", "unknown")), ", ".join(resources)]
	_permission_panel.visible = true


func _render_next_question() -> void:
	_pending_question = _next_interaction(_pending_questions_by_key)
	if _pending_question.is_empty():
		_question_panel.visible = false
		return
	_question_text.text = "OpenCode needs an explicit answer"
	for child in _question_inputs.get_children():
		child.queue_free()
	_question_lists.clear()
	_question_custom.clear()
	for question in _pending_question.get("questions", []):
		if not question is Dictionary:
			continue
		var label := Label.new()
		label.text = "%s — %s" % [question.get("header", "Question"), question.get("question", "")]
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_question_inputs.add_child(label)
		var choices := ItemList.new()
		choices.custom_minimum_size.y = 72
		choices.select_mode = ItemList.SELECT_MULTI if question.get("multiple", false) else ItemList.SELECT_SINGLE
		for option in question.get("options", []):
			if option is Dictionary:
				choices.add_item(String(option.get("label", "")))
		_question_inputs.add_child(choices)
		_question_lists.append(choices)
		var custom := LineEdit.new()
		custom.placeholder_text = "Custom answer (optional)"
		custom.visible = bool(question.get("custom", true))
		_question_inputs.add_child(custom)
		_question_custom.append(custom)
	_question_panel.visible = true


func _on_request_state_changed(session_id: String, active: bool, detail: String) -> void:
	if not is_instance_valid(_api) or session_id != String(_api.active_session_id):
		return
	_busy = active
	_send.disabled = active or not _prompt.editable
	_cancel.disabled = not active
	_summary.text = detail


func _on_request_completed(session_id: String, state: String) -> void:
	if not is_instance_valid(_api) or session_id != String(_api.active_session_id):
		return
	_busy = false
	_cancel.disabled = true
	_send.disabled = not _prompt.editable
	_summary.text = "Request %s" % state


func _on_api_error(category: String, detail: String) -> void:
	show_diagnostic(category, detail)
	_summary.text = "%s: %s" % [category, detail]


func _on_session_selected(index: int) -> void:
	var session_id := String(_sessions.get_item_metadata(index))
	if not session_id.is_empty():
		_api.select_session(session_id)


func _on_new_session() -> void:
	_api.create_session()


func _on_refresh_sessions() -> void:
	_api.list_sessions()


func _on_send() -> void:
	var text := _prompt.text
	if text.strip_edges().is_empty():
		return
	_prompt.clear()
	_append_message("You", text, "8ecae6")
	_api.send_prompt(text)


func _on_cancel() -> void:
	_api.cancel_active()


func _on_permission_reply(choice: String) -> void:
	var request_id := String(_pending_permission.get("id", ""))
	if request_id.is_empty() or bool(_pending_permission.get("_submitting", false)):
		return
	_pending_permission["_submitting"] = true
	_pending_permissions_by_key[String(_pending_permission.get("_key", ""))] = _pending_permission
	_api.reply_permission(request_id, choice, "", String(_pending_permission.get("_session_id", "")))


func _on_question_answer() -> void:
	var answers: Array = []
	for index in range(_question_lists.size()):
		var values: Array[String] = []
		for selected in _question_lists[index].get_selected_items():
			values.append(_question_lists[index].get_item_text(selected))
		var custom := _question_custom[index].text.strip_edges()
		if not custom.is_empty():
			values.append(custom)
		answers.append(values)
	var request_id := String(_pending_question.get("id", ""))
	if request_id.is_empty() or bool(_pending_question.get("_submitting", false)):
		return
	_pending_question["_submitting"] = true
	_pending_questions_by_key[String(_pending_question.get("_key", ""))] = _pending_question
	_api.answer_question(request_id, answers, String(_pending_question.get("_session_id", "")))


func _on_question_reject() -> void:
	var request_id := String(_pending_question.get("id", ""))
	if request_id.is_empty() or bool(_pending_question.get("_submitting", false)):
		return
	_pending_question["_submitting"] = true
	_pending_questions_by_key[String(_pending_question.get("_key", ""))] = _pending_question
	_api.reject_question(request_id, String(_pending_question.get("_session_id", "")))


func _on_interaction_response_completed(operation: String, session_id: String, request_id: String) -> void:
	var key := _interaction_key(session_id, request_id)
	if operation.begins_with("permission"):
		_pending_permissions_by_key.erase(key)
		_render_next_permission()
	else:
		_pending_questions_by_key.erase(key)
		_render_next_question()


func _on_interaction_response_failed(operation: String, session_id: String, request_id: String, _detail: String) -> void:
	var key := _interaction_key(session_id, request_id)
	var queue: Dictionary = _pending_permissions_by_key if operation.begins_with("permission") else _pending_questions_by_key
	if queue.has(key):
		var pending: Dictionary = queue[key]
		pending["_submitting"] = false
		queue[key] = pending
	if operation.begins_with("permission"):
		_render_next_permission()
	else:
		_render_next_question()


func _interaction_key(session_id: String, request_id: String) -> String:
	return session_id + "\u001f" + request_id


func _next_interaction(queue: Dictionary) -> Dictionary:
	var active := String(_api.active_session_id) if is_instance_valid(_api) else ""
	for key in queue:
		var candidate: Variant = queue[key]
		if candidate is Dictionary and String(candidate.get("_session_id", "")) == active:
			return candidate.duplicate(true)
	for key in queue:
		var candidate: Variant = queue[key]
		if candidate is Dictionary:
			return candidate.duplicate(true)
	return {}


func _set_chat_enabled(enabled: bool) -> void:
	if _prompt == null or _send == null:
		return
	_prompt.editable = enabled
	_send.disabled = not enabled or _busy
	if _new_session != null:
		_new_session.disabled = not enabled
	if _refresh_sessions != null:
		_refresh_sessions.disabled = not enabled
	if _sessions != null:
		_sessions.disabled = not enabled or _sessions.item_count == 0
	if enabled:
		_summary.text = "OpenCode ready"


func _reset_transport_interaction_state() -> void:
	# A daemon replacement or credential rejection cancels in-flight HTTP calls.
	# Permission and question IDs are daemon-generation scoped: retaining them
	# would expose offline controls and could submit an answer to a reused ID in
	# the replacement daemon. The authenticated pending snapshots restore only
	# the new daemon's authoritative interactions after reconnect.
	_busy = false
	if _cancel != null:
		_cancel.disabled = true
	_pending_permission.clear()
	_pending_question.clear()
	_pending_permissions_by_key.clear()
	_pending_questions_by_key.clear()
	_render_next_permission()
	_render_next_question()


func _append_message(author: String, text: String, color: String) -> void:
	if text.is_empty():
		return
	_transcript_content += "\n[color=#%s][b]%s[/b][/color]\n%s\n" % [color, _escape_bbcode(author), _escape_bbcode(text)]
	_render_transcript()


func _commit_streaming_assistant() -> void:
	if _streaming_assistant_text.is_empty():
		return
	var text := _streaming_assistant_text
	_streaming_assistant_text = ""
	_streaming_assistant_session = ""
	_transcript_content += "\n[color=#a6e3a1][b]OpenCode[/b][/color]\n%s\n" % _escape_bbcode(text)
	_render_transcript()


func _reset_transcript(initial_bbcode: String = "") -> void:
	_transcript_content = initial_bbcode
	_streaming_assistant_text = ""
	_streaming_assistant_session = ""
	_render_transcript()


func _render_transcript() -> void:
	if _transcript == null:
		return
	var streaming := ""
	if not _streaming_assistant_text.is_empty():
		streaming = "\n[color=#a6e3a1][b]OpenCode[/b][/color]\n%s" % _escape_bbcode(_streaming_assistant_text)
	_transcript.text = _transcript_content + streaming


func _escape_bbcode(value: String) -> String:
	return value.replace("[", "[lb]")


func _refresh_status() -> void:
	if _status_text == null:
		return
	var mode_line := ""
	if _lifecycle != null and _lifecycle.has_method("get_status"):
		var status: Dictionary = _lifecycle.get_status()
		mode_line = "Godot tools mode: %s%s" % [String(status.get("integration_mode", "mcp")), " (requested %s)" % String(status.get("requested_integration_mode")) if not String(status.get("requested_integration_mode", "")).is_empty() else ""]
	var header := "[b]%s[/b]\n%s\n%s\n%s\n\n" % [_escape_bbcode(_daemon_status), _escape_bbcode(_bridge_status), _escape_bbcode(_tools_status), _escape_bbcode(mode_line)]
	var lines: Array[String] = []
	for entry in _diagnostics:
		lines.append("[color=gray]%s[/color]" % _escape_bbcode(entry))
	_status_text.text = header + "\n".join(lines)


func _append_status(message: String) -> void:
	_diagnostics.append(message)
	if _diagnostics.size() > 100:
		_diagnostics.pop_front()
	if _status_text != null:
		_refresh_status()
