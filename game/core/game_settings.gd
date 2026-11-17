class_name GameSettings
extends RefCounted
## Player settings stored in user://settings.cfg: graphics profile, motion, volumes. Static access, loaded lazily.

const PATH := "user://settings.cfg"
const QUALITY := ["low", "medium", "high", "ultra"]
const QUALITY_NAMES := {"low": "Низкое", "medium": "Среднее", "high": "Высокое", "ultra": "Ультра"}
## What each profile changes (map tiles, label budgets, effects).
const PROFILES := {
	"low": {"map_quality": "low", "label_cap": 90, "region_cap": 0, "effects": false},
	"medium": {"map_quality": "medium", "label_cap": 160, "region_cap": 90, "effects": true},
	"high": {"map_quality": "high", "label_cap": 220, "region_cap": 160, "effects": true},
	"ultra": {"map_quality": "high", "label_cap": 320, "region_cap": 260, "effects": true},
}
const DEFAULTS := {
	"quality": "high", "reduce_motion": false, "vol_master": 0.8, "vol_ui": 0.7, "vol_music": 0.35, "ui_scale": 1.0,
}

static var path := PATH   # tests point this at a scratch file
static var _data: Dictionary = {}
static var _loaded := false


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_data = DEFAULTS.duplicate()
	if MobileLayout.is_phone():
		_data["quality"] = "medium"
	var cf := ConfigFile.new()
	if cf.load(path) == OK:
		for k in DEFAULTS:
			if cf.has_section_key("settings", k):
				_data[k] = cf.get_value("settings", k)
	if not QUALITY.has(_data["quality"]):
		_data["quality"] = DEFAULTS["quality"]


static func get_value(key: String) -> Variant:
	_ensure()
	return _data.get(key, DEFAULTS.get(key))


static func set_value(key: String, value: Variant) -> void:
	_ensure()
	_data[key] = value
	var cf := ConfigFile.new()
	cf.load(path)
	cf.set_value("settings", key, value)
	cf.save(path)


static func profile() -> Dictionary:
	return PROFILES[get_value("quality")]


static func reduce_motion() -> bool:
	return bool(get_value("reduce_motion"))


## Test hook: forget cached values (and optionally use different defaults).
static func reset_for_tests() -> void:
	_loaded = false
	_data = {}
