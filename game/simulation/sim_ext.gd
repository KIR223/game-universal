class_name SimExt
extends RefCounted
## Deep government and world systems (opt-in with scenario rule "gov2"): finance, society, domestic politics, diplomacy,
## space, staff orders and public works. Pure functions over a Simulation; all state lives in `sim.x` (saved, part of the
## state hash when the rule is on). Integer maths only and `sim.rng` for chance, so runs stay deterministic.
## Everything here is an abstract game model with invented balance numbers, not a model of real institutions.

const PARTY_NAMES := {
	"democracy": ["Либеральный союз", "Партия труда"], "monarchy": ["Корона и порядок", "Консервативный совет"],
	"communism": ["Рабочий фронт", "Народная коммуна"], "autocracy": ["Национальный фронт", "Партия порядка"],
}
const ORGS := ["Всемирная ассамблея", "Торговая организация", "Миротворческий совет", "Международный суд"]
const AI_SUBSYSTEMS := ["strategic", "economic", "political", "military", "diplomatic", "modern"]
const WORKS := {
	"rail": {"name": "Железная дорога", "cost": 90, "steel": 25, "days": 20, "income": 1},
	"port": {"name": "Развитие порта", "cost": 80, "steel": 20, "days": 25, "income": 2},
	"airport": {"name": "Развитие аэропорта", "cost": 85, "steel": 20, "days": 25, "income": 1},
	"depot": {"name": "Склад снабжения", "cost": 60, "steel": 15, "days": 15, "income": 0},
	"power": {"name": "Электростанция", "cost": 110, "steel": 30, "days": 30, "income": 3},
	"farm": {"name": "Агрокомплекс", "cost": 70, "steel": 10, "days": 20, "income": 1},
	"factory": {"name": "Промышленный район", "cost": 120, "steel": 30, "days": 30, "income": 3},
}
const ECON_NORM := 130   # percent: the tax/corruption/shadow factors average about 0.75, this keeps the default-tax income at the classic level
const SPACE_LEVEL_COST := 400   # progress needed per level (level 1 = 400, level 2 = 800, ...)
const SAT_KINDS := {"recon": "Разведывательный", "nav": "Навигационный", "comm": "Связной"}


# ------------------------------------------------------------------ setup

static func setup(s: Simulation) -> void:
	s.x = {
		"fin": {}, "soc": {}, "pol": {}, "space": {}, "staff": {}, "tariff": [], "projects": [], "works": {}, "log": [],
		"dip": {"pacts": [], "blocs": [], "bases": [], "offers": [], "rel": {}, "claims": [], "crises": [], "next_id": 1},
		"info": {},
	}
	for c in s.countries:
		var cid: int = c["id"]
		var gdp := float(s.gdp_of.get(cid, 800000))
		var pop := float(maxi(int(s.pop_of.get(cid, 20000000)), 1000000))
		var pc := int(gdp * 1000000.0 / pop)   # GDP per head, USD
		s.x["fin"][cid] = {"tax": 30, "debt": 0, "infl": 200, "fx": 10000, "stock": 1000, "edu": 10, "health": 10, "state": 40, "foreign": 10,
			"shadow": clampi(35 - pc / 1500, 5, 35), "default_until": 0, "last_anticorr": -999}
		s.x["soc"][cid] = {"edu": clampi(20 + pc / 600, 15, 90), "health": clampi(20 + pc / 650, 15, 90), "urban": clampi(25 + pc / 700, 20, 90),
			"birth": clampi(32 - pc / 2500, 9, 38), "death": clampi(10 - pc / 12000, 6, 13), "corr": clampi(70 - pc / 700, 10, 80),
			"unemp": clampi(14 - pc / 4000, 3, 18), "poverty": clampi(60 - pc / 600, 3, 70), "mood": 50, "pop": 10000, "acc": 0,
			"refugees": 0, "epidemic": 0, "pc": pc}
		var parties: Array = []
		var n := 1
		for ideo in PARTY_NAMES:
			var w: int = 30 + (cid * 7 + n * 13) % 41
			parties.append({"id": n, "name": PARTY_NAMES[ideo][0], "ideo": ideo, "w": w})
			parties.append({"id": n + 1, "name": PARTY_NAMES[ideo][1], "ideo": ideo, "w": 100 - w})
			n += 2
		s.x["pol"][cid] = {"parties": parties, "gov": _first_party(parties, str(c.get("ideology", "autocracy"))), "coalition": [],
			"next_election": 150 + (cid * 53) % 1400, "unrest": 0, "strike_until": 0, "autonomy": 0, "info_def": 0,
			"constitution": "parliamentary" if str(c.get("ideology", "")) == "democracy" else ("monarchy" if str(c.get("ideology", "")) == "monarchy" else "presidential"),
			"last_result": "", "protest_logged": false, "last_info_op": -999, "approval": 50}
		s.x["space"][cid] = {"level": 0, "progress": 0, "sats": {"recon": 0, "nav": 0, "comm": 0}, "coop": -1}
		s.x["staff"][cid] = {"directives": [], "reports": [], "auto": false, "next_id": 1}
		s.x["info"][cid] = {"defense": 0}
	SimMore.setup(s)


static func _first_party(parties: Array, ideo: String) -> int:
	for p in parties:
		if p["ideo"] == ideo:
			return p["id"]
	return parties[0]["id"]


static func fin(s: Simulation, cid: int) -> Dictionary:
	return s.x["fin"][cid]


static func soc(s: Simulation, cid: int) -> Dictionary:
	return s.x["soc"][cid]


static func pol(s: Simulation, cid: int) -> Dictionary:
	return s.x["pol"][cid]


static func _log(s: Simulation, text: String) -> void:
	s._log("%s: %s" % [s.date_string(), text])


## Support (percent of voters) of one party: the ideology's share, split between its two parties.
static func party_pct(s: Simulation, cid: int, p: Dictionary) -> int:
	return int(s.countries[cid]["party_pop"].get(p["ideo"], 0)) * int(p["w"]) / 100


# ------------------------------------------------------------------ economy hook

## Called every day after the base income and upkeep are known and before the treasury changes.
static func adjust_economy(s: Simulation) -> void:
	for c in s.countries:
		if not c["alive"]:
			continue
		var cid: int = c["id"]
		var f: Dictionary = s.x["fin"][cid]
		var so: Dictionary = s.x["soc"][cid]
		var po: Dictionary = s.x["pol"][cid]
		var inc: int = c["income"] * 100 * ECON_NORM / 100 * int(f["tax"]) / 30   # fixed point x100: small incomes must not truncate to zero
		var shadow := clampi(int(f["shadow"]) + maxi(0, int(f["tax"]) - 30) / 2, 0, 60)
		inc = inc * (100 - shadow) / 100
		inc = inc * (100 - int(so["corr"]) / 4) / 100
		inc = inc * (100 - int(so["unemp"]) / 2) / 100
		inc = inc * (100 - int(f["infl"]) / 200) / 100
		if int(po["strike_until"]) > s.day:
			inc = inc * 85 / 100
		if int(so["epidemic"]) > 0:
			inc = inc * 90 / 100
		if int(f["stock"]) > 1200:
			inc = inc * 102 / 100
		elif int(f["stock"]) < 700:
			inc = inc * 98 / 100
		inc = inc * (100 + (60 - int(f["state"])) / 10 + int(f["foreign"]) / 10) / 100
		inc = inc * (100 + (int(so["edu"]) - 50) / 10) / 100
		inc = inc * (100 + (int(so["urban"]) - 50) / 25) / 100
		inc = inc * (100 - int(po["autonomy"]) * 4) / 100
		for p in s.x["dip"]["blocs"]:
			if p["members"].has(cid):
				inc = inc * 102 / 100
		inc = SimMore.income_mod(s, cid, inc)
		inc += (_works_income(s, cid) + _projects_bonus(s, cid)) * 100
		var up: int = c["upkeep"]
		up += inc * (int(f["edu"]) + int(f["health"])) / 10000
		up += int(f["debt"]) * _rate(s, cid, inc / 100) / 3650000
		up += _sat_total(s, cid)
		inc = (inc + 99) / 100
		c["income"] = maxi(inc, 0)
		c["upkeep"] = up
	_apply_tariffs(s)


static func _rate(s: Simulation, cid: int, income: int) -> int:
	var f: Dictionary = s.x["fin"][cid]
	var ratio := int(f["debt"]) * 100 / maxi(income * 365, 1)
	return maxi(100, 300 + int(f["infl"]) / 4 + mini(1500, ratio * 5) + SimMore.policy(s, cid) * 60)


static func _apply_tariffs(s: Simulation) -> void:
	for t in s.x["tariff"]:
		var a: int = t["a"]
		var b: int = t["b"]
		if not s.countries[a]["alive"] or not s.countries[b]["alive"]:
			continue
		var pct := mini(int(t["pct"]), 40)
		var hit: int = s.countries[b]["income"] * pct / 400
		s.countries[b]["income"] -= hit
		s.countries[a]["income"] += s.countries[a]["income"] * pct / 800


# ------------------------------------------------------------------ daily step

static func daily(s: Simulation) -> void:
	var d: int = s.day
	for c in s.countries:
		if not c["alive"]:
			continue
		var cid: int = c["id"]
		_finance_daily(s, cid)
		_society_daily(s, cid)
		_politics_daily(s, cid)
	_projects_daily(s)
	if d % 5 == 0:
		_diplomacy_daily(s)
	if d % 30 == 0:
		_space_monthly(s)
	if d % 3 == 0:
		_staff_daily(s)
	SimMore.daily(s)


static func _debt_ratio(s: Simulation, cid: int) -> int:
	var f: Dictionary = s.x["fin"][cid]
	return int(f["debt"]) * 100 / maxi(s.countries[cid]["income"] * 365, 1)


static func _finance_daily(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var f: Dictionary = s.x["fin"][cid]
	var so: Dictionary = s.x["soc"][cid]
	var ratio := _debt_ratio(s, cid)
	var target := maxi(0, 150 + clampi(ratio, 0, 200) * 8 - SimMore.policy(s, cid) * 40)
	f["infl"] = clampi(int(f["infl"]) + signi(target - int(f["infl"])) * 5, 0, 6000)
	var fx_target := clampi(10000 + (int(c["stability"]) - 50) * 30 - (int(f["infl"]) - 200) * 2 - mini(3000, ratio * 10), 3000, 20000)
	f["fx"] = int(f["fx"]) + signi(fx_target - int(f["fx"])) * 20
	if s.day % 5 == 0:
		var drift: int = (int(c["stability"]) - 50) * 2 + (int(so["mood"]) - 50) - (10 if not s.enemies_of(cid).is_empty() else 0) + (1000 - int(f["stock"])) / 50
		f["stock"] = clampi(int(f["stock"]) + drift + s.rng.randi_range(-25, 25), 200, 3000)
	if s.day % 30 == 0:
		var shadow_target: int = int(so["corr"]) / 2 + maxi(0, int(f["tax"]) - 30)
		f["shadow"] = clampi(int(f["shadow"]) + signi(shadow_target - int(f["shadow"])), 2, 60)
		if int(c["stability"]) < 40 or int(f["tax"]) > 45:
			so["corr"] = mini(95, int(so["corr"]) + 1)
		elif int(c["stability"]) > 60 and int(so["corr"]) > 5:
			so["corr"] = int(so["corr"]) - 1
	# sovereign default: debt beyond two years of income with an empty treasury
	if int(f["debt"]) > c["income"] * 730 and c["treasury"] <= 0 and int(f["default_until"]) < s.day:
		f["debt"] = int(f["debt"]) / 2
		f["default_until"] = s.day + 365
		c["stability"] = maxi(0, int(c["stability"]) - 15)
		s.x["pol"][cid]["unrest"] = mini(100, int(s.x["pol"][cid]["unrest"]) + 20)
		_log(s, "%s объявляет дефолт: долг списан наполовину, кредитов не будет год" % c["name"])


static func _society_daily(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var f: Dictionary = s.x["fin"][cid]
	var so: Dictionary = s.x["soc"][cid]
	# population: births minus deaths (per mille a year) accumulated in 1/365 basis points
	var death: int = int(so["death"]) + (6 if int(so["epidemic"]) > 0 else 0) - (int(so["health"]) - 50) / 25
	var g: int = int(so["birth"]) - (int(so["urban"]) - 50) / 40 - death
	so["acc"] = int(so["acc"]) + g * 10
	while int(so["acc"]) >= 365:
		so["pop"] = mini(20000, int(so["pop"]) + 1)
		so["acc"] = int(so["acc"]) - 365
	while int(so["acc"]) <= -365:
		so["pop"] = maxi(5000, int(so["pop"]) - 1)
		so["acc"] = int(so["acc"]) + 365
	if int(so["epidemic"]) > 0:
		so["epidemic"] = int(so["epidemic"]) - 1
		if int(so["epidemic"]) == 0:
			_log(s, "эпидемия в стране %s закончилась" % c["name"])
	var d: int = s.day
	if d % 5 == 0:
		var mood_target: int = (int(c["stability"]) + (100 - int(so["poverty"])) + (100 - int(so["corr"])) + (100 - int(so["unemp"]) * 3)) / 4
		so["mood"] = clampi(int(so["mood"]) + signi(mood_target - int(so["mood"])), 0, 100)
		if not s.enemies_of(cid).is_empty():
			var hurt := 0
			for p in s.cells_of(cid):
				if s.damage[p] > 40:
					hurt += 1
			so["refugees"] = mini(500, int(so["refugees"]) + hurt / 4)
		elif int(so["refugees"]) > 0:
			so["refugees"] = int(so["refugees"]) - 1
	if d % 10 == 0:
		if int(so["epidemic"]) == 0:
			var meds := 0
			for t in c["techs"]:
				if str(t).begins_with("med") or str(t) in ["fld", "abx", "evac"]:
					meds += 1
			var chance := clampi((100 - int(so["health"])) * 3 + int(so["urban"]) / 2 - meds * 15, 5, 400)
			if s.rng.randi_range(0, 9999) < chance:
				so["epidemic"] = s.rng.randi_range(30, 60)
				_log(s, "в стране %s началась эпидемия" % c["name"])
		if int(so["refugees"]) > 30 and int(c["stability"]) > 0:
			c["stability"] = int(c["stability"]) - 1
	if d % 30 == 0:
		so["edu"] = clampi(int(so["edu"]) + (int(f["edu"]) - 8) / 4, 5, 100)
		so["health"] = clampi(int(so["health"]) + (int(f["health"]) - 8) / 4, 5, 100)
		var unemp_t: int = clampi(14 - int(so["pc"]) / 4000 - int(so["edu"]) / 20 + (4 if int(c["stability"]) < 40 else 0) + (2 if not s.enemies_of(cid).is_empty() else 0), 2, 30)
		so["unemp"] = int(so["unemp"]) + signi(unemp_t - int(so["unemp"]))
		var pov_t: int = clampi(60 - int(so["pc"]) / 600 + int(so["unemp"]) + int(f["infl"]) / 400, 2, 90)
		so["poverty"] = int(so["poverty"]) + signi(pov_t - int(so["poverty"]))
		# migration: people leave an unhappy country for a happier neighbour
		if int(so["mood"]) < 35:
			for nb in s.neighbor_countries(cid):
				var other: Dictionary = s.x["soc"][nb]
				if int(other["mood"]) > int(so["mood"]) + 10 and not s.at_war(cid, nb):
					so["pop"] = maxi(5000, int(so["pop"]) - 20)
					other["pop"] = mini(20000, int(other["pop"]) + 20)
					break
	if d % 90 == 0 and int(c["industry"]) > 0:
		so["urban"] = mini(95, int(so["urban"]) + 1)


static func _politics_daily(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var po: Dictionary = s.x["pol"][cid]
	var so: Dictionary = s.x["soc"][cid]
	var f: Dictionary = s.x["fin"][cid]
	var d: int = s.day
	if d % 5 == 0:
		var delta := 0
		delta += 2 if int(so["mood"]) < 40 else 0
		delta += 2 if int(c["stability"]) < 40 else 0
		delta += 1 if int(f["tax"]) > 45 else 0
		delta += 1 if int(so["corr"]) > 60 else 0
		delta += 1 if int(so["unemp"]) > 12 else 0
		delta -= 1 if int(po["autonomy"]) >= 1 else 0
		if int(so["mood"]) > 60 and int(c["stability"]) > 55:
			delta -= 2
		else:
			delta -= 0
		po["unrest"] = clampi(int(po["unrest"]) + (delta if delta != 0 else -1), 0, 100)
		po["approval"] = clampi((int(so["mood"]) + int(c["stability"])) / 2, 0, 100)
	if int(po["unrest"]) >= 40:
		if d % 10 == 0:
			c["stability"] = maxi(0, int(c["stability"]) - 1)
		if not bool(po["protest_logged"]):
			po["protest_logged"] = true
			_log(s, "протесты в стране %s" % c["name"])
	else:
		po["protest_logged"] = false
	if int(po["unrest"]) >= 60 and int(po["strike_until"]) < d - 30:
		po["strike_until"] = d + 14
		_log(s, "забастовки в стране %s" % c["name"])
	if int(po["unrest"]) >= 90 and int(c["stability"]) <= 20:
		c["crisis"] = int(c["crisis"]) + 3   # the old crisis counter turns this into a coup or a civil war
	# elections (replace the legacy yearly vote) and plebiscites
	if d >= int(po["next_election"]):
		_election(s, cid)


static func _election(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var po: Dictionary = s.x["pol"][cid]
	var cycle := 1460 if po["constitution"] == "presidential" else 1095
	var democracy: bool = str(c["ideology"]) == "democracy"
	if not democracy:
		po["next_election"] = int(po["next_election"]) + 1825
		var ok: bool = int(po["approval"]) >= 50
		c["stability"] = clampi(int(c["stability"]) + (3 if ok else -3), 0, 100)
		po["last_result"] = "плебисцит: %s" % ("одобрен" if ok else "не одобрен")
		return
	po["next_election"] = int(po["next_election"]) + cycle
	var best: Dictionary = {}
	var best_score := -999999
	var total := 0
	var scores := {}
	for p in po["parties"]:
		var pct := party_pct(s, cid, p)
		total += pct
		var sc: int = pct * 10 + (int(c["stability"]) - 50) * (5 if p["ideo"] == c["ideology"] else -5) + s.rng.randi_range(-50, 50)
		scores[p["id"]] = [pct, sc]
		if sc > best_score:
			best_score = sc
			best = p
	po["gov"] = best["id"]
	var coalition: Array = []
	var share: int = scores[best["id"]][0]
	if share < 40:
		var others: Array = po["parties"].filter(func(p): return p["id"] != best["id"])
		others.sort_custom(func(a, b): return scores[a["id"]][0] > scores[b["id"]][0])
		for o in others:
			if share >= 50:
				break
			coalition.append(o["id"])
			share += scores[o["id"]][0]
	po["coalition"] = coalition
	po["last_result"] = "победила партия «%s» (%d%%)%s" % [best["name"], scores[best["id"]][0], (", коалиция из %d партий" % coalition.size()) if not coalition.is_empty() else ""]
	_log(s, "выборы в стране %s: %s" % [c["name"], po["last_result"]])
	if best["ideo"] != c["ideology"]:
		s._change_government(c, best["ideo"], "выборы")
	else:
		c["stability"] = mini(100, int(c["stability"]) + 3)
	SimMore.after_election(s, cid)


# ------------------------------------------------------------------ works, space helpers used by the economy

static func _works_income(s: Simulation, cid: int) -> int:
	var total := 0
	var works: Dictionary = s.x["works"]
	for cell in works:
		if s.owner[cell] != cid:
			continue
		var w: Dictionary = works[cell]
		for k in WORKS:
			if int(w.get(k, 0)) > 0:
				total += int(WORKS[k]["income"]) * int(w[k]) * (100 - s.damage[cell]) / 100
	return total


static func _projects_bonus(_s: Simulation, _cid: int) -> int:
	return 0


static func _sat_total(s: Simulation, cid: int) -> int:
	var n := 0
	for k in s.x["space"][cid]["sats"]:
		n += int(s.x["space"][cid]["sats"][k])
	return n


static func sat_count(s: Simulation, cid: int, kind: String) -> int:
	if not s.rule_gov2 or not s.x["space"].has(cid):
		return 0
	return int(s.x["space"][cid]["sats"].get(kind, 0))


## Modifier added to Simulation.mod(): navigation satellites help supply, communication satellites help stability-like research.
static func mod_bonus(s: Simulation, cid: int, key: String) -> int:
	if not s.x.has("space") or not s.x["space"].has(cid):
		return 0
	var sp: Dictionary = s.x["space"][cid]
	if key == "supply_pct":
		return mini(int(sp["sats"]["nav"]), 5) * 5
	if key == "research_pct":
		return mini(int(sp["sats"]["comm"]), 4) * 2 + int(s.x["soc"][cid]["edu"]) / 20
	return 0


static func _projects_daily(s: Simulation) -> void:
	var keep: Array = []
	for p in s.x["projects"]:
		if int(p["done"]) <= s.day:
			if s.owner[p["cell"]] == p["owner"]:
				var w: Dictionary = s.x["works"].get(p["cell"], {})
				w[p["kind"]] = int(w.get(p["kind"], 0)) + 1
				s.x["works"][p["cell"]] = w
				_log(s, "%s: готово — %s" % [s.countries[p["owner"]]["name"], WORKS[p["kind"]]["name"]])
		else:
			keep.append(p)
	s.x["projects"] = keep
	# city growth: developed cells with infrastructure grow slowly (aggregated, no per-building simulation)
	if s.day % 90 == 0:
		for cell in s.x["works"]:
			var w2: Dictionary = s.x["works"][cell]
			if s.owner[cell] >= 0 and s.infra[cell] >= 3 and s.damage[cell] < 20:
				w2["growth"] = mini(50, int(w2.get("growth", 0)) + 1)
	_rebuild_supply_cache(s)


## Flat per-cell supply cost reduction from railways and depots (read by the supply search through supply_bonus()).
static func _rebuild_supply_cache(s: Simulation) -> void:
	if s._works_supply.size() != s.owner.size():
		s._works_supply = PackedInt32Array()
		s._works_supply.resize(s.owner.size())
	s._works_supply.fill(0)
	for cell in s.x["works"]:
		var w: Dictionary = s.x["works"][cell]
		s._works_supply[cell] = int(w.get("rail", 0)) * 3 + int(w.get("depot", 0)) * 2


# ------------------------------------------------------------------ diplomacy

static func _pair(a: int, b: int) -> String:
	return "%d_%d" % [mini(a, b), maxi(a, b)]


static func relation(s: Simulation, a: int, b: int) -> int:
	var d: Dictionary = s.x["dip"]
	var r: int = int(d["rel"].get(_pair(a, b), 0))
	if s.allied(a, b):
		r += 40
	if s.at_war(a, b):
		r -= 80
	if s._embargoed(a, b):
		r -= 20
	for p in d["pacts"]:
		if (p["a"] == a and p["b"] == b) or (p["a"] == b and p["b"] == a):
			r += 15 if p["kind"] == "trade_pact" else 8
	for bl in d["blocs"]:
		if bl["members"].has(a) and bl["members"].has(b):
			r += 10
	return clampi(r, -100, 100)


static func _shift_rel(s: Simulation, a: int, b: int, delta: int) -> void:
	var k := _pair(a, b)
	s.x["dip"]["rel"][k] = clampi(int(s.x["dip"]["rel"].get(k, 0)) + delta, -60, 60)


static func blocks_war(s: Simulation, a: int, b: int) -> bool:
	if not s.rule_gov2:
		return false
	for p in s.x["dip"]["pacts"]:
		if p["kind"] == "nap" and ((p["a"] == a and p["b"] == b) or (p["a"] == b and p["b"] == a)) and s.day - int(p["since"]) < 730:
			return true
	return false


const OFFER_VALUE := {"trade_pact": 20, "nap": 10, "base_lease": -15}


## What the target thinks of an offer: relation, the deal's worth and the money it gets.
static func offer_score(s: Simulation, o: Dictionary) -> int:
	return relation(s, o["from"], o["to"]) / 2 + int(OFFER_VALUE.get(o["kind"], 0)) + int(o["money"]) / 10


static func _apply_offer(s: Simulation, o: Dictionary) -> bool:
	var a: Dictionary = s.countries[o["from"]]
	var b: Dictionary = s.countries[o["to"]]
	if a["treasury"] < int(o["money"]):
		return false
	a["treasury"] -= int(o["money"])
	b["treasury"] += int(o["money"])
	s.x["dip"]["pacts"].append({"a": o["from"], "b": o["to"], "kind": o["kind"], "since": s.day, "cell": int(o.get("cell", -1))})
	if o["kind"] == "trade_pact":
		s.x["tariff"] = s.x["tariff"].filter(func(t): return not ((t["a"] == o["from"] and t["b"] == o["to"]) or (t["a"] == o["to"] and t["b"] == o["from"])))
	_shift_rel(s, o["from"], o["to"], 5)
	_log(s, "%s и %s заключили соглашение: %s" % [a["name"], b["name"], o["kind"]])
	return true


static func _propose(s: Simulation, cid: int, cmd: Dictionary) -> Dictionary:
	var target: int = int(cmd.get("target", -1))
	var kind: String = str(cmd.get("kind", ""))
	var money: int = clampi(int(cmd.get("money", 0)), -500, 500)
	if target < 0 or target >= s.countries.size() or target == cid or not s.countries[target]["alive"]:
		return s._fail("invalid target")
	if not OFFER_VALUE.has(kind):
		return s._fail("invalid offer")
	if s.at_war(cid, target):
		return s._fail("at war")
	for p in s.x["dip"]["pacts"]:
		if p["kind"] == kind and ((p["a"] == cid and p["b"] == target) or (p["a"] == target and p["b"] == cid)):
			return s._fail("already agreed")
	var cell := -1
	if kind == "base_lease":
		cell = int(cmd.get("cell", -1))
		if cell < 0 or cell >= s.owner.size() or s.owner[cell] != target:
			return s._fail("invalid base")
	var d: Dictionary = s.x["dip"]
	var o := {"id": d["next_id"], "from": cid, "to": target, "kind": kind, "money": money, "cell": cell, "status": "pending", "day": s.day}
	d["next_id"] = int(d["next_id"]) + 1
	d["offers"].append(o)
	if s.countries[target]["ai"]:
		_ai_answer(s, o)
	return {"ok": true, "offer": o["id"], "status": o["status"]}


## AI target: accept a good offer, answer a middling one with a costlier counter-offer, refuse a bad one.
static func _ai_answer(s: Simulation, o: Dictionary) -> void:
	var score := offer_score(s, o)
	if score >= 20:
		o["status"] = "accepted" if _apply_offer(s, o) else "failed"
	elif score >= -10:
		o["money"] = int(o["money"]) + (20 - score) * 10
		o["status"] = "countered"
	else:
		o["status"] = "refused"
		_shift_rel(s, o["from"], o["to"], -2)


static func _respond(s: Simulation, cid: int, cmd: Dictionary) -> Dictionary:
	var oid: int = int(cmd.get("offer", -1))
	for o in s.x["dip"]["offers"]:
		if o["id"] != oid:
			continue
		var accept: bool = bool(cmd.get("accept", true))
		if o["status"] == "countered" and o["from"] == cid:
			if not accept:
				o["status"] = "declined"
				return {"ok": true}
			if not _apply_offer(s, o):
				return s._fail("not enough funds")
			o["status"] = "accepted"
			return {"ok": true}
		if o["status"] == "pending" and o["to"] == cid:
			if accept and _apply_offer(s, o):
				o["status"] = "accepted"
				return {"ok": true}
			o["status"] = "refused" if not accept else "failed"
			return {"ok": true} if not accept else s._fail("not enough funds")
		return s._fail("not your offer")
	return s._fail("no such offer")


static func _diplomacy_daily(s: Simulation) -> void:
	var d: Dictionary = s.x["dip"]
	# tensions between neighbours with poor relations turn into diplomatic crises
	if s.day % 15 == 0:
		for c in s.countries:
			if not c["alive"] or not c["ai"]:
				continue
			for nb in s.neighbor_countries(c["id"]):
				if nb > c["id"] and relation(s, c["id"], nb) < -50 and not s.at_war(c["id"], nb) and s.rng.randi_range(0, 99) < 8:
					var open := false
					for cr in d["crises"]:
						open = open or (cr["a"] == c["id"] and cr["b"] == nb)
					if not open:
						d["crises"].append({"a": c["id"], "b": nb, "until": s.day + 60})
						_log(s, "дипломатический кризис: %s — %s" % [c["name"], s.countries[nb]["name"]])
	var keep: Array = []
	for cr in d["crises"]:
		if int(cr["until"]) < s.day:
			_shift_rel(s, cr["a"], cr["b"], -10)
		else:
			keep.append(cr)
	d["crises"] = keep
	# court rulings
	var open_claims: Array = []
	for cl in d["claims"]:
		if int(cl["ruling"]) <= s.day:
			s.countries[cl["against"]]["stability"] = maxi(0, int(s.countries[cl["against"]]["stability"]) - 5)
			s.countries[cl["by"]]["pp"] = mini(Simulation.PP_CAP, int(s.countries[cl["by"]]["pp"]) + 5)
			_shift_rel(s, cl["by"], cl["against"], -10)
			_log(s, "Международный суд вынес решение по иску %s против %s" % [s.countries[cl["by"]]["name"], s.countries[cl["against"]]["name"]])
		else:
			open_claims.append(cl)
	d["claims"] = open_claims
	if s.day % 30 == 0:
		for bl in d["blocs"]:
			for i in bl["members"].size():
				for j in range(i + 1, bl["members"].size()):
					_shift_rel(s, bl["members"][i], bl["members"][j], 1)


static func _space_monthly(s: Simulation) -> void:
	for c in s.countries:
		if not c["alive"]:
			continue
		var sp: Dictionary = s.x["space"][c["id"]]
		var partner: int = int(sp["coop"])
		if partner >= 0 and s.countries[partner]["alive"] and s.allied(c["id"], partner):
			sp["progress"] = int(sp["progress"]) + 20
			_level_up(s, c["id"])
			_shift_rel(s, c["id"], partner, 1)


static func _level_up(s: Simulation, cid: int) -> void:
	var sp: Dictionary = s.x["space"][cid]
	while int(sp["progress"]) >= (int(sp["level"]) + 1) * SPACE_LEVEL_COST and int(sp["level"]) < 5:
		sp["level"] = int(sp["level"]) + 1
		_log(s, "%s достигает уровня космической программы %d" % [s.countries[cid]["name"], sp["level"]])


# ------------------------------------------------------------------ staff

static func _staff_daily(s: Simulation) -> void:
	for c in s.countries:
		if not c["alive"]:
			continue
		var cid: int = c["id"]
		var st: Dictionary = s.x["staff"][cid]
		if bool(st["auto"]) and s.day % 15 == 0:
			_auto_directives(s, cid)
		var keep: Array = []
		for dr in st["directives"]:
			var g: Dictionary = s.group_by_id(int(dr["group"]))
			var members: Array = s.group_members(g) if not g.is_empty() else []
			if members.is_empty():
				_report(s, cid, "группа расформирована, приказ снят")
				continue
			var skill := 3
			var gen: Dictionary = s._general(cid, int(members[0].get("gen", -1)))
			if not gen.is_empty():
				skill = int(gen.get("skill", 3))
			if skill < 4 and s.day % 6 != 0:
				keep.append(dr)
				continue   # a hesitant commander acts less often
			if s.rng.randi_range(0, 99) < clampi(35 - skill * 6, 0, 40):
				_report(s, cid, "приказ «%s» задержан: ошибка командования" % dr["stance"])
				keep.append(dr)
				continue
			var target: int = int(dr["target"])
			if dr["stance"] == "reserve":
				target = c["capital"]
			var at_target := true
			for a in members:
				at_target = at_target and a["prov"] == target
			if at_target:
				if dr["stance"] == "attack" and s.owner[target] == cid:
					_report(s, cid, "цель достигнута: клетка #%d" % target)
					continue   # an attack directive ends with the objective
				keep.append(dr)
				continue
			var r := s._group_move(cid, int(dr["group"]), target)
			if not r.get("ok", false):
				_report(s, cid, "группа не может идти к клетке #%d" % target)
			keep.append(dr)
		st["directives"] = keep


static func _report(s: Simulation, cid: int, text: String) -> void:
	var st: Dictionary = s.x["staff"][cid]
	st["reports"].append("%s: %s" % [s.date_string(), text])
	while st["reports"].size() > 20:
		st["reports"].pop_front()


static func _auto_directives(s: Simulation, cid: int) -> void:
	var st: Dictionary = s.x["staff"][cid]
	var busy := {}
	for dr in st["directives"]:
		busy[dr["group"]] = true
	for g in s.groups_of(cid):
		if busy.has(g["id"]):
			continue
		var members := s.group_members(g)
		if members.is_empty():
			continue
		var target := _nearest_enemy_cell(s, cid, int(members[0]["prov"]))
		if target >= 0:
			_add_directive(s, cid, int(g["id"]), target, "attack")
		else:
			_add_directive(s, cid, int(g["id"]), s.countries[cid]["capital"], "reserve")


static func _nearest_enemy_cell(s: Simulation, cid: int, from: int) -> int:
	var enemies := s.enemies_of(cid)
	if enemies.is_empty():
		return -1
	var seen := {from: 0}
	var queue: Array[int] = [from]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		if seen[cur] > 10:
			break
		for q in s.provinces()[cur]["land_neighbors"]:
			if seen.has(q):
				continue
			seen[q] = seen[cur] + 1
			if s.owner[q] >= 0 and enemies.has(s.owner[q]):
				return q
			queue.append(q)
	return -1


static func _add_directive(s: Simulation, cid: int, group: int, target: int, stance: String) -> void:
	var st: Dictionary = s.x["staff"][cid]
	st["directives"] = st["directives"].filter(func(d): return d["group"] != group)
	st["directives"].append({"id": st["next_id"], "group": group, "target": target, "stance": stance})
	st["next_id"] = int(st["next_id"]) + 1


# ------------------------------------------------------------------ commands

const COMMANDS := ["set_tax", "borrow", "repay", "set_budget", "set_state_share", "set_foreign_share", "anticorruption", "set_tariff", "referendum",
	"set_autonomy", "propose", "respond_offer", "create_bloc", "join_bloc", "leave_bloc", "request_ceasefire", "court_case", "summit", "concede",
	"invest_space", "launch_satellite", "space_coop", "set_directive", "clear_directive", "set_staff_auto", "build_works", "repair_cell", "info_op",
	"set_info_defense", "build_ship", "airlift"]


static func command(s: Simulation, cid: int, type: String, cmd: Dictionary) -> Dictionary:
	if s.rule_gov2 and SimMore.COMMANDS.has(type):
		return SimMore.command(s, cid, type, cmd)
	if not s.rule_gov2 or not COMMANDS.has(type):
		return s._fail("unknown command")
	var c: Dictionary = s.countries[cid]
	var f: Dictionary = s.x["fin"][cid]
	var po: Dictionary = s.x["pol"][cid]
	match type:
		"set_tax":
			f["tax"] = clampi(int(cmd.get("rate", 30)), 10, 60)
			return {"ok": true}
		"borrow":
			var amount := clampi(int(cmd.get("amount", 0)), 1, 5000)
			if int(f["default_until"]) > s.day:
				return s._fail("in default")
			if int(f["debt"]) + amount > maxi(c["income"], 5) * 400:
				return s._fail("credit limit")
			f["debt"] = int(f["debt"]) + amount
			c["treasury"] += amount
			return {"ok": true}
		"repay":
			var pay := mini(clampi(int(cmd.get("amount", 0)), 1, 5000), mini(int(f["debt"]), c["treasury"]))
			if pay <= 0:
				return s._fail("nothing to repay")
			f["debt"] = int(f["debt"]) - pay
			c["treasury"] -= pay
			return {"ok": true}
		"set_budget":
			f["edu"] = clampi(int(cmd.get("edu", f["edu"])), 0, 30)
			f["health"] = clampi(int(cmd.get("health", f["health"])), 0, 30)
			return {"ok": true}
		"set_state_share":
			f["state"] = clampi(int(cmd.get("share", 40)), 0, 100)
			f["foreign"] = mini(int(f["foreign"]), 100 - int(f["state"]))
			return {"ok": true}
		"set_foreign_share":
			f["foreign"] = clampi(int(cmd.get("share", 10)), 0, mini(50, 100 - int(f["state"])))
			return {"ok": true}
		"anticorruption":
			if c["pp"] < 20:
				return s._fail("not enough influence")
			if s.day - int(f["last_anticorr"]) < 60:
				return s._fail("on cooldown")
			c["pp"] -= 20
			f["last_anticorr"] = s.day
			s.x["soc"][cid]["corr"] = maxi(5, int(s.x["soc"][cid]["corr"]) - 5)
			return {"ok": true}
		"set_tariff":
			var tg: int = int(cmd.get("target", -1))
			var pct := clampi(int(cmd.get("pct", 0)), 0, 40)
			if tg < 0 or tg >= s.countries.size() or tg == cid or not s.countries[tg]["alive"]:
				return s._fail("invalid target")
			s.x["tariff"] = s.x["tariff"].filter(func(t): return not (t["a"] == cid and t["b"] == tg))
			if pct > 0:
				for p in s.x["dip"]["pacts"]:
					if p["kind"] == "trade_pact" and ((p["a"] == cid and p["b"] == tg) or (p["a"] == tg and p["b"] == cid)):
						return s._fail("trade pact")
				s.x["tariff"].append({"a": cid, "b": tg, "pct": pct})
				_shift_rel(s, cid, tg, -pct / 5)
			return {"ok": true}
		"referendum":
			if c["pp"] < 30:
				return s._fail("not enough influence")
			var topic := str(cmd.get("topic", ""))
			if not ["constitution", "liberalize"].has(topic):
				return s._fail("invalid topic")
			if topic == "liberalize" and str(c["ideology"]) == "democracy":
				return s._fail("already democracy")
			if topic == "constitution" and str(c["ideology"]) != "democracy":
				return s._fail("not a democracy")
			c["pp"] -= 30
			var pass_it: bool = (int(po["approval"]) + s.rng.randi_range(-15, 15)) >= 50
			if pass_it:
				if topic == "constitution":
					po["constitution"] = "presidential" if po["constitution"] == "parliamentary" else "parliamentary"
				else:
					s._change_government(c, "democracy", "референдум")
				c["stability"] = mini(100, int(c["stability"]) + 5)
				po["unrest"] = maxi(0, int(po["unrest"]) - 15)
			else:
				c["stability"] = maxi(0, int(c["stability"]) - 5)
				po["unrest"] = mini(100, int(po["unrest"]) + 10)
			_log(s, "референдум в стране %s (%s): %s" % [c["name"], topic, "принят" if pass_it else "отклонён"])
			return {"ok": true, "passed": pass_it}
		"set_autonomy":
			var lvl := clampi(int(cmd.get("level", 0)), 0, 2)
			var cost := absi(lvl - int(po["autonomy"])) * 10
			if c["pp"] < cost:
				return s._fail("not enough influence")
			c["pp"] -= cost
			po["autonomy"] = lvl
			return {"ok": true}
		"propose":
			return _propose(s, cid, cmd)
		"respond_offer":
			return _respond(s, cid, cmd)
		"create_bloc":
			var nm := str(cmd.get("name", "")).strip_edges()
			if nm.is_empty() or nm.length() > 24:
				return s._fail("invalid name")
			if c["pp"] < 30:
				return s._fail("not enough influence")
			for bl in s.x["dip"]["blocs"]:
				if bl["members"].has(cid):
					return s._fail("already in a bloc")
			c["pp"] -= 30
			s.x["dip"]["blocs"].append({"id": s.x["dip"]["next_id"], "name": nm, "leader": cid, "members": [cid]})
			s.x["dip"]["next_id"] = int(s.x["dip"]["next_id"]) + 1
			return {"ok": true}
		"join_bloc":
			for bl in s.x["dip"]["blocs"]:
				if bl["members"].has(cid):
					return s._fail("already in a bloc")
			for bl in s.x["dip"]["blocs"]:
				if bl["id"] == int(cmd.get("bloc", -1)):
					if relation(s, bl["leader"], cid) < 10:
						return s._fail("refused")
					bl["members"].append(cid)
					return {"ok": true}
			return s._fail("no such bloc")
		"leave_bloc":
			for bl in s.x["dip"]["blocs"]:
				if bl["members"].has(cid):
					bl["members"].erase(cid)
					if bl["leader"] == cid and not bl["members"].is_empty():
						bl["leader"] = bl["members"][0]
			s.x["dip"]["blocs"] = s.x["dip"]["blocs"].filter(func(b): return not b["members"].is_empty())
			return {"ok": true}
		"request_ceasefire":
			var en: int = int(cmd.get("target", -1))
			if c["pp"] < 20:
				return s._fail("not enough influence")
			if en < 0 or en >= s.countries.size() or not s.at_war(cid, en):
				return s._fail("not at war")
			c["pp"] -= 20
			var chance: int = 20 + (100 - int(c["war_support"])) / 4 + (100 - int(s.countries[en]["war_support"])) / 4
			var ok := s.rng.randi_range(0, 99) < chance
			if ok:
				s._end_war(cid, en, "миротворческий совет")
			return {"ok": true, "ceasefire": ok}
		"court_case":
			var ag: int = int(cmd.get("against", -1))
			if c["pp"] < 15:
				return s._fail("not enough influence")
			if ag < 0 or ag >= s.countries.size() or ag == cid:
				return s._fail("invalid target")
			var legal_cells := 0
			for p in s.cells_of(ag):
				if s.legal[p] == cid:
					legal_cells += 1
			if legal_cells == 0:
				return s._fail("no claim")
			for cl in s.x["dip"]["claims"]:
				if cl["by"] == cid and cl["against"] == ag:
					return s._fail("already filed")
			c["pp"] -= 15
			s.x["dip"]["claims"].append({"by": cid, "against": ag, "ruling": s.day + 30, "cells": legal_cells})
			return {"ok": true}
		"summit":
			if c["pp"] < 25:
				return s._fail("not enough influence")
			var who: Array = cmd.get("targets", [])
			if who.size() < 2 or who.size() > 6:
				return s._fail("invalid targets")
			for t in who:
				if int(t) < 0 or int(t) >= s.countries.size() or int(t) == cid or not s.countries[int(t)]["alive"]:
					return s._fail("invalid target")
			c["pp"] -= 25
			for i in who.size():
				_shift_rel(s, cid, int(who[i]), 8)
				for j in range(i + 1, who.size()):
					_shift_rel(s, int(who[i]), int(who[j]), 3)
			s.x["dip"]["crises"] = s.x["dip"]["crises"].filter(func(cr): return not (who.has(cr["a"]) and who.has(cr["b"])))
			return {"ok": true}
		"concede":
			for cr in s.x["dip"]["crises"]:
				if cr["a"] == cid or cr["b"] == cid:
					if c["treasury"] < 30:
						return s._fail("cannot afford")
					c["treasury"] -= 30
					_shift_rel(s, cr["a"], cr["b"], 20)
					s.x["dip"]["crises"].erase(cr)
					return {"ok": true}
			return s._fail("no crisis")
		"invest_space":
			var inv := clampi(int(cmd.get("amount", 100)), 10, 1000)
			if c["treasury"] < inv:
				return s._fail("not enough funds")
			c["treasury"] -= inv
			s.x["space"][cid]["progress"] = int(s.x["space"][cid]["progress"]) + inv
			_level_up(s, cid)
			return {"ok": true}
		"launch_satellite":
			var sp: Dictionary = s.x["space"][cid]
			var kind := str(cmd.get("kind", ""))
			if not SAT_KINDS.has(kind):
				return s._fail("invalid satellite")
			if int(sp["level"]) < 1:
				return s._fail("technology required")
			if c["treasury"] < 120:
				return s._fail("not enough funds")
			if c["stock"]["steel"] < 30:
				return s._fail("not enough steel")
			if _sat_total(s, cid) >= 12:
				return s._fail("too many sites")
			c["treasury"] -= 120
			c["stock"]["steel"] -= 30
			sp["sats"][kind] = int(sp["sats"][kind]) + 1
			return {"ok": true}
		"space_coop":
			var pt: int = int(cmd.get("partner", -1))
			if pt >= 0 and (pt >= s.countries.size() or not s.allied(cid, pt)):
				return s._fail("ally required")
			s.x["space"][cid]["coop"] = pt
			return {"ok": true}
		"set_directive":
			var g := s.group_by_id(int(cmd.get("group", -1)))
			if g.is_empty() or g["owner"] != cid:
				return s._fail("no such group")
			var stance := str(cmd.get("stance", "attack"))
			if not ["attack", "defend", "reserve"].has(stance):
				return s._fail("invalid stance")
			var tgt: int = int(cmd.get("target", c["capital"]))
			if tgt < 0 or tgt >= s.owner.size() or not s.provinces()[tgt]["land"]:
				return s._fail("invalid destination")
			_add_directive(s, cid, int(g["id"]), tgt, stance)
			return {"ok": true}
		"clear_directive":
			var gid: int = int(cmd.get("group", -1))
			s.x["staff"][cid]["directives"] = s.x["staff"][cid]["directives"].filter(func(d): return d["group"] != gid)
			return {"ok": true}
		"set_staff_auto":
			s.x["staff"][cid]["auto"] = bool(cmd.get("on", true))
			return {"ok": true}
		"build_works":
			var wk := str(cmd.get("kind", ""))
			var cell: int = int(cmd.get("cell", -1))
			if not WORKS.has(wk):
				return s._fail("invalid site")
			if cell < 0 or cell >= s.owner.size() or s.owner[cell] != cid or not s.provinces()[cell]["land"]:
				return s._fail("invalid base")
			var wd: Dictionary = WORKS[wk]
			var have: int = int(s.x["works"].get(cell, {}).get(wk, 0))
			if have >= 3:
				return s._fail("already maximal")
			for pr in s.x["projects"]:
				if pr["cell"] == cell and pr["kind"] == wk:
					return s._fail("already running")
			if wk == "port" and s._coastal[cell] != 1:
				return s._fail("no port")
			if c["treasury"] < int(wd["cost"]) * (have + 1):
				return s._fail("not enough funds")
			if c["stock"]["steel"] < int(wd["steel"]) * (have + 1):
				return s._fail("not enough steel")
			c["treasury"] -= int(wd["cost"]) * (have + 1)
			c["stock"]["steel"] -= int(wd["steel"]) * (have + 1)
			s.x["projects"].append({"owner": cid, "cell": cell, "kind": wk, "done": s.day + int(wd["days"])})
			return {"ok": true}
		"repair_cell":
			var rc: int = int(cmd.get("cell", -1))
			if rc < 0 or rc >= s.owner.size() or s.owner[rc] != cid or s.damage[rc] <= 0:
				return s._fail("nothing to repair")
			var fix := mini(20, s.damage[rc])
			var price := fix * 2
			if c["treasury"] < price:
				return s._fail("not enough funds")
			c["treasury"] -= price
			s.damage[rc] -= fix
			s._agg_key = []
			return {"ok": true}
		"info_op":
			var tg2: int = int(cmd.get("target", -1))
			if tg2 < 0 or tg2 >= s.countries.size() or tg2 == cid or not s.countries[tg2]["alive"]:
				return s._fail("invalid target")
			if c["pp"] < 20:
				return s._fail("not enough influence")
			if s.day - int(po["last_info_op"]) < 20:
				return s._fail("on cooldown")
			c["pp"] -= 20
			po["last_info_op"] = s.day
			var success := 70 - int(s.x["info"][tg2]["defense"]) * 10 - s.mod(tg2, "cyber_def_pct")
			var hit := s.rng.randi_range(0, 99) < clampi(success, 10, 90)
			if hit:
				s.countries[tg2]["stability"] = maxi(0, int(s.countries[tg2]["stability"]) - 3)
				s.countries[tg2]["war_support"] = maxi(0, int(s.countries[tg2]["war_support"]) - 5)
				s.x["pol"][tg2]["unrest"] = mini(100, int(s.x["pol"][tg2]["unrest"]) + 4)
			_shift_rel(s, cid, tg2, -3)
			return {"ok": true, "success": hit}
		"set_info_defense":
			var lv := clampi(int(cmd.get("level", 0)), 0, 3)
			var price2 := maxi(0, lv - int(s.x["info"][cid]["defense"])) * 15
			if c["pp"] < price2:
				return s._fail("not enough influence")
			c["pp"] -= price2
			s.x["info"][cid]["defense"] = lv
			return {"ok": true}
		"build_ship":
			return s._build_ship(cid, str(cmd.get("cls", "")))
		"airlift":
			return s._airlift(cid, int(cmd.get("army", -1)), int(cmd.get("target", -1)))
	return s._fail("unknown command")


# ------------------------------------------------------------------ AI subsystems

## One entry per subsystem so each can be tested and tuned on its own (the legacy military/strategic AI of Simulation._ai stays as it was).
static func ai(s: Simulation, cid: int) -> void:
	if not s.rule_gov2 or not s.x["fin"].has(cid):
		return
	_ai_economic(s, cid)
	_ai_political(s, cid)
	_ai_diplomatic(s, cid)
	_ai_space(s, cid)
	_ai_military(s, cid)
	_ai_modern(s, cid)
	SimMore.ai(s, cid)


static func _ai_economic(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var f: Dictionary = s.x["fin"][cid]
	var po: Dictionary = s.x["pol"][cid]
	if c["treasury"] < 40:
		command(s, cid, "borrow", {"amount": 100})
	elif c["treasury"] > 600 and int(f["debt"]) > 0:
		command(s, cid, "repay", {"amount": 100})
	var tax := int(f["tax"])
	if int(c["stability"]) > 60 and int(po["unrest"]) < 20 and tax < 36:
		command(s, cid, "set_tax", {"rate": tax + 1})
	elif int(c["stability"]) < 35 and tax > 24:
		command(s, cid, "set_tax", {"rate": tax - 2})
	if c["treasury"] > 400 and c["stock"]["steel"] >= 60:
		var kinds := ["rail", "power", "factory", "farm"]
		var kind: String = kinds[(s.day / 5 + cid) % kinds.size()]
		command(s, cid, "build_works", {"kind": kind, "cell": c["capital"]})


static func _ai_political(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var po: Dictionary = s.x["pol"][cid]
	if int(po["unrest"]) >= 50 and int(po["autonomy"]) < 1:
		command(s, cid, "set_autonomy", {"level": 1})
	if int(s.x["soc"][cid]["corr"]) > 60:
		command(s, cid, "anticorruption", {})
	if int(po["approval"]) >= 60 and c["pp"] >= 60 and s.day % 360 == 0 and s.rng.randi_range(0, 99) < 15:
		command(s, cid, "referendum", {"topic": "liberalize" if str(c["ideology"]) != "democracy" else "constitution"})


static func _ai_diplomatic(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	for en in s.enemies_of(cid):
		if int(c["war_support"]) < 30:
			command(s, cid, "request_ceasefire", {"target": en})
			break
	if s.day % 60 != 0:
		return
	var in_bloc := false
	for bl in s.x["dip"]["blocs"]:
		in_bloc = in_bloc or bl["members"].has(cid)
	if not in_bloc and s.x["dip"]["blocs"].is_empty() and c["pp"] >= 60 and s.cells_of(cid).size() >= 30:
		command(s, cid, "create_bloc", {"name": "Союз %s" % c["name"]})
	elif not in_bloc:
		for bl in s.x["dip"]["blocs"]:
			if command(s, cid, "join_bloc", {"bloc": bl["id"]}).get("ok", false):
				break
	for nb in s.neighbor_countries(cid):
		if relation(s, cid, nb) >= 10 and not s.at_war(cid, nb):
			var r := command(s, cid, "propose", {"target": nb, "kind": "trade_pact", "money": 0})
			if r.get("ok", false):
				break


static func _ai_space(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var sp: Dictionary = s.x["space"][cid]
	if c["treasury"] > 500 and s.day % 10 == 0:
		command(s, cid, "invest_space", {"amount": 100})
	if int(sp["level"]) >= 1 and c["treasury"] > 300 and s.day % 30 == 0:
		var kinds := ["nav", "recon", "comm"]
		command(s, cid, "launch_satellite", {"kind": kinds[(s.day / 30 + cid) % 3]})


static func _ai_military(s: Simulation, cid: int) -> void:
	var st: Dictionary = s.x["staff"][cid]
	if not bool(st["auto"]):
		st["auto"] = true


static func _ai_modern(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	if int(s.x["info"][cid]["defense"]) < 1 and c["pp"] >= 15:
		command(s, cid, "set_info_defense", {"level": 1})
	for en in s.enemies_of(cid):
		if c["pp"] >= 40 and s.day % 20 == 0:
			command(s, cid, "info_op", {"target": en})
			break


# ------------------------------------------------------------------ player panel (data-driven: the UI only renders these rows)

static func _cmd(country: int, type: String, extra: Dictionary) -> Dictionary:
	var d := {"type": type, "country": country}
	d.merge(extra)
	return d


static func panel(s: Simulation, cid: int) -> Array:
	var rows: Array = []
	var c: Dictionary = s.countries[cid]
	var f: Dictionary = s.x["fin"][cid]
	var so: Dictionary = s.x["soc"][cid]
	var po: Dictionary = s.x["pol"][cid]
	var sp: Dictionary = s.x["space"][cid]
	var st: Dictionary = s.x["staff"][cid]
	rows.append({"t": "h", "text": "Финансы"})
	rows.append({"t": "kv", "k": "Налог", "v": "%d%%  (доход %d, расход %d в день)" % [f["tax"], c["income"], c["upkeep"]]})
	rows.append({"t": "step", "text": "Ставка налога", "value": "%d%%" % f["tax"], "minus": _cmd(cid, "set_tax", {"rate": int(f["tax"]) - 5}), "plus": _cmd(cid, "set_tax", {"rate": int(f["tax"]) + 5})})
	rows.append({"t": "kv", "k": "Долг", "v": "%d (ставка %.1f%%)" % [f["debt"], float(_rate(s, cid, maxi(c["income"], 1))) / 100.0]})
	rows.append({"t": "step", "text": "Кредит / погашение", "value": "100", "minus": _cmd(cid, "repay", {"amount": 100}), "plus": _cmd(cid, "borrow", {"amount": 100})})
	rows.append({"t": "kv", "k": "Инфляция · курс · биржа", "v": "%.1f%% · %.2f · %d" % [float(f["infl"]) / 100.0, float(f["fx"]) / 10000.0, f["stock"]]})
	rows.append({"t": "kv", "k": "Теневая экономика", "v": "%d%%" % f["shadow"]})
	rows.append({"t": "step", "text": "Расходы на образование", "value": "%d%%" % f["edu"], "minus": _cmd(cid, "set_budget", {"edu": int(f["edu"]) - 2}), "plus": _cmd(cid, "set_budget", {"edu": int(f["edu"]) + 2})})
	rows.append({"t": "step", "text": "Расходы на здравоохранение", "value": "%d%%" % f["health"], "minus": _cmd(cid, "set_budget", {"health": int(f["health"]) - 2}), "plus": _cmd(cid, "set_budget", {"health": int(f["health"]) + 2})})
	rows.append({"t": "step", "text": "Доля государства в экономике", "value": "%d%% (иностр. %d%%)" % [f["state"], f["foreign"]], "minus": _cmd(cid, "set_state_share", {"share": int(f["state"]) - 10}), "plus": _cmd(cid, "set_state_share", {"share": int(f["state"]) + 10})})
	rows.append({"t": "h", "text": "Общество"})
	rows.append({"t": "kv", "k": "Рождаемость / смертность", "v": "%d‰ / %d‰ (население %.1f%% от старта)" % [so["birth"], so["death"], float(so["pop"]) / 100.0]})
	rows.append({"t": "kv", "k": "Образование · здоровье · урбанизация", "v": "%d · %d · %d%%" % [so["edu"], so["health"], so["urban"]]})
	rows.append({"t": "kv", "k": "Безработица · бедность · коррупция", "v": "%d%% · %d%% · %d%%" % [so["unemp"], so["poverty"], so["corr"]]})
	rows.append({"t": "kv", "k": "Настроения · беженцы · эпидемия", "v": "%d · %d · %s" % [so["mood"], so["refugees"], ("%d дн." % so["epidemic"]) if int(so["epidemic"]) > 0 else "нет"]})
	rows.append({"t": "btn", "text": "Борьба с коррупцией (20 влияния)", "cmd": _cmd(cid, "anticorruption", {})})
	rows.append({"t": "h", "text": "Политика"})
	var gov := ""
	for p in po["parties"]:
		if p["id"] == po["gov"]:
			gov = p["name"]
	rows.append({"t": "kv", "k": "Правящая партия", "v": "%s · %s" % [gov, po["constitution"]]})
	var plist: Array[String] = []
	for p in po["parties"]:
		var pc := party_pct(s, cid, p)
		if pc >= 5:
			plist.append("%s %d%%" % [p["name"], pc])
	rows.append({"t": "kv", "k": "Партии", "v": ", ".join(plist)})
	rows.append({"t": "kv", "k": "Выборы / последний итог", "v": "день %d · %s" % [po["next_election"], po["last_result"] if str(po["last_result"]) != "" else "—"]})
	rows.append({"t": "kv", "k": "Недовольство · одобрение", "v": "%d%% · %d%%%s" % [po["unrest"], po["approval"], "  (забастовка)" if int(po["strike_until"]) > s.day else ""]})
	rows.append({"t": "step", "text": "Региональная автономия", "value": str(po["autonomy"]), "minus": _cmd(cid, "set_autonomy", {"level": int(po["autonomy"]) - 1}), "plus": _cmd(cid, "set_autonomy", {"level": int(po["autonomy"]) + 1})})
	rows.append({"t": "btn", "text": "Референдум: реформа конституции (30 влияния)", "cmd": _cmd(cid, "referendum", {"topic": "constitution"})})
	rows.append({"t": "btn", "text": "Референдум: либерализация (30 влияния)", "cmd": _cmd(cid, "referendum", {"topic": "liberalize"})})
	rows.append({"t": "h", "text": "Дипломатия"})
	var d: Dictionary = s.x["dip"]
	for o in d["offers"]:
		if o["status"] == "countered" and o["from"] == cid:
			rows.append({"t": "btn", "text": "Встречное предложение от %s: %s, платёж %d — принять" % [s.countries[o["to"]]["name"], o["kind"], o["money"]], "cmd": _cmd(cid, "respond_offer", {"offer": o["id"], "accept": true})})
	for bl in d["blocs"]:
		var mine: bool = bl["members"].has(cid)
		rows.append({"t": "kv", "k": "Блок «%s»" % bl["name"], "v": "%d стран%s" % [bl["members"].size(), " (вы в блоке)" if mine else ""]})
		if not mine:
			rows.append({"t": "btn", "text": "Вступить в блок «%s»" % bl["name"], "cmd": _cmd(cid, "join_bloc", {"bloc": bl["id"]})})
	rows.append({"t": "btn", "text": "Создать экономический блок (30 влияния)", "cmd": _cmd(cid, "create_bloc", {"name": "Союз %s" % c["name"]})})
	rows.append({"t": "kv", "k": "Дипломатические кризисы", "v": str(d["crises"].size())})
	rows.append({"t": "h", "text": "Космос"})
	rows.append({"t": "kv", "k": "Уровень программы", "v": "%d (прогресс %d / %d)" % [sp["level"], sp["progress"], (int(sp["level"]) + 1) * SPACE_LEVEL_COST]})
	rows.append({"t": "kv", "k": "Спутники", "v": "разведка %d · навигация %d · связь %d" % [sp["sats"]["recon"], sp["sats"]["nav"], sp["sats"]["comm"]]})
	rows.append({"t": "btn", "text": "Вложить в космос 100", "cmd": _cmd(cid, "invest_space", {"amount": 100})})
	for k in SAT_KINDS:
		rows.append({"t": "btn", "text": "Запустить спутник: %s (120 $, 30 стали)" % SAT_KINDS[k], "cmd": _cmd(cid, "launch_satellite", {"kind": k})})
	rows.append({"t": "h", "text": "Штаб"})
	rows.append({"t": "kv", "k": "Режим штаба", "v": "автоматический" if bool(st["auto"]) else "ручной"})
	rows.append({"t": "btn", "text": "Переключить режим штаба", "cmd": _cmd(cid, "set_staff_auto", {"on": not bool(st["auto"])})})
	for dr in st["directives"]:
		rows.append({"t": "kv", "k": "Приказ группе #%d" % dr["group"], "v": "%s → клетка #%d" % [dr["stance"], dr["target"]]})
	for r in st["reports"].slice(maxi(0, st["reports"].size() - 4)):
		rows.append({"t": "kv", "k": "Отчёт", "v": r})
	rows.append({"t": "h", "text": "Информационная война"})
	rows.append({"t": "kv", "k": "Защита", "v": str(s.x["info"][cid]["defense"])})
	rows.append({"t": "step", "text": "Уровень информационной защиты", "value": str(s.x["info"][cid]["defense"]), "minus": _cmd(cid, "set_info_defense", {"level": int(s.x["info"][cid]["defense"]) - 1}), "plus": _cmd(cid, "set_info_defense", {"level": int(s.x["info"][cid]["defense"]) + 1})})
	for en in s.enemies_of(cid):
		rows.append({"t": "btn", "text": "Информационная кампания против %s (20 влияния)" % s.countries[en]["name"], "cmd": _cmd(cid, "info_op", {"target": en})})
		rows.append({"t": "btn", "text": "Просить перемирие: %s (20 влияния)" % s.countries[en]["name"], "cmd": _cmd(cid, "request_ceasefire", {"target": en})})
	rows.append_array(SimMore.panel(s, cid))
	return rows
