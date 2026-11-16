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
const REASONS := {
	"not enough funds": "не хватает денег", "not enough steel": "не хватает стали",
	"seller has no surplus": "у продавца нет излишков", "no trade route": "нет торгового пути",
	"cannot afford": "не хватает денег для сделки", "too many deals": "слишком много сделок",
	"human target": "партнёр — игрок", "queue full": "очередь заполнена", "missing prerequisite": "нужна предыдущая технология", "already researched or queued": "уже изучено или в очереди", "no manpower": "не хватает людей", "army full": "армия заполнена", "capital lost": "столица потеряна", "not in same province": "армии в разных провинциях", "invalid army": "неверная армия", "refused": "отказано", "no common border": "нет границы",
	"no transport": "нет транспорта", "no route": "нет маршрута", "ally": "это союзник",
	"already embargoed": "эмбарго уже введено", "no embargo": "эмбарго не было", "no port": "нет порта",
	"invalid target": "неверная цель", "not at war": "нет войны", "already at war": "уже война",
}
const EFFECT_NAMES := {
	"income_pct": "доход", "upkeep_pct": "содержание армий", "food_pct": "добыча продовольствия", "coal_pct": "добыча угля",
	"iron_pct": "добыча железа", "oil_pct": "добыча нефти", "steel_pct": "выплавка стали", "manpower_pct": "прирост людей",
	"atk_pct": "атака всех войск", "def_pct": "защита всех войск", "atk_infantry_pct": "атака пехоты", "atk_armor_pct": "атака танков",
	"atk_artillery_pct": "атака артиллерии", "def_infantry_pct": "защита пехоты", "def_armor_pct": "защита танков",
	"def_artillery_pct": "защита артиллерии", "fleet_pct": "сила флота в бою", "supply_pct": "ёмкость снабжения",
	"supply_decay_pct": "дальность снабжения", "attrition_pct": "снижение потерь от нехватки", "research_pct": "скорость исследований",
	"research_slots": "слот исследований",
}
var _tech: PanelContainer
var _tech_buttons := {}
var _tech_queue_box: VBoxContainer
var _eco: PanelContainer
var _eco_dyn: VBoxContainer
var _t_res := 0
var _t_partner := 0
var _t_amount := 3


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
	var pb_bg := StyleBoxFlat.new()
	pb_bg.bg_color = Color(0.13, 0.16, 0.21)
	pb_bg.set_corner_radius_all(3)
	var pb_fill := StyleBoxFlat.new()
	pb_fill.bg_color = Color("c9a23c")
	pb_fill.set_corner_radius_all(3)
	t.set_stylebox("background", "ProgressBar", pb_bg)
	t.set_stylebox("fill", "ProgressBar", pb_fill)
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
	var tech := Button.new()
	tech.text = "Технологии"
	tech.pressed.connect(_toggle_tech)
	hb.add_child(tech)
	var eco := Button.new()
	eco.text = "Экономика"
	eco.pressed.connect(_toggle_eco)
	hb.add_child(eco)
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
	_side.offset_bottom = -180
	_side.custom_minimum_size = Vector2(320, 0)
	_side.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	root.add_child(_side)
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 8)
	_side.add_child(sv)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sv.add_child(scroll)
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 8)
	scroll.add_child(inner)
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(_info)
	_actions = VBoxContainer.new()
	_actions.add_theme_constant_override("separation", 6)
	inner.add_child(_actions)

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
			map.selected_fleet = -1
			map.queue_redraw()
			_refresh_info()


func _on_province_clicked(pid: int) -> void:
	if sim == null or player < 0:
		return
	if map.selected_fleet >= 0 and not sim.fleet_by_id(map.selected_fleet).is_empty():
		var fl := sim.fleet_by_id(map.selected_fleet)
		var rf := sim.apply_command({"type": "move_fleet", "country": player, "fleet": fl["id"], "target": pid})
		if not rf["ok"]:
			_log.append_text("[color=#d9a05a]Приказ флоту отклонён: %s[/color]\n" % _reason(rf["reason"]))
		map.selected_fleet = -1
		map.selected_province = pid
		map.queue_redraw()
		_refresh_info()
		return
	if map.selected_army >= 0 and not sim.army_by_id(map.selected_army).is_empty():
		var a := sim.army_by_id(map.selected_army)
		if a["prov"] != pid:
			var r := sim.apply_command({"type": "move_army", "country": player, "army": a["id"], "target": pid})
			if not r["ok"]:
				_log.append_text("[color=#d9a05a]Приказ отклонён: %s[/color]\n" % _reason(r["reason"]))
			map.selected_army = -1
			map.selected_province = pid
			map.queue_redraw()
			_refresh_info()
			return
	map.selected_province = pid
	map.selected_army = -1
	map.selected_fleet = -1
	map.queue_redraw()
	_refresh_info()


func _refresh_all() -> void:
	_refresh_top()
	_refresh_info()
	if _eco != null and is_instance_valid(_eco):
		_eco_refresh()
	if _tech != null and is_instance_valid(_tech):
		_tech_refresh()
	while log_seen < sim.log_lines.size():
		_log.append_text(sim.log_lines[log_seen] + "\n")
		log_seen += 1


func _refresh_top() -> void:
	if _top_label == null:
		return
	var c: Dictionary = sim.countries[player]
	_top_label.text = "%s   |   %s   |   Казна: %d (%+d/день)   |   Армий: %d   |   Флотов: %d   |   Люди: %d   Сталь: %d   Нефть: %d   Еда: %d   |   Войн: %d" % [
		c["name"], sim.date_string(), c["treasury"], c["income"] - c["upkeep"],
		sim.armies_of(player).size(), sim.fleets_of(player).size(), c["manpower"], c["stock"]["steel"], c["stock"]["oil"], c["stock"]["food"], sim.enemies_of(player).size()]
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
		t += "Море\n"
		var sf := sim.fleets_in(pid)
		for f in sf:
			var m := " ◀" if f["id"] == map.selected_fleet else ""
			t += "Флот #%d  [color=%s]%s[/color]  сила %d%s\n" % [f["id"], sim.countries[f["owner"]]["color"], sim.countries[f["owner"]]["name"], f["strength"], m]
		_info.text = t
		for f in sf:
			if f["owner"] == player:
				var fb := Button.new()
				fb.text = "Выбрать флот #%d (затем клик по морю)" % f["id"]
				fb.pressed.connect(func():
					map.selected_fleet = f["id"]
					map.selected_army = -1
					map.queue_redraw()
					_refresh_info())
				_actions.add_child(fb)
		return
	t += "Рельеф: %s\nНаселение: %d тыс.\nПромышленность: %d\n" % [p["terrain"], p["pop"], p["industry"]]
	var dep := ""
	for r in p["deposits"]:
		dep += "%s +%d  " % [_res_name(r), p["deposits"][r]]
	t += "Добыча: %s\n" % (dep if dep != "" else "—")
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
			t += "#%d  [color=%s]%s[/color]  %s  сила %d  снабж. %d%%%s\n" % [a["id"], sim.countries[a["owner"]]["color"], sim.countries[a["owner"]]["name"], sim.army_label(a), a["strength"], a["supply"], mark]
			if a["gen"] >= 0:
				var gg: Dictionary = sim._general(a["owner"], a["gen"])
				t += "   генерал %s (ур. %d)\n" % [gg["name"], gg["skill"]]
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
	if map.selected_army >= 0:
		_army_tools(sim.army_by_id(map.selected_army), here)
	if o == player and pid == sim.countries[player]["capital"]:
		for ut in sim.unit_defs:
			var u: Dictionary = sim.unit_defs[ut]
			var tb := Button.new()
			tb.text = "Обучить: %s (%d $, %d стали, %d чел.)" % [u["name"], u["cost"], u["steel"], u["manpower"]]
			var target_army := map.selected_army if (map.selected_army >= 0 and not sim.army_by_id(map.selected_army).is_empty() and sim.army_by_id(map.selected_army)["prov"] == pid) else -1
			tb.pressed.connect(func():
				var rt := sim.apply_command({"type": "train_division", "country": player, "unit": ut, "army": target_army})
				if not rt["ok"]:
					_log.append_text("[color=#d9a05a]%s[/color]\n" % _reason(rt["reason"]))
				map.queue_redraw()
				_refresh_all())
			_actions.add_child(tb)
		var rb := Button.new()
		rb.text = "Набрать армию (%d)" % Simulation.ARMY_COST
		rb.disabled = sim.countries[player]["treasury"] < Simulation.ARMY_COST
		rb.pressed.connect(func():
			sim.apply_command({"type": "recruit", "country": player})
			map.queue_redraw()
			_refresh_all())
		_actions.add_child(rb)
	if o == player and sim.is_coastal(pid) and pid == sim.port_of(player):
		var nb := Button.new()
		nb.text = "Построить флот (%d)" % Simulation.FLEET_COST
		nb.disabled = sim.countries[player]["treasury"] < Simulation.FLEET_COST
		nb.pressed.connect(func():
			var rr := sim.apply_command({"type": "build_fleet", "country": player})
			if not rr["ok"]:
				_log.append_text("[color=#d9a05a]%s[/color]\n" % rr["reason"])
			map.queue_redraw()
			_refresh_all())
		_actions.add_child(nb)
	if o >= 0 and o != player:
		_diplomacy_buttons(o)


func _diplomacy_buttons(o: int) -> void:
	var oname: String = sim.countries[o]["name"]
	if sim.allied(player, o):
		_cmd_button("Расторгнуть союз", {"type": "break_alliance", "country": player, "target": o})
	elif sim.at_war(player, o):
		_cmd_button("Предложить мир: %s" % oname, {"type": "propose_peace", "country": player, "target": o})
	else:
		_cmd_button("Предложить союз: %s" % oname, {"type": "propose_alliance", "country": player, "target": o})
		if sim.can_declare_war(player, o):
			_cmd_button("Объявить войну: %s" % oname, {"type": "declare_war", "country": player, "target": o})


func _cmd_button(label: String, cmd: Dictionary) -> void:
	var b := Button.new()
	b.text = label
	b.pressed.connect(func():
		var r := sim.apply_command(cmd)
		var msg := "Выполнено: %s" % label if r["ok"] else "Отказ (%s): %s" % [_reason(r["reason"]), label]
		_log.append_text("[color=%s]%s[/color]\n" % ["#8ac58a" if r["ok"] else "#d9a05a", msg])
		map.queue_redraw()
		_refresh_all())
	_actions.add_child(b)


func _res_name(id: String) -> String:
	for r in sim.res_defs:
		if r["id"] == id:
			return r["name"]
	return id


func _toggle_eco() -> void:
	if _eco != null and is_instance_valid(_eco):
		_eco.queue_free()
		_eco = null
		return
	_eco = PanelContainer.new()
	_eco.theme = _theme
	_eco.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_eco.position = Vector2(12, 62)
	_eco.custom_minimum_size = Vector2(520, 0)
	ui.add_child(_eco)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_eco.add_child(v)
	var h := Label.new()
	h.text = "Экономика и торговля"
	h.add_theme_font_size_override("font_size", 20)
	h.add_theme_color_override("font_color", Color("e0c070"))
	v.add_child(h)
	_eco_dyn = VBoxContainer.new()
	v.add_child(_eco_dyn)
	v.add_child(HSeparator.new())
	# new deal controls
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	var ores := OptionButton.new()
	for r in sim.res_defs:
		ores.add_item(r["name"])
	ores.select(_t_res)
	ores.item_selected.connect(func(i): _t_res = i)
	row.add_child(ores)
	var part := OptionButton.new()
	var partner_ids: Array[int] = []
	for c in sim.countries:
		if c["alive"] and c["id"] != player:
			part.add_item(c["name"])
			partner_ids.append(c["id"])
	if not partner_ids.is_empty():
		part.select(clampi(_t_partner, 0, partner_ids.size() - 1))
	part.item_selected.connect(func(i): _t_partner = i)
	row.add_child(part)
	var amount := SpinBox.new()
	amount.min_value = 1
	amount.max_value = 20
	amount.value = _t_amount
	amount.value_changed.connect(func(val): _t_amount = int(val))
	row.add_child(amount)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	v.add_child(row2)
	var buy := Button.new()
	buy.text = "Купить (в день)"
	buy.pressed.connect(func():
		if partner_ids.is_empty():
			return
		_eco_cmd({"type": "propose_trade", "country": player, "target": partner_ids[clampi(_t_partner, 0, partner_ids.size() - 1)], "res": sim.res_defs[_t_res]["id"], "amount": _t_amount}))
	row2.add_child(buy)
	var emb := Button.new()
	emb.text = "Эмбарго"
	emb.pressed.connect(func():
		if not partner_ids.is_empty():
			_eco_cmd({"type": "embargo", "country": player, "target": partner_ids[clampi(_t_partner, 0, partner_ids.size() - 1)]}))
	row2.add_child(emb)
	var lift := Button.new()
	lift.text = "Снять эмбарго"
	lift.pressed.connect(func():
		if not partner_ids.is_empty():
			_eco_cmd({"type": "lift_embargo", "country": player, "target": partner_ids[clampi(_t_partner, 0, partner_ids.size() - 1)]}))
	row2.add_child(lift)
	var close := Button.new()
	close.text = "Закрыть"
	close.pressed.connect(_toggle_eco)
	row2.add_child(close)
	_eco_refresh()


func _eco_cmd(cmd: Dictionary) -> void:
	var r := sim.apply_command(cmd)
	var ok: bool = r["ok"]
	_log.append_text("[color=%s]%s[/color]\n" % ["#8ac58a" if ok else "#d9a05a", "Готово" if ok else "Отказ: %s" % _reason(r.get("reason", ""))])
	_eco_refresh()
	_refresh_top()


func _eco_refresh() -> void:
	for ch in _eco_dyn.get_children():
		ch.queue_free()
	var c: Dictionary = sim.countries[player]
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 22)
	_eco_dyn.add_child(grid)
	for head in ["Ресурс", "Запас", "Добыча", "Расход", "Баланс"]:
		var l := Label.new()
		l.text = head
		l.add_theme_color_override("font_color", Color("e0c070"))
		grid.add_child(l)
	for r in sim.res_defs:
		var id: String = r["id"]
		var net := sim.net_of(player, id)
		var cells := [r["name"], str(c["stock"][id]), str(c["prod"][id]), str(c["cons"][id]), "%+d" % net]
		for i in cells.size():
			var l := Label.new()
			l.text = cells[i]
			if i == 4:
				l.add_theme_color_override("font_color", Color("d96a5a") if net < 0 else Color("8ac58a"))
			if i == 0 and c["short"].has(id):
				l.add_theme_color_override("font_color", Color("d96a5a"))
			grid.add_child(l)
	var deals := sim.trades_of(player)
	var t := Label.new()
	t.text = "Торговые сделки: %d" % deals.size()
	_eco_dyn.add_child(t)
	for d in deals:
		var hb := HBoxContainer.new()
		var l := Label.new()
		var buying: bool = d["buyer"] == player
		var other: int = d["seller"] if buying else d["buyer"]
		l.text = "%s %s ×%d/день  %s  (цена %d)" % ["Покупка" if buying else "Продажа", _res_name(d["res"]), d["amount"], sim.countries[other]["name"], d["price"]]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(l)
		var cb := Button.new()
		cb.text = "Отменить"
		var did: int = d["id"]
		cb.pressed.connect(func(): _eco_cmd({"type": "cancel_trade", "country": player, "deal": did}))
		hb.add_child(cb)
		_eco_dyn.add_child(hb)
	var emb_names: Array[String] = []
	for e in sim.embargoes:
		if e["a"] == player:
			emb_names.append(sim.countries[e["b"]]["name"])
	if not emb_names.is_empty():
		var el := Label.new()
		el.text = "Ваше эмбарго: " + ", ".join(emb_names)
		_eco_dyn.add_child(el)


func _reason(key: String) -> String:
	return REASONS.get(key, key)


func _army_tools(a: Dictionary, here: Array) -> void:
	if a.is_empty() or a["owner"] != player:
		return
	if a["div"].size() > 1:
		_cmd_button("Отделить дивизию", {"type": "split_army", "country": player, "army": a["id"], "count": 1})
	for b in here:
		if b["owner"] == player and b["id"] != a["id"]:
			_cmd_button("Влить армию #%d" % b["id"], {"type": "merge_armies", "country": player, "army": a["id"], "other": b["id"]})
	for g in sim.countries[player]["generals"]:
		if g["id"] != a["gen"]:
			_cmd_button("Генерал: %s (ур. %d)%s" % [g["name"], g["skill"], " — занят" if g["army"] >= 0 else ""], {"type": "assign_general", "country": player, "army": a["id"], "general": g["id"]})


func _effects_text(t: Dictionary) -> String:
	var parts: Array[String] = []
	for k in t["effects"]:
		var v: int = t["effects"][k]
		if k == "research_slots":
			parts.append("+%d %s" % [v, EFFECT_NAMES[k]])
		else:
			parts.append("%+d%% %s" % [v, EFFECT_NAMES.get(k, k)])
	return ", ".join(parts)


func _toggle_tech() -> void:
	if _tech != null and is_instance_valid(_tech):
		_tech.queue_free()
		_tech = null
		return
	var cats: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/techs.json")).get("categories", [])
	_tech = PanelContainer.new()
	_tech.theme = _theme
	_tech.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_tech.position = Vector2(12, 62)
	_tech.custom_minimum_size = Vector2(900, 560)
	ui.add_child(_tech)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_tech.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var h := Label.new()
	h.text = "Исследования"
	h.add_theme_font_size_override("font_size", 20)
	h.add_theme_color_override("font_color", Color("e0c070"))
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(h)
	var close := Button.new()
	close.text = "Закрыть"
	close.pressed.connect(_toggle_tech)
	head.add_child(close)
	_tech_queue_box = VBoxContainer.new()
	v.add_child(_tech_queue_box)
	v.add_child(HSeparator.new())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	scroll.add_child(body)
	_tech_buttons.clear()
	for cat in cats:
		var cl := Label.new()
		cl.text = cat["name"]
		cl.add_theme_color_override("font_color", Color("e0c070"))
		body.add_child(cl)
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 6)
		body.add_child(flow)
		for id in sim.tech_order:
			var t: Dictionary = sim.tech_defs[id]
			if t["category"] != cat["id"]:
				continue
			var b := Button.new()
			var tid: String = id
			b.pressed.connect(func(): _tech_click(tid))
			flow.add_child(b)
			_tech_buttons[id] = b
	_tech_refresh()


func _tech_click(id: String) -> void:
	var c: Dictionary = sim.countries[player]
	var cmd := {"type": "unqueue_tech", "country": player, "tech": id} if c["queue"].has(id) else {"type": "research", "country": player, "tech": id}
	var r := sim.apply_command(cmd)
	if not r["ok"]:
		_log.append_text("[color=#d9a05a]Отказ: %s[/color]\n" % _reason(r["reason"]))
	_tech_refresh()


func _tech_refresh() -> void:
	var c: Dictionary = sim.countries[player]
	for ch in _tech_queue_box.get_children():
		ch.queue_free()
	var info := Label.new()
	info.text = "Слотов: %d   Очки на слот: %d/день   Изучено: %d / %d" % [sim.research_slots(player), sim.research_points(player), c["techs"].size(), sim.tech_defs.size()]
	_tech_queue_box.add_child(info)
	var active := 0
	for id in c["queue"]:
		var t: Dictionary = sim.tech_defs[id]
		var row := HBoxContainer.new()
		var runs: bool = active < sim.research_slots(player) and sim.tech_reqs_met(player, id)
		if runs:
			active += 1
		var l := Label.new()
		l.text = ("▶ " if runs else "⏳ ") + t["name"]
		l.custom_minimum_size = Vector2(280, 0)
		row.add_child(l)
		var bar := ProgressBar.new()
		bar.max_value = t["cost"]
		bar.value = c["progress"].get(id, 0)
		bar.custom_minimum_size = Vector2(300, 18)
		bar.show_percentage = false
		row.add_child(bar)
		_tech_queue_box.add_child(row)
	for id in _tech_buttons:
		var t: Dictionary = sim.tech_defs[id]
		var b: Button = _tech_buttons[id]
		var done: bool = c["techs"].has(id)
		var queued: bool = c["queue"].has(id)
		var avail := true
		for r in t["requires"]:
			if not c["techs"].has(r) and not c["queue"].has(r):
				avail = false
		if done:
			b.text = "✓ " + t["name"]
		elif queued:
			b.text = "⏳ %s  (%d%%)" % [t["name"], 100 * c["progress"].get(id, 0) / t["cost"]]
		else:
			b.text = "%s  [%d]" % [t["name"], t["cost"]]
		b.disabled = done or (not queued and not avail)
		var req_names: Array[String] = []
		for r in t["requires"]:
			req_names.append(sim.tech_defs[r]["name"])
		b.tooltip_text = "%s\nСтоимость: %d\n%s" % [_effects_text(t), t["cost"], ("Требует: " + ", ".join(req_names)) if not req_names.is_empty() else "Без требований"]
