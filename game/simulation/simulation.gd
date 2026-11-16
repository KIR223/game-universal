class_name Simulation
extends RefCounted
## Headless, deterministic game simulation. No Node/graphics dependencies.
## All mutations from players go through apply_command(); time advances via tick_day().

const SAVE_VERSION := 8
const ARMY_COST := 60
const ARMY_BASE_STRENGTH := 1000
const FLEET_COST := 90
const FLEET_STRENGTH := 1500
const TRANSPORT_PER_FLEET := 2
const ARMY_STEEL := 40
const FLEET_STEEL := 100
const STOCK_CAP := 3000
const MAX_DEALS := 6
const GRACE_DAYS := 60  # AI does not start wars before this day
const MAX_DIV := 9
const AI_STACK := 6
const MAX_GENERALS := 8
const MAX_QUEUE := 8
const BASE_SLOTS := 2
const WING_SIZE := 50
const PP_CAP := 300
const MAX_NET := 100
const MOVE_DAYS := 3
const MAX_WAR_DAYS := 150
const TERRAIN_DEFENSE := {
	"plains": 1.0, "forest": 1.2, "mountain": 1.5, "desert": 0.9, "hills": 1.15, "sea": 1.0,
}

var seed_value := 0
var rng := RandomNumberGenerator.new()
var world: Dictionary = {}
var day := 0
var owner := PackedInt32Array()
var countries: Array = []
var armies: Array = []
var wars: Array = []  # each: {"a": int, "b": int, "start": int}
var next_army_id := 1
var fleets: Array = []
var next_fleet_id := 1
var trades: Array = []  # {"id","seller","buyer","res","amount","price","fails"}
var next_trade_id := 1
var embargoes: Array = []  # {"a": embargoer, "b": target}
var res_defs: Array = []
var unit_defs: Dictionary = {}
var name_pool: Dictionary = {}
var next_general_id := 1
var wings: Array = []  # {"id","owner","base","type","strength","mission","target"}
var next_wing_id := 1
var damage := PackedInt32Array()  # per-province bombing damage 0..100
var air_defs: Dictionary = {}
var air_sup: Dictionary = {}  # derived daily: province -> {country: fighter share}
var air_cas: Dictionary = {}  # derived daily: province -> {country: close-air-support strength}
var ideo_defs: Dictionary = {}
var ideo_order: Array = []
var law_defs: Dictionary = {}
var law_defaults: Dictionary = {}
var event_defs: Array = []
var decision_defs: Array = []
var next_event_uid := 1
var intel_defs: Dictionary = {}
var ops: Array = []  # {"id","owner","target","type","left","total"}
var next_op_id := 1
var tech_defs: Dictionary = {}
var tech_order: Array = []
var alliances: Array = []  # each: {"a": int, "b": int}
var command_log: Array = []
var log_lines: Array = []
var dirty_provinces: Array[int] = []


func setup(seed_value_: int, country_defs: Array) -> void:
	seed_value = seed_value_
	rng.seed = seed_value
	res_defs = load_resource_defs()
	unit_defs = load_unit_defs()
	name_pool = load_name_pool()
	_load_techs()
	_load_politics()
	_load_intel()
	air_defs = load_air_defs()
	world = WorldGen.generate(seed_value)
	var caps := WorldGen.pick_capitals(world, country_defs.size(), rng)
	owner = WorldGen.assign_owners(world, caps)
	damage.resize(owner.size())
	damage.fill(0)
	countries.clear()
	for i in caps.size():
		var d: Dictionary = country_defs[i]
		_new_country(d["tag"], d["name"], d["color"], caps[i])
		_init_politics(i)
		_spawn_army(i, caps[i])
		_spawn_army(i, caps[i])
		for _g in 3:
			_new_general(i)
		var mine := armies_of(i)
		for k in mini(2, mine.size()):
			_set_general(mine[k], countries[i]["generals"][k]["id"])


func _zero_res() -> Dictionary:
	var d := {}
	for r in res_defs:
		d[r["id"]] = 0
	return d


func _start_stock() -> Dictionary:
	var d := _zero_res()
	for k in d:
		d[k] = 40
	if d.has("steel"):
		d["steel"] = 120
	return d


func res_name(res: String) -> String:
	for r in res_defs:
		if r["id"] == res:
			return r["name"]
	return res


func price_of(res: String) -> int:
	for r in res_defs:
		if r["id"] == res:
			return r["price"]
	return 1


func _load_techs() -> void:
	tech_defs = {}
	tech_order = []
	var f := FileAccess.open("res://data/techs.json", FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for t in parsed.get("techs", []):
		tech_defs[t["id"]] = t
		tech_order.append(t["id"])


func mod(cid: int, key: String) -> int:
	return countries[cid]["mods"].get(key, 0)


func tech_reqs_met(cid: int, id: String) -> bool:
	for r in tech_defs[id]["requires"]:
		if not countries[cid]["techs"].has(r):
			return false
	return true


func research_slots(cid: int) -> int:
	return BASE_SLOTS + mod(cid, "research_slots")


func research_points(cid: int) -> int:
	return int((6 + countries[cid]["industry"] / 6) * (100 + mod(cid, "research_pct")) / 100.0)


## Validated enqueue used by commands and AI.
func _queue_tech(cid: int, id: String) -> Dictionary:
	var c: Dictionary = countries[cid]
	if not tech_defs.has(id):
		return _fail("unknown tech")
	if c["techs"].has(id) or c["queue"].has(id):
		return _fail("already researched or queued")
	if c["queue"].size() >= MAX_QUEUE:
		return _fail("queue full")
	for r in tech_defs[id]["requires"]:
		if not c["techs"].has(r) and not c["queue"].has(r):
			return _fail("missing prerequisite")
	c["queue"].append(id)
	return {"ok": true}


func _research() -> void:
	for c in countries:
		if not c["alive"]:
			continue
		var cid: int = c["id"]
		var slots := research_slots(cid)
		var pts := research_points(cid)
		var active := 0
		for id in c["queue"].duplicate():
			if active >= slots:
				break
			if not tech_reqs_met(cid, id):
				continue
			active += 1
			c["progress"][id] = c["progress"].get(id, 0) + pts
			if c["progress"][id] >= tech_defs[id]["cost"]:
				c["queue"].erase(id)
				c["progress"].erase(id)
				c["techs"].append(id)
				_recalc_mods(cid)
				if not c["ai"]:
					_log("%s: %s — изучено: %s" % [date_string(), c["name"], tech_defs[id]["name"]])


func _ai_research(cid: int) -> void:
	var c: Dictionary = countries[cid]
	if c["queue"].size() >= research_slots(cid) + 1:
		return
	var warlike := not enemies_of(cid).is_empty()
	var best := ""
	var best_score := 1e12
	for id in tech_order:
		if c["techs"].has(id) or c["queue"].has(id) or not tech_reqs_met(cid, id):
			continue
		var t: Dictionary = tech_defs[id]
		var score: float = t["cost"]
		if warlike and ["weapons", "armor", "logistics", "medicine", "navy"].has(t["category"]):
			score *= 0.7
		if score < best_score:
			best_score = score
			best = id
	if best != "":
		_queue_tech(cid, best)


static func load_air_defs() -> Dictionary:
	var out := {}
	var f := FileAccess.open("res://data/aircraft.json", FileAccess.READ)
	if f == null:
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		for a in parsed.get("aircraft", []):
			out[a["id"]] = a
	return out


# ---------------------------------------------------------------- aviation

func wings_of(cid: int) -> Array:
	return wings.filter(func(w): return w["owner"] == cid)


func wings_at(p: int) -> Array:
	return wings.filter(func(w): return w["base"] == p)


func wing_by_id(wid: int) -> Dictionary:
	for w in wings:
		if w["id"] == wid:
			return w
	return {}


func air_capacity(p: int) -> int:
	var cap: int = 2 + provinces()[p]["industry"] / 2
	for c in countries:
		if c["capital"] == p and owner[p] == c["id"]:
			cap += 2
	return cap


func air_range(cid: int, type: String) -> int:
	return air_defs[type]["range"] + mod(cid, "air_range")


## Province -> hop distance for every province within `limit` hops (air and sea included).
func reach(from: int, limit: int) -> Dictionary:
	var provs := provinces()
	var dist := {from: 0}
	var queue: Array[int] = [from]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		if dist[cur] >= limit:
			continue
		for q in provs[cur]["neighbors"]:
			if not dist.has(q):
				dist[q] = dist[cur] + 1
				queue.append(q)
	return dist


func _build_wing(cid: int, type: String, base: int) -> Dictionary:
	var c: Dictionary = countries[cid]
	if not air_defs.has(type):
		return _fail("invalid aircraft")
	if base < 0 or base >= owner.size() or owner[base] != cid or not provinces()[base]["land"]:
		return _fail("invalid base")
	if wings_at(base).size() >= air_capacity(base):
		return _fail("airbase full")
	var d: Dictionary = air_defs[type]
	if c["treasury"] < d["cost"]:
		return _fail("not enough funds")
	if c["stock"]["steel"] < d["steel"]:
		return _fail("not enough steel")
	if c["manpower"] < d["manpower"]:
		return _fail("no manpower")
	c["treasury"] -= d["cost"]
	c["stock"]["steel"] -= d["steel"]
	c["manpower"] -= d["manpower"]
	wings.append({"id": next_wing_id, "owner": cid, "base": base, "type": type, "strength": WING_SIZE, "mission": "idle", "target": -1})
	next_wing_id += 1
	return {"ok": true}


func _set_mission(cid: int, w: Dictionary, mission: String, target: int) -> Dictionary:
	if mission == "idle":
		w["mission"] = "idle"
		w["target"] = -1
		return {"ok": true}
	var provs := provinces()
	if target < 0 or target >= owner.size():
		return _fail("invalid target")
	var need := {"air_superiority": "fighter", "bomb": "bomber", "cas": "attacker"}
	if not need.has(mission) or need[mission] != w["type"]:
		return _fail("wrong aircraft for mission")
	if mission != "air_superiority" and not provs[target]["land"]:
		return _fail("land target required")
	if mission == "bomb" and (owner[target] < 0 or not at_war(cid, owner[target])):
		return _fail("target not at war")
	if not reach(w["base"], air_range(cid, w["type"])).has(target):
		return _fail("out of range")
	w["mission"] = mission
	w["target"] = target
	return {"ok": true}


func _can_fly(w: Dictionary) -> bool:
	return not countries[w["owner"]]["short"].has("oil")


func air_oil(cid: int) -> int:
	var n := 0
	for w in wings:
		if w["owner"] == cid and w["mission"] != "idle":
			n += w["strength"] / 25
	return n


func _zone_add(zone: Dictionary, t: int, cid: int, w: Dictionary, weight: float) -> void:
	if not zone.has(t):
		zone[t] = {}
	if not zone[t].has(cid):
		zone[t][cid] = []
	zone[t][cid].append([w, weight])


func _zone_power(list: Array, cid: int) -> float:
	var p := 0.0
	for e in list:
		p += e[0]["strength"] * e[1]
	return p * (100 + mod(cid, "air_fighter_pct")) / 100.0


func _wing_losses(list: Array, amount: float) -> void:
	var total := 0.0
	for e in list:
		total += e[0]["strength"] * e[1]
	if total <= 0.0 or amount <= 0.0:
		return
	for e in list:
		e[0]["strength"] -= int(amount * e[0]["strength"] * e[1] / total)


func _foe_power(zp: Dictionary, cid: int) -> float:
	var foe := 0.0
	for o in zp:
		if at_war(cid, o):
			foe += zp[o]
	return foe


func _friend_power(zp: Dictionary, cid: int) -> float:
	var f := 0.0
	for o in zp:
		if o == cid or allied(cid, o):
			f += zp[o]
	return f


func _air() -> void:
	air_sup = {}
	air_cas = {}
	if wings.is_empty():
		return
	var provs := provinces()
	# bases that fell: relocate or lose the wing
	for w in wings:
		if owner[w["base"]] != w["owner"]:
			var cap_p: int = countries[w["owner"]]["capital"]
			if owner[cap_p] == w["owner"] and wings_at(cap_p).size() < air_capacity(cap_p):
				w["base"] = cap_p
				w["mission"] = "idle"
				w["target"] = -1
			else:
				w["strength"] = 0
	# 1. fighters: superiority missions and idle interceptors
	var zone := {}
	for w in wings:
		if w["type"] != "fighter" or w["strength"] <= 0:
			continue
		var cid: int = w["owner"]
		if w["mission"] == "air_superiority" and _can_fly(w):
			_zone_add(zone, w["target"], cid, w, 1.0)
		elif w["mission"] == "idle":
			_zone_add(zone, w["base"], cid, w, 0.5)
			for q in provs[w["base"]]["neighbors"]:
				_zone_add(zone, q, cid, w, 0.5)
	var zpow := {}
	var tkeys: Array = zone.keys()
	tkeys.sort()
	for t in tkeys:
		var per: Dictionary = zone[t]
		var cids: Array = per.keys()
		cids.sort()
		var zp := {}
		for cid in cids:
			zp[cid] = _zone_power(per[cid], cid)
		zpow[t] = zp
		air_sup[t] = {}
		for cid in cids:
			var foe := _foe_power(zp, cid)
			air_sup[t][cid] = zp[cid] / (zp[cid] + foe) if (zp[cid] + foe) > 0.0 else 0.5
		for cid in cids:
			var foe2 := _foe_power(zp, cid)
			if foe2 > 0.0:
				_wing_losses(per[cid], foe2 * 0.04 * rng.randf_range(0.8, 1.2))
	# 2. bombers and ground-attack aircraft
	for w in wings:
		if w["strength"] <= 0 or w["mission"] == "idle" or w["type"] == "fighter":
			continue
		var cid2: int = w["owner"]
		if not _can_fly(w):
			continue
		var t2: int = w["target"]
		var zp2: Dictionary = zpow.get(t2, {})
		var foe3 := _foe_power(zp2, cid2)
		if w["type"] == "bomber" and w["mission"] == "bomb":
			var o2 := owner[t2]
			if o2 < 0 or not at_war(cid2, o2):
				w["mission"] = "idle"
				w["target"] = -1
				continue
			var interception := foe3 / (foe3 + _friend_power(zp2, cid2) + 25.0)
			var dmg: float = w["strength"] * 0.8 * (1.0 - interception) * (100 + mod(cid2, "air_bomber_pct")) / 100.0
			damage[t2] = mini(100, damage[t2] + int(dmg / 10.0))
			for a in armies:
				if a["prov"] == t2 and at_war(cid2, a["owner"]):
					_hurt(a, int(dmg * 0.5))
			_wing_losses([[w, 1.0]], foe3 * 0.05 + (1.0 if day % 3 == 0 else 0.0))
		elif w["type"] == "attacker" and w["mission"] == "cas":
			if not air_cas.has(t2):
				air_cas[t2] = {}
			var cur: float = air_cas[t2].get(cid2, 0.0)
			air_cas[t2][cid2] = cur + w["strength"] * (100 + mod(cid2, "air_attacker_pct")) / 100.0
			_wing_losses([[w, 1.0]], foe3 * 0.03 + (1.0 if day % 4 == 0 else 0.0))
	# 3. replenishment, repair, cleanup
	for w in wings:
		if w["mission"] == "idle" and w["strength"] < WING_SIZE and day % 2 == 0:
			w["strength"] += 1
	for p in damage.size():
		if damage[p] > 0 and day % 2 == 0:
			damage[p] -= 1
	wings = wings.filter(func(w): return w["strength"] > 3)


func _ai_air(cid: int) -> void:
	var c: Dictionary = countries[cid]
	var provs := provinces()
	if day % 10 == 0 and c["treasury"] >= 250 and wings_of(cid).size() < 2 + country_provinces(cid).size() / 4:
		var kinds := ["fighter", "attacker", "bomber", "fighter"]
		var base: int = c["capital"]
		if owner[base] != cid or wings_at(base).size() >= air_capacity(base):
			base = -1
			for p in owner.size():
				if owner[p] == cid and provs[p]["land"] and wings_at(p).size() < air_capacity(p):
					base = p
					break
		if base >= 0:
			_build_wing(cid, kinds[(day / 10 + cid) % kinds.size()], base)
	if day % 5 != 0:
		return
	var enemies := enemies_of(cid)
	var hot := -1
	for a in armies_of(cid):
		for b in armies:
			if b["prov"] == a["prov"] and enemies.has(b["owner"]):
				hot = a["prov"]
				break
		if hot >= 0:
			break
	for w in wings_of(cid):
		var r := reach(w["base"], air_range(cid, w["type"]))
		match w["type"]:
			"fighter":
				if hot >= 0 and r.has(hot):
					_set_mission(cid, w, "air_superiority", hot)
				else:
					_set_mission(cid, w, "idle", -1)
			"attacker":
				if hot >= 0 and r.has(hot):
					_set_mission(cid, w, "cas", hot)
				else:
					_set_mission(cid, w, "idle", -1)
			"bomber":
				var best := -1
				var best_v := -1
				for t in r:
					if provs[t]["land"] and owner[t] >= 0 and enemies.has(owner[t]):
						var v: int = provs[t]["industry"] * 10 + armies_in(t).size()
						if v > best_v:
							best_v = v
							best = t
				if best >= 0:
					_set_mission(cid, w, "bomb", best)
				else:
					_set_mission(cid, w, "idle", -1)


# ---------------------------------------------------------------- politics

func _new_country(tag: String, cname: String, color: String, capital: int) -> Dictionary:
	var c := {
		"id": countries.size(), "tag": tag, "name": cname, "color": color,
		"capital": capital, "treasury": 120, "income": 0, "upkeep": 0,
		"ai": true, "alive": true, "last_peace": -100,
		"stock": _start_stock(), "prod": _zero_res(), "cons": _zero_res(), "short": [],
		"manpower": 200, "generals": [],
		"techs": [], "queue": [], "progress": {}, "mods": {}, "industry": 0,
		"ideology": "", "party_pop": {}, "stability": 50, "war_support": 40, "pp": 50,
		"laws": law_defaults.duplicate(), "done": {}, "timed": [], "crisis": 0,
		"ev_seen": {}, "pending": [],
		"intel": {"level": 1, "xp": 0, "net": {}, "counter": 0, "disinfo_until": -1},
	}
	countries.append(c)
	return c


func _load_politics() -> void:
	ideo_defs = {}
	ideo_order = []
	law_defs = {}
	law_defaults = {}
	event_defs = []
	decision_defs = []
	var f := FileAccess.open("res://data/politics.json", FileAccess.READ)
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			for i in parsed["ideologies"]:
				ideo_defs[i["id"]] = i
				ideo_order.append(i["id"])
			law_defs = parsed["laws"]
			law_defaults = parsed["defaults"]
	var f2 := FileAccess.open("res://data/events.json", FileAccess.READ)
	if f2 != null:
		var p2: Variant = JSON.parse_string(f2.get_as_text())
		if typeof(p2) == TYPE_DICTIONARY:
			event_defs = p2["events"]
	var f3 := FileAccess.open("res://data/decisions.json", FileAccess.READ)
	if f3 != null:
		var p3: Variant = JSON.parse_string(f3.get_as_text())
		if typeof(p3) == TYPE_DICTIONARY:
			decision_defs = p3["decisions"]


func _init_politics(cid: int) -> void:
	var c: Dictionary = countries[cid]
	var ruling: String = ideo_order[rng.randi_range(0, ideo_order.size() - 1)]
	c["ideology"] = ruling
	var ruling_pop := 45 + rng.randi_range(0, 15)
	var others: Array = ideo_order.filter(func(i): return i != ruling)
	var rem := 100 - ruling_pop
	var pop := {ruling: ruling_pop}
	for i in others.size():
		var left: int = others.size() - 1 - i
		var v: int = rem if left == 0 else rng.randi_range(1, maxi(1, rem - left))
		pop[others[i]] = v
		rem -= v
	c["party_pop"] = pop
	c["stability"] = _stability_target(c)
	c["war_support"] = _war_support_target(c)
	_recalc_mods(cid)


func law_option(category: String, id: String) -> Dictionary:
	for o in law_defs[category]["options"]:
		if o["id"] == id:
			return o
	return {}


func top_opposition(c: Dictionary) -> String:
	var best := ""
	var bv := -1
	for i in ideo_order:
		if i != c["ideology"] and c["party_pop"][i] > bv:
			bv = c["party_pop"][i]
			best = i
	return best


func _stability_target(c: Dictionary) -> int:
	var t: int = ideo_defs[c["ideology"]]["stability_base"]
	for cat in law_defs:
		t += law_option(cat, c["laws"][cat]).get("stability", 0)
	if c["short"].has("food"):
		t -= 10
	if c["short"].has("oil"):
		t -= 4
	if c["treasury"] <= 0:
		t -= 8
	var weariness := 0
	for e in enemies_of(c["id"]):
		weariness += (day - _war_start(c["id"], e)) / 15
	t -= mini(weariness, 15)
	return clampi(t, 0, 100)


func _war_support_target(c: Dictionary) -> int:
	var t := 40
	if not enemies_of(c["id"]).is_empty():
		t += 15
	for cat in law_defs:
		t += law_option(cat, c["laws"][cat]).get("war_support", 0)
	var age := 0
	for e in enemies_of(c["id"]):
		age = maxi(age, day - _war_start(c["id"], e))
	t -= mini(age / 12, 20)
	return clampi(t, 0, 100)


## Rebuild all modifiers: technologies + ideology + laws + timed effects + stability/war support.
func _recalc_mods(cid: int) -> void:
	var c: Dictionary = countries[cid]
	var m := {}
	for id in c["techs"]:
		for k in tech_defs[id]["effects"]:
			m[k] = m.get(k, 0) + int(tech_defs[id]["effects"][k])
	var add := func(d: Dictionary):
		for k in d:
			m[k] = m.get(k, 0) + int(d[k])
	if c["ideology"] != "":
		add.call(ideo_defs[c["ideology"]]["mods"])
		for cat in law_defs:
			add.call(law_option(cat, c["laws"][cat]).get("mods", {}))
	for t in c["timed"]:
		m[t["key"]] = m.get(t["key"], 0) + int(t["value"])
	var stab: int = c["stability"]
	if stab < 50:
		m["income_pct"] = m.get("income_pct", 0) - (50 - stab) / 3
	elif stab > 75:
		m["income_pct"] = m.get("income_pct", 0) + 3
	if stab < 25:
		m["atk_pct"] = m.get("atk_pct", 0) - 5
	if c["war_support"] < 30:
		m["atk_pct"] = m.get("atk_pct", 0) - 3
	elif c["war_support"] >= 70:
		m["atk_pct"] = m.get("atk_pct", 0) + 3
	c["mods"] = m


func _cond_ok(c: Dictionary, cond: Dictionary) -> bool:
	var v: Variant = cond.get("value", 0)
	match cond["type"]:
		"min_day": return day >= int(v)
		"stability_below": return c["stability"] < int(v)
		"stability_above": return c["stability"] > int(v)
		"war_support_below": return c["war_support"] < int(v)
		"war_support_above": return c["war_support"] > int(v)
		"at_war": return not enemies_of(c["id"]).is_empty()
		"not_at_war": return enemies_of(c["id"]).is_empty()
		"ideology": return c["ideology"] == v
		"not_ideology": return c["ideology"] != v
		"has_tech": return c["techs"].has(v)
		"treasury_above": return c["treasury"] > int(v)
		"treasury_below": return c["treasury"] < int(v)
		"short": return c["short"].has(v)
		"provinces_min": return country_provinces(c["id"]).size() >= int(v)
	return false


func _conds_ok(c: Dictionary, conds: Array) -> bool:
	for cd in conds:
		if not _cond_ok(c, cd):
			return false
	return true


func _shift_popularity(c: Dictionary, ideo: String, delta: int) -> void:
	var pop: Dictionary = c["party_pop"]
	var new_v := clampi(pop[ideo] + delta, 0, 95)
	var d: int = new_v - pop[ideo]
	pop[ideo] = new_v
	var guard := 0
	while d != 0 and guard < 200:
		guard += 1
		var pick := ""
		for i in ideo_order:
			if i == ideo:
				continue
			if d > 0 and pop[i] > 0 and (pick == "" or pop[i] > pop[pick]):
				pick = i
			elif d < 0 and pop[i] < 95 and (pick == "" or pop[i] < pop[pick]):
				pick = i
		if pick == "":
			break
		if d > 0:
			pop[pick] -= 1
			d -= 1
		else:
			pop[pick] += 1
			d += 1


func _apply_effect(c: Dictionary, ef: Dictionary) -> void:
	var v: int = int(ef.get("value", 0))
	match ef["type"]:
		"stability": c["stability"] = clampi(c["stability"] + v, 0, 100)
		"war_support": c["war_support"] = clampi(c["war_support"] + v, 0, 100)
		"treasury": c["treasury"] = maxi(0, c["treasury"] + v)
		"treasury_pct": c["treasury"] = maxi(0, c["treasury"] + c["treasury"] * v / 100)
		"stock": c["stock"][ef["res"]] = clampi(c["stock"][ef["res"]] + v, 0, STOCK_CAP)
		"manpower": c["manpower"] = maxi(0, c["manpower"] + v)
		"pp": c["pp"] = clampi(c["pp"] + v, 0, PP_CAP)
		"popularity": _shift_popularity(c, ef["ideology"], v)
		"popularity_ruling": _shift_popularity(c, c["ideology"], v)
		"modifier": c["timed"].append({"key": ef["key"], "value": v, "until": day + int(ef["days"])})
		"tech_progress":
			var done := false
			for id in c["queue"]:
				if tech_reqs_met(c["id"], id):
					c["progress"][id] = c["progress"].get(id, 0) + v
					done = true
					break
			if not done:
				c["pp"] = clampi(c["pp"] + v / 5, 0, PP_CAP)
		"army_exp":
			for a in armies:
				if a["owner"] == c["id"]:
					for d in a["div"]:
						d["exp"] = mini(d["exp"] + v, 50)


func event_def(id: String) -> Dictionary:
	for e in event_defs:
		if e["id"] == id:
			return e
	return {}


func _fire_event(c: Dictionary, e: Dictionary) -> void:
	c["ev_seen"][e["id"]] = day
	if c["ai"]:
		var total := 0
		for o in e["options"]:
			total += int(o["ai"])
		var r := rng.randi_range(0, maxi(total, 1) - 1)
		for o in e["options"]:
			r -= int(o["ai"])
			if r < 0:
				for ef in o["effects"]:
					_apply_effect(c, ef)
				return
	else:
		c["pending"].append({"uid": next_event_uid, "event": e["id"], "day": day})
		next_event_uid += 1
		_log("%s: событие — %s" % [date_string(), e["title"]])


func _resolve_event(c: Dictionary, uid: int, option: int) -> Dictionary:
	for p in c["pending"]:
		if p["uid"] == uid:
			var e := event_def(p["event"])
			if option < 0 or option >= e["options"].size():
				return _fail("invalid option")
			for ef in e["options"][option]["effects"]:
				_apply_effect(c, ef)
			c["pending"].erase(p)
			return {"ok": true}
	return _fail("no such event")


func _events(c: Dictionary) -> void:
	for e in event_defs:
		if e["once"] and c["ev_seen"].has(e["id"]):
			continue
		if day - c["ev_seen"].get(e["id"], -99999) < int(e["cooldown"]):
			continue
		if not _conds_ok(c, e["conditions"]):
			continue
		if rng.randf() >= float(e["chance"]):
			continue
		_fire_event(c, e)


func _change_government(c: Dictionary, new_ideo: String, why: String) -> void:
	_log("%s: %s — смена власти (%s): %s" % [date_string(), c["name"], why, ideo_defs[new_ideo]["name"]])
	c["ideology"] = new_ideo
	c["stability"] = clampi((c["stability"] + 50) / 2 if why == "выборы" else 40, 0, 100)
	if why != "выборы":
		for a in armies:
			if a["owner"] == c["id"]:
				_hurt(a, a["strength"] / 10)


func _politics() -> void:
	for c in countries:
		if not c["alive"]:
			continue
		var cid: int = c["id"]
		c["pp"] = mini(c["pp"] + 1, PP_CAP)
		var live: Array = c["timed"].filter(func(t): return t["until"] > day)
		c["timed"] = live
		if day % 2 == 0:
			var tg := _stability_target(c)
			c["stability"] += signi(tg - c["stability"])
			var wt := _war_support_target(c)
			c["war_support"] += signi(wt - c["war_support"])
		if day % 5 == 0:
			if c["stability"] < 45:
				var opp := top_opposition(c)
				_shift_popularity(c, c["ideology"], -1)
				_shift_popularity(c, opp, 1)
			elif c["stability"] > 65:
				_shift_popularity(c, c["ideology"], 1)
		# elections / coups
		var ideo: Dictionary = ideo_defs[c["ideology"]]
		if ideo["elections"] and day >= 100 and (day - 100 - 40 * cid) % 365 == 0:
			var winner: String = c["ideology"]
			for i in ideo_order:
				if c["party_pop"][i] > c["party_pop"][winner]:
					winner = i
			if winner != c["ideology"]:
				_change_government(c, winner, "выборы")
			else:
				c["stability"] = mini(100, c["stability"] + 3)
		elif not ideo["elections"] and c["stability"] < 20 and day % 10 == 0 and rng.randf() < 0.3:
			_change_government(c, top_opposition(c), "переворот")
		if c["stability"] < 10:
			c["crisis"] += 1
		else:
			c["crisis"] = 0
		if c["crisis"] >= 20:
			c["crisis"] = 0
			if country_provinces(cid).size() >= 6:
				_civil_war(cid)
			else:
				_change_government(c, top_opposition(c), "революция")
		# unanswered events resolve themselves
		for p in c["pending"].duplicate():
			if day - p["day"] > 20:
				_resolve_event(c, p["uid"], 0)
		_recalc_mods(cid)
		_events(c)


func _civil_war(cid: int) -> void:
	var c: Dictionary = countries[cid]
	var provs := provinces()
	var own := country_provinces(cid)
	var dist := {c["capital"]: 0}
	var queue: Array[int] = [c["capital"]]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for q in provs[cur]["land_neighbors"]:
			if owner[q] == cid and not dist.has(q):
				dist[q] = dist[cur] + 1
				queue.append(q)
	own.sort_custom(func(a, b): return dist.get(a, 99) > dist.get(b, 99) or (dist.get(a, 99) == dist.get(b, 99) and a < b))
	var n := maxi(3, own.size() * 2 / 5)
	var rebel_ps: Array = own.slice(0, n)
	var cap: int = rebel_ps[0]
	for p in rebel_ps:
		if provs[p]["pop"] > provs[cap]["pop"]:
			cap = p
	var color := "#" + Color.from_hsv(rng.randf(), 0.5, 0.8).to_html(false)
	var rc := _new_country("RB%d" % countries.size(), "Повстанцы (%s)" % c["name"], color, cap)
	var rid: int = rc["id"]
	var opp := top_opposition(c)
	rc["ideology"] = opp
	rc["party_pop"] = {}
	for i in ideo_order:
		rc["party_pop"][i] = 10 if i != opp else 100 - 10 * (ideo_order.size() - 1)
	rc["techs"] = c["techs"].duplicate()
	rc["treasury"] = c["treasury"] * 35 / 100
	c["treasury"] -= rc["treasury"]
	rc["stability"] = 40
	rc["war_support"] = 55
	for p in rebel_ps:
		owner[p] = rid
		dirty_provinces.append(p)
	for a in armies:
		if a["owner"] == cid and rebel_ps.has(a["prov"]):
			_set_general(a, -1)
			a["owner"] = rid
	for w in wings:
		if w["owner"] == cid and rebel_ps.has(w["base"]):
			w["owner"] = rid
	_spawn_army(rid, cap)
	_spawn_army(rid, cap)
	for _g in 2:
		_new_general(rid)
	var mine := armies_of(rid)
	for k in mini(2, mine.size()):
		_set_general(mine[k], rc["generals"][k]["id"])
	rc["stock"]["steel"] = 100
	wars.append({"a": rid, "b": cid, "start": day})
	c["stability"] = 35
	_recalc_mods(rid)
	_recalc_mods(cid)
	_log("%s: гражданская война в государстве %s — образованы %s" % [date_string(), c["name"], rc["name"]])


func _ai_politics(cid: int) -> void:
	var c: Dictionary = countries[cid]
	var at_war_now := not enemies_of(cid).is_empty()
	# laws
	var want_econ: String = "war" if at_war_now else ("partial" if c["stability"] > 55 else "civilian")
	var want_cons: String = "extended" if at_war_now else "limited"
	for pair in [["economy", want_econ], ["conscription", want_cons]]:
		var cat: String = pair[0]
		if c["laws"][cat] != pair[1] and c["pp"] >= int(law_option(cat, pair[1]).get("cost", 0)) + 40:
			_set_law(c, cat, pair[1])
			break
	# one decision per call
	for dd in decision_defs:
		if dd["ai"] <= 0 or not _conds_ok(c, dd["ai_conditions"]):
			continue
		if _decision_error(c, dd) == "":
			_run_decision(c, dd)
			break


func _set_law(c: Dictionary, cat: String, id: String) -> void:
	c["pp"] -= int(law_option(cat, id).get("cost", 0))
	c["laws"][cat] = id
	_recalc_mods(c["id"])


func decision_def(id: String) -> Dictionary:
	for d in decision_defs:
		if d["id"] == id:
			return d
	return {}


func _decision_error(c: Dictionary, dd: Dictionary) -> String:
	if day - c["done"].get(dd["id"], -99999) < int(dd["cooldown"]):
		return "on cooldown"
	if not _conds_ok(c, dd["requires"]):
		return "requirements not met"
	var cost: Dictionary = dd["cost"]
	if c["pp"] < cost.get("pp", 0):
		return "not enough influence"
	if c["treasury"] < cost.get("treasury", 0):
		return "not enough funds"
	return ""


func _run_decision(c: Dictionary, dd: Dictionary) -> void:
	var cost: Dictionary = dd["cost"]
	c["pp"] -= int(cost.get("pp", 0))
	c["treasury"] -= int(cost.get("treasury", 0))
	for ef in dd["effects"]:
		_apply_effect(c, ef)
	c["done"][dd["id"]] = day
	_log("%s: %s — %s" % [date_string(), c["name"], dd["name"]])


# ------------------------------------------------------------- intelligence

func _load_intel() -> void:
	intel_defs = {}
	var f := FileAccess.open("res://data/intel.json", FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		for o in parsed["operations"]:
			intel_defs[o["id"]] = o


func net_of_agent(viewer: int, target: int) -> int:
	return countries[viewer]["intel"]["net"].get(target, 0)


func intel_slots(cid: int) -> int:
	return 1 + (countries[cid]["intel"]["level"] + 1) / 2


func ops_of(cid: int) -> Array:
	return ops.filter(func(o): return o["owner"] == cid)


## Percent chance that an operation of `type` by `cid` against `target` succeeds.
func op_chance(cid: int, target: int, type: String) -> int:
	var lvl: int = countries[cid]["intel"]["level"]
	if type == "counter_intel":
		return 100
	var counter: int = countries[target]["intel"]["counter"]
	if type == "build_network":
		return clampi(60 + 5 * lvl - counter / 3, 10, 95)
	return clampi(45 + 5 * lvl + net_of_agent(cid, target) / 4 - counter / 2, 10, 90)


func _start_op(cid: int, type: String, target: int) -> Dictionary:
	if not intel_defs.has(type):
		return _fail("invalid operation")
	var d: Dictionary = intel_defs[type]
	var c: Dictionary = countries[cid]
	if type == "counter_intel":
		target = cid
	elif target < 0 or target >= countries.size() or target == cid or not countries[target]["alive"]:
		return _fail("invalid target")
	if ops_of(cid).size() >= intel_slots(cid):
		return _fail("no free agents")
	if net_of_agent(cid, target) < int(d["min_network"]) and type != "counter_intel":
		return _fail("network too weak")
	if c["treasury"] < int(d["cost"]):
		return _fail("not enough funds")
	for o in ops:
		if o["owner"] == cid and o["target"] == target and o["type"] == type:
			return _fail("already running")
	c["treasury"] -= int(d["cost"])
	ops.append({"id": next_op_id, "owner": cid, "target": target, "type": type, "left": int(d["duration"]), "total": int(d["duration"])})
	next_op_id += 1
	return {"ok": true}


func _gain_xp(cid: int, amount: int) -> void:
	var it: Dictionary = countries[cid]["intel"]
	it["xp"] += amount
	var lvl := mini(5, 1 + it["xp"] / 100)
	if lvl > it["level"]:
		it["level"] = lvl
		_log("%s: разведка %s достигла уровня %d" % [date_string(), countries[cid]["name"], lvl])


## Resolve one finished operation. `force` (-1 random, 0 fail, 1 success) is for tests.
func _resolve_op(op: Dictionary, force: int = -1) -> void:
	var cid: int = op["owner"]
	var tid: int = op["target"]
	var c: Dictionary = countries[cid]
	var t: Dictionary = countries[tid]
	var type: String = op["type"]
	var ok: bool
	if force >= 0:
		ok = force == 1
	else:
		ok = rng.randi_range(1, 100) <= op_chance(cid, tid, type)
	if not ok:
		c["intel"]["net"][tid] = maxi(0, net_of_agent(cid, tid) - 25)
		_gain_xp(cid, 4)
		if not t["ai"] or not c["ai"]:
			_log("%s: операция «%s» против %s провалена, агентура раскрыта" % [date_string(), intel_defs[type]["name"], t["name"]])
		return
	_gain_xp(cid, 15)
	match type:
		"build_network":
			c["intel"]["net"][tid] = mini(MAX_NET, net_of_agent(cid, tid) + 25)
		"sabotage":
			var best := -1
			for p in owner.size():
				if owner[p] == tid and (best < 0 or provinces()[p]["industry"] > provinces()[best]["industry"]):
					best = p
			if best >= 0:
				damage[best] = mini(100, damage[best] + 35)
		"destabilize":
			t["stability"] = clampi(t["stability"] - 8, 0, 100)
			_shift_popularity(t, t["ideology"], -2)
			_shift_popularity(t, top_opposition(t), 2)
		"steal_tech":
			if t["techs"].size() > c["techs"].size():
				_apply_effect(c, {"type": "tech_progress", "value": 120})
		"disinformation":
			c["intel"]["disinfo_until"] = day + 60
		"counter_intel":
			c["intel"]["counter"] = mini(80, c["intel"]["counter"] + 20)
	# the target may notice a successful operation
	if type != "counter_intel" and rng.randi_range(1, 100) <= t["intel"]["counter"] / 2:
		c["intel"]["net"][tid] = maxi(0, net_of_agent(cid, tid) - 10)
		if not t["ai"]:
			_log("%s: контрразведка %s вскрыла операцию против нас («%s»)" % [date_string(), t["name"], intel_defs[type]["name"]])


func _intel() -> void:
	var live: Array = []
	for op in ops:
		if not countries[op["owner"]]["alive"] or not countries[op["target"]]["alive"]:
			continue
		op["left"] -= 1
		if op["left"] <= 0:
			_resolve_op(op)
		else:
			live.append(op)
	ops = live
	if day % 10 == 0:
		for c in countries:
			if not c["alive"]:
				continue
			var net: Dictionary = c["intel"]["net"]
			for tid in net.keys():
				net[tid] = net[tid] - 1 - countries[tid]["intel"]["counter"] / 20
				if net[tid] <= 0 or not countries[tid]["alive"]:
					net.erase(tid)
	if day % 5 == 0:
		for c in countries:
			if c["alive"] and c["intel"]["counter"] > 0:
				c["intel"]["counter"] -= 1


## Can `viewer` see this army's real strength? (own/allied, agent network, or next to their territory/forces)
func intel_visible(viewer: int, a: Dictionary) -> bool:
	var o: int = a["owner"]
	if o == viewer or allied(viewer, o) or net_of_agent(viewer, o) >= 25:
		return true
	var provs := provinces()
	var p: int = a["prov"]
	if owner[p] == viewer:
		return true
	for q in provs[p]["neighbors"]:
		if owner[q] == viewer:
			return true
	for b in armies:
		if b["owner"] == viewer and (b["prov"] == p or provs[p]["neighbors"].has(b["prov"])):
			return true
	return false


## Strength as `viewer` perceives it: -1 = unknown; disinformation distorts it.
func perceived_strength(viewer: int, a: Dictionary) -> int:
	if not intel_visible(viewer, a):
		return -1
	var o: int = a["owner"]
	var s: int = a["strength"]
	if o != viewer and not allied(viewer, o) and countries[o]["intel"]["disinfo_until"] > day and net_of_agent(viewer, o) < 60:
		s = s * (60 + (a["id"] * 37) % 81) / 100
	return s


func _ai_intel(cid: int) -> void:
	var c: Dictionary = countries[cid]
	if c["treasury"] < 150 or ops_of(cid).size() >= intel_slots(cid):
		return
	if c["intel"]["counter"] < 15 and _start_op(cid, "counter_intel", cid)["ok"]:
		return
	var targets := enemies_of(cid)
	for n in neighbor_countries(cid):
		if not targets.has(n):
			targets.append(n)
	for t in targets:
		var net := net_of_agent(cid, t)
		var order: Array = ["build_network"]
		if net >= 20:
			order = ["disinformation", "sabotage", "destabilize", "steal_tech", "build_network"]
		if enemies_of(cid).has(t) and net >= 30:
			order = ["sabotage", "destabilize", "steal_tech", "build_network"]
		for type in order:
			if type == "build_network" and net >= 75:
				continue
			if _start_op(cid, type, t)["ok"]:
				return


static func load_unit_defs() -> Dictionary:
	var out := {}
	var f := FileAccess.open("res://data/units.json", FileAccess.READ)
	if f == null:
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		for u in parsed.get("units", []):
			out[u["id"]] = u
	return out


static func load_name_pool() -> Dictionary:
	var f := FileAccess.open("res://data/generals.json", FileAccess.READ)
	if f == null:
		return {"first": ["Генерал"], "last": ["Безымянный"]}
	return JSON.parse_string(f.get_as_text())


static func load_resource_defs() -> Array:
	var f := FileAccess.open("res://data/resources.json", FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	return parsed.get("resources", [])


static func load_country_defs() -> Array:
	var f := FileAccess.open("res://data/countries.json", FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	return parsed.get("countries", [])


# ---------------------------------------------------------------- queries

func provinces() -> Array:
	return world["provinces"]


func country_provinces(cid: int) -> Array[int]:
	var out: Array[int] = []
	for p in owner.size():
		if owner[p] == cid:
			out.append(p)
	return out


func armies_in(prov: int) -> Array:
	var out: Array = []
	for a in armies:
		if a["prov"] == prov:
			out.append(a)
	return out


func army_by_id(aid: int) -> Dictionary:
	for a in armies:
		if a["id"] == aid:
			return a
	return {}


func at_war(a: int, b: int) -> bool:
	for w in wars:
		if (w["a"] == a and w["b"] == b) or (w["a"] == b and w["b"] == a):
			return true
	return false


func enemies_of(cid: int) -> Array[int]:
	var out: Array[int] = []
	for w in wars:
		if w["a"] == cid:
			out.append(w["b"])
		elif w["b"] == cid:
			out.append(w["a"])
	return out


func neighbor_countries(cid: int) -> Array[int]:
	var out: Array[int] = []
	var provs := provinces()
	for p in owner.size():
		if owner[p] != cid:
			continue
		for q in provs[p]["land_neighbors"]:
			var o := owner[q]
			if o >= 0 and o != cid and not out.has(o):
				out.append(o)
	out.sort()
	return out


func allied(a: int, b: int) -> bool:
	for al in alliances:
		if (al["a"] == a and al["b"] == b) or (al["a"] == b and al["b"] == a):
			return true
	return false


func allies_of(cid: int) -> Array[int]:
	var out: Array[int] = []
	for al in alliances:
		if al["a"] == cid:
			out.append(al["b"])
		elif al["b"] == cid:
			out.append(al["a"])
	return out


func is_coastal(p: int) -> bool:
	var provs := provinces()
	if not provs[p]["land"]:
		return false
	for q in provs[p]["neighbors"]:
		if not provs[q]["land"]:
			return true
	return false


func sea_next_to(p: int) -> int:
	for q in provinces()[p]["neighbors"]:
		if not provinces()[q]["land"]:
			return q
	return -1


## Preferred port of a country: capital if coastal, else the first coastal province it owns.
func port_of(cid: int) -> int:
	var cap: int = countries[cid]["capital"]
	if owner[cap] == cid and is_coastal(cap):
		return cap
	for p in owner.size():
		if owner[p] == cid and is_coastal(p):
			return p
	return -1


func fleets_of(cid: int) -> Array:
	var out: Array = []
	for f in fleets:
		if f["owner"] == cid:
			out.append(f)
	return out


func fleet_by_id(fid: int) -> Dictionary:
	for f in fleets:
		if f["id"] == fid:
			return f
	return {}


func fleets_in(prov: int) -> Array:
	var out: Array = []
	for f in fleets:
		if f["prov"] == prov:
			out.append(f)
	return out


## Armies currently at sea or ordered across it.
func sea_load(cid: int) -> int:
	var provs := provinces()
	var n := 0
	for a in armies:
		if a["owner"] != cid:
			continue
		var wet: bool = not provs[a["prov"]]["land"]
		for q in a["path"]:
			if not provs[q]["land"]:
				wet = true
		if wet:
			n += 1
	return n


func transport_free(cid: int) -> bool:
	return sea_load(cid) < fleets_of(cid).size() * TRANSPORT_PER_FLEET


func can_reach_overseas(cid: int, target: int) -> bool:
	if fleets_of(cid).is_empty():
		return false
	for p in owner.size():
		if owner[p] == target and is_coastal(p):
			return true
	return false


func can_declare_war(cid: int, target: int) -> bool:
	return neighbor_countries(cid).has(target) or can_reach_overseas(cid, target)


func army_strength(cid: int) -> int:
	var s := 0
	for a in armies:
		if a["owner"] == cid:
			s += a["strength"]
	return s


func alive_count() -> int:
	var n := 0
	for c in countries:
		if c["alive"]:
			n += 1
	return n


func date_string() -> String:
	var unix := Time.get_unix_time_from_datetime_string("1936-01-01T00:00:00") + day * 86400
	return Time.get_date_string_from_unix_time(unix)


# --------------------------------------------------------------- commands

## Validated entry point for every player/network action.
func apply_command(cmd: Dictionary) -> Dictionary:
	var res := _validate_and_run(cmd)
	if res["ok"]:
		command_log.append({"day": day, "cmd": cmd})
	return res


func _validate_and_run(cmd: Dictionary) -> Dictionary:
	var type: String = cmd.get("type", "")
	var cid: int = cmd.get("country", -1)
	if cid < 0 or cid >= countries.size() or not countries[cid]["alive"]:
		return _fail("invalid country")
	match type:
		"recruit":
			var c: Dictionary = countries[cid]
			if c["treasury"] < ARMY_COST:
				return _fail("not enough funds")
			if c["stock"]["steel"] < ARMY_STEEL:
				return _fail("not enough steel")
			if owner[c["capital"]] != cid:
				return _fail("capital lost")
			if c["manpower"] < 2 * unit_defs["infantry"]["manpower"]:
				return _fail("no manpower")
			c["treasury"] -= ARMY_COST
			c["stock"]["steel"] -= ARMY_STEEL
			c["manpower"] -= 2 * unit_defs["infantry"]["manpower"]
			_spawn_army(cid, c["capital"])
			return {"ok": true}
		"intel_op":
			return _start_op(cid, cmd.get("op", ""), cmd.get("target", -1))
		"cancel_op":
			var oid: int = cmd.get("op_id", -1)
			for o in ops:
				if o["id"] == oid and o["owner"] == cid:
					ops = ops.filter(func(x): return x["id"] != oid)
					return {"ok": true}
			return _fail("no such operation")
		"set_law":
			var cat: String = cmd.get("category", "")
			var lid: String = cmd.get("law", "")
			if not law_defs.has(cat) or law_option(cat, lid).is_empty():
				return _fail("invalid law")
			if countries[cid]["laws"][cat] == lid:
				return _fail("already in force")
			if countries[cid]["pp"] < int(law_option(cat, lid).get("cost", 0)):
				return _fail("not enough influence")
			_set_law(countries[cid], cat, lid)
			return {"ok": true}
		"decision":
			var dd := decision_def(cmd.get("id", ""))
			if dd.is_empty():
				return _fail("invalid decision")
			var err := _decision_error(countries[cid], dd)
			if err != "":
				return _fail(err)
			_run_decision(countries[cid], dd)
			return {"ok": true}
		"event_choice":
			return _resolve_event(countries[cid], cmd.get("uid", -1), cmd.get("option", -1))
		"build_wing":
			return _build_wing(cid, cmd.get("type_air", ""), cmd.get("base", -1))
		"air_mission":
			var aw := wing_by_id(cmd.get("wing", -1))
			if aw.is_empty() or aw["owner"] != cid:
				return _fail("invalid wing")
			return _set_mission(cid, aw, cmd.get("mission", ""), cmd.get("target", -1))
		"rebase":
			var rw := wing_by_id(cmd.get("wing", -1))
			var nb: int = cmd.get("base", -1)
			if rw.is_empty() or rw["owner"] != cid:
				return _fail("invalid wing")
			if nb < 0 or nb >= owner.size() or owner[nb] != cid or not provinces()[nb]["land"]:
				return _fail("invalid base")
			if wings_at(nb).size() >= air_capacity(nb):
				return _fail("airbase full")
			if not reach(rw["base"], air_range(cid, rw["type"]) * 2).has(nb):
				return _fail("out of range")
			rw["base"] = nb
			rw["mission"] = "idle"
			rw["target"] = -1
			return {"ok": true}
		"research":
			return _queue_tech(cid, cmd.get("tech", ""))
		"unqueue_tech":
			var ut2: String = cmd.get("tech", "")
			if not countries[cid]["queue"].has(ut2):
				return _fail("not queued")
			countries[cid]["queue"].erase(ut2)
			# drop queued techs that depended on it
			var changed := true
			while changed:
				changed = false
				for q in countries[cid]["queue"].duplicate():
					for r in tech_defs[q]["requires"]:
						if not countries[cid]["techs"].has(r) and not countries[cid]["queue"].has(r):
							countries[cid]["queue"].erase(q)
							changed = true
							break
			return {"ok": true}
		"train_division":
			var ut: String = cmd.get("unit", "")
			if not unit_defs.has(ut):
				return _fail("invalid unit")
			return _train(cid, ut, cmd.get("army", -1))
		"merge_armies":
			var ma := army_by_id(cmd.get("army", -1))
			var mb := army_by_id(cmd.get("other", -1))
			if ma.is_empty() or mb.is_empty() or ma["owner"] != cid or mb["owner"] != cid or ma["id"] == mb["id"]:
				return _fail("invalid army")
			if ma["prov"] != mb["prov"]:
				return _fail("not in same province")
			if ma["div"].size() + mb["div"].size() > MAX_DIV:
				return _fail("army full")
			_merge(ma, mb)
			return {"ok": true}
		"split_army":
			var sa := army_by_id(cmd.get("army", -1))
			var n: int = cmd.get("count", 1)
			if sa.is_empty() or sa["owner"] != cid:
				return _fail("invalid army")
			if n < 1 or n >= sa["div"].size():
				return _fail("invalid split")
			var moved: Array = sa["div"].slice(sa["div"].size() - n)
			sa["div"] = sa["div"].slice(0, sa["div"].size() - n)
			_sync(sa)
			_add_army(cid, sa["prov"], moved)
			return {"ok": true}
		"assign_general":
			var ga := army_by_id(cmd.get("army", -1))
			if ga.is_empty() or ga["owner"] != cid:
				return _fail("invalid army")
			var gid: int = cmd.get("general", -1)
			if gid >= 0 and _general(cid, gid).is_empty():
				return _fail("invalid general")
			_set_general(ga, gid)
			return {"ok": true}
		"declare_war":
			var target: int = cmd.get("target", -1)
			if target < 0 or target >= countries.size() or target == cid or not countries[target]["alive"]:
				return _fail("invalid target")
			if at_war(cid, target):
				return _fail("already at war")
			if allied(cid, target):
				return _fail("ally")
			if not can_declare_war(cid, target):
				return _fail("no common border")
			_declare_war(cid, target)
			return {"ok": true}
		"build_fleet":
			var c2: Dictionary = countries[cid]
			var port := port_of(cid)
			if port < 0:
				return _fail("no port")
			if c2["treasury"] < FLEET_COST:
				return _fail("not enough funds")
			if c2["stock"]["steel"] < FLEET_STEEL:
				return _fail("not enough steel")
			c2["treasury"] -= FLEET_COST
			c2["stock"]["steel"] -= FLEET_STEEL
			_spawn_fleet(cid, sea_next_to(port))
			return {"ok": true}
		"propose_trade":
			var seller: int = cmd.get("target", -1)
			var res: String = cmd.get("res", "")
			var amount: int = cmd.get("amount", 0)
			if seller < 0 or seller >= countries.size() or seller == cid or not countries[seller]["alive"]:
				return _fail("invalid target")
			if not countries[cid]["stock"].has(res) or amount <= 0 or amount > 50:
				return _fail("invalid deal")
			if not countries[seller]["ai"]:
				return _fail("human target")
			return _try_trade(cid, seller, res, amount)
		"cancel_trade":
			var tid: int = cmd.get("deal", -1)
			for t in trades:
				if t["id"] == tid and (t["buyer"] == cid or t["seller"] == cid):
					trades = trades.filter(func(x): return x["id"] != tid)
					return {"ok": true}
			return _fail("no such deal")
		"embargo":
			var et: int = cmd.get("target", -1)
			if et < 0 or et >= countries.size() or et == cid:
				return _fail("invalid target")
			if _embargoed(cid, et):
				return _fail("already embargoed")
			embargoes.append({"a": cid, "b": et})
			trades = trades.filter(func(x): return not ((x["buyer"] == cid and x["seller"] == et) or (x["buyer"] == et and x["seller"] == cid)))
			_log("%s: %s вводит эмбарго против %s" % [date_string(), countries[cid]["name"], countries[et]["name"]])
			return {"ok": true}
		"lift_embargo":
			var lt: int = cmd.get("target", -1)
			var before := embargoes.size()
			embargoes = embargoes.filter(func(e): return not (e["a"] == cid and e["b"] == lt))
			return {"ok": embargoes.size() != before, "reason": "no embargo"}
		"move_fleet":
			var f := fleet_by_id(cmd.get("fleet", -1))
			if f.is_empty() or f["owner"] != cid:
				return _fail("invalid fleet")
			var sea: int = cmd.get("target", -1)
			if sea < 0 or sea >= owner.size() or provinces()[sea]["land"]:
				return _fail("invalid destination")
			var sp := _sea_path(f["prov"], sea)
			if sp.is_empty() and f["prov"] != sea:
				return _fail("no route")
			f["path"] = sp
			f["move"] = 0
			return {"ok": true}
		"propose_alliance":
			var t2: int = cmd.get("target", -1)
			if t2 < 0 or t2 >= countries.size() or t2 == cid or not countries[t2]["alive"]:
				return _fail("invalid target")
			if allied(cid, t2) or at_war(cid, t2):
				return _fail("not possible")
			if not countries[t2]["ai"]:
				return _fail("human target")
			if not _ai_accepts_alliance(t2, cid):
				return _fail("refused")
			alliances.append({"a": cid, "b": t2})
			_log("%s: союз %s — %s" % [date_string(), countries[cid]["name"], countries[t2]["name"]])
			return {"ok": true}
		"break_alliance":
			var t3: int = cmd.get("target", -1)
			if not allied(cid, t3):
				return _fail("not allied")
			_break_alliance(cid, t3)
			return {"ok": true}
		"propose_peace":
			var t4: int = cmd.get("target", -1)
			if t4 < 0 or t4 >= countries.size() or not at_war(cid, t4):
				return _fail("not at war")
			if not countries[t4]["ai"]:
				return _fail("human target")
			if not _ai_accepts_peace(t4, cid):
				return _fail("refused")
			_end_war(cid, t4, "мирный договор")
			return {"ok": true}
		"move_army":
			var a := army_by_id(cmd.get("army", -1))
			if a.is_empty() or a["owner"] != cid:
				return _fail("invalid army")
			var dest: int = cmd.get("target", -1)
			if dest < 0 or dest >= owner.size() or not provinces()[dest]["land"]:
				return _fail("invalid destination")
			var path := _find_path(a["prov"], cid, dest)
			if path.is_empty() and a["prov"] != dest:
				return _fail("no route")
			var wet := false
			for q in path:
				if not provinces()[q]["land"]:
					wet = true
			if wet and sea_load(cid) - (1 if _army_is_wet(a) else 0) >= fleets_of(cid).size() * TRANSPORT_PER_FLEET:
				return _fail("no transport")
			a["path"] = path
			a["move"] = 0
			return {"ok": true}
		_:
			return _fail("unknown command")


func _army_is_wet(a: Dictionary) -> bool:
	if not provinces()[a["prov"]]["land"]:
		return true
	for q in a["path"]:
		if not provinces()[q]["land"]:
			return true
	return false


func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


# --------------------------------------------------------------- time step

func tick_day() -> void:
	day += 1
	_economy()
	_trade()
	_resources()
	_politics()
	_intel()
	_research()
	_move_armies()
	_move_fleets()
	_supply()
	_air()
	_battles()
	_occupation()
	if day % 5 == 0:
		_ai()
	_peace()
	_eliminate()
	if day % 120 == 0:
		for c in countries:
			if c["alive"] and c["generals"].size() < MAX_GENERALS:
				_new_general(c["id"])


func _economy() -> void:
	var provs := provinces()
	for c in countries:
		if not c["alive"]:
			continue
		c["income"] = 0
		c["upkeep"] = 0
	for p in owner.size():
		var o := owner[p]
		if o >= 0 and countries[o]["alive"]:
			countries[o]["income"] += provs[p]["pop"] * provs[p]["industry"] * (100 - damage[p]) / 10000
	for a in armies:
		countries[a["owner"]]["upkeep"] += a["strength"] / 200
	for f in fleets:
		countries[f["owner"]]["upkeep"] += f["strength"] / 150
	for c in countries:
		if c["alive"]:
			c["income"] = c["income"] * (100 + mod(c["id"], "income_pct")) / 100
			c["upkeep"] = c["upkeep"] * (100 + mod(c["id"], "upkeep_pct")) / 100
	for c in countries:
		if c["alive"]:
			c["treasury"] += c["income"] - c["upkeep"]
			if c["treasury"] < 0:
				c["treasury"] = 0
				# unpaid armies lose strength
				for a in armies:
					if a["owner"] == c["id"]:
						_hurt(a, a["strength"] / 50)


func _embargoed(a: int, b: int) -> bool:
	for e in embargoes:
		if (e["a"] == a and e["b"] == b) or (e["a"] == b and e["b"] == a):
			return true
	return false


func can_trade(a: int, b: int) -> bool:
	if a == b or at_war(a, b) or _embargoed(a, b):
		return false
	return neighbor_countries(a).has(b) or (port_of(a) >= 0 and port_of(b) >= 0)


func _sell_committed(seller: int, res: String) -> int:
	var n := 0
	for t in trades:
		if t["seller"] == seller and t["res"] == res:
			n += t["amount"]
	return n


func trades_of(cid: int) -> Array:
	return trades.filter(func(t): return t["buyer"] == cid or t["seller"] == cid)


func _try_trade(buyer: int, seller: int, res: String, amount: int) -> Dictionary:
	if not can_trade(buyer, seller):
		return _fail("no trade route")
	var bc: Dictionary = countries[buyer]
	var sc: Dictionary = countries[seller]
	var buying := 0
	for t in trades:
		if t["buyer"] == buyer:
			buying += 1
	if buying >= MAX_DEALS:
		return _fail("too many deals")
	var price := int(ceil(price_of(res) * 1.2))
	if bc["treasury"] < price * amount * 10:
		return _fail("cannot afford")
	var net: int = sc["prod"][res] - sc["cons"][res]
	var free: int = net - _sell_committed(seller, res)
	if free < amount and sc["stock"][res] < 300:
		return _fail("seller has no surplus")
	trades.append({"id": next_trade_id, "seller": seller, "buyer": buyer, "res": res, "amount": amount, "price": price, "fails": 0})
	next_trade_id += 1
	_log("%s: торговля — %s покупает %s (%d/день) у %s" % [date_string(), bc["name"], res_name(res).to_lower(), amount, sc["name"]])
	return {"ok": true}


func _trade() -> void:
	var kept: Array = []
	for t in trades:
		var b: Dictionary = countries[t["buyer"]]
		var s: Dictionary = countries[t["seller"]]
		if not b["alive"] or not s["alive"] or at_war(t["buyer"], t["seller"]) or _embargoed(t["buyer"], t["seller"]):
			continue
		var cost: int = t["amount"] * t["price"]
		if s["stock"][t["res"]] >= t["amount"] and b["treasury"] >= cost:
			s["stock"][t["res"]] -= t["amount"]
			b["stock"][t["res"]] = mini(b["stock"][t["res"]] + t["amount"], STOCK_CAP)
			b["treasury"] -= cost
			s["treasury"] += cost
			t["fails"] = 0
		else:
			t["fails"] += 1
			if t["fails"] > 15:
				continue
		kept.append(t)
	trades = kept


func _resources() -> void:
	var provs := provinces()
	var pop_sum := {}
	var ind_sum := {}
	for c in countries:
		if c["alive"]:
			c["prod"] = _zero_res()
			c["cons"] = _zero_res()
			c["short"] = []
			pop_sum[c["id"]] = 0
			ind_sum[c["id"]] = 0
	for p in owner.size():
		var o := owner[p]
		if o < 0 or not countries[o]["alive"]:
			continue
		for r in provs[p]["deposits"]:
			countries[o]["prod"][r] += provs[p]["deposits"][r]
		pop_sum[o] += provs[p]["pop"]
		ind_sum[o] += (provs[p]["industry"] * (100 - damage[p]) + 50) / 100
	for c in countries:
		if not c["alive"]:
			continue
		var cid: int = c["id"]
		var st: Dictionary = c["stock"]
		for rr in ["food", "coal", "iron", "oil"]:
			c["prod"][rr] = c["prod"][rr] * (100 + mod(cid, rr + "_pct")) / 100
		c["industry"] = ind_sum[cid]
		c["cons"]["food"] = pop_sum[cid] / 90
		var astr := army_strength(cid)
		var fstr := 0
		for f in fleets_of(cid):
			fstr += f["strength"]
		var armor_hp := 0
		for a in armies_of(cid):
			for d in a["div"]:
				if unit_defs[d["t"]]["oil"]:
					armor_hp += d["hp"]
		c["cons"]["oil"] = (astr - armor_hp) / 4000 + armor_hp / 1000 + 2 * fstr / 2000 + air_oil(cid)
		c["manpower"] = mini(c["manpower"] + pop_sum[cid] * (100 + mod(cid, "manpower_pct")) / 20000, 2000)
		# smelting: iron + coal -> steel, limited by industry
		var steel := mini(mini(st["iron"] + c["prod"]["iron"], st["coal"] + c["prod"]["coal"]), ind_sum[cid] * (100 + mod(cid, "steel_pct")) / 300)
		c["prod"]["steel"] = steel
		c["cons"]["iron"] = steel
		c["cons"]["coal"] = steel
		for r in st:
			st[r] = st[r] + c["prod"][r] - c["cons"][r]
			if st[r] < 0:
				st[r] = 0
				c["short"].append(r)
			st[r] = mini(st[r], STOCK_CAP)
		# shortages hurt the army
		if c["short"].has("oil") or c["short"].has("food"):
			for a in armies:
				if a["owner"] == cid:
					_hurt(a, a["strength"] / (100 if c["short"].has("oil") else 200) * (100 - mini(mod(cid, "attrition_pct"), 90)) / 100)


func net_of(cid: int, res: String) -> int:
	var c: Dictionary = countries[cid]
	return c["prod"][res] - c["cons"][res]


func _move_armies() -> void:
	for a in armies:
		if a["path"].is_empty():
			continue
		a["move"] += 1
		if a["move"] < MOVE_DAYS:
			continue
		a["move"] = 0
		var nxt: int = a["path"][0]
		var o := owner[nxt]
		var cid: int = a["owner"]
		if o != cid and o >= 0 and not at_war(cid, o) and not allied(cid, o):
			a["path"] = []  # blocked by a neutral foreign border
			continue
		a["path"].remove_at(0)
		a["prov"] = nxt


func _move_fleets() -> void:
	for f in fleets:
		if f["path"].is_empty():
			continue
		f["move"] += 1
		if f["move"] < 2:
			continue
		f["move"] = 0
		f["prov"] = f["path"][0]
		f["path"].remove_at(0)


func _naval_battles() -> void:
	var provs := provinces()
	var by_prov := {}
	for f in fleets:
		if not by_prov.has(f["prov"]):
			by_prov[f["prov"]] = []
		by_prov[f["prov"]].append(f)
	var keys: Array = by_prov.keys()
	keys.sort()
	for p in keys:
		var group: Array = by_prov[p]
		for i in group.size():
			for j in range(i + 1, group.size()):
				var x: Dictionary = group[i]
				var y: Dictionary = group[j]
				if x["strength"] <= 0 or y["strength"] <= 0 or not at_war(x["owner"], y["owner"]):
					continue
				var px: float = x["strength"] * rng.randf_range(0.8, 1.2) * (1.0 + mod(x["owner"], "fleet_pct") / 100.0)
				var py: float = y["strength"] * rng.randf_range(0.8, 1.2) * (1.0 + mod(y["owner"], "fleet_pct") / 100.0)
				x["strength"] -= int(py * 0.15)
				y["strength"] -= int(px * 0.15)
	# transports without escort are sunk by enemy fleets
	for a in armies:
		if provs[a["prov"]]["land"]:
			continue
		var enemy_here := false
		var friend_here := false
		for f in fleets_in(a["prov"]):
			if f["strength"] <= 0:
				continue
			if f["owner"] == a["owner"] or allied(f["owner"], a["owner"]):
				friend_here = true
			elif at_war(f["owner"], a["owner"]):
				enemy_here = true
		if enemy_here and not friend_here:
			_hurt(a, int(a["strength"] * 0.35) + 1)
	fleets = fleets.filter(func(f): return f["strength"] > 100)


func _battles() -> void:
	_naval_battles()
	var by_prov := {}
	for a in armies:
		if not by_prov.has(a["prov"]):
			by_prov[a["prov"]] = []
		by_prov[a["prov"]].append(a)
	var provs := provinces()
	var keys: Array = by_prov.keys()
	keys.sort()
	for p in keys:
		var group: Array = by_prov[p]
		if group.size() < 2:
			continue
		var def_bonus: float = TERRAIN_DEFENSE.get(provs[p]["terrain"], 1.0)
		for i in group.size():
			for j in range(i + 1, group.size()):
				var x: Dictionary = group[i]
				var y: Dictionary = group[j]
				if x["strength"] <= 0 or y["strength"] <= 0:
					continue
				if not at_war(x["owner"], y["owner"]):
					continue
				var x_def: bool = owner[p] == x["owner"]
				var y_def: bool = owner[p] == y["owner"]
				var px: float = army_power(x, not x_def) * rng.randf_range(0.8, 1.2) * (def_bonus if x_def else 1.0)
				var py: float = army_power(y, not y_def) * rng.randf_range(0.8, 1.2) * (def_bonus if y_def else 1.0)
				_hurt(x, int(py * 0.12))
				_hurt(y, int(px * 0.12))
				_battle_xp(x)
				_battle_xp(y)
	var survivors: Array = []
	for a in armies:
		if a["strength"] > 50 and not a["div"].is_empty():
			survivors.append(a)
		else:
			_set_general(a, -1)
	armies = survivors


func _occupation() -> void:
	for a in armies:
		var p: int = a["prov"]
		if not provinces()[p]["land"]:
			continue
		var o := owner[p]
		var cid: int = a["owner"]
		if o == cid:
			continue
		if o >= 0 and not at_war(cid, o):
			continue
		var contested := false
		for b in armies:
			if b["prov"] == p and b["owner"] != cid and at_war(cid, b["owner"]):
				contested = true
				break
		if contested:
			continue
		owner[p] = cid
		dirty_provinces.append(p)
		if o >= 0 and countries[o]["capital"] == p:
			_capital_fell(o, cid)


func _capital_fell(loser: int, winner: int) -> void:
	_log("%s: пала столица %s" % [date_string(), countries[loser]["name"]])
	countries[loser]["stability"] = maxi(0, countries[loser]["stability"] - 20)
	countries[loser]["war_support"] = maxi(0, countries[loser]["war_support"] - 10)
	var rest := country_provinces(loser)
	if not rest.is_empty():
		countries[loser]["capital"] = rest[0]
	_end_war(loser, winner, "капитуляция")


func _peace() -> void:
	for w in wars.duplicate():
		if day - w["start"] >= MAX_WAR_DAYS:
			_end_war(w["a"], w["b"], "белый мир")


func _end_war(a: int, b: int, why: String) -> void:
	var kept: Array = []
	for w in wars:
		if not ((w["a"] == a and w["b"] == b) or (w["a"] == b and w["b"] == a)):
			kept.append(w)
	if kept.size() != wars.size():
		_log("%s: мир %s — %s (%s)" % [date_string(), countries[a]["name"], countries[b]["name"], why])
	wars = kept
	countries[a]["last_peace"] = day
	countries[b]["last_peace"] = day


func _eliminate() -> void:
	for c in countries:
		if not c["alive"]:
			continue
		if country_provinces(c["id"]).is_empty():
			c["alive"] = false
			_log("%s: государство %s уничтожено" % [date_string(), c["name"]])
			wars = wars.filter(func(w): return w["a"] != c["id"] and w["b"] != c["id"])
			armies = armies.filter(func(a): return a["owner"] != c["id"])
			fleets = fleets.filter(func(f): return f["owner"] != c["id"])
			alliances = alliances.filter(func(al): return al["a"] != c["id"] and al["b"] != c["id"])
			trades = trades.filter(func(t): return t["buyer"] != c["id"] and t["seller"] != c["id"])


func _declare_war(a: int, b: int) -> void:
	wars.append({"a": a, "b": b, "start": day})
	trades = trades.filter(func(t): return not ((t["buyer"] == a and t["seller"] == b) or (t["buyer"] == b and t["seller"] == a)))
	_log("%s: %s объявляет войну %s" % [date_string(), countries[a]["name"], countries[b]["name"]])
	for side in [[a, b], [b, a]]:
		for x in allies_of(side[0]):
			if x != side[1] and countries[x]["alive"] and not allied(x, side[1]) and not at_war(x, side[1]):
				wars.append({"a": x, "b": side[1], "start": day})
				_log("%s: %s вступает в войну на стороне %s" % [date_string(), countries[x]["name"], countries[side[0]]["name"]])


func _make_div(t: String) -> Dictionary:
	return {"t": t, "hp": unit_defs[t]["hp"], "exp": 0}


func _sync(a: Dictionary) -> void:
	var s := 0
	for d in a["div"]:
		s += d["hp"]
	a["strength"] = s


## Damage spread proportionally over divisions; nearly dead divisions are lost.
func _hurt(a: Dictionary, amount: int) -> void:
	var total: int = a["strength"]
	if total <= 0 or amount <= 0:
		return
	for d in a["div"]:
		d["hp"] -= int(float(amount) * d["hp"] / total)
	a["div"] = a["div"].filter(func(d): return d["hp"] > 25)
	_sync(a)


func _battle_xp(a: Dictionary) -> void:
	for d in a["div"]:
		d["exp"] = mini(d["exp"] + 1, 50)
	var g := _general(a["owner"], a["gen"])
	if not g.is_empty():
		g["xp"] += 1
		if g["xp"] >= 150 * g["skill"] and g["skill"] < 5:
			g["skill"] += 1
			g["xp"] = 0
			_log("%s: генерал %s (%s) повышен до уровня %d" % [date_string(), g["name"], countries[a["owner"]]["name"], g["skill"]])


## Combat power of an army in its current province.
func army_power(a: Dictionary, attacking: bool) -> float:
	var terrain: String = provinces()[a["prov"]]["terrain"]
	var oil_short: bool = countries[a["owner"]]["short"].has("oil")
	var p := 0.0
	for d in a["div"]:
		var u: Dictionary = unit_defs[d["t"]]
		var m: float = u["atk"] if attacking else u["def"]
		m *= u["terrain"].get(terrain, 1.0)
		var o: int = a["owner"]
		var tb: int = (mod(o, "atk_pct") + mod(o, "atk_" + d["t"] + "_pct")) if attacking else (mod(o, "def_pct") + mod(o, "def_" + d["t"] + "_pct"))
		m *= 1.0 + tb / 100.0
		if u["oil"] and oil_short:
			m *= 0.5
		p += d["hp"] * m * (1.0 + d["exp"] / 200.0)
	var sup: float = 0.5 + 0.5 * a["supply"] / 100.0
	var g := _general(a["owner"], a["gen"])
	var gm: float = 1.0 + (0.05 * g["skill"] if not g.is_empty() else 0.0)
	var tprov: int = a["prov"]
	var air_share := 0.5
	if air_sup.has(tprov) and air_sup[tprov].has(a["owner"]):
		air_share = air_sup[tprov][a["owner"]]
	var cas: float = air_cas.get(tprov, {}).get(a["owner"], 0.0)
	var cas_m: float = 1.0 + minf(0.3, cas / (a["strength"] + 1.0) * 2.0)
	return p * sup * gm * (1.0 + 0.2 * (air_share - 0.5)) * cas_m


func divisions_of(cid: int) -> int:
	var n := 0
	for a in armies:
		if a["owner"] == cid:
			n += a["div"].size()
	return n


func army_label(a: Dictionary) -> String:
	var counts := {}
	for d in a["div"]:
		counts[d["t"]] = counts.get(d["t"], 0) + 1
	var parts: Array[String] = []
	for t in unit_defs:
		if counts.has(t):
			parts.append("%s×%d" % [unit_defs[t]["name"], counts[t]])
	return ", ".join(parts)


# ---- generals

func _general(cid: int, gid: int) -> Dictionary:
	if gid < 0:
		return {}
	for g in countries[cid]["generals"]:
		if g["id"] == gid:
			return g
	return {}


func _new_general(cid: int) -> void:
	var first: Array = name_pool["first"]
	var last: Array = name_pool["last"]
	countries[cid]["generals"].append({
		"id": next_general_id,
		"name": "%s %s" % [first[rng.randi_range(0, first.size() - 1)], last[rng.randi_range(0, last.size() - 1)]],
		"skill": rng.randi_range(1, 3), "xp": 0, "army": -1,
	})
	next_general_id += 1


## Assign general `gid` (or -1 to clear) to army `a`, releasing any previous holder.
func _set_general(a: Dictionary, gid: int) -> void:
	var cid: int = a["owner"]
	var old := _general(cid, a["gen"])
	if not old.is_empty():
		old["army"] = -1
	a["gen"] = -1
	if gid < 0:
		return
	var g := _general(cid, gid)
	if g.is_empty():
		return
	if g["army"] >= 0:
		var prev := army_by_id(g["army"])
		if not prev.is_empty():
			prev["gen"] = -1
	g["army"] = a["id"]
	a["gen"] = gid


func _merge(a: Dictionary, b: Dictionary) -> void:
	a["div"].append_array(b["div"])
	if a["gen"] < 0 and b["gen"] >= 0:
		var gid: int = b["gen"]
		_set_general(b, -1)
		_set_general(a, gid)
	else:
		_set_general(b, -1)
	armies = armies.filter(func(x): return x["id"] != b["id"])
	_sync(a)


## Train one division at the capital: adds to an army there or founds a new one.
func _train(cid: int, t: String, army_id: int = -1) -> Dictionary:
	var c: Dictionary = countries[cid]
	var u: Dictionary = unit_defs[t]
	if owner[c["capital"]] != cid:
		return _fail("capital lost")
	if c["treasury"] < u["cost"]:
		return _fail("not enough funds")
	if c["stock"]["steel"] < u["steel"]:
		return _fail("not enough steel")
	if c["manpower"] < u["manpower"]:
		return _fail("no manpower")
	var target := {}
	if army_id >= 0:
		target = army_by_id(army_id)
		if target.is_empty() or target["owner"] != cid or target["prov"] != c["capital"]:
			return _fail("invalid army")
		if target["div"].size() >= MAX_DIV:
			return _fail("army full")
	else:
		for a in armies_of(cid):
			if a["prov"] == c["capital"] and a["path"].is_empty() and a["div"].size() < AI_STACK:
				target = a
				break
	c["treasury"] -= u["cost"]
	c["stock"]["steel"] -= u["steel"]
	c["manpower"] -= u["manpower"]
	if target.is_empty():
		_add_army(cid, c["capital"], [_make_div(t)])
	else:
		target["div"].append(_make_div(t))
		_sync(target)
	return {"ok": true}


# ---- supply

## Supply distance from hubs (capital; ports too when a fleet provides naval supply).
func _supply_dist(cid: int) -> Dictionary:
	var provs := provinces()
	var dist := {}
	var buckets: Array = []
	for _i in 160:
		buckets.append([])
	var cap: int = countries[cid]["capital"]
	if owner[cap] == cid:
		dist[cap] = 0
		buckets[0].append(cap)
	else:
		for p in owner.size():
			if owner[p] == cid:
				dist[p] = 6
				buckets[6].append(p)
				break
	if not fleets_of(cid).is_empty():
		for p in owner.size():
			if owner[p] == cid and is_coastal(p) and not dist.has(p):
				dist[p] = 8
				buckets[8].append(p)
	for d in 160:
		for p in buckets[d]:
			if dist[p] != d:
				continue
			for q in provs[p]["land_neighbors"]:
				var o := owner[q]
				var cost := 1 if (o == cid or allied(cid, o)) else 3
				var nd := d + cost
				if nd < 160 and nd < dist.get(q, 999):
					dist[q] = nd
					buckets[nd].append(q)
	return dist


func _supply() -> void:
	var provs := provinces()
	var industry := {}
	for c in countries:
		industry[c["id"]] = 0
	for p in owner.size():
		if owner[p] >= 0:
			industry[owner[p]] += provs[p]["industry"]
	for c in countries:
		if not c["alive"]:
			continue
		var mine := armies_of(c["id"])
		if mine.is_empty():
			continue
		var dist := _supply_dist(c["id"])
		var demand := 0
		for a in mine:
			demand += a["div"].size()
		var factor := minf(1.0, float(6 + industry[c["id"]]) * (100 + mod(c["id"], "supply_pct")) / 100.0 / maxf(demand, 1.0))
		for a in mine:
			var d: int = dist.get(a["prov"], 999)
			if not provs[a["prov"]]["land"]:
				d = 8
			a["supply"] = int(clampf(1.0 - d * 0.1 * (100 - mini(mod(c["id"], "supply_decay_pct"), 80)) / 100.0, 0.0, 1.0) * factor * 100.0)
			if a["supply"] < 20:
				_hurt(a, a["strength"] / 100)


func _add_army(cid: int, prov: int, divs: Array) -> Dictionary:
	var a := {
		"id": next_army_id, "owner": cid, "prov": prov, "div": divs,
		"strength": 0, "path": [], "move": 0, "gen": -1, "supply": 100,
	}
	_sync(a)
	armies.append(a)
	next_army_id += 1
	return a


func _spawn_army(cid: int, prov: int, types: Array = ["infantry", "infantry"]) -> void:
	var divs: Array = []
	for t in types:
		divs.append(_make_div(t))
	_add_army(cid, prov, divs)


func _spawn_fleet(cid: int, sea: int) -> void:
	fleets.append({
		"id": next_fleet_id, "owner": cid, "prov": sea,
		"strength": FLEET_STRENGTH, "path": [], "move": 0,
	})
	next_fleet_id += 1


func _break_alliance(a: int, b: int) -> void:
	alliances = alliances.filter(func(al): return not ((al["a"] == a and al["b"] == b) or (al["a"] == b and al["b"] == a)))
	_log("%s: союз %s — %s расторгнут" % [date_string(), countries[a]["name"], countries[b]["name"]])


func _common_enemy(a: int, b: int) -> bool:
	var ea := enemies_of(a)
	for e in enemies_of(b):
		if ea.has(e):
			return true
	return false


func _common_threat(a: int, b: int) -> bool:
	var nb := neighbor_countries(b)
	for n in neighbor_countries(a):
		if n != b and nb.has(n) and army_strength(n) > army_strength(a) and army_strength(n) > army_strength(b):
			return true
	return false


## Would AI country `ai` agree to ally with `other`?
func _ai_accepts_alliance(ai: int, other: int) -> bool:
	return _common_enemy(ai, other) or _common_threat(ai, other)


## Would AI country `ai` agree to peace with `other`?
func _ai_accepts_peace(ai: int, other: int) -> bool:
	var age := 0
	for w in wars:
		if (w["a"] == ai and w["b"] == other) or (w["a"] == other and w["b"] == ai):
			age = day - w["start"]
	return age >= 20 and (army_strength(ai) <= army_strength(other) * 1.2 or age >= 60)


func _log(text: String) -> void:
	log_lines.append(text)
	if log_lines.size() > 200:
		log_lines.pop_front()


# ---------------------------------------------------------------- pathing

## BFS over land. Passable: own, enemy-owned or unowned provinces.
func _find_path(from: int, cid: int, goal: int) -> Array:
	return _route(from, cid, func(p): return p == goal)


## Land-only route first; if none, a route that may use sea hops (needs a fleet).
func _route(from: int, cid: int, is_goal: Callable) -> Array:
	var path := _bfs(from, cid, is_goal, false)
	if path.is_empty() and not fleets_of(cid).is_empty():
		path = _bfs(from, cid, is_goal, true)
	return path


func _sea_path(from: int, goal: int) -> Array:
	var provs := provinces()
	var prev := {from: -1}
	var queue: Array[int] = [from]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		if cur == goal:
			var path: Array = []
			var n := cur
			while n != from:
				path.push_front(n)
				n = prev[n]
			return path
		for q in provs[cur]["neighbors"]:
			if not prev.has(q) and not provs[q]["land"]:
				prev[q] = cur
				queue.append(q)
	return []


func _bfs(from: int, cid: int, is_goal: Callable, allow_sea: bool) -> Array:
	var provs := provinces()
	var enemies := enemies_of(cid)
	var prev := {from: -1}
	var queue: Array[int] = [from]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		if cur != from and is_goal.call(cur):
			var path: Array = []
			var n := cur
			while n != from:
				path.push_front(n)
				n = prev[n]
			return path
		for q in provs[cur]["neighbors"]:
			if prev.has(q):
				continue
			if not provs[q]["land"]:
				if allow_sea and not _enemy_fleet_in(q, enemies):
					prev[q] = cur
					queue.append(q)
				continue
			if not provs[cur]["land"] and q == from:
				continue
			var o := owner[q]
			if o == cid or o == -1 or enemies.has(o) or allied(cid, o):
				prev[q] = cur
				queue.append(q)
	return []


# --------------------------------------------------------------------- AI

func _ai() -> void:
	for c in countries:
		if not c["alive"] or not c["ai"]:
			continue
		var cid: int = c["id"]
		var my_str := army_strength(cid)
		var enemies := enemies_of(cid)
		# strategic: choose a victim
		if enemies.is_empty() and day >= GRACE_DAYS and day - c["last_peace"] > 30 and armies_of(cid).size() >= 2:
			var victim := -1
			var weakest := 1 << 30
			var targets := neighbor_countries(cid)
			if fleets_of(cid).size() >= 2:
				for o2 in countries:
					if o2["alive"] and o2["id"] != cid and not targets.has(o2["id"]) and can_reach_overseas(cid, o2["id"]):
						targets.append(o2["id"])
			for n in targets:
				if allied(cid, n):
					continue
				var s := army_strength(n)
				if s < weakest:
					weakest = s
					victim = n
			if victim >= 0 and my_str > weakest * 1.3:
				_declare_war(cid, victim)
				enemies = enemies_of(cid)
		# diplomacy: seek an ally every 30 days
		if day % 30 == 0 and allies_of(cid).is_empty() and enemies.is_empty():
			for n in neighbor_countries(cid):
				if not allied(cid, n) and not at_war(cid, n) and _ai_accepts_alliance(n, cid) and countries[n]["ai"]:
					alliances.append({"a": cid, "b": n})
					_log("%s: союз %s — %s" % [date_string(), c["name"], countries[n]["name"]])
					break
		# peace: tired of losing
		for e in enemies.duplicate():
			if day - _war_start(cid, e) >= 90 and my_str < army_strength(e) and countries[e]["ai"]:
				_end_war(cid, e, "усталость от войны")
				enemies = enemies_of(cid)
		# naval: build fleets
		if day % 10 == 0:
			_ai_trade(cid)
		if c["treasury"] >= FLEET_COST * 3 and c["stock"]["steel"] >= FLEET_STEEL and port_of(cid) >= 0 and fleets_of(cid).size() < mini(4, 1 + country_provinces(cid).size() / 10):
			c["treasury"] -= FLEET_COST
			c["stock"]["steel"] -= FLEET_STEEL
			_spawn_fleet(cid, sea_next_to(port_of(cid)))
		# economic: build armies
		if c["treasury"] >= 120 and divisions_of(cid) < 6 + country_provinces(cid).size():
			var kinds := ["infantry", "infantry", "armor", "artillery"]
			_train(cid, kinds[(day / 5 + cid) % kinds.size()])
		_ai_generals(cid)
		_ai_air(cid)
		if day % 10 == 0:
			_ai_politics(cid)
		if day % 15 == 0:
			_ai_intel(cid)
		if day % 10 == 0:
			_ai_research(cid)
		if day % 10 == 0:
			_ai_merge(cid)
		# military: send idle armies at the nearest enemy target
		if enemies.is_empty():
			continue
		for a in armies_of(cid):
			if not a["path"].is_empty():
				continue
			var path := _route(a["prov"], cid, func(p):
				var o := owner[p]
				if enemies.has(o):
					return true
				for b in armies:
					if b["prov"] == p and enemies.has(b["owner"]):
						return true
				return false)
			if not path.is_empty():
				var wet := false
				for q in path:
					if not provinces()[q]["land"]:
						wet = true
				if wet and not transport_free(cid):
					continue
				a["path"] = path
				a["move"] = 0


func _enemy_fleet_in(p: int, enemies: Array) -> bool:
	for f in fleets:
		if f["prov"] == p and enemies.has(f["owner"]):
			return true
	return false


func _ai_generals(cid: int) -> void:
	for a in armies_of(cid):
		if a["gen"] >= 0:
			continue
		var best := {}
		for g in countries[cid]["generals"]:
			if g["army"] < 0 and (best.is_empty() or g["skill"] > best["skill"]):
				best = g
		if not best.is_empty():
			_set_general(a, best["id"])


func _ai_merge(cid: int) -> void:
	var mine := armies_of(cid)
	for i in mine.size():
		for j in range(i + 1, mine.size()):
			var a: Dictionary = mine[i]
			var b: Dictionary = mine[j]
			if a["prov"] == b["prov"] and a["path"].is_empty() and b["path"].is_empty() and a["div"].size() + b["div"].size() <= AI_STACK:
				_merge(a, b)
				return


func _ai_trade(cid: int) -> void:
	var c: Dictionary = countries[cid]
	for r in res_defs:
		var res: String = r["id"]
		if c["stock"][res] >= 40 or net_of(cid, res) >= 0:
			continue
		var want := mini(5, -net_of(cid, res) + 1)
		for other in countries:
			if other["alive"] and other["ai"] and other["id"] != cid and _try_trade(cid, other["id"], res, want)["ok"]:
				break


func _war_start(a: int, b: int) -> int:
	for w in wars:
		if (w["a"] == a and w["b"] == b) or (w["a"] == b and w["b"] == a):
			return w["start"]
	return day


func armies_of(cid: int) -> Array:
	var out: Array = []
	for a in armies:
		if a["owner"] == cid:
			out.append(a)
	return out


# ----------------------------------------------------- save / load / hash

func to_dict() -> Dictionary:
	return {
		"version": SAVE_VERSION, "seed": seed_value, "day": day,
		"owner": owner, "countries": countries, "armies": armies, "wars": wars,
		"next_army_id": next_army_id, "next_general_id": next_general_id, "ops": ops, "next_op_id": next_op_id, "next_event_uid": next_event_uid, "wings": wings, "next_wing_id": next_wing_id, "damage": damage, "fleets": fleets, "next_fleet_id": next_fleet_id, "alliances": alliances, "trades": trades, "next_trade_id": next_trade_id, "embargoes": embargoes, "rng_state": rng.state, "command_log": command_log,
	}


static func from_dict(d: Dictionary, country_defs: Array) -> Simulation:
	var sim := Simulation.new()
	sim.seed_value = d["seed"]
	sim.world = WorldGen.generate(sim.seed_value)
	sim.day = d["day"]
	sim.owner = d["owner"]
	sim.countries = d["countries"]
	sim.armies = d["armies"]
	sim.wars = d["wars"]
	sim.next_army_id = d["next_army_id"]
	sim.fleets = d["fleets"]
	sim.next_fleet_id = d["next_fleet_id"]
	sim.alliances = d["alliances"]
	sim.trades = d["trades"]
	sim.next_trade_id = d["next_trade_id"]
	sim.embargoes = d["embargoes"]
	sim.res_defs = load_resource_defs()
	sim.unit_defs = load_unit_defs()
	sim.name_pool = load_name_pool()
	sim._load_techs()
	sim.next_general_id = d["next_general_id"]
	sim.ops = d["ops"]
	sim.next_op_id = d["next_op_id"]
	sim._load_intel()
	sim.next_event_uid = d["next_event_uid"]
	sim._load_politics()
	sim.wings = d["wings"]
	sim.next_wing_id = d["next_wing_id"]
	sim.damage = d["damage"]
	sim.air_defs = load_air_defs()
	sim.rng.seed = sim.seed_value
	sim.rng.state = d["rng_state"]
	sim.command_log = d.get("command_log", [])
	return sim


## State fingerprint for desync detection (multiplayer) and tests.
func checksum() -> int:
	return var_to_str([day, owner, countries, armies, fleets, wings, damage, alliances, trades, embargoes, wars, rng.state]).hash()
