@tool
extends EditorPlugin

var websocket_server: Node
var command_router: Node
var status_panel: Control
var bridge_session: RefCounted
var runtime_service_controller: RefCounted
var auto_dismiss_dialogs := false

var _dialog_check_timer := 0.0
const _DIALOG_CHECK_INTERVAL := 0.5


func _enter_tree() -> void:
	bridge_session = preload("res://addons/godot_mcp/bridge_session_coordinator.gd").new()
	if not bridge_session.start_session():
		push_error("[MCP] Bridge session startup failed: %s" % bridge_session.last_error)
		set_process(false)
		return

	runtime_service_controller = preload("res://addons/godot_mcp/runtime_service_controller.gd").new()
	runtime_service_controller.setup(self, bridge_session.owner_nonce)

	command_router = preload("res://addons/godot_mcp/command_router.gd").new()
	command_router.name = "MCPCommandRouter"
	command_router.editor_plugin = self
	add_child(command_router)

	websocket_server = preload("res://addons/godot_mcp/websocket_server.gd").new()
	websocket_server.name = "MCPWebSocketServer"
	websocket_server.command_router = command_router
	websocket_server.session_coordinator = bridge_session
	add_child(websocket_server)

	command_router.configure_bridge_context(
		bridge_session.project_path,
		websocket_server.is_session_ready,
		runtime_service_controller
	)

	var panel_scene: PackedScene = preload("res://addons/godot_mcp/ui/status_panel.tscn")
	status_panel = panel_scene.instantiate()
	add_control_to_bottom_panel(status_panel, "MCP Pro")
	status_panel.call_deferred("setup", websocket_server, command_router)

	if bridge_session.owns_current_session():
		websocket_server.start_server(bridge_session)

	var config := ConfigFile.new()
	var version := "unknown"
	if config.load("res://addons/godot_mcp/plugin.cfg") == OK:
		version = config.get_value("plugin", "version", "unknown")
	print("[MCP] Godot MCP Pro v%s started (authenticated discovery bridge)" % version)


func _exit_tree() -> void:
	# Invalidate transport/session before editor and runtime context disappear.
	if is_instance_valid(websocket_server):
		websocket_server.stop_server()

	if runtime_service_controller != null:
		runtime_service_controller.cleanup_owned_services()

	if bridge_session != null:
		bridge_session.stop_session()

	if is_instance_valid(status_panel):
		remove_control_from_bottom_panel(status_panel)
		status_panel.queue_free()
	if is_instance_valid(command_router):
		command_router.queue_free()
	if is_instance_valid(websocket_server):
		websocket_server.queue_free()

	print("[MCP] Godot MCP Pro stopped")


func _process(delta: float) -> void:
	if runtime_service_controller != null:
		runtime_service_controller.update_game_state()
	var debugger_flag := OS.get_user_data_dir().path_join("mcp_debugger_continue")
	if FileAccess.file_exists(debugger_flag):
		DirAccess.remove_absolute(debugger_flag)
		_try_debugger_continue()

	if auto_dismiss_dialogs:
		_dialog_check_timer += delta
		if _dialog_check_timer >= _DIALOG_CHECK_INTERVAL:
			_dialog_check_timer = 0.0
			_auto_dismiss_dialogs()


func _try_debugger_continue() -> void:
	var base: Node = EditorInterface.get_base_control()
	var continue_button := _find_debugger_continue_button(base)
	if continue_button and continue_button.visible and not continue_button.disabled:
		continue_button.emit_signal("pressed")
		push_warning("[MCP] Auto-pressed debugger Continue button")
	else:
		push_warning("[MCP] Could not find debugger Continue button")


func _find_debugger_continue_button(node: Node) -> Button:
	var continue_icon: Texture2D = null
	var base: Control = EditorInterface.get_base_control()
	if base != null and base.has_theme_icon("DebugContinue", "EditorIcons"):
		continue_icon = base.get_theme_icon("DebugContinue", "EditorIcons")
	return _find_continue_button_recursive(node, continue_icon)


func _find_continue_button_recursive(node: Node, continue_icon: Texture2D) -> Button:
	if node is Button:
		var button: Button = node
		if continue_icon != null and button.icon == continue_icon:
			return button
		if button.tooltip_text.contains("Continue") or button.text == "Continue":
			return button
	for child in node.get_children():
		var found := _find_continue_button_recursive(child, continue_icon)
		if found:
			return found
	return null


func _auto_dismiss_dialogs() -> void:
	var base: Node = EditorInterface.get_base_control()
	if base:
		_find_and_dismiss_dialogs(base)


func _find_and_dismiss_dialogs(node: Node) -> void:
	if node is AcceptDialog and node.visible:
		var dialog: AcceptDialog = node
		if dialog is FileDialog or not dialog.exclusive:
			return
		var title := dialog.title
		var text := dialog.dialog_text
		dialog.get_ok_button().emit_signal("pressed")
		push_warning("[MCP] Auto-dismissed editor dialog: '%s' - %s" % [title, text])
		return
	for child in node.get_children():
		if child is Window and not child.visible:
			continue
		_find_and_dismiss_dialogs(child)
