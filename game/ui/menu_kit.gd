class_name MenuKit
extends RefCounted
## Shared look of the main menu and scenario screens: animated map backdrop, gold accent, card panels.

const GOLD := Color("e0c070")
const INK := Color("0b1119")


## Slowly drifting world imagery with a dark gradient, so menus sit on the actual map of the game.
static func backdrop(root: Control) -> void:
	var base := ColorRect.new()
	base.color = INK
	base.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(base)
	if EarthVisual.available():
		var img := EarthVisual.overview_image()
		if img != null:
			var tr := TextureRect.new()
			tr.texture = ImageTexture.create_from_image(img)
			tr.set_anchors_preset(Control.PRESET_FULL_RECT)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			tr.modulate = Color(0.5, 0.58, 0.72, 1.0)
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(tr)
			tr.resized.connect(func(): tr.pivot_offset = tr.size * 0.5)
			if not GameSettings.reduce_motion() and not MobileLayout.is_phone():   # a never-ending tween keeps a phone rendering (battery)
				var tw := tr.create_tween().set_loops()
				tw.tween_property(tr, "scale", Vector2(1.12, 1.12), 40.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
				tw.tween_property(tr, "scale", Vector2.ONE, 40.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	for spec in [[Gradient.new(), true], [Gradient.new(), false]]:
		var g: Gradient = spec[0]
		if spec[1]:   # left-to-right: dark behind the menu column, open towards the map
			g.colors = PackedColorArray([Color(0.035, 0.05, 0.075, 0.97), Color(0.035, 0.05, 0.075, 0.8), Color(0.02, 0.03, 0.05, 0.25)])
			g.offsets = PackedFloat32Array([0.0, 0.38, 1.0])
		else:         # bottom vignette
			g.colors = PackedColorArray([Color(0, 0, 0, 0), Color(0, 0, 0, 0.7)])
			g.offsets = PackedFloat32Array([0.7, 1.0])
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.fill = GradientTexture2D.FILL_LINEAR
		gt.fill_from = Vector2(0, 0) if spec[1] else Vector2(0, 0)
		gt.fill_to = Vector2(1, 0) if spec[1] else Vector2(0, 1)
		var ov := TextureRect.new()
		ov.texture = gt
		ov.set_anchors_preset(Control.PRESET_FULL_RECT)
		ov.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ov.stretch_mode = TextureRect.STRETCH_SCALE
		ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(ov)


static func _box(bg: Color, border: Color, left_accent: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.border_width_left = maxi(1, left_accent)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


## Menu button. kind: "primary" (gold) or "normal" (dark glass with a gold edge on hover).
static func button(text: String, kind: String = "normal", min_w: float = 340.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 46 if kind == "primary" else 40)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if kind == "primary":
		b.add_theme_stylebox_override("normal", _box(Color(0.62, 0.47, 0.13, 0.95), Color("f0d27a"), 4))
		b.add_theme_stylebox_override("hover", _box(Color(0.78, 0.6, 0.18, 1.0), Color("ffe9a8"), 6))
		b.add_theme_stylebox_override("pressed", _box(Color(0.5, 0.37, 0.1, 1.0), Color("f0d27a"), 4))
		b.add_theme_color_override("font_color", Color("fff6dc"))
		b.add_theme_color_override("font_hover_color", Color.WHITE)
		b.add_theme_font_size_override("font_size", 17)
	else:
		b.add_theme_stylebox_override("normal", _box(Color(0.06, 0.08, 0.11, 0.72), Color(0.3, 0.35, 0.42, 0.55), 1))
		b.add_theme_stylebox_override("hover", _box(Color(0.14, 0.17, 0.22, 0.92), Color(0.6, 0.5, 0.25, 0.9), 4))
		b.add_theme_stylebox_override("pressed", _box(Color(0.2, 0.17, 0.09, 0.95), GOLD, 4))
		b.add_theme_font_size_override("font_size", 15)
	return b


static func card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.11, 0.86)
	sb.border_color = Color(0.3, 0.35, 0.42, 0.6)
	sb.set_border_width_all(1)
	sb.border_width_top = 3
	sb.border_color = Color(0.3, 0.35, 0.42, 0.6)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(16)
	return sb


## Small rounded tag ("реальная карта", "рельеф", ...).
static func badge(text: String, col: Color = Color("8fb3d9")) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", col)
	return l


static func gold_rule(width: float = 120.0) -> ColorRect:
	var r := ColorRect.new()
	r.color = GOLD
	r.custom_minimum_size = Vector2(width, 2)
	return r


## Facts about a scenario for its card: dataset size from the manifest and the opt-in rules it enables.
static func scenario_facts(data: Dictionary) -> Dictionary:
	var facts := {"tags": [], "line": ""}
	if str(data.get("world", "procedural")) == "earth":
		var ds := str(data.get("world_dataset", "world"))
		var path := "res://data/%s/manifest.json" % ds
		facts["tags"].append("реальная карта")
		if FileAccess.file_exists(path):
			var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if typeof(m) == TYPE_DICTIONARY and m.has("counts"):
				var c: Dictionary = m["counts"]
				facts["line"] = "%s ячеек суши · %s населённых пунктов" % [_thousands(int(c.get("cells_land", 0))), _thousands(int(c.get("settlements", 0)))]
	else:
		facts["tags"].append("случайный мир")
	var rules: Dictionary = data.get("rules", {})
	if rules.get("terrain", false):
		facts["tags"].append("рельеф и дороги")
	if rules.get("weather", false):
		facts["tags"].append("сезоны и погода")
	if rules.get("modern", false):
		facts["tags"].append("современная война")
	return facts


static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += " "
		out += s[i]
	return out
