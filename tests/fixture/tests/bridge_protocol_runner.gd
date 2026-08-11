extends SceneTree

const Protocol := preload("res://addons/godot_mcp/bridge_protocol_v1.gd")
const ProcessIdentity := preload("res://addons/godot_mcp/bridge_process_identity.gd")
const SessionCoordinator := preload("res://addons/godot_mcp/bridge_session_coordinator.gd")
const RuntimeServiceController := preload("res://addons/godot_mcp/runtime_service_controller.gd")
const WebSocketBridgeClient := preload("res://addons/godot_mcp/websocket_server.gd")
const CommandRouter := preload("res://addons/godot_mcp/command_router.gd")

var _failures: Array[String] = []
var _fixture: Dictionary = {}


func _initialize() -> void:
	_fixture = _load_protocol_fixture()
	if _fixture.is_empty():
		push_error("TEST FAILURE: shared protocol fixture could not be loaded")
		quit(1)
		return
	_run()


func _run() -> void:
	_test_path_canonicalization()
	_test_encoding_and_hmac_vectors()
	_test_discovery_validation()
	_test_process_identity()
	_test_session_validation_and_lifecycle()
	_test_runtime_service_map()
	_test_reconnect_contract()
	_test_router_session_guards()
	if _failures.is_empty():
		print("GODOT_BRIDGE_TESTS_OK")
		quit(0)
		return
	for failure: String in _failures:
		push_error("TEST FAILURE: %s" % failure)
	quit(1)


func _test_path_canonicalization() -> void:
	for vector: Dictionary in _fixture.get("canonical_paths", []):
		var platform_name := "Linux"
		if vector.get("platform") == "win32":
			platform_name = "Windows"
		elif vector.get("platform") == "darwin":
			platform_name = "macOS"
		_expect_equal(
			Protocol.canonicalize_project_path(vector.get("input", ""), platform_name),
			vector.get("output"),
			"shared canonical path fixture: %s" % vector.get("input", "")
		)
	_expect_equal(
		Protocol.canonicalize_project_path("C:\\Work\\Game\\.\\", "Windows"),
		"c:/work/game",
		"Windows paths are simplified and lowercased"
	)
	_expect_equal(
		Protocol.canonicalize_project_path("C:/", "Windows"),
		"c:/",
		"Windows drive roots retain their trailing separator"
	)
	_expect_equal(
		Protocol.canonicalize_project_path("/tmp/Game/../Game/", "Linux"),
		"/tmp/Game",
		"POSIX paths preserve case and trim trailing separators"
	)
	_expect_equal(
		Protocol.canonicalize_project_path("/tmp/项目/", "macOS"),
		"/tmp/项目",
		"Unicode path segments survive canonicalization"
	)


func _test_encoding_and_hmac_vectors() -> void:
	var vector: Dictionary = _fixture["hmac_vector"]
	var key: PackedByteArray = str(vector["key_hex"]).hex_decode()
	var encoded := Protocol.base64url_encode(key)
	_expect_equal(
		encoded,
		"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
		"32-byte token has deterministic base64url encoding"
	)
	_expect_equal(Protocol.base64url_decode(encoded), key, "base64url token round trips")
	var owner_nonce: String = vector["owner_nonce"]
	var client_nonce: String = vector["client_nonce"]
	var server_nonce: String = vector["server_nonce"]
	_expect_equal(
		Protocol.hmac_proof(key, "server", vector["project_path"], owner_nonce, client_nonce, server_nonce),
		vector["server_proof"],
		"server proof matches the shared TypeScript/GDScript vector"
	)
	_expect_equal(
		Protocol.hmac_proof(key, "client", vector["project_path"], owner_nonce, client_nonce, server_nonce),
		vector["client_proof"],
		"client proof matches the shared TypeScript/GDScript vector"
	)
	_expect(Protocol.constant_time_equal("same", "same"), "constant-time comparison accepts equal strings")
	_expect(not Protocol.constant_time_equal("same", "different"), "constant-time comparison rejects unequal strings")
	_expect(not Protocol.validate_nonce(owner_nonce + "=", 16), "padded nonce encoding is rejected")
	_expect(not Protocol.validate_proof("ujNK9XKYdwFrjO7KaVhc9cLSU-BBchXvt-IpJRT9K3t"), "non-canonical proof tail is rejected")
	var errors: Dictionary = _fixture["errors"]
	_expect_equal(Protocol.ERROR_NOT_READY, errors["bridge_not_ready"], "shared not-ready error code")
	_expect_equal(Protocol.ERROR_AUTHENTICATION, errors["authentication_failed"], "shared authentication error code")
	_expect_equal(Protocol.ERROR_PROJECT_MISMATCH, errors["project_mismatch"], "shared project error code")
	_expect_equal(Protocol.ERROR_UNSUPPORTED_PROTOCOL, errors["unsupported_protocol"], "shared protocol error code")
	_expect_equal(Protocol.ERROR_HANDSHAKE_TIMEOUT, errors["handshake_timeout"], "shared timeout error code")
	_expect_equal(Protocol.CLOSE_PROTOCOL_ERROR, _fixture["close_codes"]["protocol"], "shared protocol close code")
	_expect_equal(Protocol.CLOSE_POLICY_VIOLATION, _fixture["close_codes"]["policy"], "shared policy close code")
	_expect_equal(int(Protocol.HANDSHAKE_TIMEOUT_SECONDS * 1000.0), _fixture["handshake_timeout_ms"], "shared handshake timeout")
	_expect_equal(_fixture["state_steps"], ["HANDSHAKING", "bridge.handshake", "bridge.authenticate", "READY"], "shared handshake state sequence")


func _test_discovery_validation() -> void:
	var now := Protocol.now_ms()
	var project := "c:/work/game"
	var owner_nonce := "AAECAwQFBgcICQoLDA0ODw"
	var record := {
		"schema": Protocol.DISCOVERY_SCHEMA,
		"protocol_version": Protocol.PROTOCOL_VERSION,
		"project_path": project,
		"endpoint": "ws://127.0.0.1:43123",
		"owner_pid": OS.get_process_id(),
		"owner_started_at_ms": 1,
		"parent_pid": 0,
		"parent_started_at_ms": 0,
		"owner_nonce": owner_nonce,
		"created_at_ms": now,
		"expires_at_ms": now + Protocol.DISCOVERY_TTL_MS,
	}
	_expect(
		Protocol.validate_discovery(record, project, owner_nonce, now).get("ok", false),
		"valid discovery record is accepted"
	)
	var expired: Dictionary = record.duplicate(true)
	expired["expires_at_ms"] = now
	_expect(
		not Protocol.validate_discovery(expired, project, owner_nonce, now).get("ok", false),
		"expired discovery record is rejected"
	)
	var wrong_project: Dictionary = record.duplicate(true)
	wrong_project["project_path"] = "c:/work/other"
	_expect(
		not Protocol.validate_discovery(wrong_project, project, owner_nonce, now).get("ok", false),
		"cross-project discovery record is rejected"
	)
	var wrong_owner: Dictionary = record.duplicate(true)
	wrong_owner["owner_nonce"] = "ICEiIyQlJicoKSorLC0uLw"
	_expect(
		not Protocol.validate_discovery(wrong_owner, project, owner_nonce, now).get("ok", false),
		"discovery for a different owner nonce is rejected"
	)
	var unsupported_version: Dictionary = record.duplicate(true)
	unsupported_version["protocol_version"] = Protocol.PROTOCOL_VERSION + 1
	_expect(
		not Protocol.validate_discovery(unsupported_version, project, owner_nonce, now).get("ok", false),
		"discovery with an unsupported protocol version is rejected"
	)
	var wildcard_endpoint: Dictionary = record.duplicate(true)
	wildcard_endpoint["endpoint"] = "ws://0.0.0.0:43123"
	_expect(
		not Protocol.validate_discovery(wildcard_endpoint, project, owner_nonce, now).get("ok", false),
		"non-loopback discovery endpoint is rejected"
	)
	var noncanonical_endpoint: Dictionary = record.duplicate(true)
	noncanonical_endpoint["endpoint"] = "ws://127.0.0.1:043123"
	_expect(
		not Protocol.validate_discovery(noncanonical_endpoint, project, owner_nonce, now).get("ok", false),
		"non-canonical loopback endpoint text is rejected consistently"
	)
	var malformed: Dictionary = record.duplicate(true)
	malformed.erase("owner_pid")
	_expect(
		not Protocol.validate_discovery(malformed, project, owner_nonce, now).get("ok", false),
		"missing required discovery fields fail closed"
	)
	_expect(not record.has("token") and not record.has("token_file"), "discovery fixture contains no credential material")
	var credential_leak: Dictionary = record.duplicate(true)
	credential_leak["token_file"] = "/tmp/secret"
	_expect(
		not Protocol.validate_discovery(credential_leak, project, owner_nonce, now).get("ok", false),
		"discovery records containing credential material fail closed"
	)
	var excessive_lifetime: Dictionary = record.duplicate(true)
	excessive_lifetime["expires_at_ms"] = now + Protocol.DISCOVERY_TTL_MS + 1
	_expect(
		not Protocol.validate_discovery(excessive_lifetime, project, owner_nonce, now).get("ok", false),
		"discovery lifetime uses the exact shared thirty-second cap"
	)
	var inverted_lifetime: Dictionary = record.duplicate(true)
	inverted_lifetime["created_at_ms"] = now + 10_000
	inverted_lifetime["expires_at_ms"] = now + 5_000
	_expect(
		not Protocol.validate_discovery(inverted_lifetime, project, owner_nonce, now).get("ok", false),
		"discovery expiration must follow creation"
	)


func _test_process_identity() -> void:
	var process_vector: Dictionary = _fixture["process_identity_linux_v1"]
	var boot_id := "  %s\n" % str(process_vector["boot_id"]).to_upper()
	var start_ticks := str(process_vector["start_ticks"])
	var expected_linux_identity := int(process_vector["identity"])
	_expect_equal(
		ProcessIdentity.linux_identity_from_boot_id_and_ticks(boot_id, start_ticks),
		expected_linux_identity,
		"Linux v1 process identity matches the shared fixed vector"
	)
	_expect_equal(
		ProcessIdentity.linux_identity_from_boot_id_and_ticks(boot_id, start_ticks),
		expected_linux_identity,
		"Linux v1 identity is stable without btime or CLK_TCK"
	)
	_expect(
		expected_linux_identity >= ProcessIdentity.IDENTITY_V1_BASE and expected_linux_identity <= ProcessIdentity.IDENTITY_V1_MAX,
		"Linux v1 identity is within the JSON-safe version-tagged range"
	)
	_expect(
		ProcessIdentity.linux_identity_from_boot_id_and_ticks(boot_id, str(process_vector["changed_ticks"])) != expected_linux_identity,
		"Linux v1 identity changes when raw start ticks change"
	)
	_expect(
		ProcessIdentity.linux_identity_from_boot_id_and_ticks(str(process_vector["changed_boot_id"]), start_ticks) != expected_linux_identity,
		"Linux v1 identity changes when boot identity changes"
	)
	var live_stat := _linux_stat_fixture("S", start_ticks)
	_expect_equal(
		ProcessIdentity.linux_identity_from_proc_stat(boot_id, live_stat),
		expected_linux_identity,
		"Linux stat parser preserves the original raw start ticks"
	)
	var zombie_stat := _linux_stat_fixture("Z", start_ticks)
	_expect_equal(ProcessIdentity.linux_identity_from_proc_stat(boot_id, zombie_stat), -1, "zombie identity is unavailable")
	_expect_equal(ProcessIdentity._linux_proc_stat_exists(zombie_stat), 0, "zombie process is definitively stale")
	_expect_equal(ProcessIdentity._linux_proc_stat_exists("unreadable"), -1, "unreadable proc state remains UNKNOWN")
	_expect(not ProcessIdentity._linux_unverifiable_expected_identity(1).get("stale", true), "legacy Linux identity with a live PID remains UNKNOWN")
	_expect(not ProcessIdentity._linux_unverifiable_expected_identity(-1).get("stale", true), "legacy Linux identity with unknown PID state remains UNKNOWN")
	_expect(ProcessIdentity._linux_unverifiable_expected_identity(0).get("stale", false), "legacy Linux identity with an absent or zombie PID is stale")
	_expect(not ProcessIdentity._is_linux_identity_v1(ProcessIdentity.IDENTITY_V1_BASE - 1), "legacy epoch identity is outside Linux v1 range")
	_expect(not ProcessIdentity._is_linux_identity_v1(ProcessIdentity.IDENTITY_V1_MAX + 1), "oversized identity is outside Linux v1 range")
	for invalid_ticks: String in ["", "+123456789", "-123456789", " 123456789", "123456789 ", "123x456789"]:
		_expect_equal(ProcessIdentity.linux_identity_from_boot_id_and_ticks(boot_id, invalid_ticks), -1, "non-ASCII-decimal ticks are rejected: %s" % invalid_ticks)
	# Stat fields are whitespace-separated; validate only malformed single-token
	# forms here, while the loop above covers direct padded input.
	for malformed_stat_ticks: String in ["", "+123456789", "-123456789", "123x456789"]:
		_expect(ProcessIdentity._parse_linux_proc_stat(_linux_stat_fixture("S", malformed_stat_ticks)).is_empty(), "invalid stat ticks are rejected: %s" % malformed_stat_ticks)
	var proc_fixture_path := "user://bridge-proc-ascii-fixture.bin"
	var proc_fixture := FileAccess.open(proc_fixture_path, FileAccess.WRITE)
	_expect(proc_fixture != null, "proc reader fixture opens")
	if proc_fixture != null:
		var proc_bytes := "123 (name with spaces) S 1 2 3".to_utf8_buffer()
		proc_bytes.append(0)
		proc_bytes.append_array("ignored".to_utf8_buffer())
		proc_fixture.store_buffer(proc_bytes)
		proc_fixture.close()
		_expect(
			ProcessIdentity._read_linux_proc_ascii(proc_fixture_path) == "123 (name with spaces) S 1 2 3",
			"proc reader consumes raw ASCII bytes and stops before Godot 4.3 NUL padding"
		)
	if OS.get_name() == "Linux":
		var repeated_identity := ProcessIdentity.started_at_ms(OS.get_process_id())
		_expect_equal(repeated_identity, ProcessIdentity.started_at_ms(OS.get_process_id()), "Linux current identity does not drift between reads")
		var legacy_status := ProcessIdentity.inspect(OS.get_process_id(), ProcessIdentity.IDENTITY_V1_BASE - 1)
		_expect(not legacy_status.get("matches", false) and not legacy_status.get("stale", true), "legacy Linux epoch identity remains UNKNOWN")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(proc_fixture_path))
	var pid := OS.get_process_id()
	var started_at := ProcessIdentity.started_at_ms(pid)
	_expect(started_at > 0, "current process has a durable start identity")
	if started_at > 0:
		_expect(ProcessIdentity.inspect(pid, started_at).get("matches", false), "current PID/start identity matches")
		_expect(ProcessIdentity.inspect(pid, started_at + 1).get("stale", false), "same PID with a different start identity is classified as reused")
	var external_pid_text := OS.get_environment("GODOT_MCP_EXTERNAL_TEST_PID")
	var external_started_text := OS.get_environment("GODOT_MCP_EXTERNAL_TEST_STARTED_AT_MS")
	_expect(external_pid_text.is_valid_int() and external_started_text.is_valid_int(), "external process identity fixture is configured")
	if external_pid_text.is_valid_int() and external_started_text.is_valid_int():
		_expect(
			ProcessIdentity.inspect(int(external_pid_text), int(external_started_text)).get("matches", false),
			"an external same-user process PID/start identity matches"
		)


func _linux_stat_fixture(state: String, ticks: String) -> String:
	var fields := PackedStringArray([state])
	for _index: int in range(18):
		fields.append("0")
	fields.append(ticks)
	return "4242 (worker with ) parentheses) " + " ".join(fields)


func _test_session_validation_and_lifecycle() -> void:
	var coordinator: RefCounted = SessionCoordinator.new()
	_expect(coordinator.start_session(), "session coordinator starts")
	if not coordinator.owns_current_session():
		_failures.append("session coordinator owns a fresh 32-byte credential")
		return
	_expect(FileAccess.file_exists(coordinator.session_path), "protected session contract is published")
	_expect(FileAccess.file_exists(coordinator.token_path), "protected token file is published")
	var competing: RefCounted = SessionCoordinator.new()
	_expect(not competing.start_session(), "a second live editor session cannot replace the active project lock")
	var file := FileAccess.open(coordinator.session_path, FileAccess.READ)
	var json := JSON.new()
	var parse_error := json.parse(file.get_as_text()) if file != null else ERR_FILE_CANT_OPEN
	if file != null:
		file.close()
	_expect_equal(parse_error, OK, "session contract is complete JSON")
	if parse_error == OK:
		_expect(
			Protocol.validate_session(json.data, coordinator.project_path).get("ok", false),
			"published session contract matches the protocol schema"
		)
		_expect(not JSON.stringify(json.data).contains(Protocol.base64url_encode(coordinator.token_bytes)), "session JSON does not contain raw token material")
	var old_session_path: String = coordinator.session_path
	var old_token_path: String = coordinator.token_path
	coordinator.stop_session()
	coordinator.stop_session()
	_expect(not FileAccess.file_exists(old_session_path), "owned session contract is removed idempotently")
	_expect(not FileAccess.file_exists(old_token_path), "owned token file is removed idempotently")
	_expect(competing.start_session(), "project lock is reusable after the owning session stops")
	competing.stop_session()

	# A complete prior contract whose PID/start identity has been reused may be
	# recovered together with its exact token and discovery artifacts.
	var stale_nonce := "AAECAwQFBgcICQoLDA0ODw"
	var stale_token_path: String = coordinator.runtime_dir.path_join("bridge-token-%s.txt" % stale_nonce)
	var stale_token_file := FileAccess.open(stale_token_path, FileAccess.WRITE)
	stale_token_file.store_string(Protocol.base64url_encode(Crypto.new().generate_random_bytes(32)))
	stale_token_file.close()
	var stale_now := Protocol.now_ms()
	var stale_discovery_file := FileAccess.open(coordinator.discovery_path, FileAccess.WRITE)
	stale_discovery_file.store_string(JSON.stringify({
		"schema": Protocol.DISCOVERY_SCHEMA,
		"protocol_version": Protocol.PROTOCOL_VERSION,
		"project_path": coordinator.project_path,
		"endpoint": "ws://127.0.0.1:43123",
		"owner_pid": OS.get_process_id(),
		"owner_started_at_ms": ProcessIdentity.started_at_ms(OS.get_process_id()) + 1,
		"parent_pid": 0,
		"parent_started_at_ms": 0,
		"owner_nonce": stale_nonce,
		"created_at_ms": stale_now,
		"expires_at_ms": stale_now + Protocol.DISCOVERY_TTL_MS,
	}))
	stale_discovery_file.close()
	var stale_session_file := FileAccess.open(coordinator.session_path, FileAccess.WRITE)
	stale_session_file.store_string(JSON.stringify({
		"schema": Protocol.SESSION_SCHEMA,
		"protocol_version": Protocol.PROTOCOL_VERSION,
		"project_path": coordinator.project_path,
		"discovery_path": coordinator.discovery_path,
		"token_file": stale_token_path,
		"owner_nonce": stale_nonce,
		"created_at_ms": stale_now,
		"coordinator_pid": OS.get_process_id(),
		"coordinator_started_at_ms": ProcessIdentity.started_at_ms(OS.get_process_id()) + 1,
	}))
	stale_session_file.close()
	var artifact_recovery: RefCounted = SessionCoordinator.new()
	_expect(artifact_recovery.start_session(), "verified stale session/token/discovery artifacts are recovered")
	_expect(not FileAccess.file_exists(stale_token_path), "recovery removes only the verified stale token")
	_expect(not FileAccess.file_exists(coordinator.discovery_path), "recovery removes the verified stale discovery record")
	artifact_recovery.stop_session()

	# Expiration never overrides UNKNOWN process identity: the record must be
	# preserved until ownership can be established as MATCH or STALE.
	var unknown_guard: RefCounted = SessionCoordinator.new()
	_expect(unknown_guard.start_session(), "session for UNKNOWN-identity cleanup guard starts")
	if unknown_guard.owns_current_session():
		var expired_now := Protocol.now_ms()
		var expired_discovery_file := FileAccess.open(unknown_guard.discovery_path, FileAccess.WRITE)
		expired_discovery_file.store_string(JSON.stringify({
			"schema": Protocol.DISCOVERY_SCHEMA,
			"protocol_version": Protocol.PROTOCOL_VERSION,
			"project_path": unknown_guard.project_path,
			"endpoint": "ws://127.0.0.1:43124",
			"owner_pid": OS.get_process_id(),
			"owner_started_at_ms": ProcessIdentity.started_at_ms(OS.get_process_id()),
			"parent_pid": 0,
			"parent_started_at_ms": 0,
			"owner_nonce": unknown_guard.owner_nonce,
			"created_at_ms": expired_now - 2_000,
			"expires_at_ms": expired_now - 1_000,
		}))
		expired_discovery_file.close()
		unknown_guard._process_identity_inspector = func(_pid: int, _started_at_ms: int) -> Dictionary:
			return {"matches": false, "stale": false, "error": "synthetic identity outage"}
		_expect(
			not unknown_guard._cleanup_discovery_if_stale(unknown_guard.owner_nonce),
			"expired discovery is not deleted while owner identity is UNKNOWN"
		)
		_expect(FileAccess.file_exists(unknown_guard.discovery_path), "UNKNOWN discovery record is preserved")
	unknown_guard.stop_session()

	# A malformed owner write that remains past the grace period can be removed
	# without deleting unrelated runtime artifacts.
	var incomplete_lock_dir: String = coordinator.runtime_dir.path_join("bridge-session.lock")
	DirAccess.make_dir_absolute(incomplete_lock_dir)
	var incomplete_owner_file := FileAccess.open(incomplete_lock_dir.path_join("owner.json"), FileAccess.WRITE)
	incomplete_owner_file.store_string("{interrupted")
	incomplete_owner_file.close()
	_expect(coordinator._remove_stale_lock(null, 0), "aged malformed lock owner is recoverable")
	_expect(not DirAccess.dir_exists_absolute(incomplete_lock_dir), "malformed stale lock directory is removed")

	# A lock naming a live PID with a mismatched start identity represents PID
	# reuse and may be cleaned without treating that process as the owner. Its
	# nonce proves ownership of exact token/session/discovery temporary files.
	var stale_lock_dir: String = coordinator.runtime_dir.path_join("bridge-session.lock")
	DirAccess.make_dir_absolute(stale_lock_dir)
	var crash_nonce := "EBESExQVFhcYGRobHB0eHw"
	var crash_token_path: String = coordinator.runtime_dir.path_join("bridge-token-%s.txt" % crash_nonce)
	var crash_token_file := FileAccess.open(crash_token_path, FileAccess.WRITE)
	crash_token_file.store_string(Protocol.base64url_encode(Crypto.new().generate_random_bytes(32)))
	crash_token_file.close()
	var crash_session_temporary: String = "%s.tmp-%s" % [coordinator.session_path, crash_nonce]
	var crash_session_file := FileAccess.open(crash_session_temporary, FileAccess.WRITE)
	crash_session_file.store_string("interrupted")
	crash_session_file.close()
	var crash_discovery_temporary: String = coordinator.runtime_dir.path_join(".%s.99999.11111111-1111-1111-1111-111111111111.tmp" % crash_nonce)
	var crash_discovery_file := FileAccess.open(crash_discovery_temporary, FileAccess.WRITE)
	crash_discovery_file.store_string("interrupted")
	crash_discovery_file.close()
	var unrelated_nonce := "ICEiIyQlJicoKSorLC0uLw"
	var unrelated_token_path: String = coordinator.runtime_dir.path_join("bridge-token-%s.txt" % unrelated_nonce)
	var unrelated_token_file := FileAccess.open(unrelated_token_path, FileAccess.WRITE)
	unrelated_token_file.store_string("preserve")
	unrelated_token_file.close()
	var stale_lock_file := FileAccess.open(stale_lock_dir.path_join("owner.json"), FileAccess.WRITE)
	stale_lock_file.store_string(JSON.stringify({
		"schema": "godot-ai-bridge-session-lock",
		"protocol_version": 1,
		"project_path": coordinator.project_path,
		"coordinator_pid": OS.get_process_id(),
		"coordinator_started_at_ms": ProcessIdentity.started_at_ms(OS.get_process_id()) + 1,
		"owner_nonce": crash_nonce,
		"created_at_ms": Protocol.now_ms(),
	}))
	stale_lock_file.close()
	var recovered: RefCounted = SessionCoordinator.new()
	var recovered_ok: bool = recovered.start_session()
	_expect(recovered_ok, "verified PID-reuse lock is recovered: %s" % recovered.last_error)
	_expect(not FileAccess.file_exists(crash_token_path), "verified stale lock token artifact is removed")
	_expect(not FileAccess.file_exists(crash_session_temporary), "verified stale session temporary is removed")
	_expect(not FileAccess.file_exists(crash_discovery_temporary), "verified stale discovery temporary is removed")
	_expect(FileAccess.file_exists(unrelated_token_path), "unrelated token artifact is preserved")
	recovered.stop_session()
	DirAccess.remove_absolute(unrelated_token_path)


func _test_runtime_service_map() -> void:
	var controller: RefCounted = RuntimeServiceController.new()
	_expect_equal(controller.required_services_for_method("get_project_info"), [], "editor-only tools require no runtime autoload")
	_expect_equal(controller.required_services_for_method("get_game_screenshot"), ["screenshot"], "screenshot tools select only screenshot service")
	_expect_equal(controller.required_services_for_method("simulate_key"), ["input"], "input tools select only input service")
	_expect_equal(controller.required_services_for_method("get_game_scene_tree"), ["inspector"], "runtime inspection selects only inspector service")
	_expect_equal(controller.required_services_for_method("run_test_scenario"), ["input", "inspector"], "test scenario selects its two required services")
	_expect_equal(controller.required_services_for_method("capture_frames"), ["inspector"], "frame capture uses the inspector runtime service")
	_expect_equal(controller.required_services_for_method("start_recording"), ["inspector"], "runtime recording uses the inspector service")
	_expect_equal(controller.required_services_for_method("compare_screenshots"), [], "offline image comparison does not alter runtime autoloads")

	var screenshot_key := "autoload/MCPScreenshot"
	var input_key := "autoload/MCPInputService"
	var inspector_key := "autoload/MCPGameInspector"
	for key: String in [screenshot_key, input_key, inspector_key]:
		ProjectSettings.set_setting(key, null)
	ProjectSettings.save()
	var enabled_result: Dictionary = controller.set_tool_enabled("get_game_screenshot", true)
	_expect(enabled_result.get("ok", false), "explicitly enabling a runtime tool succeeds before game launch")
	_expect(ProjectSettings.has_setting(screenshot_key), "enabling screenshot tooling installs its owned service")
	_expect(not ProjectSettings.has_setting(input_key), "enabling screenshot tooling does not install input service")
	_expect(not ProjectSettings.has_setting(inspector_key), "enabling screenshot tooling does not install inspector service")
	controller.set_tool_enabled("get_game_screenshot", false)
	_expect(not ProjectSettings.has_setting(screenshot_key), "disabling the last screenshot tool removes its owned service")

	var wanted := "*res://addons/godot_mcp/mcp_screenshot_service.gd"
	ProjectSettings.set_setting(screenshot_key, wanted)
	ProjectSettings.save()
	var preserving_controller: RefCounted = RuntimeServiceController.new()
	_expect(
		preserving_controller.set_tool_enabled("get_game_screenshot", true).get("ok", false),
		"matching pre-existing runtime service is usable"
	)
	preserving_controller.set_tool_enabled("get_game_screenshot", false)
	_expect_equal(ProjectSettings.get_setting(screenshot_key), wanted, "unowned pre-existing service is preserved on disable")
	ProjectSettings.set_setting(screenshot_key, null)
	ProjectSettings.save()

	var game_state := {"running": true}
	var running_controller: RefCounted = RuntimeServiceController.new()
	running_controller.setup(null, "runtime-test-owner", func() -> bool: return bool(game_state["running"]))
	var missing_while_running: Dictionary = running_controller.ensure_service("input")
	_expect(not missing_while_running.get("ok", false), "a missing service is not added after the game has started")
	_expect_equal(
		missing_while_running.get("error", {}).get("code"),
		-32020,
		"an already-running game reports the explicit runtime-service-unavailable error"
	)
	_expect(not ProjectSettings.has_setting(input_key), "already-running diagnostics leave project autoloads unchanged")

	game_state["running"] = false
	running_controller.update_game_state()
	_expect(
		running_controller.set_tool_enabled("simulate_key", true).get("ok", false),
		"a runtime service can be installed before the next game launch"
	)
	game_state["running"] = true
	running_controller.update_game_state()
	_expect(
		running_controller.ensure_service("input").get("ok", false),
		"the game-launch service snapshot accepts a service installed before launch"
	)
	running_controller.set_tool_enabled("simulate_key", false)
	_expect(not ProjectSettings.has_setting(input_key), "disabling a running service removes only its project setting")
	_expect(
		running_controller.set_tool_enabled("simulate_key", true).get("ok", false),
		"re-enabling a service loaded by the current game uses the launch snapshot"
	)
	_expect(ProjectSettings.has_setting(input_key), "re-enabling during a run restores the next-launch project setting")
	var late_inspector: Dictionary = running_controller.ensure_service("inspector")
	_expect_equal(
		late_inspector.get("error", {}).get("code"),
		-32020,
		"a different service first requested after launch remains unavailable"
	)
	running_controller.cleanup_owned_services()

	# Simulate a crash between moving the old journal to its backup and
	# publishing the newly flushed journal. Startup must recover from the
	# backup so an owned autoload is not stranded in the project.
	ProjectSettings.set_setting(screenshot_key, wanted)
	ProjectSettings.save()
	var interrupted_journal := ConfigFile.new()
	interrupted_journal.set_value("session", "owner_nonce", "AAECAwQFBgcICQoLDA0ODw")
	interrupted_journal.set_value(
		"session",
		"project_path",
		Protocol.canonicalize_project_path(ProjectSettings.globalize_path("res://"))
	)
	interrupted_journal.set_value("owned", "screenshot", "res://addons/godot_mcp/mcp_screenshot_service.gd")
	var backup_path: String = RuntimeServiceController.JOURNAL_BACKUP_PATH
	_expect_equal(interrupted_journal.save(backup_path), OK, "interrupted journal backup fixture is written")
	var recovery_controller: RefCounted = RuntimeServiceController.new()
	recovery_controller.setup(null, "runtime-recovery-owner", func() -> bool: return false)
	_expect(not ProjectSettings.has_setting(screenshot_key), "backup journal recovery removes the stranded owned autoload")
	_expect(not FileAccess.file_exists(backup_path), "backup journal is removed after successful recovery")


func _test_reconnect_contract() -> void:
	var client: Node = WebSocketBridgeClient.new()
	var first_nonce: String = client._fresh_client_nonce()
	var second_nonce: String = client._fresh_client_nonce()
	_expect(Protocol.validate_nonce(first_nonce, 16), "a reconnect handshake creates a valid client nonce")
	_expect(Protocol.validate_nonce(second_nonce, 16), "a subsequent handshake creates a valid client nonce")
	_expect(first_nonce != second_nonce, "separate handshake attempts use fresh client nonces")

	client._running = true
	client._generation = 7
	client._client_nonce = first_nonce
	client._server_nonce = "stale-server-nonce"
	for attempt: int in range(8):
		client._schedule_reconnect("test reconnect %d" % attempt)
		_expect(client.get_state_name() == "BACKOFF", "failed sessions enter BACKOFF")
		_expect(client.get_retry_seconds() >= 0.0 and client.get_retry_seconds() <= 6.0, "retry delay remains bounded at five seconds plus jitter")
		_expect(client._retry_delay <= 5.0, "the exponential retry base never exceeds five seconds")
	_expect(client.get_session_generation() > 7, "closing/retrying invalidates the prior session generation")
	_expect(client._client_nonce.is_empty() and client._server_nonce.is_empty(), "incomplete handshake state is not replayed across reconnects")
	client.queue_free()

	var malformed_client: Node = WebSocketBridgeClient.new()
	malformed_client._running = true
	malformed_client._state = WebSocketBridgeClient.BridgeState.HANDSHAKING
	malformed_client._handshake_stage = "server_proof"
	malformed_client._handshake_request_id = "malformed-response"
	malformed_client._handle_message(JSON.stringify({
		"jsonrpc": "2.0",
		"id": "malformed-response",
		"result": {"server_nonce": 7, "server_proof": "invalid"},
	}))
	_expect(malformed_client.get_state_name() == "BACKOFF", "malformed cross-language handshake fields fail closed")
	malformed_client.queue_free()

	var unsupported_client: Node = WebSocketBridgeClient.new()
	unsupported_client._running = true
	unsupported_client._state = WebSocketBridgeClient.BridgeState.HANDSHAKING
	unsupported_client._handshake_stage = "server_proof"
	unsupported_client._handshake_request_id = "unsupported-response"
	unsupported_client._handle_message(JSON.stringify({
		"jsonrpc": "2.0",
		"id": "unsupported-response",
		"error": {"code": Protocol.ERROR_UNSUPPORTED_PROTOCOL, "message": "unsupported_protocol"},
	}))
	_expect(unsupported_client.get_state_name() == "BACKOFF", "unsupported protocol response fails closed")
	_expect_equal(
		unsupported_client._last_close_code,
		Protocol.CLOSE_PROTOCOL_ERROR,
		"JSON numeric unsupported-version error selects the protocol close code"
	)
	unsupported_client.queue_free()

	var timeout_client: Node = WebSocketBridgeClient.new()
	timeout_client._running = true
	timeout_client._state = WebSocketBridgeClient.BridgeState.HANDSHAKING
	timeout_client._handle_handshake_timeout()
	_expect(timeout_client.get_state_name() == "BACKOFF", "shared handshake deadline enters reconnect backoff")
	_expect(timeout_client.get_state_detail().contains("timed out"), "handshake timeout retains a diagnostic")
	timeout_client.queue_free()


func _test_router_session_guards() -> void:
	var router: Node = CommandRouter.new()
	var missing_project: Dictionary = router._validate_authorized_session_context(1)
	_expect_equal(missing_project.get("code"), -32002, "an unconfigured bridge project fails closed")
	router.expected_project_path = Protocol.canonicalize_project_path(ProjectSettings.globalize_path("res://"))
	var missing_validator: Dictionary = router._validate_authorized_session_context(1)
	_expect_equal(missing_validator.get("code"), -32000, "a missing session validator fails closed")
	router.session_validator = func(_generation: int) -> bool: return true
	var missing_generation: Dictionary = router._validate_authorized_session_context(-1)
	_expect_equal(missing_generation.get("code"), -32000, "a missing session generation fails closed")
	router.session_validator = func(_generation: int) -> bool: return false
	var invalid_session: Dictionary = router._validate_authorized_session_context(3)
	_expect_equal(invalid_session.get("code"), -32000, "a non-READY authorized session fails closed")
	router.session_validator = func(generation: int) -> bool: return generation == 4
	_expect(router._validate_authorized_session_context(4).is_empty(), "a matching READY session passes the authorization guard")
	var missing_plugin: Dictionary = router._validate_execution_context(4)
	_expect_equal(missing_plugin.get("code"), -32603, "an unavailable EditorPlugin context returns a structured failure")
	router.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		_failures.append("%s (expected %s, got %s)" % [message, str(expected), str(actual)])


func _load_protocol_fixture() -> Dictionary:
	var path := "res://tests/fixtures/bridge-protocol-v1.json"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var json := JSON.new()
	var parse_error := json.parse(file.get_as_text())
	file.close()
	if parse_error != OK or not json.data is Dictionary:
		return {}
	return json.data
