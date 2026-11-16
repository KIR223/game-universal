class_name DisplaySettings
extends RefCounted
## Desktop window settings (windowed / fullscreen / borderless, resolution). Stored per machine in
## user://display.cfg, separate from game saves, so it never affects the shared save format.

const PATH := "user://display.cfg"
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]
enum Mode { WINDOWED, FULLSCREEN, BORDERLESS }

var mode: int = Mode.WINDOWED
var resolution_index: int = 1


static func load_settings(path: String = PATH) -> DisplaySettings:
	var s := DisplaySettings.new()
	var cfg := ConfigFile.new()
	if cfg.load(path) == OK:
		s.mode = clampi(int(cfg.get_value("display", "mode", Mode.WINDOWED)), 0, Mode.BORDERLESS)
		s.resolution_index = clampi(int(cfg.get_value("display", "resolution", 1)), 0, RESOLUTIONS.size() - 1)
	return s


func save_settings(path: String = PATH) -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("display", "mode", mode)
	cfg.set_value("display", "resolution", resolution_index)
	return cfg.save(path) == OK


func toggle_fullscreen() -> void:
	mode = Mode.WINDOWED if mode == Mode.FULLSCREEN else Mode.FULLSCREEN


func toggle_borderless() -> void:
	mode = Mode.WINDOWED if mode == Mode.BORDERLESS else Mode.BORDERLESS


func next_resolution() -> void:
	resolution_index = (resolution_index + 1) % RESOLUTIONS.size()


func resolution() -> Vector2i:
	return RESOLUTIONS[resolution_index]


func describe() -> String:
	var names: Array[String] = ["оконный", "полный экран", "без рамки"]
	var m: String = names[mode]
	return "%s, окно %d×%d" % [m, resolution().x, resolution().y]


## Applies the settings to the window. A windowed resolution is clamped to the usable screen area.
func apply(window: Window) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var screen := window.current_screen
	match mode:
		Mode.FULLSCREEN:
			window.borderless = false
			window.mode = Window.MODE_FULLSCREEN
		Mode.BORDERLESS:
			window.mode = Window.MODE_WINDOWED
			window.borderless = true
			window.position = DisplayServer.screen_get_position(screen)
			# one extra pixel row off-screen: a borderless window exactly the size of the screen is turned into exclusive fullscreen by Windows
			window.size = DisplayServer.screen_get_size(screen) + Vector2i(0, 1)
		_:
			window.borderless = false
			window.mode = Window.MODE_WINDOWED
			var usable := DisplayServer.screen_get_usable_rect(screen)
			var size := resolution()
			size.x = mini(size.x, usable.size.x)
			size.y = mini(size.y, usable.size.y)
			window.size = size
			window.position = usable.position + (usable.size - size) / 2
