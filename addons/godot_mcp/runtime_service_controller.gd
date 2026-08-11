@tool
extends RefCounted
class_name MCPRuntimeServiceController

const JOURNAL_PATH := "user://mcp_runtime_service_ownership.cfg"
const JOURNAL_BACKUP_PATH := JOURNAL_PATH + ".backup"
const SERVICE_DEFINITIONS := {
	"screenshot": {
		"autoload": "MCPScreenshot",
		"script": "res://addons/godot_mcp/mcp_screenshot_service.gd",
	},
	"input": {
		"autoload": "MCPInputService",
		"script": "res://addons/godot_mcp/mcp_input_service.gd",
	},
	"inspector": {
		"autoload": "MCPGameInspector",
		"script": "res://addons/godot_mcp/mcp_game_inspector_service.gd",
	},
}

const SCREENSHOT_METHODS := {"get_game_screenshot": true}
const INPUT_METHODS := {
	"simulate_key": true, "simulate_mouse_click": true, "simulate_mouse_move": true,
	"simulate_action": true, "simulate_sequence": true, "run_stress_test": true,
}
const INSPECTOR_METHODS := {
	"get_game_scene_tree": true, "get_game_node_properties": true,
	"set_game_node_property": true, "capture_frames": true,
	"monitor_properties": true, "execute_game_script": true,
	"start_recording": true, "stop_recording": true, "replay_recording": true,
	"find_nodes_by_script": true, "get_autoload": true,
	"batch_get_properties": true, "find_ui_elements": true,
	"click_button_by_text": true, "wait_for_node": true,
	"find_nearby_nodes": true, "navigate_to": true, "move_to": true,
	"watch_signals": true, "get_performance_monitors": true,
	"assert_node_state": true, "assert_screen_text": true,
	"run_test_scenario": true,
}

var editor_plugin: EditorPlugin
var owner_nonce: String = ""
var _owned: Dictionary = {}
var _enabled_methods: Dictionary = {}
var _game_was_running := false
var _running_services: Dictionary = {}
var _game_running_probe: Callable


func setup(plugin: EditorPlugin, session_owner_nonce: String, game_running_probe: Callable = Callable()) -> void:
	editor_plugin = plugin
	owner_nonce = session_owner_nonce
	_game_running_probe = game_running_probe
	_recover_stale_owned_services()
	_game_was_running = _is_game_running()
	if _game_was_running:
		_running_services = _configured_services()


func update_game_state() -> void:
	var running := _is_game_running()
	if running and not _game_was_running:
		# Snapshot what the new game process could actually load. Later project
		# setting changes cannot make a service appear in an already-running game.
		_running_services = _configured_services()
	elif not running and _game_was_running:
		_running_services.clear()
	_game_was_running = running


func prepare_for_command(method: String) -> Dictionary:
	var required := required_services_for_method(method)
	for service_id: String in required:
		var result := ensure_service(service_id)
		if not result.get("ok", false):
			return result
	return {"ok": true}


func is_runtime_method(method: String) -> bool:
	return not required_services_for_method(method).is_empty()


func sync_enabled_methods(methods: Array) -> Dictionary:
	_enabled_methods.clear()
	for method: Variant in methods:
		if method is String:
			var result := set_tool_enabled(method, true)
			if not result.get("ok", false):
				return result
	_remove_unused_owned_services()
	return {"ok": true}


func set_tool_enabled(method: String, enabled: bool) -> Dictionary:
	var required := required_services_for_method(method)
	if required.is_empty():
		return {"ok": true}
	if not enabled:
		_enabled_methods.erase(method)
		_remove_unused_owned_services()
		return {"ok": true}
	for service_id: String in required:
		var result := ensure_service(service_id)
		if not result.get("ok", false):
			_remove_unused_owned_services()
			return result
	_enabled_methods[method] = true
	return {"ok": true}


func required_services_for_method(method: String) -> Array[String]:
	var services: Array[String] = []
	if SCREENSHOT_METHODS.has(method):
		services.append("screenshot")
	if INPUT_METHODS.has(method) or method == "run_test_scenario":
		services.append("input")
	if INSPECTOR_METHODS.has(method):
		services.append("inspector")
	return services


func ensure_service(service_id: String) -> Dictionary:
	if not SERVICE_DEFINITIONS.has(service_id):
		return _error("Unknown runtime service: %s" % service_id)
	var definition: Dictionary = SERVICE_DEFINITIONS[service_id]
	var key := "autoload/%s" % definition["autoload"]
	var script: String = definition["script"]
	var wanted := "*" + script
	update_game_state()
	if _game_was_running and _running_services.has(service_id):
		# The active game loaded this service at launch. Restore the project
		# setting if a tool was disabled and re-enabled during that same run so
		# the next launch keeps the service available as well.
		if not ProjectSettings.has_setting(key):
			_owned[service_id] = {"key": key, "script": script}
			if not _save_journal():
				_owned.erase(service_id)
				return _error("Could not persist ownership before restoring runtime service '%s'" % service_id)
			ProjectSettings.set_setting(key, wanted)
			var restore_error := ProjectSettings.save()
			if restore_error != OK:
				ProjectSettings.set_setting(key, null)
				_owned.erase(service_id)
				_save_journal()
				return _error("Could not restore runtime service '%s': %s" % [service_id, error_string(restore_error)])
		return {"ok": true, "owned": _owned.has(service_id)}
	if ProjectSettings.has_setting(key):
		var existing := str(ProjectSettings.get_setting(key))
		if existing == wanted or existing == script:
			if _game_was_running and not _running_services.has(service_id):
				return _error(
					"Runtime service '%s' was enabled after the current game process started. Stop and relaunch the game so it can load the service." % service_id,
					-32020
				)
			# A matching pre-existing service is available but remains unowned.
			return {"ok": true, "owned": _owned.has(service_id)}
		return _error("Runtime service '%s' conflicts with existing autoload '%s'" % [service_id, existing])
	if _is_game_running():
		return _error(
			"Runtime service '%s' was not loaded by the running game. Stop the game, retry this tool to enable the service, then launch the game again." % service_id,
			-32020
		)
	_owned[service_id] = {"key": key, "script": script}
	if not _save_journal():
		_owned.erase(service_id)
		return _error("Could not persist ownership before enabling runtime service '%s'" % service_id)
	ProjectSettings.set_setting(key, wanted)
	var save_error := ProjectSettings.save()
	if save_error != OK:
		ProjectSettings.set_setting(key, null)
		_owned.erase(service_id)
		_save_journal()
		return _error("Could not save runtime service '%s': %s" % [service_id, error_string(save_error)])
	return {"ok": true, "owned": true, "restart_required": false}


func _configured_services() -> Dictionary:
	var configured: Dictionary = {}
	for service_id: String in SERVICE_DEFINITIONS:
		var definition: Dictionary = SERVICE_DEFINITIONS[service_id]
		var key := "autoload/%s" % definition["autoload"]
		var script: String = definition["script"]
		if ProjectSettings.has_setting(key):
			var current := str(ProjectSettings.get_setting(key))
			if current == script or current == "*" + script:
				configured[service_id] = true
	return configured


func cleanup_owned_services() -> void:
	var removed: Dictionary = {}
	for service_id: String in _owned.keys():
		var item: Dictionary = _owned[service_id]
		var key: String = item["key"]
		var script: String = item["script"]
		if not ProjectSettings.has_setting(key):
			continue
		var current := str(ProjectSettings.get_setting(key))
		if current == script or current == "*" + script:
			ProjectSettings.set_setting(key, null)
			removed[service_id] = "*" + script
	var changed := not removed.is_empty()
	_enabled_methods.clear()
	if changed:
		var save_error := ProjectSettings.save()
		if save_error != OK:
			for service_id: String in removed:
				var item: Dictionary = _owned[service_id]
				ProjectSettings.set_setting(item["key"], removed[service_id])
			ProjectSettings.save()
			push_error("[MCP] Could not remove owned runtime services: %s" % error_string(save_error))
			return
	_owned.clear()
	_remove_journal()


func _remove_unused_owned_services() -> void:
	var required_services: Dictionary = {}
	for method: String in _enabled_methods:
		for service_id: String in required_services_for_method(method):
			required_services[service_id] = true
	var removed: Dictionary = {}
	for service_id: String in _owned.keys():
		if required_services.has(service_id):
			continue
		var item: Dictionary = _owned[service_id]
		var key: String = item["key"]
		var script: String = item["script"]
		if ProjectSettings.has_setting(key):
			var current := str(ProjectSettings.get_setting(key))
			if current == script or current == "*" + script:
				ProjectSettings.set_setting(key, null)
				removed[service_id] = "*" + script
	var changed := not removed.is_empty()
	if changed:
		var save_error := ProjectSettings.save()
		if save_error != OK:
			for service_id: String in removed:
				var item: Dictionary = _owned[service_id]
				ProjectSettings.set_setting(item["key"], removed[service_id])
			ProjectSettings.save()
			push_error("[MCP] Could not disable owned runtime services: %s" % error_string(save_error))
			return
	for service_id: String in removed:
		_owned.erase(service_id)
	if not _save_journal():
		push_warning("[MCP] Runtime service ownership journal could not be updated after cleanup")


func _recover_stale_owned_services() -> void:
	var config := ConfigFile.new()
	var loaded_path := JOURNAL_PATH
	if config.load(JOURNAL_PATH) != OK:
		loaded_path = JOURNAL_BACKUP_PATH
		if config.load(JOURNAL_BACKUP_PATH) != OK:
			return
	if not config.has_section("owned"):
		return
	var recorded_project: String = config.get_value("session", "project_path", "")
	var current_project := preload("res://addons/godot_mcp/bridge_protocol_v1.gd").canonicalize_project_path(ProjectSettings.globalize_path("res://"))
	if recorded_project != current_project:
		push_warning("[MCP] Ignoring runtime ownership journal for a different project")
		return
	var stale: Dictionary = {}
	for service_id: String in config.get_section_keys("owned"):
		if not SERVICE_DEFINITIONS.has(service_id):
			continue
		var recorded: String = config.get_value("owned", service_id, "")
		var definition: Dictionary = SERVICE_DEFINITIONS[service_id]
		var key := "autoload/%s" % definition["autoload"]
		var script: String = definition["script"]
		if recorded == script and ProjectSettings.has_setting(key):
			var current := str(ProjectSettings.get_setting(key))
			if current == script or current == "*" + script:
				stale[service_id] = {"key": key, "script": script}
	if loaded_path == JOURNAL_BACKUP_PATH and FileAccess.file_exists(JOURNAL_PATH):
		# A newer primary appeared while the fallback was inspected. Its
		# ownership was not verified by this recovery pass, so preserve both.
		return
	_owned = stale
	cleanup_owned_services()


func _save_journal() -> bool:
	if _owned.is_empty():
		_remove_journal()
		return true
	var config := ConfigFile.new()
	config.set_value("session", "owner_nonce", owner_nonce)
	config.set_value(
		"session",
		"project_path",
		preload("res://addons/godot_mcp/bridge_protocol_v1.gd").canonicalize_project_path(ProjectSettings.globalize_path("res://"))
	)
	for service_id: String in _owned:
		config.set_value("owned", service_id, (_owned[service_id] as Dictionary)["script"])
	var temporary := "%s.tmp-%s" % [JOURNAL_PATH, owner_nonce]
	var save_error := config.save(temporary)
	if save_error != OK:
		return false
	var absolute_temporary := ProjectSettings.globalize_path(temporary)
	var absolute_journal := ProjectSettings.globalize_path(JOURNAL_PATH)
	var absolute_backup := ProjectSettings.globalize_path(JOURNAL_BACKUP_PATH)
	if FileAccess.file_exists(JOURNAL_BACKUP_PATH):
		var remove_backup_error := DirAccess.remove_absolute(absolute_backup)
		if remove_backup_error != OK:
			DirAccess.remove_absolute(absolute_temporary)
			return false
	if FileAccess.file_exists(JOURNAL_PATH):
		var backup_error := DirAccess.rename_absolute(absolute_journal, absolute_backup)
		if backup_error != OK:
			DirAccess.remove_absolute(absolute_temporary)
			return false
	var rename_error := DirAccess.rename_absolute(absolute_temporary, absolute_journal)
	if rename_error != OK:
		DirAccess.remove_absolute(absolute_temporary)
		if FileAccess.file_exists(JOURNAL_BACKUP_PATH) and not FileAccess.file_exists(JOURNAL_PATH):
			DirAccess.rename_absolute(absolute_backup, absolute_journal)
		return false
	if FileAccess.file_exists(JOURNAL_BACKUP_PATH):
		DirAccess.remove_absolute(absolute_backup)
	return true


func _remove_journal() -> void:
	if FileAccess.file_exists(JOURNAL_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(JOURNAL_PATH))
	if FileAccess.file_exists(JOURNAL_BACKUP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(JOURNAL_BACKUP_PATH))


func _is_game_running() -> bool:
	if _game_running_probe.is_valid():
		return bool(_game_running_probe.call())
	return is_instance_valid(editor_plugin) and editor_plugin.get_editor_interface().is_playing_scene()


func _error(message: String, code: int = -32603) -> Dictionary:
	return {"ok": false, "error": {"code": code, "message": message}}
