extends CanvasLayer
## On-screen touch controls for a phone or tablet: a virtual stick in the lower left,
## a look-drag area over the rest of the screen, and a button cluster in the lower right.
##
## Built entirely in code, the way the rest of this project's UI is (no external
## resources). It never edits the player directly: the stick and the four action buttons
## drive the same InputMap actions the keyboard and mouse drive, a look drag is turned
## into the same `InputEventMouseMotion` the mouse feeds the player, and the three
## system buttons post the key events the game already handles. So every path here is
## one that already exists on desktop.
##
## It shows by itself whenever the device has a touchscreen, and a desktop can force it
## on for testing with `Settings.touch_controls` (or the `--touch` command-line flag).

## No control is smaller than this many canvas units; a finger is coarse, and the
## guideline numbers for a comfortable target are well under it.
const MIN_TOUCH := 72.0
const JOY_BASE_R := 90.0            # stick base radius
const JOY_KNOB_R := 36.0            # knob radius (72 across, so it meets the minimum)
const BTN := 84.0                   # the four big action buttons
const SYS_BTN := 76.0               # the small system buttons
const EDGE := 24.0                  # margin from the screen edges
const GAP := 8.0                    # space between neighbouring buttons
const DEAD := 16.0                  # stick dead zone, in canvas units

var player
var world

var root: Control
var joy_base: Panel
var joy_knob: Panel
var joy_center := Vector2.ZERO

## name -> Rect2 in canvas coordinates, rebuilt by `_layout`. This is what the layout
## check in the selftest reads, and what the touch hit-testing walks.
var _rects: Dictionary = {}
var _btn_nodes: Dictionary = {}     # name -> Panel
var _btn_labels: Dictionary = {}    # name -> Label
var _view_size := Vector2.ZERO

## True while the game is in a state the controls belong in (play, no panel up). Set by
## main each frame.
var _allowed := false
var _joy_touch := -1
var _look_touch := -1
var _look_last := Vector2.ZERO
## The four stick directions, so a direction is only pressed/released when it changes.
var _axis := {"forward": false, "back": false, "left": false, "right": false}
## Which button each touch index is currently holding down.
var _holds: Dictionary = {}
## True while a menu is on screen (set by main each frame). The controls are hidden then,
## but the menus are ordinary Buttons and still need a pointer, so a touch is bridged into
## a mouse event for exactly as long as this is set.
var _menu := false
## True when the engine already mirrors touch into mouse, which is its default. Then the
## menus need no bridge -- and bridging as well would deliver every click twice -- so the
## bridge stands down. Read once: the project setting does not change while the game runs.
var _emulate_mouse := bool(ProjectSettings.get_setting(
	"input_devices/pointing/emulate_mouse_from_touch", true))


func build(p, w) -> void:
	player = p
	world = w
	layer = 15
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	root.theme = Art.theme
	add_child(root)
	root.resized.connect(_layout)
	_build_controls()
	_layout()


# ================================================================ construction
func _build_controls() -> void:
	joy_base = _make_panel(Color(0.12, 0.13, 0.18, 0.34), Color(0.62, 0.66, 0.78, 0.55),
		int(JOY_BASE_R))
	joy_knob = _make_panel(Color(0.72, 0.76, 0.88, 0.55), Color(0.85, 0.88, 0.96, 0.75),
		int(JOY_KNOB_R))
	_make_labeled_button("attack", BTN, "DIG")
	_make_labeled_button("use", BTN, "USE")
	_make_labeled_button("jump", BTN, "JUMP")
	_make_labeled_button("sneak", BTN, "SNEAK")
	_make_labeled_button("menu", SYS_BTN, "MENU")
	_make_labeled_button("fly", SYS_BTN, "FLY")
	_make_labeled_button("backpack", SYS_BTN, "BAG")


func _make_panel(bg: Color, border: Color, radius: int) -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := Art._sb_flat(bg, 3, border)
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	p.add_theme_stylebox_override("panel", sb)
	root.add_child(p)
	return p


## A button is a plain Panel plus a clipped Label, never a real Button: nothing here
## relies on GUI input, because the layer hit-tests in `_input` itself. That also means
## the panel keeps whatever size it is given, instead of growing to fit its text and
## shoving its neighbours out of the way.
func _make_labeled_button(nm: String, sz: float, text: String) -> void:
	var p := _make_panel(Color(0.10, 0.10, 0.14, 0.55), Color(0.58, 0.62, 0.74, 0.7), 12)
	var side := maxf(sz, MIN_TOUCH)
	p.custom_minimum_size = Vector2(side, side)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", PFont.S)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	_btn_nodes[nm] = p
	_btn_labels[nm] = l


# ================================================================ layout
func _layout() -> void:
	if root == null:
		return
	var s: Vector2 = root.size
	_view_size = s
	# the stick sits where a left thumb rests
	joy_center = Vector2(140.0, s.y - 140.0)
	joy_base.position = (joy_center - Vector2(JOY_BASE_R, JOY_BASE_R)).round()
	joy_base.size = Vector2(JOY_BASE_R * 2.0, JOY_BASE_R * 2.0)
	joy_knob.size = Vector2(JOY_KNOB_R * 2.0, JOY_KNOB_R * 2.0)
	joy_knob.position = (joy_center - Vector2(JOY_KNOB_R, JOY_KNOB_R)).round()

	# the four big actions hug the lower-right corner, dig outermost
	var ax := s.x - EDGE - BTN * 0.5
	var ay := s.y - EDGE - BTN * 0.5
	var ux := ax - BTN - GAP
	_place_button("attack", ax, ay)
	_place_button("use", ux, ay)
	_place_button("jump", ux, ay - BTN - GAP)
	_place_button("sneak", ax, ay - BTN - GAP)

	# the three system buttons sit in a row above them
	var sy := ay - BTN * 0.5 - BTN - GAP * 2.0 - SYS_BTN * 0.5
	var mx := s.x - EDGE - SYS_BTN * 0.5
	_place_button("menu", mx, sy)
	_place_button("fly", mx - SYS_BTN - GAP, sy)
	_place_button("backpack", mx - (SYS_BTN + GAP) * 2.0, sy)

	_rebuild_rects()


func _place_button(nm: String, cx: float, cy: float) -> void:
	var p: Panel = _btn_nodes[nm]
	var sz: float = p.custom_minimum_size.x
	p.size = Vector2(sz, sz)
	p.position = (Vector2(cx, cy) - Vector2(sz, sz) * 0.5).round()
	var l: Label = _btn_labels[nm]
	l.position = Vector2.ZERO
	l.size = Vector2(sz, sz)


func _rebuild_rects() -> void:
	_rects.clear()
	_rects["joystick"] = Rect2(joy_center - Vector2(JOY_BASE_R, JOY_BASE_R),
		Vector2(JOY_BASE_R * 2.0, JOY_BASE_R * 2.0))
	for nm in _btn_nodes:
		var p: Panel = _btn_nodes[nm]
		_rects[nm] = Rect2(p.position, p.size)


# ================================================================ public surface
## True when the controls should be on screen: the game is in a playable state and
## either the device has a touchscreen or the force switch is on.
func is_active() -> bool:
	return _allowed and (Settings.touch_controls or DisplayServer.is_touchscreen_available())


## Set by main each frame from the mode state machine and the open-panel checks.
func set_allowed(v: bool) -> void:
	_allowed = v


## Set by main each frame: true while a menu is up. The controls themselves stay hidden
## then, but the menus still need a pointer, so this is what turns the bridge on.
func set_menu(v: bool) -> void:
	_menu = v


func has_control(nm: String) -> bool:
	return _rects.has(nm)


func control_rects() -> Dictionary:
	return _rects.duplicate()


func view_size() -> Vector2:
	return _view_size


# ================================================================ visibility
func _process(_delta: float) -> void:
	var on := is_active()
	visible = on
	if not on:
		_release_all()


func _release_all() -> void:
	for a in _axis:
		_set_axis(str(a), false)
	for idx in _holds:
		_release_button(str(_holds[idx]))
	_holds.clear()
	_joy_touch = -1
	_look_touch = -1
	if joy_knob != null:
		joy_knob.position = (joy_center - Vector2(JOY_KNOB_R, JOY_KNOB_R)).round()


# ================================================================ input
func _input(event: InputEvent) -> void:
	# Nothing here reacts to mouse or keyboard: on a desktop, where the controls are off,
	# every mouse and key event must keep behaving exactly as it did before.
	if _menu:
		# The menus are ordinary Buttons and only ever hear a mouse. Godot used to turn
		# every touch into one; with that emulation switched off in the project file the
		# menus would simply stop responding on a phone, so the touch is bridged into the
		# mouse event they already handle. This runs only while a menu is up: in live play
		# a tap has to stay a tap, or the same bridge would arrive as a left click and mine
		# whatever block the reticle happens to be on.
		_bridge_to_mouse(event)
		return
	if not is_active():
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_touch_down(t.index, t.position)
		else:
			_touch_up(t.index)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		_touch_move(d.index, d.position)


## Feeds a menu the mouse events it expects (it is off while the engine still does the
## mirroring itself, and off on a plain desktop where there is no touch to bridge).
func _bridge_to_mouse(event: InputEvent) -> void:
	if _emulate_mouse:
		return
	if not (Settings.touch_controls or DisplayServer.is_touchscreen_available()):
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = t.pressed
		mb.position = _to_window(t.position)
		mb.global_position = mb.position
		Input.parse_input_event(mb)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		var mm := InputEventMouseMotion.new()
		mm.position = _to_window(d.position)
		mm.global_position = mm.position
		mm.relative = _to_window(d.relative)
		Input.parse_input_event(mm)


func _control_at(pos: Vector2) -> String:
	# buttons win over the stick, if they ever brush each other
	for nm in _btn_nodes:
		if (_rects[nm] as Rect2).has_point(pos):
			return nm
	if (_rects["joystick"] as Rect2).has_point(pos):
		return "joystick"
	return ""


func _touch_down(index: int, pos: Vector2) -> void:
	var c := _control_at(pos)
	if c == "joystick":
		_joy_touch = index
		_joy_move(pos)
	elif c != "":
		_holds[index] = c
		_press_button(c)
	else:
		# anywhere else is the look area
		_look_touch = index
		_look_last = pos


func _touch_move(index: int, pos: Vector2) -> void:
	if index == _joy_touch:
		_joy_move(pos)
	elif index == _look_touch:
		var rel := pos - _look_last
		_look_last = pos
		_post_look(rel)


func _touch_up(index: int) -> void:
	if index == _joy_touch:
		_joy_touch = -1
		_joy_release()
	if _holds.has(index):
		_release_button(str(_holds[index]))
		_holds.erase(index)
	if index == _look_touch:
		_look_touch = -1


# ================================================================ stick
func _joy_move(pos: Vector2) -> void:
	var v: Vector2 = pos - joy_center
	_set_axis("forward", v.y < -DEAD)
	_set_axis("back", v.y > DEAD)
	_set_axis("left", v.x < -DEAD)
	_set_axis("right", v.x > DEAD)
	var clamped := v.limit_length(JOY_BASE_R - JOY_KNOB_R + 4.0)
	joy_knob.position = (joy_center + clamped - Vector2(JOY_KNOB_R, JOY_KNOB_R)).round()


func _joy_release() -> void:
	for a in _axis:
		_set_axis(str(a), false)
	joy_knob.position = (joy_center - Vector2(JOY_KNOB_R, JOY_KNOB_R)).round()


func _set_axis(action: String, on: bool) -> void:
	if bool(_axis[action]) == on:
		return
	_axis[action] = on
	if on:
		Input.action_press(action)
	else:
		Input.action_release(action)


# ================================================================ buttons
func _press_button(nm: String) -> void:
	match nm:
		"attack", "use", "jump", "sneak":
			Input.action_press(nm)
		"backpack":
			_post_key(KEY_E)
		"menu":
			_post_key(KEY_ESCAPE)
		"fly":
			# there is no flight action in the InputMap -- flight is toggled by the /fly
			# command and by a double-tapped Space -- so this runs the real command
			Commands.run_command("fly")


func _release_button(nm: String) -> void:
	match nm:
		"attack", "use", "jump", "sneak":
			Input.action_release(nm)
		"backpack":
			_post_key_release(KEY_E)
		"menu":
			_post_key_release(KEY_ESCAPE)


func _post_look(rel: Vector2) -> void:
	# the same event the mouse produces, fed through the same pipeline, so the existing
	# mouse-look code turns the view and nothing about it is special-cased for touch.
	# Events returned to the engine go back in window coordinates, which is what a real
	# pointer hands over, so the deltas are converted out of canvas space first.
	var mm := InputEventMouseMotion.new()
	mm.relative = _to_window(rel)
	Input.parse_input_event(mm)


## Canvas coordinates -> the window coordinates an input event is expressed in. On a
## device where the viewport is stretched to the window this is not identity, so anything
## synthesised has to be converted or it lands in the wrong place.
func _to_window(p: Vector2) -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return p
	return vp.get_final_transform() * p


func _post_key(k: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.pressed = true
	Input.parse_input_event(ev)


func _post_key_release(k: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.pressed = false
	Input.parse_input_event(ev)
