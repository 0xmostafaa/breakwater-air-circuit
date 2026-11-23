extends Node3D

const Jet = preload("res://aircraft.gd")
const Island = preload("res://island.gd")
const UI = preload("res://interface.gd")
const Art = preload("res://visuals.gd")
const PORT := 28741
const ROUND_SECONDS := 300.0
const SHOT_RANGE := 420.0
const MAX_PLAYERS := 4
const SNAPSHOT_INTERVAL := 1.0 / 30

var arena := Island.new()
var camera := Camera3D.new()
var menu_jet := Jet.new()
var hud := UI.new()
var planes := {}
var mode := "menu"
var phase := "waiting"
var scores := Vector2i.ZERO
var remaining := ROUND_SECONDS
var net_timer := 0.0
var join_timer := 0.0
var aim := Vector2.ZERO
var camera_spawn := -1
var ip_hint := ""
var last_camera_pos := Vector3.ZERO
var fire_sound := AudioStreamPlayer.new()
var motor := AudioStreamPlayer.new()
var menu_clock := 0.0

func _ready() -> void:
	_bind_controls()
	add_child(arena)
	camera.far = 7000
	camera.near = 0.15
	camera.fov = 72
	add_child(camera)
	camera.current = true
	add_child(menu_jet)
	_menu_camera(0)
	var layer := CanvasLayer.new()
	add_child(layer)
	layer.add_child(hud)
	hud.host_requested.connect(host)
	hud.join_requested.connect(join)
	hud.practice_requested.connect(practice)
	hud.resume_requested.connect(_resume)
	hud.leave_requested.connect(leave)
	hud.rematch_requested.connect(rematch)
	# Pilots exchange state only with the host. Direct peer announcements are unnecessary.
	(multiplayer as SceneMultiplayer).server_relay = false
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(func(): leave("Could not reach the host. Check the IP and Wi-Fi."))
	multiplayer.server_disconnected.connect(func(): leave("The host closed the session."))
	multiplayer.peer_disconnected.connect(_peer_left)
	_audio()

func _bind_controls() -> void:
	var bindings := {"climb":KEY_W,"dive":KEY_S,"bank_left":KEY_A,"bank_right":KEY_D,"boost":KEY_SPACE}
	for action in bindings:
		if not InputMap.has_action(action): InputMap.add_action(action)
		var key := InputEventKey.new()
		key.physical_keycode = bindings[action]
		if not InputMap.action_has_event(action, key): InputMap.action_add_event(action,key)
	if not InputMap.has_action("fire"):
		InputMap.add_action("fire")
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event("fire", click)

func _audio() -> void:
	# Original loop and blaster pulse. Synthesize once, then let Godot mix them.
	for engine in [true,false]:
		var rate := 12000
		var count := 6000 if engine else 1500
		var pcm := PackedByteArray()
		pcm.resize(count*2)
		for i in range(count):
			var t := float(i)/rate
			var wave := sin(TAU*56*t)*0.42 + sin(TAU*112*t)*0.18 + sin(TAU*224*t)*0.06
			if not engine: wave = sin(TAU*(850*t-2400*t*t))*exp(-t*27)
			pcm.encode_s16(i*2, int(wave*13000))
		var clip := AudioStreamWAV.new()
		clip.format = AudioStreamWAV.FORMAT_16_BITS
		clip.mix_rate = rate
		clip.data = pcm
		var player := motor if engine else fire_sound
		if engine:
			clip.loop_mode = AudioStreamWAV.LOOP_FORWARD
			clip.loop_end = count
		player.stream = clip
		player.volume_db = -20 if engine else -11
		add_child(player)

func host() -> void:
	if mode != "menu": return
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, MAX_PLAYERS-1) != OK:
		hud.message("Could not host on UDP port %d. Close any other host and try again." % PORT)
		return
	multiplayer.multiplayer_peer = peer
	mode = "host"
	var ips := PackedStringArray()
	for address in IP.get_local_addresses():
		if address.count(".") == 3 and not address.begins_with("127.") and not address.begins_with("169.254."):
			ips.append(address)
	ip_hint = ", ".join(ips) if not ips.is_empty() else "check your Wi-Fi IPv4 address"
	_add_plane(1,0)
	_start_flight()
	print("Hosting Breakwater on UDP ", PORT)

func practice() -> void:
	if mode != "menu": return
	mode = "practice"
	_add_plane(1,0)
	_start_flight()

func join(address: String) -> void:
	if mode != "menu": return
	if address.count(".") != 3 or not address.is_valid_ip_address():
		hud.message("Enter the host laptop’s IPv4 address, for example 192.168.1.12.")
		return
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, PORT) != OK:
		hud.message("Could not start the connection.")
		return
	mode = "connecting"
	join_timer = 8.0
	multiplayer.multiplayer_peer = peer
	hud.message("Connecting to %s…" % address)

func _connected() -> void:
	mode = "client"
	_client_ready.rpc_id(1)

@rpc("any_peer","call_remote","reliable")
func _client_ready() -> void:
	if mode != "host": return
	var id := multiplayer.get_remote_sender_id()
	if planes.has(id) or planes.size() >= MAX_PLAYERS: return
	var counts := Vector2i.ZERO
	for jet: Jet in planes.values(): counts[jet.team] += 1
	_add_plane(id, 1 if counts.x > counts.y else 0)
	if phase == "waiting": _begin_round()

func _start_flight() -> void:
	menu_jet.hide()
	camera_spawn = -1
	aim = Vector2.ZERO
	_resume()
	motor.play()

func _resume() -> void:
	hud.play()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func leave(message := "") -> void:
	mode = "menu"
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	for id in planes.keys(): _remove_plane(id)
	motor.stop()
	scores = Vector2i.ZERO
	phase = "waiting"
	remaining = ROUND_SECONDS
	net_timer = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.menu(message)
	menu_jet.show()
	_menu_camera(0.0)

func _peer_left(id: int) -> void:
	if mode != "host": return
	_remove_plane(id)
	var teams := {}
	for jet: Jet in planes.values(): teams[jet.team] = true
	if teams.size() < 2:
		phase = "waiting"
		scores = Vector2i.ZERO
		remaining = ROUND_SECONDS
		if hud.overlay == "result": _resume()

func _add_plane(id: int, team: int) -> Jet:
	var jet := Jet.new()
	jet.team = team
	jet.name = "Pilot_%d" % id
	add_child(jet)
	planes[id] = jet
	_spawn(id)
	return jet

func _remove_plane(id: int) -> void:
	if planes.has(id):
		var jet: Jet = planes[id]
		planes.erase(id)
		remove_child(jet)
		jet.queue_free()

func _spawn(id: int) -> void:
	var jet: Jet = planes[id]
	var side := 1.0 if jet.team == 0 else -1.0
	var offset := 0
	for other in planes:
		if other == id: break
		if planes[other].team == jet.team: offset += 1
	# Both spawn points face toward the central valley.
	var at := Vector3(side*(365+offset*75), 123+offset*25, side*415)
	jet.reset_flight(at, atan2(at.x, at.z))

func _begin_round() -> void:
	phase = "active"
	remaining = ROUND_SECONDS
	scores = Vector2i.ZERO
	for id in planes: _spawn(id)
	if hud.overlay == "result": _resume()

func rematch() -> void:
	if mode == "host" and phase == "finished":
		_begin_round()
		_broadcast()

func _finish_round() -> void:
	phase = "finished"
	_show_results()

func _show_results() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var title := "Draw"
	if scores.x > scores.y: title = "Tide wins"
	elif scores.y > scores.x: title = "Ember wins"
	hud.results(title, "Tide   %d     /     %d   Ember" % [scores.x,scores.y], mode == "host")

func _unhandled_input(event: InputEvent) -> void:
	if mode in ["menu","connecting"]: return
	if event.is_action_pressed("ui_cancel"):
		if hud.overlay == "pause": _resume()
		elif hud.overlay == "":
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			hud.pause_menu()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and hud.overlay == "":
		aim = (aim + Vector2(event.relative.x, -event.relative.y) * 0.0045).limit_length(1.0)

func _physics_process(dt: float) -> void:
	if mode == "connecting":
		join_timer -= dt
		if join_timer <= 0: leave("Connection timed out. Check the IP and Wi-Fi.")
		return
	if mode == "menu": return
	var id := multiplayer.get_unique_id()
	if not planes.has(id): return
	var enabled := hud.overlay == ""
	var key_axes := Vector2.ZERO
	if enabled:
		key_axes = Vector2(Input.get_axis("bank_left","bank_right"), Input.get_axis("dive","climb"))
	var steering := aim if enabled else Vector2.ZERO
	var boost := enabled and Input.is_action_pressed("boost")
	var fire := enabled and Input.is_action_pressed("fire")
	net_timer += dt
	if mode == "client":
		if net_timer >= SNAPSHOT_INTERVAL:
			net_timer = 0
			_controls.rpc_id(1, steering, key_axes, boost, fire)
		return
	_set_input(planes[id], steering, key_axes, boost, fire)
	if phase != "finished":
		for pilot in planes:
			_fly(pilot, dt)
			if phase == "finished": break
		if phase == "active":
			remaining = maxf(0, remaining-dt)
			if remaining <= 0: _finish_round()
	if mode == "host" and net_timer >= SNAPSHOT_INTERVAL:
		net_timer = 0
		_broadcast()

@rpc("any_peer","call_remote","unreliable_ordered",1)
func _controls(steering: Vector2, axes: Vector2, boost: bool, fire: bool) -> void:
	var id := multiplayer.get_remote_sender_id()
	if mode == "host" and planes.has(id) and steering.is_finite() and axes.is_finite():
		_set_input(planes[id], steering.limit_length(1.0), axes.clamp(Vector2(-1,-1),Vector2.ONE), boost, fire)

func _set_input(jet: Jet, steering: Vector2, axes: Vector2, boost: bool, fire: bool) -> void:
	jet.aim = steering
	jet.keys = axes
	jet.boost_pressed = boost
	jet.trigger = fire

func _fly(id: int, dt: float) -> void:
	var jet: Jet = planes[id]
	if jet.hp <= 0:
		jet.respawn_time -= dt
		if jet.respawn_time <= 0: _spawn(id)
		return
	jet.advance(dt)
	if arena.blocked(jet.position) or Vector2(jet.position.x,jet.position.z).length() > 1600 or jet.position.y > 850:
		_eliminate(jet)
	elif jet.trigger and jet.cooldown <= 0:
		_fire(id)

func _eliminate(jet: Jet) -> void:
	jet.hp = 0
	jet.respawn_time = 3.0
	jet.visible = false
	jet.boosting = false

func _fire(id: int) -> void:
	var shooter: Jet = planes[id]
	shooter.cooldown = 0.16
	var dir := shooter.direction()
	var start := shooter.position + dir*5.0
	var distance := SHOT_RANGE
	var target: Jet
	for other in planes:
		var rival: Jet = planes[other]
		if rival.team == shooter.team or rival.hp <= 0: continue
		var delta_pos := rival.position - start
		var along := delta_pos.dot(dir)
		if along > 0 and along < distance and (delta_pos-dir*along).length_squared() < 36:
			distance = along
			target = rival
	var travel := 0.0
	while travel < distance:
		if arena.blocked(start + dir*travel):
			distance = travel
			target = null
			break
		travel += 4
	if target != null and phase == "active":
		target.hp -= 1
		if target.hp == 0:
			_eliminate(target)
			scores[shooter.team] += 1
			if scores[shooter.team] >= 5: _finish_round()
	var end := start+dir*distance
	_tracer(id, start, end, shooter.team, target != null)
	if mode == "host": _tracer.rpc(id, start, end, shooter.team, target != null)

@rpc("authority","call_remote","unreliable",2)
func _tracer(id: int, start: Vector3, end: Vector3, team: int, hit: bool) -> void:
	if mode == "menu": return
	var span := end-start
	if span.length_squared() < 0.01: return
	var instance := Art.box(self, (start+end)/2, Vector3(0.13,0.13,span.length()), Art.material(Jet.TEAM_COLORS[team],true))
	instance.quaternion = Quaternion(Vector3.FORWARD, span.normalized())
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().create_timer(0.07).timeout.connect(instance.queue_free)
	if id == multiplayer.get_unique_id():
		fire_sound.play()
		if hit: hud.hit_until = Time.get_ticks_msec()+160

func _broadcast() -> void:
	if multiplayer.get_peers().is_empty(): return
	var states := {}
	for id in planes: states[id] = planes[id].snapshot()
	_state.rpc(states, phase, scores, remaining)

@rpc("authority","call_remote","unreliable_ordered",1)
func _state(states: Dictionary, round_phase: String, points: Vector2i, seconds: float) -> void:
	if mode != "client": return
	for id in planes.keys():
		if not states.has(id): _remove_plane(id)
	for id in states:
		if not planes.has(id):
			var jet := _add_plane(id, states[id][Jet.State.TEAM])
			jet.spawn_serial = -1
		planes[id].receive_state(states[id])
	var previous := phase
	phase = round_phase
	remaining = seconds
	scores = points
	if not planes.has(multiplayer.get_unique_id()): return
	if hud.overlay == "menu": _start_flight()
	if phase == "finished" and hud.overlay != "result": _show_results()
	elif previous == "finished" and phase != "finished": _resume()

func _process(dt: float) -> void:
	if mode in ["menu","connecting"]:
		menu_clock += dt
		_menu_camera(menu_clock)
		return
	if mode == "client":
		for jet: Jet in planes.values(): jet.smooth(dt)
	var id := multiplayer.get_unique_id()
	if not planes.has(id): return
	var pilot: Jet = planes[id]
	var dir := pilot.direction()
	var up := Vector3.UP.rotated(dir, -pilot.bank * 0.20)
	var goal := pilot.position - dir * (17 if pilot.boosting else 14) + Vector3.UP * 4.3
	if camera_spawn != pilot.spawn_serial:
		last_camera_pos = goal
		camera_spawn = pilot.spawn_serial
		aim = Vector2.ZERO
	last_camera_pos = last_camera_pos.lerp(goal,1.0-exp(-10*dt))
	camera.position = last_camera_pos
	camera.look_at(pilot.position+dir*30, up)
	camera.fov = lerpf(camera.fov, 81 if pilot.boosting else 72, 1.0-exp(-4*dt))
	motor.pitch_scale = lerpf(motor.pitch_scale,1.55 if pilot.boosting else 1.0,1.0-exp(-6*dt))
	motor.volume_db = -42 if pilot.hp <= 0 or phase == "finished" else -20
	hud.aim = Vector2(aim.x,-aim.y)
	hud.nose = camera.unproject_position(pilot.position+dir*200)
	hud.markers.clear()
	for other in planes:
		var p: Jet = planes[other]
		if other == id or p.hp <= 0 or camera.is_position_behind(p.position): continue
		hud.markers.append([camera.unproject_position(p.position+Vector3.UP*8), Jet.TEAM_COLORS[p.team]])
	var banner := ""
	if mode == "practice": banner = "Practice flight"
	elif phase == "waiting": banner = "Waiting for pilots   •   Join IP: " + ip_hint
	if pilot.position.y > 720 or Vector2(pilot.position.x,pilot.position.z).length() > 1360:
		banner = "Return to the island"
	hud.match_data = {"scores":scores,"clock":ceili(remaining),"banner":banner,"dead":pilot.respawn_time,"charge":pilot.charge,"hp":pilot.hp,"team":"TIDE" if pilot.team==0 else "EMBER"}
	hud.queue_redraw()

func _menu_camera(t: float) -> void:
	camera.position = Vector3(565+sin(t*0.04)*65, 205, 590+cos(t*0.04)*45)
	camera.look_at(Vector3(-55,60,-120))
	menu_jet.position = camera.to_global(Vector3(4.8,0.15,-13.0))
	menu_jet.heading = atan2(camera.basis.z.x,camera.basis.z.z) + 0.66
	menu_jet.pitch = -0.04
	menu_jet.bank = -0.28 + 0.08*sin(t*0.3)
	menu_jet.update_pose()
