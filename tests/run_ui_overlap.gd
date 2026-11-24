extends SceneTree
## Overlap and overflow audit at many screen shapes (desktop and phone/tablet layouts):
##   godot --headless --path . -s tests/run_ui_overlap.gd              desktop layout
##   godot --headless --path . -s tests/run_ui_overlap.gd -- --phone   phone layout (bottom navigation, compact card)
## For every size: HUD pieces stay inside the window and never overlap each other; every nav panel stays inside the window, clear of
## the top bar and navigation, and nothing inside a panel is wider than the panel (no clipped text or buttons).

const DESKTOP: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1080), Vector2i(1280, 1024), Vector2i(1024, 768)]
const PHONE: Array[Vector2i] = [Vector2i(1170, 540), Vector2i(1334, 600), Vector2i(1560, 720), Vector2i(1624, 750), Vector2i(1366, 1024), Vector2i(1180, 820), Vector2i(960, 440)]

var passed := 0
var failures := 0
var _main: Node
var _frames := 0
var _phone := false


func _initialize() -> void:
	_phone = OS.get_cmdline_user_args().has("--phone")
	if _phone:
		MobileLayout.force = true
	GameSettings.path = "user://test_overlap_settings.cfg"
	GameSettings.reset_for_tests()
	GameSettings.set_value("reduce_motion", true)
	GameSettings.set_value("tutorial", false)
	_main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(_main)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 3:
		_run_all()
	return false


func _run_all() -> void:
	await run()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GameSettings.path))
	print("\n%d UI overlap checks passed, %d failed" % [passed, failures])
	quit(1 if failures > 0 else 0)


func _wait(n: int = 3) -> void:
	for i in n:
		await process_frame


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failures += 1
		printerr("  FAIL: ", msg)


func _vis(c: Control) -> bool:
	return c != null and is_instance_valid(c) and c.is_visible_in_tree()


## Descendant controls wider than the scroll area that holds them would be clipped (horizontal scrolling is off in panels).
func _overflow(panel: Control, tag: String) -> void:
	var stack: Array = [panel]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is ScrollContainer and _vis(n as Control):
			var sc := n as ScrollContainer
			var lim := sc.get_global_rect().end.x + 1.0
			var inner: Array = [sc]
			while not inner.is_empty():
				var m: Node = inner.pop_back()
				for ch in m.get_children():
					inner.append(ch)
					if ch is Control and _vis(ch as Control) and (ch is Button or ch is Label or ch is ProgressBar):
						var r := (ch as Control).get_global_rect()
						if r.size.x > 1.0 and r.end.x > lim:
							check(false, "%s: %s «%s» sticks out of its panel by %.0f px" % [tag, ch.get_class(), (ch.text if "text" in ch else ""), r.end.x - lim])
		for ch2 in n.get_children():
			stack.append(ch2)


func run() -> void:
	var main: Node = _main
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"gov2": true}
	main._start_scenario(scn)
	var fr: int = main.sim.countries.find_custom(func(c): return c["name"] == "Франция")
	main._start_playing(fr)
	main.map.hide()
	var sizes: Array[Vector2i] = PHONE if _phone else DESKTOP
	for res in sizes:
		root.size = res
		root.content_scale_size = Vector2i(1600, 900) if not _phone else Vector2i(1170, 540)
		var vis: Rect2 = root.get_visible_rect()
		var tag := "%s %dx%d" % ["phone" if _phone else "desktop", res.x, res.y]
		main._refresh_all()
		await _wait()
		var hud := {"top": main._top, "nav": main._nav["state"].get_parent().get_parent(), "bottom": main._bottom, "modes": main._mode_opt.get_parent().get_parent()}
		if _vis(main._right):
			hud["right"] = main._right
		var rects := {}
		for k in hud:
			var p: Control = hud[k]
			if not _vis(p):
				continue
			rects[k] = p.get_global_rect()
			check(vis.grow(1.0).encloses(rects[k]), "%s: %s inside the window (%s in %s)" % [tag, k, str(rects[k]), str(vis)])
		var keys := rects.keys()
		for i in keys.size():
			for j in range(i + 1, keys.size()):
				check(not (rects[keys[i]] as Rect2).grow(-1.0).intersects((rects[keys[j]] as Rect2).grow(-1.0)), "%s: %s and %s overlap (%s / %s)" % [tag, keys[i], keys[j], str(rects[keys[i]]), str(rects[keys[j]])])
		# every top-bar child stays inside the bar
		var top: Control = main._top
		for ch in top.find_children("*", "Control", true, false):
			var c := ch as Control
			if _vis(c) and c.size.x > 1.0:
				var r := c.get_global_rect()
				if r.end.x > top.get_global_rect().end.x + 1.0 or r.position.x < top.get_global_rect().position.x - 1.0:
					check(false, "%s: top bar item %s sticks out (%s of %s)" % [tag, c.get_class(), str(r), str(top.get_global_rect())])
		for it in main._nav_items():
			main._nav_pressed(it[0])
			main._refresh_all()
			await _wait()
			var pn := ""
			var panel: Control = null
			match it[0]:
				"economy": panel = main._eco
				"tech": panel = main._tech
				"politics": panel = main._pol
				"intel": panel = main._intel
				_: panel = main._generic
			if panel != null and is_instance_valid(panel):
				var pr := panel.get_global_rect()
				check(vis.grow(1.0).encloses(pr), "%s: panel %s inside the window (%s in %s)" % [tag, it[0], str(pr), str(vis)])
				check(not pr.grow(-1.0).intersects((rects["top"] as Rect2).grow(-1.0)), "%s: panel %s covers the top bar" % [tag, it[0]])
				check(not pr.grow(-1.0).intersects((rects["nav"] as Rect2).grow(-1.0)), "%s: panel %s covers the navigation (%s vs %s)" % [tag, it[0], str(pr), str(rects["nav"])])
				_overflow(panel, "%s panel %s" % [tag, it[0]])
			else:
				check(false, "%s: panel %s opens" % [tag, it[0]])
			main._nav_pressed(it[0])
