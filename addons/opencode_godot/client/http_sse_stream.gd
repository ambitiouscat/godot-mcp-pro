@tool
extends Node

signal frame_received(frame: Dictionary, generation: int)
signal stream_state_changed(state: String, detail: String, generation: int)
signal stream_failed(status_code: int, detail: String, generation: int)

const SSEParser := preload("res://addons/opencode_godot/client/sse_parser.gd")
const INITIAL_RETRY_SECONDS := 0.25
const MAX_RETRY_SECONDS := 5.0

var _client: HTTPClient
var _parser: RefCounted
var _host := ""
var _port := 0
var _path := ""
var _headers := PackedStringArray()
var _generation := 0
var _running := false
var _phase := "stopped"
var _response_code := 0
var _retry_delay := INITIAL_RETRY_SECONDS
var _retry_remaining := 0.0


func start(host: String, port: int, path: String, headers: PackedStringArray, generation: int) -> void:
	stop()
	_host = host
	_port = port
	_path = path
	_headers = headers.duplicate()
	_generation = generation
	_running = true
	_retry_delay = INITIAL_RETRY_SECONDS
	_retry_remaining = 0.0
	_connect()


func stop() -> void:
	_running = false
	_phase = "stopped"
	if _client != null:
		_client.close()
	_client = null
	_parser = null


func is_running_for(generation: int) -> bool:
	return _running and _generation == generation


func _exit_tree() -> void:
	stop()


func _process(delta: float) -> void:
	if not _running:
		return
	if _client == null:
		_retry_remaining -= delta
		if _retry_remaining <= 0.0:
			_connect()
		return

	var poll_error := _client.poll()
	if poll_error != OK:
		_schedule_retry("SSE transport poll failed: %s" % error_string(poll_error))
		return
	var status := _client.get_status()
	match status:
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_REQUESTING:
			return
		HTTPClient.STATUS_CONNECTED:
			if _phase == "connecting":
				var request_error := _client.request(HTTPClient.METHOD_GET, _path, _headers)
				if request_error != OK:
					_schedule_retry("SSE request failed: %s" % error_string(request_error))
					return
				_phase = "requesting"
				stream_state_changed.emit("requesting", _path, _generation)
				return
			if _phase == "streaming":
				_schedule_retry("SSE stream ended")
				return
			_capture_headers_if_available()
		HTTPClient.STATUS_BODY:
			if not _capture_headers_if_available():
				return
			if _response_code < 200 or _response_code >= 300:
				_fail_http()
				return
			_phase = "streaming"
			_retry_delay = INITIAL_RETRY_SECONDS
			var chunk := _client.read_response_body_chunk()
			if chunk.is_empty():
				return
			var frames: Array[Dictionary] = _parser.feed(chunk)
			if not _parser.last_error.is_empty():
				stream_failed.emit(_response_code, _parser.last_error, _generation)
				_schedule_retry(_parser.last_error, false)
				return
			for frame in frames:
				if int(frame.get("retry_ms", -1)) >= 0:
					_retry_delay = clampf(float(frame["retry_ms"]) / 1000.0, INITIAL_RETRY_SECONDS, MAX_RETRY_SECONDS)
				frame_received.emit(frame, _generation)
		HTTPClient.STATUS_DISCONNECTED, HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			_schedule_retry("SSE connection unavailable (status %d)" % status)


func _connect() -> void:
	if not _running:
		return
	_client = HTTPClient.new()
	_parser = SSEParser.new()
	_response_code = 0
	_phase = "connecting"
	var connect_error := _client.connect_to_host(_host, _port)
	if connect_error != OK:
		_schedule_retry("SSE connect failed: %s" % error_string(connect_error))
		return
	stream_state_changed.emit("connecting", "%s:%d" % [_host, _port], _generation)


func _capture_headers_if_available() -> bool:
	if _response_code != 0:
		return true
	if not _client.has_response():
		return false
	_response_code = _client.get_response_code()
	if _response_code < 200 or _response_code >= 300:
		_fail_http()
		return false
	stream_state_changed.emit("connected", "HTTP %d" % _response_code, _generation)
	return true


func _fail_http() -> void:
	var code := _response_code
	var detail := "SSE endpoint returned HTTP %d" % code
	stream_failed.emit(code, detail, _generation)
	if code == 401 or code == 403:
		_running = false
		_phase = "stopped"
		if _client != null:
			_client.close()
		_client = null
		return
	_schedule_retry(detail, false)


func _schedule_retry(detail: String, notify_failure: bool = true) -> void:
	if notify_failure:
		stream_failed.emit(0, detail, _generation)
	if _client != null:
		_client.close()
	_client = null
	_parser = null
	if not _running:
		return
	_phase = "backoff"
	_retry_remaining = _retry_delay * randf_range(0.85, 1.15)
	_retry_delay = minf(_retry_delay * 2.0, MAX_RETRY_SECONDS)
	stream_state_changed.emit("backoff", "%s; retrying in %.2fs" % [detail, _retry_remaining], _generation)
