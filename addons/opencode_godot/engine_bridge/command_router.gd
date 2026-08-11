@tool
extends Node

const Protocol := preload("res://addons/opencode_godot/engine_bridge/bridge_protocol_v1.gd")
const RuntimePaths := preload("res://addons/opencode_godot/engine_bridge/runtime/runtime_paths.gd")

var editor_plugin: EditorPlugin
var runtime_service_controller: RefCounted
var session_validator: Callable
var expected_project_path: String = ""

var _command_handlers: Dictionary = {}  # method_name -> Callable
var _disabled_tools: Dictionary = {}  # method_name -> true
var _enabled_runtime_tools: Dictionary = {}  # explicitly enabled method_name -> true

func _ready() -> void:
	_load_tool_config()
	_register_commands()


func _register_commands() -> void:
	var command_classes := [
		preload("res://addons/opencode_godot/engine_bridge/commands/project_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/scene_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/node_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/script_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/editor_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/input_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/runtime_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/animation_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/tilemap_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/theme_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/profiling_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/batch_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/shader_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/export_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/resource_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/input_map_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/scene_3d_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/physics_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/analysis_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/animation_tree_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/audio_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/navigation_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/particle_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/test_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/android_commands.gd"),
		preload("res://addons/opencode_godot/engine_bridge/commands/headless_commands.gd"),
	]

	for cmd_class in command_classes:
		var cmd: Node = cmd_class.new()
		cmd.editor_plugin = editor_plugin
		add_child(cmd)
		var methods: Dictionary = cmd.get_commands()
		for method_name: String in methods:
			_command_handlers[method_name] = methods[method_name]

	print("[MCP] Registered %d commands" % _command_handlers.size())


func configure_bridge_context(
		project_path: String,
		validator: Callable,
		runtime_controller: RefCounted
	) -> void:
	expected_project_path = project_path
	session_validator = validator
	runtime_service_controller = runtime_controller
	if runtime_service_controller != null and runtime_service_controller.has_method("sync_enabled_methods"):
		var sync_result: Dictionary = runtime_service_controller.sync_enabled_methods(_enabled_runtime_tools.keys())
		if not sync_result.get("ok", false):
			push_warning("[MCP] Could not restore runtime tool configuration: %s" % sync_result.get("error", {}))


func execute(method: String, params: Dictionary, session_generation: int = -1) -> Dictionary:
	var context_error := _validate_execution_context(session_generation)
	if not context_error.is_empty():
		return {"error": context_error}

	if not _command_handlers.has(method):
		return {
			"error": {
				"code": -32601,
				"message": "Method not found: %s" % method,
				"data": {"available_methods": _command_handlers.keys()}
			}
		}

	if is_tool_disabled(method):
		return {
			"error": {
				"code": -32603,
				"message": "Tool '%s' is disabled in MCP Server settings" % method
			}
		}

	if runtime_service_controller != null and runtime_service_controller.has_method("prepare_for_command"):
		var service_result: Dictionary = runtime_service_controller.prepare_for_command(method)
		if not service_result.get("ok", false):
			return {"error": service_result.get("error", {
				"code": -32603,
				"message": "Required Godot runtime service is unavailable",
			})}

	var handler: Callable = _command_handlers[method]
	# Not typed as Dictionary on assignment: a handler that returns something
	# else would raise here, aborting the coroutine so no response is ever
	# sent and the caller waits out its whole timeout instead of being told
	# what went wrong.
	var result: Variant = await handler.call(params)
	# The handler may have yielded for several frames. Do not present its result
	# as belonging to a replacement bridge session or a torn-down plugin.
	context_error = _validate_execution_context(session_generation)
	if not context_error.is_empty():
		return {"error": context_error}
	if not result is Dictionary:
		return {
			"error": {
				"code": -32603,
				"message": "Handler for '%s' returned %s instead of a result dictionary" % [
					method, type_string(typeof(result))
				],
			}
		}
	return result


func _validate_execution_context(session_generation: int) -> Dictionary:
	# These OS thread IDs are exposed in Godot 4.3, unlike
	# Thread.is_main_thread(), while preserving the same dispatcher guard.
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return {
			"code": -32603,
			"message": "Godot editor commands must execute on the main thread",
		}
	if not is_instance_valid(editor_plugin) or not editor_plugin.is_inside_tree():
		return {
			"code": -32603,
			"message": "Godot EditorPlugin context is unavailable",
		}
	return _validate_authorized_session_context(session_generation)


func _validate_authorized_session_context(session_generation: int) -> Dictionary:
	if expected_project_path.is_empty():
		return {
			"code": -32002,
			"message": "The authenticated bridge project context is not configured",
		}
	var current_project := Protocol.canonicalize_project_path(ProjectSettings.globalize_path("res://"))
	if current_project != expected_project_path:
		return {
			"code": -32002,
			"message": "The active Godot project no longer matches the authenticated bridge session",
		}
	if session_generation < 0 or not session_validator.is_valid():
		return {
			"code": -32000,
			"message": "The authenticated bridge session context is not configured",
		}
	if not bool(session_validator.call(session_generation)):
		return {
			"code": -32000,
			"message": "The authenticated bridge session is no longer READY",
		}
	return {}


func get_available_methods() -> Array:
	return _command_handlers.keys()


func is_tool_disabled(method: String) -> bool:
	if _is_runtime_tool(method):
		return not _enabled_runtime_tools.has(method)
	return _disabled_tools.has(method)


func set_tool_disabled(method: String, disabled: bool) -> Dictionary:
	if _is_runtime_tool(method):
		if runtime_service_controller != null and runtime_service_controller.has_method("set_tool_enabled"):
			var result: Dictionary = runtime_service_controller.set_tool_enabled(method, not disabled)
			if not result.get("ok", false):
				return result
		if disabled:
			_enabled_runtime_tools.erase(method)
		else:
			_enabled_runtime_tools[method] = true
		_save_tool_config()
		return {"ok": true}
	if disabled:
		_disabled_tools[method] = true
	else:
		_disabled_tools.erase(method)
	_save_tool_config()
	return {"ok": true}


func set_all_tools_disabled(disabled: bool) -> Dictionary:
	for method: String in _command_handlers:
		var result := set_tool_disabled(method, disabled)
		if not result.get("ok", false):
			return result
	return {"ok": true}


func _load_tool_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(RuntimePaths.file("tool-config.cfg")) != OK:
		return
	if cfg.has_section("disabled_tools"):
		for method: String in cfg.get_section_keys("disabled_tools"):
			if cfg.get_value("disabled_tools", method, false):
				_disabled_tools[method] = true
	if cfg.has_section("enabled_runtime_tools"):
		for method: String in cfg.get_section_keys("enabled_runtime_tools"):
			if cfg.get_value("enabled_runtime_tools", method, false):
				_enabled_runtime_tools[method] = true


func _save_tool_config() -> void:
	var cfg := ConfigFile.new()
	for method: String in _disabled_tools:
		cfg.set_value("disabled_tools", method, true)
	for method: String in _enabled_runtime_tools:
		cfg.set_value("enabled_runtime_tools", method, true)
	cfg.save(RuntimePaths.file("tool-config.cfg"))


func _is_runtime_tool(method: String) -> bool:
	return (
		runtime_service_controller != null
		and runtime_service_controller.has_method("is_runtime_method")
		and runtime_service_controller.is_runtime_method(method)
	)
