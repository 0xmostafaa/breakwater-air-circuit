shader_type spatial;
render_mode unshaded;
varying vec2 world_xz;
void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}
void fragment() {
	vec2 p = world_xz;
	float swell = sin(p.y * 0.026 + sin(p.x * 0.013) * 3.0 + TIME * 0.65);
	float ripples = smoothstep(0.94, 1.0, swell) * smoothstep(0.25, 0.85, sin(p.x * 0.05 + p.y * 0.017));
	float fade = 1.0 - smoothstep(240.0, 1300.0, length(p - CAMERA_POSITION_WORLD.xz));
	ALBEDO = mix(vec3(0.12, 0.45, 0.49), vec3(0.36, 0.67, 0.66), 0.22 + ripples * fade * 0.65);
}
