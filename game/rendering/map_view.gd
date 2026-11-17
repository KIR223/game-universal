class_name MapView
extends Node2D
## Renders the world: shaded relief texture, owner tint, borders, armies, labels.
## Pure view: reads Simulation, never mutates it. Camera: drag / wheel / trackpad.

signal province_clicked(province_id: int)
signal province_right_clicked(province_id: int, screen_pos: Vector2)

const CELL := 4.0
const MIN_ZOOM := 0.5
const TERRAIN_COLORS := {
	"plains": Color("7c9a58"), "forest": Color("4d7040"), "mountain": Color("8b8478"),
	"desert": Color("c4a96a"), "hills": Color("8f9561"),
}

var sim: Simulation
var camera := Camera2D.new()
var selected_province := -1
var selected_army := -1
var selected_fleet := -1
var selected_wing := -1
var player_country := -1
var min_zoom := 0.5
var max_zoom := 6.0
var cull := Rect2(-1e9, -1e9, 2e9, 2e9)   # world-space rectangle that is actually visible (units outside are skipped)
var lod_compact := false                    # far zoom: draw units as small markers without text
var ui_scale := 1.0                         # world units per screen pixel (markers keep a constant on-screen size)
var map_mode := "political"  # political | terrain

var _image: Image
var _texture: ImageTexture
var _border_country := PackedVector2Array()
var _border_prov := PackedVector2Array()
var _labels: Array = []
var _drag_start := Vector2.ZERO
var _rc_start := Vector2.ZERO
var _dragging := false
var _touch := TouchGestures.new()
var _drag_moved := false
var _press_ms := 0


func _ready() -> void:
	add_child(camera)
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 14.0
	camera.make_current()


## World-space position of a cell (the legacy map is a plain grid; the Earth view projects longitude/latitude).
func cell_world(p: int) -> Vector2:
	return sim.provinces()[p]["center"] * CELL


func world_size() -> Vector2:
	return Vector2(sim.world["w"], sim.world["h"]) * CELL


func set_active(on: bool) -> void:
	visible = on
	camera.enabled = on
	set_process_unhandled_input(on)
	if on and camera.is_inside_tree():
		camera.make_current()


func bind(sim_: Simulation) -> void:
	sim = sim_
	var w: int = sim.world["w"]
	var h: int = sim.world["h"]
	_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	camera.position = Vector2(w, h) * CELL * 0.5
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2.ZERO
	if vp.x < 1.0 or vp.y < 1.0:
		vp = Vector2(1600, 900)
	camera.zoom = Vector2.ONE * minf(vp.x / (w * CELL), vp.y / (h * CELL)) * 0.95
	repaint_all()


func repaint_all() -> void:
	if sim == null:
		return
	var n: int = sim.provinces().size()
	for p in n:
		_paint_province(p)
	_texture.update(_image)
	_rebuild_overlays()
	queue_redraw()


func refresh(dirty: Array[int]) -> void:
	for p in dirty:
		_paint_province(p)
	if not dirty.is_empty():
		_texture.update(_image)
		_rebuild_overlays()
	queue_redraw()


func _paint_province(p: int) -> void:
	var w: int = sim.world["w"]
	var elev: PackedFloat32Array = sim.world["elev"]
	var cells: PackedInt32Array = sim.world["prov_cells"][p]
	var prov: Dictionary = sim.provinces()[p]
	var o := sim.owner[p]
	var tint := Color.TRANSPARENT
	if o >= 0 and map_mode == "political":
		tint = Color(sim.countries[o]["color"])
	for c in cells:
		var e := elev[c]
		var col: Color
		if not prov["land"]:
			var depth := clampf((WorldGen.LAND_THRESHOLD - e) * 1.6, 0.0, 1.0)
			col = Color("2f5f86").lerp(Color("0e2a45"), depth)
		else:
			col = TERRAIN_COLORS[prov["terrain"]]
			col = col.lerp(Color.WHITE, clampf((e - 0.3) * 0.8, 0.0, 0.4))
			if tint.a > 0.0:
				col = col.lerp(tint, 0.58)
			# cheap hillshade from the north-west neighbour
			var x := c % w
			var y := c / w
			if x > 0 and y > 0:
				var d := e - elev[c - w - 1]
				col = col.lightened(clampf(d * 2.5, -0.2, 0.2)) if d > 0 else col.darkened(clampf(-d * 2.5, 0.0, 0.2))
		_image.set_pixel(c % w, c / w, col)


func _rebuild_overlays() -> void:
	var w: int = sim.world["w"]
	var h: int = sim.world["h"]
	var cp: PackedInt32Array = sim.world["cell_prov"]
	var provs := sim.provinces()
	_border_country.clear()
	_border_prov.clear()
	for y in h:
		for x in w:
			var a := cp[y * w + x]
			if x + 1 < w:
				_edge(a, cp[y * w + x + 1], Vector2(x + 1, y), Vector2(x + 1, y + 1), provs)
			if y + 1 < h:
				_edge(a, cp[(y + 1) * w + x], Vector2(x, y + 1), Vector2(x + 1, y + 1), provs)
	# country labels at the centroid of their provinces
	_labels.clear()
	for c in sim.countries:
		if not c["alive"]:
			continue
		var sum := Vector2.ZERO
		var cnt := 0
		for p in sim.country_provinces(c["id"]):
			sum += provs[p]["center"]
			cnt += 1
		if cnt > 0:
			_labels.append({"name": c["name"], "pos": sum / cnt * CELL, "size": 12 + mini(cnt, 20)})


func _edge(a: int, b: int, p0: Vector2, p1: Vector2, provs: Array) -> void:
	if a == b:
		return
	var la: bool = provs[a]["land"]
	var lb: bool = provs[b]["land"]
	if la != lb:
		return
	if not la:
		return
	if sim.owner[a] != sim.owner[b]:
		_border_country.append(p0 * CELL)
		_border_country.append(p1 * CELL)
	else:
		_border_prov.append(p0 * CELL)
		_border_prov.append(p1 * CELL)


func _draw() -> void:
	if sim == null:
		return
	_draw_base()
	_draw_units()
	_draw_labels()


func _draw_base() -> void:
	var size_px := Vector2(sim.world["w"], sim.world["h"]) * CELL
	draw_texture_rect(_texture, Rect2(Vector2.ZERO, size_px), false)
	if not _border_prov.is_empty():
		draw_multiline(_border_prov, Color(0, 0, 0, 0.22), 1.0)
	if not _border_country.is_empty():
		draw_multiline(_border_country, Color(0.05, 0.05, 0.07, 0.9), 2.2)
	var provs := sim.provinces()
	if selected_province >= 0:
		draw_arc(cell_world(selected_province), 14.0, 0, TAU, 32, Color("ffe08a"), 2.0)


func _draw_units() -> void:
	var provs := sim.provinces()
	var us := ui_scale
	var font := UiFont.regular()
	var fsz := maxi(int(round(8.0)), 1)
	# armies (drawn in a local frame anchored at the cell centre so sizes stay constant on screen)
	var slot := {}
	for a in sim.armies:
		var p: int = a["prov"]
		var i: int = slot.get(p, 0)
		slot[p] = i + 1
		var base: Vector2 = cell_world(p)
		if not cull.has_point(base):
			continue
		var col := Color(sim.countries[a["owner"]]["color"])
		var pos := Vector2(-9 + i * 15, -4)
		draw_set_transform(base, 0.0, Vector2(us, us))
		if lod_compact:
			draw_rect(Rect2(pos, Vector2(9, 6)).grow(1.0), Color(0, 0, 0, 0.8))
			draw_rect(Rect2(pos, Vector2(9, 6)), col)
		else:
			var rect := Rect2(pos, Vector2(14, 9))
			draw_rect(rect.grow(1.5), Color(0, 0, 0, 0.85))
			draw_rect(rect, col)
			if a["id"] == selected_army:
				draw_rect(rect.grow(3.0), Color("ffe08a"), false, 1.5)
			if a["supply"] < 30:
				draw_rect(rect.grow(2.5), Color("e04a3a"), false, 1.5)
			var known := player_country < 0 or sim.intel_visible(player_country, a)
			draw_string(font, pos + Vector2(0, 19), ("%d·%d" % [a["div"].size(), sim.perceived_strength(player_country, a) / 100]) if known and player_country >= 0 else ("%d·%d" % [a["div"].size(), a["strength"] / 100] if known else "?"), HORIZONTAL_ALIGNMENT_LEFT, -1, fsz, Color.WHITE)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# movement arrow
		if not a["path"].is_empty() and not lod_compact:
			var pts := PackedVector2Array([base])
			for q in a["path"]:
				pts.append(cell_world(q))
			draw_polyline(pts, Color(1, 0.85, 0.4, 0.9), 2.0 * us, true)
			var end: Vector2 = pts[pts.size() - 1]
			var dir := (end - pts[pts.size() - 2]).normalized()
			if dir.length() < 0.5:
				continue   # zero-length last segment: no arrow head (degenerate triangle)
			var nrm := dir.orthogonal()
			draw_colored_polygon(PackedVector2Array([end, end - dir * 9 * us + nrm * 5 * us, end - dir * 9 * us - nrm * 5 * us]), Color(1, 0.85, 0.4))
	# bombing damage
	for p in sim.damage.size():
		if sim.damage[p] > 0 and cull.has_point(cell_world(p)):
			draw_circle(cell_world(p), (5.0 + sim.damage[p] * 0.12) * us, Color(0.85, 0.2, 0.1, 0.12 + sim.damage[p] * 0.003))
	# aircraft: wings at their bases, mission lines to targets
	var wslot := {}
	var mission_col := {"air_superiority": Color(0.55, 0.8, 1.0, 0.85), "bomb": Color(1.0, 0.45, 0.3, 0.85), "cas": Color(0.7, 1.0, 0.5, 0.85)}
	var letters := {"fighter": "И", "bomber": "Б", "attacker": "Ш"}
	for w in sim.wings:
		var bp: int = w["base"]
		var wi: int = wslot.get(bp, 0)
		wslot[bp] = wi + 1
		var wbase: Vector2 = cell_world(bp)
		if not cull.has_point(wbase) or lod_compact:
			continue
		var wpos := Vector2(-9 + wi * 11, -17)
		var wcol := Color(sim.countries[w["owner"]]["color"])
		draw_set_transform(wbase, 0.0, Vector2(us, us))
		var plane := PackedVector2Array([wpos + Vector2(0, -5), wpos + Vector2(4, 3), wpos + Vector2(0, 1), wpos + Vector2(-4, 3)])
		draw_colored_polygon(plane, wcol)
		draw_polyline(PackedVector2Array([plane[0], plane[1], plane[2], plane[3], plane[0]]), Color("ffe08a") if w["id"] == selected_wing else Color.BLACK, 1.2)
		draw_string(font, wpos + Vector2(-3, 12), "%s%d" % [letters.get(w["type"], "?"), w["strength"]], HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color.WHITE)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if w["mission"] != "idle" and w["target"] >= 0:
			var tpos: Vector2 = cell_world(w["target"])
			var mc: Color = mission_col.get(w["mission"], Color.WHITE)
			draw_dashed_line(wbase + wpos * us, tpos, mc, 1.5 * us, 5.0 * us)
			draw_arc(tpos, 9.0 * us, 0, TAU, 20, mc, 1.5 * us)
	# fleets
	var fslot := {}
	for f in sim.fleets:
		var fp: int = f["prov"]
		var fi: int = fslot.get(fp, 0)
		fslot[fp] = fi + 1
		var fbase: Vector2 = cell_world(fp)
		if not cull.has_point(fbase):
			continue
		var fpos := Vector2(fi * 14 - 6, 6)
		var fcol := Color(sim.countries[f["owner"]]["color"])
		draw_set_transform(fbase, 0.0, Vector2(us, us))
		var tri := PackedVector2Array([fpos + Vector2(0, -7), fpos + Vector2(8, 6), fpos + Vector2(-8, 6)])
		draw_colored_polygon(tri, fcol)
		draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), Color.BLACK if f["id"] != selected_fleet else Color("ffe08a"), 1.5)
		if not lod_compact:
			draw_string(font, fpos + Vector2(-6, 17), str(f["strength"] / 100), HORIZONTAL_ALIGNMENT_LEFT, -1, fsz, Color.WHITE)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if not f["path"].is_empty() and not lod_compact:
			var fpts := PackedVector2Array([fbase])
			for q in f["path"]:
				fpts.append(cell_world(q))
			draw_polyline(fpts, Color(0.6, 0.85, 1.0, 0.9), 2.0 * us, true)


func _draw_labels() -> void:
	var font := UiFont.regular()
	for l in _labels:
		var fs: int = l["size"]
		var text: String = l["name"]
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var at: Vector2 = l["pos"] - Vector2(tw * 0.5, -fs * 0.3)
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.8))
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.92))


# ------------------------------------------------------------------ input

func province_at(world_pos: Vector2) -> int:
	var w: int = sim.world["w"]
	var h: int = sim.world["h"]
	var cx := int(world_pos.x / CELL)
	var cy := int(world_pos.y / CELL)
	if cx < 0 or cy < 0 or cx >= w or cy >= h:
		return -1
	return sim.world["cell_prov"][cy * w + cx]


func _unhandled_input(event: InputEvent) -> void:
	if sim == null:
		return
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		var g := _touch.feed(event, Time.get_ticks_msec() / 1000.0)
		if not g.is_empty():
			_dragging = false
			_zoom_at(g["zoom"])
			camera.position -= (g["pan"] as Vector2) / camera.zoom.x
			_clamp_camera()
		return
	if _touch.multi and (event is InputEventMouseButton or event is InputEventMouseMotion):
		_dragging = false   # emulated mouse events of a multi-finger gesture
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(1.12)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(1.0 / 1.12)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_rc_start = mb.position
			elif mb.position.distance_to(_rc_start) < 6.0:
				var rid := province_at(get_global_mouse_position())
				if rid >= 0:
					province_right_clicked.emit(rid, get_viewport().get_mouse_position())
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_dragging = true
				_drag_moved = false
				_drag_start = mb.position
				_press_ms = Time.get_ticks_msec()
			else:
				if _dragging and not _drag_moved and mb.button_index == MOUSE_BUTTON_LEFT and not _touch.long_fired:
					var pid := province_at(get_global_mouse_position())
					if pid >= 0:
						if TouchSupport.is_long_press(Time.get_ticks_msec() - _press_ms, _drag_moved, OS.has_feature("mobile")):
							province_right_clicked.emit(pid, get_viewport().get_mouse_position())
						else:
							province_clicked.emit(pid)
				_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		if mm.position.distance_to(_drag_start) > 4.0:
			_drag_moved = true
		if _drag_moved:
			camera.position -= mm.relative / camera.zoom.x
			camera.position_smoothing_enabled = false
			_clamp_camera()
			camera.position_smoothing_enabled = true
	elif event is InputEventPanGesture:
		camera.position += (event as InputEventPanGesture).delta * 12.0 / camera.zoom.x
		_clamp_camera()
	elif event is InputEventMagnifyGesture:
		_zoom_at((event as InputEventMagnifyGesture).factor, (event as InputEventMagnifyGesture).position)


## Smooth zoom towards the cursor (HoI4-style): wheel notches / pinch only set a target; _smooth_zoom() eases the camera to it
## while keeping the world point under the cursor (or the pinch centre) fixed on screen.
var _zoom_target := 1.0
var _zooming := false
var _zoom_anchor_world := Vector2.ZERO
var _zoom_anchor_screen := Vector2.ZERO
const ZOOM_SPEED := 16.0   # larger = snappier


func _process(delta: float) -> void:
	_smooth_zoom(delta)


func _zoom_at(factor: float, anchor_screen: Variant = null) -> void:
	var anchor: Vector2 = anchor_screen if anchor_screen != null else get_viewport().get_mouse_position()
	if not _zooming:
		_zoom_target = camera.zoom.x
	_zoom_target = clampf(_zoom_target * factor, min_zoom, max_zoom)
	# the world point under the anchor, from the zoom/centre the camera has RIGHT NOW
	var half := get_viewport_rect().size * 0.5
	_zoom_anchor_screen = anchor
	_zoom_anchor_world = camera.position + (anchor - half) / camera.zoom.x
	_zooming = true
	camera.position_smoothing_enabled = false


## One animation step; returns true while still zooming. Called every frame by the map views.
func _smooth_zoom(delta: float) -> bool:
	if not _zooming:
		return false
	var z := camera.zoom.x
	if absf(_zoom_target - z) < 0.0005 * z:
		z = _zoom_target
		_zooming = false
	else:
		z += (_zoom_target - z) * (1.0 - exp(-ZOOM_SPEED * delta))
	camera.zoom = Vector2.ONE * z
	var half := get_viewport_rect().size * 0.5
	camera.position = _zoom_anchor_world - (_zoom_anchor_screen - half) / z
	if sim != null:
		_clamp_camera()
	if not _zooming:
		camera.position_smoothing_enabled = true
	return _zooming


func _clamp_camera() -> void:
	camera.position = camera.position.clamp(Vector2.ZERO, world_size())
