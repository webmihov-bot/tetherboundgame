// island_terrain.gdshader
// Floating-island surface. Toon-banded like the cel shader, plus procedural
// detail in world space: patchy ground, rock strata on the sides, and pulsing
// energy veins that are faint on top and bright on the underside, so islands
// glow from beneath.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

global uniform float storm_intensity;

uniform vec4 accent : source_color = vec4(0.61, 0.42, 1.0, 1.0);
uniform vec4 shadow_tint : source_color = vec4(0.30, 0.24, 0.60, 1.0);
uniform float vein_energy : hint_range(0.0, 8.0) = 2.2;
uniform float top_vein_amount : hint_range(0.0, 1.0) = 0.05;
uniform int bands : hint_range(1, 6) = 3;

varying vec3 world_pos;
varying vec3 world_normal;

float hash3(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise3(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash3(i), hash3(i + vec3(1.0, 0.0, 0.0)), f.x),
			mix(hash3(i + vec3(0.0, 1.0, 0.0)), hash3(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
		mix(mix(hash3(i + vec3(0.0, 0.0, 1.0)), hash3(i + vec3(1.0, 0.0, 1.0)), f.x),
			mix(hash3(i + vec3(0.0, 1.0, 1.0)), hash3(i + vec3(1.0, 1.0, 1.0)), f.x), f.y),
		f.z);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 base = COLOR.rgb;
	float up = world_normal.y;
	float n = noise3(world_pos * 0.35) * 0.65 + noise3(world_pos * 1.1) * 0.35;

	// Top: patchy ground with faint accent-tinted patches.
	vec3 top = base * (0.7 + 0.7 * n);
	top += accent.rgb * 0.035 * smoothstep(0.5, 0.75, noise3(world_pos * 0.09 + 7.0));
	// Sides and underside: layered rock strata.
	float strata = sin(world_pos.y * 1.6 + n * 5.0) * 0.5 + 0.5;
	vec3 side = base * mix(0.5, 1.3, smoothstep(0.35, 0.65, strata));
	ALBEDO = mix(side, top, smoothstep(0.55, 0.8, up));
	ROUGHNESS = 0.92;
	METALLIC = 0.0;

	// Energy veins: thin ridges of two noise fields.
	float ridge_a = abs(noise3(world_pos * 0.22) * 2.0 - 1.0);
	float ridge_b = abs(noise3(world_pos * 0.5 + 13.0) * 2.0 - 1.0);
	float vein = smoothstep(0.05, 0.0, ridge_a) + 0.5 * smoothstep(0.035, 0.0, ridge_b);
	float under = smoothstep(0.35, -0.3, up);
	float pulse = 0.6 + 0.4 * sin(TIME * 1.3 - world_pos.y * 0.35 + n * 6.0);
	EMISSION = accent.rgb * vein * mix(top_vein_amount, 1.0, under) * pulse * vein_energy * (0.7 + storm_intensity);
}

void light() {
	float lit = clamp(dot(NORMAL, LIGHT) * 0.5 + 0.5, 0.0, 1.0) * ATTENUATION;
	float b = float(bands);
	float scaled = lit * b;
	float stepped = (floor(scaled) + smoothstep(0.46, 0.54, fract(scaled))) / b;
	DIFFUSE_LIGHT += LIGHT_COLOR / PI * stepped * mix(shadow_tint.rgb, vec3(1.0), stepped);
}
