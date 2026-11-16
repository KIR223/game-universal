extends SceneTree
## Benchmarks for the real-world map. Run windowed for render numbers, headless for simulation numbers:
##   godot --path . -s tools/benchmark_world.gd            (window: includes camera/zoom frame times)
##   godot --headless --path . -s tools/benchmark_world.gd (simulation, data, search only)
## Prints a Markdown table.

var rows: Array = []
var main: Node
var frames := 0
var phase := "sim"
var cam_samples: Array = []
var last_us := 0
var sim: Simulation


func _ms(t0: int) -> float:
	return float(Time.get_ticks_usec() - t0) / 1000.0


func add(name: String, value: String, note: String = "") -> void:
	rows.append([name, value, note])


func _initialize() -> void:
	var headless: bool = DisplayServer.get_name() == "headless"
	var t := Time.get_ticks_usec()
	var w := EarthWorld.load_world()
	add("Загрузка карты (ячейки, смежность, растры)", "%.0f мс" % _ms(t), "%d ячеек, %d суши" % [w["provinces"].size(), w["land_count"]])
	t = Time.get_ticks_usec()
	EarthWorld.ensure_settlements()
	var sett_ms := _ms(t)
	add("Загрузка населённых пунктов (отложенная)", "%.0f мс" % sett_ms, "%d пунктов, колоночное хранение" % EarthWorld.settlement_count())
	t = Time.get_ticks_usec()
	var ln := EarthWorld.lines()
	add("Загрузка векторных слоёв (отложенная)", "%.0f мс" % _ms(t), "дороги %d, ж/д %d, реки %d" % [ln["roads"].size(), ln["rails"].size(), ln["rivers"].size()])
	t = Time.get_ticks_usec()
	sim = Simulation.new()
	sim.setup_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json"))
	add("Создание сценария «Современный мир»", "%.0f мс" % _ms(t), "%d стран, %d армий" % [sim.countries.size(), sim.armies.size()])
	# search
	var queries := ["mos", "new york", "Токио", "ham", "san", "Париж", "pek", "lon"]
	t = Time.get_ticks_usec()
	EarthWorld.search("zz")
	var first := _ms(t)
	t = Time.get_ticks_usec()
	var n := 0
	for rep in 10:
		for q in queries:
			EarthWorld.search(q, 20)
			n += 1
	add("Поиск населённого пункта", "%.1f мс на запрос" % (_ms(t) / n), "первый запрос с построением индекса: %.0f мс" % first)
	# simulation day
	t = Time.get_ticks_usec()
	for i in 30:
		sim.tick_day()
	add("Игровой день (205 стран, мир)", "%.0f мс" % (_ms(t) / 30.0), "среднее за 30 дней")
	# mass control change
	var rs := RandomNumberGenerator.new()
	rs.seed = 7
	var cells: Array = []
	for i in 3000:
		cells.append(rs.randi_range(0, sim.world["land_count"] - 1))
	t = Time.get_ticks_usec()
	for c in cells:
		sim.set_owner(c, (sim.owner[c] + 1) % sim.countries.size())
	add("Массовая смена контроля", "%.0f мс" % _ms(t), "3000 ячеек (кеши владельцев обновляются инкрементально)")
	# fronts
	var wars := 0
	for c in sim.countries:
		for nb in sim.neighbor_countries(c["id"]):
			if wars < 40 and not sim.at_war(c["id"], nb):
				sim.wars.append({"a": c["id"], "b": nb, "start": 0})
				wars += 1
	t = Time.get_ticks_usec()
	var total := 0
	for wr in sim.wars:
		total += sim.front_cells(wr["a"], wr["b"]).size() + sim.front_cells(wr["b"], wr["a"]).size()
	add("Пересчёт линий фронта", "%.1f мс" % _ms(t), "%d войн, %d ячеек фронта" % [sim.wars.size(), total])
	t = Time.get_ticks_usec()
	for c in sim.countries.slice(0, 40):
		sim.cut_off_cells(c["id"])
	add("Поиск окружённых ячеек", "%.1f мс" % (_ms(t) / 40.0), "на страну, среднее по 40 странам")
	add("Память (статическая)", "%.0f МБ" % (OS.get_static_memory_usage() / 1048576.0), "после загрузки мира, 205 стран и ~70 тыс. пунктов")
	if headless:
		_finish()
		return
	main = load("res://game/ui/main.tscn").instantiate()
	root.add_child(main)
	phase = "bind"


func _process(_delta: float) -> bool:
	frames += 1
	if phase == "bind" and frames == 3:
		var t := Time.get_ticks_usec()
		main._bind_map(sim)
		add("Подготовка карты к показу (текстуры, палитра)", "%.0f мс" % _ms(t), "EarthMapView.bind")
		main.map.player_country = 0
		main.map.camera.zoom = Vector2.ONE * 0.25
		phase = "warm"
		frames = 0
	elif phase == "warm" and frames == 120:
		phase = "pan"
		frames = 0
		cam_samples.clear()
		last_us = Time.get_ticks_usec()
	elif phase == "pan":
		var now := Time.get_ticks_usec()
		cam_samples.append(float(now - last_us) / 1000.0)
		last_us = now
		var t_ := float(frames) / 300.0
		main.map.camera.position = main.map.world_pos_of(-120.0 + 280.0 * t_, 45.0 - 40.0 * t_)
		if frames >= 300:
			add("Перемещение камеры (дальний план)", _frame_stats(), "300 кадров, масштаб 0.25")
			phase = "zoom"
			frames = 0
			cam_samples.clear()
	elif phase == "zoom":
		var now2 := Time.get_ticks_usec()
		cam_samples.append(float(now2 - last_us) / 1000.0)
		last_us = now2
		var z := 0.2 * pow(40.0, float(frames) / 300.0)
		main.map.camera.zoom = Vector2.ONE * z
		main.map.camera.position = main.map.world_pos_of(10.0, 50.0)
		if frames >= 300:
			add("Масштабирование 0.2 → 8 (Европа)", _frame_stats(), "300 кадров, города, дороги и границы включаются по уровню детализации")
			phase = "mode"
			frames = 0
			cam_samples.clear()
	elif phase == "mode" and frames == 5:
		var t2 := Time.get_ticks_usec()
		for m in EarthMapView.MODES:
			main.map.set_mode(m[0])
		add("Переключение режима карты", "%.1f мс" % (_ms(t2) / EarthMapView.MODES.size()), "в среднем на режим (12 режимов, палитра на 14 779 ячеек)")
		var t3 := Time.get_ticks_usec()
		var dirty: Array[int] = []
		for c in 1500:
			dirty.append(c * 3 % 14000)
		main.map.refresh(dirty)
		add("Обновление карты после захвата", "%.1f мс" % _ms(t3), "1500 изменённых ячеек: только их пиксели палитры")
		add("Видеопамять (текстуры)", "%.0f МБ" % (Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0), "")
		add("Вызовов отрисовки за кадр", "%d" % Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), "последний кадр")
		_finish()
	return false


func _frame_stats() -> String:
	var s := cam_samples.duplicate()
	s.sort()
	var avg := 0.0
	for v in s:
		avg += v
	avg /= s.size()
	return "%.1f мс среднее, p95 %.1f мс (%.0f FPS)" % [avg, s[int(s.size() * 0.95)], 1000.0 / avg]


func _finish() -> void:
	print("\n| Показатель | Значение | Примечание |\n|---|---|---|")
	for r in rows:
		print("| %s | %s | %s |" % [r[0], r[1], r[2]])
	quit(0)
