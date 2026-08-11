@tool
extends RefCounted
class_name MCPBridgeSessionCoordinator

const Protocol := preload("res://addons/godot_mcp/bridge_protocol_v1.gd")
const ProcessIdentity := preload("res://addons/godot_mcp/bridge_process_identity.gd")
const DIRECTORY_PERMISSIONS := 448 # 0700
const FILE_PERMISSIONS := 384 # 0600
const LOCK_SCHEMA := "godot-ai-bridge-session-lock"
const INCOMPLETE_LOCK_GRACE_SECONDS := 30

var project_path: String = ""
var runtime_dir: String = ""
var session_path: String = ""
var discovery_path: String = ""
var token_path: String = ""
var lock_dir: String = ""
var lock_owner_path: String = ""
var owner_nonce: String = ""
var token_bytes := PackedByteArray()
var coordinator_pid := 0
var coordinator_started_at_ms := 0
var last_error: String = ""
var _started := false
var _owns_lock := false
var _process_identity_inspector := Callable()


func start_session() -> bool:
	if _started:
		return true
	last_error = ""
	project_path = Protocol.canonicalize_project_path(ProjectSettings.globalize_path("res://"))
	if project_path.is_empty():
		last_error = "Could not canonicalize the Godot project path"
		return false
	runtime_dir = _system_temp_dir().path_join("godot-mcp-pro").path_join(Protocol.project_hash(project_path))
	if not _ensure_private_directory(runtime_dir):
		return false

	var configured_session := OS.get_environment("GODOT_MCP_SESSION_FILE").strip_edges() if OS.has_environment("GODOT_MCP_SESSION_FILE") else ""
	session_path = configured_session.replace("\\", "/").simplify_path() if not configured_session.is_empty() else runtime_dir.path_join("bridge-session.json")
	if not session_path.is_absolute_path():
		last_error = "GODOT_MCP_SESSION_FILE must be an absolute path"
		return false
	if not _ensure_private_directory(session_path.get_base_dir()):
		return false
	discovery_path = runtime_dir.path_join("bridge-discovery.json")
	lock_dir = runtime_dir.path_join("bridge-session.lock")
	lock_owner_path = lock_dir.path_join("owner.json")

	coordinator_pid = OS.get_process_id()
	coordinator_started_at_ms = ProcessIdentity.started_at_ms(coordinator_pid)
	if coordinator_pid <= 0 or coordinator_started_at_ms <= 0:
		last_error = "Could not establish a durable identity for the Godot editor process"
		return false
	owner_nonce = Protocol.random_base64url(24)
	token_bytes = Crypto.new().generate_random_bytes(32)
	if token_bytes.size() != 32 or not Protocol.validate_nonce(owner_nonce, 16):
		last_error = "Cryptographic session material could not be generated"
		return false
	if not _acquire_session_lock():
		token_bytes.clear()
		return false
	if not _cleanup_verified_previous_session():
		_release_session_lock()
		token_bytes.clear()
		return false

	token_path = runtime_dir.path_join("bridge-token-%s.txt" % owner_nonce)
	if not _write_protected_file(token_path, Protocol.base64url_encode(token_bytes)):
		_cleanup_owned_files()
		return false
	var contract := {
		"schema": Protocol.SESSION_SCHEMA,
		"protocol_version": Protocol.PROTOCOL_VERSION,
		"project_path": project_path,
		"discovery_path": discovery_path,
		"token_file": token_path,
		"owner_nonce": owner_nonce,
		"created_at_ms": Protocol.now_ms(),
		"coordinator_pid": coordinator_pid,
		"coordinator_started_at_ms": coordinator_started_at_ms,
	}
	if not _write_session_contract(contract):
		_cleanup_owned_files()
		return false
	_started = true
	return true


func stop_session() -> void:
	if not _started and owner_nonce.is_empty() and not _owns_lock:
		return
	_remove_json_if_owned(discovery_path)
	_remove_json_if_owned(session_path)
	if not token_path.is_empty() and FileAccess.file_exists(token_path):
		DirAccess.remove_absolute(token_path)
	token_bytes.clear()
	_started = false
	_release_session_lock()
	owner_nonce = ""


func read_valid_discovery(_check_process_liveness: bool = true) -> Dictionary:
	if not _started:
		return {"ok": false, "error": "Bridge session coordinator is not running"}
	var record := _read_json_dictionary(discovery_path)
	if record == null:
		return {"ok": false, "error": "Waiting for a complete agent discovery record"}
	var validation: Dictionary = Protocol.validate_discovery(record, project_path, owner_nonce)
	if not validation.get("ok", false):
		return validation
	var data: Dictionary = validation["record"]
	var owner_status: Dictionary = _inspect_process_identity(int(data["owner_pid"]), int(data["owner_started_at_ms"]))
	if not owner_status.get("matches", false):
		return {"ok": false, "error": "Discovery owner identity is invalid: %s" % owner_status.get("error", "unknown")}
	var parent_pid := int(data["parent_pid"])
	if parent_pid > 0:
		var parent_status: Dictionary = _inspect_process_identity(parent_pid, int(data["parent_started_at_ms"]))
		if not parent_status.get("matches", false):
			return {"ok": false, "error": "Discovery parent identity is invalid: %s" % parent_status.get("error", "unknown")}
	return validation


func owns_current_session() -> bool:
	return _started and _owns_lock and not owner_nonce.is_empty() and token_bytes.size() == 32


func _acquire_session_lock() -> bool:
	var lock_error := DirAccess.make_dir_absolute(lock_dir)
	if lock_error == ERR_ALREADY_EXISTS:
		var existing := _inspect_existing_lock()
		if not existing.get("stale", false):
			last_error = existing.get("error", "Another editor owns this project bridge session")
			return false
		if not _remove_stale_lock(existing.get("record")):
			return false
		lock_error = DirAccess.make_dir_absolute(lock_dir)
	if lock_error != OK:
		last_error = "Could not acquire the project bridge session lock: %s" % error_string(lock_error)
		return false
	_owns_lock = true
	if not _apply_unix_permissions(lock_dir, DIRECTORY_PERMISSIONS):
		_owns_lock = false
		DirAccess.remove_absolute(lock_dir)
		return false
	var record := {
		"schema": LOCK_SCHEMA,
		"protocol_version": Protocol.PROTOCOL_VERSION,
		"project_path": project_path,
		"coordinator_pid": coordinator_pid,
		"coordinator_started_at_ms": coordinator_started_at_ms,
		"owner_nonce": owner_nonce,
		"created_at_ms": Protocol.now_ms(),
	}
	if not _write_protected_file(lock_owner_path, JSON.stringify(record)):
		_owns_lock = false
		DirAccess.remove_absolute(lock_dir)
		return false
	return true


func _inspect_existing_lock() -> Dictionary:
	var record := _read_json_dictionary(lock_owner_path)
	if record == null:
		var incomplete_path := lock_owner_path if FileAccess.file_exists(lock_owner_path) else lock_dir
		var modified_seconds := FileAccess.get_modified_time(incomplete_path)
		var age_seconds := int(Time.get_unix_time_from_system()) - modified_seconds
		if modified_seconds > 0 and age_seconds >= INCOMPLETE_LOCK_GRACE_SECONDS:
			return {"stale": true, "record": null, "error": "Incomplete session lock is stale"}
		return {"stale": false, "error": "A session lock is being created or is malformed; retry after 30 seconds"}
	var data: Dictionary = record
	if (
		data.get("schema") != LOCK_SCHEMA
		or data.get("protocol_version") != Protocol.PROTOCOL_VERSION
		or data.get("project_path") != project_path
		or not _is_integer_number(data.get("coordinator_pid"))
		or not _is_integer_number(data.get("coordinator_started_at_ms"))
		or not data.get("owner_nonce") is String
		or int(data.get("coordinator_pid")) <= 0
		or int(data.get("coordinator_started_at_ms")) <= 0
		or not Protocol.validate_nonce(data.get("owner_nonce"), 16)
	):
		return {"stale": false, "error": "Existing session lock has an unverified format"}
	var status: Dictionary = _inspect_process_identity(int(data["coordinator_pid"]), int(data["coordinator_started_at_ms"]))
	if status.get("matches", false):
		return {"stale": false, "record": data, "error": "Another live Godot editor owns this project's bridge session"}
	if not status.get("stale", false):
		return {"stale": false, "record": data, "error": "Existing session lock ownership cannot be verified"}
	return {"stale": true, "record": data, "error": status.get("error", "Stale session lock")}


func _remove_stale_lock(record: Variant, incomplete_grace_seconds: int = INCOMPLETE_LOCK_GRACE_SECONDS) -> bool:
	if record != null:
		var current := _read_json_dictionary(lock_owner_path)
		if current == null or not current is Dictionary:
			last_error = "Session lock changed while stale ownership was being verified"
			return false
		var expected: Dictionary = record
		if (
			current.get("owner_nonce") != expected.get("owner_nonce")
			or current.get("coordinator_pid") != expected.get("coordinator_pid")
			or current.get("coordinator_started_at_ms") != expected.get("coordinator_started_at_ms")
		):
			last_error = "Session lock owner changed while cleanup was in progress"
			return false
		var expected_status: Dictionary = _inspect_process_identity(
			int(expected.get("coordinator_pid")),
			int(expected.get("coordinator_started_at_ms"))
		)
		if not expected_status.get("stale", false):
			last_error = "Session lock ownership is no longer verified stale"
			return false
		if not _cleanup_artifacts_owned_by_nonce(str(expected.get("owner_nonce", ""))):
			return false
		var owner_remove_error := DirAccess.remove_absolute(lock_owner_path)
		if owner_remove_error != OK:
			last_error = "Could not remove the verified stale lock owner: %s" % error_string(owner_remove_error)
			return false
	else:
		# An interrupted owner write has no usable identity. Recheck both its
		# contents and age immediately before removing only the malformed lock.
		var owner_existed := FileAccess.file_exists(lock_owner_path)
		var artifact_path := lock_owner_path if owner_existed else lock_dir
		var modified_seconds := FileAccess.get_modified_time(artifact_path)
		var age_seconds := int(Time.get_unix_time_from_system()) - modified_seconds
		if modified_seconds <= 0 or age_seconds < maxi(0, incomplete_grace_seconds):
			last_error = "Incomplete session lock has not remained unchanged for the cleanup grace period"
			return false
		if _read_json_dictionary(lock_owner_path) is Dictionary:
			last_error = "Session lock became complete while stale cleanup was in progress"
			return false
		if owner_existed:
			if not FileAccess.file_exists(lock_owner_path) or FileAccess.get_modified_time(lock_owner_path) != modified_seconds:
				last_error = "Incomplete session lock changed while stale cleanup was in progress"
				return false
			var malformed_remove_error := DirAccess.remove_absolute(lock_owner_path)
			if malformed_remove_error != OK:
				last_error = "Could not remove the stale incomplete lock owner: %s" % error_string(malformed_remove_error)
				return false
		elif FileAccess.file_exists(lock_owner_path) or FileAccess.get_modified_time(lock_dir) != modified_seconds:
			last_error = "Incomplete session lock changed while stale cleanup was in progress"
			return false
	var remove_error := DirAccess.remove_absolute(lock_dir)
	if remove_error != OK:
		last_error = "Could not remove verified stale session lock: %s" % error_string(remove_error)
		return false
	return true


func _release_session_lock() -> void:
	if not _owns_lock:
		return
	var record := _read_json_dictionary(lock_owner_path)
	if record is Dictionary:
		var data: Dictionary = record
		if (
			data.get("owner_nonce") == owner_nonce
			and data.get("coordinator_pid") == coordinator_pid
			and data.get("coordinator_started_at_ms") == coordinator_started_at_ms
		):
			DirAccess.remove_absolute(lock_owner_path)
			DirAccess.remove_absolute(lock_dir)
	_owns_lock = false


func _cleanup_verified_previous_session() -> bool:
	if FileAccess.file_exists(session_path):
		var old_contract := _read_json_dictionary(session_path)
		if old_contract == null:
			last_error = "Existing bridge session contract is malformed and cannot be cleaned safely"
			return false
		var validation: Dictionary = Protocol.validate_session(old_contract, project_path)
		if not validation.get("ok", false):
			last_error = "Existing bridge session contract cannot be verified: %s" % validation.get("error", "invalid")
			return false
		var data: Dictionary = old_contract
		if not _is_integer_number(data.get("coordinator_pid")) or not _is_integer_number(data.get("coordinator_started_at_ms")):
			last_error = "Existing bridge session lacks a durable coordinator identity"
			return false
		var status: Dictionary = _inspect_process_identity(int(data["coordinator_pid"]), int(data["coordinator_started_at_ms"]))
		if status.get("matches", false):
			last_error = "Another live Godot editor session is already active for this project"
			return false
		if not status.get("stale", false):
			last_error = "Existing Godot editor session ownership cannot be verified"
			return false
		var old_nonce: String = data["owner_nonce"]
		if not _cleanup_discovery_if_stale(old_nonce):
			return false
		var old_token_path: String = data["token_file"]
		if not _is_verified_token_path(old_token_path, old_nonce):
			last_error = "Existing session references a token outside the verified project runtime directory"
			return false
		if FileAccess.file_exists(old_token_path):
			DirAccess.remove_absolute(old_token_path)
		DirAccess.remove_absolute(session_path)
		return true
	return _cleanup_discovery_if_stale("")


func _cleanup_discovery_if_stale(expected_owner_nonce: String) -> bool:
	if not FileAccess.file_exists(discovery_path):
		return true
	var record := _read_json_dictionary(discovery_path)
	if record == null:
		last_error = "Existing discovery record is malformed and cannot be cleaned safely"
		return false
	var data: Dictionary = record
	var record_nonce: Variant = data.get("owner_nonce")
	if not record_nonce is String or (not expected_owner_nonce.is_empty() and record_nonce != expected_owner_nonce):
		last_error = "Existing discovery record does not belong to the verified prior session"
		return false
	if not data.get("created_at_ms") is int and not data.get("created_at_ms") is float:
		last_error = "Existing discovery creation time is invalid"
		return false
	if not data.get("expires_at_ms") is int and not data.get("expires_at_ms") is float:
		last_error = "Existing discovery expiration time is invalid"
		return false
	var created_at := int(data["created_at_ms"])
	var expires_at := int(data["expires_at_ms"])
	if expires_at <= created_at:
		last_error = "Existing discovery lifetime is invalid"
		return false
	var structural_time := mini(Protocol.now_ms(), expires_at - 1)
	var validation: Dictionary = Protocol.validate_discovery(data, project_path, record_nonce, structural_time)
	if not validation.get("ok", false):
		last_error = "Existing discovery record cannot be verified: %s" % validation.get("error", "invalid")
		return false
	var expired := expires_at <= Protocol.now_ms()
	var owner_status: Dictionary = _inspect_process_identity(int(data["owner_pid"]), int(data["owner_started_at_ms"]))
	if not owner_status.get("matches", false) and not owner_status.get("stale", false):
		last_error = "Existing discovery owner identity cannot be verified"
		return false
	var parent_stale := false
	if int(data["parent_pid"]) > 0:
		var parent_status: Dictionary = _inspect_process_identity(int(data["parent_pid"]), int(data["parent_started_at_ms"]))
		if not parent_status.get("matches", false) and not parent_status.get("stale", false):
			last_error = "Existing discovery parent identity cannot be verified"
			return false
		parent_stale = parent_status.get("stale", false)
	var stale: bool = expired or bool(owner_status.get("stale", false)) or parent_stale
	if not stale:
		last_error = "A live agent bridge still owns this project's discovery record"
		return false
	var current := _read_json_dictionary(discovery_path)
	if current == null or current.get("owner_nonce") != record_nonce or current.get("created_at_ms") != data.get("created_at_ms") or current.get("expires_at_ms") != data.get("expires_at_ms"):
		last_error = "Discovery owner changed while stale cleanup was in progress"
		return false
	DirAccess.remove_absolute(discovery_path)
	return true


func _cleanup_artifacts_owned_by_nonce(nonce: String) -> bool:
	if not Protocol.validate_nonce(nonce, 16):
		last_error = "Verified stale lock contains an invalid owner nonce"
		return false
	var exact_paths: Array[String] = [
		runtime_dir.path_join("bridge-token-%s.txt" % nonce),
		"%s.tmp-%s" % [session_path, nonce],
	]
	for artifact_path: String in exact_paths:
		if not FileAccess.file_exists(artifact_path):
			continue
		var remove_error := DirAccess.remove_absolute(artifact_path)
		if remove_error != OK:
			last_error = "Could not remove a verified stale session artifact: %s" % error_string(remove_error)
			return false
	var directory := DirAccess.open(runtime_dir)
	if directory == null:
		last_error = "Could not inspect the project bridge runtime directory"
		return false
	var temporary_prefix := ".%s." % nonce
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if not directory.current_is_dir() and entry.begins_with(temporary_prefix) and entry.ends_with(".tmp"):
			var parts := entry.trim_prefix(".").split(".", false)
			if parts.size() == 4 and parts[0] == nonce and parts[1].is_valid_int() and int(parts[1]) > 0 and parts[3] == "tmp":
				var temporary_path := runtime_dir.path_join(entry)
				var remove_temporary_error := DirAccess.remove_absolute(temporary_path)
				if remove_temporary_error != OK:
					directory.list_dir_end()
					last_error = "Could not remove a verified stale discovery temporary file: %s" % error_string(remove_temporary_error)
					return false
		entry = directory.get_next()
	directory.list_dir_end()
	return true


func _inspect_process_identity(pid: int, started_at_ms: int) -> Dictionary:
	if _process_identity_inspector.is_valid():
		var result: Variant = _process_identity_inspector.call(pid, started_at_ms)
		if result is Dictionary:
			return result
	return ProcessIdentity.inspect(pid, started_at_ms)


func _is_verified_token_path(path: String, nonce: String) -> bool:
	var normalized := path.replace("\\", "/").simplify_path()
	var normalized_runtime := runtime_dir.replace("\\", "/").simplify_path()
	var expected_file := "bridge-token-%s.txt" % nonce
	if OS.get_name() == "Windows":
		normalized = normalized.to_lower()
		normalized_runtime = normalized_runtime.to_lower()
		expected_file = expected_file.to_lower()
	return normalized.get_base_dir() == normalized_runtime and normalized.get_file() == expected_file


func _write_session_contract(contract: Dictionary) -> bool:
	var validation := Protocol.validate_session(contract, project_path)
	if not validation.get("ok", false):
		last_error = validation.get("error", "Invalid session contract")
		return false
	var temporary := "%s.tmp-%s" % [session_path, owner_nonce]
	if not _write_protected_file(temporary, JSON.stringify(contract)):
		return false
	if FileAccess.file_exists(session_path):
		last_error = "Bridge session contract appeared after the project lock was acquired"
		DirAccess.remove_absolute(temporary)
		return false
	var rename_error := DirAccess.rename_absolute(temporary, session_path)
	if rename_error != OK:
		last_error = "Could not publish bridge session contract: %s" % error_string(rename_error)
		DirAccess.remove_absolute(temporary)
		return false
	if not _apply_unix_permissions(session_path, FILE_PERMISSIONS):
		DirAccess.remove_absolute(session_path)
		return false
	return true


func _write_protected_file(path: String, contents: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		last_error = "Could not write protected bridge file: %s" % path
		return false
	file.store_string(contents)
	file.flush()
	file.close()
	if not _apply_unix_permissions(path, FILE_PERMISSIONS):
		DirAccess.remove_absolute(path)
		return false
	return true


func _ensure_private_directory(path: String) -> bool:
	var mkdir_error := DirAccess.make_dir_recursive_absolute(path)
	if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
		last_error = "Could not create bridge runtime directory: %s" % error_string(mkdir_error)
		return false
	return _apply_unix_permissions(path, DIRECTORY_PERMISSIONS)


func _apply_unix_permissions(path: String, permissions: int) -> bool:
	if OS.get_name() in ["Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		var permission_error := FileAccess.set_unix_permissions(path, permissions)
		if permission_error != OK:
			last_error = "Could not restrict bridge permissions for %s: %s" % [path, error_string(permission_error)]
			return false
	return true


func _system_temp_dir() -> String:
	# OS.get_temp_dir() was introduced after the addon's Godot 4.3 baseline.
	for environment_name: String in ["TMPDIR", "TEMP", "TMP"]:
		if OS.has_environment(environment_name):
			var candidate := OS.get_environment(environment_name).strip_edges()
			if not candidate.is_empty():
				return candidate.replace("\\", "/").simplify_path()
	if OS.get_name() == "Windows" and OS.has_environment("LOCALAPPDATA"):
		return OS.get_environment("LOCALAPPDATA").replace("\\", "/").path_join("Temp").simplify_path()
	if OS.get_name() in ["Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		return "/tmp"
	return ProjectSettings.globalize_path("user://").path_join("tmp").simplify_path()


func _read_json_dictionary(path: String) -> Variant:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return null
	return json.data


func _is_integer_number(value: Variant) -> bool:
	return value is int or (value is float and floor(value as float) == value as float)


func _remove_json_if_owned(path: String) -> void:
	var record := _read_json_dictionary(path)
	if record is Dictionary and (record as Dictionary).get("owner_nonce") == owner_nonce:
		DirAccess.remove_absolute(path)


func _cleanup_owned_files() -> void:
	if not token_path.is_empty() and FileAccess.file_exists(token_path):
		DirAccess.remove_absolute(token_path)
	_remove_json_if_owned(session_path)
	token_bytes.clear()
	_release_session_lock()
