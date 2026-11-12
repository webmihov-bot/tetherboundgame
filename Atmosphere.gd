extends Node3D
## Atmosphere - everything that makes the Drift feel alive but has no gameplay:
## the animated storm sky, post-processing, drifting energy motes, storm wind
## streaks, and a slowly turning belt of colossal debris on the horizon.
## Created by Main at startup; never exists on a headless server.

const Fx = preload("res://scripts/Fx.gd")
const SKY_SHADER: Shader = preload("res://shaders/drift_sky.gdshader")
const CEL_SHADER: Shader = preload("res://shaders/cel_toon_pbr.gdshader")
const WIND := Vector3(1.0, 0.05, 0.35)

var _game: Node
var _sky_material: ShaderMaterial
var _motes: GPUParticles3D
var _motes_process: ParticleProcessMaterial
var _streaks: GPUParticles3D
var _embers: GPUParticles3D
var _belt: Node3D
var _storm := -1.0


func _ready() -> void:
	_game = get_tree().get_first_node_in_group("game")
	_setup_environment()
	_build_motes()
	_build_streaks()
	_build_embers()
	_build_belt()


func _setup_environment() -> void:
	if _game == null:
		return
	var env: Environment = _game.world_environment.environment
	if env == null:
		return
	_sky_material = ShaderMaterial.new()
	_sky_material.shader = SKY_SHADER
	var sky := Sky.new()
	sky.sky_material = _sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	env.sky = sky

	# Depth and contact shadows.
	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.ssao_intensity = 2.2
	env.ssao_power = 1.6
	# Distant islands sink into the night instead of popping in.
	env.fog_enabled = true
	env.fog_light_color = Color(0.07, 0.05, 0.18)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.15
	env.fog_density = 0.0011
	env.fog_aerial_perspective = 0.7
	env.fog_sky_affect = 0.0
	env.volumetric_fog_sky_affect = 0.0
	# A little more punch.
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.18
	env.adjustment_contrast = 1.06


func _build_motes() -> void:
	_motes_process = ParticleProcessMaterial.new()
	_motes_process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_motes_process.emission_box_extents = Vector3(48, 22, 48)
	_motes_process.direction = WIND
	_motes_process.spread = 35.0
	_motes_process.initial_velocity_min = 0.4
	_motes_process.initial_velocity_max = 2.0
	_motes_process.gravity = Vector3(0, 0.15, 0)
	_motes_process.scale_min = 0.4
	_motes_process.scale_max = 1.5
	_motes_process.turbulence_enabled = true
	_motes_process.turbulence_noise_strength = 1.2
	_motes_process.turbulence_noise_scale = 3.0
	_motes_process.turbulence_influence_min = 0.05
	_motes_process.turbulence_influence_max = 0.2
	_motes_process.color_ramp = Fx.fade_ramp()
	_motes_process.color_initial_ramp = Fx.ramp([Color(0.3, 0.95, 1.0), Color(0.65, 0.5, 1.0), Color(1.0, 0.82, 0.45), Color(0.3, 0.95, 1.0)])
	_motes = Fx.particles(700, 9.0, Vector2(0.2, 0.2), _motes_process)
	_motes.visibility_aabb = AABB(Vector3(-80, -50, -80), Vector3(160, 100, 160))
	add_child(_motes)


func _build_streaks() -> void:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(60, 26, 60)
	process.direction = WIND
	process.spread = 4.0
	process.initial_velocity_min = 34.0
	process.initial_velocity_max = 60.0
	process.gravity = Vector3.ZERO
	process.color = Color(0.7, 0.6, 1.0, 0.5)
	process.color_ramp = Fx.fade_ramp()
	_streaks = Fx.particles(220, 1.5, Vector2(0.05, 3.2), process, Fx.streak_material())
	_streaks.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Y_TO_VELOCITY
	_streaks.visibility_aabb = AABB(Vector3(-140, -60, -140), Vector3(280, 120, 280))
	add_child(_streaks)


## Sparks rising out of the abyss far below.
func _build_embers() -> void:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(130, 4, 130)
	process.direction = Vector3(0.15, 1, 0.05)
	process.spread = 12.0
	process.initial_velocity_min = 3.0
	process.initial_velocity_max = 8.0
	process.gravity = Vector3.ZERO
	process.scale_min = 0.6
	process.scale_max = 2.4
	process.color_ramp = Fx.fade_ramp()
	process.color_initial_ramp = Fx.ramp([Color(0.55, 0.35, 1.0), Color(0.25, 0.8, 1.0)])
	_embers = Fx.particles(260, 14.0, Vector2(0.45, 0.45), process)
	_embers.visibility_aabb = AABB(Vector3(-160, -20, -160), Vector3(320, 160, 320))
	add_child(_embers)


## A ring of colossal rocks and broken monolith slabs far beyond the islands.
func _build_belt() -> void:
	_belt = Node3D.new()
	add_child(_belt)
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var rock_mat := ShaderMaterial.new()
	rock_mat.shader = CEL_SHADER
	rock_mat.set_shader_parameter("albedo", Color(0.05, 0.04, 0.11))
	rock_mat.set_shader_parameter("metallic", 0.3)
	rock_mat.set_shader_parameter("roughness", 0.6)
	rock_mat.set_shader_parameter("rim_color", Color(0.6, 0.45, 1.0))
	rock_mat.set_shader_parameter("rim_strength", 1.2)
	rock_mat.set_shader_parameter("fresnel_glow", 0.35)
	rock_mat.set_shader_parameter("spec_strength", 0.0)
	var slab_mat := rock_mat.duplicate() as ShaderMaterial
	slab_mat.set_shader_parameter("albedo", Color(0.03, 0.03, 0.08))
	slab_mat.set_shader_parameter("metallic", 0.85)
	slab_mat.set_shader_parameter("roughness", 0.2)
	slab_mat.set_shader_parameter("fresnel_glow", 0.8)

	var rock := SphereMesh.new()
	rock.radius = 1.0
	rock.height = 1.6
	rock.radial_segments = 6
	rock.rings = 3
	var rocks := MultiMesh.new()
	rocks.transform_format = MultiMesh.TRANSFORM_3D
	rocks.mesh = rock
	rocks.instance_count = 80
	for i in rocks.instance_count:
		var angle := rng.randf() * TAU
		var dist := rng.randf_range(430.0, 900.0)
		var size := rng.randf_range(5.0, 34.0)
		var b := Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU))
		b = b.scaled(Vector3(size * rng.randf_range(0.7, 1.6), size, size * rng.randf_range(0.7, 1.6)))
		rocks.set_instance_transform(i, Transform3D(b, Vector3(cos(angle) * dist, rng.randf_range(-160.0, 240.0), sin(angle) * dist)))
	_add_belt_layer(rocks, rock_mat)

	var slab := BoxMesh.new()
	slab.size = Vector3(1, 1, 1)
	var slabs := MultiMesh.new()
	slabs.transform_format = MultiMesh.TRANSFORM_3D
	slabs.mesh = slab
	slabs.instance_count = 14
	for i in slabs.instance_count:
		var angle := TAU * float(i) / float(slabs.instance_count) + rng.randf_range(-0.15, 0.15)
		var dist := rng.randf_range(620.0, 980.0)
		var b := Basis.from_euler(Vector3(rng.randf_range(-0.5, 0.5), rng.randf() * TAU, rng.randf_range(-0.5, 0.5)))
		b = b.scaled(Vector3(rng.randf_range(22.0, 40.0), rng.randf_range(160.0, 340.0), rng.randf_range(22.0, 40.0)))
		slabs.set_instance_transform(i, Transform3D(b, Vector3(cos(angle) * dist, rng.randf_range(-120.0, 120.0), sin(angle) * dist)))
	_add_belt_layer(slabs, slab_mat)


func _add_belt_layer(multimesh: MultiMesh, material: Material) -> void:
	var node := MultiMeshInstance3D.new()
	node.multimesh = multimesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.custom_aabb = AABB(Vector3(-1100, -500, -1100), Vector3(2200, 1000, 2200))
	_belt.add_child(node)


func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var focus := cam.global_position
	_motes.global_position = focus
	_streaks.global_position = focus - WIND.normalized() * 40.0
	_embers.global_position = Vector3(focus.x, focus.y - 70.0, focus.z)
	_belt.global_position = Vector3(focus.x, 0.0, focus.z)
	_belt.rotation.y += delta * 0.004

	var storm := 0.2
	if _game != null:
		storm = float(_game.storm)
	if absf(storm - _storm) > 0.01:
		_storm = storm
		if _sky_material != null:
			_sky_material.set_shader_parameter("storm", storm)
		_motes_process.initial_velocity_min = 0.4 + storm * 4.0
		_motes_process.initial_velocity_max = 2.0 + storm * 9.0
		_streaks.amount_ratio = clampf((storm - 0.2) / 0.6, 0.02, 1.0)
