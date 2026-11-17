class_name Simulation
extends RefCounted
## Headless, deterministic game simulation. No Node/graphics dependencies.
## All mutations from players go through apply_command(); time advances via tick_day().

const SAVE_VERSION := 11
const MIN_SAVE_VERSION := 10
const SUPPLY_RANGE := 140
const STARVING_SUPPLY := 25   # AI armies below this supply % retreat to their own land
const SANCTION_COST_PP := 25      # political influence paid by the country that imposes sanctions
const SANCTION_INCOME_PCT := 12   # income lost by the target per sanctioning country
const SANCTION_MAX_PCT := 48
const SUPPLY_EVERY := 3  # supply is recomputed per country every N days (staggered)
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
const MAX_INFRA := 5
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
var sanctions: Array = []  # {"a": imposer, "b": target, "since": day}: financial pressure, see sanction_pct()
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
var start_date := "1936-01-01"
var disabled_events: Array = []
var grace_days := GRACE_DAYS
var scenario_id := ""
var scenario_deposits: Dictionary = {}
var infra := PackedInt32Array()  # per-province railway/road level 1..5
## `owner` is the GAME CONTROL of each cell (changes only through armies / explicit rules).
## `legal` is the internationally recognised sovereign (changes only through treaties or the creation of a new state).
var legal := PackedInt32Array()
var load_error := ""
var _cp: Dictionary = {}          # country id -> sorted Array[int] of controlled cells
var _nc: Dictionary = {}          # country id -> neighbour countries (cache)
var _nc_ver := -1
var _owner_ver := 0
var _coastal := PackedByteArray()
var _agg: Dictionary = {}         # country id -> {"prod","pop","ind","income"} (exact; rebuilt when ownership/damage/deposits change)
var _blockade_key: Array = []   # inputs of the last blockade computation (see _logistics)
var _agg_key: Array = []
var ai_war_chance := 1.0          # probability gate for AI war declarations (scenario-tunable)
## Opt-in rule sets (scenario "rules": {...}); off by default so existing scenarios and their reference checksums are unchanged.
var rule_terrain := false         # terrain, roads and railways change movement and supply cost
var rule_modern := false          # abstract drones, electronic warfare, satellites and cyber (techs with "rule": "modern")
var rule_markets := false         # population dynamics and a world market with floating prices
var pop_bp := {}                  # cid -> population index in basis points (10000 = start); only with rules.markets
var market_pct := {}              # resource -> world price in percent of the base price (100 = base)
var _market_flow := {}            # resource -> units bought (+) / sold (-) on the market since the last price update
const MARKET_SPREAD := 10         # percent: players buy at +10% and sell at -10%
const MARKET_RES := ["food", "coal", "iron", "oil", "steel"]
var missile_stock := {}           # cid -> {"tactical": n, "strategic": n}; only with rules.modern
var strikes: Array = []           # recent launches for the map and the log: {"day","owner","from","target","type","hit"}
const MISSILE_CAP := 40
## Abstract missile types (game balance only): range in cells (hops), damage to the cell (0..100), share of enemy army strength lost.
const MISSILE_DEFS := {
	"tactical": {"name": "Тактические ракеты", "cost": 40, "steel": 8, "range": 5, "dmg": 25, "army_pct": 8, "tech": "mis1"},
	"strategic": {"name": "Ракеты дальнего действия", "cost": 120, "steel": 25, "range": 12, "dmg": 55, "army_pct": 18, "tech": "mis2"},
}
var rule_weather := false         # seasons, winter by latitude and local storms slow armies, supply and air operations
var _cell_lat := PackedFloat32Array()
var _start_doy := 1
const TERRAIN_MOVE := {"plains": 100, "desert": 125, "forest": 150, "hills": 165, "mountain": 260, "sea": 100}  # percent of base days
const TERRAIN_SUPPLY_EXTRA := {"plains": 0, "desert": 2, "forest": 2, "hills": 3, "mountain": 6, "sea": 0}
var tech_defs: Dictionary = {}
var tech_order: Array = []
var alliances: Array = []  # each: {"a": int, "b": int}
var command_log: Array = []
var log_lines: Array = []
var dirty_provinces: Array[int] = []


func _load_static() -> void:
	res_defs = load_resource_defs()
	unit_defs = load_unit_defs()
	name_pool = load_name_pool()
	_load_techs()
	_load_politics()
	_load_intel()
	air_defs = load_air_defs()


## Share the immutable Earth dataset between simulations; provinces are copy-on-write.
func _own_earth_world() -> void:
	var ew := EarthWorld.load_world()
	world = ew.duplicate()
	world["provinces"] = ew["provinces"].duplicate()


func set_deposits(p: int, dep: Dictionary) -> void:
	var provs: Array = world["provinces"]
	provs[p] = provs[p].duplicate()
	provs[p]["deposits"] = dep
	_owner_ver += 1


func _rebuild_caches() -> void:
	var provs := provinces()
	_cp = {}
	for p in owner.size():
		var o := owner[p]
		if o >= 0:
			if not _cp.has(o):
				var a: Array[int] = []
				_cp[o] = a
			_cp[o].append(p)
	_coastal = PackedByteArray()
	_coastal.resize(provs.size())
	for p in provs.size():
		if provs[p]["land"]:
			for q in provs[p]["neighbors"]:
				if not provs[q]["land"]:
					_coastal[p] = 1
					break
	_nc.clear()
	_owner_ver += 1


## The only way a cell changes hands (keeps per-country caches consistent).
func set_owner(p: int, cid: int) -> void:
	var old := owner[p]
	if old == cid:
		return
	var base_ok := _agg_base_ver == _owner_ver and not _agg_base.is_empty()
	if base_ok:
		if old >= 0:
			_agg_cell(_agg_base, old, p, -1)
		if cid >= 0:
			_agg_cell(_agg_base, cid, p, 1)
	if old >= 0 and _cp.has(old):
		var l: Array = _cp[old]
		var i := l.bsearch(p)
		if i < l.size() and l[i] == p:
			l.remove_at(i)
	owner[p] = cid
	if cid >= 0:
		if not _cp.has(cid):
			var a: Array[int] = []
			_cp[cid] = a
		var l2: Array = _cp[cid]
		l2.insert(l2.bsearch(p), p)
	_owner_ver += 1
	if base_ok:
		_agg_base_ver = _owner_ver


## Read-only view of the cells a country controls (do not modify).
func cells_of(cid: int) -> Array:
	return _cp.get(cid, [])


func setup(seed_value_: int, country_defs: Array) -> void:
	seed_value = seed_value_
	rng.seed = seed_value
	_load_static()
	world = WorldGen.generate(seed_value)
	var caps := WorldGen.pick_capitals(world, country_defs.size(), rng)
	owner = WorldGen.assign_owners(world, caps)
	legal = owner.duplicate()
	_rebuild_caches()
	damage.resize(owner.size())
	damage.fill(0)
	infra.resize(owner.size())
	for p in owner.size():
		var pv: Dictionary = world["provinces"][p]
		infra[p] = clampi(1 + pv["pop"] / 80, 1, 4) if pv["land"] else 0
	for cap_p in caps:
		infra[cap_p] = mini(MAX_INFRA, infra[cap_p] + 1)
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
	var f := _open_data("techs.json")
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for t in parsed.get("techs", []):
		if t.get("rule", "") == "modern" and not rule_modern:
			continue   # opt-in rule set: not part of scenarios that do not enable it
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
	var f := _open_data("aircraft.json")
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
	if countries[w["owner"]]["short"].has("oil"):
		return false
	if rule_weather and (storm_at(w["base"]) or winter_at(w["base"]) > 85):
		return false
	return true


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
	if day % 10 == 0 and c["treasury"] >= 250 and wings_of(cid).size() < 2 + cells_of(cid).size() / 4:
		var kinds := ["fighter", "attacker", "bomber", "fighter"]
		var base: int = c["capital"]
		if owner[base] != cid or wings_at(base).size() >= air_capacity(base):
			base = -1
			for p in cells_of(cid):
				if wings_at(p).size() < air_capacity(p):
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


# ------------------------------------------------------------ real-world map

static func _tag_color(tag: String) -> String:
	var h := 7
	for ch in tag:
		h = (h * 31 + ch.unicode_at(0)) % 360007
	return "#" + Color.from_hsv(float(h % 360) / 360.0, 0.45 + float(h % 7) * 0.05, 0.72 + float(h % 5) * 0.04).to_html(false)


## Build the game on the real-world dataset: every sovereign state with territory becomes a country.
func setup_earth(scn: Dictionary) -> Array:
	var ds := str(scn.get("world_dataset", "world"))
	if not EarthWorld.available_dataset(ds):
		return ["real-world dataset is missing (data/%s)" % ds]
	EarthWorld.activate(ds)
	seed_value = int(scn.get("seed", 2026))
	rng.seed = seed_value
	_load_static()
	_own_earth_world()
	var ew := EarthWorld.load_world()
	var provs: Array = world["provinces"]
	var cdata: Array = ew["countries"]
	var primary := {}
	for i in cdata.size():
		var c: Dictionary = cdata[i]
		if not primary.has(c["sov"]) or c["adm0"] == c["sov"]:
			primary[c["sov"]] = i
	var cell_count := {}
	for p in provs:
		if p["land"]:
			var sov: String = cdata[p["country"]]["sov"]
			cell_count[sov] = cell_count.get(sov, 0) + 1
	var tags: Array = cell_count.keys()
	tags.sort()
	var sov_id := {}
	for t in tags:
		sov_id[t] = sov_id.size()
	owner.resize(provs.size())
	owner.fill(-1)
	for p in provs:
		if p["land"]:
			owner[p["id"]] = sov_id[cdata[p["country"]]["sov"]]
	legal = owner.duplicate()
	damage.resize(provs.size())
	damage.fill(0)
	infra.resize(provs.size())
	for p in provs:
		infra[p["id"]] = int(p.get("infra0", 0))
	_rebuild_caches()
	var income_factor := {"1. High income: OECD": 1.3, "2. High income: nonOECD": 1.25, "3. Upper middle income": 1.1, "4. Lower middle income": 1.0, "5. Low income": 0.8}
	countries.clear()
	for t in tags:
		var pc: Dictionary = cdata[primary[t]]
		var cid: int = sov_id[t]
		var own: Array = cells_of(cid)
		var cap: int = int(pc.get("capital_cell", -1))
		if cap < 0 or owner[cap] != cid:
			cap = own[0]
			for q in own:
				if provs[q]["pop_real"] > provs[cap]["pop_real"]:
					cap = q
		var nm: String = pc["name_ru"] if pc.get("name_ru") != null and str(pc["name_ru"]) != "" else pc["name_en"]
		var c := _new_country(t, nm, _tag_color(t), cap)
		c["treasury"] = clampi(int(pc["gdp_md"]) / 4000 + 80, 80, 6000)
		c["manpower"] = clampi(100 + int(pc["pop"]) / 50000, 100, 2000)
		c["ai"] = true
		_init_politics(cid)
		var inc: float = income_factor.get(pc.get("income", ""), 1.0)
		var n_div := clampi(1 + int(sqrt(float(pc["pop"]) / 1000000.0) / 1.4 * inc), 1, 36)
		var by_pop: Array = own.duplicate()
		by_pop.sort_custom(func(a, b): return provs[a]["pop_real"] > provs[b]["pop_real"] or (provs[a]["pop_real"] == provs[b]["pop_real"] and a < b))
		var stacks := mini(maxi(1, (n_div + 2) / 3), mini(by_pop.size(), 6))
		var left := n_div
		for k in stacks:
			var cnt := mini(3, left) if k < stacks - 1 else left
			cnt = mini(cnt, MAX_DIV)
			var kinds: Array = []
			for j in cnt:
				kinds.append("infantry")
			if cnt >= 3 and inc >= 1.1:
				kinds[cnt - 1] = "armor" if k % 2 == 0 else "artillery"
			_spawn_army(cid, by_pop[k], kinds)
			left -= cnt
			if left <= 0:
				break
		for _g in 3:
			_new_general(cid)
		var mine := armies_of(cid)
		for k in mini(2, mine.size()):
			_set_general(mine[k], c["generals"][k]["id"])
		if inc >= 1.25:
			c["techs"] = ["ind1", "eco1", "wp1", "lg1"]
		elif inc >= 1.1:
			c["techs"] = ["ind1", "wp1"]
		_recalc_mods(cid)
	return []


## Cells held by `a` that touch a cell held by `b` (the front between two belligerents).
func front_cells(a: int, b: int) -> Array[int]:
	var out: Array[int] = []
	var provs := provinces()
	for p in cells_of(a):
		for q in provs[p]["land_neighbors"]:
			if owner[q] == b:
				out.append(p)
				break
	return out


## Cells of `cid` that are cut off from its capital by the enemy: not connected through own/allied cells AND touching a cell held by
## a country it is at war with (islands and exclaves with no enemy next to them are not "encircled").
func cut_off_cells(cid: int) -> Array[int]:
	var provs := provinces()
	var cap: int = countries[cid]["capital"]
	var reached := {}
	if owner[cap] == cid:
		reached[cap] = true
		var queue: Array[int] = [cap]
		while not queue.is_empty():
			var cur: int = queue.pop_front()
			for q in provs[cur]["land_neighbors"]:
				if not reached.has(q) and (owner[q] == cid or (owner[q] >= 0 and allied(cid, owner[q]))):
					reached[q] = true
					queue.append(q)
	var enemies := enemies_of(cid)
	var out: Array[int] = []
	if enemies.is_empty():
		return out
	for p in cells_of(cid):
		if reached.has(p):
			continue
		for q in provs[p]["land_neighbors"]:
			if enemies.has(owner[q]):
				out.append(p)
				break
	return out


## Who currently controls a settlement (the controller of its cell); `contested` if an enemy army stands in the cell.
func settlement_status(sett: Dictionary) -> Dictionary:
	var cell: int = int(sett["cell"])
	var ctl := owner[cell]
	var contested := false
	for a in armies:
		if a["prov"] == cell and ctl >= 0 and a["owner"] != ctl and at_war(a["owner"], ctl):
			contested = true
			break
	return {"controller": ctl, "legal": legal[cell], "contested": contested}


func is_earth_world() -> bool:
	return str(world.get("kind", "")) == "earth"


## Region hierarchy helpers (administrative regions are independent of who controls the cells).
func region_of(cell: int) -> int:
	return int(provinces()[cell].get("region", 0))


func region_cells(region_id: int) -> Array:
	if not world.has("region_index"):
		var idx := {}
		for p in provinces():
			if p["land"]:
				var r: int = p["region"]
				if not idx.has(r):
					idx[r] = []
				idx[r].append(p["id"])
		world["region_index"] = idx
	return world["region_index"].get(region_id, [])


## controller country id -> number of cells it holds inside the region.
func region_control(region_id: int) -> Dictionary:
	var out := {}
	for c in region_cells(region_id):
		out[owner[c]] = out.get(owner[c], 0) + 1
	return out


func region_legal(region_id: int) -> Dictionary:
	var out := {}
	for c in region_cells(region_id):
		out[legal[c]] = out.get(legal[c], 0) + 1
	return out


# --------------------------------------------------------------- scenarios

## Structural checks that need no world (types, tags, references between fields).
static func validate_scenario(scn: Dictionary) -> Array:
	var errs: Array = []
	if int(scn.get("schema_version", 0)) != 1:
		errs.append("unsupported schema_version")
	if not scn.has("seed") or typeof(scn["seed"]) not in [TYPE_INT, TYPE_FLOAT]:
		errs.append("seed must be a number")
	var tags := {}
	var cs: Variant = scn.get("countries", [])
	var is_earth: bool = str(scn.get("world", "procedural")) == "earth"
	if typeof(cs) != TYPE_ARRAY or (cs.size() < 2 and not is_earth):
		errs.append("need at least 2 countries")
		return errs
	for c in cs:
		for k in ["tag", "name", "color"]:
			if not c.has(k) or str(c[k]) == "":
				errs.append("country missing %s" % k)
		if c.has("tag"):
			if tags.has(c["tag"]):
				errs.append("duplicate tag %s" % c["tag"])
			tags[c["tag"]] = true
		if c.has("color") and not str(c["color"]).is_valid_html_color():
			errs.append("bad color %s" % c["color"])
	for pair_key in ["alliances", "wars"]:
		for pair in scn.get(pair_key, []):
			if is_earth:
				if pair.size() != 2 or pair[0] == pair[1]:
					errs.append("bad %s entry %s" % [pair_key, str(pair)])
			elif pair.size() != 2 or not tags.has(pair[0]) or not tags.has(pair[1]) or pair[0] == pair[1]:
				errs.append("bad %s entry %s" % [pair_key, str(pair)])
	for a in scn.get("armies", []):
		if not is_earth and not tags.has(a.get("tag", "")):
			errs.append("army for unknown tag %s" % str(a.get("tag", "")))
	for t in scn.get("owners", {}).values():
		if not is_earth and t != null and not tags.has(t):
			errs.append("owner override for unknown tag %s" % str(t))
	for t in scn.get("capitals", {}):
		if not is_earth and not tags.has(t):
			errs.append("capital for unknown tag %s" % t)
	return errs


## Build the game from a scenario dictionary. Returns a list of problems (empty = success).
func setup_scenario(scn: Dictionary) -> Array:
	var problems := validate_scenario(scn)
	if not problems.is_empty():
		return problems
	var is_earth: bool = str(scn.get("world", "procedural")) == "earth"
	var defs: Array = scn.get("countries", [])
	start_date = str(scn.get("start_date", "1936-01-01"))
	disabled_events = scn.get("disabled_events", []).duplicate()
	grace_days = int(scn.get("grace_days", GRACE_DAYS))
	ai_war_chance = float(scn.get("ai_war_chance", 1.0))
	rule_terrain = bool(scn.get("rules", {}).get("terrain", false))
	rule_weather = bool(scn.get("rules", {}).get("weather", false))
	rule_modern = bool(scn.get("rules", {}).get("modern", false))
	rule_markets = bool(scn.get("rules", {}).get("markets", false))
	pop_bp = {}
	market_pct = {}
	_market_flow = {}
	if rule_markets:
		for r in MARKET_RES:
			market_pct[r] = 100
			_market_flow[r] = 0
	if rule_modern:
		_load_techs()
		missile_stock = {}
		strikes = []
	_compute_start_doy()
	scenario_id = str(scn.get("id", ""))
	if is_earth:
		var ep := setup_earth(scn)
		if world.is_empty():
			return ep
		problems.append_array(ep)
	else:
		setup(int(scn["seed"]), defs)
		if countries.size() != defs.size():
			return ["map has room for only %d countries" % countries.size()]
	var by_tag := {}
	for c in countries:
		by_tag[c["tag"]] = c["id"]
	var provs := provinces()
	for k in scn.get("deposits", {}):
		var p := int(k)
		if p < 0 or p >= provs.size() or not provs[p]["land"]:
			problems.append("deposits on invalid province %s" % k)
			continue
		var dep := {}
		for r in scn["deposits"][k]:
			if int(scn["deposits"][k][r]) > 0:
				dep[r] = int(scn["deposits"][k][r])
		set_deposits(p, dep)
		scenario_deposits[str(p)] = dep
	for k in scn.get("owners", {}):
		var p2 := int(k)
		if p2 < 0 or p2 >= owner.size() or not provs[p2]["land"]:
			problems.append("owner override on invalid province %s" % k)
			continue
		var tag: Variant = scn["owners"][k]
		set_owner(p2, by_tag[tag] if tag != null else -1)
		legal[p2] = owner[p2]
	for tag in scn.get("capitals", {}):
		var cp := int(scn["capitals"][tag])
		if cp >= 0 and cp < owner.size() and provs[cp]["land"]:
			countries[by_tag[tag]]["capital"] = cp
	for c in countries:
		var own := country_provinces(c["id"])
		if own.is_empty():
			problems.append("%s owns no provinces" % c["tag"])
			continue
		if owner[c["capital"]] != c["id"]:
			c["capital"] = own[0]
	for d in defs:
		if not by_tag.has(d["tag"]):
			if not is_earth:
				problems.append("unknown country %s" % str(d["tag"]))
			continue
		var c: Dictionary = countries[by_tag[d["tag"]]]
		if d.has("treasury"):
			c["treasury"] = int(d["treasury"])
		if d.has("manpower"):
			c["manpower"] = int(d["manpower"])
		for r in d.get("stock", {}):
			if c["stock"].has(r):
				c["stock"][r] = int(d["stock"][r])
		for t in d.get("techs", []):
			if tech_defs.has(t):
				if not c["techs"].has(t):
					c["techs"].append(t)
			else:
				problems.append("unknown tech %s" % str(t))
		for cat in d.get("laws", {}):
			if law_defs.has(cat) and not law_option(cat, d["laws"][cat]).is_empty():
				c["laws"][cat] = d["laws"][cat]
			else:
				problems.append("unknown law %s/%s" % [cat, str(d["laws"][cat])])
		if d.has("ideology"):
			if ideo_defs.has(d["ideology"]):
				c["ideology"] = d["ideology"]
				_shift_popularity(c, d["ideology"], 55 - c["party_pop"][d["ideology"]])
			else:
				problems.append("unknown ideology %s" % str(d["ideology"]))
	if scn.get("armies_mode", "") == "replace":
		armies.clear()
		for c in countries:
			for g in c["generals"]:
				g["army"] = -1
	for a in scn.get("armies", []):
		if not by_tag.has(a["tag"]):
			problems.append("army for unknown country %s" % str(a["tag"]))
			continue
		var cid: int = by_tag[a["tag"]]
		var divs: Array = []
		for t in a.get("divisions", ["infantry", "infantry"]):
			if unit_defs.has(t):
				divs.append(_make_div(t))
			else:
				problems.append("unknown unit %s" % str(t))
		if int(a["province"]) < 0 or int(a["province"]) >= owner.size() or not provs[int(a["province"])]["land"] or divs.is_empty():
			problems.append("bad army placement for %s" % a["tag"])
			continue
		_add_army(cid, int(a["province"]), divs)
	for c in countries:
		var mine := armies_of(c["id"])
		var gi := 0
		for a in mine:
			if a["gen"] < 0 and gi < c["generals"].size():
				while gi < c["generals"].size() and c["generals"][gi]["army"] >= 0:
					gi += 1
				if gi < c["generals"].size():
					_set_general(a, c["generals"][gi]["id"])
	for pair in scn.get("alliances", []):
		if by_tag.has(pair[0]) and by_tag.has(pair[1]):
			alliances.append({"a": by_tag[pair[0]], "b": by_tag[pair[1]]})
		else:
			problems.append("alliance with unknown country %s" % str(pair))
	for pair in scn.get("wars", []):
		if not by_tag.has(pair[0]) or not by_tag.has(pair[1]):
			problems.append("war with unknown country %s" % str(pair))
		elif not at_war(by_tag[pair[0]], by_tag[pair[1]]):
			wars.append({"a": by_tag[pair[0]], "b": by_tag[pair[1]], "start": 0})
	for c in countries:
		c["stability"] = _stability_target(c)
		c["war_support"] = _war_support_target(c)
		_recalc_mods(c["id"])
	dirty_provinces.clear()
	return problems


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
		"blockade": 0,
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
	var f := _open_data("politics.json")
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			for i in parsed["ideologies"]:
				ideo_defs[i["id"]] = i
				ideo_order.append(i["id"])
			law_defs = parsed["laws"]
			law_defaults = parsed["defaults"]
	var f2 := _open_data("events.json")
	if f2 != null:
		var p2: Variant = JSON.parse_string(f2.get_as_text())
		if typeof(p2) == TYPE_DICTIONARY:
			event_defs = p2["events"]
	var f3 := _open_data("decisions.json")
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
		"provinces_min": return cells_of(c["id"]).size() >= int(v)
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
		if disabled_events.has(e["id"]):
			continue
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
			if cells_of(cid).size() >= 6:
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
		set_owner(p, rid)
		legal[p] = rid
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
	var f := _open_data("intel.json")
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
			for p in cells_of(tid):
				if best < 0 or provinces()[p]["industry"] > provinces()[best]["industry"]:
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


func _ai_navy(cid: int) -> void:
	var enemies := enemies_of(cid)
	var mine := fleets_of(cid)
	var idx := 0
	for f in mine:
		idx += 1
		if not f["path"].is_empty():
			continue
		var goals: Array[int] = []
		if not enemies.is_empty() and idx % 2 == 1:
			# blockade / raid: enemy ports and the lanes of their sea trade
			for e in enemies:
				for p in cells_of(e):
					if _coastal[p] == 1:
						var sn := sea_next_to(p)
						if sn >= 0 and not goals.has(sn):
							goals.append(sn)
			for t in trades:
				if enemies.has(t["buyer"]) or enemies.has(t["seller"]):
					for q in trade_route(t["buyer"], t["seller"]):
						if not goals.has(q):
							goals.append(q)
		else:
			# escort: sit on the lane of our own sea trade, else at home
			for t in trades:
				if t["buyer"] == cid or t["seller"] == cid:
					var r := trade_route(t["buyer"], t["seller"])
					if not r.is_empty():
						goals.append(r[r.size() / 2])
						break
			if goals.is_empty() and port_of(cid) >= 0:
				goals.append(sea_next_to(port_of(cid)))
		var best: Array = []
		for g in goals:
			if g == f["prov"]:
				best = []
				break
			var path := _sea_path(f["prov"], g)
			if not path.is_empty() and (best.is_empty() or path.size() < best.size()):
				best = path
		if not best.is_empty():
			f["path"] = best
			f["move"] = 0


func _ai_infra(cid: int) -> void:
	var c: Dictionary = countries[cid]
	if c["treasury"] < 300 or c["stock"]["steel"] < 60:
		return
	var best := -1
	for a in armies_of(cid):
		var p: int = a["prov"]
		if owner[p] == cid and infra[p] < MAX_INFRA and (best < 0 or infra[p] < infra[best]):
			best = p
	if best < 0 and owner[c["capital"]] == cid and infra[c["capital"]] < MAX_INFRA:
		best = c["capital"]
	if best >= 0:
		apply_command({"type": "build_infra", "country": cid, "province": best})


## Data files can be overridden by mods: user://mods/data/<name> wins over res://data/<name>.
static func _open_data(name: String) -> FileAccess:
	var mod_path := "user://mods/data/" + name
	if FileAccess.file_exists(mod_path):
		var mf := FileAccess.open(mod_path, FileAccess.READ)
		if mf != null:
			return mf
	return FileAccess.open("res://data/" + name, FileAccess.READ)


static func read_data(name: String) -> String:
	var f := _open_data(name)
	return f.get_as_text() if f != null else ""


static func load_unit_defs() -> Dictionary:
	var out := {}
	var f := _open_data("units.json")
	if f == null:
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		for u in parsed.get("units", []):
			out[u["id"]] = u
	return out


static func load_name_pool() -> Dictionary:
	var f := _open_data("generals.json")
	if f == null:
		return {"first": ["Генерал"], "last": ["Безымянный"]}
	return JSON.parse_string(f.get_as_text())


static func load_resource_defs() -> Array:
	var f := _open_data("resources.json")
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	return parsed.get("resources", [])


static func load_country_defs() -> Array:
	var f := _open_data("countries.json")
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
	out.assign(_cp.get(cid, []))
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
	if _nc_ver != _owner_ver:
		_nc.clear()
		_nc_ver = _owner_ver
	if not _nc.has(cid):
		var seen := {}
		var provs := provinces()
		for p in cells_of(cid):
			for q in provs[p]["land_neighbors"]:
				var o := owner[q]
				if o >= 0 and o != cid:
					seen[o] = true
		var keys: Array = seen.keys()
		keys.sort()
		var res: Array[int] = []
		res.assign(keys)
		_nc[cid] = res
	var out: Array[int] = []
	out.assign(_nc[cid])
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
	return _coastal[p] == 1


func sea_next_to(p: int) -> int:
	for q in provinces()[p]["neighbors"]:
		if not provinces()[q]["land"]:
			return q
	return -1


## Preferred port of a country: capital if coastal, else the first coastal province it owns.
func port_of(cid: int) -> int:
	var cap: int = countries[cid]["capital"]
	if owner[cap] == cid and _coastal[cap] == 1:
		return cap
	for p in cells_of(cid):
		if _coastal[p] == 1:
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
	for p in cells_of(target):
		if _coastal[p] == 1:
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
	var unix := Time.get_unix_time_from_datetime_string(start_date + "T00:00:00") + day * 86400
	return Time.get_date_string_from_unix_time(unix)


# --------------------------------------------------------------- commands

## Validated entry point for every player/network action.
## Multiplayer hooks (both unset in single player; never serialised):
##  - command_sink: a network CLIENT forwards every command to the host instead of applying it here;
##  - command_hook: the network HOST is told about every command that was applied, to broadcast it.
var command_sink := Callable()
var command_hook := Callable()


var _in_tick := false   # commands the simulation issues itself (AI) while a day is processed are replayed by every peer


func apply_command(cmd: Dictionary) -> Dictionary:
	if command_sink.is_valid() and not _in_tick:
		return command_sink.call(cmd)
	var res := _validate_and_run(cmd)
	if res["ok"]:
		command_log.append({"day": day, "cmd": cmd})
		if command_hook.is_valid() and not _in_tick:
			command_hook.call(cmd)
	return res


## A network client applies the host's already validated commands here (bypasses command_sink and command_hook).
func apply_remote_command(cmd: Dictionary) -> Dictionary:
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
		"build_infra":
			var ip: int = cmd.get("province", -1)
			if ip < 0 or ip >= owner.size() or owner[ip] != cid or not provinces()[ip]["land"]:
				return _fail("invalid province")
			if infra[ip] >= MAX_INFRA:
				return _fail("already maximal")
			var ic: Dictionary = countries[cid]
			var icost := 60 + 20 * infra[ip]
			if ic["treasury"] < icost:
				return _fail("not enough funds")
			if ic["stock"]["steel"] < 15:
				return _fail("not enough steel")
			ic["treasury"] -= icost
			ic["stock"]["steel"] -= 15
			infra[ip] += 1
			return {"ok": true}
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
		"market_buy":
			return _market_trade(cid, cmd.get("res", ""), int(cmd.get("amount", 1)), true)
		"market_sell":
			return _market_trade(cid, cmd.get("res", ""), int(cmd.get("amount", 1)), false)
		"build_missile":
			return _build_missile(cid, cmd.get("mtype", ""), int(cmd.get("count", 1)))
		"launch_missile":
			return _launch_missile(cid, cmd.get("mtype", ""), int(cmd.get("target", -1)))
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
		"impose_sanctions":
			var st: int = cmd.get("target", -1)
			if st < 0 or st >= countries.size() or st == cid or not countries[st]["alive"]:
				return _fail("invalid target")
			if allied(cid, st):
				return _fail("ally")
			if sanctioned_by(cid, st):
				return _fail("already sanctioned")
			if countries[cid]["pp"] < SANCTION_COST_PP:
				return _fail("not enough influence")
			countries[cid]["pp"] -= SANCTION_COST_PP
			sanctions.append({"a": cid, "b": st, "since": day})
			_log("%s: %s вводит санкции против %s (доход −%d%%)" % [date_string(), countries[cid]["name"], countries[st]["name"], sanction_pct(st)])
			return {"ok": true}
		"lift_sanctions":
			var ls: int = cmd.get("target", -1)
			var n_before := sanctions.size()
			sanctions = sanctions.filter(func(x): return not (x["a"] == cid and x["b"] == ls))
			if sanctions.size() == n_before:
				return _fail("no sanctions")
			_log("%s: %s снимает санкции с %s" % [date_string(), countries[cid]["name"], countries[ls]["name"]])
			return {"ok": true}
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
			var terms: String = cmd.get("terms", "status_quo")
			if terms != "status_quo" and terms != "annex":
				return _fail("invalid terms")
			if terms == "annex" and cells_held_from(cid, t4).is_empty():
				return _fail("nothing to annex")
			if not _ai_accepts_peace(t4, cid):
				return _fail("refused")
			if terms == "annex" and not _ai_accepts_annex(t4, cid):
				return _fail("refused terms")
			_end_war(cid, t4, "мирный договор")
			if terms == "annex":
				_settle_annex(cid, t4)
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
	_in_tick = true
	day += 1
	_logistics()
	_economy()
	_trade()
	_resources()
	if rule_markets:
		_population()
		_market()
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
	_in_tick = false


var _agg_base: Dictionary = {}
var _agg_base_ver := -1


## Adds (sign = 1) or removes (sign = -1) one cell's undamaged contribution to the per-country base sums.
func _agg_cell(base: Dictionary, o: int, p: int, sign: int) -> void:
	if not base.has(o):
		base[o] = {"prod": {}, "pop": 0, "ind": 0, "income": 0, "n": 0}
	var a: Dictionary = base[o]
	var pv: Dictionary = provinces()[p]
	for r in pv["deposits"]:
		a["prod"][r] = a["prod"].get(r, 0) + sign * pv["deposits"][r]
	a["pop"] += sign * pv["pop"]
	a["ind"] += sign * ((pv["industry"] * 100 + 50) / 100)
	a["income"] += sign * (pv["pop"] * pv["industry"] * 100 / 10000)
	a["n"] += sign
	if a["n"] == 0:
		base.erase(o)


## Per-country sums of production, population, industry and income. The undamaged sums are cached until ownership changes;
## each call only adds the (exact, integer) correction of the currently damaged cells.
func _aggregate() -> Dictionary:
	var provs := provinces()
	if _agg_base_ver != _owner_ver or _agg_base.is_empty():
		var base := {}
		for p in owner.size():
			if owner[p] >= 0:
				_agg_cell(base, owner[p], p, 1)
		_agg_base = base
		_agg_base_ver = _owner_ver
		_agg_key = []
	var key := [_owner_ver, hash(damage)]
	if not _agg.is_empty() and _agg_key == key:
		return _agg
	var agg := {}
	for o in _agg_base:
		var b: Dictionary = _agg_base[o]
		agg[o] = {"prod": b["prod"], "pop": b["pop"], "ind": b["ind"], "income": b["income"]}
	for p in damage.size():
		var d := damage[p]
		if d == 0:
			continue
		var o2 := owner[p]
		if o2 < 0:
			continue
		var pv2: Dictionary = provs[p]
		var a2: Dictionary = agg[o2]
		a2["ind"] += (pv2["industry"] * (100 - d) + 50) / 100 - (pv2["industry"] * 100 + 50) / 100
		a2["income"] += pv2["pop"] * pv2["industry"] * (100 - d) / 10000 - pv2["pop"] * pv2["industry"] * 100 / 10000
	_agg = agg
	_agg_key = key
	return agg


func _economy() -> void:
	var provs := provinces()
	for c in countries:
		if not c["alive"]:
			continue
		c["income"] = 0
		c["upkeep"] = 0
	var agg := _aggregate()
	for o in agg:
		if countries[o]["alive"]:
			countries[o]["income"] = agg[o]["income"]
	for a in armies:
		countries[a["owner"]]["upkeep"] += a["strength"] / 200
	for f in fleets:
		countries[f["owner"]]["upkeep"] += f["strength"] / 150
	for c in countries:
		if c["alive"]:
			c["income"] = c["income"] * (100 + mod(c["id"], "income_pct")) * (100 - c["blockade"] / 5) * (100 - sanction_pct(c["id"])) / 1000000
			c["upkeep"] = c["upkeep"] * (100 + mod(c["id"], "upkeep_pct")) / 100
			if rule_modern:
				# abstract cyber pressure: enemies at war reduce income, cyber defence offsets it (at most -25%)
				var hit := 0
				for e in enemies_of(c["id"]):
					hit += mod(e, "cyber_pct")
				hit = clampi(hit - mod(c["id"], "cyber_def_pct"), 0, 25)
				if hit > 0:
					c["income"] = c["income"] * (100 - hit) / 100
	for c in countries:
		if c["alive"]:
			c["treasury"] += c["income"] - c["upkeep"]
			if c["treasury"] < 0:
				c["treasury"] = 0
				# unpaid armies lose strength
				for a in armies:
					if a["owner"] == c["id"]:
						_hurt(a, a["strength"] / 50)


func sanctioned_by(a: int, b: int) -> bool:
	for x in sanctions:
		if x["a"] == a and x["b"] == b:
			return true
	return false


## How many (living) countries sanction `target`.
func sanction_level(target: int) -> int:
	var n := 0
	for x in sanctions:
		if x["b"] == target and countries[x["a"]]["alive"]:
			n += 1
	return n


## Share of its income `target` loses to sanctions (stacks per sanctioning country, capped).
func sanction_pct(target: int) -> int:
	return mini(SANCTION_MAX_PCT, SANCTION_INCOME_PCT * sanction_level(target))


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


## A port province is blockaded when an enemy fleet sits in an adjacent sea and no friendly fleet contests it.
func port_blockaded(p: int, cid: int) -> bool:
	var provs := provinces()
	var enemy_here := false
	var friend_here := false
	for q in provs[p]["neighbors"]:
		if provs[q]["land"]:
			continue
		for f in fleets:
			if f["prov"] != q or f["strength"] <= 0:
				continue
			if f["owner"] == cid or allied(cid, f["owner"]):
				friend_here = true
			elif at_war(cid, f["owner"]):
				enemy_here = true
	return enemy_here and not friend_here


func _fleets_by_sea() -> Dictionary:
	var idx := {}
	for f in fleets:
		if f["strength"] > 0:
			if not idx.has(f["prov"]):
				idx[f["prov"]] = []
			idx[f["prov"]].append(f["owner"])
	return idx


func _port_blockaded_idx(p: int, cid: int, idx: Dictionary) -> bool:
	var provs := provinces()
	var enemy_here := false
	for q in provs[p]["neighbors"]:
		if provs[q]["land"] or not idx.has(q):
			continue
		var friend := false
		var enemy := false
		for o in idx[q]:
			if o == cid or allied(cid, o):
				friend = true
			elif at_war(cid, o):
				enemy = true
		if friend:
			return false
		if enemy:
			enemy_here = true
	return enemy_here


func blockade_level(cid: int, idx: Dictionary = {}) -> int:
	var use: Dictionary = idx if not idx.is_empty() else _fleets_by_sea()
	var ports := 0
	var blocked := 0
	for p in cells_of(cid):
		if _coastal[p] == 1:
			ports += 1
			if _port_blockaded_idx(p, cid, use):
				blocked += 1
	return blocked * 100 / ports if ports > 0 else 0


func trade_route(buyer: int, seller: int) -> Array:
	if neighbor_countries(buyer).has(seller):
		return []
	var pb := port_of(buyer)
	var ps := port_of(seller)
	if pb < 0 or ps < 0:
		return []
	var a := sea_next_to(pb)
	var b := sea_next_to(ps)
	if a < 0 or b < 0:
		return []
	var path := _sea_path(a, b)
	path.push_front(a)
	return path


func _lane_forces(route: Array, buyer: int, seller: int) -> Vector2:
	var raiders := 0.0
	var escorts := 0.0
	for f in fleets:
		if f["strength"] <= 0 or not route.has(f["prov"]):
			continue
		var o: int = f["owner"]
		if o == buyer or o == seller or allied(o, buyer) or allied(o, seller):
			escorts += f["strength"]
		elif at_war(o, buyer) or at_war(o, seller):
			raiders += f["strength"]
	return Vector2(raiders, escorts)


func _logistics() -> void:
	if fleets.is_empty():
		for c in countries:
			c["blockade"] = 0
		_blockade_key = []   # values were reset: the next non-empty computation must not be skipped
		return
	# the blockade is a pure function of cell owners, fleet positions, wars and alliances: skip the O(all cells) pass
	# when none of them changed since the last computation
	var fleet_key := PackedInt32Array()
	for f in fleets:
		if f["strength"] > 0:
			fleet_key.append(f["prov"])
			fleet_key.append(f["owner"])
	var key := [_owner_ver, fleet_key, hash(wars), hash(alliances), countries.size(), alive_count()]
	if _blockade_key == key:
		return
	_blockade_key = key
	var idx := _fleets_by_sea()
	var fleet_owners := {}
	for f in fleets:
		if f["strength"] > 0:
			fleet_owners[f["owner"]] = true
	for c in countries:
		if c["alive"]:
			# a port is blockaded only by a fleet of a country at war with the owner
			var threatened := false
			for e in enemies_of(c["id"]):
				if fleet_owners.has(e):
					threatened = true
					break
			c["blockade"] = blockade_level(c["id"], idx) if threatened else 0


func _trade() -> void:
	var kept: Array = []
	for t in trades:
		var b: Dictionary = countries[t["buyer"]]
		var s: Dictionary = countries[t["seller"]]
		if not b["alive"] or not s["alive"] or at_war(t["buyer"], t["seller"]) or _embargoed(t["buyer"], t["seller"]):
			continue
		var cost: int = t["amount"] * t["price"]
		var route := trade_route(t["buyer"], t["seller"])
		if not route.is_empty():
			if b["blockade"] >= 50 or s["blockade"] >= 50:
				t["fails"] += 1
				if t["fails"] <= 15:
					kept.append(t)
				continue
			var forces := _lane_forces(route, t["buyer"], t["seller"])
			if forces.x > forces.y and s["stock"][t["res"]] >= t["amount"]:
				s["stock"][t["res"]] -= t["amount"]  # shipment sunk
				if day % 10 == 0:
					_log("%s: конвой %s → %s потоплен рейдерами" % [date_string(), s["name"], b["name"]])
				kept.append(t)
				continue
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
	var pop_sum := {}
	var ind_sum := {}
	for c in countries:
		if c["alive"]:
			c["prod"] = _zero_res()
			c["cons"] = _zero_res()
			c["short"] = []
			pop_sum[c["id"]] = 0
			ind_sum[c["id"]] = 0
	# per-owner military totals in one pass (each country only ever hurts its own armies below, so these stay valid)
	var astr_of := {}
	var fstr_of := {}
	var armor_of := {}
	for a in armies:
		var ao: int = a["owner"]
		astr_of[ao] = astr_of.get(ao, 0) + a["strength"]
		for d in a["div"]:
			if unit_defs[d["t"]]["oil"]:
				armor_of[ao] = armor_of.get(ao, 0) + d["hp"]
	for f in fleets:
		fstr_of[f["owner"]] = fstr_of.get(f["owner"], 0) + f["strength"]
	var agg := _aggregate()
	var armies_by_owner := {}   # one pass instead of a scan over all armies per country (O(countries x armies))
	for a in armies:
		var ao: int = a["owner"]
		if not armies_by_owner.has(ao):
			armies_by_owner[ao] = []
		armies_by_owner[ao].append(a)
	for o in agg:
		if not countries[o]["alive"]:
			continue
		for r in agg[o]["prod"]:
			countries[o]["prod"][r] += agg[o]["prod"][r]
		pop_sum[o] = agg[o]["pop"]
		ind_sum[o] = agg[o]["ind"]
	for c in countries:
		if not c["alive"]:
			continue
		var cid: int = c["id"]
		var st: Dictionary = c["stock"]
		for rr in ["food", "coal", "iron", "oil"]:
			c["prod"][rr] = c["prod"][rr] * (100 + mod(cid, rr + "_pct")) / 100
		c["industry"] = ind_sum[cid]
		c["cons"]["food"] = pop_sum[cid] * pop_index(cid) / 10000 / 90
		var astr: int = astr_of.get(cid, 0)
		var fstr: int = fstr_of.get(cid, 0)
		var armor_hp: int = armor_of.get(cid, 0)
		c["cons"]["oil"] = (astr - armor_hp) / 4000 + armor_hp / 1000 + 2 * fstr / 2000 + air_oil(cid)
		c["manpower"] = mini(c["manpower"] + pop_sum[cid] * pop_index(cid) / 10000 * (100 + mod(cid, "manpower_pct")) / 20000, 2000)
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
			for a in armies_by_owner.get(cid, []):
				_hurt(a, a["strength"] / (100 if c["short"].has("oil") else 200) * (100 - mini(mod(cid, "attrition_pct"), 90)) / 100)


func net_of(cid: int, res: String) -> int:
	var c: Dictionary = countries[cid]
	return c["prod"][res] - c["cons"][res]


## Day of the year (1..366) of the scenario start; used by the seasonal model.
func _compute_start_doy() -> void:
	var cum := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
	var parts := start_date.split("-")
	if parts.size() == 3:
		_start_doy = cum[clampi(int(parts[1]) - 1, 0, 11)] + int(parts[2])
	else:
		_start_doy = 1


func _ensure_cell_lat() -> void:
	if _cell_lat.size() == provinces().size():
		return
	_cell_lat = PackedFloat32Array()
	_cell_lat.resize(provinces().size())
	var res := float(world.get("res", 0.0))
	var top := float(world.get("lat_top", 0.0))
	for p in provinces():
		_cell_lat[p["id"]] = top - (p["center"].y + 0.5) * res if res > 0.0 else 45.0


## Winter severity 0..100 at a cell: peaks mid-January in the north (mid-July in the south) and grows with latitude (integer maths).
func winter_at(cell: int) -> int:
	_ensure_cell_lat()
	var lat := int(_cell_lat[cell])
	var doy := (_start_doy + day - 1) % 365
	var dist := mini(absi(doy - 15), 365 - absi(doy - 15))   # 0..182 days from mid-January
	var north := 100 - dist * 100 / 182
	var w := north if lat >= 0 else 100 - north
	var lat_f := clampi((absi(lat) - 25) * 100 / 40, 0, 100)
	return w * lat_f / 100


## Local storm (≈7% of cell-days), deterministic from the calendar and the cell.
func storm_at(cell: int) -> bool:
	return ((day / 3) * 7919 + (cell / 37) * 104729) % 100 < 7


## Days an army needs to enter `to_cell` from `from_cell` (3 by default). Roads and railways speed it up, terrain and weather slow it.
func move_days(from_cell: int, to_cell: int) -> int:
	if not rule_terrain and not rule_weather:
		return MOVE_DAYS
	var pct := 100
	if rule_terrain:
		pct = TERRAIN_MOVE.get(provinces()[to_cell]["terrain"], 100)
		var key := mini(from_cell, to_cell) * 100000 + maxi(from_cell, to_cell)
		if world.get("rail_link", {}).has(key):
			pct = pct * 50 / 100
		elif world.get("road_link", {}).has(key):
			pct = pct * 75 / 100
	if rule_weather:
		pct = pct * (100 + winter_at(to_cell) * 80 / 100) / 100
		if storm_at(to_cell):
			pct = pct * 130 / 100
	return maxi(1, (MOVE_DAYS * pct + 50) / 100)


func _move_armies() -> void:
	for a in armies:
		if a["path"].is_empty():
			continue
		a["move"] += 1
		var next_cell: int = a["path"][0]
		if a["move"] < move_days(a["prov"], next_cell):
			continue
		a["move"] = 0
		var nxt: int = next_cell
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
		set_owner(p, cid)
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
	_settle_annex(winner, loser)   # surrender is a treaty too: what the winner holds becomes recognised


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
		if cells_of(c["id"]).is_empty():
			c["alive"] = false
			_log("%s: государство %s уничтожено" % [date_string(), c["name"]])
			wars = wars.filter(func(w): return w["a"] != c["id"] and w["b"] != c["id"])
			armies = armies.filter(func(a): return a["owner"] != c["id"])
			fleets = fleets.filter(func(f): return f["owner"] != c["id"])
			alliances = alliances.filter(func(al): return al["a"] != c["id"] and al["b"] != c["id"])
			trades = trades.filter(func(t): return t["buyer"] != c["id"] and t["seller"] != c["id"])
			sanctions = sanctions.filter(func(x): return x["a"] != c["id"] and x["b"] != c["id"])


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
func eff_infra(p: int) -> int:
	return maxi(1, infra[p] - damage[p] / 30)


## Supply distance from hubs. Cost per step depends on infrastructure (own land ~5-9, hostile ~20-24).
func _supply_dist(cid: int, targets: Array = []) -> Dictionary:
	var provs := provinces()
	var dist := {}
	var buckets: Array = []
	for _i in SUPPLY_RANGE + 1:
		buckets.append([])
	var cap: int = countries[cid]["capital"]
	if owner[cap] == cid:
		dist[cap] = 0
		buckets[0].append(cap)
	else:
		for p in cells_of(cid):
			dist[p] = 60
			buckets[60].append(p)
			break
	if not fleets_of(cid).is_empty():
		for p in cells_of(cid):
			if _coastal[p] == 1 and not dist.has(p) and not port_blockaded(p, cid):
				dist[p] = 80
				buckets[80].append(p)
	var need := {}
	for t in targets:
		need[t] = true
	var enemy_set := {}
	for e in enemies_of(cid):
		enemy_set[e] = true
	var ally_set := {}
	for al in allies_of(cid):
		ally_set[al] = true
	var terr_extra := _terrain_supply_extra() if rule_terrain else PackedInt32Array()
	for d in SUPPLY_RANGE + 1:
		for p in buckets[d]:
			if dist[p] != d:
				continue
			if not need.is_empty() and need.has(p):
				need.erase(p)
				if need.is_empty():
					return dist  # every army's supply distance is final
			for q in provs[p]["land_neighbors"]:
				var o := owner[q]
				var hostile := o >= 0 and o != cid and enemy_set.has(o)
				var eff := maxi(1, infra[q] - damage[q] / 30)
				var cost: int = (10 - eff) if (o == cid or ally_set.has(o)) else (25 - eff)
				if rule_terrain:
					cost += terr_extra[q]
				if rule_weather:
					cost += _winter_cached(q) / 20
				var nd := d + cost
				if nd <= SUPPLY_RANGE and nd < dist.get(q, 9999):
					dist[q] = nd
					if not hostile:  # supply never flows THROUGH enemy-held cells => encirclement cuts it
						buckets[nd].append(q)
	return dist


var _terr_extra_cache := PackedInt32Array()
var _winter_val := PackedInt32Array()
var _winter_stamp := PackedInt32Array()


func _terrain_supply_extra() -> PackedInt32Array:
	var provs := provinces()
	if _terr_extra_cache.size() != provs.size():
		_terr_extra_cache = PackedInt32Array()
		_terr_extra_cache.resize(provs.size())
		for p in provs:
			_terr_extra_cache[p["id"]] = TERRAIN_SUPPLY_EXTRA.get(p["terrain"], 0)
	return _terr_extra_cache


## winter_at() memoised per day (it is called for the same cells many times during supply searches).
func _winter_cached(cell: int) -> int:
	if _winter_val.size() != provinces().size():
		_winter_val.resize(provinces().size())
		_winter_stamp.resize(provinces().size())
		_winter_stamp.fill(-1)
	if _winter_stamp[cell] != day:
		_winter_val[cell] = winter_at(cell)
		_winter_stamp[cell] = day
	return _winter_val[cell]


var _ind_ver := -1
var _ind_cache := {}


## Raw industry sum of a country, cached until the ownership of any cell changes.
func _industry_of(cid: int) -> int:
	if _ind_ver != _owner_ver:
		_ind_cache = {}
		_ind_ver = _owner_ver
	if not _ind_cache.has(cid):
		var provs := provinces()
		var sum := 0
		for p in cells_of(cid):
			sum += provs[p]["industry"]
		_ind_cache[cid] = sum
	return _ind_cache[cid]


func _supply() -> void:
	var provs := provinces()
	var by_owner := {}
	for a in armies:
		if not by_owner.has(a["owner"]):
			by_owner[a["owner"]] = []
		by_owner[a["owner"]].append(a)
	var ids: Array = by_owner.keys()
	ids.sort()
	for cid in ids:
		var c: Dictionary = countries[cid]
		if not c["alive"] or (day + cid) % SUPPLY_EVERY != 0:
			continue
		var mine: Array = by_owner[cid]
		var targets: Array = []
		var demand := 0
		for a in mine:
			demand += a["div"].size()
			if provs[a["prov"]]["land"]:
				targets.append(a["prov"])
		var dist := _supply_dist(cid, targets)
		var industry := _industry_of(cid)
		var factor := minf(1.0, float(6 + industry) * (100 + mod(cid, "supply_pct")) / 100.0 / maxf(demand, 1.0))
		for a in mine:
			var d: int = dist.get(a["prov"], 9999)
			if not provs[a["prov"]]["land"]:
				d = 80
			a["supply"] = int(clampf(1.0 - d * 0.01 * (100 - mini(mod(cid, "supply_decay_pct"), 80)) / 100.0, 0.0, 1.0) * factor * 100.0)
			if a["supply"] < 20:
				_hurt(a, a["strength"] * SUPPLY_EVERY / 100)


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


## Cells `holder` controls (owner[]) that are legally (legal[]) another country's.
func cells_held_from(holder: int, legal_owner: int) -> Array[int]:
	var out: Array[int] = []
	for p in cells_of(holder):
		if legal[p] == legal_owner:
			out.append(p)
	return out


## The only way recognised ownership (legal[]) changes in a war: a peace treaty with the "annex" term.
## The winner gets legal title to everything it holds from the loser; whatever the loser still holds of the
## winner's legal land is handed back. Control (owner[]) of annexed cells does not change.
func _settle_annex(winner: int, loser: int) -> void:
	var annexed := cells_held_from(winner, loser)
	for p in annexed:
		legal[p] = winner
		dirty_provinces.append(p)
	var returned := cells_held_from(loser, winner)
	for p in returned:
		set_owner(p, winner)
		dirty_provinces.append(p)
	var cap: int = countries[loser]["capital"]
	if cap < 0 or owner[cap] != loser:
		var rest := cells_of(loser)
		if not rest.is_empty():
			countries[loser]["capital"] = rest[0]
	_log("%s: договор — %s: признано за ним %d яч. государства %s%s" % [date_string(), countries[winner]["name"], annexed.size(), countries[loser]["name"], ", возвращено ему %d яч." % returned.size() if not returned.is_empty() else ""])


## An AI only accepts losing recognised land to a clearly stronger enemy (on top of the normal peace conditions).
func _ai_accepts_annex(ai: int, other: int) -> bool:
	return army_strength(other) >= army_strength(ai) * 1.5


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


# ---------------------------------------------------------------- population and world market (rules.markets)

## Population index (basis points, 10000 = scenario start). Scales food demand and manpower growth.
func pop_index(cid: int) -> int:
	return int(pop_bp.get(cid, 10000)) if rule_markets else 10000


## Daily population dynamics (integer maths): slow growth, famine and war devastation shrink a country.
func _population() -> void:
	var provs := provinces()
	for c in countries:
		if not c["alive"]:
			continue
		var cid: int = c["id"]
		var bp: int = pop_bp.get(cid, 10000)
		if day % 4 == 0:
			bp += 1                                  # ~0.9 % per year
		if c["short"].has("food"):
			bp -= 4                                  # famine: -0.04 % per day
		if day % 10 == 0 and not enemies_of(cid).is_empty():
			var hurt := 0
			for p in cells_of(cid):
				if damage[p] > 40:
					hurt += 1
			bp -= mini(30, hurt / 4)                 # devastated cells lose people
		pop_bp[cid] = clampi(bp, 5000, 15000)


func market_price_x100(res: String) -> int:
	return price_of(res) * int(market_pct.get(res, 100))


## World prices follow global demand/supply every 5 days (smoothed, 50..300 % of base) and players' own trades push them.
func _market() -> void:
	if day % 5 != 0:
		return
	for r in MARKET_RES:
		var prod := 1
		var cons := 1
		for c in countries:
			if c["alive"]:
				prod += c["prod"].get(r, 0)
				cons += c["cons"].get(r, 0)
		var target := clampi(cons * 100 / prod, 50, 300) + int(_market_flow.get(r, 0)) * 2
		var cur: int = market_pct.get(r, 100)
		market_pct[r] = clampi((cur * 9 + target) / 10, 50, 300)
		_market_flow[r] = 0


func _market_trade(cid: int, res: String, amount: int, buy: bool) -> Dictionary:
	if not rule_markets:
		return _fail("rule disabled")
	if not MARKET_RES.has(res):
		return _fail("invalid resource")
	amount = clampi(amount, 1, 20)
	var c: Dictionary = countries[cid]
	var unit := market_price_x100(res)
	if buy:
		var cost := maxi(1, (unit * amount * (100 + MARKET_SPREAD) + 9999) / 10000)
		if c["treasury"] < cost:
			return _fail("not enough funds")
		if c["stock"][res] + amount > STOCK_CAP:
			return _fail("stock full")
		c["treasury"] -= cost
		c["stock"][res] += amount
		_market_flow[res] = int(_market_flow.get(res, 0)) + amount
	else:
		if c["stock"][res] < amount:
			return _fail("not enough stock")
		var gain := unit * amount * (100 - MARKET_SPREAD) / 10000
		c["treasury"] += gain
		c["stock"][res] -= amount
		_market_flow[res] = int(_market_flow.get(res, 0)) - amount
	return {"ok": true}


## AI keeps its stocks afloat: buys what it lacks, sells large surpluses.
func _ai_market(cid: int) -> void:
	if day % 5 != 0:
		return
	var c: Dictionary = countries[cid]
	for r in MARKET_RES:
		if c["short"].has(r) and c["treasury"] > 150:
			_market_trade(cid, r, 5, true)
		elif c["stock"][r] > STOCK_CAP * 8 / 10:
			_market_trade(cid, r, 10, false)


# ---------------------------------------------------------------- missiles and air defence (abstract, rules.modern)

const MISSILE_START := {"tactical": 3, "strategic": 0}


## Missiles in stock (read-only: never creates state).
func missile_count(cid: int, mtype: String) -> int:
	return int(missile_stock.get(cid, MISSILE_START).get(mtype, 0))


func _set_missiles(cid: int, mtype: String, n: int) -> void:
	if not missile_stock.has(cid):
		missile_stock[cid] = MISSILE_START.duplicate()
	missile_stock[cid][mtype] = n


## Chance (percent) that a launch against this country is shot down.
func air_defense(cid: int) -> int:
	return clampi(8 + mod(cid, "ad_pct"), 0, 80)


func _build_missile(cid: int, mtype: String, count: int) -> Dictionary:
	if not rule_modern:
		return _fail("rule disabled")
	if not MISSILE_DEFS.has(mtype):
		return _fail("invalid missile")
	var d: Dictionary = MISSILE_DEFS[mtype]
	var c: Dictionary = countries[cid]
	if not c["techs"].has(d["tech"]):
		return _fail("technology required")
	count = clampi(count, 1, 10)
	if missile_count(cid, mtype) + count > MISSILE_CAP:
		return _fail("stock full")
	if c["treasury"] < d["cost"] * count:
		return _fail("not enough funds")
	if c["stock"]["steel"] < d["steel"] * count:
		return _fail("not enough steel")
	c["treasury"] -= d["cost"] * count
	c["stock"]["steel"] -= d["steel"] * count
	_set_missiles(cid, mtype, missile_count(cid, mtype) + count)
	return {"ok": true}


## Nearest own land cell from which `target` is within `range_cells` hops (-1 if none).
func missile_site(cid: int, target: int, range_cells: int) -> int:
	var best := -1
	var best_d := 9999
	var r := reach(target, range_cells)
	var provs := provinces()
	for p in r:
		if owner[p] == cid and provs[p]["land"]:
			var dd: int = r[p]
			if dd < best_d or (dd == best_d and p < best):
				best_d = dd
				best = p
	return best


func _launch_missile(cid: int, mtype: String, target: int) -> Dictionary:
	if not rule_modern:
		return _fail("rule disabled")
	if not MISSILE_DEFS.has(mtype):
		return _fail("invalid missile")
	if target < 0 or target >= owner.size() or not provinces()[target]["land"]:
		return _fail("land target required")
	var def_owner := owner[target]
	if def_owner < 0 or not at_war(cid, def_owner):
		return _fail("target not at war")
	if missile_count(cid, mtype) <= 0:
		return _fail("no missiles")
	var d: Dictionary = MISSILE_DEFS[mtype]
	var from := missile_site(cid, target, d["range"] + mod(cid, "air_range"))
	if from < 0:
		return _fail("out of range")
	_set_missiles(cid, mtype, missile_count(cid, mtype) - 1)
	var chance := clampi(air_defense(def_owner) - mod(cid, "missile_pen_pct"), 0, 85)
	var hit := rng.randi_range(0, 99) >= chance
	strikes.append({"day": day, "owner": cid, "from": from, "target": target, "type": mtype, "hit": hit})
	if strikes.size() > 40:
		strikes.pop_front()
	var where := "ячейка #%d" % target
	if is_earth_world():
		var rn := EarthWorld.region_name(world, int(provinces()[target].get("region", 0)))
		if rn != "":
			where = rn
	if hit:
		damage[target] = mini(100, damage[target] + d["dmg"])
		for a in armies:
			if a["prov"] == target and a["owner"] != cid and at_war(cid, a["owner"]):
				_hurt(a, a["strength"] * d["army_pct"] / 100)
		_log("%s: %s наносит удар (%s) по территории %s — %s" % [date_string(), countries[cid]["name"], d["name"], countries[def_owner]["name"], where])
	else:
		_log("%s: ПВО страны %s перехватила ракету (%s) из %s" % [date_string(), countries[def_owner]["name"], d["name"], countries[cid]["name"]])
	_aggregate_dirty()
	return {"ok": true, "hit": hit}


func _aggregate_dirty() -> void:
	_agg_key = []   # damage changed: per-country sums must be recomputed


func _ai_missiles(cid: int) -> void:
	var c: Dictionary = countries[cid]
	var enemies := enemies_of(cid)
	if enemies.is_empty():
		return
	if day % 7 == 0 and c["treasury"] >= 260 and c["stock"]["steel"] >= 60:
		for mt in ["strategic", "tactical"]:
			if c["techs"].has(MISSILE_DEFS[mt]["tech"]) and missile_count(cid, mt) < 6:
				_build_missile(cid, mt, 1)
				break
	if day % 6 != 0:
		return
	for mt in ["strategic", "tactical"]:
		if missile_count(cid, mt) <= 0:
			continue
		var best := -1
		var best_v := -1
		for t in cells_of_enemies(enemies):
			var v: int = provinces()[t]["industry"] * 10 + armies_in(t).size() * 4 - damage[t] / 10
			if v > best_v and missile_site(cid, t, MISSILE_DEFS[mt]["range"] + mod(cid, "air_range")) >= 0:
				best_v = v
				best = t
		if best >= 0:
			_launch_missile(cid, mt, best)
			return


func cells_of_enemies(enemies: Array) -> Array:
	var out: Array = []
	for e in enemies:
		out.append_array(cells_of(e))
	return out


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
		if enemies.is_empty() and day >= grace_days and day - c["last_peace"] > 30 and armies_of(cid).size() >= 2 and (ai_war_chance >= 1.0 or rng.randf() < ai_war_chance):
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
				if not cells_held_from(e, cid).is_empty() and army_strength(e) >= my_str * 1.5:
					_settle_annex(e, cid)   # the clearly stronger side keeps what it holds (same rule as the player's treaty)
				enemies = enemies_of(cid)
		# naval: build fleets
		if day % 10 == 0:
			_ai_trade(cid)
		if c["treasury"] >= FLEET_COST * 3 and c["stock"]["steel"] >= FLEET_STEEL and port_of(cid) >= 0 and fleets_of(cid).size() < mini(4, 1 + cells_of(cid).size() / 10):
			c["treasury"] -= FLEET_COST
			c["stock"]["steel"] -= FLEET_STEEL
			_spawn_fleet(cid, sea_next_to(port_of(cid)))
		# economic: build armies
		if c["treasury"] >= 120 and divisions_of(cid) < 6 + cells_of(cid).size():
			var kinds := ["infantry", "infantry", "armor", "artillery"]
			_train(cid, kinds[(day / 5 + cid) % kinds.size()])
		_ai_generals(cid)
		_ai_air(cid)
		if rule_modern:
			_ai_missiles(cid)
		if rule_markets:
			_ai_market(cid)
		if day % 10 == 0:
			_ai_politics(cid)
		if day % 15 == 0:
			_ai_intel(cid)
		if day % 10 == 0:
			_ai_navy(cid)
		if day % 20 == 0:
			_ai_infra(cid)
		if day % 10 == 0:
			_ai_research(cid)
		if day % 10 == 0:
			_ai_merge(cid)
		# military: send idle armies at the nearest enemy target
		if enemies.is_empty():
			continue
		_ai_retreat_starving(cid)
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


## Armies deep in enemy land lose supply (and 1%/day strength below 20%): the AI pulls them back to its own territory
## instead of letting them starve. Returns the number of armies ordered back.
func _ai_retreat_starving(cid: int) -> int:
	var ordered := 0
	for a in armies_of(cid):
		if a["supply"] >= STARVING_SUPPLY or not provinces()[a["prov"]]["land"]:
			continue
		var here := owner[a["prov"]]
		if here == cid or allied(cid, here):
			continue
		var path := _bfs(a["prov"], cid, func(p): return owner[p] == cid, false)
		if not path.is_empty():
			a["path"] = path
			a["move"] = 0
			ordered += 1
	return ordered


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
		var tried := {}
		var cand: Array = neighbor_countries(cid)
		var n := countries.size()
		for k in mini(16, n):  # plus a rotating window of other partners (keeps AI cost bounded with 200 countries)
			cand.append((day / 10 * 7 + cid * 13 + k * 11) % n)
		for oid in cand:
			if oid == cid or tried.has(oid):
				continue
			tried[oid] = true
			var other: Dictionary = countries[oid]
			if other["alive"] and other["ai"] and _try_trade(cid, oid, res, want)["ok"]:
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
		"next_army_id": next_army_id, "world_kind": str(world.get("kind", "procedural")), "world_dataset": str(world.get("dataset", "world")), "world_hash": str(world.get("world_hash", "")), "legal": legal, "next_general_id": next_general_id, "start_date": start_date, "disabled_events": disabled_events, "grace_days": grace_days, "scenario_id": scenario_id, "ai_war_chance": ai_war_chance, "rule_terrain": rule_terrain, "rule_weather": rule_weather, "rule_modern": rule_modern, "rule_markets": rule_markets, "pop_bp": pop_bp, "market_pct": market_pct, "market_flow": _market_flow, "missile_stock": missile_stock, "strikes": strikes, "scenario_deposits": scenario_deposits, "infra": infra, "ops": ops, "next_op_id": next_op_id, "next_event_uid": next_event_uid, "wings": wings, "next_wing_id": next_wing_id, "damage": damage, "fleets": fleets, "next_fleet_id": next_fleet_id, "alliances": alliances, "trades": trades, "next_trade_id": next_trade_id, "embargoes": embargoes, "sanctions": sanctions, "rng_state": rng.state, "command_log": command_log,
	}


static func from_dict(d: Dictionary, country_defs: Array) -> Simulation:
	var sim := Simulation.new()
	sim.seed_value = d["seed"]
	if str(d.get("world_kind", "procedural")) == "earth":
		var ds2 := str(d.get("world_dataset", "world"))
		if not EarthWorld.available_dataset(ds2):
			sim.load_error = "real-world dataset is missing (%s)" % ds2
			return sim
		EarthWorld.activate(ds2)
		sim._own_earth_world()
		if str(d.get("world_hash", "")) != str(sim.world.get("world_hash", "")):
			sim.load_error = "save was made with a different world dataset (%s)" % str(d.get("world_hash", "")).substr(0, 8)
			return sim
	else:
		sim.world = WorldGen.generate(sim.seed_value)
	sim.day = d["day"]
	sim.owner = d["owner"]
	sim.legal = d.get("legal", d["owner"].duplicate())   # migration: v10 saves have no separate legal ownership
	sim._rebuild_caches()
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
	sim.sanctions = d.get("sanctions", [])   # saves from before sanctions have none
	sim.res_defs = load_resource_defs()
	sim.unit_defs = load_unit_defs()
	sim.name_pool = load_name_pool()
	sim.rule_modern = bool(d.get("rule_modern", false))
	sim.rule_markets = bool(d.get("rule_markets", false))
	sim.pop_bp = d.get("pop_bp", {})
	sim.market_pct = d.get("market_pct", {})
	sim._market_flow = d.get("market_flow", {})
	sim.missile_stock = d.get("missile_stock", {})
	sim.strikes = d.get("strikes", [])
	sim._load_techs()
	sim.next_general_id = d["next_general_id"]
	sim.start_date = d["start_date"]
	sim.disabled_events = d["disabled_events"]
	sim.grace_days = d["grace_days"]
	sim.scenario_id = d["scenario_id"]
	sim.ai_war_chance = float(d.get("ai_war_chance", 1.0))
	sim.rule_terrain = bool(d.get("rule_terrain", false))
	sim.rule_weather = bool(d.get("rule_weather", false))
	sim._compute_start_doy()
	sim.scenario_deposits = d["scenario_deposits"]
	for k in sim.scenario_deposits:
		sim.set_deposits(int(k), sim.scenario_deposits[k])
	sim.infra = d["infra"]
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
	# legal[] is part of the state hash: treaties and capitulations change it, a multiplayer desync there must be detected
	var parts := [day, owner, legal, countries, armies, fleets, wings, damage, infra, alliances, trades, embargoes, wars, rng.state]
	if not sanctions.is_empty():
		parts.append(sanctions)   # only when present: a game without sanctions keeps the checksum it always had
	if rule_markets:
		parts.append([pop_bp, market_pct, _market_flow])
	if rule_modern:
		parts.append([missile_stock, strikes])   # only with the rule: other scenarios keep their reference checksums
	return var_to_str(parts).hash()
