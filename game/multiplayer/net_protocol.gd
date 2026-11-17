class_name NetProtocol
extends RefCounted
## Wire protocol of the cross-platform multiplayer (authoritative host + deterministic lockstep).
##
## Messages are Dictionaries with a "t" (type) key, serialised with var_to_bytes (platform independent, no objects).
##   client -> host: hello, cmd, desync, pause_req, ping
##   host -> client: welcome, reject, ev, tick, result, pause, players, snapshot, pong
## Only commands and day ticks cross the network; the whole state is sent only on join / resync (zstd compressed, ~50 KB).
## `ev` (a validated command or a controller change) and `tick` travel on one reliable ordered channel, so every peer
## applies the same events in the same order before the same tick_day(): identical state, verified by checksum().

const VERSION := 1          # bump on ANY incompatible change of messages or of the simulation rules used online
const DEFAULT_PORT := 24680
const MAX_NAME := 24
const MAX_COMMAND_FIELDS := 16
const MAX_STRING := 128

## Rejection reasons (host -> client "reject")
const R_PROTOCOL := "protocol version mismatch"
const R_WORLD := "world data mismatch"
const R_SAVE := "save format mismatch"
const R_FULL := "game is full"
const R_COUNTRY := "country is not available"
const R_BAD := "malformed message"
const R_RULES := "game rules mismatch (different game version or platform arithmetic)"
const R_DESYNC := "too many desyncs"
const MAX_RESYNCS := 5      # per player; a peer that keeps drifting is not playing the same game


static func snapshot_pack(sim: Simulation) -> Dictionary:
	var raw := var_to_bytes(sim.to_dict())
	return {"snap": raw.compress(FileAccess.COMPRESSION_ZSTD), "snap_size": raw.size()}


## Returns the restored Simulation, or null if the snapshot is unusable.
static func snapshot_unpack(msg: Dictionary) -> Simulation:
	if not (msg.get("snap") is PackedByteArray) or typeof(msg.get("snap_size")) != TYPE_INT:
		return null
	var size: int = msg["snap_size"]
	if size <= 0 or size > 256 * 1024 * 1024:
		return null
	var raw: PackedByteArray = (msg["snap"] as PackedByteArray).decompress(size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != size:
		return null
	var d: Variant = bytes_to_var(raw)
	if typeof(d) != TYPE_DICTIONARY:
		return null
	var sim := Simulation.from_dict(d, Simulation.load_country_defs())
	return null if sim.load_error != "" else sim


## A command received from a client must be a small dictionary of plain values; the simulation validates the rest.
static func command_is_sane(cmd: Variant) -> bool:
	if typeof(cmd) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = cmd
	if d.size() > MAX_COMMAND_FIELDS or typeof(d.get("type")) != TYPE_STRING or typeof(d.get("country")) != TYPE_INT:
		return false
	for k in d:
		if typeof(k) != TYPE_STRING or (k as String).length() > 32:
			return false
		var v: Variant = d[k]
		match typeof(v):
			TYPE_INT, TYPE_BOOL, TYPE_FLOAT:
				pass
			TYPE_STRING:
				if (v as String).length() > MAX_STRING:
					return false
			_:
				return false
	return true


static func clean_name(raw: Variant) -> String:
	var s := str(raw).strip_edges().substr(0, MAX_NAME)
	return s if s != "" else "Player"


static var _rules_fp := 0

## Fingerprint of the simulation RULES: the state checksum of a short fixed game (procedural world, fixed seed).
## Two builds (or two platforms) that compute the same fingerprint will compute the same game; a mismatch is caught
## at the handshake instead of as endless desyncs. Cached (about 0.3 s the first time).
static func rules_fingerprint() -> int:
	if _rules_fp == 0:
		var sim := Simulation.new()
		sim.setup(20261117, Simulation.load_country_defs())
		for _i in 40:
			sim.tick_day()
		_rules_fp = sim.checksum()
	return _rules_fp
