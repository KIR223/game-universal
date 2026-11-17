class_name SettingsPanel
extends PanelContainer
## Sound and motion settings. The rows are also embedded in the main settings screen (`add_rows`); this panel is the stand-alone
## version (in-game menu: "Звук и анимации…"). Every change is applied and saved at once.

signal changed
signal closed


func build(theme_: Theme) -> void:
	theme = theme_
	custom_minimum_size = Vector2(560, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", Design.S3)
	add_child(v)
	var title := Label.new()
	title.text = "Звук и анимации"
	title.add_theme_font_size_override("font_size", Design.FS_H2)
	title.add_theme_color_override("font_color", Design.C_GOLD)
	v.add_child(title)
	add_rows(v, func(): changed.emit())
	var close := Button.new()
	close.text = "Готово"
	close.custom_minimum_size = Vector2(0, Design.BTN_H)
	close.pressed.connect(func(): closed.emit())
	v.add_child(close)


## Reduced-motion checkbox and the three volume sliders.
static func add_rows(parent: Control, on_change: Callable) -> void:
	var rm := CheckBox.new()
	rm.text = "Уменьшить движение (без анимаций панелей, дрейфа фона, воды и осадков)"
	rm.button_pressed = GameSettings.reduce_motion()
	rm.toggled.connect(func(on: bool):
		GameSettings.set_value("reduce_motion", on)
		on_change.call())
	parent.add_child(rm)
	var tut := CheckBox.new()
	tut.text = "Подсказки обучения в первой игре"
	tut.button_pressed = bool(GameSettings.get_value("tutorial"))
	tut.toggled.connect(func(on: bool):
		GameSettings.set_value("tutorial", on)
		on_change.call())
	parent.add_child(tut)
	var snd := Label.new()
	snd.text = "Звук"
	snd.add_theme_color_override("font_color", Design.C_TEXT_DIM)
	snd.add_theme_font_size_override("font_size", Design.FS_CAPTION)
	parent.add_child(snd)
	parent.add_child(_slider_row("Общая громкость", "vol_master", on_change))
	parent.add_child(_slider_row("Звуки интерфейса", "vol_ui", on_change))
	parent.add_child(_slider_row("Музыка", "vol_music", on_change))


static func _slider_row(label: String, key: String, on_change: Callable) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", Design.S3)
	var l := Label.new()
	l.text = label
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = float(GameSettings.get_value(key))
	s.custom_minimum_size = Vector2(180, Design.BTN_H)
	s.focus_mode = Control.FOCUS_NONE
	h.add_child(s)
	var pct := Label.new()
	pct.custom_minimum_size = Vector2(48, 0)
	pct.text = "%d%%" % int(round(s.value * 100.0))
	h.add_child(pct)
	s.value_changed.connect(func(val: float):
		GameSettings.set_value(key, val)
		pct.text = "%d%%" % int(round(val * 100.0))
		on_change.call())
	return h
