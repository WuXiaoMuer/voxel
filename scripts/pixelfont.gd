extends Node
## A 5x7 pixel font built at runtime into a real FontFile.
## Lower-case letters are drawn as small-caps so the blocky look stays consistent.

const S := 16   # 14 px tall
const M := 24   # 21 px tall
const L := 32   # 28 px tall
const XL := 48  # 42 px tall

const GW := 5
const GH := 7
const COLS := 12

const GLYPHS := {
	"A": "01110/10001/10001/11111/10001/10001/10001",
	"B": "11110/10001/10001/11110/10001/10001/11110",
	"C": "01110/10001/10000/10000/10000/10001/01110",
	"D": "11100/10010/10001/10001/10001/10010/11100",
	"E": "11111/10000/10000/11110/10000/10000/11111",
	"F": "11111/10000/10000/11110/10000/10000/10000",
	"G": "01110/10001/10000/10111/10001/10001/01111",
	"H": "10001/10001/10001/11111/10001/10001/10001",
	"I": "01110/00100/00100/00100/00100/00100/01110",
	"J": "00111/00010/00010/00010/00010/10010/01100",
	"K": "10001/10010/10100/11000/10100/10010/10001",
	"L": "10000/10000/10000/10000/10000/10000/11111",
	"M": "10001/11011/10101/10101/10001/10001/10001",
	"N": "10001/11001/10101/10011/10001/10001/10001",
	"O": "01110/10001/10001/10001/10001/10001/01110",
	"P": "11110/10001/10001/11110/10000/10000/10000",
	"Q": "01110/10001/10001/10001/10101/10010/01101",
	"R": "11110/10001/10001/11110/10100/10010/10001",
	"S": "01111/10000/10000/01110/00001/00001/11110",
	"T": "11111/00100/00100/00100/00100/00100/00100",
	"U": "10001/10001/10001/10001/10001/10001/01110",
	"V": "10001/10001/10001/10001/10001/01010/00100",
	"W": "10001/10001/10001/10101/10101/11011/10001",
	"X": "10001/10001/01010/00100/01010/10001/10001",
	"Y": "10001/10001/01010/00100/00100/00100/00100",
	"Z": "11111/00001/00010/00100/01000/10000/11111",
	"0": "01110/10001/10011/10101/11001/10001/01110",
	"1": "00100/01100/00100/00100/00100/00100/01110",
	"2": "01110/10001/00001/00110/01000/10000/11111",
	"3": "11110/00001/00001/01110/00001/00001/11110",
	"4": "00010/00110/01010/10010/11111/00010/00010",
	"5": "11111/10000/11110/00001/00001/10001/01110",
	"6": "00110/01000/10000/11110/10001/10001/01110",
	"7": "11111/00001/00010/00100/01000/01000/01000",
	"8": "01110/10001/10001/01110/10001/10001/01110",
	"9": "01110/10001/10001/01111/00001/00010/01100",
	" ": "00000/00000/00000/00000/00000/00000/00000",
	".": "00000/00000/00000/00000/00000/00000/00100",
	",": "00000/00000/00000/00000/00000/00100/01000",
	":": "00000/00100/00100/00000/00100/00100/00000",
	";": "00000/00100/00100/00000/00100/01000/00000",
	"!": "00100/00100/00100/00100/00100/00000/00100",
	"?": "01110/10001/00001/00110/00100/00000/00100",
	"'": "00100/00100/00000/00000/00000/00000/00000",
	"\"": "01010/01010/00000/00000/00000/00000/00000",
	"-": "00000/00000/00000/11111/00000/00000/00000",
	"_": "00000/00000/00000/00000/00000/00000/11111",
	"+": "00000/00100/00100/11111/00100/00100/00000",
	"=": "00000/00000/11111/00000/11111/00000/00000",
	"/": "00001/00010/00010/00100/01000/01000/10000",
	"\\": "10000/01000/01000/00100/00010/00010/00001",
	"(": "00010/00100/01000/01000/01000/00100/00010",
	")": "01000/00100/00010/00010/00010/00100/01000",
	"[": "01110/01000/01000/01000/01000/01000/01110",
	"]": "01110/00010/00010/00010/00010/00010/01110",
	"<": "00010/00100/01000/10000/01000/00100/00010",
	">": "01000/00100/00010/00001/00010/00100/01000",
	"*": "00000/10101/01110/11111/01110/10101/00000",
	"%": "10001/00010/00100/00100/01000/10001/00000",
	"#": "01010/01010/11111/01010/11111/01010/01010",
	"@": "01110/10001/10111/10101/10111/10000/01110",
	"|": "00100/00100/00100/00100/00100/00100/00100",
	"&": "01100/10010/10100/01000/10101/10010/01101",
	"$": "00100/01111/10100/01110/00101/11110/00100",
	"^": "00100/01010/10001/00000/00000/00000/00000",
	"~": "00000/00000/01001/10110/00000/00000/00000",
}

const SCALES := {8: 1, 16: 2, 24: 3, 32: 4, 48: 6}

var font: FontFile
var ok := false

var _order: Array = []


func _ready() -> void:
	_build_order()
	_build()


func _build_order() -> void:
	for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
		_order.append([c, false])
	for c in "abcdefghijklmnopqrstuvwxyz":
		_order.append([c, true])
	for c in "0123456789":
		_order.append([c, false])
	var punct := [" ", ".", ",", ":", ";", "!", "?", "'", "\"", "-", "_", "+", "=",
		"/", "\\", "(", ")", "[", "]", "<", ">", "*", "%", "#", "@", "|", "&", "$", "^", "~"]
	for c in punct:
		_order.append([c, false])


func rows_for(ch: String) -> PackedStringArray:
	var key := ch.to_upper()
	if GLYPHS.has(key):
		return GLYPHS[key].split("/")
	return GLYPHS["?"].split("/")


func has_glyph(ch: String) -> bool:
	return GLYPHS.has(ch.to_upper())


func _build() -> void:
	var f := FontFile.new()
	if not f.has_method("set_texture_image") or not f.has_method("set_glyph_uv_rect"):
		push_warning("Runtime bitmap FontFile API unavailable, using fallback font.")
		ok = false
		return

	var tex_index := 0
	for size_key in SCALES.keys():
		var s: int = SCALES[size_key]
		var cell_w := (GW + 1) * s
		var cell_h := (GH + 1) * s
		var n := _order.size()
		var rows := int(ceil(float(n) / float(COLS)))
		var img := Image.create(COLS * cell_w, rows * cell_h, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))

		var key := Vector2i(size_key, 0)
		for i in n:
			var entry: Array = _order[i]
			var ch: String = entry[0]
			var lower: bool = entry[1]
			var col := i % COLS
			var row := i / COLS
			var ox := col * cell_w
			var oy := row * cell_h
			var gr := rows_for(ch)
			var is_space: bool = ch == " "
			var gw := GW
			var gh := GH
			var dy := 0
			if lower:
				gw = 4
				gh = 5
				dy = 2   # small-caps row, aligned to the same baseline
			for y in gh:
				for x in gw:
					var sx := int(float(x) * float(GW) / float(gw))
					var sy := int(float(y) * float(GH) / float(gh))
					if is_space or sx >= GW or sy >= GH:
						continue
					if gr[sy][sx] != "1":
						continue
					for py in s:
						for px in s:
							img.set_pixel(ox + x * s + px, oy + (dy + y) * s + py, Color(1, 1, 1, 1))

			var adv := float(gw + 1) * s
			if is_space:
				adv = float(4 * s)
			var g := ch.unicode_at(0)
			f.set_glyph_texture_idx(0, key, g, tex_index)
			f.set_glyph_uv_rect(0, key, g,
				Rect2(ox, oy + dy * s, gw * s, gh * s))
			f.set_glyph_size(0, key, g, Vector2(gw * s, gh * s))
			f.set_glyph_offset(0, key, g, Vector2(0, dy * s))
			f.set_glyph_advance(0, size_key, g, Vector2(adv, 0.0))

		f.set_texture_image(0, key, tex_index, img)
		f.set_cache_ascent(0, size_key, float(GH * s))
		f.set_cache_descent(0, size_key, 0.0)
		tex_index += 1

	font = f
	_install_fallback(f)
	ok = true


## A system font used only for characters the 5x7 pixel set does not cover --
## Chinese, most obviously. Godot asks the fallback for any codepoint the primary
## font has no glyph for, so English keeps the crisp pixel look while CJK picks up
## a real outline font instead of rendering a row of "?".
func _install_fallback(f: FontFile) -> void:
	var fb := SystemFont.new()
	fb.font_names = PackedStringArray([
		"Microsoft YaHei", "微软雅黑", "Noto Sans CJK SC", "Source Han Sans SC",
		"PingFang SC", "WenQuanYi Micro Hei", "sans-serif",
	])
	fb.allow_system_fallback = true
	fb.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	var arr: Array[Font] = [fb]
	f.fallbacks = arr


func build_theme(extra: Theme = null) -> Theme:
	var t := extra if extra != null else Theme.new()
	if ok:
		t.default_font = font
	t.default_font_size = M
	return t