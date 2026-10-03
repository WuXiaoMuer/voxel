class_name InvSlot
extends Control
## One inventory cell: frame, isometric item icon and stack count.

signal slot_pressed(index: int, button: int)
## Emitted with the item under the cursor (0 when the pointer leaves). The HUD owns
## the tooltip widget, so the slot only reports what it is showing.
signal hover_changed(id: int, screen_pos: Vector2)

var index := -1
var item_id := 0
var count := 0
var highlighted := false
var flat := false
var dur := -1.0            # 0..1 tool durability, or -1 when the item has none
var _hover := false


func _ready() -> void:
	custom_minimum_size = Vector2(46, 46)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(_on_hover_in)
	mouse_exited.connect(_on_hover_out)


func _on_hover_in() -> void:
	_hover = true
	queue_redraw()
	if item_id > 0:
		hover_changed.emit(item_id, get_global_rect().end)


func _on_hover_out() -> void:
	_hover = false
	queue_redraw()
	hover_changed.emit(0, Vector2.ZERO)


func set_item(id: int, n: int) -> void:
	item_id = id
	count = n
	if id <= 0:
		dur = -1.0
	queue_redraw()


func set_dur(f: float) -> void:
	dur = f
	queue_redraw()


func _font() -> Font:
	return PFont.font if PFont.ok else ThemeDB.fallback_font


func _draw() -> void:
	var s := size
	if not flat:
		var frame := Art.tex_slot_sel if highlighted else Art.tex_slot
		draw_texture_rect(frame, Rect2(Vector2.ZERO, s), false)
	if item_id <= 0:
		return
	var icon := Items.icon(item_id)
	if icon == null:
		return
	# Centre a *square* icon in the cell. A grid column can be wider than it is tall
	# (or the reverse), and pinning the icon to the top-left then left a gap on one
	# side while the count stayed glued to the far edge -- which is what made the
	# number look detached from the item it belongs to.
	var inset := 5.0
	var box := Vector2(s.x - inset * 2.0, s.y - inset * 2.0)
	var side := maxf(4.0, minf(box.x, box.y))
	var icon_pos := Vector2(roundf((s.x - side) * 0.5), roundf((s.y - side) * 0.5))
	var icon_rect := Rect2(icon_pos, Vector2(side, side))
	draw_texture_rect(icon, icon_rect, false)
	if count > 1:
		_draw_count(icon_rect, count)
	if dur >= 0.0 and dur < 1.0:
		_draw_dur(icon_rect)
	if _hover:
		draw_rect(Rect2(Vector2.ZERO, s), Color(1, 1, 1, 0.28), false, 2.0)


## The durability bar along the bottom of the icon, green fading to red as it wears.
func _draw_dur(cell: Rect2) -> void:
	var bar_h := 3.0
	var y := cell.position.y + cell.size.y - bar_h
	var full := Rect2(Vector2(cell.position.x, y), Vector2(cell.size.x, bar_h))
	draw_rect(full, Color(0, 0, 0, 0.7))
	var f := clampf(dur, 0.0, 1.0)
	var col := Color(0.35, 0.85, 0.25).lerp(Color(0.9, 0.2, 0.15), 1.0 - f)
	draw_rect(Rect2(Vector2(cell.position.x, y), Vector2(cell.size.x * f, bar_h)), col)


## The stack count, bottom-right of the *icon* and always fully inside the cell.
##
## The baseline has to be lifted by the font's descent, not by a guessed constant:
## a bitmap font reports zero descent while a fallback outline font does not, so a
## hard-coded offset put the glyphs' feet below the cell edge on one of them and the
## number came out sliced in half along the bottom of every slot.
func _draw_count(cell: Rect2, n: int) -> void:
	var f := _font()
	var txt := str(n)
	var fs := 16
	var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var descent := f.get_descent(fs)
	var pad := 2.0
	var pos := Vector2(
		roundf(cell.position.x + cell.size.x - w - pad),
		roundf(cell.position.y + cell.size.y - pad - descent))
	# a 1px drop shadow, so a white number stays legible on a white-ish icon
	draw_string(f, pos + Vector2(1, 1), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
		Color(0, 0, 0, 0.9))
	draw_string(f, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			slot_pressed.emit(index, mb.button_index)
			accept_event()