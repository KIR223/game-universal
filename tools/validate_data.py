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

if errors:
    print("\n".join(errors)); sys.exit(1)
print(f"data OK ({len(tags)} countries)")
