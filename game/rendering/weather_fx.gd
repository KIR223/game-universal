class_name WeatherFx
extends Control
## Screen-space snow and rain over the map where the weather rule says so (winter by latitude and season, local storms).
## Off with reduced motion, with the "Low" graphics profile, when zoomed far out and in scenarios without rules.weather.

var _snow: CPUParticles2D
var _rain: CPUParticles2D
var _t := 0.0


## Intensities 0..1 for the cell under the camera. Pure function (unit tested).
static func state_for(winter: int, storm: bool, zoom: float, effects: bool, reduce_motion: bool) -> Dictionary:
	if not effects or reduce_motion or zoom < 1.2:
		return {"snow": 0.0, "rain": 0.0}
	var snow := clampf(float(winter - 35) / 55.0, 0.0, 1.0)
	var rain := 0.0
	if storm:
		rain = 0.85 if winter < 35 else 0.0     # storms in deep winter fall as snow
		snow = maxf(snow, 0.9 if winter >= 35 else 0.0)
	return {"snow": snow, "rain": rain}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_snow = _make(380, 6.0, Vector2(0.15, 1.0), 55.0, 110.0, 2.5, 5.0, Color(1, 1, 1, 0.85), null)
	_rain = _make(380, 0.9, Vector2(0.18, 1.0), 650.0, 820.0, 1.0, 1.0, Color(0.7, 0.8, 1.0, 0.55), _streak())
	add_child(_snow)
	add_child(_rain)


func _make(amount: int, life: float, dir: Vector2, v_min: float, v_max: float, s_min: float, s_max: float, col: Color, tex: Texture2D) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = amount
	p.lifetime = life
	p.preprocess = life
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = dir
	p.spread = 12.0
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = v_min
	p.initial_velocity_max = v_max
	p.scale_amount_min = s_min
	p.scale_amount_max = s_max
	p.color = col
	p.texture = tex
	p.emitting = false
	return p


func _streak() -> Texture2D:
	var img := Image.create(2, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		var a := float(y) / 15.0
		for x in 2:
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
	var sz := get_viewport_rect().size
	for p in [_snow, _rain]:
		p.position = Vector2(sz.x * 0.5, -12.0)
		p.emission_rect_extents = Vector2(sz.x * 0.6, 2.0)


## Called by the game a few times per second with the map and the simulation.
func refresh(map: MapView, sim: Simulation) -> void:
	if sim == null or not sim.rule_weather or not (map is EarthMapView):
		_apply({"snow": 0.0, "rain": 0.0})
		return
	var cell: int = map.province_at(map.camera.get_screen_center_position())
	if cell < 0:
		_apply({"snow": 0.0, "rain": 0.0})
		return
	var prof := GameSettings.profile()
	_apply(state_for(sim.winter_at(cell), sim.storm_at(cell), map.camera.zoom.x, prof["effects"], GameSettings.reduce_motion()))


func _apply(st: Dictionary) -> void:
	_snow.emitting = st["snow"] > 0.02
	_snow.modulate.a = st["snow"]
	_rain.emitting = st["rain"] > 0.02
	_rain.modulate.a = st["rain"]
