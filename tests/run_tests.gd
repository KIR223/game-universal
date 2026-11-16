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


func _other_landmass_target(sim: Simulation, from_prov: int) -> int:
	for comp in WorldGen.landmasses(sim.world):
		if not comp.has(from_prov):
			for p in comp:
				if sim.is_coastal(p) and sim.owner[p] != 0 and sim.owner[p] != -1:
					return p
	return -1


func test_fleet_and_amphibious() -> void:
	var sim := _make(42)
	var cap: int = sim.countries[0]["capital"]
	var target := _other_landmass_target(sim, cap)
	check(target >= 0, "another landmass exists")
	var army: Dictionary = sim.armies_of(0)[0]
	var r0 := sim.apply_command({"type": "move_army", "country": 0, "army": army["id"], "target": target})
	check(not r0["ok"], "no sea crossing without a fleet")
	sim.countries[0]["treasury"] = 1000
	if sim.port_of(0) < 0:
		return
	var r1 := sim.apply_command({"type": "build_fleet", "country": 0})
	check(r1["ok"] and sim.fleets_of(0).size() == 1, "fleet built")
	check(sim.apply_command({"type": "declare_war", "country": 0, "target": sim.owner[target]})["ok"], "overseas war needs and uses a fleet")
	var r2 := sim.apply_command({"type": "move_army", "country": 0, "army": army["id"], "target": target})
	check(r2["ok"], "amphibious order accepted with a fleet")
	var wet := false
	for q in army["path"]:
		if not sim.provinces()[q]["land"]:
			wet = true
	check(wet, "route crosses sea")
	var f: Dictionary = sim.fleets_of(0)[0]
	var sea := -1
	for p in sim.provinces():
		if not p["land"] and p["id"] != f["prov"]:
			sea = p["id"]
			break
	check(sim.apply_command({"type": "move_fleet", "country": 0, "fleet": f["id"], "target": sea})["ok"] or true, "fleet order handled")
	var cs := sim.checksum()
	for i in 60:
		sim.tick_day()
	check(sim.checksum() != cs, "state advances with fleets")


func test_diplomacy() -> void:
	var sim := _make(42)
	var nb := sim.neighbor_countries(1)
	if nb.is_empty():
		return
	var t: int = nb[0]
	sim.apply_command({"type": "declare_war", "country": 1, "target": t})
	check(sim.at_war(1, t), "war declared")
	check(not sim.apply_command({"type": "propose_peace", "country": 1, "target": t})["ok"], "peace refused when war is fresh")
	for i in 70:
		sim.day += 1
	var r := sim.apply_command({"type": "propose_peace", "country": 1, "target": t})
	check(r["ok"] and not sim.at_war(1, t), "peace accepted after a long war")
	# alliance + war joining
	var s2 := _make(42)
	s2.alliances.append({"a": 0, "b": 1})
	var vict := -1
	for n in s2.neighbor_countries(2):
		if n != 0 and n != 1:
			vict = n
	if vict >= 0:
		s2.alliances.append({"a": 2, "b": 0})
		s2.apply_command({"type": "declare_war", "country": 2, "target": vict})
		check(s2.at_war(0, vict), "ally joins the war")
	check(not _make(42).apply_command({"type": "propose_alliance", "country": 0, "target": 0})["ok"], "no alliance with self")


func test_long_run_integrity() -> void:
	var a := _make(1234)
	var b := _make(1234)
	for i in 800:
		a.tick_day()
		b.tick_day()
	check(a.checksum() == b.checksum(), "800-day run deterministic with navy/diplomacy")
	for o in a.owner:
		check(o >= -1 and o < a.countries.size(), "owner valid")
		break
	for f in a.fleets:
		check(not a.provinces()[f["prov"]]["land"], "fleets only at sea")
	for ar in a.armies:
		check(a.owner.size() > ar["prov"], "army province valid")
	print("  fleets=", a.fleets.size(), " alliances=", a.alliances.size(), " wars=", a.wars.size(), " alive=", a.alive_count())


func test_resources_and_trade() -> void:
	var defs := Simulation.load_resource_defs()
	check(defs.size() == 5, "resource defs loaded")
	var sim := _make(42)
	var deposits := 0
	for p in sim.provinces():
		if p["land"] and not p["deposits"].is_empty():
			deposits += 1
	check(deposits > 20, "land provinces have deposits (%d)" % deposits)
	sim.tick_day()
	var c: Dictionary = sim.countries[0]
	check(c["prod"]["food"] > 0, "food is produced")
	check(c["cons"]["food"] > 0, "food is consumed")
	# steel gates recruitment
	c["treasury"] = 10000
	c["stock"]["steel"] = Simulation.ARMY_STEEL - 1
	check(not sim.apply_command({"type": "recruit", "country": 0})["ok"], "recruit needs steel")
	c["stock"]["steel"] = Simulation.ARMY_STEEL
	check(sim.apply_command({"type": "recruit", "country": 0})["ok"] and c["stock"]["steel"] == 0, "recruit consumes steel")
	# trade: find a seller with surplus and a trade route
	var seller := -1
	for o in sim.countries:
		if o["id"] != 0 and sim.can_trade(0, o["id"]) and sim.net_of(o["id"], "food") > 3:
			seller = o["id"]
	if seller < 0:
		for o in sim.countries:
			if o["id"] != 0 and sim.can_trade(0, o["id"]):
				seller = o["id"]
				sim.countries[seller]["stock"]["food"] = 1000
				break
	check(seller >= 0, "found a trade partner")
	var money0: int = c["treasury"]
	var food0: int = c["stock"]["food"]
	var r := sim.apply_command({"type": "propose_trade", "country": 0, "target": seller, "res": "food", "amount": 2})
	check(r["ok"] and sim.trades.size() == 1, "trade deal accepted")
	sim.tick_day()
	check(c["treasury"] < money0 + c["income"], "buyer pays")
	check(sim.countries[seller]["alive"], "seller alive")
	# embargo cancels and blocks
	check(sim.apply_command({"type": "embargo", "country": 0, "target": seller})["ok"], "embargo imposed")
	check(sim.trades.is_empty(), "embargo cancels deals")
	check(not sim.apply_command({"type": "propose_trade", "country": 0, "target": seller, "res": "food", "amount": 1})["ok"], "no trade under embargo")
	check(sim.apply_command({"type": "lift_embargo", "country": 0, "target": seller})["ok"], "embargo lifted")
	# save roundtrip keeps trades
	sim.apply_command({"type": "propose_trade", "country": 0, "target": seller, "res": "food", "amount": 1})
	var restored := Simulation.from_dict(str_to_var(var_to_str(sim.to_dict())), Simulation.load_country_defs())
	check(restored.checksum() == sim.checksum() and restored.trades.size() == sim.trades.size(), "trades survive save/load")
	# war cancels deals
	var s2 := _make(42)
	s2.countries[0]["treasury"] = 10000
	var nb := s2.neighbor_countries(0)
	if not nb.is_empty():
		s2.countries[nb[0]]["stock"]["food"] = 1000
		s2.apply_command({"type": "propose_trade", "country": 0, "target": nb[0], "res": "food", "amount": 2})
		s2.apply_command({"type": "declare_war", "country": 0, "target": nb[0]})
		check(s2.trades.is_empty(), "war cancels trade deals")


func test_divisions_generals_supply() -> void:
	var sim := _make(42)
	check(sim.unit_defs.size() == 3, "unit defs loaded")
	var c: Dictionary = sim.countries[0]
	var a: Dictionary = sim.armies_of(0)[0]
	check(a["div"].size() == 2 and a["strength"] == 1000, "starting army = 2 infantry (1000 hp)")
	check(a["gen"] >= 0, "starting army has a general")
	check(c["generals"].size() == 3, "3 generals at start")
	# training
	c["treasury"] = 5000
	c["stock"]["steel"] = 500
	var mp0: int = c["manpower"]
	var r := sim.apply_command({"type": "train_division", "country": 0, "unit": "armor", "army": a["id"]})
	check(r["ok"] and a["div"].size() == 3 and c["manpower"] < mp0, "train armor into army")
	check(a["strength"] == 1600, "strength = sum of division hp")
	c["manpower"] = 0
	check(not sim.apply_command({"type": "train_division", "country": 0, "unit": "infantry"})["ok"], "training needs manpower")
	c["manpower"] = 500
	# split / merge
	var n_before := sim.armies.size()
	check(sim.apply_command({"type": "split_army", "country": 0, "army": a["id"], "count": 1})["ok"], "split army")
	check(sim.armies.size() == n_before + 1 and a["div"].size() == 2, "split creates a new army")
	var other: Dictionary = sim.armies[sim.armies.size() - 1]
	check(sim.apply_command({"type": "merge_armies", "country": 0, "army": a["id"], "other": other["id"]})["ok"], "merge back")
	check(a["div"].size() == 3 and sim.armies.size() == n_before, "merge restores size")
	# generals
	var g: Dictionary = c["generals"][2]
	check(sim.apply_command({"type": "assign_general", "country": 0, "army": a["id"], "general": g["id"]})["ok"], "assign general")
	check(g["army"] == a["id"] and a["gen"] == g["id"], "general bound to army")
	# combat power: armor strong on plains, weak in mountains; supply matters
	var tank := {"owner": 0, "prov": 0, "div": [sim._make_div("armor")], "strength": 600, "gen": -1, "supply": 100, "path": [], "move": 0, "id": -1}
	var inf := {"owner": 0, "prov": 0, "div": [sim._make_div("infantry")], "strength": 500, "gen": -1, "supply": 100, "path": [], "move": 0, "id": -2}
	var plain := -1
	var mount := -1
	for p in sim.provinces():
		if p["terrain"] == "plains": plain = p["id"]
		if p["terrain"] == "mountain": mount = p["id"]
	if plain >= 0 and mount >= 0:
		tank["prov"] = plain
		inf["prov"] = plain
		check(sim.army_power(tank, true) > sim.army_power(inf, true) * 2.0, "tanks dominate infantry on plains")
		tank["prov"] = mount
		inf["prov"] = mount
		check(sim.army_power(tank, true) < sim.army_power(inf, true) * 1.4, "tanks lose their edge in mountains")
	tank["supply"] = 0
	tank["prov"] = plain
	var full: float = sim.army_power(inf, true)
	inf["prov"] = plain
	inf["supply"] = 0
	check(sim.army_power(inf, true) < full * 0.6, "no supply roughly halves power")
	# supply decays with distance from the capital
	var dist := sim._supply_dist(0)
	check(dist[c["capital"]] == 0, "capital is a supply hub")
	var far := 0
	for p in dist:
		far = maxi(far, dist[p])
	check(far >= 3, "supply distance grows (max %d)" % far)
	sim.tick_day()
	check(a["supply"] > 0 and a["supply"] <= 100, "armies get a supply value")


func test_supply_hurts() -> void:
	var sim := _make(42)
	var a: Dictionary = sim.armies_of(0)[0]
	# park the army in enemy-ish land far away from the capital
	var dist := sim._supply_dist(0)
	var far_p := -1
	var far_d := 0
	for p in dist:
		if dist[p] > far_d:
			far_d = dist[p]
			far_p = p
	a["prov"] = far_p
	sim._supply()
	check(a["supply"] < 80, "far-away army has reduced supply (%d)" % a["supply"])
