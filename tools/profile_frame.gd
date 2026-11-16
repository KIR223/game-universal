extends SceneTree
## Windowed frame profiler on the real world (VSync off): wall frame time, CPU/GPU render time, draw calls.
##   godot --path . -s tools/profile_frame.gd -- [zoom] [frames]

var main: Node
var frames := 0
var zoom := 0.25
var total := 300
var wall: Array[float] = []
var cpu: Array[float] = []
var gpu: Array[float] = []
var last := 0
var static_cam := false


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		zoom = float(a[0])
	if a.size() > 2:
		static_cam = a[2] == "static"
	if a.size() > 1:
		total = int(a[1])
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(main)


func _process(_d: float) -> bool:
	frames += 1
	if frames == 5:
		main._start_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json"))
	elif frames == 10:
		main._start_playing(0)
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
		main.map.camera.position_smoothing_enabled = false
		main.map.camera.zoom = Vector2.ONE * zoom
	elif frames > 60 and frames <= 60 + total:
		var t_ := float(frames - 60) / float(total)
		if not static_cam:
			main.map.camera.position = main.map.world_pos_of(-120.0 + 280.0 * t_, 45.0 - 40.0 * t_)
		var now := Time.get_ticks_usec()
		if last > 0:
			wall.append(float(now - last) / 1000.0)
		last = now
		var rid := root.get_viewport_rid()
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	elif frames > 60 + total:
		print("zoom ", zoom, ": wall ", _avg(wall), " ms (", 1000.0 / _avg(wall), " FPS) | render CPU ", _avg(cpu), " ms | GPU ", _avg(gpu),
			" ms | draw calls ", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			" | process ", Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, " ms")
		var m: Array = Engine.get_meta("prof", [0,0,0,0,0])
		if m[3] > 0:
			print("per _draw: base ", m[0]/m[3]/1000.0, " ms, units ", m[1]/m[3]/1000.0, " ms, labels ", m[2]/m[3]/1000.0, " ms, draws ", m[3])
		quit(0)
	return false


func _avg(a: Array[float]) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(1.0, float(a.size()))
