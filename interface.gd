extends Control

signal host_requested
signal join_requested(address: String)
signal practice_requested
signal resume_requested
signal leave_requested
signal rematch_requested

const INK := Color("#102937")
const PAPER := Color("#eff5ee")
const MINT := Color("#7ae3cf")
const MUTED := Color("#b3c6cc")
const CORAL := Color("#ff997f")
var panel: PanelContainer
var content: VBoxContainer
var notice: Label
var address: LineEdit
var overlay := "menu"
var match_data := {}
var nose := Vector2.ZERO
var markers: Array = []
var hit_until := 0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu()

func _box(color: Color, outline := Color.TRANSPARENT) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(5)
	style.set_border_width_all(1)
	style.border_color = outline
	style.content_margin_left = 15
	style.content_margin_right = 15
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func _open(kind: String) -> void:
	overlay = kind
	if is_instance_valid(panel):
		remove_child(panel)
		panel.queue_free()
	panel = PanelContainer.new()
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.anchor_left = 0.045
	panel.anchor_right = 0.045
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size.x = 396
	var style := _box(Color("#0d2330f5"), Color("#47636b"))
	style.content_margin_left = 27
	style.content_margin_right = 27
	style.content_margin_top = 23
	style.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 9)
	panel.add_child(content)
	notice = null
	queue_redraw()

func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", font_size)
	content.add_child(label)
	return label

func _button(title: String, action: Callable, primary := false) -> Button:
	var button := Button.new()
	button.text = title
	button.custom_minimum_size.y = 37
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var base := MINT if primary else Color("#263e4b")
	button.add_theme_stylebox_override("normal", _box(base))
	button.add_theme_stylebox_override("hover", _box(base.lightened(0.15)))
	button.add_theme_stylebox_override("pressed", _box(base.darkened(0.15)))
	for state in ["font_color","font_hover_color","font_pressed_color","font_focus_color"]:
		button.add_theme_color_override(state, INK if primary else PAPER)
	button.pressed.connect(action)
	content.add_child(button)
	return button

func menu(message := "") -> void:
	_open("menu")
	_label("LAN DEATHMATCH", 14, MINT)
	_label("air-strike", 49, PAPER)
	_label("Kestrel Island", 21, MUTED)
	content.add_child(HSeparator.new())
	_button("Host LAN match", func(): host_requested.emit(), true)
	address = LineEdit.new()
	address.placeholder_text = "Host IPv4 address"
	address.add_theme_stylebox_override("normal", _box(Color("#1a3240"), Color("#5d7780")))
	content.add_child(address)
	address.text_submitted.connect(func(_s: String): join_requested.emit(address.text.strip_edges()))
	_button("Join by IP", func(): join_requested.emit(address.text.strip_edges()))
	_button("Practice flight", func(): practice_requested.emit())
	_label("W/S   climb / dive       A/D   bank", 15, MUTED)
	_label("Left click or F   fire      Space   boost", 15, MUTED)
	notice = _label(message, 14, CORAL)
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.custom_minimum_size.x = 315

func message(value: String) -> void:
	if is_instance_valid(notice): notice.text = value

func play() -> void:
	overlay = ""
	panel.hide()
	queue_redraw()

func pause_menu() -> void:
	_open("pause")
	_label("Flight menu", 32, PAPER)
	_button("Resume flight", func(): resume_requested.emit(), true)
	_button("Leave session", func(): leave_requested.emit())

func results(title: String, score: String, hosting: bool) -> void:
	_open("result")
	_label("MATCH COMPLETE", 14, MINT)
	_label(title, 32, PAPER)
	_label(score, 19, MUTED)
	if hosting:
		_button("Rematch", func(): rematch_requested.emit(), true)
	else:
		_label("Waiting for host to start a rematch", 16, MUTED)
	_button("Leave session", func(): leave_requested.emit())

func _caption(p: Vector2, value: String, font_size: int, color: Color, centered := false) -> void:
	var font := ThemeDB.fallback_font
	if centered: p.x -= font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x * 0.5
	draw_string_outline(font, p, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color("#102937b3"))
	draw_string(font, p, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw() -> void:
	if overlay != "" or match_data.is_empty(): return
	var mid := size * 0.5
	var d := match_data
	draw_rect(Rect2(mid.x - 159, 17, 318, 46), Color("#102937dd"))
	_caption(Vector2(mid.x-105,48), "TIDE  %d" % d.scores.x, 19, MINT, true)
	_caption(Vector2(mid.x,49), "%d:%02d" % [int(d.clock)/60, int(d.clock)%60], 23, PAPER, true)
	_caption(Vector2(mid.x+105,48), "%d  EMBER" % d.scores.y, 19, CORAL, true)
	if d.banner != "": _caption(Vector2(mid.x,88), d.banner, 17, PAPER, true)
	if d.dead > 0:
		_caption(mid, "Respawning in %d" % ceili(d.dead), 28, PAPER, true)
	else:
		var cross_color := MINT if Time.get_ticks_msec() < hit_until else PAPER
		for axis in [Vector2.LEFT,Vector2.RIGHT,Vector2.UP,Vector2.DOWN]:
			draw_line(nose+axis*3, nose+axis*9, cross_color, 2, true)
		for item in markers:
			var point: Vector2 = item[0]
			var color: Color = item[1]
			draw_polyline(PackedVector2Array([point+Vector2(-5,-5),point,point+Vector2(5,-5)]),color,2,true)
	draw_rect(Rect2(22,size.y-91,248,70), Color("#102937dc"))
	_caption(Vector2(35,size.y-65), "%s    /    HULL  %d/3" % [d.team, d.hp], 15, PAPER)
	_caption(Vector2(35,size.y-38), "NITRO", 13, MINT)
	draw_rect(Rect2(91,size.y-47,158,7),Color("#475961"))
	draw_rect(Rect2(91,size.y-47,158*d.charge,7), MINT)
	_caption(Vector2(size.x-124,size.y-34), "ESC   Menu", 15, PAPER)
