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

if errors:
    print("\n".join(errors)); sys.exit(1)
print(f"data OK ({len(tags)} countries, {len(ids)} resources, {len(units['units'])} units, {len(tmap)} techs)")
