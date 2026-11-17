shader_type canvas_item;
// Real-world map: hill-shaded relief + per-cell palette lookup by cell id.
// Changing who controls a cell only rewrites one palette pixel; map modes swap the palette.
// Borders are derived on the GPU from the id raster, so they stay ~1 screen pixel wide at any zoom.

uniform sampler2D relief : filter_linear, repeat_disable;
uniform sampler2D ids : filter_nearest, repeat_disable;
uniform sampler2D pal_cur : filter_nearest, repeat_disable;
uniform sampler2D pal_prev : filter_nearest, repeat_disable;
uniform sampler2D info_a : filter_nearest, repeat_disable; // R,G = controller id (16 bit), B,A = region id (16 bit)
uniform sampler2D info_b : filter_nearest, repeat_disable; // B = flags (1 cut off, 2 contested, 4 front), A = capture flash
uniform vec2 origin = vec2(0.0, 0.0);   // global uv of this tile's top-left corner (ids / palettes are global)
uniform vec2 span = vec2(1.0, 1.0);     // global uv size of this tile
uniform float use_mask = 0.0;           // 1: imagery alpha is the exact land mask (visual tiles)
uniform float tint = 0.62;              // strength of the political / mode colour over the imagery
uniform vec2 pal_size = vec2(256.0, 64.0);
uniform float fade = 1.0;
uniform float zoom = 0.3;
uniform int sel_id = -1;
uniform int hover_id = -1;
uniform float pulse = 0.0;

int id16(vec4 v) {
	return int(v.r * 255.0 + 0.5) + int(v.g * 255.0 + 0.5) * 256;
}

int reg16(vec4 v) {
	return int(v.b * 255.0 + 0.5) + int(v.a * 255.0 + 0.5) * 256;
}

int cell_at(vec2 uv) {
	return id16(texture(ids, uv));
}

vec2 pal_uv(int id) {
	return (vec2(float(id % 256), float(id / 256)) + 0.5) / pal_size;
}

void fragment() {
	vec2 uv = origin + UV * span;
	vec4 img = texture(relief, UV);
	vec3 col = img.rgb;
	float land_w = mix(1.0, smoothstep(0.4, 0.6, img.a), use_mask);
	int id = cell_at(uv);
	if (id != 65535 && land_w > 0.01) {
		vec2 pu = pal_uv(id);
		vec4 pc = mix(texture(pal_prev, pu), texture(pal_cur, pu), fade);
		col = mix(col, pc.rgb, pc.a * tint * land_w);
		vec4 ia = texture(info_a, pu);
		vec4 ib = texture(info_b, pu);
		int ctl = id16(ia);
		int reg = reg16(ia);
		vec2 d = fwidth(uv);
		float ctl_e = 0.0;
		float reg_e = 0.0;
		float cell_e = 0.0;
		float coast = 0.0;
		float sel_e = 0.0;
		vec2 offs[4] = vec2[4](vec2(d.x, 0.0), vec2(-d.x, 0.0), vec2(0.0, d.y), vec2(0.0, -d.y));
		for (int k = 0; k < 4; k++) {
			int nid = cell_at(uv + offs[k]);
			if (nid != id) {
				if (id == sel_id || nid == sel_id) {
					sel_e = 1.0;
				}
				if (nid == 65535) {
					coast = 1.0;
				} else {
					vec4 na = texture(info_a, pal_uv(nid));
					if (id16(na) != ctl) {
						ctl_e = 1.0;
					} else if (reg16(na) != reg) {
						reg_e = 1.0;
					} else {
						cell_e = 1.0;
					}
				}
			}
		}
		float z_reg = smoothstep(0.3, 0.8, zoom);
		float z_cell = smoothstep(1.2, 2.6, zoom);
		float edge = max(ctl_e * 0.9, max(reg_e * 0.38 * z_reg, cell_e * 0.2 * z_cell));
		col = mix(col, vec3(0.03, 0.04, 0.06), edge * land_w);
		col = mix(col, vec3(0.02, 0.03, 0.05), coast * 0.5 * land_w * (1.0 - use_mask));
		int flags = int(ib.b * 255.0 + 0.5);
		if ((flags & 1) != 0) {
			float hatch = step(0.55, fract((FRAGCOORD.x + FRAGCOORD.y) / 9.0));
			col = mix(col, vec3(0.9, 0.15, 0.1), 0.45 * hatch);
		}
		if ((flags & 2) != 0) {
			col = mix(col, vec3(1.0, 0.45, 0.1), 0.35 + 0.25 * pulse);
		}
		if ((flags & 4) != 0) {
			col = mix(col, vec3(1.0, 0.85, 0.35), 0.18);
		}
		col += vec3(1.0, 0.9, 0.5) * ib.a * 0.55;
		if (id == hover_id) {
			col = mix(col, vec3(1.0), 0.16);
		}
		if (id == sel_id) {
			col = mix(col, vec3(1.0, 0.88, 0.54), 0.18);
		}
		col = mix(col, vec3(1.0, 0.88, 0.54), sel_e * 0.95);
	}
	COLOR = vec4(col, 1.0);
}
