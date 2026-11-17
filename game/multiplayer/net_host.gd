class_name NetHost
extends RefCounted
## Authoritative host of a multiplayer game. It owns the real Simulation: every command is validated here by
## Simulation.apply_command() and broadcast to all peers ("ev"), every game day is advanced here and announced ("tick").
## Peers never advance time on their own, so time is synchronised by construction (lockstep); every `checksum_every`
## days the tick carries Simulation.checksum() so a peer that drifted is detected and resynchronised from a snapshot.
## See NetProtocol for the wire format.

signal log_added(text: String)

var sim: Simulation
var transport: NetTransport
var checksum_every := 5
var max_players := 8
var allow_client_pause := true
var paused := false
var host_country := -1
var players: Dictionary = {}      # token -> {name, country, peer, connected}
var peer_token: Dictionary = {}   # peer id -> token (only peers that completed the handshake)
var stats := {"ticks": 0, "commands": 0, "rejected_commands": 0, "rejected_peers": 0, "desyncs": 0, "resyncs": 0, "snapshot_bytes": 0}
var _token_counter := 0


func _init(game: Simulation, t: NetTransport) -> void:
	sim = game
	transport = t
	sim.command_hook = _on_command_applied


## The host's own player; every other country stays AI until a client takes it.
func set_host_country(cid: int) -> void:
	host_country = cid
	sim.countries[cid]["ai"] = false


func poll() -> void:
	for ev in transport.poll():
		match ev["type"]:
			"disconnect":
				_on_disconnect(ev["peer"])
			"message":
				_on_message(ev["peer"], ev["msg"])


## Advances one game day for everybody. Returns false while paused.
func tick() -> bool:
	if paused:
		return false
	sim.tick_day()
	var m := {"t": "tick", "day": sim.day}
	if checksum_every > 0 and sim.day % checksum_every == 0:
		m["sum"] = sim.checksum()
	_broadcast(m)
	stats["ticks"] += 1
	return true


func set_paused(p: bool) -> void:
	paused = p
	_broadcast({"t": "pause", "paused": p})


func connected_count() -> int:
	var n := 0
	for tok in players:
		if players[tok]["connected"]:
			n += 1
	return n


func player_list() -> Array:
	var out: Array = []
	if host_country >= 0:
		out.append({"name": "host", "country": host_country, "connected": true, "host": true})
	for tok in players:
		var p: Dictionary = players[tok]
		out.append({"name": p["name"], "country": p["country"], "connected": p["connected"], "host": false})
	return out


func close() -> void:
	sim.command_hook = Callable()
	transport.close()


# ------------------------------------------------------------------ internals

func _log(text: String) -> void:
	log_added.emit(text)


func _broadcast(msg: Dictionary) -> void:
	for peer in peer_token:
		transport.send(peer, msg)


func _on_command_applied(cmd: Dictionary) -> void:
	stats["commands"] += 1
	_broadcast({"t": "ev", "day": sim.day, "k": "cmd", "cmd": cmd})


func _set_ai(cid: int, ai: bool) -> void:
	sim.countries[cid]["ai"] = ai
	_broadcast({"t": "ev", "day": sim.day, "k": "ai", "country": cid, "ai": ai})


func _reject(peer: int, reason: String) -> void:
	stats["rejected_peers"] += 1
	transport.send(peer, {"t": "reject", "reason": reason})
	transport.disconnect_peer(peer)
	_log("rejected a peer: %s" % reason)


func _on_message(peer: int, msg: Dictionary) -> void:
	var t: Variant = msg.get("t")
	if typeof(t) != TYPE_STRING:
		return
	if t == "hello":
		_on_hello(peer, msg)
		return
	if not peer_token.has(peer):
		return   # nothing is accepted before a successful handshake
	match t:
		"cmd":
			_on_command(peer, msg)
		"desync":
			_on_desync(peer)
		"pause_req":
			if allow_client_pause and typeof(msg.get("paused")) == TYPE_BOOL:
				set_paused(msg["paused"])
		"ping":
			transport.send(peer, {"t": "pong", "ts": msg.get("ts", 0)})


func _check_hello(msg: Dictionary) -> String:
	if msg.get("proto") != NetProtocol.VERSION:
		return NetProtocol.R_PROTOCOL
	# the installed geodata set must be byte-identical (stable cell ids); compared by its world_hash, not by the game kind
	if str(msg.get("world_hash", "")) != str(EarthWorld.manifest().get("world_hash", "")):
		return NetProtocol.R_WORLD
	if msg.get("save_version") != Simulation.SAVE_VERSION:
		return NetProtocol.R_SAVE
	if msg.get("rules") != NetProtocol.rules_fingerprint():
		return NetProtocol.R_RULES
	return ""


func _on_hello(peer: int, msg: Dictionary) -> void:
	if peer_token.has(peer):
		return
	var bad := _check_hello(msg)
	if bad != "":
		_reject(peer, bad)
		return
	var token := str(msg.get("token", ""))
	var pl: Dictionary
	if token != "" and players.has(token):
		pl = players[token]   # reconnect: the player gets the same country back
		if pl["connected"]:
			peer_token.erase(pl["peer"])
			transport.disconnect_peer(pl["peer"])
	else:
		if connected_count() >= max_players:
			_reject(peer, NetProtocol.R_FULL)
			return
		var want: Variant = msg.get("country", -1)
		var cid := _assign_country(want if typeof(want) == TYPE_INT else -1)
		if cid < 0:
			_reject(peer, NetProtocol.R_COUNTRY)
			return
		_token_counter += 1
		token = "%d-%d" % [_token_counter, randi()]
		pl = {"name": "", "country": cid, "peer": peer, "connected": false}
		players[token] = pl
	pl["name"] = NetProtocol.clean_name(msg.get("name"))
	pl["peer"] = peer
	pl["connected"] = true
	_set_ai(pl["country"], false)       # announced to the OTHER peers; the newcomer gets it inside the snapshot
	peer_token[peer] = token
	var welcome := {"t": "welcome", "proto": NetProtocol.VERSION, "token": token, "country": pl["country"], "day": sim.day, "paused": paused, "players": player_list()}
	welcome.merge(_pack())
	transport.send(peer, welcome)
	_broadcast({"t": "players", "players": player_list()})
	_log("%s joined as %s" % [pl["name"], sim.countries[pl["country"]]["name"]])


func _pack() -> Dictionary:
	var p := NetProtocol.snapshot_pack(sim)
	stats["snapshot_bytes"] += (p["snap"] as PackedByteArray).size()
	return p


## A free, alive, AI-controlled country: the requested one, or the first suitable one.
func _assign_country(want: int) -> int:
	var taken := {}
	for tok in players:
		taken[players[tok]["country"]] = true
	if host_country >= 0:
		taken[host_country] = true
	var ok := func(cid: int) -> bool:
		return cid >= 0 and cid < sim.countries.size() and sim.countries[cid]["alive"] and sim.countries[cid]["ai"] and not taken.has(cid)
	if want >= 0:
		return want if ok.call(want) else -1
	for c in sim.countries:
		if ok.call(c["id"]) and not sim.cells_of(c["id"]).is_empty():
			return c["id"]
	return -1


func _on_command(peer: int, msg: Dictionary) -> void:
	var seq: Variant = msg.get("seq", 0)
	var cmd: Variant = msg.get("cmd")
	var reason := ""
	if not NetProtocol.command_is_sane(cmd):
		reason = NetProtocol.R_BAD
	elif cmd["country"] != players[peer_token[peer]]["country"]:
		reason = "not your country"   # a peer can only command its own country
	if reason != "":
		stats["rejected_commands"] += 1
		transport.send(peer, {"t": "result", "seq": seq, "ok": false, "reason": reason})
		return
	var res := sim.apply_command(cmd)   # command_hook broadcasts it to everyone (the sender included)
	if not res["ok"]:
		stats["rejected_commands"] += 1
	transport.send(peer, {"t": "result", "seq": seq, "ok": res["ok"], "reason": res.get("reason", "")})


func _on_desync(peer: int) -> void:
	stats["desyncs"] += 1
	var token: String = peer_token[peer]
	players[token]["resyncs"] = int(players[token].get("resyncs", 0)) + 1
	if players[token]["resyncs"] > NetProtocol.MAX_RESYNCS:
		_reject(peer, NetProtocol.R_DESYNC)   # it keeps drifting: a snapshot flood helps nobody
		return
	stats["resyncs"] += 1
	var snap := {"t": "snapshot", "day": sim.day}
	snap.merge(_pack())
	transport.send(peer, snap)
	_log("peer %d out of sync: snapshot sent" % peer)


func _on_disconnect(peer: int) -> void:
	if not peer_token.has(peer):
		return
	var token: String = peer_token[peer]
	peer_token.erase(peer)
	var pl: Dictionary = players[token]
	if pl["peer"] != peer:
		return   # the player already reconnected on another connection
	pl["connected"] = false
	_set_ai(pl["country"], true)       # the country keeps playing under AI until the player returns
	_broadcast({"t": "players", "players": player_list()})
	_log("%s disconnected: %s is AI-controlled" % [pl["name"], sim.countries[pl["country"]]["name"]])
