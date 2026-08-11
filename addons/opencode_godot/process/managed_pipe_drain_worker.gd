@tool
extends RefCounted

## Performs the only potentially blocking pipe operation away from Godot's
## editor thread. The queue is deliberately byte-bounded: diagnostic output is
## lossy under sustained pressure, while the operating-system pipe is always
## consumed so it cannot stall the managed child.

const READ_CHUNK_BYTES := 4096
const MAX_QUEUED_BYTES := 128 * 1024

var _pipe: FileAccess
var _thread: Thread
var _mutex := Mutex.new()
var _queued := PackedByteArray()
var _dropped_bytes := 0
var _drop_generation := 0
var _finished := false
var _close_requested := false
var _sink_output := false


func start(pipe: FileAccess) -> bool:
	if pipe == null or _thread != null:
		return false
	_pipe = pipe
	_thread = Thread.new()
	if _thread.start(_read_loop) != OK:
		_thread = null
		return false
	return true


func take(maximum_bytes: int) -> PackedByteArray:
	var snapshot := take_snapshot(maximum_bytes)
	return snapshot.get("bytes", PackedByteArray()) as PackedByteArray


func take_snapshot(maximum_bytes: int) -> Dictionary:
	if maximum_bytes <= 0:
		return {"bytes": PackedByteArray(), "drop_generation": _drop_generation}
	_mutex.lock()
	var count := mini(maximum_bytes, _queued.size())
	var result := _queued.slice(0, count)
	if count == _queued.size():
		_queued.clear()
	else:
		_queued = _queued.slice(count)
	var generation := _drop_generation
	_mutex.unlock()
	return {"bytes": result, "drop_generation": generation}


func dropped_bytes() -> int:
	_mutex.lock()
	var result := _dropped_bytes
	_mutex.unlock()
	return result


func discard_queued() -> void:
	_mutex.lock()
	_wipe_queued_locked()
	_mutex.unlock()


func discard_and_sink() -> void:
	_mutex.lock()
	_wipe_queued_locked()
	_sink_output = true
	_mutex.unlock()


func get_pipe() -> FileAccess:
	return _pipe


func is_finished() -> bool:
	_mutex.lock()
	var result := _finished
	_mutex.unlock()
	return result


func is_alive() -> bool:
	return _thread != null and _thread.is_alive()


func join_if_finished() -> bool:
	if _thread == null:
		return true
	if _thread.is_alive():
		return false
	if _thread.is_started():
		_thread.wait_to_finish()
	return true


func close_pipe() -> void:
	# Callers close only their own lifecycle handle. On 4.3 this races a blocked
	# platform read, so the worker must remain strongly referenced until it exits
	# and is joined; callers never destroy this object while it is alive.
	_mutex.lock()
	_close_requested = true
	_mutex.unlock()
	if _pipe != null and _pipe.is_open():
		_pipe.close()


func _read_loop() -> void:
	while _pipe != null and _pipe.is_open():
		var chunk := _pipe.get_buffer(READ_CHUNK_BYTES)
		# 4.3 Unix reports ERR_FILE_CANT_READ for a *full* successful read, so
		# get_error() cannot distinguish that from failure. Our own close is the
		# only concurrent-close path; once requested, discard the return because
		# the 4.3 binding can otherwise surface an invalid-length buffer.
		if _is_close_requested():
			break
		if chunk.is_empty():
			break
		_mutex.lock()
		var free_bytes := MAX_QUEUED_BYTES - _queued.size()
		if _sink_output:
			_dropped_bytes += chunk.size()
		elif free_bytes > 0:
			var accepted := mini(free_bytes, chunk.size())
			if accepted > 0:
				_queued.append_array(chunk.slice(0, accepted))
			if chunk.size() > accepted:
				_dropped_bytes += chunk.size() - accepted
				_drop_generation += 1
		else:
			_dropped_bytes += chunk.size()
			_drop_generation += 1
		_mutex.unlock()
	_mutex.lock()
	_finished = true
	_mutex.unlock()


func _is_close_requested() -> bool:
	_mutex.lock()
	var result := _close_requested
	_mutex.unlock()
	return result


func _wipe_queued_locked() -> void:
	_queued.fill(0)
	_queued.clear()
