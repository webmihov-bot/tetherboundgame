// cel_toon_pbr.gdshader
// Stylized cel shading: banded diffuse, hard specular, crisp rim light,
// fresnel glow and emissive pulse. Used for characters, islands, ruins, the Ark.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform vec4 albedo : source_color = vec4(0.5, 0.5, 0.6, 1.0);
uniform float use_vertex_color : hint_range(0.0, 1.0) = 0.0;
uniform float metallic : hint_range(0.0, 1.0) = 0.2;
uniform float roughness : hint_range(0.0, 1.0) = 0.6;
uniform int bands : hint_range(1, 6) = 3;
uniform float band_softness : hint_range(0.001, 0.5) = 0.04;
uniform vec4 shadow_tint : source_color = vec4(0.30, 0.24, 0.60, 1.0);
uniform vec4 rim_color : source_color = vec4(0.45, 0.85, 1.0, 1.0);
uniform float rim_power : hint_range(0.5, 8.0) = 3.0;
uniform float rim_strength : hint_range(0.0, 4.0) = 1.0;
uniform float fresnel_glow : hint_range(0.0, 4.0) = 0.0;
uniform float spec_strength : hint_range(0.0, 4.0) = 1.0;
uniform vec4 emission : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy : hint_range(0.0, 16.0) = 0.0;
uniform float pulse_speed : hint_range(0.0, 10.0) = 0.0;

void fragment() {
	vec3 base = albedo.rgb * mix(vec3(1.0), COLOR.rgb, use_vertex_color);
	ALBEDO = base;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	float pulse = 1.0 + 0.35 * sin(TIME * pulse_speed) * step(0.001, pulse_speed);
	EMISSION = emission.rgb * emission_energy * pulse + rim_color.rgb * fres * fresnel_glow;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	// Half-lambert, quantized into bands with a soft edge between them.
	float lit = clamp(ndl * 0.5 + 0.5, 0.0, 1.0) * ATTENUATION;
	float b = float(bands);
	float scaled = lit * b;
	float stepped = (floor(scaled) + smoothstep(0.5 - band_softness, 0.5 + band_softness, fract(scaled))) / b;
	vec3 light_col = LIGHT_COLOR / PI;
	DIFFUSE_LIGHT += light_col * stepped * mix(shadow_tint.rgb, vec3(1.0), stepped);

	// Hard-edged specular highlight; stronger on metals.
	vec3 h = normalize(VIEW + LIGHT);
	float ndh = max(dot(NORMAL, h), 0.0);
	float gloss = mix(8.0, 220.0, 1.0 - ROUGHNESS);
	float spec = smoothstep(0.5 - band_softness, 0.5 + band_softness, pow(ndh, gloss));
	SPECULAR_LIGHT += light_col * spec * spec_strength * mix(0.25, 1.0, METALLIC) * ATTENUATION;

	// Crisp rim light on the lit side only.
	float rim = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), rim_power);
	rim = smoothstep(0.45, 0.55, rim) * smoothstep(0.0, 0.25, ndl);
	SPECULAR_LIGHT += rim_color.rgb * rim * rim_strength * light_col * ATTENUATION;
}
