extends Node
## Game shell: main menu -> country selection -> HUD loop.
## UI is built in code with a shared dark theme; the simulation stays headless.

const SPEEDS := [0.0, 1.0, 3.0, 8.0, 20.0]

var sim: Simulation
var map: MapView
var ui: CanvasLayer
var player := -1
var speed_idx := 1
var accum := 0.0
var log_seen := 0

var _top: PanelContainer
var _side: PanelContainer
var _log: RichTextLabel
var _top_label: Label
var _info: RichTextLabel
var _actions: VBoxContainer
var _speed_buttons: Array[Button] = []
var _theme: Theme
var _seed_edit: LineEdit
var _menu_root: Control


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("0b1119"))
	_theme = _make_theme()
	map = MapView.new()
	map.province_clicked.connect(_on_province_clicked)
	add_child(map)
	ui = CanvasLayer.new()
	add_child(ui)
	_show_menu()


func _make_theme() -> Theme:
	var t := Theme.new()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.07, 0.09, 0.12, 0.93)
	panel.border_color = Color(0.75, 0.62, 0.3, 0.55)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(4)
	panel.set_content_margin_all(10)
	t.set_stylebox("panel", "PanelContainer", panel)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(3)
		sb.set_content_margin_all(6)
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.border_color = Color(0.75, 0.62, 0.3, 0.6)
		sb.set_border_width_all(1)
		match state:
			"normal": sb.bg_color = Color(0.13, 0.16, 0.21)
			"hover": sb.bg_color = Color(0.2, 0.25, 0.32)
			"pressed": sb.bg_color = Color(0.45, 0.36, 0.14)
			"disabled": sb.bg_color = Color(0.09, 0.1, 0.12)
		t.set_stylebox(state, "Button", sb)
	t.set_color("font_color", "Button", Color("e8e2d0"))
	t.set_color("font_disabled_color", "Button", Color(0.5, 0.5, 0.5))
	t.set_color("font_color", "Label", Color("e8e2d0"))
	t.set_font_size("font_size", "Label", 15)
	t.set_font_size("font_size", "Button", 15)
	t.set_font_size("normal_font_size", "RichTextLabel", 14)
	t.set_color("default_color", "RichTextLabel", Color("d8d2c0"))
	return t


func _clear_ui() -> void:
	for c in ui.get_children():
		c.queue_free()
	_speed_buttons.clear()


# ------------------------------------------------------------------ menu

func _show_menu() -> void:
	_clear_ui()
	player = -1
	sim = null
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = _theme
	ui.add_child(root)
	var bg := ColorRect.new()
	bg.color = Color("0b1119")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(360, 0)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 14)
	root.add_child(box)
	var title := Label.new()
	title.text = "IRON DOMINION"
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color("e0c070"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var sub := Label.new()
	sub.text = "Глобальная стратегия"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)
	_seed_edit = LineEdit.new()
	_seed_edit.text = str(randi() % 100000)
	_seed_edit.placeholder_text = "Seed мира"
	box.add_child(_seed_edit)
	var start := Button.new()
	start.text = "Новая игра"
	start.pressed.connect(_new_game)
	box.add_child(start)
	var load_btn := Button.new()
	load_btn.text = "Загрузить (F9)"
	load_btn.pressed.connect(_load_game)
	box.add_child(load_btn)
	var quit := Button.new()
	quit.text = "Выход"
	quit.pressed.connect(func(): get_tree().quit())
	box.add_child(quit)
	_menu_root = root


func _new_game() -> void:
	var s := int(_seed_edit.text) if _seed_edit.text.is_valid_int() else hash(_seed_edit.text)
	sim = Simulation.new()
	sim.setup(s, Simulation.load_country_defs())
	map.bind(sim)
	_show_country_select()


func _load_game() -> void:
	var loaded := SaveSystem.load_slot("quick")
	if loaded == null:
		return
	sim = loaded
	map.bind(sim)
	var pid := 0
	for c in sim.countries:
		if not c["ai"]:
			pid = c["id"]
	_start_playing(pid)


func _show_country_select() -> void:
	_clear_ui()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = _theme
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(root)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	panel.position = Vector2(20, 0)
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var h := Label.new()
	h.text = "Выберите государство"
	h.add_theme_font_size_override("font_size", 20)
	h.add_theme_color_override("font_color", Color("e0c070"))
	v.add_child(h)
	for c in sim.countries:
		var b := Button.new()
		var cid: int = c["id"]
		b.text = "%s  (%d пров.)" % [c["name"], sim.country_provinces(cid).size()]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var sb: StyleBoxFlat = _theme.get_stylebox("normal", "Button").duplicate()
		sb.border_color = Color(c["color"])
		sb.border_width_left = 8
		b.add_theme_stylebox_override("normal", sb)
		b.pressed.connect(_start_playing.bind(cid))
		b.mouse_entered.connect(func():
			map.selected_province = sim.countries[cid]["capital"]
			map.queue_redraw())
		v.add_child(b)
	var back := Button.new()
	back.text = "← Назад"
	back.pressed.connect(_show_menu)
	v.add_child(back)


# -------------------------------------------------------------------- HUD

func _start_playing(cid: int) -> void:
	player = cid
	for c in sim.countries:
		c["ai"] = c["id"] != cid
	map.player_country = cid
	map.selected_province = sim.countries[cid]["capital"]
	map.selected_army = -1
	var cap: Vector2 = sim.provinces()[sim.countries[cid]["capital"]]["center"] * MapView.CELL
	map.camera.position = cap
	map.camera.zoom = Vector2.ONE * 2.0
	log_seen = sim.log_lines.size()
	speed_idx = 0
	_build_hud()
	_refresh_all()


func _build_hud() -> void:
	_clear_ui()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _theme
	ui.add_child(root)

	_top = PanelContainer.new()
	_top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	root.add_child(_top)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	_top.add_child(hb)
	_top_label = Label.new()
	_top_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(_top_label)
	for i in SPEEDS.size():
		var b := Button.new()
		b.text = "⏸" if i == 0 else "▶".repeat(i)
		b.pressed.connect(_set_speed.bind(i))
		hb.add_child(b)
		_speed_buttons.append(b)
	var mode := Button.new()
	mode.text = "Карта: политика"
	mode.pressed.connect(func():
		map.map_mode = "terrain" if map.map_mode == "political" else "political"
		mode.text = "Карта: рельеф" if map.map_mode == "terrain" else "Карта: политика"
		map.repaint_all())
	hb.add_child(mode)
	var save := Button.new()
	save.text = "Сохранить"
	save.pressed.connect(func(): SaveSystem.save(sim, "quick"))
	hb.add_child(save)
	var menu := Button.new()
	menu.text = "Меню"
	menu.pressed.connect(_show_menu)
	hb.add_child(menu)

	_side = PanelContainer.new()
	_side.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_side.offset_top = 64
	_side.offset_bottom = -190
	_side.custom_minimum_size = Vector2(320, 0)
	_side.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	root.add_child(_side)
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 8)
	_side.add_child(sv)
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sv.add_child(_info)
	_actions = VBoxContainer.new()
	_actions.add_theme_constant_override("separation", 6)
	sv.add_child(_actions)

	var log_panel := PanelContainer.new()
	log_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	log_panel.offset_top = -170
	log_panel.offset_right = -340
	root.add_child(log_panel)
	_log = RichTextLabel.new()
	_log.scroll_following = true
	_log.bbcode_enabled = true
	log_panel.add_child(_log)


func _set_speed(i: int) -> void:
	speed_idx = i
	_refresh_top()


func _process(delta: float) -> void:
	if sim == null or player < 0:
		return
	var rate: float = SPEEDS[speed_idx]
	if rate <= 0.0:
		return
	accum += delta * rate
	var stepped := false
	var guard := 0
	while accum >= 1.0 and guard < 30:
		accum -= 1.0
		guard += 1
		sim.tick_day()
		stepped = true
	if stepped:
		var dirty := sim.dirty_provinces.duplicate()
		sim.dirty_provinces.clear()
		map.refresh(dirty)
		_refresh_all()
		if not sim.countries[player]["alive"]:
			speed_idx = 0
			_log.append_text("[color=#d96a5a]Ваше государство уничтожено.[/color]\n")


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo or sim == null or player < 0:
		return
	match (event as InputEventKey).keycode:
		KEY_SPACE: _set_speed(0 if speed_idx > 0 else 1)
		KEY_1: _set_speed(1)
		KEY_2: _set_speed(2)
		KEY_3: _set_speed(3)
		KEY_4: _set_speed(4)
		KEY_F5: SaveSystem.save(sim, "quick")
		KEY_ESCAPE:
			map.selected_army = -1
			map.queue_redraw()
			_refresh_info()


func _on_province_clicked(pid: int) -> void:
	if sim == null or player < 0:
		return
	if map.selected_army >= 0 and not sim.army_by_id(map.selected_army).is_empty():
		var a := sim.army_by_id(map.selected_army)
		if a["prov"] != pid:
			var r := sim.apply_command({"type": "move_army", "country": player, "army": a["id"], "target": pid})
			if not r["ok"]:
				_log.append_text("[color=#d9a05a]Приказ отклонён: %s[/color]\n" % r["reason"])
			map.selected_army = -1
			map.selected_province = pid
			map.queue_redraw()
			_refresh_info()
			return
	map.selected_province = pid
	map.selected_army = -1
	map.queue_redraw()
	_refresh_info()


func _refresh_all() -> void:
	_refresh_top()
	_refresh_info()
	while log_seen < sim.log_lines.size():
		_log.append_text(sim.log_lines[log_seen] + "\n")
		log_seen += 1


func _refresh_top() -> void:
	if _top_label == null:
		return
	var c: Dictionary = sim.countries[player]
	_top_label.text = "%s   |   %s   |   Казна: %d (%+d/день)   |   Армий: %d   |   Войн: %d" % [
		c["name"], sim.date_string(), c["treasury"], c["income"] - c["upkeep"],
		sim.armies_of(player).size(), sim.enemies_of(player).size()]
	for i in _speed_buttons.size():
		_speed_buttons[i].disabled = i == speed_idx


func _refresh_info() -> void:
	if _info == null:
		return
	for ch in _actions.get_children():
		ch.queue_free()
	var pid := map.selected_province
	if pid < 0:
		_info.text = "Выберите провинцию."
		return
	var p: Dictionary = sim.provinces()[pid]
	var o := sim.owner[pid]
	var t := "[b]Провинция #%d[/b]\n" % pid
	if not p["land"]:
		t += "Море"
		_info.text = t
		return
	t += "Рельеф: %s\nНаселение: %d тыс.\nПромышленность: %d\n" % [p["terrain"], p["pop"], p["industry"]]
	if o >= 0:
		var oc: Dictionary = sim.countries[o]
		t += "Владелец: [color=%s]%s[/color]\n" % [oc["color"], oc["name"]]
		if o != player:
			t += "Отношения: %s\n" % ("[color=#d96a5a]ВОЙНА[/color]" if sim.at_war(player, o) else "мир")
	else:
		t += "Владелец: нейтральная\n"
	var here := sim.armies_in(pid)
	if not here.is_empty():
		t += "\n[b]Армии:[/b]\n"
		for a in here:
			var mark := " ◀" if a["id"] == map.selected_army else ""
			t += "#%d  [color=%s]%s[/color]  сила %d%s\n" % [a["id"], sim.countries[a["owner"]]["color"], sim.countries[a["owner"]]["name"], a["strength"], mark]
	_info.text = t

	# actions
	for a in here:
		if a["owner"] == player:
			var b := Button.new()
			b.text = "Выбрать армию #%d (затем клик по цели)" % a["id"]
			b.pressed.connect(func():
				map.selected_army = a["id"]
				map.queue_redraw()
				_refresh_info())
			_actions.add_child(b)
	if o == player and pid == sim.countries[player]["capital"]:
		var rb := Button.new()
		rb.text = "Набрать армию (%d)" % Simulation.ARMY_COST
		rb.disabled = sim.countries[player]["treasury"] < Simulation.ARMY_COST
		rb.pressed.connect(func():
			sim.apply_command({"type": "recruit", "country": player})
			map.queue_redraw()
			_refresh_all())
		_actions.add_child(rb)
	if o >= 0 and o != player and not sim.at_war(player, o) and sim.neighbor_countries(player).has(o):
		var wb := Button.new()
		wb.text = "Объявить войну: %s" % sim.countries[o]["name"]
		wb.pressed.connect(func():
			var r := sim.apply_command({"type": "declare_war", "country": player, "target": o})
			if not r["ok"]:
				_log.append_text("[color=#d9a05a]%s[/color]\n" % r["reason"])
			_refresh_all())
		_actions.add_child(wb)
