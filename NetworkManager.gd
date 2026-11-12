extends Node
## NetworkManager (autoload)
## Host / client / headless dedicated server + lobby state.
##
## Command line (after `--`, or directly):
##   --server            run as dedicated server (automatic when headless)
##   --port=7777         UDP port (or env TETHERBOUND_PORT)
##   --seed=12345        fixed world seed
##   --join=IP[:PORT]    join a host straight from launch (also accepts an invite code)
##   --name=Callsign     player name

signal lobby_changed
signal player_registered(id: int)
signal player_unregistered(id: int)
signal session_started
signal session_ended(reason: String)
signal status_changed(text: String)

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 4
const PLAYER_COLORS: Array[Color] = [
	Color(1.0, 0.42, 0.54),
	Color(0.95, 0.76, 0.38),
	Color(0.39, 0.87, 0.75),
	Color(0.72, 0.61, 1.0),
]
const B36 := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

## id -> {"name": String, "slot": int}
var players: Dictionary = {}
var is_dedicated := false
var in_session := false
var solo := false
var port := DEFAULT_PORT
var world_seed := 20261
var local_name := "Resonator"
## Last status line, kept so the menu can show why a session ended.
var last_status := ""

var _seed_forced := false
var _join_timer := 0.0
var _joining := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	var env_port := OS.get_environment("TETHERBOUND_PORT")
	if env_port.is_valid_int():
		port = env_port.to_int()

	var want_server := false
	var join_target := ""
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for arg in args:
		if arg == "--server":
			want_server = true
		elif arg.begins_with("--port="):
			port = arg.get_slice("=", 1).to_int()
		elif arg.begins_with("--seed="):
			world_seed = arg.get_slice("=", 1).to_int()
			_seed_forced = true
		elif arg.begins_with("--join="):
			join_target = arg.get_slice("=", 1)
		elif arg.begins_with("--name="):
			local_name = arg.get_slice("=", 1).left(16)

	if join_target != "":
		join.call_deferred(join_target)
	elif want_server or is_headless():
		host.call_deferred(true)


func _process(delta: float) -> void:
	if _joining:
		_join_timer -= delta
		if _join_timer <= 0.0:
			_joining = false
			_reset_peer()
			status_changed.emit("Could not reach the host. Check the address and that UDP port %d is open." % port)


func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


func get_sorted_ids() -> Array:
	var ids: Array = players.keys()
	ids.sort()
	return ids


func get_slot(id: int) -> int:
	if players.has(id):
		return int(players[id]["slot"])
	return 0


func get_color(id: int) -> Color:
	return PLAYER_COLORS[get_slot(id) % PLAYER_COLORS.size()]


func get_player_name(id: int) -> String:
	if players.has(id):
		return str(players[id]["name"])
	return "Resonator"


# ---------------------------------------------------------------- sessions

func host(dedicated: bool = false) -> int:
	leave(false)
	var peer := ENetMultiplayerPeer.new()
	var err: int = peer.create_server(port, MAX_PLAYERS if dedicated else MAX_PLAYERS - 1)
	if err != OK:
		status_changed.emit("Could not open UDP port %d (error %d). Is another host running?" % [port, err])
		push_error("TETHERBOUND: create_server failed on port %d (error %d)" % [port, err])
		if dedicated:
			get_tree().quit(1)
		return err
	multiplayer.multiplayer_peer = peer
	is_dedicated = dedicated
	solo = false
	if not _seed_forced:
		randomize()
		world_seed = randi() % 1000000
	in_session = true
	if not dedicated:
		_add_player(1, local_name)
	print("TETHERBOUND: %s on UDP %d, seed %d" % ["dedicated server" if dedicated else "hosting", port, world_seed])
	status_changed.emit("Hosting on port %d." % port)
	session_started.emit()
	return OK


func join(target: String) -> int:
	leave(false)
	var address := target.strip_edges()
	var join_port := port
	if address.to_upper().begins_with("TB-"):
		var decoded: Dictionary = decode_invite_code(address)
		if decoded.is_empty():
			status_changed.emit("That invite code is not valid.")
			return ERR_INVALID_PARAMETER
		address = str(decoded["ip"])
		join_port = int(decoded["port"])
	elif address.count(":") == 1:
		join_port = address.get_slice(":", 1).to_int()
		address = address.get_slice(":", 0)
	if address == "":
		address = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var err: int = peer.create_client(address, join_port)
	if err != OK:
		status_changed.emit("Could not start a connection to %s (error %d)." % [address, err])
		return err
	multiplayer.multiplayer_peer = peer
	solo = false
	is_dedicated = false
	_joining = true
	_join_timer = 8.0
	status_changed.emit("Connecting to %s:%d ..." % [address, join_port])
	return OK


func start_solo() -> void:
	leave(false)
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	solo = true
	is_dedicated = false
	if not _seed_forced:
		randomize()
		world_seed = randi() % 1000000
	in_session = true
	_add_player(1, local_name)
	session_started.emit()


func leave(announce: bool = true, reason: String = "") -> void:
	var was_in_session := in_session
	_joining = false
	_reset_peer()
	players.clear()
	in_session = false
	solo = false
	is_dedicated = false
	if announce and was_in_session:
		last_status = reason
		session_ended.emit(reason)


func _reset_peer() -> void:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer != null and not (peer is OfflineMultiplayerPeer):
		peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


# ------------------------------------------------------------------- lobby

func _add_player(id: int, player_name: String) -> void:
	_insert_player(id, player_name)
	lobby_changed.emit()
	player_registered.emit(id)


func _insert_player(id: int, player_name: String) -> void:
	var used := {}
	for existing in players.values():
		used[int(existing["slot"])] = true
	var slot := 0
	while used.has(slot):
		slot += 1
	var clean := player_name.strip_edges().left(16)
	if clean == "":
		clean = "Resonator"
	players[id] = {"name": clean, "slot": slot}


func _on_peer_connected(_id: int) -> void:
	pass  # Clients introduce themselves with _register once connected.


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	if players.has(id):
		print("TETHERBOUND: peer %d left" % id)
		players.erase(id)
		player_unregistered.emit(id)
		lobby_changed.emit()
		_lobby.rpc(players)


func _on_connected_to_server() -> void:
	_register.rpc_id(1, local_name)


func _on_connection_failed() -> void:
	_joining = false
	_reset_peer()
	status_changed.emit("Connection failed.")


func _on_server_disconnected() -> void:
	leave(true, "The host closed the session.")


@rpc("any_peer", "call_remote", "reliable")
func _register(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if players.has(sender):
		return
	if players.size() >= MAX_PLAYERS:
		var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
		if enet != null:
			enet.disconnect_peer(sender)
		return
	print("TETHERBOUND: peer %d joined as '%s'" % [sender, player_name.left(16)])
	# Order matters: the newcomer learns the seed and its slot first, then the
	# game spawns its Resonator and sends the shared state.
	_insert_player(sender, player_name)
	_welcome.rpc_id(sender, world_seed, players)
	lobby_changed.emit()
	player_registered.emit(sender)
	_lobby.rpc(players)


@rpc("authority", "call_remote", "reliable")
func _welcome(server_seed: int, lobby: Dictionary) -> void:
	_joining = false
	world_seed = server_seed
	players = lobby
	in_session = true
	lobby_changed.emit()
	session_started.emit()


@rpc("authority", "call_remote", "reliable")
func _lobby(lobby: Dictionary) -> void:
	players = lobby
	lobby_changed.emit()


# ------------------------------------------------------------ invite codes

func get_local_ip() -> String:
	var fallback := "127.0.0.1"
	for address in IP.get_local_addresses():
		if address.count(".") != 3:
			continue
		if address.begins_with("127.") or address.begins_with("169.254."):
			continue
		if address.begins_with("192.168.") or address.begins_with("10."):
			return address
		fallback = address
	return fallback


## Invite code = this machine's LAN IPv4 + port in base 36, e.g. "TB-1HGE9P5-5ZL".
## It only works for players who can reach that address (same network, VPN,
## or a forwarded port); for internet play share your public IP instead.
func get_invite_code() -> String:
	var parts: PackedStringArray = get_local_ip().split(".")
	var value := 0
	for part in parts:
		value = value * 256 + part.to_int()
	return "TB-%s-%s" % [_to_base36(value), _to_base36(port)]


func decode_invite_code(code: String) -> Dictionary:
	var parts: PackedStringArray = code.strip_edges().to_upper().split("-")
	if parts.size() != 3 or parts[0] != "TB":
		return {}
	var value := _from_base36(parts[1])
	var decoded_port := _from_base36(parts[2])
	if value < 0 or decoded_port <= 0 or decoded_port > 65535:
		return {}
	var ip := "%d.%d.%d.%d" % [(value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255]
	return {"ip": ip, "port": decoded_port}


func _to_base36(value: int) -> String:
	if value <= 0:
		return "0"
	var out := ""
	while value > 0:
		out = B36[value % 36] + out
		@warning_ignore("integer_division")
		value = value / 36
	return out


func _from_base36(text: String) -> int:
	if text == "":
		return -1
	var value := 0
	for i in text.length():
		var digit := B36.find(text[i])
		if digit < 0:
			return -1
		value = value * 36 + digit
	return value
