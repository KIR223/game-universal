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
uniform float detail_fx = 1.0;         // 1: procedural close-up relief detail, shallow-water shading and surf (High graphics only)
uniform float water_fx = 1.0;          // 1: gentle animated shimmer on open water (graphics profile, off with reduced motion)

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float a = 0.5;
	float v = 0.0;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(17.0, 9.0);
		a *= 0.5;
	}
	return v;
}

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
	float dmul = 1.0;
	if (detail_fx > 0.5 && use_mask > 0.5) {
		float zd = smoothstep(2.2, 9.0, zoom);
		if (land_w > 0.02 && zd > 0.01) {
			// procedural micro-relief anchored to the globe (stable while panning): light from the north-west, stronger in rough terrain
			// base frequency follows the screen: the finest octave stays ~3 px, two neighbouring scales are cross-faded (no shimmering)
			float px_uv = max(length(fwidth(uv)), 1e-7);
			float lv = log2(1.0 / (px_uv * 24.0));
			float l0 = floor(lv);
			float mixf = smoothstep(0.0, 1.0, lv - l0);
			vec2 pa = uv * vec2(2.0, 1.0) * exp2(l0);
			vec2 pb = uv * vec2(2.0, 1.0) * exp2(l0 + 1.0);
			float d_e = 0.45 / 24.0;
			float h0 = mix(fbm(pa), fbm(pb), mixf);
			float hx = mix(fbm(pa + vec2(d_e, 0.0)), fbm(pb + vec2(d_e, 0.0)), mixf);
			float hy = mix(fbm(pa + vec2(0.0, d_e)), fbm(pb + vec2(0.0, d_e)), mixf);
			float slope = ((h0 - hx) * 0.8 + (h0 - hy) * 0.6) * 5.5;
			float rough = clamp(length(vec3(img.rgb) - vec3(dot(img.rgb, vec3(0.333)))) * 3.0 + 0.45, 0.45, 1.0);
			dmul = 1.0 + slope * 0.9 * rough * zd + (h0 - 0.5) * 0.22 * zd;
		}
		if (land_w < 0.98) {
			// shallow water: lighter and greener close to the coast (mask is sampled at growing distances)
			vec2 px = 1.0 / vec2(textureSize(relief, 0));
			float near = 0.0;
			for (int k = 1; k <= 4; k++) {
				float rr = float(k) * 1.6;
				float m0 = texture(relief, UV + vec2(px.x * rr, 0.0)).a;
				float m1 = texture(relief, UV + vec2(-px.x * rr, 0.0)).a;
				float m2 = texture(relief, UV + vec2(0.0, px.y * rr)).a;
				float m3 = texture(relief, UV + vec2(0.0, -px.y * rr)).a;
				near += (m0 + m1 + m2 + m3) * 0.25 / float(k);
			}
			near = clamp(near * 0.9, 0.0, 1.0);
			float wdeep = 1.0 - land_w;
			col = mix(col, vec3(0.30, 0.62, 0.66), near * 0.34 * wdeep);
			float surf = smoothstep(0.35, 0.5, img.a) * (1.0 - smoothstep(0.5, 0.62, img.a));
			col = mix(col, vec3(0.92, 0.97, 1.0), surf * 0.42 * smoothstep(1.5, 5.0, zoom));
		}
	}
	// organic borders: the id raster is stair-stepped, so lookups are domain-warped by low-frequency noise (<= 0.45 cell) when zoomed in
	vec2 isz = vec2(textureSize(ids, 0));
	float warp_amt = detail_fx * smoothstep(0.8, 2.2, zoom);
	vec2 wq = uv * isz * 0.55;
	vec2 warp = (vec2(vnoise(wq), vnoise(wq + vec2(31.7, 11.3))) - 0.5) * 0.9 / isz * warp_amt;
	vec2 uvi = uv + warp;
	int id = cell_at(uvi);
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
			int nid = cell_at(uvi + offs[k]);
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
	if (use_mask > 0.5 && water_fx > 0.5) {
		float w = 1.0 - land_w;
		vec2 q = uv * vec2(520.0, 300.0);
		float sh = sin(q.x * 1.7 + TIME * 0.6) * sin(q.y * 2.3 - TIME * 0.45) + 0.5 * sin((q.x + q.y) * 3.1 + TIME * 0.8);
		col += vec3(0.010, 0.014, 0.018) * sh * w * clamp(zoom * 0.5, 0.0, 1.0);
	}
	col *= mix(1.0, dmul, land_w);   // micro-relief on top of the political colour
	COLOR = vec4(col, 1.0);
}
