extends SceneTree
## UI audit on the real-world map (needs the scene tree running, so it executes in frames):
##   godot --headless --path . -s tests/run_ui_audit.gd
## 1. Every button on every screen is wired to an action (no decorative stubs).
## 2. The HUD stays inside the window and its panels do not overlap at all supported resolutions and aspect ratios.
## Exit code 0 = all passed.

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160),   # 16:9
	Vector2i(1920, 1200), Vector2i(1280, 1024), Vector2i(2560, 1080), Vector2i(1280, 800)]   # 16:10, 5:4, 21:9, 16:10

var failures := 0
var passed := 0
var _main: Node
var _frames := 0
var _stubs: Array[String] = []


func _initialize() -> void:
	_main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3:
		run()
		print("\n%d UI audit checks passed, %d failed" % [passed, failures])
		quit(1 if failures > 0 else 0)
	return false


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failures += 1
		printerr("  FAIL: ", msg)


## A button is wired if something listens to pressed/toggled (menus and option lists use their own signals).
func _scan(node: Node, screen: String) -> int:
	var n := 0
	if node is OptionButton or node is MenuButton:
		return 0
	if node is BaseButton and (node as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:   # IGNORE = a pure icon, not clickable
		n += 1
		var b := node as BaseButton
		var wired := b.pressed.get_connections().size() > 0 or b.toggled.get_connections().size() > 0 or b.button_down.get_connections().size() > 0
		if not wired and not b.disabled:
			_stubs.append("%s: «%s» (%s)" % [screen, b.text if b.text != "" else b.tooltip_text, b.get_class()])
	for c in node.get_children():
		if not c.is_queued_for_deletion():
			n += _scan(c, screen)
	return n


func _audit(screen: String, min_buttons: int) -> void:
	var before := _stubs.size()
	var n := _scan(_main.ui, screen)
	check(n >= min_buttons, "%s: found %d buttons (expected >= %d)" % [screen, n, min_buttons])
	check(_stubs.size() == before, "%s: every button has an action" % screen)


func run() -> void:
	var main: Node = _main
	_audit("main menu", 4)
	main._show_scenarios()
	_audit("scenarios", 4)
	main._start_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json"))
	_audit("country select", 10)
	var fr: int = main.sim.countries.find_custom(func(c): return c["name"] == "Франция")
	main._start_playing(fr)
	_audit("HUD", 12)
	for it in main.NAV_ITEMS:
		main._nav_pressed(it[0])
		main._refresh_all()
		_audit("panel " + it[0], 1)
		main._nav_pressed(it[0])
	for tab in main.RIGHT_TABS:
		main._right_set_tab(tab[0])
		_audit("right tab " + tab[0], 1)
	main._right_set_tab("events")
	# a war so the war tab, diplomacy and army buttons have content
	var other: int = main.sim.neighbor_countries(fr)[0]
	main.sim.apply_command({"type": "declare_war", "country": fr, "target": other})
	main._refresh_all()
	for tab in main.RIGHT_TABS:
		main._right_set_tab(tab[0])
		_audit("right tab (at war) " + tab[0], 0)
	for it in ["diplomacy", "army", "politics", "intel", "tech", "economy", "build"]:
		main._nav_pressed(it)
		main._refresh_all()
		_audit("panel (at war) " + it, 1)
		main._nav_pressed(it)
	for s in _stubs:
		printerr("  STUB: ", s)
	# the in-game settings window: all its buttons are wired and it fits every screen
	main._show_settings_overlay()
	_audit("settings overlay", 2)
	main._show_settings_overlay()
	# resource chips in the top bar are clickable and lead somewhere
	for kind in main._chips:
		var chip: Control = main._chips[kind].get_parent()
		check(chip.gui_input.get_connections().size() > 0 and main.CHIP_TARGETS.has(kind), "top-bar chip '%s' is wired to a panel" % kind)
	main._chip_clicked("coin")
	check(main._open_panel_name == "economy", "clicking the treasury chip opens the economy panel")
	main._chip_clicked("flag")
	check(main._right_tab == "wars", "clicking the wars chip opens the Wars tab")
	main._nav_pressed("economy")
	# hotkeys follow the physical key: they work on the Russian layout too ('ь' is on the M key)
	var mode_before: String = main.map.mode
	var ru := InputEventKey.new()
	ru.keycode = 0x044C
	ru.physical_keycode = KEY_M
	ru.pressed = true
	main._unhandled_key_input(ru)
	check(main.map.mode != mode_before, "M key switches the map mode on the Russian layout")
	var latin := InputEventKey.new()
	latin.keycode = KEY_M
	latin.physical_keycode = KEY_M
	latin.pressed = true
	var mode_mid: String = main.map.mode
	main._unhandled_key_input(latin)
	check(main.map.mode != mode_mid, "M key switches the map mode on the Latin layout")
	var sp := InputEventKey.new()
	sp.keycode = KEY_SPACE
	sp.physical_keycode = KEY_SPACE
	sp.pressed = true
	var speed_before: int = main.speed_idx
	main._unhandled_key_input(sp)
	check(main.speed_idx != speed_before, "Space toggles pause/play")
	main._unhandled_key_input(sp)
	# F9 loads the quick save even from the main menu (the button says so)
	check(SaveSystem.save(main.sim, "quick"), "quick save written")
	var press := InputEventKey.new()
	press.keycode = KEY_F9
	press.pressed = true
	main._unhandled_key_input(press)
	check(main.sim != null and main.player >= 0, "F9 loads the quick save")
	main._show_menu()
	check(main.sim == null, "back in the main menu")
	main._unhandled_key_input(press)
	check(main.sim != null and main.player >= 0, "F9 loads the quick save from the main menu")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://saves/quick.sav"))
	main._start_playing(fr)
	# layout at every resolution/aspect: HUD inside the window, panels do not overlap
	main._start_playing(fr)
	for res in RESOLUTIONS:
		root.size = res
		root.content_scale_size = Vector2i(1600, 900)
		var vis: Rect2 = root.get_visible_rect()
		main._refresh_all()
		var panels := {"top": main._top, "rail": main._nav["state"].get_parent().get_parent(), "right": main._right, "bottom": main._bottom,
			"modes": main._mode_opt.get_parent().get_parent()}
		var rects := {}
		for k in panels:
			var p: Control = panels[k]
			if p == null or not is_instance_valid(p):
				check(false, "%dx%d: panel %s exists" % [res.x, res.y, k])
				continue
			rects[k] = p.get_global_rect()
			check(vis.grow(1.0).encloses(rects[k]), "%dx%d: %s panel inside the window (%s in %s)" % [res.x, res.y, k, str(rects[k]), str(vis)])
		main._show_settings_overlay()
		var ov: Control = main._settings_overlay
		if ov != null and is_instance_valid(ov):
			var op: Control = ov.get_child(0)
			check(vis.grow(1.0).encloses(op.get_global_rect()), "%dx%d: the settings window fits the screen (%s in %s)" % [res.x, res.y, str(op.get_global_rect()), str(vis)])
			main._show_settings_overlay()
		var keys := rects.keys()
		for i in keys.size():
			for j in range(i + 1, keys.size()):
				var a: Rect2 = rects[keys[i]]
				var b: Rect2 = rects[keys[j]]
				check(not a.grow(-1.0).intersects(b.grow(-1.0)), "%dx%d: %s and %s panels do not overlap" % [res.x, res.y, keys[i], keys[j]])
	main.queue_free()
