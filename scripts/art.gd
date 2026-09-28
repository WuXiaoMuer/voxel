extends Node
## Procedural GUI artwork + the global Theme.
## Every texture here is drawn pixel by pixel at runtime.

const MC_BG := Color(0.776, 0.776, 0.776)      # inventory grey
const MC_DARK := Color(0.216, 0.216, 0.216)
const MC_LIGHT := Color(1, 1, 1)

var tex_button: ImageTexture
var tex_button_hover: ImageTexture
var tex_button_press: ImageTexture
var tex_button_disabled: ImageTexture
var tex_panel: ImageTexture
var tex_slot: ImageTexture
var tex_slot_sel: ImageTexture
var tex_heart_full: ImageTexture
var tex_heart_half: ImageTexture
var tex_heart_empty: ImageTexture
var tex_bubble_full: ImageTexture
var tex_bubble_empty: ImageTexture
var tex_food_full: ImageTexture
var tex_food_half: ImageTexture
var tex_food_empty: ImageTexture
var tex_crack: Array = []
var tex_crosshair: ImageTexture
var tex_dirt_bg: ImageTexture
var tex_vignette: ImageTexture
var tex_slot_armor: ImageTexture

var theme: Theme


func _ready() -> void:
	_build_all()


func _tex(img: Image) -> ImageTexture:
	return ImageTexture.create_from_image(img)


func _img(w: int, h: int) -> Image:
	return Image.create(w, h, false, Image.FORMAT_RGBA8)


func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


# ---------------------------------------------------------------- widget chrome
func _bevel_box(fill: Color, light: Color, dark: Color, size: int = 20) -> Image:
	var img := _img(size, size)
	img.fill(fill)
	for i in size:
		img.set_pixel(i, 0, MC_DARK)
		img.set_pixel(i, size - 1, MC_DARK)
		img.set_pixel(0, i, MC_DARK)
		img.set_pixel(size - 1, i, MC_DARK)
		img.set_pixel(i, 1, light)
		img.set_pixel(1, i, light)
		img.set_pixel(i, size - 2, dark)
		img.set_pixel(size - 2, i, dark)
	return img


func _inset_box(fill: Color, dark: Color, light: Color, size: int = 18) -> Image:
	var img := _img(size, size)
	img.fill(fill)
	for i in size:
		img.set_pixel(i, 0, dark)
		img.set_pixel(0, i, dark)
		img.set_pixel(i, size - 1, light)
		img.set_pixel(size - 1, i, light)
	return img


func _panel_box(w: int, h: int) -> Image:
	var img := _img(w, h)
	img.fill(MC_BG)
	for i in w:
		img.set_pixel(i, 0, MC_LIGHT)
		img.set_pixel(i, h - 1, Color(0.33, 0.33, 0.33))
	for j in h:
		img.set_pixel(0, j, MC_LIGHT)
		img.set_pixel(w - 1, j, Color(0.33, 0.33, 0.33))
	return img


func _slot_box(size: int, highlight: bool) -> Image:
	var img := _img(size, size)
	img.fill(Color(0.545, 0.545, 0.545))
	for i in size:
		img.set_pixel(i, 0, Color(0.216, 0.216, 0.216))
		img.set_pixel(0, i, Color(0.216, 0.216, 0.216))
		img.set_pixel(i, size - 1, Color(1, 1, 1, 0.65))
		img.set_pixel(size - 1, i, Color(1, 1, 1, 0.65))
		img.set_pixel(i, 1, Color(0.216, 0.216, 0.216, 0.55))
		img.set_pixel(1, i, Color(0.216, 0.216, 0.216, 0.55))
	if highlight:
		for i in size:
			img.set_pixel(i, 0, Color(1, 1, 1, 0.95))
			img.set_pixel(i, size - 1, Color(1, 1, 1, 0.95))
			img.set_pixel(0, i, Color(1, 1, 1, 0.95))
			img.set_pixel(size - 1, i, Color(1, 1, 1, 0.95))
	return img


# ---------------------------------------------------------------- hearts
const HEART := [
	"0110110",
	"1111111",
	"1111111",
	"1111111",
	"0111110",
	"0011100",
	"0001000",
]


func _heart(fill: Color, half: bool = false) -> Image:
	var size := 9
	var img := _img(size, size)
	img.fill(Color(0, 0, 0, 0))
	var ox := 1
	var oy := 1
	# outer dark outline
	for y in 7:
		for x in 7:
			if HEART[y][x] != "1":
				continue
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var px := ox + x + dx
					var py := oy + y + dy
					if px < 0 or py < 0 or px >= size or py >= size:
						continue
					img.set_pixel(px, py, Color(0, 0, 0, 0.85))
	for y in 7:
		for x in 7:
			if HEART[y][x] != "1":
				continue
			if half and x > 3:
				continue
			img.set_pixel(ox + x, oy + y, fill)
	# a small specular highlight
	if not half:
		img.set_pixel(ox + 1, oy + 1, Color(1, 1, 1, 0.55))
	else:
		img.set_pixel(ox + 1, oy + 1, Color(1, 1, 1, 0.55))
	return img


const BUBBLE := [
	"00100",
	"01110",
	"11111",
	"01110",
	"00100",
]


func _bubble(fill: Color) -> Image:
	var size := 9
	var img := _img(size, size)
	img.fill(Color(0, 0, 0, 0))
	for y in 5:
		for x in 5:
			if BUBBLE[y][x] != "1":
				continue
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var px := 2 + x + dx
					var py := 2 + y + dy
					if px >= 0 and py >= 0 and px < size and py < size:
						img.set_pixel(px, py, Color(0, 0, 0, 0.85))
	for y in 5:
		for x in 5:
			if BUBBLE[y][x] == "1":
				img.set_pixel(2 + x, 2 + y, fill)
	return img


# ---------------------------------------------------------------- hunger
const FOOD := [
	"0011000",
	"0111110",
	"1111111",
	"0111111",
	"0011110",
	"0000110",
	"0000010",
]


func _food(fill: Color, half: bool = false) -> Image:
	var size := 9
	var img := _img(size, size)
	img.fill(Color(0, 0, 0, 0))
	var ox := 1
	var oy := 1
	for y in 7:
		for x in 7:
			if FOOD[y][x] != "1":
				continue
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var px := ox + x + dx
					var py := oy + y + dy
					if px >= 0 and py >= 0 and px < size and py < size:
						img.set_pixel(px, py, Color(0, 0, 0, 0.85))
	for y in 7:
		for x in 7:
			if FOOD[y][x] != "1":
				continue
			# the hunger bar is mirrored (the first drumstick is rightmost), so a half
			# one fills from the RIGHT — the opposite side from a half heart
			if half and x < 3:
				continue
			img.set_pixel(ox + x, oy + y, fill)
	# the glint goes on the filled side too
	img.set_pixel(ox + (5 if half else 2), oy + 2, Color(1, 0.94, 0.76, 0.55))
	return img


# ---------------------------------------------------------------- crack overlay
## Five progressive crack overlays drawn over the block being mined. The walks are
## generated from the same seeded RNG each time, so stage k is always a superset of
## stage k-1 and the damage visibly deepens as you dig.
func crack_overlay(stage: int) -> Image:
	var size := 16
	var img := _img(size, size)
	img.fill(Color(0, 0, 0, 0))
	var r := _rng(9091)
	var rays := stage + 1
	for w in rays:
		# Straight rays out from the middle with only a little jitter, spread evenly
		# around the face: random angles clump together and read as one long scratch
		# instead of a block cracking from its centre.
		var dir := (float(w) / float(rays)) * TAU + r.randf_range(-0.35, 0.35)
		var x := size / 2
		var y := size / 2
		var reach := r.randi_range(5, 8)
		for s in reach:
			if x < 0 or y < 0 or x >= size or y >= size:
				break
			img.set_pixel(x, y, Color(0, 0, 0, 0.85))
			dir += r.randf_range(-0.20, 0.20)
			x += int(round(cos(dir)))
			y += int(round(sin(dir)))
	# the point every ray springs from, so the middle is the darkest spot
	img.set_pixel(size / 2, size / 2, Color(0, 0, 0, 0.95))
	return img


# ---------------------------------------------------------------- crosshair
func _crosshair() -> Image:
	var size := 15
	var img := _img(size, size)
	img.fill(Color(0, 0, 0, 0))
	var c := size / 2
	for i in size:
		for w in range(-1, 2):
			img.set_pixel(i, c + w, Color(0, 0, 0, 0.55))
			img.set_pixel(c + w, i, Color(0, 0, 0, 0.55))
	for i in range(2, size - 2):
		img.set_pixel(i, c, Color(1, 1, 1, 0.85))
		img.set_pixel(c, i, Color(1, 1, 1, 0.85))
	return img


# ---------------------------------------------------------------- backgrounds
func dirt_background() -> Image:
	var r := _rng(77)
	var img := _img(16, 16)
	var base := Color(0.25, 0.17, 0.11)
	for y in 16:
		for x in 16:
			var f := 1.0 + r.randf_range(-0.30, 0.30)
			img.set_pixel(x, y, Color(base.r * f, base.g * f, base.b * f))
	for i in 24:
		img.set_pixel(r.randi_range(0, 15), r.randi_range(0, 15), Color(0.15, 0.10, 0.07))
	return img


func _vignette() -> Image:
	var s := 64
	var img := _img(s, s)
	for y in s:
		for x in s:
			var uv := Vector2(float(x) / (s - 1.0), float(y) / (s - 1.0)) * 2.0 - Vector2.ONE
			var d := clampf(uv.length() / 1.42, 0.0, 1.0)
			var a := pow(d, 3.0) * 0.55
			img.set_pixel(x, y, Color(0, 0, 0, a))
	return img


# ---------------------------------------------------------------- logo
func make_logo(text: String, scale: int) -> ImageTexture:
	var gw := PFont.GW
	var gh := PFont.GH
	var adv := gw + 1
	var tw := (text.length() * adv - 1) * scale
	var th := gh * scale
	var pad := scale
	var img := _img(tw + pad * 2, th + pad * 2)
	img.fill(Color(0, 0, 0, 0))
	var r := _rng(4242)
	var on := {}
	for i in text.length():
		var ch := text[i]
		var rows := PFont.rows_for(ch)
		var ox := pad + i * adv * scale
		for y in gh:
			for x in gw:
				if y >= rows.size() or x >= rows[y].length():
					continue
				if rows[y][x] != "1":
					continue
				for py in scale:
					for px in scale:
						on[Vector2i(ox + x * scale + px, pad + y * scale + py)] = true
	# drop shadow first
	var shadow := img.duplicate() as Image
	for p in on.keys():
		for k in 2:
			var sx: int = p.x + (k + 1) * scale
			var sy: int = p.y + (k + 1) * scale
			if sx < img.get_width() and sy < img.get_height():
				img.set_pixel(sx, sy, Color(0.10, 0.10, 0.12, 0.85))
	_on_paint(img, on, scale, r)
	shadow = null
	return _tex(img)


func _on_paint(img: Image, on: Dictionary, scale: int, r: RandomNumberGenerator) -> void:
	for p in on.keys():
		var x: int = p.x
		var y: int = p.y
		var above: bool = on.has(Vector2i(x, y - 1))
		var below: bool = on.has(Vector2i(x, y + 1))
		var col := Color(0.62, 0.62, 0.64)
		if not above:
			col = Color(0.88, 0.88, 0.90)
		elif not below:
			col = Color(0.42, 0.42, 0.45)
		var f := 1.0 + r.randf_range(-0.06, 0.06)
		img.set_pixel(x, y, Color(col.r * f, col.g * f, col.b * f, 1.0))


# ---------------------------------------------------------------- build
func _build_all() -> void:
	tex_button = _tex(_bevel_box(Color(0.42, 0.42, 0.42), Color(0.62, 0.62, 0.62), Color(0.28, 0.28, 0.28)))
	tex_button_hover = _tex(_bevel_box(Color(0.55, 0.57, 0.62), Color(0.78, 0.80, 0.86), Color(0.33, 0.34, 0.38)))
	tex_button_press = _tex(_bevel_box(Color(0.36, 0.36, 0.36), Color(0.26, 0.26, 0.26), Color(0.55, 0.55, 0.55)))
	tex_button_disabled = _tex(_bevel_box(Color(0.27, 0.27, 0.27), Color(0.34, 0.34, 0.34), Color(0.20, 0.20, 0.20)))
	tex_panel = _tex(_panel_box(24, 24))
	tex_slot = _tex(_slot_box(18, false))
	tex_slot_sel = _tex(_slot_box(18, true))
	tex_slot_armor = _tex(_slot_box(18, false))
	tex_heart_full = _tex(_heart(Color(0.83, 0.15, 0.13)))
	tex_heart_half = _tex(_heart(Color(0.83, 0.15, 0.13), true))
	tex_heart_empty = _tex(_heart(Color(0.28, 0.28, 0.28)))
	tex_bubble_full = _tex(_bubble(Color(0.25, 0.55, 0.95, 0.85)))
	tex_bubble_empty = _tex(_bubble(Color(0.25, 0.25, 0.30, 0.75)))
	tex_food_full = _tex(_food(Color(0.74, 0.42, 0.24)))
	tex_food_half = _tex(_food(Color(0.74, 0.42, 0.24), true))
	tex_food_empty = _tex(_food(Color(0.28, 0.28, 0.28)))
	tex_crack.clear()
	for i in 5:
		tex_crack.append(_tex(crack_overlay(i)))
	tex_crosshair = _tex(_crosshair())
	tex_dirt_bg = _tex(dirt_background())
	tex_vignette = _tex(_vignette())
	theme = _build_theme()


func _sb_texture(t: ImageTexture, margin: int, content: int = 0) -> StyleBoxTexture:
	var s := StyleBoxTexture.new()
	s.texture = t
	s.texture_margin_left = margin
	s.texture_margin_right = margin
	s.texture_margin_top = margin
	s.texture_margin_bottom = margin
	s.content_margin_left = content
	s.content_margin_right = content
	s.content_margin_top = content
	s.content_margin_bottom = content
	return s


func _sb_flat(c: Color, border: int, bc: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_border_width_all(border)
	s.border_color = bc
	s.corner_detail = 1
	return s


func _build_theme() -> Theme:
	var t := Theme.new()
	if PFont.ok:
		t.default_font = PFont.font
	t.default_font_size = PFont.M

	var font_color := Color(0.16, 0.16, 0.16)
	var font_shadow := Color(0, 0, 0, 0.0)

	t.set_stylebox("normal", "Button", _sb_texture(tex_button, 3, 10))
	t.set_stylebox("hover", "Button", _sb_texture(tex_button_hover, 3, 10))
	t.set_stylebox("pressed", "Button", _sb_texture(tex_button_press, 3, 10))
	t.set_stylebox("disabled", "Button", _sb_texture(tex_button_disabled, 3, 10))
	t.set_stylebox("focus", "Button", _sb_flat(Color(0, 0, 0, 0), 0, Color(0, 0, 0, 0)))
	t.set_color("font_color", "Button", Color(0.95, 0.95, 0.95))
	t.set_color("font_hover_color", "Button", Color(1.0, 1.0, 0.55))
	t.set_color("font_pressed_color", "Button", Color(0.85, 0.85, 0.85))
	t.set_color("font_disabled_color", "Button", Color(0.45, 0.45, 0.45))

	var panel_sb := _sb_texture(tex_panel, 5, 8)
	t.set_stylebox("panel", "Panel", panel_sb)
	t.set_stylebox("panel", "PanelContainer", panel_sb)
	t.set_stylebox("panel", "ScrollContainer", _sb_flat(Color(0, 0, 0, 0), 0, Color(0, 0, 0, 0)))

	t.set_color("font_color", "Label", Color(1, 1, 1))
	t.set_color("font_shadow_color", "Label", font_shadow)
	t.set_constant("shadow_offset_x", "Label", 2)
	t.set_constant("shadow_offset_y", "Label", 2)

	t.set_stylebox("normal", "LineEdit", _sb_texture(tex_slot, 2, 6))
	t.set_stylebox("focus", "LineEdit", _sb_texture(tex_slot_sel, 2, 6))
	t.set_color("font_color", "LineEdit", Color(1, 1, 1))
	t.set_color("caret_color", "LineEdit", Color(1, 1, 1))
	t.set_color("selection_color", "LineEdit", Color(0.4, 0.5, 0.9, 0.6))

	t.set_stylebox("slider", "HSlider", _sb_flat(Color(0.25, 0.25, 0.25), 0, Color(0, 0, 0, 0)))
	t.set_stylebox("grabber_area", "HSlider", _sb_flat(Color(0.55, 0.75, 0.95), 0, Color(0, 0, 0, 0)))
	t.set_stylebox("grabber_area_highlight", "HSlider", _sb_flat(Color(0.70, 0.85, 1.0), 0, Color(0, 0, 0, 0)))

	t.set_stylebox("scroll", "VScrollBar", _sb_flat(Color(0.18, 0.18, 0.18), 0, Color(0, 0, 0, 0)))
	t.set_stylebox("grabber", "VScrollBar", _sb_flat(Color(0.45, 0.45, 0.45), 0, Color(0, 0, 0, 0)))
	t.set_stylebox("grabber_highlight", "VScrollBar", _sb_flat(Color(0.60, 0.60, 0.60), 0, Color(0, 0, 0, 0)))

	t.set_color("font_color", "CheckButton", Color(1, 1, 1))
	t.set_color("font_color", "OptionButton", Color(1, 1, 1))
	t.set_stylebox("normal", "OptionButton", _sb_texture(tex_button, 3, 8))
	t.set_stylebox("hover", "OptionButton", _sb_texture(tex_button_hover, 3, 8))
	t.set_stylebox("pressed", "OptionButton", _sb_texture(tex_button_press, 3, 8))
	t.set_stylebox("focus", "OptionButton", _sb_flat(Color(0, 0, 0, 0), 0, Color(0, 0, 0, 0)))

	t.set_stylebox("panel", "PopupMenu", _sb_flat(Color(0.12, 0.12, 0.12, 0.96), 2, Color(0.55, 0.55, 0.55)))
	t.set_color("font_color", "PopupMenu", Color(1, 1, 1))
	t.set_color("font_hover_color", "PopupMenu", Color(1, 1, 0.6))

	t.set_stylebox("panel", "TooltipPanel", _sb_flat(Color(0.08, 0.02, 0.10, 0.94), 1, Color(0.55, 0.35, 0.75)))
	t.set_color("font_color", "TooltipLabel", Color(1, 1, 1))

	t.set_stylebox("normal", "ProgressBar", _sb_flat(Color(0.15, 0.15, 0.15), 1, Color(0.05, 0.05, 0.05)))
	t.set_stylebox("fill", "ProgressBar", _sb_flat(Color(0.35, 0.75, 0.30), 0, Color(0, 0, 0, 0)))
	t.set_color("font_color", "ProgressBar", Color(1, 1, 1))

	t.set_constant("outline_size", "Label", 0)
	t.set_constant("line_spacing", "Label", 2)
	return t


## Builds a background that tiles the dirt texture behind a screen.
func make_dirt_bg() -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex_dirt_bg
	tr.stretch_mode = TextureRect.STRETCH_TILE
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.modulate = Color(0.62, 0.62, 0.68)
	return tr


func make_vignette() -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex_vignette
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr