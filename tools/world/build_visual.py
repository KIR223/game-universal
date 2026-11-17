#!/usr/bin/env python3
"""Build the visual layer of the world (data/world_visual) — independent of the simulation dataset.

Usage:
    python3 tools/world/build_visual.py --raw RAW_DIR --world data/world --out data/world_visual

Inputs (RAW_DIR): ne/ne_10m_land.geojson, ne/ne_10m_lakes.geojson, ne/ne_10m_glaciated_areas.geojson (unused for the mask, kept for extras),
ne2/NE2_50M_SR_W.zip (Natural Earth II, shaded relief + water, public domain), ne/ne_10m_* border/river layers.
Outputs:
    tiles/t_<col>_<row>.bin   RGBA: Natural Earth II imagery + land mask in alpha, 0.05 deg/px, 8x4 tiles of 900x720 px (lat 84..-60)
    overview.bin              1800x720 RGBA (always resident while zoomed out)
    ext_<world>.bin           RG8 (16-bit) cell ids of the SIMULATION raster with land ids dilated into coastal water (for colouring/picking)
    land_fraction.bin         uint8 land fraction (0..255) per simulation-raster pixel (to tell coastal land from coastal sea when picking)
    vectors.json.z            fine coast, lake outlines, rivers and borders
    manifest.json             sources, hashes
The visual layer never feeds the simulation: changing it does not change world_hash or any game rule.
"""
import argparse, hashlib, io, json, math, os, sys, time, zipfile, zlib
import numpy as np
from PIL import Image, ImageDraw
from shapely.geometry import LineString

Image.MAX_IMAGE_PIXELS = None
FINE = 0.05                      # degrees per imagery pixel
LAT_TOP, LAT_BOT = 84.0, -60.0
FW = int(round(360 / FINE))      # 7200
FH = int(round((LAT_TOP - LAT_BOT) / FINE))   # 2880
TILE_W, TILE_H = 900, 720
T0 = time.time()


def log(*a):
    print("[%6.1fs]" % (time.time() - T0), *a, flush=True)


def load(raw, name):
    with open(os.path.join(raw, "ne", name + ".geojson"), encoding="utf-8") as f:
        return json.load(f)["features"]


def rings_of(geom):
    out = []
    if geom is None:
        return out
    polys = [geom["coordinates"]] if geom["type"] == "Polygon" else geom["coordinates"] if geom["type"] == "MultiPolygon" else []
    for poly in polys:
        out.append(poly)
    return out


def land_mask(raw, ss=2):
    """Supersampled land mask from ne_10m_land minus lakes; returns uint8 FWxFH (0/255, anti-aliased)."""
    W, H = FW * ss, FH * ss
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    def px(ring):
        return [((x + 180.0) / FINE * ss, (LAT_TOP - y) / FINE * ss) for x, y in ring]
    for f in load(raw, "ne_10m_land"):
        for poly in rings_of(f["geometry"]):
            d.polygon(px(poly[0]), fill=255)
            for hole in poly[1:]:
                d.polygon(px(hole), fill=0)
    for f in load(raw, "ne_10m_minor_islands"):
        for poly in rings_of(f["geometry"]):
            d.polygon(px(poly[0]), fill=255)
    lakes = load(raw, "ne_10m_lakes")
    for f in lakes:
        for poly in rings_of(f["geometry"]):
            d.polygon(px(poly[0]), fill=0)
            for hole in poly[1:]:
                d.polygon(px(hole), fill=255)
    return np.array(img.resize((FW, FH), Image.BOX), dtype=np.uint8)


def imagery(raw):
    zpath = os.path.join(raw, "ne2", "NE2_50M_SR_W.zip")
    with zipfile.ZipFile(zpath) as z:
        name = [n for n in z.namelist() if n.lower().endswith((".tif", ".tiff"))][0]
        data = z.read(name)
    im = Image.open(io.BytesIO(data)).convert("RGB")
    w, h = im.size
    top = int(round((90.0 - LAT_TOP) / 180.0 * h))
    bot = int(round((90.0 - LAT_BOT) / 180.0 * h))
    im = im.crop((0, top, w, bot)).resize((FW, FH), Image.LANCZOS)
    return np.array(im, dtype=np.uint8)


def read_z_int32(path, shape):
    return np.frombuffer(zlib.decompress(open(path, "rb").read()), dtype="<i4").reshape(shape)


def dilate_ids(cells, n_land, iterations=2):
    """Grow land cell ids into adjacent water so every coastal land pixel of the fine mask has a land id."""
    out = cells.copy()
    H, W = out.shape
    for _ in range(iterations):
        is_water = (out < 0) | (out >= n_land)
        best = np.full(out.shape, -1, dtype=np.int32)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            sh = np.roll(np.roll(out, dy, axis=0), dx, axis=1)
            if dy == 1:
                sh[0, :] = -1
            if dy == -1:
                sh[-1, :] = -1
            ok = (sh >= 0) & (sh < n_land) & is_water & (best < 0)
            best[ok] = sh[ok]
        out = np.where(best >= 0, best, out)
    return out


def simplify_rings(feats, tol, kind="ring"):
    res = []
    for f in feats:
        for poly in rings_of(f["geometry"]):
            for ri, ring in enumerate(poly[:1] if kind == "ring" else poly):
                ls = LineString(ring).simplify(tol, preserve_topology=False)
                if len(ls.coords) >= 3:
                    res.append([(round(x, 4), round(y, 4)) for x, y in ls.coords])
    return res


def write_ext(a, mask):
    # extended ids + land fraction for the simulation raster
    man = json.load(open(os.path.join(a.world, "manifest.json"), encoding="utf-8"))
    cm = json.loads(zlib.decompress(open(os.path.join(a.world, "cells.json.z"), "rb").read()))
    Wc, Hc = man["raster"]["w"], man["raster"]["h"]
    cells = read_z_int32(os.path.join(a.world, "raster_cells.bin"), (Hc, Wc))
    ext = dilate_ids(cells, cm["n_land"], 2)
    zdir = os.path.basename(os.path.normpath(a.world))
    ids16 = np.where(ext >= 0, ext, 65535).astype(np.uint16)
    rg = np.stack([(ids16 & 255).astype(np.uint8), (ids16 >> 8).astype(np.uint8)], axis=2)
    with open(os.path.join(a.out, "ext_%s.bin" % zdir), "wb") as fh:   # RG8 little-endian 16-bit ids (65535 = none), same layout as raster_ids.bin
        fh.write(zlib.compress(rg.tobytes(), 9))
    # land fraction per simulation pixel (visual mask is on the same lat range)
    fy, fx = FH // Hc, FW // Wc
    frac = mask.reshape(Hc, fy, Wc, fx).mean(axis=(1, 3)).astype(np.uint8)
    with open(os.path.join(a.out, "land_fraction_%s.bin" % zdir), "wb") as fh:
        fh.write(zlib.compress(frac.tobytes(), 9))
    log("extended ids + land fraction done")


def write_manifest(a):
    zdir = os.path.basename(os.path.normpath(a.world))
    man = json.load(open(os.path.join(a.world, "manifest.json"), encoding="utf-8"))
    mpath = os.path.join(a.out, "manifest.json")
    old = json.load(open(mpath, encoding="utf-8")) if os.path.exists(mpath) else {}
    files = {}
    h = hashlib.sha256()
    for root_, _, names in os.walk(a.out):
        for n in sorted(names):
            if n == "manifest.json":
                continue
            p = os.path.join(root_, n)
            rel = os.path.relpath(p, a.out).replace(os.sep, "/")
            data = open(p, "rb").read()
            files[rel] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    for rel in sorted(files):
        h.update(rel.encode() + files[rel]["sha256"].encode())
    linked = dict(old.get("linked_worlds", {}))
    if not linked and "linked_world" in old:
        linked[old["linked_world"]["dir"]] = old["linked_world"]["world_hash"]
    linked[zdir] = man["world_hash"]
    manifest = {
        "visual_version": 1, "built": time.strftime("%Y-%m-%d"),
        "imagery": {"px_deg": FINE, "w": FW, "h": FH, "tile_w": TILE_W, "tile_h": TILE_H, "lat_top": LAT_TOP, "lat_bottom": LAT_BOT},
        "linked_world": {"dir": zdir, "world_hash": man["world_hash"]}, "linked_worlds": linked,
        "sources": ["Natural Earth II 50m shaded relief + water (public domain)", "Natural Earth 10m land, lakes, rivers, admin (public domain)"],
        "visual_hash": h.hexdigest(), "files": files,
    }
    json.dump(manifest, open(os.path.join(a.out, "manifest.json"), "w", encoding="utf-8"), indent=1)
    total = sum(v["bytes"] for v in files.values())
    log("done: %d files, %.1f MB, visual_hash %s" % (len(files), total / 1048576, manifest["visual_hash"][:12]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--world", default="data/world")
    ap.add_argument("--out", default="data/world_visual")
    ap.add_argument("--quality", type=int, default=82)
    ap.add_argument("--ext-only", action="store_true", help="only (re)build ext/land-fraction rasters for --world into an existing --out")
    a = ap.parse_args()
    os.makedirs(os.path.join(a.out, "tiles"), exist_ok=True)

    log("land mask (supersampled)")
    mask = land_mask(a.raw)
    log("land fraction %.1f%%" % (mask.mean() / 2.55))
    if a.ext_only:
        write_ext(a, mask)
        write_manifest(a)
        log("ext-only done")
        return
    log("imagery NE2 50m")
    img = imagery(a.raw)
    rgba = np.dstack([img, mask])
    # tiles
    nt = 0
    for r in range(FH // TILE_H):
        for c in range(FW // TILE_W):
            tile = rgba[r * TILE_H:(r + 1) * TILE_H, c * TILE_W:(c + 1) * TILE_W]
            buf = io.BytesIO()
            Image.fromarray(tile).save(buf, "WEBP", quality=a.quality, alpha_quality=100, method=6, exact=True)
            # stored as .bin (not .webp) so Godot does not import it as a texture; decoded at runtime with Image.load_webp_from_buffer
            with open(os.path.join(a.out, "tiles", "t_%d_%d.bin" % (c, r)), "wb") as fh:
                fh.write(buf.getvalue())
            nt += 1
    # resize colour and mask separately: a premultiplied RGBA resize would turn all water (alpha 0) black
    ov_rgb = Image.fromarray(img).resize((FW // 4, FH // 4), Image.LANCZOS)
    ov_a = Image.fromarray(mask).resize((FW // 4, FH // 4), Image.LANCZOS)
    ov = Image.merge("RGBA", (*ov_rgb.split(), ov_a))
    buf = io.BytesIO()
    ov.save(buf, "WEBP", quality=a.quality, alpha_quality=100, method=6, exact=True)
    with open(os.path.join(a.out, "overview.bin"), "wb") as fh:
        fh.write(buf.getvalue())
    log("tiles:", nt)

    write_ext(a, mask)

    # fine vectors
    land = load(a.raw, "ne_10m_land") + load(a.raw, "ne_10m_minor_islands")
    lakes = load(a.raw, "ne_10m_lakes")
    rivers = load(a.raw, "ne_10m_rivers_lake_centerlines")
    a0 = load(a.raw, "ne_10m_admin_0_countries")
    a1 = load(a.raw, "ne_10m_admin_1_states_provinces")
    river_lines = []
    for f in rivers:
        g = f["geometry"]
        if not g:
            continue
        for line in g["coordinates"]:
            ls = LineString(line).simplify(0.01, preserve_topology=False)
            if len(ls.coords) >= 2:
                river_lines.append([float(f["properties"].get("scalerank") or 9)] + [(round(x, 4), round(y, 4)) for x, y in ls.coords])
    vec = {
        "coast": simplify_rings(land, 0.008), "lakes": simplify_rings(lakes, 0.01),
        "rivers": river_lines, "border0": simplify_rings([f for f in a0 if f["properties"]["ADM0_A3"] != "ATA"], 0.01),
        "border1": simplify_rings(a1, 0.02),
    }
    raw_b = json.dumps(vec, separators=(",", ":")).encode()
    with open(os.path.join(a.out, "vectors.json.z"), "wb") as fh:
        fh.write(zlib.compress(raw_b, 9))
    log("vectors: coast %d rings, rivers %d, border0 %d, border1 %d" % (len(vec["coast"]), len(vec["rivers"]), len(vec["border0"]), len(vec["border1"])))

    write_manifest(a)


if __name__ == "__main__":
    main()
