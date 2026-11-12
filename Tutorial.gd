extends CanvasLayer
## Tutorial - interactive walkthrough for Solo Mode.
## Each step watches what the player actually does and advances on its own.
## T skips it (or replays it later). While it runs the storm is frozen and the
## monolith puzzle has no time limit. Completion is remembered in
## user://tetherbound.cfg so it only starts by itself the first time.

const CONFIG_PATH := "user://tetherbound.cfg"
const HOME := "0_0"
const C_BG := Color(0.047, 0.051, 0.125, 0.82)
const C_TEXT := Color(0.93, 0.94, 1.0)
const C_DIM := Color(0.68, 0.70, 0.84)
const C_CYAN := Color(0.24, 0.91, 0.96)
const C_GOLD := Color(0.95, 0.76, 0.38)
const C_GREEN := Color(0.45, 0.95, 0.7)

## id, title, instruction, tip
const STEPS: Array = [
	["move", "Move", "Walk with W A S D and look around with the mouse.", "You are standing on the Ark, your flying base."],
	["jump", "Jump", "Press SPACE to jump.", ""],
	["dash", "Dash", "Press LEFT CTRL while moving to dash.", "It recharges in about a second."],
	["drop", "Leave the Ark", "Walk off the edge of the Ark and land on the island below.", "The glowing cable keeps you tied to the Ark."],
	["anchor", "Anchor", "On the ground, hold LEFT SHIFT for a moment to lock your magnetic anchor.", "Anchored, nothing can pull you. In the air, SHIFT slams you straight down."],
	["reel", "Reel in", "Walk a few steps away from the Ark, then hold Q to reel the cable in until the tension bar turns violet.", "Walking further away tightens it too."],
	["catapult", "Catapult", "While the cable is violet, press SPACE to launch toward the Ark.", "The tighter the cable, the harder the launch."],
	["slack", "Reel out", "Hold E to let the cable back out.", ""],
	["ring", "Ring the monoliths", "Stand behind a golden tuning fork so it is between you and the Ark, then hold Q until it rings. Ring all three.", "Arrows mark the forks you still need. Tangled or stuck? Press X to free the cable."],
	["core", "Take the core", "A Harmonic Core has surfaced in the middle of the island. Touch it.", "Follow the pillar of light, or the CORE marker on the compass."],
	["board", "Back aboard", "Go under the Ark and press F to board it.", "The ARK marker on the compass points the way."],
	["helm", "Fly the Ark", "Walk to the gold-lit pedestal at the bow and press F. Steer with W A S D, SPACE up, CTRL down.", "Fly a short distance. Press F again to let go."],
]

var active := false

var _game: Node
var _index := -1
var _hold := 0.0
var _advance_in := -1.0
var _moved := 0.0
var _last_rel := Vector3.ZERO
var _ark_start := Vector3.ZERO
var _markers: Array = []
var _finish_timer := -1.0
var _time := 0.0

var _panel: PanelContainer
var _step_label: Label
var _title_label: Label
var _text_label: Label
var _tip_label: Label
var _pips: HBoxContainer


func _ready() -> void:
	layer = 6
	_game = get_tree().get_first_node_in_group("game")
	_build()
	var config := ConfigFile.new()
	var done := config.load(CONFIG_PATH) == OK and bool(config.get_value("tutorial", "done", false))
	if done:
		_panel.visible = false
		_game.hud.flash("PRESS T TO REPLAY THE TUTORIAL", C_DIM)
	else:
		start()


func start() -> void:
	active = true
	_index = -1
	_finish_timer = -1.0
	_panel.visible = true
	_game.tutorial_active = true
	_build_markers()
	_go_to(0)


func stop(completed: bool) -> void:
	active = false
	_panel.visible = false
	_game.tutorial_active = false
	_clear_markers()
	if completed:
		var config := ConfigFile.new()
		config.load(CONFIG_PATH)
		config.set_value("tutorial", "done", true)
		config.save(CONFIG_PATH)


func _exit_tree() -> void:
	if _game != null and is_instance_valid(_game):
		_game.tutorial_active = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).physical_keycode == KEY_T:
		if active:
			stop(true)
			_game.hud.flash("TUTORIAL SKIPPED  ·  T TO REPLAY", C_DIM)
		else:
			start()


# ------------------------------------------------------------------- build

func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _build() -> void:
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = C_BG
	style.border_color = Color(0.24, 0.91, 0.96, 0.6)
	style.set_border_width_all(1)
	style.set_corner_radius_all(16)
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	_panel.add_theme_stylebox_override("panel", style)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_panel)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.offset_left = -300
	_panel.offset_right = 300
	_panel.offset_top = 150
	_panel.grow_vertical = Control.GROW_DIRECTION_END

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(box)
	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(header)
	_step_label = _label("TUTORIAL", 12, C_CYAN)
	_step_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_step_label)
	var skip := _label("T  skip", 12, C_DIM)
	skip.autowrap_mode = TextServer.AUTOWRAP_OFF
	header.add_child(skip)
	_title_label = _label("", 24, C_TEXT)
	box.add_child(_title_label)
	_text_label = _label("", 17, C_TEXT)
	box.add_child(_text_label)
	_tip_label = _label("", 14, C_DIM)
	box.add_child(_tip_label)
	_pips = HBoxContainer.new()
	_pips.add_theme_constant_override("separation", 4)
	_pips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_pips)
	for i in STEPS.size():
		var pip := ColorRect.new()
		pip.custom_minimum_size = Vector2(0, 5)
		pip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pips.add_child(pip)


func _go_to(index: int) -> void:
	_index = index
	_hold = 0.0
	_advance_in = -1.0
	_moved = 0.0
	if _game.ark != null:
		_ark_start = _game.ark.global_position
	var local: Node3D = _game.get_local_player()
	if local != null and _game.ark != null:
		_last_rel = local.global_position - _game.ark.global_position
	var step: Array = STEPS[index]
	_step_label.text = "TUTORIAL  ·  %d / %d" % [index + 1, STEPS.size()]
	_title_label.text = str(step[1])
	_title_label.add_theme_color_override("font_color", C_TEXT)
	_text_label.text = str(step[2])
	_tip_label.text = str(step[3])
	_tip_label.visible = str(step[3]) != ""
	for i in _pips.get_child_count():
		var pip := _pips.get_child(i) as ColorRect
		if i < index:
			pip.color = C_GREEN
		elif i == index:
			pip.color = C_CYAN
		else:
			pip.color = Color(1, 1, 1, 0.18)


# ----------------------------------------------------------------- markers

func _build_markers() -> void:
	_clear_markers()
	var world: Node3D = _game.world
	if not world.islands.has(HOME):
		return
	var monoliths: Array = world.islands[HOME]["monoliths"]
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.45)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.35)
	mat.emission_energy_multiplier = 3.0
	var cone := CylinderMesh.new()
	cone.top_radius = 0.9
	cone.bottom_radius = 0.0
	cone.height = 1.8
	cone.radial_segments = 4
	for entry in monoliths:
		var body: Node3D = entry["body"]
		var arrow := MeshInstance3D.new()
		arrow.mesh = cone
		arrow.material_override = mat
		arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arrow.visible = false
		body.add_child(arrow)
		arrow.position = Vector3(0, 13.0, 0)
		_markers.append(arrow)


func _clear_markers() -> void:
	for marker in _markers:
		if is_instance_valid(marker):
			(marker as Node).queue_free()
	_markers.clear()


func _update_markers(show: bool, rung: Dictionary) -> void:
	for i in _markers.size():
		var marker: MeshInstance3D = _markers[i] if is_instance_valid(_markers[i]) else null
		if marker == null:
			continue
		marker.visible = show and not rung.has(i)
		marker.position.y = 13.0 + sin(_time * 3.0 + float(i)) * 0.6
		marker.rotation.y = _time * 1.5


# -------------------------------------------------------------------- loop

func _process(delta: float) -> void:
	_time += delta
	if not active:
		return
	if _finish_timer >= 0.0:
		_finish_timer -= delta
		if _finish_timer <= 0.0:
			stop(true)
		return
	var local: Node3D = _game.get_local_player()
	if local == null or _index < 0:
		return
	var id: String = STEPS[_index][0]
	var rung: Dictionary = _game.get_ring_progress(HOME)
	_update_markers(id == "ring", rung)

	if _advance_in >= 0.0:
		_advance_in -= delta
		if _advance_in <= 0.0:
			if _index + 1 >= STEPS.size():
				_finish()
			else:
				_go_to(_index + 1)
		return

	if _check(id, local, rung, delta):
		_title_label.text = "DONE  ·  " + str(STEPS[_index][1])
		_title_label.add_theme_color_override("font_color", C_GREEN)
		(_pips.get_child(_index) as ColorRect).color = C_GREEN
		_game.sound.play_chime(12 + _index, 0.2)
		_advance_in = 0.9


func _check(id: String, local: Node3D, rung: Dictionary, delta: float) -> bool:
	var active_input := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var ark: Node3D = _game.ark
	match id:
		"move":
			var rel := local.global_position - ark.global_position
			_moved += Vector2(rel.x - _last_rel.x, rel.z - _last_rel.z).length()
			_last_rel = rel
			return _moved > 5.0
		"jump":
			return active_input and Input.is_action_just_pressed("jump")
		"dash":
			return float(local.dash_cooldown) > 0.8
		"drop":
			return local.is_on_floor() and not ark.is_over_deck(local.global_position) and local.global_position.y < ark.global_position.y - 3.0
		"anchor":
			_hold = _hold + delta if bool(local.anchored) else 0.0
			return _hold > 0.7
		"reel":
			return float(local.tension) >= 0.4
		"catapult":
			_text_label.text = str(STEPS[_index][2]) if float(local.tension) > 0.3 else "Hold Q or walk away from the Ark until the cable is violet again, then press SPACE."
			return active_input and Input.is_action_just_pressed("jump") and float(local.tension) > 0.3
		"slack":
			return float(local.reel) >= 0.95
		"ring":
			_step_label.text = "TUTORIAL  ·  %d / %d  ·  RUNG %d / 3" % [_index + 1, STEPS.size(), rung.size()]
			return _game.revealed.has(HOME)
		"core":
			return _game.collected.has(HOME)
		"board":
			return ark.is_over_deck(local.global_position) and local.is_on_floor()
		"helm":
			if bool(local.piloting):
				_text_label.text = "You have the helm. Steer with W A S D, SPACE up, CTRL down. Fly a short distance."
			return ark.global_position.distance_to(_ark_start) > 12.0
	return false


func _finish() -> void:
	_step_label.text = "TUTORIAL COMPLETE"
	_title_label.text = "You are ready"
	_title_label.add_theme_color_override("font_color", C_GOLD)
	_text_label.text = "Fly the Ark to other islands and collect five cores before the storm reaches 100%. Purple islands hide titans: wrap the cable around one and pull."
	_tip_label.text = "Bring friends with Host World. Press T any time to replay this."
	_tip_label.visible = true
	for pip in _pips.get_children():
		(pip as ColorRect).color = C_GREEN
	_game.sound.play_chord(0)
	_finish_timer = 12.0
