class_name GraphicsQuality
extends RefCounted
## Map drawing quality (Low / Medium / High). Only rendering is affected - never the simulation. The choice is stored
## per machine in user://graphics.cfg. Phones default to Medium, desktops to High.

enum Level { LOW, MEDIUM, HIGH }
const PATH := "user://graphics.cfg"
const NAMES := ["Низкое", "Среднее", "Высокое"]

## labels: max city labels per frame; pop_scale: multiplies the population threshold for drawing a city (bigger = fewer);
## roads_zoom: zoom from which roads/rails are drawn (very large = only in the logistics/infrastructure modes).
const PARAMS := [
	{"labels": 40, "pop_scale": 2.5, "roads_zoom": 99.0},
	{"labels": 110, "pop_scale": 1.5, "roads_zoom": 2.4},
	{"labels": 220, "pop_scale": 1.0, "roads_zoom": 1.6},
]


static func default_level(mobile: bool) -> int:
	return Level.MEDIUM if mobile else Level.HIGH


static func load_level(path: String = PATH, mobile: bool = false) -> int:
	var cfg := ConfigFile.new()
	if cfg.load(path) == OK:
		return clampi(int(cfg.get_value("graphics", "quality", default_level(mobile))), Level.LOW, Level.HIGH)
	return default_level(mobile)


static func save_level(level: int, path: String = PATH) -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("graphics", "quality", clampi(level, Level.LOW, Level.HIGH))
	return cfg.save(path) == OK


static func params(level: int) -> Dictionary:
	return PARAMS[clampi(level, Level.LOW, Level.HIGH)]


static func next(level: int) -> int:
	return (clampi(level, Level.LOW, Level.HIGH) + 1) % PARAMS.size()   # Low -> Medium -> High -> Low


static func label(level: int) -> String:
	return NAMES[clampi(level, Level.LOW, Level.HIGH)]
