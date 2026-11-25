extends Node3D

const Art = preload("res://visuals.gd")
const MAP_SCALE := sqrt(2.0)
const FLIGHT_RADIUS := 1600.0 * MAP_SCALE
const STEP := 30.0 * MAP_SCALE
const HALF := 42
var heights := PackedFloat32Array()
var obstacles: Array[AABB] = []
var tree_cells := {}

func _ready() -> void:
	_light()
	_terrain()
	_airfield()
	_woods()
	_clouds()

func _light() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("#427bab")
	sky_mat.sky_horizon_color = Color("#ffddae")
	sky_mat.sky_curve = 0.16
	sky_mat.ground_horizon_color = Color("#e7caa6")
	sky_mat.ground_bottom_color = Color("#699293")
	sky_mat.sun_angle_max = 4.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#bacbde")
	env.ambient_light_energy = 0.40
	env.fog_enabled = true
	env.fog_light_color = Color("#e3d5b6")
	env.fog_density = 0.00018
	env.fog_sky_affect = 0.08
	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-27, -56, 0)
	sun.light_color = Color("#fff0d0")
	sun.light_energy = 0.84
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 320
	add_child(sun)

func _land(x: float, z: float) -> float:
	x /= MAP_SCALE
	z /= MAP_SCALE
	var r := sqrt(pow((x + 35.0 * sin(z * 0.007)) / 1090.0, 2) + pow((z - 45.0 * sin(x * 0.006)) / 735.0, 2))
	var shore := clampf((1.0 - r) * 5.0, 0, 1)
	var ridge := 220.0 * exp(-pow((z + 100.0 + 0.20 * x) / 195.0, 2) - pow(x / 670.0, 2))
	ridge *= 1.0 - 0.90 * exp(-pow((x - 65.0) / 100.0, 2))
	var ridges := 0.85 + 0.17 * sin(x * 0.018) + 0.09 * cos(z * 0.045 + x * 0.009)
	return -9.0 + shore * (28.0 + ridge * ridges + 4.0 * sin(x * 0.021) * cos(z * 0.025))

func _index(x: int, z: int) -> int:
	return z * (HALF * 2 + 1) + x

func ground_at(x: float, z: float) -> float:
	var grid := Vector2(x, z) / STEP + Vector2(HALF, HALF)
	var a := Vector2i(floori(grid.x), floori(grid.y))
	if a.x < 0 or a.y < 0 or a.x >= HALF * 2 or a.y >= HALF * 2:
		return 0.0
	var f := grid - Vector2(a)
	var low := heights[_index(a.x, a.y)]
	var right := heights[_index(a.x + 1, a.y)]
	var down := heights[_index(a.x, a.y + 1)]
	var high := heights[_index(a.x + 1, a.y + 1)]
	var h := low + f.x * (right - low) + f.y * (down - low)
	if f.x + f.y > 1.0:
		h = high + (1.0 - f.x) * (down - high) + (1.0 - f.y) * (right - high)
	return maxf(0.0, h)

func blocked(p: Vector3) -> bool:
	if p.y <= ground_at(p.x, p.z) + 1.5:
		return true
	for bounds in obstacles:
		if bounds.has_point(p):
			return true
	var cell := Vector2i(floori(p.x/32), floori(p.z/32))
	if tree_cells.has(cell):
		for trunk: AABB in tree_cells[cell]:
			if trunk.has_point(p): return true
	return false

func _terrain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 6183
	for z in range(-HALF, HALF + 1):
		for x in range(-HALF, HALF + 1):
			heights.append(_land(x * STEP, z * STEP))
	for z in range(HALF * 2):
		for x in range(HALF * 2):
			var p := Vector3((x - HALF) * STEP, 0, (z - HALF) * STEP)
			var a := p + Vector3.UP * heights[_index(x, z)]
			var b := p + Vector3(STEP, heights[_index(x + 1, z)], 0)
			var c := p + Vector3(0, heights[_index(x, z + 1)], STEP)
			var d := p + Vector3(STEP, heights[_index(x + 1, z + 1)], STEP)
			_facet(st, a, b, c, rng)
			_facet(st, b, d, c, rng)
	var mat := Art.material(Color.WHITE)
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	Art.mesh(self, st.commit(), mat, Vector3.ZERO)
	var ocean := PlaneMesh.new()
	ocean.size = Vector2(24000, 24000)
	var water := ShaderMaterial.new()
	water.shader = preload("res://water.gdshader")
	Art.mesh(self, ocean, water, Vector3.ZERO)

func _facet(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, rng: RandomNumberGenerator) -> void:
	var n := (c - a).cross(b - a).normalized()
	var h := (a.y + b.y + c.y) / 3
	var tint := Color("#678c73")
	if h < 12: tint = Color("#dcc08d")
	elif n.y < 0.78: tint = Color("#797e78")
	elif h > 145: tint = Color("#9a9a83")
	elif h > 55: tint = Color("#537763")
	tint = tint.lightened(rng.randf_range(0, 0.045))
	for v in [a, b, c]:
		st.set_normal(n)
		st.set_color(tint)
		st.add_vertex(v)

func _airfield() -> void:
	var dark := Art.material(Color("#394953"))
	var paint := Art.material(Color("#e8ddbf"))
	var red := Art.material(Color("#b85839"))
	var base := Vector3(190 * MAP_SCALE, 25, 325 * MAP_SCALE)
	Art.box(self, base, Vector3(280, 3, 29), dark)
	obstacles.append(AABB(base - Vector3(140,1.5,14.5), Vector3(280,3,29)))
	for i in range(-6, 7):
		Art.box(self, base + Vector3(i * 20, 1.6, 0), Vector3(9, 0.15, 1.3), paint)
	for offset in [Vector3(95,0,42), Vector3(52,0,42), Vector3(-98,0,35)]:
		var p: Vector3 = base + offset
		var size := Vector3(28,18,20)
		Art.box(self, p, size, red)
		Art.box(self, p + Vector3.UP * 9, Vector3(29,1,21), dark)
		obstacles.append(AABB(p - size/2, size).grow(1))
	# Three striped navigation towers make an easy first flight course.
	for x in [-280, 0, 280]:
		var p := Vector3(x * MAP_SCALE, 0, 200 * MAP_SCALE)
		p.y = ground_at(p.x, p.z)
		Art.cylinder(self, p + Vector3.UP * 32, 4, 7, 64, paint)
		Art.cylinder(self, p + Vector3.UP * 50, 4.9, 5.4, 8, red)
		Art.cylinder(self, p + Vector3.UP * 65, 3, 4, 4, red)
		obstacles.append(AABB(p - Vector3(6,0,6), Vector3(12,67,12)))

func _clouds() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 912
	var mat := Art.material(Color("#fff2de"))
	for i in range(25):
		var angle := TAU * i / 25.0
		var p := Vector3(cos(angle) * 2700, rng.randf_range(240, 540), sin(angle) * 2700)
		for j in range(3):
			var shape := SphereMesh.new()
			shape.radial_segments = 7
			shape.rings = 3
			var puff := Art.mesh(self, shape, mat, p + Vector3(j * 100, rng.randf_range(-12,12), j * 28))
			puff.scale = Vector3(260, rng.randf_range(36,78), 125)
			puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _woods() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4781
	var forest := MultiMesh.new()
	forest.transform_format = MultiMesh.TRANSFORM_3D
	forest.use_colors = true
	var cone := CylinderMesh.new()
	cone.top_radius = 0
	cone.bottom_radius = 0.5
	cone.height = 1
	cone.radial_segments = 6
	cone.rings = 0
	forest.mesh = cone
	var poses: Array[Transform3D] = []
	var colors: Array[Color] = []
	var airfield_center := Vector2(190, 325) * MAP_SCALE
	var airfield_bounds := Rect2(airfield_center - Vector2(166,55), Vector2(326,120))
	for grove in range(104):
		var center := Vector2(rng.randf_range(-920,920),rng.randf_range(-610,610)) * MAP_SCALE
		for i in range(28):
			var x := center.x + rng.randfn(0,35)
			var z := center.y + rng.randfn(0,23)
			var h := ground_at(x,z)
			if h < 13 or h > 135 or airfield_bounds.has_point(Vector2(x,z)): continue
			var height := rng.randf_range(7.0,17.0)
			var width := height * rng.randf_range(0.43,0.68)
			var at := Vector3(x,h+height*0.42,z)
			poses.append(Transform3D(Basis().scaled(Vector3(width,height,width)),at))
			colors.append(Color("#274f49").lerp(Color("#547766"),rng.randf()))
			var bounds := AABB(Vector3(x-1,h-1,z-1),Vector3(2,height,2))
			for cx in range(floori(bounds.position.x/32),floori(bounds.end.x/32)+1):
				for cz in range(floori(bounds.position.z/32),floori(bounds.end.z/32)+1):
					var key := Vector2i(cx,cz)
					if not tree_cells.has(key): tree_cells[key] = []
					tree_cells[key].append(bounds)
	forest.instance_count = poses.size()
	for i in range(poses.size()):
		forest.set_instance_transform(i,poses[i])
		forest.set_instance_color(i,colors[i])
	var material := Art.material(Color.WHITE)
	material.vertex_color_use_as_albedo = true
	var foliage := MultiMeshInstance3D.new()
	foliage.multimesh = forest
	foliage.material_override = material
	add_child(foliage)
