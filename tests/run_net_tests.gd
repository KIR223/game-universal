extends SceneTree
## Multiplayer tests on the in-memory network (deterministic, no sockets):
##   godot --headless --path . -s tests/run_net_tests.gd
## Exit code 0 = all passed.

var failures := 0
var passed := 0


func _init() -> void:
	for m in get_method_list():
		if str(m["name"]).begins_with("test_"):
			print("▶ ", m["name"])
			call(m["name"])
	print("\n%d net checks passed, %d failed" % [passed, failures])
	quit(1 if failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failures += 1
		printerr("  FAIL: ", msg)


func _game(checksum_every: int = 1) -> Array:
	var sim := Simulation.new()
	sim.setup_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json"))
	for e in sim.event_defs:
		sim.disabled_events.append(e["id"])
	var net := LoopbackNet.new()
	var host := NetHost.new(sim, net.server)
	host.checksum_every = checksum_every
	host.set_host_country(sim.countries.find_custom(func(c): return c["name"] == "Польша"))
	return [host, net]


func _join(net: LoopbackNet, host: NetHost, name: String, want: int = -1, token: String = "") -> NetClient:
	var c := NetClient.new(net.connect_client(), name, want, token)
	_pump(host, [c])
	return c


func _pump(host: NetHost, clients: Array, rounds: int = 4) -> void:
	for _r in rounds:
		host.poll()
		for c in clients:
			c.poll()


func _all_equal(host: NetHost, clients: Array) -> bool:
	for c in clients:
		if c.sim == null or c.sim.checksum() != host.sim.checksum() or c.sim.day != host.sim.day:
			return false
	return true


func test_handshake_gives_a_free_country_and_an_identical_state() -> void:
	var g := _game()
	var host: NetHost = g[0]
	var net: LoopbackNet = g[1]
	var c := _join(net, host, "Anna")
	check(c.state == "playing", "client joined (state %s, error '%s')" % [c.state, c.last_error])
	check(c.country >= 0 and c.country != host.host_country and host.sim.countries[c.country]["ai"] == false, "client got its own country and controls it")
	check(c.sim != null and c.sim.checksum() == host.sim.checksum(), "the snapshot makes the client state identical to the host's")
	check(host.players.size() == 1 and host.connected_count() == 1, "host tracks the player")
	var want := host.sim.countries.find_custom(func(x): return x["name"] == "Франция")
	var c2 := _join(net, host, "Boris", want)
	check(c2.state == "playing" and c2.country == want, "a second client can ask for a specific country")
	var c3 := _join(net, host, "Cheater", want)
	check(c3.state == "rejected" and c3.last_error == NetProtocol.R_COUNTRY, "a taken country is refused (%s)" % c3.last_error)
	var c4 := _join(net, host, "Hostile", host.host_country)
	check(c4.state == "rejected", "the host's own country cannot be taken")


func test_handshake_rejects_incompatible_peers() -> void:
	var g := _game()
	var host: NetHost = g[0]
	var net: LoopbackNet = g[1]
	var a := NetClient.new(net.connect_client(), "OldVersion")
	a.hello_overrides = {"proto": NetProtocol.VERSION + 1}
	_pump(host, [a])
	check(a.state == "rejected" and a.last_error == NetProtocol.R_PROTOCOL, "wrong protocol version is rejected (%s)" % a.last_error)
	var b := NetClient.new(net.connect_client(), "OtherData")
	b.hello_overrides = {"world_hash": "deadbeef"}
	_pump(host, [b])
	check(b.state == "rejected" and b.last_error == NetProtocol.R_WORLD, "a different world dataset is rejected (%s)" % b.last_error)
	var r := NetClient.new(net.connect_client(), "OtherRules")
	r.hello_overrides = {"rules": 12345}
	_pump(host, [r])
	check(r.state == "rejected" and r.last_error == NetProtocol.R_RULES, "a different rules fingerprint is rejected (%s)" % r.last_error)
	var c := NetClient.new(net.connect_client(), "OtherSaves")
	c.hello_overrides = {"save_version": Simulation.SAVE_VERSION + 1}
	_pump(host, [c])
	check(c.state == "rejected" and c.last_error == NetProtocol.R_SAVE, "a different save format is rejected (%s)" % c.last_error)
	check(host.connected_count() == 0 and host.peer_token.is_empty(), "rejected peers never get in")
	host.max_players = 1
	var d := _join(net, host, "First")
	var e := _join(net, host, "Second")
	check(d.state == "playing" and e.state == "rejected" and e.last_error == NetProtocol.R_FULL, "the player limit is enforced (%s)" % e.last_error)
	# nothing but hello is accepted before the handshake
	var raw := net.connect_client()
	raw.send(1, {"t": "cmd", "seq": 1, "cmd": {"type": "recruit", "country": 0}})
	_pump(host, [])
	check(host.stats["commands"] == 0, "a command before the handshake is ignored")


func test_lockstep_keeps_everybody_identical_for_a_game_year() -> void:
	var g := _game(5)
	var host: NetHost = g[0]
	var net: LoopbackNet = g[1]
	var a := _join(net, host, "Anna")
	var b := _join(net, host, "Boris")
	var clients := [a, b]
	var neighbor: int = host.sim.neighbor_countries(a.country)[0]
	var idle_bytes := 0
	for day in 120:
		if day == 5:
			a.sim.apply_command({"type": "declare_war", "country": a.country, "target": neighbor})   # forwarded to the host
		if day == 1:
			b.sim.apply_command({"type": "recruit", "country": b.country})
		if day == 2:
			host.sim.apply_command({"type": "recruit", "country": host.host_country})
		var before := net.bytes_to_clients
		host.tick()
		_pump(host, clients)
		if day >= 60 and day < 100:
			idle_bytes += net.bytes_to_clients - before
		if not _all_equal(host, clients):
			check(false, "desync on day %d" % host.sim.day)
			return
	check(_all_equal(host, clients), "host and both clients share the exact state after 120 days (day %d)" % host.sim.day)
	check(a.sim.at_war(a.country, neighbor) == host.sim.at_war(a.country, neighbor) and b.sim.at_war(a.country, neighbor) == host.sim.at_war(a.country, neighbor), "a client's command (declare_war) took effect identically everywhere")
	check(a.stats["desyncs"] == 0 and b.stats["desyncs"] == 0, "no desync was reported")
	check(a.stats["ticks"] >= 119 and a.stats["events"] >= 3, "clients applied ticks and events (%d ticks, %d events)" % [a.stats["ticks"], a.stats["events"]])
	var per_tick := float(idle_bytes) / 40.0 / 2.0
	check(per_tick < 400.0, "the map/state is not re-sent: %.0f bytes per tick and client on quiet days" % per_tick)
	check(host.stats["commands"] >= 3 and host.stats["rejected_commands"] <= 3, "commands were accepted by the host (%d)" % host.stats["commands"])
	for c in clients:
		check(c.sim.command_log.size() == host.sim.command_log.size(), "the command log is identical on every peer")


func test_peers_can_only_command_their_own_country() -> void:
	var g := _game()
	var host: NetHost = g[0]
	var net: LoopbackNet = g[1]
	var a := _join(net, host, "Anna")
	var other: int = host.host_country
	var rej_before: int = host.stats["rejected_commands"]
	a.sim.apply_command({"type": "declare_war", "country": other, "target": a.country})   # pretending to be the host
	_pump(host, [a])
	check(host.stats["rejected_commands"] == rej_before + 1 and not host.sim.at_war(other, a.country), "a command for somebody else's country is refused")
	check(a.last_results.size() > 0 and a.last_results[-1]["ok"] == false and a.last_results[-1]["reason"] == "not your country", "the sender is told why")
	# malformed commands never reach the simulation
	for bad in [{"type": 5, "country": 0}, {"type": "recruit"}, {"type": "recruit", "country": 0, "x": Vector2(1, 2)}, {"type": "recruit", "country": a.country, "list": [1, 2]}]:
		a.transport.send(1, {"t": "cmd", "seq": 99, "cmd": bad})
	_pump(host, [a])
	check(host.stats["rejected_commands"] >= rej_before + 5, "malformed commands are rejected (%d)" % host.stats["rejected_commands"])
	a.transport.send(1, {"t": "cmd", "seq": 100, "cmd": "not a dictionary"})
	a.transport.send(1, {"t": "weird"})
	a.transport.send(1, {})
	_pump(host, [a])
	check(host.connected_count() == 1 and _all_equal(host, [a]), "garbage messages do not break the host")


func test_desync_is_detected_and_repaired_from_a_snapshot() -> void:
	var g := _game(1)
	var host: NetHost = g[0]
	var net: LoopbackNet = g[1]
	var a := _join(net, host, "Anna")
	var b := _join(net, host, "Boris")
	for i in 5:
		host.tick()
		_pump(host, [a, b])
	check(_all_equal(host, [a, b]), "in sync before tampering")
	var snap_before: int = a.stats["snapshots"]
	a.sim.countries[a.country]["treasury"] += 12345      # simulate a divergence (a bug, a different float result, a bad packet)
	check(a.sim.checksum() != host.sim.checksum(), "the divergence is visible in the checksum")
	host.tick()
	_pump(host, [a, b], 6)
	check(a.stats["desyncs"] >= 1 and host.stats["desyncs"] >= 1, "the client reported the desync (%s)" % a.last_error)
	check(a.stats["snapshots"] == snap_before + 1, "the client was resynchronised from a snapshot")
	check(b.stats["desyncs"] == 0, "the healthy client was not disturbed")
	for i in 5:
		host.tick()
		_pump(host, [a, b])
	check(_all_equal(host, [a, b]), "all peers are identical again after the repair (day %d)" % host.sim.day)
	check(a.sim.command_sink.is_valid(), "the replaced simulation still forwards commands to the host")


func test_pause_and_time_are_controlled_by_the_host() -> void:
	var g := _game()
	var host: NetHost = g[0]
	var net: LoopbackNet = g[1]
	var a := _join(net, host, "Anna")
	host.set_paused(true)
	var day: int = host.sim.day
	_pump(host, [a])
	check(a.paused and host.tick() == false and host.sim.day == day, "while paused the host does not advance the day")
	_pump(host, [a])
	check(a.sim.day == day, "clients cannot advance time on their own")
	a.request_pause(false)
	_pump(host, [a])
	check(not host.paused and not a.paused, "a client can ask to resume")
	check(host.tick() and host.sim.day == day + 1, "time runs again")
	_pump(host, [a])
	check(a.sim.day == day + 1, "the client followed the host's tick")
	a.ping()
	_pump(host, [a])
	check(a.rtt_ms >= 0, "ping/pong measures latency (%d ms)" % a.rtt_ms)


func test_disconnect_hands_the_country_to_ai_and_reconnect_gets_it_back() -> void:
	var g := _game(1)
	var host: NetHost = g[0]
	var net: LoopbackNet = g[1]
	var a := _join(net, host, "Anna")
	var b := _join(net, host, "Boris")
	var a_country: int = a.country
	var a_token: String = a.token
	for i in 3:
		host.tick()
		_pump(host, [a, b])
	net.drop_client(a.transport.id)   # the cable is pulled
	_pump(host, [a, b])
	check(a.state == "disconnected", "the client noticed the disconnect")
	check(host.sim.countries[a_country]["ai"] == true and host.connected_count() == 1, "the host switched the country to AI and keeps the game going")
	for i in 10:
		host.tick()
		_pump(host, [b])
	check(_all_equal(host, [b]) and b.sim.countries[a_country]["ai"] == true, "the other client sees the same (checksums equal)")
	var a2 := _join(net, host, "Anna", -1, a_token)
	check(a2.state == "playing" and a2.country == a_country, "reconnecting with the token returns the same country")
	check(host.sim.countries[a_country]["ai"] == false and a2.sim.checksum() == host.sim.checksum(), "control is back and the state is identical")
	for i in 5:
		host.tick()
		_pump(host, [a2, b])
	check(_all_equal(host, [a2, b]), "all peers stay in sync after the reconnect")
	var stranger := _join(net, host, "Stranger", -1, "no-such-token")
	check(stranger.state == "playing" and stranger.country != a_country, "an unknown token just joins as a new player")


func test_network_snapshot_equals_a_normal_save() -> void:
	var g := _game()
	var host: NetHost = g[0]
	var net: LoopbackNet = g[1]
	var a := _join(net, host, "Anna")
	for i in 20:
		host.tick()
		_pump(host, [a])
	check(SaveSystem.save(host.sim, "nettest"), "the host can save the running game")
	var loaded := SaveSystem.load_slot("nettest")
	check(loaded != null and loaded.checksum() == host.sim.checksum() and loaded.checksum() == a.sim.checksum(), "a save, the host and the client are all the same state")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://saves/nettest.sav"))
	var pack := NetProtocol.snapshot_pack(host.sim)
	check((pack["snap"] as PackedByteArray).size() < 200 * 1024, "a snapshot is small (%d KB compressed)" % ((pack["snap"] as PackedByteArray).size() / 1024))
	check(NetProtocol.snapshot_unpack({"snap": PackedByteArray([1, 2, 3]), "snap_size": 3}) == null, "a corrupt snapshot is refused, not loaded")


func test_a_peer_that_keeps_drifting_is_removed() -> void:
	var g := _game(1)
	var host: NetHost = g[0]
	var net: LoopbackNet = g[1]
	var a := _join(net, host, "Drifter")
	var b := _join(net, host, "Steady")
	for day in 40:
		a.sim.countries[a.country]["treasury"] += 1     # diverges again after every repair
		host.tick()
		_pump(host, [a, b], 6)
		if a.state == "rejected":
			break
	check(a.state == "rejected" and a.last_error == NetProtocol.R_DESYNC, "after %d resyncs the drifting peer is removed (%s)" % [host.stats["resyncs"], a.last_error])
	check(host.stats["resyncs"] <= NetProtocol.MAX_RESYNCS, "the host sent at most %d snapshots to it" % NetProtocol.MAX_RESYNCS)
	check(b.state == "playing" and b.stats["desyncs"] == 0, "the other player is not affected")
	for i in 3:
		host.tick()
		_pump(host, [b])
	check(_all_equal(host, [b]), "the game goes on for the others")
