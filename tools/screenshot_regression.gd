extends SceneTree
## Visual regression check (windowed run, needs a display): renders key screens at 1600x900, shrinks them to 320x180 and compares
## with the reference images in tests/golden/. Differences above THRESHOLD (mean absolute channel difference, 0..1) fail.
##   godot --path . -s tools/screenshot_regression.gd             compare
##   godot --path . -s tools/screenshot_regression.gd -- --update  rewrite the references (after an intended visual change)
## Animations are off (reduced motion, scratch settings) so two runs of the same build match.

const THRESHOLD := 0.035
const GOLDEN := "res://tests/golden/"

var main: Node
var frames := 0
var update := false
var failed := 0
var steps := ["menu", "scenarios", "country_select", "map_europe", "card_rome", "economy"]
var idx := 0
var wait := 0


func _initialize() -> void:
	update = OS.get_cmdline_user_args().has("--update")
	GameSettings.path = "user://regression_settings.cfg"
	GameSettings.reset_for_tests()
	GameSettings.set_value("reduce_motion", true)
	GameSettings.set_value("tutorial", false)
	main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(main)


func _process(_d: float) -> bool:
	frames += 1
	if wait > 0:
		wait -= 1
		return false
	if idx >= steps.size():
		print("REGRESSION %s: %d of %d screens differ" % ["updated" if update else "done", failed, steps.size()])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameSettings.path))
		quit(1 if failed > 0 and not update else 0)
		return false
	var name: String = steps[idx]
	if not _prepared:
		_prepare(name)
		_prepared = true
		wait = 50
		return false
	_check(name)
	idx += 1
	_prepared = false
	return false


var _prepared := false


func _prepare(name: String) -> void:
	match name:
		"menu":
			pass
		"scenarios":
			main._show_scenarios()
		"country_select":
			main._start_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world_hd.json"))
		"map_europe":
			var pid := _country("Италия")
			main._start_playing(pid)
			main.map.camera.zoom = Vector2.ONE * 2.2
			main.map.camera.position = main.map.call("world_pos_of", 12.5, 43.0)
		"card_rome":
			main.map.selected_province = main.sim.countries[main.player]["capital"]
			main._refresh_all()
		"economy":
			main._nav_pressed("economy")


func _country(n: String) -> int:
	for c in main.sim.countries:
		if c["name"] == n:
			return c["id"]
	return 0


func _check(name: String) -> void:
	var img := root.get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	img.resize(320, 180, Image.INTERPOLATE_LANCZOS)
	var path := GOLDEN + name + ".png"
	if update:
		img.save_png(ProjectSettings.globalize_path(path))
		print("REGRESSION wrote ", path)
		return
	var ref := Image.load_from_file(ProjectSettings.globalize_path(path))
	if ref == null:
		print("REGRESSION missing reference ", path)
		failed += 1
		return
	ref.convert(Image.FORMAT_RGB8)
	var diff := 0.0
	for y in 180:
		for x in 320:
			var a := img.get_pixel(x, y)
			var b := ref.get_pixel(x, y)
			diff += (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
	diff /= 320.0 * 180.0
	var ok := diff <= THRESHOLD
	print("REGRESSION %-15s diff %.4f %s" % [name, diff, "ok" if ok else "FAILED"])
	if not ok:
		failed += 1
		img.save_png(ProjectSettings.globalize_path("user://regression_" + name + ".png"))
