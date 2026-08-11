@tool
extends RefCounted

## Incremental Server-Sent Events parser. It keeps raw bytes until a complete
## line is available so UTF-8 code points split across transport chunks are not
## decoded prematurely.

const MAX_PENDING_BYTES := 2 * 1024 * 1024
const MAX_EVENT_BYTES := 4 * 1024 * 1024

var last_error := ""
var _pending := PackedByteArray()
var _event_name := ""
var _event_id := ""
var _retry_ms := -1
var _data_lines: Array[String] = []
var _event_bytes := 0


func feed(chunk: PackedByteArray) -> Array[Dictionary]:
	var frames: Array[Dictionary] = []
	if chunk.is_empty():
		return frames
	_pending.append_array(chunk)
	if _pending.size() > MAX_PENDING_BYTES:
		last_error = "SSE line exceeds the bounded parser buffer"
		reset()
		return frames

	while true:
		var newline := _find_newline()
		if newline < 0:
			break
		var line_bytes := _pending.slice(0, newline)
		_pending = _pending.slice(newline + 1)
		if not line_bytes.is_empty() and line_bytes[line_bytes.size() - 1] == 13:
			line_bytes = line_bytes.slice(0, line_bytes.size() - 1)
		var line := line_bytes.get_string_from_utf8()
		var frame := _consume_line(line)
		if not frame.is_empty():
			frames.append(frame)
		if not last_error.is_empty():
			break
	return frames


func reset() -> void:
	_pending.clear()
	_reset_event()


func _find_newline() -> int:
	for index in range(_pending.size()):
		if _pending[index] == 10:
			return index
	return -1


func _consume_line(line: String) -> Dictionary:
	if line.is_empty():
		return _dispatch()
	if line.begins_with(":"):
		return {}
	var separator := line.find(":")
	var field := line if separator < 0 else line.left(separator)
	var value := "" if separator < 0 else line.substr(separator + 1)
	if value.begins_with(" "):
		value = value.substr(1)
	_event_bytes += line.to_utf8_buffer().size()
	if _event_bytes > MAX_EVENT_BYTES:
		last_error = "SSE event exceeds the bounded parser buffer"
		_reset_event()
		return {}
	match field:
		"event":
			_event_name = value
		"id":
			if not value.contains("\u0000"):
				_event_id = value
		"retry":
			if value.is_valid_int():
				_retry_ms = maxi(int(value), 0)
		"data":
			_data_lines.append(value)
	return {}


func _dispatch() -> Dictionary:
	if _data_lines.is_empty():
		_reset_event()
		return {}
	var frame := {
		"event": _event_name,
		"id": _event_id,
		"retry_ms": _retry_ms,
		"data": "\n".join(_data_lines),
	}
	_reset_event()
	return frame


func _reset_event() -> void:
	_event_name = ""
	_event_id = ""
	_retry_ms = -1
	_data_lines.clear()
	_event_bytes = 0
