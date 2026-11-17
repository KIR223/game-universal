class_name GameSettings
extends RefCounted
## Player settings stored in user://settings.cfg: reduced motion and volumes (graphics quality and window live in GraphicsQuality / DisplaySettings). Static access, loaded lazily.

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"reduce_motion": false, "vol_master": 0.8, "vol_ui": 0.7, "vol_music": 0.35,
}

static var path := PATH   # tests point this at a scratch file
static var _data: Dictionary = {}
static var _loaded := false


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_data = DEFAULTS.duplicate()
	var cf := ConfigFile.new()
	if cf.load(path) == OK:
		for k in DEFAULTS:
			if cf.has_section_key("settings", k):
				_data[k] = cf.get_value("settings", k)


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


static func reduce_motion() -> bool:
	return bool(get_value("reduce_motion"))


## Test hook: forget cached values (and optionally use different defaults).
static func reset_for_tests() -> void:
	_loaded = false
	_data = {}
