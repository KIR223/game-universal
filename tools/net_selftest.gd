extends SceneTree
## One side of a real-network (ENet, UDP) test; started twice by tests/net_enet_test.py (host and client processes).
##   godot --headless --path . -s tools/net_selftest.gd -- host   <port> <days>
##   godot --headless --path . -s tools/net_selftest.gd -- client <port> <days> [name]
## Prints HOST_READY / HOST_DONE / CLIENT_JOINED / CLIENT_DONE lines with the final state checksum.

var role := "host"
var port := 24680
var days := 40
var name_ := "Tester"
var host: NetHost
var client: NetClient
var started := 0
var done_frames := 0
var sent_cmd := false
var host_cmd_day := 3
var ready_printed := false
var player_joined := false
var final_sum := 0
var final_day := -1


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	role = a[0] if a.size() > 0 else "host"
	port = int(a[1]) if a.size() > 1 else port
	days = int(a[2]) if a.size() > 2 else days
	name_ = a[3] if a.size() > 3 else name_
	started = Time.get_ticks_msec()
	if role == "host":
		var sim := Simulation.new()
		sim.setup_scenario(ScenarioLoader.read_file("res://game/scenarios/modern_world.json"))
		for e in sim.event_defs:
			sim.disabled_events.append(e["id"])
		var t := ENetServerTransport.new()
		var err := t.listen(port, 8, "127.0.0.1")
		if err != OK:
			print("HOST_FAILED listen error %d" % err)
			quit(2)
			return
		host = NetHost.new(sim, t)
		host.checksum_every = 1
		host.set_host_country(sim.countries.find_custom(func(c): return c["name"] == "Польша"))
	else:
		var ct := ENetClientTransport.new()
		if ct.connect_to("127.0.0.1", port) != OK:
			print("CLIENT_FAILED connect")
			quit(2)
			return
		client = NetClient.new(ct, name_)


func _process(_delta: float) -> bool:
	OS.delay_msec(1)
	if Time.get_ticks_msec() - started > 90000:
		print("%s_TIMEOUT" % role.to_upper())
		quit(3)
		return true
	if role == "host":
		_host_frame()
	else:
		_client_frame()
	return false


func _host_frame() -> void:
	host.poll()
	if not ready_printed:
		ready_printed = true
		print("HOST_READY port=%d" % port)
	if host.connected_count() >= 1:
		player_joined = true
	if not player_joined:
		return   # wait for the client to join before the first day; afterwards the host runs on even if it leaves
	if host.sim.day < days:
		if host.sim.day == host_cmd_day:
			host.sim.apply_command({"type": "recruit", "country": host.host_country})
		host.tick()
		if host.sim.day >= days:
			final_day = host.sim.day
			final_sum = host.sim.checksum()   # the state the client must reach (before anybody disconnects)
	else:
		done_frames += 1
		if done_frames > 120:   # let the last packets flow and the client finish
			print("HOST_DONE day=%d sum=%d desyncs=%d commands=%d rejected=%d players=%d" % [final_day, final_sum, host.stats["desyncs"], host.stats["commands"], host.stats["rejected_commands"], host.players.size()])
			host.close()
			quit(0)


func _client_frame() -> void:
	client.poll()
	if client.state == "rejected" or client.state == "disconnected":
		print("CLIENT_FAILED state=%s error=%s" % [client.state, client.last_error])
		quit(4)
		return
	if client.state != "playing":
		return
	if not sent_cmd:
		sent_cmd = true
		print("CLIENT_JOINED country=%s day=%d" % [client.sim.countries[client.country]["name"], client.sim.day])
		var enemy: int = client.sim.neighbor_countries(client.country)[0]
		client.sim.apply_command({"type": "declare_war", "country": client.country, "target": enemy})   # forwarded to the host over the network
	if client.sim.day >= days:
		print("CLIENT_DONE day=%d sum=%d desyncs=%d snapshots=%d events=%d" % [client.sim.day, client.sim.checksum(), client.stats["desyncs"], client.stats["snapshots"], client.stats["events"]])
		print("CLIENT_RESULTS %s" % str(client.last_results))
		client.close()
		quit(0)
