// glass_panel.gdshader
// Glassmorphism panel for the main menu: blurs the live 3D world behind it.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform float blur : hint_range(0.0, 5.0) = 3.0;
uniform vec4 tint : source_color = vec4(0.08, 0.09, 0.20, 0.58);
uniform float corner_radius = 28.0;
uniform vec2 rect_size = vec2(520.0, 700.0);

void fragment() {
	vec3 bg = textureLod(screen_tex, SCREEN_UV, blur).rgb;
	vec2 p = UV * rect_size;
	vec2 q = abs(p - rect_size * 0.5) - rect_size * 0.5 + corner_radius;
	float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - corner_radius;
	float inside = 1.0 - smoothstep(-1.0, 1.0, d);
	float border = smoothstep(-2.5, -1.0, d) * inside;
	vec3 col = mix(bg, tint.rgb, tint.a) + vec3(0.05) * (1.0 - UV.y);
	col = mix(col, vec3(1.0), border * 0.18);
	COLOR = vec4(col, inside);
}
