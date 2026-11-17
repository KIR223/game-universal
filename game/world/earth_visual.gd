class_name EarthVisual
extends RefCounted
## Visual layer of the real-world map (data/world_visual): imagery tiles with an exact land mask in the alpha channel,
## fine vector coast/rivers/borders and the "extended" cell-id raster (land ids grown into coastal water).
## It never feeds the simulation: swapping or deleting it does not change world_hash or any game rule.

const DIR := "res://data/world_visual/"

static var _manifest: Dictionary = {}
static var _vectors: Dictionary = {}
static var _lock := Mutex.new()


static func available() -> bool:
	return FileAccess.file_exists(DIR + "manifest.json")


static func manifest() -> Dictionary:
	if _manifest.is_empty() and available():
		_manifest = JSON.parse_string(FileAccess.get_file_as_string(DIR + "manifest.json"))
	return _manifest


static func _image_from_bin(path: String, mipmaps: bool) -> Image:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_webp_from_buffer(bytes) != OK:
		return null
	if mipmaps:
		img.generate_mipmaps()
	return img


## One 900x720 imagery tile (RGBA: Natural Earth II colour + land mask in alpha).
static func tile_image(col: int, row: int) -> Image:
	return _image_from_bin(DIR + "tiles/t_%d_%d.bin" % [col, row], true)


static func overview_image() -> Image:
	return _image_from_bin(DIR + "overview.bin", true)


static func tile_grid() -> Vector2i:
	var m := manifest()
	var im: Dictionary = m["imagery"]
	return Vector2i(int(im["w"]) / int(im["tile_w"]), int(im["h"]) / int(im["tile_h"]))


static func _bytes(name: String) -> PackedByteArray:
	var comp := FileAccess.get_file_as_bytes(DIR + name)
	if comp.is_empty():
		return PackedByteArray()
	return comp.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)


## Extended cell ids (RG8, 16-bit little endian, 65535 = none): land ids grown 2 pixels into coastal water.
static func ext_bytes(world_dir: String = "world") -> PackedByteArray:
	return _bytes("ext_%s.bin" % world_dir)


static func ext_image(w: int, h: int, world_dir: String = "world") -> Image:
	return Image.create_from_data(w, h, false, Image.FORMAT_RG8, ext_bytes(world_dir))


## Land fraction (0..255) of each simulation-raster pixel; tells coastal land from coastal sea.
static func land_fraction(world_dir: String = "world") -> PackedByteArray:
	return _bytes("land_fraction_%s.bin" % world_dir)


static func vectors() -> Dictionary:
	_lock.lock()
	if _vectors.is_empty():
		var b := _bytes("vectors.json.z")
		if not b.is_empty():
			_vectors = JSON.parse_string(b.get_string_from_utf8())
	var out := _vectors
	_lock.unlock()
	return out


static func release_vectors() -> void:
	_lock.lock()
	_vectors = {}
	_lock.unlock()
