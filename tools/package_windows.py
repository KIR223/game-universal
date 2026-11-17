#!/usr/bin/env python3
"""Packs an exported Windows build into a release folder + ZIP with README, version info and licenses.

    python3 tools/package_windows.py --exe build/windows/IronDominion.exe --out build/release [--godot 4.7.2]

Output: <out>/IronDominion-<version>/ (IronDominion.exe, README_WINDOWS.txt, VERSION.txt, LICENSES/) and
        <out>/IRON-DOMINION-WINDOWS-X64-<version>.zip. Also refuses an EXE that is obviously incomplete
        (the real-world dataset data/world must be inside; without it the EXE is ~104 MB instead of ~116 MB).
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MIN_EXE_BYTES = 110 * 1024 * 1024   # template alone is ~100 MB; with data/world ~116 MB


def preset_version() -> str:
    text = (ROOT / "export_presets.cfg").read_text(encoding="utf-8")
    m = re.search(r'application/product_version="([0-9.]+)"', text)
    v = m.group(1) if m else "0.0.0.0"
    return ".".join(v.split(".")[:3])   # 0.1.0.0 (Windows file version) -> 0.1.0


def git_info() -> tuple[str, str]:
    sha = os.environ.get("GITHUB_SHA", "")
    ref = os.environ.get("GITHUB_REF_NAME", "")
    try:
        if not sha:
            sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
        if not ref:
            ref = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        pass
    return sha or "unknown", ref or "unknown"


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--godot", default="4.7.2")
    args = ap.parse_args()
    exe = pathlib.Path(args.exe)
    if not exe.is_file():
        print(f"EXE not found: {exe}")
        return 1
    if exe.stat().st_size < MIN_EXE_BYTES:
        print(f"EXE is only {exe.stat().st_size / 1048576:.1f} MB: the world dataset is probably missing (export filter!)")
        return 1
    version = preset_version()
    sha, ref = git_info()
    manifest = json.loads((ROOT / "data/world/manifest.json").read_text(encoding="utf-8"))
    world_hash = manifest.get("world_hash", "unknown")
    out = pathlib.Path(args.out)
    folder = out / f"IronDominion-{version}"
    if folder.exists():
        shutil.rmtree(folder)
    (folder / "LICENSES").mkdir(parents=True)
    shutil.copy2(exe, folder / "IronDominion.exe")
    shutil.copy2(ROOT / "platform/windows/README_WINDOWS.txt", folder / "README_WINDOWS.txt")
    shutil.copy2(ROOT / "platform/windows/THIRD_PARTY_NOTICES.txt", folder / "LICENSES/THIRD_PARTY_NOTICES.txt")
    shutil.copy2(ROOT / "ASSET_LICENSES.md", folder / "LICENSES/ASSET_LICENSES.md")
    shutil.copy2(ROOT / "docs/DATA_SOURCES.md", folder / "LICENSES/DATA_SOURCES.md")
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    (folder / "VERSION.txt").write_text(
        "Iron Dominion\n"
        f"Version:        {version}\n"
        f"Platform:       Windows x64 (release export)\n"
        f"Engine:         Godot {args.godot} (Vulkan, Forward Mobile)\n"
        f"Commit:         {sha}\n"
        f"Branch/tag:     {ref}\n"
        f"Built:          {now}\n"
        f"World data:     world_hash {world_hash}\n"
        f"EXE size:       {exe.stat().st_size} bytes\n"
        f"EXE SHA-256:    {sha256(folder / 'IronDominion.exe')}\n"
        "Save format:    shared with macOS/Android (versioned; see docs/ARCHITECTURE.md)\n", encoding="utf-8")
    zip_path = out / f"IRON-DOMINION-WINDOWS-X64-{version}.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for p in sorted(folder.rglob("*")):
            if p.is_file():
                z.write(p, f"{folder.name}/{p.relative_to(folder).as_posix()}")
    print(f"packaged {folder} -> {zip_path} ({zip_path.stat().st_size / 1048576:.1f} MB), version {version}, commit {sha[:8]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
