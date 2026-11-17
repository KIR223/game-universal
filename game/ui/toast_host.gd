class_name ToastHost
extends VBoxContainer
## Short notifications at the top centre of the map: slide in, stay ~3.5 s, fade out. At most three at a time.

const MAX_VISIBLE := 3
const LIFETIME := 3.6
const KIND_COLORS := {"war": Design.C_BAD, "peace": Design.C_OK, "info": Design.C_INFO, "warn": Design.C_WARN}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	offset_top = 64
	add_theme_constant_override("separation", Design.S1)


## Which kind of toast a game-log line is (colour and sound), by its wording.
static func kind_of(text: String) -> String:
	var t := text.to_lower()
	for w in ["объяв", "войн", "удар", "захвач", "потерял", "уничтож", "блокад"]:
		if t.contains(w):
			return "war"
	for w in ["мир", "союз", "изучено", "договор"]:
		if t.contains(w):
			return "peace"
	return "info"


func show_toast(text: String, kind: String = "info") -> void:
	while get_child_count() >= MAX_VISIBLE:
		var old := get_child(0)
		remove_child(old)
		old.queue_free()
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Design.C_PANEL, 0.96)
	sb.border_color = KIND_COLORS.get(kind, Design.C_INFO)
	sb.set_border_width_all(1)
	sb.border_width_left = 4
	sb.set_corner_radius_all(Design.RADIUS)
	sb.content_margin_left = Design.S3
	sb.content_margin_right = Design.S4
	sb.content_margin_top = Design.S2
	sb.content_margin_bottom = Design.S2
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(0, 0)
	p.add_child(l)
	add_child(p)
	if not UiMotion.enabled():
		get_tree().create_timer(LIFETIME).timeout.connect(func(): if is_instance_valid(p): p.queue_free())
		return
	p.modulate.a = 0.0
	p.scale = Vector2(0.96, 0.96)
	p.pivot_offset = Vector2(120, 0)
	var tw := p.create_tween()
	tw.tween_property(p, "modulate:a", 1.0, 0.18)
	tw.parallel().tween_property(p, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(LIFETIME)
	tw.tween_property(p, "modulate:a", 0.0, 0.35)
	tw.tween_callback(p.queue_free)
