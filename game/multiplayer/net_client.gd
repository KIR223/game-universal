class_name NetClient
extends RefCounted
## Client of a multiplayer game. Holds its own Simulation copy, never advances time by itself: it applies the host's
## "ev" events and "tick" day announcements in order. Commands issued through Simulation.apply_command() are
## forwarded to the host (command_sink); they take effect when the host broadcasts them back.
## A checksum mismatch or a failed event is a desync: the client asks for a snapshot and continues from it.

signal sim_replaced
signal state_changed(state: String)
signal log_added(text: String)

var transport: NetTransport
var sim: Simulation = null
var state := "connecting"      # connecting | handshaking | playing | rejected | disconnected
var country := -1
var token := ""
var player_name := "Player"
var want_country := -1
var paused := false
var players: Array = []
var last_error := ""
var rtt_ms := -1
var hello_overrides: Dictionary = {}   # tests: tamper with the handshake (wrong version, wrong world hash, ...)
var stats := {"ticks": 0, "events": 0, "desyncs": 0, "snapshots": 0, "results_failed": 0}
var last_results: Array = []
var _seq := 0
var _awaiting_snapshot := false
var _ping_sent := 0


func _init(t: NetTransport, name: String = "Player", country_wanted: int = -1, saved_token: String = "") -> void:
	transport = t
	player_name = name
	want_country = country_wanted
	token = saved_token


func poll() -> void:
	for ev in transport.poll():
		match ev["type"]:
			"connect":
				_set_state("handshaking")
				var hello := {"t": "hello", "proto": NetProtocol.VERSION, "save_version": Simulation.SAVE_VERSION,
					"world_hash": "", "rules": NetProtocol.rules_fingerprint(), "name": player_name, "country": want_country, "token": token}
				hello["world_hash"] = str(_expected_world_hash())
				hello.merge(hello_overrides, true)
				transport.send(1, hello)
			"disconnect":
				if state != "rejected":
					_set_state("disconnected")
			"message":
				_on_message(ev["msg"])


## The world data hash this client has installed (the host's snapshot must use the same data).
func _expected_world_hash() -> String:
	return str(EarthWorld.manifest().get("world_hash", ""))


## Forwards a command to the host; the result arrives later (last_results). Installed as Simulation.command_sink.
func submit(cmd: Dictionary) -> Dictionary:
	_seq += 1
	transport.send(1, {"t": "cmd", "seq": _seq, "cmd": cmd})
	return {"ok": true, "pending": true, "seq": _seq}


func request_pause(p: bool) -> void:
	transport.send(1, {"t": "pause_req", "paused": p})


func ping() -> void:
	_ping_sent = Time.get_ticks_msec()
	transport.send(1, {"t": "ping", "ts": _ping_sent})


func close() -> void:
	transport.close()
	_set_state("disconnected")


# ------------------------------------------------------------------ internals

func _set_state(s: String) -> void:
	if state != s:
		state = s
		state_changed.emit(s)


func _install(new_sim: Simulation) -> void:
	sim = new_sim
	sim.command_sink = submit
	_awaiting_snapshot = false
	sim_replaced.emit()


func _on_message(msg: Dictionary) -> void:
	var t: Variant = msg.get("t")
	if typeof(t) != TYPE_STRING:
		return
	match t:
		"welcome":
			var s := NetProtocol.snapshot_unpack(msg)
			if s == null:
				last_error = "bad snapshot"
				_set_state("rejected")
				return
			token = str(msg.get("token", ""))
			country = int(msg.get("country", -1))
			paused = bool(msg.get("paused", false))
			players = msg.get("players", [])
			_install(s)
			_set_state("playing")
			log_added.emit("joined as %s (day %d)" % [s.countries[country]["name"], s.day])
		"reject":
			last_error = str(msg.get("reason", "rejected"))
			_set_state("rejected")
			log_added.emit("rejected by the host: %s" % last_error)
		"ev":
			if state == "playing" and not _awaiting_snapshot:
				_on_event(msg)
		"tick":
			if state == "playing" and not _awaiting_snapshot:
				_on_tick(msg)
		"snapshot":
			var s2 := NetProtocol.snapshot_unpack(msg)
			if s2 != null:
				stats["snapshots"] += 1
				_install(s2)
				log_added.emit("resynchronised from a snapshot (day %d)" % s2.day)
		"result":
			last_results.append(msg)
			if last_results.size() > 32:
				last_results.pop_front()
			if not bool(msg.get("ok", false)):
				stats["results_failed"] += 1
		"pause":
			paused = bool(msg.get("paused", false))
		"players":
			players = msg.get("players", [])
		"pong":
			rtt_ms = Time.get_ticks_msec() - int(msg.get("ts", 0))


func _on_event(msg: Dictionary) -> void:
	stats["events"] += 1
	if msg.get("day") != sim.day:
		_desync("event for day %s while at day %d" % [str(msg.get("day")), sim.day])
		return
	if msg.get("k") == "cmd":
		var res := sim.apply_remote_command(msg["cmd"])
		if not res["ok"]:
			_desync("host command failed here: %s" % str(res.get("reason", "")))
	elif msg.get("k") == "ai":
		var cid: int = int(msg.get("country", -1))
		if cid >= 0 and cid < sim.countries.size():
			sim.countries[cid]["ai"] = bool(msg.get("ai", true))


func _on_tick(msg: Dictionary) -> void:
	if msg.get("day") != sim.day + 1:
		_desync("tick for day %s while at day %d" % [str(msg.get("day")), sim.day])
		return
	sim.tick_day()
	stats["ticks"] += 1
	if msg.has("sum") and sim.checksum() != msg["sum"]:
		_desync("checksum mismatch on day %d" % sim.day)


func _desync(reason: String) -> void:
	stats["desyncs"] += 1
	last_error = reason
	_awaiting_snapshot = true   # ignore events/ticks until the host's snapshot arrives
	log_added.emit("DESYNC: %s" % reason)
	transport.send(1, {"t": "desync", "day": sim.day, "sum": sim.checksum()})
