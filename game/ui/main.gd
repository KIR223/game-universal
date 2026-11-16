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
	"human target": "партнёр — игрок", "invalid province": "неверная провинция", "already maximal": "уже максимальный уровень", "invalid operation": "неверная операция", "no free agents": "нет свободных агентов", "network too weak": "сеть слишком слаба", "already running": "уже выполняется", "invalid law": "неверный закон", "already in force": "уже действует", "not enough influence": "не хватает политического влияния", "on cooldown": "ещё нельзя повторить", "requirements not met": "условия не выполнены", "invalid decision": "неверное решение", "no such event": "событие не найдено", "invalid option": "неверный вариант", "airbase full": "аэродром переполнен", "invalid base": "неверный аэродром", "out of range": "вне радиуса действия", "wrong aircraft for mission": "эта авиация не подходит для задачи", "land target required": "нужна сухопутная цель", "target not at war": "нет войны с владельцем", "invalid wing": "неверная авиагруппа", "queue full": "очередь заполнена", "missing prerequisite": "нужна предыдущая технология", "already researched or queued": "уже изучено или в очереди", "no manpower": "не хватает людей", "army full": "армия заполнена", "capital lost": "столица потеряна", "not in same province": "армии в разных провинциях", "invalid army": "неверная армия", "refused": "отказано", "no common border": "нет границы",
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
var _pending_air := ""
var _intel: PanelContainer
var _intel_body: VBoxContainer
var _i_op := 0
var _i_target := 0
var _pol: PanelContainer
var _pol_body: VBoxContainer
var _event_panel: PanelContainer
var _event_uid := -1
var _pol_day := -1
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
	for state in ["normal", "focus", "read_only"]:
		var le := StyleBoxFlat.new()
		le.bg_color = Color(0.1, 0.12, 0.16)
		le.border_color = Color(0.75, 0.62, 0.3, 0.7 if state == "focus" else 0.35)
		le.set_border_width_all(1)
		le.set_corner_radius_all(3)
		le.set_content_margin_all(5)
		t.set_stylebox(state, "LineEdit", le)
	var te := StyleBoxFlat.new()
	te.bg_color = Color(0.1, 0.12, 0.16)
	te.border_color = Color(0.75, 0.62, 0.3, 0.35)
	te.set_border_width_all(1)
	te.set_content_margin_all(5)
	t.set_stylebox("normal", "TextEdit", te)
	t.set_stylebox("focus", "TextEdit", te)
	t.set_color("font_color", "LineEdit", Color("e8e2d0"))
	t.set_color("font_color", "TextEdit", Color("e8e2d0"))
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
	t.set_font_size("font_size", "Button", 14)
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
	start.text = "Новая игра (случайный мир)"
	start.pressed.connect(_new_game)
	box.add_child(start)
	var scen := Button.new()
	scen.text = "Сценарии"
	scen.pressed.connect(_show_scenarios)
	box.add_child(scen)
	var edit := Button.new()
	edit.text = "Редактор сценариев"
	edit.pressed.connect(func(): _open_editor(ScenarioLoader.blank(int(_seed_edit.text) if _seed_edit.text.is_valid_int() else randi() % 100000)))
	box.add_child(edit)
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


func _start_scenario(scn: Dictionary) -> void:
	var fresh := Simulation.new()
	var problems := fresh.setup_scenario(scn)
	if not problems.is_empty() and fresh.world.is_empty():
		_show_scenarios("Сценарий не загружен: " + "; ".join(problems.slice(0, 3)))
		return
	sim = fresh
	map.bind(sim)
	map.player_country = -1
	_show_country_select()


func _show_scenarios(message: Variant = "") -> void:
	_clear_ui()
	player = -1
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
	box.custom_minimum_size = Vector2(620, 0)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 10)
	root.add_child(box)
	var title := Label.new()
	title.text = "Сценарии"
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color("e0c070"))
	box.add_child(title)
	if str(message) != "":
		var m := Label.new()
		m.text = str(message)
		m.add_theme_color_override("font_color", Color("d9a05a"))
		m.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(m)
	var seed_row := HBoxContainer.new()
	box.add_child(seed_row)
	var sl := Label.new()
	sl.text = "Seed (пусто — из сценария):"
	seed_row.add_child(sl)
	var seed_override := LineEdit.new()
	seed_override.custom_minimum_size = Vector2(120, 0)
	seed_row.add_child(seed_override)
	for entry in ScenarioLoader.list_all():
		var data: Dictionary = entry["data"]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		box.add_child(row)
		var b := Button.new()
		b.text = "%s%s" % [data.get("name", "?"), "" if entry["builtin"] else "  (пользовательский)"]
		b.tooltip_text = "%s\nСтарт: %s, seed %s, стран: %d" % [data.get("description", ""), data.get("start_date", ""), str(data.get("seed", "")), data.get("countries", []).size()]
		b.custom_minimum_size = Vector2(300, 0)
		b.pressed.connect(func():
			var scn: Dictionary = data.duplicate(true)
			var has_overrides: bool = scn.has("owners") or scn.has("deposits") or scn.has("armies") or scn.has("capitals")
			if seed_override.text.is_valid_int() and not has_overrides:
				scn["seed"] = int(seed_override.text)
			_start_scenario(scn))
		row.add_child(b)
		var d := Label.new()
		d.text = str(data.get("description", ""))
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		d.custom_minimum_size = Vector2(260, 0)
		row.add_child(d)
		var eb := Button.new()
		eb.text = "Править"
		eb.pressed.connect(func(): _open_editor(data))
		row.add_child(eb)
	var back := Button.new()
	back.text = "← Назад"
	back.pressed.connect(_show_menu)
	box.add_child(back)


func _open_editor(scn: Dictionary) -> void:
	_clear_ui()
	player = -1
	var ed := ScenarioEditor.new()
	ui.add_child(ed)
	ed.start(map, _theme, scn)
	ed.closed.connect(_show_menu)
	ed.play_requested.connect(func(s: Dictionary):
		_clear_ui()
		_start_scenario(s))


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
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	_top.add_child(vb)
	_top_label = Label.new()
	vb.add_child(_top_label)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	vb.add_child(hb)
	for i in SPEEDS.size():
		var b := Button.new()
		b.text = "⏸" if i == 0 else "▶".repeat(mini(i, 3)) + ("+" if i == 4 else "")
		b.pressed.connect(_set_speed.bind(i))
		hb.add_child(b)
		_speed_buttons.append(b)
	var mode := Button.new()
	mode.text = "Карта"
	mode.pressed.connect(func():
		map.map_mode = "terrain" if map.map_mode == "political" else "political"
		mode.text = "Рельеф" if map.map_mode == "terrain" else "Карта"
		map.repaint_all())
	hb.add_child(mode)
	var intb := Button.new()
	intb.text = "Разведка"
	intb.pressed.connect(_toggle_intel)
	hb.add_child(intb)
	var polb := Button.new()
	polb.text = "Политика"
	polb.pressed.connect(_toggle_pol)
	hb.add_child(polb)
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
	_side.offset_top = 96
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
	if rate <= 0.0 or (_event_panel != null and is_instance_valid(_event_panel)):
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
			map.selected_wing = -1
			_pending_air = ""
			map.queue_redraw()
			_refresh_info()


func _on_province_clicked(pid: int) -> void:
	if sim == null or player < 0:
		return
	if map.selected_wing >= 0 and _pending_air != "" and not sim.wing_by_id(map.selected_wing).is_empty():
		var cmd: Dictionary
		if _pending_air == "rebase":
			cmd = {"type": "rebase", "country": player, "wing": map.selected_wing, "base": pid}
		else:
			cmd = {"type": "air_mission", "country": player, "wing": map.selected_wing, "mission": _pending_air, "target": pid}
		var ra := sim.apply_command(cmd)
		if not ra["ok"]:
			_log.append_text("[color=#d9a05a]Приказ авиации отклонён: %s[/color]\n" % _reason(ra["reason"]))
		_pending_air = ""
		map.selected_province = pid
		map.queue_redraw()
		_refresh_info()
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
	map.selected_wing = -1
	_pending_air = ""
	map.queue_redraw()
	_refresh_info()


func _refresh_all() -> void:
	_refresh_top()
	_refresh_info()
	if _eco != null and is_instance_valid(_eco):
		_eco_refresh()
	if _tech != null and is_instance_valid(_tech):
		_tech_refresh()
	if _pol != null and is_instance_valid(_pol) and sim.day != _pol_day and sim.day % 5 == 0:
		_pol_refresh()
	if _intel != null and is_instance_valid(_intel) and sim.day % 2 == 0:
		_intel_refresh()
	_check_events()
	while log_seen < sim.log_lines.size():
		_log.append_text(sim.log_lines[log_seen] + "\n")
		log_seen += 1


func _refresh_top() -> void:
	if _top_label == null:
		return
	var c: Dictionary = sim.countries[player]
	_top_label.text = "%s | %s | $%d (%+d) | Арм %d  Флот %d  Авиа %d | Стаб %d%%  Влияние %d | Люди %d  Сталь %d  Нефть %d  Еда %d | Войн %d" % [
		c["name"], sim.date_string(), c["treasury"], c["income"] - c["upkeep"],
		sim.armies_of(player).size(), sim.fleets_of(player).size(), sim.wings_of(player).size(), c["stability"], c["pp"],
		c["manpower"], c["stock"]["steel"], c["stock"]["oil"], c["stock"]["food"], sim.enemies_of(player).size()]
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
	t += "Инфраструктура: %d%s\n" % [sim.infra[pid], (" (из-за разрушений %d)" % sim.eff_infra(pid)) if sim.eff_infra(pid) != sim.infra[pid] else ""]
	if sim.damage[pid] > 0:
		t += "Разрушения от бомбардировок: %d%%\n" % sim.damage[pid]
	var wh := sim.wings_at(pid)
	if not wh.is_empty():
		t += "\n[b]Авиация (аэродром %d/%d):[/b]\n" % [wh.size(), sim.air_capacity(pid)]
		for w in wh:
			var mname := {"idle": "ожидание", "air_superiority": "господство", "bomb": "бомбардировка", "cas": "поддержка войск"}
			t += "#%d [color=%s]%s[/color] %s ×%d — %s%s\n" % [w["id"], sim.countries[w["owner"]]["color"], sim.countries[w["owner"]]["name"], sim.air_defs[w["type"]]["name"], w["strength"], mname.get(w["mission"], ""), " ◀" if w["id"] == map.selected_wing else ""]
	var here := sim.armies_in(pid)
	if not here.is_empty():
		t += "\n[b]Армии:[/b]\n"
		for a in here:
			var mark := " ◀" if a["id"] == map.selected_army else ""
			var seen := sim.perceived_strength(player, a)
			if seen < 0:
				t += "#%d  [color=%s]%s[/color]  состав и сила неизвестны (нужна разведка)%s\n" % [a["id"], sim.countries[a["owner"]]["color"], sim.countries[a["owner"]]["name"], mark]
			elif a["owner"] == player or sim.allied(player, a["owner"]):
				t += "#%d  [color=%s]%s[/color]  %s  сила %d  снабж. %d%%%s\n" % [a["id"], sim.countries[a["owner"]]["color"], sim.countries[a["owner"]]["name"], sim.army_label(a), a["strength"], a["supply"], mark]
			else:
				t += "#%d  [color=%s]%s[/color]  %s  сила ≈%d%s\n" % [a["id"], sim.countries[a["owner"]]["color"], sim.countries[a["owner"]]["name"], sim.army_label(a), seen, mark]
			if a["gen"] >= 0 and seen >= 0:
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
	for w in wh:
		if w["owner"] == player:
			var wb2 := Button.new()
			wb2.text = "Выбрать авиагруппу #%d" % w["id"]
			var wid: int = w["id"]
			wb2.pressed.connect(func():
				map.selected_wing = wid
				map.selected_army = -1
				_pending_air = ""
				map.queue_redraw()
				_refresh_info())
			_actions.add_child(wb2)
	if map.selected_wing >= 0:
		_air_tools(sim.wing_by_id(map.selected_wing))
	if o == player and sim.infra[pid] < Simulation.MAX_INFRA:
		_cmd_button("Улучшить инфраструктуру до %d (%d $, 15 стали)" % [sim.infra[pid] + 1, 60 + 20 * sim.infra[pid]], {"type": "build_infra", "country": player, "province": pid})
	if o == player:
		for at in sim.air_defs:
			var ad: Dictionary = sim.air_defs[at]
			var ab := Button.new()
			ab.text = "Авиагруппа: %s (%d $, %d стали, %d чел.)" % [ad["name"], ad["cost"], ad["steel"], ad["manpower"]]
			ab.disabled = wh.size() >= sim.air_capacity(pid)
			ab.pressed.connect(func():
				var rw := sim.apply_command({"type": "build_wing", "country": player, "type_air": at, "base": pid})
				if not rw["ok"]:
					_log.append_text("[color=#d9a05a]%s[/color]\n" % _reason(rw["reason"]))
				map.queue_redraw()
				_refresh_all())
			_actions.add_child(ab)
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
	_eco.position = Vector2(12, 96)
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
	if c["blockade"] > 0:
		var bl := Label.new()
		bl.text = "Блокада портов: %d%% (доход снижен, морская торговля нарушена)" % c["blockade"]
		bl.add_theme_color_override("font_color", Color("d96a5a"))
		_eco_dyn.add_child(bl)
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
	var cats: Array = JSON.parse_string(Simulation.read_data("techs.json")).get("categories", [])
	_tech = PanelContainer.new()
	_tech.theme = _theme
	_tech.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_tech.position = Vector2(12, 96)
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


func _air_tools(w: Dictionary) -> void:
	if w.is_empty() or w["owner"] != player:
		return
	var l := Label.new()
	l.text = "Авиагруппа #%d: %s, дальность %d" % [w["id"], sim.air_defs[w["type"]]["name"], sim.air_range(player, w["type"])]
	_actions.add_child(l)
	var missions := {"fighter": ["air_superiority", "Господство в воздухе"], "bomber": ["bomb", "Бомбардировка"], "attacker": ["cas", "Поддержка войск"]}
	var m: Array = missions[w["type"]]
	var b := Button.new()
	b.text = "%s — затем клик по цели%s" % [m[1], " ◀" if _pending_air == m[0] else ""]
	b.pressed.connect(func():
		_pending_air = m[0]
		_log.append_text("[color=#8ac5ff]%s: выберите цель на карте[/color]\n" % m[1])
		_refresh_info())
	_actions.add_child(b)
	var rb := Button.new()
	rb.text = "Перебазировать — затем клик по аэродрому"
	rb.pressed.connect(func():
		_pending_air = "rebase"
		_log.append_text("[color=#8ac5ff]Выберите новый аэродром[/color]\n")
		_refresh_info())
	_actions.add_child(rb)
	_cmd_button("Отбой (ожидание)", {"type": "air_mission", "country": player, "wing": w["id"], "mission": "idle", "target": -1})


# ---------------------------------------------------------------- politics UI

func _effect_text(ef: Dictionary) -> String:
	var v: int = int(ef.get("value", 0))
	match ef["type"]:
		"stability": return "%+d стабильность" % v
		"war_support": return "%+d поддержка войны" % v
		"treasury": return "%+d $" % v
		"treasury_pct": return "%+d%% казны" % v
		"stock": return "%+d %s" % [v, _res_name(ef["res"]).to_lower()]
		"manpower": return "%+d людей" % v
		"pp": return "%+d влияния" % v
		"popularity": return "%+d%% партии «%s»" % [v, sim.ideo_defs[ef["ideology"]]["name"]]
		"popularity_ruling": return "%+d%% правящей партии" % v
		"modifier": return "%+d%% %s на %d дн." % [v, EFFECT_NAMES.get(ef["key"], ef["key"]), int(ef["days"])]
		"tech_progress": return "+%d очков исследования" % v
		"army_exp": return "+%d опыта армиям" % v
	return ef["type"]


func _effects_list(effects: Array) -> String:
	var parts: Array[String] = []
	for ef in effects:
		parts.append(_effect_text(ef))
	return ", ".join(parts)


func _check_events() -> void:
	if _event_panel != null and is_instance_valid(_event_panel):
		return
	var pend: Array = sim.countries[player]["pending"]
	if pend.is_empty():
		return
	speed_idx = 0
	_refresh_top()
	var p: Dictionary = pend[0]
	var e := sim.event_def(p["event"])
	_event_uid = p["uid"]
	_event_panel = PanelContainer.new()
	_event_panel.theme = _theme
	_event_panel.set_anchors_preset(Control.PRESET_CENTER)
	_event_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_event_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_event_panel.custom_minimum_size = Vector2(560, 0)
	ui.add_child(_event_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_event_panel.add_child(v)
	var t := Label.new()
	t.text = e["title"]
	t.add_theme_font_size_override("font_size", 22)
	t.add_theme_color_override("font_color", Color("e0c070"))
	v.add_child(t)
	var d := Label.new()
	d.text = e["desc"]
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(d)
	for i in e["options"].size():
		var o: Dictionary = e["options"][i]
		var b := Button.new()
		b.text = "%s\n(%s)" % [o["text"], _effects_list(o["effects"])]
		b.pressed.connect(func():
			var uid := _event_uid
			sim.apply_command({"type": "event_choice", "country": player, "uid": uid, "option": i})
			_event_panel.queue_free()
			_event_panel = null
			_refresh_all())
		v.add_child(b)


func _toggle_pol() -> void:
	if _pol != null and is_instance_valid(_pol):
		_pol.queue_free()
		_pol = null
		return
	_pol = PanelContainer.new()
	_pol.theme = _theme
	_pol.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_pol.position = Vector2(12, 96)
	_pol.custom_minimum_size = Vector2(760, 560)
	ui.add_child(_pol)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_pol.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var h := Label.new()
	h.text = "Политика"
	h.add_theme_font_size_override("font_size", 20)
	h.add_theme_color_override("font_color", Color("e0c070"))
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(h)
	var close := Button.new()
	close.text = "Закрыть"
	close.pressed.connect(_toggle_pol)
	head.add_child(close)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_pol_body = VBoxContainer.new()
	_pol_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pol_body.add_theme_constant_override("separation", 6)
	scroll.add_child(_pol_body)
	_pol_refresh()


func _bar(label: String, value: int, color: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(230, 0)
	row.add_child(l)
	var b := ProgressBar.new()
	b.max_value = 100
	b.value = value
	b.custom_minimum_size = Vector2(300, 18)
	b.show_percentage = false
	b.add_theme_stylebox_override("fill", _flat(color))
	row.add_child(b)
	var n := Label.new()
	n.text = " %d%%" % value
	row.add_child(n)
	return row


func _flat(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(3)
	return sb


func _pol_refresh() -> void:
	_pol_day = sim.day
	for ch in _pol_body.get_children():
		ch.queue_free()
	var c: Dictionary = sim.countries[player]
	var ideo: Dictionary = sim.ideo_defs[c["ideology"]]
	var hl := Label.new()
	hl.text = "Правительство: %s   |   Политическое влияние: %d (+1/день)" % [ideo["name"], c["pp"]]
	hl.add_theme_color_override("font_color", Color(ideo["color"]))
	_pol_body.add_child(hl)
	var sc := Color("8ac58a") if c["stability"] >= 50 else (Color("d9a05a") if c["stability"] >= 25 else Color("d96a5a"))
	_pol_body.add_child(_bar("Стабильность (цель %d%%)" % sim._stability_target(c), c["stability"], sc))
	_pol_body.add_child(_bar("Поддержка войны (цель %d%%)" % sim._war_support_target(c), c["war_support"], Color("c9a23c")))
	var pl := Label.new()
	pl.text = "Партии"
	pl.add_theme_color_override("font_color", Color("e0c070"))
	_pol_body.add_child(pl)
	for i in sim.ideo_order:
		_pol_body.add_child(_bar(sim.ideo_defs[i]["name"] + (" (у власти)" if i == c["ideology"] else ""), c["party_pop"][i], Color(sim.ideo_defs[i]["color"])))
	if ideo["elections"]:
		var next_el := 100 + 40 * player
		while next_el < sim.day:
			next_el += 365
		var el := Label.new()
		el.text = "Следующие выборы: через %d дн." % (next_el - sim.day)
		_pol_body.add_child(el)
	var ll := Label.new()
	ll.text = "Законы"
	ll.add_theme_color_override("font_color", Color("e0c070"))
	_pol_body.add_child(ll)
	for cat in sim.law_defs:
		var row := HBoxContainer.new()
		var cl := Label.new()
		cl.text = sim.law_defs[cat]["name"] + ":"
		cl.custom_minimum_size = Vector2(110, 0)
		row.add_child(cl)
		for o in sim.law_defs[cat]["options"]:
			var b := Button.new()
			var current: bool = c["laws"][cat] == o["id"]
			b.text = ("● " if current else "") + o["name"] + ("" if current or o["cost"] == 0 else " (%d)" % o["cost"])
			b.disabled = current or c["pp"] < o["cost"]
			b.tooltip_text = _effects_list([{"type": "stability", "value": o.get("stability", 0)}, {"type": "war_support", "value": o.get("war_support", 0)}]) + (", " + ", ".join(_mod_texts(o["mods"])) if not o["mods"].is_empty() else "")
			var cat_id: String = cat
			var law_id: String = o["id"]
			b.pressed.connect(func():
				_pol_cmd({"type": "set_law", "country": player, "category": cat_id, "law": law_id}))
			row.add_child(b)
		_pol_body.add_child(row)
	var dl := Label.new()
	dl.text = "Национальные решения"
	dl.add_theme_color_override("font_color", Color("e0c070"))
	_pol_body.add_child(dl)
	for dd in sim.decision_defs:
		var err := sim._decision_error(c, dd)
		var b := Button.new()
		var cost: Dictionary = dd["cost"]
		var cost_txt := "%d влияния" % cost.get("pp", 0)
		if cost.get("treasury", 0) > 0:
			cost_txt += ", %d $" % cost["treasury"]
		b.text = "%s  [%s]" % [dd["name"], cost_txt]
		b.disabled = err != ""
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var left: int = int(dd["cooldown"]) - (sim.day - c["done"].get(dd["id"], -99999))
		b.tooltip_text = "%s\nЭффект: %s%s" % [dd["desc"], _effects_list(dd["effects"]), ("\nМожно повторить через %d дн." % left) if err == "on cooldown" else ""]
		var did: String = dd["id"]
		b.pressed.connect(func():
			_pol_cmd({"type": "decision", "country": player, "id": did}))
		_pol_body.add_child(b)


func _mod_texts(mods: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for k in mods:
		out.append("%+d%% %s" % [mods[k], EFFECT_NAMES.get(k, k)])
	return out


func _pol_cmd(cmd: Dictionary) -> void:
	var r := sim.apply_command(cmd)
	if not r["ok"]:
		_log.append_text("[color=#d9a05a]Отказ: %s[/color]\n" % _reason(r["reason"]))
	_pol_refresh()
	_refresh_top()


# ------------------------------------------------------------ intelligence UI

func _toggle_intel() -> void:
	if _intel != null and is_instance_valid(_intel):
		_intel.queue_free()
		_intel = null
		return
	_intel = PanelContainer.new()
	_intel.theme = _theme
	_intel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_intel.position = Vector2(12, 96)
	_intel.custom_minimum_size = Vector2(720, 520)
	ui.add_child(_intel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_intel.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var h := Label.new()
	h.text = "Разведка"
	h.add_theme_font_size_override("font_size", 20)
	h.add_theme_color_override("font_color", Color("e0c070"))
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(h)
	var close := Button.new()
	close.text = "Закрыть"
	close.pressed.connect(_toggle_intel)
	head.add_child(close)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_intel_body = VBoxContainer.new()
	_intel_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_intel_body.add_theme_constant_override("separation", 6)
	scroll.add_child(_intel_body)
	_intel_refresh()


func _intel_cmd(cmd: Dictionary) -> void:
	var r := sim.apply_command(cmd)
	_log.append_text("[color=%s]%s[/color]\n" % ["#8ac58a" if r["ok"] else "#d9a05a", "Операция начата" if r["ok"] else "Отказ: %s" % _reason(r["reason"])])
	_intel_refresh()
	_refresh_top()


func _intel_refresh() -> void:
	for ch in _intel_body.get_children():
		ch.queue_free()
	var c: Dictionary = sim.countries[player]
	var it: Dictionary = c["intel"]
	var info := Label.new()
	info.text = "Агентство: уровень %d (опыт %d)   Агентов: %d/%d   Контрразведка: %d%%%s" % [it["level"], it["xp"], sim.ops_of(player).size(), sim.intel_slots(player), it["counter"], "   Дезинформация активна" if it["disinfo_until"] > sim.day else ""]
	_intel_body.add_child(info)
	var sl := Label.new()
	sl.text = "Агентурные сети"
	sl.add_theme_color_override("font_color", Color("e0c070"))
	_intel_body.add_child(sl)
	var partner_ids: Array[int] = []
	for o in sim.countries:
		if o["alive"] and o["id"] != player:
			partner_ids.append(o["id"])
			_intel_body.add_child(_bar("%s (его контрразведка %d%%)" % [o["name"], o["intel"]["counter"]], sim.net_of_agent(player, o["id"]), Color(o["color"])))
	var al := Label.new()
	al.text = "Активные операции"
	al.add_theme_color_override("font_color", Color("e0c070"))
	_intel_body.add_child(al)
	for op in sim.ops_of(player):
		var row := HBoxContainer.new()
		var l := Label.new()
		var tname: String = sim.countries[op["target"]]["name"]
		l.text = "%s → %s" % [sim.intel_defs[op["type"]]["name"], tname]
		l.custom_minimum_size = Vector2(330, 0)
		row.add_child(l)
		var pb := ProgressBar.new()
		pb.max_value = op["total"]
		pb.value = op["total"] - op["left"]
		pb.show_percentage = false
		pb.custom_minimum_size = Vector2(200, 18)
		row.add_child(pb)
		var cb := Button.new()
		cb.text = "Отменить"
		var oid: int = op["id"]
		cb.pressed.connect(func(): _intel_cmd({"type": "cancel_op", "country": player, "op_id": oid}))
		row.add_child(cb)
		_intel_body.add_child(row)
	var nl := Label.new()
	nl.text = "Новая операция"
	nl.add_theme_color_override("font_color", Color("e0c070"))
	_intel_body.add_child(nl)
	var ids: Array = sim.intel_defs.keys()
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	_intel_body.add_child(row2)
	var ob := OptionButton.new()
	for id in ids:
		ob.add_item(sim.intel_defs[id]["name"])
	_i_op = clampi(_i_op, 0, ids.size() - 1)
	ob.select(_i_op)
	ob.item_selected.connect(func(i):
		_i_op = i
		_intel_refresh())
	row2.add_child(ob)
	var tb := OptionButton.new()
	for pid in partner_ids:
		tb.add_item(sim.countries[pid]["name"])
	_i_target = clampi(_i_target, 0, maxi(partner_ids.size() - 1, 0))
	if not partner_ids.is_empty():
		tb.select(_i_target)
	tb.item_selected.connect(func(i):
		_i_target = i
		_intel_refresh())
	row2.add_child(tb)
	var type: String = ids[_i_op]
	var d: Dictionary = sim.intel_defs[type]
	var target: int = partner_ids[_i_target] if not partner_ids.is_empty() else -1
	var go := Button.new()
	go.text = "Начать (%d $)" % d["cost"]
	go.pressed.connect(func(): _intel_cmd({"type": "intel_op", "country": player, "op": type, "target": target}))
	row2.add_child(go)
	var desc := Label.new()
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var chance_txt := ""
	if target >= 0:
		chance_txt = "   Шанс успеха: %d%%" % sim.op_chance(player, target, type)
	desc.text = "%s\nДлительность: %d дн.  Нужна сеть ≥ %d%%.%s" % [d["desc"], d["duration"], d["min_network"], chance_txt]
	_intel_body.add_child(desc)
