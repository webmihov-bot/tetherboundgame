// wind_grass_foliage.gdshader
// Vertex-displaced grass blades and floating crystal shards.
// Reacts to storm wind (global storm_intensity) and to the local player
// (global player_position). UV.y = 0 at the root, 1 at the tip.
shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

global uniform vec3 player_position;
global uniform float storm_intensity;

uniform vec4 base_color : source_color = vec4(0.05, 0.25, 0.30, 1.0);
uniform vec4 tip_color : source_color = vec4(0.30, 0.95, 0.85, 1.0);
uniform float wind_strength : hint_range(0.0, 2.0) = 0.35;
uniform float wind_speed : hint_range(0.0, 8.0) = 1.6;
uniform vec2 wind_dir = vec2(1.0, 0.35);
uniform float push_radius : hint_range(0.1, 8.0) = 2.4;
uniform float push_strength : hint_range(0.0, 3.0) = 0.9;
uniform float floating : hint_range(0.0, 1.0) = 0.0;
uniform float emission_energy : hint_range(0.0, 8.0) = 0.2;

varying float tip;
varying float variation;
varying float sheen;

void vertex() {
	tip = UV.y;
	variation = fract(sin(float(INSTANCE_ID) * 12.9898) * 43758.5453);
	vec3 wp = VERTEX;
	float phase = dot(wp.xz, vec2(0.13, 0.17));
	float grounded = 1.0 - floating;

	// Storm wind: two layered gusts, bending the tip more than the root.
	float gust = sin(TIME * wind_speed + phase) + 0.5 * sin(TIME * wind_speed * 2.3 + phase * 1.7);
	float amount = wind_strength * (0.5 + storm_intensity * 1.5) * tip * tip;
	VERTEX.xz += normalize(wind_dir) * gust * amount * grounded;
	// A band of light that travels across the field with each gust.
	sheen = smoothstep(0.6, 1.4, gust) * grounded;

	// Player proximity: blades flatten away from the player's feet.
	vec2 away = wp.xz - player_position.xz;
	float dist = length(away);
	float near_height = 1.0 - smoothstep(2.0, 4.0, abs(wp.y - player_position.y));
	float push = (1.0 - smoothstep(0.0, push_radius, dist)) * near_height;
	vec2 dir = away / max(dist, 0.001);
	VERTEX.xz += dir * push * push_strength * tip * grounded;
	VERTEX.y -= push * 0.35 * tip * grounded;

	// Crystal shards: slow bob, storm shiver, and they drift away from the player.
	float bob = sin(TIME * 0.8 + phase * 3.0) * 0.6 + storm_intensity * sin(TIME * 3.0 + phase) * 0.2;
	VERTEX.y += floating * bob;
	VERTEX.xz += floating * dir * (1.0 - smoothstep(0.0, push_radius * 2.0, dist)) * 1.5;
}

void fragment() {
	vec3 col = mix(base_color.rgb, tip_color.rgb, tip * (0.55 + 0.6 * variation));
	col *= 0.8 + 0.4 * variation;
	ALBEDO = col;
	ROUGHNESS = mix(0.85, 0.25, floating);
	METALLIC = floating * 0.6;
	EMISSION = tip_color.rgb * emission_energy * mix(tip, 1.0, floating) * (0.6 + 0.8 * variation) + tip_color.rgb * sheen * tip * 0.5;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
