class_name SettingsPanel
extends PanelContainer
## Settings: graphics profile, reduced motion, interface scale and volumes. Every change is applied and saved at once.

signal changed
signal closed


func build(theme_: Theme) -> void:
	theme = theme_
	custom_minimum_size = Vector2(560, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", Design.S3)
	add_child(v)
	var title := Label.new()
	title.text = "Настройки"
	title.add_theme_font_size_override("font_size", Design.FS_H2)
	title.add_theme_color_override("font_color", Design.C_GOLD)
	v.add_child(title)
	# graphics
	v.add_child(_section("Графика"))
	var q := OptionButton.new()
	for k in GameSettings.QUALITY:
		q.add_item(GameSettings.QUALITY_NAMES[k])
	q.selected = GameSettings.QUALITY.find(GameSettings.get_value("quality"))
	q.item_selected.connect(func(i: int):
		GameSettings.set_value("quality", GameSettings.QUALITY[i])
		changed.emit())
	v.add_child(_row("Профиль качества (тайлы карты, число подписей)", q))
	var rm := CheckBox.new()
	rm.text = "Уменьшить движение (без анимаций панелей и дрейфа фона)"
	rm.button_pressed = GameSettings.reduce_motion()
	rm.toggled.connect(func(on: bool):
		GameSettings.set_value("reduce_motion", on)
		changed.emit())
	v.add_child(rm)
	v.add_child(_slider_row("Масштаб интерфейса", "ui_scale", 0.8, 1.6, 0.05))
	# sound
	v.add_child(_section("Звук"))
	v.add_child(_slider_row("Общая громкость", "vol_master", 0.0, 1.0, 0.05))
	v.add_child(_slider_row("Звуки интерфейса", "vol_ui", 0.0, 1.0, 0.05))
	v.add_child(_slider_row("Музыка", "vol_music", 0.0, 1.0, 0.05))
	var close := Button.new()
	close.text = "Готово"
	close.custom_minimum_size = Vector2(0, Design.BTN_H)
	close.pressed.connect(func(): closed.emit())
	v.add_child(close)


func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Design.C_TEXT_DIM)
	l.add_theme_font_size_override("font_size", Design.FS_CAPTION)
	return l


func _row(label: String, ctl: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", Design.S3)
	var l := Label.new()
	l.text = label
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	h.add_child(ctl)
	return h


func _slider_row(label: String, key: String, lo: float, hi: float, step: float) -> HBoxContainer:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(GameSettings.get_value(key))
	s.custom_minimum_size = Vector2(200, Design.BTN_H)
	s.focus_mode = Control.FOCUS_NONE
	var pct := Label.new()
	pct.custom_minimum_size = Vector2(48, 0)
	pct.text = "%d%%" % int(round(s.value * 100.0))
	s.value_changed.connect(func(val: float):
		GameSettings.set_value(key, val)
		pct.text = "%d%%" % int(round(val * 100.0))
		changed.emit())
	var h := _row(label, s)
	h.add_child(pct)
	return h
