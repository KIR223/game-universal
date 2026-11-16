extends SceneTree
## Windowed smoke test on the REAL world: start modern_world, play days, screenshot,
## save -> load round trip with checksum comparison.
##   godot --path . -s tools/screenshot_earth.gd -- out_prefix [days]

var main: Node
var frames := 0
var out := "user://earth"
var days := 60
var sum_before := ""


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
	if frames == 90:
		main._start_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json"))
	elif frames == 100:
		root.get_viewport().get_texture().get_image().save_png(out + "_select.png")
		var cid := 0
		for c in main.sim.countries:
			if c["name"].find("Польша") >= 0 or c["name"] == "Poland":
				cid = c["id"]
		main._start_playing(cid)
		var t := Time.get_ticks_msec()
		for i in days:
			main.sim.tick_day()
		print("sim ", days, " days: ", Time.get_ticks_msec() - t, " ms, country=", main.sim.countries[cid]["name"])
		main.sim.dirty_provinces.clear()
		main._refresh_all()
		main.map.camera.zoom = Vector2.ONE * 3.0
	elif frames == 130:
		root.get_viewport().get_texture().get_image().save_png(out + "_game.png")
		var ok := SaveSystem.save(main.sim, "wintest")
		sum_before = str(main.sim.checksum())
		var loaded := SaveSystem.load_slot("wintest")
		var same: bool = loaded != null and str(loaded.checksum()) == sum_before
		print("save ok=", ok, " load ok=", loaded != null, " checksum equal=", same, " day=", main.sim.day, " owner cells=", main.sim.owner.size())
		quit(0 if same else 1)
	return false
