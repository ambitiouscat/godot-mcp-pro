@tool
extends "res://addons/opencode_godot/process/opencode_daemon_lifecycle.gd"

## Test-only descriptor augmentation for the packaged tool invocation E2E.
## The production lifecycle deliberately owns no model-provider configuration.

func _build_owned_config() -> Dictionary:
	var config: Dictionary = super._build_owned_config()
	var base_url := OS.get_environment("GODOT_MCP_E2E_PROVIDER_BASE_URL").strip_edges()
	if base_url.is_empty():
		return config
	config["provider"] = {
		"godot-e2e": {
			"name": "Godot packaged-tool E2E responder",
			"npm": "@ai-sdk/openai-compatible",
			"api": base_url,
			"options": {
				"apiKey": "godot-e2e-test-key",
				"baseURL": base_url,
				"timeout": 30000,
			},
			"models": {
				"tool-test": {
					"name": "Godot packaged-tool E2E model",
					"tool_call": true,
					"limit": {"context": 32000, "output": 1024},
				},
			},
		},
	}
	return config
