class_name SimMore
extends RefCounted
## Second layer of the gov2 rule: banks and corporations as objects, parliament and coalitions, international organisations
## with votes, defence lines with garrisons and reserves, ship roles (submarine raiders, carrier air groups, picket boats) and
## the AI's army-group and defence planning. State lives in `sim.x["more"]` (saved, part of the state hash with the rule).
## Everything is an abstract game model with invented balance numbers.

const SECTORS := {
	"industry": "Промышленность", "energy": "Энергетика", "tech": "Технологии", "food": "Агропром", "finance": "Финансы", "arms": "Оборонка",
}
const BANK_NAMES := ["Национальный банк", "Торговый банк", "Сберегательный банк", "Инвестиционный банк"]
const IDEO_POS := {"democracy": 0, "monarchy": 1, "autocracy": 2, "communism": 3}
const ORG_DEFS := [
	{"id": 0, "name": "Всемирная ассамблея", "weights": "equal", "veto": 0, "kinds": ["condemn", "aid", "expel"]},
	{"id": 1, "name": "Торговая организация", "weights": "income", "veto": 0, "kinds": ["sanction", "tariff_free"]},
	{"id": 2, "name": "Миротворческий совет", "weights": "equal", "veto": 3, "kinds": ["peace", "sanction"]},
	{"id": 3, "name": "Международный суд", "weights": "equal", "veto": 0, "kinds": ["condemn"]},
]
const COMMANDS := ["set_policy", "bail_bank", "nationalize_corp", "privatize_corp", "subsidize_corp", "form_coalition", "concede_partner",
	"dissolve_parliament", "join_org", "leave_org", "propose_resolution", "vote", "draw_line", "fortify_line", "man_line", "set_reserve",
	"remove_line", "embark_wing", "disembark_wing"]
const MAX_LINES := 4


# ------------------------------------------------------------------ setup

static func setup(s: Simulation) -> void:
	var m := {"bank": {}, "corp": {}, "parl": {}, "orgs": [], "lines": {}, "sanctions": {}, "next_id": 1, "raids": 0}
	s.x["more"] = m
	for c in s.countries:
		var cid: int = c["id"]
		var gdp := int(s.gdp_of.get(cid, 800000))
		var nb := clampi(2 + gdp / 1500000, 2, 4)
		var banks: Array = []
		for i in nb:
			var cap := 100 + gdp / 4000 / nb
			banks.append({"id": m["next_id"], "name": BANK_NAMES[i], "cap": cap, "loans": cap * 8, "bad": 3, "state": i == 0, "failed_until": 0})
			m["next_id"] = int(m["next_id"]) + 1
		m["bank"][cid] = {"policy": 0, "last_policy": -999, "banks": banks, "crisis_until": 0}
		var nc := clampi(2 + gdp / 800000, 2, 6)
		var corps: Array = []
		var keys: Array = SECTORS.keys()
		for i in nc:
			var sec: String = keys[(cid + i) % keys.size()]
			corps.append({"id": m["next_id"], "name": "%s-%d" % [SECTORS[sec], cid * 10 + i], "sector": sec, "size": 60 + (cid * 17 + i * 31) % 140,
				"profit": 3, "state": i == 0 and (cid % 3 == 0), "foreign": i == nc - 1 and (cid % 2 == 0)})
			m["next_id"] = int(m["next_id"]) + 1
		m["corp"][cid] = corps
		m["lines"][cid] = []
		m["parl"][cid] = {"seats": {}, "coalition": [], "sat": {}, "minority_since": -1, "last_dissolve": -9999}
		_seat_parliament(s, cid)
	# organisations: every country starts as a member; veto holders of the peace council are the three richest
	var by_income: Array = []
	for c in s.countries:
		if c["alive"]:
			by_income.append(c["id"])
	by_income.sort_custom(func(a, b): return s.countries[a]["income"] > s.countries[b]["income"] or (s.countries[a]["income"] == s.countries[b]["income"] and a < b))
	for d in ORG_DEFS:
		var members: Array = []
		for c in s.countries:
			if c["alive"]:
				members.append(c["id"])
		m["orgs"].append({"id": d["id"], "name": d["name"], "weights": d["weights"], "kinds": d["kinds"], "members": members,
			"veto": by_income.slice(0, d["veto"]), "res": []})


# ------------------------------------------------------------------ economy hooks

static func policy(s: Simulation, cid: int) -> int:
	return int(s.x["more"]["bank"][cid]["policy"])


## Income modifiers of the money system: credit boom, corporate profit tax, org sanctions, banking crisis.
static func income_mod(s: Simulation, cid: int, inc: int) -> int:
	var mm: Dictionary = s.x["more"]
	var bk: Dictionary = mm["bank"][cid]
	var loans := 0
	for b in bk["banks"]:
		if int(b["failed_until"]) <= s.day:
			loans += int(b["loans"])
	var cap_total := 0
	for b in bk["banks"]:
		cap_total += maxi(int(b["cap"]), 0)
	if loans > 0:
		inc = inc * (100 + mini(4, loans / maxi(cap_total * 4, 1))) / 100   # a healthy credit supply helps growth
	if int(bk["crisis_until"]) > s.day:
		inc = inc * 93 / 100
	var tax: int = int(s.x["fin"][cid]["tax"])
	var corp_tax := 0
	for cp in mm["corp"][cid]:
		var prof: int = int(cp["size"]) * int(cp["profit"]) / 100
		if bool(cp["state"]):
			corp_tax += prof
		else:
			corp_tax += prof * tax / 100 * (100 - int(s.x["fin"][cid]["shadow"])) / 100
	inc += corp_tax * 100 / 30   # inc is fixed point x100 here
	if int(mm["sanctions"].get(cid, 0)) > s.day:
		inc = inc * 92 / 100
	return inc


# ------------------------------------------------------------------ daily

static func daily(s: Simulation) -> void:
	var d: int = s.day
	if d % 30 == 0:
		for c in s.countries:
			if c["alive"]:
				_banks_monthly(s, c["id"])
				_corps_monthly(s, c["id"])
				_parliament_monthly(s, c["id"])
	if d % 5 == 0:
		_resolve_orgs(s)
		_raid_convoys(s)
	if d % 3 == 0:
		_lines_daily(s)
	_carrier_check(s)


static func _banks_monthly(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var bk: Dictionary = s.x["more"]["bank"][cid]
	var so: Dictionary = s.x["soc"][cid]
	var f: Dictionary = s.x["fin"][cid]
	var pol: int = int(bk["policy"])
	for b in bk["banks"]:
		if int(b["failed_until"]) > s.day:
			continue
		if int(b["failed_until"]) != 0:   # a failed bank is replaced by a fresh one
			b["failed_until"] = 0
			b["cap"] = 60
			b["loans"] = 300
			b["bad"] = 4
		var grow: int = 2 - pol * 2 + (int(so["mood"]) - 50) / 25
		b["loans"] = clampi(int(b["loans"]) + int(b["loans"]) * grow / 100, 50, maxi(int(b["cap"]), 20) * 14)
		var stress: int = int(so["unemp"]) / 3 + int(f["infl"]) / 400 + (3 if int(c["stability"]) < 40 else 0) + pol + (4 if int(f["default_until"]) > s.day else 0) - 5
		b["bad"] = clampi(int(b["bad"]) + signi(stress - int(b["bad"])), 0, 40)
		var profit: int = int(b["loans"]) * (30 + pol * 4) / 10000 - int(b["loans"]) * int(b["bad"]) / 3000
		b["cap"] = int(b["cap"]) + profit
		if int(b["cap"]) < 0:
			b["failed_until"] = s.day + 90
			b["loans"] = 0
			bk["crisis_until"] = s.day + 90
			c["stability"] = maxi(0, int(c["stability"]) - 4)
			so["mood"] = maxi(0, int(so["mood"]) - 6)
			s.x["pol"][cid]["unrest"] = mini(100, int(s.x["pol"][cid]["unrest"]) + 8)
			SimExt._log(s, "в стране %s обанкротился «%s»: банковский кризис" % [c["name"], b["name"]])


## Capital ratio in percent (capital / loans); below 8 a bank is in danger.
static func bank_ratio(b: Dictionary) -> int:
	return int(b["cap"]) * 100 / maxi(int(b["loans"]), 1)


static func _corps_monthly(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var so: Dictionary = s.x["soc"][cid]
	var f: Dictionary = s.x["fin"][cid]
	var at_war: bool = not s.enemies_of(cid).is_empty()
	var total := 0
	var lobby := false
	for cp in s.x["more"]["corp"][cid]:
		var base := 3
		match str(cp["sector"]):
			"arms":
				base += 3 if at_war else -1
			"tech":
				base += (int(so["edu"]) - 50) / 20
			"energy":
				base += 1 if c["short"].has("oil") else 0
			"food":
				base += -1 if c["short"].has("food") else 1
			"finance":
				base += (int(f["stock"]) - 1000) / 250
		base -= int(so["corr"]) / 40 + (1 if int(s.x["pol"][cid]["strike_until"]) > s.day else 0) + (2 if int(so["epidemic"]) > 0 else 0)
		if bool(cp["state"]):
			base -= 1   # state firms are less efficient
		cp["profit"] = clampi(base, -5, 12)
		cp["size"] = clampi(int(cp["size"]) + int(cp["size"]) * int(cp["profit"]) / 400, 20, 400)
		total += int(cp["profit"])
		if not bool(cp["state"]) and int(cp["size"]) > 220 and str(cp["sector"]) in ["tech", "finance", "arms"]:
			lobby = true
	if lobby and int(so["corr"]) < 80:
		so["corr"] = int(so["corr"]) + 1   # big private firms lobby
	var n := maxi(s.x["more"]["corp"][cid].size(), 1)
	f["stock"] = clampi(int(f["stock"]) + (total / n - 3) * 8, 200, 3000)


static func _parliament_monthly(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var pa: Dictionary = s.x["more"]["parl"][cid]
	var po: Dictionary = s.x["pol"][cid]
	var gov: int = int(po["gov"])
	var seats := coalition_seats(s, cid)
	for pid in pa["coalition"]:
		if pid == gov:
			continue
		var sat: int = int(pa["sat"].get(pid, 60))
		sat += (2 if int(po["approval"]) >= 55 else -2) + (-2 if int(po["unrest"]) > 50 else 0) + (-2 if seats < 51 else 0)
		pa["sat"][pid] = clampi(sat, 0, 100)
	for pid in pa["coalition"].duplicate():
		if pid != gov and int(pa["sat"].get(pid, 60)) < 15:
			pa["coalition"].erase(pid)
			SimExt._log(s, "в стране %s партия «%s» покинула коалицию" % [c["name"], _party_name(s, cid, pid)])
	seats = coalition_seats(s, cid)
	if seats < 51:
		po["approval"] = maxi(0, int(po["approval"]) - 3)
		c["stability"] = maxi(0, int(c["stability"]) - 1)
		if int(pa["minority_since"]) < 0:
			pa["minority_since"] = s.day
			SimExt._log(s, "в стране %s правительство меньшинства" % c["name"])
		elif s.day - int(pa["minority_since"]) >= 90 and str(c["ideology"]) == "democracy":
			po["next_election"] = s.day + 1   # snap election
			pa["minority_since"] = -1
			SimExt._log(s, "в стране %s досрочные выборы: коалиция не собрана" % c["name"])
	else:
		pa["minority_since"] = -1
		po["approval"] = mini(100, int(po["approval"]) + 2)


static func _party_name(s: Simulation, cid: int, pid: int) -> String:
	for p in s.x["pol"][cid]["parties"]:
		if p["id"] == pid:
			return str(p["name"])
	return "?"


# ------------------------------------------------------------------ parliament

## 100 seats by largest remainder of the parties' support; non-democracies appoint a docile chamber with a 70-seat ruling party.
static func _seat_parliament(s: Simulation, cid: int) -> void:
	var pa: Dictionary = s.x["more"]["parl"][cid]
	var po: Dictionary = s.x["pol"][cid]
	var c: Dictionary = s.countries[cid]
	var weights := {}
	var total := 0
	for p in po["parties"]:
		var w: int = SimExt.party_pct(s, cid, p) * 100 + 1
		weights[p["id"]] = w
		total += w
	var seats := {}
	var used := 0
	var rem: Array = []
	for pid in weights:
		var q: int = weights[pid] * 100 / total
		seats[pid] = q
		used += q
		rem.append([weights[pid] * 100 % total, pid])
	rem.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	var i := 0
	while used < 100:
		seats[rem[i % rem.size()][1]] += 1
		used += 1
		i += 1
	if str(c["ideology"]) != "democracy":
		var gov: int = int(po["gov"])
		var rest := 30
		var others := 0
		for pid in seats:
			if pid != gov:
				others += int(seats[pid])
		for pid in seats:
			if pid == gov:
				seats[pid] = 70
			else:
				seats[pid] = int(seats[pid]) * rest / maxi(others, 1)
		var sum := 0
		for pid in seats:
			sum += int(seats[pid])
		seats[gov] = int(seats[gov]) + (100 - sum)
	pa["seats"] = seats
	_default_coalition(s, cid)


static func seats_of(s: Simulation, cid: int, pid: int) -> int:
	return int(s.x["more"]["parl"][cid]["seats"].get(pid, 0))


static func coalition_seats(s: Simulation, cid: int) -> int:
	var n := 0
	for pid in s.x["more"]["parl"][cid]["coalition"]:
		n += seats_of(s, cid, pid)
	return n


static func _party_ideo(s: Simulation, cid: int, pid: int) -> String:
	for p in s.x["pol"][cid]["parties"]:
		if p["id"] == pid:
			return str(p["ideo"])
	return "democracy"


## Distance between two parties on the ideology axis (0 = same ideology).
static func party_distance(s: Simulation, cid: int, a: int, b: int) -> int:
	return absi(int(IDEO_POS[_party_ideo(s, cid, a)]) - int(IDEO_POS[_party_ideo(s, cid, b)]))


## Greedy coalition: the ruling party plus the closest parties until it holds 51 seats.
static func _default_coalition(s: Simulation, cid: int) -> void:
	var pa: Dictionary = s.x["more"]["parl"][cid]
	var gov: int = int(s.x["pol"][cid]["gov"])
	var members: Array = [gov]
	var n: int = seats_of(s, cid, gov)
	var cand: Array = []
	for pid in pa["seats"]:
		if pid != gov and int(pa["seats"][pid]) > 0:
			cand.append(pid)
	cand.sort_custom(func(a, b):
		var da := party_distance(s, cid, gov, a)
		var db := party_distance(s, cid, gov, b)
		if da != db:
			return da < db
		if pa["seats"][a] != pa["seats"][b]:
			return pa["seats"][a] > pa["seats"][b]
		return a < b)
	for pid in cand:
		if n >= 51:
			break
		members.append(pid)
		n += int(pa["seats"][pid])
	pa["coalition"] = members
	pa["sat"] = {}
	for pid in members:
		if pid != gov:
			pa["sat"][pid] = 60
	pa["minority_since"] = -1 if n >= 51 else s.day


## Called after every election or plebiscite: a new chamber and a new coalition.
static func after_election(s: Simulation, cid: int) -> void:
	if s.rule_gov2 and s.x.has("more"):
		_seat_parliament(s, cid)


# ------------------------------------------------------------------ organisations

static func org(s: Simulation, oid: int) -> Dictionary:
	for o in s.x["more"]["orgs"]:
		if o["id"] == oid:
			return o
	return {}


static func org_weight(s: Simulation, o: Dictionary, cid: int) -> int:
	if str(o["weights"]) == "income":
		return 1 + int(s.countries[cid]["income"]) / 4
	return 1


static func _ai_vote(s: Simulation, cid: int, o: Dictionary, r: Dictionary) -> bool:
	var by: int = int(r["by"])
	var tg: int = int(r["target"])
	var kind := str(r["kind"])
	var rb: int = SimExt.relation(s, cid, by)
	var rt: int = SimExt.relation(s, cid, tg)
	if cid == by:
		return true
	match kind:
		"peace":
			var other: int = int(r["other"])
			return not (s.at_war(cid, tg) or s.at_war(cid, other))
		"aid":
			return rt >= 5 or s.allied(cid, tg)
		"tariff_free":
			return rb >= 0
		_:   # condemn, sanction, expel
			var score: int = rb / 2 - rt + (20 if s.allied(cid, by) else 0) - (40 if s.allied(cid, tg) else 0)
			return score >= 5


static func _propose_res(s: Simulation, cid: int, cmd: Dictionary) -> Dictionary:
	var o := org(s, int(cmd.get("org", -1)))
	if o.is_empty():
		return s._fail("no such organization")
	if not o["members"].has(cid):
		return s._fail("not a member")
	var kind := str(cmd.get("kind", ""))
	if not o["kinds"].has(kind):
		return s._fail("invalid resolution")
	var tg: int = int(cmd.get("target", -1))
	var other: int = int(cmd.get("other", -1))
	if kind != "tariff_free" and (tg < 0 or tg >= s.countries.size() or not s.countries[tg]["alive"] or (tg == cid and kind != "aid")):
		return s._fail("invalid target")
	if kind == "peace":
		if other < 0 or other >= s.countries.size() or not s.at_war(tg, other):
			return s._fail("not at war")
		if not o["members"].has(tg) or not o["members"].has(other):
			return s._fail("not a member")
	var c: Dictionary = s.countries[cid]
	if c["pp"] < 15:
		return s._fail("not enough influence")
	var open := 0
	for r in o["res"]:
		if r["status"] == "open":
			open += 1
			if r["kind"] == kind and r["target"] == tg and r["other"] == other:
				return s._fail("already proposed")
	if open >= 3:
		return s._fail("agenda full")
	c["pp"] -= 15
	var mm: Dictionary = s.x["more"]
	var r := {"id": mm["next_id"], "by": cid, "kind": kind, "target": tg, "other": other, "day": s.day, "deadline": s.day + 8, "votes": {cid: true}, "status": "open"}
	mm["next_id"] = int(mm["next_id"]) + 1
	for mem in o["members"]:
		if mem != cid and s.countries[mem]["alive"] and s.countries[mem]["ai"]:
			r["votes"][mem] = _ai_vote(s, mem, o, r)
	o["res"].append(r)
	return {"ok": true, "res": r["id"]}


static func tally(s: Simulation, o: Dictionary, r: Dictionary) -> Dictionary:
	var yes := 0
	var no := 0
	var total := 0
	var vetoed := false
	for mem in o["members"]:
		if s.countries[mem]["alive"]:
			total += org_weight(s, o, mem)
	for mem in r["votes"]:
		if not o["members"].has(mem) or not s.countries[mem]["alive"]:
			continue
		var w := org_weight(s, o, mem)
		if r["votes"][mem]:
			yes += w
		else:
			no += w
			if o["veto"].has(mem):
				vetoed = true
	return {"yes": yes, "no": no, "total": total, "vetoed": vetoed}


static func _resolve_orgs(s: Simulation) -> void:
	for o in s.x["more"]["orgs"]:
		for r in o["res"]:
			if r["status"] != "open" or int(r["deadline"]) > s.day:
				continue
			var t := tally(s, o, r)
			var passed: bool = t["yes"] > t["no"] and not t["vetoed"] and (t["yes"] + t["no"]) * 100 >= t["total"] * 40
			r["status"] = "passed" if passed else ("vetoed" if t["vetoed"] and t["yes"] > t["no"] else "rejected")
			if passed:
				_apply_res(s, o, r)
		if o["res"].size() > 12:
			o["res"] = o["res"].filter(func(r): return r["status"] == "open").duplicate() + o["res"].filter(func(r): return r["status"] != "open").slice(-6)


static func _apply_res(s: Simulation, o: Dictionary, r: Dictionary) -> void:
	var tg: int = int(r["target"])
	var tname: String = s.countries[tg]["name"] if tg >= 0 else ""
	match str(r["kind"]):
		"condemn":
			s.countries[tg]["stability"] = maxi(0, int(s.countries[tg]["stability"]) - 3)
			for mem in r["votes"]:
				if r["votes"][mem] and mem != tg:
					SimExt._shift_rel(s, mem, tg, -4)
			SimExt._log(s, "«%s» осудила страну %s" % [o["name"], tname])
		"sanction":
			s.x["more"]["sanctions"][tg] = s.day + 90
			s.countries[tg]["stability"] = maxi(0, int(s.countries[tg]["stability"]) - 2)
			SimExt._log(s, "«%s» ввела санкции против страны %s на 90 дней" % [o["name"], tname])
		"aid":
			var pool := 0
			for mem in r["votes"]:
				if r["votes"][mem] and mem != tg and s.countries[mem]["treasury"] >= 15:
					s.countries[mem]["treasury"] -= 15
					pool += 15
			s.countries[tg]["treasury"] += pool
			SimExt._log(s, "«%s» направила помощь стране %s: %d" % [o["name"], tname, pool])
		"expel":
			o["members"].erase(tg)
			SimExt._log(s, "страна %s исключена из «%s»" % [tname, o["name"]])
		"peace":
			var other: int = int(r["other"])
			if s.at_war(tg, other):
				s._end_war(tg, other, "решение «%s»" % o["name"])
		"tariff_free":
			var yes_list: Array = []
			for mem in r["votes"]:
				if r["votes"][mem]:
					yes_list.append(mem)
			s.x["tariff"] = s.x["tariff"].filter(func(t): return not (yes_list.has(t["a"]) and yes_list.has(t["b"])))
			SimExt._log(s, "«%s»: пошлины между поддержавшими отменены" % o["name"])


# ------------------------------------------------------------------ naval roles

static func _detectors_in(s: Simulation, cell: int, owner_id: int) -> int:
	var n := 0
	for f in s.fleets_in(cell):
		if f["owner"] == owner_id and f["strength"] > 0 and str(f.get("cls", "")) in ["destroyer", "usv"]:
			n += 1
	return n


static func embarked(s: Simulation, fleet_id: int) -> int:
	var n := 0
	for w in s.wings:
		if int(w.get("carrier", -1)) == fleet_id and w["strength"] > 0:
			n += 1
	return n


## Multiplier of `me` against `foe` in a sea cell: submarines strike first from hiding, escorts hunt submarines, carriers fight better
## with an air group and an escort, pickets spot submarines.
static func ship_mult(s: Simulation, me: Dictionary, foe: Dictionary, cell: int) -> float:
	if not s.rule_gov2:
		return 1.0
	var cls := str(me.get("cls", ""))
	var fcls := str(foe.get("cls", ""))
	match cls:
		"submarine":
			if fcls == "submarine":
				return 1.0
			return 0.75 if _detectors_in(s, cell, int(foe["owner"])) > 0 else 1.6
		"destroyer":
			return 1.25 if fcls == "submarine" else 1.0
		"usv":
			return 1.15 if fcls == "submarine" else 1.0
		"carrier":
			var k := 1.0 + 0.12 * embarked(s, int(me["id"]))
			if _detectors_in(s, cell, int(me["owner"])) == 0:
				k *= 0.8   # no escort
			return k
	return 1.0


## Submarines on the sea lane of an enemy's trade intercept cargo while no escort is on station.
static func _raid_convoys(s: Simulation) -> void:
	for f in s.fleets:
		if str(f.get("cls", "")) != "submarine" or f["strength"] <= 0:
			continue
		var me: int = f["owner"]
		for t in s.trades:
			var victim := -1
			if s.at_war(me, t["buyer"]):
				victim = t["buyer"]
			elif s.at_war(me, t["seller"]):
				victim = t["seller"]
			if victim < 0:
				continue
			if not s.trade_route(t["buyer"], t["seller"]).has(f["prov"]):
				continue
			if _detectors_in(s, f["prov"], victim) > 0:
				continue
			var loss := mini(4, int(s.countries[victim]["treasury"]))
			if loss > 0:
				s.countries[victim]["treasury"] -= loss
				s.countries[me]["treasury"] += loss / 2
				s.x["more"]["raids"] = int(s.x["more"]["raids"]) + 1


static func _carrier_check(s: Simulation) -> void:
	for w in s.wings:
		if w.has("carrier") and s.wing_pos(w) == w["base"] and not _fleet_alive(s, int(w["carrier"])):
			w.erase("carrier")
			w["strength"] = w["strength"] / 2   # an air group lost its carrier
			w["mission"] = "idle"
			w["target"] = -1


static func _fleet_alive(s: Simulation, fid: int) -> bool:
	for f in s.fleets:
		if f["id"] == fid and f["strength"] > 0:
			return true
	return false


# ------------------------------------------------------------------ defence lines

static func lines_of(s: Simulation, cid: int) -> Array:
	return s.x["more"]["lines"].get(cid, [])


static func line_by_id(s: Simulation, cid: int, lid: int) -> Dictionary:
	for l in lines_of(s, cid):
		if l["id"] == lid:
			return l
	return {}


## Level of a finished defence line covering `cell` for `cid` (0 when none).
static func line_level(s: Simulation, cell: int, cid: int) -> int:
	var best := 0
	for l in lines_of(s, cid):
		if l["cells"].has(cell) and int(l["ready"]) <= s.day:
			best = maxi(best, int(l["level"]))
	return best


## Defender multiplier from a line (+10 % per level) and its garrison being present (+5 %).
static func line_bonus(s: Simulation, cell: int, cid: int) -> float:
	if not s.rule_gov2 or not s.x.has("more"):
		return 1.0
	var lv := line_level(s, cell, cid)
	if lv == 0:
		return 1.0
	var k := 1.0 + 0.10 * lv
	for l in lines_of(s, cid):
		if l["cells"].has(cell) and int(l["garrison"]) >= 0:
			var g := s.group_by_id(int(l["garrison"]))
			if not g.is_empty():
				for a in s.group_members(g):
					if a["prov"] == cell:
						return k + 0.05
	return k


static func _threatened(s: Simulation, cid: int, l: Dictionary) -> int:
	var enemies := s.enemies_of(cid)
	if enemies.is_empty():
		return -1
	for cell in l["cells"]:
		for q in s.provinces()[cell]["land_neighbors"]:
			if enemies.has(s.owner[q]):
				return cell
			for a in s.armies:
				if a["prov"] == q and enemies.has(a["owner"]):
					return cell
	return -1


static func _lines_daily(s: Simulation) -> void:
	for cid in s.x["more"]["lines"]:
		if not s.countries[cid]["alive"]:
			continue
		for l in s.x["more"]["lines"][cid]:
			var hot := _threatened(s, cid, l)
			var cell: int = hot if hot >= 0 else l["cells"][l["cells"].size() / 2]
			if hot >= 0 and not l["breach_logged"]:
				SimExt._report(s, cid, "угроза линии «%s»: клетка #%d" % [l["name"], hot])
				l["breach_logged"] = true
			elif hot < 0:
				l["breach_logged"] = false
			for slot in ["garrison", "reserve"]:
				var gid: int = int(l[slot])
				if gid < 0:
					continue
				var g := s.group_by_id(gid)
				if g.is_empty() or s.group_members(g).is_empty():
					l[slot] = -1
					continue
				if slot == "reserve" and hot < 0:
					continue   # the reserve waits until the line is threatened
				var target := cell
				if slot == "reserve" and hot >= 0:
					target = hot
				var at := true
				for a in s.group_members(g):
					at = at and a["prov"] == target
				if not at:
					SimExt._add_directive(s, cid, gid, target, "defend")
					if slot == "reserve":
						SimExt._report(s, cid, "резерв брошен к линии «%s»" % l["name"])


static func _chain_ok(s: Simulation, cells: Array) -> bool:
	for i in range(1, cells.size()):
		if not s.provinces()[cells[i - 1]]["land_neighbors"].has(cells[i]):
			return false
	return true


static func _draw_line(s: Simulation, cid: int, cmd: Dictionary) -> Dictionary:
	var nm := str(cmd.get("name", "")).strip_edges()
	if nm.is_empty() or nm.length() > 24:
		return s._fail("invalid name")
	var cells: Array = cmd.get("cells", [])
	if cells.size() < 2 or cells.size() > 12:
		return s._fail("invalid line")
	var seen := {}
	for p in cells:
		var cell := int(p)
		if cell < 0 or cell >= s.owner.size() or s.owner[cell] != cid or not s.provinces()[cell]["land"] or seen.has(cell):
			return s._fail("invalid line")
		seen[cell] = true
	var ints: Array = []
	for p in cells:
		ints.append(int(p))
	if not _chain_ok(s, ints):
		return s._fail("line not continuous")
	if lines_of(s, cid).size() >= MAX_LINES:
		return s._fail("too many lines")
	var c: Dictionary = s.countries[cid]
	var cost := ints.size() * 20
	if c["treasury"] < cost:
		return s._fail("not enough funds")
	c["treasury"] -= cost
	var mm: Dictionary = s.x["more"]
	var l := {"id": mm["next_id"], "name": nm, "cells": ints, "level": 1, "ready": s.day + 10, "garrison": -1, "reserve": -1, "breach_logged": false}
	mm["next_id"] = int(mm["next_id"]) + 1
	mm["lines"][cid].append(l)
	return {"ok": true, "line": l["id"]}


# ------------------------------------------------------------------ commands

static func command(s: Simulation, cid: int, type: String, cmd: Dictionary) -> Dictionary:
	var c: Dictionary = s.countries[cid]
	var mm: Dictionary = s.x["more"]
	match type:
		"set_policy":
			var bk: Dictionary = mm["bank"][cid]
			if s.day - int(bk["last_policy"]) < 30:
				return s._fail("on cooldown")
			bk["policy"] = clampi(int(cmd.get("level", 0)), -2, 2)
			bk["last_policy"] = s.day
			return {"ok": true}
		"bail_bank":
			for b in mm["bank"][cid]["banks"]:
				if b["id"] == int(cmd.get("bank", -1)):
					if int(b["failed_until"]) > s.day:
						return s._fail("bank failed")
					var price := int(b["loans"]) * 3 / 100 + 10
					if c["treasury"] < price:
						return s._fail("not enough funds")
					c["treasury"] -= price
					b["cap"] = int(b["cap"]) + price * 2
					b["bad"] = maxi(0, int(b["bad"]) - 4)
					b["state"] = true
					return {"ok": true}
			return s._fail("no such bank")
		"nationalize_corp", "privatize_corp", "subsidize_corp":
			for cp in mm["corp"][cid]:
				if cp["id"] != int(cmd.get("corp", -1)):
					continue
				var f: Dictionary = s.x["fin"][cid]
				if type == "nationalize_corp":
					if bool(cp["state"]):
						return s._fail("already state")
					if c["pp"] < 10:
						return s._fail("not enough influence")
					var price2 := int(cp["size"]) * 2
					if c["treasury"] < price2:
						return s._fail("not enough funds")
					c["treasury"] -= price2
					c["pp"] -= 10
					cp["state"] = true
					f["state"] = mini(100, int(f["state"]) + 3)
					if bool(cp["foreign"]):
						cp["foreign"] = false
						f["foreign"] = maxi(0, int(f["foreign"]) - 3)
						f["stock"] = maxi(200, int(f["stock"]) - 80)   # investors dislike expropriation
					return {"ok": true}
				if type == "privatize_corp":
					if not bool(cp["state"]):
						return s._fail("not state")
					c["treasury"] += int(cp["size"]) * 3 / 2
					cp["state"] = false
					f["state"] = maxi(0, int(f["state"]) - 3)
					return {"ok": true}
				if c["treasury"] < 40:
					return s._fail("not enough funds")
				c["treasury"] -= 40
				cp["size"] = mini(400, int(cp["size"]) + 10)
				return {"ok": true}
			return s._fail("no such corporation")
		"form_coalition":
			var pa: Dictionary = mm["parl"][cid]
			var gov: int = int(s.x["pol"][cid]["gov"])
			var ids: Array = []
			for p in cmd.get("parties", []):
				if not ids.has(int(p)):
					ids.append(int(p))
			if not ids.has(gov):
				ids.append(gov)
			if ids.size() > 4:
				return s._fail("too many parties")
			if c["pp"] < 10:
				return s._fail("not enough influence")
			for pid in ids:
				if not pa["seats"].has(pid):
					return s._fail("no such party")
				if pid != gov and party_distance(s, cid, gov, pid) > 2:
					return s._fail("partner refuses")
			c["pp"] -= 10
			pa["coalition"] = ids
			for pid in ids:
				if pid != gov and not pa["sat"].has(pid):
					pa["sat"][pid] = 55
			for pid in pa["sat"].keys():
				if not ids.has(pid):
					pa["sat"].erase(pid)
			pa["minority_since"] = -1 if coalition_seats(s, cid) >= 51 else s.day
			return {"ok": true, "seats": coalition_seats(s, cid)}
		"concede_partner":
			var pa2: Dictionary = mm["parl"][cid]
			var pid2: int = int(cmd.get("party", -1))
			if not pa2["coalition"].has(pid2) or pid2 == int(s.x["pol"][cid]["gov"]):
				return s._fail("not a partner")
			if c["pp"] < 10:
				return s._fail("not enough influence")
			c["pp"] -= 10
			pa2["sat"][pid2] = mini(100, int(pa2["sat"].get(pid2, 60)) + 25)
			return {"ok": true}
		"dissolve_parliament":
			var pa3: Dictionary = mm["parl"][cid]
			if str(c["ideology"]) != "democracy":
				return s._fail("not a democracy")
			if s.day - int(pa3["last_dissolve"]) < 365:
				return s._fail("on cooldown")
			if c["pp"] < 25:
				return s._fail("not enough influence")
			c["pp"] -= 25
			pa3["last_dissolve"] = s.day
			s.x["pol"][cid]["next_election"] = s.day + 2
			return {"ok": true}
		"join_org":
			var o := org(s, int(cmd.get("org", -1)))
			if o.is_empty():
				return s._fail("no such organization")
			if o["members"].has(cid):
				return s._fail("already a member")
			o["members"].append(cid)
			return {"ok": true}
		"leave_org":
			var o2 := org(s, int(cmd.get("org", -1)))
			if o2.is_empty() or not o2["members"].has(cid):
				return s._fail("not a member")
			o2["members"].erase(cid)
			return {"ok": true}
		"propose_resolution":
			return _propose_res(s, cid, cmd)
		"vote":
			var rid: int = int(cmd.get("res", -1))
			for oo in mm["orgs"]:
				for r in oo["res"]:
					if r["id"] == rid:
						if r["status"] != "open":
							return s._fail("voting closed")
						if not oo["members"].has(cid):
							return s._fail("not a member")
						r["votes"][cid] = bool(cmd.get("yes", true))
						return {"ok": true}
			return s._fail("no such resolution")
		"draw_line":
			return _draw_line(s, cid, cmd)
		"remove_line":
			var before: int = mm["lines"][cid].size()
			mm["lines"][cid] = mm["lines"][cid].filter(func(l): return l["id"] != int(cmd.get("line", -1)))
			return {"ok": true} if mm["lines"][cid].size() < before else s._fail("no such line")
		"fortify_line":
			var l := line_by_id(s, cid, int(cmd.get("line", -1)))
			if l.is_empty():
				return s._fail("no such line")
			if int(l["level"]) >= 3:
				return s._fail("already maximal")
			if int(l["ready"]) > s.day:
				return s._fail("already running")
			var cost: int = l["cells"].size() * 20 * (int(l["level"]) + 1)
			var steel: int = l["cells"].size() * 4 * (int(l["level"]) + 1)
			if c["treasury"] < cost:
				return s._fail("not enough funds")
			if c["stock"]["steel"] < steel:
				return s._fail("not enough steel")
			c["treasury"] -= cost
			c["stock"]["steel"] -= steel
			l["level"] = int(l["level"]) + 1
			l["ready"] = s.day + 10 * int(l["level"])
			return {"ok": true}
		"man_line", "set_reserve":
			var l2 := line_by_id(s, cid, int(cmd.get("line", -1)))
			if l2.is_empty():
				return s._fail("no such line")
			var gid: int = int(cmd.get("group", -1))
			var g := s.group_by_id(gid)
			if gid >= 0 and (g.is_empty() or g["owner"] != cid):
				return s._fail("no such group")
			var slot := "garrison" if type == "man_line" else "reserve"
			var other_slot := "reserve" if slot == "garrison" else "garrison"
			if gid >= 0 and int(l2[other_slot]) == gid:
				return s._fail("group already assigned")
			l2[slot] = gid
			return {"ok": true}
		"embark_wing":
			var w := s.wing_by_id(int(cmd.get("wing", -1)))
			var fl: Dictionary = {}
			for f2 in s.fleets:
				if f2["id"] == int(cmd.get("fleet", -1)):
					fl = f2
			if w.is_empty() or w["owner"] != cid:
				return s._fail("invalid wing")
			if fl.is_empty() or fl["owner"] != cid or str(fl.get("cls", "")) != "carrier":
				return s._fail("not a carrier")
			if w["type"] == "transport":
				return s._fail("wrong aircraft for mission")
			if embarked(s, int(fl["id"])) >= 2:
				return s._fail("carrier full")
			if not s.reach(w["base"], 3).has(fl["prov"]):
				return s._fail("out of range")
			w["carrier"] = fl["id"]
			w["mission"] = "idle"
			w["target"] = -1
			return {"ok": true}
		"disembark_wing":
			var w2 := s.wing_by_id(int(cmd.get("wing", -1)))
			if w2.is_empty() or w2["owner"] != cid or not w2.has("carrier"):
				return s._fail("invalid wing")
			w2.erase("carrier")
			w2["mission"] = "idle"
			w2["target"] = -1
			return {"ok": true}
	return s._fail("unknown command")


# ------------------------------------------------------------------ AI

static func ai(s: Simulation, cid: int) -> void:
	if not s.x.has("more"):
		return
	_ai_banking(s, cid)
	_ai_parliament(s, cid)
	_ai_orgs(s, cid)
	_ai_army_groups(s, cid)
	_ai_lines(s, cid)
	_ai_drone_units(s, cid)
	_ai_ships(s, cid)


static func _ai_banking(s: Simulation, cid: int) -> void:
	var c: Dictionary = s.countries[cid]
	var f: Dictionary = s.x["fin"][cid]
	if s.day % 30 == 0:
		var want := 0
		if int(f["infl"]) > 600:
			want = 1
		elif int(f["infl"]) < 150 and int(s.x["soc"][cid]["unemp"]) > 8:
			want = -1
		command(s, cid, "set_policy", {"level": want})
	for b in s.x["more"]["bank"][cid]["banks"]:
		if int(b["failed_until"]) <= s.day and bank_ratio(b) < 6 and c["treasury"] > int(b["loans"]) * 3 / 100 + 60:
			command(s, cid, "bail_bank", {"bank": b["id"]})


static func _ai_parliament(s: Simulation, cid: int) -> void:
	if s.day % 30 != 5:
		return
	var pa: Dictionary = s.x["more"]["parl"][cid]
	var gov: int = int(s.x["pol"][cid]["gov"])
	for pid in pa["coalition"]:
		if pid != gov and int(pa["sat"].get(pid, 60)) < 30 and s.countries[cid]["pp"] >= 30:
			command(s, cid, "concede_partner", {"party": pid})
			break
	if coalition_seats(s, cid) < 51:
		var members: Array = pa["coalition"].duplicate()
		var best := -1
		for pid in pa["seats"]:
			if not members.has(pid) and party_distance(s, cid, gov, pid) <= 2 and (best < 0 or pa["seats"][pid] > pa["seats"][best]):
				best = pid
		if best >= 0 and members.size() < 4:
			members.append(best)
			command(s, cid, "form_coalition", {"parties": members})


static func _ai_orgs(s: Simulation, cid: int) -> void:
	if s.day % 30 != (cid % 6) * 5:
		return
	var c: Dictionary = s.countries[cid]
	if c["pp"] < 20:
		return
	var peace := org(s, 2)
	for en in s.enemies_of(cid):
		if peace["members"].has(cid) and peace["members"].has(en):
			var r := command(s, cid, "propose_resolution", {"org": 2, "kind": "peace", "target": cid, "other": en})
			if r.get("ok", false):
				return
	# aid for a friend in trouble, free trade with pact partners, condemnation of a hostile country
	var circle: Array = s.neighbor_countries(cid).duplicate()   # only neighbours, allies and enemies matter (a full scan of 200 countries was the AI's top cost)
	for al in s.allies_of(cid):
		if not circle.has(al):
			circle.append(al)
	for en in s.enemies_of(cid):
		if not circle.has(en):
			circle.append(en)
	for oid in circle:
		var o: Dictionary = s.countries[oid]
		if o["alive"] and oid != cid and int(o["stability"]) < 40 and (s.allied(cid, oid) or SimExt.relation(s, cid, oid) >= 15) and c["treasury"] >= 100:
			if command(s, cid, "propose_resolution", {"org": 0, "kind": "aid", "target": oid}).get("ok", false):
				return
	for p in s.x["dip"]["pacts"]:
		if p["kind"] == "trade_pact" and (p["a"] == cid or p["b"] == cid) and org(s, 1)["members"].has(cid):
			if command(s, cid, "propose_resolution", {"org": 1, "kind": "tariff_free", "target": p["b"] if p["a"] == cid else p["a"]}).get("ok", false):
				return
	var worst := -1
	var worst_rel := -15
	for oid2 in circle:
		if s.countries[oid2]["alive"] and oid2 != cid:
			var rl := SimExt.relation(s, cid, oid2)
			if rl < worst_rel:
				worst = oid2
				worst_rel = rl
	if worst >= 0:
		command(s, cid, "propose_resolution", {"org": 0, "kind": "condemn", "target": worst})


## The AI forms army groups out of armies standing together (a group needs two armies) and lets the staff command them.
static func _ai_army_groups(s: Simulation, cid: int) -> void:
	if s.day % 10 != 5:
		return
	var grouped := {}
	for g in s.groups:
		if g["owner"] == cid:
			for aid in g["armies"]:
				grouped[aid] = true
	var free: Array = []
	for a in s.armies_of(cid):
		if not grouped.has(a["id"]):
			free.append(a)
	free.sort_custom(func(x, y): return x["prov"] < y["prov"] or (x["prov"] == y["prov"] and x["id"] < y["id"]))
	var taken := {}
	for a in free:
		if taken.has(a["id"]):
			continue
		var ids: Array = [a["id"]]
		for b in free:
			if ids.size() >= 4:
				break
			if b["id"] == a["id"] or taken.has(b["id"]):
				continue
			if b["prov"] == a["prov"] or s.provinces()[a["prov"]]["land_neighbors"].has(b["prov"]):
				ids.append(b["id"])
		if ids.size() >= 2:
			var n: int = s.groups.filter(func(g): return g["owner"] == cid).size() + 1
			var r := s.apply_command({"type": "create_group", "country": cid, "name": "Группа %d" % n, "armies": ids})
			if r.get("ok", false):
				for i in ids:
					taken[i] = true
	s.x["staff"][cid]["auto"] = true


## At war the AI draws a line along its border cells that touch the enemy, garrisons it with one group and keeps another in reserve.
static func _ai_lines(s: Simulation, cid: int) -> void:
	if s.day % 20 != 5:
		return
	var enemies := s.enemies_of(cid)
	if enemies.is_empty() or lines_of(s, cid).size() >= 2:
		return
	var frontier: Array = []
	for p in s.cells_of(cid):
		for q in s.provinces()[p]["land_neighbors"]:
			if enemies.has(s.owner[q]):
				frontier.append(p)
				break
	if frontier.size() < 2:
		return
	frontier.sort()
	# a chain of adjacent frontier cells starting from the first one
	var chain: Array = [frontier[0]]
	var used := {frontier[0]: true}
	var grew := true
	while grew and chain.size() < 6:
		grew = false
		for q in s.provinces()[chain[chain.size() - 1]]["land_neighbors"]:
			if frontier.has(q) and not used.has(q):
				chain.append(q)
				used[q] = true
				grew = true
				break
	if chain.size() < 2:
		return
	var r := command(s, cid, "draw_line", {"name": "Рубеж %d" % (lines_of(s, cid).size() + 1), "cells": chain})
	if not r.get("ok", false):
		return
	var groups := s.groups_of(cid)
	var line_id: int = r["line"]
	if groups.size() >= 1:
		command(s, cid, "man_line", {"line": line_id, "group": groups[0]["id"]})
	if groups.size() >= 2:
		command(s, cid, "set_reserve", {"line": line_id, "group": groups[1]["id"]})
	command(s, cid, "fortify_line", {"line": line_id})


static func _ai_drone_units(s: Simulation, cid: int) -> void:
	if not s.rule_templates or s.day % 40 != 15:
		return
	var c: Dictionary = s.countries[cid]
	if not (c["techs"].has("drn1") and c["techs"].has("fpv1")):
		return
	var key := ""
	for t in s.templates.get(cid, []):
		if t["name"] == "Ударно-дроновая":
			key = s.template_key(cid, t["id"])
	if key == "":
		var bn: Array = ["inf", "inf", "art", "drone", "fpv"]
		if c["techs"].has("ew1"):
			bn.append("ew")
		s._create_template(cid, "Ударно-дроновая", bn)
	elif c["treasury"] > 300:
		s._train(cid, key)


static func _ai_ships(s: Simulation, cid: int) -> void:
	if s.day % 45 != 10 or s.port_of(cid) < 0 or s.countries[cid]["treasury"] < 500:
		return
	var have := {}
	for f in s.fleets_of(cid):
		have[str(f.get("cls", ""))] = int(have.get(str(f.get("cls", "")), 0)) + 1
	var pick := "destroyer"
	if int(have.get("destroyer", 0)) >= 1 and int(have.get("submarine", 0)) == 0 and not s.enemies_of(cid).is_empty():
		pick = "submarine"
	elif int(have.get("destroyer", 0)) >= 2 and int(have.get("carrier", 0)) == 0 and s.countries[cid]["treasury"] > 1500:
		pick = "carrier"
	s.apply_command({"type": "build_ship", "country": cid, "cls": pick})


# ------------------------------------------------------------------ player panel rows

static func panel(s: Simulation, cid: int) -> Array:
	var rows: Array = []
	var mm: Dictionary = s.x["more"]
	var c: Dictionary = s.countries[cid]
	var bk: Dictionary = mm["bank"][cid]
	rows.append({"t": "h", "text": "Банки и корпорации"})
	rows.append({"t": "step", "text": "Ключевая ставка (политика ЦБ)", "value": str(bk["policy"]), "minus": SimExt._cmd(cid, "set_policy", {"level": int(bk["policy"]) - 1}), "plus": SimExt._cmd(cid, "set_policy", {"level": int(bk["policy"]) + 1})})
	for b in bk["banks"]:
		var st := "обанкротился" if int(b["failed_until"]) > s.day else "капитал %d%%, плохие кредиты %d%%" % [bank_ratio(b), b["bad"]]
		rows.append({"t": "kv", "k": "%s%s" % [b["name"], " (гос.)" if b["state"] else ""], "v": "%s, кредиты %d" % [st, b["loans"]]})
		if int(b["failed_until"]) <= s.day and bank_ratio(b) < 10:
			rows.append({"t": "btn", "text": "Спасти банк «%s» (%d)" % [b["name"], int(b["loans"]) * 3 / 100 + 10], "cmd": SimExt._cmd(cid, "bail_bank", {"bank": b["id"]})})
	for cp in mm["corp"][cid]:
		rows.append({"t": "kv", "k": "%s%s%s" % [cp["name"], " (гос.)" if cp["state"] else "", " (иностр.)" if cp["foreign"] else ""], "v": "размер %d, прибыль %d%%" % [cp["size"], cp["profit"]]})
		if cp["state"]:
			rows.append({"t": "btn", "text": "Приватизировать «%s»" % cp["name"], "cmd": SimExt._cmd(cid, "privatize_corp", {"corp": cp["id"]})})
		else:
			rows.append({"t": "btn", "text": "Национализировать «%s» (%d, 10 влияния)" % [cp["name"], int(cp["size"]) * 2], "cmd": SimExt._cmd(cid, "nationalize_corp", {"corp": cp["id"]})})
		rows.append({"t": "btn", "text": "Субсидия «%s» (40)" % cp["name"], "cmd": SimExt._cmd(cid, "subsidize_corp", {"corp": cp["id"]})})
	var pa: Dictionary = mm["parl"][cid]
	rows.append({"t": "h", "text": "Парламент и коалиция"})
	var seat_list: Array[String] = []
	for p in s.x["pol"][cid]["parties"]:
		var n := seats_of(s, cid, p["id"])
		if n > 0:
			seat_list.append("%s %d" % [p["name"], n])
	rows.append({"t": "kv", "k": "Места (из 100)", "v": ", ".join(seat_list)})
	rows.append({"t": "kv", "k": "Коалиция", "v": "%d мест — %s" % [coalition_seats(s, cid), "большинство" if coalition_seats(s, cid) >= 51 else "правительство меньшинства"]})
	for pid in pa["coalition"]:
		if pid != int(s.x["pol"][cid]["gov"]):
			rows.append({"t": "btn", "text": "Уступка партнёру «%s» (довольство %d, 10 влияния)" % [_party_name(s, cid, pid), pa["sat"].get(pid, 60)], "cmd": SimExt._cmd(cid, "concede_partner", {"party": pid})})
	if str(c["ideology"]) == "democracy":
		rows.append({"t": "btn", "text": "Распустить парламент (25 влияния)", "cmd": SimExt._cmd(cid, "dissolve_parliament", {})})
	rows.append({"t": "h", "text": "Международные организации"})
	for o in mm["orgs"]:
		var mem: bool = o["members"].has(cid)
		rows.append({"t": "kv", "k": o["name"], "v": "%d стран%s" % [o["members"].size(), ", вы участник" if mem else ""]})
		rows.append({"t": "btn", "text": ("Выйти из «%s»" if mem else "Вступить в «%s»") % o["name"], "cmd": SimExt._cmd(cid, "leave_org" if mem else "join_org", {"org": o["id"]})})
		for r in o["res"]:
			if r["status"] == "open":
				var t := tally(s, o, r)
				rows.append({"t": "kv", "k": "Резолюция: %s против %s" % [r["kind"], s.countries[r["target"]]["name"] if r["target"] >= 0 else "—"], "v": "за %d / против %d, до дня %d" % [t["yes"], t["no"], r["deadline"]]})
				if mem and not r["votes"].has(cid):
					rows.append({"t": "btn", "text": "Голосовать ЗА (резолюция #%d)" % r["id"], "cmd": SimExt._cmd(cid, "vote", {"res": r["id"], "yes": true})})
					rows.append({"t": "btn", "text": "Голосовать ПРОТИВ (резолюция #%d)" % r["id"], "cmd": SimExt._cmd(cid, "vote", {"res": r["id"], "yes": false})})
	for en in s.enemies_of(cid):
		if org(s, 2)["members"].has(cid) and org(s, 2)["members"].has(en):
			rows.append({"t": "btn", "text": "Мир в Миротворческом совете: %s (15 влияния)" % s.countries[en]["name"], "cmd": SimExt._cmd(cid, "propose_resolution", {"org": 2, "kind": "peace", "target": cid, "other": en})})
	rows.append({"t": "h", "text": "Линии обороны"})
	for l in lines_of(s, cid):
		rows.append({"t": "kv", "k": "Рубеж «%s»" % l["name"], "v": "%d клеток, уровень %d%s, гарнизон %s, резерв %s" % [l["cells"].size(), l["level"], "" if int(l["ready"]) <= s.day else " (строится до дня %d)" % l["ready"], ("группа #%d" % l["garrison"]) if int(l["garrison"]) >= 0 else "нет", ("группа #%d" % l["reserve"]) if int(l["reserve"]) >= 0 else "нет"]})
		rows.append({"t": "btn", "text": "Укрепить «%s»" % l["name"], "cmd": SimExt._cmd(cid, "fortify_line", {"line": l["id"]})})
		var gs := s.groups_of(cid)
		if gs.size() >= 1:
			rows.append({"t": "btn", "text": "Гарнизон «%s»: %s" % [l["name"], gs[0]["name"]], "cmd": SimExt._cmd(cid, "man_line", {"line": l["id"], "group": gs[0]["id"]})})
		if gs.size() >= 2:
			rows.append({"t": "btn", "text": "Резерв «%s»: %s" % [l["name"], gs[1]["name"]], "cmd": SimExt._cmd(cid, "set_reserve", {"line": l["id"], "group": gs[1]["id"]})})
		rows.append({"t": "btn", "text": "Снять рубеж «%s»" % l["name"], "cmd": SimExt._cmd(cid, "remove_line", {"line": l["id"]})})
	rows.append({"t": "kv", "k": "Подсказка", "v": "рубеж задаётся командой draw_line по цепочке соседних клеток (ИИ строит их сам вдоль фронта)"})
	rows.append({"t": "h", "text": "Флот: роли кораблей"})
	var fl_n := 0
	for f in s.fleets_of(cid):
		fl_n += 1
		var cls := str(f.get("cls", ""))
		rows.append({"t": "kv", "k": "Соединение #%d" % f["id"], "v": "%s, прочность %d%s" % [cls if cls != "" else "стандартное", f["strength"], (", авиагрупп: %d" % embarked(s, int(f["id"]))) if cls == "carrier" else ""]})
	if fl_n == 0:
		rows.append({"t": "kv", "k": "Флот", "v": "нет кораблей"})
	for cl in Simulation.SHIP_CLASSES:
		var d: Dictionary = Simulation.SHIP_CLASSES[cl]
		rows.append({"t": "btn", "text": "Построить: %s (%d $, %d стали)" % [d["name"], d["cost"], d["steel"]], "cmd": SimExt._cmd(cid, "build_ship", {"cls": cl})})
	return rows
