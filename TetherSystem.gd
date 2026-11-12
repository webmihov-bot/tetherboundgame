extends Node3D
## TetherSystem - the shared energy cable.
##
## Topology: Ark -> first player -> second player -> ... (sorted by peer id).
## Each link is a one-sided spring (it only pulls when stretched past its rest
## length) with a hard maximum, plus rope wrapping around "wrappable" bodies
## (spires, columns, monoliths, titans) and a Verlet rope for the visuals.
##
## Every peer runs the same link list. A peer applies cable forces only to its
## own Resonator (solve_for), using the replicated positions and anchor states
## of the others, so the result stays consistent without a physics server.

const TETHER_SHADER: Shader = preload("res://shaders/energy_tether.gdshader")
const POINTS := 30
const ROPE_RADIUS := 0.1
const BODY_RADIUS := 0.42
const WORLD_MASK := 1
const MAX_WRAPS := 32
const FOOTPRINT_MARGIN := 0.14
const RELEASE_COOLDOWN := 0.8
const STUCK_SECONDS := 5.0

@export var ark_length := 34.0
@export var player_length := 12.0
@export var stiffness_fixed := 14.0
@export var stiffness_shared := 7.0
@export var outward_damping := 3.0
@export var max_pull_accel := 90.0
## Visual rope: gravity (m/s^2), friction on contact (0..1), slack paid out.
@export var rope_gravity := 28.0
@export var rope_friction := 0.45
@export var slack_ratio := 1.1
## Share of the pull that gets past each corner the cable is bent around.
@export var bend_grip := 0.6

## Lightning charge, 0..1. Boosts catapults and tints the cable violet.
var charge := 0.0
var links: Array = []

var _ids: Array = []
var _pull_dirs: Dictionary = {}
var _strain: Dictionary = {}
var _ring_cooldown: Dictionary = {}
var _game: Node
var _ark: Node3D
var _headless := false
var _rope_query := PhysicsRayQueryParameters3D.new()
var _ark_last := Vector3.ZERO
var _ark_step := Vector3.ZERO
var _footprints: Array = []
var _footprint_timer := 0.0
var _release_cooldown := 0.0
var _stuck_time := 0.0


class Link:
	var a: Node3D
	var b: Node3D
	var is_ark := false
	var base_len := 12.0
	var wraps: Array = []
	var pts := PackedVector3Array()
	var prev := PackedVector3Array()
	var mesh_instance: MeshInstance3D
	var imesh: ImmediateMesh
	var material: ShaderMaterial
	var tension := 0.0
	var path_len := 0.0
	var rest := 0.0
	var max_len := 0.0
	var tracked := false
	var prev_a := Vector2.ZERO
	var prev_b := Vector2.ZERO


func _ready() -> void:
	_headless = NetworkManager.is_headless()
	if not InputMap.has_action("release_rope"):
		InputMap.add_action("release_rope")
		var key := InputEventKey.new()
		key.physical_keycode = KEY_X
		InputMap.action_add_event("release_rope", key)
	_rope_query.collision_mask = WORLD_MASK
	_game = get_tree().get_first_node_in_group("game")


func add_charge(amount: float) -> void:
	charge = clampf(charge + amount, 0.0, 1.0)


func pull_direction(player: Node3D) -> Vector3:
	var dir: Vector3 = _pull_dirs.get(player.get_instance_id(), Vector3.ZERO)
	return dir


func get_rest_length(link: Link) -> float:
	if link.is_ark:
		return link.base_len * float(link.b.reel)
	return link.base_len * (float(link.a.reel) + float(link.b.reel)) * 0.5


# --------------------------------------------------------------- per frame

func _physics_process(delta: float) -> void:
	if _game == null:
		return
	if _ark == null:
		_ark = _game.ark
	charge = maxf(0.0, charge - delta * 0.12)
	_ark_step = _ark.global_position - _ark_last
	_ark_last = _ark.global_position
	for key in _ring_cooldown.keys():
		_ring_cooldown[key] = float(_ring_cooldown[key]) - delta
	_refresh_links()
	_footprint_timer -= delta
	if _footprint_timer <= 0.0:
		_footprint_timer = 0.5
		_refresh_footprints()
	for item in links:
		var link: Link = item
		if not _valid(link):
			continue
		var a := _end_a(link)
		var b := _chest(link.b)
		_update_wraps(link, a, b)
		link.path_len = _path_length(link, a, b)
		link.rest = get_rest_length(link)
		link.max_len = link.rest * 1.5 + 2.0
		link.tension = clampf((link.path_len - link.rest) / (link.max_len - link.rest), 0.0, 1.0)
		_interact_wraps(link, delta)
		if not _headless:
			_simulate(link, a, b, delta)
	_update_release(delta)


func _process(_delta: float) -> void:
	if _headless:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	for item in links:
		var link: Link = item
		if _valid(link) and link.pts.size() == POINTS:
			_draw_link(link, cam.global_position)


func _valid(link: Link) -> bool:
	if not is_instance_valid(link.b) or link.b.is_queued_for_deletion():
		return false
	if link.is_ark:
		return _ark != null
	return is_instance_valid(link.a) and not link.a.is_queued_for_deletion()


func _chest(player: Node3D) -> Vector3:
	return player.global_position + Vector3(0, 1.1, 0)


func _end_a(link: Link) -> Vector3:
	if link.is_ark:
		return _ark.get_tether_point(_chest(link.b))
	return _chest(link.a)


func _is_fixed(node: Node3D) -> bool:
	return bool(node.anchored) or bool(node.piloting)


func _refresh_links() -> void:
	var nodes: Array = _game.get_players()
	nodes.sort_custom(func(x: Node, y: Node) -> bool: return str(x.name).to_int() < str(y.name).to_int())
	var ids: Array = []
	for n in nodes:
		ids.append((n as Node).get_instance_id())
	if ids == _ids:
		return
	_ids = ids
	for item in links:
		var old: Link = item
		if old.mesh_instance != null:
			old.mesh_instance.queue_free()
	links.clear()
	_pull_dirs.clear()
	for i in nodes.size():
		var link := Link.new()
		link.b = nodes[i]
		if i == 0:
			link.is_ark = true
			link.base_len = ark_length
		else:
			link.a = nodes[i - 1]
			link.base_len = player_length
		if not _headless:
			link.imesh = ImmediateMesh.new()
			link.material = ShaderMaterial.new()
			link.material.shader = TETHER_SHADER
			link.mesh_instance = MeshInstance3D.new()
			link.mesh_instance.mesh = link.imesh
			link.mesh_instance.material_override = link.material
			link.mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(link.mesh_instance)
		links.append(link)


# ------------------------------------------------------------------ forces

## Applies cable forces to `player` (the local Resonator) and updates its
## `tension`. Called from PlayerController before move_and_slide().
func solve_for(player: Node3D, delta: float) -> void:
	var max_tension := 0.0
	var pull_sum := Vector3.ZERO
	var fixed_self := _is_fixed(player)
	for item in links:
		var link: Link = item
		if link.b != player and link.a != player:
			continue
		if not _valid(link):
			continue
		var a := _end_a(link)
		var b := _chest(link.b)
		var mine_is_b := link.b == player
		var mine := b if mine_is_b else a
		var toward: Vector3
		if link.wraps.is_empty():
			toward = a if mine_is_b else b
		elif mine_is_b:
			toward = link.wraps[link.wraps.size() - 1]["pos"]
		else:
			toward = link.wraps[0]["pos"]
		var total := _path_length(link, a, b)
		var rest := get_rest_length(link)
		var max_len := rest * 1.5 + 2.0
		var stretch := total - rest
		if stretch <= 0.0:
			continue
		var t := clampf(stretch / (max_len - rest), 0.0, 1.0)
		max_tension = maxf(max_tension, t)
		var dir := toward - mine
		if dir.length() < 0.01:
			continue
		dir = dir.normalized()
		pull_sum += dir * t
		if fixed_self:
			continue
		var other_fixed := link.is_ark or not link.wraps.is_empty()
		if not other_fixed:
			other_fixed = _is_fixed(link.a if mine_is_b else link.b)
		var k := stiffness_fixed if other_fixed else stiffness_shared
		# Capstan friction: every corner the cable is bent around takes up part
		# of the load, so a cable wound round a post holds instead of dragging
		# you back around it.
		var grip := pow(bend_grip, float(link.wraps.size()))
		player.velocity += dir * minf(k * stretch, max_pull_accel) * grip * delta
		var along: float = player.velocity.dot(dir)
		if along < 0.0:
			player.velocity -= dir * along * minf(outward_damping * delta, 1.0)
		if total > max_len:
			# The cable is at its limit: no more outward motion.
			along = player.velocity.dot(dir)
			if along < 0.0:
				player.velocity -= dir * along
			if other_fixed:
				player.global_position += dir * minf(total - max_len, 2.0) * 0.5 * grip
	player.tension = max_tension
	_pull_dirs[player.get_instance_id()] = pull_sum.normalized() if pull_sum.length() > 0.001 else Vector3.ZERO


func _path_length(link: Link, a: Vector3, b: Vector3) -> float:
	var total := 0.0
	var last := a
	for w in link.wraps:
		var p: Vector3 = w["pos"]
		total += last.distance_to(p)
		last = p
	return total + last.distance_to(b)


# ---------------------------------------------------------------- wrapping

## Frees the cable: drops every bend on the links of one Resonator, on every
## peer, so the cable runs straight again. X does this for your own cable.
@rpc("any_peer", "call_local", "reliable")
func release_rope(peer_id: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != peer_id:
		return
	for item in links:
		var link: Link = item
		if not _valid(link):
			continue
		var mine := link.b.name == str(peer_id) or (not link.is_ark and link.a.name == str(peer_id))
		if mine:
			link.wraps.clear()
			link.tracked = false
			link.pts = PackedVector3Array()


func _release_local(message: String) -> void:
	_release_cooldown = RELEASE_COOLDOWN
	_stuck_time = 0.0
	release_rope.rpc(multiplayer.get_unique_id())
	_game.hud.flash(message, Color(0.24, 0.91, 0.96))
	_game.sound.play_clunk()


## X releases your cable. It also lets go by itself if it has been wrapped
## and jammed at full tension for a few seconds.
func _update_release(delta: float) -> void:
	_release_cooldown = maxf(0.0, _release_cooldown - delta)
	var local: Node3D = _game.get_local_player()
	if local == null:
		return
	var wrapped := false
	var jammed := false
	for item in links:
		var link: Link = item
		if not _valid(link) or (link.a != local and link.b != local):
			continue
		if not link.wraps.is_empty():
			wrapped = true
			if link.tension >= 0.97:
				jammed = true
	_stuck_time = _stuck_time + delta if jammed else maxf(0.0, _stuck_time - delta * 2.0)
	if _release_cooldown > 0.0:
		return
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_action_just_pressed("release_rope"):
		_release_local("CABLE RELEASED" if wrapped else "CABLE IS ALREADY FREE")
	elif _stuck_time > STUCK_SECONDS:
		_release_local("CABLE JAMMED  ·  SLIPPED FREE")


## Wrapping, done the way a real rope does it.
##
## Every wrappable body is a vertical prism with a convex footprint. The cable
## is a chain of straight spans: A -> bend -> bend -> ... -> B. Each physics
## step the two free spans (the ones ending at A and at B) sweep a thin
## triangle as their end moves. If a footprint corner lies inside that
## triangle the cable has just been dragged across it, so a bend is added
## there, remembering which way the cable turns around it. A bend is released
## only when the cable straightens back past that corner the way it came.
## Nothing else removes a bend, so the cable cannot slip through a body, and
## it can be wound around one any number of times.

func _refresh_footprints() -> void:
	_footprints.clear()
	var focus := _ark.global_position
	for item in get_tree().get_nodes_in_group("wrappable"):
		var body := item as Node3D
		if body == null or body.global_position.distance_to(focus) > 150.0:
			continue
		var local: PackedVector2Array = body.get_meta("footprint", PackedVector2Array())
		if local.is_empty():
			var r: float = body.get_meta("wrap_radius", 1.5)
			for k in 8:
				var ang := TAU * float(k) / 8.0
				local.append(Vector2(cos(ang), sin(ang)) * r)
		var xf := body.global_transform
		var center := Vector2(xf.origin.x, xf.origin.z)
		var offsets := PackedVector2Array()
		for v in local:
			var world := xf * Vector3(v.x, 0.0, v.y)
			offsets.append(Vector2(world.x, world.z) - center)
		var fp := {
			"body": body, "offsets": offsets, "center": center,
			"y0": xf.origin.y, "y1": xf.origin.y + float(body.get_meta("wrap_top", 8.0)),
			"taper": float(body.get_meta("taper_height", 0.0)),
		}
		var poly := _poly_at(fp, xf.origin.y)
		var reach := 0.0
		for corner in poly:
			reach = maxf(reach, corner.distance_to(center))
		fp["poly"] = poly
		fp["reach"] = reach
		_footprints.append(fp)


## Footprint corner at a given height. Tapered bodies (spires) narrow as they
## rise, so the cable hugs the cone wherever it touches it.
func _corner_at(fp: Dictionary, vertex: int, y: float) -> Vector2:
	var offset: Vector2 = (fp["offsets"] as PackedVector2Array)[vertex]
	var scale := 1.0
	var taper: float = fp["taper"]
	if taper > 0.0:
		scale = clampf(1.0 - (y - float(fp["y0"])) / taper, 0.04, 1.0)
	return (fp["center"] as Vector2) + offset * scale + offset.normalized() * FOOTPRINT_MARGIN


func _poly_at(fp: Dictionary, y: float) -> PackedVector2Array:
	var poly := PackedVector2Array()
	for vi in (fp["offsets"] as PackedVector2Array).size():
		poly.append(_corner_at(fp, vi, y))
	return poly


func _cross2(u: Vector2, v: Vector2) -> float:
	return u.x * v.y - u.y * v.x


func _in_triangle(p: Vector2, t0: Vector2, t1: Vector2, t2: Vector2) -> bool:
	var d0 := _cross2(t1 - t0, p - t0)
	var d1 := _cross2(t2 - t1, p - t1)
	var d2 := _cross2(t0 - t2, p - t2)
	var negative := d0 < 0.0 or d1 < 0.0 or d2 < 0.0
	var positive := d0 > 0.0 or d1 > 0.0 or d2 > 0.0
	return not (negative and positive)


func _flat(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)


func _update_wraps(link: Link, a: Vector3, b: Vector3) -> void:
	for i in range(link.wraps.size() - 1, -1, -1):
		var body: Object = link.wraps[i]["body"]
		if not is_instance_valid(body) or not (body as Node).is_in_group("wrappable"):
			link.wraps.remove_at(i)
	var a2 := _flat(a)
	var b2 := _flat(b)
	# A fresh cable, or an end that teleported (respawn, boarding): start clean.
	if not link.tracked or a2.distance_to(link.prev_a) > 6.0 or b2.distance_to(link.prev_b) > 6.0:
		link.wraps.clear()
		link.tracked = true
		link.prev_a = a2
		link.prev_b = b2
		return

	_release_bends(link, a2, link.prev_b, true)
	_catch_bends(link, link.prev_a, a2, a.y, b.y, link.prev_b, true)
	_release_bends(link, a2, b2, false)
	_catch_bends(link, link.prev_b, b2, b.y, a.y, a2, false)
	link.prev_a = a2
	link.prev_b = b2
	_level_bends(link, a, b)


## Lets go of bends at one end once the cable has straightened past them.
func _release_bends(link: Link, a2: Vector2, b2: Vector2, at_a: bool) -> void:
	while not link.wraps.is_empty():
		var n := link.wraps.size()
		var index := 0 if at_a else n - 1
		var bend: Dictionary = link.wraps[index]
		var corner: Vector2 = bend["flat"]
		var before: Vector2 = a2 if index == 0 else link.wraps[index - 1]["flat"]
		var after: Vector2 = b2 if index == n - 1 else link.wraps[index + 1]["flat"]
		var turn := _cross2(corner - before, after - corner)
		if turn * float(bend["sign"]) > 0.0:
			return
		link.wraps.remove_at(index)


## Adds bends where the moving end has dragged its span across a corner.
func _catch_bends(link: Link, end_prev: Vector2, end_now: Vector2, end_y: float, other_y: float, other_end: Vector2, at_a: bool) -> void:
	var from := end_prev
	var skipped: Array = []
	for pass_index in 6:
		if link.wraps.size() >= MAX_WRAPS:
			return
		var pivot := other_end
		var pivot_y := other_y
		var pivot_body: Object = null
		var pivot_vertex := -1
		if not link.wraps.is_empty():
			var edge: Dictionary = link.wraps[0] if at_a else link.wraps[link.wraps.size() - 1]
			pivot = edge["flat"]
			pivot_y = (edge["pos"] as Vector3).y
			pivot_body = edge["body"]
			pivot_vertex = int(edge["vertex"])
		if absf(_cross2(from - pivot, end_now - pivot)) < 0.00001:
			return
		var span := maxf(pivot.distance_to(from), pivot.distance_to(end_now))
		var sweep_dir := (from - pivot).normalized()

		var best: Dictionary = {}
		var best_angle := 100.0
		var best_vertex := -1
		var best_corner := Vector2.ZERO
		for fp in _footprints:
			var center: Vector2 = fp["center"]
			if center.distance_to(pivot) > span + float(fp["reach"]):
				continue
			var poly: PackedVector2Array = fp["poly"]
			if float(fp["taper"]) > 0.0:
				var along_center := clampf(pivot.distance_to(center) / maxf(pivot.distance_to(end_now), 0.001), 0.0, 1.0)
				poly = _poly_at(fp, lerpf(pivot_y, end_y, along_center))
			for vi in poly.size():
				if fp["body"] == pivot_body and vi == pivot_vertex:
					continue
				var v := poly[vi]
				if v.distance_squared_to(pivot) < 0.0004:
					continue
				if not _in_triangle(v, pivot, from, end_now):
					continue
				if skipped.has([fp["body"], vi]):
					continue
				var angle := absf(sweep_dir.angle_to(v - pivot))
				if angle < best_angle:
					best_angle = angle
					best = fp
					best_vertex = vi
					best_corner = v
		if best.is_empty():
			return

		var corner := best_corner
		# Height of the cable where it meets the corner; over the top means no contact.
		var along := pivot.distance_to(corner) / maxf(pivot.distance_to(end_now), 0.001)
		var y := lerpf(pivot_y, end_y, clampf(along, 0.0, 1.0))
		if y > float(best["y1"]) or y < float(best["y0"]) - 1.0:
			skipped.append([best["body"], best_vertex])
			continue
		var before := end_now if at_a else pivot
		var after := pivot if at_a else end_now
		var turn := _cross2(corner - before, after - corner)
		if absf(turn) < 0.000001:
			return
		# A real contact turns the cable around the body, so the body sits on the
		# inside of the turn. Otherwise the span only brushed past the free side
		# of the corner (for example while unwinding) and there is nothing to hold it.
		var inward := _cross2(corner - before, (best["center"] as Vector2) - corner)
		if inward * turn <= 0.0:
			skipped.append([best["body"], best_vertex])
			continue
		var bend := {
			"pos": Vector3(corner.x, y, corner.y), "flat": corner, "body": best["body"],
			"vertex": best_vertex, "sign": signf(turn), "top": best["y1"], "fp": best,
		}
		if at_a:
			link.wraps.insert(0, bend)
		else:
			link.wraps.append(bend)
		# Keep sweeping from the new corner for the rest of this step's motion.
		from = corner + (corner - pivot).normalized() * maxf(corner.distance_to(end_now), 0.01)


## A cable under load is straight when unrolled, so each bend sits at the
## height that line gives it. If that rises above the body, the cable lifts off.
func _level_bends(link: Link, a: Vector3, b: Vector3) -> void:
	if link.wraps.is_empty():
		return
	var total := 0.0
	var last := _flat(a)
	var marks: Array = []
	for w in link.wraps:
		var f: Vector2 = w["flat"]
		total += last.distance_to(f)
		marks.append(total)
		last = f
	total += last.distance_to(_flat(b))
	for i in range(link.wraps.size() - 1, -1, -1):
		var w: Dictionary = link.wraps[i]
		var y := lerpf(a.y, b.y, float(marks[i]) / maxf(total, 0.001))
		if y > float(w["top"]) + 0.2:
			link.wraps.remove_at(i)
			continue
		var f: Vector2 = w["flat"]
		if float(w["fp"]["taper"]) > 0.0:
			f = _corner_at(w["fp"], int(w["vertex"]), y)
			w["flat"] = f
		w["pos"] = Vector3(f.x, y, f.y)


## Wrapped titans get strained until they topple; wrapped monoliths ring.
func _interact_wraps(link: Link, delta: float) -> void:
	var local: Node3D = _game.get_local_player()
	if local == null or (link.a != local and link.b != local):
		return
	for w in link.wraps:
		var body: Node = w["body"]
		if not is_instance_valid(body):
			continue
		if body.is_in_group("titan") and link.tension > 0.45:
			var key: String = body.get_meta("key", "")
			var strain: float = float(_strain.get(key, 0.0)) + delta
			if strain >= 1.2:
				strain = -4.0
				_game.request_topple(key)
			_strain[key] = strain
		elif body.is_in_group("monolith") and link.tension > 0.2:
			var mkey: String = body.get_meta("key", "")
			var idx: int = body.get_meta("idx", 0)
			var id := "%s:%d" % [mkey, idx]
			if float(_ring_cooldown.get(id, 0.0)) <= 0.0:
				_ring_cooldown[id] = 2.5
				_game.request_ring(mkey, idx)


# ------------------------------------------------------------ Verlet rope

func _simulate(link: Link, a: Vector3, b: Vector3, delta: float) -> void:
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	# Start over when the cable is new or an end jumped (respawn, boarding, or
	# the Ark switching between its deck and keel attachment).
	if link.pts.size() != POINTS or link.pts[0].distance_to(a) > 3.0 or link.pts[POINTS - 1].distance_to(b) > 3.0:
		_reset_rope(link, a, b, space)

	# The spool keeps only a little slack paid out, like a retracting leash,
	# so a loose cable sags and drapes instead of piling up.
	var rope_len := clampf(link.path_len * slack_ratio + 1.0, link.path_len, maxf(link.path_len, link.rest))
	var seg := rope_len / float(POINTS - 1)
	var storm: float = _game.storm
	var gravity := Vector3(0.0, -rope_gravity, 0.0) * delta * delta
	var wind := Vector3(1.0, 0.0, 0.35) * storm * 5.0 * delta * delta

	# Cable lying on the Ark's deck rides along with it.
	if _ark_step.length_squared() > 0.000001:
		for i in range(1, POINTS - 1):
			if _ark.is_over_deck(link.pts[i] - _ark_step):
				link.pts[i] += _ark_step
				link.prev[i] += _ark_step

	# Positions at the start of the step are known to be outside geometry;
	# every collision sweep runs from there.
	var start := link.pts.duplicate()

	for i in range(1, POINTS - 1):
		var cur := link.pts[i]
		var vel := (cur - link.prev[i]) * 0.985
		link.prev[i] = cur
		link.pts[i] = cur + vel + gravity + wind

	# Pinned points: both ends, and one per wrap contact.
	# The cable plugs into the surface of a Resonator, on the side it leaves from.
	var toward_b: Vector3 = link.wraps[link.wraps.size() - 1]["pos"] if not link.wraps.is_empty() else a
	var toward_a: Vector3 = link.wraps[0]["pos"] if not link.wraps.is_empty() else b
	var pin_b := b + _body_offset(toward_b - b)
	var pin_a := a if link.is_ark else a + _body_offset(toward_a - a)
	var pins := {0: pin_a, POINTS - 1: pin_b}
	if not link.wraps.is_empty() and link.path_len > 0.01:
		var walked := 0.0
		var last := a
		for w in link.wraps:
			var wp: Vector3 = w["pos"]
			walked += last.distance_to(wp)
			last = wp
			var idx := clampi(roundi(walked / link.path_len * float(POINTS - 1)), 1, POINTS - 2)
			pins[idx] = wp

	_collide_rope(link, start, pins, space)
	for iteration in 8:
		for idx in pins.keys():
			link.pts[idx] = pins[idx]
		for i in POINTS - 1:
			var p1 := link.pts[i]
			var p2 := link.pts[i + 1]
			var d := p2 - p1
			var length := d.length()
			if length <= seg or length < 0.0001:
				continue
			var correction := d * ((length - seg) / length) * 0.5
			link.pts[i] = p1 + correction
			link.pts[i + 1] = p2 - correction
		if iteration == 3:
			_collide_rope(link, start, pins, space)
	for idx in pins.keys():
		link.pts[idx] = pins[idx]
	# Geometry always wins over length: the cable never ends a step inside the world.
	_collide_rope(link, start, pins, space)
	_avoid_bodies(link, pins)


func _body_offset(direction: Vector3) -> Vector3:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length() < 0.01:
		return Vector3.ZERO
	return flat.normalized() * BODY_RADIUS


## Keeps the cable out of every Resonator's body (a 0.42 m cylinder).
func _avoid_bodies(link: Link, pins: Dictionary) -> void:
	for node in _game.get_players():
		var body_pos: Vector3 = (node as Node3D).global_position
		for i in range(1, POINTS - 1):
			if pins.has(i):
				continue
			var p := link.pts[i]
			if p.y < body_pos.y - 0.1 or p.y > body_pos.y + 2.1:
				continue
			var flat := Vector2(p.x - body_pos.x, p.z - body_pos.z)
			var dist := flat.length()
			if dist >= BODY_RADIUS:
				continue
			if dist < 0.001:
				flat = Vector2(1, 0)
				dist = 1.0
			flat = flat / dist * BODY_RADIUS
			link.pts[i] = Vector3(body_pos.x + flat.x, p.y, body_pos.z + flat.y)


func _reset_rope(link: Link, a: Vector3, b: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	link.pts.resize(POINTS)
	link.prev.resize(POINTS)
	for i in POINTS:
		var p := a.lerp(b, float(i) / float(POINTS - 1))
		if i > 0 and i < POINTS - 1:
			# Lay the cable on top of anything the straight line would cut through.
			_rope_query.from = p + Vector3(0, 40.0, 0)
			_rope_query.to = p - Vector3(0, ROPE_RADIUS, 0)
			var hit := space.intersect_ray(_rope_query)
			if not hit.is_empty():
				p.y = float((hit["position"] as Vector3).y) + ROPE_RADIUS
		link.pts[i] = p
		link.prev[i] = p


## Sweeps every free rope point from where it started this step to where it
## wants to be. On contact the point slides along the surface and loses speed.
func _collide_rope(link: Link, start: PackedVector3Array, pins: Dictionary, space: PhysicsDirectSpaceState3D) -> void:
	for i in range(1, POINTS - 1):
		if pins.has(i):
			continue
		var from := start[i]
		var to := link.pts[i]
		var travel := to - from
		var dist := travel.length()
		if dist < 0.0005:
			continue
		_rope_query.from = from
		_rope_query.to = to + travel / dist * ROPE_RADIUS
		var hit := space.intersect_ray(_rope_query)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit["normal"]
		var contact: Vector3 = hit["position"]
		# Slide: keep the motion along the surface, remove the part going into it.
		var depth := ROPE_RADIUS - (to - contact).dot(normal)
		var resolved := to + normal * maxf(depth, 0.0)
		# The slide must not cross another surface; if it would, stop at the contact.
		_rope_query.from = contact + normal * ROPE_RADIUS
		_rope_query.to = resolved
		if not space.intersect_ray(_rope_query).is_empty():
			resolved = contact + normal * ROPE_RADIUS
		link.pts[i] = resolved
		var vel := resolved - link.prev[i]
		vel -= normal * minf(vel.dot(normal), 0.0)
		link.prev[i] = resolved - vel * (1.0 - rope_friction)


func _draw_link(link: Link, cam_pos: Vector3) -> void:
	var width := 0.13 + 0.1 * link.tension + 0.08 * charge
	link.imesh.clear_surfaces()
	link.imesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var u := 0.0
	for i in POINTS:
		var p := link.pts[i]
		if i > 0:
			u += p.distance_to(link.pts[i - 1])
		var tangent := link.pts[mini(i + 1, POINTS - 1)] - link.pts[maxi(i - 1, 0)]
		var side := tangent.cross(cam_pos - p)
		if side.length() < 0.0001:
			side = Vector3.UP
		side = side.normalized() * width
		link.imesh.surface_set_uv(Vector2(u, 0.0))
		link.imesh.surface_add_vertex(p - side)
		link.imesh.surface_set_uv(Vector2(u, 1.0))
		link.imesh.surface_add_vertex(p + side)
	link.imesh.surface_end()
	link.material.set_shader_parameter("tension", link.tension)
	link.material.set_shader_parameter("charge", charge)
