class_name MobileLayout
extends RefCounted
## Phone/tablet layout helpers (iPhone, iPad, Android): detection, UI scale and safe-area margins.

const PHONE_UI_SCALE := 1.3
static var force := false   # tests and tools: behave like a phone on any device


## True on iPhone/iPad/Android builds (and when forced with `-- --phone-ui` for desktop testing).
static func is_phone() -> bool:
	return force or OS.has_feature("ios") or OS.has_feature("android") or OS.get_cmdline_user_args().has("--phone-ui")


## Safe area (window pixels) -> margins in UI units: Rect2(position = left/top, size = right/bottom).
## Keeps the interface out of the notch, rounded corners and the home indicator.
static func safe_area_insets(safe: Rect2i, window_px: Vector2i, ui_size: Vector2) -> Rect2:
	if window_px.x <= 0 or window_px.y <= 0 or safe.size.x <= 0 or safe.size.y <= 0:
		return Rect2()
	var k := Vector2(ui_size.x / window_px.x, ui_size.y / window_px.y)
	var left := maxf(0.0, safe.position.x * k.x)
	var top := maxf(0.0, safe.position.y * k.y)
	var right := maxf(0.0, (window_px.x - safe.position.x - safe.size.x) * k.x)
	var bottom := maxf(0.0, (window_px.y - safe.position.y - safe.size.y) * k.y)
	return Rect2(left, top, right, bottom)
