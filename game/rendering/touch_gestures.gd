class_name TouchGestures
extends RefCounted
## Touch input for phones and tablets (iPhone/iPad): two-finger pinch zoom and pan, long press = "right click" (order / context).
## Pure logic over InputEventScreenTouch / InputEventScreenDrag so it can be unit tested without a device.

const LONG_PRESS_SEC := 0.5
const MOVE_TOLERANCE := 14.0     # screen px a finger may move and still count as a press

var points := {}                 # finger index -> position
var multi := false               # two or more fingers have been down since the last time all were lifted
var long_fired := false          # the current press already produced a long press (its release must not select)
var _last_dist := 0.0
var _last_mid := Vector2.ZERO
var _press_pos := Vector2.ZERO
var _press_time := 0.0
var _press_active := false


## Feeds one event; returns {"zoom": factor, "pan": screen-pixel delta} when two fingers moved, otherwise {}.
func feed(e: InputEvent, now: float) -> Dictionary:
	if e is InputEventScreenTouch:
		var t := e as InputEventScreenTouch
		if t.pressed:
			points[t.index] = t.position
			if points.size() == 1:
				_press_pos = t.position
				_press_time = now
				_press_active = true
				long_fired = false
			else:
				multi = true
				_press_active = false
				_reset_pair()
		else:
			points.erase(t.index)
			_press_active = false
			if points.size() >= 2:
				_reset_pair()
			if points.is_empty():
				multi = false
	elif e is InputEventScreenDrag:
		var d := e as InputEventScreenDrag
		points[d.index] = d.position
		if points.size() >= 2:
			return _pair_motion()
		if _press_active and d.position.distance_to(_press_pos) > MOVE_TOLERANCE:
			_press_active = false
	return {}


## Call every frame. Returns true exactly once when the finger has rested long enough.
func long_press_due(now: float) -> bool:
	if _press_active and not long_fired and not multi and now - _press_time >= LONG_PRESS_SEC:
		long_fired = true
		_press_active = false
		return true
	return false


func press_position() -> Vector2:
	return _press_pos


func _pair() -> Array:
	var keys := points.keys()
	keys.sort()
	return [points[keys[0]], points[keys[1]]]


func _reset_pair() -> void:
	var p := _pair()
	_last_dist = maxf((p[0] as Vector2).distance_to(p[1]), 1.0)
	_last_mid = ((p[0] as Vector2) + (p[1] as Vector2)) * 0.5


func _pair_motion() -> Dictionary:
	var p := _pair()
	var dist := maxf((p[0] as Vector2).distance_to(p[1]), 1.0)
	var mid := ((p[0] as Vector2) + (p[1] as Vector2)) * 0.5
	var out := {"zoom": dist / _last_dist, "pan": mid - _last_mid}
	_last_dist = dist
	_last_mid = mid
	return out
