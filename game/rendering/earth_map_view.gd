class_name EarthMapView
extends MapView
## Real-world map renderer.
##  - base: hill-shaded relief + GPU palette lookup by cell id (earth_map.gdshader); control changes touch single palette pixels
##  - overlays: legal borders, rivers, roads, railways (vector, chunked + zoom LOD), settlements, ports, airports
##  - map modes swap the palette (smooth cross-fade); simulation data is only read, never written

const MODES := [
	["political", "Политический"], ["admin", "Административный"], ["military", "Военный"], ["control", "Контроль территорий"],
	["terrain", "Рельеф"], ["infra", "Инфраструктура"], ["economy", "Экономика"], ["resources", "Ресурсы"],
	["population", "Население"], ["logistics", "Логистика"], ["diplomacy", "Дипломатия"], ["legal", "Признанные границы"],
	["weather", "Погода и сезон"],
]
const CHUNK_DEG := 15.0
const CHUNK_COLS := 24
const BUILD_BUDGET := 2500   # polylines turned into chunked segments per frame

var mode := "political"
var _weather_day := -1
var is_earth := false
var show_settlements := true
var show_lines := true

var _shader: Shader
var _mats: Array = []                # every ShaderMaterial (overview + loaded tiles); shared uniforms are applied to all
var _params: Dictionary = {}         # last value of each shared uniform (applied to tiles created later)
var _overview: MeshInstance2D
var _tiles: Dictionary = {}          # col*100+row -> MeshInstance2D
var _tile_lru: Array = []
var _want_tiles: Array = []
var _fx_t := 0.0                    # throttle of the animated shader uniforms
var _visual := false                 # data/world_visual present (imagery tiles + exact land mask)
var quality := "high"                # low: overview only, medium: tiles when zoomed in, high: tiles from zoom 0.5
var detail := GraphicsQuality.Level.HIGH   # same setting as `quality`, as a GraphicsQuality level (labels, city density, roads)
var _tile_grid := Vector2i(8, 4)
var _world_w := 7200.0
var _world_h := 4000.0
var _k := 1146.0
var _merc_top := 0.0
var _cellpos := PackedVector2Array()
var _ext_bytes := PackedByteArray()
var _landf := PackedByteArray()
var _layers_built := false
var _pal_cur: Image
var _pal_prev: Image
var _info_a: Image
var _info_b: Image
var _t_cur: ImageTexture
var _t_prev: ImageTexture
var _t_a: ImageTexture
var _t_b: ImageTexture
var _fade := 1.0
var _tween: Tween
var _ctl := PackedInt32Array()
var _agg: Dictionary = {}          # controller -> Vector3(cells, sum_x, sum_y) for labels
var _flash: Dictionary = {}        # cell -> seconds of capture highlight left
var _cut: Dictionary = {}          # cells cut off from supply (set by the game for the player)
var _contested: Dictionary = {}    # cells with a battle going on
var _war_pairs: Dictionary = {}
var _hover := -1
var _sel_cached := -2
var _last_cam := Vector3(-1, -1, -1)
var _ccol: Dictionary = {}
var _rel: Dictionary = {}

var _chunks: Dictionary = {}       # layer -> {chunk key -> PackedVector2Array}
var _queue: Array = []             # pending [layer, polyline] items
var _meshes: Dictionary = {}       # "layer:chunk" -> ArrayMesh (built once, drawn by the GPU without re-tessellation)
var _vec_done := false
var _qpos := 0
var _vectors_started := false
var _sett_chunks: Dictionary = {}
var _prep_thread: Thread
var _data_ready := false
var _preload_started := false
var _res := 0.2
var _top := 84.0


func _ready() -> void:
	super._ready()
	set_process(true)


# ------------------------------------------------------------------ setup

func bind(sim_: Simulation) -> void:
	if str(sim_.world.get("kind", "")) != "earth":
		is_earth = false
		_set_layers_visible(false)
		super.bind(sim_)
		return
	sim = sim_
	is_earth = true
	min_zoom = 0.08
	max_zoom = 16.0
	var w: int = int(sim.world["w"])
	var h: int = int(sim.world["h"])
	EarthWorld.activate(str(sim.world.get("dataset", "world")))
	_res = float(sim.world["res"])
	_top = float(sim.world["lat_top"])
	# Web Mercator: familiar shapes (conformal). Geographic coordinates stay separate from screen coordinates.
	_world_w = 7200.0   # world units are independent of the simulation raster resolution
	_k = _world_w / TAU
	_merc_top = _k * log(tan(PI / 4.0 + deg_to_rad(_top) / 2.0))
	_world_h = project(0.0, _top - h * _res).y
	_begin_preload()
	_visual = EarthVisual.available()
	_build_layers(w, h)
	_set_layers_visible(true)
	_cellpos = PackedVector2Array()
	_cellpos.resize(sim.provinces().size())
	for p in sim.provinces():
		_cellpos[p["id"]] = px_to_world(p["center"])
	var n: int = sim.provinces().size()
	var rows: int = int(ceil(n / 256.0))
	_pal_cur = Image.create(256, rows, false, Image.FORMAT_RGBA8)
	_pal_prev = Image.create(256, rows, false, Image.FORMAT_RGBA8)
	_info_a = Image.create(256, rows, false, Image.FORMAT_RGBA8)
	_info_b = Image.create(256, rows, false, Image.FORMAT_RGBA8)
	_t_cur = ImageTexture.create_from_image(_pal_cur)
	_t_prev = ImageTexture.create_from_image(_pal_prev)
	_t_a = ImageTexture.create_from_image(_info_a)
	_t_b = ImageTexture.create_from_image(_info_b)
	_set_all("pal_cur", _t_cur)
	_set_all("pal_prev", _t_prev)
	_set_all("info_a", _t_a)
	_set_all("info_b", _t_b)
	_set_all("pal_size", Vector2(256.0, float(rows)))
	_set_all("fade", 1.0)
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2.ZERO
	if vp.x < 1.0 or vp.y < 1.0:
		vp = Vector2(1600, 900)
	camera.position = world_size() * 0.5
	camera.zoom = Vector2.ONE * minf(vp.x / _world_w, vp.y / _world_h)
	_ctl = PackedInt32Array()
	_ctl.resize(n)
	_ctl.fill(-2)
	_flash.clear()
	_contested.clear()
	_cut.clear()
	_last_cam = Vector3(-1, -1, -1)
	repaint_all()


# ------------------------------------------------------- projection & layers

func project(lon: float, lat: float) -> Vector2:
	var phi := deg_to_rad(clampf(lat, -85.0, 85.0))
	return Vector2((lon + 180.0) / 360.0 * _world_w, _merc_top - _k * log(tan(PI / 4.0 + phi / 2.0)))


## World position -> (longitude, latitude).
func unproject(p: Vector2) -> Vector2:
	var m := (_merc_top - p.y) / _k
	return Vector2(p.x / _world_w * 360.0 - 180.0, rad_to_deg(2.0 * atan(exp(m)) - PI / 2.0))


## Simulation-raster pixel (equirectangular grid used by the cell data) -> world position.
func px_to_world(px: Vector2) -> Vector2:
	return project(-180.0 + (px.x + 0.5) * _res, _top - (px.y + 0.5) * _res)


func cell_world(p: int) -> Vector2:
	if is_earth and p < _cellpos.size():
		return _cellpos[p]
	return super.cell_world(p)


func world_size() -> Vector2:
	if is_earth:
		return Vector2(_world_w, _world_h)
	return super.world_size()


func world_pos_of(lon: float, lat: float) -> Vector2:
	return project(lon, lat)


func _set_all(name: String, value: Variant) -> void:
	if _params.has(name) and _params[name] == value:
		return   # unchanged uniforms must not touch the materials: any change forces a redraw of the whole map every frame
	_params[name] = value
	for m in _mats:
		m.set_shader_parameter(name, value)


func _new_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader
	for k in _params:
		m.set_shader_parameter(k, _params[k])
	_mats.append(m)
	return m


## Grid mesh warped by the projection: x is linear, y follows Mercator; UVs are the tile's equirectangular texture coordinates.
func _make_grid_mesh(x0: float, x1: float, lat_top: float, lat_bot: float, rows: int) -> ArrayMesh:
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for r in rows + 1:
		var t := float(r) / rows
		var y := project(0.0, lerpf(lat_top, lat_bot, t)).y
		verts.append(Vector2(x0, y))
		verts.append(Vector2(x1, y))
		uvs.append(Vector2(0.0, t))
		uvs.append(Vector2(1.0, t))
	for r in rows:
		var a := r * 2
		idx.append_array(PackedInt32Array([a, a + 1, a + 2, a + 1, a + 3, a + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _load_ids(w: int, h: int) -> void:
	var ds := EarthWorld.dataset
	var ids_img: Image
	if _visual and FileAccess.file_exists("res://data/world_visual/ext_%s.bin" % ds):
		ids_img = EarthVisual.ext_image(w, h, ds)
		_ext_bytes = EarthVisual.ext_bytes(ds)
		_landf = EarthVisual.land_fraction(ds)
	else:
		ids_img = EarthWorld.ids_image()
		_ext_bytes = PackedByteArray()
		_landf = PackedByteArray()
	_set_all("ids", ImageTexture.create_from_image(ids_img))


func _build_layers(w: int, h: int) -> void:
	if _layers_built:
		_load_ids(w, h)
		return
	_layers_built = true
	_shader = load("res://game/rendering/earth_map.gdshader") as Shader
	var bottom := _top - h * _res
	var overview_img: Image = EarthVisual.overview_image() if _visual else EarthWorld.relief_image()
	if _visual:
		_tile_grid = EarthVisual.tile_grid()
	var tex := ImageTexture.create_from_image(overview_img)
	_params["use_mask"] = 1.0 if _visual else 0.0
	_params["tint"] = 0.5 if _visual else 0.62
	_overview = MeshInstance2D.new()
	_overview.mesh = _make_grid_mesh(0.0, _world_w, _top, bottom, 72)
	_overview.z_index = -3
	var m := _new_material()
	m.set_shader_parameter("relief", tex)
	m.set_shader_parameter("origin", Vector2.ZERO)
	m.set_shader_parameter("span", Vector2.ONE)
	_overview.material = m
	_overview.texture = tex
	add_child(_overview)
	_load_ids(w, h)


func _set_layers_visible(on: bool) -> void:
	if _overview != null:
		_overview.visible = on
	for k in _tiles:
		_tiles[k].visible = on


## Imagery tiles in view are decoded a couple per frame; far tiles are released (LRU), the overview always stays resident.
func _update_tiles() -> void:
	if not _visual or quality == "low":
		_want_tiles.clear()
		return
	var thr := 0.5 if quality == "high" else 1.2
	if camera.zoom.x < thr:
		_want_tiles.clear()
		return
	var tl := unproject(cull.position)
	var br := unproject(cull.end)
	var lon_span := 360.0 / _tile_grid.x
	var lat_span := (_top - (_top - float(sim.world["h"]) * _res)) / _tile_grid.y
	var c0 := clampi(int((tl.x + 180.0) / lon_span), 0, _tile_grid.x - 1)
	var c1 := clampi(int((br.x + 180.0) / lon_span), 0, _tile_grid.x - 1)
	var r0 := clampi(int((_top - tl.y) / lat_span), 0, _tile_grid.y - 1)
	var r1 := clampi(int((_top - br.y) / lat_span), 0, _tile_grid.y - 1)
	_want_tiles.clear()
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			_want_tiles.append(c * 100 + r)


func _pump_tiles() -> void:
	var loaded := 0
	for key in _want_tiles:
		if _tiles.has(key):
			_tile_lru.erase(key)
			_tile_lru.append(key)
			continue
		if loaded >= 2:
			break
		var c: int = key / 100
		var r: int = key % 100
		var img := EarthVisual.tile_image(c, r)
		if img == null:
			_tiles[key] = null
			continue
		loaded += 1
		var lon_span := 360.0 / _tile_grid.x
		var lat_span := float(sim.world["h"]) * _res / _tile_grid.y
		var node := MeshInstance2D.new()
		var x0 := _world_w / _tile_grid.x * c
		node.mesh = _make_grid_mesh(x0, x0 + _world_w / _tile_grid.x, _top - r * lat_span, _top - (r + 1) * lat_span, 36)
		node.z_index = -2
		var mat := _new_material()
		var tex := ImageTexture.create_from_image(img)
		mat.set_shader_parameter("relief", tex)
		mat.set_shader_parameter("origin", Vector2(float(c) / _tile_grid.x, float(r) / _tile_grid.y))
		mat.set_shader_parameter("span", Vector2(1.0 / _tile_grid.x, 1.0 / _tile_grid.y))
		node.material = mat
		node.texture = tex
		add_child(node)
		_tiles[key] = node
		_tile_lru.append(key)
	while _tile_lru.size() > 14:
		var old: int = _tile_lru[0]
		if _want_tiles.has(old):
			break
		_tile_lru.pop_front()
		var nd: MeshInstance2D = _tiles[old]
		if nd != null:
			_mats.erase(nd.material)
			nd.queue_free()
		_tiles.erase(old)


## Pick a cell under a world position. Uses the extended ids so coastal land is selectable, but keeps coastal sea selectable too.
func province_at(world_pos: Vector2) -> int:
	if not is_earth:
		return super.province_at(world_pos)
	var ll := unproject(world_pos)
	var w: int = int(sim.world["w"])
	var h: int = int(sim.world["h"])
	var px := int((ll.x + 180.0) / _res)
	var py := int((_top - ll.y) / _res)
	if px < 0 or py < 0 or px >= w or py >= h:
		return -1
	var i := py * w + px
	var base: int = sim.world["cell_prov"][i]
	if _ext_bytes.size() >= 2 * (i + 1):
		var e: int = _ext_bytes[2 * i] | (_ext_bytes[2 * i + 1] << 8)
		if e != 65535 and e < int(sim.world["land_count"]) and (base < 0 or base >= int(sim.world["land_count"])) and _landf[i] >= 128:
			return e
	return base


## Graphics quality (Settings / menu): sets the imagery tile level AND the drawing budget (labels, cities, roads).
func set_quality(level: int) -> void:
	detail = clampi(level, GraphicsQuality.Level.LOW, GraphicsQuality.Level.HIGH)
	quality = ["low", "medium", "high"][detail]
	_want_tiles.clear()
	queue_redraw()


func set_mode(m: String) -> void:
	if m == mode or not is_earth:
		return
	_begin_fade()
	mode = m
	_fill_palette_all()
	_upload()
	_start_fade()
	queue_redraw()


func set_cut_off(cells: Array) -> void:
	var fresh := {}
	for c in cells:
		fresh[c] = true
	var changed: Array = []
	for c in _cut:
		if not fresh.has(c):
			changed.append(c)
	for c in fresh:
		if not _cut.has(c):
			changed.append(c)
	_cut = fresh
	for c in changed:
		_write_flags(c)
	if not changed.is_empty():
		_t_b.update(_info_b)


# --------------------------------------------------------------- repainting

func repaint_all() -> void:
	if not is_earth:
		super.repaint_all()
		return
	_compute_context()
	_agg.clear()
	_ctl.fill(-1)   # forget the cached controllers, otherwise _write_info() would not rebuild the label totals
	for p in sim.provinces():
		if p["land"]:
			_write_info(p["id"])
	_fill_palette_all()
	_upload()
	queue_redraw()


func refresh(dirty: Array[int]) -> void:
	if not is_earth:
		super.refresh(dirty)
		return
	if mode == "weather" and sim.day != _weather_day and sim.day % 2 == 0:
		_weather_day = sim.day
		_fill_palette_all()
		_upload()
	if not dirty.is_empty():
		_war_pairs_rebuild()
		var touched := {}
		for c in dirty:
			touched[c] = true
			for q in sim.provinces()[c]["land_neighbors"]:
				touched[q] = true
		_begin_fade_cells(dirty)
		for c in dirty:
			_flash[c] = 1.6
		for c in touched:
			_write_info(c)
			_pal_cur.set_pixel(c % 256, c / 256, _cell_color(c))
		_upload()
		_start_fade()
	refresh_dynamic()
	queue_redraw()


## Battles and other state that changes without ownership changing.
func refresh_dynamic() -> void:
	if not is_earth or sim == null:
		return
	var seen := {}
	for a in sim.armies:
		var c: int = a["prov"]
		if not seen.has(c):
			seen[c] = a["owner"]
		elif seen[c] != a["owner"] and sim.at_war(seen[c], a["owner"]):
			seen[c] = -9
	var now := {}
	for c in seen:
		if seen[c] == -9:
			now[c] = true
	var changed: Array = []
	for c in _contested:
		if not now.has(c):
			changed.append(c)
	for c in now:
		if not _contested.has(c):
			changed.append(c)
	_contested = now
	for c in changed:
		_write_flags(c)
	if not changed.is_empty():
		_t_b.update(_info_b)


func _compute_context() -> void:
	_ccol.clear()
	for c in sim.countries:
		_ccol[c["id"]] = Color(c["color"])
	_war_pairs_rebuild()
	_rel.clear()
	if player_country >= 0 and player_country < sim.countries.size():
		for c in sim.countries:
			var o: int = c["id"]
			if o == player_country:
				_rel[o] = Color("e0c070")
			elif sim.allied(player_country, o):
				_rel[o] = Color("5fb36a")
			elif sim.at_war(player_country, o):
				_rel[o] = Color("d9534f")
			elif sim._embargoed(player_country, o):
				_rel[o] = Color("e08a3c")
			elif sim.neighbor_countries(player_country).has(o):
				_rel[o] = Color("7f8fa6")
			else:
				_rel[o] = Color("3b4656")


func _war_pairs_rebuild() -> void:
	_war_pairs.clear()
	for w in sim.wars:
		_war_pairs[int(w["a"]) * 100000 + int(w["b"])] = true
		_war_pairs[int(w["b"]) * 100000 + int(w["a"])] = true


func _country_color(cid: int) -> Color:
	if cid < 0:
		return Color(0.55, 0.55, 0.55)
	if not _ccol.has(cid) and cid < sim.countries.size():
		_ccol[cid] = Color(sim.countries[cid]["color"])
	return _ccol.get(cid, Color(0.55, 0.55, 0.55))


func _is_front(c: int) -> bool:
	var o: int = sim.owner[c]
	if o < 0:
		return false
	for q in sim.provinces()[c]["land_neighbors"]:
		var oq: int = sim.owner[q]
		if oq >= 0 and oq != o and _war_pairs.has(o * 100000 + oq):
			return true
	return false


func _write_info(c: int) -> void:
	var prov: Dictionary = sim.provinces()[c]
	var o: int = sim.owner[c]
	var old: int = _ctl[c]
	if old != o:
		if old >= 0 and _agg.has(old):
			var a: Vector3 = _agg[old]
			_agg[old] = Vector3(a.x - 1, a.y - prov["center"].x, a.z - prov["center"].y)
		if o >= 0:
			var b: Vector3 = _agg.get(o, Vector3.ZERO)
			_agg[o] = Vector3(b.x + 1, b.y + prov["center"].x, b.z + prov["center"].y)
		_ctl[c] = o
	var ctl16 := 65535 if o < 0 else o
	var reg: int = int(prov.get("region", 0))
	_info_a.set_pixel(c % 256, c / 256, Color8(ctl16 & 255, ctl16 >> 8, reg & 255, reg >> 8))
	_write_flags(c)


func _write_flags(c: int) -> void:
	var flags := 0
	if _cut.has(c):
		flags |= 1
	if _contested.has(c):
		flags |= 2
	if mode == "military" and sim.provinces()[c]["land"] and _is_front(c):
		flags |= 4
	var fl: float = _flash.get(c, 0.0)
	_info_b.set_pixel(c % 256, c / 256, Color8(0, 0, flags, int(clampf(fl / 1.6, 0.0, 1.0) * 255.0)))


func _fill_palette_all() -> void:
	for p in sim.provinces():
		var c: int = p["id"]
		_pal_cur.set_pixel(c % 256, c / 256, _cell_color(c))
		if mode == "military" or p["land"]:
			_write_flags(c)


func _upload() -> void:
	_t_cur.update(_pal_cur)
	_t_prev.update(_pal_prev)
	_t_a.update(_info_a)
	_t_b.update(_info_b)


func _begin_fade() -> void:
	_pal_prev.copy_from(_pal_cur)
	_t_prev.update(_pal_prev)
	_fade = 0.0
	_set_all("fade", 0.0)


func _begin_fade_cells(cells: Array) -> void:
	# keep every cell that is not changing exactly as it is: prev := cur for all, then only the changed cells differ
	for c in cells:
		_pal_prev.set_pixel(c % 256, c / 256, _pal_cur.get_pixel(c % 256, c / 256))
	_t_prev.update(_pal_prev)
	_fade = 0.0
	_set_all("fade", 0.0)


func _start_fade() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(func(v: float):
		_fade = v
		_set_all("fade", v), 0.0, 1.0, 0.45)
	_tween.tween_callback(func():
		_pal_prev.copy_from(_pal_cur)
		_t_prev.update(_pal_prev))


func _ramp(t: float, a: Color, b: Color) -> Color:
	return a.lerp(b, clampf(t, 0.0, 1.0))


func _cell_color(c: int) -> Color:
	var p: Dictionary = sim.provinces()[c]
	if not p["land"]:
		return Color(0, 0, 0, 0)
	var o: int = sim.owner[c]
	match mode:
		"political":
			return Color(_country_color(o), 1.0) if o >= 0 else Color(0.5, 0.5, 0.5, 0.25)
		"admin":
			var r: int = int(p.get("region", 0))
			return Color.from_hsv(float((r * 47) % 360) / 360.0, 0.45 + float((r * 13) % 5) * 0.07, 0.62 + float((r * 7) % 4) * 0.06, 0.92)
		"military":
			var col := _country_color(o)
			return Color(col, 0.55) if o >= 0 else Color(0.5, 0.5, 0.5, 0.2)
		"control":
			var lg: int = sim.legal[c]
			if lg == o:
				return Color(_country_color(lg), 0.28)
			return Color(_country_color(o), 1.0)
		"terrain":
			return Color(0, 0, 0, 0)
		"infra":
			var lvl := float(sim.eff_infra(c) - 1) / 4.0
			return Color(_ramp(lvl, Color("2c3544"), Color("f0c75e")), 0.92)
		"economy":
			var v := log(1.0 + float(p["pop"]) * float(p["industry"])) / log(1.0 + 3000.0)
			return Color(_ramp(v, Color("26352c"), Color("7ee07e")), 0.92)
		"resources":
			var best := ""
			var bv := 0
			for r2 in ["oil", "coal", "iron", "food"]:
				var dv: int = int(p["deposits"].get(r2, 0))
				if dv > bv or (r2 == "food" and bv == 0 and dv > 0):
					bv = dv
					best = r2
			if best == "":
				return Color(0, 0, 0, 0)
			var colr: Color = {"oil": Color("8a4fc0"), "coal": Color("2e2e33"), "iron": Color("c0643c"), "food": Color("6aa84f")}[best]
			return Color(colr, clampf(0.35 + bv * 0.09, 0.0, 0.95))
		"population":
			var v2 := (log(1.0 + float(p["pop_real"])) / log(10.0) - 2.5) / 5.0
			return Color(_ramp(v2, Color("233a5c"), Color("e8503c")), 0.92)
		"logistics":
			var net := float(p["road_km"]) + 2.0 * float(p["rail_km"])
			var v3 := clampf(net / maxf(float(p["area"]), 1.0) * 60.0, 0.0, 1.0)
			return Color(_ramp(v3, Color("2c3544"), Color("6ec1e4")), 0.9)
		"diplomacy":
			return Color(_rel.get(o, Color(0.5, 0.5, 0.5)), 0.9) if o >= 0 else Color(0, 0, 0, 0)
		"legal":
			return Color(_country_color(sim.legal[c]), 1.0)
		"weather":
			# winter severity (white-blue) and local storms (violet); meaningful only with the weather rule, but always shows the season
			if sim.storm_at(c) and sim.rule_weather:
				return Color("7d4fd0", 0.92)
			var w := float(sim.winter_at(c)) / 100.0
			return Color(_ramp(w, Color("5a8f4a"), Color("e8f2ff")), 0.9)
	return Color(0, 0, 0, 0)


# ------------------------------------------------------------------ frame

func _process(delta: float) -> void:
	if animate_armies(delta):
		queue_redraw()
	if _touch.long_press_due(Time.get_ticks_msec() / 1000.0) and sim != null:
		var rid := province_at(get_global_mouse_position())
		if rid >= 0:
			_dragging = false
			province_right_clicked.emit(rid, _touch.press_position())
	_smooth_zoom(delta)
	if not is_earth or sim == null:
		return
	var cam := camera.get_screen_center_position()
	var key := Vector3(cam.x, cam.y, camera.zoom.x)
	if key != _last_cam:
		_last_cam = key
		var vp := get_viewport_rect().size
		var half := vp / (2.0 * camera.zoom.x)
		cull = Rect2(cam - half - Vector2(80, 80), half * 2.0 + Vector2(160, 160))
		lod_compact = camera.zoom.x < 0.45
		ui_scale = clampf(1.0 / camera.zoom.x, 0.3, 12.0)
		_update_tiles()
		queue_redraw()
	_set_all("zoom", camera.zoom.x)
	# animated uniforms change at 10 Hz (not every frame): with the low-processor mode of phones the map then only redraws when needed
	_fx_t += delta
	if _fx_t >= 0.1:
		_fx_t = 0.0
		if sim != null and (not _war_pairs.is_empty() or not _flash.is_empty()):   # the pulse only matters on contested cells
			_set_all("pulse", 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) / 220.0))
		# the water shimmer is a TIME-based animation: only on the High profile, never on battery-saving phones' default (Medium)
		_set_all("water_fx", 1.0 if (detail == GraphicsQuality.Level.HIGH and not GameSettings.reduce_motion()) else 0.0)
	if selected_province != _sel_cached:
		_sel_cached = selected_province
		_set_all("sel_id", selected_province)
	var hid := province_at(get_global_mouse_position())
	if hid != _hover:
		_hover = hid
		_set_all("hover_id", hid)
	if not _flash.is_empty():
		var done: Array = []
		for c in _flash:
			_flash[c] -= delta
			if _flash[c] <= 0.0:
				done.append(c)
			_write_flags(c)
		for c in done:
			_flash.erase(c)
			_write_flags(c)
		_t_b.update(_info_b)
	if _prep_thread != null and not _prep_thread.is_alive():
		_prep_thread.wait_to_finish()
		_prep_thread = null
		_data_ready = true
		queue_redraw()
	_pump_tiles()
	_pump_vector_build()


# ------------------------------------------------------------ background preload

## Settlements (70k), road/rail polylines and the chunk index are prepared on a worker thread so the first frames never stall.
func _begin_preload() -> void:
	if _preload_started:
		return
	_preload_started = true
	_prep_thread = Thread.new()
	_prep_thread.start(_preload_work)


func _preload_work() -> void:
	EarthWorld.ensure_settlements()
	EarthWorld.lines()
	if EarthVisual.available():
		EarthVisual.vectors()
	# per chunk: capitals first, then the rest by falling population (ids are already ordered by population),
	# so the draw loop can stop at the first small non-capital instead of scanning every village
	var caps_c := {}
	var rest_c := {}
	for i in EarthWorld.S_POP.size():
		var key := int((EarthWorld.S_LON[i] + 180.0) / CHUNK_DEG) + CHUNK_COLS * int((_top - EarthWorld.S_LAT[i]) / CHUNK_DEG)
		var dst: Dictionary = caps_c if EarthWorld.S_CAP[i] == 1 else rest_c
		if not dst.has(key):
			dst[key] = PackedInt32Array()
		var arr: PackedInt32Array = dst[key]
		arr.append(i)
		dst[key] = arr
	for key in rest_c:
		_sett_chunks[key] = (caps_c[key] + rest_c[key]) if caps_c.has(key) else rest_c[key]
	for key in caps_c:
		if not _sett_chunks.has(key):
			_sett_chunks[key] = caps_c[key]


func _exit_tree() -> void:
	if _prep_thread != null and _prep_thread.is_started():
		_prep_thread.wait_to_finish()


# ---------------------------------------------------------- vector layers

func _start_vectors() -> void:
	_vectors_started = true
	var lines := EarthWorld.lines()
	for layer in ["rivers", "roads", "rails", "border1", "border0", "coast", "lakes"]:
		_chunks[layer] = {}
	var vis: Dictionary = EarthVisual.vectors() if _visual else {}
	if not vis.is_empty():
		# fine Natural Earth 10m geometry (coast, lakes, borders, rivers) from the visual layer
		for ring in vis.get("coast", []):
			_queue.append(["coast", ring])
		for ring in vis.get("lakes", []):
			_queue.append(["lakes", ring])
		for ring in vis.get("border0", []):
			_queue.append(["border0", ring])
		for ring in vis.get("border1", []):
			_queue.append(["border1", ring])
		for l in vis.get("rivers", []):
			if float(l[0]) <= 8.0:
				_queue.append(["rivers", l.slice(1)])
	else:
		for ring in lines.get("border0", []):
			_queue.append(["border0", ring[1]])
		for ring in lines.get("border1", []):
			_queue.append(["border1", ring[1]])
		for l in lines.get("rivers", []):
			_queue.append(["rivers", l])
	for l in lines.get("roads", []):
		_queue.append(["roads", l])
	for l in lines.get("rails", []):
		_queue.append(["rails", l])


func _pump_vector_build() -> void:
	if not _data_ready:
		return
	if not _vectors_started:
		_start_vectors()
		return
	if _qpos >= _queue.size():
		return
	var end := mini(_qpos + BUILD_BUDGET, _queue.size())
	while _qpos < end:
		var item: Array = _queue[_qpos]
		_qpos += 1
		var layer: String = item[0]
		var pts: Array = item[1]
		var store: Dictionary = _chunks[layer]
		for i in range(pts.size() - 1):
			var a: Array = pts[i]
			var b: Array = pts[i + 1]
			if absf(float(a[0]) - float(b[0])) > 180.0:
				continue
			var mx := (float(a[0]) + float(b[0])) * 0.5
			var my := (float(a[1]) + float(b[1])) * 0.5
			var key := int((mx + 180.0) / CHUNK_DEG) + CHUNK_COLS * int((_top - my) / CHUNK_DEG)
			if not store.has(key):
				store[key] = PackedVector2Array()
			var arr: PackedVector2Array = store[key]
			arr.append(project(float(a[0]), float(a[1])))
			arr.append(project(float(b[0]), float(b[1])))
			store[key] = arr
	if _qpos >= _queue.size():
		_queue.clear()
		_qpos = 0
		_vec_done = true
		EarthWorld.release_lines()   # ~70 MB of parsed Variants are no longer needed
		EarthVisual.release_vectors()
		queue_redraw()


func _visible_chunk_keys() -> Array:
	var tl := unproject(cull.position)
	var br := unproject(cull.end)
	var c0 := clampi(int((tl.x + 180.0) / CHUNK_DEG), 0, CHUNK_COLS - 1)
	var c1 := clampi(int((br.x + 180.0) / CHUNK_DEG), 0, CHUNK_COLS - 1)
	var r0 := clampi(int((_top - tl.y) / CHUNK_DEG), 0, 9)
	var r1 := clampi(int((_top - br.y) / CHUNK_DEG), 0, 9)
	var keys: Array = []
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			keys.append(c + CHUNK_COLS * r)
	return keys


func _chunk_mesh(layer: String, key: int) -> ArrayMesh:
	var id := "%s:%d" % [layer, key]
	if _meshes.has(id):
		return _meshes[id]
	var mesh: ArrayMesh = null
	if _chunks.has(layer) and _chunks[layer].has(key):
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = _chunks[layer][key]
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		_chunks[layer].erase(key)   # the mesh owns the data now
	_meshes[id] = mesh
	return mesh


## Lines are drawn as GPU meshes once the layer is fully built (1 px wide at any zoom); while building, fall back to immediate lines.
func _draw_layer(layer: String, keys: Array, color: Color, width_px: float) -> void:
	if not _chunks.has(layer):
		return
	if _vec_done:
		for k in keys:
			var m := _chunk_mesh(layer, k)
			if m != null:
				draw_mesh(m, null, Transform2D.IDENTITY, color)
		return
	var w := width_px / camera.zoom.x
	for k in keys:
		if _chunks[layer].has(k):
			draw_multiline(_chunks[layer][k], color, w)


func _draw_base() -> void:
	if not is_earth:
		super._draw_base()
		return
	var z := camera.zoom.x
	var keys := _visible_chunk_keys()
	if show_lines:
		if z >= 0.5:
			_draw_layer("rivers", keys, Color(0.35, 0.62, 0.92, 0.85), 1.0)
		if z >= 1.5:
			_draw_layer("lakes", keys, Color(0.25, 0.5, 0.8, 0.8), 1.0)
		if z >= 0.9:
			_draw_layer("coast", keys, Color(0.04, 0.07, 0.12, 0.55), 1.0)
		if z >= 0.15:
			_draw_layer("border0", keys, Color(1, 1, 1, 0.45 if mode != "legal" else 0.8), 1.0)
		if z >= 1.1 and (mode == "admin" or z >= 2.0):
			_draw_layer("border1", keys, Color(1, 1, 1, 0.26), 0.8)
		if z >= GraphicsQuality.params(detail)["roads_zoom"] or mode == "logistics" or mode == "infra":
			if z >= 0.8:
				_draw_layer("roads", keys, Color(0.95, 0.85, 0.55, 0.55 if mode != "logistics" else 0.9), 0.8)
				_draw_layer("rails", keys, Color(0.08, 0.08, 0.1, 0.6), 0.9)
	if show_settlements:
		_draw_settlements(z)
	if z >= 2.2:
		_draw_facilities(z)


func _pop_threshold(z: float) -> int:
	if z < 0.2:
		return 8000000
	if z < 0.35:
		return 3000000
	if z < 0.6:
		return 1000000
	if z < 1.0:
		return 400000
	if z < 1.8:
		return 150000
	if z < 3.2:
		return 40000
	if z < 6.0:
		return 12000
	if z < 9.0:
		return 3000
	if z < 14.0:
		return 800
	return 0


func _draw_settlements(z: float) -> void:
	if not _data_ready:
		return
	var qp := GraphicsQuality.params(detail)
	var thr := int(_pop_threshold(z) * qp["pop_scale"])
	var font := UiFont.regular()
	var r := 2.4 / z
	var halo := 0.9 / z
	# three size classes by population so dense regions read as a hierarchy instead of a white smear
	var dots: Array = [PackedVector2Array(), PackedVector2Array(), PackedVector2Array()]
	var dots_halo: Array = [PackedVector2Array(), PackedVector2Array(), PackedVector2Array()]
	var radii := [1.5 / z, 2.1 / z, 2.9 / z]
	var caps: Array = []
	var jobs: Array = []   # [position, settlement id, is capital]
	for k in _visible_chunk_keys():
		if not _sett_chunks.has(k):
			continue
		for i in _sett_chunks[k]:
			var pop: int = EarthWorld.S_POP[i]
			var cap: bool = EarthWorld.S_CAP[i] == 1
			if pop < thr:
				if not cap:
					break   # non-capitals are sorted by population: everything after is smaller
				if z < 0.25:
					continue
			var pos := world_pos_of(EarthWorld.S_LON[i], EarthWorld.S_LAT[i])
			if not cull.has_point(pos):
				continue
			if cap:
				caps.append(pos)
			else:
				var cls := 0 if pop < 60000 else (1 if pop < 600000 else 2)
				var rr: float = radii[cls]
				dots_halo[cls].append(pos - Vector2(rr + halo, 0))
				dots_halo[cls].append(pos + Vector2(rr + halo, 0))
				dots[cls].append(pos - Vector2(rr, 0))
				dots[cls].append(pos + Vector2(rr, 0))
			if z > 0.45 and (pop >= thr * 2 or z > 3.0 or cap):
				jobs.append([pos, i, cap])
	# one batched call per layer instead of thousands of circle draws
	for cls in 3:
		if not dots[cls].is_empty():
			draw_multiline(dots_halo[cls], Color(0.03, 0.04, 0.06, 0.85), 2.0 * (radii[cls] + halo))
			draw_multiline(dots[cls], Color(1, 1, 1, 0.95), 2.0 * radii[cls])
	for pos in caps:
		var d := r * 1.7
		if d < 0.5:   # at extreme zoom the diamond collapses and the triangulator rejects it
			draw_circle(pos, maxf(d, 0.05), Color("f0c75e"))
		else:
			draw_colored_polygon(PackedVector2Array([pos + Vector2(0, -d), pos + Vector2(d, 0), pos + Vector2(0, d), pos + Vector2(-d, 0)]), Color("f0c75e"))
	var labels := 0
	var taken := {}   # coarse screen-space grid of used label slots (keeps text readable)
	for job in jobs:
		if labels >= qp["labels"]:
			break
		var pos2: Vector2 = job[0]
		var gk := Vector2i(int(pos2.x * z / 90.0), int(pos2.y * z / 16.0))
		if taken.has(gk) or taken.has(gk + Vector2i(1, 0)):
			continue
		taken[gk] = true
		_text(font, pos2 + Vector2(r * 1.8, r * 0.6), EarthWorld.display_name(job[1]), 13 if job[2] else 12, Color("ffe9a8") if job[2] else Color(1, 1, 1, 0.95), 0.0)
		labels += 1


func _draw_facilities(z: float) -> void:
	var fac := EarthWorld.facilities()
	var r := 3.2 / z
	for p in fac.get("ports", []):
		var pos := world_pos_of(float(p["lon"]), float(p["lat"]))
		if cull.has_point(pos):
			draw_rect(Rect2(pos - Vector2(r, r), Vector2(r * 2, r * 2)), Color("4aa3df"))
			draw_rect(Rect2(pos - Vector2(r, r), Vector2(r * 2, r * 2)), Color(0, 0, 0, 0.8), false, 0.8 / z)
	for a in fac.get("airports", []):
		var pos2 := world_pos_of(float(a["lon"]), float(a["lat"]))
		if cull.has_point(pos2):
			if r < 0.5:
				draw_circle(pos2, maxf(r, 0.05), Color("e8e8ee"))
			else:
				draw_colored_polygon(PackedVector2Array([pos2 + Vector2(0, -r * 1.3), pos2 + Vector2(r * 1.2, r), pos2 + Vector2(-r * 1.2, r)]), Color("e8e8ee"))


## Region (admin-1) centroids in simulation-raster pixels, weighted by cell area; built once per dataset.
var _region_info: Array = []   # [{id, pos(Vector2 px), pixels}]
var _region_ds := ""


func _build_region_info() -> void:
	_region_ds = str(sim.world.get("dataset", ""))
	var sums := {}
	for p in sim.provinces():
		if not p["land"] or int(p["region"]) <= 0:
			continue
		var w: float = p["cell_count"]
		var a: Vector3 = sums.get(p["region"], Vector3.ZERO)
		sums[p["region"]] = Vector3(a.x + w, a.y + p["center"].x * w, a.z + p["center"].y * w)
	_region_info = []
	for rid in sums:
		var a2: Vector3 = sums[rid]
		var r: Dictionary = sim.world["regions"][int(rid) - 1]
		if r.get("kind") == "country":
			continue   # countries without admin-1 data are labelled as countries
		_region_info.append({"id": int(rid), "pos": Vector2(a2.y / a2.x, a2.z / a2.x), "pixels": a2.x})
	_region_info.sort_custom(func(a, b): return a["pixels"] > b["pixels"])


## Names of administrative regions, shown from mid zoom; only regions big enough on screen to hold their name, biggest first.
func _draw_region_labels(z: float, font: Font) -> void:
	if z < 1.5:
		return
	if _region_ds != str(sim.world.get("dataset", "")):
		_build_region_info()
	var res := float(sim.world.get("res", 0.2))
	var alpha := clampf((z - 1.5) / 1.0, 0.0, 1.0) * 0.85
	var taken := {}
	var shown := 0
	for ri in _region_info:
		if shown >= int(GraphicsQuality.params(detail)["labels"] * 0.75) or detail == GraphicsQuality.Level.LOW:
			break
		var pos := px_to_world(ri["pos"])
		if not cull.has_point(pos):
			continue
		var extent_px := sqrt(ri["pixels"]) * res * (_world_w / 360.0) * z
		var nm := EarthWorld.region_name(sim.world, ri["id"])
		var px := int(clampf(10.0 + extent_px / 90.0, 10.0, 15.0))
		var tw := font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
		if extent_px < tw * 0.9:
			continue
		var gk := Vector2i(int(pos.x * z / 110.0), int(pos.y * z / 18.0))
		if taken.has(gk):
			continue
		taken[gk] = true
		_text(font, pos, nm, px, Color(0.93, 0.95, 1.0, alpha), -tw * 0.5)
		shown += 1


## Recent missile launches: a trail from the launch site to the target and an expanding ring (red = hit, blue = intercepted).
func _draw_strikes(z: float) -> void:
	for s in sim.strikes:
		var age: int = sim.day - int(s["day"])
		if age < 0 or age > 8:
			continue
		var fade := 1.0 - float(age) / 9.0
		var a := cell_world(int(s["from"]))
		var b := cell_world(int(s["target"]))
		var col := Color(1.0, 0.45, 0.2, fade) if s["hit"] else Color(0.55, 0.78, 1.0, fade)
		if not (cull.has_point(a) or cull.has_point(b) or cull.grow(200.0).intersects(Rect2(a, b - a).abs())):
			continue
		var head := a.lerp(b, minf(1.0, 0.35 + 0.2 * age))
		draw_line(a, head, Color(col, fade * 0.8), 2.2 / z)
		draw_circle(head, 3.0 / z, col)
		var ring := (6.0 + 5.0 * age) / z
		draw_arc(b, ring, 0.0, TAU, 28, col, 2.0 / z)
		if s["hit"]:
			draw_circle(b, 3.5 / z, Color(1.0, 0.85, 0.3, fade))


## Air-defence batteries and launch sites as small round markers (visible from mid zoom): own ones, and foreign ones the player can see.
func _draw_sites(z: float) -> void:
	if z < 1.0 or sim.sites.is_empty():
		return
	var r := 7.0 / z
	for st in sim.sites:
		var mine: bool = st["owner"] == player_country
		if not mine and (player_country < 0 or not sim.site_visible(player_country, st)):
			continue   # foreign objects show only when the intelligence picture allows it
		var pos := cell_world(int(st["cell"]))
		if not cull.has_point(pos):
			continue
		var dmg: int = sim.damage[int(st["cell"])]
		var col := Color(0.55, 0.85, 1.0) if st["kind"] == "ad" else Color(1.0, 0.75, 0.35)
		if not mine:
			col = Color(0.95, 0.4, 0.35)
		if dmg >= 80:
			col = Color(0.5, 0.5, 0.5)
		pos += Vector2(r * 1.6, -r * 1.6)
		draw_circle(pos, r * 1.25, Color(0.04, 0.06, 0.09, 0.9))
		draw_arc(pos, r * 1.25, 0.0, TAU, 20, col, 1.4 / z)
		Icons.draw(self, "satellite" if st["kind"] == "ad" else "missile", Rect2(pos - Vector2(r, r), Vector2(r, r) * 2.0), col, 1.3 / z)


func _draw_labels() -> void:
	if not is_earth:
		super._draw_labels()
		return
	var z := camera.zoom.x
	if sim.rule_modern:
		_draw_sites(z)
		if not sim.strikes.is_empty():
			_draw_strikes(z)
	_draw_region_labels(z, UiFont.regular())
	var font := UiFont.bold()
	for l in label_layout():
		_text(font, l["pos"], l["name"], l["px"], Color(1, 1, 1, 0.92), -l["width"] * 0.5)


## Country labels that fit the current zoom: biggest countries first, a label is skipped when it would overlap one already
## placed (screen-space rectangles). A country whose centre of mass is not on its own land (overseas territories: France ends
## up in the Atlantic) is labelled at its capital. Each entry: cid, name, pos (world), px (font size), width, box (screen px).
func label_layout() -> Array:
	var out: Array = []
	var z := camera.zoom.x
	if z > 5.0 or sim == null:
		return out
	var font := UiFont.bold()
	var order: Array = _agg.keys()
	order.sort_custom(func(x, y): return _agg[x].x > _agg[y].x or (_agg[x].x == _agg[y].x and x < y))
	var placed: Array[Rect2] = []
	for cid in order:
		var a: Vector3 = _agg[cid]
		if a.x < 1.0:
			continue
		var pos := px_to_world(Vector2(a.y / a.x, a.z / a.x))
		var under := province_at(pos)
		if under < 0 or sim.owner[under] != cid:
			var cap: int = sim.countries[cid]["capital"]
			if cap >= 0 and sim.owner[cap] == cid:
				pos = px_to_world(sim.provinces()[cap]["center"])
		if not cull.has_point(pos):
			continue
		var fs_px := clampf(9.0 + sqrt(a.x) * 0.9, 9.0, 26.0)
		var nm: String = sim.countries[cid]["name"]
		var width_px := fs_px * 0.55 * nm.length()
		var extent_px := sqrt(a.x) * 20.0 * z
		if extent_px < width_px * 0.8:
			continue
		var px := int(fs_px)
		var tw := font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
		var rect := Rect2(pos * z + Vector2(-tw * 0.5 - 4.0, -px * 0.7), Vector2(tw + 8.0, px * 1.25))
		var clash := false
		for r in placed:
			if r.intersects(rect):
				clash = true
				break
		if clash:
			continue
		placed.append(rect)
		out.append({"cid": cid, "name": nm, "pos": pos, "px": px, "width": tw, "box": rect})
	return out


## Text in true screen-pixel size: glyphs are rasterised at `px` and the camera zoom is cancelled, so labels stay sharp at any zoom.
func _text(font: Font, pos: Vector2, text: String, px: int, col: Color, x_offset: float) -> void:
	draw_set_transform(pos, 0.0, Vector2.ONE / camera.zoom.x)
	var at := Vector2(x_offset, px * 0.35)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, 4, Color(0, 0, 0, 0.8))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Fly the camera to a world position (longitude/latitude).
func focus_lonlat(lon: float, lat: float, zoom_level: float = 4.0) -> void:
	camera.position = world_pos_of(lon, lat)
	camera.zoom = Vector2.ONE * clampf(zoom_level, min_zoom, max_zoom)


func focus_lonlat_cell(cell: int, zoom_level: float = 2.0) -> void:
	camera.position = cell_world(cell)
	camera.zoom = Vector2.ONE * clampf(zoom_level, min_zoom, max_zoom)
