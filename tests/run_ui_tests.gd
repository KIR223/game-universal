extends SceneTree
## UI smoke tests on the real-world map (need the scene tree running, so they execute in frames):
##   godot --headless --path . -s tests/run_ui_tests.gd
## Exit code 0 = all passed.

var failures := 0
var passed := 0
var _main: Node
var _frames := 0


func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--phone"):
		MobileLayout.force = true            # phone layout: bottom navigation, compact card, 1170x540 window
		# only the layout code paths change (bottom navigation bar, compact card, phone panel sizes); the headless window size is fixed
	GameSettings.path = "user://test_ui_settings.cfg"   # scratch settings: reduced motion makes panels appear at once, so layout can be measured
	GameSettings.reset_for_tests()
	GameSettings.set_value("reduce_motion", true)
	_main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3:
		run_checks()
	elif _frames == 4:
		_main.map.hide()   # layout checks need no map drawing (the dummy headless renderer crashes on long map draws)
	elif _frames >= 6 and _frames < 6 + _layout_panels.size() * 3:
		_layout_step(_frames - 6)
	elif _frames == 6 + _layout_panels.size() * 3:
		_main.queue_free()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameSettings.path))
		print("\n%d UI checks passed, %d failed" % [passed, failures])
		quit(1 if failures > 0 else 0)
	return false


## Layout regression checks (what a screenshot comparison would catch): the HUD must stay aligned at the window edge and
## every panel must keep its own size, stay inside the window and leave the top bar and the navigation rail visible.
var _layout_panels := ["economy", "tech", "politics", "intel", "diplomacy", "army", "stats"]
var _panel_vars := {"economy": "_eco", "tech": "_tech", "politics": "_pol", "intel": "_intel", "diplomacy": "_generic", "army": "_generic", "stats": "_generic"}


func _layout_step(i: int) -> void:
	var main: Node = _main
	var vp: Vector2 = root.get_visible_rect().size
	var idx := i / 3
	var phase := i % 3
	var name: String = _layout_panels[idx]
	if phase == 0:
		if i == 0 and OS.get_cmdline_user_args().has("--phone"):
			check(MobileLayout.is_phone() and main.BOTTOM_PAD > 8 and main.RAIL_W == 8, "phone profile is active")
		main._nav_pressed(name)
	elif phase == 2:
		var top: Control = main._top
		check(top.get_global_rect().position.y <= 12.0, "top bar sits at the window edge (y=%.0f)" % top.get_global_rect().position.y)
		var panel: Control = main.get(_panel_vars[name])
		check(panel != null and panel.is_inside_tree(), "%s panel is open" % name)
		if panel != null:
			var r := panel.get_global_rect()
			check(r.size.x <= vp.x * 0.8 + 1.0, "%s panel keeps a sane width (%.0f of %.0f px)" % [name, r.size.x, vp.x])
			check(r.position.x >= (0.0 if MobileLayout.is_phone() else 60.0) and r.end.x <= vp.x + 1.0 and r.end.y <= vp.y - float(main.BOTTOM_PAD - 8) + 1.0, "%s panel stays inside the window and clear of the nav rail (%s of %s)" % [name, str(r), str(vp)])
			check(r.position.y >= top.get_global_rect().end.y - 4.0, "%s panel does not cover the top bar" % name)
		main._nav_pressed(name)


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failures += 1
		printerr("  FAIL: ", msg)


func _find_border(sim: Simulation) -> Dictionary:
	for c in sim.countries:
		var a: int = c["id"]
		for p in sim.cells_of(a):
			if sim.region_cells(sim.region_of(p)).size() < 3 or p == c["capital"]:
				continue
			for q in sim.provinces()[p]["land_neighbors"]:
				var b: int = sim.owner[q]
				if b >= 0 and b != a:
					return {"a": a, "b": b, "cell": p, "region": sim.region_of(p)}
	return {}


func run_checks() -> void:
	var main: Node = _main
	main._start_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json"))
	check(main.sim != null and main.sim.is_earth_world() and main.map is EarthMapView, "real-world scenario uses the Earth map view")
	var fr: int = main.sim.countries.find_custom(func(c): return c["name"] == "Франция")
	check(fr >= 0, "France exists")
	main._start_playing(fr)
	check(main._chips.size() == 8 and main._nav.size() == 9 and main._speed_btns.size() == 5, "HUD: resource chips, nav rail, speed controls")
	# armies glide to their new cell (with motion on) instead of jumping; reduced motion snaps at once
	var mv: EarthMapView = main.map
	var army: Dictionary = main.sim.armies[0]
	var cell_a: int = army["prov"]
	mv.animate_armies(0.016)
	var glide_to: int = main.sim.provinces()[cell_a]["land_neighbors"][0]
	army["prov"] = glide_to
	GameSettings.set_value("reduce_motion", false)
	var moving := mv.animate_armies(0.016)
	var mid: Vector2 = mv._army_vis[army["id"]]
	check(moving and mid.distance_to(mv.cell_world(glide_to)) > 0.5, "an army eases towards its new cell")
	for i in 120:
		mv.animate_armies(0.05)
	check(not mv.animate_armies(0.05) and mv._army_vis[army["id"]].distance_to(mv.cell_world(glide_to)) < 0.5, "the glide ends exactly on the cell")
	GameSettings.set_value("reduce_motion", true)
	army["prov"] = cell_a
	mv.animate_armies(0.016)
	check(mv._army_vis[army["id"]].distance_to(mv.cell_world(cell_a)) < 0.01, "reduced motion snaps armies to their cell")
	# every map mode computes a palette and never fails
	var m: EarthMapView = main.map
	for mode in EarthMapView.MODES:
		m.set_mode(mode[0])
		check(m.mode == mode[0], "map mode " + mode[0])
	m.set_mode("political")
	var cell: int = main.sim.countries[fr]["capital"]
	check(m._cell_color(cell).a > 0.5, "land cells are coloured in political mode")
	var sea := -1
	for p in main.sim.provinces():
		if not p["land"]:
			sea = p["id"]
			break
	check(m._cell_color(sea).a == 0.0, "sea cells are transparent in the palette")
	m.set_mode("admin")
	var r1 := m._cell_color(cell)
	var other := -1
	for q in main.sim.provinces()[cell]["neighbors"]:
		if main.sim.provinces()[q]["land"] and main.sim.provinces()[q]["region"] != main.sim.provinces()[cell]["region"]:
			other = q
			break
	check(other < 0 or m._cell_color(other) != r1, "administrative mode distinguishes neighbouring regions")
	m.set_mode("political")
	# graphics quality: ordered presets, cycling, per-machine config; renderer follows the level
	check(GraphicsQuality.params(GraphicsQuality.Level.LOW)["labels"] < GraphicsQuality.params(GraphicsQuality.Level.MEDIUM)["labels"] and GraphicsQuality.params(GraphicsQuality.Level.MEDIUM)["labels"] < GraphicsQuality.params(GraphicsQuality.Level.HIGH)["labels"], "label budget grows with quality")
	check(GraphicsQuality.next(GraphicsQuality.Level.HIGH) == GraphicsQuality.Level.LOW and GraphicsQuality.next(GraphicsQuality.Level.LOW) == GraphicsQuality.Level.MEDIUM, "quality cycles Low -> Medium -> High -> Low")
	check(GraphicsQuality.default_level(true) == GraphicsQuality.Level.MEDIUM and GraphicsQuality.default_level(false) == GraphicsQuality.Level.HIGH, "phones default to Medium, desktops to High")
	var gq_tmp := "user://graphics_test.cfg"
	check(GraphicsQuality.save_level(GraphicsQuality.Level.LOW, gq_tmp) and GraphicsQuality.load_level(gq_tmp) == GraphicsQuality.Level.LOW, "quality round-trips through the config")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(gq_tmp))
	check(GraphicsQuality.load_level("user://missing_graphics.cfg", true) == GraphicsQuality.Level.MEDIUM, "missing config falls back to the platform default")
	var q_before: int = main._quality
	main._cycle_quality()
	check(main._quality != q_before and (main.map as EarthMapView).detail == main._quality, "menu item cycles the quality and the map follows")
	main._quality = q_before
	main._apply_quality()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GraphicsQuality.PATH))
	# display settings: modes, resolution cycle, per-machine config round trip
	var ds := DisplaySettings.new()
	ds.toggle_fullscreen()
	check(ds.mode == DisplaySettings.Mode.FULLSCREEN, "F11 toggles to fullscreen")
	ds.toggle_fullscreen()
	check(ds.mode == DisplaySettings.Mode.WINDOWED, "F11 toggles back to windowed")
	ds.toggle_borderless()
	check(ds.mode == DisplaySettings.Mode.BORDERLESS, "borderless mode")
	var seen := {}
	for i in DisplaySettings.RESOLUTIONS.size() + 1:
		ds.next_resolution()
		seen[ds.resolution()] = true
	check(seen.size() == DisplaySettings.RESOLUTIONS.size(), "resolution cycle covers 1366x768..3840x2160")
	var tmp := "user://display_test.cfg"
	ds.mode = DisplaySettings.Mode.FULLSCREEN
	ds.resolution_index = 3
	check(ds.save_settings(tmp), "display settings are written")
	var back := DisplaySettings.load_settings(tmp)
	check(back.mode == DisplaySettings.Mode.FULLSCREEN and back.resolution_index == 3, "display settings round-trip")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	check(DisplaySettings.load_settings("user://missing_display.cfg").mode == DisplaySettings.Mode.WINDOWED, "missing display config falls back to windowed")
	main._menu_pressed(5)
	main._menu_pressed(5)
	check(main.display.mode == DisplaySettings.Mode.WINDOWED, "menu fullscreen item toggles twice back to windowed")
	# smooth zoom towards the cursor: reaches the target and keeps the world point under the cursor fixed
	var anchor := Vector2(430, 260)
	var half: Vector2 = m.get_viewport_rect().size * 0.5
	m.camera.position_smoothing_enabled = false
	m.camera.zoom = Vector2.ONE * 1.0
	m.camera.position = m.sim.provinces()[main.sim.countries[fr]["capital"]]["center"] * MapView.CELL
	var world_under: Vector2 = m.camera.position + (anchor - half) / m.camera.zoom.x
	m._zoom_at(2.5, anchor)
	check(m._zooming and absf(m.camera.zoom.x - 1.0) < 0.001, "a wheel notch only sets a target (no jump)")
	var steps := 0
	while m._smooth_zoom(0.016) and steps < 400:
		steps += 1
	check(not m._zooming and absf(m.camera.zoom.x - 2.5) < 0.01, "smooth zoom reaches the target (%d frames)" % steps)
	var world_after: Vector2 = m.camera.position + (anchor - half) / m.camera.zoom.x
	check(world_after.distance_to(world_under) < 0.5, "the world point under the cursor stays under the cursor (moved %.3f)" % world_after.distance_to(world_under))
	m._zoom_at(100.0, anchor)
	while m._smooth_zoom(0.016):
		pass
	check(is_equal_approx(m.camera.zoom.x, m.max_zoom), "zoom is clamped to max_zoom")
	check(m.camera.position_smoothing_enabled, "camera smoothing is back on after zooming")
	# country labels: shown on the world view (they were lost after starting a game) and never overlap, at any zoom
	var world_center := Vector2(main.sim.world["w"], main.sim.world["h"]) * MapView.CELL * 0.5
	for zl in [0.15, 0.3, 0.6, 1.0, 2.0, 4.0]:
		m.camera.zoom = Vector2.ONE * zl
		m.camera.position = world_center if zl <= 0.3 else main.sim.provinces()[main.sim.countries[fr]["capital"]]["center"] * MapView.CELL
		m._last_cam = Vector3(-1, -1, -1)
		m._process(0.016)
		var lay: Array = m.label_layout()
		var overlap := 0
		for i in lay.size():
			for j in range(i + 1, lay.size()):
				if (lay[i]["box"] as Rect2).intersects(lay[j]["box"]):
					overlap += 1
		check(overlap == 0, "zoom %.2f: %d country labels, %d overlaps" % [zl, lay.size(), overlap])
		if zl <= 0.3:
			check(lay.size() >= 3, "zoom %.2f: country labels are present on the world view (%d)" % [zl, lay.size()])
			var off := []
			for l in lay:
				var under_cell: int = m.province_at(l["pos"])
				if under_cell < 0 or main.sim.owner[under_cell] != l["cid"]:
					off.append(l["name"])
			check(off.is_empty(), "zoom %.2f: every label sits on its own country's land (off: %s)" % [zl, str(off)])
	# touch support: DPI-based UI scale and long press as right click (mobile only)
	check(is_equal_approx(TouchSupport.ui_scale(420, true), 1.4), "420 dpi phone gets UI scale 1.4")
	check(TouchSupport.ui_scale(96, true) == 1.0 and TouchSupport.ui_scale(600, true) == 1.5, "mobile UI scale is clamped to 1.0..1.5")
	check(TouchSupport.ui_scale(420, false) == 1.0, "desktop UI scale is not changed by DPI")
	check(TouchSupport.is_long_press(500, false, true), "held touch is a long press")
	check(not TouchSupport.is_long_press(200, false, true) and not TouchSupport.is_long_press(900, true, true), "short or moving touch is not a long press")
	check(not TouchSupport.is_long_press(900, false, false), "a long mouse click on desktop is never a context menu")
	# autosave when the app goes to the background (mobile): written, loadable, identical state
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://saves/auto.sav"))
	check(not SaveSystem.exists("auto"), "no autosave before the app is paused")
	main._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	check(SaveSystem.exists("auto"), "pausing the app writes the autosave slot")
	var auto_sim := SaveSystem.load_slot("auto")
	check(auto_sim != null and auto_sim.checksum() == main.sim.checksum(), "autosave restores the exact game state")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://saves/auto.sav"))
	# the context menu of an enemy cell: every entry has its own id (a duplicate id once made "Embargo" run the annexation)
	var neighbor_c: int = main.sim.neighbor_countries(fr)[0]
	var declared: Dictionary = main.sim.apply_command({"type": "declare_war", "country": fr, "target": neighbor_c})
	check(declared["ok"], "war declared on a neighbour for the menu test (%s)" % str(declared))
	var foe_cells: Array = main.sim.cells_of(neighbor_c)
	var foe_cell: int = foe_cells[0]
	main.sim.armies = main.sim.armies.filter(func(x): return x["prov"] != foe_cell)
	main.sim._add_army(fr, foe_cell, [main.sim._make_div("infantry")])
	main.sim._occupation()
	check(not main.sim.cells_held_from(fr, neighbor_c).is_empty(), "France holds an enemy cell (so the annexation entry appears)")
	var click_cell: int = main.sim.cells_of(neighbor_c)[0]
	main._on_province_right_clicked(click_cell, Vector2(300, 300))
	var ids := {}
	var dup := 0
	for i in main._ctx.item_count:
		if main._ctx.is_item_separator(i):
			continue
		var iid: int = main._ctx.get_item_id(i)
		if ids.has(iid):
			dup += 1
		ids[iid] = main._ctx.get_item_text(i)
	check(dup == 0, "context menu entries have unique ids (%d duplicates in %s)" % [dup, str(ids)])
	check(ids.has(14) and str(ids[14]).begins_with("Мир с аннексией"), "the annexation peace entry has its own id")
	check(not ids.has(13), "no embargo entry while at war with that country")
	var peaceful := -1
	for c in main.sim.countries:
		if c["id"] != fr and c["alive"] and not main.sim.at_war(fr, c["id"]) and not main.sim.cells_of(c["id"]).is_empty():
			peaceful = c["id"]
			break
	main._on_province_right_clicked(main.sim.cells_of(peaceful)[0], Vector2(300, 300))
	var ids2 := {}
	for i in main._ctx.item_count:
		if not main._ctx.is_item_separator(i):
			ids2[main._ctx.get_item_id(i)] = main._ctx.get_item_text(i)
	check(ids2.has(13) and str(ids2[13]).begins_with("Эмбарго") and not ids2.has(14), "for a country at peace id 13 is the embargo and there is no annexation entry")
	# settings screen: window mode / resolution / UI scale / quality apply at once and persist per machine
	var holder := VBoxContainer.new()
	main.add_child(holder)
	main._build_settings(holder, func(): pass)
	var opts: Array = []
	var sliders: Array = []
	var btns: Array = []
	var stack: Array = [holder]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is OptionButton:
			opts.append(n)
		elif n is HSlider:
			sliders.append(n)
		elif n is Button:
			btns.append(n)
		stack.append_array(n.get_children())
	opts.sort_custom(func(a, b): return a.get_index() < b.get_index() if a.get_parent() == b.get_parent() else a.get_global_rect().position.y < b.get_global_rect().position.y)
	check(opts.size() == 3 and sliders.size() == 1 and btns.size() == 2, "settings: window mode, resolution, quality, scale slider, Auto and Close (%d/%d/%d)" % [opts.size(), sliders.size(), btns.size()])
	var mode_o: OptionButton = holder.get_child(2)
	var res_o: OptionButton = holder.get_child(3)
	mode_o.item_selected.emit(DisplaySettings.Mode.BORDERLESS)
	check(main.display.mode == DisplaySettings.Mode.BORDERLESS, "settings: the window mode option applies")
	res_o.item_selected.emit(2)
	check(main.display.mode == DisplaySettings.Mode.WINDOWED and main.display.resolution_index == 2 and mode_o.selected == DisplaySettings.Mode.WINDOWED, "settings: choosing a resolution returns to windowed mode")
	sliders[0].value = 1.3
	check(is_equal_approx(main.get_window().content_scale_factor, 1.3) and is_equal_approx(main.display.ui_scale, 1.3), "settings: the UI scale slider applies")
	check(is_equal_approx(DisplaySettings.load_settings().ui_scale, 1.3) and DisplaySettings.load_settings().resolution_index == 2, "settings: the choice is stored per machine")
	for b in btns:
		if b.text == "Авто":
			b.pressed.emit()
	check(main.display.ui_scale < 0.0 and is_equal_approx(main.get_window().content_scale_factor, 1.0), "settings: Auto returns to the default scale")
	var q_o: OptionButton = holder.get_child(7)
	q_o.item_selected.emit(0)
	check(main._quality == 0 and (main.map as EarthMapView).detail == 0, "settings: the graphics quality option applies to the map")
	var keys_text := ""
	for n in holder.get_children():
		if n is Label and (n as Label).text.find("F11") >= 0:
			keys_text = (n as Label).text
	check(keys_text.find("F9") >= 0 and keys_text.find("Пробел") >= 0, "settings: the controls help lists the hotkeys")
	main._show_settings_overlay()
	check(main._settings_overlay != null and is_instance_valid(main._settings_overlay), "the in-game settings window opens")
	main._show_settings_overlay()
	check(main._settings_overlay == null or not is_instance_valid(main._settings_overlay) or main._settings_overlay.is_queued_for_deletion(), "...and closes again")
	holder.queue_free()
	main._quality = GraphicsQuality.Level.HIGH
	main._apply_quality()
	main.get_window().content_scale_factor = 1.0
	main.display = DisplaySettings.new()
	for f in ["display.cfg", "graphics.cfg"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + f))
	check(ids2.has(15) and str(ids2[15]).begins_with("Санкции") and not ids2.has(16), "the menu offers sanctions against a country at peace")
	main.sim.countries[fr]["pp"] = 100
	var pp_was: int = main.sim.countries[fr]["pp"]
	main._ctx_cell = main.sim.cells_of(peaceful)[0]
	main._ctx_pressed(15)
	check(main.sim.sanctioned_by(fr, peaceful) and main.sim.countries[fr]["pp"] == pp_was - Simulation.SANCTION_COST_PP, "choosing 'Санкции' imposes them and costs influence")
	main._on_province_right_clicked(main.sim.cells_of(peaceful)[0], Vector2(300, 300))
	var ids3 := {}
	for i in main._ctx.item_count:
		if not main._ctx.is_item_separator(i):
			ids3[main._ctx.get_item_id(i)] = main._ctx.get_item_text(i)
	check(ids3.has(16) and str(ids3[16]).begins_with("Снять санкции") and not ids3.has(15), "afterwards the menu offers to lift them")
	main._ctx_pressed(16)
	check(not main.sim.sanctioned_by(fr, peaceful), "choosing 'Снять санкции' lifts them")
	# panels open and close
	for it in main.NAV_ITEMS:
		main._nav_pressed(it[0])
		check(main._open_panel_name == it[0], "panel opens: " + it[0])
		main._refresh_all()
		main._nav_pressed(it[0])
		check(main._open_panel_name == "", "panel closes: " + it[0])
	for tab in main.RIGHT_TABS:
		main._right_set_tab(tab[0])
		check(main._right_tab == tab[0], "right tab " + tab[0])
	# search finds a real city and selecting it fills the card
	main._on_search_changed("Hamburg")
	check(main._search_panel != null and is_instance_valid(main._search_panel), "search results are shown")
	var hid: int = EarthWorld.search("Hamburg")[0]["id"]
	main._select_settlement(hid)
	check(main._selected_sett == hid and main.map.selected_province == int(EarthWorld.settlement(hid)["cell"]), "selecting a city selects its cell")
	check(main._info.text.contains("Гамбург") or main._info.text.contains("Hamburg"), "city card is shown")
	main._on_province_right_clicked(main.map.selected_province, Vector2(300, 300))
	check(main._ctx.item_count > 0, "context menu has entries")
	# run a few days with all UI hooks active
	for i in 8:
		main.sim.tick_day()
		var dirty: Array[int] = main.sim.dirty_provinces.duplicate()
		main.sim.dirty_provinces.clear()
		main.map.refresh(dirty)
		main._refresh_all()
	check(main.sim.day == 8, "game advances with the HUD attached")
	# a captured cell repaints only that cell's palette entry
	var f := _find_border(main.sim)
	main.sim.wars.append({"a": f["b"], "b": f["a"], "start": 0})
	main.sim.armies = main.sim.armies.filter(func(x): return x["prov"] != f["cell"])
	main.sim._add_army(f["b"], f["cell"], [main.sim._make_div("infantry")])
	main.sim._occupation()
	var dirty2: Array[int] = main.sim.dirty_provinces.duplicate()
	main.sim.dirty_provinces.clear()
	check(dirty2 == [f["cell"]], "exactly one cell is reported dirty after a capture")
	main.map.refresh(dirty2)
	check(m._ctl[f["cell"]] == f["b"], "renderer tracks the new controller of the captured cell")
	main._refresh_all()
