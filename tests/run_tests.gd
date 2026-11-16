extends SceneTree
## Headless test runner:
##   godot --headless --path . -s tests/run_tests.gd
## Exit code 0 = all passed.

var failures := 0
var passed := 0


func _init() -> void:
	for m in get_method_list():
		if str(m["name"]).begins_with("test_"):
			print("▶ ", m["name"])
			call(m["name"])
	print("\n%d checks passed, %d failed" % [passed, failures])
	quit(1 if failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failures += 1
		printerr("  FAIL: ", msg)


func _make(seed_value: int) -> Simulation:
	var sim := Simulation.new()
	sim.setup(seed_value, Simulation.load_country_defs())
	return sim


func test_country_data() -> void:
	var defs := Simulation.load_country_defs()
	check(defs.size() >= 2, "countries.json has entries")
	var tags := {}
	for d in defs:
		check(d.has("tag") and d.has("name") and d.has("color"), "country has required fields")
		check(not tags.has(d["tag"]), "unique tag " + str(d["tag"]))
		tags[d["tag"]] = true


func test_worldgen_deterministic() -> void:
	var a := WorldGen.generate(42)
	var b := WorldGen.generate(42)
	var c := WorldGen.generate(43)
	check(a["cell_prov"] == b["cell_prov"], "same seed => same map")
	check(a["cell_prov"] != c["cell_prov"], "different seed => different map")
	var land := WorldGen.main_landmass(a)
	check(land.size() >= 20, "main landmass is big enough (%d)" % land.size())
	var caps := WorldGen.pick_capitals(a, 8, RandomNumberGenerator.new())
	check(caps.size() == 8, "8 capitals picked")


func test_world_integrity() -> void:
	var sim := _make(7)
	for p in sim.provinces():
		for q in p["neighbors"]:
			check(sim.provinces()[q]["neighbors"].has(p["id"]), "adjacency symmetric")
	var ids_ok := true
	for o in sim.owner:
		if o < -1 or o >= sim.countries.size():
			ids_ok = false
	check(ids_ok, "owner ids valid")
	for c in sim.countries:
		check(sim.owner[c["capital"]] == c["id"], "capital owned by its country")


func test_simulation_deterministic() -> void:
	var a := _make(99)
	var b := _make(99)
	for i in 400:
		a.tick_day()
		b.tick_day()
	check(a.checksum() == b.checksum(), "same seed + same inputs => same checksum")
	check(a.wars.size() >= 0 and a.armies.size() > 0, "armies exist after 400 days")
	var ids_ok := true
	for o in a.owner:
		if o < -1 or o >= a.countries.size():
			ids_ok = false
	check(ids_ok, "owner ids still valid after simulation")


func test_ai_wages_war() -> void:
	var sim := _make(5)
	var saw_war := false
	for i in 600:
		sim.tick_day()
		if not sim.wars.is_empty():
			saw_war = true
	check(saw_war, "AI declares at least one war within 600 days")


func test_commands() -> void:
	var sim := _make(11)
	var bad := sim.apply_command({"type": "nope", "country": 0})
	check(not bad["ok"], "unknown command rejected")
	var bad2 := sim.apply_command({"type": "declare_war", "country": 0, "target": 0})
	check(not bad2["ok"], "cannot declare war on self")
	var before := sim.armies.size()
	var r := sim.apply_command({"type": "recruit", "country": 0})
	check(r["ok"] and sim.armies.size() == before + 1, "recruit works")
	sim.countries[0]["treasury"] = 0
	check(not sim.apply_command({"type": "recruit", "country": 0})["ok"], "recruit needs funds")
	var nb := sim.neighbor_countries(0)
	if not nb.is_empty():
		check(sim.apply_command({"type": "declare_war", "country": 0, "target": nb[0]})["ok"], "declare war on neighbor")
		check(sim.at_war(0, nb[0]), "war recorded")
	check(sim.command_log.size() >= 1, "commands are logged")


func test_save_roundtrip() -> void:
	var sim := _make(21)
	for i in 120:
		sim.tick_day()
	var restored := Simulation.from_dict(str_to_var(var_to_str(sim.to_dict())), Simulation.load_country_defs())
	check(sim.checksum() == restored.checksum(), "save/load preserves state")
	for i in 60:
		sim.tick_day()
		restored.tick_day()
	check(sim.checksum() == restored.checksum(), "restored sim continues identically")
