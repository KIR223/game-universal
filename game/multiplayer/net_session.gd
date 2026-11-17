class_name NetSession
extends RefCounted
## What the UI holds while a multiplayer game is running: exactly one of a host or a client, plus the connection
## parameters needed to reconnect. Keeps all multiplayer knowledge out of the UI code.

var host: NetHost = null
var client: NetClient = null
var address := "127.0.0.1"
var port := NetProtocol.DEFAULT_PORT
var player_name := "Player"


static func for_host(h: NetHost) -> NetSession:
	var s := NetSession.new()
	s.host = h
	return s


static func for_client(c: NetClient, addr: String = "127.0.0.1", p: int = NetProtocol.DEFAULT_PORT) -> NetSession:
	var s := NetSession.new()
	s.client = c
	s.address = addr
	s.port = p
	s.player_name = c.player_name
	return s


func is_host() -> bool:
	return host != null


func is_client() -> bool:
	return client != null


func sim() -> Simulation:
	return host.sim if host != null else (client.sim if client != null else null)


func poll() -> void:
	if host != null:
		host.poll()
	elif client != null:
		client.poll()


## Host: advance one game day for everybody (false while paused). Clients never advance time themselves.
func tick() -> bool:
	return host != null and host.tick()


## Client: connect again with the stored token, which returns the player's country (the host made it AI meanwhile).
func reconnect() -> bool:
	if client == null:
		return false
	var t := ENetClientTransport.new()
	if t.connect_to(address, port) != OK:
		return false
	var old := client
	client = NetClient.new(t, player_name, -1, old.token)
	return true


func close() -> void:
	if host != null:
		host.close()
	elif client != null:
		client.close()


func describe() -> String:
	if host != null:
		return "сеть: хост, игроков %d%s" % [host.connected_count() + 1, ", пауза" if host.paused else ""]
	if client != null:
		match client.state:
			"playing":
				return "сеть: клиент%s%s" % [", RTT %d мс" % client.rtt_ms if client.rtt_ms >= 0 else "", ", пауза" if client.paused else ""]
			"connecting", "handshaking":
				return "сеть: подключение…"
			"rejected":
				return "сеть: отказ (%s)" % client.last_error
			_:
				return "сеть: нет соединения"
	return ""
