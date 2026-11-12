extends Node3D
## WorldGenerator - chunked, seeded, infinite floating islands.
## Every peer generates the same world locally from the shared seed, so no
## terrain is sent over the network. Chunks follow the local player (or the Ark).
##
## Biome 0, Obsidian Spires: low gravity, lightning, glass spires, slumbering titans.
## Biome 1, Golden Resonance Ruins: tuning-fork monoliths that hide a Harmonic Core.

const CHUNK := 110.0
const GRID := 22
const BIOME_SPIRES := 0
const BIOME_RUINS := 1
const PROP_LAYERS := 5  # layer 1 (world) + layer 3 (wrappable)
const ARK_BERTH := Vector2(0.0, 30.0)  # matches the Ark's start in Main.tscn
const ARK_BERTH_CLEAR := 14.0

const CEL_SHADER: Shader = preload("res://shaders/cel_toon_pbr.gdshader")
const FOLIAGE_SHADER: Shader = preload("res://shaders/wind_grass_foliage.gdshader")
const TERRAIN_SHADER: Shader = preload("res://shaders/island_terrain.gdshader")
const Fx = preload("res://scripts/Fx.gd")

@export var view_radius := 2

var world_seed := 20261
## key "cx_cz" -> island Dictionary
var islands: Dictionary = {}

var _loaded: Dictionary = {}
var _queue: Array[Vector2i] = []
var _noise := FastNoiseLite.new()
var _mats: Dictionary = {}
var _blade_mesh: ArrayMesh
var _shard_mesh: SphereMesh
var _cone_mesh: CylinderMesh
var _firefly_mesh: SphereMesh
var _rock_mesh: SphereMesh
## [node, angular velocity] pairs for purely decorative spinning parts.
var _spinners: Array = []
var _game: Node
var _time := 0.0
var _headless := false
var _faces := PackedVector3Array()


func _ready() -> void:
	_headless = NetworkManager.is_headless()
	_game = get_tree().get_first_node_in_group("game")
	_build_shared_resources()
	set_seed(world_seed)


func set_seed(new_seed: int) -> void:
	world_seed = new_seed
	_noise.seed = new_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.02
	_noise.fractal_octaves = 3
	for key in islands.keys():
		var isl: Dictionary = islands[key]
		(isl["node"] as Node3D).queue_free()
	islands.clear()
	_loaded.clear()
	_queue.clear()
	# The home chunk is built at once so nobody spawns over a void.
	_build_chunk(Vector2i(0, 0))


func _process(delta: float) -> void:
	_time += delta
	var focus := _focus_position()
	var center := Vector2i(roundi(focus.x / CHUNK), roundi(focus.z / CHUNK))

	for dz in range(-view_radius, view_radius + 1):
		for dx in range(-view_radius, view_radius + 1):
			var c := center + Vector2i(dx, dz)
			if not _loaded.has(c) and not _queue.has(c):
				_queue.append(c)
	if not _queue.is_empty():
		var best := 0
		var best_dist := 1.0e12
		for i in _queue.size():
			var d := float((_queue[i] - center).length_squared())
			if d < best_dist:
				best_dist = d
				best = i
		var next: Vector2i = _queue[best]
		_queue.remove_at(best)
		_build_chunk(next)

	for c in _loaded.keys():
		var chunk: Vector2i = c
		if absi(chunk.x - center.x) > view_radius + 1 or absi(chunk.y - center.y) > view_radius + 1:
			_free_chunk(chunk)

	# Cores hover and spin.
	for key in islands.keys():
		var isl: Dictionary = islands[key]
		var core: Node3D = isl["core"]
		if core != null and core.visible:
			core.rotation.y = _time * 1.2
			core.position.y = float(isl["core_y"]) + sin(_time * 1.7 + float(isl["radius"])) * 0.35
		var titan: Node3D = isl["titan"]
		if titan != null and not bool(isl["titan_down"]):
			# Slumbering titans breathe.
			titan.rotation.z = sin(_time * 0.55 + float(isl["radius"])) * 0.022
	for i in range(_spinners.size() - 1, -1, -1):
		var spinner: Node3D = _spinners[i][0] if is_instance_valid(_spinners[i][0]) else null
		if spinner == null:
			_spinners.remove_at(i)
		else:
			spinner.rotation += (_spinners[i][1] as Vector3) * delta


func _focus_position() -> Vector3:
	if _game != null:
		var local: Node3D = _game.get_local_player()
		if local != null:
			return local.global_position
		if _game.ark != null:
			return _game.ark.global_position
	return Vector3.ZERO


# ---------------------------------------------------------------- queries

func get_biome_at(pos: Vector3) -> int:
	return _biome_chunk(roundi(pos.x / CHUNK), roundi(pos.z / CHUNK))


func _biome_chunk(cx: int, cz: int) -> int:
	if cx == 0 and cz == 0:
		return BIOME_RUINS
	return BIOME_RUINS if _noise.get_noise_3d(cx * 30.0, 123.0, cz * 30.0) > 0.0 else BIOME_SPIRES


func nearest_core(pos: Vector3) -> Variant:
	var best: Variant = null
	var best_dist := 1.0e12
	for key in islands.keys():
		var isl: Dictionary = islands[key]
		var core: Node3D = isl["core"]
		if core != null and core.visible:
			var d := pos.distance_squared_to(core.global_position)
			if d < best_dist:
				best_dist = d
				best = core.global_position
	return best


func core_near(pos: Vector3, radius: float) -> String:
	for key in islands.keys():
		var isl: Dictionary = islands[key]
		var core: Node3D = isl["core"]
		if core != null and core.visible and pos.distance_to(core.global_position) < radius:
			return str(key)
	return ""


func get_monolith_position(key: String, idx: int) -> Variant:
	if not islands.has(key):
		return null
	var list: Array = islands[key]["monoliths"]
	if idx < 0 or idx >= list.size():
		return null
	return (list[idx]["body"] as Node3D).global_position


func random_spire_near(pos: Vector3) -> Vector3:
	var best_key := ""
	var best_dist := 1.0e12
	for key in islands.keys():
		var isl: Dictionary = islands[key]
		if (isl["spires"] as Array).is_empty():
			continue
		var d := pos.distance_squared_to(isl["center"])
		if d < best_dist:
			best_dist = d
			best_key = str(key)
	if best_key == "":
		return pos + Vector3(randf_range(-20, 20), 0, randf_range(-20, 20))
	var spires: Array = islands[best_key]["spires"]
	return spires[randi() % spires.size()]


# ------------------------------------------------------- state from server

func apply_state() -> void:
	for key in islands.keys():
		_apply_island_state(str(key))


func _apply_island_state(key: String) -> void:
	if not islands.has(key):
		return
	var isl: Dictionary = islands[key]
	var core: Node3D = isl["core"]
	if core != null:
		var is_revealed: bool = not bool(isl["puzzle"])
		var is_collected := false
		if _game != null:
			is_revealed = is_revealed or _game.revealed.has(key)
			is_collected = _game.collected.has(key)
		core.visible = is_revealed and not is_collected
	var titan: Node3D = isl["titan"]
	if titan != null and _game != null and _game.toppled.has(key) and not bool(isl["titan_down"]):
		isl["titan_down"] = true
		titan.rotation.x = PI * 0.47
		titan.remove_from_group("wrappable")


func ring_monolith(key: String, idx: int) -> void:
	if not islands.has(key):
		return
	var list: Array = islands[key]["monoliths"]
	if idx < 0 or idx >= list.size():
		return
	var mat: ShaderMaterial = list[idx]["material"]
	var body: Node3D = list[idx]["body"]
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_method(func(v: float) -> void: mat.set_shader_parameter("emission_energy", v), 7.0, 0.6, 2.2)
	body.scale = Vector3(1.12, 1.0, 1.12)
	tween.tween_property(body, "scale", Vector3.ONE, 0.6).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func reveal_core(key: String) -> void:
	if not islands.has(key):
		return
	_apply_island_state(key)
	var core: Node3D = islands[key]["core"]
	if core != null and core.visible:
		core.scale = Vector3.ONE * 0.05
		create_tween().tween_property(core, "scale", Vector3.ONE, 0.8).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func collect_core(key: String) -> void:
	_apply_island_state(key)


func topple_titan(key: String) -> void:
	if not islands.has(key):
		return
	var isl: Dictionary = islands[key]
	var titan: Node3D = isl["titan"]
	if titan != null and not bool(isl["titan_down"]):
		isl["titan_down"] = true
		titan.remove_from_group("wrappable")
		var tween := create_tween()
		tween.tween_property(titan, "rotation:x", PI * 0.47, 1.7).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	reveal_core(key)


# ------------------------------------------------------------- generation

func _key(c: Vector2i) -> String:
	return "%d_%d" % [c.x, c.y]


func _free_chunk(c: Vector2i) -> void:
	var key := _key(c)
	if islands.has(key):
		(islands[key]["node"] as Node3D).queue_free()
		islands.erase(key)
	_loaded.erase(c)


func _build_chunk(c: Vector2i) -> void:
	if _loaded.has(c):
		return
	_loaded[c] = true
	var home := c == Vector2i(0, 0)
	if not home and _noise.get_noise_3d(c.x * 40.0, 500.0, c.y * 40.0) < -0.22:
		return  # open sky

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(c.x, c.y, world_seed))
	var radius := 42.0 if home else rng.randf_range(24.0, 44.0)
	var margin := maxf(CHUNK * 0.5 - radius * 1.25 - 1.0, 0.0)
	var center := Vector3(c.x * CHUNK, 0.0, c.y * CHUNK)
	if not home:
		center.x += rng.randf_range(-margin, margin)
		center.z += rng.randf_range(-margin, margin)
		center.y = _noise.get_noise_3d(c.x * 25.0, 900.0, c.y * 25.0) * 16.0
	var biome := _biome_chunk(c.x, c.y)
	var key := _key(c)

	var isl := {
		"key": key,
		"center": center,
		"radius": radius,
		"depth": radius * rng.randf_range(0.7, 1.2),
		"offset": rng.randf_range(0.0, 900.0),
		"biome": biome,
		"puzzle": home or rng.randf() < 0.6,
		"node": null,
		"core": null,
		"core_y": 0.0,
		"titan": null,
		"titan_down": false,
		"monoliths": [],
		"spires": [],
	}
	var loose_core: bool = not bool(isl["puzzle"]) and rng.randf() < 0.35

	var node := Node3D.new()
	node.name = "Island_" + key
	add_child(node)
	node.position = center
	isl["node"] = node

	_build_terrain(isl, node, rng)
	if biome == BIOME_SPIRES:
		_build_spires(isl, node, rng)
		if bool(isl["puzzle"]):
			_build_titan(isl, node, rng)
	else:
		_build_columns(isl, node, rng)
		if bool(isl["puzzle"]):
			_build_monoliths(isl, node, rng)
	if bool(isl["puzzle"]) or loose_core:
		_build_core(isl, node)
	if not _headless:
		_build_foliage(isl, node, rng)

	islands[key] = isl
	_apply_island_state(key)


## Returns [x, z, top, bottom, inside] for a local point. Points beyond the
## island's rim are pulled onto it so the top and bottom shells close cleanly.
func _shape(lx: float, lz: float, isl: Dictionary) -> Array:
	var radius: float = isl["radius"]
	var off: float = isl["offset"]
	var d := sqrt(lx * lx + lz * lz) / radius
	var edge := 1.0 + 0.22 * _noise.get_noise_3d(lx * 1.3 + off, 7.0, lz * 1.3 + off)
	var dn := d / edge
	if dn >= 1.0:
		var s := 1.0 / dn
		return [lx * s, lz * s, -0.8, -0.8, false]
	var bump := _noise.get_noise_3d(lx * 2.0 + off, 31.0, lz * 2.0 + off) * 2.2
	var top := bump * (1.0 - dn * dn) - pow(dn, 6.0) * 0.8
	var rough := 0.65 + 0.35 * _noise.get_noise_3d(lx * 4.0 + off, 77.0, lz * 4.0 + off)
	var bottom: float = -0.8 - float(isl["depth"]) * pow(1.0 - dn, 0.8) * rough
	return [lx, lz, top, bottom, true]


func _top(isl: Dictionary, lx: float, lz: float) -> float:
	return float(_shape(lx, lz, isl)[2])


func _build_terrain(isl: Dictionary, node: Node3D, rng: RandomNumberGenerator) -> void:
	var radius: float = isl["radius"]
	var biome: int = isl["biome"]
	var top_col := Color(0.05, 0.10, 0.14) if biome == BIOME_SPIRES else Color(0.17, 0.12, 0.13)
	var rock_col := Color(0.05, 0.04, 0.11) if biome == BIOME_SPIRES else Color(0.10, 0.07, 0.14)
	var extent := radius * 1.25
	var n := GRID
	var pts: Array = []
	pts.resize((n + 1) * (n + 1))
	for j in n + 1:
		for i in n + 1:
			var lx := -extent + 2.0 * extent * float(i) / float(n)
			var lz := -extent + 2.0 * extent * float(j) / float(n)
			pts[j * (n + 1) + i] = _shape(lx, lz, isl)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_faces = PackedVector3Array()
	for j in n:
		for i in n:
			var p00: Array = pts[j * (n + 1) + i]
			var p10: Array = pts[j * (n + 1) + i + 1]
			var p01: Array = pts[(j + 1) * (n + 1) + i]
			var p11: Array = pts[(j + 1) * (n + 1) + i + 1]
			if not (p00[4] or p10[4] or p01[4] or p11[4]):
				continue
			var shade := rng.randf_range(0.85, 1.15)
			var ct := top_col * shade
			var cb := rock_col * rng.randf_range(0.8, 1.2)
			# Top shell (clockwise seen from above).
			_tri(st, _v(p00, 2), _v(p10, 2), _v(p11, 2), ct)
			_tri(st, _v(p00, 2), _v(p11, 2), _v(p01, 2), ct)
			# Underside shell (reversed).
			_tri(st, _v(p00, 3), _v(p11, 3), _v(p10, 3), cb)
			_tri(st, _v(p00, 3), _v(p01, 3), _v(p11, 3), cb)
	var body := StaticBody3D.new()
	body.name = "Terrain"
	body.collision_layer = 1
	body.collision_mask = 0
	node.add_child(body)
	if not _headless:
		st.generate_normals()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = _mats["island_spires"] if int(isl["biome"]) == BIOME_SPIRES else _mats["island_ruins"]
		body.add_child(mi)
	var col := CollisionShape3D.new()
	var trimesh := ConcavePolygonShape3D.new()
	trimesh.set_faces(_faces)
	col.shape = trimesh
	body.add_child(col)


func _v(p: Array, which: int) -> Vector3:
	return Vector3(p[0], p[which], p[1])


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	if (b - a).cross(c - a).length_squared() < 0.00001:
		return
	st.set_color(color)
	st.add_vertex(a)
	st.set_color(color)
	st.add_vertex(b)
	st.set_color(color)
	st.add_vertex(c)
	_faces.append(a)
	_faces.append(b)
	_faces.append(c)


func _random_spot(isl: Dictionary, rng: RandomNumberGenerator, min_r: float, max_r: float) -> Vector3:
	var radius: float = isl["radius"]
	var lx := 0.0
	var lz := 0.0
	for attempt in 10:
		var angle := rng.randf() * TAU
		var dist := radius * rng.randf_range(min_r, max_r)
		lx = cos(angle) * dist
		lz = sin(angle) * dist
		# Keep the Ark's starting berth on the home island clear: the Ark is solid now.
		if str(isl["key"]) != "0_0" or Vector2(lx, lz).distance_to(ARK_BERTH) > ARK_BERTH_CLEAR:
			break
	return Vector3(lx, _top(isl, lx, lz), lz)


func _static_prop(node: Node3D, pos: Vector3, wrap_radius: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = PROP_LAYERS
	body.collision_mask = 0
	node.add_child(body)
	body.position = pos
	body.add_to_group("wrappable")
	body.set_meta("wrap_radius", wrap_radius)
	return body


func _mesh_part(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	if not _headless:
		mi.mesh = mesh
		mi.material_override = mat
	parent.add_child(mi)
	mi.position = pos
	return mi


func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


func _build_spires(isl: Dictionary, node: Node3D, rng: RandomNumberGenerator) -> void:
	var count := rng.randi_range(4, 8)
	for i in count:
		var spot := _random_spot(isl, rng, 0.3, 0.8)
		var height := rng.randf_range(10.0, 26.0)
		var base := rng.randf_range(1.6, 3.2)
		var body := _static_prop(node, spot + Vector3(0, -0.6, 0), base + 0.35)
		body.set_meta("cone_height", height)
		var cone := CylinderMesh.new()
		cone.top_radius = 0.05
		cone.bottom_radius = base
		cone.height = height
		cone.radial_segments = 5
		cone.rings = 1
		var mi := _mesh_part(body, cone, Vector3(0, height * 0.5, 0), _mats["obsidian"])
		mi.rotation.y = rng.randf() * TAU
		var tip := _mesh_part(body, _shard_mesh, Vector3(0, height + 0.9, 0), _mats["crystal_spires"])
		if not _headless:
			_spinners.append([tip, Vector3(0, rng.randf_range(0.6, 1.4), 0)])
		# Collider is the same five-sided cone as the mesh, so nothing clips it.
		var cone_points := PackedVector3Array([Vector3(0, height, 0)])
		for k in 5:
			var ca := TAU * float(k) / 5.0
			cone_points.append(Vector3(sin(ca) * base, 0.0, cos(ca) * base))
		var shape := ConvexPolygonShape3D.new()
		shape.points = cone_points
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		col.rotation.y = mi.rotation.y
		var spire_print := PackedVector2Array()
		for k in 5:
			var fa := TAU * float(k) / 5.0
			var corner := Basis(Vector3.UP, mi.rotation.y) * Vector3(sin(fa) * base, 0.0, cos(fa) * base)
			spire_print.append(Vector2(corner.x, corner.z))
		body.set_meta("footprint", spire_print)
		body.set_meta("taper_height", height)
		body.set_meta("wrap_top", height * 0.92)
		(isl["spires"] as Array).append((isl["center"] as Vector3) + spot + Vector3(0, height - 0.6, 0))


func _build_titan(isl: Dictionary, node: Node3D, rng: RandomNumberGenerator) -> void:
	var spot := _random_spot(isl, rng, 0.12, 0.22)
	var body := _static_prop(node, spot + Vector3(0, -0.3, 0), 2.6)
	body.name = "Titan"
	body.add_to_group("titan")
	body.set_meta("key", isl["key"])
	body.rotation.y = rng.randf() * TAU
	var stone: Material = _mats["titan"]
	_mesh_part(body, _box(Vector3(1.3, 8.0, 1.3)), Vector3(-1.5, 4.0, 0), stone)
	_mesh_part(body, _box(Vector3(1.3, 8.0, 1.3)), Vector3(1.5, 4.0, 0), stone)
	var torso := CylinderMesh.new()
	torso.top_radius = 2.9
	torso.bottom_radius = 2.0
	torso.height = 5.0
	torso.radial_segments = 6
	_mesh_part(body, torso, Vector3(0, 10.4, 0), stone)
	_mesh_part(body, _box(Vector3(1.0, 6.0, 1.0)), Vector3(-3.5, 9.2, 0), stone)
	_mesh_part(body, _box(Vector3(1.0, 6.0, 1.0)), Vector3(3.5, 9.2, 0), stone)
	var head := SphereMesh.new()
	head.radius = 1.5
	head.height = 3.4
	head.radial_segments = 4
	head.rings = 2
	_mesh_part(body, head, Vector3(0, 14.8, 0), stone)
	_mesh_part(body, _box(Vector3(1.4, 0.3, 0.3)), Vector3(0, 14.9, -1.0), _mats["titan_eye"])
	var shape := CapsuleShape3D.new()
	shape.radius = 2.3
	shape.height = 15.5
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	col.position = Vector3(0, 7.75, 0)
	for arm_x in [-3.5, 3.5]:
		var arm_shape := BoxShape3D.new()
		arm_shape.size = Vector3(1.0, 6.0, 1.0)
		var arm_col := CollisionShape3D.new()
		arm_col.shape = arm_shape
		body.add_child(arm_col)
		arm_col.position = Vector3(arm_x, 9.2, 0)
	body.set_meta("wrap_top", 14.0)
	isl["titan"] = body


func _build_columns(isl: Dictionary, node: Node3D, rng: RandomNumberGenerator) -> void:
	var count := rng.randi_range(5, 9)
	for i in count:
		var spot := _random_spot(isl, rng, 0.58, 0.82)
		var height := rng.randf_range(3.5, 11.0)
		var body := _static_prop(node, spot + Vector3(0, -0.4, 0), 1.03)
		body.set_meta("wrap_top", height)
		var shaft := CylinderMesh.new()
		shaft.top_radius = 0.8
		shaft.bottom_radius = 0.95
		shaft.height = height
		shaft.radial_segments = 8
		_mesh_part(body, shaft, Vector3(0, height * 0.5, 0), _mats["ruin"])
		if height > 8.0:
			_mesh_part(body, _box(Vector3(2.3, 0.5, 2.3)), Vector3(0, height + 0.25, 0), _mats["ruin"])
		var shape := CylinderShape3D.new()
		shape.radius = 0.95
		shape.height = height
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		col.position = Vector3(0, height * 0.5, 0)


func _build_monoliths(isl: Dictionary, node: Node3D, rng: RandomNumberGenerator) -> void:
	var radius: float = isl["radius"]
	var start := rng.randf() * TAU
	for idx in 3:
		var angle := start + TAU * float(idx) / 3.0
		var lx := cos(angle) * radius * 0.42
		var lz := sin(angle) * radius * 0.42
		var body := _static_prop(node, Vector3(lx, _top(isl, lx, lz) - 0.3, lz), 1.6)
		body.name = "Monolith%d" % idx
		body.add_to_group("monolith")
		body.set_meta("key", isl["key"])
		body.set_meta("idx", idx)
		body.rotation.y = -angle
		var mat := _cel(Color(0.85, 0.62, 0.22), 0.9, 0.25, Color(1.0, 0.85, 0.5), 1.5)
		mat.set_shader_parameter("emission", Color(1.0, 0.75, 0.3))
		mat.set_shader_parameter("emission_energy", 0.6)
		mat.set_shader_parameter("pulse_speed", 0.9 + 0.2 * float(idx))
		_mesh_part(body, _box(Vector3(2.3, 1.2, 0.9)), Vector3(0, 0.6, 0), _mats["ruin"])
		_mesh_part(body, _box(Vector3(0.7, 2.6, 0.7)), Vector3(0, 2.5, 0), mat)
		_mesh_part(body, _box(Vector3(2.1, 0.6, 0.7)), Vector3(0, 4.1, 0), mat)
		_mesh_part(body, _box(Vector3(0.5, 5.2, 0.7)), Vector3(-0.8, 7.0, 0), mat)
		_mesh_part(body, _box(Vector3(0.5, 5.2, 0.7)), Vector3(0.8, 7.0, 0), mat)
		var halo_mesh := TorusMesh.new()
		halo_mesh.inner_radius = 1.55
		halo_mesh.outer_radius = 1.63
		halo_mesh.rings = 32
		halo_mesh.ring_segments = 4
		var halo := _mesh_part(body, halo_mesh, Vector3(0, 8.4, 0), mat)
		halo.rotation.x = 0.35
		if not _headless:
			_spinners.append([halo, Vector3(0, 0.9 + 0.3 * float(idx), 0)])
		body.set_meta("footprint", PackedVector2Array([Vector2(-1.15, -0.45), Vector2(1.15, -0.45), Vector2(1.15, 0.45), Vector2(-1.15, 0.45)]))
		body.set_meta("wrap_top", 9.6)
		# Fork and plinth each get a collider that matches what you see.
		var shape := BoxShape3D.new()
		shape.size = Vector3(2.1, 8.4, 0.7)
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		col.position = Vector3(0, 5.4, 0)
		var plinth_shape := BoxShape3D.new()
		plinth_shape.size = Vector3(2.3, 1.2, 0.9)
		var plinth_col := CollisionShape3D.new()
		plinth_col.shape = plinth_shape
		body.add_child(plinth_col)
		plinth_col.position = Vector3(0, 0.6, 0)
		(isl["monoliths"] as Array).append({"body": body, "material": mat})


func _build_core(isl: Dictionary, node: Node3D) -> void:
	var core := Node3D.new()
	core.name = "Core"
	node.add_child(core)
	var y := _top(isl, 0.0, 0.0) + 3.0
	core.position = Vector3(0, y, 0)
	isl["core_y"] = y
	var gem := SphereMesh.new()
	gem.radius = 0.8
	gem.height = 2.2
	gem.radial_segments = 6
	gem.rings = 2
	_mesh_part(core, gem, Vector3.ZERO, _mats["core"])
	# Two gyroscope rings turning on different axes.
	for r in 2:
		var ring := TorusMesh.new()
		ring.inner_radius = 1.25 + 0.4 * float(r)
		ring.outer_radius = 1.36 + 0.4 * float(r)
		ring.rings = 32
		ring.ring_segments = 5
		var ring_mi := _mesh_part(core, ring, Vector3.ZERO, _mats["core"])
		ring_mi.rotation = Vector3(0.5 + 0.9 * float(r), 0, 0.3 * float(r))
		if not _headless:
			_spinners.append([ring_mi, Vector3(1.1 - 1.9 * float(r), 0.0, 0.7)])
	if not _headless:
		# A pillar of light so a surfaced core can be seen from far away.
		var beam := CylinderMesh.new()
		beam.top_radius = 0.0
		beam.bottom_radius = 0.4
		beam.height = 80.0
		beam.radial_segments = 8
		beam.cap_top = false
		beam.cap_bottom = false
		var beam_mi := _mesh_part(core, beam, Vector3(0, 40.0, 0), _mats["beam"])
		beam_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var process := ParticleProcessMaterial.new()
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		process.emission_sphere_radius = 1.6
		process.direction = Vector3(0, 1, 0)
		process.spread = 25.0
		process.initial_velocity_min = 0.5
		process.initial_velocity_max = 1.8
		process.gravity = Vector3.ZERO
		process.scale_min = 0.4
		process.scale_max = 1.3
		process.color = Color(1.0, 0.82, 0.45)
		process.color_ramp = Fx.fade_ramp()
		core.add_child(Fx.particles(30, 2.4, Vector2(0.2, 0.2), process))
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.8, 0.4)
		light.light_energy = 4.0
		light.omni_range = 16.0
		light.light_volumetric_fog_energy = 0.0
		core.add_child(light)
	isl["core"] = core


func _build_foliage(isl: Dictionary, node: Node3D, rng: RandomNumberGenerator) -> void:
	var radius: float = isl["radius"]
	var biome: int = isl["biome"]
	# Grass
	var count := clampi(int(radius * radius * 1.6), 400, 3200)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _blade_mesh
	mm.instance_count = count
	for i in count:
		var angle := rng.randf() * TAU
		var dist := radius * sqrt(rng.randf()) * 0.95
		var lx := cos(angle) * dist
		var lz := sin(angle) * dist
		var s: Array = _shape(lx, lz, isl)
		var sc: float = rng.randf_range(0.7, 1.6) if s[4] else 0.0
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sc, sc, sc))
		mm.set_instance_transform(i, Transform3D(b, Vector3(lx, float(s[2]) - 0.05, lz)))
	var grass := MultiMeshInstance3D.new()
	grass.multimesh = mm
	grass.material_override = _mats["grass_spires"] if biome == BIOME_SPIRES else _mats["grass_ruins"]
	grass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(grass)

	# Floating crystal shards around the rim
	var shard_count := rng.randi_range(28, 56)
	var sm := MultiMesh.new()
	sm.transform_format = MultiMesh.TRANSFORM_3D
	sm.mesh = _shard_mesh
	sm.instance_count = shard_count
	for i in shard_count:
		var angle := rng.randf() * TAU
		var dist := radius * rng.randf_range(1.1, 1.6)
		var y := rng.randf_range(-float(isl["depth"]) * 0.6, 7.0)
		var sc := rng.randf_range(0.5, 1.8)
		var b := Basis.from_euler(Vector3(rng.randf_range(-0.6, 0.6), rng.randf() * TAU, rng.randf_range(-0.6, 0.6))).scaled(Vector3(sc, sc, sc))
		sm.set_instance_transform(i, Transform3D(b, Vector3(cos(angle) * dist, y, sin(angle) * dist)))
	var shards := MultiMeshInstance3D.new()
	shards.multimesh = sm
	shards.material_override = _mats["shard_spires"] if biome == BIOME_SPIRES else _mats["shard_ruins"]
	shards.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shards.custom_aabb = AABB(Vector3(-radius * 2.0, -radius * 2.0, -radius * 2.0), Vector3(radius * 4.0, radius * 4.0, radius * 4.0))
	node.add_child(shards)


	_build_dressing(isl, node, rng)


func _multimesh_layer(node: Node3D, mesh: Mesh, transforms: Array, material: Material, margin: float) -> void:
	if transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.material_override = material
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.extra_cull_margin = margin
	node.add_child(inst)


## Decorative layers: glowing crystal clusters, stalactites under the island,
## fireflies over the grass, and slow-bobbing rock debris around the rim.
func _build_dressing(isl: Dictionary, node: Node3D, rng: RandomNumberGenerator) -> void:
	var radius: float = isl["radius"]
	var spires: bool = int(isl["biome"]) == BIOME_SPIRES
	var crystal_mat: Material = _mats["crystal_spires"] if spires else _mats["crystal_ruins"]

	var crystals: Array = []
	for cluster in rng.randi_range(7, 13):
		var spot := _random_spot(isl, rng, 0.15, 0.9)
		for k in rng.randi_range(3, 6):
			var lx := spot.x + rng.randf_range(-0.9, 0.9)
			var lz := spot.z + rng.randf_range(-0.9, 0.9)
			var s: Array = _shape(lx, lz, isl)
			if not s[4]:
				continue
			var b := Basis.from_euler(Vector3(rng.randf_range(-0.5, 0.5), rng.randf() * TAU, rng.randf_range(-0.5, 0.5)))
			b = b.scaled(Vector3(rng.randf_range(0.6, 1.3), rng.randf_range(0.7, 2.6), rng.randf_range(0.6, 1.3)))
			crystals.append(Transform3D(b, Vector3(lx, float(s[2]) - 0.1, lz) + b * Vector3(0, 0.5, 0)))
	_multimesh_layer(node, _cone_mesh, crystals, crystal_mat, 4.0)

	var stalactites: Array = []
	for k in rng.randi_range(30, 55):
		var angle := rng.randf() * TAU
		var dist := radius * sqrt(rng.randf()) * 0.85
		var lx := cos(angle) * dist
		var lz := sin(angle) * dist
		var s: Array = _shape(lx, lz, isl)
		if not s[4]:
			continue
		var width := rng.randf_range(1.5, 4.0)
		var length := rng.randf_range(3.0, 9.0)
		var b := Basis.from_euler(Vector3(PI + rng.randf_range(-0.15, 0.15), rng.randf() * TAU, rng.randf_range(-0.15, 0.15)))
		b = b.scaled(Vector3(width, length, width))
		stalactites.append(Transform3D(b, Vector3(lx, float(s[3]) + 0.5, lz) + b * Vector3(0, 0.5, 0)))
	_multimesh_layer(node, _cone_mesh, stalactites, _mats["stalactite_spires"] if spires else _mats["stalactite_ruins"], 10.0)

	var fireflies: Array = []
	for k in rng.randi_range(50, 90):
		var spot := _random_spot(isl, rng, 0.0, 0.92)
		fireflies.append(Transform3D(Basis.IDENTITY, spot + Vector3(0, rng.randf_range(0.8, 3.2), 0)))
	_multimesh_layer(node, _firefly_mesh, fireflies, _mats["firefly_spires"] if spires else _mats["firefly_ruins"], 6.0)

	var debris: Array = []
	for k in rng.randi_range(5, 9):
		var angle := rng.randf() * TAU
		var dist := radius * rng.randf_range(1.15, 1.6)
		var size := rng.randf_range(0.6, 2.2)
		var b := Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU))
		b = b.scaled(Vector3(size * rng.randf_range(0.7, 1.5), size, size * rng.randf_range(0.7, 1.5)))
		debris.append(Transform3D(b, Vector3(cos(angle) * dist, rng.randf_range(-float(isl["depth"]) * 0.7, -3.0), sin(angle) * dist)))
	_multimesh_layer(node, _rock_mesh, debris, _mats["debris"], 8.0)


# --------------------------------------------------------------- materials

func _cel(color: Color, metallic: float, roughness: float, rim: Color, rim_strength: float = 1.0) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = CEL_SHADER
	mat.set_shader_parameter("albedo", color)
	mat.set_shader_parameter("metallic", metallic)
	mat.set_shader_parameter("roughness", roughness)
	mat.set_shader_parameter("rim_color", rim)
	mat.set_shader_parameter("rim_strength", rim_strength)
	return mat


func _foliage(base: Color, tip: Color, emission: float, floating: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = FOLIAGE_SHADER
	mat.set_shader_parameter("base_color", base)
	mat.set_shader_parameter("tip_color", tip)
	mat.set_shader_parameter("emission_energy", emission)
	mat.set_shader_parameter("floating", floating)
	return mat


func _build_shared_resources() -> void:
	var island := _cel(Color(1, 1, 1), 0.05, 0.85, Color(0.5, 0.6, 1.0), 0.6)
	island.set_shader_parameter("use_vertex_color", 1.0)
	island.set_shader_parameter("spec_strength", 0.0)
	island.set_shader_parameter("rim_strength", 0.0)
	_mats["island"] = island
	for biome_name in ["spires", "ruins"]:
		var is_spires: bool = biome_name == "spires"
		var accent := Color(0.55, 0.4, 1.0) if is_spires else Color(1.0, 0.72, 0.3)
		var terrain := ShaderMaterial.new()
		terrain.shader = TERRAIN_SHADER
		terrain.set_shader_parameter("accent", accent)
		_mats["island_" + biome_name] = terrain
		var crystal := _cel(accent * 0.35, 0.6, 0.15, accent.lightened(0.3), 2.0)
		crystal.set_shader_parameter("emission", accent)
		crystal.set_shader_parameter("emission_energy", 1.0)
		crystal.set_shader_parameter("pulse_speed", 1.1)
		crystal.set_shader_parameter("fresnel_glow", 0.5)
		_mats["crystal_" + biome_name] = crystal
		var stalactite := _cel(accent * 0.12, 0.7, 0.25, accent, 1.6)
		stalactite.set_shader_parameter("emission", accent)
		stalactite.set_shader_parameter("emission_energy", 0.5)
		stalactite.set_shader_parameter("pulse_speed", 0.7)
		stalactite.set_shader_parameter("fresnel_glow", 1.2)
		_mats["stalactite_" + biome_name] = stalactite
		var firefly_color := Color(0.4, 1.0, 0.9) if is_spires else Color(1.0, 0.85, 0.5)
		_mats["firefly_" + biome_name] = _foliage(firefly_color, firefly_color, 4.0, 1.0)
	_mats["debris"] = _cel(Color(0.06, 0.05, 0.12), 0.1, 0.85, Color(0.6, 0.45, 1.0), 0.8)
	(_mats["debris"] as ShaderMaterial).set_shader_parameter("spec_strength", 0.0)
	var beam := StandardMaterial3D.new()
	beam.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	beam.cull_mode = BaseMaterial3D.CULL_DISABLED
	beam.albedo_color = Color(1.0, 0.8, 0.4, 0.22)
	_mats["beam"] = beam
	var obsidian := _cel(Color(0.05, 0.04, 0.10), 0.85, 0.18, Color(0.61, 0.42, 1.0), 2.0)
	obsidian.set_shader_parameter("fresnel_glow", 0.5)
	_mats["obsidian"] = obsidian
	_mats["ruin"] = _cel(Color(0.52, 0.42, 0.30), 0.1, 0.8, Color(1.0, 0.85, 0.55), 0.5)
	(_mats["ruin"] as ShaderMaterial).set_shader_parameter("spec_strength", 0.3)
	_mats["titan"] = _cel(Color(0.12, 0.11, 0.22), 0.5, 0.4, Color(0.61, 0.42, 1.0), 1.6)
	var eye := _cel(Color(0.1, 0.1, 0.1), 0.0, 0.5, Color(1, 1, 1), 0.0)
	eye.set_shader_parameter("emission", Color(0.72, 0.5, 1.0))
	eye.set_shader_parameter("emission_energy", 6.0)
	eye.set_shader_parameter("pulse_speed", 2.0)
	_mats["titan_eye"] = eye
	var core := _cel(Color(1.0, 0.8, 0.4), 0.6, 0.2, Color(1.0, 0.95, 0.8), 2.0)
	core.set_shader_parameter("emission", Color(1.0, 0.78, 0.35))
	core.set_shader_parameter("emission_energy", 2.4)
	core.set_shader_parameter("pulse_speed", 3.0)
	core.set_shader_parameter("fresnel_glow", 1.5)
	_mats["core"] = core
	_mats["grass_spires"] = _foliage(Color(0.04, 0.20, 0.26), Color(0.30, 0.95, 0.85), 0.35, 0.0)
	_mats["grass_ruins"] = _foliage(Color(0.33, 0.20, 0.09), Color(1.0, 0.80, 0.40), 0.2, 0.0)
	_mats["shard_spires"] = _foliage(Color(0.30, 0.20, 0.70), Color(0.61, 0.42, 1.0), 1.6, 1.0)
	_mats["shard_ruins"] = _foliage(Color(0.70, 0.45, 0.15), Color(1.0, 0.80, 0.40), 1.4, 1.0)

	# Grass blade: two crossed tapered triangles, UV.y = 0 at root, 1 at tip.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Each blade: three tapering segments with a gentle forward curve.
	var rows: Array = [[0.0, 0.045, 0.0], [0.18, 0.036, 0.015], [0.34, 0.022, 0.05], [0.46, 0.0, 0.11]]
	for turn in 2:
		var b := Basis(Vector3.UP, PI * 0.5 * float(turn) + 0.3)
		for r in 3:
			var lo: Array = rows[r]
			var hi: Array = rows[r + 1]
			var quad: Array = [
				[Vector3(-lo[1], lo[0], lo[2]), lo[0]], [Vector3(lo[1], lo[0], lo[2]), lo[0]], [Vector3(hi[1], hi[0], hi[2]), hi[0]],
				[Vector3(-lo[1], lo[0], lo[2]), lo[0]], [Vector3(hi[1], hi[0], hi[2]), hi[0]], [Vector3(-hi[1], hi[0], hi[2]), hi[0]],
			]
			for corner in quad:
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(0.5, float(corner[1]) / 0.46))
				st.add_vertex(b * (corner[0] as Vector3))
	_blade_mesh = st.commit()

	_shard_mesh = SphereMesh.new()
	_shard_mesh.radius = 0.35
	_shard_mesh.height = 1.5
	_shard_mesh.radial_segments = 4
	_shard_mesh.rings = 2

	_cone_mesh = CylinderMesh.new()
	_cone_mesh.top_radius = 0.0
	_cone_mesh.bottom_radius = 0.25
	_cone_mesh.height = 1.0
	_cone_mesh.radial_segments = 5
	_cone_mesh.rings = 1
	_firefly_mesh = SphereMesh.new()
	_firefly_mesh.radius = 0.07
	_firefly_mesh.height = 0.14
	_firefly_mesh.radial_segments = 6
	_firefly_mesh.rings = 3
	_rock_mesh = SphereMesh.new()
	_rock_mesh.radius = 1.0
	_rock_mesh.height = 1.5
	_rock_mesh.radial_segments = 5
	_rock_mesh.rings = 3
