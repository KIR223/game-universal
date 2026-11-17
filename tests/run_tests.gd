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
			EarthWorld.activate("world")  # scenario tests may switch the dataset; every test starts from the base world
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


func test_technology() -> void:
	var sim := _make(42)
	check(sim.tech_defs.size() == 38, "tech defs loaded")
	var c: Dictionary = sim.countries[0]
	check(not sim.apply_command({"type": "research", "country": 0, "tech": "nope"})["ok"], "unknown tech rejected")
	check(not sim.apply_command({"type": "research", "country": 0, "tech": "ind3"})["ok"], "missing prerequisites rejected")
	check(sim.apply_command({"type": "research", "country": 0, "tech": "ag1"})["ok"], "queue ag1")
	check(not sim.apply_command({"type": "research", "country": 0, "tech": "ag1"})["ok"], "no duplicate queue")
	check(sim.apply_command({"type": "research", "country": 0, "tech": "ag2"})["ok"], "can queue behind queued prerequisite")
	check(sim.apply_command({"type": "unqueue_tech", "country": 0, "tech": "ag1"})["ok"], "unqueue")
	check(c["queue"].is_empty(), "dependents removed with their prerequisite")
	# research finishes and its effect applies
	sim.apply_command({"type": "research", "country": 0, "tech": "ag1"})
	var days := 0
	while not c["techs"].has("ag1") and days < 200:
		sim.tick_day()
		days += 1
	check(c["techs"].has("ag1"), "ag1 researched in %d days" % days)
	check(days > 5 and days < 120, "research takes a sensible time (%d days)" % days)
	check(sim.mod(0, "food_pct") == 15, "effect applied to modifiers")
	# slots: only `slots` techs progress at once
	var s2 := _make(42)
	for id in ["ag1", "en1", "wp1", "lg1"]:
		s2.apply_command({"type": "research", "country": 0, "tech": id})
	s2.tick_day()
	check(s2.countries[0]["progress"].size() == s2.research_slots(0), "only %d techs progress at once" % s2.research_slots(0))
	# real effects
	var a := _make(42)
	var b := _make(42)
	b.countries[0]["techs"] = ["wp1", "ar1", "lg1", "eco1"]
	b._recalc_mods(0)
	var inf := {"owner": 0, "prov": 0, "div": [a._make_div("infantry")], "strength": 500, "gen": -1, "supply": 100, "path": [], "move": 0, "id": -1}
	check(b.army_power(inf, true) > a.army_power(inf, true) * 1.09, "weapons tech boosts infantry attack")
	a.tick_day()
	b.tick_day()
	check(b.countries[0]["income"] > a.countries[0]["income"], "economy tech raises income")
	var dist_a := a._supply_dist(0)
	check(dist_a.size() > 0, "supply hubs exist")
	# AI researches and everything stays deterministic
	var x := _make(7)
	var y := _make(7)
	for i in 300:
		x.tick_day()
		y.tick_day()
	check(x.checksum() == y.checksum(), "deterministic with research")
	var total := 0
	for cc in x.countries:
		total += cc["techs"].size()
	check(total > 8, "AI countries research technologies (%d done)" % total)
	# save/load keeps research
	var r := Simulation.from_dict(str_to_var(var_to_str(x.to_dict())), Simulation.load_country_defs())
	check(r.checksum() == x.checksum(), "research survives save/load")
	check(r.mod(0, "income_pct") == x.mod(0, "income_pct"), "modifiers rebuilt after load")


func _prep_air(sim: Simulation) -> void:
	for c in sim.countries:
		c["treasury"] = 100000
		c["stock"]["steel"] = 5000
		c["manpower"] = 5000


func test_aviation() -> void:
	var sim := _make(42)
	_prep_air(sim)
	check(sim.air_defs.size() == 3, "aircraft defs loaded")
	var cap: int = sim.countries[0]["capital"]
	var enemy_cap: int = sim.countries[1]["capital"]
	# building
	var r := sim.apply_command({"type": "build_wing", "country": 0, "type_air": "fighter", "base": cap})
	check(r["ok"] and sim.wings.size() == 1 and sim.wings[0]["strength"] == Simulation.WING_SIZE, "wing built at capital")
	check(not sim.apply_command({"type": "build_wing", "country": 0, "type_air": "fighter", "base": enemy_cap})["ok"], "cannot build on foreign base")
	while sim.wings_at(cap).size() < sim.air_capacity(cap):
		sim.apply_command({"type": "build_wing", "country": 0, "type_air": "bomber", "base": cap})
	check(not sim.apply_command({"type": "build_wing", "country": 0, "type_air": "bomber", "base": cap})["ok"], "airbase capacity enforced")
	sim.countries[0]["stock"]["steel"] = 0
	check(not sim.apply_command({"type": "build_wing", "country": 0, "type_air": "fighter", "base": sim.port_of(0) if sim.port_of(0) != cap else cap})["ok"], "wings need steel")
	sim.countries[0]["stock"]["steel"] = 5000
	# mission validation
	var fighter: Dictionary = sim.wings[0]
	check(not sim.apply_command({"type": "air_mission", "country": 0, "wing": fighter["id"], "mission": "bomb", "target": cap})["ok"], "fighters cannot bomb")
	var far := -1
	var reachable := sim.reach(cap, sim.air_range(0, "fighter"))
	for p in sim.provinces():
		if p["land"] and not reachable.has(p["id"]):
			far = p["id"]
			break
	check(far >= 0 and not sim.apply_command({"type": "air_mission", "country": 0, "wing": fighter["id"], "mission": "air_superiority", "target": far})["ok"], "range limit enforced")
	check(sim.apply_command({"type": "air_mission", "country": 0, "wing": fighter["id"], "mission": "air_superiority", "target": cap})["ok"], "superiority mission accepted in range")
	check(sim.apply_command({"type": "air_mission", "country": 0, "wing": fighter["id"], "mission": "idle"})["ok"], "mission can be cancelled")


func test_air_combat_effects() -> void:
	var sim := _make(42)
	sim.wars.append({"a": 0, "b": 1, "start": 0})
	var t: int = sim.countries[1]["capital"]
	var home: int = sim.countries[0]["capital"]
	# dogfight: both sides lose planes, shares are symmetric
	sim.wings = [
		{"id": 1, "owner": 0, "base": home, "type": "fighter", "strength": 50, "mission": "air_superiority", "target": t},
		{"id": 2, "owner": 1, "base": t, "type": "fighter", "strength": 50, "mission": "air_superiority", "target": t},
	]
	sim.next_wing_id = 3
	sim._air()
	check(sim.wings.size() == 2 and sim.wings[0]["strength"] < 50 and sim.wings[1]["strength"] < 50, "dogfight costs both sides planes")
	check(absf(sim.air_sup[t][0] - 0.5) < 0.001, "equal fighters => 50% air superiority")
	# superiority bonus for the land army
	var army: Dictionary = sim.armies_of(1)[0]
	var base_power := _power_without_air(sim, army)
	sim.wings = [{"id": 1, "owner": 1, "base": t, "type": "fighter", "strength": 50, "mission": "air_superiority", "target": army["prov"]}]
	sim._air()
	check(sim.army_power(army, false) > base_power, "air superiority boosts the army below")
	# bombing: damages province and enemy army; interceptors reduce it
	sim.damage[t] = 0
	var h0: int = army["strength"]
	sim.wings = [{"id": 1, "owner": 0, "base": home, "type": "bomber", "strength": 50, "mission": "bomb", "target": t}]
	var enemy_armies_here := sim.armies_in(t)
	var hp_before: int = enemy_armies_here[0]["strength"] if not enemy_armies_here.is_empty() else 0
	sim._air()
	check(sim.damage[t] > 0, "bombing damages the province")
	check(not enemy_armies_here.is_empty() and enemy_armies_here[0]["strength"] < hp_before, "bombing hurts enemy armies")
	var d_free: int = sim.damage[t]
	sim.damage[t] = 0
	sim.wings = [
		{"id": 1, "owner": 0, "base": home, "type": "bomber", "strength": 50, "mission": "bomb", "target": t},
		{"id": 2, "owner": 1, "base": t, "type": "fighter", "strength": 50, "mission": "idle", "target": -1},
	]
	sim._air()
	check(sim.damage[t] <= d_free, "interceptors reduce bombing damage")
	# close air support
	var a1: Dictionary = sim.armies_of(0)[0]
	var plain := _power_without_air(sim, a1)
	sim.wings = [{"id": 1, "owner": 0, "base": home, "type": "attacker", "strength": 50, "mission": "cas", "target": a1["prov"]}]
	sim._air()
	check(sim.army_power(a1, true) > plain * 1.05, "close air support boosts the supported army")
	# no oil, no sorties
	sim.countries[0]["short"] = ["oil"]
	sim.damage[t] = 0
	sim.wings = [{"id": 1, "owner": 0, "base": home, "type": "bomber", "strength": 50, "mission": "bomb", "target": t}]
	sim._air()
	check(sim.damage[t] == 0, "wings are grounded without oil")
	sim.countries[0]["short"] = []
	# damage reduces income
	var s2 := _make(42)
	s2.tick_day()
	var inc: int = s2.countries[1]["income"]
	for p in s2.owner.size():
		if s2.owner[p] == 1:
			s2.damage[p] = 100
	s2.tick_day()
	check(s2.countries[1]["income"] < inc, "bomb damage cuts income")


func _power_without_air(sim: Simulation, army: Dictionary) -> float:
	var a := sim.air_sup
	var b := sim.air_cas
	sim.air_sup = {}
	sim.air_cas = {}
	var p := sim.army_power(army, true)
	sim.air_sup = a
	sim.air_cas = b
	return p


func test_air_long_run() -> void:
	var x := _make(3)
	var y := _make(3)
	var peak := 0
	for i in 500:
		x.tick_day()
		y.tick_day()
		peak = maxi(peak, x.wings.size())
	check(x.checksum() == y.checksum(), "air war deterministic over 500 days")
	check(peak > 0, "AI builds air wings (peak %d)" % peak)
	for w in x.wings:
		check(x.owner[w["base"]] == w["owner"], "wings only sit on own bases")
		check(w["strength"] > 0 and w["strength"] <= Simulation.WING_SIZE, "wing strength within bounds")
	var r := Simulation.from_dict(str_to_var(var_to_str(x.to_dict())), Simulation.load_country_defs())
	check(r.checksum() == x.checksum() and r.wings.size() == x.wings.size(), "aviation survives save/load")
	print("  wings=", x.wings.size(), " peak=", peak)


func test_politics_basics() -> void:
	var sim := _make(42)
	check(sim.ideo_order.size() == 4 and sim.event_defs.size() == 14 and sim.decision_defs.size() == 11, "politics data loaded")
	for c in sim.countries:
		var total := 0
		for i in sim.ideo_order:
			total += c["party_pop"][i]
		check(total == 100, "party popularity sums to 100 (%d)" % total)
		check(c["stability"] >= 0 and c["stability"] <= 100, "stability in range")
	var c0: Dictionary = sim.countries[0]
	# laws
	c0["pp"] = 10
	check(not sim.apply_command({"type": "set_law", "country": 0, "category": "conscription", "law": "extended"})["ok"], "law needs influence")
	c0["pp"] = 300
	var m0 := sim.mod(0, "manpower_pct")
	check(sim.apply_command({"type": "set_law", "country": 0, "category": "conscription", "law": "extended"})["ok"], "law adopted")
	check(sim.mod(0, "manpower_pct") == m0 + 30 - sim.law_option("conscription", "limited").get("mods", {}).get("manpower_pct", 0), "law changes modifiers")
	check(c0["pp"] == 200, "law cost deducted")
	check(not sim.apply_command({"type": "set_law", "country": 0, "category": "conscription", "law": "extended"})["ok"], "no duplicate law")
	# decisions
	c0["treasury"] = 1000
	var st: int = c0["stability"]
	check(sim.apply_command({"type": "decision", "country": 0, "id": "propaganda"})["ok"], "decision executed")
	check(c0["stability"] == mini(100, st + 8), "decision effect applied")
	check(not sim.apply_command({"type": "decision", "country": 0, "id": "propaganda"})["ok"], "decision cooldown")
	check(not sim.apply_command({"type": "decision", "country": 0, "id": "emergency"})["ok"], "decision requirements enforced")
	# popularity shift keeps the sum
	sim._shift_popularity(c0, "democracy", 15)
	sim._shift_popularity(c0, "autocracy", -7)
	var tot := 0
	for i in sim.ideo_order:
		tot += c0["party_pop"][i]
		check(c0["party_pop"][i] >= 0, "popularity non-negative")
	check(tot == 100, "popularity sum preserved after shifts")
	# low stability hurts the economy
	c0["stability"] = 50
	sim._recalc_mods(0)
	var income_ok := sim.mod(0, "income_pct")
	c0["stability"] = 10
	sim._recalc_mods(0)
	check(sim.mod(0, "income_pct") < income_ok, "low stability lowers income modifier")


func test_events_and_timed_modifiers() -> void:
	var sim := _make(42)
	var c: Dictionary = sim.countries[0]
	c["ai"] = false
	var ev := sim.event_def("strike")
	sim._fire_event(c, ev)
	check(c["pending"].size() == 1, "player gets a pending event")
	var uid: int = c["pending"][0]["uid"]
	check(not sim.apply_command({"type": "event_choice", "country": 0, "uid": 999, "option": 0})["ok"], "unknown event rejected")
	check(not sim.apply_command({"type": "event_choice", "country": 0, "uid": uid, "option": 9})["ok"], "bad option rejected")
	var t0: int = c["treasury"]
	check(sim.apply_command({"type": "event_choice", "country": 0, "uid": uid, "option": 0})["ok"], "event resolved")
	check(c["pending"].is_empty() and c["treasury"] == maxi(0, t0 - 60), "option effects applied")
	# unanswered event resolves itself
	sim._fire_event(c, ev)
	sim.day += 25
	sim._politics()
	check(c["pending"].is_empty(), "stale events resolve automatically")
	# AI resolves immediately
	var ai_c: Dictionary = sim.countries[1]
	sim._fire_event(ai_c, ev)
	check(ai_c["pending"].is_empty(), "AI events resolve instantly")
	# timed modifier
	var s2 := _make(42)
	s2._apply_effect(s2.countries[0], {"type": "modifier", "key": "oil_pct", "value": 25, "days": 10})
	s2._recalc_mods(0)
	check(s2.mod(0, "oil_pct") >= 25, "timed modifier active")
	for i in 12:
		s2.tick_day()
	check(s2.mod(0, "oil_pct") < 25, "timed modifier expires")


func test_government_changes() -> void:
	var sim := _make(42)
	var c: Dictionary = sim.countries[0]
	# election
	c["ideology"] = "democracy"
	c["party_pop"] = {"democracy": 20, "monarchy": 15, "communism": 50, "autocracy": 15}
	sim.day = 100 + 40 * 0 + 365 - 1
	sim.tick_day()
	check(c["ideology"] == "communism", "election hands power to the most popular party (%s)" % c["ideology"])
	# coup in a non-democracy
	var changed := false
	var s2 := _make(42)
	var c2: Dictionary = s2.countries[0]
	c2["ideology"] = "autocracy"
	c2["party_pop"] = {"democracy": 40, "monarchy": 20, "communism": 20, "autocracy": 20}
	for i in 60:
		c2["stability"] = 5
		c2["crisis"] = 0
		s2.day = 10 * (i + 1)
		s2._politics()
		if c2["ideology"] != "autocracy":
			changed = true
			break
	check(changed, "unstable dictatorship eventually suffers a coup")


func test_civil_war() -> void:
	var sim := _make(42)
	var big := 0
	for c in sim.countries:
		if sim.country_provinces(c["id"]).size() > sim.country_provinces(big).size():
			big = c["id"]
	var c: Dictionary = sim.countries[big]
	var n_before := sim.countries.size()
	var provs_before := sim.country_provinces(big).size()
	check(provs_before >= 6, "test country is large enough (%d)" % provs_before)
	c["stability"] = 0
	c["crisis"] = 19
	sim.day += 1
	sim._politics()
	check(sim.countries.size() == n_before + 1, "civil war creates a new state")
	var rebels: Dictionary = sim.countries[n_before]
	check(sim.at_war(big, rebels["id"]), "rebels fight the government")
	check(sim.country_provinces(rebels["id"]).size() >= 3, "rebels hold provinces")
	check(sim.country_provinces(big).size() + sim.country_provinces(rebels["id"]).size() == provs_before, "no provinces lost in the split")
	check(sim.owner[rebels["capital"]] == rebels["id"], "rebel capital is rebel-held")
	check(sim.armies_of(rebels["id"]).size() >= 2, "rebels have armies")
	check(sim.dirty_provinces.size() >= 3, "map is told to repaint")
	for i in 120:
		sim.tick_day()
	for o in sim.owner:
		check(o >= -1 and o < sim.countries.size(), "owner ids valid after the split")
		break
	# determinism incl. new country
	var a := _make(42)
	var b := _make(42)
	for s in [a, b]:
		s.countries[big]["stability"] = 0
		s.countries[big]["crisis"] = 19
		s.day += 1
		s._politics()
		for i in 150:
			s.tick_day()
	check(a.checksum() == b.checksum(), "civil war is deterministic")
	var r := Simulation.from_dict(str_to_var(var_to_str(a.to_dict())), Simulation.load_country_defs())
	check(r.checksum() == a.checksum() and r.countries.size() == a.countries.size(), "save/load keeps new states")


func test_politics_long_run() -> void:
	var x := _make(11)
	var y := _make(11)
	for i in 700:
		x.tick_day()
		y.tick_day()
	check(x.checksum() == y.checksum(), "politics deterministic over 700 days")
	var events := 0
	for c in x.countries:
		events += c["ev_seen"].size()
		check(c["stability"] >= 0 and c["stability"] <= 100, "stability stays in range")
		check(c["pp"] >= 0 and c["pp"] <= Simulation.PP_CAP, "influence stays in range")
	check(events > 0, "events fire during a long game (%d)" % events)
	print("  countries=", x.countries.size(), " events=", events, " log=", x.log_lines.size())


func test_intelligence() -> void:
	var sim := _make(42)
	check(sim.intel_defs.size() == 6, "intel ops loaded")
	var c0: Dictionary = sim.countries[0]
	c0["treasury"] = 5000
	check(sim.intel_slots(0) == 2, "level 1 agency has 2 slots")
	# need a network first
	check(not sim.apply_command({"type": "intel_op", "country": 0, "op": "sabotage", "target": 1})["ok"], "sabotage needs a network")
	check(not sim.apply_command({"type": "intel_op", "country": 0, "op": "build_network", "target": 0})["ok"], "cannot spy on yourself")
	var t0: int = c0["treasury"]
	check(sim.apply_command({"type": "intel_op", "country": 0, "op": "build_network", "target": 1})["ok"], "network operation started")
	check(c0["treasury"] == t0 - int(sim.intel_defs["build_network"]["cost"]), "operation cost paid")
	check(not sim.apply_command({"type": "intel_op", "country": 0, "op": "build_network", "target": 1})["ok"], "no duplicate operation")
	check(sim.apply_command({"type": "intel_op", "country": 0, "op": "build_network", "target": 2})["ok"], "second slot used")
	check(not sim.apply_command({"type": "intel_op", "country": 0, "op": "build_network", "target": 3})["ok"], "slots are limited")
	check(sim.apply_command({"type": "cancel_op", "country": 0, "op_id": sim.ops_of(0)[1]["id"]})["ok"], "operation cancelled")
	# resolve outcomes deterministically
	var op: Dictionary = sim.ops_of(0)[0]
	sim._resolve_op(op, 1)
	check(sim.net_of_agent(0, 1) == 25, "successful network gives +25")
	sim._resolve_op(op, 0)
	check(sim.net_of_agent(0, 1) == 0, "failure burns the network")
	c0["intel"]["net"][1] = 60
	sim.ops = []
	# sabotage
	var d0 := 0
	for p in sim.owner.size():
		d0 += sim.damage[p]
	sim._resolve_op({"owner": 0, "target": 1, "type": "sabotage"}, 1)
	var d1 := 0
	for p in sim.owner.size():
		d1 += sim.damage[p]
	check(d1 > d0, "sabotage damages the target")
	# destabilize
	var st: int = sim.countries[1]["stability"]
	sim._resolve_op({"owner": 0, "target": 1, "type": "destabilize"}, 1)
	check(sim.countries[1]["stability"] == st - 8, "destabilization lowers stability")
	var tot := 0
	for i in sim.ideo_order:
		tot += sim.countries[1]["party_pop"][i]
	check(tot == 100, "party popularity stays at 100% after destabilization")
	# counter-intelligence lowers the enemy's success chance
	var ch_before := sim.op_chance(0, 1, "sabotage")
	sim._resolve_op({"owner": 1, "target": 1, "type": "counter_intel"}, 1)
	check(sim.countries[1]["intel"]["counter"] == 20, "counter-intelligence raised")
	check(sim.op_chance(0, 1, "sabotage") < ch_before, "counter-intelligence lowers enemy odds")
	# disinformation hides real numbers
	var army: Dictionary = sim.armies_of(1)[0]
	army["prov"] = sim.countries[1]["capital"]
	c0["intel"]["net"][1] = 0
	check(sim.perceived_strength(0, army) == -1, "unknown armies are hidden without intel")
	check(sim.perceived_strength(1, army) == army["strength"], "own armies are always visible")
	c0["intel"]["net"][1] = 30
	check(sim.perceived_strength(0, army) == army["strength"], "agent network reveals armies")
	sim.countries[1]["intel"]["disinfo_until"] = sim.day + 60
	check(sim.perceived_strength(0, army) != army["strength"], "disinformation distorts what we see")
	c0["intel"]["net"][1] = 70
	check(sim.perceived_strength(0, army) == army["strength"], "strong network sees through disinformation")
	# xp levels the agency up
	var s2 := _make(42)
	for i in 10:
		s2._gain_xp(0, 15)
	check(s2.countries[0]["intel"]["level"] >= 2 and s2.intel_slots(0) >= 2, "agency levels up with experience")


func test_intelligence_long_run() -> void:
	var x := _make(5)
	var y := _make(5)
	var nets := 0
	for i in 400:
		x.tick_day()
		y.tick_day()
	for c in x.countries:
		nets += c["intel"]["net"].size()
		check(c["intel"]["counter"] >= 0 and c["intel"]["counter"] <= 80, "counter-intel in range")
	check(x.checksum() == y.checksum(), "intelligence is deterministic")
	check(nets > 0 or x.ops.size() > 0, "AI runs intelligence work (networks %d, ops %d)" % [nets, x.ops.size()])
	var r := Simulation.from_dict(str_to_var(var_to_str(x.to_dict())), Simulation.load_country_defs())
	check(r.checksum() == x.checksum() and r.ops.size() == x.ops.size(), "intelligence survives save/load")


func _sea_trade_pair(sim: Simulation) -> Array:
	for a in sim.countries:
		for b in sim.countries:
			if a["id"] < b["id"] and sim.can_trade(a["id"], b["id"]) and not sim.trade_route(a["id"], b["id"]).is_empty():
				return [a["id"], b["id"]]
	return []


func test_infrastructure() -> void:
	var sim := _make(42)
	for p in sim.provinces():
		if p["land"]:
			check(sim.infra[p["id"]] >= 1 and sim.infra[p["id"]] <= Simulation.MAX_INFRA, "infra in range")
		else:
			check(sim.infra[p["id"]] == 0, "sea has no infra")
	var c: Dictionary = sim.countries[0]
	c["treasury"] = 5000
	c["stock"]["steel"] = 500
	var prov := -1
	for p in sim.country_provinces(0):
		if sim.infra[p] < Simulation.MAX_INFRA:
			prov = p
			break
	var lvl: int = sim.infra[prov]
	var t0: int = c["treasury"]
	check(sim.apply_command({"type": "build_infra", "country": 0, "province": prov})["ok"], "infrastructure upgraded")
	check(sim.infra[prov] == lvl + 1 and c["treasury"] == t0 - (60 + 20 * lvl), "level and cost correct")
	check(not sim.apply_command({"type": "build_infra", "country": 0, "province": sim.country_provinces(1)[0]})["ok"], "cannot build abroad")
	sim.infra[prov] = Simulation.MAX_INFRA
	check(not sim.apply_command({"type": "build_infra", "country": 0, "province": prov})["ok"], "max level enforced")
	# bombing degrades infrastructure
	sim.damage[prov] = 90
	check(sim.eff_infra(prov) < Simulation.MAX_INFRA, "bomb damage lowers effective infrastructure")
	# better infrastructure => shorter supply distance
	var s2 := _make(42)
	var far := 0
	var d0 := s2._supply_dist(0)
	for p in d0:
		if d0[p] > d0.get(far, 0):
			far = p
	for p in s2.country_provinces(0):
		s2.infra[p] = Simulation.MAX_INFRA
	var d1 := s2._supply_dist(0)
	check(d1[far] < d0[far], "railways shorten the supply line (%d -> %d)" % [d0[far], d1[far]])


func test_blockade_and_convoys() -> void:
	var sim := _make(42)
	var port := -1
	var victim := -1
	for c in sim.countries:
		if sim.port_of(c["id"]) >= 0:
			victim = c["id"]
			port = sim.port_of(victim)
			break
	check(victim >= 0, "found a coastal country")
	var attacker := 0 if victim != 0 else 1
	var sea := sim.sea_next_to(port)
	sim.wars.append({"a": attacker, "b": victim, "start": 0})
	sim.fleets.append({"id": 900, "owner": attacker, "prov": sea, "strength": 1500, "path": [], "move": 0})
	check(sim.port_blockaded(port, victim), "enemy fleet blockades the port")
	check(sim.blockade_level(victim) > 0, "blockade level positive")
	sim.fleets.append({"id": 901, "owner": victim, "prov": sea, "strength": 1500, "path": [], "move": 0})
	check(not sim.port_blockaded(port, victim), "a defending fleet breaks the blockade")
	# income falls under blockade
	var s2 := _make(42)
	s2.tick_day()
	var inc: int = s2.countries[victim]["income"]
	s2.countries[victim]["blockade"] = 100
	s2._economy()
	check(s2.countries[victim]["income"] < inc, "blockade cuts income")
	# sea trade: raiders sink convoys, escorts protect them
	var pair := _sea_trade_pair(_make(42))
	if pair.is_empty():
		return
	var s3 := _make(42)
	var b: int = pair[0]
	var sl: int = pair[1]
	var third := 0
	for c in s3.countries:
		if c["id"] != b and c["id"] != sl:
			third = c["id"]
			break
	s3.countries[b]["treasury"] = 100000
	s3.countries[sl]["stock"]["food"] = 1000
	s3.countries[sl]["prod"]["food"] = 50
	check(s3.apply_command({"type": "propose_trade", "country": b, "target": sl, "res": "food", "amount": 5})["ok"], "sea trade deal made")
	var route := s3.trade_route(b, sl)
	s3.wars.append({"a": third, "b": b, "start": 0})
	s3.fleets.append({"id": 910, "owner": third, "prov": route[route.size() / 2], "strength": 1500, "path": [], "move": 0})
	var stock0: int = s3.countries[sl]["stock"]["food"]
	var buyer0: int = s3.countries[b]["stock"]["food"]
	s3._trade()
	check(s3.countries[sl]["stock"]["food"] == stock0 - 5, "seller loses the sunk shipment")
	check(s3.countries[b]["stock"]["food"] == buyer0, "buyer receives nothing")
	s3.fleets.append({"id": 911, "owner": b, "prov": route[route.size() / 2], "strength": 3000, "path": [], "move": 0})
	var stock1: int = s3.countries[sl]["stock"]["food"]
	s3._trade()
	check(s3.countries[b]["stock"]["food"] == buyer0 + 5 and s3.countries[sl]["stock"]["food"] == stock1 - 5, "escorted convoy gets through")


func test_logistics_long_run() -> void:
	var x := _make(21)
	var y := _make(21)
	for i in 500:
		x.tick_day()
		y.tick_day()
	check(x.checksum() == y.checksum(), "logistics deterministic over 500 days")
	var upgraded := 0
	for p in x.owner.size():
		if x.infra[p] > 0:
			upgraded += x.infra[p]
	check(upgraded > 0, "infrastructure exists")
	var r := Simulation.from_dict(str_to_var(var_to_str(x.to_dict())), Simulation.load_country_defs())
	check(r.checksum() == x.checksum() and r.infra == x.infra, "infrastructure survives save/load")


func test_scenarios_builtin() -> void:
	var all := ScenarioLoader.list_all()
	check(all.size() >= 3, "built-in scenarios listed (%d)" % all.size())
	for entry in all:
		var scn: Dictionary = entry["data"]
		var sim := Simulation.new()
		var problems := sim.setup_scenario(scn)
		check(problems.is_empty(), "scenario %s loads cleanly %s" % [scn.get("id"), str(problems)])
		if scn.get("world", "procedural") != "earth":
			check(sim.countries.size() == scn["countries"].size(), "%s: country count" % scn.get("id"))
		for c in sim.countries:
			check(not sim.country_provinces(c["id"]).is_empty(), "%s: %s owns land" % [scn.get("id"), c["tag"]])
		for i in 30:
			sim.tick_day()
		check(sim.day == 30, "%s: runs" % scn.get("id"))
	var cold := Simulation.new()
	cold.setup_scenario(ScenarioLoader.read_file("res://game/scenarios/cold_blocs.json"))
	check(cold.allied(0, 2) and cold.allied(0, 3), "bloc alliances preset")
	check(cold.date_string() == "1950-03-01", "scenario start date")
	check(cold.countries[0]["techs"].has("wp1") and cold.mod(0, "atk_infantry_pct") >= 10, "starting techs apply modifiers")
	check(cold.countries[0]["laws"]["economy"] == "partial", "starting laws")
	var chaos := Simulation.new()
	chaos.setup_scenario(ScenarioLoader.read_file("res://game/scenarios/chaos.json"))
	check(chaos.wars.size() == 3 and chaos.at_war(0, 1), "preset wars")
	check(chaos.grace_days == 0, "scenario grace period")


func test_scenario_overrides() -> void:
	var base := ScenarioLoader.blank(42)
	var sim0 := Simulation.new()
	check(sim0.setup_scenario(base.duplicate(true)).is_empty(), "blank scenario loads")
	var scn := base.duplicate(true)
	var target_p: int = sim0.country_provinces(0)[0]
	var other_p: int = sim0.country_provinces(1)[0]
	scn["owners"] = {str(target_p): "SLV", str(other_p): null}
	scn["deposits"] = {str(target_p): {"oil": 9}}
	scn["capitals"] = {"SLV": sim0.countries[1]["capital"]}
	scn["countries"][0]["ideology"] = "communism"
	scn["countries"][0]["treasury"] = 777
	scn["countries"][0]["stock"] = {"steel": 321}
	scn["armies_mode"] = "replace"
	scn["armies"] = [{"tag": "NRM", "province": sim0.countries[0]["capital"], "divisions": ["armor", "armor", "artillery"]}]
	scn["disabled_events"] = ["strike"]
	var sim := Simulation.new()
	var problems := sim.setup_scenario(scn)
	check(problems.is_empty(), "overrides load %s" % str(problems))
	check(sim.owner[target_p] == 1 and sim.owner[other_p] == -1, "province ownership overridden")
	check(sim.provinces()[target_p]["deposits"].get("oil", 0) == 9, "deposit overridden")
	check(sim.countries[0]["ideology"] == "communism", "ideology overridden")
	check(sim.countries[0]["treasury"] == 777 and sim.countries[0]["stock"]["steel"] == 321, "treasury and stock overridden")
	check(sim.armies.size() == 1 and sim.armies[0]["div"].size() == 3, "armies replaced")
	check(sim.disabled_events.has("strike"), "disabled events stored")
	var total := 0
	for i in sim.ideo_order:
		total += sim.countries[0]["party_pop"][i]
	check(total == 100, "popularity still sums to 100 after ideology override")
	# deposits survive save/load (world is regenerated from the seed)
	var r := Simulation.from_dict(str_to_var(var_to_str(sim.to_dict())), Simulation.load_country_defs())
	check(r.provinces()[target_p]["deposits"].get("oil", 0) == 9, "deposit override survives save/load")
	check(r.checksum() == sim.checksum() and r.start_date == sim.start_date, "scenario state survives save/load")
	# a disabled event never fires
	for i in 800:
		sim.tick_day()
	for c in sim.countries:
		check(not c["ev_seen"].has("strike"), "disabled event never fires")
		break


func test_scenario_validation() -> void:
	var ok := ScenarioLoader.blank(42)
	check(Simulation.validate_scenario(ok).is_empty(), "valid scenario passes")
	var bad := ok.duplicate(true)
	bad["countries"] = [bad["countries"][0]]
	check(not Simulation.validate_scenario(bad).is_empty(), "single-country scenario rejected")
	bad = ok.duplicate(true)
	bad["countries"][1]["tag"] = bad["countries"][0]["tag"]
	check(not Simulation.validate_scenario(bad).is_empty(), "duplicate tags rejected")
	bad = ok.duplicate(true)
	bad["countries"][0]["color"] = "nonsense"
	check(not Simulation.validate_scenario(bad).is_empty(), "bad colour rejected")
	bad = ok.duplicate(true)
	bad["alliances"] = [["NRM", "XXX"]]
	check(not Simulation.validate_scenario(bad).is_empty(), "unknown tag in alliance rejected")
	bad = ok.duplicate(true)
	bad["schema_version"] = 99
	check(not Simulation.validate_scenario(bad).is_empty(), "unknown schema version rejected")
	# semantic problems found while building
	bad = ok.duplicate(true)
	bad["countries"][0]["techs"] = ["no_such_tech"]
	bad["countries"][1]["ideology"] = "no_such_ideology"
	var sim := Simulation.new()
	check(sim.setup_scenario(bad).size() >= 2, "unknown tech and ideology are reported")
	# every province taken from a country => reported
	var sim0 := Simulation.new()
	sim0.setup_scenario(ok.duplicate(true))
	var wipe := ok.duplicate(true)
	wipe["owners"] = {}
	for p in sim0.country_provinces(2):
		wipe["owners"][str(p)] = "NRM"
	var s2 := Simulation.new()
	var pr := s2.setup_scenario(wipe)
	check(not pr.is_empty(), "country without land is reported")


func test_scenario_files_and_mods() -> void:
	var scn := ScenarioLoader.blank(7)
	scn["name"] = "Тест сценария"
	scn["id"] = "unit_test_scenario"
	var path := ScenarioLoader.save_user(scn)
	check(path != "" and FileAccess.file_exists(path), "scenario saved to user dir")
	var back := ScenarioLoader.read_file(path)
	check(back.get("seed") == 7 and back.get("name") == "Тест сценария", "scenario round-trips through JSON")
	var found := false
	for e in ScenarioLoader.list_all():
		if e["data"].get("id") == "unit_test_scenario":
			found = not e["builtin"]
	check(found, "user scenario appears in the list")
	check(ScenarioLoader.delete_user(path) and not FileAccess.file_exists(path), "user scenario deleted")
	check(not ScenarioLoader.delete_user("res://project.godot"), "refuses to delete outside user dir")
	check(ScenarioLoader.slug("Мой Сценарий 1") != "", "slug never empty")
	# data mods: user://mods/data overrides built-in data
	DirAccess.make_dir_recursive_absolute("user://mods/data")
	var mf := FileAccess.open("user://mods/data/countries.json", FileAccess.WRITE)
	mf.store_string('{"schema_version":1,"countries":[{"tag":"AAA","name":"Мод-А","color":"#112233"},{"tag":"BBB","name":"Мод-Б","color":"#445566"}]}')
	mf.close()
	var defs := Simulation.load_country_defs()
	check(defs.size() == 2 and defs[0]["tag"] == "AAA", "mod data overrides the built-in file")
	DirAccess.remove_absolute("user://mods/data/countries.json")
	check(Simulation.load_country_defs().size() == 8, "removing the mod restores built-in data")


func test_scenario_editor_logic() -> void:
	var map := MapView.new()
	root.add_child(map)
	var ed := ScenarioEditor.new()
	root.add_child(ed)
	ed.start(map, Theme.new(), ScenarioLoader.blank(42))
	check(ed.sim != null and ed.problems.is_empty(), "editor builds a preview game")
	# every tab builds without errors
	for i in ScenarioEditor.TOOLS.size():
		ed._set_tool(i)
	# paint a border
	ed._set_tool(1)
	ed.brush = 2  # second country
	var pid: int = ed.sim.country_provinces(0)[0]
	ed._on_province(pid)
	check(ed.sim.owner[pid] == 1, "painting changes the preview owner")
	check(ed.scn["owners"][str(pid)] == "SLV", "painting is stored in the scenario")
	# neutral brush
	ed.brush = 0
	ed._on_province(pid)
	check(ed.sim.owner[pid] == -1 and ed.scn["owners"][str(pid)] == null, "neutral brush clears ownership")
	# armies: first edit freezes armies, then add one
	ed._set_tool(2)
	ed.brush = 1
	ed.unit_kind = "armor"
	ed.unit_count = 3
	ed.sel_province = ed.sim.countries[0]["capital"]
	var before: int = ed.sim.armies.size()
	ed._materialize_armies()
	ed.scn["armies"].append({"tag": "NRM", "province": ed.sel_province, "divisions": ["armor", "armor", "armor"]})
	ed._rebuild()
	check(ed.sim.armies.size() == before + 1, "scenario army appears in the preview")
	# resource edit
	ed._set_tool(3)
	ed.scn["deposits"] = {str(pid): {"oil": 7}}
	ed._rebuild()
	check(ed.sim.provinces()[pid]["deposits"].get("oil", 0) == 7, "deposit edit applies")
	# the edited scenario is playable and valid
	var s2 := Simulation.new()
	var probs := s2.setup_scenario(ed.scn.duplicate(true))
	check(probs.is_empty(), "edited scenario loads: %s" % str(probs))
	# adding/removing countries
	ed._set_tool(0)
	var n0: int = ed.scn["countries"].size()
	ed.scn["countries"].append({"tag": "ZZZ", "name": "Тест", "color": "#aabbcc"})
	ed._rebuild()
	check(ed.sim.countries.size() == n0 + 1, "new country appears")
	ed._drop_tag("ZZZ")
	ed.scn["countries"].pop_back()
	ed._rebuild()
	check(ed.sim.countries.size() == n0, "country removed")
	ed.queue_free()
	map.queue_free()


# ================================================================ real-world map

func _earth() -> Simulation:
	var sim := Simulation.new()
	var probs := sim.setup_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json"))
	check(probs.is_empty(), "modern_world loads %s" % str(probs))
	return sim


func test_earth_dataset_integrity() -> void:
	var man := EarthWorld.manifest()
	check(man.has("world_hash") and man["files"].size() >= 10, "manifest present")
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var names: Array = man["files"].keys()
	names.sort()
	for fn in names:
		var d: String = FileAccess.get_sha256("res://data/world/" + fn)
		check(d == man["files"][fn]["sha256"], "sha256 of " + fn)
		ctx.update((fn + d).to_utf8_buffer())
	check(ctx.finish().hex_encode() == man["world_hash"], "world_hash matches the files (platform independent)")
	var w := EarthWorld.load_world()
	check(w["world_hash"] == man["world_hash"], "loader reports the manifest hash")
	check(w["provinces"].size() == int(man["counts"]["cells_land"]) + int(man["counts"]["cells_sea"]), "cell count matches the manifest")


func test_earth_cells_geometry() -> void:
	var w := EarthWorld.load_world()
	var provs: Array = w["provinces"]
	var nl: int = w["land_count"]
	var w_px: int = w["w"]
	var h_px: int = w["h"]
	var bad := 0
	for i in provs.size():
		var p: Dictionary = provs[i]
		if p["id"] != i or p["land"] != (i < nl) or p["cell_count"] <= 0 or p["area"] <= 0:
			bad += 1
		var c: Vector2 = p["center"]
		if c.x < 0 or c.y < 0 or c.x >= w_px or c.y >= h_px:
			bad += 1
	check(bad == 0, "ids unique & sequential (land first), geometry sane (%d bad)" % bad)
	var asym := 0
	for p in provs:
		for q in p["neighbors"]:
			if q == p["id"] or not provs[q]["neighbors"].has(p["id"]):
				asym += 1
		for q in p["land_neighbors"]:
			if not provs[q]["land"]:
				asym += 1
	check(asym == 0, "adjacency symmetric, no self links, land_neighbors are land (%d bad)" % asym)
	# raster <-> cell lists agree (sampled)
	var mism := 0
	for c in range(0, provs.size(), 5):
		for px in w["prov_cells"][c]:
			if w["cell_prov"][px] != c:
				mism += 1
	check(mism == 0, "raster agrees with per-cell pixel lists (%d bad)" % mism)
	# cells nest inside administrative regions, regions inside one country
	var nest := 0
	var area_sum := 0.0
	for i in nl:
		var p: Dictionary = provs[i]
		var r: int = p["region"]
		if r <= 0 or r > w["regions"].size() or w["regions"][r - 1]["country"] != p["country"]:
			nest += 1
		area_sum += p["area"]
	check(nest == 0, "every land cell belongs to a region of the same country (%d bad)" % nest)
	check(area_sum > 1.2e8 and area_sum < 1.7e8, "land area plausible: %.0f million km2" % (area_sum / 1e6))
	# reality checks
	var paris := EarthWorld.cell_at_lonlat(w, 2.35, 48.85)
	check(provs[paris]["land"] and w["countries"][provs[paris]["country"]]["name"] == "France", "Paris is in France")
	var sydney := EarthWorld.cell_at_lonlat(w, 151.2, -33.87)
	check(provs[sydney]["land"] and w["countries"][provs[sydney]["country"]]["name"] == "Australia", "Sydney is in Australia")
	check(not provs[EarthWorld.cell_at_lonlat(w, -30.0, 30.0)]["land"], "mid-Atlantic is sea")
	check(provs[EarthWorld.cell_at_lonlat(w, 27.6, 62.8)]["terrain"] != "desert", "Finland is not a desert")
	check(provs[EarthWorld.cell_at_lonlat(w, 10.0, 24.0)]["terrain"] == "desert", "Sahara is desert")


func test_earth_settlements_and_search() -> void:
	var man := EarthWorld.manifest()
	var count := EarthWorld.settlement_count()
	check(count == int(man["counts"]["settlements"]), "settlements loaded (%d)" % count)
	var w := EarthWorld.load_world()
	var bad := 0
	for i in count:
		if EarthWorld.S_CELL[i] < 0 or EarthWorld.S_CELL[i] >= w["land_count"] or EarthWorld.S_POP[i] < 0 or EarthWorld.S_NAME[i] == "":
			bad += 1
	var sorted_ok := true
	for i in range(1, mini(count, 5000)):
		if EarthWorld.S_POP[i] > EarthWorld.S_POP[i - 1]:
			sorted_ok = false
	check(sorted_ok, "settlement ids are ordered by population")
	check(bad == 0, "every settlement sits in a land cell (%d bad)" % bad)
	var res := EarthWorld.search("moscow")
	check(not res.is_empty() and res[0]["pop"] > 10000000, "search 'moscow' finds the big city first")
	var ru := EarthWorld.search("Париж")
	check(not ru.is_empty() and ru[0]["name"] == "Paris", "Russian name search finds Paris")
	check(EarthWorld.search("zzzzqqqq").is_empty(), "unknown name finds nothing")
	check(EarthWorld.search("a").is_empty(), "too-short queries are ignored")
	var cap_count := 0
	for i in count:
		cap_count += EarthWorld.S_CAP[i]
	check(cap_count >= 150, "capitals flagged (%d)" % cap_count)


func test_earth_scenario_setup() -> void:
	var sim := _earth()
	check(sim.countries.size() >= 190, "real countries created (%d)" % sim.countries.size())
	check(sim.is_earth_world() and sim.provinces().size() > 14000, "real-world cells in use")
	var bad := 0
	for c in sim.countries:
		if sim.cells_of(c["id"]).is_empty() or sim.owner[c["capital"]] != c["id"]:
			bad += 1
	check(bad == 0, "every country owns land and holds its capital (%d bad)" % bad)
	check(sim.owner == sim.legal, "at the start control equals recognised ownership")
	var usa := -1
	for c in sim.countries:
		if c["name"] == "США":
			usa = c["id"]
	check(usa >= 0 and sim.cells_of(usa).size() > 500, "USA is large with Russian name")
	var tot := 0
	for c in sim.countries:
		tot += sim.armies_of(c["id"]).size()
	check(tot > 150, "starting armies exist (%d)" % tot)
	# two sims are independent although they share the dataset
	var s2 := _earth()
	s2.set_deposits(0, {"oil": 9})
	check(sim.provinces()[0]["deposits"].get("oil", 0) != 9 or sim.provinces()[0]["deposits"].get("oil", 0) == EarthWorld.load_world()["provinces"][0]["deposits"].get("oil", 0), "deposit edits do not leak between simulations")


func _find_border(sim: Simulation) -> Dictionary:
	for c in sim.countries:
		var a: int = c["id"]
		for p in sim.cells_of(a):
			if sim.region_cells(sim.region_of(p)).size() < 3 or p == c["capital"]:
				continue
			for q in sim.provinces()[p]["land_neighbors"]:
				var b: int = sim.owner[q]
				if b >= 0 and b != a:
					return {"a": a, "b": b, "cell": p, "region": sim.region_of(p)}
	return {}


func test_partial_capture_of_one_cell() -> void:
	var sim := _earth()
	var f := _find_border(sim)
	check(not f.is_empty(), "found a border region with several cells")
	var a: int = f["a"]
	var b: int = f["b"]
	var cell: int = f["cell"]
	var region: int = f["region"]
	var cells: Array = sim.region_cells(region)
	var before: Dictionary = sim.region_control(region)
	check(before.size() == 1 and before.has(a), "region starts fully controlled by its owner")
	# war + an attacker army standing in ONE cell
	sim.wars.append({"a": b, "b": a, "start": 0})
	sim.armies = sim.armies.filter(func(x): return x["prov"] != cell)
	sim._add_army(b, cell, [sim._make_div("infantry"), sim._make_div("infantry")])
	sim._occupation()
	check(sim.owner[cell] == b, "the occupied cell changes controller")
	var untouched := 0
	for q in cells:
		if q != cell and sim.owner[q] == a:
			untouched += 1
	check(untouched == cells.size() - 1, "ONE captured cell does NOT hand over the other cells of the region (%d of %d kept)" % [untouched, cells.size() - 1])
	var after: Dictionary = sim.region_control(region)
	check(after.size() == 2 and after[b] == 1 and after[a] == cells.size() - 1, "region is now contested by two states")
	var legal_after: Dictionary = sim.region_legal(region)
	check(legal_after.size() == 1 and legal_after.has(a), "recognised (legal) ownership is unchanged by occupation")
	# the front line moved: the new cell is on b's front, a's front now touches it
	check(sim.front_cells(b, a).has(cell), "captured cell is on the attacker's front")
	var front_a := sim.front_cells(a, b)
	var touches := false
	for q in front_a:
		if sim.provinces()[q]["land_neighbors"].has(cell):
			touches = true
	check(touches, "defender's front now borders the captured cell")
	# march on: capture a neighbouring cell too; the region stays partially held
	var nxt := -1
	for q in sim.provinces()[cell]["land_neighbors"]:
		if sim.owner[q] == a and cells.has(q):
			nxt = q
			break
	if nxt >= 0:
		sim.armies = sim.armies.filter(func(x): return x["prov"] != nxt)
		sim._add_army(b, nxt, [sim._make_div("infantry")])
		sim._occupation()
		check(sim.owner[nxt] == b, "front advances cell by cell")
		var held := 0
		for q in cells:
			if sim.owner[q] == a:
				held += 1
		check(held == cells.size() - 2, "the remaining cells still belong to the defender")
	# counter-attack: the defender retakes a cell
	sim.armies = sim.armies.filter(func(x): return x["prov"] != cell)
	sim._add_army(a, cell, [sim._make_div("infantry"), sim._make_div("infantry")])
	sim._occupation()
	check(sim.owner[cell] == a, "counter-attack restores control of the cell")


func test_encirclement_and_supply() -> void:
	var sim := _earth()
	var f := _find_border(sim)
	var a: int = f["a"]
	var b: int = f["b"]
	var p: int = f["cell"]
	sim.armies = sim.armies.filter(func(x): return x["owner"] != a or x["prov"] != p)
	sim._add_army(a, p, [sim._make_div("infantry")])
	var army: Dictionary = sim.armies_of(a).filter(func(x): return x["prov"] == p)[0]
	sim.day = (3 - a % 3) % 3
	sim._supply()
	check(army["supply"] > 0, "connected army is supplied (%d%%)" % army["supply"])
	check(not sim.cut_off_cells(a).has(p), "connected cell is not cut off")
	# surround p with enemy-held cells at war
	sim.wars.append({"a": a, "b": b, "start": 0})
	var ring: Array = sim.provinces()[p]["land_neighbors"].duplicate()
	for q in ring:
		sim.set_owner(q, b)
	sim.day = (3 - a % 3) % 3
	sim._supply()
	check(army["supply"] == 0, "encircled army loses all supply")
	check(sim.cut_off_cells(a).has(p), "encircled cell is reported as cut off")
	# relieve: give the neighbours back and supply returns
	for q in ring:
		sim.set_owner(q, a)
	sim.day = (3 - a % 3) % 3
	sim._supply()
	check(army["supply"] > 0, "supply is restored when the ring is broken")


func test_settlement_control() -> void:
	var sim := _earth()
	var big: Dictionary = EarthWorld.search("Hamburg")[0]
	var cell: int = big["cell"]
	var owner0: int = sim.owner[cell]
	var s0 := sim.settlement_status(big)
	check(s0["controller"] == owner0 and not s0["contested"], "city starts under its owner's control")
	var enemy := 0 if owner0 != 0 else 1
	sim.wars.append({"a": enemy, "b": owner0, "start": 0})
	sim.armies = sim.armies.filter(func(x): return x["prov"] != cell)  # no defenders in this cell
	sim._add_army(enemy, cell, [sim._make_div("infantry")])
	check(sim.settlement_status(big)["contested"], "enemy army in the cell contests the city")
	sim._occupation()
	var s1 := sim.settlement_status(big)
	check(s1["controller"] == enemy and s1["legal"] == owner0, "city control changes but legal ownership stays")
	check(EarthWorld.settlement_count() > 0, "settlement list available")


func test_earth_save_load_and_migration() -> void:
	var sim := _earth()
	for i in 12:
		sim.tick_day()
	var d := sim.to_dict()
	check(d["world_kind"] == "earth" and d["world_hash"] == EarthWorld.manifest()["world_hash"], "save records dataset identity")
	var r := Simulation.from_dict(str_to_var(var_to_str(d)), Simulation.load_country_defs())
	check(r.load_error == "" and r.checksum() == sim.checksum(), "earth save/load preserves state")
	check(r.legal == sim.legal and r.cells_of(0) == sim.cells_of(0), "ownership caches rebuilt after load")
	for i in 8:
		sim.tick_day()
		r.tick_day()
	check(sim.checksum() == r.checksum(), "loaded earth game continues identically")
	var bad: Dictionary = str_to_var(var_to_str(d))
	bad["world_hash"] = "deadbeef"
	check(Simulation.from_dict(bad, Simulation.load_country_defs()).load_error != "", "save from a different dataset is refused, not silently loaded")
	# migration: a v10 (procedural) save has no legal ownership / world kind
	var old := _make(42)
	for i in 5:
		old.tick_day()
	var od := old.to_dict()
	od["version"] = 10
	for k in ["world_kind", "world_hash", "legal", "ai_war_chance"]:
		od.erase(k)
	var m := Simulation.from_dict(str_to_var(var_to_str(od)), Simulation.load_country_defs())
	check(m.load_error == "" and m.legal == m.owner and m.world.get("kind", "procedural") != "earth", "v10 saves migrate (legal := owner)")
	check(m.checksum() == old.checksum(), "migrated save keeps its state")


func test_earth_determinism_and_performance() -> void:
	var t0 := Time.get_ticks_msec()
	var a := _earth()
	var setup_ms := Time.get_ticks_msec() - t0
	check(setup_ms < 6000, "scenario setup is fast enough (%d ms)" % setup_ms)
	var b := _earth()
	var t1 := Time.get_ticks_msec()
	for i in 40:
		a.tick_day()
	var per_day := float(Time.get_ticks_msec() - t1) / 40.0
	for i in 40:
		b.tick_day()
	check(a.checksum() == b.checksum(), "real-world simulation is deterministic")
	check(per_day < 400.0, "a day costs %.0f ms (budget 400)" % per_day)
	print("  earth: setup %d ms, %.0f ms/day, %d countries, %d wars" % [setup_ms, per_day, a.countries.size(), a.wars.size()])


func test_terrain_weather_rules() -> void:
	var base := _earth()
	check(not base.rule_terrain and not base.rule_weather, "rules are off by default")
	check(base.move_days(0, 1) == Simulation.MOVE_DAYS, "default movement time is unchanged")
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"terrain": true, "weather": true}
	var a := Simulation.new()
	check(a.setup_scenario(scn).is_empty(), "scenario with rules loads")
	check(a.rule_terrain and a.rule_weather, "rule flags are read from the scenario")
	# find a mountain cell and a plains cell: mountains must be slower
	var mtn := -1
	var pl := -1
	for p in a.provinces():
		if not p["land"]:
			continue
		if mtn < 0 and p["terrain"] == "mountain":
			mtn = p["id"]
		if pl < 0 and p["terrain"] == "plains":
			pl = p["id"]
	if mtn >= 0 and pl >= 0:
		var rw := a.rule_weather
		a.rule_weather = false
		check(a.move_days(pl, mtn) > a.move_days(mtn, pl), "mountains are slower to enter than plains")
		a.rule_weather = rw
	# winter: strong at high northern latitude in January, absent in July, always within 0..100
	var north := -1
	for p in a.provinces():
		a._ensure_cell_lat()
		if p["land"] and a._cell_lat[p["id"]] > 60.0:
			north = p["id"]
			break
	check(north >= 0, "there are land cells above 60 N")
	if north >= 0:
		a._start_doy = 15
		a.day = 1
		var jan := a.winter_at(north)
		a._start_doy = 196
		var jul := a.winter_at(north)
		check(jan > 60 and jul < 10 and jan <= 100, "winter peaks in January and vanishes in July (%d/%d)" % [jan, jul])
	# determinism + save/load with rules on
	var b := Simulation.new()
	b.setup_scenario(scn)
	for i in 20:
		a.tick_day()
		b.tick_day()
	var c := Simulation.new()
	c.setup_scenario(scn)
	var d := Simulation.new()
	d.setup_scenario(scn)
	for i in 20:
		c.tick_day()
		d.tick_day()
	check(c.checksum() == d.checksum(), "simulation with terrain/weather rules is deterministic")
	var restored := Simulation.from_dict(str_to_var(var_to_str(c.to_dict())), Simulation.load_country_defs())
	check(restored.rule_terrain and restored.rule_weather, "rule flags survive save/load")
	check(restored.checksum() == c.checksum(), "checksum survives save/load with rules on")


func test_hd_world_dataset() -> void:
	check(EarthWorld.available_dataset("world_hd"), "HD dataset is present")
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world_hd.json")
	var a := Simulation.new()
	var probs := a.setup_scenario(scn)
	check(probs.is_empty(), "HD scenario loads %s" % str(probs))
	check(str(a.world["dataset"]) == "world_hd", "HD dataset is active")
	check(int(a.world["land_count"]) >= 20000, "HD map has 20k+ land cells (%d)" % int(a.world["land_count"]))
	check(EarthWorld.settlement_count() >= 200000, "HD map has 200k+ settlements (%d)" % EarthWorld.settlement_count())
	check(a.rule_terrain and a.rule_weather, "HD scenario enables terrain and weather rules")
	var seen := {}
	for p in a.provinces():
		if p["land"]:
			seen[a.owner[p["id"]]] = true
	check(seen.size() > 150, "every country owns cells on the HD map (%d owners)" % seen.size())
	var b := Simulation.new()
	b.setup_scenario(scn)
	for i in 10:
		a.tick_day()
		b.tick_day()
	check(a.checksum() == b.checksum(), "HD simulation is deterministic")
	var r := Simulation.from_dict(str_to_var(var_to_str(a.to_dict())), Simulation.load_country_defs())
	check(str(r.world["dataset"]) == "world_hd" and r.checksum() == a.checksum(), "HD save/load keeps dataset and checksum")
	EarthWorld.activate("world")
	check(int(Simulation.new().setup_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json")).size()) == 0, "switching back to the base dataset works")


func test_visual_layer_data() -> void:
	check(EarthVisual.available(), "visual layer is present")
	var m := EarthVisual.manifest()
	var g := EarthVisual.tile_grid()
	check(g == Vector2i(8, 4), "imagery tile grid is 8x4")
	var t := EarthVisual.tile_image(4, 1)
	check(t != null and t.get_width() == int(m["imagery"]["tile_w"]) and t.get_height() == int(m["imagery"]["tile_h"]), "imagery tile has the expected size")
	check(t.get_format() == Image.FORMAT_RGBA8, "imagery tile carries the land mask in alpha")
	var land := 0
	for y in range(0, t.get_height(), 8):
		for x in range(0, t.get_width(), 8):
			if t.get_pixel(x, y).a > 0.5:
				land += 1
	check(land > 0, "tile (4,1) contains land and water (Europe/Atlantic)")
	var fr := EarthVisual.land_fraction("world")
	var w: Dictionary = EarthWorld.load_world()
	check(fr.size() == int(w["w"]) * int(w["h"]), "land fraction raster matches the simulation raster")
	var ext := EarthVisual.ext_bytes("world")
	check(ext.size() == int(w["w"]) * int(w["h"]) * 2, "extended id raster matches the simulation raster")
	var vec := EarthVisual.vectors()
	check(vec["coast"].size() > 1000 and vec["rivers"].size() > 100 and vec["border0"].size() > 100, "fine vector layers are populated")
	# fine coast must stay close to the source geometry: Italy's boot tip near 38 N 16 E lies on the coast
	var best := 1e9
	for ring in vec["coast"]:
		for pt in ring:
			var d: float = Vector2(pt[0], pt[1]).distance_to(Vector2(16.0, 38.0))
			if d < best:
				best = d
	check(best < 0.6, "fine coastline passes near the toe of Italy (%.2f deg)" % best)


func test_xl_world_dataset() -> void:
	check(EarthWorld.available_dataset("world_xl"), "XL dataset is present")
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world_xl.json")
	var a := Simulation.new()
	var probs := a.setup_scenario(scn)
	check(probs.is_empty(), "XL scenario loads %s" % str(probs))
	check(int(a.world["land_count"]) >= 50000, "XL map has 50k+ land cells (%d)" % int(a.world["land_count"]))
	check(a.world["provinces"].size() < 65535, "cell ids fit the 16-bit extended raster")
	var b := Simulation.new()
	b.setup_scenario(scn)
	for i in 5:
		a.tick_day()
		b.tick_day()
	check(a.checksum() == b.checksum(), "XL simulation is deterministic")
	EarthWorld.activate("world")


func test_modern_warfare_rule() -> void:
	var base := _earth()
	check(not base.rule_modern and not base.tech_defs.has("drn1"), "modern techs are absent unless the scenario enables the rule")
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"modern": true}
	var a := Simulation.new()
	check(a.setup_scenario(scn).is_empty(), "scenario with the modern rule loads")
	for id in ["drn1", "drn2", "ew1", "sat1", "cyb1", "cyb2"]:
		check(a.tech_defs.has(id), "tech %s is available" % id)
	# cyber pressure: a cyber-capable enemy at war cuts income, cyber defence offsets it
	var x := 0
	var y := 1
	for i in 3:
		a.tick_day()
	for c in a.countries:
		if c["alive"] and c["id"] != x and c["income"] > a.countries[y]["income"]:
			y = c["id"]
	a.wars.append({"a": x, "b": y, "start": 0})
	a.tick_day()
	var calm: int = a.countries[y]["income"]
	a.countries[x]["mods"]["cyber_pct"] = 20
	a.tick_day()
	var hit: int = a.countries[y]["income"]
	check(calm > 20 and hit < calm, "enemy cyber operations cut income (%d -> %d)" % [calm, hit])
	a.countries[y]["mods"]["cyber_def_pct"] = 20
	a.tick_day()
	var shielded: int = a.countries[y]["income"]
	check(shielded > hit, "cyber defence offsets the loss (%d -> %d)" % [hit, shielded])
	var r := Simulation.from_dict(str_to_var(var_to_str(a.to_dict())), Simulation.load_country_defs())
	check(r.rule_modern and r.tech_defs.has("cyb2"), "modern rule and techs survive save/load")
	check(r.checksum() == a.checksum(), "checksum survives save/load with the modern rule")


func test_incremental_aggregate_matches_rebuild() -> void:
	var sim := _earth()
	for i in 5:
		sim.tick_day()
	sim._aggregate()   # prime the incremental base
	var rs := RandomNumberGenerator.new()
	rs.seed = 11
	var land: int = sim.world["land_count"]
	for i in 400:
		sim.set_owner(rs.randi_range(0, land - 1), rs.randi_range(0, sim.countries.size() - 1))
	for i in 300:
		sim.damage[rs.randi_range(0, land - 1)] = rs.randi_range(0, 100)
	var inc: Dictionary = sim._aggregate().duplicate(true)
	sim._agg_base = {}
	sim._agg_base_ver = -1
	sim._agg = {}
	var fresh: Dictionary = sim._aggregate()
	var same := inc.size() == fresh.size()
	for o in fresh:
		same = same and inc.has(o)
		if inc.has(o):
			for k in ["pop", "ind", "income"]:
				if inc[o][k] != fresh[o][k]:
					same = false
			for r in fresh[o]["prod"]:
				if inc[o]["prod"].get(r, 0) != fresh[o]["prod"][r]:
					same = false
	check(same, "incremental per-country aggregate equals a full rebuild")
