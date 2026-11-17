class_name ENetClientTransport
extends NetTransport
## Real network transport for a client (the host is always peer 1).

var conn := ENetConnection.new()
var peer: ENetPacketPeer = null
var open := false
var _connected := false


func connect_to(address: String, port: int = NetProtocol.DEFAULT_PORT) -> Error:
	var err := conn.create_host(1, 1, 0, 0)
	if err != OK:
		return err
	peer = conn.connect_to_host(address, port, 1)
	open = peer != null
	return OK if open else ERR_CANT_CONNECT


func poll() -> Array:
	var out: Array = []
	if not open:
		return out
	for _i in 256:
		var ev: Array = conn.service(0)
		var kind: int = ev[0]
		if kind == ENetConnection.EVENT_NONE or kind == ENetConnection.EVENT_ERROR:
			break
		if kind == ENetConnection.EVENT_CONNECT:
			_connected = true
			out.append({"type": "connect", "peer": 1})
		elif kind == ENetConnection.EVENT_DISCONNECT:
			open = false
			out.append({"type": "disconnect", "peer": 1})
		elif kind == ENetConnection.EVENT_RECEIVE:
			var v: Variant = bytes_to_var((ev[1] as ENetPacketPeer).get_packet())
			if typeof(v) == TYPE_DICTIONARY:
				out.append({"type": "message", "peer": 1, "msg": v})
	return out


func send(_peer: int, msg: Dictionary) -> void:
	if open and peer != null:
		peer.send(0, var_to_bytes(msg), ENetPacketPeer.FLAG_RELIABLE)


func close() -> void:
	if open and peer != null:
		peer.peer_disconnect()
		conn.flush()
	conn.destroy()
	open = false


func is_open() -> bool:
	return open
