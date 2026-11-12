// energy_tether.gdshader
// Plasma cable. UV.x = metres along the rope, UV.y = 0..1 across the ribbon.
// Cyan (slack) -> Violet (charged) -> Red (critical, about to overload).
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform float tension : hint_range(0.0, 1.0) = 0.0;
uniform float charge : hint_range(0.0, 1.0) = 0.0;
uniform vec4 color_slack : source_color = vec4(0.24, 0.91, 0.96, 1.0);
uniform vec4 color_charged : source_color = vec4(0.61, 0.42, 1.0, 1.0);
uniform vec4 color_critical : source_color = vec4(1.0, 0.30, 0.37, 1.0);
uniform float energy : hint_range(0.0, 12.0) = 2.2;

float hash1(float n) {
	return fract(sin(n) * 43758.5453);
}

float noise1(float x) {
	float i = floor(x);
	float f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(hash1(i), hash1(i + 1.0), f);
}

void fragment() {
	float t = clamp(max(tension, charge * 0.7), 0.0, 1.0);
	vec3 col = mix(color_slack.rgb, color_charged.rgb, smoothstep(0.25, 0.6, t));
	col = mix(col, color_critical.rgb, smoothstep(0.75, 0.95, tension));

	float speed = mix(1.5, 14.0, t);
	// Electric wobble of the core, stronger with tension.
	float wobble = (noise1(UV.x * 3.0 + TIME * speed) - 0.5) * mix(0.05, 0.45, t);
	float v_core = abs(UV.y - 0.5 + wobble * 0.5) * 2.0;
	float v_halo = abs(UV.y - 0.5) * 2.0;

	float core = smoothstep(0.22, 0.0, v_core);
	float halo = pow(max(1.0 - v_halo, 0.0), 2.5);
	// Plasma beads racing along the cable once it is charged.
	float beads = pow(max(sin(UV.x * 2.2 - TIME * speed) * 0.5 + 0.5, 0.0), 12.0) * smoothstep(0.3, 0.6, t);
	float pulse = 0.75 + 0.25 * sin(TIME * mix(3.0, 50.0, smoothstep(0.7, 1.0, tension)));
	float flicker = mix(1.0, step(0.25, hash1(floor(TIME * 30.0))), smoothstep(0.85, 1.0, tension) * 0.6);

	// Two thin filaments that spiral around the core.
	float twist = UV.x * 5.0 - TIME * speed * 0.6;
	float fil_a = smoothstep(0.09, 0.0, abs(UV.y - 0.5 - sin(twist) * 0.2));
	float fil_b = smoothstep(0.09, 0.0, abs(UV.y - 0.5 + sin(twist) * 0.2));
	float filaments = (fil_a + fil_b) * (0.25 + 0.5 * t);

	float a = (core * 1.6 + halo * 0.55 + beads * halo * 2.0 + filaments) * pulse * flicker;
	ALBEDO = col * a * energy + vec3(core) * 0.8 * energy * flicker;
	ALPHA = clamp(a, 0.0, 1.0);
}
