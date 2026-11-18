class_name Design
extends RefCounted
## IRON DOMINION design tokens (see docs/ART_DIRECTION.md). One place for spacing, sizes and colours; new UI code uses these
## instead of ad-hoc numbers. Spacing follows a 4/8 px grid.

# spacing (px)
const S1 := 4
const S2 := 8
const S3 := 12
const S4 := 16
const S5 := 24
const S6 := 32

# radii and touch targets
const RADIUS := 4
const RADIUS_LG := 6
const BTN_H := 36            # desktop button height
const BTN_H_TOUCH := 48      # phones: >= 44 pt after the 1.3 UI scale
const ROW_H := 28
const PANEL_W := 920         # default width of modal panels (economy, technologies, diplomacy)

# font sizes
const FS_CAPTION := 12
const FS_BODY := 15
const FS_BODY_L := 16
const FS_H3 := 18
const FS_H2 := 22
const FS_H1 := 32
const FS_TITLE := 64

# palette: graphite / steel / muted gold, state colours for game events
const C_BG := Color("0b1119")
const C_PANEL := Color("151a22")
const C_PANEL_HI := Color("1f2530")
const C_LINE := Color("3a4452")
const C_TEXT := Color("dde3ea")
const C_TEXT_DIM := Color("93a3b8")
const C_GOLD := Color("e0c070")
const C_GOLD_DIM := Color("a8893f")
const C_OK := Color("8ac58a")
const C_WARN := Color("d9a05a")
const C_BAD := Color("d96a5a")
const C_INFO := Color("8ac5ff")

# motion
const ANIM_FAST := 0.12
const ANIM_PANEL := 0.18


## WCAG contrast ratio of two colours (>= 4.5 for body text, >= 3 for large text and icons).
static func contrast(a: Color, b: Color) -> float:
	var la := _lum(a)
	var lb := _lum(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


static func _lum(c: Color) -> float:
	var f := func(v: float) -> float: return v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4)
	return 0.2126 * f.call(c.r) + 0.7152 * f.call(c.g) + 0.0722 * f.call(c.b)
