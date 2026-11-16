class_name SaveSystem
extends RefCounted

const DIR := "user://saves"


static func save(sim: Simulation, slot: String = "quick") -> bool:
	DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open("%s/%s.sav" % [DIR, slot], FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(var_to_str(sim.to_dict()))
	return true


static func load_slot(slot: String = "quick") -> Simulation:
	var path := "%s/%s.sav" % [DIR, slot]
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	var d: Variant = str_to_var(f.get_as_text())
	if typeof(d) != TYPE_DICTIONARY or d.get("version", -1) != Simulation.SAVE_VERSION:
		return null
	return Simulation.from_dict(d, Simulation.load_country_defs())
