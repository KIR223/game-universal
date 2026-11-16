class_name ScenarioLoader
extends RefCounted
## Finds, reads and writes scenarios.
## Built-in: res://game/scenarios/index.json (list of file names). User/mod: user://scenarios/*.json

const BUILTIN_DIR := "res://game/scenarios/"
const USER_DIR := "user://scenarios"


static func list_all() -> Array:
	var out: Array = []
	var idx := FileAccess.open(BUILTIN_DIR + "index.json", FileAccess.READ)
	if idx != null:
		var parsed: Variant = JSON.parse_string(idx.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			for fname in parsed.get("scenarios", []):
				var scn := read_file(BUILTIN_DIR + fname)
				if not scn.is_empty():
					out.append({"path": BUILTIN_DIR + fname, "data": scn, "builtin": true})
	var dir := DirAccess.open(USER_DIR)
	if dir != null:
		var names: Array = []
		for f in dir.get_files():
			if f.ends_with(".json"):
				names.append(f)
		names.sort()
		for f in names:
			var scn2 := read_file(USER_DIR + "/" + f)
			if not scn2.is_empty():
				out.append({"path": USER_DIR + "/" + f, "data": scn2, "builtin": false})
	return out


static func read_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


static func slug(text: String) -> String:
	var out := ""
	for ch in text.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_":
			out += ch
		elif ch == " " or ch == "-":
			out += "_"
	return out if out != "" else "scenario"


## Writes the scenario to user://scenarios/<id>.json and returns the path ("" on failure).
static func save_user(scn: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(USER_DIR)
	var id: String = slug(str(scn.get("id", scn.get("name", "scenario"))))
	scn["id"] = id
	var path := "%s/%s.json" % [USER_DIR, id]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(scn, "\t"))
	return path


static func delete_user(path: String) -> bool:
	if not path.begins_with(USER_DIR):
		return false
	return DirAccess.remove_absolute(path) == OK


## Default scenario: the stock country list on a given seed.
static func blank(seed_value: int) -> Dictionary:
	return {
		"schema_version": 1, "id": "new_scenario", "name": "Новый сценарий", "description": "",
		"seed": seed_value, "start_date": "1936-01-01",
		"countries": Simulation.load_country_defs().duplicate(true),
		"disabled_events": [],
	}
