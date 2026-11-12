extends RefCounted
## Fx - shared helpers for particles and one-shot effects.
## Use through preload:  const Fx = preload("res://scripts/Fx.gd")

static var _dot: GradientTexture2D
static var _glow_additive: StandardMaterial3D
static var _streak: StandardMaterial3D


## Soft round sprite used by every particle.
static func dot_texture() -> Texture2D:
	if _dot == null:
		var gradient := Gradient.new()
		gradient.set_color(0, Color(1, 1, 1, 1))
		gradient.set_color(1, Color(1, 1, 1, 0))
		gradient.add_point(0.35, Color(1, 1, 1, 0.45))
		_dot = GradientTexture2D.new()
		_dot.gradient = gradient
		_dot.fill = GradientTexture2D.FILL_RADIAL
		_dot.fill_from = Vector2(0.5, 0.5)
		_dot.fill_to = Vector2(1.0, 0.5)
		_dot.width = 64
		_dot.height = 64
	return _dot


static func glow_material() -> StandardMaterial3D:
	if _glow_additive == null:
		_glow_additive = _sprite_material()
		_glow_additive.albedo_texture = dot_texture()
	return _glow_additive


static func streak_material() -> StandardMaterial3D:
	if _streak == null:
		_streak = _sprite_material()
		_streak.albedo_texture = dot_texture()
	return _streak


static func _sprite_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	return mat


## Colour-over-lifetime ramp from a list of colours (evenly spaced).
static func ramp(colors: Array) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.set_color(0, colors[0])
	gradient.set_color(1, colors[colors.size() - 1])
	for i in range(1, colors.size() - 1):
		gradient.add_point(float(i) / float(colors.size() - 1), colors[i])
	var tex := GradientTexture1D.new()
	tex.gradient = gradient
	return tex


static func fade_ramp() -> GradientTexture1D:
	return ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])


static func particles(amount: int, lifetime: float, quad: Vector2, process: ParticleProcessMaterial, material: Material = null) -> GPUParticles3D:
	var node := GPUParticles3D.new()
	node.amount = amount
	node.lifetime = lifetime
	node.process_material = process
	var mesh := QuadMesh.new()
	mesh.size = quad
	mesh.material = material if material != null else glow_material()
	node.draw_pass_1 = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


## One-shot spherical burst that frees itself.
static func burst(parent: Node, pos: Vector3, color: Color, amount: int = 24, speed: float = 6.0, lifetime: float = 0.7, size: float = 0.22, up_bias: float = 0.5) -> void:
	if parent == null or not parent.is_inside_tree() or DisplayServer.get_name() == "headless":
		return
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.2
	process.direction = Vector3(0, 1, 0)
	process.spread = lerpf(180.0, 60.0, clampf(up_bias, 0.0, 1.0))
	process.initial_velocity_min = speed * 0.4
	process.initial_velocity_max = speed
	process.gravity = Vector3(0, -6.0, 0)
	process.damping_min = 2.0
	process.damping_max = 4.0
	process.scale_min = 0.5
	process.scale_max = 1.4
	process.color = color
	process.color_ramp = ramp([Color(1, 1, 1, 1), Color(1, 1, 1, 0.8), Color(1, 1, 1, 0)])
	var node := particles(amount, lifetime, Vector2(size, size), process)
	node.one_shot = true
	node.explosiveness = 0.95
	parent.add_child(node)
	node.global_position = pos
	node.emitting = true
	parent.get_tree().create_timer(lifetime + 0.6).timeout.connect(node.queue_free)


## Expanding ground ring (anchor slam, landing).
static func shock_ring(parent: Node, pos: Vector3, color: Color, radius: float = 3.5, duration: float = 0.45) -> void:
	if parent == null or not parent.is_inside_tree() or DisplayServer.get_name() == "headless":
		return
	var torus := TorusMesh.new()
	torus.inner_radius = 0.9
	torus.outer_radius = 1.0
	torus.rings = 32
	torus.ring_segments = 4
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(color.r, color.g, color.b, 0.9)
	var ring := MeshInstance3D.new()
	ring.mesh = torus
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(ring)
	ring.global_position = pos
	ring.scale = Vector3(0.3, 0.3, 0.3)
	var tween := ring.create_tween()
	tween.set_parallel(true)
	tween.tween_property(ring, "scale", Vector3(radius, 0.4, radius), duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, duration)
	tween.chain().tween_callback(ring.queue_free)


## Jagged lightning bolt between two points, with a flash of light. Frees itself.
static func bolt(parent: Node, from: Vector3, to: Vector3, color: Color) -> void:
	if parent == null or not parent.is_inside_tree() or DisplayServer.get_name() == "headless":
		return
	var points := PackedVector3Array()
	var segments := 14
	var length := from.distance_to(to)
	for i in segments + 1:
		var f := float(i) / float(segments)
		var p := from.lerp(to, f)
		if i > 0 and i < segments:
			var jitter := length * 0.035
			p += Vector3(randf_range(-jitter, jitter), randf_range(-jitter, jitter) * 0.3, randf_range(-jitter, jitter))
		points.append(p)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 8.0
	var mesh := ImmediateMesh.new()
	# Two crossed ribbons for the trunk, plus a few short branches.
	for pass_index in 2:
		var side := Vector3(1, 0, 0) if pass_index == 0 else Vector3(0, 0, 1)
		mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for i in points.size():
			var width := lerpf(0.9, 0.25, float(i) / float(segments))
			mesh.surface_add_vertex(points[i] - side * width)
			mesh.surface_add_vertex(points[i] + side * width)
		mesh.surface_end()
	for branch in 4:
		var start: Vector3 = points[randi_range(3, segments - 3)]
		var dir := Vector3(randf_range(-1, 1), randf_range(-0.9, -0.2), randf_range(-1, 1)).normalized()
		mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		var p := start
		for i in 5:
			var w := lerpf(0.3, 0.02, float(i) / 4.0)
			mesh.surface_add_vertex(p - Vector3(w, 0, 0))
			mesh.surface_add_vertex(p + Vector3(w, 0, 0))
			p += dir * length * 0.05 + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
		mesh.surface_end()
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	node.global_transform = Transform3D.IDENTITY
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 40.0
	light.omni_range = 90.0
	parent.add_child(light)
	light.global_position = to + Vector3(0, 5, 0)
	var tween := node.create_tween()
	tween.set_parallel(true)
	# Double flicker, then fade.
	tween.tween_property(mat, "albedo_color:a", 0.2, 0.06)
	tween.tween_property(light, "light_energy", 6.0, 0.06)
	tween.chain().tween_property(mat, "albedo_color:a", 1.0, 0.05)
	tween.tween_property(light, "light_energy", 30.0, 0.05)
	tween.chain().tween_property(mat, "albedo_color:a", 0.0, 0.35)
	tween.tween_property(light, "light_energy", 0.0, 0.35)
	tween.chain().tween_callback(node.queue_free)
	tween.tween_callback(light.queue_free)
	burst(parent, to, color, 40, 14.0, 0.9, 0.35, 0.3)
