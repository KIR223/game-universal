#!/usr/bin/env python3
"""Validates game data files. Run: python3 tools/validate_data.py"""
import json, re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
errors = []

data = json.loads((root / "data/countries.json").read_text(encoding="utf-8"))
if data.get("schema_version") != 1:
    errors.append("countries.json: unsupported schema_version")
tags = set()
for c in data["countries"]:
    for k in ("tag", "name", "color"):
        if k not in c:
            errors.append(f"country {c}: missing {k}")
    if c.get("tag") in tags:
        errors.append(f"duplicate tag {c.get('tag')}")
    tags.add(c.get("tag"))
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", c.get("color", "")):
        errors.append(f"{c.get('tag')}: bad color")

res = json.loads((root / "data/resources.json").read_text(encoding="utf-8"))
ids = set()
for r in res["resources"]:
    for k in ("id", "name", "price", "color"):
        if k not in r:
            errors.append(f"resource {r}: missing {k}")
    if r.get("id") in ids:
        errors.append(f"duplicate resource {r.get('id')}")
    ids.add(r.get("id"))
    if not isinstance(r.get("price"), int) or r["price"] < 1:
        errors.append(f"{r.get('id')}: bad price")
for need in ("food", "oil", "steel", "iron", "coal"):
    if need not in ids:
        errors.append(f"missing required resource {need}")

units = json.loads((root / "data/units.json").read_text(encoding="utf-8"))
terrains = {"plains", "forest", "hills", "mountain", "desert"}
for u in units["units"]:
    for k in ("id", "name", "cost", "steel", "manpower", "hp", "atk", "def", "oil", "terrain"):
        if k not in u:
            errors.append(f"unit {u.get('id')}: missing {k}")
    if set(u.get("terrain", {})) != terrains:
        errors.append(f"unit {u.get('id')}: terrain table must cover {sorted(terrains)}")
if "infantry" not in {u["id"] for u in units["units"]}:
    errors.append("units.json must define infantry")
gen = json.loads((root / "data/generals.json").read_text(encoding="utf-8"))
if not gen.get("first") or not gen.get("last"):
    errors.append("generals.json: need first and last name lists")

techs = json.loads((root / "data/techs.json").read_text(encoding="utf-8"))
cats = {c["id"] for c in techs["categories"]}
EFFECTS = {"income_pct", "upkeep_pct", "food_pct", "coal_pct", "iron_pct", "oil_pct", "steel_pct", "manpower_pct",
           "atk_pct", "def_pct", "atk_infantry_pct", "atk_armor_pct", "atk_artillery_pct", "def_infantry_pct",
           "def_armor_pct", "def_artillery_pct", "fleet_pct", "supply_pct", "supply_decay_pct", "attrition_pct",
           "research_pct", "research_slots", "air_fighter_pct", "air_bomber_pct", "air_attacker_pct", "air_range"}
tmap = {}
for t in techs["techs"]:
    if t["id"] in tmap:
        errors.append(f"duplicate tech {t['id']}")
    tmap[t["id"]] = t
    if t["category"] not in cats:
        errors.append(f"{t['id']}: unknown category {t['category']}")
    if not isinstance(t["cost"], int) or t["cost"] <= 0:
        errors.append(f"{t['id']}: bad cost")
    for k in t["effects"]:
        if k not in EFFECTS:
            errors.append(f"{t['id']}: unknown effect {k}")
for t in techs["techs"]:
    for r in t["requires"]:
        if r not in tmap:
            errors.append(f"{t['id']}: missing prerequisite {r}")
# cycle check
state = {}
def visit(i):
    if state.get(i) == 1:
        errors.append(f"tech cycle at {i}"); return
    if state.get(i) == 2:
        return
    state[i] = 1
    for r in tmap[i]["requires"]:
        if r in tmap:
            visit(r)
    state[i] = 2
for i in tmap:
    visit(i)

air = json.loads((root / "data/aircraft.json").read_text(encoding="utf-8"))
air_ids = set()
for a in air["aircraft"]:
    for k in ("id", "name", "cost", "steel", "manpower", "range"):
        if k not in a:
            errors.append(f"aircraft {a.get('id')}: missing {k}")
    air_ids.add(a.get("id"))
for need in ("fighter", "bomber", "attacker"):
    if need not in air_ids:
        errors.append(f"aircraft.json must define {need}")

pol = json.loads((root / "data/politics.json").read_text(encoding="utf-8"))
ideo_ids = {i["id"] for i in pol["ideologies"]}
for i in pol["ideologies"]:
    for k in ("id", "name", "color", "stability_base", "mods", "elections"):
        if k not in i:
            errors.append(f"ideology {i.get('id')}: missing {k}")
    for k in i.get("mods", {}):
        if k not in EFFECTS:
            errors.append(f"ideology {i['id']}: unknown mod {k}")
for cat, ld in pol["laws"].items():
    oids = {o["id"] for o in ld["options"]}
    if pol["defaults"].get(cat) not in oids:
        errors.append(f"law {cat}: default missing")
    for o in ld["options"]:
        for k in o.get("mods", {}):
            if k not in EFFECTS:
                errors.append(f"law {cat}/{o['id']}: unknown mod {k}")
EFFECT_TYPES = {"stability", "war_support", "treasury", "treasury_pct", "stock", "manpower", "pp", "popularity",
                "popularity_ruling", "modifier", "tech_progress", "army_exp"}
COND_TYPES = {"min_day", "stability_below", "stability_above", "war_support_below", "war_support_above", "at_war",
              "not_at_war", "ideology", "not_ideology", "has_tech", "treasury_above", "treasury_below", "short", "provinces_min"}
def check_effects(owner_id, effects):
    for ef in effects:
        if ef["type"] not in EFFECT_TYPES:
            errors.append(f"{owner_id}: unknown effect type {ef['type']}")
        if ef["type"] == "popularity" and ef.get("ideology") not in ideo_ids:
            errors.append(f"{owner_id}: bad ideology {ef.get('ideology')}")
        if ef["type"] == "stock" and ef.get("res") not in ids:
            errors.append(f"{owner_id}: bad resource {ef.get('res')}")
        if ef["type"] == "modifier" and (ef.get("key") not in EFFECTS or "days" not in ef):
            errors.append(f"{owner_id}: bad modifier")
def check_conds(owner_id, conds):
    for cd in conds:
        if cd["type"] not in COND_TYPES:
            errors.append(f"{owner_id}: unknown condition {cd['type']}")
        if cd["type"] in ("ideology", "not_ideology") and cd.get("value") not in ideo_ids:
            errors.append(f"{owner_id}: bad ideology in condition")
        if cd["type"] == "has_tech" and cd.get("value") not in tmap:
            errors.append(f"{owner_id}: bad tech in condition")
        if cd["type"] == "short" and cd.get("value") not in ids:
            errors.append(f"{owner_id}: bad resource in condition")
evs = json.loads((root / "data/events.json").read_text(encoding="utf-8"))["events"]
eids = set()
for e in evs:
    if e["id"] in eids:
        errors.append(f"duplicate event {e['id']}")
    eids.add(e["id"])
    if not e["options"]:
        errors.append(f"event {e['id']}: no options")
    check_conds("event " + e["id"], e["conditions"])
    for o in e["options"]:
        check_effects("event " + e["id"], o["effects"])
decs = json.loads((root / "data/decisions.json").read_text(encoding="utf-8"))["decisions"]
dids = set()
for d in decs:
    if d["id"] in dids:
        errors.append(f"duplicate decision {d['id']}")
    dids.add(d["id"])
    check_conds("decision " + d["id"], d["requires"] + d["ai_conditions"])
    check_effects("decision " + d["id"], d["effects"])

if errors:
    print("\n".join(errors)); sys.exit(1)
print(f"data OK ({len(tags)} countries, {len(ids)} resources, {len(units['units'])} units, {len(tmap)} techs, {len(evs)} events, {len(decs)} decisions)")
