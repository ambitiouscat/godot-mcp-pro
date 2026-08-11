@tool
extends RefCounted

## Owns exactly one OpenCode daemon for one canonical Godot project.  This file
## intentionally contains no editor-command path: HTTP/SSE consumers receive
## `daemon_ready`; native-plugin and MCP-compatibility providers each use the
## same hardened project bridge and editor command router, never both at once.

signal state_changed(state: String, detail: String)
signal daemon_ready(base_url: String, password: String, generation: int)
signal daemon_stopped(generation: int)
signal diagnostic(category: String, message: String)

const MANIFEST_PATH := "res://addons/opencode_godot/payload-manifest.json"
const NATIVE_MANIFEST_PATH := "res://addons/opencode_godot/runtime/opencode-plugins/godot-tools.manifest.json"
const NATIVE_ARTIFACT_RELATIVE_PATH := "runtime/opencode-plugins/godot-tools.js"
const RUNTIME_ROOT := "user://opencode_godot/runtime"
const MODE_STATE_ROOT := "user://opencode_godot/integration-mode"
const DESCRIPTOR_SCHEMA := "opencode-godot-launch"
const LISTEN_SCHEMA := "opencode-godot-listen"
const DESCRIPTOR_VERSION := 1
const DAEMON_OWNERSHIP_SCHEMA := "opencode-godot-ownership"
const DAEMON_OWNERSHIP_SCHEMA_VERSION := 1
const DAEMON_OWNERSHIP_FIELDS := [
	"schema",
	"schema_version",
	"phase",
	"project_hash",
	"canonical_project",
	"launch_nonce",
	"pid",
	"started_at_ms",
	"process_start",
	"hostname",
	"port",
	"opencode_path",
	"executable_sha256",
	"executable_size_bytes",
	"opencode_version",
	"build_fingerprint",
	"listen_record_path",
	"integration_mode",
	"mcp_ownership_path",
	"native_plugin",
	"bridge_owner_nonce",
	"bridge_discovery_path",
]
const MAX_LOG_BYTES := 16 * 1024
const MAX_DRAIN_BYTES_PER_UPDATE := 64 * 1024
const DRAIN_CHUNK_BYTES := 4096
const PIPE_DRAIN_QUARANTINE_META_KEY := "_opencode_godot_pipe_drain_quarantine_v1"
const PIPE_DRAIN_QUARANTINE_LIMIT := 8
const MAX_RESTART_ATTEMPTS := 3
const RESTART_BACKOFF_SECONDS := [0.5, 1.5, 4.0]
const STARTUP_PROBE_RETRIES := 8
const HEALTH_INTERVAL_MS := 2000
const IDENTITY_CHECK_INTERVAL_MS := 2000
const GRACEFUL_STOP_MS := 1000
const SIDECAR_STOP_MS := 100
const MAX_PROBE_BODY_BYTES := 1024 * 1024
const LEGACY_STDERR_QUARANTINE_META_KEY := "_opencode_godot_legacy_stderr_quarantine_v1"
const LEGACY_STDERR_QUARANTINE_LIMIT := 8
const MCP_OWNERSHIP_SCHEMA := "opencode-godot-mcp-ownership"
const MCP_OWNERSHIP_SCHEMA_VERSION := 1
const MCP_VERSION := "1.16.0"
const MCP_API_CONTRACT := "godot-mcp-pro/1.16.0"
const NATIVE_MANIFEST_SCHEMA := "opencode-godot-native-plugin-manifest"
const NATIVE_MANIFEST_VERSION := 1
const NATIVE_PLUGIN_ID := "godot-tools"
const NATIVE_PLUGIN_API_VERSION := "1.17.18"
const NATIVE_ZOD_VERSION := "4.1.8"
const BRIDGE_PROTOCOL_VERSION := 1
const NATIVE_PROFILE_TOOL_COUNT := 35
const FULL_PROFILE_TOOL_COUNT := 178
const NATIVE_TIMEOUT_MS := 30000

const Protocol := preload("res://addons/opencode_godot/engine_bridge/bridge_protocol_v1.gd")
const ProcessIdentity := preload("res://addons/opencode_godot/engine_bridge/bridge_process_identity.gd")
const ManagedPipeDrainWorker := preload("res://addons/opencode_godot/process/managed_pipe_drain_worker.gd")

var canonical_project: String = ""
var project_hash: String = ""
var runtime_dir: String = ""
var bridge_session: RefCounted
var websocket_server: Node
var state := "stopped"
var detail := ""
var generation := 0
var password := ""
var launch_nonce := ""
var daemon_pid := 0
var daemon_started_at_ms := 0
# A returned handle, a PID without a start identity, or an UNKNOWN identity is
# deliberately retained across stop/plugin exit.  The on-disk launching record
# is the second defense when an editor callback observes a fresh object.
var _launch_ownership_uncertain := false
var base_url := ""
var _control_lease: FileAccess
var _stderr_pipe: FileAccess
var _control_drain_worker
var _stderr_drain_worker
var _control_drain_drop_generation := 0
var _stderr_drain_drop_generation := 0
var _manifest: Dictionary = {}
var _payload: Dictionary = {}
var _native_manifest: Dictionary = {}
var _native_diagnostics: Array[String] = []
var requested_integration_mode := ""
var current_integration_mode := "mcp"
var _restart_attempt := 0
var _restart_after_ms := 0
var _output_buffer := ""
var _redaction_tail := ""
var _listen_record: Dictionary = {}
var _probe_client: HTTPClient
var _probe_phase := "idle"
var _probe_operation := ""
var _probe_code := 0
var _probe_body := PackedByteArray()
var _probe_failures := 0
var _probe_after_ms := 0
var _last_health_ms := 0
var _identity_warning_reported := false
var _last_identity_check_ms := 0
var _last_identity: Dictionary = {}
var _platform_error := ""
var _last_stopped_signal_generation := -1
# Test seam: the host probe remains fail-closed when it is unavailable.
var _linux_libc_detector := Callable()
# Test seam: force the 4.3 blocking-pipe path on newer editors so the actual
# OS pipe regression fixture can run in the normal foundation matrix.
var _pipe_drain_worker_runtime_detector := Callable()
# Test seams for synthetic process identities. The default is the platform
# identity provider and OS termination used by production.
var _process_identity_inspector := Callable()
var _process_terminator := Callable()
# Test seam for proving fail-closed starts never reach OS.execute_with_pipe.
var _process_launcher := Callable()


func setup(session: RefCounted, bridge: Node) -> void:
	bridge_session = session
	websocket_server = bridge
	canonical_project = Protocol.canonicalize_project_path(ProjectSettings.globalize_path("res://"))
	project_hash = Protocol.project_hash(canonical_project)
	runtime_dir = ProjectSettings.globalize_path(RUNTIME_ROOT).path_join(project_hash)
	requested_integration_mode = _load_requested_integration_mode()


func start() -> Dictionary:
	if state == "ready":
		return {"ok": true, "base_url": base_url, "generation": generation}
	if state in ["starting", "probing", "stopping"]:
		return {"ok": false, "error": "OpenCode lifecycle is already %s." % state}
	# An UNKNOWN launch is a lifecycle-scoped tombstone.  If an external actor
	# removed both durable ownership slots, do not let normal preflight recreate
	# a descriptor and replace a possible child; only an explicit stale recovery
	# or proven cleanup may clear this flag.
	if _launch_ownership_uncertain and not runtime_dir.is_empty():
		var ownership_path := runtime_dir.path_join("ownership.json")
		if not FileAccess.file_exists(ownership_path) and not FileAccess.file_exists(ownership_path + ".bak"):
			_clear_live_transport_state()
			return _fail("ownership", "A prior launch remains UNKNOWN in this lifecycle, but its durable ownership record is gone; refusing to start another daemon.")
	if _uses_blocking_pipe_drain_workers():
		_reap_process_lifetime_drain_workers()
		var reserved_workers := _process_lifetime_drain_worker_count() + 2
		# Legacy Unix stderr handles and active/stuck worker objects are both
		# process-lifetime retention. Admit the pair together so a sequence of
		# 4.3 launches can never exceed the shared retention budget.
		if _uses_legacy_unix_stderr_quarantine():
			reserved_workers += _legacy_stderr_quarantine_count()
		if reserved_workers > PIPE_DRAIN_QUARANTINE_LIMIT:
			return _fail("process", _pipe_drain_quarantine_limit_message())
	if _uses_legacy_unix_stderr_quarantine() and _legacy_stderr_quarantine_is_full():
		return _fail("process", _legacy_stderr_quarantine_limit_message())
	if bridge_session == null or not bridge_session.owns_current_session():
		return _fail("bridge", "The authenticated Godot bridge is not available; OpenCode will not start.")
	if _bridge_editor_identity().is_empty():
		return _fail("bridge", "The authenticated Godot bridge has no valid coordinator process identity; OpenCode will not start.")
	if not _ensure_private_directory(runtime_dir):
		return _fail("runtime", "Could not create private OpenCode runtime directory.")
	var validation := _validate_payloads()
	if not validation.get("ok", false):
		return validation
	current_integration_mode = str(validation.get("integration_mode", "mcp"))
	var ownership_path := runtime_dir.path_join("ownership.json")
	if _launch_ownership_uncertain and not FileAccess.file_exists(ownership_path) and not FileAccess.file_exists(ownership_path + ".bak"):
		_clear_live_transport_state()
		return _fail("ownership", "A prior launch remains UNKNOWN in this lifecycle, but its durable ownership record is gone; refusing to start another daemon.")
	# Stale child reclamation verifies the sidecar against the current pinned
	# manifest/payload identity, so load that identity before reading any prior
	# daemon or MCP ownership evidence.
	var previous := _prepare_previous_ownership()
	if not previous.get("ok", false):
		return previous
	if _launch_ownership_uncertain:
		_clear_live_transport_state()
		return _fail("ownership", "A prior launch remains UNKNOWN in this lifecycle; explicit stale recovery is required before starting another daemon.")
	# A previous launch was either reclaimed or rejected above.  This fresh
	# launch starts with no in-memory uncertainty; abort paths set the flag again
	# before returning an UNKNOWN result.
	_launch_ownership_uncertain = false
	password = Protocol.random_base64url(32)
	launch_nonce = Protocol.random_base64url(32)
	if not Protocol.validate_nonce(password, 32) or not Protocol.validate_nonce(launch_nonce, 32):
		return _fail("security", "Could not generate daemon authentication material.")
	generation += 1
	_reset_probe()
	_listen_record.clear()
	_identity_warning_reported = false
	_redaction_tail = ""
	var descriptor_path := runtime_dir.path_join("launch-%s.json" % launch_nonce)
	var listen_record_path := runtime_dir.path_join("listen-%s.json" % launch_nonce)
	var config := _build_owned_config()
	var descriptor := _build_descriptor(JSON.stringify(config), listen_record_path)
	if not _write_private_json_atomic(descriptor_path, descriptor):
		return _fail("runtime", "Could not atomically publish launch descriptor.")
	# Publish a nonce-bound pending ownership record before asking the OS to
	# create a child.  execute_with_pipe can return a partial Dictionary, so a
	# descriptor alone is not durable evidence that a later enable may replace
	# this launch.  The pending record is intentionally incomplete until both
	# the PID and immutable process start identity are known.
	if not _write_ownership_record(listen_record_path, "launching"):
		_cleanup_failed_launch_artifacts(descriptor_path, listen_record_path)
		return _fail("runtime", "Could not atomically publish pending daemon ownership.")
	_set_state("starting", "Launching bundled OpenCode daemon")
	# Godot 4.3 exposes the two-argument form; its console behavior already
	# defaults to false, so this remains non-interactive on every supported 4.x.
	var launch: Dictionary
	var launch_arguments := PackedStringArray(["serve", "--godot-launch-descriptor", descriptor_path])
	if _process_launcher.is_valid():
		var injected_launch: Variant = _process_launcher.call(str(_payload["opencode_path"]), launch_arguments)
		launch = injected_launch if injected_launch is Dictionary else {}
	else:
		launch = OS.execute_with_pipe(str(_payload["opencode_path"]), launch_arguments)
	# Capture both returned handles before inspecting the PID. A malformed or
	# partially populated result can still carry a legacy Linux stderr object;
	# letting that Dictionary release it is enough to close editor fd 0.
	_control_lease = launch.get("stdio") as FileAccess
	_stderr_pipe = launch.get("stderr") as FileAccess
	if not _start_drain_workers():
		return _abort_failed_launch(descriptor_path, listen_record_path, "Could not start bounded daemon output drain workers.")
	if _uses_legacy_unix_stderr_quarantine() and _stderr_pipe != null and _stderr_drain_worker == null and not _retain_legacy_stderr_pipe(_stderr_pipe):
		return _abort_failed_launch(descriptor_path, listen_record_path, _legacy_stderr_quarantine_limit_message())
	var returned_pid := int(launch.get("pid", 0))
	if returned_pid > 0:
		daemon_pid = returned_pid
		daemon_started_at_ms = maxi(0, ProcessIdentity.started_at_ms(daemon_pid))
		_reset_daemon_identity_cache()
		# A partially populated execute_with_pipe result can still name a real
		# child. Persist its nonce-bound identity before deciding whether it is
		# safe to terminate or remove its startup artifacts.  Keep a positive PID
		# even when the start identity is unavailable; the incomplete record must
		# block a later replacement attempt.
		if not _write_ownership_record(listen_record_path, "launching"):
			return _abort_failed_launch(descriptor_path, listen_record_path, "Could not atomically update daemon ownership after launch.")
	if (
		returned_pid <= 0
		or not launch.get("stdio") is FileAccess
		or not launch.get("stderr") is FileAccess
	):
		return _abort_failed_launch(descriptor_path, listen_record_path, "Bundled OpenCode daemon launch returned an incomplete process result.")
	if daemon_started_at_ms <= 0 or not _ownership_matches_current_launch():
		return _abort_failed_launch(descriptor_path, listen_record_path, "Could not establish a verifiable ownership record for the launched daemon.")
	_launch_ownership_uncertain = false
	_set_state("starting", "Waiting for authenticated OpenCode readiness")
	return {"ok": true, "generation": generation}


func update() -> void:
	_drain_child_output()
	if state == "starting":
		_try_read_listen_record()
	_update_probe()
	if state == "ready" and _probe_client == null and Protocol.now_ms() - _last_health_ms >= HEALTH_INTERVAL_MS:
		_start_probe("health")
	if daemon_pid > 0:
		var identity := _inspect_daemon_identity()
		if identity.get("stale", false):
			_handle_exit("The managed OpenCode daemon exited or its PID was reused.")
		elif not identity.get("matches", false) and not _identity_warning_reported:
			_identity_warning_reported = true
			diagnostic.emit("ownership", "Daemon process identity is temporarily unverifiable; it will not be killed or adopted.")
	if state == "backoff" and Protocol.now_ms() >= _restart_after_ms:
		start()


func stop() -> void:
	var stopped_generation := generation
	_set_state("stopping", "Stopping managed OpenCode daemon")
	_reset_probe()
	# Closing the retained stdio lease is the daemon's authoritative owner-loss
	# signal. Never kill an identity that no longer matches our record.
	_release_child_pipes()
	_redaction_tail = ""
	var ownership_requires_recovery := _launch_ownership_uncertain or _matching_incomplete_launch_record()
	var safe_to_clean := daemon_pid <= 0 and not ownership_requires_recovery
	if daemon_pid > 0:
		var identity := _inspect_daemon_identity(true)
		if identity.get("matches", false):
			# The normal update loop caches process identity for two seconds. Do
			# not turn graceful shutdown into a high-frequency PowerShell/procfs
			# polling loop; one delayed confirmation keeps termination bounded.
			OS.delay_msec(GRACEFUL_STOP_MS)
			identity = _inspect_daemon_identity(true)
			if identity.get("stale", false):
				safe_to_clean = true
			if not safe_to_clean and identity.get("matches", false):
				OS.kill(daemon_pid)
				OS.delay_msec(25)
				var after_kill := _inspect_daemon_identity(true)
				safe_to_clean = after_kill.get("stale", false)
		elif identity.get("stale", false):
			safe_to_clean = true
		else:
			diagnostic.emit("ownership", "Preserving state for an unverified daemon process; no forced termination was attempted.")
	_reap_process_lifetime_drain_workers()
	var cleanup_complete := true
	if safe_to_clean:
		cleanup_complete = _cleanup_owned_runtime_files()
	else:
		# Losing the stdio lease disconnects the editor from the daemon, but an
		# UNKNOWN process identity is not proof that the process stopped. Keep the
		# nonce-bound identity in memory and on disk so the next recovery attempt
		# cannot silently adopt, overwrite, or misreport the possible orphan.
		_clear_live_transport_state()
		_restart_attempt = 0
		_set_state("orphaned", "OpenCode daemon identity is UNKNOWN; ownership evidence was preserved and no process was terminated.")
		diagnostic.emit("ownership", detail)
		_emit_daemon_stopped(stopped_generation)
		return
	if not cleanup_complete:
		# The parent is proven stale here, but an MCP child or its immutable
		# ownership record could not be verified. Preserve the complete launch
		# binding and surface a recovery state instead of claiming a clean stop.
		_clear_live_transport_state()
		_restart_attempt = 0
		_set_state("orphaned", "OpenCode daemon stopped, but MCP ownership evidence could not be safely reclaimed.")
		diagnostic.emit("mcp-ownership", detail)
		_emit_daemon_stopped(stopped_generation)
		return
	daemon_pid = 0
	daemon_started_at_ms = 0
	_clear_live_transport_state()
	launch_nonce = ""
	_launch_ownership_uncertain = false
	_restart_attempt = 0
	_set_state("stopped", "OpenCode daemon stopped")
	_emit_daemon_stopped(stopped_generation)


func get_status() -> Dictionary:
	return {
		"state": state,
		"detail": detail,
		"generation": generation,
		"base_url": base_url,
		"chat_ready": state == "ready",
		"tools_ready": websocket_server != null and websocket_server.is_session_ready(),
		"integration_mode": current_integration_mode,
		"requested_integration_mode": requested_integration_mode,
		"native_diagnostics": _native_diagnostics.duplicate(),
	}


func get_integration_mode() -> String:
	return current_integration_mode


func set_requested_integration_mode(mode: String) -> Dictionary:
	var normalized := mode.to_lower().strip_edges()
	if normalized not in ["mcp", "native"]:
		return {"ok": false, "error": "Integration mode must be 'mcp' or 'native'."}
	if normalized == requested_integration_mode:
		return {"ok": true, "changed": false, "mode": normalized}
	if not _write_requested_integration_mode(normalized):
		return {"ok": false, "error": "Could not persist the project-scoped integration mode."}
	requested_integration_mode = normalized
	return {"ok": true, "changed": true, "mode": normalized}


func _validate_payloads() -> Dictionary:
	_native_diagnostics.clear()
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		return _fail("payload", "Payload manifest is missing from the addon.")
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	file.close()
	if parse_error != OK or not parser.data is Dictionary:
		return _fail("payload", "Payload manifest is malformed.")
	_manifest = parser.data
	if _manifest.get("schema") != "opencode-godot-payload-manifest" or int(_manifest.get("schema_version", 0)) != 1:
		return _fail("payload", "Payload manifest schema is unsupported.")
	var daemon_release: Dictionary = _manifest.get("opencode", {})
	var sidecar_release: Dictionary = _manifest.get("godot_mcp", {})
	if str(daemon_release.get("version", "")) != "1.17.18" or str(sidecar_release.get("version", "")) != "1.16.0":
		return _fail("payload", "Payload manifest versions do not match the pinned OpenCode 1.17.18 / MCP 1.16.0 contract.")
	if not _valid_source_fingerprint(str(daemon_release.get("source_fingerprint", ""))) or not _valid_source_fingerprint(str(sidecar_release.get("source_fingerprint", ""))):
		return _fail("payload", "Payload manifest does not contain release source fingerprints.")
	_platform_error = ""
	var key := _platform_key()
	var entries: Dictionary = _manifest.get("payloads", {})
	if key.is_empty() or not entries.has(key):
		return _fail("payload", _platform_error if not _platform_error.is_empty() else "Unsupported host platform. This addon supports Windows/macOS/Linux x86_64 and arm64 only.")
	var item: Dictionary = entries[key]
	var daemon := item.get("opencode", {})
	var sidecar := item.get("mcp", {})
	if not daemon is Dictionary or not sidecar is Dictionary:
		return _fail("payload", "Current platform payload entry is incomplete.")
	var addon_root := ProjectSettings.globalize_path("res://addons/opencode_godot")
	var daemon_path_result := _resolve_payload_path(addon_root, str((daemon as Dictionary).get("path", "")))
	if not daemon_path_result.get("ok", false):
		return _fail("payload", "OpenCode payload path is invalid: %s" % daemon_path_result.get("error", "unknown path validation failure"))
	var daemon_path := str(daemon_path_result["path"])
	var daemon_metadata := _validate_artifact_metadata(daemon, "OpenCode", "1.17.18", true)
	if not daemon_metadata.get("ok", false):
		return daemon_metadata
	var daemon_validation := _validate_payload_file(daemon, daemon_path, "OpenCode", true)
	if not daemon_validation.get("ok", false):
		return daemon_validation
	var native_validation := _load_and_validate_native_manifest(addon_root)
	var selected_mode := _select_integration_mode(native_validation)
	if selected_mode == "native" and not native_validation.get("ok", false):
		return _fail("native-payload", "Native mode is unavailable: %s" % native_validation.get("error", "native plugin validation failed"))
	var sidecar_path := ""
	var sidecar_validation := {"ok": true, "available": false}
	if selected_mode == "mcp":
		var sidecar_path_result := _resolve_payload_path(addon_root, str((sidecar as Dictionary).get("path", "")))
		if not sidecar_path_result.get("ok", false):
			return _fail("payload", "Godot MCP sidecar payload path is invalid: %s" % sidecar_path_result.get("error", "unknown path validation failure"))
		sidecar_path = str(sidecar_path_result["path"])
		var sidecar_metadata := _validate_artifact_metadata(sidecar, "Godot MCP sidecar", "1.16.0", true)
		if not sidecar_metadata.get("ok", false):
			return sidecar_metadata
		sidecar_validation = _validate_payload_file(sidecar, sidecar_path, "Godot MCP sidecar", true)
		if not sidecar_validation.get("ok", false):
			return sidecar_validation
	_payload = {
		"opencode_path": daemon_path,
		"opencode_sha256": str((daemon as Dictionary).get("sha256", "")).trim_prefix("sha256:").to_lower(),
		"opencode_size_bytes": int((daemon as Dictionary).get("size_bytes", 0)),
		"opencode_build_fingerprint": str((daemon as Dictionary).get("build_fingerprint", "")),
		"mcp_path": sidecar_path,
		"mcp_sha256": str((sidecar as Dictionary).get("sha256", "")).trim_prefix("sha256:").to_lower(),
		"mcp_size_bytes": int((sidecar as Dictionary).get("size_bytes", 0)),
		"mcp_build_fingerprint": str((sidecar as Dictionary).get("build_fingerprint", "")),
		"mcp_available": selected_mode == "mcp" and sidecar_validation.get("available", false),
		"native_path": str(native_validation.get("artifact_path", "")),
		"native_sha256": str(native_validation.get("sha256", "")),
		"native_size_bytes": int(native_validation.get("size_bytes", 0)),
		"native_build_fingerprint": str(native_validation.get("build_fingerprint", "")),
		"native_source_fingerprint": str(native_validation.get("source_fingerprint", "")),
		"native_available": native_validation.get("ok", false),
		"platform": key,
	}
	return {"ok": true, "integration_mode": selected_mode}


func _validate_artifact_metadata(entry: Dictionary, label: String, expected_version: String, required: bool) -> Dictionary:
	var build_fingerprint := str(entry.get("build_fingerprint", ""))
	if (
		str(entry.get("version", "")) != expected_version
		or not bool(entry.get("version_verified", false))
		or not _valid_source_fingerprint(str(entry.get("source_fingerprint", "")))
		or build_fingerprint in ["", "UNVERIFIED", "UNPACKAGED"]
		or str(entry.get("status", "")) == "missing"
	):
		return _payload_file_failure(required, "%s release identity is missing or incompatible." % label)
	return {"ok": true, "available": true}


func _valid_source_fingerprint(value: String) -> bool:
	var digest := value.trim_prefix("sha256:")
	return value.begins_with("sha256:") and digest.length() == 64 and digest.is_valid_hex_number(false)


func _resolve_payload_path(addon_root: String, manifest_path: String) -> Dictionary:
	# Release metadata is an input to process execution. Do not allow an
	# absolute path, a drive/UNC path, empty component, or lexical traversal to
	# escape the bundled addon payload directory.
	if addon_root.is_empty() or not addon_root.is_absolute_path():
		return {"ok": false, "error": "the addon root is not absolute"}
	if manifest_path.is_empty() or manifest_path != manifest_path.strip_edges():
		return {"ok": false, "error": "the manifest path is empty or padded"}
	var relative := manifest_path.replace("\\", "/")
	if relative.is_absolute_path() or relative.begins_with("/") or relative.begins_with("//") or relative.contains(":"):
		return {"ok": false, "error": "the manifest path must be relative"}
	for component: String in relative.split("/", true):
		if component in ["", ".", ".."]:
			return {"ok": false, "error": "the manifest path contains a forbidden component"}
	var root := addon_root.replace("\\", "/").simplify_path()
	var resolved := root.path_join(relative).simplify_path()
	if OS.get_name() == "Windows":
		root = root.to_lower()
		resolved = resolved.to_lower()
	if not resolved.begins_with(root + "/"):
		return {"ok": false, "error": "the manifest path escapes the addon root"}
	return {"ok": true, "path": resolved}


func _validate_payload_file(entry: Dictionary, path: String, label: String, required: bool) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _payload_file_failure(required, "%s payload is not packaged for this host: %s" % [label, path])
	var expected_hash := str(entry.get("sha256", "")).trim_prefix("sha256:").to_lower()
	if expected_hash.length() != 64 or not expected_hash.is_valid_hex_number(false):
		return _payload_file_failure(required, "%s payload checksum metadata is invalid." % label)
	if FileAccess.get_sha256(path).to_lower() != expected_hash:
		return _payload_file_failure(required, "%s payload failed SHA-256 integrity validation." % label)
	var expected_size := int(entry.get("size_bytes", 0))
	var payload_file := FileAccess.open(path, FileAccess.READ)
	var actual_size := payload_file.get_length() if payload_file != null else -1
	if payload_file != null:
		payload_file.close()
	if expected_size <= 0 or actual_size != expected_size:
		return _payload_file_failure(required, "%s payload size does not match the release manifest." % label)
	if OS.get_name() in ["Linux", "macOS"]:
		var permissions := FileAccess.get_unix_permissions(path)
		if permissions < 0 or (permissions & 73) == 0: # at least one execute bit
			return _payload_file_failure(required, "%s payload is not executable." % label)
	var signature: Variant = entry.get("signature")
	if signature is Dictionary:
		var status := str((signature as Dictionary).get("status", ""))
		if status not in ["verified", "signed", "unsigned", "unverified"]:
			return _payload_file_failure(required, "%s payload signature metadata is invalid." % label)
		if status in ["unsigned", "unverified"]:
			var release: Dictionary = _manifest.get("release", {})
			if str(release.get("mode", "")) == "full" or bool(release.get("complete", false)):
				return _payload_file_failure(required, "%s is not signed as required by the full release manifest." % label)
			diagnostic.emit("signature", "%s is checksum-verified but not release-signed; use a full signed payload for distribution." % label)
	elif not signature is String or str(signature).is_empty():
		return _payload_file_failure(required, "%s payload signature metadata is missing." % label)
	return {"ok": true, "available": true}


func _payload_file_failure(required: bool, message: String) -> Dictionary:
	if required:
		return _fail("payload", message)
	diagnostic.emit("mcp-payload", message)
	return {"ok": false, "available": false, "error": message}


func _select_integration_mode(native_validation: Dictionary) -> String:
	if requested_integration_mode in ["mcp", "native"]:
		return requested_integration_mode
	if native_validation.get("ok", false) and bool(native_validation.get("native_default_attested", false)) and str(native_validation.get("default_integration_mode", "")) == "native":
		return "native"
	return "mcp"


func _load_and_validate_native_manifest(addon_root: String) -> Dictionary:
	_native_manifest.clear()
	var file := FileAccess.open(NATIVE_MANIFEST_PATH, FileAccess.READ)
	if file == null:
		return _native_manifest_failure("The bundled native plugin compatibility manifest is not packaged.")
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	file.close()
	if parse_error != OK or not parser.data is Dictionary:
		return _native_manifest_failure("The bundled native plugin compatibility manifest is malformed.")
	_native_manifest = parser.data
	var manifest := _native_manifest
	if manifest.get("schema") != NATIVE_MANIFEST_SCHEMA or int(manifest.get("schema_version", 0)) != NATIVE_MANIFEST_VERSION:
		return _native_manifest_failure("The native plugin manifest schema is unsupported.")
	var plugin: Variant = manifest.get("plugin")
	var compatibility: Variant = manifest.get("compatibility")
	if not plugin is Dictionary or not compatibility is Dictionary:
		return _native_manifest_failure("The native plugin manifest plugin or compatibility identity is missing.")
	var plugin_data: Dictionary = plugin
	var compatibility_data: Dictionary = compatibility
	if str(plugin_data.get("id", "")) != NATIVE_PLUGIN_ID or str(plugin_data.get("version", "")) != MCP_VERSION:
		return _native_manifest_failure("The native plugin manifest must identify godot-tools at MCP version 1.16.0.")
	if (
		str(compatibility_data.get("godot_mcp_version", "")) != MCP_VERSION
		or str(compatibility_data.get("opencode_version", "")) != NATIVE_PLUGIN_API_VERSION
		or str(compatibility_data.get("opencode_plugin_api", "")) != NATIVE_PLUGIN_API_VERSION
		or str(compatibility_data.get("zod_version", "")) != NATIVE_ZOD_VERSION
		or int(compatibility_data.get("bridge_protocol_version", 0)) != BRIDGE_PROTOCOL_VERSION
	):
		return _native_manifest_failure("The native plugin manifest does not match the pinned MCP, OpenCode, Zod, or bridge protocol versions.")
	if str(plugin_data.get("format", "")) != "esm" or str(plugin_data.get("runtime", "")) != "bundled-opencode-bun":
		return _native_manifest_failure("The native plugin manifest does not attest the bundled ESM runtime format.")
	var artifact_path_result := _resolve_payload_path(addon_root, str(plugin_data.get("path", "")))
	if not artifact_path_result.get("ok", false):
		return _native_manifest_failure("The native plugin artifact path is invalid: %s" % artifact_path_result.get("error", "unknown validation failure"))
	var expected_path := _resolve_payload_path(addon_root, NATIVE_ARTIFACT_RELATIVE_PATH)
	if not expected_path.get("ok", false) or not _same_ownership_path(str(artifact_path_result.get("path", "")), str(expected_path.get("path", ""))):
		return _native_manifest_failure("The native plugin artifact must be runtime/opencode-plugins/godot-tools.js.")
	var artifact_validation := _validate_native_artifact_file(plugin_data, str(artifact_path_result["path"]))
	if not artifact_validation.get("ok", false):
		return _native_manifest_failure(str(artifact_validation.get("error", "native artifact validation failed")))
	if not _native_profile_counts_match(manifest.get("profiles", {})):
		return _native_manifest_failure("The native plugin manifest must attest exactly 35 opencode-default and 178 full catalog tools.")
	var gates: Variant = manifest.get("gates")
	if not gates is Dictionary:
		return _native_manifest_failure("The native plugin manifest gate attestations are missing.")
	var gate_data: Dictionary = gates
	for gate: String in ["catalog_parity", "packaged_plugin_loading", "supported_platform_smoke", "multi_project_isolation"]:
		if not bool(gate_data.get(gate, false)):
			_native_diagnostics.append("Native default gate is not attested: %s" % gate)
	var all_gates := _all_native_default_gates(gate_data)
	var native_default_attested := bool(manifest.get("native_default_attested", false))
	var default_integration_mode := str(manifest.get("default_integration_mode", ""))
	var expected_default_mode := "native" if all_gates else "mcp"
	if native_default_attested != all_gates or default_integration_mode != expected_default_mode:
		return _native_manifest_failure("The native manifest default mode and attestation must exactly match all required gate attestations.")
	return {
		"ok": true,
		"artifact_path": str(artifact_path_result["path"]),
		"sha256": str(plugin_data.get("sha256", "")).trim_prefix("sha256:").to_lower(),
		"size_bytes": int(plugin_data.get("size_bytes", 0)),
		"build_fingerprint": str(plugin_data.get("build_fingerprint", "")),
		"source_fingerprint": str(plugin_data.get("source_fingerprint", "")),
		"native_default_attested": native_default_attested,
		"default_integration_mode": default_integration_mode,
	}


func _native_manifest_failure(message: String) -> Dictionary:
	_native_diagnostics.append(message)
	return {"ok": false, "error": message}


func _native_profile_counts_match(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var profiles: Dictionary = value
	return str(profiles.get("default", "")) == "opencode-default" \
		and int(profiles.get("default_v1_count", 0)) == NATIVE_PROFILE_TOOL_COUNT \
		and int(profiles.get("full_count", 0)) == FULL_PROFILE_TOOL_COUNT \
		and _valid_source_fingerprint(str(profiles.get("manifest_sha256", "")))


func _validate_native_artifact_file(entry: Dictionary, path: String) -> Dictionary:
	var expected_hash := str(entry.get("sha256", "")).trim_prefix("sha256:").to_lower()
	if expected_hash.length() != 64 or not expected_hash.is_valid_hex_number(false) or not _valid_source_fingerprint(str(entry.get("source_fingerprint", ""))) or str(entry.get("build_fingerprint", "")).is_empty():
		return {"ok": false, "error": "native artifact checksum, source, or build identity is invalid"}
	if not FileAccess.file_exists(path) or FileAccess.get_sha256(path).to_lower() != expected_hash:
		return {"ok": false, "error": "native artifact is missing or failed SHA-256 integrity validation"}
	var file := FileAccess.open(path, FileAccess.READ)
	var actual_size := file.get_length() if file != null else -1
	if file != null:
		file.close()
	if int(entry.get("size_bytes", 0)) <= 0 or actual_size != int(entry.get("size_bytes", 0)):
		return {"ok": false, "error": "native artifact size does not match the manifest"}
	return {"ok": true}


func _all_native_default_gates(gates: Dictionary) -> bool:
	return bool(gates.get("catalog_parity", false)) \
		and bool(gates.get("packaged_plugin_loading", false)) \
		and bool(gates.get("supported_platform_smoke", false)) \
		and bool(gates.get("multi_project_isolation", false))


func _mode_state_path() -> String:
	return ProjectSettings.globalize_path(MODE_STATE_ROOT).path_join(project_hash).path_join("mode.json")


func _load_requested_integration_mode() -> String:
	var path := _mode_state_path()
	if not FileAccess.file_exists(path):
		return ""
	var stored := _read_json(path)
	if not stored is Dictionary:
		diagnostic.emit("integration-mode", "Ignoring malformed project-scoped integration mode state.")
		return ""
	var data: Dictionary = stored
	if data.get("schema") != "opencode-godot-integration-mode" or int(data.get("schema_version", 0)) != 1 or data.get("project_hash") != project_hash:
		diagnostic.emit("integration-mode", "Ignoring integration mode state not owned by this project.")
		return ""
	var mode := str(data.get("mode", ""))
	if mode not in ["mcp", "native"]:
		diagnostic.emit("integration-mode", "Ignoring invalid project-scoped integration mode state.")
		return ""
	return mode


func _write_requested_integration_mode(mode: String) -> bool:
	var path := _mode_state_path()
	if not _ensure_private_directory(path.get_base_dir()):
		return false
	return _write_private_json_atomic(path, {
		"schema": "opencode-godot-integration-mode",
		"schema_version": 1,
		"project_hash": project_hash,
		"canonical_project": canonical_project,
		"mode": mode,
	})


func _prepare_previous_ownership() -> Dictionary:
	var ownership_path := runtime_dir.path_join("ownership.json")
	if not FileAccess.file_exists(ownership_path) and not FileAccess.file_exists(ownership_path + ".bak"):
		return {"ok": true}
	var ownership := _read_json(ownership_path)
	if not ownership is Dictionary:
		return _fail("ownership", "Previous OpenCode ownership record is malformed; refusing unsafe replacement.")
	var validation := _validate_daemon_ownership_record(ownership, true)
	if not validation.get("ok", false):
		return _fail("ownership", "Previous OpenCode ownership record is invalid: %s" % validation.get("error", "schema validation failed"))
	if validation.get("pending", false):
		return _fail("ownership", "Previous OpenCode ownership identity is incomplete; state and process were preserved.")
	var pid := int(ownership["pid"])
	var started_at_ms := int(ownership["started_at_ms"])
	var nonce := str(ownership["launch_nonce"])
	var identity := _inspect_process_identity(pid, started_at_ms)
	if identity.get("matches", false):
		return _fail("ownership", "A prior daemon for this project is still running but its one-time credential is unavailable. It was not adopted or terminated.")
	if not identity.get("stale", false):
		return _fail("ownership", "A prior daemon identity cannot be verified. State and process were preserved.")
	if not _cleanup_stale_ownership(ownership, ownership_path, false):
		return _fail("mcp-ownership", "Previous OpenCode daemon is stale, but its MCP sidecar ownership could not be safely reclaimed. Ownership evidence was preserved.")
	# This is the only recovery path that clears an UNKNOWN launch tombstone:
	# process identity was proven STALE and every nonce-bound artifact was
	# reclaimed successfully.
	_launch_ownership_uncertain = false
	diagnostic.emit("ownership", "Reclaimed verified stale OpenCode ownership state without terminating a process.")
	return {"ok": true}


func _validate_daemon_ownership_record(record: Dictionary, allow_pending: bool = false) -> Dictionary:
	if not _has_exact_keys(record, DAEMON_OWNERSHIP_FIELDS):
		return {"ok": false, "error": "schema fields are missing or unknown"}
	if (
		not record["schema"] is String
		or record["schema"] != DAEMON_OWNERSHIP_SCHEMA
		or not _json_nonnegative_integer(record["schema_version"])
		or record["schema_version"] != DAEMON_OWNERSHIP_SCHEMA_VERSION
	):
		return {"ok": false, "error": "schema or version is invalid"}
	if (
		not record["project_hash"] is String
		or record["project_hash"] != project_hash
		or not record["canonical_project"] is String
		or record["canonical_project"] != canonical_project
	):
		return {"ok": false, "error": "project binding is invalid"}
	var nonce: Variant = record["launch_nonce"]
	if not nonce is String or not Protocol.validate_nonce(nonce, 16):
		return {"ok": false, "error": "launch nonce is invalid"}
	var phase: Variant = record["phase"]
	if not phase is String or phase not in ["launching", "listening"]:
		return {"ok": false, "error": "phase is invalid"}
	var pid: Variant = record["pid"]
	var started_at_ms: Variant = record["started_at_ms"]
	var port: Variant = record["port"]
	var executable_size: Variant = record["executable_size_bytes"]
	if (
		not _json_nonnegative_integer(pid)
		or not _json_nonnegative_integer(started_at_ms)
		or not _json_nonnegative_integer(port)
		or not _json_positive_integer(executable_size)
	):
		return {"ok": false, "error": "numeric identity fields are invalid"}
	var pending := int(pid) <= 0 or int(started_at_ms) <= 0
	if pending and (not allow_pending or phase != "launching"):
		return {"ok": false, "error": "process identity is incomplete"}
	if not record["process_start"] is String or not record["hostname"] is String:
		return {"ok": false, "error": "listen identity types are invalid"}
	if record["hostname"] != "127.0.0.1":
		return {"ok": false, "error": "listen hostname is invalid"}
	if phase == "launching":
		if record["process_start"] != "" or int(port) != 0:
			return {"ok": false, "error": "launching record has listen-only fields"}
	else:
		if pending or int(port) < 1 or int(port) > 65535 or record["process_start"] == "":
			return {"ok": false, "error": "listening identity is incomplete"}
	if not record["opencode_path"] is String or not record["opencode_path"].is_absolute_path():
		return {"ok": false, "error": "OpenCode path is not absolute"}
	var expected_opencode_path := str(_payload.get("opencode_path", ""))
	var expected_opencode_hash := str(_payload.get("opencode_sha256", "")).trim_prefix("sha256:").to_lower()
	var expected_build := str(_payload.get("opencode_build_fingerprint", ""))
	var expected_size: Variant = _payload.get("opencode_size_bytes", 0)
	if (
		expected_opencode_path.is_empty()
		or not _same_ownership_path(record["opencode_path"], expected_opencode_path)
		or expected_opencode_hash.length() != 64
		or not expected_opencode_hash.is_valid_hex_number(false)
		or not _json_positive_integer(expected_size)
		or not record["executable_sha256"] is String
		or str(record["executable_sha256"]).trim_prefix("sha256:").to_lower() != expected_opencode_hash
		or int(record["executable_size_bytes"]) != int(expected_size)
		or not record["opencode_version"] is String
		or record["opencode_version"] != NATIVE_PLUGIN_API_VERSION
		or not record["build_fingerprint"] is String
		or record["build_fingerprint"] != expected_build
	):
		return {"ok": false, "error": "OpenCode executable identity does not match the pinned payload"}
	var expected_listen_path := runtime_dir.path_join("listen-%s.json" % str(nonce))
	if (
		not record["listen_record_path"] is String
		or not _same_ownership_path(record["listen_record_path"], expected_listen_path)
	):
		return {"ok": false, "error": "listen record path is not nonce-bound"}
	var integration_mode: Variant = record["integration_mode"]
	if not integration_mode is String or integration_mode not in ["mcp", "native"]:
		return {"ok": false, "error": "integration mode is invalid"}
	if not record["mcp_ownership_path"] is String or not record["native_plugin"] is Dictionary:
		return {"ok": false, "error": "integration ownership fields have invalid types"}
	if integration_mode == "mcp":
		if not _same_ownership_path(record["mcp_ownership_path"], _mcp_ownership_path(str(nonce))) or not (record["native_plugin"] as Dictionary).is_empty():
			return {"ok": false, "error": "MCP ownership binding is invalid"}
	else:
		if record["mcp_ownership_path"] != "":
			return {"ok": false, "error": "native ownership has an MCP path"}
		var native: Dictionary = record["native_plugin"]
		var expected_native_path := str(_payload.get("native_path", ""))
		var expected_native_hash := str(_payload.get("native_sha256", "")).trim_prefix("sha256:").to_lower()
		var expected_native_build := str(_payload.get("native_build_fingerprint", ""))
		if not _has_exact_keys(native, ["id", "path", "sha256", "build_fingerprint"]):
			return {"ok": false, "error": "native plugin schema is invalid"}
		if not native["id"] is String or not native["path"] is String or not native["sha256"] is String or not native["build_fingerprint"] is String:
			return {"ok": false, "error": "native plugin field types are invalid"}
		if (
			native["id"] != NATIVE_PLUGIN_ID
			or expected_native_path.is_empty()
			or not _same_ownership_path(str(native["path"]), expected_native_path)
			or expected_native_hash.length() != 64
			or native["sha256"] != "sha256:" + expected_native_hash
			or native["build_fingerprint"] != expected_native_build
		):
			return {"ok": false, "error": "native plugin identity does not match the pinned payload"}
	if not record["bridge_owner_nonce"] is String or not Protocol.validate_nonce(record["bridge_owner_nonce"], 16):
		return {"ok": false, "error": "bridge owner nonce is invalid"}
	if bridge_session == null or not record["bridge_discovery_path"] is String or not _same_ownership_path(record["bridge_discovery_path"], str(bridge_session.discovery_path)):
		return {"ok": false, "error": "bridge discovery path is invalid"}
	return {"ok": true, "pending": pending}


func _has_exact_keys(record: Dictionary, expected: Array) -> bool:
	var actual := record.keys()
	actual.sort()
	var normalized_expected := expected.duplicate()
	normalized_expected.sort()
	return actual == normalized_expected


func _json_nonnegative_integer(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number := float(value)
	return number >= 0.0 and number <= 9007199254740991.0 and number == floor(number)


func _json_positive_integer(value: Variant) -> bool:
	return _json_nonnegative_integer(value) and value > 0


func _matching_incomplete_launch_record() -> bool:
	if launch_nonce.is_empty():
		return false
	var ownership_path := runtime_dir.path_join("ownership.json")
	if not FileAccess.file_exists(ownership_path) and not FileAccess.file_exists(ownership_path + ".bak"):
		return false
	var ownership := _read_json(ownership_path)
	if not ownership is Dictionary:
		return true
	if ownership.get("launch_nonce") != launch_nonce or ownership.get("project_hash") != project_hash:
		return true
	var validation := _validate_daemon_ownership_record(ownership, true)
	return not validation.get("ok", false) or bool(validation.get("pending", false))


func _remove_file_if_present(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return true
	if DirAccess.remove_absolute(path) != OK:
		return not FileAccess.file_exists(path)
	return not FileAccess.file_exists(path)


func _remove_nonce_bound_json_pair(path: String, nonce: String) -> bool:
	if path.get_base_dir() != runtime_dir:
		return false
	for candidate: String in [path, path + ".bak"]:
		if not FileAccess.file_exists(candidate):
			continue
		var record := _read_json(candidate)
		if not record is Dictionary or record.get("launch_nonce") != nonce or record.get("project_hash") != project_hash:
			return false
		if not _remove_file_if_present(candidate):
			return false
	return true


func _nonce_bound_json_pair_is_safe(path: String, nonce: String) -> bool:
	if path.get_base_dir() != runtime_dir:
		return false
	for candidate: String in [path, path + ".bak"]:
		if not FileAccess.file_exists(candidate):
			continue
		var record := _read_json(candidate)
		if not record is Dictionary or record.get("launch_nonce") != nonce or record.get("project_hash") != project_hash:
			return false
	return true


func _cleanup_stale_ownership(ownership: Dictionary, ownership_path: String, allow_pending: bool = false) -> bool:
	var validation := _validate_daemon_ownership_record(ownership, allow_pending)
	if not validation.get("ok", false) or validation.get("pending", false):
		diagnostic.emit("ownership", "Preserving stale ownership evidence because the daemon record is incomplete or malformed.")
		return false
	var nonce := str(ownership.get("launch_nonce", ""))
	var expected_ownership_path := runtime_dir.path_join("ownership.json")
	if not _same_ownership_path(ownership_path, expected_ownership_path):
		return false
	var backup_path := ownership_path + ".bak"
	if FileAccess.file_exists(backup_path):
		var backup := _read_json(backup_path)
		if not backup is Dictionary or backup.get("launch_nonce") != nonce or backup.get("project_hash") != project_hash:
			return false
		var backup_validation := _validate_daemon_ownership_record(backup, false)
		if not backup_validation.get("ok", false):
			return false
	var listen_path := str(ownership["listen_record_path"])
	var descriptor_path := runtime_dir.path_join("launch-%s.json" % nonce)
	if not _nonce_bound_json_pair_is_safe(listen_path, nonce) or not _nonce_bound_json_pair_is_safe(descriptor_path, nonce):
		return false
	# A stale OpenCode parent can have left behind a live sidecar. Reclaim that
	# first; otherwise retain the parent binding as recovery evidence.
	if str(ownership.get("integration_mode", "mcp")) == "mcp" and not _cleanup_owned_mcp_ownership(ownership):
		return false
	if str(ownership.get("integration_mode", "mcp")) == "native" and FileAccess.file_exists(str(ownership.get("bridge_discovery_path", ""))):
		diagnostic.emit("native-ownership", "Preserving stale native ownership evidence because discovery cleanup was not verified.")
		return false
	if not _remove_nonce_bound_json_pair(listen_path, nonce):
		return false
	_cleanup_atomic_temporary(listen_path, nonce)
	if not _remove_nonce_bound_json_pair(descriptor_path, nonce):
		return false
	_cleanup_atomic_temporary(descriptor_path, nonce)
	if not _remove_file_if_present(ownership_path) or not _remove_file_if_present(backup_path):
		return false
	_cleanup_atomic_temporary(ownership_path, nonce)
	return true


func _build_owned_config() -> Dictionary:
	if current_integration_mode == "native":
		var editor_identity := _bridge_editor_identity()
		return {
			"plugin": [[
				_file_url(str(_payload.get("native_path", ""))),
				{
					"canonical_project": canonical_project,
					"launch_nonce": launch_nonce,
					"bridge_session_file": str(bridge_session.session_path),
					"bridge_owner_nonce": str(bridge_session.owner_nonce),
					"bridge_discovery_path": str(bridge_session.discovery_path),
					"editor": {
						"pid": int(editor_identity.get("pid", 0)),
						"started_at_ms": int(editor_identity.get("started_at_ms", 0)),
					},
					"profile": "opencode-default",
					"timeout": NATIVE_TIMEOUT_MS,
				}
			]]
		}
	var mcp_ownership_path := _mcp_ownership_path(launch_nonce)
	return {
		"mcp": {
			"godot": {
				"type": "local",
				"command": [str(_payload.get("mcp_path", ""))],
				"environment": {
					"GODOT_PROJECT_PATH": canonical_project,
					"GODOT_MCP_SESSION_FILE": str(bridge_session.session_path),
					"OPENCODE_GODOT_LAUNCH_NONCE": launch_nonce,
					"GODOT_MCP_OWNERSHIP_FILE": mcp_ownership_path,
					"GODOT_MCP_EXPECTED_EXECUTABLE": str(_payload.get("mcp_path", "")),
					"GODOT_MCP_EXPECTED_EXECUTABLE_SHA256": "sha256:" + str(_payload.get("mcp_sha256", "")),
					"GODOT_MCP_EXPECTED_BUILD_FINGERPRINT": str(_payload.get("mcp_build_fingerprint", "")),
				},
				"enabled": bool(_payload.get("mcp_available", false)),
			}
		}
	}


func _file_url(path: String) -> String:
	# Godot's URI encoder correctly escapes spaces, Unicode, and literal '%'.
	# Preserve URI separators and the Windows drive separator after encoding.
	var normalized := path.replace("\\", "/").simplify_path()
	if normalized.begins_with("//"):
		var unc := normalized.trim_prefix("//")
		var slash := unc.find("/")
		if slash <= 0:
			return ""
		var host := unc.left(slash).uri_encode()
		var share_path := unc.substr(slash).uri_encode().replace("%2F", "/").replace("%2f", "/")
		return "file://%s%s" % [host, share_path]
	var encoded := normalized.uri_encode().replace("%2F", "/").replace("%2f", "/").replace("%3A", ":").replace("%3a", ":")
	if encoded.length() >= 3 and encoded.substr(1, 2) == ":/":
		return "file:///" + encoded
	return "file://" + encoded


func _build_descriptor(config_content: String, listen_record_path: String) -> Dictionary:
	# This shape is intentionally exact. The daemon rejects both missing and
	# unknown keys so a stale addon cannot silently weaken the launch contract.
	var editor_identity := _bridge_editor_identity()
	return {
		"schema": DESCRIPTOR_SCHEMA,
		"schema_version": DESCRIPTOR_VERSION,
		"hostname": "127.0.0.1",
		"port": 0,
		"canonical_project": canonical_project,
		"project_hash": project_hash,
		"editor": {
			"pid": int(editor_identity.get("pid", 0)),
			"start": str(editor_identity.get("started_at_ms", 0)),
		},
		"launch_nonce": launch_nonce,
		"password": password,
		"config": config_content,
		"listen_record_path": listen_record_path,
		"opencode": {
			"version": "1.17.18",
			"build_fingerprint": str(_payload.get("opencode_build_fingerprint", "")),
		},
	}


func _bridge_editor_identity() -> Dictionary:
	if bridge_session == null:
		return {}
	var pid: Variant = bridge_session.coordinator_pid
	var started_at_ms: Variant = bridge_session.coordinator_started_at_ms
	if not _positive_safe_integer(pid) or not _positive_safe_integer(started_at_ms):
		return {}
	return {
		"pid": int(pid),
		"started_at_ms": int(started_at_ms),
	}


func _try_read_listen_record() -> void:
	if launch_nonce.is_empty() or state != "starting":
		return
	var path := runtime_dir.path_join("listen-%s.json" % launch_nonce)
	if not FileAccess.file_exists(path):
		return
	var record := _read_json(path)
	if not record is Dictionary or record.get("schema") != LISTEN_SCHEMA or int(record.get("schema_version", 0)) != 1:
		return
	if record.get("launch_nonce") != launch_nonce or record.get("project_hash") != project_hash:
		diagnostic.emit("daemon", "Ignoring listen record that does not match this project launch.")
		return
	var port := int(record.get("port", 0))
	var expected_fingerprint := str(_payload.get("opencode_build_fingerprint", ""))
	if (
		port < 1 or port > 65535
		or record.get("hostname") != "127.0.0.1"
		or int(record.get("pid", 0)) != daemon_pid
		or str(record.get("process_start", "")).is_empty()
		or record.get("opencode_version") != "1.17.18"
		or record.get("build_fingerprint") != expected_fingerprint
	):
		diagnostic.emit("daemon", "Ignoring incomplete or incompatible OpenCode listen record.")
		return
	_listen_record = record
	if not _write_ownership_record(path, "listening"):
		_handle_exit("Could not atomically persist the authenticated daemon ownership record.")
		return
	base_url = "http://127.0.0.1:%d" % port
	_set_state("probing", "Authenticating managed OpenCode ownership")
	_start_probe("health")


func _handle_exit(message: String) -> void:
	if state == "stopped" or state == "stopping":
		return
	diagnostic.emit("daemon", message)
	_clear_live_transport_state()
	_release_child_pipes()
	_redaction_tail = ""
	# The process/health path is no longer usable even if ownership cleanup or a
	# bounded restart still follows. Invalidate HTTP/SSE consumers immediately;
	# generation deduplication prevents repeated exit observations from emitting
	# duplicate interruption events.
	_emit_daemon_stopped(generation)
	var ownership_requires_recovery := _launch_ownership_uncertain or _matching_incomplete_launch_record()
	var safe_to_clean := daemon_pid <= 0 and not ownership_requires_recovery
	if daemon_pid > 0:
		var identity := _inspect_daemon_identity(true)
		if identity.get("matches", false):
			OS.kill(daemon_pid)
			OS.delay_msec(25)
			identity = _inspect_daemon_identity(true)
			safe_to_clean = identity.get("stale", false)
		elif identity.get("stale", false):
			safe_to_clean = true
		else:
			_launch_ownership_uncertain = true
			_reap_process_lifetime_drain_workers()
			_fail("ownership", "Daemon identity is unknown; preserving the possible orphan and refusing automatic restart.")
			return
	_reap_process_lifetime_drain_workers()
	if not safe_to_clean:
		_launch_ownership_uncertain = true
		_fail("ownership", "Daemon ownership is incomplete or UNKNOWN; preserving nonce-bound state and refusing automatic restart.")
		return
	if safe_to_clean and not _cleanup_owned_runtime_files():
		_fail("mcp-ownership", "OpenCode exited, but MCP ownership evidence was preserved because the sidecar could not be safely reclaimed.")
		return
	daemon_pid = 0
	daemon_started_at_ms = 0
	_clear_live_transport_state()
	launch_nonce = ""
	_launch_ownership_uncertain = false
	if _restart_attempt >= MAX_RESTART_ATTEMPTS:
		_fail("daemon", "%s Retry limit reached." % message)
		return
	var delay: float = RESTART_BACKOFF_SECONDS[_restart_attempt]
	_restart_attempt += 1
	_restart_after_ms = Protocol.now_ms() + int(delay * 1000.0)
	_set_state("backoff", "%s Restarting in %.1f seconds." % [message, delay])


func _emit_daemon_stopped(stopped_generation: int) -> void:
	if _last_stopped_signal_generation == stopped_generation:
		return
	_last_stopped_signal_generation = stopped_generation
	daemon_stopped.emit(stopped_generation)


func _start_probe(operation: String) -> void:
	if base_url.is_empty() or _probe_client != null:
		return
	_probe_operation = operation
	_probe_after_ms = Protocol.now_ms()


func _update_probe() -> void:
	if _probe_client == null:
		if not _probe_operation.is_empty() and Protocol.now_ms() >= _probe_after_ms:
			_connect_probe()
		return
	var poll_error := _probe_client.poll()
	if poll_error != OK:
		_probe_failed("Managed-health transport failed: %s" % error_string(poll_error))
		return
	var status := _probe_client.get_status()
	match status:
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_REQUESTING:
			return
		HTTPClient.STATUS_CONNECTED:
			if _probe_phase == "connecting":
				_send_probe_request()
				return
			if _probe_phase == "body":
				_finish_probe_response()
				return
			if _probe_client.has_response():
				_capture_probe_response()
				if _probe_client.get_response_body_length() == 0:
					_finish_probe_response()
		HTTPClient.STATUS_BODY:
			_capture_probe_response()
			_probe_phase = "body"
			var chunk := _probe_client.read_response_body_chunk()
			if not chunk.is_empty():
				_probe_body.append_array(chunk)
				if _probe_body.size() > MAX_PROBE_BODY_BYTES:
					_probe_failed("Managed-health response is too large", true)
		HTTPClient.STATUS_DISCONNECTED, HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			_probe_failed("Managed-health connection unavailable (status %d)" % status)


func _connect_probe() -> void:
	_probe_client = HTTPClient.new()
	_probe_phase = "connecting"
	_probe_code = 0
	_probe_body.clear()
	var port := int(_listen_record.get("port", 0))
	var connect_error := _probe_client.connect_to_host("127.0.0.1", port)
	if connect_error != OK:
		_probe_failed("Managed-health connect failed: %s" % error_string(connect_error))


func _send_probe_request() -> void:
	var path := "/global/godot-health"
	if _probe_operation == "project":
		# Project.Info.worktree is `/` for a valid non-Git project, so it cannot
		# prove instance routing. `/path` exposes the exact routed instance
		# directory for both Git and non-Git projects.
		path = "/path"
	var authorization := Marshalls.utf8_to_base64("opencode:%s" % password)
	var headers := PackedStringArray([
		"Authorization: Basic %s" % authorization,
		"Accept: application/json",
		"x-opencode-directory: %s" % canonical_project.uri_encode(),
	])
	var request_error := _probe_client.request(HTTPClient.METHOD_GET, path, headers)
	if request_error != OK:
		_probe_failed("Managed-health request failed: %s" % error_string(request_error))
		return
	_probe_phase = "requesting"


func _capture_probe_response() -> void:
	if _probe_code == 0 and _probe_client.has_response():
		_probe_code = _probe_client.get_response_code()


func _finish_probe_response() -> void:
	_capture_probe_response()
	var text := _probe_body.get_string_from_utf8()
	if _probe_code == 401 or _probe_code == 403:
		_probe_failed("Managed OpenCode rejected its launch credential", true)
		return
	if _probe_code < 200 or _probe_code >= 300:
		_probe_failed("Managed-health returned HTTP %d" % _probe_code)
		return
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		_probe_failed("Managed-health returned malformed JSON", true)
		return
	var response: Dictionary = parser.data
	var operation := _probe_operation
	_reset_probe(true)
	if operation == "health":
		if not _health_matches_listen_record(response):
			_probe_failed("Authenticated health does not match the owned listen record", true)
			return
		_probe_failures = 0
		_last_health_ms = Protocol.now_ms()
		if state == "probing":
			_start_probe("project")
		return
	if operation == "project":
		if not _project_probe_matches(response):
			_probe_failed("Directory-bound probe targeted a different project", true)
			return
		_probe_failures = 0
		_restart_attempt = 0
		_last_health_ms = Protocol.now_ms()
		_set_state("ready", "OpenCode daemon ownership and project routing verified")
		daemon_ready.emit(base_url, password, generation)


func _health_matches_listen_record(response: Dictionary) -> bool:
	for field: String in ["schema", "schema_version", "hostname", "port", "pid", "process_start", "project_hash", "launch_nonce", "opencode_version", "build_fingerprint"]:
		if response.get(field) != _listen_record.get(field):
			return false
	return response.get("schema") == LISTEN_SCHEMA and int(response.get("schema_version", 0)) == DESCRIPTOR_VERSION


func _project_probe_matches(response: Dictionary) -> bool:
	var instance_path: Dictionary = response.get("data", response) if response.get("data", response) is Dictionary else {}
	var path: Variant = instance_path.get("directory", "")
	if not path is String or path.is_empty():
		return false
	return Protocol.canonicalize_project_path(path) == canonical_project


func _probe_failed(message: String, fatal: bool = false) -> void:
	_reset_probe(false)
	_probe_failures += 1
	diagnostic.emit("health", message)
	var limit := 3 if state == "ready" else STARTUP_PROBE_RETRIES
	if fatal or _probe_failures >= limit:
		_handle_exit(message)
		return
	_probe_operation = "health"
	_probe_after_ms = Protocol.now_ms() + mini(1000, 100 * (1 << mini(_probe_failures, 3)))


func _reset_probe(clear_operation: bool = true) -> void:
	if _probe_client != null:
		_probe_client.close()
	_probe_client = null
	_probe_phase = "idle"
	_probe_code = 0
	_probe_body.clear()
	if clear_operation:
		_probe_operation = ""


func _clear_live_transport_state() -> void:
	# UNKNOWN/error paths may retain PID/start/nonce evidence for recovery, but
	# never retain credentials or a transport endpoint that callers could reuse.
	password = ""
	base_url = ""
	_listen_record.clear()
	_redaction_tail = ""
	_reset_probe()


func _write_ownership_record(listen_record_path: String, phase: String) -> bool:
	var process_start := ""
	var port := 0
	if phase == "listening":
		process_start = str(_listen_record.get("process_start", ""))
		port = int(_listen_record.get("port", 0))
	return _write_private_json_atomic(runtime_dir.path_join("ownership.json"), {
		"schema": DAEMON_OWNERSHIP_SCHEMA,
		"schema_version": DAEMON_OWNERSHIP_SCHEMA_VERSION,
		"phase": phase,
		"project_hash": project_hash,
		"canonical_project": canonical_project,
		"launch_nonce": launch_nonce,
		"pid": daemon_pid,
		"started_at_ms": daemon_started_at_ms,
		"process_start": process_start,
		"hostname": "127.0.0.1",
		"port": port,
		"opencode_path": str(_payload.get("opencode_path", "")),
		"executable_sha256": str(_payload.get("opencode_sha256", "")),
		"executable_size_bytes": int(_payload.get("opencode_size_bytes", 0)),
		"opencode_version": "1.17.18",
		"build_fingerprint": str(_payload.get("opencode_build_fingerprint", "")),
		"listen_record_path": listen_record_path,
		"integration_mode": current_integration_mode,
		"mcp_ownership_path": _mcp_ownership_path(launch_nonce) if current_integration_mode == "mcp" else "",
		"native_plugin": {
			"id": NATIVE_PLUGIN_ID,
			"path": str(_payload.get("native_path", "")),
			"sha256": "sha256:" + str(_payload.get("native_sha256", "")),
			"build_fingerprint": str(_payload.get("native_build_fingerprint", "")),
		} if current_integration_mode == "native" else {},
		"bridge_owner_nonce": str(bridge_session.owner_nonce),
		"bridge_discovery_path": str(bridge_session.discovery_path),
	})


func _abort_failed_launch(descriptor_path: String, listen_record_path: String, message: String) -> Dictionary:
	# Capture this before releasing the handles.  A handle without a PID is still
	# evidence that execute_with_pipe created or attempted to own a child; it is
	# not proof that no process exists.  Only the explicit no-PID/no-handle case
	# is safe to clean without further identity verification.
	var returned_handle := _control_lease != null or _stderr_pipe != null
	_release_child_pipes()
	_reap_process_lifetime_drain_workers()
	_clear_live_transport_state()
	var ownership_proven := false
	if daemon_pid > 0 and daemon_started_at_ms > 0:
		var identity := _inspect_daemon_identity(true)
		if identity.get("matches", false):
			# MATCH is the only identity result that authorizes termination.  An
			# initially STALE result is already safe to reclaim and never reaches
			# this branch; UNKNOWN is preserved below.
			_terminate_process(daemon_pid)
			OS.delay_msec(25)
			identity = _inspect_daemon_identity(true)
			_reap_process_lifetime_drain_workers()
			ownership_proven = identity.get("stale", false)
			if not ownership_proven:
				_launch_ownership_uncertain = true
				return _fail("ownership", "%s The launched PID could not be safely reclaimed; ownership remains UNKNOWN and nonce-bound state was retained." % message)
		elif identity.get("stale", false):
			# The first observation proved that this PID/start pair is no longer
			# live.  No process termination is permitted in this path.
			ownership_proven = true
		else:
			_launch_ownership_uncertain = true
			return _fail("ownership", "%s The launched PID could not be verified; ownership remains UNKNOWN and nonce-bound state was retained." % message)
	elif daemon_pid > 0:
		_launch_ownership_uncertain = true
		return _fail("ownership", "%s The launched PID has no durable start identity; ownership remains UNKNOWN and nonce-bound state was retained." % message)
	elif returned_handle:
		_launch_ownership_uncertain = true
		return _fail("ownership", "%s The launch returned a process handle without a verifiable PID; ownership remains UNKNOWN and nonce-bound state was retained." % message)
	else:
		# No PID and no returned handle is the only launch failure that proves no
		# child ownership was handed back by the OS.  The pending record and
		# startup artifacts may be removed so a normal retry can proceed.
		ownership_proven = true
	if ownership_proven:
		_launch_ownership_uncertain = false
		_cleanup_failed_launch_artifacts(descriptor_path, listen_record_path)
		daemon_pid = 0
		daemon_started_at_ms = 0
		_reset_daemon_identity_cache()
	return _fail("daemon", message)


func _cleanup_failed_launch_artifacts(descriptor_path: String, listen_record_path: String) -> void:
	# Every path is exact, in our private runtime directory, and requires the
	# active nonce/project before deletion. This leaves uncertain state for a
	# later explicit recovery instead of widening cleanup scope.
	_cleanup_nonce_json(descriptor_path)
	_cleanup_nonce_json(listen_record_path)
	var ownership_path := runtime_dir.path_join("ownership.json")
	var ownership := _read_json(ownership_path)
	if ownership is Dictionary and ownership.get("launch_nonce") == launch_nonce and ownership.get("project_hash") == project_hash:
		var validation := _validate_daemon_ownership_record(ownership, true)
		if validation.get("ok", false):
			var backup_path := ownership_path + ".bak"
			var backup_safe := true
			if FileAccess.file_exists(backup_path):
				var backup := _read_json(backup_path)
				backup_safe = backup is Dictionary and backup.get("launch_nonce") == launch_nonce and backup.get("project_hash") == project_hash and _validate_daemon_ownership_record(backup, true).get("ok", false)
			if backup_safe:
				_remove_file_if_present(ownership_path)
				_remove_file_if_present(backup_path)
	_cleanup_atomic_temporary(descriptor_path, launch_nonce)
	_cleanup_atomic_temporary(listen_record_path, launch_nonce)
	_cleanup_atomic_temporary(ownership_path, launch_nonce)


func _cleanup_nonce_json(path: String) -> void:
	if path.get_base_dir() != runtime_dir:
		return
	_remove_nonce_bound_json_pair(path, launch_nonce)


func _uses_blocking_pipe_drain_workers() -> bool:
	if _pipe_drain_worker_runtime_detector.is_valid():
		return bool(_pipe_drain_worker_runtime_detector.call())
	return _is_blocking_pipe_drain_runtime(Engine.get_version_info())


func _is_blocking_pipe_drain_runtime(version_info: Dictionary) -> bool:
	# Godot 4.3's Unix and Windows FileAccess*Pipe classes return zero from
	# get_length(). get_buffer() is blocking, so the main thread cannot safely
	# use the normal readiness-gated drain loop on any supported host platform.
	return int(version_info.get("major", 0)) == 4 and int(version_info.get("minor", 0)) == 3


func _start_drain_workers() -> bool:
	if not _uses_blocking_pipe_drain_workers():
		return true
	if _control_lease == null or _stderr_pipe == null:
		return true # The launch result is rejected immediately after this call.
	var control_worker = ManagedPipeDrainWorker.new()
	if not control_worker.start(_control_lease):
		return false
	_control_drain_worker = control_worker
	_control_drain_drop_generation = 0
	_retain_process_lifetime_drain_worker(control_worker, false)
	var stderr_worker = ManagedPipeDrainWorker.new()
	if not stderr_worker.start(_stderr_pipe):
		return false
	_stderr_drain_worker = stderr_worker
	_stderr_drain_drop_generation = 0
	_retain_process_lifetime_drain_worker(stderr_worker, _uses_legacy_unix_stderr_quarantine())
	return true


func _process_lifetime_drain_workers() -> Array:
	if Engine.has_meta(PIPE_DRAIN_QUARANTINE_META_KEY):
		var stored: Variant = Engine.get_meta(PIPE_DRAIN_QUARANTINE_META_KEY)
		if stored is Array:
			return stored as Array
	var created: Array = []
	Engine.set_meta(PIPE_DRAIN_QUARANTINE_META_KEY, created)
	return created


func _process_lifetime_drain_worker_count() -> int:
	if not Engine.has_meta(PIPE_DRAIN_QUARANTINE_META_KEY):
		return 0
	var stored: Variant = Engine.get_meta(PIPE_DRAIN_QUARANTINE_META_KEY)
	return (stored as Array).size() if stored is Array else 0


func _retain_process_lifetime_drain_worker(worker, retain_forever: bool) -> void:
	if worker == null:
		return
	var retained := _process_lifetime_drain_workers()
	retained.append({"worker": worker, "retain_forever": retain_forever})
	Engine.set_meta(PIPE_DRAIN_QUARANTINE_META_KEY, retained)


func _release_process_lifetime_drain_worker(worker, include_permanent: bool = false) -> void:
	if worker == null or not Engine.has_meta(PIPE_DRAIN_QUARANTINE_META_KEY):
		return
	var retained := _process_lifetime_drain_workers()
	for index in range(retained.size() - 1, -1, -1):
		var record: Variant = retained[index]
		if record is Dictionary and record.get("worker") == worker and (include_permanent or not record.get("retain_forever", false)):
			retained.remove_at(index)
	Engine.set_meta(PIPE_DRAIN_QUARANTINE_META_KEY, retained)


func _reap_process_lifetime_drain_workers() -> void:
	if not Engine.has_meta(PIPE_DRAIN_QUARANTINE_META_KEY):
		return
	var retained := _process_lifetime_drain_workers()
	for index in range(retained.size() - 1, -1, -1):
		var record: Variant = retained[index]
		if not record is Dictionary:
			continue
		var worker = record.get("worker")
		if worker == null or not worker.join_if_finished():
			continue
		if record.get("retain_forever", false):
			# The only permanent worker is the affected Unix stderr reader. Once
			# it has finished, join it before script teardown and transfer the
			# native FileAccess to the older, native-only fd quarantine.
			_retain_legacy_stderr_pipe(worker.get_pipe(), true)
		retained.remove_at(index)
	Engine.set_meta(PIPE_DRAIN_QUARANTINE_META_KEY, retained)


func _pipe_drain_quarantine_limit_message() -> String:
	return "Godot 4.3 reached the safe background pipe-drain quarantine limit (%d workers). Restart the Godot editor before launching another OpenCode daemon." % PIPE_DRAIN_QUARANTINE_LIMIT


func _release_child_pipes() -> void:
	if _control_lease != null:
		if _control_drain_worker != null:
			_control_drain_worker.discard_and_sink()
			_control_drain_worker.close_pipe()
		else:
			_control_lease.close()
		_control_lease = null
	_release_stderr_pipe()
	_finalize_drain_workers()


func _finalize_drain_workers() -> void:
	if _control_drain_worker != null:
		if _control_drain_worker.join_if_finished():
			_release_process_lifetime_drain_worker(_control_drain_worker)
		_control_drain_worker = null
		_control_drain_drop_generation = 0
	if _stderr_drain_worker != null:
		if _stderr_drain_worker.join_if_finished():
			if _uses_legacy_unix_stderr_quarantine():
				# A completed GDScript worker is safe to release. Keep only the
				# native FileAccess in the pre-existing Engine quarantine; retaining
				# a GDScript Mutex/Thread object through script-server teardown is not.
				_retain_legacy_stderr_pipe(_stderr_drain_worker.get_pipe(), true)
				_release_process_lifetime_drain_worker(_stderr_drain_worker, true)
			else:
				_release_process_lifetime_drain_worker(_stderr_drain_worker)
		_stderr_drain_worker = null
		_stderr_drain_drop_generation = 0


func _uses_legacy_linux_stderr_quarantine() -> bool:
	return _uses_legacy_unix_stderr_quarantine()


func _uses_legacy_unix_stderr_quarantine() -> bool:
	return _is_legacy_unix_pipe_runtime(Engine.get_version_info(), OS.get_name())


func _is_legacy_linux_pipe_runtime(version_info: Dictionary, platform: String) -> bool:
	return _is_legacy_unix_pipe_runtime(version_info, platform)


func _is_legacy_unix_pipe_runtime(version_info: Dictionary, platform: String) -> bool:
	var major := int(version_info.get("major", 0))
	var minor := int(version_info.get("minor", 0))
	return platform in ["Linux", "macOS"] and major == 4 and minor >= 3 and minor < 5


func _legacy_stderr_quarantine_limit_message() -> String:
	return "Godot 4.3/4.4 Linux/macOS reached the safe execute_with_pipe stderr quarantine limit (%d). Restart the Godot editor before launching another OpenCode daemon." % LEGACY_STDERR_QUARANTINE_LIMIT


func _legacy_stderr_quarantine_is_full() -> bool:
	if not Engine.has_meta(LEGACY_STDERR_QUARANTINE_META_KEY):
		return false
	var stored: Variant = Engine.get_meta(LEGACY_STDERR_QUARANTINE_META_KEY)
	return stored is Array and (stored as Array).size() >= LEGACY_STDERR_QUARANTINE_LIMIT


func _legacy_stderr_quarantine() -> Array:
	if Engine.has_meta(LEGACY_STDERR_QUARANTINE_META_KEY):
		var stored: Variant = Engine.get_meta(LEGACY_STDERR_QUARANTINE_META_KEY)
		if stored is Array:
			return stored as Array
	var created: Array = []
	Engine.set_meta(LEGACY_STDERR_QUARANTINE_META_KEY, created)
	return created


func _legacy_stderr_quarantine_count() -> int:
	if not Engine.has_meta(LEGACY_STDERR_QUARANTINE_META_KEY):
		return 0
	var stored: Variant = Engine.get_meta(LEGACY_STDERR_QUARANTINE_META_KEY)
	return (stored as Array).size() if stored is Array else 0


func _retain_legacy_stderr_pipe(pipe: FileAccess, allow_limit_exceeded: bool = false) -> bool:
	if pipe == null:
		return true
	var retained := _legacy_stderr_quarantine()
	if retained.has(pipe):
		return true
	if retained.size() >= LEGACY_STDERR_QUARANTINE_LIMIT and not allow_limit_exceeded:
		return false
	# This Array is stored on the Engine singleton, not on this lifecycle. The
	# legacy Linux FileAccess must remain strongly referenced across plugin
	# disable/enable and native-to-MCP lifecycle replacement until editor exit.
	retained.append(pipe)
	Engine.set_meta(LEGACY_STDERR_QUARANTINE_META_KEY, retained)
	return true


func _release_stderr_pipe() -> void:
	var pipe := _stderr_pipe
	if pipe == null:
		return
	if _uses_legacy_unix_stderr_quarantine():
		# Never close or release this handle on Godot 4.3/4.4 Linux/macOS. Godot's
		# execute_with_pipe stderr destructor can close the editor's fd 0 there.
		# The Engine metadata Array owns the reference until editor process exit.
		if _stderr_drain_worker != null:
			_stderr_drain_worker.discard_and_sink()
		else:
			_retain_legacy_stderr_pipe(pipe, true)
		_stderr_pipe = null
		return
	_stderr_pipe = null
	if _stderr_drain_worker != null:
		_stderr_drain_worker.discard_and_sink()
		_stderr_drain_worker.close_pipe()
	else:
		pipe.close()


func _drain_child_output() -> void:
	var remaining := MAX_DRAIN_BYTES_PER_UPDATE
	if _control_drain_worker != null:
		remaining = _drain_worker(_control_drain_worker, remaining, true)
	else:
		remaining = _drain_pipe(_control_lease, remaining)
	if _stderr_drain_worker != null:
		_drain_worker(_stderr_drain_worker, remaining, false)
	else:
		_drain_pipe(_stderr_pipe, remaining)
	_reap_process_lifetime_drain_workers()


func _drain_worker(worker, remaining: int, control_stream: bool) -> int:
	if worker == null or remaining <= 0:
		return remaining
	var snapshot: Dictionary = worker.take_snapshot(mini(remaining, DRAIN_CHUNK_BYTES))
	var observed_drop_generation := int(snapshot.get("drop_generation", 0))
	var previous_drop_generation := _control_drain_drop_generation if control_stream else _stderr_drain_drop_generation
	if observed_drop_generation != previous_drop_generation:
		# A raw queue drop can split a credential exactly at its boundary. Do not
		# allow the old redaction tail or any already-buffered post-drop bytes to
		# join across it; start again from a known-safe boundary.
		if control_stream:
			_control_drain_drop_generation = observed_drop_generation
		else:
			_stderr_drain_drop_generation = observed_drop_generation
		worker.discard_queued()
		_redaction_tail = ""
		_output_buffer = (_output_buffer + "\n[daemon output truncated under bounded drain pressure]\n").right(MAX_LOG_BYTES)
		return remaining
	var chunk: PackedByteArray = snapshot.get("bytes", PackedByteArray()) as PackedByteArray
	if not chunk.is_empty():
		remaining -= chunk.size()
		_append_redacted_output(chunk.get_string_from_utf8())
	return remaining


func _drain_pipe(pipe: FileAccess, remaining: int) -> int:
	if pipe == null or not pipe.is_open():
		return remaining
	while remaining > 0:
		var available := pipe.get_length()
		if available <= 0:
			break
		var chunk := pipe.get_buffer(mini(remaining, mini(available, DRAIN_CHUNK_BYTES)))
		if chunk.is_empty():
			break
		remaining -= chunk.size()
		_append_redacted_output(chunk.get_string_from_utf8())
	return remaining


func _append_redacted_output(text: String) -> void:
	# Keep enough trailing text uncommitted to prevent a password or nonce split
	# across pipe reads from reaching the diagnostic buffer unredacted.
	var combined := _redaction_tail + text
	if not password.is_empty():
		combined = combined.replace(password, "[REDACTED]")
	if not launch_nonce.is_empty():
		combined = combined.replace(launch_nonce, "[NONCE]")
	var secret_span := maxi(password.length(), launch_nonce.length())
	var emit_length := maxi(0, combined.length() - maxi(0, secret_span - 1))
	var safe_text := combined.left(emit_length)
	_redaction_tail = combined.substr(emit_length)
	_output_buffer = (_output_buffer + safe_text).right(MAX_LOG_BYTES)


func _ensure_private_directory(path: String) -> bool:
	var result := DirAccess.make_dir_recursive_absolute(path)
	if result != OK and result != ERR_ALREADY_EXISTS:
		return false
	if OS.get_name() in ["Linux", "macOS"]:
		return FileAccess.set_unix_permissions(path, 448) == OK # 0700
	if OS.get_name() == "Windows":
		return _apply_windows_private_acl(path, true)
	return true


func _write_private_json_atomic(path: String, value: Dictionary) -> bool:
	var temporary := "%s.%s.tmp" % [path, launch_nonce if not launch_nonce.is_empty() else "pending"]
	if FileAccess.file_exists(temporary):
		_cleanup_atomic_temporary(path, launch_nonce)
	if not _write_private_json(temporary, value):
		_cleanup_atomic_temporary(path, launch_nonce)
		return false
	var backup := path + ".bak"
	if FileAccess.file_exists(path):
		if FileAccess.file_exists(backup):
			_cleanup_atomic_temporary(path, launch_nonce)
			return false
		if DirAccess.rename_absolute(path, backup) != OK:
			_cleanup_atomic_temporary(path, launch_nonce)
			return false
	var result := DirAccess.rename_absolute(temporary, path)
	if result != OK:
		_cleanup_atomic_temporary(path, launch_nonce)
		if FileAccess.file_exists(backup) and DirAccess.rename_absolute(backup, path) != OK:
			diagnostic.emit("runtime", "Atomic state write failed and the prior ownership record could not be restored.")
		return false
	if result == OK and FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	return true


func _cleanup_atomic_temporary(path: String, nonce: String) -> void:
	if path.get_base_dir() != runtime_dir:
		return
	var temporary := "%s.%s.tmp" % [path, nonce if not nonce.is_empty() else "pending"]
	if FileAccess.file_exists(temporary):
		DirAccess.remove_absolute(temporary)


func _write_private_json(path: String, value: Dictionary) -> bool:
	var serialized := JSON.stringify(value)
	if serialized.is_empty():
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(serialized)
	var write_error := file.get_error()
	file.flush()
	var flush_error := file.get_error()
	file.close()
	if write_error != OK or flush_error != OK:
		return false
	# A successful store/flush is not sufficient on every platform: verify the
	# exact bytes before the caller rotates an existing record into .bak.
	var verification := FileAccess.open(path, FileAccess.READ)
	if verification == null:
		return false
	var actual := verification.get_as_text()
	verification.close()
	if actual != serialized:
		return false
	if OS.get_name() in ["Linux", "macOS"]:
		return FileAccess.set_unix_permissions(path, 384) == OK # 0600
	if OS.get_name() == "Windows":
		return _apply_windows_private_acl(path, false)
	return true


func _apply_windows_private_acl(path: String, directory: bool) -> bool:
	var identity_output: Array = []
	if OS.execute("whoami.exe", PackedStringArray(), identity_output, true, false) != 0 or identity_output.is_empty():
		diagnostic.emit("security", "Could not determine the Windows identity used to protect OpenCode runtime state.")
		return false
	var identity := str(identity_output[0]).strip_edges()
	if identity.is_empty():
		return false
	# icacls still applies the legacy MAX_PATH limit to ordinary paths. Godot's
	# app_userdata name can be project-controlled and therefore make the
	# nonce-bound temporary descriptor exceed that limit even though FileAccess
	# can create it. Use the Win32 extended path form for long paths, including
	# the UNC variant, while leaving short paths readable in diagnostics.
	var acl_path := path.replace("/", "\\")
	if acl_path.length() >= 240 and not acl_path.begins_with("\\\\?\\"):
		if acl_path.begins_with("\\\\"):
			acl_path = "\\\\?\\UNC\\" + acl_path.substr(2)
		else:
			acl_path = "\\\\?\\" + acl_path
	var grant := "%s:%s" % [identity, "(OI)(CI)F" if directory else "F"]
	var acl_output: Array = []
	var exit_code := OS.execute(
		"icacls.exe",
		PackedStringArray([
			acl_path,
			"/inheritance:r",
			"/grant:r", grant,
			# Well-known SIDs avoid localized account names. Reject a directory or
			# descriptor if broad Everyone/Users allows cannot be removed.
			"/remove:g", "*S-1-1-0", "*S-1-5-32-545",
		]),
		acl_output,
		true,
		false
	)
	if exit_code != 0:
		diagnostic.emit("security", "Could not remove broad Everyone/Users access from OpenCode runtime state.")
		return false
	return true


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".bak"):
		path += ".bak"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parser := JSON.new()
	var result := parser.parse(file.get_as_text())
	file.close()
	return parser.data if result == OK else null


func _cleanup_owned_runtime_files() -> bool:
	if _launch_ownership_uncertain:
		diagnostic.emit("ownership", "Preserving nonce-bound launch evidence because in-memory launch ownership is UNKNOWN.")
		return false
	if launch_nonce.is_empty():
		return true
	var ownership_path := runtime_dir.path_join("ownership.json")
	var ownership_exists := FileAccess.file_exists(ownership_path) or FileAccess.file_exists(ownership_path + ".bak")
	var ownership := _read_json(ownership_path)
	# The daemon record is process/child cleanup authority. A matching incomplete
	# launching record is deliberately not treated as harmless just because the
	# in-memory PID was reset during an editor callback.
	if ownership_exists:
		if not ownership is Dictionary or ownership.get("launch_nonce") != launch_nonce or ownership.get("project_hash") != project_hash:
			diagnostic.emit("ownership", "Preserving runtime evidence because ownership.json is malformed or belongs to another launch.")
			return false
		var validation := _validate_daemon_ownership_record(ownership, true)
		if not validation.get("ok", false) or validation.get("pending", false):
			diagnostic.emit("ownership", "Preserving runtime evidence because the current launch ownership record is incomplete or invalid.")
			return false
		var backup_path := ownership_path + ".bak"
		if FileAccess.file_exists(backup_path):
			var backup := _read_json(backup_path)
			if not backup is Dictionary or backup.get("launch_nonce") != launch_nonce or backup.get("project_hash") != project_hash:
				return false
			var backup_validation := _validate_daemon_ownership_record(backup, false)
			if not backup_validation.get("ok", false):
				return false
		var expected_listen_path := runtime_dir.path_join("listen-%s.json" % launch_nonce)
		var expected_descriptor_path := runtime_dir.path_join("launch-%s.json" % launch_nonce)
		if not _nonce_bound_json_pair_is_safe(expected_listen_path, launch_nonce) or not _nonce_bound_json_pair_is_safe(expected_descriptor_path, launch_nonce):
			return false
		if str(ownership["integration_mode"]) == "mcp":
			# MCP is lazy and may never be started for this daemon. Once a child is
			# started, server publishes this record synchronously before connect, so
			# absence here is safe only under the complete parent record above.
			if not _cleanup_owned_mcp_ownership(ownership):
				return false
		if str(ownership["integration_mode"]) == "native":
			var discovery_path := str(ownership["bridge_discovery_path"])
			for _attempt in 10:
				if not FileAccess.file_exists(discovery_path):
					break
				OS.delay_msec(50)
			if FileAccess.file_exists(discovery_path):
				diagnostic.emit("native-ownership", "Native bridge discovery remains after daemon shutdown; preserving ownership evidence and refusing replacement.")
				return false
	else:
		# Without a complete record, exact startup files are still possible orphan
		# evidence. Never infer that their absence of a parent record authorizes a
		# broad cleanup.
		for name: String in ["launch-%s.json" % launch_nonce, "listen-%s.json" % launch_nonce]:
			var artifact_path := runtime_dir.path_join(name)
			if FileAccess.file_exists(artifact_path) or FileAccess.file_exists(artifact_path + ".bak"):
				return false
		return true
	for name: String in ["launch-%s.json" % launch_nonce, "listen-%s.json" % launch_nonce]:
		var path := runtime_dir.path_join(name)
		if not _remove_nonce_bound_json_pair(path, launch_nonce):
			return false
	if not _remove_file_if_present(ownership_path) or not _remove_file_if_present(ownership_path + ".bak"):
		return false
	_cleanup_atomic_temporary(ownership_path, launch_nonce)
	return true


func _mcp_ownership_path(nonce: String) -> String:
	return runtime_dir.path_join("mcp-ownership-%s.json" % nonce)


func _cleanup_owned_mcp_ownership(daemon_ownership: Dictionary) -> bool:
	# This matches the complete schema published by server/src/mcp-ownership.ts.
	# The record is process-kill authority, so every binding must match exactly.
	var nonce := str(daemon_ownership.get("launch_nonce", ""))
	var path := str(daemon_ownership.get("mcp_ownership_path", ""))
	if not Protocol.validate_nonce(nonce, 16) or path != _mcp_ownership_path(nonce):
		diagnostic.emit("mcp-ownership", "Preserving MCP ownership evidence: the daemon record does not name the nonce-bound sidecar ownership path.")
		return false
	if not FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".bak"):
		# MCP is lazy: an otherwise healthy daemon may never start its local
		# server. When it does start, the server publishes ownership synchronously
		# before accepting a connect, so the complete parent record can safely
		# distinguish this ordinary no-child case from an incomplete launch.
		return true
	var record := _read_json(path)
	if not record is Dictionary:
		diagnostic.emit("mcp-ownership", "Preserving MCP ownership evidence: the sidecar record is malformed or unreadable.")
		return false
	var validation := _validate_mcp_ownership_record(record, daemon_ownership, nonce)
	if not validation.get("ok", false):
		diagnostic.emit("mcp-ownership", "Preserving MCP ownership evidence: %s" % validation.get("error", "the sidecar record did not match this launch"))
		return false
	var backup_path := path + ".bak"
	if FileAccess.file_exists(backup_path):
		var backup := _read_json(backup_path)
		if not backup is Dictionary or not _validate_mcp_ownership_record(backup, daemon_ownership, nonce).get("ok", false):
			diagnostic.emit("mcp-ownership", "Preserving MCP ownership evidence: its atomic backup is malformed or does not match this launch.")
			return false
	var parent: Dictionary = record["opencode_parent"]
	var parent_identity := _inspect_process_identity(int(parent["pid"]), int(parent["started_at_ms"]))
	if not parent_identity.get("stale", false):
		diagnostic.emit("mcp-ownership", "Preserving MCP ownership evidence: the recorded OpenCode parent is live or its identity is UNKNOWN.")
		return false
	var sidecar: Dictionary = record["sidecar"]
	var sidecar_identity := _inspect_process_identity(int(sidecar["pid"]), int(sidecar["started_at_ms"]))
	if sidecar_identity.get("stale", false):
		return _remove_mcp_ownership_record(path, nonce)
	if not sidecar_identity.get("matches", false):
		diagnostic.emit("mcp-ownership", "Preserving MCP ownership evidence: the sidecar identity is UNKNOWN; it was not terminated.")
		return false
	_terminate_process(int(sidecar["pid"]))
	OS.delay_msec(SIDECAR_STOP_MS)
	sidecar_identity = _inspect_process_identity(int(sidecar["pid"]), int(sidecar["started_at_ms"]))
	if not sidecar_identity.get("stale", false):
		diagnostic.emit("mcp-ownership", "Preserving MCP ownership evidence: the verified sidecar did not exit within the bounded wait.")
		return false
	return _remove_mcp_ownership_record(path, nonce)


func _validate_mcp_ownership_record(record: Dictionary, daemon_ownership: Dictionary, nonce: String) -> Dictionary:
	var sidecar: Variant = record.get("sidecar")
	var parent: Variant = record.get("opencode_parent")
	var executable: Variant = record.get("executable")
	var mcp: Variant = record.get("mcp")
	var release: Dictionary = _manifest.get("godot_mcp", {})
	if not sidecar is Dictionary or not parent is Dictionary or not executable is Dictionary or not mcp is Dictionary:
		return {"ok": false, "error": "required nested identity fields are missing"}
	if (
		record.get("schema") != MCP_OWNERSHIP_SCHEMA
		or record.get("schema_version") != MCP_OWNERSHIP_SCHEMA_VERSION
		or record.get("canonical_project") != canonical_project
		or record.get("project_hash") != project_hash
		or record.get("launch_nonce") != nonce
		or record.get("bridge_owner_nonce") != daemon_ownership.get("bridge_owner_nonce")
		or not Protocol.validate_nonce(str(record.get("bridge_owner_nonce", "")), 16)
		or not _same_ownership_path(str(record.get("bridge_discovery_path", "")), str(daemon_ownership.get("bridge_discovery_path", "")))
		or not _same_ownership_path(str(record.get("bridge_discovery_path", "")), str(bridge_session.discovery_path))
		or not _positive_safe_integer(sidecar.get("pid"))
		or not _positive_safe_integer(sidecar.get("started_at_ms"))
		or parent.get("pid") != daemon_ownership.get("pid")
		or parent.get("started_at_ms") != daemon_ownership.get("started_at_ms")
		or not _positive_safe_integer(parent.get("pid"))
		or not _positive_safe_integer(parent.get("started_at_ms"))
		or not _same_ownership_path(str(executable.get("path", "")), str(_payload.get("mcp_path", "")))
		or executable.get("sha256") != "sha256:" + str(_payload.get("mcp_sha256", ""))
		or mcp.get("version") != MCP_VERSION
		or mcp.get("api_contract") != MCP_API_CONTRACT
		or mcp.get("source_fingerprint") != str(release.get("source_fingerprint", ""))
		or mcp.get("build_fingerprint") != str(_payload.get("mcp_build_fingerprint", ""))
		or not _nonnegative_safe_integer(record.get("created_at_ms"))
		or not _nonnegative_safe_integer(record.get("updated_at_ms"))
	):
		return {"ok": false, "error": "schema, launch, parent, payload, bridge, or timestamp identity does not match"}
	return {"ok": true}


func _positive_safe_integer(value: Variant) -> bool:
	return _nonnegative_safe_integer(value) and float(value) > 0.0


func _nonnegative_safe_integer(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number := float(value)
	return number >= 0.0 and number <= 9007199254740991.0 and number == floor(number)


func _same_ownership_path(left: String, right: String) -> bool:
	if left.is_empty() or right.is_empty() or not left.is_absolute_path() or not right.is_absolute_path():
		return false
	var normalized_left := left.replace("\\", "/").simplify_path()
	var normalized_right := right.replace("\\", "/").simplify_path()
	if OS.get_name() == "Windows":
		normalized_left = normalized_left.to_lower()
		normalized_right = normalized_right.to_lower()
	return normalized_left == normalized_right


func _remove_mcp_ownership_record(path: String, nonce: String) -> bool:
	if DirAccess.remove_absolute(path) != OK and FileAccess.file_exists(path):
		diagnostic.emit("mcp-ownership", "The stale MCP ownership record could not be removed; preserving parent evidence.")
		return false
	if FileAccess.file_exists(path + ".bak") and DirAccess.remove_absolute(path + ".bak") != OK:
		diagnostic.emit("mcp-ownership", "The stale MCP ownership backup could not be removed; preserving parent evidence.")
		return false
	_cleanup_atomic_temporary(path, nonce)
	return true


func _inspect_process_identity(pid: int, started_at_ms: int) -> Dictionary:
	if _process_identity_inspector.is_valid():
		var injected: Variant = _process_identity_inspector.call(pid, started_at_ms)
		return injected if injected is Dictionary else {"matches": false, "stale": false, "error": "Injected process identity inspector returned invalid data"}
	return ProcessIdentity.inspect(pid, started_at_ms)


func _terminate_process(pid: int) -> void:
	if _process_terminator.is_valid():
		_process_terminator.call(pid)
	else:
		OS.kill(pid)


func _platform_key() -> String:
	# Match the payload to the architecture of the running Godot editor.  Host
	# environment variables are optional and can describe a compatibility
	# shell instead of the process that will launch the executable.
	var architecture := Engine.get_architecture_name().to_lower()
	var suffix := ""
	match architecture:
		"x86_64": suffix = "x86_64"
		"arm64", "aarch64": suffix = "arm64"
		_: return ""
	match OS.get_name():
		"Windows": return "windows-" + suffix
		"macOS": return "macos-" + suffix
		"Linux":
			var libc := _linux_libc_flavor()
			if libc != "glibc":
				_platform_error = "Unsupported Linux libc '%s'. This addon ships glibc-baseline payloads only; install/run a glibc Godot build or use a future explicitly packaged musl payload." % libc
				return ""
			return "linux-" + suffix + "-glibc"
	_platform_error = "Unsupported host operating system: %s" % OS.get_name()
	return ""


func _linux_libc_flavor() -> String:
	if _linux_libc_detector.is_valid():
		var injected: Variant = _linux_libc_detector.call()
		return str(injected).to_lower().strip_edges()
	var output: Array = []
	var exit_code := OS.execute("getconf", PackedStringArray(["GNU_LIBC_VERSION"]), output, true, false)
	var result := str(output[0]).to_lower().strip_edges() if exit_code == 0 and not output.is_empty() else "unknown"
	if result.begins_with("glibc "):
		return "glibc"
	if result.contains("musl"):
		return "musl"
	return "unknown"


func _inspect_daemon_identity(force: bool = false) -> Dictionary:
	if daemon_pid <= 0 or daemon_started_at_ms <= 0:
		return {"matches": false, "stale": false, "error": "Daemon identity fields are invalid"}
	var now := Protocol.now_ms()
	if not force and not _last_identity.is_empty() and now - _last_identity_check_ms < IDENTITY_CHECK_INTERVAL_MS:
		return _last_identity
	_last_identity = _inspect_process_identity(daemon_pid, daemon_started_at_ms)
	_last_identity_check_ms = now
	return _last_identity


func _reset_daemon_identity_cache() -> void:
	_last_identity_check_ms = 0
	_last_identity.clear()


func _ownership_matches_current_launch() -> bool:
	var ownership := _read_json(runtime_dir.path_join("ownership.json"))
	if not ownership is Dictionary:
		return false
	var validation := _validate_daemon_ownership_record(ownership, true)
	return validation.get("ok", false) \
		and not validation.get("pending", false) \
		and ownership.get("launch_nonce") == launch_nonce \
		and ownership.get("project_hash") == project_hash \
		and ownership.get("pid") == daemon_pid \
		and ownership.get("started_at_ms") == daemon_started_at_ms


func _set_state(next_state: String, next_detail: String) -> void:
	state = next_state
	detail = next_detail
	state_changed.emit(state, detail)


func _fail(category: String, message: String) -> Dictionary:
	_set_state("error", message)
	diagnostic.emit(category, message)
	return {"ok": false, "error": message}
