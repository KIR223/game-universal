extends SceneTree
## Windowed smoke test: boots the real game, simulates some days, saves PNGs.
##   godot --path . -s tools/screenshot.gd -- /path/out_prefix [days]

var main: Node
var frames := 0
var out := "user://shot"
var days := 150


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out = args[0]
	if args.size() > 1:
		days = int(args[1])
	main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 5:
		main._seed_edit.text = "42"
		main._new_game()
	elif frames == 12:
		root.get_viewport().get_texture().get_image().save_png(out + "_select.png")
		main._start_playing(0)
		for i in days:
			main.sim.tick_day()
		var dirty: Array[int] = main.sim.dirty_provinces.duplicate()
		main.sim.dirty_provinces.clear()
		main.map.refresh(dirty)
		main._refresh_all()
		main.map.camera.zoom = Vector2.ONE * 1.0
		main.map.camera.position = Vector2(main.sim.world["w"], main.sim.world["h"]) * MapView.CELL * 0.5
	elif frames == 40:
		root.get_viewport().get_texture().get_image().save_png(out + "_game.png")
		print("wars=", main.sim.wars.size(), " day=", main.sim.day, " alive=", main.sim.alive_count())
		quit(0)
	return false
