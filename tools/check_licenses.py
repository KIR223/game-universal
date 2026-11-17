#!/usr/bin/env python3
"""Fails if binary assets exist under game/assets that are not mentioned in ASSET_LICENSES.md."""
import pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
licenses = (root / "ASSET_LICENSES.md").read_text(encoding="utf-8")
missing = [str(p.relative_to(root)) for p in (root / "game/assets").rglob("*")
           if p.is_file() and p.name != ".gitkeep" and not p.name.endswith((".import", ".uid")) and p.name not in licenses]   # .import/.uid are derived by the engine
if missing:
    print("Assets without license entry:\n  " + "\n  ".join(missing)); sys.exit(1)
print("asset licenses OK")
