extends SceneTree

const Game = preload("res://game.gd")
var game: Game
var failed := false
var shots_seen := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	game = preload("res://main.tscn").instantiate()
	root.add_child(game)
	game.child_entered_tree.connect(func(node: Node):
		if node is MeshInstance3D: shots_seen += 1)
	var args := OS.get_cmdline_user_args()
	match args[0]:
		"flight": await _flight()
		"host": await _host()
		"client": await _client()
		"squad_host": await _squad_host()
		"squad_client": await _squad_client()
		_: _check(false, "Unknown test mode")
	game.leave()
	await process_frame
	print("FAIL" if failed else "PASS ", args[0])
	quit(1 if failed else 0)

func _check(ok: bool, detail: String) -> bool:
	if not ok:
		printerr("FAILED: ", detail)
		failed = true
	return ok

func _until(condition: Callable, detail: String, seconds := 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return _check(condition.call(), detail)

func _flight() -> void:
	game.join("invalid")
	_check(game.mode == "menu" and "IPv4" in game.hud.notice.text, "invalid join feedback")
	game.hud.practice_requested.emit()
	var jet = game.planes[1]
	var initial_heading: float = jet.heading
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(180,-120)
	Input.parse_input_event(motion)
	await create_timer(0.12).timeout
	_check(is_equal_approx(initial_heading, jet.heading) and is_zero_approx(jet.pitch), "mouse motion leaves course unchanged")
	var origin: Vector3 = jet.position
	Input.action_press("climb")
	Input.action_press("bank_right")
	Input.action_press("boost")
	await create_timer(0.35).timeout
	_check(jet.pitch > 0.15 and jet.bank < -0.2, "climb and right bank")
	_check(jet.boosting and jet.charge < 0.9 and jet.position.distance_to(origin) > 21, "nitro flight")
	for action in ["climb","bank_right","boost"]: Input.action_release(action)
	var charge: float = jet.charge
	await create_timer(0.2).timeout
	_check(jet.charge > charge, "nitro recharges on release")
	for turn in ["bank_left", "bank_right"]:
		Input.action_press(turn)
		var before := shots_seen
		_fire_event(true)
		_fire_event(false)
		await _until(func(): return shots_seen > before, "quick click during " + turn)
		_fire_event(true, true)
		await _until(func(): return shots_seen >= before + 3, "held F fires repeatedly during " + turn)
		_fire_event(false, true)
		Input.action_release(turn)
	_check(game.arena.ground_at(1250,0) > 1.5, "land extends past the former east coast")
	jet.reset_flight(Vector3(1800,400,0),0)
	await physics_frame
	await physics_frame
	_check(jet.hp == 3, "new flight area extends beyond the former boundary")
	game._eliminate(jet)
	await _until(func(): return jet.hp == 3 and jet.visible, "three-second respawn", 4.5)
	_check(game.arena.blocked(Vector3(0,-1,0)) and not game.arena.blocked(Vector3(0,500,0)), "terrain collision")
	game.hud.leave_requested.emit()
	_check(game.planes.is_empty() and game.hud.overlay == "menu", "clean practice exit")

func _fire_event(pressed: bool, keyboard := false) -> void:
	if keyboard:
		var key := InputEventKey.new()
		key.physical_keycode = KEY_F
		key.pressed = pressed
		Input.parse_input_event(key)
	else:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		Input.parse_input_event(click)
	Input.flush_buffered_events()

func _host() -> void:
	game.hud.host_requested.emit()
	if not _check(game.mode == "host", "host binds UDP port"): return
	if not await _until(func(): return game.phase == "active" and game.planes.size() == 2, "remote joins", 18.0): return
	var remote_id: int
	for id in game.planes:
		if id != 1: remote_id = id
	var rival = game.planes[remote_id]
	if not await _until(func(): return rival.boosting and rival.bank < -0.05 and shots_seen >= 2, "remote pilot fires while banking and boosting"): return
	_check(rival.team == 1 and game.planes[1].team == 0, "opposing teams")
	# Use reproducible geometry and the actual host firing path to finish a round.
	var pilot = game.planes[1]
	pilot.reset_flight(Vector3(0,400,300),0)
	rival.reset_flight(Vector3(0,400,160),0)
	for point in range(5):
		if point > 0: rival.reset_flight(Vector3(0,400,160),0)
		for hit in range(3): game._fire(1)
		_check(game.scores.x == point + 1, "one score per elimination")
	_check(game.phase == "finished" and game.hud.overlay == "result", "score-limit result")
	await create_timer(0.9).timeout
	game.hud.rematch_requested.emit()
	_check(game.phase == "active" and game.scores == Vector2i.ZERO, "rematch resets scores")
	await create_timer(0.9).timeout
	game.remaining = 0.025
	if not await _until(func(): return game.phase == "finished", "timer ends tied game"): return
	await _until(func(): return game.planes.size() == 1 and game.phase == "waiting", "client leave resets lobby")

func _client() -> void:
	game.hud.join_requested.emit("127.0.0.1")
	if not await _until(func(): return game.phase == "active" and game.planes.size() == 2, "client sees both planes"): return
	Input.action_press("boost")
	Input.action_press("bank_right")
	_fire_event(true)
	if not await _until(func(): return game.phase == "finished" and game.scores.x == 5, "client receives winning score"): return
	_fire_event(false)
	Input.action_release("boost")
	Input.action_release("bank_right")
	_check(game.hud.overlay == "result", "client results screen")
	if not await _until(func(): return game.phase == "active" and game.scores == Vector2i.ZERO, "client sees rematch"): return
	if not await _until(func(): return game.phase == "finished" and game.scores == Vector2i.ZERO, "client receives draw"): return
	game.hud.leave_requested.emit()

func _squad_host() -> void:
	game.host()
	if not await _until(func(): return game.planes.size() == 4, "four-player host roster", 18.0): return
	var teams := Vector2i.ZERO
	for jet in game.planes.values(): teams[jet.team] += 1
	_check(teams == Vector2i(2,2), "balanced 2v2 match")
	await create_timer(1.0).timeout
	game.remaining = 0.03
	await _until(func(): return game.planes.size() == 1, "all three remote pilots leave")

func _squad_client() -> void:
	game.join("127.0.0.1")
	if not await _until(func(): return game.planes.size() == 4 and game.phase == "active", "2v2 client roster", 18.0): return
	if not await _until(func(): return game.phase == "finished", "2v2 match result"): return
	await create_timer(0.3).timeout
	game.leave()
