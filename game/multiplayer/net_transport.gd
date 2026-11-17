class_name NetTransport
extends RefCounted
## Message transport used by NetHost / NetClient. Implementations: LoopbackNet (in memory, for tests) and ENet (real network).
## poll() returns events: {"type": "connect" | "disconnect", "peer": int} and {"type": "message", "peer": int, "msg": Dictionary}.
## On the client side the host is always peer 1.

func poll() -> Array:
	return []


func send(_peer: int, _msg: Dictionary) -> void:
	pass


func disconnect_peer(_peer: int) -> void:
	pass


func close() -> void:
	pass


func is_open() -> bool:
	return false
