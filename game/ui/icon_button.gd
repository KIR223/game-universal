class_name IconButton
extends Button
## Button that draws a vector icon (see Icons) with hover/pressed/active colours and an optional badge counter.

var icon_kind := "state"
var active := false          # highlighted as the currently open panel
var badge := 0
var caption := ""            # optional small caption under the icon
var pad := 9.0               # inner padding around the icon


func _init(kind: String = "state", tip: String = "", size: Vector2 = Vector2(44, 44)) -> void:
	icon_kind = kind
	tooltip_text = tip
	custom_minimum_size = size
	focus_mode = Control.FOCUS_NONE
	flat = false
	text = ""
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.14, 0.18, 0.0)
	normal.set_corner_radius_all(6)
	add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate()
	hover.bg_color = Color(0.22, 0.26, 0.33, 0.9)
	add_theme_stylebox_override("hover", hover)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.36, 0.3, 0.14, 0.95)
	add_theme_stylebox_override("pressed", pressed)
	var disabled := normal.duplicate()
	add_theme_stylebox_override("disabled", disabled)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)


func set_active(on: bool) -> void:
	active = on
	queue_redraw()


func set_badge(n: int) -> void:
	badge = n
	queue_redraw()


func _draw() -> void:
	var col := Color("cfd6df")
	if disabled:
		col = Color(0.4, 0.43, 0.48)
	elif active:
		col = Color("e8c46a")
	elif is_hovered():
		col = Color("ffffff")
	var r := Rect2(Vector2(pad, pad), size - Vector2(pad, pad) * 2.0)
	if caption != "":
		r = Rect2(Vector2(pad, 5), Vector2(size.x - pad * 2.0, size.y - 17))
	Icons.draw(self, icon_kind, r, col)
	if active:
		draw_rect(Rect2(0, size.y * 0.2, 3, size.y * 0.6), Color("e8c46a"))
	if caption != "":
		var font := get_theme_default_font()
		draw_string(font, Vector2(0, size.y - 4), caption, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, col)
	if badge > 0:
		var br := Vector2(size.x - 11, 11)
		draw_circle(br, 8.0, Color("c0392b"))
		draw_string(get_theme_default_font(), br + Vector2(-5.0 if badge < 10 else -8.0, 4.0), str(mini(badge, 99)), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)
