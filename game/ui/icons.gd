class_name Icons
extends RefCounted
## One consistent set of vector icons drawn in code (same stroke width and proportions everywhere).
## Usage: Icons.draw(canvas_item, "coin", rect, color)  or  IconButton with icon_kind.

const NAMES := [
	"state", "economy", "build", "diplomacy", "army", "tech", "politics", "intel", "stats", "bell", "search", "layers", "menu",
	"coin", "influence", "stability", "manpower", "steel", "oil", "food", "pause", "play", "fast", "faster", "fastest", "close", "plus", "flag", "gear",
]


static func draw(ci: CanvasItem, kind: String, r: Rect2, col: Color, w: float = 1.7) -> void:
	var c := r.get_center()
	var s := minf(r.size.x, r.size.y) * 0.5
	var u := s / 10.0   # unit: icons are designed on a 20x20 grid
	var P := func(x: float, y: float) -> Vector2: return c + Vector2(x, y) * u
	match kind:
		"state":  # flag on a pole
			ci.draw_line(P.call(-5, 8), P.call(-5, -8), col, w)
			ci.draw_colored_polygon(PackedVector2Array([P.call(-5, -8), P.call(7, -5), P.call(-5, -1)]), col)
		"economy", "coin":
			ci.draw_arc(c, 8.0 * u, 0, TAU, 28, col, w)
			ci.draw_arc(c, 4.8 * u, 0, TAU, 20, col, w * 0.8)
		"build":  # hammer
			ci.draw_line(P.call(-6, 7), P.call(3, -2), col, w * 1.3)
			ci.draw_colored_polygon(PackedVector2Array([P.call(0, -7), P.call(8, -3), P.call(5, 1), P.call(-3, -3)]), col)
		"diplomacy":  # globe
			ci.draw_arc(c, 8.0 * u, 0, TAU, 28, col, w)
			ci.draw_line(P.call(-8, 0), P.call(8, 0), col, w * 0.8)
			ci.draw_arc(c, 8.0 * u, 0, TAU, 4, col, 0.0)
			ci.draw_arc(c, Vector2(4.0, 8.0).x * u, -PI / 2, PI / 2, 14, col, w * 0.8)
			ci.draw_arc(c, Vector2(4.0, 8.0).x * u, PI / 2, 3 * PI / 2, 14, col, w * 0.8)
		"army":  # shield with chevron
			ci.draw_polyline(PackedVector2Array([P.call(-7, -8), P.call(7, -8), P.call(7, 1), P.call(0, 9), P.call(-7, 1), P.call(-7, -8)]), col, w)
			ci.draw_polyline(PackedVector2Array([P.call(-4, -1), P.call(0, -4), P.call(4, -1)]), col, w)
		"tech":  # flask
			ci.draw_polyline(PackedVector2Array([P.call(-3, -9), P.call(-3, -2), P.call(-8, 7), P.call(8, 7), P.call(3, -2), P.call(3, -9)]), col, w)
			ci.draw_line(P.call(-4, -9), P.call(4, -9), col, w)
			ci.draw_circle(P.call(-1, 4), 1.3 * u, col)
		"politics":  # scales
			ci.draw_line(P.call(0, -8), P.call(0, 8), col, w)
			ci.draw_line(P.call(-7, -5), P.call(7, -5), col, w)
			ci.draw_line(P.call(-4, 8), P.call(4, 8), col, w)
			ci.draw_polyline(PackedVector2Array([P.call(-9, 1), P.call(-7, -5), P.call(-5, 1), P.call(-9, 1)]), col, w * 0.8)
			ci.draw_polyline(PackedVector2Array([P.call(5, 1), P.call(7, -5), P.call(9, 1), P.call(5, 1)]), col, w * 0.8)
		"intel":  # eye
			ci.draw_arc(P.call(0, 6), 10.0 * u, -2.4, -0.74, 16, col, w)
			ci.draw_arc(P.call(0, -6), 10.0 * u, 0.74, 2.4, 16, col, w)
			ci.draw_circle(c, 2.6 * u, col)
		"stats":  # bars
			ci.draw_rect(Rect2(P.call(-8, 1), Vector2(4, 7) * u), col)
			ci.draw_rect(Rect2(P.call(-2, -3), Vector2(4, 11) * u), col)
			ci.draw_rect(Rect2(P.call(4, -8), Vector2(4, 16) * u), col)
		"bell":
			ci.draw_polyline(PackedVector2Array([P.call(-7, 5), P.call(-5, 3), P.call(-5, -3), P.call(0, -8), P.call(5, -3), P.call(5, 3), P.call(7, 5), P.call(-7, 5)]), col, w)
			ci.draw_arc(P.call(0, 5), 2.0 * u, 0, PI, 8, col, w)
		"search":
			ci.draw_arc(P.call(-2, -2), 6.0 * u, 0, TAU, 22, col, w)
			ci.draw_line(P.call(2.5, 2.5), P.call(8, 8), col, w * 1.3)
		"layers":
			for k in 3:
				var y := -5.0 + k * 5.0
				ci.draw_polyline(PackedVector2Array([P.call(-8, y), P.call(0, y - 4), P.call(8, y), P.call(0, y + 4), P.call(-8, y)]), col, w * (1.0 if k == 0 else 0.8))
		"menu":
			for k in 3:
				ci.draw_line(P.call(-7, -5.0 + k * 5.0), P.call(7, -5.0 + k * 5.0), col, w * 1.2)
		"influence":  # laurel-ish star
			ci.draw_polyline(PackedVector2Array([P.call(0, -8), P.call(2.4, -2.5), P.call(8, -2), P.call(3.8, 2), P.call(5, 8), P.call(0, 5), P.call(-5, 8), P.call(-3.8, 2), P.call(-8, -2), P.call(-2.4, -2.5), P.call(0, -8)]), col, w * 0.9)
		"stability":  # gauge
			ci.draw_arc(P.call(0, 3), 8.0 * u, PI, TAU, 18, col, w)
			ci.draw_line(P.call(0, 3), P.call(4, -3), col, w * 1.2)
			ci.draw_line(P.call(-8, 3), P.call(8, 3), col, w * 0.8)
		"manpower":  # person
			ci.draw_circle(P.call(0, -4), 3.0 * u, col)
			ci.draw_arc(P.call(0, 9), 7.0 * u, PI, TAU, 12, col, w)
		"steel":  # ingot
			ci.draw_polyline(PackedVector2Array([P.call(-8, 5), P.call(-5, -3), P.call(5, -3), P.call(8, 5), P.call(-8, 5)]), col, w)
			ci.draw_line(P.call(-4, 1), P.call(4, 1), col, w * 0.8)
		"oil":  # drop
			ci.draw_polyline(PackedVector2Array([P.call(0, -9), P.call(6, 1), P.call(5, 5), P.call(0, 8), P.call(-5, 5), P.call(-6, 1), P.call(0, -9)]), col, w)
		"food":  # wheat
			ci.draw_line(P.call(0, 9), P.call(0, -8), col, w)
			for k in 3:
				ci.draw_line(P.call(0, 4.0 - k * 4.5), P.call(-5, 1.0 - k * 4.5), col, w * 0.9)
				ci.draw_line(P.call(0, 4.0 - k * 4.5), P.call(5, 1.0 - k * 4.5), col, w * 0.9)
		"pause":
			ci.draw_rect(Rect2(P.call(-5, -6), Vector2(3.5, 12) * u), col)
			ci.draw_rect(Rect2(P.call(1.5, -6), Vector2(3.5, 12) * u), col)
		"play", "fast", "faster", "fastest":
			var n: int = {"play": 1, "fast": 2, "faster": 3, "fastest": 4}[kind]
			var step: float = 5.0 if n > 2 else 7.0
			var x0: float = -(n - 1) * step * 0.5 - 3.0
			for k in n:
				var x: float = x0 + k * step
				ci.draw_colored_polygon(PackedVector2Array([P.call(x, -6), P.call(x + 6, 0), P.call(x, 6)]), col)
		"close":
			ci.draw_line(P.call(-6, -6), P.call(6, 6), col, w * 1.2)
			ci.draw_line(P.call(-6, 6), P.call(6, -6), col, w * 1.2)
		"plus":
			ci.draw_line(P.call(-7, 0), P.call(7, 0), col, w * 1.2)
			ci.draw_line(P.call(0, -7), P.call(0, 7), col, w * 1.2)
		"flag":
			ci.draw_line(P.call(-5, 9), P.call(-5, -8), col, w)
			ci.draw_rect(Rect2(P.call(-5, -8), Vector2(12, 8) * u), col)
		"gear":
			ci.draw_arc(c, 5.0 * u, 0, TAU, 20, col, w)
			for k in 8:
				var a := TAU * k / 8.0
				ci.draw_line(c + Vector2(cos(a), sin(a)) * 6.0 * u, c + Vector2(cos(a), sin(a)) * 9.0 * u, col, w * 1.4)
		_:
			ci.draw_arc(c, 6.0 * u, 0, TAU, 16, col, w)
