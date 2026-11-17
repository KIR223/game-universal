extends SceneTree
## Syntax/type check of every GDScript file in the project (a script that fails to compile fails here):
##   godot --headless --path . -s tools/check_gdscript.gd
## Exit code 0 = all scripts compile.

var checked := 0
var failed: Array[String] = []


func _initialize() -> void:
	_scan("res://")
	print("GDScript check: %d scripts, %d failed" % [checked, failed.size()])
	for f in failed:
		printerr("  FAILED: ", f)
	quit(1 if not failed.is_empty() or checked == 0 else 0)


func _scan(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		if sub.begins_with(".") or sub == "build" or sub == "export":
			continue
		_scan(dir.path_join(sub))
	for file in d.get_files():
		if file.get_extension() != "gd":
			continue
		var path := dir.path_join(file)
		checked += 1
		var script: Resource = load(path)   # a script with a parse/type error loads but cannot be instantiated
		if script == null or not (script is GDScript) or not (script as GDScript).can_instantiate():
			failed.append(path)
