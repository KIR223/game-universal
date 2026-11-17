extends SceneTree
## Multiplayer through the real game UI (two game instances over the in-memory network, executes in frames):
##   godot --headless --path . -s tests/run_net_ui_tests.gd
## Exit code 0 = all passed.

var failures := 0
var passed := 0
var _frames := 0
var A: Node
var B: Node


func _initialize() -> void:
	A = load("res://game/ui/main.tscn").instantiate()
	B = load("res://game/ui/main.tscn").instantiate()
	root.add_child(A)
	root.add_child(B)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 3:
		run()
		print("\n%d net UI checks passed, %d failed" % [passed, failures])
		quit(1 if failures > 0 else 0)
	return false


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failures += 1
		printerr("  FAIL: ", msg)


func run() -> void:
	# host: the real flow up to the country choice, then the session is attached (instead of opening a socket)
	A._start_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json"))
	for e in A.sim.event_defs:
		A.sim.disabled_events.append(e["id"])
	var pl: int = A.sim.countries.find_custom(func(c): return c["name"] == "Польша")
	A._start_playing(pl)
	var lan := LoopbackNet.new()
	var h := NetHost.new(A.sim, lan.server)
	h.checksum_every = 1
	A._net_attach_host(h)
	check(A.net != null and A.net.is_host() and h.paused and A.speed_idx == 0, "the host starts paused with the session attached")
	check(not A.sim.countries[pl]["ai"] and A.sim.countries[(pl + 1) % A.sim.countries.size()]["ai"], "only the host's country is human")
	# client: connects, is welcomed, and the game starts by itself
	var c := NetClient.new(lan.connect_client(), "Anna")
	B._net_attach_client(c)
	for _i in 6:
		A._process(0.016)
		B._process(0.016)
	check(c.state == "playing" and B.player == c.country and B.sim == c.sim, "the client game started after the welcome (state %s)" % c.state)
	check(B.sim.checksum() == A.sim.checksum() and not B.sim.countries[B.player]["ai"], "the client starts from the host's exact state, controlling its own country")
	check(B.speed_idx == 0 and h.paused, "joining does not change the host's pause state")
	var day0: int = A.sim.day
	for _i in 10:
		A._process(0.5)
		B._process(0.016)
	check(A.sim.day == day0 and B.sim.day == day0, "nobody advances time while the host is paused")
	# the host starts the clock: the client follows
	A._set_speed(2)
	for _i in 40:
		A._process(0.4)
		B._process(0.016)
		A._net_frame()
	check(A.sim.day > day0 + 5, "the host advanced the days (%d -> %d)" % [day0, A.sim.day])
	for _i in 8:
		B._process(0.016)
	check(B.sim.day == A.sim.day and B.sim.checksum() == A.sim.checksum(), "the client follows every tick: day %d, identical state" % A.sim.day)
	check(B.speed_idx != 0, "the client's HUD shows the game running")
	# a command from the client's UI goes through the host and comes back
	var enemy: int = B.sim.neighbor_countries(B.player)[0]
	var r: Dictionary = B.sim.apply_command({"type": "declare_war", "country": B.player, "target": enemy})
	check(r.get("pending", false), "a client's command is forwarded, not applied locally (%s)" % str(r))
	check(not B.sim.at_war(B.player, enemy), "...and nothing happens until the host confirms")
	for _i in 4:
		A._net_frame()
		B._process(0.016)
	check(B.sim.at_war(B.player, enemy) and A.sim.at_war(B.player, enemy), "the war is declared on both sides once the host broadcast it")
	check(B.sim.checksum() == A.sim.checksum(), "still identical")
	# pause from the client's UI is a request to the host
	B._set_speed(0)
	for _i in 4:
		A._net_frame()
		B._process(0.016)
	check(h.paused, "the client paused the game through the host")
	check(A.net.describe().find("хост") >= 0 and B.net.describe().find("клиент") >= 0, "the HUD describes the session: '%s' / '%s'" % [A.net.describe(), B.net.describe()])
	# a desync repairs itself and the client keeps playing with the new simulation
	A._set_speed(2)
	B.sim.countries[B.player]["treasury"] += 777
	for _i in 30:
		A._process(0.4)
		B._process(0.016)
		A._net_frame()
	for _i in 8:
		B._process(0.016)
	check(c.stats["desyncs"] >= 1 and c.stats["snapshots"] >= 1, "the client noticed the divergence and took a snapshot")
	check(B.sim == c.sim and B.sim.checksum() == A.sim.checksum() and B.sim.day == A.sim.day, "after the repair the UI runs on the repaired simulation (day %d)" % A.sim.day)
	# leaving the game closes the session
	B._show_menu()
	check(B.net == null and B.sim == null, "back to the menu ends the session")
	A._process(0.016)
	A._net_frame()
	check(h.connected_count() == 0 and A.sim.countries[c.country]["ai"], "the host sees the client leave and its country becomes AI")
