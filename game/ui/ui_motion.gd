class_name UiMotion
extends RefCounted
## Small, quick interface animations (all skipped with "reduce motion"): button hover/press, staggered entrance, value flashes,
## fade-out before a panel is freed.

const HOVER_SCALE := 1.035
const PRESS_SCALE := 0.97


static func enabled() -> bool:
	return not GameSettings.reduce_motion()


## Plain Buttons grow slightly under the cursor and press in a little; pivot stays at the centre.
static func hover_button(b: Button) -> void:
	if b.get_script() != null or b.get_class() != "Button" or b.has_meta("ui_motion"):
		return
	b.set_meta("ui_motion", true)
	b.resized.connect(func(): b.pivot_offset = b.size * 0.5)
	b.pivot_offset = b.size * 0.5
	b.mouse_entered.connect(func(): _scale(b, HOVER_SCALE, Design.ANIM_FAST))
	b.mouse_exited.connect(func(): _scale(b, 1.0, Design.ANIM_FAST))
	b.button_down.connect(func(): _scale(b, PRESS_SCALE, 0.06))
	b.button_up.connect(func(): _scale(b, HOVER_SCALE if b.is_hovered() else 1.0, 0.08))


static func _scale(n: Control, target: float, dur: float) -> void:
	if not enabled() or not is_instance_valid(n):
		n.scale = Vector2.ONE
		return
	var tw := n.create_tween()
	tw.tween_property(n, "scale", Vector2(target, target), dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## Children fade in one after another (container children cannot be offset, so it is a pure fade).
static func stagger_in(nodes: Array, step: float = 0.05) -> void:
	if not enabled():
		return
	var i := 0
	for n in nodes:
		if not (n is Control) or not is_instance_valid(n):
			continue
		var c := n as Control
		c.modulate.a = 0.0
		var tw := c.create_tween()
		tw.tween_interval(step * i)
		tw.tween_property(c, "modulate:a", 1.0, 0.22)
		i += 1


## Brief colour pulse on a label when its value changed.
static func flash(l: Control, color: Color) -> void:
	if not enabled() or not is_instance_valid(l):
		return
	var tw := l.create_tween()
	l.modulate = color.lerp(Color.WHITE, 0.15) * 1.6
	tw.tween_property(l, "modulate", Color.WHITE, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## Fade a panel out and free it (immediately with reduced motion).
static func fade_out_free(n: Control, dur: float = 0.12) -> void:
	if not is_instance_valid(n):
		return
	if not enabled() or not n.is_inside_tree():
		n.queue_free()
		return
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tw := n.create_tween()
	tw.tween_property(n, "modulate:a", 0.0, dur)
	tw.tween_callback(n.queue_free)


## Number at the start of a chip text ("120 (+3)" -> 120); -1 when there is none.
static func leading_number(text: String) -> int:
	var digits := ""
	for ch in text:
		if ch >= "0" and ch <= "9" or (digits == "" and ch == "-"):
			digits += ch
		elif digits != "":
			break
	return int(digits) if digits not in ["", "-"] else -1
