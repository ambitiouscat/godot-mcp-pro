extends SceneTree

const APIClient := preload("res://addons/opencode_godot/client/opencode_api_client.gd")

const TIMEOUT_MS := 20_000
var failures: Array[String] = []
var outputs: Array[String] = []
var permissions := 0
var questions := 0
var responses := 0
var sessions := 0
var api: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var record: Variant = _read_json(OS.get_environment("OPENCODE_CLIENT_TRANSPORT_READY"))
	_expect(record is Dictionary, "wrapper supplies a valid loopback mock record")
	if not record is Dictionary:
		_finish()
		return
	var project := ProjectSettings.globalize_path("res://").replace("\\", "/").simplify_path()
	api = APIClient.new()
	root.add_child(api)
	api.setup(project)
	api.assistant_output.connect(func(_session: String, text: String, _replace: bool) -> void: outputs.append(text))
	api.sessions_changed.connect(func(items: Array) -> void: sessions = items.size())
	api.permission_pending.connect(func(_session: String, _request: Dictionary) -> void: permissions += 1)
	api.question_pending.connect(func(_session: String, _request: Dictionary) -> void: questions += 1)
	api.interaction_response_completed.connect(func(_op: String, _session: String, _id: String) -> void: responses += 1)
	api.api_error.connect(func(category: String, detail: String) -> void: print("[client-transport][%s] %s" % [category, detail]))
	_expect(api.configure_daemon(str((record as Dictionary).get("base_url", "")), str((record as Dictionary).get("password", "")), 7), "client accepts loopback mock daemon credentials")
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < deadline and sessions == 0:
		await process_frame
	_expect(sessions == 1, "authenticated directory-bound session list reaches the live transport client")
	api.select_session("ses_live")
	# Force the same bounded transport-loss path an editor observes when its SSE
	# socket disconnects after cursor 1.  The second request must use that
	# exclusive durable cursor; the wrapper audits both real wire requests.
	for _frame in range(30):
		await process_frame
	api._last_sequence_by_session["ses_live"] = 1
	api._durable_stream.stop()
	api._start_durable_stream("ses_live")
	while Time.get_ticks_msec() < deadline and (permissions == 0 or questions == 0):
		await process_frame
	_expect(permissions > 0 and questions > 0, "real HTTP transport restores pending permission and question interactions")
	api.reply_permission("per_live", "once", "", "ses_live")
	api.answer_question("que_live", [["Yes"]], "ses_live")
	for _frame in range(90):
		await process_frame
	_expect(responses <= 2, "interaction transport remains bounded while permission and question replies are in flight")
	api.send_prompt("cancel the synthetic request")
	for _frame in range(30):
		await process_frame
	api.cancel_active()
	for _frame in range(90):
		await process_frame
	api.shutdown()
	api.queue_free()
	_finish()


func _read_json(path: String) -> Variant:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parser := JSON.new()
	var result: Variant = parser.data if parser.parse(file.get_as_text()) == OK else null
	file.close()
	return result


func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("OPENCODE_GODOT_CLIENT_TRANSPORT_OK")
		quit(0)
	else:
		for failure: String in failures:
			push_error("TEST FAILURE: " + failure)
		quit(1)
