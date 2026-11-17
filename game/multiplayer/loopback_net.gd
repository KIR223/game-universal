class_name LoopbackNet
extends RefCounted
## In-memory network for deterministic tests: one server endpoint and any number of client endpoints.
## Every message makes a var_to_bytes round trip like on a real wire (types survive exactly as they would over ENet).

class Endpoint extends NetTransport:
	var net: LoopbackNet
	var id := 1
	var is_server := false
	var open := true
	var inbox: Array = []

	func poll() -> Array:
		var out := inbox
		inbox = []
		return out

	func send(peer: int, msg: Dictionary) -> void:
		if not open:
			return
		if is_server:
			net._to_client(peer, msg)
		else:
			net._to_server(id, msg)

	func disconnect_peer(peer: int) -> void:
		if is_server:
			net.drop_client(peer)

	func close() -> void:
		if is_server:
			for cid in net.clients.keys():
				net.drop_client(cid)
		else:
			net.drop_client(id)
		open = false

	func is_open() -> bool:
		return open

var server := Endpoint.new()
var clients: Dictionary = {}
var next_id := 2
var bytes_to_clients := 0
var bytes_to_server := 0
var messages_to_clients := 0


func _init() -> void:
	server.net = self
	server.is_server = true


func connect_client() -> Endpoint:
	var c := Endpoint.new()
	c.net = self
	c.id = next_id
	next_id += 1
	clients[c.id] = c
	server.inbox.append({"type": "connect", "peer": c.id})
	c.inbox.append({"type": "connect", "peer": 1})
	return c


## Abrupt disconnect of one client (as if the network cable was pulled): both sides get a disconnect event.
func drop_client(id: int) -> void:
	if not clients.has(id):
		return
	var c: Endpoint = clients[id]
	clients.erase(id)
	if c.open:
		c.open = false
		c.inbox.append({"type": "disconnect", "peer": 1})
	server.inbox.append({"type": "disconnect", "peer": id})


func _wire(msg: Dictionary) -> Array:
	var raw := var_to_bytes(msg)
	return [bytes_to_var(raw), raw.size()]


func _to_client(id: int, msg: Dictionary) -> void:
	if not clients.has(id):
		return
	var w := _wire(msg)
	bytes_to_clients += w[1]
	messages_to_clients += 1
	(clients[id] as Endpoint).inbox.append({"type": "message", "peer": 1, "msg": w[0]})


func _to_server(id: int, msg: Dictionary) -> void:
	if not clients.has(id):
		return
	var w := _wire(msg)
	bytes_to_server += w[1]
	server.inbox.append({"type": "message", "peer": id, "msg": w[0]})
