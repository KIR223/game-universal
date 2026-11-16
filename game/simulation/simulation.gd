class_name Simulation
extends RefCounted
## Headless, deterministic game simulation. No Node/graphics dependencies.
## All mutations from players go through apply_command(); time advances via tick_day().

const SAVE_VERSION := 5
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
	world = WorldGen.generate(seed_value)
	var caps := WorldGen.pick_capitals(world, country_defs.size(), rng)
	owner = WorldGen.assign_owners(world, caps)
	countries.clear()
	for i in caps.size():
		var d: Dictionary = country_defs[i]
		countries.append({
			"id": i, "tag": d["tag"], "name": d["name"], "color": d["color"],
			"capital": caps[i], "treasury": 120, "income": 0, "upkeep": 0,
			"ai": true, "alive": true, "last_peace": -100,
			"stock": _start_stock(), "prod": _zero_res(), "cons": _zero_res(), "short": [],
			"manpower": 200, "generals": [],
			"techs": [], "queue": [], "progress": {}, "mods": {}, "industry": 0,
		})
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


func _recalc_mods(cid: int) -> void:
	var m := {}
	for id in countries[cid]["techs"]:
		for k in tech_defs[id]["effects"]:
			m[k] = m.get(k, 0) + int(tech_defs[id]["effects"][k])
	countries[cid]["mods"] = m


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
	_research()
	_move_armies()
	_move_fleets()
	_supply()
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
			countries[o]["income"] += provs[p]["pop"] * provs[p]["industry"] / 100
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
		ind_sum[o] += provs[p]["industry"]
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
		c["cons"]["oil"] = (astr - armor_hp) / 4000 + armor_hp / 1000 + 2 * fstr / 2000
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
	return p * sup * gm


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
		"next_army_id": next_army_id, "next_general_id": next_general_id, "fleets": fleets, "next_fleet_id": next_fleet_id, "alliances": alliances, "trades": trades, "next_trade_id": next_trade_id, "embargoes": embargoes, "rng_state": rng.state, "command_log": command_log,
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
	sim.rng.seed = sim.seed_value
	sim.rng.state = d["rng_state"]
	sim.command_log = d.get("command_log", [])
	for c in sim.countries:
		sim._recalc_mods(c["id"])
	return sim


## State fingerprint for desync detection (multiplayer) and tests.
func checksum() -> int:
	return var_to_str([day, owner, countries, armies, fleets, alliances, trades, embargoes, wars, rng.state]).hash()
