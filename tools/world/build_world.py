#!/usr/bin/env python3
"""Build the Iron Dominion Earth dataset (data/world/*) from open geodata.

Usage:
    python3 tools/world/build_world.py --raw RAW_DIR --out data/world [--cities cities5000]

RAW_DIR layout (see docs/DATA_SOURCES.md for URLs):
    ne/*.geojson               Natural Earth 10m vector layers (public domain)
    geonames/cities5000.zip    GeoNames populated places (CC BY 4.0)
    geonames/admin1CodesASCII.txt, countryInfo.txt
    dem/4_<x>_<y>.png          Terrain Tiles (terrarium encoding), zoom 4

Requires: numpy, shapely, Pillow (no scipy). Deterministic: same inputs => identical output (and world_hash).
Raster: equirectangular, RES degrees per pixel, lat range [LAT_TOP, LAT_BOT].
"""
import argparse, hashlib, io, json, math, os, sys, time, zipfile, zlib
import numpy as np
from PIL import Image, ImageDraw
from collections import deque
from shapely.geometry import shape, LineString, Point
from shapely.strtree import STRtree

RES = 0.2
LAT_TOP, LAT_BOT = 84.0, -60.0
W = int(round(360 / RES))
H = int(round((LAT_TOP - LAT_BOT) / RES))
LAND_CELL_KM2 = 12000.0
SEA_ZONE_KM2 = 700000.0
SEA_MIN_KM2 = 150000.0
KM_PER_DEG = 111.32
TERRAINS = ["sea", "plains", "forest", "hills", "mountain", "desert"]
WORLD_VERSION = 2


def log(*a):
    print("[%7.1fs]" % (time.time() - T0), *a, flush=True)


T0 = time.time()


def lon2x(lon): return (np.asarray(lon) + 180.0) / RES
def lat2y(lat): return (LAT_TOP - np.asarray(lat)) / RES
def x2lon(x): return -180.0 + (np.asarray(x) + 0.5) * RES
def y2lat(y): return LAT_TOP - (np.asarray(y) + 0.5) * RES


ROW_LAT = y2lat(np.arange(H))
PIX_KM2 = ((RES * KM_PER_DEG) ** 2 * np.cos(np.radians(ROW_LAT))).astype(np.float64)  # per row


def configure(res, land_km2, sea_km2):
    """Re-derive every raster-dependent global (the helpers read these at call time)."""
    global RES, W, H, LAND_CELL_KM2, SEA_ZONE_KM2, ROW_LAT, PIX_KM2
    RES = res
    W = int(round(360 / RES))
    H = int(round((LAT_TOP - LAT_BOT) / RES))
    LAND_CELL_KM2 = land_km2
    SEA_ZONE_KM2 = sea_km2
    ROW_LAT = y2lat(np.arange(H))
    PIX_KM2 = ((RES * KM_PER_DEG) ** 2 * np.cos(np.radians(ROW_LAT))).astype(np.float64)


def load_geojson(raw, name):
    with open(os.path.join(raw, "ne", name + ".geojson"), encoding="utf-8") as f:
        return json.load(f)["features"]


def polys_of(geom):
    if geom is None:
        return []
    if geom["type"] == "Polygon":
        return [geom["coordinates"]]
    if geom["type"] == "MultiPolygon":
        return geom["coordinates"]
    return []


def draw_features(img_arr_shape, items):
    """items: list of (value, geometry, sort_area). Large first so small features overwrite."""
    img = Image.new("I", (W, H), 0)
    d = ImageDraw.Draw(img)
    for value, geom, _ in sorted(items, key=lambda t: -t[2]):
        for poly in polys_of(geom):
            ring = poly[0]
            xy = [(float(lon2x(x)), float(lat2y(y))) for x, y in ring]
            if len(xy) >= 3:
                d.polygon(xy, fill=int(value))
    return np.array(img, dtype=np.int32)


def bbox_area(geom):
    xs, ys = [], []
    for poly in polys_of(geom):
        for x, y in poly[0]:
            xs.append(x); ys.append(y)
    return (max(xs) - min(xs)) * (max(ys) - min(ys)) if xs else 0.0


def stamp_missing(arr, items):
    """Make sure tiny features keep at least one pixel."""
    present = set(np.unique(arr).tolist())
    n = 0
    for value, geom, _ in items:
        if int(value) in present:
            continue
        pts = []
        for poly in polys_of(geom):
            pts.extend(poly[0])
        if not pts:
            continue
        cx = sum(p[0] for p in pts) / len(pts)
        cy = sum(p[1] for p in pts) / len(pts)
        px, py = int(lon2x(cx)), int(lat2y(cy))
        if 0 <= px < W and 0 <= py < H:
            arr[py, px] = int(value)
            n += 1
    return n


def kmeans_pixels(ys, xs, k, seed, weights=None):
    """Equal-area-ish k-means on pixel coordinates; returns labels (len n) in 0..k-1.
    `weights` (>0) concentrate seeds where they are large (adaptive grids).
    Large inputs (oceans) fit the centres on a deterministic sample, then assign every pixel in chunks."""
    n = len(ys)
    if k <= 1 or n <= 1:
        return np.zeros(n, dtype=np.int32)
    k = min(k, n)
    rs = np.random.RandomState(seed)
    scale = np.cos(np.radians(y2lat(ys))).astype(np.float64)
    allpts = np.stack([xs * scale, ys.astype(np.float64)], axis=1)
    allw = np.ones(n) if weights is None else np.asarray(weights, dtype=np.float64)
    if n > 30000:
        sel = np.sort(rs.choice(n, 30000, replace=False))
        pts, wts = allpts[sel], allw[sel]
    else:
        pts, wts = allpts, allw
    m = len(pts)
    weighted = weights is not None and not np.allclose(wts, 1.0)
    # unweighted path keeps the exact random stream of dataset v2 (rebuilding it must reproduce world_hash)
    first = rs.choice(m, p=wts / wts.sum()) if weighted else rs.randint(m)
    centers = [pts[first]]
    d2 = ((pts - centers[0]) ** 2).sum(1)
    for _ in range(1, k):
        pr = d2 * wts if weighted else d2
        probs = pr / pr.sum() if pr.sum() > 0 else wts / wts.sum()
        c = pts[rs.choice(m, p=probs)]
        centers.append(c)
        d2 = np.minimum(d2, ((pts - c) ** 2).sum(1))
    centers = np.array(centers)
    for _ in range(8):
        dist = ((pts[:, None, :] - centers[None, :, :]) ** 2).sum(2)
        lab = dist.argmin(1)
        for j in range(k):
            mm = lab == j
            if mm.any():
                centers[j] = (pts[mm] * wts[mm, None]).sum(0) / wts[mm].sum() if weighted else pts[mm].mean(0)
    labels = np.zeros(n, dtype=np.int32)
    for c0 in range(0, n, 50000):
        blk = allpts[c0:c0 + 50000]
        dist = ((blk[:, None, :] - centers[None, :, :]) ** 2).sum(2)
        labels[c0:c0 + 50000] = dist.argmin(1)
    return labels


def label8(mask, wrap=False):
    """8-connected component labelling by BFS. Returns (labels int32 with 0 = background, count)."""
    h, w = mask.shape
    lab = np.zeros((h, w), dtype=np.int32)
    flat = mask.ravel()
    labf = lab.ravel()
    ys, xs = np.nonzero(mask)
    order = ys * w + xs
    count = 0
    for start in order.tolist():
        if labf[start] != 0:
            continue
        count += 1
        labf[start] = count
        dq = deque([start])
        while dq:
            cur = dq.popleft()
            cy, cx = divmod(cur, w)
            for dy in (-1, 0, 1):
                ny = cy + dy
                if ny < 0 or ny >= h:
                    continue
                for dx in (-1, 0, 1):
                    if dy == 0 and dx == 0:
                        continue
                    nx = cx + dx
                    if nx < 0 or nx >= w:
                        if not wrap:
                            continue
                        nx %= w
                    n = ny * w + nx
                    if flat[n] and labf[n] == 0:
                        labf[n] = count
                        dq.append(n)
    return lab, count


def label_components(mask, wrap=True):
    """4-connected labelling with antimeridian wrap, vectorised union-find (fast for ocean-sized masks)."""
    idx = np.arange(H * W, dtype=np.int64).reshape(H, W)
    parent = np.where(mask, idx, -1).ravel()
    flat_mask = mask.ravel()
    pairs = [(idx[:, :-1].ravel(), idx[:, 1:].ravel()), (idx[:-1, :].ravel(), idx[1:, :].ravel())]
    if wrap:
        pairs.append((idx[:, -1].ravel(), idx[:, 0].ravel()))
    sel = []
    for a, b in pairs:
        ok = flat_mask[a] & flat_mask[b]
        sel.append((a[ok], b[ok]))
    for _ in range(200):
        before = parent.copy()
        for a, b in sel:
            pa, pb = parent[a], parent[b]
            lo = np.minimum(pa, pb)
            hi = np.maximum(pa, pb)
            np.minimum.at(parent, hi, lo)
        while True:  # pointer jumping
            valid = parent >= 0
            nxt = parent.copy()
            nxt[valid] = parent[parent[valid]]
            if np.array_equal(nxt, parent):
                break
            parent = nxt
        if np.array_equal(before, parent):
            break
    roots = parent[parent >= 0]
    uniq, inv = np.unique(roots, return_inverse=True)
    lab = np.zeros(H * W, dtype=np.int32)
    lab[parent >= 0] = inv + 1
    return lab.reshape(H, W)


def build_cells(region, mask_land, regions_meta, density=None):
    """Return cell raster (-1 water). Cells nest in regions and are connected."""
    cell = np.full((H, W), -1, dtype=np.int32)
    next_id = 0
    ys_all, xs_all = np.nonzero(mask_land)
    reg_vals = region[ys_all, xs_all]
    order = np.argsort(reg_vals, kind="stable")
    ys_all, xs_all, reg_vals = ys_all[order], xs_all[order], reg_vals[order]
    bounds = np.flatnonzero(np.diff(reg_vals)) + 1
    starts = np.concatenate([[0], bounds])
    ends = np.concatenate([bounds, [len(reg_vals)]])
    for s, e in zip(starts, ends):
        rid = int(reg_vals[s])
        ys, xs = ys_all[s:e], xs_all[s:e]
        sub = np.zeros((int(ys.max() - ys.min() + 3), int(xs.max() - xs.min() + 3)), dtype=bool)
        sub[ys - ys.min() + 1, xs - xs.min() + 1] = True
        lab, ncomp = label8(sub)
        comp_of = lab[ys - ys.min() + 1, xs - xs.min() + 1]
        area = PIX_KM2[ys]
        for c in range(1, ncomp + 1):
            m = comp_of == c
            cy, cx = ys[m], xs[m]
            dens = density[cy, cx] if density is not None else None
            a = float((area[m] * dens).sum()) if dens is not None else float(area[m].sum())
            k = max(1, int(round(a / LAND_CELL_KM2)))
            labels = kmeans_pixels(cy, cx, k, seed=rid * 131 + c, weights=dens)
            # deterministic cluster order: by centroid (y then x)
            cents = []
            for j in range(labels.max() + 1):
                mm = labels == j
                if mm.any():
                    cents.append((cy[mm].mean(), cx[mm].mean(), j))
            cents.sort()
            for _, _, j in cents:
                mm = labels == j
                cell[cy[mm], cx[mm]] = next_id
                next_id += 1
    # enforce connectivity of every cell (re-attach stray fragments to the neighbour they touch most)
    fixed = 0
    for cid in range(next_id):
        pass
    return cell, next_id


def fix_connectivity(cell, n_land):
    """Split off disconnected fragments: merge into the best adjacent cell, else make a new cell."""
    flat = cell.ravel()
    order = np.argsort(flat, kind="stable")
    sf = flat[order]
    first = np.searchsorted(sf, np.arange(n_land + 1))
    new_id = n_land
    fixed = 0
    for cid in range(n_land):
        idxs = order[first[cid]:first[cid + 1]]
        if len(idxs) < 2:
            continue
        ys, xs = idxs // W, idxs % W
        y0, x0 = ys.min(), xs.min()
        sub = np.zeros((ys.max() - y0 + 1, xs.max() - x0 + 1), dtype=bool)
        sub[ys - y0, xs - x0] = True
        lab, n = label8(sub)
        if n <= 1:
            continue
        sizes = np.bincount(lab.ravel())[1:]
        keep = int(sizes.argmax()) + 1
        comp_of = lab[ys - y0, xs - x0]
        for comp in range(1, n + 1):
            if comp == keep:
                continue
            m = comp_of == comp
            fy, fx = ys[m], xs[m]
            counts = {}
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                vals = cell[np.clip(fy + dy, 0, H - 1), (fx + dx) % W]
                for v in vals.tolist():
                    if v >= 0 and v != cid:
                        counts[v] = counts.get(v, 0) + 1
            if counts:
                tgt = max(counts.items(), key=lambda t: (t[1], -t[0]))[0]
            else:
                tgt = new_id
                new_id += 1
            cell[fy, fx] = tgt
            fixed += 1
    return cell, new_id, fixed


def compact_ids(cell):
    ids = np.unique(cell[cell >= 0])
    remap = np.full(int(ids.max()) + 2, -1, dtype=np.int32)
    remap[ids] = np.arange(len(ids), dtype=np.int32)
    out = np.where(cell >= 0, remap[np.where(cell >= 0, cell, 0)], -1).astype(np.int32)
    return out, len(ids)


def decode_dem(raw, dem_dir="dem", zoom=4):
    side = 1 << zoom
    mosaic = np.zeros((side * 256, side * 256), dtype=np.int16)
    for x in range(side):
        for y in range(side):
            im = np.array(Image.open(os.path.join(raw, dem_dir, "%d_%d_%d.png" % (zoom, x, y))).convert("RGB"), dtype=np.float32)
            mosaic[y * 256:(y + 1) * 256, x * 256:(x + 1) * 256] = np.round(im[..., 0] * 256 + im[..., 1] + im[..., 2] / 256 - 32768).astype(np.int16)
    n = mosaic.shape[0]
    xs = np.arange(W)
    ys = np.arange(H)
    lon = x2lon(xs)
    lat = y2lat(ys)
    px = ((lon + 180.0) / 360.0 * n).astype(np.int64) % n
    latr = np.radians(np.clip(lat, -85.05, 85.05))
    py = ((1 - np.log(np.tan(latr) + 1 / np.cos(latr)) / math.pi) / 2 * n).astype(np.int64)
    py = np.clip(py, 0, n - 1)
    return mosaic[py[:, None], px[None, :]].astype(np.int16)


def density_raster(region, reg_country, cities_xy, adaptive):
    """Relative cell density per pixel: >1 = smaller cells (near big cities and state borders)."""
    dens = np.ones((H, W), dtype=np.float64)
    if not adaptive:
        return dens
    land = region > 0
    cr = np.where(land, reg_country[region], -1)
    border = np.zeros((H, W), dtype=bool)
    for dy, dx in ((0, 1), (1, 0)):
        sh = np.roll(np.roll(cr, -dy, axis=0), -dx, axis=1)
        diff = (cr != sh) & land & (sh >= 0)
        border |= diff
        border |= np.roll(np.roll(diff, dy, axis=0), dx, axis=1)
    dens[border] = np.maximum(dens[border], 2.0)
    r = max(2, int(round(0.35 / RES)))
    for lon, lat, pop in cities_xy:
        cx, cy = int(lon2x(lon)), int(lat2y(lat))
        if not (0 <= cx < W and 0 <= cy < H):
            continue
        boost = 5.0 if pop >= 3000000 else 3.5 if pop >= 1000000 else 2.5
        y0, y1, x0, x1 = max(cy - r, 0), min(cy + r + 1, H), max(cx - r, 0), min(cx + r + 1, W)
        yy, xx = np.mgrid[y0:y1, x0:x1]
        disk = ((yy - cy) ** 2 + (xx - cx) ** 2) <= r * r
        sub = dens[y0:y1, x0:x1]
        sub[disk & land[y0:y1, x0:x1]] = np.maximum(sub[disk & land[y0:y1, x0:x1]], boost)
    return dens


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--cities", default="cities5000")
    ap.add_argument("--cache", default=None, help="directory for intermediate .npz (speeds up reruns)")
    ap.add_argument("--res", type=float, default=0.2, help="simulation raster, degrees per pixel (0.2 base, 0.1 hd)")
    ap.add_argument("--cell-km2", type=float, default=12000.0, help="target land cell area")
    ap.add_argument("--sea-km2", type=float, default=700000.0, help="target sea zone area")
    ap.add_argument("--adaptive", action="store_true", help="smaller cells near big cities and borders")
    ap.add_argument("--dem-dir", default="dem")
    ap.add_argument("--dem-zoom", type=int, default=4)
    ap.add_argument("--world-version", type=int, default=2)
    args = ap.parse_args()
    configure(args.res, args.cell_km2, args.sea_km2)
    global WORLD_VERSION
    WORLD_VERSION = args.world_version
    raw, out = args.raw, args.out
    os.makedirs(out, exist_ok=True)
    cache = args.cache or os.path.join(raw, "_cache")
    os.makedirs(cache, exist_ok=True)

    # ------------------------------------------------------------ countries & regions
    log("loading Natural Earth admin layers")
    a0 = load_geojson(raw, "ne_10m_admin_0_countries")
    a0 = [f for f in a0 if f["properties"]["ADM0_A3"] != "ATA" and f["properties"].get("ADMIN") != "Antarctica"]
    countries = []
    for f in a0:
        p = f["properties"]
        countries.append({
            "adm0": p["ADM0_A3"], "sov": p["SOV_A3"], "name": p["ADMIN"], "sovereign": p["SOVEREIGNT"],
            "name_en": p.get("NAME_EN") or p["ADMIN"], "name_ru": p.get("NAME_RU"), "type": p["TYPE"],
            "pop": int(p.get("POP_EST") or 0), "gdp_md": int(p.get("GDP_MD") or 0), "income": p.get("INCOME_GRP"),
            "continent": p.get("CONTINENT"), "iso_a3": p.get("ISO_A3"),
        })
    adm0_index = {c["adm0"]: i for i, c in enumerate(countries)}
    sov_codes = sorted({c["sov"] for c in countries})
    log(len(countries), "admin-0 entities,", len(sov_codes), "sovereign groups")

    a1 = load_geojson(raw, "ne_10m_admin_1_states_provinces")
    regions = []
    for i, c in enumerate(countries):
        regions.append({"kind": "country", "country": i, "name": c["name"], "name_local": None, "name_ru": c["name_ru"], "code": c["adm0"]})
    n_country_regions = len(regions)
    for f in a1:
        p = f["properties"]
        ci = adm0_index.get(p.get("adm0_a3"))
        if ci is None or not f["geometry"]:
            continue
        regions.append({"kind": "admin1", "country": ci, "name": p["name"] or "?", "name_local": p.get("name_local"),
                        "name_ru": p.get("name_ru"), "code": p.get("iso_3166_2") or "", "type": p.get("type")})
    reg_geoms = [None] * n_country_regions
    for i, f in enumerate(a1):
        pass
    # region ids: 0 = water, 1.. = regions (index + 1)
    items = []
    for i, f in enumerate(a0):
        items.append((i + 1, f["geometry"], bbox_area(f["geometry"])))
    region = draw_features((H, W), items)
    n_miss = stamp_missing(region, items)
    log("admin-0 rasterised; stamped", n_miss, "tiny countries")
    items1 = []
    ridx = n_country_regions
    for f in a1:
        p = f["properties"]
        ci = adm0_index.get(p.get("adm0_a3"))
        if ci is None or not f["geometry"]:
            continue
        items1.append((ridx + 1, f["geometry"], bbox_area(f["geometry"])))
        ridx += 1
    region1 = draw_features((H, W), items1)
    n_miss1 = stamp_missing(region1, items1)
    region = np.where(region1 > 0, region1, region)
    # admin-1 can spill over the coast generalisation: only keep land where admin-0 or admin-1 says so
    log("admin-1 rasterised; stamped", n_miss1)

    lakes = load_geojson(raw, "ne_10m_lakes")
    lake_img = draw_features((H, W), [(1, f["geometry"], bbox_area(f["geometry"])) for f in lakes if f["geometry"]])
    water_lake = lake_img > 0
    region[water_lake & (region > 0)] = 0
    # gaps of country-level pseudo regions in countries that do have admin-1: attach to nearest admin-1 region
    country_has_a1 = {}
    for rid, r in enumerate(regions, start=1):
        if r["kind"] == "admin1":
            country_has_a1[r["country"]] = True
    reg_country = np.array([0] + [r["country"] for r in regions], dtype=np.int32)
    for ci in country_has_a1:
        pseudo = ci + 1
        m = region == pseudo
        if not m.any():
            continue
        ys, xs = np.nonzero(m)
        y0, y1, x0, x1 = max(ys.min() - 3, 0), min(ys.max() + 4, H), max(xs.min() - 3, 0), min(xs.max() + 4, W)
        for _ in range(80):
            sub = region[y0:y1, x0:x1]
            gap = sub == pseudo
            if not gap.any():
                break
            ok = (sub > n_country_regions) & (reg_country[sub] == ci)
            filled = np.zeros_like(sub)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dy == 0 and dx == 0:
                        continue
                    shifted = np.roll(np.roll(sub, dy, axis=0), dx, axis=1)
                    sok = np.roll(np.roll(ok, dy, axis=0), dx, axis=1)
                    take = gap & sok & (filled == 0)
                    filled[take] = shifted[take]
            if not (filled > 0).any():
                break
            sub[filled > 0] = filled[filled > 0]
            region[y0:y1, x0:x1] = sub
    # drop pseudo-regions that ended up empty
    log("regions drawn")

    land = region > 0
    # ------------------------------------------------------------ elevation
    log("decoding elevation tiles")
    elev = decode_dem(raw, args.dem_dir, args.dem_zoom)
    # ------------------------------------------------------------ disputed areas
    disp = load_geojson(raw, "ne_10m_admin_0_disputed_areas")
    disputes = []
    ditems = []
    for i, f in enumerate(disp):
        p = f["properties"]
        disputes.append({"name": p.get("BRK_NAME") or p.get("NAME"), "admin": p.get("ADMIN"), "sovereign": p.get("SOVEREIGNT"),
                         "type": p.get("TYPE"), "note": p.get("NOTE_BRK") or p.get("NOTE_ADM0"), "sov_a3": p.get("SOV_A3")})
        if f["geometry"]:
            ditems.append((i + 1, f["geometry"], bbox_area(f["geometry"])))
    dispute_r = draw_features((H, W), ditems)
    # ------------------------------------------------------------ terrain hints
    geo = load_geojson(raw, "ne_10m_geography_regions_polys")
    desert_items = [(1, f["geometry"], bbox_area(f["geometry"])) for f in geo if f["properties"]["FEATURECLA"] == "Desert" and f["geometry"]]
    desert = draw_features((H, W), desert_items) > 0
    log("desert hint polygons:", len(desert_items))

    # ------------------------------------------------------------ cells
    ckey = "cells.npz" if (args.res == 0.2 and args.cell_km2 == 12000.0 and not args.adaptive) else "cells_%g_%g_%s.npz" % (args.res, args.cell_km2, "a" if args.adaptive else "u")
    cpath = os.path.join(cache, ckey)
    if os.path.exists(cpath):
        z = np.load(cpath)
        cell, n_land = z["cell"], int(z["n_land"])
        log("cells loaded from cache:", n_land)
    else:
        log("building land cells")
        big = []
        if args.adaptive:
            with zipfile.ZipFile(os.path.join(raw, "geonames", "cities5000.zip")) as zf5:
                for line in zf5.open("cities5000.txt"):
                    p_ = line.decode("utf-8").split("\t")
                    if int(p_[14] or 0) >= 500000:
                        big.append((float(p_[5]), float(p_[4]), int(p_[14])))
        dens = density_raster(region, reg_country, big, args.adaptive)
        cell, n_raw = build_cells(region, land, regions, dens)
        cell, n_new, fixed = fix_connectivity(cell, n_raw)
        cell, n_land = compact_ids(cell)
        log("land cells:", n_land, "(connectivity fixes:", fixed, ")")
        np.savez_compressed(cpath, cell=cell, n_land=n_land)

    # ------------------------------------------------------------ sea zones
    water = (cell < 0)
    wlab = label_components(water)
    sea = np.full((H, W), -1, dtype=np.int32)
    n_sea = 0
    ids, counts = np.unique(wlab[wlab > 0], return_counts=True)
    for wid in ids:
        m = wlab == wid
        ys, xs = np.nonzero(m)
        a = float(PIX_KM2[ys].sum())
        if a < SEA_MIN_KM2:
            continue
        k = max(1, int(round(a / SEA_ZONE_KM2)))
        labels = kmeans_pixels(ys, xs, k, seed=int(wid) * 977)
        cents = []
        for j in range(labels.max() + 1):
            mm = labels == j
            if mm.any():
                cents.append((ys[mm].mean(), xs[mm].mean(), j))
        cents.sort()
        for _, _, j in cents:
            mm = labels == j
            sea[ys[mm], xs[mm]] = n_land + n_sea
            n_sea += 1
    log("sea zones:", n_sea)
    full = np.where(cell >= 0, cell, sea).astype(np.int32)
    n_total = n_land + n_sea

    # ------------------------------------------------------------ per-cell stats
    flat = full.ravel()
    area_pix = np.broadcast_to(PIX_KM2[:, None], (H, W)).ravel()
    ar = np.bincount(flat[flat >= 0], weights=area_pix[flat >= 0], minlength=n_total)
    yy, xx = np.mgrid[0:H, 0:W]
    cnt = np.bincount(flat[flat >= 0], minlength=n_total).astype(np.float64)
    cy = np.bincount(flat[flat >= 0], weights=yy.ravel()[flat >= 0], minlength=n_total) / np.maximum(cnt, 1)
    # circular mean of x so cells crossing the antimeridian get a sane centre
    ang = xx.ravel()[flat >= 0] / W * 2 * np.pi
    sx = np.bincount(flat[flat >= 0], weights=np.cos(ang), minlength=n_total)
    sy = np.bincount(flat[flat >= 0], weights=np.sin(ang), minlength=n_total)
    cx = (np.arctan2(sy, sx) % (2 * np.pi)) / (2 * np.pi) * W
    e = elev.ravel().astype(np.float64)
    elev_mean = np.bincount(flat[flat >= 0], weights=e[flat >= 0], minlength=n_total) / np.maximum(cnt, 1)
    elev_sq = np.bincount(flat[flat >= 0], weights=(e ** 2)[flat >= 0], minlength=n_total) / np.maximum(cnt, 1)
    relief = np.sqrt(np.maximum(elev_sq - elev_mean ** 2, 0))  # standard deviation as roughness proxy
    reg_of_cell = np.zeros(n_total, dtype=np.int32)
    rr = region.ravel()
    # region of a cell = the region of its pixels (cells nest in regions, take the mode via max count)
    order = np.argsort(flat, kind="stable")
    sf = flat[order]
    for cid in range(n_land):
        pass
    first = np.searchsorted(sf, np.arange(n_total))
    for cid in range(n_land):
        idxs = order[first[cid]:first[cid] + int(cnt[cid])]
        reg_of_cell[cid] = int(np.bincount(rr[idxs]).argmax())
    country_of_cell = np.where(reg_of_cell > 0, reg_country[reg_of_cell], -1)
    desert_frac = np.bincount(flat[flat >= 0], weights=desert.ravel()[flat >= 0].astype(np.float64), minlength=n_total) / np.maximum(cnt, 1)
    lat_of_cell = y2lat(cy)
    terrain = np.zeros(n_total, dtype=np.int8)
    for cid in range(n_land):
        em, rl, lt = elev_mean[cid], relief[cid], abs(lat_of_cell[cid])
        if em > 2200 or rl > 650:
            t = 4
        elif desert_frac[cid] > 0.5:
            t = 5
        elif em > 700 or rl > 280:
            t = 3
        elif lt >= 50 or lt < 10:
            t = 2
        else:
            t = 1
        terrain[cid] = t
    # dispute id per cell (majority)
    disp_of_cell = np.zeros(n_total, dtype=np.int32)
    dm = dispute_r.ravel() > 0
    if dm.any():
        for cid in np.unique(flat[dm & (flat >= 0)]):
            sel = (flat == cid) & dm
            v = np.bincount(dispute_r.ravel()[sel]).argmax()
            if sel.sum() * 3 >= cnt[cid]:
                disp_of_cell[cid] = v
    log("cell statistics done")

    # ------------------------------------------------------------ adjacency (with wrap-around)
    pairs = []
    a, b = full[:, :-1].ravel(), full[:, 1:].ravel()
    pairs.append((a, b))
    a, b = full[:-1, :].ravel(), full[1:, :].ravel()
    pairs.append((a, b))
    pairs.append((full[:, -1], full[:, 0]))
    allp = np.concatenate([np.stack([p[0], p[1]], 1) for p in pairs])
    allp = allp[(allp[:, 0] >= 0) & (allp[:, 1] >= 0) & (allp[:, 0] != allp[:, 1])]
    lo = np.minimum(allp[:, 0], allp[:, 1]).astype(np.int64)
    hi = np.maximum(allp[:, 0], allp[:, 1]).astype(np.int64)
    key = lo * n_total + hi
    ukey, ucnt = np.unique(key, return_counts=True)
    edge_lo, edge_hi = (ukey // n_total).astype(np.int32), (ukey % n_total).astype(np.int32)
    log("adjacent pairs:", len(ukey))

    # ------------------------------------------------------------ settlements
    log("reading GeoNames", args.cities)
    zf = zipfile.ZipFile(os.path.join(raw, "geonames", args.cities + ".zip"))
    admin1_names = {}
    with open(os.path.join(raw, "geonames", "admin1CodesASCII.txt"), encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            admin1_names[p[0]] = p[1]
    admin2_names = {}
    a2path = os.path.join(raw, "geonames", "admin2Codes.txt")
    if os.path.exists(a2path):
        with open(a2path, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                admin2_names[p[0]] = p[1]
    ne_places = load_geojson(raw, "ne_10m_populated_places")
    ne_xy = np.array([f["geometry"]["coordinates"][:2] for f in ne_places])
    ne_taken = np.zeros(len(ne_places), dtype=bool)
    sett = []
    pix_cell = full
    land_idx = None
    # nearest land cell for coastal places whose pixel is water
    lm = full >= 0
    for line in zf.open(args.cities + ".txt"):
        p = line.decode("utf-8").rstrip("\n").split("\t")
        lat, lon = float(p[4]), float(p[5])
        px, py = int(lon2x(lon)), int(lat2y(lat))
        if not (0 <= px < W and 0 <= py < H):
            continue
        sett.append([p[0], p[1], p[2], p[3], lat, lon, p[7], p[8], p[10], p[11], int(p[14] or 0), px, py])
    log("GeoNames rows:", len(sett))
    sx_ = np.array([s[11] for s in sett]); sy_ = np.array([s[12] for s in sett])
    cid_of = full[sy_, sx_]
    reg_of = np.where(cid_of >= 0, reg_of_cell[np.clip(cid_of, 0, n_total - 1)], 0)
    # snap those on water (or sea) to the nearest land pixel within 6 px
    bad = (cid_of < 0) | (cid_of >= n_land)
    for i in np.flatnonzero(bad):
        px, py = int(sx_[i]), int(sy_[i])
        y0, y1, x0, x1 = max(py - 6, 0), min(py + 7, H), max(px - 6, 0), min(px + 7, W)
        sub = full[y0:y1, x0:x1]
        yy_, xx_ = np.nonzero((sub >= 0) & (sub < n_land))
        if len(yy_) == 0:
            cid_of[i] = -1
            continue
        dd = (yy_ + y0 - py) ** 2 + (xx_ + x0 - px) ** 2
        k = int(dd.argmin())
        cid_of[i] = sub[yy_[k], xx_[k]]
    settlements = []
    xy_g = np.array([[s[5], s[4]] for s in sett])
    d_ne = np.zeros(len(xy_g))
    i_ne = np.zeros(len(xy_g), dtype=np.int64)
    for c0 in range(0, len(xy_g), 2000):
        blk = xy_g[c0:c0 + 2000]
        dist2 = (blk[:, None, 0] - ne_xy[None, :, 0]) ** 2 + (blk[:, None, 1] - ne_xy[None, :, 1]) ** 2
        i_ne[c0:c0 + 2000] = dist2.argmin(1)
        d_ne[c0:c0 + 2000] = np.sqrt(dist2.min(1))
    for i, s in enumerate(sett):
        cid = int(cid_of[i])
        if cid < 0 or cid >= n_land:
            continue
        pop = s[10]
        rec = {"id": len(settlements), "gn": int(s[0]), "name": s[1], "ascii": s[2], "alt": [a for a in s[3].split(",") if a and a != s[1]][:4],
               "lat": round(s[4], 4), "lon": round(s[5], 4), "pop": pop, "fcode": s[6], "cc": s[7], "adm1": s[8], "adm2": s[9],
               "district": admin2_names.get("%s.%s.%s" % (s[7], s[8], s[9]), ""),
               "cell": cid, "region": int(reg_of_cell[cid]), "capital": 1 if s[6] == "PPLC" else 0}
        j = i_ne[i]
        if d_ne[i] < 0.25 and j < len(ne_places):
            q = ne_places[int(j)]["properties"]
            qn = str(q.get("NAMEASCII") or q.get("NAME") or "").lower()
            same_name = qn != "" and (qn == str(s[2]).lower() or qn == str(s[1]).lower())
            ratio = (q["POP_MAX"] or 1) / max(pop, 1)
            if not ne_taken[int(j)] and (q["POP_MAX"] or 0) > 0 and (same_name or 0.25 < ratio < 4.0):
                rec["name_ru"] = q.get("NAME_RU")
                rec["rank"] = q.get("SCALERANK")
                if q.get("ADM0CAP") == 1:
                    rec["capital"] = 1
                ne_taken[int(j)] = True
        settlements.append(rec)
    settlements.sort(key=lambda r: (-r["pop"], r["name"], r["gn"]))
    for i_, r_ in enumerate(settlements):
        r_["id"] = i_
    log("settlements kept:", len(settlements), "capitals:", sum(s["capital"] for s in settlements))

    # ------------------------------------------------------------ roads, rails, rivers
    log("processing roads / railroads / rivers")
    def densify_cells(lines):
        """Return list of (cellA, cellB) road links and per-cell km."""
        km = np.zeros(n_total, dtype=np.float64)
        links = set()
        for coords in lines:
            pts = np.array(coords, dtype=np.float64)
            if len(pts) < 2:
                continue
            seg = np.diff(pts, axis=0)
            lens = np.hypot(seg[:, 0], seg[:, 1])
            steps = np.maximum(1, np.ceil(lens / (RES / 2))).astype(int)
            prev = -1
            for si in range(len(seg)):
                t = np.linspace(0, 1, steps[si] + 1)
                xs_ = pts[si, 0] + seg[si, 0] * t
                ys_ = pts[si, 1] + seg[si, 1] * t
                px = np.clip(lon2x(xs_).astype(int), 0, W - 1)
                py = np.clip(lat2y(ys_).astype(int), 0, H - 1)
                cc = full[py, px]
                seg_km = lens[si] * KM_PER_DEG * math.cos(math.radians(ys_.mean()))
                for c in cc:
                    c = int(c)
                    if 0 <= c < n_land:
                        km[c] += seg_km / len(cc)
                        if prev >= 0 and c != prev:
                            links.add((min(prev, c), max(prev, c)))
                        prev = c
        return km, links
    def lines_from(feats, keep):
        res = []
        for f in feats:
            if not f["geometry"] or not keep(f["properties"]):
                continue
            g = f["geometry"]
            if g["type"] == "LineString":
                res.append(g["coordinates"])
            else:
                res.extend(g["coordinates"])
        return res
    roads = load_geojson(raw, "ne_10m_roads")
    road_lines = lines_from(roads, lambda p: p.get("type") in ("Major Highway", "Secondary Highway", "Road", "Beltway", "Bypass") or p.get("scalerank", 99) <= 6)
    road_km, road_links = densify_cells(road_lines)
    rails = load_geojson(raw, "ne_10m_railroads")
    rail_lines = lines_from(rails, lambda p: True)
    rail_km, rail_links = densify_cells(rail_lines)
    log("road links:", len(road_links), "rail links:", len(rail_links))
    # near-road/rail flags for settlements via STRtree of simplified lines
    def simplify_lines(lines, tol):
        out = []
        for c in lines:
            if len(c) < 2:
                continue
            ls = LineString(c).simplify(tol, preserve_topology=False)
            if not ls.is_empty and ls.geom_type == "LineString" and len(ls.coords) >= 2:
                out.append([(round(x, 3), round(y, 3)) for x, y in ls.coords])
        return out
    road_s = simplify_lines([l for l in road_lines], 0.04)
    rail_s = simplify_lines(rail_lines, 0.03)
    for name, linesx, key_ in (("road", road_s, "on_road"), ("rail", rail_s, "on_rail")):
        geoms = [LineString(l) for l in linesx]
        st = STRtree(geoms)
        for rec in settlements:
            pt = Point(rec["lon"], rec["lat"])
            near = st.query(pt.buffer(0.06))
            rec[key_] = 1 if len(near) and any(geoms[int(i)].distance(pt) < 0.06 for i in near) else 0
    rivers = load_geojson(raw, "ne_10m_rivers_lake_centerlines")
    river_lines = []
    for f in rivers:
        if f["geometry"]:
            for c in f["geometry"]["coordinates"]:
                river_lines.append((float(f["properties"].get("scalerank") or 9), c))
    river_s = []
    for sr, c in river_lines:
        if sr > 7:
            continue
        ls = LineString(c).simplify(0.03, preserve_topology=False)
        if len(ls.coords) >= 2:
            river_s.append([(round(x, 3), round(y, 3)) for x, y in ls.coords])
    # borders: boundary rings of admin-0 (legal borders + coast) and admin-1
    def rings(feats, tol, idfn):
        res = []
        for i, f in enumerate(feats):
            if not f["geometry"]:
                continue
            for poly in polys_of(f["geometry"]):
                ring = LineString(poly[0]).simplify(tol, preserve_topology=False)
                if len(ring.coords) >= 3:
                    res.append((idfn(i, f), [(round(x, 3), round(y, 3)) for x, y in ring.coords]))
        return res
    border0 = rings(a0, 0.03, lambda i, f: i)
    border1 = rings(a1, 0.05, lambda i, f: i)
    log("polylines: roads", len(road_s), "rails", len(rail_s), "rivers", len(river_s), "borders0", len(border0), "borders1", len(border1))

    # ------------------------------------------------------------ ports & airports
    ports_f = load_geojson(raw, "ne_10m_ports")
    air_f = load_geojson(raw, "ne_10m_airports")
    def snap(lon, lat):
        px, py = int(lon2x(lon)), int(lat2y(lat))
        if not (0 <= px < W and 0 <= py < H):
            return -1
        c = int(full[py, px])
        if 0 <= c < n_land:
            return c
        y0, y1, x0, x1 = max(py - 4, 0), min(py + 5, H), max(px - 4, 0), min(px + 5, W)
        sub = full[y0:y1, x0:x1]
        ys_, xs_ = np.nonzero((sub >= 0) & (sub < n_land))
        if len(ys_) == 0:
            return -1
        d = (ys_ + y0 - py) ** 2 + (xs_ + x0 - px) ** 2
        k = int(d.argmin())
        return int(sub[ys_[k], xs_[k]])
    ports = []
    for f in ports_f:
        lon, lat = f["geometry"]["coordinates"][:2]
        c = snap(lon, lat)
        if c >= 0:
            ports.append({"name": f["properties"]["name"], "lat": round(lat, 4), "lon": round(lon, 4), "cell": c, "rank": f["properties"].get("scalerank")})
    airports = []
    for f in air_f:
        lon, lat = f["geometry"]["coordinates"][:2]
        c = snap(lon, lat)
        if c >= 0:
            p = f["properties"]
            airports.append({"name": p.get("name_en") or p["name"], "iata": p.get("iata_code"), "type": p.get("type"), "lat": round(lat, 4), "lon": round(lon, 4), "cell": c})
    log("ports", len(ports), "airports", len(airports))

    # ------------------------------------------------------------ per-cell economy estimates
    pop_set = np.zeros(n_land)
    for s in settlements:
        pop_set[s["cell"]] += s["pop"]
    country_pop = np.array([c["pop"] for c in countries], dtype=np.float64)
    terr_w = np.array([0, 1.0, 0.8, 0.5, 0.2, 0.08])
    weight = ar[:n_land] * terr_w[terrain[:n_land]]
    pop_est = np.zeros(n_land)
    for ci in range(len(countries)):
        cells = np.flatnonzero(country_of_cell[:n_land] == ci)
        if len(cells) == 0:
            continue
        rural = max(country_pop[ci] - pop_set[cells].sum(), 0.0)
        w = weight[cells]
        pop_est[cells] = pop_set[cells] + (rural * w / w.sum() if w.sum() > 0 else 0)
    income_rank = {"1. High income: OECD": 4, "2. High income: nonOECD": 4, "3. Upper middle income": 3, "4. Lower middle income": 2, "5. Low income": 1}
    inc = np.array([income_rank.get(c["income"], 2) for c in countries])
    urban_max = np.zeros(n_land)
    for s in settlements:
        urban_max[s["cell"]] = max(urban_max[s["cell"]], s["pop"])
    industry = np.zeros(n_land, dtype=np.int8)
    for cid in range(n_land):
        up = urban_max[cid]
        base = 4 if up > 2e6 else 3 if up > 5e5 else 2 if up > 1e5 else 1
        ci = country_of_cell[cid]
        adj = (inc[ci] - 2) // 2 if ci >= 0 else 0
        industry[cid] = int(min(4, max(1, base + adj)))
    # infrastructure level 1..5 from road/rail density and settlements
    dens = (road_km[:n_land] * 1.0 + rail_km[:n_land] * 2.0) / np.maximum(ar[:n_land], 1.0) * 1000.0
    infra = np.ones(n_land, dtype=np.int8)
    for cid in range(n_land):
        d = dens[cid] + (3.0 if urban_max[cid] > 1e5 else 0.0)
        infra[cid] = 5 if d > 40 else 4 if d > 20 else 3 if d > 8 else 2 if d > 2 else 1
    log("economy estimates done")

    # ---- resource deposits: country totals from OWID energy data (if present), allocation inside the country is synthetic
    owid_path = os.path.join(raw, "owid-energy-data.csv")
    country_prod = {"oil": {}, "coal": {}}
    owid_year = None
    if os.path.exists(owid_path):
        import csv
        with open(owid_path, encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh))
        for res_key, col in (("oil", "oil_production"), ("coal", "coal_production")):
            best = {}
            for r in rows:
                iso, yr, v = r.get("iso_code"), r.get("year"), r.get(col)
                if iso and len(iso) == 3 and v and yr and int(yr) <= 2024:
                    if iso not in best or int(yr) > best[iso][0]:
                        best[iso] = (int(yr), float(v))
            country_prod[res_key] = {k: v[1] for k, v in best.items() if v[1] > 0}
            owid_year = max(v[0] for v in best.values()) if best else owid_year
        log("OWID production: oil", len(country_prod["oil"]), "countries, coal", len(country_prod["coal"]))
    rs = np.random.RandomState(20261116)
    deposits = {k: np.zeros(n_land, dtype=np.int8) for k in ("food", "coal", "iron", "oil")}
    sov_to_iso = {c["adm0"]: c["iso_a3"] for c in countries}
    by_country = {}
    for cid in range(n_land):
        by_country.setdefault(int(country_of_cell[cid]), []).append(cid)
    for key, cap_cells, total_cells in (("oil", 1, 140), ("coal", 1, 120)):
        prod = country_prod[key]
        world_total = sum(prod.values()) or 1.0
        for ci, cells_c in sorted(by_country.items()):
            if ci < 0:
                continue
            iso = countries[ci]["iso_a3"] if countries[ci]["iso_a3"] not in (None, "-99") else countries[ci]["adm0"]
            share = prod.get(iso, 0.0) / world_total
            n = int(round(share * total_cells))
            if share > 0 and n < 1:
                n = 1
            if n <= 0:
                continue
            pref = [c for c in cells_c if terrain[c] in ((5, 1, 3) if key == "oil" else (3, 4, 1))] or cells_c
            pick = rs.permutation(len(pref))[:min(n, len(pref), 30)]
            val = int(min(8, max(2, 2 + round(share * 60))))
            for pi in pick:
                deposits[key][pref[int(pi)]] = val
    for cid in range(n_land):
        t = int(terrain[cid])
        deposits["food"][cid] = {1: rs.randint(4, 7), 2: rs.randint(2, 5), 3: rs.randint(2, 4), 4: 1, 5: rs.randint(0, 2)}[t]
        if t in (3, 4) and rs.rand() < 0.35:
            deposits["iron"][cid] = rs.randint(2, 7)
        elif t in (1, 2) and rs.rand() < 0.04:
            deposits["iron"][cid] = rs.randint(2, 4)

    # ---- capitals and the biggest settlement per cell
    top_settle = np.full(n_land, -1, dtype=np.int32)
    for s_ in settlements:
        c_ = s_["cell"]
        if top_settle[c_] < 0 or s_["pop"] > settlements[top_settle[c_]]["pop"]:
            top_settle[c_] = s_["id"]
    cap_of_country = [-1] * len(countries)
    for s_ in settlements:
        ci = int(country_of_cell[s_["cell"]])
        if ci < 0:
            continue
        cur = cap_of_country[ci]
        if s_["capital"] and (cur < 0 or not settlements[cur]["capital"] or s_["pop"] > settlements[cur]["pop"]):
            cap_of_country[ci] = s_["id"]
    for ci in range(len(countries)):
        if cap_of_country[ci] < 0:
            best = max((s_ for s_ in settlements if country_of_cell[s_["cell"]] == ci), key=lambda s_: s_["pop"], default=None)
            cap_of_country[ci] = best["id"] if best else -1
    for ci, c in enumerate(countries):
        c["capital_settlement"] = cap_of_country[ci]
        sid = cap_of_country[ci]
        c["capital_cell"] = settlements[sid]["cell"] if sid >= 0 else -1
        c["capital_name"] = settlements[sid]["name"] if sid >= 0 else None
        c["capital_name_ru"] = settlements[sid].get("name_ru") if sid >= 0 else None

    # ------------------------------------------------------------ write
    def zjson(name, obj):
        raw_b = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        with open(os.path.join(out, name), "wb") as fh:
            fh.write(zlib.compress(raw_b, 9))
        return len(raw_b)
    def zbin(name, arr):
        b = np.ascontiguousarray(arr).astype("<" + arr.dtype.str[1:]).tobytes()
        with open(os.path.join(out, name), "wb") as fh:
            fh.write(zlib.compress(b, 9))
        return len(b)
    pix_order = np.argsort(np.where(full.ravel() >= 0, full.ravel(), n_total + 1), kind="stable").astype(np.int32)
    zbin("raster_order.bin", pix_order[: int((full.ravel() >= 0).sum())])
    # ---- GPU textures: cell ids as RG8 (65535 = none) and a hill-shaded relief base colour as RGB8
    ids16 = np.where(full >= 0, full, 65535).astype(np.uint16)
    rg = np.stack([(ids16 & 255).astype(np.uint8), (ids16 >> 8).astype(np.uint8)], axis=2)
    with open(os.path.join(out, "raster_ids.bin"), "wb") as fh:
        fh.write(zlib.compress(rg.tobytes(), 9))
    zr = elev.astype(np.float64)
    meters_x = (RES * KM_PER_DEG * 1000.0) * np.maximum(np.cos(np.radians(ROW_LAT)), 0.2)[:, None]
    meters_y = RES * KM_PER_DEG * 1000.0
    gy, gx = np.gradient(zr, meters_y, axis=0)[0] if False else (np.gradient(zr, axis=0) / meters_y, np.gradient(zr, axis=1) / meters_x)
    ex = 6.0  # vertical exaggeration for readability
    az, alt = math.radians(315.0), math.radians(40.0)
    slope = np.arctan(ex * np.hypot(gx, gy))
    aspect = np.arctan2(-gx, gy)
    shade = np.sin(alt) * np.cos(slope) + np.cos(alt) * np.sin(slope) * np.cos(az - aspect)
    shade = np.clip(shade, 0.0, 1.0)
    terr_colors = np.array([[47, 95, 134], [124, 154, 88], [77, 112, 64], [143, 149, 97], [139, 132, 120], [196, 169, 106]], dtype=np.float64)
    terr_px = np.zeros((H, W), dtype=np.int64)
    landpx = full >= 0
    terr_px[landpx] = terrain[full[landpx]]
    base = terr_colors[terr_px]
    land_mask = (full >= 0) & (full < n_land)
    hi = np.clip((zr - 300.0) / 4000.0, 0.0, 1.0)[..., None]
    base = np.where(land_mask[..., None], base * (1 - 0.45 * hi) + 245 * 0.45 * hi, base)
    depth = np.clip(-zr / 5000.0, 0.0, 1.0)[..., None]
    sea_col = np.array([47, 95, 134]) * (1 - depth) + np.array([14, 42, 69]) * depth
    water = ~land_mask
    base = np.where(water[..., None], sea_col, base)
    lit = 0.55 + 0.75 * (shade - 0.5) + 0.2
    lit = np.where(water, 0.9 + 0.25 * (shade - 0.5), lit)
    img = np.clip(base * lit[..., None], 0, 255).astype(np.uint8)
    with open(os.path.join(out, "raster_relief.bin"), "wb") as fh:
        fh.write(zlib.compress(img.tobytes(), 9))
    zbin("raster_cells.bin", full.astype(np.int32))
    zbin("raster_region.bin", region.astype(np.int32))
    zbin("raster_elev.bin", elev.astype(np.int32))
    zbin("adj.bin", np.stack([edge_lo, edge_hi, ucnt.astype(np.int32)], 1).astype(np.int32))
    links_arr = np.array(sorted([(a, b, 1) for a, b in road_links] + [(a, b, 2) for a, b in rail_links]), dtype=np.int32).reshape(-1, 3)
    zbin("links.bin", links_arr)
    cells_meta = {
        "n_land": int(n_land), "n_sea": int(n_sea), "w": W, "h": H, "res": RES, "lat_top": LAT_TOP,
        "cx": [round(float(v), 2) for v in cx], "cy": [round(float(v), 2) for v in cy],
        "area": [round(float(v), 1) for v in ar], "pixels": [int(v) for v in cnt],
        "region": [int(v) for v in reg_of_cell[:n_land]], "country": [int(v) for v in country_of_cell[:n_land]],
        "terrain": [int(v) for v in terrain], "elev": [int(round(v)) for v in elev_mean], "relief": [int(round(v)) for v in relief],
        "pop_est": [int(v) for v in pop_est], "pop_settle": [int(v) for v in pop_set], "industry": [int(v) for v in industry],
        "infra": [int(v) for v in infra], "road_km": [int(v) for v in road_km[:n_land]], "rail_km": [int(v) for v in rail_km[:n_land]],
        "dispute": [int(v) for v in disp_of_cell[:n_land]],
        "dep_food": [int(v) for v in deposits["food"]], "dep_coal": [int(v) for v in deposits["coal"]],
        "dep_iron": [int(v) for v in deposits["iron"]], "dep_oil": [int(v) for v in deposits["oil"]],
        "top_settlement": [int(v) for v in top_settle], "owid_year": owid_year,
    }
    sizes = {"cells.json.z": zjson("cells.json.z", cells_meta)}
    sizes["countries.json.z"] = zjson("countries.json.z", {"sovereign_tags": sov_codes, "countries": countries, "disputes": disputes})
    sizes["regions.json.z"] = zjson("regions.json.z", {"regions": regions, "n_country_regions": n_country_regions})
    scol = {
        "name": [r["name"] for r in settlements], "ascii": [r["ascii"] for r in settlements],
        "alt": ["|".join(r["alt"]) for r in settlements], "name_ru": [r.get("name_ru") or "" for r in settlements],
        "district": [r["district"] for r in settlements], "fcode": [r["fcode"] for r in settlements],
        "lat": [r["lat"] for r in settlements], "lon": [r["lon"] for r in settlements], "pop": [r["pop"] for r in settlements],
        "cell": [r["cell"] for r in settlements], "region": [r["region"] for r in settlements], "capital": [r["capital"] for r in settlements],
        "on_road": [r["on_road"] for r in settlements], "on_rail": [r["on_rail"] for r in settlements],
        "rank": [r.get("rank") or 0 for r in settlements],
    }
    sizes["settlements.json.z"] = zjson("settlements.json.z", scol)
    sizes["facilities.json.z"] = zjson("facilities.json.z", {"ports": ports, "airports": airports})
    sizes["lines.json.z"] = zjson("lines.json.z", {"roads": road_s, "rails": rail_s, "rivers": river_s, "border0": border0, "border1": border1})
    manifest = {
        "world_version": WORLD_VERSION, "built": time.strftime("%Y-%m-%d"), "raster": {"w": W, "h": H, "res_deg": RES, "lat_top": LAT_TOP, "lat_bottom": LAT_BOT},
        "counts": {"cells_land": int(n_land), "cells_sea": int(n_sea), "regions": len(regions), "countries": len(countries), "settlements": len(settlements),
                   "ports": len(ports), "airports": len(airports), "road_lines": len(road_s), "rail_lines": len(rail_s)},
        "notes": "terrain, per-cell population/industry/infrastructure and resource allocation inside countries are estimates derived from the sources (see docs/DATA_SOURCES.md)",
        "files": {},
    }
    h = hashlib.sha256()
    for fn in sorted(os.listdir(out)):
        if fn.endswith(".bin") or fn.endswith(".z"):
            with open(os.path.join(out, fn), "rb") as fh:
                data = fh.read()
            d = hashlib.sha256(data).hexdigest()
            manifest["files"][fn] = {"sha256": d, "bytes": len(data)}
            h.update(fn.encode() + d.encode())
    manifest["world_hash"] = h.hexdigest()
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=1)
    total = sum(v["bytes"] for v in manifest["files"].values())
    log("done. world_hash", manifest["world_hash"][:16], "files", len(manifest["files"]), "total %.1f MB" % (total / 1048576))


if __name__ == "__main__":
    main()
