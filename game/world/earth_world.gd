class_name EarthWorld
extends RefCounted
## Loader for the real-world dataset in data/world (built by tools/world/build_world.py).
## Produces the same `world` dictionary shape as WorldGen, plus hierarchy (countries, regions, settlements).
## Territorial cells ("provinces" for the simulation) nest inside administrative regions but are an independent system.

## Several datasets can exist side by side (data/world = base, data/world_hd = detailed). One is "active" per process.
static var dataset := "world"
static var _store: Dictionary = {}


static func _dir() -> String:
	return "res://data/%s/" % dataset


static func available_dataset(ds: String) -> bool:
	return FileAccess.file_exists("res://data/%s/manifest.json" % ds)


static func _snapshot() -> Dictionary:
	return {
		"cache": _cache, "lines": _lines, "facilities": _facilities, "relief": _relief_img, "ids": _ids_img,
		"sett_loaded": _sett_loaded, "cell_index": _cell_index, "search": _search_index,
		"S_NAME": S_NAME, "S_ASCII": S_ASCII, "S_ALT": S_ALT, "S_NAME_RU": S_NAME_RU, "S_DISTRICT": S_DISTRICT, "S_FCODE": S_FCODE,
		"S_LAT": S_LAT, "S_LON": S_LON, "S_POP": S_POP, "S_CELL": S_CELL, "S_REGION": S_REGION, "S_CAP": S_CAP, "S_ROAD": S_ROAD, "S_RAIL": S_RAIL,
	}


static func _restore(st: Dictionary) -> void:
	_cache = st.get("cache", {})
	_lines = st.get("lines", {})
	_facilities = st.get("facilities", {})
	_relief_img = st.get("relief", null)
	_ids_img = st.get("ids", null)
	_sett_loaded = st.get("sett_loaded", false)
	_cell_index = st.get("cell_index", {})
	_search_index = st.get("search", PackedStringArray())
	S_NAME = st.get("S_NAME", PackedStringArray())
	S_ASCII = st.get("S_ASCII", PackedStringArray())
	S_ALT = st.get("S_ALT", PackedStringArray())
	S_NAME_RU = st.get("S_NAME_RU", PackedStringArray())
	S_DISTRICT = st.get("S_DISTRICT", PackedStringArray())
	S_FCODE = st.get("S_FCODE", PackedStringArray())
	S_LAT = st.get("S_LAT", PackedFloat32Array())
	S_LON = st.get("S_LON", PackedFloat32Array())
	S_POP = st.get("S_POP", PackedInt32Array())
	S_CELL = st.get("S_CELL", PackedInt32Array())
	S_REGION = st.get("S_REGION", PackedInt32Array())
	S_CAP = st.get("S_CAP", PackedByteArray())
	S_ROAD = st.get("S_ROAD", PackedByteArray())
	S_RAIL = st.get("S_RAIL", PackedByteArray())


## Make `ds` the active dataset (loaded data of the previous one is kept in memory and restored on switching back).
static func activate(ds: String) -> void:
	if ds == dataset:
		return
	_lock.lock()
	_store[dataset] = _snapshot()
	_restore(_store.get(ds, {}))
	dataset = ds
	_lock.unlock()
const TERRAIN_NAMES := ["sea", "plains", "forest", "hills", "mountain", "desert"]
const POP_UNIT := 100000.0  # simulation population unit = 100k people

static var _cache: Dictionary = {}
static var _lines: Dictionary = {}
static var _facilities: Dictionary = {}


static func _bytes(name: String) -> PackedByteArray:
	var comp := FileAccess.get_file_as_bytes(_dir() + name)
	if comp.is_empty():
		return PackedByteArray()
	return comp.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)


static func _json(name: String) -> Variant:
	var b := _bytes(name)
	if b.is_empty():
		return null
	return JSON.parse_string(b.get_string_from_utf8())


static func manifest() -> Dictionary:
	var f := FileAccess.open(_dir() + "manifest.json", FileAccess.READ)
	if f == null:
		return {}
	return JSON.parse_string(f.get_as_text())


static func available() -> bool:
	return FileAccess.file_exists(_dir() + "manifest.json")


## Heavy, loaded once per process.
static func load_world() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	var man := manifest()
	var meta: Dictionary = _json("cells.json.z")
	var w: int = meta["w"]
	var h: int = meta["h"]
	var n_land: int = meta["n_land"]
	var n_total: int = n_land + int(meta["n_sea"])
	var cell_prov := _bytes("raster_cells.bin").to_int32_array()
	var region_raster := _bytes("raster_region.bin").to_int32_array()
	var elev_raster := _bytes("raster_elev.bin").to_int32_array()
	var order := _bytes("raster_order.bin").to_int32_array()
	var pixels: Array = meta["pixels"]
	var prov_cells: Array = []
	var start := 0
	for c in n_total:
		var cnt: int = int(pixels[c])
		prov_cells.append(order.slice(start, start + int(cnt)))
		start += cnt
	# adjacency (lo, hi, shared-boundary pixels)
	var adj := _bytes("adj.bin").to_int32_array()
	var nb: Array = []
	for _c in n_total:
		nb.append([])
	var i := 0
	while i < adj.size():
		nb[adj[i]].append(adj[i + 1])
		nb[adj[i + 1]].append(adj[i])
		i += 3
	var links := _bytes("links.bin").to_int32_array()
	var road_link := {}
	var rail_link := {}
	i = 0
	while i < links.size():
		var key: int = links[i] * 100000 + links[i + 1]
		if links[i + 2] == 1:
			road_link[key] = true
		else:
			rail_link[key] = true
		i += 3
	var provinces: Array = []
	var cx: Array = meta["cx"]
	var cy: Array = meta["cy"]
	var terr: Array = meta["terrain"]
	for c in n_total:
		var is_land := c < n_land
		var nbs: Array = nb[c]
		nbs.sort()
		var land_nb: Array = []
		if is_land:
			for q in nbs:
				if q < n_land:
					land_nb.append(q)
		var d := {
			"id": c, "land": is_land, "center": Vector2(cx[c], cy[c]), "cell_count": int(pixels[c]),
			"terrain": TERRAIN_NAMES[int(terr[c])], "pop": 0, "industry": 0, "deposits": {},
			"neighbors": nbs, "land_neighbors": land_nb, "area": int(meta["area"][c]), "elev": int(meta["elev"][c]),
		}
		if is_land:
			# JSON numbers arrive as floats: all simulation state must be integers (determinism across save/load and platforms)
			d["pop"] = maxi(1, int(round(float(meta["pop_est"][c]) / POP_UNIT)))
			d["industry"] = int(meta["industry"][c])
			d["region"] = int(meta["region"][c])
			d["country"] = int(meta["country"][c])
			d["infra0"] = int(meta["infra"][c])
			d["pop_real"] = int(meta["pop_est"][c])
			d["pop_settle"] = int(meta["pop_settle"][c])
			d["top_settlement"] = int(meta["top_settlement"][c])
			d["road_km"] = int(meta["road_km"][c])
			d["rail_km"] = int(meta["rail_km"][c])
			d["dispute"] = int(meta["dispute"][c])
			var dep := {}
			for pair in [["food", "dep_food"], ["coal", "dep_coal"], ["iron", "dep_iron"], ["oil", "dep_oil"]]:
				var v: int = int(meta[pair[1]][c])
				if v > 0:
					dep[pair[0]] = v
			d["deposits"] = dep
		provinces.append(d)
	var cdata: Dictionary = _json("countries.json.z")
	var rdata: Dictionary = _json("regions.json.z")
	_cache = {
		"kind": "earth", "dataset": dataset, "seed": 0, "w": w, "h": h, "res": meta["res"], "lat_top": meta["lat_top"],
		"cell_prov": cell_prov, "region_raster": region_raster, "elev": elev_raster, "prov_cells": prov_cells,
		"provinces": provinces, "land_count": n_land,
		"road_link": road_link, "rail_link": rail_link,
		"countries": cdata["countries"], "sovereign_tags": cdata["sovereign_tags"], "disputes": cdata["disputes"],
		"regions": rdata["regions"], "n_country_regions": rdata["n_country_regions"],
		"world_hash": man.get("world_hash", ""), "world_version": man.get("world_version", 0),
		"owid_year": meta.get("owid_year"),
	}
	return _cache


# ------------------------------------------------------------ GPU textures

static var _relief_img: Image = null
static var _ids_img: Image = null


## Hill-shaded base colours (RGB8), W x H.
static func relief_image() -> Image:
	if _relief_img == null:
		var man := load_world()
		_relief_img = Image.create_from_data(int(man["w"]), int(man["h"]), false, Image.FORMAT_RGB8, _bytes("raster_relief.bin"))
	return _relief_img


## Cell ids (RG8, little endian 16 bit, 65535 = no cell), W x H.
static func ids_image() -> Image:
	if _ids_img == null:
		var man := load_world()
		_ids_img = Image.create_from_data(int(man["w"]), int(man["h"]), false, Image.FORMAT_RG8, _bytes("raster_ids.bin"))
	return _ids_img


# ---------------------------------------------------------------- lazy layers
# Settlements are stored as columns (typed arrays): 70 thousand dictionaries would cost ~230 MB.
# All lazy loaders are guarded by a mutex because the map view preloads them on a worker thread.

static var _lock := Mutex.new()
static var _sett_loaded := false
static var S_NAME := PackedStringArray()
static var S_ASCII := PackedStringArray()
static var S_ALT := PackedStringArray()      # alternative names joined by "|"
static var S_NAME_RU := PackedStringArray()  # "" = no Russian name in the sources
static var S_DISTRICT := PackedStringArray() # GeoNames admin-2 name ("" = no data)
static var S_FCODE := PackedStringArray()
static var S_LAT := PackedFloat32Array()
static var S_LON := PackedFloat32Array()
static var S_POP := PackedInt32Array()       # 0 = no data
static var S_CELL := PackedInt32Array()
static var S_REGION := PackedInt32Array()
static var S_CAP := PackedByteArray()
static var S_ROAD := PackedByteArray()
static var S_RAIL := PackedByteArray()


static func ensure_settlements() -> void:
	_lock.lock()
	if not _sett_loaded:
		var v: Variant = _json("settlements.json.z")
		if typeof(v) == TYPE_DICTIONARY:
			S_NAME = PackedStringArray(v["name"])
			S_ASCII = PackedStringArray(v["ascii"])
			S_ALT = PackedStringArray(v["alt"])
			S_NAME_RU = PackedStringArray(v["name_ru"])
			S_DISTRICT = PackedStringArray(v["district"])
			S_FCODE = PackedStringArray(v["fcode"])
			S_LAT = PackedFloat32Array(v["lat"])
			S_LON = PackedFloat32Array(v["lon"])
			S_POP = PackedInt32Array(v["pop"])
			S_CELL = PackedInt32Array(v["cell"])
			S_REGION = PackedInt32Array(v["region"])
			S_CAP = PackedByteArray(v["capital"])
			S_ROAD = PackedByteArray(v["on_road"])
			S_RAIL = PackedByteArray(v["on_rail"])
			_sett_loaded = true
	_lock.unlock()


static func settlement_count() -> int:
	ensure_settlements()
	return S_POP.size()


## One settlement as a dictionary (built on demand from the columns). Ids are ordered by population, biggest first.
static func settlement(i: int) -> Dictionary:
	ensure_settlements()
	return {
		"id": i, "name": S_NAME[i], "ascii": S_ASCII[i], "alt": Array(S_ALT[i].split("|", false)),
		"name_ru": S_NAME_RU[i] if S_NAME_RU[i] != "" else null, "district": S_DISTRICT[i], "fcode": S_FCODE[i],
		"lat": S_LAT[i], "lon": S_LON[i], "pop": S_POP[i], "cell": S_CELL[i], "region": S_REGION[i],
		"capital": S_CAP[i], "on_road": S_ROAD[i], "on_rail": S_RAIL[i],
	}


static func display_name(i: int) -> String:
	ensure_settlements()
	return S_NAME_RU[i] if S_NAME_RU[i] != "" else S_NAME[i]


static func lines() -> Dictionary:
	_lock.lock()
	if _lines.is_empty():
		var v: Variant = _json("lines.json.z")
		if typeof(v) == TYPE_DICTIONARY:
			_lines = v
	var out := _lines
	_lock.unlock()
	return out


## The parsed polylines are ~70 MB of Variants; the map view turns them into packed arrays and then lets them go.
static func release_lines() -> void:
	_lock.lock()
	_lines = {}
	_lock.unlock()


static func facilities() -> Dictionary:
	if _facilities.is_empty():
		var v: Variant = _json("facilities.json.z")
		if typeof(v) == TYPE_DICTIONARY:
			_facilities = v
	return _facilities


# ------------------------------------------------------------------ geography

## Longitude/latitude -> raster pixel.
static func lonlat_to_pixel(world: Dictionary, lon: float, lat: float) -> Vector2i:
	var res: float = world["res"]
	return Vector2i(int((lon + 180.0) / res), int((float(world["lat_top"]) - lat) / res))


static func pixel_to_lonlat(world: Dictionary, x: float, y: float) -> Vector2:
	var res: float = world["res"]
	return Vector2(-180.0 + (x + 0.5) * res, float(world["lat_top"]) - (y + 0.5) * res)


static func cell_at_lonlat(world: Dictionary, lon: float, lat: float) -> int:
	var p := lonlat_to_pixel(world, lon, lat)
	if p.x < 0 or p.y < 0 or p.x >= int(world["w"]) or p.y >= int(world["h"]):
		return -1
	return world["cell_prov"][p.y * int(world["w"]) + p.x]


# ------------------------------------------------------------------ hierarchy

static func region_name(world: Dictionary, region_id: int) -> String:
	if region_id <= 0 or region_id > world["regions"].size():
		return ""
	var r: Dictionary = world["regions"][region_id - 1]
	return r.get("name_ru") if r.get("name_ru") != null and str(r.get("name_ru")) != "" else r["name"]


static func region_cells(world: Dictionary, region_id: int) -> Array:
	var out: Array = []
	for p in world["provinces"]:
		if p["land"] and p["region"] == region_id:
			out.append(p["id"])
	return out


# ---------------------------------------------------------------- cell index

static var _cell_index: Dictionary = {}


## Settlement ids inside a territorial cell, biggest first (ids are already ordered by population).
static func settlements_in_cell(cell: int) -> Array:
	ensure_settlements()
	_lock.lock()
	if _cell_index.is_empty():
		for i in S_CELL.size():
			var c: int = S_CELL[i]
			if not _cell_index.has(c):
				_cell_index[c] = []
			_cell_index[c].append(i)
	_lock.unlock()
	return _cell_index.get(cell, [])


static func settlement_kind(s: Dictionary) -> String:
	if int(s["capital"]) == 1:
		return "столица"
	var pop: int = int(s["pop"])
	if pop >= 1000000:
		return "мегаполис" if pop >= 5000000 else "крупный город"
	if pop >= 100000:
		return "город"
	if pop >= 20000:
		return "малый город"
	return "посёлок"


# --------------------------------------------------------------------- search

static var _search_index := PackedStringArray()


static func _norm(t: String) -> String:
	return t.to_lower().strip_edges()


## Case-insensitive search over local, ASCII, alternative and Russian names. Biggest settlements first.
static func search(query: String, limit: int = 20) -> Array:
	var q := _norm(query)
	if q.length() < 2:
		return []
	ensure_settlements()
	_lock.lock()
	if _search_index.is_empty():
		_search_index.resize(S_NAME.size())
		for i in S_NAME.size():
			_search_index[i] = _norm(S_NAME[i] + "|" + S_ASCII[i] + "|" + S_ALT[i] + "|" + S_NAME_RU[i])
	_lock.unlock()
	var out: Array = []
	for i in _search_index.size():   # ids are ordered by population, so the first hits are the biggest places
		if _search_index[i].contains(q):
			out.append(settlement(i))
			if out.size() >= limit:
				break
	return out
