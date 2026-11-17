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
]
const CHUNK_DEG := 15.0
const CHUNK_COLS := 24
const BUILD_BUDGET := 2500   # polylines turned into chunked segments per frame

var mode := "political"
var is_earth := false
var show_settlements := true
var show_lines := true

var _sprite: Sprite2D
var _mat: ShaderMaterial
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
		if _sprite != null:
			_sprite.visible = false
		super.bind(sim_)
		return
	sim = sim_
	is_earth = true
	min_zoom = 0.08
	max_zoom = 16.0
	var w: int = int(sim.world["w"])
	var h: int = int(sim.world["h"])
	if _sprite == null:
		_sprite = Sprite2D.new()
		_sprite.centered = false
		_sprite.z_index = -1
		var shader := load("res://game/rendering/earth_map.gdshader") as Shader
		_mat = ShaderMaterial.new()
		_mat.shader = shader
		_sprite.material = _mat
		add_child(_sprite)
		_sprite.texture = ImageTexture.create_from_image(EarthWorld.relief_image())
		_mat.set_shader_parameter("relief", _sprite.texture)
		_mat.set_shader_parameter("ids", ImageTexture.create_from_image(EarthWorld.ids_image()))
	_res = float(sim.world["res"])
	_top = float(sim.world["lat_top"])
	_begin_preload()
	_sprite.visible = true
	_sprite.scale = Vector2(CELL, CELL)
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
	_mat.set_shader_parameter("pal_cur", _t_cur)
	_mat.set_shader_parameter("pal_prev", _t_prev)
	_mat.set_shader_parameter("info_a", _t_a)
	_mat.set_shader_parameter("info_b", _t_b)
	_mat.set_shader_parameter("pal_size", Vector2(256.0, float(rows)))
	_mat.set_shader_parameter("fade", 1.0)
	camera.position = Vector2(w, h) * CELL * 0.5
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2.ZERO
	if vp.x < 1.0 or vp.y < 1.0:
		vp = Vector2(1600, 900)
	camera.zoom = Vector2.ONE * minf(vp.x / (w * CELL), vp.y / (h * CELL)) * 1.0
	_ctl = PackedInt32Array()
	_ctl.resize(n)
	_ctl.fill(-2)
	_flash.clear()
	_contested.clear()
	_cut.clear()
	_last_cam = Vector3(-1, -1, -1)
	repaint_all()


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
	_mat.set_shader_parameter("fade", 0.0)


func _begin_fade_cells(cells: Array) -> void:
	# keep every cell that is not changing exactly as it is: prev := cur for all, then only the changed cells differ
	for c in cells:
		_pal_prev.set_pixel(c % 256, c / 256, _pal_cur.get_pixel(c % 256, c / 256))
	_t_prev.update(_pal_prev)
	_fade = 0.0
	_mat.set_shader_parameter("fade", 0.0)


func _start_fade() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(func(v: float):
		_fade = v
		_mat.set_shader_parameter("fade", v), 0.0, 1.0, 0.45)
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
	return Color(0, 0, 0, 0)


# ------------------------------------------------------------------ frame

func _process(delta: float) -> void:
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
		queue_redraw()
	_mat.set_shader_parameter("zoom", camera.zoom.x)
	_mat.set_shader_parameter("pulse", 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) / 220.0))
	if selected_province != _sel_cached:
		_sel_cached = selected_province
		_mat.set_shader_parameter("sel_id", selected_province)
	var hid := province_at(get_global_mouse_position())
	if hid != _hover:
		_hover = hid
		_mat.set_shader_parameter("hover_id", hid)
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
	for i in EarthWorld.S_POP.size():
		var key := int((EarthWorld.S_LON[i] + 180.0) / CHUNK_DEG) + CHUNK_COLS * int((_top - EarthWorld.S_LAT[i]) / CHUNK_DEG)
		if not _sett_chunks.has(key):
			_sett_chunks[key] = PackedInt32Array()
		var arr: PackedInt32Array = _sett_chunks[key]
		arr.append(i)
		_sett_chunks[key] = arr


func _exit_tree() -> void:
	if _prep_thread != null and _prep_thread.is_started():
		_prep_thread.wait_to_finish()


# ---------------------------------------------------------- vector layers

func _start_vectors() -> void:
	_vectors_started = true
	var lines := EarthWorld.lines()
	for layer in ["rivers", "roads", "rails", "border1", "border0"]:
		_chunks[layer] = {}
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
			arr.append(Vector2((float(a[0]) + 180.0) / _res * CELL, (_top - float(a[1])) / _res * CELL))
			arr.append(Vector2((float(b[0]) + 180.0) / _res * CELL, (_top - float(b[1])) / _res * CELL))
			store[key] = arr
	if _qpos >= _queue.size():
		_queue.clear()
		_qpos = 0
		_vec_done = true
		EarthWorld.release_lines()   # ~70 MB of parsed Variants are no longer needed
		queue_redraw()


func _visible_chunk_keys() -> Array:
	var res: float = float(sim.world["res"])
	var top: float = float(sim.world["lat_top"])
	var lon0 := cull.position.x / CELL * res - 180.0
	var lon1 := cull.end.x / CELL * res - 180.0
	var lat1 := top - cull.position.y / CELL * res
	var lat0 := top - cull.end.y / CELL * res
	var c0 := clampi(int((lon0 + 180.0) / CHUNK_DEG), 0, CHUNK_COLS - 1)
	var c1 := clampi(int((lon1 + 180.0) / CHUNK_DEG), 0, CHUNK_COLS - 1)
	var r0 := clampi(int((top - lat1) / CHUNK_DEG), 0, 9)
	var r1 := clampi(int((top - lat0) / CHUNK_DEG), 0, 9)
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
		if z >= 0.7:
			_draw_layer("rivers", keys, Color(0.45, 0.7, 0.95, 0.75), 1.0)
		if z >= 0.18:
			_draw_layer("border0", keys, Color(1, 1, 1, 0.35 if mode != "legal" else 0.7), 1.0)
		if z >= 1.1 and (mode == "admin" or z >= 2.0):
			_draw_layer("border1", keys, Color(1, 1, 1, 0.22), 0.8)
		if z >= 1.6 or mode == "logistics" or mode == "infra":
			if z >= 0.8:
				_draw_layer("roads", keys, Color(0.95, 0.85, 0.55, 0.5 if mode != "logistics" else 0.85), 0.8)
				_draw_layer("rails", keys, Color(0.08, 0.08, 0.1, 0.55), 0.9)
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
	return 0


func world_pos_of(lon: float, lat: float) -> Vector2:
	var res: float = float(sim.world["res"])
	return Vector2((lon + 180.0) / res * CELL, (float(sim.world["lat_top"]) - lat) / res * CELL)


func _draw_settlements(z: float) -> void:
	if not _data_ready:
		return
	var thr := _pop_threshold(z)
	var font := UiFont.regular()
	var r := 2.4 / z
	var halo := 0.9 / z
	var dots := PackedVector2Array()
	var dots_halo := PackedVector2Array()
	var caps: Array = []
	var jobs: Array = []   # [position, settlement id, is capital]
	for k in _visible_chunk_keys():
		if not _sett_chunks.has(k):
			continue
		for i in _sett_chunks[k]:
			var pop: int = EarthWorld.S_POP[i]
			var cap: bool = EarthWorld.S_CAP[i] == 1
			if pop < thr and not (cap and z >= 0.25):
				continue
			var pos := world_pos_of(EarthWorld.S_LON[i], EarthWorld.S_LAT[i])
			if not cull.has_point(pos):
				continue
			if cap:
				caps.append(pos)
			else:
				dots_halo.append(pos - Vector2(r + halo, 0))
				dots_halo.append(pos + Vector2(r + halo, 0))
				dots.append(pos - Vector2(r, 0))
				dots.append(pos + Vector2(r, 0))
			if z > 0.45 and (pop >= thr * 2 or z > 3.0 or cap):
				jobs.append([pos, i, cap])
	# one batched call per layer instead of thousands of circle draws
	if not dots.is_empty():
		draw_multiline(dots_halo, Color(0.03, 0.04, 0.06, 0.9), 2.0 * (r + halo))
		draw_multiline(dots, Color(1, 1, 1, 0.95), 2.0 * r)
	for pos in caps:
		var d := r * 1.7
		draw_colored_polygon(PackedVector2Array([pos + Vector2(0, -d), pos + Vector2(d, 0), pos + Vector2(0, d), pos + Vector2(-d, 0)]), Color("f0c75e"))
	var labels := 0
	var taken := {}   # coarse screen-space grid of used label slots (keeps text readable)
	for job in jobs:
		if labels >= 220:
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
			draw_colored_polygon(PackedVector2Array([pos2 + Vector2(0, -r * 1.3), pos2 + Vector2(r * 1.2, r), pos2 + Vector2(-r * 1.2, r)]), Color("e8e8ee"))


func _draw_labels() -> void:
	if not is_earth:
		super._draw_labels()
		return
	var z := camera.zoom.x
	if z > 5.0:
		return
	var font := UiFont.bold()
	for cid in _agg:
		var a: Vector3 = _agg[cid]
		if a.x < 1.0:
			continue
		var pos := Vector2(a.y / a.x, a.z / a.x) * CELL
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
		_text(font, pos, nm, px, Color(1, 1, 1, 0.92), -tw * 0.5)


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
	camera.position = sim.provinces()[cell]["center"] * CELL
	camera.zoom = Vector2.ONE * clampf(zoom_level, min_zoom, max_zoom)
