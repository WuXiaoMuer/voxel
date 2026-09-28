extends CanvasLayer
## In-game HUD (crosshair, hotbar, hearts, air, debug overlay, toasts) and the
## inventory / crafting screen.

const SLOT := 46
const HOTBAR_BOTTOM := 26

## The chat box doubles as the command console: submitting a line that starts
## with "/" runs it through the Commands autoload instead of being a message.
signal chat_submitted(text: String)
signal chat_canceled()

var player
var world
var sky

var root: Control
var crosshair: TextureRect
var hotbar_panel: Panel
var hotbar_slots: Array = []
var hearts: Array = []
var foods: Array = []
var bubbles: Array = []
var debug_panel: Panel
var debug_label: Label
var water_tint: ColorRect
var hurt_flash: ColorRect
var item_label: Label
var toast_box: VBoxContainer
var cursor_icon: InvSlot
var vignette: TextureRect

## The item tooltip: one floating panel that follows the pointer while it is over a
## filled inventory cell. A single widget rather than one per slot, so there is no
## way for two of them to be on screen at once.
var tip_panel: PanelContainer
var tip_name: Label
var tip_desc: Label
var tip_icon: TextureRect
var _tip_id := 0

## Chat / command console. The log is always there (it fades out when idle); the
## text field only appears while it is open.
var chat_panel: Panel
var chat_clip: Control
var chat_log: VBoxContainer
var chat_input: LineEdit
var chat_open := false
var _chat_entries: Array = []      # [Label, keep-visible flag]
var _chat_history: Array = []
var _chat_hist_idx := -1
var _chat_idle := 0.0
const CHAT_KEEP := 60               # lines kept at all
const CHAT_CLOSED_SHOWN := 10       # lines kept on screen when the box is shut
const CHAT_OPEN_SHOWN := 24
const CHAT_LINGER := 8.0            # seconds the backlog stays up after a line
const CHAT_PANEL_H := 230.0

var inv_root: Control
var inv_slots: Array = []
var craft_slots: Array = []
var result_slot: InvSlot
var craft_hint: Array = []
var palette_slots: Array = []
var palette_grid: GridContainer
var pal_names := PackedStringArray()

var debug_visible := false
var _item_label_t: float = 0.0
var _hurt_t: float = 0.0
var _inv_open := false
var _hunger_shown := true
## [Label, english source] pairs for the fixed captions in the inventory screen,
## so a language change can re-letter them without rebuilding the whole HUD.
var _lang_labels: Array = []


func build(p, w, s) -> void:
	player = p
	world = w
	sky = s
	layer = 10
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	root.theme = Art.theme
	add_child(root)
	root.resized.connect(_layout)

	water_tint = ColorRect.new()
	water_tint.color = Color(0.10, 0.30, 0.60, 0.0)
	water_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	water_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(water_tint)

	vignette = Art.make_vignette()
	vignette.modulate = Color(0.5, 0.5, 0.55, 0.5)
	root.add_child(vignette)

	hurt_flash = ColorRect.new()
	hurt_flash.color = Color(0.75, 0.05, 0.05, 0.0)
	hurt_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	hurt_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hurt_flash)

	crosshair = TextureRect.new()
	crosshair.texture = Art.tex_crosshair
	crosshair.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	crosshair.custom_minimum_size = Vector2(45, 45)
	crosshair.size = Vector2(45, 45)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(crosshair)

	hotbar_panel = Panel.new()
	var sb := Art._sb_texture(Art.tex_panel, 4, 6)
	hotbar_panel.add_theme_stylebox_override("panel", sb)
	hotbar_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hotbar_panel)

	for i in 9:
		var sl := InvSlot.new()
		sl.index = i
		sl.slot_pressed.connect(_on_hotbar_slot)
		hotbar_panel.add_child(sl)
		hotbar_slots.append(sl)

	for i in 10:
		var h := TextureRect.new()
		h.texture = Art.tex_heart_full
		h.stretch_mode = TextureRect.STRETCH_SCALE
		h.custom_minimum_size = Vector2(18, 18)
		h.size = Vector2(18, 18)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(h)
		hearts.append(h)

	# hunger sits on the same line as the hearts, right aligned and mirrored, so
	# the first drumstick is the one nearest the corner
	for i in 10:
		var f := TextureRect.new()
		f.texture = Art.tex_food_full
		f.stretch_mode = TextureRect.STRETCH_SCALE
		f.custom_minimum_size = Vector2(18, 18)
		f.size = Vector2(18, 18)
		f.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(f)
		foods.append(f)

	for i in 10:
		var b := TextureRect.new()
		b.texture = Art.tex_bubble_full
		b.stretch_mode = TextureRect.STRETCH_SCALE
		b.custom_minimum_size = Vector2(18, 18)
		b.size = Vector2(18, 18)
		b.visible = false
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(b)
		bubbles.append(b)

	item_label = Label.new()
	item_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	item_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item_label.modulate = Color(1, 1, 1, 0)
	root.add_child(item_label)

	toast_box = VBoxContainer.new()
	toast_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(toast_box)

	debug_panel = Panel.new()
	debug_panel.add_theme_stylebox_override("panel",
		Art._sb_flat(Color(0, 0, 0, 0.55), 0, Color(0, 0, 0, 0)))
	debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	debug_panel.visible = false
	root.add_child(debug_panel)
	debug_label = Label.new()
	debug_label.add_theme_font_size_override("font_size", PFont.S)
	debug_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	debug_label.offset_left = 8
	debug_label.offset_top = 6
	debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	debug_panel.add_child(debug_label)

	cursor_icon = InvSlot.new()
	cursor_icon.flat = true
	cursor_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor_icon.size = Vector2(SLOT, SLOT)
	cursor_icon.visible = false
	cursor_icon.z_index = 100
	root.add_child(cursor_icon)

	_build_inventory()
	_build_chat()
	_build_tooltip()
	_layout()

	if not I18n.changed.is_connected(_apply_language):
		I18n.changed.connect(_apply_language)

	player.health_changed.connect(refresh_health)
	player.hunger_changed.connect(refresh_hunger)
	player.hotbar_changed.connect(refresh_hotbar)
	player.selected_changed.connect(_on_selection_changed)
	player.stats_changed.connect(func(_n): refresh_air())
	refresh_hotbar()
	refresh_health()
	refresh_hunger()
	refresh_air()


# ================================================================ layout
func _layout() -> void:
	if root == null:
		return
	var s := root.size
	var bar_w := 9 * SLOT + 14
	var bar_h := SLOT + 14
	hotbar_panel.position = Vector2(round((s.x - bar_w) * 0.5), s.y - bar_h - HOTBAR_BOTTOM)
	hotbar_panel.size = Vector2(bar_w, bar_h)
	for i in 9:
		hotbar_slots[i].position = Vector2(7 + i * SLOT, 7)
		hotbar_slots[i].size = Vector2(SLOT, SLOT)
	var hx := hotbar_panel.position.x
	var hy := hotbar_panel.position.y
	for i in 10:
		hearts[i].position = Vector2(hx + 2 + i * 19, hy - 28)
		foods[i].position = Vector2(hx + bar_w - 20 - i * 19, hy - 28)
		bubbles[i].position = Vector2(hx + 2 + i * 19, hy - 48)
	crosshair.position = Vector2(round((s.x - 45) * 0.5), round((s.y - 45) * 0.5))
	item_label.position = Vector2(0, hy - 62)
	item_label.size = Vector2(s.x, 30)
	toast_box.position = Vector2(s.x - 330, 16)
	toast_box.size = Vector2(314, 300)
	debug_panel.position = Vector2(14, 14)
	_fit_debug_panel()
	_layout_chat()


# ================================================================ chat / console
func _build_chat() -> void:
	chat_panel = Panel.new()
	chat_panel.add_theme_stylebox_override("panel",
		Art._sb_flat(Color(0, 0, 0, 0.42), 0, Color(0, 0, 0, 0)))
	chat_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chat_panel.visible = false
	root.add_child(chat_panel)

	# clip so a long backlog spills nowhere instead of drawing over the hotbar
	chat_clip = Control.new()
	chat_clip.set_anchors_preset(Control.PRESET_FULL_RECT)
	chat_clip.clip_contents = true
	chat_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chat_panel.add_child(chat_clip)

	chat_log = VBoxContainer.new()
	# sized and positioned by hand in `_refresh_chat_visibility`, so the visible
	# block is pinned to the bottom of the panel and the older lines are clipped
	# off the top rather than pushing the whole log down out of view
	chat_log.alignment = BoxContainer.ALIGNMENT_BEGIN
	chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chat_clip.add_child(chat_log)

	# the field lives outside the clip, at the bottom of the panel, so it is never
	# cut off by the backlog above it
	chat_input = LineEdit.new()
	chat_input.visible = false
	chat_input.mouse_filter = Control.MOUSE_FILTER_STOP
	chat_input.add_theme_font_size_override("font_size", PFont.S)
	chat_input.text_submitted.connect(func(t: String) -> void: chat_submitted.emit(t))
	chat_input.gui_input.connect(_on_chat_key)
	root.add_child(chat_input)


func _layout_chat() -> void:
	if chat_panel == null:
		return
	var s := root.size
	var w := minf(700.0, s.x - 40.0)
	var h := CHAT_PANEL_H
	chat_panel.position = Vector2(16, s.y - h - 104)
	chat_panel.size = Vector2(w, h)
	chat_input.position = chat_panel.position + Vector2(6, h - 34)
	chat_input.size = Vector2(w - 12, 30)
	_refresh_chat_visibility()


## Prints a line into the chat log. `color` tints it (command output, errors).
func chat_print(text: String, color: Color = Color(1, 1, 1)) -> void:
	if chat_log == null or text == "":
		return
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", PFont.S)
	l.add_theme_color_override("font_color", color)
	# one line per message, clipped rather than wrapped: the log is positioned from
	# a measured line height, so a wrapping line would silently overlap the input
	# field. Chat lines are far shorter than the panel is wide, so this is safe.
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chat_log.add_child(l)
	_chat_entries.append(l)
	while _chat_entries.size() > CHAT_KEEP:
		var old: Label = _chat_entries.pop_front()
		old.queue_free()
	_chat_idle = 0.0
	chat_panel.visible = true
	_refresh_chat_visibility()


func is_chat_open() -> bool:
	return chat_open


func open_chat(prefix: String = "") -> void:
	if chat_open:
		return
	chat_open = true
	chat_panel.visible = true
	chat_input.visible = true
	chat_input.text = prefix
	chat_input.caret_column = prefix.length()
	chat_input.grab_focus()
	_chat_hist_idx = _chat_history.size()
	_chat_idle = 0.0
	_layout_chat()
	_refresh_chat_visibility()


func close_chat() -> void:
	chat_open = false
	chat_input.visible = false
	chat_input.text = ""
	chat_input.release_focus()
	_chat_idle = 0.0
	_layout_chat()
	_refresh_chat_visibility()


func _chat_line_height() -> float:
	if PFont.font != null:
		return PFont.font.get_height(PFont.S) + 3.0
	return 20.0


## Decides which lines are on screen and pins them to the bottom of the panel.
## The visible count is derived from the panel height rather than hard-coded, so a
## long `/help` cannot push the newest line out of sight.
func _refresh_chat_visibility() -> void:
	# the input field occupies the bottom of the panel while the box is open, so the
	# log has to stop above it -- otherwise the newest line hides behind the field
	var bottom := 42.0 if chat_open else 6.0
	var avail := CHAT_PANEL_H - bottom - 6.0
	var line_h := _chat_line_height()
	var fits := maxi(1, int(avail / line_h))
	var shown := mini(CHAT_OPEN_SHOWN if chat_open else CHAT_CLOSED_SHOWN, fits)
	var n := _chat_entries.size()
	var vis := 0
	for i in n:
		var l: Label = _chat_entries[i]
		if not is_instance_valid(l):
			continue
		var on := i >= n - shown
		l.visible = on
		if on:
			vis += 1
	if chat_log != null and chat_panel != null:
		chat_log.size = Vector2(maxf(10.0, chat_panel.size.x - 16.0), float(vis) * line_h)
		chat_log.position = Vector2(8.0, maxf(4.0, CHAT_PANEL_H - bottom - chat_log.size.y))
	if vis == 0 and not chat_open:
		chat_panel.visible = false


func _on_chat_key(ev: InputEvent) -> void:
	if not (ev is InputEventKey) or not ev.pressed or ev.echo:
		return
	var k := (ev as InputEventKey).keycode
	match k:
		KEY_ESCAPE:
			chat_canceled.emit()
			chat_input.accept_event()
		KEY_UP:
			_chat_recall(-1)
			chat_input.accept_event()
		KEY_DOWN:
			_chat_recall(1)
			chat_input.accept_event()
		KEY_TAB:
			_chat_complete()
			chat_input.accept_event()


## Up/Down walk the submitted history, the way a shell does.
func _chat_recall(dir: int) -> void:
	if _chat_history.is_empty():
		return
	_chat_hist_idx = clampi(_chat_hist_idx + dir, 0, _chat_history.size())
	if _chat_hist_idx >= _chat_history.size():
		chat_input.text = ""
	else:
		chat_input.text = str(_chat_history[_chat_hist_idx])
	chat_input.caret_column = chat_input.text.length()


## Tab completes a partly typed command name, and only a command name -- guessing
## arguments would be worse than doing nothing.
func _chat_complete() -> void:
	var t := chat_input.text
	if not t.begins_with("/"):
		return
	var body := t.substr(1)
	if body.contains(" "):
		return
	var matches: Array = []
	for n in Commands.command_names():
		if str(n).begins_with(body.to_lower()):
			matches.append(str(n))
	if matches.is_empty():
		return
	if matches.size() == 1:
		chat_input.text = "/" + str(matches[0]) + " "
	else:
		chat_print("  " + "  ".join(matches), Color(0.7, 0.85, 1.0))
	chat_input.caret_column = chat_input.text.length()


## Called by main once a line is accepted, so the history survives reopening.
func remember_line(text: String) -> void:
	if text.strip_edges() == "":
		return
	if _chat_history.is_empty() or str(_chat_history[-1]) != text:
		_chat_history.append(text)
	if _chat_history.size() > 60:
		_chat_history.pop_front()
	_chat_hist_idx = _chat_history.size()


# ================================================================ item tooltip
func _build_tooltip() -> void:
	# A PanelContainer, not a Panel: a plain Control never grows to fit its children,
	# so the tooltip had no background and no width to place itself by.
	tip_panel = PanelContainer.new()
	var sb := Art._sb_flat(Color(0.06, 0.06, 0.09, 0.94), 1, Color(0.45, 0.48, 0.60, 0.9))
	sb.content_margin_left = 9
	sb.content_margin_right = 10
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	tip_panel.add_theme_stylebox_override("panel", sb)
	tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tip_panel.z_index = 120
	tip_panel.visible = false
	root.add_child(tip_panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tip_panel.add_child(row)

	tip_icon = TextureRect.new()
	tip_icon.custom_minimum_size = Vector2(32, 32)
	tip_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tip_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tip_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tip_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(tip_icon)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)

	tip_name = Label.new()
	tip_name.add_theme_font_size_override("font_size", PFont.M)
	tip_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(tip_name)

	tip_desc = Label.new()
	tip_desc.add_theme_font_size_override("font_size", PFont.S)
	tip_desc.add_theme_color_override("font_color", Color(0.78, 0.80, 0.86))
	tip_desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(tip_desc)


## Wired to every inventory cell. `id` 0 means the pointer left the slot.
func _on_slot_hover(id: int, at: Vector2) -> void:
	if id <= 0:
		_tip_id = 0
		tip_panel.visible = false
		return
	_tip_id = id
	tip_icon.texture = Items.icon(id)
	tip_name.text = Items.name_of(id)
	tip_desc.text = Items.describe(id)
	tip_panel.visible = true
	_place_tooltip(at)


## Puts the tooltip beside the cell, flipping to the other side when it would run
## off the screen. Clamped rather than merely flipped, so it is on screen always.
func _place_tooltip(at: Vector2) -> void:
	var want := tip_panel.get_combined_minimum_size()
	var s := root.size
	var pos := at + Vector2(6, -6)
	if pos.x + want.x > s.x - 4.0:
		pos.x = at.x - want.x - 52.0
	pos.x = clampf(pos.x, 4.0, maxf(4.0, s.x - want.x - 4.0))
	pos.y = clampf(pos.y, 4.0, maxf(4.0, s.y - want.y - 4.0))
	tip_panel.position = pos.round()


## Keeps a live tooltip in step with a changing world: a slot that empties under the
## cursor, a language switch, or the panel being rebuilt.
func _sync_tooltip() -> void:
	if _tip_id <= 0 or not tip_panel.visible:
		return
	tip_name.text = Items.name_of(_tip_id)
	tip_desc.text = Items.describe(_tip_id)
	if not _inv_open:
		_tip_id = 0
		tip_panel.visible = false
		return
	_place_tooltip(root.get_local_mouse_position())


# ================================================================ hotbar
func _on_hotbar_slot(index: int, _button: int) -> void:
	player.select_slot(index)


func refresh_hotbar() -> void:
	for i in 9:
		var st: Dictionary = player.hotbar[i]
		hotbar_slots[i].set_item(int(st["id"]), int(st["count"]))
	_refresh_cursor()


func _on_selection_changed() -> void:
	for i in 9:
		hotbar_slots[i].highlighted = i == player.selected
		hotbar_slots[i].queue_redraw()
	_show_item_name()
	if _inv_open:
		refresh_inventory()


func _show_item_name() -> void:
	var id: int = player.selected_id()
	if id <= 0:
		return
	item_label.text = Items.name_of(id)
	_item_label_t = 2.0


func refresh_health() -> void:
	var hp: float = player.health
	for i in 10:
		var v := hp - float(i) * 2.0
		if v >= 2.0:
			hearts[i].texture = Art.tex_heart_full
		elif v >= 1.0:
			hearts[i].texture = Art.tex_heart_half
		else:
			hearts[i].texture = Art.tex_heart_empty


## Creative mode has no hunger bar, exactly like Minecraft: the whole row hides.
func refresh_hunger() -> void:
	_hunger_shown = not player.creative
	var h: float = player.hunger
	for i in 10:
		foods[i].visible = _hunger_shown
		var v := h - float(i) * 2.0
		if v >= 2.0:
			foods[i].texture = Art.tex_food_full
		elif v >= 1.0:
			foods[i].texture = Art.tex_food_half
		else:
			foods[i].texture = Art.tex_food_empty


func refresh_air() -> void:
	var a := 0.0
	if player.has_method("head_in_water") and player.head_in_water():
		a = player.air
	var show := a < 11.9
	for i in 10:
		bubbles[i].visible = show and float(i) < a
		bubbles[i].texture = Art.tex_bubble_full


func flash_hurt() -> void:
	_hurt_t = 0.55


func set_debug(visible_now: bool) -> void:
	debug_visible = visible_now
	debug_panel.visible = visible_now


func set_debug_text(t: String) -> void:
	debug_label.text = t
	_fit_debug_panel()


## Sizes the panel to the text it actually holds. The overlay is a fixed-size box
## otherwise, and the last lines of a long frame (drops, draw calls, VRAM) get cut
## off or spill past the background.
func _fit_debug_panel() -> void:
	if debug_panel == null or debug_label == null:
		return
	var font := debug_label.get_theme_font("font")
	var fs := debug_label.get_theme_font_size("font_size")
	if font == null:
		return
	var lines := debug_label.text.split("\n")
	var widest := 1.0
	for line in lines:
		widest = maxf(widest, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs).x)
	var line_h := font.get_height(fs) + 2.0
	debug_panel.size = Vector2(widest + 20.0, float(lines.size()) * line_h + 14.0)


func toast(msg: String) -> void:
	var l := Label.new()
	l.text = msg
	l.add_theme_font_size_override("font_size", PFont.S)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.modulate = Color(0, 0, 0, 0)
	toast_box.add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "modulate", Color(1, 1, 1, 1), 0.15)
	tw.tween_interval(2.2)
	tw.tween_property(l, "modulate", Color(0, 0, 0, 0), 0.6)
	tw.tween_callback(l.queue_free)


func _process(delta: float) -> void:
	if _item_label_t > 0.0:
		_item_label_t -= delta
		item_label.modulate.a = clampf(_item_label_t, 0.0, 1.0)
	if _hurt_t > 0.0:
		_hurt_t = maxf(0.0, _hurt_t - delta * 1.6)
		hurt_flash.color.a = _hurt_t * 0.45
	if _inv_open:
		cursor_icon.position = root.get_local_mouse_position() - Vector2(SLOT * 0.5, SLOT * 0.5)
		_sync_tooltip()
	if sky != null and sky.get("underwater") != null:
		water_tint.color.a = lerpf(water_tint.color.a, 0.28 if sky.get("underwater") else 0.0,
			clampf(delta * 5.0, 0.0, 1.0))
	if player != null and (not player.creative) != _hunger_shown:
		refresh_hunger()
	# the chat backlog lingers for a few seconds, then fades out; opening the box
	# brings the whole history back
	if chat_panel != null:
		if chat_open:
			_chat_idle = 0.0
			chat_panel.modulate.a = 1.0
		elif not _chat_entries.is_empty():
			_chat_idle += delta
			var a := clampf(CHAT_LINGER + 1.0 - _chat_idle, 0.0, 1.0)
			chat_panel.modulate.a = a
			if a <= 0.0:
				chat_panel.visible = false


func _lang_label(key: String) -> Label:
	var l := Label.new()
	l.text = I18n.t(key)
	_lang_labels.append([l, key])
	return l


## Connected to I18n.changed: re-letters the fixed captions in place.
func _apply_language() -> void:
	for entry in _lang_labels:
		(entry[0] as Label).text = I18n.t(str(entry[1]))
	if craft_hint.size() == 2:
		_fill_craft_hint()
	# item names shown while the inventory is open are rebuilt on the next refresh
	if _inv_open:
		refresh_inventory()
	_show_item_name()
	_sync_tooltip()


## The recipe list beside the crafting grid: the header plus one line per recipe,
## read straight off the table so it cannot drift out of step with the matcher.
func _fill_craft_hint() -> void:
	var lines: Array = []
	if player != null:
		lines = player.recipe_lines()
	var half := int(ceil(float(lines.size()) / 2.0))
	for c in 2:
		if c >= craft_hint.size():
			return
		var part: Array = lines.slice(c * half, mini((c + 1) * half, lines.size()))
		(craft_hint[c] as Label).text = "\n".join(part)


# ================================================================ inventory
func _build_inventory() -> void:
	inv_root = Control.new()
	inv_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	inv_root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	inv_root.theme = Art.theme
	inv_root.visible = false
	add_child(inv_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	inv_root.add_child(dim)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", Art._sb_texture(Art.tex_panel, 6, 14))
	# anchored to the screen with a margin rather than given a fixed size: the panel
	# grew past the bottom of a 1024x576 window once the recipe list became complete,
	# and a fixed size would just do it again on the next window
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 40
	panel.offset_top = 14
	panel.offset_right = -40
	panel.offset_bottom = -14
	inv_root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 18
	vb.offset_top = 12
	vb.offset_right = -18
	vb.offset_bottom = -12
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	var title := _lang_label("INVENTORY")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	vb.add_child(top)

	# --- crafting
	var craft_col := VBoxContainer.new()
	craft_col.add_theme_constant_override("separation", 4)
	top.add_child(craft_col)
	var clabel := _lang_label("CRAFTING")
	craft_col.add_child(clabel)
	var cgrid := GridContainer.new()
	cgrid.columns = 3
	cgrid.add_theme_constant_override("h_separation", 2)
	cgrid.add_theme_constant_override("v_separation", 2)
	cgrid.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	craft_col.add_child(cgrid)
	for i in 9:
		var sl := InvSlot.new()
		sl.index = 100 + i
		sl.slot_pressed.connect(_on_inv_slot)
		sl.hover_changed.connect(_on_slot_hover)
		cgrid.add_child(sl)
		craft_slots.append(sl)

	var arrow := Label.new()
	arrow.text = ">>"
	arrow.custom_minimum_size = Vector2(50, 46)
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(arrow)

	result_slot = InvSlot.new()
	result_slot.index = 200
	result_slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	result_slot.slot_pressed.connect(_on_inv_slot)
	top.add_child(result_slot)

	# the hint list is generated from the recipe table, so it lists every recipe the
	# game actually accepts rather than a hand-kept sample of the first four. Split
	# over two columns: at one line per recipe a single column is taller than the
	# panel, and it would push the backpack off the bottom of the screen.
	var hint_wrap := VBoxContainer.new()
	hint_wrap.add_theme_constant_override("separation", 4)
	hint_wrap.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	top.add_child(hint_wrap)
	var hint_head := _lang_label("Drag items into the grid.")
	hint_head.add_theme_font_size_override("font_size", PFont.S)
	hint_wrap.add_child(hint_head)
	var hint_cols := HBoxContainer.new()
	hint_cols.add_theme_constant_override("separation", 20)
	hint_wrap.add_child(hint_cols)
	craft_hint = []
	for c in 2:
		var col := Label.new()
		col.add_theme_font_size_override("font_size", PFont.S)
		col.autowrap_mode = TextServer.AUTOWRAP_OFF
		col.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		hint_cols.add_child(col)
		craft_hint.append(col)
	_fill_craft_hint()

	# --- creative palette
	var pal_wrap := VBoxContainer.new()
	pal_wrap.add_theme_constant_override("separation", 4)
	pal_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(pal_wrap)
	var pal_label := _lang_label("BLOCKS  (click to take a stack)")
	pal_label.add_theme_font_size_override("font_size", PFont.S)
	pal_wrap.add_child(pal_label)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(430, 200)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pal_wrap.add_child(scroll)
	palette_grid = GridContainer.new()
	palette_grid.columns = 7
	palette_grid.add_theme_constant_override("h_separation", 6)
	palette_grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(palette_grid)

	for i in range(1, 48):
		if Blocks.defs[i] == null or i == Blocks.WATER:
			continue
		var sl := InvSlot.new()
		sl.index = 300 + pal_names.size()
		sl.set_item(i, 64)
		sl.slot_pressed.connect(_on_inv_slot)
		sl.hover_changed.connect(_on_slot_hover)
		palette_grid.add_child(sl)
		palette_slots.append(sl)
		pal_names.append("")

	# the pure items too, so food is reachable in creative mode
	for id in [Blocks.ITEM_STICK, Blocks.ITEM_COAL, Blocks.ITEM_IRON, Blocks.ITEM_GOLD,
			Blocks.ITEM_DIAMOND, Blocks.ITEM_COPPER, Blocks.ITEM_APPLE, Blocks.ITEM_BREAD]:
		var it := InvSlot.new()
		it.index = 300 + pal_names.size()
		it.set_item(id, 64)
		it.slot_pressed.connect(_on_inv_slot)
		it.hover_changed.connect(_on_slot_hover)
		palette_grid.add_child(it)
		palette_slots.append(it)
		pal_names.append("")

	# --- inventory grid
	var invlab := _lang_label("BACKPACK")
	vb.add_child(invlab)
	var igrid := GridContainer.new()
	igrid.columns = 9
	igrid.add_theme_constant_override("h_separation", 2)
	igrid.add_theme_constant_override("v_separation", 2)
	igrid.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	vb.add_child(igrid)
	for i in 27:
		var sl := InvSlot.new()
		sl.index = i
		sl.slot_pressed.connect(_on_inv_slot)
		sl.hover_changed.connect(_on_slot_hover)
		igrid.add_child(sl)
		inv_slots.append(sl)

	var hblab := _lang_label("HOTBAR")
	vb.add_child(hblab)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 2)
	hb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	vb.add_child(hb)
	for i in 9:
		var sl := InvSlot.new()
		sl.index = 50 + i
		sl.slot_pressed.connect(_on_inv_slot)
		sl.hover_changed.connect(_on_slot_hover)
		hb.add_child(sl)
		inv_slots.append(sl)

	cursor_icon.size = Vector2(SLOT, SLOT)


func open_inventory(open: bool) -> void:
	_inv_open = open
	inv_root.visible = open
	cursor_icon.visible = open and (int(player.cursor_stack["id"]) > 0)
	if open:
		refresh_inventory()
	else:
		# the tooltip belongs to the inventory screen; closing it must take the
		# tooltip with it, or a stale one hangs over the world
		_tip_id = 0
		tip_panel.visible = false


func is_inventory_open() -> bool:
	return _inv_open


func refresh_inventory() -> void:
	for i in 27:
		var st: Dictionary = player.inventory[i]
		inv_slots[i].set_item(int(st["id"]), int(st["count"]))
	for i in 9:
		var st2: Dictionary = player.hotbar[i]
		inv_slots[27 + i].set_item(int(st2["id"]), int(st2["count"]))
		inv_slots[27 + i].highlighted = i == player.selected
		inv_slots[27 + i].queue_redraw()
	for i in 9:
		var st3: Dictionary = player.crafting[i]
		craft_slots[i].set_item(int(st3["id"]), int(st3["count"]))
	var res: Dictionary = player.craft_result()
	result_slot.set_item(int(res["id"]), int(res["count"]))
	_refresh_cursor()


func _refresh_cursor() -> void:
	var st: Dictionary = player.cursor_stack
	cursor_icon.set_item(int(st["id"]), int(st["count"]))
	cursor_icon.visible = _inv_open and int(st["id"]) > 0


func _on_inv_slot(index: int, button: int) -> void:
	if index >= 300:
		var i := index - 300
		# creative palette: grab a full stack of that block
		var id := 0
		var n := 0
		for c in palette_slots:
			if c.index == index:
				id = c.item_id
				n = c.count
		if id > 0:
			player.cursor_stack = {"id": id, "count": n}
			Sfx.play("click", -12.0)
			_refresh_cursor()
		return

	if index == 200:
		var res: Dictionary = player.craft_result()
		if int(res["id"]) <= 0:
			return
		var cur: Dictionary = player.cursor_stack
		if int(cur["id"]) != 0 and (int(cur["id"]) != int(res["id"])
				or int(cur["count"]) + int(res["count"]) > Items.max_stack(int(res["id"]))):
			return
		if int(cur["id"]) == 0:
			player.cursor_stack = {"id": int(res["id"]), "count": int(res["count"])}
		else:
			cur["count"] = int(cur["count"]) + int(res["count"])
		player.consume_crafting()
		Sfx.play("craft", -8.0)
		refresh_inventory()
		return

	var arr = _array_for(index)
	if arr == null:
		return
	var li := _local_index(index)
	var st: Dictionary = arr[li]
	var cur2: Dictionary = player.cursor_stack
	var cid := int(cur2["id"])
	var ccount := int(cur2["count"])
	var sid := int(st["id"])
	var scount := int(st["count"])

	if button == MOUSE_BUTTON_RIGHT:
		if cid == 0:
			if scount > 0:
				var half := int(ceil(float(scount) * 0.5))
				player.cursor_stack = {"id": sid, "count": half}
				st["count"] = scount - half
				if int(st["count"]) == 0:
					st["id"] = 0
		else:
			if sid == 0:
				st["id"] = cid
				st["count"] = 1
				cur2["count"] = ccount - 1
			elif sid == cid and scount < Items.max_stack(sid):
				st["count"] = scount + 1
				cur2["count"] = ccount - 1
			if int(cur2["count"]) <= 0:
				player.cursor_stack = {"id": 0, "count": 0}
	else:
		if cid == 0:
			if sid != 0:
				player.cursor_stack = {"id": sid, "count": scount}
				st["id"] = 0
				st["count"] = 0
		elif sid == cid:
			var maxs := Items.max_stack(sid)
			var add := mini(maxs - scount, ccount)
			st["count"] = scount + add
			cur2["count"] = ccount - add
			if int(cur2["count"]) <= 0:
				player.cursor_stack = {"id": 0, "count": 0}
		else:
			player.cursor_stack = {"id": sid, "count": scount}
			st["id"] = cid
			st["count"] = ccount
	Sfx.play("click", -16.0)
	player.notify_inventory_changed()
	refresh_inventory()


func _array_for(index: int):
	if index >= 50 and index < 59:
		return player.hotbar
	if index >= 100 and index < 109:
		return player.crafting
	if index >= 0 and index < 27:
		return player.inventory
	return null


func _local_index(index: int) -> int:
	if index >= 50 and index < 59:
		return index - 50
	if index >= 100 and index < 109:
		return index - 100
	return index