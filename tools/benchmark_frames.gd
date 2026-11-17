extends SceneTree
## Windowed frame-time benchmark of a scenario: camera pan and zoom, prints average / p95 frame time.
##   godot --path . -s tools/benchmark_frames.gd -- modern_world_xl
var main: Node
var frames := 0
var phase := "load"
var samples: Array = []
var last := 0
var scn := "modern_world"
func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: scn = a[0]
	main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(main)
func _stats() -> String:
	var s := samples.duplicate(); s.sort()
	var avg := 0.0
	for v in s: avg += v
	avg /= s.size()
	return "%.1f ms avg, p95 %.1f ms (%.0f FPS)" % [avg, s[int(s.size() * 0.95)], 1000.0 / avg]
func _process(_d: float) -> bool:
	frames += 1
	if phase == "load" and frames == 3:
		main._start_scenario(ScenarioLoader.read_file("res://game/scenarios/%s.json" % scn))
		main._start_playing(0)
		main.map.camera.zoom = Vector2.ONE * 0.25
		phase = "warm"; frames = 0
	elif phase == "warm" and frames == 120:
		phase = "pan"; frames = 0; samples.clear(); last = Time.get_ticks_usec()
	elif phase == "pan":
		var now := Time.get_ticks_usec(); samples.append((now - last) / 1000.0); last = now
		var t := float(frames) / 300.0
		main.map.camera.position = main.map.call("world_pos_of", -120.0 + 280.0 * t, 45.0 - 40.0 * t)
		if frames >= 300:
			print(scn, " PAN: ", _stats()); phase = "zoom"; frames = 0; samples.clear()
	elif phase == "zoom":
		var now2 := Time.get_ticks_usec(); samples.append((now2 - last) / 1000.0); last = now2
		main.map.camera.zoom = Vector2.ONE * (0.2 * pow(40.0, float(frames) / 300.0))
		main.map.camera.position = main.map.call("world_pos_of", 10.0, 50.0)
		if frames >= 300:
			print(scn, " ZOOM: ", _stats()); quit(0)
	return false
