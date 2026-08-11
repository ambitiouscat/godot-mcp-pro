extends RefCounted

const Protocol := preload("res://addons/opencode_godot/engine_bridge/bridge_protocol_v1.gd")

## Runtime IPC/state filenames.  Keep these names here so the editor-side
## command producers and game-side service consumers cannot silently drift
## onto different files again.
const GAME_REQUEST := "game_request"
const GAME_RESPONSE := "game_response"
const INPUT_COMMANDS := "input_commands"
const SCREENSHOT_REQUEST := "screenshot_request"
const SCREENSHOT := "screenshot.png"
const DEBUGGER_CONTINUE := "debugger_continue"


static func directory() -> String:
	var project := Protocol.canonicalize_project_path(ProjectSettings.globalize_path("res://"))
	return "user://opencode_godot/runtime/%s/engine" % Protocol.project_hash(project)


static func file(name: String) -> String:
	var root := directory()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root))
	return root.path_join(name)
