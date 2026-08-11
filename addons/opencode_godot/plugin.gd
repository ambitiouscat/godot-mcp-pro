@tool
extends EditorPlugin

const RuntimePaths := preload("res://addons/opencode_godot/engine_bridge/runtime/runtime_paths.gd")

## The unified addon is the only owner of the command router and bridge. The
## dock remains visible when a preflight or daemon problem occurs so recovery is
## actionable rather than a silent missing panel.

var websocket_server: Node
var command_router: Node
var bridge_session: RefCounted
var runtime_service_controller: RefCounted
var lifecycle: RefCounted
var api_client: Node
var dock: Control
var _debugger_flag_path := ""


func _enter_tree() -> void:
	_create_dock_and_client()
	if EditorInterface.is_plugin_enabled("godot_mcp"):
		_report_preflight_error("Legacy Godot MCP Pro is enabled. Disable 'godot_mcp' before enabling OpenCode for Godot; only one authenticated bridge may own this project.")
		return
	_start_unified_bridge()


func _exit_tree() -> void:
	_stop_owned_components()
	if is_instance_valid(dock):
		remove_control_from_docks(dock)
		dock.queue_free()


func _process(_delta: float) -> void:
	if lifecycle != null:
		lifecycle.update()
	if runtime_service_controller != null:
		runtime_service_controller.update_game_state()
	if not _debugger_flag_path.is_empty() and FileAccess.file_exists(_debugger_flag_path):
		# Consume the one-shot request before touching editor UI. A runtime error
		# must never leave a stale flag that resumes a later, unrelated pause.
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_debugger_flag_path))
		_try_debugger_continue()


func _try_debugger_continue() -> void:
	var debugger := _find_script_editor_debugger()
	if debugger == null:
		return
	var base := EditorInterface.get_base_control()
	var continue_icon: Texture2D = null
	if base != null and base.has_theme_icon("DebugContinue", "EditorIcons"):
		continue_icon = base.get_theme_icon("DebugContinue", "EditorIcons")
	var fallback: Button = null
	var queue: Array[Node] = [debugger]
	while not queue.is_empty():
		var node := queue.pop_front()
		if node is Button:
			var button := node as Button
			if continue_icon != null and button.icon == continue_icon:
				if button.visible and not button.disabled:
					button.emit_signal("pressed")
					push_warning("[OpenCode] Auto-pressed debugger Continue button")
					return
			if fallback == null and button.tooltip_text == "Continue":
				fallback = button
		for child in node.get_children():
			queue.append(child)
	if fallback != null and fallback.visible and not fallback.disabled:
		fallback.emit_signal("pressed")
		push_warning("[OpenCode] Auto-pressed debugger Continue button")


func _find_script_editor_debugger() -> Node:
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	var queue: Array[Node] = [base]
	while not queue.is_empty():
		var node := queue.pop_front()
		if node.get_class() == "ScriptEditorDebugger":
			return node
		for child in node.get_children():
			queue.append(child)
	return null


func _create_dock_and_client() -> void:
	var dock_script := load("res://addons/opencode_godot/ui/opencode_dock.gd")
	if dock_script is Script:
		dock = (dock_script as Script).new()
		dock.name = "OpenCode"
		add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	else:
		push_error("[OpenCode] The native dock script is missing from the addon.")
	var client_script := load("res://addons/opencode_godot/client/opencode_api_client.gd")
	if client_script is Script:
		api_client = (client_script as Script).new()
		add_child(api_client)
		var canonical_project := preload("res://addons/opencode_godot/engine_bridge/bridge_protocol_v1.gd").canonicalize_project_path(ProjectSettings.globalize_path("res://"))
		if api_client.has_method("setup"):
			api_client.setup(canonical_project)
	else:
		push_error("[OpenCode] The HTTP/SSE client script is missing from the addon.")


func _start_unified_bridge() -> void:
	bridge_session = preload("res://addons/opencode_godot/engine_bridge/bridge_session_coordinator.gd").new()
	if not bridge_session.start_session():
		_report_preflight_error("Authenticated bridge startup failed: %s" % bridge_session.last_error)
		return
	runtime_service_controller = preload("res://addons/opencode_godot/engine_bridge/runtime/runtime_service_controller.gd").new()
	runtime_service_controller.setup(self, bridge_session.owner_nonce)
	_debugger_flag_path = RuntimePaths.file(RuntimePaths.DEBUGGER_CONTINUE)
	command_router = preload("res://addons/opencode_godot/engine_bridge/command_router.gd").new()
	command_router.name = "OpenCodeGodotCommandRouter"
	command_router.editor_plugin = self
	add_child(command_router)
	websocket_server = preload("res://addons/opencode_godot/engine_bridge/websocket_server.gd").new()
	websocket_server.name = "OpenCodeGodotWebSocketServer"
	websocket_server.command_router = command_router
	websocket_server.session_coordinator = bridge_session
	add_child(websocket_server)
	command_router.configure_bridge_context(bridge_session.project_path, websocket_server.is_session_ready, runtime_service_controller)
	websocket_server.start_server(bridge_session)
	lifecycle = preload("res://addons/opencode_godot/process/opencode_daemon_lifecycle.gd").new()
	lifecycle.setup(bridge_session, websocket_server)
	lifecycle.diagnostic.connect(_on_lifecycle_diagnostic)
	lifecycle.state_changed.connect(_on_lifecycle_state_changed)
	if is_instance_valid(dock) and dock.has_method("setup"):
		dock.setup(lifecycle, api_client, websocket_server)
		if dock.has_signal("integration_mode_requested") and not dock.is_connected("integration_mode_requested", _on_integration_mode_requested):
			dock.connect("integration_mode_requested", _on_integration_mode_requested)
	var result: Dictionary = lifecycle.start()
	if not result.get("ok", false):
		_report_preflight_error(str(result.get("error", "OpenCode daemon startup failed.")))


func _on_integration_mode_requested(mode: String) -> void:
	var requested := mode.to_lower().strip_edges()
	if requested not in ["mcp", "native"]:
		_report_preflight_error("Integration mode must be 'mcp' or 'native'.")
		return
	if lifecycle == null:
		_report_preflight_error("Integration mode cannot change before lifecycle startup.")
		return
	var lifecycle_status: Dictionary = lifecycle.get_status() if lifecycle.has_method("get_status") else {}
	var persisted_request := str(lifecycle_status.get("requested_integration_mode", ""))
	var lifecycle_state := str(lifecycle_status.get("state", ""))
	if (
		requested == lifecycle.get_integration_mode()
		and persisted_request in ["", requested]
		and lifecycle_state in ["starting", "probing", "ready", "backoff"]
	):
		_on_lifecycle_diagnostic("integration-mode", "Integration mode is already %s; no restart was required." % requested)
		return
	# Immediately detach streams and local request state. The daemon is then
	# stopped before any bridge/session artifact is changed.
	if is_instance_valid(api_client) and api_client.has_method("shutdown_transport"):
		api_client.shutdown_transport()
	if lifecycle != null:
		lifecycle.stop()
	if lifecycle == null or lifecycle.state != "stopped":
		_on_lifecycle_diagnostic("integration-mode", "Mode switch stopped fail-closed: old daemon ownership or provider cleanup could not be verified. Evidence was preserved; no replacement was started.")
		return
	if is_instance_valid(websocket_server):
		websocket_server.stop_server()
	if runtime_service_controller != null:
		runtime_service_controller.cleanup_owned_services()
	if bridge_session != null:
		bridge_session.stop_session()
	if bridge_session != null and (FileAccess.file_exists(bridge_session.discovery_path) or FileAccess.file_exists(bridge_session.session_path) or FileAccess.file_exists(bridge_session.token_path)):
		_on_lifecycle_diagnostic("integration-mode", "Mode switch stopped fail-closed: previous bridge discovery or protected session cleanup could not be verified. No replacement was started.")
		return
	var persisted: Dictionary = lifecycle.set_requested_integration_mode(requested)
	if not persisted.get("ok", false):
		_on_lifecycle_diagnostic("integration-mode", str(persisted.get("error", "Could not persist integration mode.")))
		return
	if is_instance_valid(command_router):
		if command_router.get_parent() != null:
			command_router.get_parent().remove_child(command_router)
		command_router.queue_free()
	if is_instance_valid(websocket_server):
		if websocket_server.get_parent() != null:
			websocket_server.get_parent().remove_child(websocket_server)
		websocket_server.queue_free()
	command_router = null
	websocket_server = null
	runtime_service_controller = null
	bridge_session = null
	lifecycle = null
	_start_unified_bridge()


func _stop_owned_components() -> void:
	# API hooks first: no late HTTP/SSE callback may reach editor-owned state.
	if is_instance_valid(api_client) and api_client.has_method("shutdown"):
		api_client.shutdown()
	if lifecycle != null:
		lifecycle.stop()
	if is_instance_valid(websocket_server):
		websocket_server.stop_server()
	if runtime_service_controller != null:
		runtime_service_controller.cleanup_owned_services()
	if bridge_session != null:
		bridge_session.stop_session()
	if is_instance_valid(command_router):
		command_router.queue_free()
	if is_instance_valid(websocket_server):
		websocket_server.queue_free()


func _on_lifecycle_diagnostic(category: String, message: String) -> void:
	push_warning("[OpenCode][%s] %s" % [category, message])
	if is_instance_valid(dock) and dock.has_method("show_diagnostic"):
		dock.show_diagnostic(category, message)


func _on_lifecycle_state_changed(state: String, message: String) -> void:
	if is_instance_valid(dock) and dock.has_method("set_lifecycle_state"):
		dock.set_lifecycle_state(state, message)


func _report_preflight_error(message: String) -> void:
	push_error("[OpenCode] %s" % message)
	if is_instance_valid(dock) and dock.has_method("show_diagnostic"):
		dock.show_diagnostic("preflight", message)
