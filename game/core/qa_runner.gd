class_name QaRunner
extends Node
## Built-in device QA (launched with the `--qa-run` argument): drives the real game through its main flows on the device or
## simulator and writes user://qa_report.json plus screenshots. Used because a phone cannot be clicked through by a script.
## Read the results with:  xcrun simctl get_app_container booted <bundle> data   (files are in the container's Documents/ or Library/).

var main: Node
var report := {"checks": [], "metrics": {}}
var _t_boot := 0


func run(main_node: Node) -> void:
	main = main_node
	_t_boot = Time.get_ticks_msec()
	await _frames(10)
	var vp := get_viewport().get_visible_rect().size
	var safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	report["metrics"]["viewport"] = "%dx%d" % [vp.x, vp.y]
	report["metrics"]["window_px"] = "%dx%d" % [win.x, win.y]
	report["metrics"]["safe_area_px"] = str(safe)
	report["metrics"]["ui_scale"] = get_window().content_scale_factor
	report["metrics"]["boot_to_menu_ms"] = _t_boot
	_check("menu is shown", main._menu_root != null and is_instance_valid(main._menu_root))
	_shot("01_menu")
	# scenario load
	var t := Time.get_ticks_msec()
	main._start_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world_hd.json"))
	await _frames(5)
	report["metrics"]["hd_scenario_load_ms"] = Time.get_ticks_msec() - t
	_check("HD scenario loaded", main.sim != null and main.sim.is_earth_world() and int(main.sim.world["land_count"]) > 20000)
	_check("country list is shown", main.player == -1 and main.sim.countries.size() > 100)
	await _frames(30)
	_shot("02_country_select")
	var pid := 0
	for c in main.sim.countries:
		if c["name"] == "Россия":
			pid = c["id"]
	t = Time.get_ticks_msec()
	main._start_playing(pid)
	await _frames(60)
	report["metrics"]["start_playing_ms"] = Time.get_ticks_msec() - t
	_check("game screen is shown", main.player == pid and main._top != null and is_instance_valid(main._top))
	_shot("03_game")
	_check_hud_bounds("hud")
	report["metrics"]["fps_idle"] = await _fps(3.0, false)
	_mem("after_start")
	# panels
	for name in ["economy", "tech", "politics", "intel", "diplomacy", "army", "build", "stats"]:
		main._nav_pressed(name)
		await _frames(25)
		var panel: Control = _panel_of(name)
		var ok := panel != null and is_instance_valid(panel) and panel.is_inside_tree()
		_check("panel %s opens" % name, ok)
		if ok:
			var r := panel.get_global_rect()
			var vp2 := get_viewport().get_visible_rect().size
			_check("panel %s stays inside the screen" % name, r.position.x >= -1.0 and r.position.y >= -1.0 and r.end.x <= vp2.x + 1.0 and r.end.y <= vp2.y + 1.0)
			report["metrics"]["panel_%s_rect" % name] = str(r)
		if name in ["economy", "tech", "diplomacy"]:
			_shot("04_panel_" + name)
		main._nav_pressed(name)
		await _frames(10)
	# gestures through real input events
	var cam: Camera2D = main.map.camera
	var p0 := cam.position
	var z0 := cam.zoom.x
	await _drag(Vector2(500, 400), Vector2(300, 300))
	_check("one-finger drag pans the map", cam.position.distance_to(p0) > 1.0)
	var z1 := cam.zoom.x
	await _pinch(Vector2(500, 400), 40.0, 160.0)
	_check("two-finger pinch zooms the map in", cam.zoom.x > z1 * 1.2)
	_shot("05_after_gestures")
	# selection and orders
	var cap: int = main.sim.countries[pid]["capital"]
	main._on_province_clicked(cap)
	await _frames(5)
	_check("tapping a territory selects it", main.map.selected_province == cap)
	var army: Dictionary = main.sim.armies_of(pid)[0] if not main.sim.armies_of(pid).is_empty() else {}
	_check("the player has armies", not army.is_empty())
	if not army.is_empty():
		var dest: int = main.sim.provinces()[army["prov"]]["land_neighbors"][0]
		var r2: Dictionary = main.sim.apply_command({"type": "move_army", "country": pid, "army": army["id"], "target": dest})
		_check("an army accepts a move order", r2["ok"] and not army["path"].is_empty())
	# time passes and the UI follows
	var d0: int = main.sim.day
	main._set_speed(3)
	report["metrics"]["fps_running"] = await _fps(4.0, false)
	main._set_speed(0)
	_check("game time advances", main.sim.day > d0)
	report["metrics"]["days_in_4s_at_speed3"] = main.sim.day - d0
	# camera moving (typical play)
	report["metrics"]["fps_panning"] = await _fps(4.0, true)
	_mem("after_play")
	# save / load
	t = Time.get_ticks_msec()
	var saved := SaveSystem.save(main.sim, "qa")
	report["metrics"]["save_ms"] = Time.get_ticks_msec() - t
	t = Time.get_ticks_msec()
	var loaded: Simulation = SaveSystem.load_slot("qa")
	report["metrics"]["load_ms"] = Time.get_ticks_msec() - t
	_check("save is written", saved)
	_check("save loads back with the same state", loaded != null and loaded.checksum() == main.sim.checksum())
	_check("the quick save slot exists after saving", SaveSystem.exists("qa"))
	# long run: memory growth over 60 more days
	var mem_a := OS.get_static_memory_usage()
	for i in 60:
		main.sim.tick_day()
	await _frames(5)
	report["metrics"]["mem_growth_60_days_mb"] = float(OS.get_static_memory_usage() - mem_a) / 1048576.0
	_mem("end")
	report["summary"] = "%d of %d checks passed" % [_passed(), report["checks"].size()]
	var f := FileAccess.open("user://qa_report.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("QA DONE ", report["summary"], " path=", ProjectSettings.globalize_path("user://qa_report.json"))
	if not (OS.get_cmdline_args().has("--qa-hold") or OS.get_cmdline_user_args().has("--qa-hold")):
		get_tree().quit()   # with --qa-hold the game stays open (to test suspend/resume from outside)


func _passed() -> int:
	var n := 0
	for c in report["checks"]:
		if c["ok"]:
			n += 1
	return n


func _check(name: String, ok: bool) -> void:
	report["checks"].append({"name": name, "ok": ok})
	print("QA ", "PASS" if ok else "FAIL", " ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://qa_%s.png" % name)


func _mem(tag: String) -> void:
	report["metrics"]["static_mem_mb_" + tag] = snappedf(float(OS.get_static_memory_usage()) / 1048576.0, 0.1)
	report["metrics"]["texture_mem_mb_" + tag] = snappedf(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1)
	report["metrics"]["draw_calls_" + tag] = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))


## Average and 95th-percentile frame time over `seconds`; with `pan` the camera keeps moving like during play.
func _fps(seconds: float, pan: bool) -> Dictionary:
	var samples: Array = []
	var t_end := Time.get_ticks_msec() + int(seconds * 1000.0)
	var last := Time.get_ticks_usec()
	var cam: Camera2D = main.map.camera
	var p := cam.position
	var k := 0
	while Time.get_ticks_msec() < t_end:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		samples.append(float(now - last) / 1000.0)
		last = now
		if pan:
			k += 1
			cam.position = p + Vector2(sin(k * 0.05) * 120.0, cos(k * 0.04) * 60.0)
	samples.sort()
	var avg := 0.0
	for s in samples:
		avg += s
	avg /= maxf(samples.size(), 1.0)
	return {"avg_ms": snappedf(avg, 0.1), "p95_ms": snappedf(samples[int(samples.size() * 0.95)], 0.1), "fps": snappedf(1000.0 / maxf(avg, 0.001), 0.1), "frames": samples.size()}


func _panel_of(name: String) -> Control:
	var m := {"economy": "_eco", "tech": "_tech", "politics": "_pol", "intel": "_intel"}
	if m.has(name):
		return main.get(m[name])
	return main._generic


func _check_hud_bounds(tag: String) -> void:
	var vp := get_viewport().get_visible_rect().size
	var top: Control = main._top
	var r := top.get_global_rect()
	_check("%s: top bar is inside the screen" % tag, r.position.x >= -1.0 and r.position.y >= -1.0 and r.end.x <= vp.x + 1.0)
	report["metrics"]["top_bar_rect"] = str(r)
	report["metrics"]["bottom_card_rect"] = str(main._bottom.get_global_rect())
	_check("%s: bottom card is inside the screen" % tag, main._bottom.get_global_rect().end.y <= vp.y + 1.0)


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	Input.parse_input_event(e)


func _move(index: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	e.relative = rel
	Input.parse_input_event(e)


func _drag(a: Vector2, b: Vector2) -> void:
	_touch(0, a, true)
	for i in 10:
		var pos := a.lerp(b, float(i + 1) / 10.0)
		_move(0, pos, (b - a) / 10.0)
		await get_tree().process_frame
	_touch(0, b, false)
	await _frames(3)


func _pinch(center: Vector2, d0: float, d1: float) -> void:
	_touch(0, center - Vector2(d0, 0), true)
	_touch(1, center + Vector2(d0, 0), true)
	for i in 10:
		var d := lerpf(d0, d1, float(i + 1) / 10.0)
		_move(0, center - Vector2(d, 0), Vector2(-(d1 - d0) / 10.0, 0))
		_move(1, center + Vector2(d, 0), Vector2((d1 - d0) / 10.0, 0))
		await get_tree().process_frame
	_touch(0, center - Vector2(d1, 0), false)
	_touch(1, center + Vector2(d1, 0), false)
	await _frames(3)
