extends CanvasLayer
## HUD - minimal in-game UI, built in code.
## Compass (Ark + nearest core markers), squad list, core count, storm level,
## tether tension bar (slack / charged / snap risk), anchor state, key hints,
## context prompt, and event flashes.

const C_BG := Color(0.047, 0.051, 0.125, 0.68)
const C_BORDER := Color(1, 1, 1, 0.16)
const C_TEXT := Color(0.93, 0.94, 1.0)
const C_DIM := Color(0.68, 0.70, 0.84)
const C_CYAN := Color(0.24, 0.91, 0.96)
const C_VIOLET := Color(0.61, 0.42, 1.0)
const C_RED := Color(1.0, 0.30, 0.37)
const C_GOLD := Color(0.95, 0.76, 0.38)


class Compass extends Control:
	const NAMES: Array[String] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var heading := 0.0
	var markers: Array = []

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var font := get_theme_default_font()
		var per_degree := w / 120.0
		for deg in range(0, 360, 15):
			var diff := wrapf(float(deg) - heading, -180.0, 180.0)
			if absf(diff) > 58.0:
				continue
			var x := w * 0.5 + diff * per_degree
			var major := deg % 45 == 0
			var fade := 1.0 - absf(diff) / 70.0
			draw_line(Vector2(x, h - (12.0 if major else 7.0)), Vector2(x, h - 3.0), Color(1, 1, 1, 0.55 * fade), 2.0 if major else 1.0)
			if major:
				@warning_ignore("integer_division")
				var label: String = NAMES[deg / 45]
				var cardinal := deg % 90 == 0
				var text_size := 18 if cardinal else 13
				var text_color := Color(0.93, 0.94, 1.0, fade) if cardinal else Color(0.68, 0.70, 0.84, fade)
				draw_string(font, Vector2(x - 20.0, h * 0.5 + 3.0), label, HORIZONTAL_ALIGNMENT_CENTER, 40.0, text_size, text_color)
		draw_line(Vector2(w * 0.5, 0.0), Vector2(w * 0.5, 7.0), Color(1, 1, 1, 0.9), 2.0)
		var row := 0
		for marker in markers:
			var diff_m := clampf(wrapf(float(marker["bearing"]) - heading, -180.0, 180.0), -58.0, 58.0)
			var mx := w * 0.5 + diff_m * per_degree
			var my := h + 12.0 + float(row) * 16.0
			row += 1
			var color: Color = marker["color"]
			draw_colored_polygon(PackedVector2Array([Vector2(mx, my - 6.0), Vector2(mx + 6.0, my), Vector2(mx, my + 6.0), Vector2(mx - 6.0, my)]), color)
			draw_string(font, Vector2(mx + 10.0, my + 5.0), str(marker["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, color)


class TensionBar extends Control:
	var value := 0.0
	var color := Color(0.24, 0.91, 0.96)

	func _draw() -> void:
		var back := StyleBoxFlat.new()
		back.bg_color = Color(1, 1, 1, 0.14)
		back.set_corner_radius_all(7)
		draw_style_box(back, Rect2(Vector2.ZERO, size))
		if value > 0.01:
			var fill := StyleBoxFlat.new()
			fill.bg_color = color
			fill.set_corner_radius_all(7)
			draw_style_box(fill, Rect2(0.0, 0.0, maxf(size.x * value, 14.0), size.y))
		for mark in [0.4, 0.8]:
			draw_rect(Rect2(size.x * float(mark) - 1.0, 0.0, 2.0, size.y), Color(0.02, 0.03, 0.06, 0.85))


var _root: Control
var _compass: Compass
var _squad_box: VBoxContainer
var _squad_rows: Dictionary = {}
var _cores_label: Label
var _core_pips: HBoxContainer
var _storm_bar: TensionBar
var _storm_label: Label
var _tension_bar: TensionBar
var _tension_label: Label
var _anchor_label: Label
var _prompt_label: Label
var _flash_label: Label
var _leave_button: Button
var _flash_time := 0.0
var _slow_timer := 0.0
var _game: Node


func _ready() -> void:
	layer = 5
	_game = get_tree().get_first_node_in_group("game")
	_build()
	NetworkManager.lobby_changed.connect(_rebuild_squad)
	_rebuild_squad()


func flash(text: String, color: Color = C_TEXT) -> void:
	if _flash_label == null:
		return
	_flash_label.text = text
	_flash_label.add_theme_color_override("font_color", color)
	_flash_time = 3.2


# ------------------------------------------------------------------- build

func _style(bg: Color, radius: int = 14) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(14)
	return sb


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _place(control: Control, left: float, top: float, right: float, bottom: float, rect: Rect2) -> void:
	# Anchors (0..1) + pixel offsets from those anchors.
	control.anchor_left = left
	control.anchor_top = top
	control.anchor_right = right
	control.anchor_bottom = bottom
	control.offset_left = rect.position.x
	control.offset_top = rect.position.y
	control.offset_right = rect.position.x + rect.size.x
	control.offset_bottom = rect.position.y + rect.size.y


func _boxed(left: float, top: float, right: float, bottom: float, rect: Rect2) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(C_BG))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(panel)
	_place(panel, left, top, right, bottom, rect)
	return panel


func _build() -> void:
	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Compass, top centre.
	var compass_panel := _boxed(0.5, 0.0, 0.5, 0.0, Rect2(-300, 24, 600, 44))
	compass_panel.add_theme_stylebox_override("panel", _style(C_BG, 12))
	_compass = Compass.new()
	_compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compass.clip_contents = false
	compass_panel.add_child(_compass)

	# Squad, top left.
	var squad_panel := _boxed(0.0, 0.0, 0.0, 0.0, Rect2(28, 24, 290, 60))
	_squad_box = VBoxContainer.new()
	_squad_box.add_theme_constant_override("separation", 8)
	_squad_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	squad_panel.add_child(_squad_box)

	# Cores + storm, top right.
	var goal_panel := _boxed(1.0, 0.0, 1.0, 0.0, Rect2(-318, 24, 290, 110))
	var goal_box := VBoxContainer.new()
	goal_box.add_theme_constant_override("separation", 8)
	goal_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	goal_panel.add_child(goal_box)
	var goal_row := HBoxContainer.new()
	goal_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	goal_box.add_child(goal_row)
	var goal_title := _label("HARMONIC CORES", 12, C_DIM)
	goal_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	goal_row.add_child(goal_title)
	_cores_label = _label("0 / 5", 22, C_GOLD)
	goal_row.add_child(_cores_label)
	_core_pips = HBoxContainer.new()
	_core_pips.add_theme_constant_override("separation", 6)
	_core_pips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	goal_box.add_child(_core_pips)
	for i in 5:
		var pip := ColorRect.new()
		pip.custom_minimum_size = Vector2(0, 8)
		pip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_core_pips.add_child(pip)
	var storm_row := HBoxContainer.new()
	storm_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	goal_box.add_child(storm_row)
	var storm_title := _label("STORM", 12, C_DIM)
	storm_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	storm_row.add_child(storm_title)
	_storm_label = _label("15%", 13, C_VIOLET)
	storm_row.add_child(_storm_label)
	_storm_bar = TensionBar.new()
	_storm_bar.custom_minimum_size = Vector2(0, 8)
	_storm_bar.color = C_VIOLET
	_storm_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	goal_box.add_child(_storm_bar)

	# Tether tension, bottom centre.
	var tension_panel := _boxed(0.5, 1.0, 0.5, 1.0, Rect2(-250, -116, 500, 88))
	var tension_box := VBoxContainer.new()
	tension_box.add_theme_constant_override("separation", 8)
	tension_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tension_panel.add_child(tension_box)
	var tension_row := HBoxContainer.new()
	tension_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tension_box.add_child(tension_row)
	var tension_title := _label("TETHER TENSION", 12, C_DIM)
	tension_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tension_row.add_child(tension_title)
	_tension_label = _label("SLACK · 0%", 15, C_CYAN)
	tension_row.add_child(_tension_label)
	_tension_bar = TensionBar.new()
	_tension_bar.custom_minimum_size = Vector2(0, 14)
	_tension_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tension_box.add_child(_tension_bar)
	var zones := HBoxContainer.new()
	zones.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tension_box.add_child(zones)
	var zone_names := ["SLACK", "CHARGED", "SNAP RISK"]
	var zone_ratios := [2.0, 2.0, 1.0]
	for i in 3:
		var zone := _label(zone_names[i], 11, C_DIM)
		zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		zone.size_flags_stretch_ratio = zone_ratios[i]
		zones.add_child(zone)

	# Key hints, bottom left.
	var hints_panel := _boxed(0.0, 1.0, 0.0, 1.0, Rect2(28, -150, 340, 122))
	var hints := VBoxContainer.new()
	hints.add_theme_constant_override("separation", 4)
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hints_panel.add_child(hints)
	for line in ["WASD  move      SPACE  jump / catapult", "SHIFT  anchor (in air: slam)      X  release cable", "Q / E  reel in / out      CTRL  dash", "F  interact      ESC  free the mouse      T  tutorial (solo)"]:
		hints.add_child(_label(line, 13, C_DIM))

	# Anchor state, bottom right.
	var anchor_panel := _boxed(1.0, 1.0, 1.0, 1.0, Rect2(-228, -96, 200, 68))
	var anchor_box := VBoxContainer.new()
	anchor_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_panel.add_child(anchor_box)
	anchor_box.add_child(_label("ANCHOR", 11, C_DIM))
	_anchor_label = _label("Ready", 17, C_TEXT)
	anchor_box.add_child(_anchor_label)

	# Context prompt and event flash.
	_prompt_label = _label("", 18, C_TEXT)
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_prompt_label)
	_place(_prompt_label, 0.0, 1.0, 1.0, 1.0, Rect2(0, -168, 0, 30))
	_flash_label = _label("", 26, C_TEXT)
	_flash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_flash_label)
	_place(_flash_label, 0.0, 0.0, 1.0, 0.0, Rect2(0, 120, 0, 40))

	_leave_button = Button.new()
	_leave_button.text = "Leave session"
	_leave_button.add_theme_stylebox_override("normal", _style(C_BG, 10))
	_leave_button.add_theme_stylebox_override("hover", _style(Color(0.2, 0.1, 0.16, 0.9), 10))
	_leave_button.add_theme_stylebox_override("pressed", _style(Color(0.3, 0.1, 0.16, 0.9), 10))
	_leave_button.add_theme_color_override("font_color", C_TEXT)
	_root.add_child(_leave_button)
	_place(_leave_button, 0.5, 0.5, 0.5, 0.5, Rect2(-90, -24, 180, 48))
	_leave_button.visible = false
	_leave_button.pressed.connect(func() -> void: NetworkManager.leave(true, "You left the session."))


func _rebuild_squad() -> void:
	if _squad_box == null:
		return
	for child in _squad_box.get_children():
		child.queue_free()
	_squad_rows.clear()
	var ids: Array = NetworkManager.get_sorted_ids()
	_squad_box.add_child(_label("RESONATORS %d/%d" % [ids.size(), NetworkManager.MAX_PLAYERS], 12, C_DIM))
	for id in ids:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var chip := ColorRect.new()
		chip.color = NetworkManager.get_color(id)
		chip.custom_minimum_size = Vector2(12, 12)
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(chip)
		var who: String = NetworkManager.get_player_name(id)
		if id == multiplayer.get_unique_id():
			who += " (you)"
		var name_label := _label(who, 15, C_TEXT)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var status := _label("", 12, C_DIM)
		row.add_child(status)
		_squad_box.add_child(row)
		_squad_rows[id] = status


# ------------------------------------------------------------------ update

func _process(delta: float) -> void:
	if not visible or _game == null:
		return
	if _flash_time > 0.0:
		_flash_time -= delta
		_flash_label.modulate.a = clampf(_flash_time, 0.0, 1.0)
	else:
		_flash_label.modulate.a = 0.0

	var local: Node3D = _game.get_local_player()
	_leave_button.visible = local != null and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	if local == null:
		return

	# Tension bar.
	var t := clampf(maxf(float(local.tension), 0.0), 0.0, 1.0)
	var state := "SLACK"
	var color := C_CYAN
	if t >= 0.8:
		state = "CRITICAL"
		color = C_RED
	elif t >= 0.4:
		state = "CHARGED"
		color = C_VIOLET
	if float(_game.tether.charge) > 0.3 and t < 0.8:
		state += " + LIGHTNING"
	_tension_bar.value = t
	_tension_bar.color = color
	_tension_bar.queue_redraw()
	_tension_label.text = "%s · %d%%" % [state, roundi(t * 100.0)]
	_tension_label.add_theme_color_override("font_color", color.lightened(0.25))

	# Anchor.
	if bool(local.anchored):
		if float(local.anchor_overload) > 0.4:
			_anchor_label.text = "OVERLOADING"
			_anchor_label.add_theme_color_override("font_color", C_RED.lightened(0.25))
		else:
			_anchor_label.text = "Locked"
			_anchor_label.add_theme_color_override("font_color", C_CYAN)
	elif float(local.anchor_cooldown) > 0.0:
		_anchor_label.text = "Recharging %.1fs" % float(local.anchor_cooldown)
		_anchor_label.add_theme_color_override("font_color", C_DIM)
	else:
		_anchor_label.text = "Ready"
		_anchor_label.add_theme_color_override("font_color", C_TEXT)

	_prompt_label.text = str(local.prompt)

	# Compass.
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var forward := -cam.global_transform.basis.z
		_compass.heading = fposmod(rad_to_deg(atan2(forward.x, -forward.z)), 360.0)
		var markers: Array = []
		var ark_pos: Vector3 = _game.ark.global_position
		markers.append(_marker(local.global_position, ark_pos, "ARK", C_CYAN))
		var core: Variant = _game.world.nearest_core(local.global_position)
		if core != null:
			markers.append(_marker(local.global_position, core, "CORE", C_GOLD))
		_compass.markers = markers
		_compass.queue_redraw()

	_slow_timer -= delta
	if _slow_timer <= 0.0:
		_slow_timer = 0.2
		_update_slow()


func _marker(from: Vector3, to: Vector3, label: String, color: Color) -> Dictionary:
	var d := to - from
	var bearing := fposmod(rad_to_deg(atan2(d.x, -d.z)), 360.0)
	return {"bearing": bearing, "label": "%s %dm" % [label, roundi(Vector2(d.x, d.z).length())], "color": color}


func _update_slow() -> void:
	var cores: int = _game.cores
	var goal: int = _game.core_goal
	_cores_label.text = "%d / %d" % [cores, goal]
	var filled := cores - (goal - 5)
	for i in _core_pips.get_child_count():
		(_core_pips.get_child(i) as ColorRect).color = C_GOLD if i < filled else Color(1, 1, 1, 0.18)
	var storm: float = _game.storm
	_storm_bar.value = storm
	_storm_bar.color = C_RED if storm > 0.8 else C_VIOLET
	_storm_bar.queue_redraw()
	_storm_label.text = "%d%%" % roundi(storm * 100.0)

	for id in _squad_rows.keys():
		var status: Label = _squad_rows[id]
		if not is_instance_valid(status):
			continue
		var node: Node3D = _game.players_root.get_node_or_null(str(id))
		if node == null:
			status.text = "JOINING"
			continue
		var text := "FREE"
		var color := C_DIM
		if bool(node.piloting):
			text = "AT THE HELM"
			color = C_GOLD
		elif bool(node.anchored):
			text = "ANCHORED"
			color = C_CYAN
		elif float(node.velocity.y) < -16.0:
			text = "FALLING"
			color = C_RED.lightened(0.25)
		elif float(node.tension) > 0.8:
			text = "CRITICAL"
			color = C_RED.lightened(0.25)
		status.text = text
		status.add_theme_color_override("font_color", color)
