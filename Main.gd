extends Node3D
## Main - game orchestration.
## The server (host, solo, or dedicated) owns the shared state: storm level,
## collected cores, solved monolith puzzles, toppled titans, lightning, and
## spawning. Clients ask through request_* and receive do_* broadcasts.

const PLAYER_SCENE: PackedScene = preload("res://scenes/Player.tscn")
const ATMOSPHERE_SCRIPT: Script = preload("res://scripts/Atmosphere.gd")
const Fx = preload("res://scripts/Fx.gd")
const TUTORIAL_SCRIPT: Script = preload("res://scripts/Tutorial.gd")
const CORE_GOAL_STEP := 5
const RING_WINDOW := 45.0

@onready var world: Node3D = $WorldGenerator
@onready var ark: Node3D = $Ark
@onready var players_root: Node3D = $Players
@onready var tether: Node3D = $TetherSystem
@onready var sound: Node = $Soundscape
@onready var hud: CanvasLayer = $HUD
@onready var menu: CanvasLayer = $MainMenu
@onready var menu_camera: Camera3D = $MenuCamera
@onready var world_environment: WorldEnvironment = $WorldEnvironment

var storm := 0.15
var cores := 0
var core_goal := CORE_GOAL_STEP
var revealed := {}
var collected := {}
var toppled := {}

var _ring_times := {}
## Set by Tutorial.gd: freezes the storm and removes the puzzle time limit.
var tutorial_active := false
var _sync_timer := 0.0
var _lightning_timer := 8.0
var _orbit := 0.0
var _time := 0.0


func _enter_tree() -> void:
	add_to_group("game")


func _ready() -> void:
	NetworkManager.player_registered.connect(_on_player_registered)
	NetworkManager.player_unregistered.connect(_on_player_unregistered)
	NetworkManager.session_started.connect(_on_session_started)
	NetworkManager.session_ended.connect(_on_session_ended)
	hud.visible = false
	menu.visible = not NetworkManager.is_headless()
	menu_camera.current = true
	if not NetworkManager.is_headless():
		var atmosphere := Node3D.new()
		atmosphere.name = "Atmosphere"
		atmosphere.set_script(ATMOSPHERE_SCRIPT)
		add_child(atmosphere)
	if NetworkManager.in_session:
		_on_session_started()


func get_local_player() -> Node3D:
	if not NetworkManager.in_session or NetworkManager.is_dedicated:
		return null
	return players_root.get_node_or_null(str(multiplayer.get_unique_id())) as Node3D


## Which of an island's monoliths have been rung (idx -> time).
func get_ring_progress(key: String) -> Dictionary:
	var times: Dictionary = _ring_times.get(key, {})
	return times


func get_players() -> Array:
	var out: Array = []
	for child in players_root.get_children():
		if child is CharacterBody3D and not child.is_queued_for_deletion():
			out.append(child)
	return out


# ---------------------------------------------------------------- sessions

func _on_session_started() -> void:
	menu.visible = false
	hud.visible = not NetworkManager.is_dedicated
	storm = 0.15
	cores = 0
	core_goal = CORE_GOAL_STEP
	revealed.clear()
	collected.clear()
	toppled.clear()
	world.set_seed(NetworkManager.world_seed)
	if NetworkManager.solo and not NetworkManager.is_headless() and not has_node("Tutorial"):
		var tutorial := CanvasLayer.new()
		tutorial.name = "Tutorial"
		tutorial.set_script(TUTORIAL_SCRIPT)
		add_child.call_deferred(tutorial)
	if multiplayer.is_server():
		# Players registered before this scene was listening (host / solo).
		for id in NetworkManager.get_sorted_ids():
			_spawn_player(id)


func _on_session_ended(_reason: String) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()


func _on_player_registered(id: int) -> void:
	if not multiplayer.is_server() or not NetworkManager.in_session:
		return
	_spawn_player(id)
	if id != multiplayer.get_unique_id():
		full_state.rpc_id(id, revealed, collected, toppled, cores, core_goal, storm)


func _on_player_unregistered(id: int) -> void:
	var node := players_root.get_node_or_null(str(id))
	if node != null:
		node.queue_free()


func _spawn_player(id: int) -> void:
	if players_root.has_node(str(id)):
		return
	var player := PLAYER_SCENE.instantiate()
	player.name = str(id)
	players_root.add_child(player, true)


# -------------------------------------------------------------- game loop

func _process(delta: float) -> void:
	_time += delta
	var local := get_local_player()
	if local == null:
		_orbit += delta * 0.12
		var focus: Vector3 = ark.global_position
		menu_camera.global_position = focus + Vector3(cos(_orbit) * 46.0, 14.0, sin(_orbit) * 46.0)
		menu_camera.look_at(focus + Vector3(0, 2, 0), Vector3.UP)
		if not menu_camera.current:
			menu_camera.current = true
		RenderingServer.global_shader_parameter_set("player_position", Vector3(0, -1000, 0))
	else:
		RenderingServer.global_shader_parameter_set("player_position", local.global_position)
	RenderingServer.global_shader_parameter_set("storm_intensity", storm)
	var env: Environment = world_environment.environment
	if env != null:
		env.volumetric_fog_density = lerpf(0.0012, 0.007, storm)

	if NetworkManager.in_session and multiplayer.is_server():
		_server_tick(delta)


func _server_tick(delta: float) -> void:
	if get_players().is_empty():
		return
	if not tutorial_active:
		storm = clampf(storm + delta * 0.0018, 0.0, 1.0)
	if storm >= 1.0:
		storm = 0.4
		do_surge.rpc()
	_sync_timer -= delta
	if _sync_timer <= 0.0:
		_sync_timer = 1.0
		sync_state.rpc(storm, cores, core_goal)
	_lightning_timer -= delta
	if _lightning_timer <= 0.0:
		_lightning_timer = lerpf(14.0, 4.0, storm) * randf_range(0.7, 1.3)
		var list := get_players()
		var target: Node3D = list[randi() % list.size()]
		if world.get_biome_at(target.global_position) == world.BIOME_SPIRES:
			do_lightning.rpc(world.random_spire_near(target.global_position))


# --------------------------------------------------------------- requests
# Called locally by gameplay code; routed to the server.

func request_ring(key: String, idx: int) -> void:
	if multiplayer.is_server():
		_server_ring(key, idx)
	else:
		_rpc_ring.rpc_id(1, key, idx)


func request_topple(key: String) -> void:
	if multiplayer.is_server():
		_server_topple(key)
	else:
		_rpc_topple.rpc_id(1, key)


func request_collect(key: String) -> void:
	if multiplayer.is_server():
		_server_collect(key)
	else:
		_rpc_collect.rpc_id(1, key)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_ring(key: String, idx: int) -> void:
	if multiplayer.is_server():
		_server_ring(key, idx)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_topple(key: String) -> void:
	if multiplayer.is_server():
		_server_topple(key)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_collect(key: String) -> void:
	if multiplayer.is_server():
		_server_collect(key)


func _server_ring(key: String, idx: int) -> void:
	if idx < 0 or idx > 2:
		return
	var times: Dictionary = _ring_times.get(key, {})
	if times.has(idx) and _time - float(times[idx]) < 1.5:
		return
	times[idx] = _time
	_ring_times[key] = times
	do_ring.rpc(key, idx)
	if revealed.has(key):
		return
	var solved := times.size() == 3
	for t in times.values():
		if not tutorial_active and _time - float(t) > RING_WINDOW:
			solved = false
	if solved:
		revealed[key] = true
		do_reveal.rpc(key)


func _server_topple(key: String) -> void:
	if toppled.has(key):
		return
	toppled[key] = true
	revealed[key] = true
	do_topple.rpc(key)


func _server_collect(key: String) -> void:
	if collected.has(key):
		return
	collected[key] = true
	cores += 1
	storm = maxf(0.0, storm - 0.2)
	var stabilized := cores >= core_goal
	if stabilized:
		core_goal += CORE_GOAL_STEP
		storm = 0.0
	do_collect.rpc(key, cores, core_goal, stabilized)


# ------------------------------------------------------------- broadcasts

@rpc("authority", "call_local", "reliable")
func do_ring(key: String, idx: int) -> void:
	world.ring_monolith(key, idx)
	var local := get_local_player()
	var where: Variant = world.get_monolith_position(key, idx)
	if local != null and where != null and local.global_position.distance_to(where) < 90.0:
		sound.play_chord(idx)


@rpc("authority", "call_local", "reliable")
func do_reveal(key: String) -> void:
	revealed[key] = true
	world.reveal_core(key)
	hud.flash("RESONANCE FOUND  ·  A CORE HAS SURFACED", Color(0.95, 0.76, 0.38))
	sound.play_chime(12, 0.3)


@rpc("authority", "call_local", "reliable")
func do_topple(key: String) -> void:
	toppled[key] = true
	revealed[key] = true
	world.topple_titan(key)
	hud.flash("TITAN TOPPLED", Color(0.72, 0.61, 1.0))
	sound.play_thunder()


@rpc("authority", "call_local", "reliable")
func do_collect(key: String, new_cores: int, new_goal: int, stabilized: bool) -> void:
	collected[key] = true
	cores = new_cores
	core_goal = new_goal
	world.collect_core(key)
	sound.play_chord(0)
	sound.play_chime(19, 0.3)
	if stabilized:
		hud.flash("FREQUENCY STABILIZED  ·  THE STORM RECEDES", Color(0.24, 0.91, 0.96))
	else:
		hud.flash("HARMONIC CORE SECURED", Color(0.95, 0.76, 0.38))


@rpc("authority", "call_local", "reliable")
func do_lightning(pos: Vector3) -> void:
	_spawn_bolt(pos)
	sound.play_thunder()
	var local := get_local_player()
	if local != null and local.global_position.distance_to(pos) < 45.0:
		tether.add_charge(1.0)
		hud.flash("LIGHTNING  ·  TETHER CHARGED", Color(0.72, 0.61, 1.0))


@rpc("authority", "call_local", "reliable")
func do_surge() -> void:
	storm = 0.4
	hud.flash("STORM SURGE  ·  RECALLED TO THE ARK", Color(1.0, 0.3, 0.37))
	sound.play_thunder()
	var local := get_local_player()
	if local != null:
		local.respawn()


@rpc("authority", "call_remote", "unreliable_ordered")
func sync_state(new_storm: float, new_cores: int, new_goal: int) -> void:
	storm = new_storm
	cores = new_cores
	core_goal = new_goal


@rpc("authority", "call_remote", "reliable")
func full_state(new_revealed: Dictionary, new_collected: Dictionary, new_toppled: Dictionary, new_cores: int, new_goal: int, new_storm: float) -> void:
	revealed = new_revealed
	collected = new_collected
	toppled = new_toppled
	cores = new_cores
	core_goal = new_goal
	storm = new_storm
	world.apply_state()


func _spawn_bolt(pos: Vector3) -> void:
	var from := pos + Vector3(randf_range(-30.0, 30.0), 170.0, randf_range(-30.0, 30.0))
	Fx.bolt(self, from, pos, Color(0.72, 0.61, 1.0))
