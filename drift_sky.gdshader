// drift_sky.gdshader
// The Drift: animated storm sky. Nebula clouds, twinkling stars, aurora
// curtains, and a slowly turning storm eye that flashes with lightning.
// The reflection/ambient pass only gets the calm gradient, so the animated
// parts never make the world lighting flicker.
shader_type sky;

uniform float storm : hint_range(0.0, 1.0) = 0.2;
uniform vec3 top_color : source_color = vec3(0.012, 0.010, 0.055);
uniform vec3 horizon_color : source_color = vec3(0.11, 0.07, 0.27);
uniform vec3 abyss_color : source_color = vec3(0.004, 0.004, 0.018);
uniform vec3 nebula_a : source_color = vec3(0.45, 0.20, 0.90);
uniform vec3 nebula_b : source_color = vec3(0.10, 0.70, 0.85);
uniform vec3 eye_direction = vec3(-0.55, 0.38, -0.75);
uniform vec3 eye_color : source_color = vec3(0.75, 0.55, 1.0);

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

float fbm(vec3 p) {
	float amp = 0.5;
	float sum = 0.0;
	for (int i = 0; i < 4; i++) {
		sum += amp * noise3(p);
		p = p * 2.02 + vec3(1.7);
		amp *= 0.5;
	}
	return sum;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = d.y;
	vec3 col = mix(horizon_color, top_color, smoothstep(0.0, 0.75, h));
	col = mix(col, abyss_color, smoothstep(0.0, -0.6, h));
	col += horizon_color * 0.5 * exp(-abs(h) * 9.0);

	if (!AT_CUBEMAP_PASS) {
		float t = TIME;

		// Nebula clouds, domain-warped so they churn instead of sliding.
		vec3 p = d * 2.2 + vec3(t * 0.012, 0.0, t * 0.008);
		float n = fbm(p + fbm(p * 1.7 + t * 0.01) * 0.8);
		float cloud = smoothstep(0.42, 0.85, n);
		vec3 nebula = mix(nebula_a, nebula_b, fbm(d * 1.3 + 4.0));
		col += nebula * cloud * (0.16 + 0.22 * storm);

		// Stars.
		vec3 sp = d * 200.0;
		float star = hash3(floor(sp));
		float twinkle = 0.6 + 0.4 * sin(t * (1.5 + star * 5.0) + star * 40.0);
		float dist = length(fract(sp) - 0.5);
		col += vec3(0.9, 0.9, 1.0) * step(0.996, star) * smoothstep(0.35, 0.0, dist) * twinkle * (1.0 - cloud) * smoothstep(-0.4, 0.0, h) * 1.5;

		// Aurora curtains.
		float around = atan(d.x, d.z);
		float curtain = sin(around * 6.0 + t * 0.15 + noise3(vec3(cos(around) * 3.0, sin(around) * 3.0, t * 0.1)) * 4.0);
		float band = smoothstep(0.06, 0.28, h) * smoothstep(0.8, 0.3, h);
		float rays = pow(noise3(vec3(cos(around) * 40.0, sin(around) * 40.0, t * 0.4 + h * 2.0)), 2.0);
		float aurora = pow(max(curtain, 0.0), 3.0) * band * (0.35 + 0.65 * rays);
		col += mix(vec3(0.15, 0.9, 0.8), vec3(0.6, 0.35, 1.0), clamp(h * 1.6, 0.0, 1.0)) * aurora * 0.4;

		// The storm eye: a spiral disc with a bright core and lightning flashes.
		vec3 e = normalize(eye_direction);
		if (dot(d, e) > 0.0) {
			vec3 side = normalize(cross(e, vec3(0.0, 1.0, 0.0)));
			vec3 up = cross(side, e);
			vec2 q = vec2(dot(d, side), dot(d, up));
			float r = length(q);
			float angle = atan(q.y, q.x);
			float arms = sin(angle * 3.0 + 5.0 / (r + 0.15) - t * 0.45) * 0.5 + 0.5;
			float grain = 0.6 + 0.4 * noise3(vec3(q * 9.0, t * 0.08));
			float disc = smoothstep(0.6, 0.0, r) * smoothstep(0.03, 0.1, r);
			col += eye_color * disc * (0.12 + 0.6 * arms * arms) * grain * (0.45 + 0.8 * storm);
			col += eye_color * exp(-r * 20.0) * 1.6;
			float flash = pow(max(noise3(vec3(t * 2.6, 3.0, 9.0)) - 0.74, 0.0) * 3.8, 2.0) * (0.25 + storm);
			col += eye_color * flash * exp(-r * 2.2) * 2.0;
		}
	}
	COLOR = col;
}
