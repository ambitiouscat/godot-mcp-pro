@tool
extends RefCounted
class_name MCPBridgeProtocolV1

const PROTOCOL_VERSION := 1
const DISCOVERY_SCHEMA := "godot-ai-bridge-discovery"
const SESSION_SCHEMA := "godot-ai-bridge-session"
const PROOF_DOMAIN := "godot-ai-bridge-v1"
const HANDSHAKE_TIMEOUT_SECONDS := 5.0
const DISCOVERY_TTL_MS := 30_000
const DISCOVERY_REFRESH_MS := 10_000

const ERROR_NOT_READY := -32000
const ERROR_AUTHENTICATION := -32001
const ERROR_PROJECT_MISMATCH := -32002
const ERROR_UNSUPPORTED_PROTOCOL := -32003
const ERROR_HANDSHAKE_TIMEOUT := -32004

const CLOSE_POLICY_VIOLATION := 1008
const CLOSE_PROTOCOL_ERROR := 1002


static func now_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


static func canonicalize_project_path(raw_path: String, platform_name: String = "") -> String:
	var platform := platform_name if not platform_name.is_empty() else OS.get_name()
	var value := raw_path.strip_edges()
	if value.begins_with("res://") or value.begins_with("user://"):
		value = ProjectSettings.globalize_path(value)
	value = value.replace("\\", "/")
	if not _is_absolute_path(value):
		value = ProjectSettings.globalize_path("res://").path_join(value)
	value = value.simplify_path().replace("\\", "/")
	while value.contains("//") and not value.begins_with("//"):
		value = value.replace("//", "/")
	if platform == "Windows":
		value = value.to_lower()
		if value.begins_with("//") and _is_filesystem_root(value) and not value.ends_with("/"):
			value += "/"
	while value.length() > 1 and value.ends_with("/") and not _is_filesystem_root(value):
		value = value.left(value.length() - 1)
	return value


static func project_hash(canonical_project_path: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(canonical_project_path.to_utf8_buffer())
	return context.finish().hex_encode()


static func base64url_encode(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").rstrip("=")


static func base64url_decode(value: String) -> PackedByteArray:
	var padded := value.replace("-", "+").replace("_", "/")
	while padded.length() % 4 != 0:
		padded += "="
	return Marshalls.base64_to_raw(padded)


static func random_base64url(byte_count: int) -> String:
	var crypto := Crypto.new()
	return base64url_encode(crypto.generate_random_bytes(byte_count))


static func proof_input(
		role: String,
		canonical_project_path: String,
		owner_nonce: String,
		client_nonce: String,
		server_nonce: String
	) -> PackedByteArray:
	var fields: Array[String] = [
		PROOF_DOMAIN,
		role,
		canonical_project_path,
		owner_nonce,
		client_nonce,
		server_nonce,
	]
	var bytes := PackedByteArray()
	for index in fields.size():
		bytes.append_array(fields[index].to_utf8_buffer())
		if index + 1 < fields.size():
			bytes.append(0)
	return bytes


static func hmac_proof(
		key: PackedByteArray,
		role: String,
		canonical_project_path: String,
		owner_nonce: String,
		client_nonce: String,
		server_nonce: String
	) -> String:
	var hmac := HMACContext.new()
	var err := hmac.start(HashingContext.HASH_SHA256, key)
	if err != OK:
		return ""
	hmac.update(proof_input(role, canonical_project_path, owner_nonce, client_nonce, server_nonce))
	return base64url_encode(hmac.finish())


static func constant_time_equal(left: String, right: String) -> bool:
	var a := left.to_utf8_buffer()
	var b := right.to_utf8_buffer()
	var difference := a.size() ^ b.size()
	var length := maxi(a.size(), b.size())
	for index in length:
		var av := a[index] if index < a.size() else 0
		var bv := b[index] if index < b.size() else 0
		difference |= av ^ bv
	return difference == 0


static func validate_nonce(value: Variant, minimum_bytes: int = 16) -> bool:
	if not value is String or (value as String).is_empty():
		return false
	var text: String = value
	if not _is_canonical_base64url(text):
		return false
	var decoded := base64url_decode(text)
	return decoded.size() >= minimum_bytes and base64url_encode(decoded) == text


static func validate_proof(value: Variant) -> bool:
	if not value is String or not _is_canonical_base64url(value as String):
		return false
	var decoded := base64url_decode(value as String)
	return decoded.size() == 32 and base64url_encode(decoded) == value


static func validate_discovery(
		record: Variant,
		expected_project_path: String,
		expected_owner_nonce: String,
		current_time_ms: int = -1
	) -> Dictionary:
	if not record is Dictionary:
		return _invalid("Discovery record must be an object")
	var data: Dictionary = record
	var required := [
		"schema", "protocol_version", "project_path", "endpoint",
		"owner_pid", "owner_started_at_ms", "parent_pid", "parent_started_at_ms",
		"owner_nonce", "created_at_ms", "expires_at_ms",
	]
	for field: String in required:
		if not data.has(field):
			return _invalid("Discovery record is missing '%s'" % field)
	if data.has("token") or data.has("token_file"):
		return _invalid("Discovery record must not contain credential material")
	if data.get("schema") != DISCOVERY_SCHEMA:
		return _invalid("Unsupported discovery schema")
	if not _is_integer_number(data.get("protocol_version")) or int(data.get("protocol_version")) != PROTOCOL_VERSION:
		return _invalid("Unsupported bridge protocol version")
	if not data.get("project_path") is String or data.get("project_path") != expected_project_path:
		return _invalid("Discovery project does not match this editor")
	if not data.get("owner_nonce") is String or data.get("owner_nonce") != expected_owner_nonce:
		return _invalid("Discovery owner nonce does not match this session")
	if not _valid_loopback_websocket_url(data.get("endpoint")):
		return _invalid("Discovery endpoint is not an IPv4 loopback WebSocket URL")
	for field: String in ["owner_pid", "owner_started_at_ms", "parent_pid", "parent_started_at_ms", "created_at_ms", "expires_at_ms"]:
		if not _is_integer_number(data.get(field)) or int(data.get(field)) < 0:
			return _invalid("Discovery field '%s' must be a non-negative integer" % field)
	if int(data.get("owner_pid")) <= 0 or int(data.get("owner_started_at_ms")) <= 0:
		return _invalid("Discovery owner process identity is invalid")
	var parent_pid := int(data.get("parent_pid"))
	var parent_started := int(data.get("parent_started_at_ms"))
	if (parent_pid == 0) != (parent_started == 0):
		return _invalid("Discovery parent identity must be either a complete pair or zero")
	var now := current_time_ms if current_time_ms >= 0 else now_ms()
	if int(data.get("created_at_ms")) > now + 5_000:
		return _invalid("Discovery creation time is in the future")
	if int(data.get("expires_at_ms")) <= now:
		return _invalid("Discovery record has expired")
	if int(data.get("expires_at_ms")) <= int(data.get("created_at_ms")):
		return _invalid("Discovery expiration must be later than creation")
	if int(data.get("expires_at_ms")) - int(data.get("created_at_ms")) > DISCOVERY_TTL_MS:
		return _invalid("Discovery lifetime exceeds the protocol limit")
	return {"ok": true, "record": data}


static func validate_session(record: Variant, expected_project_path: String) -> Dictionary:
	if not record is Dictionary:
		return _invalid("Session contract must be an object")
	var data: Dictionary = record
	for field: String in ["schema", "protocol_version", "project_path", "discovery_path", "token_file", "owner_nonce", "created_at_ms"]:
		if not data.has(field):
			return _invalid("Session contract is missing '%s'" % field)
	if data.get("schema") != SESSION_SCHEMA:
		return _invalid("Unsupported session schema")
	if not _is_integer_number(data.get("protocol_version")) or int(data.get("protocol_version")) != PROTOCOL_VERSION:
		return _invalid("Unsupported session protocol version")
	if data.get("project_path") != expected_project_path:
		return _invalid("Session project does not match this editor")
	if not data.get("discovery_path") is String or not _is_absolute_path(data.get("discovery_path")):
		return _invalid("Session discovery path must be absolute")
	if not data.get("token_file") is String or not _is_absolute_path(data.get("token_file")):
		return _invalid("Session token path must be absolute")
	if not validate_nonce(data.get("owner_nonce"), 16):
		return _invalid("Session owner nonce is invalid")
	if not _is_integer_number(data.get("created_at_ms")) or int(data.get("created_at_ms")) <= 0:
		return _invalid("Session creation time is invalid")
	return {"ok": true, "record": data}


static func _valid_loopback_websocket_url(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	const PREFIX := "ws://127.0.0.1:"
	if not text.begins_with(PREFIX):
		return false
	var port_text := text.substr(PREFIX.length())
	if port_text.contains("/") or not port_text.is_valid_int():
		return false
	var port := int(port_text)
	return port > 0 and port <= 65535 and str(port) == port_text


static func _is_integer_number(value: Variant) -> bool:
	if value is int:
		return true
	return value is float and floor(value as float) == value as float


static func _is_canonical_base64url(value: String) -> bool:
	if value.is_empty():
		return false
	for byte: int in value.to_ascii_buffer():
		var allowed := (
			(byte >= 48 and byte <= 57)
			or (byte >= 65 and byte <= 90)
			or (byte >= 97 and byte <= 122)
			or byte == 45
			or byte == 95
		)
		if not allowed:
			return false
	return true


static func _is_absolute_path(value: String) -> bool:
	if value.begins_with("/") or value.begins_with("//"):
		return true
	return value.length() >= 3 and value[1] == ":" and value[2] == "/"


static func _is_filesystem_root(value: String) -> bool:
	if value == "/":
		return true
	if value.length() == 3 and value[1] == ":" and value[2] == "/":
		return true
	if value.begins_with("//"):
		var unc_path := value.trim_prefix("//").trim_suffix("/")
		return unc_path.split("/", false).size() == 2
	return false


static func _invalid(message: String) -> Dictionary:
	return {"ok": false, "error": message}
