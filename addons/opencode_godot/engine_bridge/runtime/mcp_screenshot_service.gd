## Autoload injected by Godot MCP Pro plugin at runtime.
## Monitors for screenshot requests from the editor and captures the game viewport.
extends Node

const RuntimePaths := preload("res://addons/opencode_godot/engine_bridge/runtime/runtime_paths.gd")

var _request_path := ""
var _screenshot_path := ""


func _ready() -> void:
	_request_path = RuntimePaths.file(RuntimePaths.SCREENSHOT_REQUEST)
	_screenshot_path = RuntimePaths.file(RuntimePaths.SCREENSHOT)
	# This service only exists to serve the editor-driven MCP workflow. In an
	# exported game it would poll user:// every frame for nothing, so shut it
	# down entirely there.
	if not OS.has_feature("editor") or OS.has_environment("GODOT_MCP_HEADLESS_CHILD"):
		process_mode = Node.PROCESS_MODE_DISABLED
		set_process(false)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if FileAccess.file_exists(_request_path):
		_take_screenshot()


func _take_screenshot() -> void:
	# Delete request file immediately to avoid re-triggering
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_request_path))

	# Wait one frame so the viewport has a fully rendered image
	# process_always=true (default) so the timer ticks even when tree is paused
	await get_tree().create_timer(0.05).timeout

	var viewport := get_viewport()
	if viewport == null:
		return

	var image := viewport.get_texture().get_image()
	if image == null:
		return

	image.save_png(_screenshot_path)
