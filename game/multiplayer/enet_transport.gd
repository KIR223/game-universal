class_name ENetServerTransport
extends NetTransport
## Real network transport for the host (UDP, reliable ordered channel 0 via ENet).

var conn := ENetConnection.new()
var peers: Dictionary = {}       # id -> ENetPacketPeer
var _ids: Dictionary = {}        # ENetPacketPeer instance id -> id
var _next_id := 2
var open := false


func listen(port: int = NetProtocol.DEFAULT_PORT, max_peers: int = 8, bind_address: String = "*") -> Error:
	var err := conn.create_host_bound(bind_address, port, max_peers, 1, 0, 0)
	open = err == OK
	return err


func poll() -> Array:
	var out: Array = []
	if not open:
		return out
	for _i in 256:
		var ev: Array = conn.service(0)
		var kind: int = ev[0]
		if kind == ENetConnection.EVENT_NONE or kind == ENetConnection.EVENT_ERROR:
			break
		var peer: ENetPacketPeer = ev[1]
		if kind == ENetConnection.EVENT_CONNECT:
			var id := _next_id
			_next_id += 1
			peers[id] = peer
			_ids[peer.get_instance_id()] = id
			out.append({"type": "connect", "peer": id})
		elif kind == ENetConnection.EVENT_DISCONNECT:
			var id2: int = _ids.get(peer.get_instance_id(), -1)
			if id2 >= 0:
				peers.erase(id2)
				_ids.erase(peer.get_instance_id())
				out.append({"type": "disconnect", "peer": id2})
		elif kind == ENetConnection.EVENT_RECEIVE:
			var id3: int = _ids.get(peer.get_instance_id(), -1)
			var v: Variant = bytes_to_var(peer.get_packet())
			if id3 >= 0 and typeof(v) == TYPE_DICTIONARY:
				out.append({"type": "message", "peer": id3, "msg": v})
	return out


func send(peer: int, msg: Dictionary) -> void:
	if peers.has(peer):
		(peers[peer] as ENetPacketPeer).send(0, var_to_bytes(msg), ENetPacketPeer.FLAG_RELIABLE)


func disconnect_peer(peer: int) -> void:
	if peers.has(peer):
		(peers[peer] as ENetPacketPeer).peer_disconnect_later()


func close() -> void:
	if open:
		for id in peers.keys():
			(peers[id] as ENetPacketPeer).peer_disconnect()
		conn.flush()
		conn.destroy()
		open = false
		peers.clear()


func is_open() -> bool:
	return open
