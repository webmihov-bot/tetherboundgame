extends AnimatableBody3D
## ArkBase - the hovering home base and root of the tether chain.
## Server-authoritative: the pilot's peer sends steering input, the server
## moves the Ark, and MultiplayerSynchronizer replicates its state.
##
## Clients never apply network positions directly. Packets arrive at uneven
## times, so doing that made the Ark (and everyone standing on it) stall and
## jump, out of step with the 60 Hz physics the players move on. Instead each
## client moves its Ark every physics step with the server's velocity and
## eases out the difference to the server's position over about half a second.

const CEL_SHADER: Shader = preload("res://shaders/cel_toon_pbr.gdshader")
const Fx = preload("res://scripts/Fx.gd")
const DECK_RADIUS := 9.0
const SNAP_DISTANCE := 12.0
## Collisions: share of speed bounced back, share of sliding speed lost to
## scraping, and the hit speed (m/s) that counts as a crash.
const RESTITUTION := 0.3
const SCRAPE := 0.12
const IMPACT_MIN := 2.5
const WORLD_MASK := 1
const CORRECTION_RATE := 2.5

@export var cruise_speed := 16.0
@export var climb_speed := 8.0
@export var acceleration := 1.6

# Replicated.
var pilot_id := 0
var net_position := Vector3.ZERO
var net_velocity := Vector3.ZERO

var _pilot_input := Vector3.ZERO
var _velocity := Vector3.ZERO
var _ring: MeshInstance3D
var _ring_outer: MeshInstance3D
var _lights_ring: Node3D
var _time := 0.0
var _impact_cooldown := 0.0

@onready var _visual: Node3D = $Visual


func _enter_tree() -> void:
	add_to_group("ark")


func _ready() -> void:
	if not NetworkManager.is_headless():
		_build_visual()
	NetworkManager.player_unregistered.connect(_on_player_left)
	net_position = global_position
	collision_mask = WORLD_MASK
	_add_keel_collider()


func get_spawn_point(slot: int) -> Vector3:
	var angle := TAU * float(slot) / 4.0 + PI * 0.25
	return global_position + Vector3(cos(angle) * 4.5, 0.2, sin(angle) * 4.5)


func get_helm_point() -> Vector3:
	return global_position + Vector3(0.0, 0.05, -6.6)


## Cable root: top of the pylon for players on or above the deck, the keel
## for players hanging below it.
func get_tether_point(target: Vector3) -> Vector3:
	if target.y < global_position.y - 1.0:
		return global_position + Vector3(0, -2.2, 0)
	return global_position + Vector3(0, 3.5, 0)


func is_over_deck(pos: Vector3) -> bool:
	var flat := Vector2(pos.x - global_position.x, pos.z - global_position.z)
	return flat.length() < DECK_RADIUS + 0.3 and absf(pos.y - global_position.y) < 1.2


func is_boardable_from(pos: Vector3) -> bool:
	var flat := Vector2(pos.x - global_position.x, pos.z - global_position.z)
	return flat.length() < 20.0 and pos.y < global_position.y + 1.0 and pos.y > global_position.y - 30.0


# ---------------------------------------------------------------- piloting

func request_pilot(want: bool) -> void:
	if multiplayer.is_server():
		_server_set_pilot(multiplayer.get_unique_id(), want)
	else:
		_rpc_request_pilot.rpc_id(1, want)


func send_pilot_input(steer: Vector3) -> void:
	if multiplayer.is_server():
		if pilot_id == multiplayer.get_unique_id():
			_pilot_input = steer.limit_length(1.5)
	else:
		_rpc_pilot_input.rpc_id(1, steer)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_pilot(want: bool) -> void:
	if multiplayer.is_server():
		_server_set_pilot(multiplayer.get_remote_sender_id(), want)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_pilot_input(steer: Vector3) -> void:
	if multiplayer.is_server() and multiplayer.get_remote_sender_id() == pilot_id:
		_pilot_input = steer.limit_length(1.5)


func _server_set_pilot(id: int, want: bool) -> void:
	if want and pilot_id == 0:
		pilot_id = id
	elif not want and pilot_id == id:
		pilot_id = 0
		_pilot_input = Vector3.ZERO


func _on_player_left(id: int) -> void:
	if pilot_id == id:
		pilot_id = 0
		_pilot_input = Vector3.ZERO


func _physics_process(delta: float) -> void:
	if not NetworkManager.in_session:
		return
	if not multiplayer.is_server():
		_follow_server(delta)
		return
	if pilot_id == 0:
		_pilot_input = Vector3.ZERO
	var target := Vector3(_pilot_input.x * cruise_speed, _pilot_input.y * climb_speed, _pilot_input.z * cruise_speed)
	_velocity = _velocity.lerp(target, clampf(acceleration * delta, 0.0, 1.0))
	_impact_cooldown = maxf(0.0, _impact_cooldown - delta)
	if _velocity.length() > 0.01:
		var before := _velocity
		var result := _move_with_collisions(_velocity, delta)
		_velocity = result["velocity"]
		if result.has("speed") and float(result["speed"]) > IMPACT_MIN and _impact_cooldown <= 0.0:
			_impact_cooldown = 0.35
			do_impact.rpc(result["point"], result["normal"], _velocity - before, float(result["speed"]))
	net_position = global_position
	net_velocity = _velocity


## Moves the Ark by vel * delta, stopping at terrain, pillars, spires and
## titans. On contact it slides along the surface, bounces a little and loses
## speed to scraping. Returns the new velocity and, if it hit, the hardest hit.
func _move_with_collisions(vel: Vector3, delta: float) -> Dictionary:
	var result := {}
	var motion := vel * delta
	for i in 4:
		if motion.length_squared() < 0.0000001:
			break
		var hit := move_and_collide(motion, false, 0.04)
		if hit == null:
			break
		var normal := hit.get_normal()
		var into := vel.dot(normal)
		if into < 0.0:
			if not result.has("speed") or -into > float(result["speed"]):
				result["speed"] = -into
				result["point"] = hit.get_position()
				result["normal"] = normal
			vel -= normal * into * (1.0 + RESTITUTION)
			var along := vel - normal * vel.dot(normal)
			vel -= along * SCRAPE
		motion = hit.get_remainder().slide(normal)
	result["velocity"] = vel
	return result


## Everyone sees and feels the crash: sparks, dust, sound, camera shake, and
## riders who aren't anchored get thrown by the sudden stop.
@rpc("authority", "call_local", "reliable")
func do_impact(point: Vector3, normal: Vector3, change: Vector3, speed: float) -> void:
	var game := get_tree().get_first_node_in_group("game")
	if game == null:
		return
	var k := clampf((speed - IMPACT_MIN) / 12.0, 0.0, 1.0)
	if not NetworkManager.is_headless():
		Fx.burst(game, point, Color(1.0, 0.72, 0.38), int(lerpf(16.0, 70.0, k)), lerpf(5.0, 13.0, k), 0.7, 0.22, 0.2)
		Fx.burst(game, point + normal * 0.5, Color(0.5, 0.46, 0.78), int(lerpf(10.0, 40.0, k)), 2.5, 1.4, 0.55, 0.9)
		if k > 0.35:
			Fx.shock_ring(game, point + normal * 0.3, Color(1.0, 0.8, 0.5), lerpf(3.0, 7.0, k), 0.5)
		game.sound.play_crash(k)
	var local: Node3D = game.get_local_player()
	if local != null:
		var near := local.global_position.distance_to(global_position) < DECK_RADIUS + 6.0
		local.ark_jolt(change, k, near)


func _add_keel_collider() -> void:
	# The hull under the deck, a cone like the visible keel.
	var points := PackedVector3Array()
	for i in 12:
		var angle := TAU * float(i) / 12.0
		points.append(Vector3(cos(angle) * (DECK_RADIUS - 1.5), -1.0, sin(angle) * (DECK_RADIUS - 1.5)))
		points.append(Vector3(cos(angle) * 1.2, -4.0, sin(angle) * 1.2))
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	var col := CollisionShape3D.new()
	col.name = "Keel"
	col.shape = shape
	add_child(col)


## Client side: dead reckoning plus gentle error correction.
func _follow_server(delta: float) -> void:
	# Predict with the same collisions as the server, so we never fly into a
	# rock the server already stopped at.
	if net_velocity.length() > 0.01:
		_move_with_collisions(net_velocity, delta)
	var error := net_position - global_position
	if error.length() > SNAP_DISTANCE:
		global_position = net_position
	else:
		global_position += error * minf(1.0, CORRECTION_RATE * delta)


func _process(delta: float) -> void:
	_time += delta
	if _ring != null:
		_ring.rotation.y += delta * 0.6
		_ring_outer.rotation.y -= delta * 0.35
		_ring_outer.rotation.x = 0.12 + sin(_time * 0.5) * 0.05
		_lights_ring.rotation.y += delta * 0.25
		_visual.position.y = sin(_time * 0.9) * 0.08


# ------------------------------------------------------------------ visual

func _cel(color: Color, metallic: float, roughness: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = CEL_SHADER
	mat.set_shader_parameter("albedo", color)
	mat.set_shader_parameter("metallic", metallic)
	mat.set_shader_parameter("roughness", roughness)
	mat.set_shader_parameter("rim_color", Color(0.45, 0.9, 1.0))
	mat.set_shader_parameter("rim_strength", 1.4)
	return mat


func _part(mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	_visual.add_child(mi)
	mi.position = pos
	return mi


func _build_visual() -> void:
	var hull := _cel(Color(0.24, 0.22, 0.44), 0.4, 0.5)
	var dark := _cel(Color(0.06, 0.06, 0.14), 0.8, 0.3)
	var glow := _cel(Color(0.1, 0.1, 0.12), 0.0, 0.4)
	glow.set_shader_parameter("emission", Color(0.24, 0.91, 0.96))
	glow.set_shader_parameter("emission_energy", 1.8)
	glow.set_shader_parameter("pulse_speed", 1.5)
	var gold := _cel(Color(0.2, 0.15, 0.05), 0.5, 0.3)
	gold.set_shader_parameter("emission", Color(0.95, 0.76, 0.38))
	gold.set_shader_parameter("emission_energy", 1.4)

	var deck := CylinderMesh.new()
	deck.top_radius = DECK_RADIUS
	deck.bottom_radius = DECK_RADIUS - 1.2
	deck.height = 1.0
	deck.radial_segments = 12
	_part(deck, Vector3(0, -0.5, 0), hull)

	var keel := CylinderMesh.new()
	keel.top_radius = DECK_RADIUS - 1.5
	keel.bottom_radius = 1.2
	keel.height = 3.0
	keel.radial_segments = 12
	_part(keel, Vector3(0, -2.5, 0), dark)

	var pylon := CylinderMesh.new()
	pylon.top_radius = 0.5
	pylon.bottom_radius = 1.2
	pylon.height = 3.2
	pylon.radial_segments = 6
	_part(pylon, Vector3(0, 1.6, 0), hull)
	var beacon := SphereMesh.new()
	beacon.radius = 0.45
	beacon.height = 0.9
	beacon.radial_segments = 8
	beacon.rings = 4
	_part(beacon, Vector3(0, 3.5, 0), glow)

	var ring := TorusMesh.new()
	ring.inner_radius = DECK_RADIUS + 0.7
	ring.outer_radius = DECK_RADIUS + 0.9
	ring.rings = 48
	ring.ring_segments = 6
	_ring = _part(ring, Vector3(0, -0.6, 0), glow)

	# A second, thinner ring that counter-rotates with a slow wobble.
	var outer := TorusMesh.new()
	outer.inner_radius = DECK_RADIUS + 2.3
	outer.outer_radius = DECK_RADIUS + 2.4
	outer.rings = 64
	outer.ring_segments = 4
	_ring_outer = _part(outer, Vector3(0, -0.2, 0), glow)

	# Running lights that circle the rim.
	_lights_ring = Node3D.new()
	_visual.add_child(_lights_ring)
	var lamp := BoxMesh.new()
	lamp.size = Vector3(0.35, 0.12, 0.12)
	for i in 16:
		var lamp_angle := TAU * float(i) / 16.0
		var lamp_mi := MeshInstance3D.new()
		lamp_mi.mesh = lamp
		lamp_mi.material_override = gold if i % 4 == 0 else glow
		_lights_ring.add_child(lamp_mi)
		lamp_mi.position = Vector3(cos(lamp_angle) * (DECK_RADIUS - 0.25), 0.07, sin(lamp_angle) * (DECK_RADIUS - 0.25))
		lamp_mi.rotation.y = -lamp_angle + PI * 0.5

	# Engine: a soft cone of light and a stream of sparks under the keel.
	var beam_mat := StandardMaterial3D.new()
	beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	beam_mat.albedo_color = Color(0.24, 0.91, 0.96, 0.12)
	var beam := CylinderMesh.new()
	beam.top_radius = 1.1
	beam.bottom_radius = 0.0
	beam.height = 14.0
	beam.radial_segments = 10
	beam.cap_top = false
	beam.cap_bottom = false
	var beam_mi := _part(beam, Vector3(0, -11.0, 0), beam_mat)
	beam_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var thrust := ParticleProcessMaterial.new()
	thrust.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	thrust.emission_sphere_radius = 1.0
	thrust.direction = Vector3(0, -1, 0)
	thrust.spread = 14.0
	thrust.initial_velocity_min = 4.0
	thrust.initial_velocity_max = 9.0
	thrust.gravity = Vector3.ZERO
	thrust.scale_min = 0.5
	thrust.scale_max = 1.6
	thrust.color = Color(0.35, 0.95, 1.0)
	thrust.color_ramp = Fx.fade_ramp()
	var sparks := Fx.particles(90, 1.6, Vector2(0.28, 0.28), thrust)
	_visual.add_child(sparks)
	sparks.position = Vector3(0, -4.0, 0)

	# Helm pedestal at the bow (-Z) and four gold tether ports.
	var helm := BoxMesh.new()
	helm.size = Vector3(1.4, 1.1, 0.5)
	_part(helm, Vector3(0, 0.55, -7.6), dark)
	var helm_light := BoxMesh.new()
	helm_light.size = Vector3(1.2, 0.08, 0.3)
	_part(helm_light, Vector3(0, 1.14, -7.6), gold)
	var port := BoxMesh.new()
	port.size = Vector3(0.5, 0.12, 0.5)
	for i in 4:
		var angle := TAU * float(i) / 4.0 + PI * 0.25
		_part(port, Vector3(cos(angle) * 4.5, 0.06, sin(angle) * 4.5), gold)

	var engine := OmniLight3D.new()
	engine.light_color = Color(0.24, 0.91, 0.96)
	engine.light_energy = 6.0
	engine.omni_range = 26.0
	engine.light_volumetric_fog_energy = 0.0
	_visual.add_child(engine)
	engine.position = Vector3(0, -4.5, 0)
	var deck_light := OmniLight3D.new()
	deck_light.light_color = Color(0.7, 0.75, 1.0)
	deck_light.light_energy = 4.0
	deck_light.omni_range = 18.0
	deck_light.light_volumetric_fog_energy = 0.0
	_visual.add_child(deck_light)
	deck_light.position = Vector3(0, 4.5, 0)
