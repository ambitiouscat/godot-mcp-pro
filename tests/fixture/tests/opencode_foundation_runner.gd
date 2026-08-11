extends SceneTree

const Protocol := preload("res://addons/opencode_godot/engine_bridge/bridge_protocol_v1.gd")
const ProcessIdentity := preload("res://addons/opencode_godot/engine_bridge/bridge_process_identity.gd")
const SessionCoordinator := preload("res://addons/opencode_godot/engine_bridge/bridge_session_coordinator.gd")
const Lifecycle := preload("res://addons/opencode_godot/process/opencode_daemon_lifecycle.gd")

var failures: Array[String] = []


class ModeSwitchPluginFixture:
	extends "res://addons/opencode_godot/plugin.gd"

	var replacement_starts := 0

	func _start_unified_bridge() -> void:
		replacement_starts += 1


class ModeSwitchApiFixture:
	extends Node

	var events: Array[String]
	var shutdown_transport_count := 0

	func _init(shared_events: Array[String]) -> void:
		events = shared_events

	func shutdown_transport() -> void:
		shutdown_transport_count += 1
		events.append("api.shutdown_transport")


class ModeSwitchLifecycleFixture:
	extends RefCounted

	var events: Array[String]
	var state := "ready"
	var current_mode := "mcp"
	var requested_mode := ""
	var stop_succeeds := true
	var persist_count := 0

	func _init(shared_events: Array[String], succeeds: bool = true) -> void:
		events = shared_events
		stop_succeeds = succeeds

	func get_status() -> Dictionary:
		return {
			"state": state,
			"integration_mode": current_mode,
			"requested_integration_mode": requested_mode,
		}

	func get_integration_mode() -> String:
		return current_mode

	func stop() -> void:
		events.append("lifecycle.stop")
		if stop_succeeds:
			state = "stopped"
			events.append("lifecycle.stopped")
		else:
			state = "error"

	func set_requested_integration_mode(mode: String) -> Dictionary:
		persist_count += 1
		requested_mode = mode
		events.append("lifecycle.persist_mode")
		return {"ok": true}


class ModeSwitchWebSocketFixture:
	extends Node

	var events: Array[String]
	var stop_count := 0

	func _init(shared_events: Array[String]) -> void:
		events = shared_events

	func stop_server() -> void:
		stop_count += 1
		events.append("websocket.stop_server")


class ModeSwitchRuntimeFixture:
	extends RefCounted

	var events: Array[String]
	var cleanup_count := 0

	func _init(shared_events: Array[String]) -> void:
		events = shared_events

	func cleanup_owned_services() -> void:
		cleanup_count += 1
		events.append("runtime.cleanup")


class ModeSwitchBridgeFixture:
	extends RefCounted

	var events: Array[String]
	var discovery_path := ""
	var session_path := ""
	var token_path := ""
	var leave_files_on_stop := false
	var stop_count := 0

	func _init(shared_events: Array[String], fixture_id: String, leave_files: bool = false) -> void:
		events = shared_events
		leave_files_on_stop = leave_files
		discovery_path = "user://opencode-mode-switch-seam-%s-discovery.json" % fixture_id
		session_path = "user://opencode-mode-switch-seam-%s-session.json" % fixture_id
		token_path = "user://opencode-mode-switch-seam-%s-token.bin" % fixture_id
		_remove_files()
		for path: String in [discovery_path, session_path, token_path]:
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_string("fixture")
				file.close()

	func stop_session() -> void:
		stop_count += 1
		events.append("bridge.stop_session")
		if not leave_files_on_stop:
			_remove_files()

	func cleanup() -> void:
		_remove_files()

	func _remove_files() -> void:
		for path: String in [discovery_path, session_path, token_path]:
			if not path.is_empty():
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _initialize() -> void:
	if _is_editor_mode_switch_probe():
		_run_integration_mode_switch_seam()
		if failures.is_empty():
			print("OPENCODE_GODOT_MODE_SWITCH_EDITOR_OK")
			quit(0)
		for failure: String in failures:
			push_error("TEST FAILURE: " + failure)
		quit(1)
		return
	var manifest_file := FileAccess.open("res://addons/opencode_godot/payload-manifest.json", FileAccess.READ)
	_expect(manifest_file != null, "payload manifest is packaged")
	if manifest_file != null:
		var parser := JSON.new()
		_expect(parser.parse(manifest_file.get_as_text()) == OK, "payload manifest parses")
		manifest_file.close()
		if parser.data is Dictionary:
			var manifest: Dictionary = parser.data
			_expect(manifest.get("schema") == "opencode-godot-payload-manifest", "payload manifest schema is pinned")
			_expect((manifest.get("payloads", {}) as Dictionary).size() == 6, "payload manifest declares all six supported tuples")
			_expect((manifest.get("opencode", {}) as Dictionary).get("version") == "1.17.18", "OpenCode version is pinned")
			_expect((manifest.get("godot_mcp", {}) as Dictionary).get("version") == "1.16.0", "MCP version is pinned")
		_test_proc_ascii_reader()
	_test_linux_process_identity()
	var bridge: RefCounted = SessionCoordinator.new()
	_expect(bridge.start_session(), "bridge session starts for lifecycle validation")
	if bridge.owns_current_session():
		var lifecycle: RefCounted = Lifecycle.new()
		lifecycle.setup(bridge, null)
		_expect(lifecycle.runtime_dir.ends_with(Protocol.project_hash(lifecycle.canonical_project)), "runtime state is project-hash scoped")
		_expect(lifecycle.runtime_dir.contains("opencode_godot/runtime"), "runtime state stays under the addon namespace")
		_expect(not lifecycle._platform_key().is_empty(), "the running Godot editor architecture resolves to a supported manifest tuple")
		if OS.get_name() == "Linux":
			lifecycle._linux_libc_detector = func() -> String:
				return "musl"
			_expect(lifecycle._platform_key().is_empty(), "musl Linux hosts fail closed instead of selecting a glibc payload")
			_expect(lifecycle._platform_error.contains("glibc-baseline"), "musl rejection explains the packaged libc baseline")
			lifecycle._linux_libc_detector = func() -> String:
				return "glibc"
			_expect(lifecycle._platform_key().contains("-glibc"), "glibc Linux hosts resolve the glibc payload")
			lifecycle._linux_libc_detector = Callable()
		lifecycle.daemon_pid = OS.get_process_id()
		lifecycle.daemon_started_at_ms = 1
		lifecycle._last_identity = {"matches": false, "stale": false, "error": "cached fixture"}
		lifecycle._last_identity_check_ms = Protocol.now_ms()
		_expect(lifecycle._inspect_daemon_identity() == lifecycle._last_identity, "process identity checks use the short cached interval")
		lifecycle.daemon_pid = 0
		lifecycle.daemon_started_at_ms = 0
		lifecycle.launch_nonce = Protocol.random_base64url(32)
		lifecycle.password = Protocol.random_base64url(32)
		lifecycle._manifest = {"opencode": {"source_fingerprint": "sha256:" + "a".repeat(64)}}
		lifecycle._payload = {"opencode_build_fingerprint": "test-fingerprint"}
		var descriptor: Dictionary = lifecycle._build_descriptor("{\"mcp\":{}}", lifecycle.runtime_dir.path_join("listen-test.json"))
		var descriptor_keys := descriptor.keys()
		descriptor_keys.sort()
		var expected_keys := ["canonical_project", "config", "editor", "hostname", "launch_nonce", "listen_record_path", "opencode", "password", "port", "project_hash", "schema", "schema_version"]
		expected_keys.sort()
		_expect(descriptor_keys == expected_keys, "launch descriptor matches the daemon's exact one-time schema")
		_expect(descriptor.get("config") is String and not descriptor.has("config_path"), "OpenCode config is descriptor-contained, not persisted by path")
		_expect((descriptor.get("editor", {}) as Dictionary).get("start") is String, "editor start identity uses the daemon contract field")
		_expect(lifecycle._project_probe_matches({"directory": lifecycle.canonical_project, "worktree": "/"}), "lifecycle routing proof uses the exact instance directory for non-Git projects")
		_expect(not lifecycle._project_probe_matches({"worktree": lifecycle.canonical_project}), "lifecycle never accepts project worktree metadata as exact routing proof")
		var addon_root := ProjectSettings.globalize_path("res://addons/opencode_godot")
		_expect(lifecycle._resolve_payload_path(addon_root, "bin/windows-x86_64/opencode.exe").get("ok", false), "manifest payload paths resolve only below the addon root")
		for unsafe_payload_path: String in ["../outside", "bin/../outside", "/absolute/payload", "C:/absolute/payload", "bin//empty", " bin/padded"]:
			_expect(not lifecycle._resolve_payload_path(addon_root, unsafe_payload_path).get("ok", false), "manifest payload path rejects traversal and absolute-path forms: %s" % unsafe_payload_path)
		var missing_payload: Dictionary = lifecycle._validate_payload_file(
			{},
			lifecycle.runtime_dir.path_join("definitely-missing-payload.exe"),
			"Missing fixture",
			true
		)
		_expect(not missing_payload.get("ok", true), "a missing payload is never misreported as ready")
		_expect(lifecycle.state == "error", "a missing payload enters an actionable error state")
		# A PID without a durable start identity is UNKNOWN. Its descriptor must
		# survive so a later recovery never mistakes a possibly live child for a
		# safely reclaimed launch.
		var unknown_descriptor: String = lifecycle.runtime_dir.path_join("launch-%s.json" % lifecycle.launch_nonce)
		var unknown_listen: String = lifecycle.runtime_dir.path_join("listen-%s.json" % lifecycle.launch_nonce)
		_expect(lifecycle._ensure_private_directory(lifecycle.runtime_dir), "runtime directory can be protected before atomic launch-state writes")
		_expect(lifecycle._write_private_json_atomic(unknown_descriptor, {"launch_nonce": lifecycle.launch_nonce, "project_hash": lifecycle.project_hash}), "unknown-launch descriptor fixture writes atomically")
		lifecycle.daemon_pid = 777777
		lifecycle.daemon_started_at_ms = 0
		lifecycle._abort_failed_launch(unknown_descriptor, unknown_listen, "synthetic partial launch")
		_expect(FileAccess.file_exists(unknown_descriptor), "UNKNOWN partial launch retains its nonce-bound descriptor")
		_expect(lifecycle.daemon_pid == 777777, "UNKNOWN partial launch retains PID ownership evidence")
		DirAccess.remove_absolute(unknown_descriptor)
		# Ownership recovery fixtures need the same complete pinned payload identity
		# that production writes; a partial synthetic payload would make a schema
		# validator fail for the wrong reason.
		lifecycle.current_integration_mode = "mcp"
		lifecycle._payload = {
			"opencode_path": lifecycle.runtime_dir.path_join("synthetic-opencode"),
			"opencode_sha256": "a".repeat(64),
			"opencode_size_bytes": 1,
			"opencode_build_fingerprint": "synthetic-opencode-build",
		}
		_run_atomic_runtime_write_fixtures(lifecycle)
		_run_partial_launch_ownership_fixtures(lifecycle)
		_run_unknown_tombstone_start_fixture(lifecycle)
		_run_abort_identity_outcome_fixtures(lifecycle)
		_run_daemon_ownership_schema_fixtures(lifecycle)
		# Managed sidecar recovery uses an injected identity provider so the test
		# covers MATCH, STALE, UNKNOWN, PID reuse, and record mismatch without
		# inspecting or terminating real processes.
		lifecycle._manifest = {"godot_mcp": {"source_fingerprint": "sha256:" + "c".repeat(64)}}
		lifecycle._payload = {
			"mcp_path": lifecycle.runtime_dir.path_join("synthetic-godot-mcp"),
			"mcp_sha256": "d".repeat(64),
			"mcp_build_fingerprint": "synthetic-mcp-build",
		}
		_run_native_mode_fixtures(lifecycle)
		lifecycle.daemon_pid = 4242
		lifecycle.daemon_started_at_ms = 8001
		_run_mcp_ownership_cleanup_fixtures(lifecycle)
		_run_stop_fail_closed_fixtures(lifecycle)
		_run_unexpected_exit_signal_fixture(lifecycle)
		_run_bounded_output_fixture(lifecycle)
		_run_real_pipe_backpressure_fixture(lifecycle)
		_run_delayed_legacy_worker_reap_fixture(lifecycle)
		_run_legacy_stderr_quarantine_fixtures(lifecycle)
		_run_listener_and_duplicate_start_fixtures(lifecycle)
		_run_editor_mode_switch_probe()
		lifecycle._process_identity_inspector = Callable()
		lifecycle._process_terminator = Callable()
		lifecycle.daemon_pid = 0
		lifecycle.daemon_started_at_ms = 0
		lifecycle.stop()
		bridge.stop_session()
	if failures.is_empty():
		print("OPENCODE_GODOT_FOUNDATION_OK")
		quit(0)
	else:
		for failure: String in failures:
			push_error("TEST FAILURE: " + failure)
		quit(1)


func _test_proc_ascii_reader() -> void:
	var fixture_path := "user://opencode-proc-ascii-fixture.bin"
	var fixture := FileAccess.open(fixture_path, FileAccess.WRITE)
	_expect(fixture != null, "unified proc reader fixture opens")
	if fixture != null:
		var bytes := "456 (native editor) S 1 2 3".to_utf8_buffer()
		bytes.append(0)
		bytes.append_array("ignored".to_utf8_buffer())
		fixture.store_buffer(bytes)
		fixture.close()
		_expect(
			ProcessIdentity._read_linux_proc_ascii(fixture_path) == "456 (native editor) S 1 2 3",
			"unified proc reader consumes raw ASCII bytes and stops before Godot 4.3 NUL padding"
		)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture_path))


func _test_linux_process_identity() -> void:
	var boot_id := "  550E8400-E29B-41D4-A716-446655440000\n"
	var expected_linux_identity := 6128128571249836
	_expect(
		ProcessIdentity.linux_identity_from_boot_id_and_ticks(boot_id, "123456789") == expected_linux_identity,
		"unified Linux v1 identity matches the shared fixed vector"
	)
	_expect(
		ProcessIdentity.linux_identity_from_boot_id_and_ticks(boot_id, "123456790") != expected_linux_identity,
		"unified Linux v1 identity changes when raw start ticks change"
	)
	_expect(expected_linux_identity >= ProcessIdentity.IDENTITY_V1_BASE and expected_linux_identity <= ProcessIdentity.IDENTITY_V1_MAX, "unified Linux v1 identity is JSON-safe and version-tagged")
	var zombie_stat := _linux_stat_fixture("Z", "123456789")
	_expect(ProcessIdentity.linux_identity_from_proc_stat(boot_id, zombie_stat) == -1, "unified zombie identity is unavailable")
	_expect(ProcessIdentity._linux_proc_stat_exists(zombie_stat) == 0, "unified zombie process is stale")
	_expect(ProcessIdentity._linux_proc_stat_exists("unreadable") == -1, "unified unreadable proc state remains UNKNOWN")
	for invalid_ticks: String in ["+123456789", "-123456789", " 123456789", "123456789 "]:
		_expect(ProcessIdentity.linux_identity_from_boot_id_and_ticks(boot_id, invalid_ticks) == -1, "unified non-ASCII-decimal ticks are rejected")
	if OS.get_name() == "Linux":
		var current_identity := ProcessIdentity.started_at_ms(OS.get_process_id())
		_expect(current_identity > 0, "unified Linux current process has an opaque identity")
		_expect(current_identity == ProcessIdentity.started_at_ms(OS.get_process_id()), "unified Linux identity does not drift between reads")


func _linux_stat_fixture(state: String, ticks: String) -> String:
	var fields := PackedStringArray([state])
	for _index: int in range(18):
		fields.append("0")
	fields.append(ticks)
	return "4242 (worker with ) parentheses) " + " ".join(fields)


func _run_partial_launch_ownership_fixtures(lifecycle: RefCounted) -> void:
	# A pending record is published before execute_with_pipe in production.  A
	# synthetic no-PID/no-handle failure proves that this record and both startup
	# artifacts can be safely reclaimed, allowing a normal retry.
	var cleanup_nonce: String = Protocol.random_base64url(32)
	lifecycle.launch_nonce = cleanup_nonce
	lifecycle._launch_ownership_uncertain = false
	lifecycle.daemon_pid = 0
	lifecycle.daemon_started_at_ms = 0
	lifecycle._control_lease = null
	lifecycle._stderr_pipe = null
	var cleanup_descriptor: String = lifecycle.runtime_dir.path_join("launch-%s.json" % cleanup_nonce)
	var cleanup_listen: String = lifecycle.runtime_dir.path_join("listen-%s.json" % cleanup_nonce)
	_expect(lifecycle._write_private_json_atomic(cleanup_descriptor, {"launch_nonce": cleanup_nonce, "project_hash": lifecycle.project_hash}), "no-PID launch descriptor fixture writes")
	_expect(lifecycle._write_private_json_atomic(cleanup_listen, {"launch_nonce": cleanup_nonce, "project_hash": lifecycle.project_hash}), "no-PID listen fixture writes")
	_expect(lifecycle._write_ownership_record(cleanup_listen, "launching"), "no-PID pending ownership fixture writes")
	var cleanup_record: Variant = lifecycle._read_json(lifecycle.runtime_dir.path_join("ownership.json"))
	var cleanup_validation: Dictionary = lifecycle._validate_daemon_ownership_record(cleanup_record as Dictionary, true) if cleanup_record is Dictionary else {"ok": false, "error": "record unreadable"}
	_expect(cleanup_validation.get("ok", false), "no-PID pending ownership matches strict schema (%s record=%s)" % [cleanup_validation.get("error", ""), cleanup_record])
	lifecycle._abort_failed_launch(cleanup_descriptor, cleanup_listen, "synthetic no-PID/no-handle launch")
	_expect(not FileAccess.file_exists(cleanup_descriptor), "no-PID/no-handle launch removes its descriptor")
	_expect(not FileAccess.file_exists(cleanup_listen), "no-PID/no-handle launch removes its listen evidence")
	_expect(not FileAccess.file_exists(lifecycle.runtime_dir.path_join("ownership.json")), "no-PID/no-handle launch removes pending ownership")
	_expect(lifecycle._prepare_previous_ownership().get("ok", false), "clean no-PID launch failure permits a later retry")

	# A returned handle with no PID is ambiguous: closing the handle does not
	# prove that no child exists, so abort -> stop must preserve all evidence.
	_run_handle_only_abort_stop_fixture(lifecycle, false)
	# The child may consume the descriptor before the editor closes its handle.
	# The remaining listen/ownership evidence must still force orphaned state.
	_run_handle_only_abort_stop_fixture(lifecycle, true)

	# A positive PID whose start timestamp cannot be read is also UNKNOWN.  The
	# durable record must retain that incomplete identity and block replacement;
	# this seam never inspects or terminates a real process.
	var unknown_start_nonce: String = Protocol.random_base64url(32)
	lifecycle.launch_nonce = unknown_start_nonce
	lifecycle.daemon_pid = 8899
	lifecycle.daemon_started_at_ms = 0
	lifecycle.password = Protocol.random_base64url(32)
	lifecycle.base_url = "http://127.0.0.1:4555"
	lifecycle._listen_record = {"hostname": "127.0.0.1", "port": 4555, "process_start": "unknown"}
	var unknown_start_descriptor: String = lifecycle.runtime_dir.path_join("launch-%s.json" % unknown_start_nonce)
	var unknown_start_listen: String = lifecycle.runtime_dir.path_join("listen-%s.json" % unknown_start_nonce)
	_expect(lifecycle._write_private_json_atomic(unknown_start_descriptor, {"launch_nonce": unknown_start_nonce, "project_hash": lifecycle.project_hash}), "unknown-start launch descriptor fixture writes")
	_expect(lifecycle._write_private_json_atomic(unknown_start_listen, {"launch_nonce": unknown_start_nonce, "project_hash": lifecycle.project_hash}), "unknown-start listen fixture writes")
	_expect(lifecycle._write_ownership_record(unknown_start_listen, "launching"), "unknown-start pending ownership fixture writes")
	var identity_checks := 0
	lifecycle._process_identity_inspector = func(_pid: int, _started_at_ms: int) -> Dictionary:
		identity_checks += 1
		return {"matches": false, "stale": false, "error": "synthetic identity should not be queried"}
	lifecycle._abort_failed_launch(unknown_start_descriptor, unknown_start_listen, "synthetic PID/unknown-start launch")
	_expect(lifecycle.password.is_empty() and lifecycle.base_url.is_empty() and lifecycle._listen_record.is_empty(), "PID/unknown-start abort clears sensitive transport state")
	var unknown_start_record: Variant = lifecycle._read_json(lifecycle.runtime_dir.path_join("ownership.json"))
	_expect(unknown_start_record is Dictionary and int((unknown_start_record as Dictionary).get("pid", 0)) == 8899 and int((unknown_start_record as Dictionary).get("started_at_ms", -1)) == 0, "PID/unknown-start launch preserves incomplete durable identity")
	_expect(FileAccess.file_exists(unknown_start_descriptor) and FileAccess.file_exists(unknown_start_listen), "PID/unknown-start launch preserves startup evidence")
	_expect(identity_checks == 0, "PID/unknown-start launch performs no unverifiable process inspection")
	_expect(not lifecycle._prepare_previous_ownership().get("ok", true), "PID/unknown-start pending identity rejects replacement")
	lifecycle.stop()
	_expect(lifecycle.state == "orphaned", "PID/unknown-start abort followed by stop remains orphaned")
	_expect(FileAccess.file_exists(lifecycle.runtime_dir.path_join("ownership.json")), "PID/unknown-start stop preserves pending ownership")
	_expect(FileAccess.file_exists(unknown_start_listen), "PID/unknown-start stop preserves remaining listen evidence")
	DirAccess.remove_absolute(unknown_start_descriptor)
	DirAccess.remove_absolute(unknown_start_listen)
	DirAccess.remove_absolute(lifecycle.runtime_dir.path_join("ownership.json"))
	lifecycle._process_identity_inspector = Callable()
	lifecycle._launch_ownership_uncertain = false
	lifecycle.daemon_pid = 0
	lifecycle.daemon_started_at_ms = 0
	lifecycle.launch_nonce = ""


func _run_unknown_tombstone_start_fixture(lifecycle: RefCounted) -> void:
	# Simulate an external deletion of both ownership slots after a handle-only
	# abort.  The same lifecycle must reject a subsequent start before it can
	# publish a new descriptor or reach execute_with_pipe.
	var nonce: String = Protocol.random_base64url(32)
	lifecycle.state = "stopped"
	lifecycle.launch_nonce = nonce
	lifecycle.daemon_pid = 9292
	lifecycle.daemon_started_at_ms = 9393
	lifecycle.password = Protocol.random_base64url(32)
	lifecycle.base_url = "http://127.0.0.1:4558"
	lifecycle._listen_record = {"hostname": "127.0.0.1", "port": 4558, "process_start": "tombstone"}
	lifecycle._launch_ownership_uncertain = true
	var ownership_path: String = lifecycle.runtime_dir.path_join("ownership.json")
	var descriptor: String = lifecycle.runtime_dir.path_join("launch-%s.json" % nonce)
	var listen: String = lifecycle.runtime_dir.path_join("listen-%s.json" % nonce)
	_expect(lifecycle._write_private_json_atomic(descriptor, {"launch_nonce": nonce, "project_hash": lifecycle.project_hash}), "UNKNOWN tombstone descriptor fixture writes")
	_expect(lifecycle._write_private_json_atomic(listen, {"launch_nonce": nonce, "project_hash": lifecycle.project_hash}), "UNKNOWN tombstone listen fixture writes")
	_expect(lifecycle._write_ownership_record(listen, "launching"), "UNKNOWN tombstone ownership fixture writes")
	lifecycle._process_identity_inspector = func(_pid: int, _started_at_ms: int) -> Dictionary:
		return {"matches": false, "stale": false, "error": "synthetic tombstone UNKNOWN"}
	lifecycle._abort_failed_launch(descriptor, listen, "synthetic tombstone UNKNOWN launch")
	_expect(lifecycle._launch_ownership_uncertain, "UNKNOWN tombstone fixture starts from an abort UNKNOWN result")
	DirAccess.remove_absolute(ownership_path)
	DirAccess.remove_absolute(ownership_path + ".bak")
	DirAccess.remove_absolute(descriptor)
	DirAccess.remove_absolute(listen)
	lifecycle._process_identity_inspector = Callable()
	lifecycle.state = "stopped"
	var launch_calls := 0
	lifecycle._process_launcher = func(_path: String, _arguments: PackedStringArray) -> Dictionary:
		launch_calls += 1
		return {}
	var result: Dictionary = lifecycle.start()
	_expect(launch_calls == 0, "UNKNOWN tombstone rejection never reaches execute_with_pipe")
	_expect(not result.get("ok", true), "UNKNOWN tombstone rejects a subsequent start when both ownership slots are gone")
	_expect(str(result.get("error", "")).contains("UNKNOWN") and str(result.get("error", "")).contains("refusing"), "UNKNOWN tombstone start rejection explains the fail-closed reason")
	_expect(not FileAccess.file_exists(descriptor) and not FileAccess.file_exists(listen), "UNKNOWN tombstone rejection publishes no replacement launch artifacts")
	_expect(lifecycle._launch_ownership_uncertain and lifecycle.daemon_pid == 9292 and lifecycle.daemon_started_at_ms == 9393 and lifecycle.launch_nonce == nonce, "UNKNOWN tombstone retains in-memory process evidence")
	_expect(lifecycle.password.is_empty() and lifecycle.base_url.is_empty() and lifecycle._listen_record.is_empty(), "UNKNOWN tombstone rejection clears sensitive transport state")
	lifecycle._launch_ownership_uncertain = false
	lifecycle.daemon_pid = 0
	lifecycle.daemon_started_at_ms = 0
	lifecycle.launch_nonce = ""
	lifecycle.state = "stopped"
	lifecycle._process_launcher = Callable()


func _run_atomic_runtime_write_fixtures(lifecycle: RefCounted) -> void:
	var path: String = lifecycle.runtime_dir.path_join("atomic-rollback-fixture.json")
	var backup: String = path + ".bak"
	var temporary: String = "%s.%s.tmp" % [path, lifecycle.launch_nonce]
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(backup)
	DirAccess.remove_absolute(temporary)
	var old_value := {"schema": "fixture-old", "value": 1}
	var new_value := {"schema": "fixture-new", "value": 2}
	_expect(lifecycle._write_private_json_atomic(path, old_value), "atomic fixture writes the original record")
	var old_text: Variant = _read_text_if_present(path)
	var backup_writer := FileAccess.open(backup, FileAccess.WRITE)
	if backup_writer != null:
		backup_writer.store_string("existing-backup-sentinel")
		backup_writer.close()
	_expect(not lifecycle._write_private_json_atomic(path, new_value), "atomic fixture refuses to overwrite when an existing backup is present")
	_expect(_read_text_if_present(path) == old_text, "atomic fixture preserves the original record after backup conflict")
	_expect(_read_text_if_present(backup) == "existing-backup-sentinel", "atomic fixture preserves the pre-existing backup")
	_expect(not FileAccess.file_exists(temporary), "atomic fixture removes its temporary file after backup conflict")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(backup)
	DirAccess.remove_absolute(temporary)


func _run_abort_identity_outcome_fixtures(lifecycle: RefCounted) -> void:
	# Abort has three distinct identity outcomes: an initial STALE result is
	# already safe, MATCH authorizes one termination followed by STALE proof, and
	# UNKNOWN preserves every launch artifact.
	for outcome: String in ["stale", "match", "unknown"]:
		var nonce: String = Protocol.random_base64url(32)
		lifecycle.launch_nonce = nonce
		lifecycle.daemon_pid = 7400
		lifecycle.daemon_started_at_ms = 9100
		lifecycle.password = Protocol.random_base64url(32)
		lifecycle.base_url = "http://127.0.0.1:4556"
		lifecycle._listen_record = {"hostname": "127.0.0.1", "port": 4556, "process_start": "synthetic"}
		lifecycle._launch_ownership_uncertain = false
		lifecycle.state = "starting"
		var descriptor: String = lifecycle.runtime_dir.path_join("launch-%s.json" % nonce)
		var listen: String = lifecycle.runtime_dir.path_join("listen-%s.json" % nonce)
		var ownership_path: String = lifecycle.runtime_dir.path_join("ownership.json")
		_expect(lifecycle._write_private_json_atomic(descriptor, {"launch_nonce": nonce, "project_hash": lifecycle.project_hash}), "abort %s descriptor fixture writes" % outcome)
		_expect(lifecycle._write_private_json_atomic(listen, {"launch_nonce": nonce, "project_hash": lifecycle.project_hash}), "abort %s listen fixture writes" % outcome)
		_expect(lifecycle._write_ownership_record(listen, "launching"), "abort %s ownership fixture writes" % outcome)
		var identity_state := {"killed": false, "kills": 0}
		lifecycle._process_identity_inspector = func(_pid: int, _started_at_ms: int) -> Dictionary:
			if outcome == "stale":
				return {"matches": false, "stale": true, "error": "synthetic initial STALE"}
			if outcome == "match":
				return {"matches": not bool(identity_state["killed"]), "stale": bool(identity_state["killed"]), "error": "synthetic MATCH then STALE"}
			return {"matches": false, "stale": false, "error": "synthetic UNKNOWN"}
		lifecycle._process_terminator = func(_pid: int) -> void:
			identity_state["kills"] = int(identity_state["kills"]) + 1
			identity_state["killed"] = true
		lifecycle._abort_failed_launch(descriptor, listen, "synthetic abort %s" % outcome)
		if outcome == "stale":
			_expect(int(identity_state["kills"]) == 0, "initial STALE abort never terminates a process")
			_expect(not lifecycle._launch_ownership_uncertain, "initial STALE abort clears launch uncertainty")
			_expect(not FileAccess.file_exists(ownership_path), "initial STALE abort removes ownership evidence")
		elif outcome == "match":
			_expect(int(identity_state["kills"]) == 1, "MATCH abort terminates exactly the matching process")
			_expect(not lifecycle._launch_ownership_uncertain, "post-kill STALE abort clears launch uncertainty")
			_expect(not FileAccess.file_exists(ownership_path), "post-kill STALE abort removes ownership evidence")
		else:
			_expect(int(identity_state["kills"]) == 0, "UNKNOWN abort never terminates a process")
			_expect(lifecycle._launch_ownership_uncertain, "UNKNOWN abort sets launch uncertainty")
			_expect(lifecycle.password.is_empty() and lifecycle.base_url.is_empty() and lifecycle._listen_record.is_empty(), "UNKNOWN abort clears sensitive transport state")
			_expect(FileAccess.file_exists(lifecycle.runtime_dir.path_join("ownership.json")), "UNKNOWN abort preserves ownership evidence")
			_expect(FileAccess.file_exists(descriptor) and FileAccess.file_exists(listen), "UNKNOWN abort preserves startup evidence")
		DirAccess.remove_absolute(descriptor)
		DirAccess.remove_absolute(listen)
		DirAccess.remove_absolute(ownership_path)
		lifecycle._launch_ownership_uncertain = false
		lifecycle.daemon_pid = 0
		lifecycle.daemon_started_at_ms = 0
	lifecycle._process_identity_inspector = Callable()
	lifecycle._process_terminator = Callable()
	lifecycle.launch_nonce = ""
func _daemon_ownership_record_fixture(lifecycle: RefCounted) -> Dictionary:
	var nonce: String = lifecycle.launch_nonce
	return {
		"schema": "opencode-godot-ownership",
		"schema_version": 1,
		"phase": "launching",
		"project_hash": lifecycle.project_hash,
		"canonical_project": lifecycle.canonical_project,
		"launch_nonce": nonce,
		"pid": lifecycle.daemon_pid,
		"started_at_ms": lifecycle.daemon_started_at_ms,
		"process_start": "",
		"hostname": "127.0.0.1",
		"port": 0,
		"opencode_path": lifecycle._payload.get("opencode_path", ""),
		"executable_sha256": lifecycle._payload.get("opencode_sha256", ""),
		"executable_size_bytes": lifecycle._payload.get("opencode_size_bytes", 0),
		"opencode_version": "1.17.18",
		"build_fingerprint": lifecycle._payload.get("opencode_build_fingerprint", ""),
		"listen_record_path": lifecycle.runtime_dir.path_join("listen-%s.json" % nonce),
		"integration_mode": "mcp",
		"mcp_ownership_path": lifecycle._mcp_ownership_path(nonce),
		"native_plugin": {},
		"bridge_owner_nonce": Protocol.random_base64url(32),
		"bridge_discovery_path": str(lifecycle.bridge_session.discovery_path),
	}


func _run_daemon_ownership_schema_fixtures(lifecycle: RefCounted) -> void:
	var ownership_path: String = lifecycle.runtime_dir.path_join("ownership.json")
	var nonce: String = Protocol.random_base64url(32)
	lifecycle.launch_nonce = nonce
	lifecycle.daemon_pid = 5151
	lifecycle.daemon_started_at_ms = 7001
	lifecycle.current_integration_mode = "mcp"
	lifecycle._launch_ownership_uncertain = false
	var identity_checks := 0
	lifecycle._process_identity_inspector = func(_pid: int, _started_at_ms: int) -> Dictionary:
		identity_checks += 1
		return {"matches": false, "stale": true, "error": "synthetic stale daemon"}

	var malformed_mode := _daemon_ownership_record_fixture(lifecycle)
	malformed_mode["integration_mode"] = "unknown"
	_expect(lifecycle._write_private_json_atomic(ownership_path, malformed_mode), "malformed integration mode fixture writes")
	_expect(not lifecycle._prepare_previous_ownership().get("ok", true), "unknown integration mode fails closed during recovery")
	_expect(identity_checks == 0, "unknown integration mode is rejected before process inspection")
	DirAccess.remove_absolute(ownership_path)

	var malformed_type := _daemon_ownership_record_fixture(lifecycle)
	malformed_type["pid"] = "5151"
	_expect(lifecycle._write_private_json_atomic(ownership_path, malformed_type), "malformed ownership type fixture writes")
	_expect(not lifecycle._prepare_previous_ownership().get("ok", true), "string PID fails closed during recovery")
	_expect(identity_checks == 0, "malformed ownership type is rejected before process inspection")
	DirAccess.remove_absolute(ownership_path)

	var malformed_path := _daemon_ownership_record_fixture(lifecycle)
	malformed_path["listen_record_path"] = lifecycle.runtime_dir.path_join("wrong-listen.json")
	_expect(lifecycle._write_private_json_atomic(ownership_path, malformed_path), "malformed listen path fixture writes")
	_expect(not lifecycle._prepare_previous_ownership().get("ok", true), "non-nonce-bound listen path fails closed during recovery")
	_expect(identity_checks == 0, "malformed listen path is rejected before process inspection")
	DirAccess.remove_absolute(ownership_path)

	var malformed_mcp_path := _daemon_ownership_record_fixture(lifecycle)
	malformed_mcp_path["mcp_ownership_path"] = lifecycle.runtime_dir.path_join("wrong-mcp.json")
	_expect(lifecycle._write_private_json_atomic(ownership_path, malformed_mcp_path), "malformed MCP path fixture writes")
	_expect(not lifecycle._prepare_previous_ownership().get("ok", true), "non-nonce-bound MCP path fails closed during recovery")
	_expect(identity_checks == 0, "malformed MCP path is rejected before process inspection")
	DirAccess.remove_absolute(ownership_path)

	# A complete stale record is reclaimable even when the MCP sidecar is absent:
	# MCP may be lazy, and the server publishes it synchronously before any child
	# connect, so this is the no-child ordinary-stop seam rather than UNKNOWN.
	var stale_record := _daemon_ownership_record_fixture(lifecycle)
	stale_record["bridge_owner_nonce"] = Protocol.random_base64url(32) # old bridge nonce need not equal this editor's nonce
	var stale_validation: Dictionary = lifecycle._validate_daemon_ownership_record(stale_record, true)
	_expect(stale_validation.get("ok", false), "complete stale fixture matches strict schema (%s)" % stale_validation.get("error", ""))
	_expect(lifecycle._write_private_json_atomic(ownership_path, stale_record), "complete stale ownership fixture writes")
	var stale_descriptor: String = lifecycle.runtime_dir.path_join("launch-%s.json" % nonce)
	var stale_listen: String = lifecycle.runtime_dir.path_join("listen-%s.json" % nonce)
	lifecycle._launch_ownership_uncertain = true
	_expect(lifecycle._write_private_json_atomic(stale_descriptor, {"launch_nonce": nonce, "project_hash": lifecycle.project_hash}), "complete stale descriptor fixture writes")
	_expect(lifecycle._write_private_json_atomic(stale_listen, {"launch_nonce": nonce, "project_hash": lifecycle.project_hash}), "complete stale listen fixture writes")
	_expect(lifecycle._prepare_previous_ownership().get("ok", false), "complete stale ownership is reclaimed after strict validation")
	_expect(not lifecycle._launch_ownership_uncertain, "verified STALE recovery clears the lifecycle UNKNOWN tombstone")
	_expect(not FileAccess.file_exists(ownership_path), "complete stale recovery removes the daemon record")
	_expect(not FileAccess.file_exists(stale_descriptor) and not FileAccess.file_exists(stale_listen), "complete stale recovery removes only exact launch artifacts")

	# Ordinary stop with a complete stale parent and no MCP sidecar remains a
	# clean stop: the sidecar is lazy, while a connected child would have
	# published its record synchronously before connect.
	var stop_nonce: String = Protocol.random_base64url(32)
	lifecycle.launch_nonce = stop_nonce
	lifecycle.daemon_pid = 5152
	lifecycle.daemon_started_at_ms = 7002
	lifecycle.state = "ready"
	var stop_record := _daemon_ownership_record_fixture(lifecycle)
	var stop_descriptor: String = lifecycle.runtime_dir.path_join("launch-%s.json" % stop_nonce)
	var stop_listen: String = lifecycle.runtime_dir.path_join("listen-%s.json" % stop_nonce)
	_expect(lifecycle._write_private_json_atomic(ownership_path, stop_record), "ordinary stop complete ownership fixture writes")
	_expect(lifecycle._write_private_json_atomic(stop_descriptor, {"launch_nonce": stop_nonce, "project_hash": lifecycle.project_hash}), "ordinary stop descriptor fixture writes")
	_expect(lifecycle._write_private_json_atomic(stop_listen, {"launch_nonce": stop_nonce, "project_hash": lifecycle.project_hash}), "ordinary stop listen fixture writes")
	lifecycle.stop()
	_expect(lifecycle.state == "stopped", "complete parent without a lazy MCP sidecar permits clean ordinary stop")
	_expect(not FileAccess.file_exists(ownership_path) and not FileAccess.file_exists(stop_listen), "ordinary stop removes only its complete ownership evidence")

	lifecycle._process_identity_inspector = Callable()
	lifecycle._launch_ownership_uncertain = false
	lifecycle.daemon_pid = 0
	lifecycle.daemon_started_at_ms = 0
	lifecycle.launch_nonce = ""


func _run_handle_only_abort_stop_fixture(lifecycle: RefCounted, descriptor_consumed: bool) -> void:
	var suffix := "consumed" if descriptor_consumed else "retained"
	var handle_nonce: String = Protocol.random_base64url(32)
	lifecycle.launch_nonce = handle_nonce
	lifecycle._launch_ownership_uncertain = false
	lifecycle.daemon_pid = 0
	lifecycle.daemon_started_at_ms = 0
	lifecycle.password = Protocol.random_base64url(32)
	lifecycle.base_url = "http://127.0.0.1:4557"
	lifecycle._listen_record = {"hostname": "127.0.0.1", "port": 4557, "process_start": "handle-only"}
	lifecycle.state = "starting"
	var handle_descriptor: String = lifecycle.runtime_dir.path_join("launch-%s.json" % handle_nonce)
	var handle_listen: String = lifecycle.runtime_dir.path_join("listen-%s.json" % handle_nonce)
	_expect(lifecycle._write_private_json_atomic(handle_descriptor, {"launch_nonce": handle_nonce, "project_hash": lifecycle.project_hash}), "handle-only %s descriptor fixture writes" % suffix)
	_expect(lifecycle._write_private_json_atomic(handle_listen, {"launch_nonce": handle_nonce, "project_hash": lifecycle.project_hash}), "handle-only %s listen fixture writes" % suffix)
	_expect(lifecycle._write_ownership_record(handle_listen, "launching"), "handle-only %s pending ownership fixture writes" % suffix)
	var handle_path: String = lifecycle.runtime_dir.path_join("handle-only-%s-fixture.log" % suffix)
	var handle_writer := FileAccess.open(handle_path, FileAccess.WRITE)
	if handle_writer != null:
		handle_writer.store_string("synthetic handle")
		handle_writer.close()
	lifecycle._control_lease = FileAccess.open(handle_path, FileAccess.READ)
	_expect(lifecycle._control_lease != null, "handle-only %s fixture opens a returned process handle" % suffix)
	lifecycle._abort_failed_launch(handle_descriptor, handle_listen, "synthetic no-PID/handle %s launch" % suffix)
	_expect(lifecycle._launch_ownership_uncertain, "handle-only %s abort sets in-memory UNKNOWN ownership" % suffix)
	_expect(lifecycle.password.is_empty() and lifecycle.base_url.is_empty() and lifecycle._listen_record.is_empty(), "handle-only %s abort clears sensitive transport state" % suffix)
	_expect(not lifecycle._prepare_previous_ownership().get("ok", true), "handle-only %s pending identity rejects replacement" % suffix)
	if descriptor_consumed:
		_expect(DirAccess.remove_absolute(handle_descriptor) == OK, "handle-only consumed fixture removes the child-consumed descriptor")
	lifecycle.stop()
	_expect(lifecycle.state == "orphaned", "handle-only %s abort followed by stop remains orphaned" % suffix)
	_expect(FileAccess.file_exists(handle_listen), "handle-only %s stop preserves listen evidence" % suffix)
	_expect(FileAccess.file_exists(lifecycle.runtime_dir.path_join("ownership.json")), "handle-only %s stop preserves pending ownership" % suffix)
	_expect(FileAccess.file_exists(handle_descriptor) == (not descriptor_consumed), "handle-only %s stop preserves descriptor state" % suffix)
	DirAccess.remove_absolute(handle_descriptor)
	DirAccess.remove_absolute(handle_listen)
	DirAccess.remove_absolute(lifecycle.runtime_dir.path_join("ownership.json"))
	DirAccess.remove_absolute(handle_path)
	lifecycle._control_lease = null
	lifecycle._launch_ownership_uncertain = false
	lifecycle.daemon_pid = 0
	lifecycle.daemon_started_at_ms = 0
	lifecycle.launch_nonce = ""
	lifecycle.state = "stopped"


func _is_editor_mode_switch_probe() -> bool:
	for argument: String in OS.get_cmdline_user_args():
		if argument == "opencode-foundation-mode-switch-editor":
			return true
	return false


func _run_editor_mode_switch_probe() -> void:
	# EditorPlugin is an editor-only virtual class and cannot be constructed by
	# the normal headless SceneTree runner.  Run this small editor child in the
	# same copied fixture so the production plugin subclass is actually
	# instantiated without loading the enabled addon or starting a daemon.
	var project_path := ProjectSettings.globalize_path("res://project.godot")
	var project_file := FileAccess.open(project_path, FileAccess.READ)
	var prior_project := project_file.get_as_text() if project_file != null else ""
	if project_file != null:
		project_file.close()
	var child_project := prior_project.replace("enabled=PackedStringArray(\"res://addons/opencode_godot/plugin.cfg\")", "enabled=PackedStringArray()")
	var plugin_was_enabled := prior_project.contains("res://addons/opencode_godot/plugin.cfg")
	if plugin_was_enabled and child_project == prior_project:
		_expect(false, "editor-only mode-switch seam refuses to spawn a child while the addon remains enabled")
		return
	if child_project != prior_project:
		var disabled_file := FileAccess.open(project_path, FileAccess.WRITE)
		if disabled_file == null:
			_expect(false, "editor-only mode-switch seam can disable the addon before its child starts")
			return
		disabled_file.store_string(child_project)
		disabled_file.close()
	var child_output: Array = []
	var child_args := PackedStringArray([
		"--headless",
		"--editor",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--script",
		"res://tests/opencode_foundation_runner.gd",
		"--",
		"opencode-foundation-mode-switch-editor",
	])
	var exit_code := OS.execute(OS.get_executable_path(), child_args, child_output, true)
	if child_project != prior_project:
		var restored_file := FileAccess.open(project_path, FileAccess.WRITE)
		if restored_file != null:
			restored_file.store_string(prior_project)
			restored_file.close()
	var output_text := "\n".join(child_output)
	if not output_text.contains("OPENCODE_GODOT_MODE_SWITCH_EDITOR_OK"):
		var diagnostic := output_text.replace("SCRIPT ERROR", "child script error").replace("Parse Error", "child parse error")
		_expect(false, "editor-only mode-switch seam completes in an editor child without starting runtime payloads (exit=%s output=%s)" % [exit_code, diagnostic])


func _run_integration_mode_switch_seam() -> void:
	# This is deliberately a seam test around the production EditorPlugin.  It
	# injects only fake editor-owned components, so no daemon, payload, network
	# listener, or real bridge session is started while validating the handoff.
	_run_mode_switch_success_fixture(str(Time.get_ticks_usec()))
	_run_mode_switch_fail_closed_fixture(str(Time.get_ticks_usec()))


func _run_mode_switch_success_fixture(fixture_id: String) -> void:
	var events: Array[String] = []
	var plugin := ModeSwitchPluginFixture.new()
	var api := ModeSwitchApiFixture.new(events)
	var lifecycle := ModeSwitchLifecycleFixture.new(events)
	var websocket := ModeSwitchWebSocketFixture.new(events)
	var runtime := ModeSwitchRuntimeFixture.new(events)
	var bridge := ModeSwitchBridgeFixture.new(events, fixture_id)
	var router := Node.new()
	router.name = "ModeSwitchRouterFixture"
	plugin.api_client = api
	plugin.lifecycle = lifecycle
	plugin.websocket_server = websocket
	plugin.runtime_service_controller = runtime
	plugin.bridge_session = bridge
	plugin.command_router = router
	plugin.add_child(router)
	plugin.add_child(websocket)
	var old_router: Node = router
	var old_websocket: Node = websocket

	plugin._on_integration_mode_requested("native")
	_expect(api.shutdown_transport_count == 1, "mode switch shuts down API transport exactly once")
	_expect(lifecycle.state == "stopped", "mode switch waits for the old lifecycle to reach stopped")
	_expect(websocket.stop_count == 1, "mode switch stops the old WebSocket bridge exactly once")
	_expect(runtime.cleanup_count == 1, "mode switch cleans up owned runtime services exactly once")
	_expect(bridge.stop_count == 1, "mode switch stops the old bridge session exactly once")
	_expect(lifecycle.persist_count == 1, "mode switch persists the replacement integration mode once")
	_expect(plugin.replacement_starts == 1, "mode switch starts exactly one replacement only after cleanup succeeds")
	_expect(not FileAccess.file_exists(bridge.discovery_path), "successful mode switch removes the old discovery file")
	_expect(not FileAccess.file_exists(bridge.session_path), "successful mode switch removes the old session file")
	_expect(not FileAccess.file_exists(bridge.token_path), "successful mode switch removes the old token file")
	_expect(not is_instance_valid(old_router) or old_router.get_parent() == null, "successful mode switch removes the old router from its parent")
	_expect(not is_instance_valid(old_websocket) or old_websocket.get_parent() == null, "successful mode switch removes the old WebSocket node from its parent")
	_expect_event_order(events, "api.shutdown_transport", "lifecycle.stop", "API transport shuts down before lifecycle stop")
	_expect_event_order(events, "lifecycle.stop", "lifecycle.stopped", "lifecycle stop completes before cleanup continues")
	_expect_event_order(events, "lifecycle.stopped", "websocket.stop_server", "WebSocket stop waits for lifecycle stop")
	_expect_event_order(events, "websocket.stop_server", "runtime.cleanup", "runtime cleanup follows WebSocket stop")
	_expect_event_order(events, "runtime.cleanup", "bridge.stop_session", "bridge session stop follows runtime cleanup")
	_expect_event_order(events, "bridge.stop_session", "lifecycle.persist_mode", "mode persistence follows old bridge cleanup")
	bridge.cleanup()
	plugin.free()


func _run_mode_switch_fail_closed_fixture(fixture_id: String) -> void:
	var events: Array[String] = []
	var plugin := ModeSwitchPluginFixture.new()
	var api := ModeSwitchApiFixture.new(events)
	var lifecycle := ModeSwitchLifecycleFixture.new(events)
	var websocket := ModeSwitchWebSocketFixture.new(events)
	var runtime := ModeSwitchRuntimeFixture.new(events)
	# Leaving one protected bridge artifact behind simulates an unverified
	# cleanup.  The production plugin must preserve evidence and refuse restart.
	var bridge := ModeSwitchBridgeFixture.new(events, fixture_id, true)
	var router := Node.new()
	router.name = "ModeSwitchFailClosedRouterFixture"
	plugin.api_client = api
	plugin.lifecycle = lifecycle
	plugin.websocket_server = websocket
	plugin.runtime_service_controller = runtime
	plugin.bridge_session = bridge
	plugin.command_router = router
	plugin.add_child(router)
	plugin.add_child(websocket)

	plugin._on_integration_mode_requested("native")
	_expect(api.shutdown_transport_count == 1, "fail-closed switch still detaches API transport first")
	_expect(lifecycle.state == "stopped", "fail-closed switch completes old lifecycle stop before refusing restart")
	_expect(websocket.stop_count == 1, "fail-closed switch stops the old WebSocket bridge")
	_expect(runtime.cleanup_count == 1, "fail-closed switch attempts owned runtime cleanup")
	_expect(bridge.stop_count == 1, "fail-closed switch attempts old bridge cleanup")
	_expect(lifecycle.persist_count == 0, "fail-closed switch does not persist a new mode after cleanup failure")
	_expect(plugin.replacement_starts == 0, "fail-closed switch never starts a replacement after cleanup failure")
	_expect(FileAccess.file_exists(bridge.session_path), "fail-closed switch preserves the unverified session evidence")
	_expect(router.get_parent() == plugin, "fail-closed switch keeps the old router attached for recovery")
	_expect(websocket.get_parent() == plugin, "fail-closed switch keeps the old WebSocket node attached for recovery")
	_expect_event_order(events, "api.shutdown_transport", "lifecycle.stop", "fail-closed switch shuts down API transport before lifecycle stop")
	bridge.cleanup()
	plugin.free()


func _expect_event_order(events: Array[String], earlier: String, later: String, message: String) -> void:
	var earlier_index := events.find(earlier)
	var later_index := events.find(later)
	_expect(earlier_index >= 0 and later_index >= 0 and earlier_index < later_index, message)


func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)


func _run_native_mode_fixtures(lifecycle: RefCounted) -> void:
	var addon_root := ProjectSettings.globalize_path("res://addons/opencode_godot")
	var plugin_dir := addon_root.path_join("runtime/opencode-plugins")
	var artifact_path := plugin_dir.path_join("godot-tools.js")
	var manifest_path := plugin_dir.path_join("godot-tools.manifest.json")
	DirAccess.make_dir_recursive_absolute(plugin_dir)
	var prior_artifact: Variant = _read_text_if_present(artifact_path)
	var prior_manifest: Variant = _read_text_if_present(manifest_path)
	if prior_artifact != null and prior_manifest != null:
		var packaged_validation: Dictionary = lifecycle._load_and_validate_native_manifest(addon_root)
		_expect(packaged_validation.get("ok", false), "the packaged native bundle matches its compatibility manifest")
		_expect(lifecycle._select_integration_mode(packaged_validation) == "mcp", "the current partially attested package keeps MCP as the safe fresh-project default")
	var artifact := FileAccess.open(artifact_path, FileAccess.WRITE)
	_expect(artifact != null, "native fixture artifact can be written beneath the addon root")
	if artifact == null:
		return
	artifact.store_string("export default function godotTools() { return {}; }\n")
	artifact.close()
	var artifact_reader := FileAccess.open(artifact_path, FileAccess.READ)
	var artifact_size := artifact_reader.get_length() if artifact_reader != null else 0
	if artifact_reader != null:
		artifact_reader.close()
	var artifact_hash: String = FileAccess.get_sha256(artifact_path)
	var manifest: Dictionary = {
		"schema": "opencode-godot-native-plugin-manifest",
		"schema_version": 1,
		"plugin": {"id": "godot-tools", "version": "1.16.0", "path": "runtime/opencode-plugins/godot-tools.js", "sha256": "sha256:" + artifact_hash, "size_bytes": artifact_size, "source_fingerprint": "sha256:" + "e".repeat(64), "build_fingerprint": "native-fixture-build", "format": "esm", "runtime": "bundled-opencode-bun"},
		"compatibility": {"opencode_version": "1.17.18", "opencode_plugin_api": "1.17.18", "godot_mcp_version": "1.16.0", "zod_version": "4.1.8", "bridge_protocol_version": 1},
		"default_integration_mode": "native",
		"native_default_attested": true,
		"gates": {"catalog_parity": true, "packaged_plugin_loading": true, "supported_platform_smoke": true, "multi_project_isolation": true},
		"profiles": {"manifest_sha256": "sha256:" + "f".repeat(64), "default": "opencode-default", "default_v1_count": 35, "full_count": 178},
	}
	_write_json(manifest_path, manifest)
	lifecycle._manifest = {"release": {"mode": "partial", "complete": false}}
	var validated: Dictionary = lifecycle._load_and_validate_native_manifest(addon_root)
	_expect(validated.get("ok", false), "attested native manifest validates its contained artifact and exact profile counts")
	_expect(lifecycle._select_integration_mode(validated) == "native", "attested native manifest selects native only without an explicit override")
	lifecycle.requested_integration_mode = "mcp"
	_expect(lifecycle._select_integration_mode(validated) == "mcp", "explicit MCP mode remains a rollback even when native is attested")
	lifecycle.requested_integration_mode = "native"
	lifecycle.current_integration_mode = "native"
	lifecycle.launch_nonce = Protocol.random_base64url(32)
	lifecycle._payload = {"native_path": artifact_path, "mcp_path": "sidecar-not-used", "mcp_available": true}
	# The bridge session owns the canonical editor identity. Use synthetic but
	# safe values here so any fresh ProcessIdentity lookup would drift from the
	# pair that was already authenticated by the bridge.
	var original_bridge_pid: int = lifecycle.bridge_session.coordinator_pid
	var original_bridge_started_at_ms: int = lifecycle.bridge_session.coordinator_started_at_ms
	var synthetic_bridge_pid := 271828
	var synthetic_bridge_started_at_ms := 314159265358
	lifecycle.bridge_session.coordinator_pid = synthetic_bridge_pid
	lifecycle.bridge_session.coordinator_started_at_ms = synthetic_bridge_started_at_ms
	var native_config: Dictionary = lifecycle._build_owned_config()
	_expect(native_config.has("plugin") and not native_config.has("mcp"), "native config contains only the file plugin provider")
	var plugin_rows: Array = native_config.get("plugin", [])
	_expect(plugin_rows.size() == 1 and plugin_rows[0] is Array and (plugin_rows[0] as Array).size() == 2, "native config has exactly one plugin URL/options pair")
	if plugin_rows.size() == 1 and plugin_rows[0] is Array:
		var options: Dictionary = (plugin_rows[0] as Array)[1]
		var keys: Array = options.keys()
		keys.sort()
		var expected: Array = ["bridge_discovery_path", "bridge_owner_nonce", "bridge_session_file", "canonical_project", "editor", "launch_nonce", "profile", "timeout"]
		expected.sort()
		_expect(keys == expected, "native plugin options exactly match the strict server contract without bridge secrets")
		var native_editor: Dictionary = options.get("editor", {})
		_expect(
			int(native_editor.get("pid", 0)) == synthetic_bridge_pid
				and int(native_editor.get("started_at_ms", 0)) == synthetic_bridge_started_at_ms,
			"native plugin editor identity reuses the authenticated bridge coordinator pair"
		)
		_expect(not JSON.stringify(options).contains(Protocol.base64url_encode(lifecycle.bridge_session.token_bytes)), "native plugin options contain no raw bridge token")
	var descriptor: Dictionary = lifecycle._build_descriptor(
		JSON.stringify(native_config),
		lifecycle.runtime_dir.path_join("listen-native-identity.json")
	)
	var descriptor_editor: Dictionary = descriptor.get("editor", {})
	_expect(
		int(descriptor_editor.get("pid", 0)) == synthetic_bridge_pid
			and int(str(descriptor_editor.get("start", "0"))) == synthetic_bridge_started_at_ms,
		"launch descriptor editor identity reuses the authenticated bridge coordinator pair"
	)
	lifecycle.bridge_session.coordinator_pid = 0
	var invalid_identity_start: Dictionary = lifecycle.start()
	_expect(
		not invalid_identity_start.get("ok", true)
			and str(invalid_identity_start.get("error", "")).contains("valid coordinator process identity"),
		"invalid bridge coordinator identity fails closed before daemon launch"
	)
	lifecycle.bridge_session.coordinator_pid = original_bridge_pid
	lifecycle.bridge_session.coordinator_started_at_ms = original_bridge_started_at_ms
	var windows_url: String = lifecycle._file_url("C:/A Folder/\u6d4b\u8bd5/godot tools.js")
	_expect(windows_url == "file:///C:/A%20Folder/%E6%B5%8B%E8%AF%95/godot%20tools.js", "Windows plugin file URL encodes spaces and Unicode")
	_expect(lifecycle._file_url("/tmp/A Folder/\u6d4b\u8bd5/godot tools.js") == "file:///tmp/A%20Folder/%E6%B5%8B%E8%AF%95/godot%20tools.js", "POSIX plugin file URL encodes spaces and Unicode")
	_expect(lifecycle._file_url("//server/share/A Folder/godot tools.js") == "file://server/share/A%20Folder/godot%20tools.js", "UNC plugin file URL uses an encoded authority and path")
	lifecycle.requested_integration_mode = ""
	var mode_change: Dictionary = lifecycle.set_requested_integration_mode("native")
	_expect(mode_change.get("ok", false) and FileAccess.file_exists(lifecycle._mode_state_path()), "explicit integration mode persists only in project-scoped addon user state")
	_expect(not lifecycle.set_requested_integration_mode("invalid").get("ok", true), "invalid integration mode is rejected before any restart")
	DirAccess.remove_absolute(lifecycle._mode_state_path())
	lifecycle.requested_integration_mode = ""
	# A manifest cannot suppress or claim the native default independently of
	# the four release gates.
	manifest["native_default_attested"] = false
	_write_json(manifest_path, manifest)
	_expect(not lifecycle._load_and_validate_native_manifest(addon_root).get("ok", true), "native manifest rejects an attestation/default that disagrees with completed gates")
	manifest["default_integration_mode"] = "mcp"
	manifest["gates"] = {"catalog_parity": true, "packaged_plugin_loading": false, "supported_platform_smoke": false, "multi_project_isolation": false}
	_write_json(manifest_path, manifest)
	_expect(lifecycle._select_integration_mode(lifecycle._load_and_validate_native_manifest(addon_root)) == "mcp", "unattested native manifest falls back to MCP by default")
	manifest["plugin"]["path"] = "../escape.js"
	_write_json(manifest_path, manifest)
	_expect(not lifecycle._load_and_validate_native_manifest(addon_root).get("ok", true), "native manifest rejects path traversal outside the addon payload root")
	_restore_text(artifact_path, prior_artifact)
	_restore_text(manifest_path, prior_manifest)
	lifecycle.current_integration_mode = "mcp"
	lifecycle._payload = {
		"mcp_path": lifecycle.runtime_dir.path_join("synthetic-godot-mcp"),
		"mcp_sha256": "d".repeat(64),
		"mcp_build_fingerprint": "synthetic-mcp-build",
	}
	lifecycle._manifest = {"godot_mcp": {"source_fingerprint": "sha256:" + "c".repeat(64)}}


func _read_text_if_present(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	return text


func _restore_text(path: String, value: Variant) -> void:
	if value == null:
		DirAccess.remove_absolute(path)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(str(value))
		file.close()


func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "native fixture manifest can be written")
	if file != null:
		file.store_string(JSON.stringify(value))
		file.close()


func _run_mcp_ownership_cleanup_fixtures(lifecycle: RefCounted) -> void:
	var fixture_state := {"mode": "match", "terminated": false, "inspections": 0}
	lifecycle._process_identity_inspector = func(pid: int, _started_at_ms: int) -> Dictionary:
		fixture_state["inspections"] = int(fixture_state["inspections"]) + 1
		if pid == lifecycle.daemon_pid:
			return {"matches": false, "stale": true, "error": "synthetic parent stale"}
		if fixture_state["mode"] == "unknown":
			return {"matches": false, "stale": false, "error": "synthetic unknown"}
		if fixture_state["mode"] == "pid-reuse":
			return {"matches": false, "stale": true, "error": "synthetic PID reuse"}
		if fixture_state["mode"] == "match" and not fixture_state["terminated"]:
			return {"matches": true, "stale": false}
		return {"matches": false, "stale": true, "error": "synthetic sidecar stale"}
	lifecycle._process_terminator = func(_pid: int) -> void:
		fixture_state["terminated"] = true

	# A live, exactly matched sidecar is the only case that receives a kill.
	_write_mcp_fixture(lifecycle, 5151, 9001)
	_expect(lifecycle._cleanup_owned_mcp_ownership(_daemon_ownership_fixture(lifecycle)), "MATCH sidecar is terminated then its exact ownership record is removed")
	_expect(fixture_state["terminated"], "MATCH sidecar receives the injected bounded termination")
	_expect(not FileAccess.file_exists(lifecycle._mcp_ownership_path(lifecycle.launch_nonce)), "MATCH sidecar cleanup removes the record after stale confirmation")

	# A stale sidecar needs no kill and the record can be reclaimed directly.
	fixture_state["mode"] = "stale"
	fixture_state["terminated"] = false
	lifecycle.launch_nonce = Protocol.random_base64url(32)
	_write_mcp_fixture(lifecycle, 5152, 9002)
	_expect(lifecycle._cleanup_owned_mcp_ownership(_daemon_ownership_fixture(lifecycle)), "STALE sidecar record is reclaimed without termination")
	_expect(not fixture_state["terminated"], "STALE sidecar is never terminated")

	# Unknown identity is fail-closed and leaves evidence untouched.
	fixture_state["mode"] = "unknown"
	lifecycle.launch_nonce = Protocol.random_base64url(32)
	_write_mcp_fixture(lifecycle, 5153, 9003)
	var unknown_path: String = str(lifecycle._mcp_ownership_path(lifecycle.launch_nonce))
	_expect(not lifecycle._cleanup_owned_mcp_ownership(_daemon_ownership_fixture(lifecycle)), "UNKNOWN sidecar identity fails cleanup")
	_expect(FileAccess.file_exists(unknown_path), "UNKNOWN sidecar retains its exact ownership record")
	DirAccess.remove_absolute(unknown_path)

	# Stale-parent recovery must leave all parent evidence in place when its
	# sidecar remains UNKNOWN, instead of deleting the only recovery binding.
	lifecycle.launch_nonce = Protocol.random_base64url(32)
	_write_mcp_fixture(lifecycle, 5156, 9006)
	var stale_parent := _daemon_ownership_fixture(lifecycle)
	var stale_ownership_path: String = str(lifecycle.runtime_dir.path_join("ownership.json"))
	var stale_descriptor_path: String = str(lifecycle.runtime_dir.path_join("launch-%s.json" % lifecycle.launch_nonce))
	_write_mcp_record(stale_ownership_path, stale_parent, "stale parent ownership fixture writes")
	_write_mcp_record(stale_descriptor_path, {"launch_nonce": lifecycle.launch_nonce, "project_hash": lifecycle.project_hash}, "stale parent descriptor fixture writes")
	_expect(not lifecycle._cleanup_stale_ownership(stale_parent, stale_ownership_path), "UNKNOWN sidecar blocks stale-parent evidence removal")
	_expect(FileAccess.file_exists(stale_ownership_path) and FileAccess.file_exists(stale_descriptor_path), "UNKNOWN sidecar preserves stale parent ownership and descriptor evidence")
	DirAccess.remove_absolute(lifecycle._mcp_ownership_path(lifecycle.launch_nonce))
	DirAccess.remove_absolute(stale_ownership_path)
	DirAccess.remove_absolute(stale_descriptor_path)

	# PID reuse is stale evidence, never an opportunity to kill the reused PID.
	fixture_state["mode"] = "pid-reuse"
	fixture_state["terminated"] = false
	lifecycle.launch_nonce = Protocol.random_base64url(32)
	_write_mcp_fixture(lifecycle, 5154, 9004)
	_expect(lifecycle._cleanup_owned_mcp_ownership(_daemon_ownership_fixture(lifecycle)), "PID reuse reclaims stale sidecar evidence")
	_expect(not fixture_state["terminated"], "PID reuse never terminates the replacement process")

	# Any immutable identity mismatch is UNKNOWN for cleanup purposes.
	fixture_state["mode"] = "stale"
	fixture_state["inspections"] = 0
	lifecycle.launch_nonce = Protocol.random_base64url(32)
	var mismatch := _mcp_record_fixture(lifecycle, 5155, 9005)
	mismatch["mcp"]["api_contract"] = "wrong-contract"
	_write_mcp_record(lifecycle._mcp_ownership_path(lifecycle.launch_nonce), mismatch, "mismatched MCP ownership fixture writes")
	var mismatch_path: String = str(lifecycle._mcp_ownership_path(lifecycle.launch_nonce))
	_expect(not lifecycle._cleanup_owned_mcp_ownership(_daemon_ownership_fixture(lifecycle)), "sidecar schema identity mismatch fails cleanup")
	_expect(FileAccess.file_exists(mismatch_path), "sidecar mismatch preserves ownership evidence")
	_expect(int(fixture_state["inspections"]) == 0, "sidecar mismatch performs no process inspection or termination")
	DirAccess.remove_absolute(mismatch_path)

	# A prior editor session has a different bridge nonce from this one. The
	# daemon and sidecar records bind each other, so stale recovery remains safe
	# without requiring the obsolete nonce to equal the current editor nonce.
	fixture_state["mode"] = "stale"
	var prior_bridge_nonce: String = Protocol.random_base64url(32)
	lifecycle.launch_nonce = Protocol.random_base64url(32)
	var prior_daemon := _daemon_ownership_fixture(lifecycle)
	prior_daemon["bridge_owner_nonce"] = prior_bridge_nonce
	var prior_sidecar := _mcp_record_fixture(lifecycle, 5157, 9007)
	prior_sidecar["bridge_owner_nonce"] = prior_bridge_nonce
	_write_mcp_record(lifecycle._mcp_ownership_path(lifecycle.launch_nonce), prior_sidecar, "prior-session MCP ownership fixture writes")
	_expect(lifecycle._cleanup_owned_mcp_ownership(prior_daemon), "stale prior-session sidecar is reclaimed using its recorded bridge nonce")


func _run_stop_fail_closed_fixtures(lifecycle: RefCounted) -> void:
	# UNKNOWN daemon identity must disconnect the editor but retain all process
	# and nonce evidence, and must never be reported as a clean stop.
	lifecycle.state = "ready"
	lifecycle.launch_nonce = Protocol.random_base64url(32)
	lifecycle.password = Protocol.random_base64url(32)
	lifecycle.base_url = "http://127.0.0.1:4096"
	lifecycle.daemon_pid = 6161
	lifecycle.daemon_started_at_ms = 10001
	lifecycle._reset_daemon_identity_cache()
	lifecycle._process_identity_inspector = func(_pid: int, _started_at_ms: int) -> Dictionary:
		return {"matches": false, "stale": false, "error": "synthetic daemon UNKNOWN"}
	lifecycle.stop()
	_expect(lifecycle.state == "orphaned", "UNKNOWN daemon stop enters the explicit orphaned state")
	_expect(lifecycle.daemon_pid == 6161 and lifecycle.daemon_started_at_ms == 10001, "UNKNOWN daemon stop retains process identity evidence")
	_expect(not lifecycle.launch_nonce.is_empty(), "UNKNOWN daemon stop retains the launch nonce")
	_expect(lifecycle.password.is_empty() and lifecycle.base_url.is_empty(), "UNKNOWN daemon stop clears live credentials and endpoint state")

	# A stale parent with an UNKNOWN sidecar must likewise preserve the complete
	# parent/child binding rather than reporting stopped and deleting evidence.
	lifecycle.state = "ready"
	lifecycle.launch_nonce = Protocol.random_base64url(32)
	lifecycle.password = Protocol.random_base64url(32)
	lifecycle.base_url = "http://127.0.0.1:4097"
	lifecycle.daemon_pid = 6262
	lifecycle.daemon_started_at_ms = 10002
	lifecycle._reset_daemon_identity_cache()
	var parent := _daemon_ownership_fixture(lifecycle)
	_write_mcp_record(lifecycle.runtime_dir.path_join("ownership.json"), parent, "orphaned parent ownership fixture writes")
	_write_mcp_fixture(lifecycle, 6263, 10003)
	lifecycle._process_identity_inspector = func(pid: int, _started_at_ms: int) -> Dictionary:
		if pid == 6262:
			return {"matches": false, "stale": true, "error": "synthetic parent stale"}
		return {"matches": false, "stale": false, "error": "synthetic sidecar UNKNOWN"}
	lifecycle.stop()
	_expect(lifecycle.state == "orphaned", "UNKNOWN MCP cleanup enters the explicit orphaned state")
	_expect(lifecycle.daemon_pid == 6262 and not lifecycle.launch_nonce.is_empty(), "UNKNOWN MCP cleanup retains the complete parent launch binding")
	_expect(FileAccess.file_exists(lifecycle.runtime_dir.path_join("ownership.json")), "UNKNOWN MCP cleanup preserves parent ownership evidence")
	_expect(FileAccess.file_exists(lifecycle._mcp_ownership_path(lifecycle.launch_nonce)), "UNKNOWN MCP cleanup preserves child ownership evidence")
	_expect(lifecycle.password.is_empty() and lifecycle.base_url.is_empty(), "UNKNOWN MCP cleanup clears live credentials and endpoint state")
	DirAccess.remove_absolute(lifecycle._mcp_ownership_path(lifecycle.launch_nonce))
	DirAccess.remove_absolute(lifecycle.runtime_dir.path_join("ownership.json"))
	lifecycle._process_identity_inspector = Callable()


func _run_unexpected_exit_signal_fixture(lifecycle: RefCounted) -> void:
	var observed := {"count": 0, "generation": -1}
	lifecycle.daemon_stopped.connect(func(stopped_generation: int) -> void:
		observed["count"] = int(observed["count"]) + 1
		observed["generation"] = stopped_generation
	)
	lifecycle.generation = 77
	lifecycle.state = "ready"
	lifecycle.daemon_pid = 8181
	lifecycle.daemon_started_at_ms = 9191
	lifecycle.launch_nonce = Protocol.random_base64url(32)
	lifecycle.password = Protocol.random_base64url(32)
	lifecycle.base_url = "http://127.0.0.1:4098"
	lifecycle._listen_record = {"hostname": "127.0.0.1", "port": 4098, "process_start": "unexpected-unknown"}
	lifecycle._launch_ownership_uncertain = false
	lifecycle._process_identity_inspector = func(_pid: int, _started_at_ms: int) -> Dictionary:
		return {"matches": false, "stale": false, "error": "synthetic unexpected-exit UNKNOWN"}
	lifecycle._restart_attempt = 0
	lifecycle._handle_exit("synthetic unexpected exit")
	_expect(int(observed["count"]) == 1 and int(observed["generation"]) == 77, "unexpected daemon exit immediately invalidates API consumers for its generation")
	_expect(lifecycle.state == "error", "unexpected exit UNKNOWN enters fail-closed error state")
	_expect(lifecycle.daemon_pid == 8181 and lifecycle.daemon_started_at_ms == 9191 and not lifecycle.launch_nonce.is_empty(), "unexpected exit UNKNOWN retains process identity and nonce evidence")
	_expect(lifecycle.password.is_empty() and lifecycle.base_url.is_empty() and lifecycle._listen_record.is_empty(), "unexpected exit UNKNOWN clears sensitive transport state")
	lifecycle._handle_exit("duplicate synthetic observation")
	_expect(int(observed["count"]) == 1, "repeated exit observation does not emit duplicate transport invalidation")
	lifecycle.state = "stopped"
	lifecycle._process_identity_inspector = Callable()
	lifecycle._launch_ownership_uncertain = false
	lifecycle.daemon_pid = 0
	lifecycle.daemon_started_at_ms = 0
	lifecycle.launch_nonce = ""
	lifecycle.password = ""
	lifecycle.base_url = ""


func _run_bounded_output_fixture(lifecycle: RefCounted) -> void:
	var output_path: String = str(lifecycle.runtime_dir).path_join("bounded-output-fixture.log")
	var secret: String = "password-" + "x".repeat(32)
	var nonce: String = "nonce-" + "y".repeat(32)
	var writer: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
	_expect(writer != null, "bounded output fixture can be created")
	if writer == null:
		return
	writer.store_string("a".repeat(70_000) + secret + "b".repeat(70_000))
	writer.close()
	var reader: FileAccess = FileAccess.open(output_path, FileAccess.READ)
	_expect(reader != null, "bounded output fixture can be opened as a synthetic child pipe")
	if reader == null:
		DirAccess.remove_absolute(output_path)
		return
	lifecycle.password = secret
	lifecycle.launch_nonce = nonce
	lifecycle._output_buffer = ""
	lifecycle._redaction_tail = ""
	lifecycle._control_lease = reader
	lifecycle._stderr_pipe = null
	lifecycle._drain_child_output()
	_expect(reader.get_position() > 0 and reader.get_position() <= lifecycle.MAX_DRAIN_BYTES_PER_UPDATE, "one update drains at most the bounded child-output budget")
	while reader.get_position() < reader.get_length():
		lifecycle._drain_child_output()
	_expect(lifecycle._output_buffer.length() <= lifecycle.MAX_LOG_BYTES, "sustained child output remains inside the diagnostic ring buffer")
	_expect(not lifecycle._output_buffer.contains(secret), "sustained child output never retains the daemon password")
	reader.close()
	lifecycle._control_lease = null
	lifecycle._output_buffer = ""
	lifecycle._redaction_tail = ""
	lifecycle._append_redacted_output("prefix-" + secret.left(12))
	lifecycle._append_redacted_output(secret.substr(12) + "-suffix")
	lifecycle._append_redacted_output("z".repeat(64))
	_expect(not lifecycle._output_buffer.contains(secret.left(12)) and lifecycle._output_buffer.contains("[REDACTED]"), "a password split across reads is redacted before any fragment is emitted")
	lifecycle.password = ""
	lifecycle.launch_nonce = ""
	lifecycle._redaction_tail = ""
	DirAccess.remove_absolute(output_path)


func _run_real_pipe_backpressure_fixture(lifecycle: RefCounted) -> void:
	# This is intentionally an OS child pipe, not a FileAccess file fixture.
	# Each stream exceeds the smallest supported anonymous-pipe capacity by a
	# large margin; without concurrent readers the child cannot reach exit.
	var command := ""
	var arguments := PackedStringArray()
	var secret := "worker-secret-" + "q".repeat(32)
	var prefix := "LEAKPREFIX-" + secret.left(18)
	var suffix := secret.substr(18) + "-LEAKSUFFIX"
	if OS.get_name() == "Windows":
		command = "powershell.exe"
		arguments = PackedStringArray([
			"-NoProfile",
			"-NonInteractive",
			"-Command",
			"$o=[Console]::OpenStandardOutput();$e=[Console]::OpenStandardError();$a=[Text.Encoding]::ASCII.GetBytes('%s');$z=[Text.Encoding]::ASCII.GetBytes('%s');$b=New-Object byte[] 1048576; for($i=0;$i -lt $b.Length;$i++){$b[$i]=120};$o.Write($a,0,$a.Length);$o.Write($b,0,$b.Length);$o.Write($z,0,$z.Length);$e.Write($b,0,$b.Length)" % [prefix, suffix],
		])
	elif OS.get_name() in ["Linux", "macOS"]:
		command = "/bin/sh"
		arguments = PackedStringArray(["-c", "printf '%s'; yes x | head -c 1048576; printf '%s'; yes y | head -c 1048576 1>&2" % [prefix, suffix]])
	else:
		return
	var launch: Dictionary = OS.execute_with_pipe(command, arguments)
	var stdio: FileAccess = launch.get("stdio") as FileAccess
	var stderr_pipe: FileAccess = launch.get("stderr") as FileAccess
	var pid := int(launch.get("pid", 0))
	_expect(stdio != null and stderr_pipe != null and pid > 0, "high-volume regression launches a real stdout/stderr pipe child")
	if stdio == null or stderr_pipe == null or pid <= 0:
		return
	lifecycle._pipe_drain_worker_runtime_detector = func() -> bool: return true
	lifecycle._control_lease = stdio
	lifecycle._stderr_pipe = stderr_pipe
	lifecycle._control_drain_worker = null
	lifecycle._stderr_drain_worker = null
	lifecycle._output_buffer = ""
	lifecycle._redaction_tail = ""
	lifecycle.password = secret
	lifecycle.launch_nonce = ""
	_expect(lifecycle._start_drain_workers(), "Godot 4.3-compatible workers start for both real child pipes")
	# Let the worker fill its bounded raw queue before the main thread consumes
	# anything. This forces a real pipe drop between the two password fragments.
	OS.delay_msec(1000)
	var deadline := Time.get_ticks_msec() + 10_000
	while Time.get_ticks_msec() < deadline:
		lifecycle._drain_child_output()
		if not OS.is_process_running(pid) and not lifecycle._control_drain_worker.is_alive() and not lifecycle._stderr_drain_worker.is_alive():
			break
		OS.delay_msec(5)
	_expect(not OS.is_process_running(pid), "high-volume child exits instead of blocking on stdout/stderr backpressure")
	for _attempt in 40:
		lifecycle._drain_child_output()
		if not lifecycle._control_drain_worker.is_alive() and not lifecycle._stderr_drain_worker.is_alive():
			break
		OS.delay_msec(5)
	_expect(lifecycle._output_buffer.length() > 0 and lifecycle._output_buffer.length() <= lifecycle.MAX_LOG_BYTES, "real high-volume pipe output reaches the bounded redacted diagnostic buffer")
	_expect(lifecycle._control_drain_worker.dropped_bytes() > 0, "real high-volume pipe exceeds the worker raw-queue budget")
	_expect(lifecycle._output_buffer.contains("bounded drain pressure"), "a raw-queue drop publishes a fixed safe truncation marker")
	_expect(not lifecycle._output_buffer.contains(secret.left(18)), "a secret split across a dropped raw-output boundary is never emitted")
	if OS.is_process_running(pid):
		OS.kill(pid)
	lifecycle._release_child_pipes()
	lifecycle._pipe_drain_worker_runtime_detector = Callable()
	lifecycle._output_buffer = ""
	lifecycle._redaction_tail = ""
	lifecycle.password = ""


func _run_delayed_legacy_worker_reap_fixture(lifecycle: RefCounted) -> void:
	if not lifecycle._uses_legacy_unix_stderr_quarantine():
		return
	# Releasing a live legacy worker is the shutdown race that previously left a
	# GDScript Mutex in Engine metadata through script teardown. The child keeps
	# stderr open briefly, then exits; the main thread must reap/join it and keep
	# only the native buggy stderr FileAccess quarantined.
	var before_workers: int = lifecycle._process_lifetime_drain_worker_count()
	var before_stderr: int = lifecycle._legacy_stderr_quarantine_count()
	var launch: Dictionary = OS.execute_with_pipe("/bin/sh", PackedStringArray(["-c", "sleep 1; printf delayed-stderr 1>&2"]))
	var stdio: FileAccess = launch.get("stdio") as FileAccess
	var stderr_pipe: FileAccess = launch.get("stderr") as FileAccess
	var pid := int(launch.get("pid", 0))
	_expect(stdio != null and stderr_pipe != null and pid > 0, "delayed legacy worker fixture launches a real child pipe")
	if stdio == null or stderr_pipe == null or pid <= 0:
		return
	lifecycle._control_lease = stdio
	lifecycle._stderr_pipe = stderr_pipe
	lifecycle._control_drain_worker = null
	lifecycle._stderr_drain_worker = null
	_expect(lifecycle._start_drain_workers(), "delayed legacy worker fixture starts both workers")
	lifecycle._release_child_pipes()
	_expect(lifecycle._process_lifetime_drain_worker_count() >= before_workers + 1, "live released worker remains strongly held until its pipe reaches EOF")
	var deadline := Time.get_ticks_msec() + 4_000
	while Time.get_ticks_msec() < deadline:
		lifecycle._reap_process_lifetime_drain_workers()
		if not OS.is_process_running(pid) and lifecycle._process_lifetime_drain_worker_count() == before_workers:
			break
		OS.delay_msec(10)
	_expect(not OS.is_process_running(pid), "delayed legacy child exits after owner-lease release")
	_expect(lifecycle._process_lifetime_drain_worker_count() == before_workers, "finished legacy worker is joined and removed before script teardown")
	_expect(lifecycle._legacy_stderr_quarantine_count() == before_stderr + 1, "finished legacy worker transfers only its native stderr FileAccess to quarantine")


func _run_legacy_stderr_quarantine_fixtures(lifecycle: RefCounted) -> void:
	_expect(lifecycle._is_legacy_linux_pipe_runtime({"major": 4, "minor": 3}, "Linux"), "Godot 4.3 Linux uses the stderr quarantine workaround")
	_expect(lifecycle._is_legacy_linux_pipe_runtime({"major": 4, "minor": 4}, "Linux"), "Godot 4.4 Linux uses the stderr quarantine workaround")
	_expect(lifecycle._is_legacy_unix_pipe_runtime({"major": 4, "minor": 3}, "macOS"), "Godot 4.3 macOS uses the stderr quarantine workaround")
	_expect(lifecycle._is_legacy_unix_pipe_runtime({"major": 4, "minor": 4}, "macOS"), "Godot 4.4 macOS uses the stderr quarantine workaround")
	_expect(not lifecycle._is_legacy_linux_pipe_runtime({"major": 4, "minor": 5}, "Linux"), "Godot 4.5 Linux does not use the legacy stderr workaround")
	_expect(not lifecycle._is_legacy_linux_pipe_runtime({"major": 4, "minor": 3}, "Windows"), "Windows does not use the Linux stderr workaround")
	_expect(lifecycle._is_blocking_pipe_drain_runtime({"major": 4, "minor": 3}), "Godot 4.3 all-platform pipes use background drain workers")
	_expect(not lifecycle._is_blocking_pipe_drain_runtime({"major": 4, "minor": 4}), "Godot 4.4 pipes retain the nonblocking main-thread drain path")
	var fixture_path := str(lifecycle.runtime_dir).path_join("legacy-stderr-quarantine-fixture.log")
	var writer := FileAccess.open(fixture_path, FileAccess.WRITE)
	_expect(writer != null, "stderr quarantine fixture can create a synthetic pipe file")
	if writer != null:
		writer.store_string("synthetic stderr")
		writer.close()
	var pipe: FileAccess = FileAccess.open(fixture_path, FileAccess.READ)
	_expect(pipe != null, "stderr quarantine fixture can open a synthetic pipe")
	if pipe != null:
		var before: int = lifecycle._legacy_stderr_quarantine_count()
		_expect(lifecycle._retain_legacy_stderr_pipe(pipe), "stderr quarantine retains a strong FileAccess reference")
		_expect(lifecycle._legacy_stderr_quarantine_count() == before + 1, "stderr quarantine is stored on the process-lifetime Engine holder")
		lifecycle._stderr_pipe = pipe
		lifecycle._release_stderr_pipe()
		_expect(lifecycle._stderr_pipe == null, "stderr release clears only the lifecycle field")
		if lifecycle._uses_legacy_linux_stderr_quarantine():
			_expect(pipe.is_open(), "legacy Unix stderr release never closes the quarantined FileAccess")
		else:
			_expect(not pipe.is_open(), "non-legacy stderr release closes the FileAccess normally")
		var replacement: RefCounted = Lifecycle.new()
		_expect(replacement._legacy_stderr_quarantine_count() == before + 1, "stderr quarantine survives lifecycle replacement through the Engine singleton")
	DirAccess.remove_absolute(fixture_path)


func _run_listener_and_duplicate_start_fixtures(lifecycle: RefCounted) -> void:
	# `port: 0` means a foreign listener can only be considered after the
	# nonce/PID record *and* authenticated managed-health proof.  Occupy a real
	# loopback port and publish a record with a deliberately wrong PID: it must
	# never become an adopted endpoint or trigger process termination.
	var foreign_listener := TCPServer.new()
	_expect(foreign_listener.listen(0, "127.0.0.1") == OK, "foreign loopback listener binds an isolated ephemeral port")
	if foreign_listener.is_listening():
		var nonce: String = Protocol.random_base64url(32)
		var listen_path: String = lifecycle.runtime_dir.path_join("listen-%s.json" % nonce)
		lifecycle.state = "starting"
		lifecycle.launch_nonce = nonce
		lifecycle.daemon_pid = 733733
		lifecycle.daemon_started_at_ms = 733734
		lifecycle.password = Protocol.random_base64url(32)
		lifecycle.base_url = ""
		lifecycle._listen_record.clear()
		lifecycle._payload = {"opencode_build_fingerprint": "synthetic-daemon-build"}
		var terminated := false
		lifecycle._process_terminator = func(_pid: int) -> void:
			terminated = true
		var record := {
			"schema": lifecycle.LISTEN_SCHEMA,
			"schema_version": lifecycle.DESCRIPTOR_VERSION,
			"hostname": "127.0.0.1",
			"port": foreign_listener.get_local_port(),
			"pid": 733732, # A live listener alone is never ownership proof.
			"process_start": "foreign-listener",
			"project_hash": lifecycle.project_hash,
			"launch_nonce": nonce,
			"opencode_version": "1.17.18",
			"build_fingerprint": "synthetic-daemon-build",
		}
		_expect(lifecycle._write_private_json_atomic(listen_path, record), "foreign listener record fixture writes atomically")
		lifecycle._try_read_listen_record()
		_expect(lifecycle._listen_record.is_empty() and lifecycle.base_url.is_empty() and lifecycle.state == "starting", "unknown loopback listener is not adopted from a conflicting port record")
		_expect(not terminated, "unknown listener fixture never invokes process termination")
		DirAccess.remove_absolute(listen_path)
		foreign_listener.stop()

	# Re-entering a live lifecycle must return its existing ownership rather than
	# creating another descriptor or process.  A concurrent start while launching
	# is rejected before it can reach execute_with_pipe.
	lifecycle.state = "ready"
	lifecycle.base_url = "http://127.0.0.1:45678"
	lifecycle.generation = 91
	var ready_start: Dictionary = lifecycle.start()
	_expect(ready_start.get("ok", false) and int(ready_start.get("generation", -1)) == 91 and ready_start.get("base_url") == lifecycle.base_url, "duplicate daemon start reuses the existing ready lifecycle without launching another daemon")
	lifecycle.state = "starting"
	var concurrent_start: Dictionary = lifecycle.start()
	_expect(not concurrent_start.get("ok", true) and str(concurrent_start.get("error", "")).contains("already starting"), "concurrent daemon start is rejected before a duplicate process can launch")
	lifecycle.state = "stopped"
	lifecycle.base_url = ""
	lifecycle.password = ""
	lifecycle.launch_nonce = ""
	lifecycle.daemon_pid = 0
	lifecycle.daemon_started_at_ms = 0
	lifecycle._listen_record.clear()


func _daemon_ownership_fixture(lifecycle: RefCounted) -> Dictionary:
	return {
		"launch_nonce": lifecycle.launch_nonce,
		"pid": lifecycle.daemon_pid,
		"started_at_ms": lifecycle.daemon_started_at_ms,
		"mcp_ownership_path": lifecycle._mcp_ownership_path(lifecycle.launch_nonce),
		"bridge_owner_nonce": lifecycle.bridge_session.owner_nonce,
		"bridge_discovery_path": lifecycle.bridge_session.discovery_path,
	}


func _mcp_record_fixture(lifecycle: RefCounted, sidecar_pid: int, sidecar_started_at_ms: int) -> Dictionary:
	return {
		"schema": "opencode-godot-mcp-ownership",
		"schema_version": 1,
		"canonical_project": lifecycle.canonical_project,
		"project_hash": lifecycle.project_hash,
		"launch_nonce": lifecycle.launch_nonce,
		"bridge_owner_nonce": lifecycle.bridge_session.owner_nonce,
		"sidecar": {"pid": sidecar_pid, "started_at_ms": sidecar_started_at_ms},
		"opencode_parent": {"pid": lifecycle.daemon_pid, "started_at_ms": lifecycle.daemon_started_at_ms},
		"executable": {"path": lifecycle._payload["mcp_path"], "sha256": "sha256:" + lifecycle._payload["mcp_sha256"]},
		"mcp": {
			"version": "1.16.0",
			"api_contract": "godot-mcp-pro/1.16.0",
			"source_fingerprint": lifecycle._manifest["godot_mcp"]["source_fingerprint"],
			"build_fingerprint": lifecycle._payload["mcp_build_fingerprint"],
		},
		"bridge_discovery_path": lifecycle.bridge_session.discovery_path,
		"created_at_ms": 1,
		"updated_at_ms": 1,
	}


func _write_mcp_fixture(lifecycle: RefCounted, sidecar_pid: int, sidecar_started_at_ms: int) -> void:
	_write_mcp_record(
		lifecycle._mcp_ownership_path(lifecycle.launch_nonce),
		_mcp_record_fixture(lifecycle, sidecar_pid, sidecar_started_at_ms),
		"synthetic MCP ownership fixture writes"
	)


func _write_mcp_record(path: String, record: Dictionary, message: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, message)
	if file != null:
		file.store_string(JSON.stringify(record))
		file.flush()
		file.close()
