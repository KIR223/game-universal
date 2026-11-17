class_name TouchSupport
extends RefCounted
## Touch helpers for phones and tablets (Android/iOS): UI scale from screen density and long press as the
## touch equivalent of a right click. Desktop behaviour is unchanged.

const LONG_PRESS_MS := 450


## Mobile UI scale from the screen DPI (about 1.4 on a 420 dpi phone; larger values squeeze the HUD panels); desktop keeps 1.0.
static func ui_scale(dpi: int, mobile: bool) -> float:
	if not mobile:
		return 1.0
	return clampf(float(dpi) / 300.0, 1.0, 1.5)


## A press held still for LONG_PRESS_MS opens the context menu (touch has no right button).
static func is_long_press(held_ms: int, moved: bool, mobile: bool) -> bool:
	return mobile and not moved and held_ms >= LONG_PRESS_MS
