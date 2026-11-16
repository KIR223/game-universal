class_name Simulation
extends RefCounted
## Headless, deterministic game simulation. No Node/graphics dependencies.
## All mutations from players go through apply_command(); time advances via tick_day().

const SAVE_VERSION := 1
const ARMY_COST := 60
const ARMY_BASE_STRENGTH := 1000
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
var command_log: Array = []
var log_lines: Array = []
var dirty_provinces: Array[int] = []


func setup(seed_value_: int, country_defs: Array) -> void:
	seed_value = seed_value_
	rng.seed = seed_value
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
		})
		_spawn_army(i, caps[i])
		_spawn_army(i, caps[i])


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
			if owner[c["capital"]] != cid:
				return _fail("capital lost")
			c["treasury"] -= ARMY_COST
			_spawn_army(cid, c["capital"])
			return {"ok": true}
		"declare_war":
			var target: int = cmd.get("target", -1)
			if target < 0 or target >= countries.size() or target == cid or not countries[target]["alive"]:
				return _fail("invalid target")
			if at_war(cid, target):
				return _fail("already at war")
			if not neighbor_countries(cid).has(target):
				return _fail("no common border")
			_declare_war(cid, target)
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
			a["path"] = path
			a["move"] = 0
			return {"ok": true}
		_:
			return _fail("unknown command")


func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


# --------------------------------------------------------------- time step

func tick_day() -> void:
	day += 1
	_economy()
	_move_armies()
	_battles()
	_occupation()
	if day % 5 == 0:
		_ai()
	_peace()
	_eliminate()


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
	for c in countries:
		if c["alive"]:
			c["treasury"] += c["income"] - c["upkeep"]
			if c["treasury"] < 0:
				c["treasury"] = 0
				# unpaid armies lose strength
				for a in armies:
					if a["owner"] == c["id"]:
						a["strength"] = int(a["strength"] * 0.98)


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
		if o != cid and o >= 0 and not at_war(cid, o):
			a["path"] = []  # blocked by a neutral foreign border
			continue
		a["path"].remove_at(0)
		a["prov"] = nxt


func _battles() -> void:
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
				var xd := def_bonus if owner[p] == x["owner"] else 1.0
				var yd := def_bonus if owner[p] == y["owner"] else 1.0
				var px: float = x["strength"] * rng.randf_range(0.8, 1.2) * xd
				var py: float = y["strength"] * rng.randf_range(0.8, 1.2) * yd
				x["strength"] -= int(py * 0.12)
				y["strength"] -= int(px * 0.12)
	var survivors: Array = []
	for a in armies:
		if a["strength"] > 50:
			survivors.append(a)
	armies = survivors


func _occupation() -> void:
	for a in armies:
		var p: int = a["prov"]
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


func _declare_war(a: int, b: int) -> void:
	wars.append({"a": a, "b": b, "start": day})
	_log("%s: %s объявляет войну %s" % [date_string(), countries[a]["name"], countries[b]["name"]])


func _spawn_army(cid: int, prov: int) -> void:
	armies.append({
		"id": next_army_id, "owner": cid, "prov": prov,
		"strength": ARMY_BASE_STRENGTH, "path": [], "move": 0,
	})
	next_army_id += 1


func _log(text: String) -> void:
	log_lines.append(text)
	if log_lines.size() > 200:
		log_lines.pop_front()


# ---------------------------------------------------------------- pathing

## BFS over land. Passable: own, enemy-owned or unowned provinces.
func _find_path(from: int, cid: int, goal: int) -> Array:
	return _bfs(from, cid, func(p): return p == goal)


func _bfs(from: int, cid: int, is_goal: Callable) -> Array:
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
		for q in provs[cur]["land_neighbors"]:
			if prev.has(q):
				continue
			var o := owner[q]
			if o == cid or o == -1 or enemies.has(o):
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
		if enemies.is_empty() and day - c["last_peace"] > 30 and armies_of(cid).size() >= 2:
			var victim := -1
			var weakest := 1 << 30
			for n in neighbor_countries(cid):
				var s := army_strength(n)
				if s < weakest:
					weakest = s
					victim = n
			if victim >= 0 and my_str > weakest * 1.3:
				_declare_war(cid, victim)
				enemies = enemies_of(cid)
		# economic: build armies
		if c["treasury"] >= ARMY_COST * 2 and armies_of(cid).size() < 3 + country_provinces(cid).size() / 4:
			c["treasury"] -= ARMY_COST
			_spawn_army(cid, c["capital"])
		# military: send idle armies at the nearest enemy target
		if enemies.is_empty():
			continue
		for a in armies_of(cid):
			if not a["path"].is_empty():
				continue
			var path := _bfs(a["prov"], cid, func(p):
				var o := owner[p]
				if enemies.has(o):
					return true
				for b in armies:
					if b["prov"] == p and enemies.has(b["owner"]):
						return true
				return false)
			if not path.is_empty():
				a["path"] = path
				a["move"] = 0


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
		"next_army_id": next_army_id, "rng_state": rng.state, "command_log": command_log,
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
	sim.rng.seed = sim.seed_value
	sim.rng.state = d["rng_state"]
	sim.command_log = d.get("command_log", [])
	return sim


## State fingerprint for desync detection (multiplayer) and tests.
func checksum() -> int:
	return var_to_str([day, owner, countries, armies, wars, rng.state]).hash()
