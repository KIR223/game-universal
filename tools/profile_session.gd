extends SceneTree
## Real play session profile on the real world, in a window: load times, memory, frame times and how many game
## days per second the game really reaches at each speed setting (with the HUD attached).
##   godot --path . -s tools/profile_session.gd -- [seconds_per_speed] [zoom]
## Events are disabled so the event dialog does not pause the simulation while measuring.

var main: Node
var f := 0
var secs := 12.0
var zoom := 1.0
var speed := 0
var t_phase := 0
var day_start := 0
var frames: Array[float] = []
var last := 0
var t_boot := 0
var results: Array = []


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		secs = float(a[0])
	if a.size() > 1:
		zoom = float(a[1])
	t_boot = Time.get_ticks_msec()
	main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(main)


func _process(_d: float) -> bool:
	f += 1
	if f == 3:
		print("menu ready: %d ms after start (engine boot excluded)" % (Time.get_ticks_msec() - t_boot))
		var t := Time.get_ticks_msec()
		main._start_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json"))
		print("scenario load (setup + map bind): %d ms" % (Time.get_ticks_msec() - t))
	elif f == 6:
		var t2 := Time.get_ticks_msec()
		main._start_playing(0)
		print("start playing (HUD build): %d ms" % (Time.get_ticks_msec() - t2))
		for e in main.sim.event_defs:
			main.sim.disabled_events.append(e["id"])
		main.map.camera.position_smoothing_enabled = false
		main.map.camera.zoom = Vector2.ONE * zoom
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
		_begin_speed(1)
	elif f > 6 and speed > 0:
		var now := Time.get_ticks_usec()
		if last > 0:
			frames.append(float(now - last) / 1000.0)
		last = now
		if (Time.get_ticks_msec() - t_phase) / 1000.0 >= secs:
			_end_speed()
			if speed < 4:
				_begin_speed(speed + 1)
			else:
				_report()
				quit(0)
	return false


func _begin_speed(i: int) -> void:
	speed = i
	main._set_speed(i)
	t_phase = Time.get_ticks_msec()
	day_start = main.sim.day
	frames.clear()
	last = 0


func _end_speed() -> void:
	var rid := root.get_viewport_rid()
	var days: int = main.sim.day - day_start
	var avg := 0.0
	for v in frames:
		avg += v
	avg /= maxf(1.0, float(frames.size()))
	var sorted := frames.duplicate()
	sorted.sort()
	var p95: float = sorted[int(sorted.size() * 0.95)] if sorted.size() > 0 else 0.0
	results.append("speed %d (%sx): %.1f days/s | frame avg %.1f ms (%.0f FPS) p95 %.1f ms | render cpu %.2f ms gpu %.2f ms | draw calls %d" % [
		speed, str(main.SPEEDS[speed]), float(days) / secs, avg, 1000.0 / maxf(avg, 0.001), p95,
		RenderingServer.viewport_get_measured_render_time_cpu(rid), RenderingServer.viewport_get_measured_render_time_gpu(rid),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))])


func _report() -> void:
	print("--- zoom %.2f, %d s per speed, day reached: %d ---" % [zoom, int(secs), main.sim.day])
	for r in results:
		print(r)
	print("memory: static %.0f MB, video %.0f MB, texture %.0f MB" % [
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0])
	print("objects: %d, nodes: %d" % [int(Performance.get_monitor(Performance.OBJECT_COUNT)), int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
