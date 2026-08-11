extends SceneTree

var failures: Array[String] = []
var project_file := ""
var project_before := ""
var external_config_path := ""
var external_config_before := ""
var project_config_path := ""
var project_config_before := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	project_file = ProjectSettings.globalize_path("res://project.godot")
	project_before = _read_text(project_file)
	external_config_path = OS.get_environment("OPENCODE_INSTALL_EXTERNAL_CONFIG")
	external_config_before = _read_text(external_config_path)
	project_config_path = OS.get_environment("OPENCODE_INSTALL_PROJECT_CONFIG")
	project_config_before = _read_text(project_config_path)
	for _frame in range(30):
		await process_frame

	# Load the legacy fixture first, then enable the unified addon. This mirrors
	# the editor migration path and avoids relying on project-array load order.
	if EditorInterface.is_plugin_enabled("godot_mcp") and not EditorInterface.is_plugin_enabled("opencode_godot"):
		EditorInterface.set_plugin_enabled("opencode_godot", true)
		for _frame in range(20):
			await process_frame

	var base := EditorInterface.get_base_control()
	_expect(EditorInterface.is_plugin_enabled("opencode_godot"), "the unified addon is enabled from one project plugin entry")
	_expect(_count_named_nodes(base, "OpenCode") == 1, "first enable creates exactly one right-side OpenCode dock")
	_expect(_count_named_nodes(base, "Chat") == 1 and _count_named_nodes(base, "Status") == 1, "the dock exposes one Chat and one Status tab")
	_expect(_count_addon_directories("opencode_godot") == 1, "the installation contains one opencode_godot addon directory")
	_expect(_count_addon_directories("godot_mcp") == (1 if EditorInterface.is_plugin_enabled("godot_mcp") else 0), "legacy addon presence is explicit and does not create a second unified copy")

	if EditorInterface.is_plugin_enabled("godot_mcp"):
		_test_legacy_conflict(base)
	else:
		_test_first_enable_state()

	# Disabling the actual editor plugin exercises _exit_tree and proves that the
	# right dock is removed instead of surviving as an orphaned editor control.
	EditorInterface.set_plugin_enabled("opencode_godot", false)
	for _frame in range(20):
		await process_frame
	_expect(_count_named_nodes(EditorInterface.get_base_control(), "OpenCode") == 0, "disabling the addon removes its right-side dock")

	if failures.is_empty():
		print("OPENCODE_GODOT_INSTALLATION_OK")
		quit(0)
	else:
		for failure: String in failures:
			push_error("TEST FAILURE: " + failure)
		quit(1)


func _test_first_enable_state() -> void:
	_expect(_read_text(project_file) == project_before, "first enable preserves project.godot configuration")
	_expect(_read_text(external_config_path) == external_config_before, "first enable preserves unrelated OpenCode configuration")
	_expect(_read_text(project_config_path) == project_config_before, "first enable preserves unrelated project-root OpenCode configuration")
	var ui_text := _collect_text(EditorInterface.get_base_control())
	var reached_launch_state := false
	for launch_state: String in ["starting", "probing", "ready"]:
		if ui_text.contains("Daemon: " + launch_state):
			reached_launch_state = true
			break
	_expect(reached_launch_state, "first enable advances the managed daemon to starting, probing, or ready")
	_expect(not ui_text.contains("Daemon: error"), "first enable does not leave the managed daemon in the failed state")
	var runtime_root := ProjectSettings.globalize_path("user://opencode_godot")
	if DirAccess.dir_exists_absolute(runtime_root):
		_expect(runtime_root.replace("\\", "/").ends_with("/opencode_godot"), "first-enable runtime state stays under the addon-owned user namespace")


func _test_legacy_conflict(base: Control) -> void:
	_expect(EditorInterface.is_plugin_enabled("godot_mcp"), "legacy addon conflict fixture is enabled")
	_expect(_collect_text(base).contains("Legacy Godot MCP Pro is enabled"), "legacy conflict is surfaced as actionable dock guidance")
	var runtime_root := ProjectSettings.globalize_path("user://opencode_godot/runtime")
	_expect(not DirAccess.dir_exists_absolute(runtime_root), "legacy conflict blocks unified bridge startup and daemon-owned runtime creation")


func _count_addon_directories(target: String) -> int:
	var addons := DirAccess.open(ProjectSettings.globalize_path("res://addons"))
	if addons == null:
		return 0
	var count := 0
	for entry: String in addons.get_directories():
		if entry == target:
			count += 1
	return count


func _count_named_nodes(node: Node, target: String) -> int:
	if node == null:
		return 0
	var count := 1 if node.name == target else 0
	for child: Node in node.get_children():
		count += _count_named_nodes(child, target)
	return count


func _collect_text(node: Node) -> String:
	if node == null:
		return ""
	var result := ""
	if node is Label:
		result += "\n" + String((node as Label).text)
	elif node is RichTextLabel:
		result += "\n" + String((node as RichTextLabel).text)
	for child: Node in node.get_children():
		result += _collect_text(child)
	return result


func _read_text(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var result := file.get_as_text()
	file.close()
	return result


func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
