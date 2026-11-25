extends Node3D

const Art = preload("res://visuals.gd")
const CRUISE := 70.0
const TEAM_COLORS := [Color("#28d6ce"), Color("#ff825d")]
const MAX_HP := 3
enum State { TEAM, POSITION, HEADING, PITCH, BANK, CHARGE, BOOSTING, HP, RESPAWN_TIME, SPAWN_SERIAL }
var team := 0
var pitch := 0.0
var heading := 0.0
var bank := 0.0
var charge := 1.0
var boost_locked := false
var boosting := false
var hp := MAX_HP
var respawn_time := 0.0
var cooldown := 0.0
var spawn_serial := 0
var keys := Vector2.ZERO
var boost_pressed := false
var trigger := false
var shot_queued := false
var exhaust: MeshInstance3D
var destination := Vector3.ZERO
var target_angles := Vector3.ZERO
var trail_mesh := ImmediateMesh.new()
var trail_points: Array[Transform3D] = []
var trail_timer := 0.0
var trail_paint := StandardMaterial3D.new()

func _ready() -> void:
	build_model()
	var trails := Art.mesh(self, trail_mesh, null, Vector3.ZERO)
	trails.top_level = true
	trails.global_transform = Transform3D.IDENTITY
	trails.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	trail_paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_paint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_paint.vertex_color_use_as_albedo = true
	trail_paint.cull_mode = BaseMaterial3D.CULL_DISABLED

func _process(dt: float) -> void:
	trail_timer += dt
	if trail_timer < 0.045: return
	trail_timer = 0
	trail_mesh.clear_surfaces()
	if not visible or (not boosting and absf(bank) < 0.55):
		trail_points.clear()
		return
	trail_points.push_front(global_transform)
	if trail_points.size() > 12: trail_points.pop_back()
	if trail_points.size() < 2: return
	for side in [-1.0,1.0]:
		trail_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, trail_paint)
		for i in range(trail_points.size()):
			var pose := trail_points[i]
			var tip := pose * Vector3(side*3.65,-0.12,1.85)
			var fade := 1.0 - float(i)/float(trail_points.size()-1)
			trail_mesh.surface_set_color(Color(0.84,0.94,1,fade*0.40))
			trail_mesh.surface_add_vertex(tip - pose.basis.x*0.10)
			trail_mesh.surface_add_vertex(tip + pose.basis.x*0.10)
		trail_mesh.surface_end()

func build_model() -> void:
	var body := Art.material(Color("#d7dedd"))
	var graphite := Art.material(Color("#354553"))
	var canopy := Art.material(Color("#30617a"))
	var stripe := Art.material(TEAM_COLORS[team])
	var nose := Vector3(0, 0, -4.3)
	var top := Vector3(0, 0.62, -0.2)
	var left := Vector3(-0.8, -0.12, 0.5)
	var right := Vector3(0.8, -0.12, 0.5)
	var tail := Vector3(0, 0.04, 3.0)
	var bottom := Vector3(0, -0.52, 0.3)
	_panels([nose, left, top, nose, top, right, left, tail, top, top, tail, right], body)
	_panels([nose, bottom, left, nose, right, bottom, left, bottom, tail, right, tail, bottom], graphite)
	for sign_x in [-1.0, 1.0]:
		var root := Vector3(0.38 * sign_x, 0.0, -1.6)
		var tip := Vector3(3.8 * sign_x, -0.13, 1.85)
		var end := Vector3(2.8 * sign_x, -0.13, 2.12)
		var inner := Vector3(0.45 * sign_x, -0.06, 1.3)
		_panels([root, tip, inner, tip, end, inner], body)
		_panels([root.lerp(tip, 0.73) + Vector3.UP * 0.02, tip + Vector3.UP * 0.02, end + Vector3.UP * 0.02], stripe)
		var fin_root := Vector3(0.32 * sign_x, 0.20, 0.95)
		var fin_tip := Vector3(0.93 * sign_x, 1.56, 2.4)
		var fin_tail := Vector3(0.46 * sign_x, 0.20, 2.75)
		_panels([fin_root, fin_tip, fin_tail], graphite)
		var stabilizer := Vector3(1.87 * sign_x, 0.03, 3.08)
		_panels([fin_root, stabilizer, fin_tail], body)
		_panels([fin_root.lerp(fin_tip, 0.67) + Vector3.RIGHT * sign_x * 0.018, fin_tip + Vector3.RIGHT * sign_x * 0.018, fin_tail.lerp(fin_tip, 0.67) + Vector3.RIGHT * sign_x * 0.018], stripe)
	var glass := SphereMesh.new()
	glass.radial_segments = 8
	glass.rings = 4
	Art.mesh(self, glass, canopy, Vector3(0,0.39,-1.12)).scale = Vector3(0.91,0.61,2.42)
	var nozzle := Art.cylinder(self, Vector3(0,0,2.5), 0.50, 0.57, 0.9, graphite)
	nozzle.rotation.x = PI/2
	exhaust = Art.cylinder(self, Vector3(0,0,3.02), 0.0, 0.34, 1.0, Art.material(Color("#98f7ff"), true))
	exhaust.rotation.x = PI/2

func _panels(points: Array, mat: StandardMaterial3D) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(0, points.size(), 3):
		var a: Vector3 = points[i]
		var b: Vector3 = points[i+1]
		var c: Vector3 = points[i+2]
		var normal := (b-a).cross(c-a).normalized()
		if normal.y < 0: normal = -normal
		for p in [a,b,c]:
			surface.set_normal(normal)
			surface.add_vertex(p)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	Art.mesh(self, surface.commit(), mat, Vector3.ZERO)

func reset_flight(at: Vector3, yaw: float) -> void:
	trail_points.clear()
	position = at
	destination = at
	heading = yaw
	pitch = 0.0
	bank = 0.0
	respawn_time = 0
	hp = MAX_HP
	charge = 1
	boost_locked = false
	boosting = false
	cooldown = 0.3
	shot_queued = false
	spawn_serial += 1
	visible = true
	update_pose()

func direction() -> Vector3:
	return Vector3(-sin(heading) * cos(pitch), sin(pitch), -cos(heading) * cos(pitch))

func advance(dt: float) -> void:
	pitch = clampf(pitch + keys.y * 1.15 * dt, -1.25, 1.25)
	bank = move_toward(bank, -keys.x * 1.05, dt * 2.7)
	heading = wrapf(heading + bank * 0.89 * dt, -PI, PI)
	if not boost_pressed and charge >= 0.15: boost_locked = false
	boosting = boost_pressed and not boost_locked and charge > 0
	if boosting:
		charge = maxf(0, charge - dt / 2.0)
		if charge <= 0: boost_locked = true
	elif not boost_pressed:
		charge = minf(1, charge + dt / 4.0)
	position += direction() * CRUISE * (1.5 if boosting else 1.0) * dt
	cooldown = maxf(0, cooldown - dt)
	update_pose()

func update_pose() -> void:
	basis = Basis(Vector3.UP, heading) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, bank)
	exhaust.scale.y = 3.5 if boosting else 0.85
	exhaust.position.z = 2.85 + exhaust.scale.y * 0.5

func snapshot() -> Array:
	return [team, position, heading, pitch, bank, charge, boosting, hp, respawn_time, spawn_serial]

func receive_state(s: Array) -> void:
	destination = s[State.POSITION]
	target_angles = Vector3(s[State.PITCH], s[State.HEADING], s[State.BANK])
	charge = s[State.CHARGE]
	boosting = s[State.BOOSTING]
	hp = s[State.HP]
	respawn_time = s[State.RESPAWN_TIME]
	visible = hp > 0
	if spawn_serial != s[State.SPAWN_SERIAL]:
		trail_points.clear()
		spawn_serial = s[State.SPAWN_SERIAL]
		position = destination
		pitch = target_angles.x
		heading = target_angles.y
		bank = target_angles.z
	update_pose()

func smooth(dt: float) -> void:
	var weight := 1.0 - exp(-22.0 * dt)
	position = position.lerp(destination, weight)
	pitch = lerpf(pitch, target_angles.x, weight)
	heading = lerp_angle(heading, target_angles.y, weight)
	bank = lerpf(bank, target_angles.z, weight)
	update_pose()
