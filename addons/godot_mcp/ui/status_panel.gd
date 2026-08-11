@tool
extends VBoxContainer

const MAX_LOG_ENTRIES := 200
const COLOR_READY := Color(0.2, 0.9, 0.2)
const COLOR_WAITING := Color(1.0, 0.7, 0.2)
const COLOR_STOPPED := Color(0.9, 0.2, 0.2)
const COLOR_SUCCESS := Color(0.6, 1.0, 0.6)
const COLOR_ERROR := Color(1.0, 0.6, 0.6)
const COLOR_DIM := Color(0.6, 0.6, 0.6)

var websocket_server: Node
var command_router: Node

var _status_icon: Label
var _status_label: Label
var _client_count_label: Label
var _bridge_state_label: Label
var _bridge_detail_label: Label
var _endpoint_label: Label
var _retry_label: Label
var _show_details_check: CheckBox
var _log_container: VBoxContainer
var _log_scroll: ScrollContainer
var _filter_edit: LineEdit
var _tools_container: VBoxContainer
var _tool_checkboxes: Dictionary = {}


func _ready() -> void:
	_build_ui()


func setup(ws_server: Node, cmd_router: Node = null) -> void:
	_disconnect_server_signals()
	websocket_server = ws_server
	command_router = cmd_router
	if is_instance_valid(websocket_server):
		websocket_server.client_connected.connect(_on_client_connected)
		websocket_server.client_disconnected.connect(_on_client_disconnected)
		websocket_server.command_completed.connect(_on_command_completed)
		websocket_server.state_changed.connect(_on_state_changed)
	if is_instance_valid(command_router):
		_populate_tools_list()


func _exit_tree() -> void:
	_disconnect_server_signals()


func _disconnect_server_signals() -> void:
	if not is_instance_valid(websocket_server):
		return
	var connections: Array = [
		["client_connected", _on_client_connected],
		["client_disconnected", _on_client_disconnected],
		["command_completed", _on_command_completed],
		["state_changed", _on_state_changed],
	]
	for connection: Array in connections:
		var signal_name: StringName = connection[0]
		var callback: Callable = connection[1]
		if websocket_server.has_signal(signal_name) and websocket_server.is_connected(signal_name, callback):
			websocket_server.disconnect(signal_name, callback)


func _build_ui() -> void:
	var header := HBoxContainer.new()
	add_child(header)

	_status_icon = Label.new()
	_status_icon.text = "●"
	_status_icon.add_theme_color_override("font_color", COLOR_STOPPED)
	header.add_child(_status_icon)

	_status_label = Label.new()
	_status_label.text = " MCP Pro: Starting"
	header.add_child(_status_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_client_count_label = Label.new()
	_client_count_label.text = "Sessions: 0"
	header.add_child(_client_count_label)

	add_child(HSeparator.new())
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)
	_build_activity_tab(tabs)
	_build_bridge_tab(tabs)
	_build_tools_tab(tabs)


func _build_activity_tab(tabs: TabContainer) -> void:
	var root := VBoxContainer.new()
	root.name = "Activity"
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_child(root)

	var controls := HBoxContainer.new()
	root.add_child(controls)
	_show_details_check = CheckBox.new()
	_show_details_check.text = "Show Response Details"
	_show_details_check.toggled.connect(_on_show_details_toggled)
	controls.add_child(_show_details_check)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(spacer)
	var clear_button := Button.new()
	clear_button.text = "Clear"
	clear_button.pressed.connect(_on_clear_log)
	controls.add_child(clear_button)

	_log_scroll = ScrollContainer.new()
	_log_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_scroll.custom_minimum_size.y = 80.0
	root.add_child(_log_scroll)
	_log_container = VBoxContainer.new()
	_log_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_scroll.add_child(_log_container)


func _build_bridge_tab(tabs: TabContainer) -> void:
	var root := VBoxContainer.new()
	root.name = "Bridge"
	tabs.add_child(root)
	_bridge_state_label = Label.new()
	_bridge_state_label.text = "State: STOPPED"
	root.add_child(_bridge_state_label)
	_bridge_detail_label = Label.new()
	_bridge_detail_label.text = "Detail: Waiting for bridge startup"
	_bridge_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_bridge_detail_label)
	_endpoint_label = Label.new()
	_endpoint_label.text = "Endpoint: not discovered"
	_endpoint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_endpoint_label)
	_retry_label = Label.new()
	_retry_label.text = "Retry: -"
	root.add_child(_retry_label)


func _build_tools_tab(tabs: TabContainer) -> void:
	var root := VBoxContainer.new()
	root.name = "Tools"
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_child(root)
	var controls := HBoxContainer.new()
	root.add_child(controls)
	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "Filter tools..."
	_filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter_edit.text_changed.connect(_on_filter_changed)
	controls.add_child(_filter_edit)
	var enable_all_button := Button.new()
	enable_all_button.text = "Enable All"
	enable_all_button.pressed.connect(_on_enable_all)
	controls.add_child(enable_all_button)
	var disable_all_button := Button.new()
	disable_all_button.text = "Disable All"
	disable_all_button.pressed.connect(_on_disable_all)
	controls.add_child(disable_all_button)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 80.0
	root.add_child(scroll)
	_tools_container = VBoxContainer.new()
	_tools_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_tools_container)


func _process(_delta: float) -> void:
	if not is_instance_valid(websocket_server):
		return
	var state: String = websocket_server.get_state_name()
	var detail: String = websocket_server.get_state_detail()
	var endpoint: String = websocket_server.get_endpoint()
	var sessions: int = websocket_server.get_client_count()
	_client_count_label.text = "Sessions: %d" % sessions
	_bridge_state_label.text = "State: %s" % state
	_bridge_detail_label.text = "Detail: %s" % detail
	_endpoint_label.text = "Endpoint: %s" % (endpoint if not endpoint.is_empty() else "not discovered")
	var retry_seconds: float = websocket_server.get_retry_seconds()
	_retry_label.text = "Retry: %.2fs" % retry_seconds if retry_seconds > 0.0 else "Retry: -"
	_apply_state_style(state)


func _apply_state_style(state: String) -> void:
	if state == "READY":
		_status_icon.add_theme_color_override("font_color", COLOR_READY)
		_status_label.text = " MCP Pro: Authenticated and ready"
	elif state in ["DISCOVERING", "CONNECTING", "HANDSHAKING", "CLOSING", "BACKOFF"]:
		_status_icon.add_theme_color_override("font_color", COLOR_WAITING)
		_status_label.text = " MCP Pro: %s" % state.capitalize()
	else:
		_status_icon.add_theme_color_override("font_color", COLOR_STOPPED)
		_status_label.text = " MCP Pro: Stopped"


func _on_state_changed(state: String, detail: String) -> void:
	_add_log("Bridge %s: %s" % [state, detail], COLOR_READY if state == "READY" else COLOR_WAITING)


func _on_client_connected() -> void:
	_add_log("Authenticated bridge session connected", COLOR_READY)


func _on_client_disconnected() -> void:
	_add_log("Bridge session disconnected", COLOR_STOPPED)


func _on_command_completed(method: String, ok: bool, response: String, source_port: int) -> void:
	var status_text := "OK" if ok else "ERR"
	var endpoint_text: String = websocket_server.get_endpoint() if is_instance_valid(websocket_server) else "port %d" % source_port
	_add_log("[%s] %s (%s)" % [status_text, method, endpoint_text], COLOR_SUCCESS if ok else COLOR_ERROR, response)


func _on_clear_log() -> void:
	for child: Node in _log_container.get_children():
		child.queue_free()


func _on_show_details_toggled(enabled: bool) -> void:
	for entry: Node in _log_container.get_children():
		if entry is VBoxContainer and entry.get_child_count() > 1:
			entry.get_child(1).visible = enabled


func _add_log(text: String, color: Color = Color.WHITE, response: String = "") -> void:
	if not is_instance_valid(_log_container):
		return
	var entry := VBoxContainer.new()
	_log_container.add_child(entry)
	var label := Label.new()
	label.text = "[%s] %s" % [Time.get_time_string_from_system(), text]
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 12)
	entry.add_child(label)
	if not response.is_empty():
		var detail := RichTextLabel.new()
		detail.text = response.left(500) + ("..." if response.length() > 500 else "")
		detail.fit_content = true
		detail.scroll_active = false
		detail.add_theme_color_override("default_color", COLOR_DIM)
		detail.add_theme_font_size_override("normal_font_size", 11)
		detail.visible = _show_details_check.button_pressed
		entry.add_child(detail)
	while _log_container.get_child_count() > MAX_LOG_ENTRIES:
		var oldest := _log_container.get_child(0)
		_log_container.remove_child(oldest)
		oldest.queue_free()
	_auto_scroll.call_deferred()


func _auto_scroll() -> void:
	if is_instance_valid(_log_scroll):
		_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)


func _populate_tools_list() -> void:
	for child: Node in _tools_container.get_children():
		child.queue_free()
	_tool_checkboxes.clear()
	var methods: Array = command_router.get_available_methods()
	methods.sort()
	for method_name: String in methods:
		var checkbox := CheckBox.new()
		checkbox.text = method_name
		checkbox.button_pressed = not command_router.is_tool_disabled(method_name)
		checkbox.toggled.connect(_on_tool_toggled.bind(method_name))
		_tools_container.add_child(checkbox)
		_tool_checkboxes[method_name] = checkbox


func _on_filter_changed(filter_text: String) -> void:
	for method_name: String in _tool_checkboxes:
		var checkbox: CheckBox = _tool_checkboxes[method_name]
		checkbox.visible = filter_text.is_empty() or method_name.containsn(filter_text)


func _on_tool_toggled(enabled: bool, method_name: String) -> void:
	if is_instance_valid(command_router):
		var result: Dictionary = command_router.set_tool_disabled(method_name, not enabled)
		if not result.get("ok", false):
			var checkbox: CheckBox = _tool_checkboxes[method_name]
			checkbox.set_pressed_no_signal(not enabled)
			_add_log("Could not change %s: %s" % [method_name, result.get("error", {})], COLOR_ERROR)


func _on_enable_all() -> void:
	if is_instance_valid(command_router):
		var result: Dictionary = command_router.set_all_tools_disabled(false)
		if not result.get("ok", false):
			_add_log("Could not enable all tools: %s" % result.get("error", {}), COLOR_ERROR)
			_populate_tools_list()
			return
	for method_name: String in _tool_checkboxes:
		_tool_checkboxes[method_name].set_pressed_no_signal(true)


func _on_disable_all() -> void:
	if is_instance_valid(command_router):
		var result: Dictionary = command_router.set_all_tools_disabled(true)
		if not result.get("ok", false):
			_add_log("Could not disable all tools: %s" % result.get("error", {}), COLOR_ERROR)
			_populate_tools_list()
			return
	for method_name: String in _tool_checkboxes:
		_tool_checkboxes[method_name].set_pressed_no_signal(false)
