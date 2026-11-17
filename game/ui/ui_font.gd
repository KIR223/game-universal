class_name UiFont
extends RefCounted
## The game's typeface: PT Sans (SIL Open Font License 1.1, ParaType), drawn for Cyrillic. Regular for text, Bold for
## headings and country names. Glyphs PT Sans lacks fall back to the engine's default font, so no name ever shows boxes.
## License text: game/assets/fonts/OFL-PTSans.txt, listed in ASSET_LICENSES.md.

const REGULAR := "res://game/assets/fonts/PTSans-Regular.ttf"
const BOLD := "res://game/assets/fonts/PTSans-Bold.ttf"

static var _regular: Font = null
static var _bold: Font = null


static func regular() -> Font:
	if _regular == null:
		_regular = _load(REGULAR)
	return _regular


static func bold() -> Font:
	if _bold == null:
		_bold = _load(BOLD)
	return _bold


static func _load(path: String) -> Font:
	var f: Resource = load(path)
	if f is FontFile:
		(f as FontFile).fallbacks = [ThemeDB.fallback_font]
		return f
	return ThemeDB.fallback_font   # never leave the UI without a font
