@tool
extends RefCounted
class_name MCPBridgeProcessIdentity

const IDENTITY_V1_BASE := 4503599627370496 # 2^52; marks Linux opaque v1 IDs.
const IDENTITY_V1_MAX := 9007199254740991 # Number.MAX_SAFE_INTEGER / 2^53 - 1.


static func inspect(pid: int, expected_started_at_ms: int) -> Dictionary:
	if pid <= 0 or expected_started_at_ms <= 0:
		return {"matches": false, "stale": false, "error": "Process identity fields are invalid"}
	if OS.get_name() == "Linux" and not _is_linux_identity_v1(expected_started_at_ms):
		# Pre-v1 Linux records stored epoch milliseconds; values above the safe
		# range are invalid too. Do not compare either to a v1 hash identity.
		return _linux_unverifiable_expected_identity(_process_exists(pid))
	var actual := started_at_ms(pid)
	if actual <= 0:
		var existence := _process_exists(pid)
		if existence == 0:
			return {"matches": false, "stale": true, "error": "Process is not running"}
		return {"matches": false, "stale": false, "error": "Process start identity is unavailable"}
	if actual != expected_started_at_ms:
		return {
			"matches": false,
			"stale": true,
			"actual_started_at_ms": actual,
			"error": "PID has been reused or the process start identity changed",
		}
	return {"matches": true, "stale": false, "actual_started_at_ms": actual}


static func _process_exists(pid: int) -> int:
	match OS.get_name():
		"Windows":
			var output: Array = []
			var command := "if (Get-Process -Id %d -ErrorAction SilentlyContinue) { exit 0 } else { exit 3 }" % pid
			var exit_code := OS.execute(
				"powershell.exe",
				PackedStringArray(["-NoProfile", "-NonInteractive", "-Command", command]),
				output,
				true,
				false
			)
			if exit_code == 0:
				return 1
			if exit_code == 3:
				return 0
		"Linux":
			if not DirAccess.dir_exists_absolute("/proc"):
				return -1
			if not DirAccess.dir_exists_absolute("/proc/%d" % pid):
				return 0
			# Linux zombies retain a /proc entry and answer kill(pid, 0), but can
			# never resume ownership of a bridge or daemon record.
			return _linux_proc_stat_exists(_read_linux_proc_ascii("/proc/%d/stat" % pid))
		"macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			var output: Array = []
			var exit_code := OS.execute("ps", PackedStringArray(["-p", str(pid)]), output, true, false)
			if exit_code == 0:
				return 1
			if exit_code == 1:
				return 0
	return -1


static func started_at_ms(pid: int) -> int:
	if pid <= 0:
		return -1
	match OS.get_name():
		"Windows":
			return _windows_started_at_ms(pid)
		"Linux":
			return _linux_started_at_ms(pid)
		"macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			return _bsd_started_at_ms(pid)
	return -1


static func _windows_started_at_ms(pid: int) -> int:
	var output: Array = []
	var command := "([DateTimeOffset](Get-Process -Id %d -ErrorAction Stop).StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()" % pid
	var exit_code := OS.execute(
		"powershell.exe",
		PackedStringArray(["-NoProfile", "-NonInteractive", "-Command", command]),
		output,
		true,
		false
	)
	if exit_code != 0 or output.is_empty():
		return -1
	var value := str(output[0]).strip_edges()
	return int(value) if value.is_valid_int() else -1


static func _linux_started_at_ms(pid: int) -> int:
	var boot_id := _read_linux_proc_ascii("/proc/sys/kernel/random/boot_id")
	return linux_identity_from_proc_stat(boot_id, _read_linux_proc_ascii("/proc/%d/stat" % pid))


static func _parse_linux_proc_stat(stat_text: String) -> Dictionary:
	var text := stat_text.strip_edges()
	var closing_parenthesis := text.rfind(")")
	if closing_parenthesis < 0:
		return {}
	var fields := text.substr(closing_parenthesis + 1).strip_edges().split(" ", false)
	if fields.size() <= 19 or fields[0].length() != 1 or not _is_ascii_decimal(fields[19]):
		return {}
	return {"state": fields[0], "start_ticks": fields[19]}


static func _is_ascii_decimal(value: String) -> bool:
	if value.is_empty():
		return false
	for byte: int in value.to_ascii_buffer():
		if byte < 48 or byte > 57:
			return false
	return true


static func _is_linux_identity_v1(value: int) -> bool:
	return value >= IDENTITY_V1_BASE and value <= IDENTITY_V1_MAX


static func _linux_unverifiable_expected_identity(existence: int) -> Dictionary:
	if existence == 0:
		return {"matches": false, "stale": true, "error": "Process is not running"}
	return {"matches": false, "stale": false, "error": "Legacy Linux process identity is unverifiable"}


static func _linux_proc_stat_exists(stat_text: String) -> int:
	var stat := _parse_linux_proc_stat(stat_text)
	if stat.is_empty():
		return -1
	return 0 if stat.get("state") == "Z" else 1


static func linux_identity_from_proc_stat(boot_id: String, stat_text: String) -> int:
	var stat := _parse_linux_proc_stat(stat_text)
	if stat.is_empty() or stat.get("state") == "Z":
		return -1
	return linux_identity_from_boot_id_and_ticks(boot_id, str(stat.get("start_ticks", "")))


# On Linux, the legacy started_at_ms field stores this opaque v1 identity,
# not a wall-clock timestamp. It is a version-tagged, JSON-safe 53-bit integer.
static func linux_identity_from_boot_id_and_ticks(boot_id: String, start_ticks: String) -> int:
	var normalized_boot_id := boot_id.strip_edges().to_lower()
	if normalized_boot_id.is_empty() or not _is_ascii_decimal(start_ticks):
		return -1
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return -1
	var payload := "godot-process-identity/linux/v1".to_utf8_buffer()
	payload.append(0)
	payload.append_array(normalized_boot_id.to_utf8_buffer())
	payload.append(0)
	payload.append_array(start_ticks.to_utf8_buffer())
	if context.update(payload) != OK:
		return -1
	var digest := context.finish()
	if digest.size() < 7:
		return -1
	var digest_prefix := 0
	for index: int in range(6):
		digest_prefix = digest_prefix * 256 + int(digest[index])
	digest_prefix = digest_prefix * 16 + (int(digest[6]) >> 4)
	return IDENTITY_V1_BASE + digest_prefix


static func _read_linux_proc_ascii(path: String, max_bytes: int = 4 * 1024 * 1024) -> String:
	if max_bytes <= 0:
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var bytes := PackedByteArray()
	var terminated := false
	while bytes.size() < max_bytes:
		var requested := mini(4096, max_bytes - bytes.size())
		var chunk := file.get_buffer(requested)
		if chunk.is_empty():
			break
		for value: int in chunk:
			# procfs files report a zero length and Godot 4.3 may pad a
			# binary read with NUL bytes. Treat the first NUL as EOF instead
			# of sending it through FileAccess.get_as_text()'s UTF-8 parser.
			if value == 0:
				terminated = true
				break
			bytes.append(value)
		if terminated or chunk.size() < requested:
			break
	var reached_limit := bytes.size() >= max_bytes and not terminated and not file.eof_reached()
	file.close()
	if reached_limit:
		return ""
	return bytes.get_string_from_ascii()


static func _bsd_started_at_ms(pid: int) -> int:
	var process_output: Array = []
	if OS.execute(
		"ps",
		PackedStringArray(["-o", "lstart=", "-p", str(pid)]),
		process_output,
		true,
		false
	) != 0 or process_output.is_empty():
		return -1
	var started_text := str(process_output[0]).strip_edges()
	if started_text.is_empty():
		return -1
	# BSD/macOS date parses the local `ps lstart` value into the same Unix
	# second that Node's Date.parse uses for the discovery publisher.
	var epoch_output: Array = []
	if OS.execute(
		"date",
		PackedStringArray(["-j", "-f", "%a %b %e %T %Y", started_text, "+%s"]),
		epoch_output,
		true,
		false
	) != 0 or epoch_output.is_empty():
		return -1
	var epoch_text := str(epoch_output[0]).strip_edges()
	return int(epoch_text) * 1000 if epoch_text.is_valid_int() else -1
