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

if errors:
    print("\n".join(errors)); sys.exit(1)
print(f"data OK ({len(tags)} countries, {len(ids)} resources)")
