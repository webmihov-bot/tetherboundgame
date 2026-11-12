extends CanvasLayer
## MainMenu - glassmorphism menu over the live world.
## [Host World]  [Join via IP]  [Solo Mode]  [Copy Invite Code]

const GLASS_SHADER: Shader = preload("res://shaders/glass_panel.gdshader")
const C_TEXT := Color(0.93, 0.94, 1.0)
const C_DIM := Color(0.68, 0.70, 0.84)
const C_SOFT := Color(0.77, 0.78, 0.90)
const C_CYAN := Color(0.24, 0.91, 0.96)
const C_VIOLET := Color(0.61, 0.42, 1.0)
const PANEL_SIZE := Vector2(520, 740)

var _name_edit: LineEdit
var _address_edit: LineEdit
var _status: Label
var _code_label: Label
var _copy_button: Button


func _ready() -> void:
	layer = 10
	_build()
	NetworkManager.status_changed.connect(_set_status)
	visibility_changed.connect(_on_visibility_changed)


func _on_visibility_changed() -> void:
	if visible and _code_label != null:
		_code_label.text = NetworkManager.get_invite_code()


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text


# ------------------------------------------------------------------- build

func _flat(bg: Color, border: Color, radius: int = 16) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text: String, bg: Color, border: Color, font_color: Color, height: float, font_size: int) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, height)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_font_size_override("font_size", font_size)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, font_color)
	button.add_theme_stylebox_override("normal", _flat(bg, border))
	button.add_theme_stylebox_override("hover", _flat(bg.lightened(0.12), border.lightened(0.2)))
	button.add_theme_stylebox_override("pressed", _flat(bg.darkened(0.15), border))
	var focus := _flat(Color(0, 0, 0, 0), C_CYAN)
	focus.set_border_width_all(2)
	button.add_theme_stylebox_override("focus", focus)
	return button


func _line_edit(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(0, 48)
	edit.add_theme_font_size_override("font_size", 16)
	edit.add_theme_color_override("font_color", C_TEXT)
	edit.add_theme_color_override("font_placeholder_color", Color(0.68, 0.70, 0.84, 0.7))
	var box := _flat(Color(0.024, 0.027, 0.06, 0.7), Color(1, 1, 1, 0.22), 10)
	box.content_margin_left = 14
	box.content_margin_right = 14
	edit.add_theme_stylebox_override("normal", box)
	var focus := _flat(Color(0.024, 0.027, 0.06, 0.7), C_CYAN, 10)
	focus.content_margin_left = 14
	focus.content_margin_right = 14
	focus.set_border_width_all(2)
	edit.add_theme_stylebox_override("focus", focus)
	return edit


func _build() -> void:
	var root := Control.new()
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Darken the left side so the panel reads against a bright sky.
	var shade := ColorRect.new()
	shade.color = Color(0.024, 0.027, 0.06, 0.35)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var holder := Control.new()
	root.add_child(holder)
	holder.anchor_top = 0.5
	holder.anchor_bottom = 0.5
	holder.offset_left = 88
	holder.offset_right = 88 + PANEL_SIZE.x
	holder.offset_top = -PANEL_SIZE.y * 0.5
	holder.offset_bottom = PANEL_SIZE.y * 0.5

	var glass := ColorRect.new()
	var glass_mat := ShaderMaterial.new()
	glass_mat.shader = GLASS_SHADER
	glass_mat.set_shader_parameter("rect_size", PANEL_SIZE)
	glass.material = glass_mat
	glass.mouse_filter = Control.MOUSE_FILTER_STOP
	holder.add_child(glass)
	glass.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 44)
	holder.add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	margin.add_child(column)

	column.add_child(_label("CO-OP PHYSICS EXTRACTION  ·  1-4 PLAYERS", 13, C_CYAN))
	var title := HBoxContainer.new()
	title.add_theme_constant_override("separation", 0)
	column.add_child(title)
	title.add_child(_label("TETHER", 58, C_TEXT))
	title.add_child(_label("BOUND", 58, C_CYAN))
	var tagline := _label("One cable. Four Resonators. Hold the line or fall together into the Drift.", 17, C_SOFT)
	tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(tagline)

	column.add_child(_label("CALLSIGN", 12, C_DIM))
	_name_edit = _line_edit("Resonator")
	_name_edit.max_length = 16
	if NetworkManager.local_name != "Resonator":
		_name_edit.text = NetworkManager.local_name
	column.add_child(_name_edit)

	var host := _button("Host World", C_CYAN, C_CYAN, Color(0.02, 0.07, 0.10), 60, 20)
	host.pressed.connect(_on_host)
	column.add_child(host)

	column.add_child(_label("JOIN VIA IP OR INVITE CODE", 12, C_DIM))
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 10)
	column.add_child(join_row)
	_address_edit = _line_edit("203.0.113.24:7777")
	_address_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address_edit.text_submitted.connect(func(_text: String) -> void: _on_join())
	join_row.add_child(_address_edit)
	var join := _button("Join", Color(0.61, 0.42, 1.0, 0.25), C_VIOLET, C_TEXT, 48, 17)
	join.alignment = HORIZONTAL_ALIGNMENT_CENTER
	join.custom_minimum_size = Vector2(96, 48)
	join.pressed.connect(_on_join)
	join_row.add_child(join)

	var solo := _button("Solo Mode", Color(1, 1, 1, 0.07), Color(1, 1, 1, 0.24), C_TEXT, 54, 18)
	solo.pressed.connect(_on_solo)
	column.add_child(solo)

	var invite := PanelContainer.new()
	invite.add_theme_stylebox_override("panel", _flat(Color(0, 0, 0, 0.12), Color(0.49, 0.92, 0.96, 0.5)))
	column.add_child(invite)
	var invite_row := HBoxContainer.new()
	invite_row.add_theme_constant_override("separation", 12)
	invite.add_child(invite_row)
	var invite_text := VBoxContainer.new()
	invite_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	invite_row.add_child(invite_text)
	invite_text.add_child(_label("YOUR INVITE CODE", 12, C_DIM))
	_code_label = _label(NetworkManager.get_invite_code(), 22, C_CYAN)
	invite_text.add_child(_code_label)
	_copy_button = _button("Copy Invite Code", Color(1, 1, 1, 0.07), Color(1, 1, 1, 0.24), C_TEXT, 48, 15)
	_copy_button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_copy_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_copy_button.pressed.connect(_on_copy)
	invite_row.add_child(_copy_button)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)
	var first_status := NetworkManager.last_status if NetworkManager.last_status != "" else "Ready. No session running."
	_status = _label(first_status, 13, C_SOFT)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)

	var footer := _label("PROTOTYPE BUILD  ·  UDP %d" % NetworkManager.port, 12, C_SOFT)
	root.add_child(footer)
	footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	footer.offset_left = -300
	footer.offset_top = -52
	footer.offset_right = -40
	footer.offset_bottom = -30
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	host.grab_focus.call_deferred()


# ----------------------------------------------------------------- actions

func _apply_name() -> void:
	var entered := _name_edit.text.strip_edges()
	NetworkManager.local_name = entered if entered != "" else "Resonator"


func _on_host() -> void:
	_apply_name()
	NetworkManager.host(false)


func _on_join() -> void:
	_apply_name()
	NetworkManager.join(_address_edit.text)


func _on_solo() -> void:
	_apply_name()
	NetworkManager.start_solo()


func _on_copy() -> void:
	var code := NetworkManager.get_invite_code()
	DisplayServer.clipboard_set(code)
	_code_label.text = code
	_copy_button.text = "Copied"
	_set_status("Invite code copied. It carries your local address %s:%d, so friends must be able to reach it (same network, VPN, or a forwarded UDP port)." % [NetworkManager.get_local_ip(), NetworkManager.port])
