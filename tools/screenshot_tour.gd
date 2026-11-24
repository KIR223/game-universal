extends SceneTree
## Windowed map tour: starts the HD scenario and saves screenshots at several places and zoom levels.
##   godot --path . -s tools/screenshot_tour.gd -- /out/dir [scenario]
var main: Node
var frames := 0
var out := "user://tour"
var spots := [
	["world", Vector2(10, 40), 0.35], ["europe", Vector2(12, 48), 1.2], ["alps", Vector2(10.5, 46.5), 4.0],
	["himalaya", Vector2(86.9, 28.0), 6.0], ["nyc", Vector2(-74.0, 40.7), 14.0], ["coast", Vector2(-9.1, 38.7), 10.0],
	["sahara", Vector2(10.0, 25.0), 3.0], ["ocean", Vector2(-30.0, 30.0), 2.0], ["japan", Vector2(138.0, 36.0), 5.0],
]
var idx := 0
var scenario := "modern_world_hd"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out = args[0]
	if args.size() > 1:
		scenario = args[1]
	GameSettings.path = "user://tour_settings.cfg"
	GameSettings.reset_for_tests()
	GameSettings.set_value("reduce_motion", true)
	GameSettings.set_value("tutorial", false)
	main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(main)


func _process(_d: float) -> bool:
	frames += 1
	if frames == 60:
		main._start_scenario(ScenarioLoader.read_file("res://game/scenarios/%s.json" % scenario))
	elif frames == 140:
		var pid := 0
		for c in main.sim.countries:
			if c["name"] == "Франция":
				pid = c["id"]
		main._start_playing(pid)
	elif frames > 200 and (frames - 200) % 45 == 0 and idx < spots.size():
		var s: Array = spots[idx]
		var cam: Camera2D = main.map.camera
		cam.zoom = Vector2.ONE * float(s[2])
		cam.position = main.map.world_pos_of(s[1].x, s[1].y)
	elif frames > 200 and (frames - 200) % 45 == 40 and idx < spots.size():
		root.get_viewport().get_texture().get_image().save_png("%s/%02d_%s.png" % [out, idx, spots[idx][0]])
		idx += 1
	elif idx >= spots.size():
		print("TOUR done")
		quit(0)
	return false
