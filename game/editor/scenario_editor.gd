class_name ScenarioEditor
extends Control
## In-game scenario editor. Edits a scenario dictionary (see ScenarioLoader / Simulation.setup_scenario)
## and shows the result live on the map: countries, borders, armies, resources, diplomacy, events, files.

signal closed
signal play_requested(scn: Dictionary)

const TOOLS := ["Страны", "Границы", "Армии", "Ресурсы", "Дипломатия", "События", "Файл"]
const NEUTRAL := "(нейтральная)"

var map: MapView
var scn: Dictionary = {}
var sim: Simulation
var tool_idx := 0
var brush := 0          # index into the brush option list (0 = neutral, 1.. = countries)
var unit_kind := "infantry"
var unit_count := 2
var sel_province := -1
var problems: Array = []
var _theme: Theme
var _content: VBoxContainer
var _status: Label
var _tool_buttons: Array[Button] = []
var _info: Label


func start(map_: MapView, theme_: Theme, scenario: Dictionary) -> void:
	map = map_
	_theme = theme_
	scn = scenario.duplicate(true)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = _theme
	_build_frame()
	map.province_clicked.connect(_on_province)
	map.player_country = -1
	map.selected_army = -1
	map.selected_fleet = -1
	map.selected_wing = -1
	_rebuild(false)
	_set_tool(0)


func _exit_tree() -> void:
	if map != null and map.province_clicked.is_connected(_on_province):
		map.province_clicked.disconnect(_on_province)


# ----------------------------------------------------------------- frame

func _build_frame() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(400, 860)
	panel.size = Vector2(400, 860)
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := Label.new()
	t.text = "Редактор сценариев"
	t.add_theme_font_size_override("font_size", 20)
	t.add_theme_color_override("font_color", Color("e0c070"))
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var exit := Button.new()
	exit.text = "Выход"
	exit.pressed.connect(func(): closed.emit())
	head.add_child(exit)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	v.add_child(flow)
	for i in TOOLS.size():
		var b := Button.new()
		b.text = TOOLS[i]
		b.toggle_mode = true
		var idx := i
		b.pressed.connect(func(): _set_tool(idx))
		flow.add_child(b)
		_tool_buttons.append(b)
	_info = Label.new()
	_info.text = "Провинция не выбрана"
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_info)
	v.add_child(HSeparator.new())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	scroll.add_child(_content)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)


func _set_tool(i: int) -> void:
	tool_idx = i
	for k in _tool_buttons.size():
		_tool_buttons[k].button_pressed = k == i
	_refresh_content()


func _label(text: String, gold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if gold:
		l.add_theme_color_override("font_color", Color("e0c070"))
	return l


func _refresh_content() -> void:
	for ch in _content.get_children():
		ch.queue_free()
	match tool_idx:
		0: _tab_countries()
		1: _tab_borders()
		2: _tab_armies()
		3: _tab_resources()
		4: _tab_diplomacy()
		5: _tab_events()
		6: _tab_file()
	_update_status()


func _update_status() -> void:
	var all: Array = Simulation.validate_scenario(scn) + problems
	if all.is_empty():
		_status.text = "✓ Сценарий корректен"
		_status.add_theme_color_override("font_color", Color("8ac58a"))
	else:
		_status.text = "⚠ " + "; ".join(all.slice(0, 4))
		_status.add_theme_color_override("font_color", Color("d9a05a"))


# ------------------------------------------------------------- rebuilding

## Recreate the preview game from the scenario, keeping the camera where it was.
func _rebuild(keep_view := true) -> void:
	var pos := map.camera.position
	var zoom := map.camera.zoom
	var fresh := Simulation.new()
	var probs := fresh.setup_scenario(scn.duplicate(true))
	problems = probs
	if fresh.world.is_empty():
		return
	sim = fresh
	map.bind(sim)
	map.player_country = -1
	if keep_view:
		map.camera.position = pos
		map.camera.zoom = zoom


func _tags() -> Array:
	var out: Array = []
	for c in scn["countries"]:
		out.append(c["tag"])
	return out


func _brush_tag() -> Variant:
	var tags := _tags()
	return null if brush <= 0 or brush > tags.size() else tags[brush - 1]


func _brush_selector() -> OptionButton:
	var ob := OptionButton.new()
	ob.add_item(NEUTRAL)
	for c in scn["countries"]:
		ob.add_item("%s — %s" % [c["tag"], c["name"]])
	brush = clampi(brush, 0, scn["countries"].size())
	ob.select(brush)
	ob.item_selected.connect(func(i): brush = i)
	return ob


# ------------------------------------------------------------ map clicks

func _on_province(pid: int) -> void:
	if sim == null:
		return
	sel_province = pid
	map.selected_province = pid
	var p: Dictionary = sim.provinces()[pid]
	var o := sim.owner[pid]
	_info.text = "Провинция #%d: %s, %s" % [pid, p["terrain"], ("владелец " + sim.countries[o]["name"]) if o >= 0 else ("нейтральная" if p["land"] else "море")]
	match tool_idx:
		1:
			if p["land"]:
				_paint(pid)
				_info.text = "Провинция #%d: владелец %s" % [pid, sim.countries[sim.owner[pid]]["name"] if sim.owner[pid] >= 0 else "нейтральная"]
		2, 3:
			_refresh_content()
	map.queue_redraw()


func _paint(pid: int) -> void:
	var tag: Variant = _brush_tag()
	scn["owners"] = scn.get("owners", {})
	scn["owners"][str(pid)] = tag
	var cid := -1
	if tag != null:
		for c in sim.countries:
			if c["tag"] == tag:
				cid = c["id"]
	sim.owner[pid] = cid
	sim.dirty_provinces.append(pid)
	var dirty: Array[int] = []
	dirty.assign(sim.dirty_provinces)
	sim.dirty_provinces.clear()
	map.refresh(dirty)
	problems = []
	for c in sim.countries:
		if sim.country_provinces(c["id"]).is_empty():
			problems.append("%s не владеет землёй" % c["tag"])
	_update_status()


# ------------------------------------------------------------------ tabs

func _tab_countries() -> void:
	var ids: Array = ["(по умолчанию)"]
	var sim_for_ideo := Simulation.new()
	sim_for_ideo._load_politics()
	for i in sim_for_ideo.ideo_order:
		ids.append(i)
	for idx in scn["countries"].size():
		var d: Dictionary = scn["countries"][idx]
		_content.add_child(_label("%s" % d["tag"], true))
		var name_edit := LineEdit.new()
		name_edit.text = d["name"]
		var commit_name := func(txt: String):
			if txt != "" and txt != d["name"]:
				d["name"] = txt
				_rebuild()
				_update_status()
		name_edit.text_submitted.connect(commit_name)
		name_edit.focus_exited.connect(func(): commit_name.call(name_edit.text))
		_content.add_child(name_edit)
		var row := HBoxContainer.new()
		_content.add_child(row)
		var cp := ColorPickerButton.new()
		cp.color = Color(d["color"])
		cp.custom_minimum_size = Vector2(60, 28)
		cp.popup_closed.connect(func():
			d["color"] = "#" + cp.color.to_html(false)
			_rebuild())
		row.add_child(cp)
		var io := OptionButton.new()
		for k in ids:
			io.add_item(k)
		io.select(maxi(0, ids.find(d.get("ideology", "(по умолчанию)"))))
		io.item_selected.connect(func(i):
			if i == 0:
				d.erase("ideology")
			else:
				d["ideology"] = ids[i]
			_rebuild())
		row.add_child(io)
		var tr := SpinBox.new()
		tr.min_value = 0
		tr.max_value = 100000
		tr.step = 10
		tr.value = d.get("treasury", 120)
		tr.value_changed.connect(func(v):
			d["treasury"] = int(v)
			_rebuild())
		row.add_child(tr)
		var techs := LineEdit.new()
		techs.placeholder_text = "стартовые технологии: ind1, wp1 …"
		techs.text = ", ".join(d.get("techs", []))
		var commit_techs := func(txt: String):
			var list: Array = []
			for part in txt.split(",", false):
				list.append(part.strip_edges())
			if list != d.get("techs", []):
				d["techs"] = list
				_rebuild()
				_update_status()
		techs.text_submitted.connect(commit_techs)
		techs.focus_exited.connect(func(): commit_techs.call(techs.text))
		_content.add_child(techs)
		_content.add_child(HSeparator.new())
	var row2 := HBoxContainer.new()
	_content.add_child(row2)
	var add := Button.new()
	add.text = "Добавить страну"
	add.pressed.connect(func():
		var n: int = scn["countries"].size() + 1
		scn["countries"].append({"tag": "N%02d" % n, "name": "Новая страна %d" % n, "color": "#" + Color.from_hsv(randf(), 0.5, 0.8).to_html(false)})
		_rebuild()
		_refresh_content())
	row2.add_child(add)
	var rem := Button.new()
	rem.text = "Убрать последнюю"
	rem.disabled = scn["countries"].size() <= 2
	rem.pressed.connect(func():
		var gone: Dictionary = scn["countries"].pop_back()
		_drop_tag(gone["tag"])
		_rebuild()
		_refresh_content())
	row2.add_child(rem)


func _drop_tag(tag: String) -> void:
	for key in ["alliances", "wars"]:
		scn[key] = scn.get(key, []).filter(func(p): return p[0] != tag and p[1] != tag)
	scn["armies"] = scn.get("armies", []).filter(func(a): return a["tag"] != tag)
	scn["capitals"] = scn.get("capitals", {})
	scn["capitals"].erase(tag)
	for k in scn.get("owners", {}).keys():
		if scn["owners"][k] == tag:
			scn["owners"][k] = null


func _tab_borders() -> void:
	_content.add_child(_label("Редактор границ: выберите страну-кисть и кликайте по провинциям на карте.", false))
	_content.add_child(_brush_selector())
	_content.add_child(_label("Столицы", true))
	for c in sim.countries:
		var row := HBoxContainer.new()
		var l := _label("%s: #%d" % [c["tag"], c["capital"]])
		l.custom_minimum_size = Vector2(150, 0)
		row.add_child(l)
		var set_cap := Button.new()
		set_cap.text = "Столица = выбранная"
		set_cap.disabled = sel_province < 0
		var tag: String = c["tag"]
		set_cap.pressed.connect(func():
			scn["capitals"] = scn.get("capitals", {})
			scn["capitals"][tag] = sel_province
			_rebuild()
			_refresh_content())
		row.add_child(set_cap)
		_content.add_child(row)


func _tab_armies() -> void:
	_content.add_child(_label("Редактор армий: выберите провинцию на карте, страну и состав.", false))
	_content.add_child(_brush_selector())
	var row := HBoxContainer.new()
	_content.add_child(row)
	var kinds: Array = sim.unit_defs.keys()
	var ko := OptionButton.new()
	for k in kinds:
		ko.add_item(sim.unit_defs[k]["name"])
	ko.select(maxi(0, kinds.find(unit_kind)))
	ko.item_selected.connect(func(i): unit_kind = kinds[i])
	row.add_child(ko)
	var cnt := SpinBox.new()
	cnt.min_value = 1
	cnt.max_value = 9
	cnt.value = unit_count
	cnt.value_changed.connect(func(v): unit_count = int(v))
	row.add_child(cnt)
	var add := Button.new()
	add.text = "Добавить армию в провинцию"
	add.disabled = sel_province < 0 or _brush_tag() == null
	add.pressed.connect(func():
		_materialize_armies()
		var divs: Array = []
		for _i in unit_count:
			divs.append(unit_kind)
		scn["armies"].append({"tag": _brush_tag(), "province": sel_province, "divisions": divs})
		_rebuild()
		_refresh_content())
	_content.add_child(add)
	var clear := Button.new()
	clear.text = "Убрать все армии из провинции"
	clear.disabled = sel_province < 0
	clear.pressed.connect(func():
		_materialize_armies()
		scn["armies"] = scn["armies"].filter(func(a): return int(a["province"]) != sel_province)
		_rebuild()
		_refresh_content())
	_content.add_child(clear)
	_content.add_child(_label("Армии в выбранной провинции", true))
	if sel_province >= 0:
		for a in sim.armies_in(sel_province):
			_content.add_child(_label("%s: %s" % [sim.countries[a["owner"]]["name"], sim.army_label(a)]))


## First manual army edit freezes the current armies into the scenario.
func _materialize_armies() -> void:
	if scn.get("armies_mode", "") == "replace":
		return
	scn["armies_mode"] = "replace"
	scn["armies"] = []
	for a in sim.armies:
		var divs: Array = []
		for d in a["div"]:
			divs.append(d["t"])
		scn["armies"].append({"tag": sim.countries[a["owner"]]["tag"], "province": a["prov"], "divisions": divs})


func _tab_resources() -> void:
	_content.add_child(_label("Редактор ресурсов: выберите сухопутную провинцию и задайте добычу в день.", false))
	if sel_province < 0 or not sim.provinces()[sel_province]["land"]:
		return
	var dep: Dictionary = sim.provinces()[sel_province]["deposits"]
	var spins := {}
	for r in ["food", "coal", "iron", "oil"]:
		var row := HBoxContainer.new()
		var l := _label(sim.res_name(r))
		l.custom_minimum_size = Vector2(160, 0)
		row.add_child(l)
		var sb := SpinBox.new()
		sb.min_value = 0
		sb.max_value = 12
		sb.value = dep.get(r, 0)
		spins[r] = sb
		row.add_child(sb)
		_content.add_child(row)
	var apply := Button.new()
	apply.text = "Применить к провинции #%d" % sel_province
	apply.pressed.connect(func():
		var nd := {}
		for r in spins:
			if int(spins[r].value) > 0:
				nd[r] = int(spins[r].value)
		scn["deposits"] = scn.get("deposits", {})
		scn["deposits"][str(sel_province)] = nd
		sim.provinces()[sel_province]["deposits"] = nd
		_info.text += "  (добыча обновлена)")
	_content.add_child(apply)


func _tab_diplomacy() -> void:
	var tags := _tags()
	var a_sel := OptionButton.new()
	var b_sel := OptionButton.new()
	for t in tags:
		a_sel.add_item(t)
		b_sel.add_item(t)
	if tags.size() > 1:
		b_sel.select(1)
	var row := HBoxContainer.new()
	row.add_child(a_sel)
	row.add_child(b_sel)
	_content.add_child(row)
	var row2 := HBoxContainer.new()
	_content.add_child(row2)
	for kind in [["alliances", "Добавить союз"], ["wars", "Добавить войну"]]:
		var key: String = kind[0]
		var b := Button.new()
		b.text = kind[1]
		b.pressed.connect(func():
			if a_sel.selected != b_sel.selected:
				scn[key] = scn.get(key, [])
				scn[key].append([tags[a_sel.selected], tags[b_sel.selected]])
				_rebuild()
				_refresh_content())
		row2.add_child(b)
	for kind in [["alliances", "Союзы"], ["wars", "Войны с первого дня"]]:
		var key2: String = kind[0]
		_content.add_child(_label(kind[1], true))
		var list: Array = scn.get(key2, [])
		for i in list.size():
			var r := HBoxContainer.new()
			var l := _label("%s — %s" % [list[i][0], list[i][1]])
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r.add_child(l)
			var x := Button.new()
			x.text = "✕"
			var idx := i
			x.pressed.connect(func():
				scn[key2].remove_at(idx)
				_rebuild()
				_refresh_content())
			r.add_child(x)
			_content.add_child(r)


func _tab_events() -> void:
	_content.add_child(_label("Редактор событий: отметьте события, которые могут происходить в этом сценарии.", false))
	var off: Array = scn.get("disabled_events", [])
	for e in sim.event_defs:
		var cb := CheckBox.new()
		cb.text = e["title"]
		cb.button_pressed = not off.has(e["id"])
		var eid: String = e["id"]
		cb.toggled.connect(func(on: bool):
			var cur: Array = scn.get("disabled_events", [])
			if on:
				cur.erase(eid)
			else:
				if not cur.has(eid):
					cur.append(eid)
			scn["disabled_events"] = cur)
		_content.add_child(cb)


func _tab_file() -> void:
	_content.add_child(_label("Название", true))
	var name_e := LineEdit.new()
	name_e.text = scn.get("name", "")
	name_e.text_changed.connect(func(t): scn["name"] = t)
	_content.add_child(name_e)
	_content.add_child(_label("Описание", true))
	var desc := TextEdit.new()
	desc.custom_minimum_size = Vector2(0, 80)
	desc.text = scn.get("description", "")
	desc.text_changed.connect(func(): scn["description"] = desc.text)
	_content.add_child(desc)
	var row := HBoxContainer.new()
	_content.add_child(row)
	row.add_child(_label("Seed:"))
	var seed_s := SpinBox.new()
	seed_s.min_value = 0
	seed_s.max_value = 999999
	seed_s.value = scn.get("seed", 0)
	row.add_child(seed_s)
	var regen := Button.new()
	regen.text = "Новый мир"
	regen.tooltip_text = "Пересоздаёт карту. Правки границ, армий, ресурсов и столиц сбрасываются."
	regen.pressed.connect(func():
		scn["seed"] = int(seed_s.value)
		for k in ["owners", "deposits", "capitals", "armies"]:
			scn.erase(k)
		scn.erase("armies_mode")
		_rebuild(false)
		_refresh_content())
	row.add_child(regen)
	var row2 := HBoxContainer.new()
	_content.add_child(row2)
	row2.add_child(_label("Дата старта:"))
	var date_e := LineEdit.new()
	date_e.text = scn.get("start_date", "1936-01-01")
	date_e.custom_minimum_size = Vector2(120, 0)
	date_e.text_changed.connect(func(t):
		if Time.get_unix_time_from_datetime_string(t + "T00:00:00") > 0:
			scn["start_date"] = t)
	row2.add_child(date_e)
	row2.add_child(_label("Мир без войн, дней:"))
	var gr := SpinBox.new()
	gr.min_value = 0
	gr.max_value = 720
	gr.value = scn.get("grace_days", Simulation.GRACE_DAYS)
	gr.value_changed.connect(func(v): scn["grace_days"] = int(v))
	row2.add_child(gr)
	var save := Button.new()
	save.text = "Сохранить сценарий"
	save.pressed.connect(func():
		var path := ScenarioLoader.save_user(scn)
		_status.text = ("Сохранено: " + ProjectSettings.globalize_path(path)) if path != "" else "Не удалось сохранить"
		_refresh_saved_list())
	_content.add_child(save)
	var play := Button.new()
	play.text = "Играть этим сценарием"
	play.disabled = not (Simulation.validate_scenario(scn) + problems).is_empty()
	play.pressed.connect(func(): play_requested.emit(scn.duplicate(true)))
	_content.add_child(play)
	_content.add_child(HSeparator.new())
	_content.add_child(_label("Сохранённые сценарии", true))
	_saved_box = VBoxContainer.new()
	_content.add_child(_saved_box)
	_refresh_saved_list()


var _saved_box: VBoxContainer


func _refresh_saved_list() -> void:
	if _saved_box == null or not is_instance_valid(_saved_box):
		return
	for ch in _saved_box.get_children():
		ch.queue_free()
	for entry in ScenarioLoader.list_all():
		var row := HBoxContainer.new()
		var l := _label(("[встроенный] " if entry["builtin"] else "") + str(entry["data"].get("name", "?")))
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var open := Button.new()
		open.text = "Открыть"
		var data: Dictionary = entry["data"]
		open.pressed.connect(func():
			scn = data.duplicate(true)
			sel_province = -1
			_rebuild(false)
			_refresh_content())
		row.add_child(open)
		if not entry["builtin"]:
			var del := Button.new()
			del.text = "Удалить"
			var path: String = entry["path"]
			del.pressed.connect(func():
				ScenarioLoader.delete_user(path)
				_refresh_saved_list())
			row.add_child(del)
		_saved_box.add_child(row)
