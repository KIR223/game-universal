extends SceneTree
## UI smoke tests on the real-world map (need the scene tree running, so they execute in frames):
##   godot --headless --path . -s tests/run_ui_tests.gd
## Exit code 0 = all passed.

var failures := 0
var passed := 0
var _main: Node
var _frames := 0


func _initialize() -> void:
	_main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3:
		run_checks()
		print("\n%d UI checks passed, %d failed" % [passed, failures])
		quit(1 if failures > 0 else 0)
	return false


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
	# touch support: DPI-based UI scale and long press as right click (mobile only)
	check(is_equal_approx(TouchSupport.ui_scale(420, true), 1.4), "420 dpi phone gets UI scale 1.4")
	check(TouchSupport.ui_scale(96, true) == 1.0 and TouchSupport.ui_scale(600, true) == 1.5, "mobile UI scale is clamped to 1.0..1.5")
	check(TouchSupport.ui_scale(420, false) == 1.0, "desktop UI scale is not changed by DPI")
	check(TouchSupport.is_long_press(500, false, true), "held touch is a long press")
	check(not TouchSupport.is_long_press(200, false, true) and not TouchSupport.is_long_press(900, true, true), "short or moving touch is not a long press")
	check(not TouchSupport.is_long_press(900, false, false), "a long mouse click on desktop is never a context menu")
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
	main.queue_free()
