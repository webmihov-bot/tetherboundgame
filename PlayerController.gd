extends CharacterBody3D
## PlayerController - a Resonator.
## Third-person spring-arm camera, snappy movement, jump, dash, magnetic
## anchor (hold on the ground to lock, press in the air to slam down), reel
## in/out, Ark helm, and a fully procedural body + animation + scarf.
##
## Authority: each peer simulates its own Resonator and replicates position,
## velocity, anchor state, facing, reel and tension to everyone else.

const CEL_SHADER: Shader = preload("res://shaders/cel_toon_pbr.gdshader")
const Fx = preload("res://scripts/Fx.gd")

@export var walk_speed := 9.5
@export var ground_accel := 70.0
@export var air_accel := 22.0
@export var jump_velocity := 12.0
@export var gravity := 28.0
@export var low_gravity_scale := 0.5
@export var dash_speed := 22.0
@export var catapult_power := 30.0
@export var mouse_sensitivity := 0.0028

# Replicated by MultiplayerSynchronizer.
var anchored := false
var piloting := false
var visual_yaw := 0.0
var reel := 1.0
var tension := 0.0
## Network position. On the Ark it is relative to the deck, so every peer
## draws riders glued to its own (smoothly moving) Ark.
var net_pos := Vector3.ZERO
var net_local := Vector3.ZERO
var net_on_ark := false

var prompt := ""
var anchor_overload := 0.0
var anchor_cooldown := 0.0
var dash_cooldown := 0.0

var _peer_id := 1
var _coyote := 0.0
var _on_ark := false
var _remote_on_ark := false
var _remote_placed := false
var _shake := 0.0
var _last_ark_pos := Vector3.ZERO
var _pilot_grace := 0.0
var _collect_cooldown := 0.0
var _anim_phase := 0.0
var _time := 0.0
var _spawned := false
var _game: Node
var _ark: Node3D
var _world: Node3D
var _tether: Node3D
var _sound: Node

var _torso: MeshInstance3D
var _head: Node3D
var _arm_l: Node3D
var _arm_r: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _anchor_fx: Node3D
var _body_mats: Array[ShaderMaterial] = []
var _accent_mats: Array[ShaderMaterial] = []
var _scarf_mesh: ImmediateMesh
var _scarf_mat: StandardMaterial3D
var _scarf_pts: PackedVector3Array = PackedVector3Array()
var _label: Label3D
var _halo: MeshInstance3D
var _glow_light: OmniLight3D
var _trail: GPUParticles3D
var _trail_process: ParticleProcessMaterial
var _accent := Color(0.4, 0.9, 1.0)
var _fx_was_air := false
var _fx_was_anchored := false
var _fx_fall_speed := 0.0
var _fx_prev_speed := 0.0

@onready var _visual: Node3D = $Visual
@onready var _pivot: Node3D = $CameraPivot
@onready var _arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var _camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D


func _enter_tree() -> void:
	_peer_id = str(name).to_int()
	set_multiplayer_authority(_peer_id)


func _ready() -> void:
	add_to_group("players")
	_resolve_refs()
	if not NetworkManager.is_headless():
		_build_visual()
		_apply_identity()
	NetworkManager.lobby_changed.connect(_apply_identity)
	if is_multiplayer_authority():
		_arm.rotation.x = -0.3
		_camera.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		respawn()
		_spawned = true
	else:
		_camera.current = false


func _exit_tree() -> void:
	if is_multiplayer_authority() and not NetworkManager.is_headless():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _resolve_refs() -> void:
	_game = get_tree().get_first_node_in_group("game")
	if _game != null:
		_ark = _game.ark
		_world = _game.world
		_tether = _game.tether
		_sound = _game.sound


func get_peer_id() -> int:
	return _peer_id


func chest_position() -> Vector3:
	return global_position + Vector3(0, 1.1, 0)


func _publish_network() -> void:
	net_pos = global_position
	net_on_ark = _on_ark or piloting
	net_local = global_position - _ark.global_position


## Remote Resonators: ride our Ark when they are on it, and glide toward
## each network update instead of jumping to it.
func _follow_network(delta: float) -> void:
	if _ark == null:
		_resolve_refs()
		if _ark == null:
			return
	var ark_now := _ark.global_position
	if net_on_ark and _remote_on_ark:
		global_position += ark_now - _last_ark_pos
	_last_ark_pos = ark_now
	_remote_on_ark = net_on_ark
	var target := ark_now + net_local if net_on_ark else net_pos
	if not _remote_placed:
		if net_pos == Vector3.ZERO and not net_on_ark:
			return
		global_position = target
		_remote_placed = true
		return
	var gap := target - global_position
	if gap.length() > 8.0:
		global_position = target
	else:
		global_position += gap * minf(1.0, delta * 16.0)


## Called when the Ark crashes. change = how much the Ark's velocity changed.
func ark_jolt(change: Vector3, strength: float, near: bool) -> void:
	if not near:
		return
	_shake = maxf(_shake, 0.3 + strength * 0.9)
	if _on_ark and not anchored and not piloting:
		# Inertia: the Ark stops, you keep going. Anchor to stay put.
		velocity -= change * 0.8
		velocity.y += 1.5 + strength * 4.0


func respawn() -> void:
	if _ark == null:
		return
	global_position = _ark.get_spawn_point(NetworkManager.get_slot(_peer_id))
	velocity = Vector3.ZERO
	anchored = false
	piloting = false
	reel = 1.0
	_on_ark = true
	_last_ark_pos = _ark.global_position
	_scarf_pts = PackedVector3Array()


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_pivot.rotation.y -= motion.relative.x * mouse_sensitivity
		_arm.rotation.x = clampf(_arm.rotation.x - motion.relative.y * mouse_sensitivity, -1.35, 0.9)
	elif event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).physical_keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ---------------------------------------------------------------- physics

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		_follow_network(delta)
		return
	if not _spawned:
		return
	if _game == null or _ark == null or not NetworkManager.in_session:
		return
	_publish_network()
	_time += delta
	anchor_cooldown = maxf(0.0, anchor_cooldown - delta)
	dash_cooldown = maxf(0.0, dash_cooldown - delta)
	_collect_cooldown = maxf(0.0, _collect_cooldown - delta)

	var active := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var input := Vector2.ZERO
	if active:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish := Basis(Vector3.UP, _pivot.rotation.y) * Vector3(input.x, 0.0, input.y)

	_update_interaction(active, delta)
	if piloting:
		_pilot(wish, active, delta)
		return

	# Ride the Ark while standing on its deck.
	if _on_ark:
		global_position += _ark.global_position - _last_ark_pos
	_last_ark_pos = _ark.global_position

	if active:
		if Input.is_action_pressed("reel_in"):
			reel = maxf(0.35, reel - 0.6 * delta)
		if Input.is_action_pressed("reel_out"):
			reel = minf(1.6, reel + 0.6 * delta)

	var grav := gravity
	if _world.get_biome_at(global_position) == 0:
		grav *= low_gravity_scale
	var on_floor := is_on_floor()
	_coyote = 0.12 if on_floor else maxf(0.0, _coyote - delta)

	var was_anchored := anchored
	var want_anchor := active and Input.is_action_pressed("anchor") and anchor_cooldown <= 0.0
	if want_anchor and on_floor:
		anchored = true
	elif want_anchor:
		# Magnetic slam: dive straight down, lock on landing.
		anchored = false
		velocity.y = minf(velocity.y, -42.0)
		velocity.x = move_toward(velocity.x, 0.0, 60.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 60.0 * delta)
	else:
		anchored = false
	if anchored and not was_anchored:
		_sound.play_clunk()

	if anchored:
		velocity = Vector3.ZERO
	else:
		if not on_floor:
			velocity.y -= grav * delta
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		if on_floor:
			horizontal = horizontal.move_toward(wish * walk_speed, ground_accel * delta)
		else:
			if wish.length() > 0.01:
				var limit := maxf(horizontal.length(), walk_speed)
				horizontal += wish * air_accel * delta
				if horizontal.length() > limit:
					horizontal = horizontal.normalized() * limit
			horizontal *= 1.0 - 0.12 * delta
		velocity.x = horizontal.x
		velocity.z = horizontal.z

		if active and Input.is_action_just_pressed("jump"):
			if _coyote > 0.0:
				velocity.y = jump_velocity
				_coyote = 0.0
			if tension > 0.3:
				# Catapult: release the stored cable energy.
				var pull: Vector3 = _tether.pull_direction(self)
				velocity += pull * tension * catapult_power * (1.0 + float(_tether.charge)) + Vector3.UP * 3.0
				_sound.play_chime(24, 0.25)
		if active and Input.is_action_just_pressed("dash") and dash_cooldown <= 0.0:
			var dash_dir := wish
			if dash_dir.length() < 0.1:
				dash_dir = Basis(Vector3.UP, visual_yaw) * Vector3.FORWARD
			velocity += dash_dir.normalized() * dash_speed
			dash_cooldown = 1.1

	_tether.solve_for(self, delta)

	# A locked anchor fails if the cable stays critical for too long.
	if anchored and tension > 0.9:
		anchor_overload += delta
		if anchor_overload > 2.2:
			anchored = false
			anchor_cooldown = 2.5
			anchor_overload = 0.0
			_game.hud.flash("ANCHOR OVERLOAD", Color(1.0, 0.3, 0.37))
			_sound.play_thunder()
	else:
		anchor_overload = maxf(0.0, anchor_overload - delta * 0.7)

	var was_on_ark := _on_ark
	move_and_slide()
	_on_ark = is_on_floor() and _ark.is_over_deck(global_position)
	# The deck is solid. If a network correction or a sharp Ark move leaves us
	# inside it, put us back on top instead of letting us drop through.
	if was_on_ark and not _on_ark and velocity.y <= 0.5:
		var below := _ark.global_position.y - global_position.y
		var flat := Vector2(global_position.x - _ark.global_position.x, global_position.z - _ark.global_position.z)
		if below > 0.02 and below < 1.6 and flat.length() < _ark.DECK_RADIUS - 0.2:
			global_position.y = _ark.global_position.y + 0.02
			velocity.y = 0.0
			_on_ark = true

	var flat := Vector3(velocity.x, 0.0, velocity.z)
	if flat.length() > 0.8:
		visual_yaw = atan2(-flat.x, -flat.z)

	if _collect_cooldown <= 0.0:
		var core_key: String = _world.core_near(chest_position(), 2.8)
		if core_key != "":
			_collect_cooldown = 1.0
			_game.request_collect(core_key)

	if global_position.y < _ark.global_position.y - 170.0:
		_game.hud.flash("LOST TO THE DRIFT  ·  RECALLED", Color(1.0, 0.3, 0.37))
		respawn()


func _update_interaction(active: bool, delta: float) -> void:
	prompt = ""
	var pressed := active and Input.is_action_just_pressed("interact")
	_pilot_grace = maxf(0.0, _pilot_grace - delta)
	if piloting:
		prompt = "F   Leave the helm"
		var taken_by_other: bool = _pilot_grace <= 0.0 and int(_ark.pilot_id) != _peer_id
		if pressed or taken_by_other:
			piloting = false
			_ark.request_pilot(false)
		return
	var helm: Vector3 = _ark.get_helm_point()
	if global_position.distance_to(helm) < 2.8 and int(_ark.pilot_id) == 0:
		prompt = "F   Take the helm"
		if pressed:
			piloting = true
			anchored = false
			_pilot_grace = 1.0
			_ark.request_pilot(true)
	elif not _on_ark and _ark.is_boardable_from(global_position):
		prompt = "F   Board the Ark"
		if pressed:
			respawn()


func _pilot(wish: Vector3, active: bool, delta: float) -> void:
	var steer := wish
	if active:
		steer.y = Input.get_action_strength("jump") - Input.get_action_strength("dash")
	_ark.send_pilot_input(steer)
	global_position = _ark.get_helm_point()
	velocity = Vector3.ZERO
	_on_ark = true
	_last_ark_pos = _ark.global_position
	_tether.solve_for(self, delta)
	if wish.length() > 0.1:
		visual_yaw = atan2(-wish.x, -wish.z)


# -------------------------------------------------- procedural body + anim

func _cel(color: Color, metallic: float, roughness: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = CEL_SHADER
	mat.set_shader_parameter("albedo", color)
	mat.set_shader_parameter("metallic", metallic)
	mat.set_shader_parameter("roughness", roughness)
	mat.set_shader_parameter("rim_strength", 1.6)
	return mat


func _part(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	parent.add_child(mi)
	mi.position = pos
	return mi


func _limb(pos: Vector3, length: float, radius: float, mat: Material) -> Node3D:
	var joint := Node3D.new()
	_visual.add_child(joint)
	joint.position = pos
	var capsule := CapsuleMesh.new()
	capsule.radius = radius
	capsule.height = length
	capsule.radial_segments = 6
	capsule.rings = 2
	_part(joint, capsule, Vector3(0, -length * 0.5, 0), mat)
	return joint


func _build_visual() -> void:
	var body := _cel(Color(0.11, 0.10, 0.24), 0.6, 0.35)
	var accent := _cel(Color(0.1, 0.1, 0.12), 0.0, 0.4)
	_body_mats.append(body)
	_accent_mats.append(accent)

	var torso := CylinderMesh.new()
	torso.top_radius = 0.34
	torso.bottom_radius = 0.2
	torso.height = 0.78
	torso.radial_segments = 6
	_torso = _part(_visual, torso, Vector3(0, 1.08, 0), body)

	_head = Node3D.new()
	_visual.add_child(_head)
	_head.position = Vector3(0, 1.82, 0)
	var mask := SphereMesh.new()
	mask.radius = 0.27
	mask.height = 0.66
	mask.radial_segments = 4
	mask.rings = 2
	var mask_mi := _part(_head, mask, Vector3.ZERO, body)
	mask_mi.rotation.y = PI * 0.25
	var eye := BoxMesh.new()
	eye.size = Vector3(0.1, 0.035, 0.03)
	_part(_head, eye, Vector3(-0.085, 0.02, -0.19), accent)
	_part(_head, eye, Vector3(0.085, 0.02, -0.19), accent)

	var port := SphereMesh.new()
	port.radius = 0.09
	port.height = 0.18
	port.radial_segments = 8
	port.rings = 4
	_part(_visual, port, Vector3(0, 1.12, -0.24), accent)

	# Halo ring floating behind the mask, in the player's colour.
	var halo := TorusMesh.new()
	halo.inner_radius = 0.31
	halo.outer_radius = 0.33
	halo.rings = 28
	halo.ring_segments = 4
	_halo = _part(_head, halo, Vector3(0, 0.02, 0.16), accent)
	_halo.rotation.x = PI * 0.5
	# Shoulder plates.
	var plate := BoxMesh.new()
	plate.size = Vector3(0.24, 0.09, 0.3)
	_part(_visual, plate, Vector3(-0.44, 1.47, 0), body).rotation.z = 0.25
	_part(_visual, plate, Vector3(0.44, 1.47, 0), body).rotation.z = -0.25
	var belt := TorusMesh.new()
	belt.inner_radius = 0.2
	belt.outer_radius = 0.235
	belt.rings = 16
	belt.ring_segments = 4
	_part(_visual, belt, Vector3(0, 0.74, 0), accent)

	# Each Resonator carries a small light and leaves sparks when moving fast.
	_glow_light = OmniLight3D.new()
	_glow_light.light_energy = 1.2
	_glow_light.omni_range = 5.5
	_glow_light.light_volumetric_fog_energy = 0.0
	add_child(_glow_light)
	_glow_light.position = Vector3(0, 1.2, 0)
	_trail_process = ParticleProcessMaterial.new()
	_trail_process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_trail_process.emission_sphere_radius = 0.35
	_trail_process.direction = Vector3(0, 1, 0)
	_trail_process.spread = 180.0
	_trail_process.initial_velocity_min = 0.2
	_trail_process.initial_velocity_max = 1.2
	_trail_process.gravity = Vector3(0, -1.0, 0)
	_trail_process.scale_min = 0.4
	_trail_process.scale_max = 1.2
	_trail_process.color_ramp = Fx.ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	_trail = Fx.particles(48, 0.7, Vector2(0.16, 0.16), _trail_process)
	_trail.emitting = false
	add_child(_trail)
	_trail.position = Vector3(0, 0.9, 0)

	_arm_l = _limb(Vector3(-0.43, 1.4, 0), 0.62, 0.07, body)
	_arm_r = _limb(Vector3(0.43, 1.4, 0), 0.62, 0.07, body)
	_leg_l = _limb(Vector3(-0.14, 0.7, 0), 0.7, 0.085, body)
	_leg_r = _limb(Vector3(0.14, 0.7, 0), 0.7, 0.085, body)

	# Magnetic anchor: ground ring + spike, shown while locked.
	_anchor_fx = Node3D.new()
	_visual.add_child(_anchor_fx)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.55
	ring.outer_radius = 0.68
	ring.rings = 20
	ring.ring_segments = 6
	_part(_anchor_fx, ring, Vector3(0, 0.04, 0), accent)
	var spike := CylinderMesh.new()
	spike.top_radius = 0.05
	spike.bottom_radius = 0.01
	spike.height = 0.9
	spike.radial_segments = 5
	_part(_anchor_fx, spike, Vector3(0, 0.3, 0.25), accent)
	_anchor_fx.visible = false

	# Scarf ribbon, drawn in world space.
	_scarf_mesh = ImmediateMesh.new()
	_scarf_mat = StandardMaterial3D.new()
	_scarf_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_scarf_mat.roughness = 0.9
	_scarf_mat.emission_enabled = true
	_scarf_mat.emission_energy_multiplier = 0.7
	var scarf := MeshInstance3D.new()
	scarf.mesh = _scarf_mesh
	scarf.material_override = _scarf_mat
	scarf.top_level = true
	scarf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(scarf)
	scarf.global_transform = Transform3D.IDENTITY

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 40
	_label.pixel_size = 0.006
	_label.outline_size = 10
	_label.no_depth_test = true
	add_child(_label)
	_label.position = Vector3(0, 2.55, 0)
	_label.visible = not is_multiplayer_authority()


func _apply_identity() -> void:
	if _scarf_mat == null:
		return
	var color: Color = NetworkManager.get_color(_peer_id)
	_scarf_mat.albedo_color = color
	_scarf_mat.emission = color
	for mat in _accent_mats:
		mat.set_shader_parameter("emission", color.lerp(Color(0.6, 0.95, 1.0), 0.25))
		mat.set_shader_parameter("emission_energy", 3.0)
	for mat in _body_mats:
		mat.set_shader_parameter("rim_color", color.lerp(Color(0.5, 0.9, 1.0), 0.4))
	_accent = color
	_glow_light.light_color = color.lerp(Color(1, 1, 1), 0.3)
	_trail_process.color = color.lerp(Color(1, 1, 1), 0.35)
	_label.text = NetworkManager.get_player_name(_peer_id)
	_label.modulate = color


func _process(delta: float) -> void:
	if _torso == null:
		return
	_visual.rotation.y = lerp_angle(_visual.rotation.y, visual_yaw, clampf(delta * 14.0, 0.0, 1.0))
	var flat_speed := Vector2(velocity.x, velocity.z).length()
	var airborne := absf(velocity.y) > 1.5 and not anchored and not piloting
	var run := clampf(flat_speed / walk_speed, 0.0, 1.5)
	_anim_phase += delta * (4.0 + flat_speed * 1.1)
	var swing := sin(_anim_phase) * 0.9 * minf(run, 1.0)
	var t := Time.get_ticks_msec() * 0.001

	var crouch := 0.0
	if anchored:
		crouch = 0.22
	elif piloting:
		crouch = 0.05
	_torso.position.y = lerpf(_torso.position.y, 1.08 - crouch, delta * 12.0)
	_torso.rotation.x = lerpf(_torso.rotation.x, -0.25 * minf(run, 1.2) - (0.3 if anchored else 0.0), delta * 10.0)
	_head.position.y = lerpf(_head.position.y, 1.82 - crouch + sin(t * 2.1 + float(_peer_id)) * 0.05, delta * 10.0)
	_head.rotation.z = sin(t * 1.3) * 0.05

	if airborne:
		_arm_l.rotation = _arm_l.rotation.lerp(Vector3(-2.4, 0, -0.5), delta * 10.0)
		_arm_r.rotation = _arm_r.rotation.lerp(Vector3(-2.4, 0, 0.5), delta * 10.0)
		_leg_l.rotation = _leg_l.rotation.lerp(Vector3(0.5, 0, 0), delta * 10.0)
		_leg_r.rotation = _leg_r.rotation.lerp(Vector3(-0.3, 0, 0), delta * 10.0)
	elif anchored:
		_arm_l.rotation = _arm_l.rotation.lerp(Vector3(-0.9, 0, -0.9), delta * 12.0)
		_arm_r.rotation = _arm_r.rotation.lerp(Vector3(-0.9, 0, 0.9), delta * 12.0)
		_leg_l.rotation = _leg_l.rotation.lerp(Vector3(0.0, 0, -0.45), delta * 12.0)
		_leg_r.rotation = _leg_r.rotation.lerp(Vector3(0.0, 0, 0.45), delta * 12.0)
	else:
		var idle := sin(t * 1.6) * 0.05
		_arm_l.rotation = _arm_l.rotation.lerp(Vector3(-swing, 0, -0.12 - idle), delta * 16.0)
		_arm_r.rotation = _arm_r.rotation.lerp(Vector3(swing, 0, 0.12 + idle), delta * 16.0)
		_leg_l.rotation = _leg_l.rotation.lerp(Vector3(swing, 0, 0), delta * 16.0)
		_leg_r.rotation = _leg_r.rotation.lerp(Vector3(-swing, 0, 0), delta * 16.0)

	# Effects driven by replicated state, so every peer sees them.
	_halo.rotation.z += delta * 2.2
	_halo.position.y = 0.02 + sin(t * 2.4) * 0.03
	if airborne:
		_fx_fall_speed = minf(_fx_fall_speed, velocity.y)
	elif _fx_was_air:
		if _fx_fall_speed < -6.0:
			Fx.burst(_game, global_position + Vector3(0, 0.15, 0), Color(0.75, 0.7, 1.0, 0.8), 18, 4.0, 0.5, 0.2, 0.7)
		if _fx_fall_speed < -30.0:
			Fx.shock_ring(_game, global_position + Vector3(0, 0.1, 0), _accent, 5.0, 0.5)
		_fx_fall_speed = 0.0
	_fx_was_air = airborne
	if anchored and not _fx_was_anchored:
		Fx.shock_ring(_game, global_position + Vector3(0, 0.1, 0), _accent, 3.2, 0.4)
		Fx.burst(_game, global_position + Vector3(0, 0.2, 0), _accent, 22, 6.0, 0.6, 0.18, 0.4)
	_fx_was_anchored = anchored
	if flat_speed - _fx_prev_speed > 9.0:
		Fx.burst(_game, global_position + Vector3(0, 1.0, 0), _accent, 26, 7.0, 0.5, 0.2, 0.0)
	_fx_prev_speed = flat_speed
	_trail.emitting = flat_speed > 13.0 or velocity.length() > 20.0
	if is_multiplayer_authority():
		var kick := clampf((velocity.length() - walk_speed) / 26.0, 0.0, 1.0)
		_camera.fov = lerpf(_camera.fov, 78.0 + kick * 16.0, clampf(delta * 4.0, 0.0, 1.0))
		if _shake > 0.001:
			var amount := _shake * _shake * 0.35
			_camera.h_offset = randf_range(-amount, amount)
			_camera.v_offset = randf_range(-amount, amount)
			_shake = maxf(0.0, _shake - delta * 1.6)
		else:
			_camera.h_offset = 0.0
			_camera.v_offset = 0.0

	_anchor_fx.visible = anchored
	if anchored:
		_anchor_fx.rotation.y += delta * 6.0
	_update_scarf(delta)


func _update_scarf(delta: float) -> void:
	const COUNT := 9
	const SEGMENT := 0.2
	var back := Basis(Vector3.UP, _visual.rotation.y) * Vector3.BACK
	var root := global_position + Vector3(0, 1.5, 0) + back * 0.2
	if _scarf_pts.size() != COUNT or _scarf_pts[0].distance_to(root) > 6.0:
		_scarf_pts.resize(COUNT)
		for i in COUNT:
			_scarf_pts[i] = root + back * SEGMENT * float(i)
	var storm := 0.2
	if _game != null:
		storm = float(_game.storm)
	var t := Time.get_ticks_msec() * 0.001
	var wind := Vector3(1.0, 0.0, 0.35).normalized() * (1.5 + storm * 6.0)
	_scarf_pts[0] = root
	for i in range(1, COUNT):
		var p := _scarf_pts[i]
		var flutter := Vector3(0, sin(t * 7.0 + float(i) * 0.9) * 0.8, cos(t * 5.0 + float(i) * 1.3) * 0.5)
		p += (wind + flutter + Vector3(0, -1.2, 0) + back * 1.5) * delta
		var prev := _scarf_pts[i - 1]
		var offset := p - prev
		if offset.length() > 0.0001:
			p = prev + offset.normalized() * SEGMENT
		_scarf_pts[i] = p

	_scarf_mesh.clear_surfaces()
	_scarf_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in COUNT:
		var p := _scarf_pts[i]
		var next := _scarf_pts[mini(i + 1, COUNT - 1)]
		var prev := _scarf_pts[maxi(i - 1, 0)]
		var side := (next - prev).cross(Vector3.UP)
		if side.length() < 0.001:
			side = Vector3.RIGHT
		var width := lerpf(0.2, 0.03, float(i) / float(COUNT - 1))
		side = side.normalized() * width
		_scarf_mesh.surface_set_normal(Vector3.UP)
		_scarf_mesh.surface_add_vertex(p - side)
		_scarf_mesh.surface_set_normal(Vector3.UP)
		_scarf_mesh.surface_add_vertex(p + side)
	_scarf_mesh.surface_end()
