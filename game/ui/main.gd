extends Node
## Game shell: main menu -> country selection -> HUD loop.
## UI is built in code with a shared dark theme; the simulation stays headless.

const SPEEDS := [0.0, 1.0, 3.0, 8.0, 20.0]

var sim: Simulation
var display := DisplaySettings.new()
var map: MapView
var map_legacy: MapView
var map_earth: EarthMapView
var ui: CanvasLayer
var player := -1
var _quality := GraphicsQuality.Level.HIGH
var speed_idx := 1
var accum := 0.0
var log_seen := 0

var _top: PanelContainer
var _side: PanelContainer
var _log: RichTextLabel
var _top_label: Label
var _info: RichTextLabel
var _actions: Container
var _speed_buttons: Array[Button] = []
const NAV_ITEMS := [["state", "Государство"], ["economy", "Экономика"], ["build", "Строительство"], ["diplomacy", "Дипломатия"], ["army", "Армия"], ["tech", "Технологии"], ["politics", "Политика"], ["intel", "Разведка"], ["stats", "Статистика"]]
const RIGHT_TABS := [["events", "События"], ["wars", "Войны"], ["fronts", "Фронты"], ["tasks", "Задачи"]]
var _nav: Dictionary = {}
var _speed_btns: Array = []
var _chips: Dictionary = {}
var _date_label: Label
var _name_label: Label
var _flag: ColorRect
var _search: LineEdit
var _search_panel: PanelContainer
var _mode_opt: OptionButton
var _bell: IconButton
var _notif_panel: PanelContainer
var _notif_seen := 0
var _right: PanelContainer
var _right_body: VBoxContainer
var _right_tab := "events"
var _right_btns: Dictionary = {}
var _bottom: PanelContainer
var _ctx: PopupMenu
var _main_menu: PopupMenu
var _ctx_cell := -1
var _selected_sett := -1
var _open_panel_name := ""
var _generic: PanelContainer
var _gbody: VBoxContainer
var _g_filter := ""
var _cut_cache_day := -99
var _stats_sort := "pop"
var _cut_set: Dictionary = {}
var _player_supply: Dictionary = {}
var _theme: Theme
var _seed_edit: LineEdit
var _menu_root: Control
const REASONS := {
	"not enough funds": "не хватает денег", "not enough steel": "не хватает стали",
	"seller has no surplus": "у продавца нет излишков", "no trade route": "нет торгового пути",
	"cannot afford": "не хватает денег для сделки", "too many deals": "слишком много сделок",
	"human target": "партнёр — игрок", "invalid province": "неверная провинция", "already maximal": "уже максимальный уровень", "invalid operation": "неверная операция", "no free agents": "нет свободных агентов", "network too weak": "сеть слишком слаба", "already running": "уже выполняется", "invalid law": "неверный закон", "already in force": "уже действует", "not enough influence": "не хватает политического влияния", "on cooldown": "ещё нельзя повторить", "requirements not met": "условия не выполнены", "invalid decision": "неверное решение", "no such event": "событие не найдено", "invalid option": "неверный вариант", "airbase full": "аэродром переполнен", "invalid base": "неверный аэродром", "out of range": "вне радиуса действия", "wrong aircraft for mission": "эта авиация не подходит для задачи", "land target required": "нужна сухопутная цель", "target not at war": "нет войны с владельцем", "invalid wing": "неверная авиагруппа", "queue full": "очередь заполнена", "missing prerequisite": "нужна предыдущая технология", "already researched or queued": "уже изучено или в очереди", "no manpower": "не хватает людей", "army full": "армия заполнена", "capital lost": "столица потеряна", "not in same province": "армии в разных провинциях", "invalid army": "неверная армия", "refused": "отказано", "refused terms": "противник не согласен отдать территории", "nothing to annex": "нечего аннексировать", "invalid terms": "неверные условия мира", "no common border": "нет границы",
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
	_quality = GraphicsQuality.load_level(GraphicsQuality.PATH, OS.has_feature("mobile"))
	display = DisplaySettings.load_settings()
	if FileAccess.file_exists(DisplaySettings.PATH):
		display.apply(get_window())   # only after the player chose something; keeps --resolution/tests intact
	get_window().content_scale_factor = TouchSupport.ui_scale(DisplayServer.screen_get_dpi(), OS.has_feature("mobile"))
	_theme = _make_theme()
	map_legacy = MapView.new()
	map_legacy.province_clicked.connect(_on_province_clicked)
	map_legacy.province_right_clicked.connect(_on_province_right_clicked)
	add_child(map_legacy)
	map_earth = EarthMapView.new()
	map_earth.province_clicked.connect(_on_province_clicked)
	map_earth.province_right_clicked.connect(_on_province_right_clicked)
	add_child(map_earth)
	map_earth.set_active(false)
	map = map_legacy
	_apply_quality()
	ui = CanvasLayer.new()
	add_child(ui)
	_show_menu()


func _make_theme() -> Theme:
	var t := Theme.new()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.082, 0.092, 0.112, 0.95)
	panel.border_color = Color(0.34, 0.4, 0.48, 0.75)
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
		sb.border_color = Color(0.32, 0.38, 0.46, 0.8)
		sb.set_border_width_all(1)
		match state:
			"normal": sb.bg_color = Color(0.125, 0.145, 0.18)
			"hover": sb.bg_color = Color(0.2, 0.235, 0.29)
			"pressed": sb.bg_color = Color(0.4, 0.33, 0.15)
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
	var pm := StyleBoxFlat.new()
	pm.bg_color = Color(0.09, 0.1, 0.125, 0.98)
	pm.border_color = Color(0.34, 0.4, 0.48, 0.8)
	pm.set_border_width_all(1)
	pm.set_corner_radius_all(4)
	pm.set_content_margin_all(6)
	t.set_stylebox("panel", "PopupMenu", pm)
	t.set_stylebox("panel", "TooltipPanel", pm)
	var pmh := StyleBoxFlat.new()
	pmh.bg_color = Color(0.22, 0.26, 0.33)
	pmh.set_corner_radius_all(3)
	t.set_stylebox("hover", "PopupMenu", pmh)
	t.set_color("font_color", "PopupMenu", Color("dde3ea"))
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	t.set_color("font_color", "TooltipLabel", Color("dde3ea"))
	for state2 in ["normal", "hover", "pressed", "disabled"]:
		t.set_stylebox(state2, "OptionButton", t.get_stylebox(state2, "Button"))
	t.set_color("font_color", "OptionButton", Color("dde3ea"))
	t.set_font_size("font_size", "OptionButton", 14)
	var pb_bg := StyleBoxFlat.new()
	pb_bg.bg_color = Color(0.13, 0.16, 0.21)
	pb_bg.set_corner_radius_all(3)
	var pb_fill := StyleBoxFlat.new()
	pb_fill.bg_color = Color("c9a23c")
	pb_fill.set_corner_radius_all(3)
	t.set_stylebox("background", "ProgressBar", pb_bg)
	t.set_stylebox("fill", "ProgressBar", pb_fill)
	t.set_color("font_color", "Button", Color("dde3ea"))
	t.set_color("font_disabled_color", "Button", Color(0.5, 0.5, 0.5))
	t.set_color("font_color", "Label", Color("dde3ea"))
	t.set_font_size("font_size", "Label", 15)
	t.set_font_size("font_size", "Button", 14)
	t.set_font_size("normal_font_size", "RichTextLabel", 14)
	t.set_color("default_color", "RichTextLabel", Color("cfd6de"))
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
	if SaveSystem.exists("auto"):
		var cont := Button.new()
		cont.text = "Продолжить (автосохранение)"
		cont.pressed.connect(_load_game.bind("auto"))
		box.add_child(cont)
	var load_btn := Button.new()
	load_btn.text = "Загрузить (F9)"
	load_btn.pressed.connect(_load_game)
	box.add_child(load_btn)
	var quit := Button.new()
	quit.text = "Выход"
	quit.pressed.connect(func(): get_tree().quit())
	box.add_child(quit)
	_menu_root = root
	var credits := Label.new()
	credits.text = "Данные карты: Natural Earth (общественное достояние) · GeoNames (CC BY 4.0) · Terrain Tiles (AWS Open Data; SRTM, GMTED, ETOPO) · Our World in Data (CC BY 4.0). Подробности: docs/DATA_SOURCES.md"
	credits.add_theme_font_size_override("font_size", 12)
	credits.add_theme_color_override("font_color", Color("6f7c8e"))
	credits.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	credits.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # wraps instead of being cut off at large UI scale
	credits.grow_vertical = Control.GROW_DIRECTION_BEGIN
	credits.offset_top = -8
	credits.offset_bottom = -8
	credits.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(credits)


func _new_game() -> void:
	var s := int(_seed_edit.text) if _seed_edit.text.is_valid_int() else hash(_seed_edit.text)
	sim = Simulation.new()
	sim.setup(s, Simulation.load_country_defs())
	_bind_map(sim)
	_show_country_select()


## Use the renderer that matches the world kind (legacy procedural map or the real-world map).
func _bind_map(s: Simulation) -> void:
	var earth := str(s.world.get("kind", "")) == "earth"
	var target: MapView = map_earth if earth else map_legacy
	if target != map:
		map.set_active(false)
		map = target
		map.set_active(true)
	map.bind(s)


func _start_scenario(scn: Dictionary) -> void:
	var fresh := Simulation.new()
	var problems := fresh.setup_scenario(scn)
	if not problems.is_empty() and fresh.world.is_empty():
		_show_scenarios("Сценарий не загружен: " + "; ".join(problems.slice(0, 3)))
		return
	sim = fresh
	_bind_map(sim)
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
	# scrollable and centred: at a large UI scale (phones) the list is taller than the screen
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var outer := VBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.alignment = BoxContainer.ALIGNMENT_CENTER
	scroll.add_child(outer)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(620, 0)
	box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_theme_constant_override("separation", 10)
	outer.add_child(box)
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
		if str(data.get("world", "procedural")) != "earth":
			var eb := Button.new()
			eb.text = "Править"
			eb.pressed.connect(func(): _open_editor(data))
			row.add_child(eb)
		else:
			var note := Label.new()
			note.text = "реальная карта"
			note.add_theme_font_size_override("font_size", 12)
			note.add_theme_color_override("font_color", Color("8a96a6"))
			row.add_child(note)
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


## Mobile OSes can kill a backgrounded app without notice: save the running game when it goes to the background.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED and sim != null and player >= 0:
		SaveSystem.save(sim, "auto")


func _load_game(slot: String = "quick") -> void:
	var loaded := SaveSystem.load_slot(slot)
	if loaded == null:
		return
	sim = loaded
	_bind_map(sim)
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
	panel.position = Vector2(16, 16)
	panel.custom_minimum_size = Vector2(430, 0)
	panel.size = Vector2(430, minf(868.0, get_viewport().get_visible_rect().size.y - 32.0))   # fits small virtual viewports (phones at a larger UI scale)
	root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	v.add_child(_h1("Выберите государство"))
	var filter := LineEdit.new()
	filter.placeholder_text = "Поиск по названию…"
	filter.clear_button_enabled = true
	v.add_child(filter)
	var hint := Label.new()
	hint.text = "Крупнейшие по населению сверху"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color("8a96a6"))
	v.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	var agg := sim._aggregate()
	var order: Array = []
	for c in sim.countries:
		order.append(c["id"])
	order.sort_custom(func(a, b):
		var pa: int = agg[a]["pop"] if agg.has(a) else 0
		var pb: int = agg[b]["pop"] if agg.has(b) else 0
		return pa > pb or (pa == pb and a < b))
	var fill := func(q: String):
		for ch in list.get_children():
			ch.queue_free()
		var shown := 0
		for cid in order:
			var c: Dictionary = sim.countries[cid]
			if q != "" and not str(c["name"]).to_lower().contains(q.to_lower()):
				continue
			if shown >= 80:
				break
			shown += 1
			var b := Button.new()
			var pop_m: float = float(agg[cid]["pop"]) * EarthWorld.POP_UNIT / 1.0e6 if agg.has(cid) else 0.0
			b.text = "%s   %s · %d яч." % [c["name"], ("%.1f млн" % pop_m) if sim.is_earth_world() else "", sim.cells_of(cid).size()]
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			var sb: StyleBoxFlat = _theme.get_stylebox("normal", "Button").duplicate()
			sb.border_color = Color(c["color"])
			sb.border_width_left = 8
			b.add_theme_stylebox_override("normal", sb)
			b.pressed.connect(_start_playing.bind(cid))
			b.mouse_entered.connect(func():
				map.selected_province = sim.countries[cid]["capital"]
				if map is EarthMapView:
					map.focus_lonlat_cell(sim.countries[cid]["capital"], 1.8)
				map.queue_redraw())
			list.add_child(b)
	fill.call("")
	filter.text_changed.connect(func(t: String): fill.call(t))
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
	map.camera.zoom = Vector2.ONE * (2.2 if sim.is_earth_world() else 2.0)
	if map is EarthMapView:
		map.repaint_all()
	log_seen = sim.log_lines.size()
	_notif_seen = sim.log_lines.size()
	speed_idx = 0
	_selected_sett = -1
	_open_panel_name = ""
	_build_hud()
	_refresh_all()


func _set_speed(i: int) -> void:
	speed_idx = i
	for k in _speed_btns.size():
		_speed_btns[k].set_active(k == i)
	_refresh_top()


func _process(delta: float) -> void:
	if sim == null or player < 0:
		return
	var rate: float = SPEEDS[speed_idx]
	if rate <= 0.0 or (_event_panel != null and is_instance_valid(_event_panel)):
		return
	accum += delta * rate
	var stepped := false
	var t0 := Time.get_ticks_usec()
	while accum >= 1.0 and (not stepped or Time.get_ticks_usec() - t0 < 14000):  # frame-time budget: never freeze the UI
		accum -= 1.0
		sim.tick_day()
		stepped = true
	if accum > 3.0:
		accum = 3.0  # the simulation cannot keep up at this speed: drop the backlog
	if stepped:
		var dirty := sim.dirty_provinces.duplicate()
		sim.dirty_provinces.clear()
		map.refresh(dirty)
		_refresh_all()
		if not sim.countries[player]["alive"]:
			speed_idx = 0
			_log.append_text("[color=#d96a5a]Ваше государство уничтожено.[/color]\n")


## Hotkeys follow the physical key position, so they work with any keyboard layout (e.g. the Russian one,
## where the M key produces 'ь' and `keycode` would never equal KEY_M).
func _hotkey(ke: InputEventKey) -> Key:
	return ke.physical_keycode if ke.physical_keycode != KEY_NONE else ke.keycode


## Next map mode (key M and the layers icon next to the mode selector).
func _cycle_map_mode() -> void:
	if map is EarthMapView and _mode_opt != null:
		var nxt := (EarthMapView.MODES.size() + _mode_opt.selected + 1) % EarthMapView.MODES.size()
		_mode_opt.select(nxt)
		map.set_mode(EarthMapView.MODES[nxt][0])


func _unhandled_key_input(event: InputEvent) -> void:
	# F9 is advertised on the main menu button, so it must work from the menu too (no game running yet)
	if event is InputEventKey and event.pressed and not event.echo and _hotkey(event) == KEY_F9:
		_load_game()
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo or sim == null or player < 0:
		return
	var ke := event as InputEventKey
	if (_hotkey(ke) == KEY_F and (ke.ctrl_pressed or ke.meta_pressed)) or _hotkey(ke) == KEY_SLASH:
		if _search != null:
			_search.grab_focus()
			get_viewport().set_input_as_handled()
		return
	match _hotkey(ke):
		KEY_SPACE: _set_speed(0 if speed_idx > 0 else 1)
		KEY_1: _set_speed(1)
		KEY_2: _set_speed(2)
		KEY_3: _set_speed(3)
		KEY_4: _set_speed(4)
		KEY_M: _cycle_map_mode()
		KEY_F5: SaveSystem.save(sim, "quick")
		KEY_F11: _change_display(func(d: DisplaySettings) -> void: d.toggle_fullscreen())
		KEY_ESCAPE:
			if _search_panel != null and is_instance_valid(_search_panel):
				_search_panel.queue_free()
				_search_panel = null
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
	_selected_sett = -1
	_pending_air = ""
	map.queue_redraw()
	_refresh_info()


func _refresh_all() -> void:
	_refresh_top()
	_update_dynamic_overlays()
	_refresh_info()
	if _generic != null and is_instance_valid(_generic) and sim.day % 3 == 0:
		_fill_generic(_open_panel_name)
	if _right_tab != "events" and sim.day % 2 == 0 and _right_body != null:
		_right_set_tab(_right_tab)
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
	if _date_label == null or not is_instance_valid(_date_label):
		return
	var c: Dictionary = sim.countries[player]
	_name_label.text = c["name"]
	_date_label.text = sim.date_string()
	var net: int = c["income"] - c["upkeep"]
	_chip("coin", "%d (%+d)" % [c["treasury"], net], Color("e8c46a") if net >= 0 else Color("e0675a"))
	_chip("influence", str(c["pp"]), Color("cfd6df"))
	var stab_col := Color("7fcf8a") if c["stability"] >= 50 else (Color("e0b45a") if c["stability"] >= 25 else Color("e0675a"))
	_chip("stability", "%d%%" % c["stability"], stab_col)
	_chip("manpower", str(c["manpower"]), Color("cfd6df"))
	_chip("steel", "%d (%+d)" % [c["stock"]["steel"], sim.net_of(player, "steel")], Color("cfd6df") if sim.net_of(player, "steel") >= 0 else Color("e0b45a"))
	_chip("oil", "%d (%+d)" % [c["stock"]["oil"], sim.net_of(player, "oil")], Color("cfd6df") if sim.net_of(player, "oil") >= 0 else Color("e0b45a"))
	_chip("food", "%d (%+d)" % [c["stock"]["food"], sim.net_of(player, "food")], Color("cfd6df") if sim.net_of(player, "food") >= 0 else Color("e0675a"))
	_chip("flag", str(sim.enemies_of(player).size()), Color("e0675a") if not sim.enemies_of(player).is_empty() else Color("8a96a6"))
	if _bell != null:
		_bell.set_badge(maxi(0, sim.log_lines.size() - _notif_seen))
	for k in _speed_btns.size():
		_speed_btns[k].set_active(k == speed_idx)


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
	var earth := sim.is_earth_world()
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
	if earth:
		t = ""
		if _selected_sett >= 0 and int(EarthWorld.settlement(_selected_sett)["cell"]) == pid:
			t += _settlement_card(_selected_sett) + "\n\n"
		t += _earth_card(pid)
	else:
		t += _legacy_card(pid, p, o)
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
	if earth:
		for sid in EarthWorld.settlements_in_cell(pid).slice(0, 6):
			var ss: Dictionary = EarthWorld.settlement(sid)
			var sbtn := Button.new()
			var snm: String = str(ss["name_ru"]) if ss.get("name_ru") != null else str(ss["name"])
			sbtn.text = "%s · %s" % [snm, EarthWorld.settlement_kind(ss)]
			var sid2: int = sid
			sbtn.pressed.connect(func(): _select_settlement(sid2))
			_actions.add_child(sbtn)
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


## Peace that also makes the occupation permanent: legal title to the cells we hold from the enemy.
func _annex_button(o: int, parent: Container = null) -> void:
	var held := sim.cells_held_from(player, o).size()
	if held > 0:
		_cmd_button("Мир с аннексией занятого (%d яч.)" % held, {"type": "propose_peace", "country": player, "target": o, "terms": "annex"}, parent)


func _diplomacy_buttons(o: int) -> void:
	var oname: String = sim.countries[o]["name"]
	if sim.allied(player, o):
		_cmd_button("Расторгнуть союз", {"type": "break_alliance", "country": player, "target": o})
	elif sim.at_war(player, o):
		_cmd_button("Предложить мир: %s" % oname, {"type": "propose_peace", "country": player, "target": o})
		_annex_button(o)
	else:
		_cmd_button("Предложить союз: %s" % oname, {"type": "propose_alliance", "country": player, "target": o})
		if sim.can_declare_war(player, o):
			_cmd_button("Объявить войну: %s" % oname, {"type": "declare_war", "country": player, "target": o})


func _cmd_button(label: String, cmd: Dictionary, parent: Container = null) -> void:
	var b := Button.new()
	b.text = label
	b.pressed.connect(func():
		var r := sim.apply_command(cmd)
		var msg := "Выполнено: %s" % label if r["ok"] else "Отказ (%s): %s" % [_reason(r["reason"]), label]
		_log.append_text("[color=%s]%s[/color]\n" % ["#8ac58a" if r["ok"] else "#d9a05a", msg])
		map.queue_redraw()
		_refresh_all())
	(parent if parent != null else _actions).add_child(b)


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
	_eco.position = Vector2(68, 56)
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
	_tech.position = Vector2(68, 56)
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
	_pol.position = Vector2(68, 56)
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
	_intel.position = Vector2(68, 56)
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


func _h1(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", Color("e8c46a"))
	return l


func _h2(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Color("9fb0c4"))
	return l


func _muted(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color("8a96a6"))
	return l


## Where a click on a top-bar resource chip leads ("@wars" = the Wars tab of the right panel).
const CHIP_TARGETS := {"coin": "economy", "influence": "politics", "stability": "politics", "manpower": "army", "steel": "economy", "oil": "economy", "food": "economy", "flag": "@wars"}


func _chip_clicked(kind: String) -> void:
	var target: String = CHIP_TARGETS.get(kind, "")
	if target == "@wars":
		_right_set_tab("wars")
	elif target != "" and _open_panel_name != target:
		_nav_pressed(target)


func _make_chip(kind: String, tip: String) -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 3)
	hb.tooltip_text = tip
	hb.mouse_filter = Control.MOUSE_FILTER_STOP
	hb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hb.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_chip_clicked(kind))
	var ic := IconButton.new(kind, tip, Vector2(22, 22))
	ic.pad = 3.0
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(ic)
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 14)
	hb.add_child(l)
	_chips[kind] = l
	return hb


func _chip(kind: String, text: String, color: Color) -> void:
	var l: Label = _chips.get(kind)
	if l != null and is_instance_valid(l):
		l.text = text
		l.add_theme_color_override("font_color", color)


func _build_hud() -> void:
	_clear_ui()
	_nav.clear()
	_speed_btns.clear()
	_speed_buttons.clear()
	_chips.clear()
	_right_btns.clear()
	_search_panel = null
	_notif_panel = null
	_generic = null
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _theme
	ui.add_child(root)

	# ---- top bar: nation, date, speed, resources, search, notifications, menu
	_top = PanelContainer.new()
	_top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	root.add_child(_top)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	_top.add_child(hb)
	_flag = ColorRect.new()
	_flag.custom_minimum_size = Vector2(6, 28)
	_flag.color = Color(sim.countries[player]["color"])
	hb.add_child(_flag)
	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 17)
	hb.add_child(_name_label)
	_date_label = Label.new()
	_date_label.add_theme_color_override("font_color", Color("9fb0c4"))
	hb.add_child(_date_label)
	var speeds := [["pause", "Пауза (Пробел)"], ["play", "Скорость 1 (1)"], ["fast", "Скорость 2 (2)"], ["faster", "Скорость 3 (3)"], ["fastest", "Скорость 4 (4)"]]
	for i in speeds.size():
		var b := IconButton.new(speeds[i][0], speeds[i][1], Vector2(34, 34))
		var idx := i
		b.pressed.connect(func(): _set_speed(idx))
		hb.add_child(b)
		_speed_btns.append(b)
	hb.add_child(VSeparator.new())
	for chip in [["coin", "Казна: запас (доход минус расходы в день)"], ["influence", "Политическое влияние (+1 в день)"], ["stability", "Стабильность"],
			["manpower", "Людские ресурсы"], ["steel", "Сталь: запас (баланс в день)"], ["oil", "Нефть: запас (баланс в день)"], ["food", "Продовольствие: запас (баланс в день)"], ["flag", "Войны, в которых вы участвуете"]]:
		hb.add_child(_make_chip(chip[0], chip[1]))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)
	_search = LineEdit.new()
	_search.placeholder_text = "Поиск: город, регион, страна"
	_search.custom_minimum_size = Vector2(200, 0)
	_search.clear_button_enabled = true
	_search.text_changed.connect(_on_search_changed)
	_search.tooltip_text = "Ctrl+F или /"
	hb.add_child(_search)
	_bell = IconButton.new("bell", "Уведомления", Vector2(38, 38))
	_bell.pressed.connect(_toggle_notifications)
	hb.add_child(_bell)
	var menu_btn := IconButton.new("menu", "Меню", Vector2(38, 38))
	menu_btn.pressed.connect(func(): _main_menu.popup(Rect2i(Vector2i(menu_btn.get_screen_position()) + Vector2i(0, 40), Vector2i(1, 1))))
	hb.add_child(menu_btn)

	# ---- left rail
	var nav := PanelContainer.new()
	nav.position = Vector2(8, 56)
	root.add_child(nav)
	var nv := VBoxContainer.new()
	nv.add_theme_constant_override("separation", 2)
	nav.add_child(nv)
	for it in NAV_ITEMS:
		var b2 := IconButton.new(it[0], it[1], Vector2(44, 44))
		b2.pressed.connect(_nav_pressed.bind(it[0]))
		nv.add_child(b2)
		_nav[it[0]] = b2

	# ---- right panel: events / wars / fronts / tasks
	_right = PanelContainer.new()
	_right.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_right.offset_left = -352
	_right.offset_right = -8
	_right.offset_top = 56
	_right.offset_bottom = -204
	root.add_child(_right)
	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 6)
	_right.add_child(rv)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 4)
	rv.add_child(tabs)
	for t in RIGHT_TABS:
		var tb := Button.new()
		tb.text = t[1]
		tb.toggle_mode = true
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var tid: String = t[0]
		tb.pressed.connect(func(): _right_set_tab(tid))
		tabs.add_child(tb)
		_right_btns[tid] = tb
	_right_body = VBoxContainer.new()
	_right_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rv.add_child(_right_body)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# ---- bottom card: selected territory / settlement / units + actions
	_bottom = PanelContainer.new()
	_bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_bottom.offset_left = 68
	_bottom.offset_right = -360
	_bottom.offset_top = -196
	_bottom.offset_bottom = -8
	root.add_child(_bottom)
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 10)
	_bottom.add_child(bh)
	var isc := ScrollContainer.new()
	isc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	isc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bh.add_child(isc)
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	isc.add_child(_info)
	bh.add_child(VSeparator.new())
	var asc := ScrollContainer.new()
	asc.custom_minimum_size = Vector2(430, 0)
	asc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bh.add_child(asc)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	flow.custom_minimum_size = Vector2(420, 0)
	asc.add_child(flow)
	_actions = flow

	# ---- map mode selector (floating, bottom-left of the map)
	var modes := PanelContainer.new()
	modes.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	modes.offset_left = 68
	modes.offset_bottom = -204
	modes.offset_top = -250
	modes.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(modes)
	var mh := HBoxContainer.new()
	mh.add_theme_constant_override("separation", 6)
	modes.add_child(mh)
	var lic := IconButton.new("layers", "Режим карты (M)", Vector2(30, 30))
	lic.pad = 5.0
	lic.pressed.connect(_cycle_map_mode)
	mh.add_child(lic)
	_mode_opt = OptionButton.new()
	_mode_opt.custom_minimum_size = Vector2(190, 0)
	if map is EarthMapView:
		for m in EarthMapView.MODES:
			_mode_opt.add_item(m[1])
		_mode_opt.select(maxi(0, _mode_index(map.mode)))
		_mode_opt.item_selected.connect(func(i): map.set_mode(EarthMapView.MODES[i][0]))
	else:
		_mode_opt.add_item("Политический")
		_mode_opt.add_item("Рельеф")
		_mode_opt.item_selected.connect(func(i):
			map.map_mode = "terrain" if i == 1 else "political"
			map.repaint_all())
	mh.add_child(_mode_opt)

	# ---- popups
	_ctx = PopupMenu.new()
	_ctx.theme = _theme
	_ctx.id_pressed.connect(_ctx_pressed)
	ui.add_child(_ctx)
	_main_menu = PopupMenu.new()
	_main_menu.theme = _theme
	_main_menu.add_item("Сохранить (F5)", 0)
	_main_menu.add_item("Загрузить", 1)
	_main_menu.add_separator()
	_main_menu.add_item("Масштаб интерфейса +", 2)
	_main_menu.add_item("Масштаб интерфейса −", 3)
	_main_menu.add_item("Качество графики: %s" % GraphicsQuality.label(_quality), 8)
	_main_menu.add_separator()
	_main_menu.add_item("Полный экран (F11)", 5)
	_main_menu.add_item("Окно без рамки", 6)
	_main_menu.add_item("Разрешение окна: далее", 7)
	_main_menu.add_separator()
	_main_menu.add_item("В главное меню", 4)
	_main_menu.id_pressed.connect(_menu_pressed)
	ui.add_child(_main_menu)
	_right_set_tab("events")
	_set_speed(speed_idx)


func _mode_index(m: String) -> int:
	for i in EarthMapView.MODES.size():
		if EarthMapView.MODES[i][0] == m:
			return i
	return 0


## Low -> Medium -> High map drawing quality; stored per machine, rendering only.
func _cycle_quality() -> void:
	_quality = GraphicsQuality.next(_quality)
	GraphicsQuality.save_level(_quality)
	_apply_quality()
	var i := _main_menu.get_item_index(8)
	if i >= 0:
		_main_menu.set_item_text(i, "Качество графики: %s" % GraphicsQuality.label(_quality))


func _apply_quality() -> void:
	for m in [map_earth, map_legacy]:
		if m is EarthMapView:
			m.set_quality(_quality)


func _menu_pressed(id: int) -> void:
	match id:
		0: SaveSystem.save(sim, "quick")
		1: _load_game()
		2: get_window().content_scale_factor = clampf(get_window().content_scale_factor + 0.1, 0.8, 1.8)
		3: get_window().content_scale_factor = clampf(get_window().content_scale_factor - 0.1, 0.8, 1.8)
		4: _show_menu()
		8: _cycle_quality()
		5: _change_display(func(d: DisplaySettings) -> void: d.toggle_fullscreen())
		6: _change_display(func(d: DisplaySettings) -> void: d.toggle_borderless())
		7: _change_display(func(d: DisplaySettings) -> void:
			d.mode = DisplaySettings.Mode.WINDOWED
			d.next_resolution())


func _change_display(change: Callable) -> void:
	change.call(display)
	display.apply(get_window())
	display.save_settings()


# ------------------------------------------------------------ navigation rail

func _close_all_panels() -> void:
	for pn in [_eco, _tech, _pol, _intel, _generic, _notif_panel]:
		if pn != null and is_instance_valid(pn):
			pn.queue_free()
	_eco = null
	_tech = null
	_pol = null
	_intel = null
	_generic = null
	_notif_panel = null


func _animate_panel(p: Control) -> void:
	if p == null or not is_instance_valid(p):
		return
	var target := p.position
	p.modulate.a = 0.0
	p.position = target + Vector2(-16, 0)
	var tw := create_tween()
	tw.tween_property(p, "modulate:a", 1.0, 0.18)
	tw.parallel().tween_property(p, "position", target, 0.18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _nav_pressed(name: String) -> void:
	var was := _open_panel_name == name
	_close_all_panels()
	_open_panel_name = ""
	for k in _nav:
		_nav[k].set_active(false)
	if was:
		return
	_open_panel_name = name
	_nav[name].set_active(true)
	match name:
		"economy":
			_toggle_eco()
			_animate_panel(_eco)
		"tech":
			_toggle_tech()
			_animate_panel(_tech)
		"politics":
			_toggle_pol()
			_animate_panel(_pol)
		"intel":
			_toggle_intel()
			_animate_panel(_intel)
		_:
			_open_generic(name)


func _open_generic(name: String) -> void:
	_generic = PanelContainer.new()
	_generic.theme = _theme
	_generic.position = Vector2(68, 56)
	_generic.custom_minimum_size = Vector2(520, 640)
	ui.add_child(_generic)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_generic.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var title := ""
	for it in NAV_ITEMS:
		if it[0] == name:
			title = it[1]
	var h := _h1(title)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(h)
	var x := IconButton.new("close", "Закрыть", Vector2(30, 30))
	x.pad = 6.0
	x.pressed.connect(func(): _nav_pressed(name))
	head.add_child(x)
	if name == "diplomacy" or name == "stats":
		var f := LineEdit.new()
		f.placeholder_text = "Фильтр по названию…"
		f.clear_button_enabled = true
		_g_filter = ""
		f.text_changed.connect(func(t: String):
			_g_filter = t
			_fill_generic(name))
		v.add_child(f)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	_gbody = VBoxContainer.new()
	_gbody.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gbody.add_theme_constant_override("separation", 6)
	sc.add_child(_gbody)
	_fill_generic(name)
	_animate_panel(_generic)


func _fill_generic(name: String) -> void:
	if _generic == null or not is_instance_valid(_generic):
		return
	for ch in _gbody.get_children():
		ch.queue_free()
	match name:
		"state": _g_state()
		"build": _g_build()
		"diplomacy": _g_dip()
		"army": _g_army()
		"stats": _g_stats()


func _where(cell: int) -> String:
	if sim.is_earth_world():
		var p: Dictionary = sim.provinces()[cell]
		var reg := EarthWorld.region_name(sim.world, int(p.get("region", 0)))
		return reg if reg != "" else "ячейка %d" % cell
	return "провинция %d" % cell


func _g_state() -> void:
	var c: Dictionary = sim.countries[player]
	var ideo: Dictionary = sim.ideo_defs[c["ideology"]]
	var title := _h2("%s · %s" % [c["name"], ideo["name"]])
	_gbody.add_child(title)
	_gbody.add_child(_bar("Стабильность", c["stability"], Color("7fcf8a") if c["stability"] >= 50 else Color("e0b45a")))
	_gbody.add_child(_bar("Поддержка войны", c["war_support"], Color("c9a23c")))
	_gbody.add_child(HSeparator.new())
	_gbody.add_child(_h2("Территория"))
	var held := sim.cells_of(player).size()
	var legal_mine := 0
	var lost := 0
	var occupied := 0
	for p in sim.owner.size():
		if sim.legal[p] == player:
			legal_mine += 1
			if sim.owner[p] != player:
				lost += 1
		elif sim.owner[p] == player:
			occupied += 1
	var t := "Под вашим контролем: %d ячеек\nПризнанных за вами: %d\nУтрачено (оккупировано противником): %d\nЗанято вами у других: %d" % [held, legal_mine, lost, occupied]
	var tl := Label.new()
	tl.text = t
	_gbody.add_child(tl)
	if sim.is_earth_world():
		var mixed: Array = []
		var seen := {}
		for p in sim.owner.size():
			if sim.legal[p] == player or sim.owner[p] == player:
				var r: int = sim.region_of(p)
				if r > 0 and not seen.has(r):
					seen[r] = true
					var ctl := sim.region_control(r)
					if ctl.size() > 1:
						mixed.append(r)
		_gbody.add_child(_h2("Регионы с разделённым контролем: %d" % mixed.size()))
		for r in mixed.slice(0, 12):
			var ctl2 := sim.region_control(r)
			var parts: Array[String] = []
			for k in ctl2:
				parts.append("%s %d" % [sim.countries[k]["name"] if k >= 0 else "нейтр.", ctl2[k]])
			var rl := Label.new()
			rl.text = "%s: %s" % [EarthWorld.region_name(sim.world, r), ", ".join(parts)]
			rl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_gbody.add_child(rl)
	_gbody.add_child(HSeparator.new())
	_gbody.add_child(_h2("Силы и экономика"))
	var u := Label.new()
	u.text = "Дивизий: %d · армий: %d · флотов: %d · авиагрупп: %d\nДоход: %+d в день · технологий: %d из %d\nСоюзников: %d · войн: %d" % [
		sim.divisions_of(player), sim.armies_of(player).size(), sim.fleets_of(player).size(), sim.wings_of(player).size(),
		c["income"] - c["upkeep"], c["techs"].size(), sim.tech_defs.size(), sim.allies_of(player).size(), sim.enemies_of(player).size()]
	_gbody.add_child(u)
	var go := Button.new()
	go.text = "Перейти к столице"
	go.pressed.connect(func():
		map.selected_province = c["capital"]
		_focus_cell(c["capital"], 3.0)
		_refresh_info())
	_gbody.add_child(go)


func _focus_cell(cell: int, zoom_level: float = 3.0) -> void:
	if cell < 0:
		return
	map.camera.position = sim.provinces()[cell]["center"] * MapView.CELL
	map.camera.zoom = Vector2.ONE * clampf(zoom_level, map.min_zoom, map.max_zoom)
	map.queue_redraw()


func _g_build() -> void:
	var c: Dictionary = sim.countries[player]
	_gbody.add_child(_muted("Заказы выполняются мгновенно за деньги, сталь и людей; результат виден в журнале событий."))
	_gbody.add_child(_h2("Инфраструктура"))
	var sel := map.selected_province
	if sel >= 0 and sim.owner[sel] == player and sim.infra[sel] < Simulation.MAX_INFRA:
		_cmd_button("Выбранная территория (%s): ур. %d → %d  (%d $, 15 стали)" % [_where(sel), sim.infra[sel], sim.infra[sel] + 1, 60 + 20 * sim.infra[sel]], {"type": "build_infra", "country": player, "province": sel}, _gbody)
	var cand: Array = []
	for a in sim.armies_of(player):
		if sim.owner[a["prov"]] == player and sim.infra[a["prov"]] < Simulation.MAX_INFRA and not cand.has(a["prov"]):
			cand.append(a["prov"])
	cand.sort_custom(func(x, y): return sim.infra[x] < sim.infra[y] or (sim.infra[x] == sim.infra[y] and x < y))
	for cell in cand.slice(0, 8):
		_cmd_button("Где стоят войска: %s: ур. %d → %d  (%d $)" % [_where(cell), sim.infra[cell], sim.infra[cell] + 1, 60 + 20 * sim.infra[cell]], {"type": "build_infra", "country": player, "province": cell}, _gbody)
	_gbody.add_child(HSeparator.new())
	_gbody.add_child(_h2("Производство в столице (%s)" % _where(c["capital"])))
	for ut in sim.unit_defs:
		var ud: Dictionary = sim.unit_defs[ut]
		_cmd_button("Дивизия: %s — %d $, %d стали, %d чел." % [ud["name"], ud["cost"], ud["steel"], ud["manpower"]], {"type": "train_division", "country": player, "unit": ut}, _gbody)
	var port := sim.port_of(player)
	if port >= 0:
		_cmd_button("Флот в порту (%s) — %d $, %d стали" % [_where(port), Simulation.FLEET_COST, Simulation.FLEET_STEEL], {"type": "build_fleet", "country": player}, _gbody)
	for at in sim.air_defs:
		var ad: Dictionary = sim.air_defs[at]
		_cmd_button("Авиагруппа: %s — %d $, %d стали" % [ad["name"], ad["cost"], ad["steel"]], {"type": "build_wing", "country": player, "type_air": at, "base": c["capital"]}, _gbody)


func _relation_text(o: int) -> String:
	if o == player:
		return "вы"
	if sim.allied(player, o):
		return "союзник"
	if sim.at_war(player, o):
		return "ВОЙНА"
	if sim._embargoed(player, o):
		return "эмбарго"
	if sim.neighbor_countries(player).has(o):
		return "сосед"
	return "—"


func _g_dip() -> void:
	var agg := sim._aggregate()
	var order: Array = []
	var q := _g_filter.to_lower()
	for c in sim.countries:
		if c["alive"] and c["id"] != player and (q == "" or str(c["name"]).to_lower().contains(q)):
			order.append(c["id"])
	var rank := func(o: int) -> int:
		if sim.at_war(player, o): return 0
		if sim.allied(player, o): return 1
		if sim.neighbor_countries(player).has(o): return 2
		return 3
	order.sort_custom(func(a, b):
		var ra: int = rank.call(a)
		var rb: int = rank.call(b)
		if ra != rb:
			return ra < rb
		var pa: int = agg[a]["pop"] if agg.has(a) else 0
		var pb: int = agg[b]["pop"] if agg.has(b) else 0
		return pa > pb or (pa == pb and a < b))
	_gbody.add_child(_muted("Сначала войны, союзники и соседи, затем крупнейшие страны. Союз принимает только ИИ."))
	for o in order.slice(0, 40):
		var c2: Dictionary = sim.countries[o]
		var card := VBoxContainer.new()
		var head := HBoxContainer.new()
		var chip := ColorRect.new()
		chip.color = Color(c2["color"])
		chip.custom_minimum_size = Vector2(6, 20)
		head.add_child(chip)
		var nl := Label.new()
		nl.text = "%s" % c2["name"]
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(nl)
		var rl := Label.new()
		rl.text = _relation_text(o)
		rl.add_theme_color_override("font_color", Color("e0675a") if sim.at_war(player, o) else (Color("7fcf8a") if sim.allied(player, o) else Color("8a96a6")))
		head.add_child(rl)
		card.add_child(head)
		var acts := HFlowContainer.new()
		acts.add_theme_constant_override("h_separation", 4)
		card.add_child(acts)
		if sim.allied(player, o):
			_cmd_button("Расторгнуть союз", {"type": "break_alliance", "country": player, "target": o}, acts)
		elif sim.at_war(player, o):
			_cmd_button("Предложить мир", {"type": "propose_peace", "country": player, "target": o}, acts)
			_annex_button(o, acts)
		else:
			_cmd_button("Союз", {"type": "propose_alliance", "country": player, "target": o}, acts)
			if sim.can_declare_war(player, o):
				_cmd_button("Объявить войну", {"type": "declare_war", "country": player, "target": o}, acts)
			if sim._embargoed(player, o):
				_cmd_button("Снять эмбарго", {"type": "lift_embargo", "country": player, "target": o}, acts)
			else:
				_cmd_button("Эмбарго", {"type": "embargo", "country": player, "target": o}, acts)
		var cap := Button.new()
		cap.text = "На карте"
		var capital: int = c2["capital"]
		cap.pressed.connect(func():
			map.selected_province = capital
			_focus_cell(capital, 2.2)
			_refresh_info())
		acts.add_child(cap)
		_gbody.add_child(card)
		_gbody.add_child(HSeparator.new())


func _g_army() -> void:
	var armies := sim.armies_of(player)
	_gbody.add_child(_h2("Армии (%d)" % armies.size()))
	for a in armies:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = "#%d  %s · сила %d · снабж. %d%% · %s" % [a["id"], sim.army_label(a), a["strength"], a["supply"], _where(a["prov"])]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(l)
		var b := Button.new()
		b.text = "Выбрать"
		var aid: int = a["id"]
		var prov: int = a["prov"]
		b.pressed.connect(func():
			map.selected_army = aid
			map.selected_province = prov
			_focus_cell(prov, 3.0)
			_refresh_info())
		row.add_child(b)
		_gbody.add_child(row)
	var fl := sim.fleets_of(player)
	_gbody.add_child(_h2("Флоты (%d)" % fl.size()))
	for f in fl:
		var l2 := Label.new()
		l2.text = "#%d  сила %d" % [f["id"], f["strength"]]
		_gbody.add_child(l2)
	var wl := sim.wings_of(player)
	_gbody.add_child(_h2("Авиагруппы (%d)" % wl.size()))
	for w in wl:
		var l3 := Label.new()
		l3.text = "#%d  %s ×%d · база: %s" % [w["id"], sim.air_defs[w["type"]]["name"], w["strength"], _where(w["base"])]
		_gbody.add_child(l3)


func _g_stats() -> void:
	var agg := sim._aggregate()
	var q := _g_filter.to_lower()
	var rows: Array = []
	for c in sim.countries:
		if not c["alive"] or (q != "" and not str(c["name"]).to_lower().contains(q)):
			continue
		var id: int = c["id"]
		rows.append({"id": id, "name": c["name"], "pop": agg[id]["pop"] if agg.has(id) else 0, "income": c["income"] - c["upkeep"],
			"army": sim.divisions_of(id), "cells": sim.cells_of(id).size(), "techs": c["techs"].size()})
	var sort_key := _stats_sort
	rows.sort_custom(func(a, b): return a[sort_key] > b[sort_key] or (a[sort_key] == b[sort_key] and a["id"] < b["id"]))
	var bar := HBoxContainer.new()
	for k in [["pop", "Население"], ["income", "Доход"], ["army", "Дивизии"], ["cells", "Территория"], ["techs", "Технологии"]]:
		var b := Button.new()
		b.text = k[1]
		b.toggle_mode = true
		b.button_pressed = _stats_sort == k[0]
		var key: String = k[0]
		b.pressed.connect(func():
			_stats_sort = key
			_fill_generic("stats"))
		bar.add_child(b)
	_gbody.add_child(bar)
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 14)
	for head in ["#", "Страна", "Нас., млн", "Доход", "Див.", "Яч."]:
		var hl := Label.new()
		hl.text = head
		hl.add_theme_color_override("font_color", Color("9fb0c4"))
		grid.add_child(hl)
	var place := 0
	for r in rows.slice(0, 40):
		place += 1
		var mine: bool = r["id"] == player
		var vals := [str(place), r["name"], "%.1f" % (float(r["pop"]) * EarthWorld.POP_UNIT / 1.0e6), "%+d" % r["income"], str(r["army"]), str(r["cells"])]
		for v in vals:
			var l := Label.new()
			l.text = v
			if mine:
				l.add_theme_color_override("font_color", Color("e8c46a"))
			grid.add_child(l)
	_gbody.add_child(grid)
	var own_rank := 0
	var all_sorted: Array = []
	for c in sim.countries:
		if c["alive"]:
			all_sorted.append(c["id"])
	all_sorted.sort_custom(func(a, b): return (agg[a]["pop"] if agg.has(a) else 0) > (agg[b]["pop"] if agg.has(b) else 0))
	own_rank = all_sorted.find(player) + 1
	_gbody.add_child(_muted("Ваше место по населению: %d из %d" % [own_rank, all_sorted.size()]))


# ------------------------------------------------------------- right panel

func _right_list() -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_right_body.add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 6)
	sc.add_child(v)
	return v


func _right_set_tab(tab: String) -> void:
	_right_tab = tab
	for k in _right_btns:
		_right_btns[k].button_pressed = k == tab
	for ch in _right_body.get_children():
		if ch == _log:
			_right_body.remove_child(ch)
		else:
			ch.queue_free()
	match tab:
		"events": _right_body.add_child(_log)
		"wars": _fill_wars()
		"fronts": _fill_fronts()
		"tasks": _fill_tasks()


func _fill_wars() -> void:
	var v := _right_list()
	var mine: Array = []
	var others: Array = []
	for w in sim.wars:
		if w["a"] == player or w["b"] == player:
			mine.append(w)
		else:
			others.append(w)
	v.add_child(_h2("Ваши войны (%d)" % mine.size()))
	if mine.is_empty():
		v.add_child(_muted("Вы не воюете."))
	for w in mine:
		var enemy: int = w["b"] if w["a"] == player else w["a"]
		var row := VBoxContainer.new()
		var l := Label.new()
		l.text = "%s · %d дн. · %s" % [sim.countries[enemy]["name"], sim.day - w["start"], "вы напали" if w["a"] == player else "на вас напали"]
		l.add_theme_color_override("font_color", Color("e0675a"))
		row.add_child(l)
		var acts := HFlowContainer.new()
		_cmd_button("Предложить мир", {"type": "propose_peace", "country": player, "target": enemy}, acts)
		_annex_button(enemy, acts)
		row.add_child(acts)
		v.add_child(row)
	v.add_child(HSeparator.new())
	v.add_child(_h2("Другие войны (%d)" % others.size()))
	for w in others.slice(0, 25):
		var l2 := Label.new()
		l2.text = "%s — %s · %d дн." % [sim.countries[w["a"]]["name"], sim.countries[w["b"]]["name"], sim.day - w["start"]]
		l2.add_theme_font_size_override("font_size", 13)
		v.add_child(l2)


func _centroid(cells: Array) -> int:
	if cells.is_empty():
		return -1
	var sum := Vector2.ZERO
	for c in cells:
		sum += sim.provinces()[c]["center"]
	var mid := sum / cells.size()
	var best: int = cells[0]
	for c in cells:
		if sim.provinces()[c]["center"].distance_squared_to(mid) < sim.provinces()[best]["center"].distance_squared_to(mid):
			best = c
	return best


func _fill_fronts() -> void:
	var v := _right_list()
	var enemies := sim.enemies_of(player)
	v.add_child(_h2("Фронты (%d)" % enemies.size()))
	if enemies.is_empty():
		v.add_child(_muted("Активных фронтов нет."))
	for e in enemies:
		var mine := sim.front_cells(player, e)
		var theirs := sim.front_cells(e, player)
		var l := Label.new()
		l.text = "%s\nВаша линия: %d яч. · линия противника: %d яч." % [sim.countries[e]["name"], mine.size(), theirs.size()]
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(l)
		var mid := _centroid(mine if not mine.is_empty() else theirs)
		if mid >= 0:
			var b := Button.new()
			b.text = "К фронту"
			b.pressed.connect(func():
				map.selected_province = mid
				_focus_cell(mid, 2.6)
				_refresh_info())
			v.add_child(b)
	var cut := sim.cut_off_cells(player)
	v.add_child(HSeparator.new())
	v.add_child(_h2("Окружения"))
	if cut.is_empty():
		v.add_child(_muted("Ваши земли связаны со столицей."))
	else:
		var cl := Label.new()
		cl.text = "Отрезано от столицы: %d яч. (снабжение армий там падает)" % cut.size()
		cl.add_theme_color_override("font_color", Color("e0675a"))
		cl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(cl)
		var cb := Button.new()
		cb.text = "К окружённым"
		var mid2 := _centroid(cut)
		cb.pressed.connect(func():
			map.selected_province = mid2
			_focus_cell(mid2, 2.6)
			_refresh_info())
		v.add_child(cb)


func _fill_tasks() -> void:
	var v := _right_list()
	var c: Dictionary = sim.countries[player]
	v.add_child(_h2("Исследования"))
	if c["queue"].is_empty():
		v.add_child(_muted("Очередь пуста — откройте «Технологии»."))
	var active := 0
	for id in c["queue"]:
		var t: Dictionary = sim.tech_defs[id]
		var runs: bool = active < sim.research_slots(player) and sim.tech_reqs_met(player, id)
		if runs:
			active += 1
		var row := VBoxContainer.new()
		var l := Label.new()
		l.text = ("▶ " if runs else "⏳ ") + t["name"]
		row.add_child(l)
		var pb := ProgressBar.new()
		pb.max_value = t["cost"]
		pb.value = c["progress"].get(id, 0)
		pb.show_percentage = false
		pb.custom_minimum_size = Vector2(0, 12)
		row.add_child(pb)
		v.add_child(row)
	v.add_child(HSeparator.new())
	v.add_child(_h2("Разведка"))
	var ops := sim.ops_of(player)
	if ops.is_empty():
		v.add_child(_muted("Операций нет."))
	for op in ops:
		var l2 := Label.new()
		l2.text = "%s → %s (%d дн.)" % [sim.intel_defs[op["type"]]["name"], sim.countries[op["target"]]["name"], op["left"]]
		v.add_child(l2)
	v.add_child(HSeparator.new())
	v.add_child(_h2("Торговля и решения"))
	var deals := sim.trades_of(player)
	var tl := Label.new()
	tl.text = "Сделок: %d · эмбарго: %d" % [deals.size(), sim.embargoes.size()]
	v.add_child(tl)
	if not c["pending"].is_empty():
		var pl := Label.new()
		pl.text = "Ждёт решения событий: %d" % c["pending"].size()
		pl.add_theme_color_override("font_color", Color("e8c46a"))
		v.add_child(pl)


# ------------------------------------------------------------------ search

func _on_search_changed(text: String) -> void:
	if _search_panel != null and is_instance_valid(_search_panel):
		_search_panel.queue_free()
		_search_panel = null
	var q := text.strip_edges()
	if q.length() < 2:
		return
	_search_panel = PanelContainer.new()
	_search_panel.theme = _theme
	var spos := _search.get_global_rect().position + Vector2(0, _search.size.y + 4)
	spos.x = minf(spos.x, get_viewport().get_visible_rect().size.x - 396.0)
	_search_panel.position = spos
	_search_panel.custom_minimum_size = Vector2(380, 0)
	ui.add_child(_search_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	_search_panel.add_child(v)
	var any := false
	var ql := q.to_lower()
	var n := 0
	for c in sim.countries:
		if c["alive"] and str(c["name"]).to_lower().contains(ql) and n < 5:
			n += 1
			any = true
			var cid: int = c["id"]
			_search_row(v, "flag", "%s — страна" % c["name"], func(): _search_pick_cell(sim.countries[cid]["capital"], 2.2))
	if sim.is_earth_world():
		var seen := {}
		var rn := 0
		for r in sim.world["regions"].size():
			var reg: Dictionary = sim.world["regions"][r]
			if reg["kind"] != "admin1" or rn >= 5:
				continue
			var nm: String = EarthWorld.region_name(sim.world, r + 1)
			if nm.to_lower().contains(ql) or str(reg["name"]).to_lower().contains(ql):
				var cells := sim.region_cells(r + 1)
				if cells.is_empty() or seen.has(nm):
					continue
				seen[nm] = true
				rn += 1
				any = true
				var mid := _centroid(cells)
				_search_row(v, "layers", "%s — регион (%s)" % [nm, sim.countries[sim.legal[cells[0]]]["name"] if sim.legal[cells[0]] >= 0 else "—"], func(): _search_pick_cell(mid, 3.0))
		for s in EarthWorld.search(q, 10):
			any = true
			var sid: int = int(s["id"])
			var nm2: String = str(s["name_ru"]) if s.get("name_ru") != null else str(s["name"])
			var pop_txt := ("%.1f млн" % (float(s["pop"]) / 1.0e6)) if int(s["pop"]) >= 1000000 else ("%d тыс." % (int(s["pop"]) / 1000) if int(s["pop"]) > 0 else "нет данных")
			var ctry := ""
			var ow: int = sim.legal[int(s["cell"])]
			if ow >= 0:
				ctry = sim.countries[ow]["name"]
			_search_row(v, "state", "%s — %s, %s (%s)" % [nm2, EarthWorld.settlement_kind(s), ctry, pop_txt], func(): _select_settlement(sid))
	if not any:
		v.add_child(_muted("Ничего не найдено"))


func _search_row(parent: Container, icon: String, text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = "   " + text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.flat = true
	b.clip_text = true
	b.custom_minimum_size = Vector2(370, 28)
	b.pressed.connect(func():
		action.call()
		if _search_panel != null and is_instance_valid(_search_panel):
			_search_panel.queue_free()
			_search_panel = null)
	parent.add_child(b)
	var ic := IconButton.new(icon, "", Vector2(22, 22))
	ic.pad = 3.0
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ic.position = Vector2(2, 3)
	b.add_child(ic)


func _search_pick_cell(cell: int, zoom_level: float) -> void:
	if cell < 0:
		return
	_selected_sett = -1
	map.selected_province = cell
	_focus_cell(cell, zoom_level)
	_refresh_info()


func _select_settlement(sid: int) -> void:
	var s: Dictionary = EarthWorld.settlement(sid)
	_selected_sett = sid
	map.selected_province = int(s["cell"])
	map.selected_army = -1
	if map is EarthMapView:
		map.focus_lonlat(float(s["lon"]), float(s["lat"]), 5.0)
	_refresh_info()


# --------------------------------------------------------- context menu & notes

func _on_province_right_clicked(pid: int, screen_pos: Vector2) -> void:
	if sim == null or player < 0 or _ctx == null:
		return
	_ctx_cell = pid
	_ctx.clear()
	_ctx.add_item("Выбрать территорию", 1)
	_ctx.add_item("Центрировать", 2)
	var o := sim.owner[pid]
	if map.selected_army >= 0 and not sim.army_by_id(map.selected_army).is_empty() and sim.provinces()[pid]["land"]:
		_ctx.add_separator()
		_ctx.add_item("Приказ армии: идти сюда", 3)
	if o >= 0 and o != player:
		_ctx.add_separator()
		var oname: String = sim.countries[o]["name"]
		if sim.at_war(player, o):
			_ctx.add_item("Предложить мир: %s" % oname, 12)
			var held := sim.cells_held_from(player, o).size()
			if held > 0:
				_ctx.add_item("Мир с аннексией занятого (%d яч.): %s" % [held, oname], 13)
		else:
			if sim.can_declare_war(player, o) and not sim.allied(player, o):
				_ctx.add_item("Объявить войну: %s" % oname, 10)
			if not sim.allied(player, o):
				_ctx.add_item("Предложить союз: %s" % oname, 11)
			_ctx.add_item("Эмбарго: %s" % oname, 13)
	if sim.is_earth_world() and not EarthWorld.settlements_in_cell(pid).is_empty():
		_ctx.add_separator()
		_ctx.add_item("Главный населённый пункт ячейки", 20)
	_ctx.popup(Rect2i(Vector2i(screen_pos), Vector2i(1, 1)))


func _ctx_pressed(id: int) -> void:
	var pid := _ctx_cell
	var o := sim.owner[pid]
	match id:
		1:
			_selected_sett = -1
			map.selected_province = pid
			_refresh_info()
		2: _focus_cell(pid, map.camera.zoom.x)
		3: _on_province_clicked(pid)
		10: _pol_cmd_log({"type": "declare_war", "country": player, "target": o})
		11: _pol_cmd_log({"type": "propose_alliance", "country": player, "target": o})
		12: _pol_cmd_log({"type": "propose_peace", "country": player, "target": o})
		13: _pol_cmd_log({"type": "propose_peace", "country": player, "target": o, "terms": "annex"})
		13: _pol_cmd_log({"type": "embargo", "country": player, "target": o})
		20:
			var ids := EarthWorld.settlements_in_cell(pid)
			if not ids.is_empty():
				_select_settlement(ids[0])


func _pol_cmd_log(cmd: Dictionary) -> void:
	var r := sim.apply_command(cmd)
	_log.append_text("[color=%s]%s[/color]\n" % ["#8ac58a" if r["ok"] else "#d9a05a", "Выполнено" if r["ok"] else "Отказ: %s" % _reason(r.get("reason", ""))])
	_refresh_all()


func _toggle_notifications() -> void:
	if _notif_panel != null and is_instance_valid(_notif_panel):
		_notif_panel.queue_free()
		_notif_panel = null
		return
	_notif_seen = sim.log_lines.size()
	_bell.set_badge(0)
	_notif_panel = PanelContainer.new()
	_notif_panel.theme = _theme
	_notif_panel.position = _bell.get_global_rect().position + Vector2(-340, 46)
	_notif_panel.custom_minimum_size = Vector2(380, 340)
	ui.add_child(_notif_panel)
	var v := VBoxContainer.new()
	_notif_panel.add_child(v)
	v.add_child(_h2("Уведомления"))
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rt.scroll_following = true
	var lines: Array = sim.log_lines.slice(maxi(0, sim.log_lines.size() - 40))
	for ln in lines:
		rt.append_text(str(ln) + "\n")
	if lines.is_empty():
		rt.append_text("Новых уведомлений нет.")
	v.add_child(rt)
	_animate_panel(_notif_panel)


# ------------------------------------------------------- territory / city card

func _kcolor(cid: int) -> String:
	return sim.countries[cid]["color"] if cid >= 0 else "#8a96a6"


func _cname(cid: int) -> String:
	return "[color=%s]%s[/color]" % [_kcolor(cid), sim.countries[cid]["name"]] if cid >= 0 else "нейтральная"


func _cell_battle(pid: int) -> bool:
	var first := -1
	for a in sim.armies:
		if a["prov"] == pid:
			if first < 0:
				first = a["owner"]
			elif a["owner"] != first and sim.at_war(first, a["owner"]):
				return true
	return false


func _cell_supply_text(pid: int) -> String:
	var o := sim.owner[pid]
	var best := -1
	for a in sim.armies:
		if a["prov"] == pid and (a["owner"] == player or sim.allied(player, a["owner"])):
			best = maxi(best, a["supply"])
	if best >= 0:
		return "%d%% (армия на месте)" % best
	if o == player:
		var d: int = _player_supply.get(pid, 9999)
		if d >= 9999:
			return "[color=#e0675a]нет связи со столицей[/color]"
		return "%d%% (оценка)" % int(clampf(1.0 - d * 0.01, 0.0, 1.0) * 100.0)
	return "—"


func _earth_card(pid: int) -> String:
	var p: Dictionary = sim.provinces()[pid]
	var w := sim.world
	var o := sim.owner[pid]
	var lg: int = sim.legal[pid]
	var region := EarthWorld.region_name(w, int(p["region"]))
	var ids := EarthWorld.settlements_in_cell(pid)
	var district := ""
	var near := "нет данных"
	if not ids.is_empty():
		var s0: Dictionary = EarthWorld.settlement(ids[0])
		district = str(s0.get("district", ""))
		var nm: String = str(s0["name_ru"]) if s0.get("name_ru") != null else str(s0["name"])
		near = "%s (%s)" % [nm, EarthWorld.settlement_kind(s0)]
	var status: Array[String] = []
	if _cell_battle(pid):
		status.append("[color=#ff9a4a]идут бои[/color]")
	elif o >= 0 and not sim.enemies_of(o).is_empty():
		for q in p["land_neighbors"]:
			var oq := sim.owner[q]
			if oq >= 0 and oq != o and sim.at_war(o, oq):
				status.append("линия фронта")
				break
	if _cut_set.has(pid):
		status.append("[color=#e0675a]в окружении[/color]")
	if status.is_empty():
		status.append("спокойно")
	var dep := ""
	for r in p["deposits"]:
		dep += "%s +%d  " % [_res_name(r), p["deposits"][r]]
	var claim := ""
	if int(p["dispute"]) > 0:
		var d: Dictionary = w["disputes"][int(p["dispute"]) - 1]
		claim = "\n[color=#e0b45a]Спорная территория:[/color] %s — %s" % [d["name"], d["note"] if d["note"] != null else "нет данных"]
	var t := "[table=3]"
	t += "[cell][b]%s[/b]\nСтрана (признана): %s\nОбласть/регион: %s\nРайон: %s\nБлижайший населённый пункт: %s\nЯчейка #%d · %d км²[/cell]" % [
		region if region != "" else "Без названия", _cname(lg), region if region != "" else "—", district if district != "" else "нет данных", near, pid, int(p["area"])]
	t += "[cell]Владелец (признанный): %s\nКонтролирует: %s%s\nСтатус: %s%s[/cell]" % [
		_cname(lg), _cname(o), "  [color=#e0b45a](оккупирована)[/color]" if o != lg else "", ", ".join(status), claim]
	t += "[cell]Рельеф: %s · высота ≈ %d м\nНаселение: %s\nПромышленность: %d · инфраструктура: %d%s\nСнабжение: %s\nДобыча: %s[/cell]" % [
		p["terrain"], int(p["elev"]), ("%d тыс." % (int(p["pop_real"]) / 1000)) if int(p["pop_real"]) > 0 else "нет данных",
		int(p["industry"]), sim.infra[pid], (" (с разрушениями %d)" % sim.eff_infra(pid)) if sim.eff_infra(pid) != sim.infra[pid] else "",
		_cell_supply_text(pid), dep if dep != "" else "—"]
	t += "[/table]\n"
	return t


func _settlement_card(sid: int) -> String:
	var s: Dictionary = EarthWorld.settlement(sid)
	var cell := int(s["cell"])
	var st := sim.settlement_status(s)
	var nm: String = str(s["name_ru"]) if s.get("name_ru") != null else str(s["name"])
	var alts: Array = []
	if s.get("name_ru") != null:
		alts.append(str(s["name"]))
	alts.append_array(s["alt"].slice(0, 3))
	var pop := int(s["pop"])
	var region := EarthWorld.region_name(sim.world, int(s["region"]))
	var t := "[b][font_size=18]%s[/font_size][/b]  [color=#8a96a6]%s[/color]\n" % [nm, EarthWorld.settlement_kind(s)]
	t += "Другие названия: %s\n" % (", ".join(alts) if not alts.is_empty() else "нет данных")
	t += "Население: %s\n" % (("%d" % pop) if pop > 0 else "нет данных")
	t += "Регион: %s · район: %s\n" % [region if region != "" else "—", s["district"] if s.get("district") != "" else "нет данных"]
	t += "Дороги: %s · железная дорога: %s\n" % ["да" if s.get("on_road", 0) == 1 else "нет данных", "да" if s.get("on_rail", 0) == 1 else "нет данных"]
	t += "Признана за: %s · контролирует: %s%s\n" % [_cname(st["legal"]), _cname(st["controller"]), "  [color=#ff9a4a]идут бои[/color]" if st["contested"] else ""]
	t += "Значение: экономика ×%d, стратегическое: %s" % [sim.provinces()[cell]["industry"], "высокое" if pop >= 1000000 or int(s["capital"]) == 1 else "обычное"]
	return t


func _legacy_card(pid: int, p: Dictionary, o: int) -> String:
	var t := "Рельеф: %s\nНаселение: %d тыс.\nПромышленность: %d\n" % [p["terrain"], p["pop"], p["industry"]]
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
	return t


func _update_dynamic_overlays() -> void:
	# cut-off cells and supply estimate for the player, refreshed every few days
	if sim.day - _cut_cache_day < 5:
		return
	_cut_cache_day = sim.day
	var cut := sim.cut_off_cells(player)
	_cut_set = {}
	for c in cut:
		_cut_set[c] = true
	_player_supply = sim._supply_dist(player)
	if map is EarthMapView:
		map.set_cut_off(cut)
