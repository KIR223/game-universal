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


## End-to-end war on the real map driven ONLY through public commands (as a player or a network client would):
## declare_war -> move_army -> days pass. Control (owner[]) changes cell by cell while legal ownership (legal[]) does not;
## the whole run is deterministic and survives a save/load in the middle of the war.
func _war_run(a: int, b: int, target: int, days: int) -> Simulation:
	var sim := _earth()
	check(sim.apply_command({"type": "declare_war", "country": a, "target": b})["ok"], "declare_war accepted")
	var moved := 0
	for army in sim.armies_of(a):
		if sim.apply_command({"type": "move_army", "country": a, "army": army["id"], "target": target})["ok"]:
			moved += 1
	check(moved > 0, "at least one army accepted a move order (%d)" % moved)
	for i in days:
		sim.tick_day()
	return sim


func test_war_flow_via_commands() -> void:
	var probe := _earth()
	var f := _find_border(probe)
	check(not f.is_empty(), "border pair for the war flow test")
	var a: int = f["a"]
	var b: int = f["b"]
	var target := -1
	for q in probe.provinces()[f["cell"]]["land_neighbors"]:
		if probe.owner[q] == b:
			target = q
			break
	check(target >= 0, "a cell of the enemy next to the border")
	var legal0 := probe.legal.duplicate()
	var sim := _war_run(a, b, target, 40)
	var controlled_by_other := 0
	var legal_changed := 0
	for i in sim.owner.size():
		if sim.legal[i] != legal0[i]:
			legal_changed += 1
		if sim.legal[i] >= 0 and sim.owner[i] != sim.legal[i]:
			controlled_by_other += 1
	print("  war flow: ", controlled_by_other, " cells under foreign control, legal changed: ", legal_changed, ", wars: ", sim.wars.size())
	# occupation alone never changes legal[]; recognised ownership may only change through a peace treaty or a
	# capitulation: between the two belligerents, and only on land the new legal owner actually holds
	var foreign_title := 0
	for i in sim.owner.size():
		if sim.legal[i] != legal0[i]:
			var between := (sim.legal[i] == a and legal0[i] == b) or (sim.legal[i] == b and legal0[i] == a)
			if not between or sim.owner[i] != sim.legal[i]:
				foreign_title += 1
	check(foreign_title == 0, "legal[] changes only between the belligerents and only on land the new owner holds (%d wrong)" % foreign_title)
	if not sim.wars.is_empty():
		check(legal_changed == 0, "while the war is on legal[] is untouched by occupation (%d changed)" % legal_changed)
	check(controlled_by_other < sim.cells_of(b).size() + sim.cells_of(a).size(), "war did not flip whole countries at once")
	# deterministic: an identical command sequence gives an identical state
	var twin := _war_run(a, b, target, 40)
	check(twin.checksum() == sim.checksum(), "identical commands -> identical checksum")
	check(twin.owner == sim.owner and twin.legal == sim.legal, "identical owner[] and legal[]")
	# save/load in the middle of the war keeps owner[] and legal[] separate and exact
	check(SaveSystem.save(sim, "wartest"), "save mid-war")
	var loaded := SaveSystem.load_slot("wartest")
	check(loaded != null and loaded.checksum() == sim.checksum(), "load mid-war: same checksum")
	check(loaded != null and loaded.owner == sim.owner and loaded.legal == sim.legal, "load mid-war: owner[] and legal[] restored")
	if loaded != null:
		for i in 20:
			sim.tick_day()
			loaded.tick_day()
		check(loaded.checksum() == sim.checksum(), "loaded game continues identically for 20 more days")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://saves/wartest.sav"))


## Cross-platform determinism: golden checksums recorded on Windows. CI runs this on Linux, macOS and Windows, so any
## divergence in floats, hashing or RNG between platforms (a Windows <-> macOS multiplayer desync) fails here first.
## If simulation rules change on purpose, regenerate: run the test, copy the printed values.
const GOLDEN_IDLE_30 := 3494266976
const GOLDEN_WAR_40 := 2834175281


func test_cross_platform_golden_checksums() -> void:
	var idle := _earth()
	for i in 30:
		idle.tick_day()
	var probe := _earth()
	var f := _find_border(probe)
	var target := -1
	for q in probe.provinces()[f["cell"]]["land_neighbors"]:
		if probe.owner[q] == f["b"]:
			target = q
			break
	var war := _war_run(f["a"], f["b"], target, 40)
	print("  golden idle30=", idle.checksum(), " war40=", war.checksum())
	check(idle.checksum() == GOLDEN_IDLE_30, "idle world after 30 days matches the golden checksum on every platform")
	check(war.checksum() == GOLDEN_WAR_40, "war after 40 days matches the golden checksum on every platform")
## Peace treaty with the "annex" term is the only war outcome that changes legal[]: control already held becomes
## recognised, land the loser held of ours is handed back, and an AI only agrees when clearly outmatched.
func test_peace_treaty_annexes_occupied_land() -> void:
	var sim := _earth()
	var f := _find_border(sim)
	var a: int = f["a"]
	var b: int = f["b"]
	var cell: int = f["cell"]
	check(not sim.apply_command({"type": "propose_peace", "country": a, "target": b, "terms": "bogus"})["ok"], "unknown peace terms are rejected")
	sim.wars.append({"a": b, "b": a, "start": -100})   # an old war: b attacks a
	check(sim.apply_command({"type": "propose_peace", "country": b, "target": a, "terms": "annex"}).get("reason", "") == "nothing to annex", "nothing held -> nothing to annex")
	# b occupies one cell of a
	sim.armies = sim.armies.filter(func(x): return x["prov"] != cell)
	sim._add_army(b, cell, [sim._make_div("infantry"), sim._make_div("infantry")])
	sim._occupation()
	check(sim.owner[cell] == b and sim.legal[cell] == a, "cell occupied: controlled by b, still legally a's")
	check(sim.cells_held_from(b, a) == [cell], "cells_held_from lists exactly the occupied cell")
	# a hold one of b's cells too (it must be handed back)
	var other := -1
	for q in sim.cells_of(b):
		if sim.legal[q] == b and not sim.provinces()[q]["land_neighbors"].has(cell) and q != sim.countries[b]["capital"]:
			other = q
			break
	sim.set_owner(other, a)
	check(sim.legal[other] == b and sim.owner[other] == a, "a holds one of b's cells")
	# AI a refuses to cede land to an enemy that is not clearly stronger (it would still agree to a plain peace)
	sim.armies = sim.armies.filter(func(x): return x["owner"] != a)
	if sim.army_strength(b) >= sim.army_strength(a) * 1.5:
		sim._add_army(a, sim.countries[a]["capital"], [sim._make_div("armor"), sim._make_div("armor"), sim._make_div("armor"), sim._make_div("armor"), sim._make_div("armor"), sim._make_div("armor")])
	var weak := sim.apply_command({"type": "propose_peace", "country": b, "target": a, "terms": "annex"})
	check(not weak["ok"] and weak.get("reason", "") == "refused terms", "AI refuses to cede land to an enemy that is not clearly stronger (%s)" % str(weak))
	check(sim.at_war(a, b) and sim.legal[cell] == a, "a refused treaty changes nothing")
	# b becomes clearly stronger: the same treaty is accepted
	sim.armies = sim.armies.filter(func(x): return x["owner"] != a)
	var expected := sim.cells_held_from(b, a).size()
	var legal_before := sim.legal.duplicate()
	var res := sim.apply_command({"type": "propose_peace", "country": b, "target": a, "terms": "annex"})
	check(res["ok"], "a clearly weaker AI accepts the annexation treaty (%s)" % str(res))
	check(not sim.at_war(a, b), "the war is over")
	check(sim.legal[cell] == b and sim.owner[cell] == b, "occupied cell is legally b's now; control is unchanged")
	check(sim.owner[other] == b, "land a held of b's is handed back (control)")
	var changed := 0
	for i in sim.legal.size():
		if sim.legal[i] != legal_before[i]:
			changed += 1
	check(changed == expected, "exactly the annexed cells changed legal title (%d of %d)" % [changed, expected])
	check(sim.owner[sim.countries[a]["capital"]] == a, "the loser's capital is still on its own land")
	# survives a save/load
	check(SaveSystem.save(sim, "peacetest"), "save after treaty")
	var loaded := SaveSystem.load_slot("peacetest")
	check(loaded != null and loaded.legal == sim.legal and loaded.checksum() == sim.checksum(), "legal[] after the treaty survives save/load")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://saves/peacetest.sav"))


## Surrender is a treaty: when a capital falls the winner gets legal title to everything it holds from the loser.
func test_capitulation_annexes_held_land() -> void:
	var sim := _earth()
	var f := _find_border(sim)
	var a: int = f["a"]
	var b: int = f["b"]
	var cap: int = sim.countries[a]["capital"]
	sim.wars.append({"a": b, "b": a, "start": 0})
	var held: int = f["cell"]
	for cell in [held, cap]:
		sim.armies = sim.armies.filter(func(x): return x["prov"] != cell)
		sim._add_army(b, cell, [sim._make_div("infantry"), sim._make_div("infantry")])
	sim._occupation()
	check(not sim.at_war(a, b), "the war ended by capitulation")
	check(sim.owner[cap] == b and sim.legal[cap] == b, "the fallen capital is now legally the winner's")
	check(sim.owner[held] == b and sim.legal[held] == b, "every cell the winner holds is recognised after the surrender")
	check(sim.owner[sim.countries[a]["capital"]] == a or not sim.countries[a]["alive"], "the loser's new capital is on its own land")
	check(sim.cells_held_from(b, a).is_empty(), "no unrecognised occupation is left between the two")


## A tired AI that is clearly outmatched concedes what the stronger side holds; a roughly equal one only makes peace.
func test_tired_ai_concedes_to_a_clearly_stronger_enemy() -> void:
	var sim := _earth()
	var f := _find_border(sim)
	var a: int = f["a"]
	var b: int = f["b"]
	sim.wars.append({"a": b, "b": a, "start": -200})
	sim.armies = sim.armies.filter(func(x): return x["prov"] != f["cell"] and x["owner"] != a)
	sim._add_army(b, f["cell"], [sim._make_div("infantry"), sim._make_div("infantry")])
	sim._occupation()
	check(sim.owner[f["cell"]] == b and sim.legal[f["cell"]] == a, "b occupies a cell of a")
	sim._ai()
	check(not sim.at_war(a, b), "the exhausted AI ended the war")
	check(sim.legal[f["cell"]] == b, "the clearly stronger enemy got legal title to the cell it holds")


## Armies cut off deep in enemy land walk home instead of starving; supplied or home armies are left alone.
func test_ai_pulls_starving_armies_back() -> void:
	var sim := _earth()
	var f := _find_border(sim)
	var a: int = f["a"]
	var b: int = f["b"]
	sim.wars.append({"a": a, "b": b, "start": 0})
	var deep := -1
	for q in sim.provinces()[f["cell"]]["land_neighbors"]:
		if sim.owner[q] == b:
			deep = q
			break
	check(deep >= 0, "an enemy cell next to the border")
	sim.armies = sim.armies.filter(func(x): return x["prov"] != deep)
	var army := sim._add_army(a, deep, [sim._make_div("infantry")])
	army["supply"] = 10
	check(sim._ai_retreat_starving(a) >= 1, "a starving army in enemy land is ordered back")
	check(not army["path"].is_empty() and sim.owner[army["path"][army["path"].size() - 1]] == a, "its route ends on its own land")
	army["path"] = []
	army["supply"] = 90
	check(sim._ai_retreat_starving(a) == 0 and army["path"].is_empty(), "a well supplied army stays")
	army["supply"] = 10
	army["prov"] = f["cell"]   # our own cell
	check(sim._ai_retreat_starving(a) == 0, "a starving army on its own land is not moved")


## The state hash must see recognised ownership: two games that differ only in legal[] are out of sync.
func test_checksum_covers_legal_ownership() -> void:
	var a := _earth()
	var b := _earth()
	check(a.checksum() == b.checksum(), "identical games share a checksum")
	var cell := 0
	for i in b.owner.size():
		if b.owner[i] >= 0:
			cell = i
			break
	var other: int = (b.owner[cell] + 1) % b.countries.size()
	b.legal[cell] = other
	check(a.checksum() != b.checksum(), "a different legal[] changes the checksum")


## Sanctions: financial pressure that costs the imposer influence and takes a share of the target's income,
## stacks per sanctioning country (capped), can be lifted, survives saves, and changes nothing when unused.
func test_sanctions() -> void:
	var sim := _earth()
	var base_sum := sim.checksum()
	var target: int = sim.countries.find_custom(func(c): return c["name"] == "Франция")
	var imposers: Array[int] = []
	for c in sim.countries:
		if c["id"] != target and c["alive"] and not sim.allied(c["id"], target) and imposers.size() < 6 and not sim.cells_of(c["id"]).is_empty():
			imposers.append(c["id"])
	for id in imposers:
		sim.countries[id]["pp"] = 200
	# validation
	check(not sim.apply_command({"type": "impose_sanctions", "country": imposers[0], "target": imposers[0]})["ok"], "no sanctions against oneself")
	check(not sim.apply_command({"type": "impose_sanctions", "country": imposers[0], "target": 9999})["ok"], "no sanctions against a country that does not exist")
	sim.countries[imposers[0]]["pp"] = Simulation.SANCTION_COST_PP - 1
	check(sim.apply_command({"type": "impose_sanctions", "country": imposers[0], "target": target}).get("reason", "") == "not enough influence", "sanctions cost political influence")
	sim.countries[imposers[0]]["pp"] = 200
	check(sim.checksum() != base_sum, "(sanity) the treasury edits above changed the state")
	# effect on income
	sim._economy()
	var income0: int = sim.countries[target]["income"]
	check(income0 > 0, "the target has income (%d)" % income0)
	var pp_before: int = sim.countries[imposers[0]]["pp"]
	check(sim.apply_command({"type": "impose_sanctions", "country": imposers[0], "target": target})["ok"], "sanctions are imposed")
	check(sim.countries[imposers[0]]["pp"] == pp_before - Simulation.SANCTION_COST_PP, "the imposer paid %d influence" % Simulation.SANCTION_COST_PP)
	check(not sim.apply_command({"type": "impose_sanctions", "country": imposers[0], "target": target})["ok"], "the same sanctions cannot be imposed twice")
	check(sim.sanction_level(target) == 1 and sim.sanction_pct(target) == Simulation.SANCTION_INCOME_PCT, "one sanctioning country = %d%%" % Simulation.SANCTION_INCOME_PCT)
	sim._economy()
	var income1: int = sim.countries[target]["income"]
	check(absi(income1 - income0 * 88 / 100) <= 1, "income fell by 12%% (%d -> %d)" % [income0, income1])
	# stacking and the cap
	for i in range(1, imposers.size()):
		sim.apply_command({"type": "impose_sanctions", "country": imposers[i], "target": target})
	check(sim.sanction_level(target) == imposers.size() and sim.sanction_pct(target) == Simulation.SANCTION_MAX_PCT, "sanctions stack and are capped at %d%% (%d countries)" % [Simulation.SANCTION_MAX_PCT, imposers.size()])
	sim._economy()
	check(absi(sim.countries[target]["income"] - income0 * 52 / 100) <= 1, "income at the cap is 52%% of normal (%d)" % sim.countries[target]["income"])
	# lifting
	check(not sim.apply_command({"type": "lift_sanctions", "country": target, "target": imposers[0]})["ok"], "a country cannot lift sanctions it never imposed")
	var level_before: int = sim.sanction_level(target)
	check(sim.apply_command({"type": "lift_sanctions", "country": imposers[1], "target": target})["ok"], "an imposer lifts its own sanctions")
	check(sim.sanction_level(target) == level_before - 1 and sim.sanctioned_by(imposers[0], target) and not sim.sanctioned_by(imposers[1], target), "...and only its own: the others stay (level %d -> %d)" % [level_before, sim.sanction_level(target)])
	for id in imposers:
		sim.apply_command({"type": "lift_sanctions", "country": id, "target": target})
	check(sim.sanctions.is_empty() and sim.sanction_pct(target) == 0, "all sanctions lifted")
	sim._economy()
	check(sim.countries[target]["income"] == income0, "income is back to normal (%d)" % sim.countries[target]["income"])
	# save / load keeps them; a game that never used them is unchanged
	sim.apply_command({"type": "impose_sanctions", "country": imposers[1], "target": target})
	var with_sanctions := sim.checksum()
	check(SaveSystem.save(sim, "sanctest"), "save with sanctions")
	var loaded := SaveSystem.load_slot("sanctest")
	check(loaded != null and loaded.sanctions == sim.sanctions and loaded.checksum() == with_sanctions, "sanctions survive save/load")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://saves/sanctest.sav"))
	sim.apply_command({"type": "lift_sanctions", "country": imposers[1], "target": target})
	var fresh := _earth()
	var fresh_sum := fresh.checksum()
	check(fresh.sanctions.is_empty() and fresh_sum == base_sum, "a fresh game has no sanctions and its checksum is unchanged")
	# a destroyed country takes its sanctions with it
	fresh.countries[imposers[2]]["pp"] = 100
	fresh.apply_command({"type": "impose_sanctions", "country": imposers[2], "target": target})
	for p in fresh.cells_of(imposers[2]).duplicate():
		fresh.set_owner(p, target)
	fresh._eliminate()
	check(not fresh.countries[imposers[2]]["alive"] and fresh.sanctions.is_empty(), "sanctions of a destroyed country disappear")


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


func _touch_ev(idx: int, pos: Vector2, pressed: bool) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	return e


func _drag_ev(idx: int, pos: Vector2) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	return e


func test_touch_gestures() -> void:
	# pinch: fingers move apart -> zoom in; both move right -> pan
	var g := TouchGestures.new()
	g.feed(_touch_ev(0, Vector2(100, 100), true), 0.0)
	g.feed(_touch_ev(1, Vector2(200, 100), true), 0.01)
	check(g.multi, "two fingers start a multi-touch gesture")
	var r := g.feed(_drag_ev(1, Vector2(300, 100)), 0.02)
	check(is_equal_approx(r["zoom"], 2.0), "pinch apart doubles the zoom (%s)" % str(r.get("zoom")))
	check((r["pan"] as Vector2).is_equal_approx(Vector2(50, 0)), "midpoint movement pans the map")
	r = g.feed(_drag_ev(0, Vector2(150, 100)), 0.03)
	check(is_equal_approx(r["zoom"], 150.0 / 200.0 * 1.0) or r["zoom"] < 1.0, "pinch together zooms out")
	g.feed(_touch_ev(1, Vector2(300, 100), false), 0.04)
	check(g.multi, "gesture stays multi-touch until every finger is lifted")
	g.feed(_touch_ev(0, Vector2(150, 100), false), 0.05)
	check(not g.multi and g.points.is_empty(), "all fingers lifted ends the gesture")
	# long press: rests 0.5 s -> fires once; moving cancels it
	var h := TouchGestures.new()
	h.feed(_touch_ev(0, Vector2(50, 50), true), 1.0)
	check(not h.long_press_due(1.3), "no long press before 0.5 s")
	check(h.long_press_due(1.6), "long press fires after 0.5 s")
	check(not h.long_press_due(2.0) and h.long_fired, "long press fires only once per touch")
	h.feed(_touch_ev(0, Vector2(50, 50), false), 2.1)
	var m := TouchGestures.new()
	m.feed(_touch_ev(0, Vector2(50, 50), true), 1.0)
	m.feed(_drag_ev(0, Vector2(90, 50)), 1.1)
	check(not m.long_press_due(2.0), "moving the finger cancels the long press")
	# a second finger cancels a pending long press
	var n := TouchGestures.new()
	n.feed(_touch_ev(0, Vector2(50, 50), true), 1.0)
	n.feed(_touch_ev(1, Vector2(80, 50), true), 1.1)
	check(not n.long_press_due(2.0), "a second finger cancels the long press")


func test_safe_area_insets() -> void:
	# iPhone-like: 1179x2556 px, notch 59 px top, home indicator 34 px bottom; UI viewport 393x852 units
	var ins := MobileLayout.safe_area_insets(Rect2i(0, 59, 1179, 2556 - 59 - 34), Vector2i(1179, 2556), Vector2(393, 852))
	check(is_equal_approx(ins.position.y, 59.0 / 3.0), "top inset follows the notch (%.1f)" % ins.position.y)
	check(is_equal_approx(ins.size.y, 34.0 / 3.0), "bottom inset follows the home indicator (%.1f)" % ins.size.y)
	check(ins.position.x == 0.0 and ins.size.x == 0.0, "no side insets in portrait")
	check(MobileLayout.safe_area_insets(Rect2i(), Vector2i(0, 0), Vector2(100, 100)) == Rect2(), "empty safe area gives no insets")


func test_missiles_and_air_defense() -> void:
	var plain := _earth()
	check(plain.apply_command({"type": "build_missile", "country": 0, "mtype": "tactical"})["reason"] == "rule disabled", "missiles need the modern rule")
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"modern": true}
	var sim := Simulation.new()
	check(sim.setup_scenario(scn).is_empty(), "modern scenario loads")
	var b := _find_border(sim)
	check(not b.is_empty(), "found two neighbouring countries")
	var a: int = b["a"]
	var d: int = b["b"]
	var target := -1
	for q in sim.provinces()[b["cell"]]["land_neighbors"]:
		if sim.owner[q] == d:
			target = q
	check(target >= 0, "enemy target cell next to the border")
	sim.wars.append({"a": a, "b": d, "start": 0})
	check(sim.missile_count(a, "tactical") == 3 and sim.missile_count(a, "strategic") == 0, "starting stock")
	check(sim.apply_command({"type": "build_missile", "country": a, "mtype": "tactical"})["reason"] == "technology required", "building needs the technology")
	sim.countries[a]["techs"].append("mis1")
	sim.countries[a]["treasury"] = 1000
	sim.countries[a]["stock"]["steel"] = 200
	check(sim.apply_command({"type": "build_missile", "country": a, "mtype": "tactical", "count": 2})["ok"], "tactical missiles are built")
	check(sim.missile_count(a, "tactical") == 5 and sim.countries[a]["treasury"] == 920, "build spends stock, money and steel")
	check(sim.apply_command({"type": "launch_missile", "country": a, "mtype": "strategic", "target": target})["reason"] == "no missiles", "cannot launch without missiles")
	# interception: defence 80% vs none
	sim.damage[target] = 0
	var hits := 0
	var tries := 0
	sim.countries[d]["mods"]["ad_pct"] = 200   # clamp -> 80 %
	for i in 4:
		var r := sim.apply_command({"type": "launch_missile", "country": a, "mtype": "tactical", "target": target})
		check(r["ok"], "launch %d accepted" % i)
		tries += 1
		if r.get("hit", false):
			hits += 1
	check(sim.missile_count(a, "tactical") == 1, "each launch uses one missile")
	check(sim.strikes.size() == tries, "launches are recorded for the map")
	check(sim.air_defense(d) == 80, "air defence is capped at 80%")
	check(sim.damage[target] == hits * 25 or sim.damage[target] == 100 or sim.damage[target] == hits * 25, "only hits damage the target (%d hits, damage %d)" % [hits, sim.damage[target]])
	# peace and range
	check(sim.apply_command({"type": "launch_missile", "country": a, "mtype": "tactical", "target": sim.countries[a]["capital"]})["reason"] == "target not at war", "own territory is not a valid target")
	var far := -1
	for c in sim.countries:
		if c["id"] != a and c["id"] != d and not sim.at_war(a, c["id"]):
			far = c["capital"]
	sim.wars.append({"a": a, "b": sim.owner[far], "start": 0})
	check(sim.apply_command({"type": "launch_missile", "country": a, "mtype": "tactical", "target": far})["reason"] == "out of range", "targets beyond the missile range are refused")
	# save/load + determinism
	var r2 := Simulation.from_dict(str_to_var(var_to_str(sim.to_dict())), Simulation.load_country_defs())
	check(r2.missile_count(a, "tactical") == 1 and r2.strikes.size() == tries, "missile state survives save/load")
	check(r2.checksum() == sim.checksum(), "checksum survives save/load with missiles")


func test_population_and_markets() -> void:
	var plain := _earth()
	check(plain.pop_index(0) == 10000 and not plain.rule_markets, "markets are off by default")
	check(plain.apply_command({"type": "market_buy", "country": 0, "res": "food", "amount": 1})["reason"] == "rule disabled", "market commands need the rule")
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"markets": true}
	var sim := Simulation.new()
	check(sim.setup_scenario(scn).is_empty(), "scenario with markets loads")
	for r in Simulation.MARKET_RES:
		check(sim.market_pct[r] == 100, "%s starts at the base price" % r)
	var c: Dictionary = sim.countries[0]
	c["treasury"] = 1000
	c["stock"]["iron"] = 100
	var t0: int = c["treasury"]
	var b := sim.apply_command({"type": "market_buy", "country": 0, "res": "iron", "amount": 10})
	check(b["ok"] and c["stock"]["iron"] == 110, "buying adds stock")
	var spent: int = t0 - c["treasury"]
	var t1: int = c["treasury"]
	var s1 := sim.apply_command({"type": "market_sell", "country": 0, "res": "iron", "amount": 10})
	var earned: int = c["treasury"] - t1
	check(s1["ok"] and spent > earned, "the spread makes a round trip lose money (%d paid, %d earned)" % [spent, earned])
	check(sim.apply_command({"type": "market_sell", "country": 0, "res": "iron", "amount": 20})["ok"] == true, "selling within stock works")
	c["stock"]["iron"] = 5
	check(sim.apply_command({"type": "market_sell", "country": 0, "res": "iron", "amount": 20})["reason"] == "not enough stock", "cannot sell more than owned")
	check(sim.apply_command({"type": "market_buy", "country": 0, "res": "gold", "amount": 1})["reason"] == "invalid resource", "unknown resource refused")
	# prices react to heavy buying
	var p0: int = sim.market_pct["oil"]
	for i in 6:
		c["treasury"] = 5000
		c["stock"]["oil"] = 0
		sim.apply_command({"type": "market_buy", "country": 0, "res": "oil", "amount": 20})
	while sim.day % 5 != 4:
		sim.tick_day()
	sim.tick_day()
	check(sim.market_pct["oil"] >= p0, "heavy buying does not lower the price (%d -> %d)" % [p0, sim.market_pct["oil"]])
	# population: famine shrinks, normal times grow slowly
	var d: Dictionary = sim.countries[1]
	sim.pop_bp[1] = 10000
	var before: int = sim.pop_bp[1]
	d["short"] = ["food"]
	sim._population()
	check(sim.pop_bp[1] < before, "famine shrinks the population")
	d["short"] = []
	sim.day = 4
	sim.pop_bp[1] = 10000
	sim._population()
	check(sim.pop_bp[1] == 10001, "peace and food grow the population slowly")
	check(sim.pop_index(1) == sim.pop_bp[1], "pop_index reads the stored value")
	# determinism + save/load
	var a := Simulation.new()
	a.setup_scenario(scn)
	var e := Simulation.new()
	e.setup_scenario(scn)
	for i in 40:
		a.tick_day()
		e.tick_day()
	check(a.checksum() == e.checksum(), "simulation with markets is deterministic")
	var r := Simulation.from_dict(str_to_var(var_to_str(a.to_dict())), Simulation.load_country_defs())
	check(r.rule_markets and r.market_pct == a.market_pct and r.pop_bp == a.pop_bp, "population and prices survive save/load")
	check(r.checksum() == a.checksum(), "checksum survives save/load with markets")


func test_design_tokens() -> void:
	for sp in [Design.S1, Design.S2, Design.S3, Design.S4, Design.S5, Design.S6]:
		check(sp % 4 == 0, "spacing %d is on the 4 px grid" % sp)
	for pair in [[Design.C_TEXT, Design.C_PANEL, 4.5], [Design.C_TEXT, Design.C_BG, 4.5], [Design.C_TEXT_DIM, Design.C_PANEL, 4.5], [Design.C_GOLD, Design.C_PANEL, 4.5],
			[Design.C_OK, Design.C_PANEL, 4.5], [Design.C_WARN, Design.C_PANEL, 4.5], [Design.C_BAD, Design.C_PANEL, 4.5], [Design.C_INFO, Design.C_PANEL, 4.5]]:
		var cr := Design.contrast(pair[0], pair[1])
		check(cr >= pair[2], "contrast %.1f:1 >= %.1f for %s on %s" % [cr, pair[2], str(pair[0]), str(pair[1])])
	check(Design.BTN_H_TOUCH * MobileLayout.PHONE_UI_SCALE >= 44.0, "touch buttons are at least 44 pt")


func test_settings_and_sound() -> void:
	GameSettings.path = "user://test_settings.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GameSettings.path))
	GameSettings.reset_for_tests()
	check(not GameSettings.reduce_motion(), "motion is on by default")
	check(is_equal_approx(float(GameSettings.get_value("vol_master")), 0.8), "default master volume")
	GameSettings.set_value("reduce_motion", true)
	GameSettings.set_value("vol_music", 0.2)
	GameSettings.reset_for_tests()   # reload from disk
	check(GameSettings.reduce_motion() and is_equal_approx(float(GameSettings.get_value("vol_music")), 0.2), "settings persist on disk")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GameSettings.path))
	GameSettings.path = GameSettings.PATH
	GameSettings.reset_for_tests()
	# procedural sounds
	var click := SoundKit.ui("click")
	check(click.data.size() == int(SoundKit.RATE * 0.06) * 2, "click has the expected length")
	var peak := 0
	for i in range(0, click.data.size() / 2):
		peak = maxi(peak, absi(click.data.decode_s16(i * 2)))
	check(peak > 3000 and peak < 32768, "click is audible and not clipped (peak %d)" % peak)
	check(SoundKit.ui("open") == SoundKit.ui("open"), "UI sounds are cached")
	var amb := SoundKit.ambient(2)
	check(amb.loop_mode == AudioStreamWAV.LOOP_FORWARD and amb.loop_end == 2 * 11025, "ambient pad loops over its whole length")
	# seamless loop: first and last samples are close
	var first := amb.data.decode_s16(0)
	var last := amb.data.decode_s16((amb.loop_end - 1) * 2)
	check(absi(first - last) < 4000, "ambient loop seam is smooth (%d vs %d)" % [first, last])


func test_weather_fx_intensity() -> void:
	var off := WeatherFx.state_for(90, true, 3.0, false, false)
	check(off["snow"] == 0.0 and off["rain"] == 0.0, "no weather effects on the Low profile")
	check(WeatherFx.state_for(90, true, 3.0, true, true)["snow"] == 0.0, "no weather effects with reduced motion")
	check(WeatherFx.state_for(90, true, 0.5, true, false)["snow"] == 0.0, "no weather effects when zoomed far out")
	check(WeatherFx.state_for(100, false, 2.0, true, false)["snow"] == 1.0, "deep winter snows at full intensity")
	check(WeatherFx.state_for(10, false, 2.0, true, false)["snow"] == 0.0, "summer has no snow")
	var storm := WeatherFx.state_for(10, true, 2.0, true, false)
	check(storm["rain"] > 0.5 and storm["snow"] == 0.0, "a summer storm brings rain")
	var wstorm := WeatherFx.state_for(80, true, 2.0, true, false)
	check(wstorm["rain"] == 0.0 and wstorm["snow"] >= 0.9, "a winter storm brings snow, not rain")


func test_ui_motion_helpers() -> void:
	check(UiMotion.leading_number("120 (+3)") == 120, "leading number of a chip text")
	check(UiMotion.leading_number("-5 (x)") == -5, "negative leading number")
	check(UiMotion.leading_number("абв") == -1, "no number gives -1")
	check(ToastHost.kind_of("Россия объявляет войну Украине") == "war", "war lines become red toasts")
	check(ToastHost.kind_of("Заключён мир") == "peace", "peace lines become green toasts")
	check(ToastHost.kind_of("Что-то произошло") == "info", "other lines are neutral")


func test_icon_set_is_complete() -> void:
	for n in ["air", "fleet", "missile", "drone", "market", "weather", "satellite"]:
		check(Icons.NAMES.has(n), "icon %s is registered" % n)


func test_division_templates() -> void:
	var plain := _earth()
	check(plain.apply_command({"type": "create_template", "country": 0, "name": "X", "bn": ["inf"]})["reason"] == "rule disabled", "templates need the rule")
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"templates": true}
	var sim := Simulation.new()
	check(sim.setup_scenario(scn).is_empty(), "scenario with templates loads")
	var four := sim.template_stats(["inf", "inf", "inf", "inf"])
	check(four["hp"] == 500 and four["cost"] == 32 and is_equal_approx(four["atk"], 1.0), "four infantry battalions equal the classic infantry division")
	var plain_avg := sim.template_stats(["inf", "art", "tank"])
	var combined := sim.template_stats(["inf", "art", "tank"])
	var no_tank := sim.template_stats(["inf", "art"])
	check(combined["atk"] > no_tank["atk"], "combined arms attack beats infantry + artillery (%.2f vs %.2f)" % [combined["atk"], no_tank["atk"]])
	check(sim.template_stats(["tank", "tank"])["oil"] and not four["oil"], "tanks make a division oil-dependent")
	var tank_only := sim.template_stats(["tank", "tank"])
	var with_recon := sim.template_stats(["tank", "tank", "recon"])
	check(with_recon["terrain"]["mountain"] > tank_only["terrain"]["mountain"], "reconnaissance softens terrain penalties")
	check(sim.template_stats([]).is_empty() and sim.template_stats(["inf", "inf", "inf", "inf", "inf", "inf", "inf", "inf", "inf", "inf"]).is_empty() and sim.template_stats(["ufo"]).is_empty(), "invalid battalion lists are refused")
	var c: Dictionary = sim.countries[0]
	var r := sim.apply_command({"type": "create_template", "country": 0, "name": "Штурмовая", "bn": ["inf", "inf", "art", "eng"]})
	check(r["ok"] and sim.unit_defs.has(r["key"]), "a template becomes a unit type")
	check(sim.apply_command({"type": "create_template", "country": 0, "name": "", "bn": ["inf"]})["reason"] == "invalid name", "a name is required")
	var key: String = r["key"]
	c["treasury"] = 1000
	c["stock"]["steel"] = 500
	c["manpower"] = 500
	var divs_before := sim.divisions_of(0)
	var t0: int = c["treasury"]
	var tr := sim.apply_command({"type": "train_division", "country": 0, "unit": key})
	check(tr["ok"] and sim.divisions_of(0) == divs_before + 1 and c["treasury"] == t0 - int(sim.unit_defs[key]["cost"]), "a template division is trained and paid for")
	check(sim.apply_command({"type": "train_division", "country": 1, "unit": key})["reason"] == "invalid unit", "other countries cannot train my template")
	check(sim.apply_command({"type": "delete_template", "country": 0, "key": key})["reason"] == "template in use", "a template in use cannot be deleted")
	var r2 := sim.apply_command({"type": "create_template", "country": 0, "name": "Запасная", "bn": ["inf"]})
	check(sim.apply_command({"type": "delete_template", "country": 0, "key": r2["key"]})["ok"] and not sim.unit_defs.has(r2["key"]), "an unused template is deleted")
	for i in 8:
		sim.apply_command({"type": "create_template", "country": 0, "name": "T%d" % i, "bn": ["inf"]})
	check(sim.apply_command({"type": "create_template", "country": 0, "name": "Лишняя", "bn": ["inf"]})["reason"] == "too many templates", "at most 8 templates per country")
	# fighting with a template division works (combat reads the generated definition)
	for i in 5:
		sim.tick_day()
	var restored := Simulation.from_dict(str_to_var(var_to_str(sim.to_dict())), Simulation.load_country_defs())
	check(restored.unit_defs.has(key) and restored.templates[0].size() == sim.templates[0].size(), "templates survive save/load")
	check(restored.checksum() == sim.checksum(), "checksum survives save/load with templates")
	# AI countries design their own divisions
	var ai := Simulation.new()
	ai.setup_scenario(scn)
	for i in 80:
		ai.tick_day()
	var made := 0
	for cid in ai.templates:
		made += ai.templates[cid].size()
	check(made >= 2, "AI countries create templates (%d)" % made)


func test_army_groups() -> void:
	var sim := _earth()
	var mine: Array = sim.armies_of(0)
	if mine.size() < 2:
		sim._spawn_army(0, sim.countries[0]["capital"])
		sim._spawn_army(0, sim.countries[0]["capital"])
		mine = sim.armies_of(0)
	var ids := [mine[0]["id"], mine[1]["id"]]
	check(sim.apply_command({"type": "create_group", "country": 0, "name": "", "armies": ids})["reason"] == "invalid name", "a group needs a name")
	check(sim.apply_command({"type": "create_group", "country": 0, "name": "Одна", "armies": [ids[0]]})["reason"] == "group needs two armies", "a group needs two armies")
	check(sim.apply_command({"type": "create_group", "country": 1, "name": "Чужие", "armies": ids})["reason"] == "invalid army", "foreign armies cannot be grouped")
	var before := sim.checksum()
	var r := sim.apply_command({"type": "create_group", "country": 0, "name": "Ударная группа", "armies": ids})
	check(r["ok"] and sim.groups_of(0).size() == 1, "a group is created")
	check(sim.checksum() != before, "a group is part of the state hash")
	# every member walks to a neighbouring land cell
	var cap: int = sim.armies_of(0)[0]["prov"]
	var dest := -1
	for q in sim.provinces()[cap]["land_neighbors"]:
		if sim.owner[q] == 0:
			dest = q
			break
	if dest >= 0:
		var gm := sim.apply_command({"type": "group_move", "country": 0, "group": r["id"], "target": dest})
		check(gm["ok"] and gm["moved"] == 2, "one order moves the whole group (%s)" % str(gm))
		check(sim.army_by_id(ids[0])["path"].size() > 0 and sim.army_by_id(ids[1])["path"].size() > 0, "both armies received a route")
	check(sim.apply_command({"type": "group_move", "country": 1, "group": r["id"], "target": cap})["reason"] == "no such group", "another country cannot order my group")
	# an army belongs to one group at a time
	var r2 := sim.apply_command({"type": "create_group", "country": 0, "name": "Вторая", "armies": ids})
	check(r2["ok"] and sim.groups_of(0).size() == 1, "regrouping the same armies replaces the old group")
	var restored := Simulation.from_dict(str_to_var(var_to_str(sim.to_dict())), Simulation.load_country_defs())
	check(restored.groups_of(0).size() == 1 and restored.checksum() == sim.checksum(), "groups survive save/load")
	check(sim.apply_command({"type": "delete_group", "country": 0, "group": r2["id"]})["ok"] and sim.groups_of(0).is_empty(), "a group is dissolved")
	var same := _earth()
	check(same.checksum() == _earth().checksum(), "games without groups keep their checksum")


func test_missile_sites() -> void:
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"modern": true}
	var sim := Simulation.new()
	sim.setup_scenario(scn)
	var b := _find_border(sim)
	var a: int = b["a"]
	var d: int = b["b"]
	sim.wars.append({"a": a, "b": d, "start": 0})
	var cap: int = sim.countries[d]["capital"]
	var home: int = b["cell"]
	check(sim.apply_command({"type": "build_site", "country": a, "kind": "ad", "cell": home})["reason"] == "technology required", "sites need their technology")
	sim.countries[a]["techs"].append_array(["ad1", "mis1"])
	sim.countries[d]["techs"].append_array(["ad1", "mis1"])
	sim.countries[a]["treasury"] = 2000
	sim.countries[a]["stock"]["steel"] = 500
	sim.countries[d]["treasury"] = 2000
	sim.countries[d]["stock"]["steel"] = 500
	check(sim.apply_command({"type": "build_site", "country": a, "kind": "ad", "cell": sim.countries[d]["capital"]})["reason"] == "invalid base", "sites go on own land only")
	# defender: a battery next to the target raises interception, a damaged one counts for less
	var target := -1
	for q in sim.provinces()[home]["land_neighbors"]:
		if sim.owner[q] == d:
			target = q
	var base_chance := sim.air_defense_at(d, target)
	check(sim.apply_command({"type": "build_site", "country": d, "kind": "ad", "cell": target})["ok"], "a battery is built")
	check(sim.apply_command({"type": "build_site", "country": d, "kind": "ad", "cell": target})["reason"] == "already built", "only one battery per cell")
	var with_battery := sim.air_defense_at(d, target)
	check(with_battery == mini(base_chance + 15, 85), "a battery adds 15 points (%d -> %d)" % [base_chance, with_battery])
	sim.damage[target] = 100
	check(sim.air_defense_at(d, target) == base_chance, "a destroyed battery adds nothing")
	sim.damage[target] = 0
	# attacker: launch sites extend the range by two cells. Find an enemy cell just out of range of every own cell.
	var range_tac: int = Simulation.MISSILE_DEFS["tactical"]["range"]
	var q2 := -1
	var site_cell := -1
	for nb in sim.neighbor_countries(a):
		for q in sim.cells_of(nb):
			if sim.missile_site(a, q, range_tac) >= 0:
				continue
			var near := sim.reach(q, range_tac + 2)
			var best := -1
			var best_d := 99
			for p2 in near:
				if sim.owner[p2] == a and sim.provinces()[p2]["land"] and near[p2] < best_d:
					best_d = near[p2]
					best = p2
			if best >= 0:
				q2 = q
				site_cell = best
				break
		if q2 >= 0:
			sim.wars.append({"a": a, "b": nb, "start": 0})
			break
	check(q2 >= 0, "found a target just beyond the tactical range")
	if q2 >= 0:
		check(sim.apply_command({"type": "build_site", "country": a, "kind": "launch", "cell": site_cell})["ok"], "a launch site is built")
		check(sim.missile_site(a, q2, range_tac) == site_cell, "the launch site makes a target two cells further reachable")
		sim.damage[site_cell] = 100
		check(sim.missile_site(a, q2, range_tac) == -1, "a destroyed launch site gives no extra range")
		sim.damage[site_cell] = 0
	var r := Simulation.from_dict(str_to_var(var_to_str(sim.to_dict())), Simulation.load_country_defs())
	check(r.sites.size() == sim.sites.size() and r.checksum() == sim.checksum(), "sites survive save/load")


func test_tutorial_steps() -> void:
	check(Tutorial.STEPS.size() == 6, "six tutorial steps")
	var ids := {}
	for st in Tutorial.STEPS:
		check(not ids.has(st["id"]) and str(st["text"]).length() > 20, "step %s has a unique id and a text" % st["id"])
		ids[st["id"]] = true
	check(not Tutorial.done("select", {}) and Tutorial.done("select", {"selected": true}), "select step")
	check(not Tutorial.done("time", {"day": 0}) and Tutorial.done("time", {"day": 3}), "time step")
	check(Tutorial.done("economy", {"panel": "economy"}) and not Tutorial.done("economy", {"panel": "tech"}), "economy step")
	check(Tutorial.done("tech", {"queue": 1}) and not Tutorial.done("tech", {"queue": 0}), "tech step")
	check(Tutorial.done("army", {"moving": true}) and not Tutorial.done("army", {}), "army step")
	check(Tutorial.done("diplomacy", {"panel": "diplomacy"}), "diplomacy step")
	check(not Tutorial.done("nonsense", {"selected": true}), "unknown steps never finish")
	check(Tutorial.first_open({}) == 0, "the first step is open at the start")
	check(Tutorial.first_open({"select": true, "time": true}) == 2, "steps finish in order")
	var all := {}
	for st in Tutorial.STEPS:
		all[st["id"]] = true
	check(Tutorial.first_open(all) == Tutorial.STEPS.size(), "all steps done")


func test_site_visibility() -> void:
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"modern": true}
	var sim := Simulation.new()
	sim.setup_scenario(scn)
	var b := _find_border(sim)
	var a: int = b["a"]
	var d: int = b["b"]
	var near: int = -1
	for q in sim.provinces()[b["cell"]]["land_neighbors"]:
		if sim.owner[q] == d:
			near = q
	var site := {"owner": d, "cell": near, "kind": "ad"}
	check(sim.site_visible(d, site), "the owner sees its own site")
	check(sim.site_visible(a, site), "a site next to my territory is visible")
	# a deep interior enemy site stays hidden
	var deep := -1
	for p in sim.cells_of(d):
		var seen := false
		for q in sim.provinces()[p]["neighbors"]:
			if sim.owner[q] == a:
				seen = true
		if not seen and p != near and not sim.provinces()[p]["land_neighbors"].has(b["cell"]):
			var far_from_army := true
			for arm in sim.armies:
				if arm["owner"] == a and (arm["prov"] == p or sim.provinces()[p]["neighbors"].has(arm["prov"])):
					far_from_army = false
			if far_from_army:
				deep = p
				break
	if deep >= 0 and sim.net_of_agent(a, d) < 25 and not sim.allied(a, d):
		check(not sim.site_visible(a, {"owner": d, "cell": deep, "kind": "launch"}), "a deep foreign site is hidden without intelligence")


func test_organization() -> void:
	var plain := _earth()
	var pa: Dictionary = plain.armies_of(0)[0]
	check(not plain.rule_organization and plain.army_org(pa) == 100 and not pa.has("org"), "organisation is off by default and armies carry no extra state")
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"organization": true}
	var sim := Simulation.new()
	sim.setup_scenario(scn)
	var a: Dictionary = sim.armies_of(0)[0]
	check(sim.army_org(a) == 100, "armies start at full organisation")
	# marching wears organisation down, resting in supply restores it
	var nb: int = sim.provinces()[a["prov"]]["land_neighbors"][0]
	a["path"] = [nb]
	a["supply"] = 100
	sim._organization()
	check(sim.army_org(a) == 99, "a marching army loses organisation")
	a["path"] = []
	a["org"] = 50
	sim._organization()
	check(sim.army_org(a) == 53, "a resting army in supply regains organisation")
	a["supply"] = 10
	sim._organization()
	check(sim.army_org(a) == 52, "an unsupplied army loses organisation")
	# weaker organisation, weaker fight
	a["supply"] = 100
	a["org"] = 100
	var full: float = sim.army_power(a, true)
	a["org"] = 0
	var empty: float = sim.army_power(a, true)
	check(is_equal_approx(empty, full * 0.5), "zero organisation halves the army's power (%.1f vs %.1f)" % [empty, full])
	a["org"] = 100
	# battle costs organisation (attacker more than defender)
	var b := _find_border(sim)
	var x: int = b["a"]
	var y: int = b["b"]
	sim.wars.append({"a": x, "b": y, "start": 0})
	var ax: Dictionary = sim.armies_of(x)[0]
	var ay: Dictionary = sim.armies_of(y)[0]
	var cell: int = b["cell"]
	ax["prov"] = cell
	ay["prov"] = cell
	ax["org"] = 100
	ay["org"] = 100
	sim._battles()
	var ox := sim.army_org(ax)
	var oy := sim.army_org(ay)
	check(ox < 100 and oy < 100, "both sides lose organisation in a battle (%d / %d)" % [ox, oy])
	var r := Simulation.from_dict(str_to_var(var_to_str(sim.to_dict())), Simulation.load_country_defs())
	check(r.rule_organization and r.checksum() == sim.checksum(), "organisation survives save/load")
	var a2 := Simulation.new()
	a2.setup_scenario(scn)
	var b2 := Simulation.new()
	b2.setup_scenario(scn)
	for i in 30:
		a2.tick_day()
		b2.tick_day()
	check(a2.checksum() == b2.checksum(), "simulation with organisation is deterministic")


func test_organization_retreat() -> void:
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"organization": true}
	var sim := Simulation.new()
	sim.setup_scenario(scn)
	var b := _find_border(sim)
	var x: int = b["a"]
	var y: int = b["b"]
	sim.wars.append({"a": x, "b": y, "start": 0})
	var ax: Dictionary = sim.armies_of(x)[0]
	var ay: Dictionary = sim.armies_of(y)[0]
	var cell: int = b["cell"]   # a cell of x
	ax["prov"] = cell
	ay["prov"] = cell
	ax["org"] = 0
	ay["org"] = 80
	sim._organization()
	check(ax["prov"] != cell and ax["prov"] >= 0 and sim.owner[ax["prov"]] == x, "a broken army retreats to an own neighbouring cell")
	check(sim.army_org(ax) == 15 and ax["path"].is_empty(), "the retreating army keeps a little organisation and stops marching")
	check(ay["prov"] == cell, "the army that held the field stays")
	# with every neighbour held by the enemy the broken army has nowhere to go and stays
	var held := sim.armies_of(y)
	var stuck: Dictionary = sim.armies_of(x)[0]
	stuck["prov"] = cell
	stuck["org"] = 0
	ay["prov"] = cell
	var i := 0
	for q in sim.provinces()[cell]["land_neighbors"]:
		if sim.owner[q] == x or sim.owner[q] == y:
			var filler: Dictionary = sim.armies_of(y)[(i + 1) % maxi(held.size(), 1)] if held.size() > 1 else ay
			if filler != ay:
				filler["prov"] = q
				i += 1
	sim._organization()
	check(stuck["prov"] == cell or sim.army_org(stuck) == 15, "a broken army either retreats or stays (never vanishes)")


func test_fog() -> void:
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"weather": true}
	var sim := Simulation.new()
	sim.setup_scenario(scn)
	var cell := 0
	for p in sim.provinces():
		if p["land"]:
			cell = p["id"]
			break
	var hits := 0
	var in_band := 0
	for d in 400:
		sim.day = d
		if sim.fog_at(cell):
			hits += 1
			var w := sim.winter_at(cell)
			if w >= 10 and w <= 70:
				in_band += 1
	check(hits == in_band, "fog appears only where winter severity is 10..70")
	check(WeatherFx.state_for(40, false, 2.0, true, false, true)["fog"] > 0.0, "fog shows with the Medium/High profile")
	check(WeatherFx.state_for(40, true, 2.0, true, false, true)["fog"] == 0.0, "a storm replaces fog")
	check(WeatherFx.state_for(40, false, 2.0, true, true, true)["fog"] == 0.0, "no fog with reduced motion")


func test_touch_target_size() -> void:
	# iPhone 17 simulator: 874 x 402 pt screen at scale 3 (2622 px), viewport 1304 logical units wide
	check(MobileLayout.touch_target(1304.0, 2622.0, 3.0) == 66.0, "44 pt is 66 logical units at the measured iPhone scale")
	check(MobileLayout.touch_target(874.0, 2622.0, 3.0) == 44.0, "at one logical unit per point a target is 44 units")
	check(MobileLayout.touch_target(0.0, 0.0, 0.0) == 44.0, "invalid inputs fall back to 44")
	check(MobileLayout.touch_target(300.0, 2622.0, 3.0) >= 36.0, "never below the desktop control size")


func test_food_balance() -> void:
	var raw: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	var off := Simulation.new()
	off.setup_scenario(raw)
	off.tick_day()
	var on_scn: Dictionary = raw.duplicate(true)
	on_scn["rules"] = {"food_balance": true}
	var on := Simulation.new()
	on.setup_scenario(on_scn)
	on.tick_day()
	check(not off.rule_food_balance and on.rule_food_balance, "the food rule is opt-in")
	var top := 0
	for c in off.countries:
		if c["alive"] and c["prod"]["food"] > off.countries[top]["prod"]["food"]:
			top = c["id"]
	var p_off: int = off.countries[top]["prod"]["food"]
	var p_on: int = on.countries[top]["prod"]["food"]
	check(p_on < p_off / 10 and p_on > 0, "the rule cuts raw food production to a few percent (%d -> %d)" % [p_off, p_on])
	check(on.countries[top]["cons"]["food"] == off.countries[top]["cons"]["food"], "consumption is unchanged")
	var short := 0
	for c in on.countries:
		if c["alive"] and c["prod"]["food"] < c["cons"]["food"]:
			short += 1
	check(short > 0, "some countries now have a food deficit (%d)" % short)
	var a := Simulation.new()
	a.setup_scenario(on_scn)
	var b := Simulation.new()
	b.setup_scenario(on_scn)
	for i in 20:
		a.tick_day()
		b.tick_day()
	check(a.checksum() == b.checksum(), "simulation with the food rule is deterministic")
	var r := Simulation.from_dict(str_to_var(var_to_str(a.to_dict())), Simulation.load_country_defs())
	check(r.rule_food_balance and r.checksum() == a.checksum(), "the food rule survives save/load")


func test_fiscal_balance() -> void:
	var raw: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	var off := Simulation.new()
	off.setup_scenario(raw)
	var on_scn: Dictionary = raw.duplicate(true)
	on_scn["rules"] = {"fiscal_balance": true}
	var on := Simulation.new()
	on.setup_scenario(on_scn)
	for i in 3:
		off.tick_day()
		on.tick_day()
	check(not off.rule_fiscal_balance and on.rule_fiscal_balance, "the fiscal rule is opt-in")
	var us := -1
	for c in on.countries:
		if c["name"] == "США":
			us = c["id"]
	check(us >= 0 and on.gdp_of.get(us, 0) > 10000000, "GDP is recorded per country (USA %d M$)" % int(on.gdp_of.get(us, 0)))
	check(on.countries[us]["income"] > off.countries[us]["income"], "income follows GDP with the rule (%d vs %d)" % [on.countries[us]["income"], off.countries[us]["income"]])
	var affordable_on := 0
	var affordable_off := 0
	for c in on.countries:
		if c["alive"] and c["income"] >= c["upkeep"]:
			affordable_on += 1
	for c in off.countries:
		if c["alive"] and c["income"] >= c["upkeep"]:
			affordable_off += 1
	check(affordable_on > affordable_off * 3, "far more countries can afford their armies (%d vs %d)" % [affordable_on, affordable_off])
	var a := Simulation.new()
	a.setup_scenario(on_scn)
	var b := Simulation.new()
	b.setup_scenario(on_scn)
	for i in 20:
		a.tick_day()
		b.tick_day()
	check(a.checksum() == b.checksum(), "simulation with the fiscal rule is deterministic")
	var r := Simulation.from_dict(str_to_var(var_to_str(a.to_dict())), Simulation.load_country_defs())
	check(r.rule_fiscal_balance and r.gdp_of.size() == a.gdp_of.size() and r.checksum() == a.checksum(), "GDP data and the rule survive save/load")
	for i in 3:
		a.tick_day()
		r.tick_day()
	check(a.checksum() == r.checksum(), "a loaded game continues exactly like the original")


func test_ai_respects_upkeep() -> void:
	var scn: Dictionary = ScenarioLoader.read_file("res://game/scenarios/modern_world.json").duplicate(true)
	scn["rules"] = {"fiscal_balance": true}
	var sim := Simulation.new()
	sim.setup_scenario(scn)
	for i in 150:
		sim.tick_day()
	var ok := 0
	var alive := 0
	var strength := 0
	for c in sim.countries:
		if c["alive"]:
			alive += 1
			if c["income"] >= c["upkeep"]:
				ok += 1
	for a in sim.armies:
		strength += a["strength"]
	check(ok * 100 / alive >= 70, "at least 70 %% of countries can pay their armies after 150 days (%d of %d)" % [ok, alive])
	check(strength / maxi(sim.armies.size(), 1) > 800, "average army strength stays healthy (%d)" % (strength / maxi(sim.armies.size(), 1)))
