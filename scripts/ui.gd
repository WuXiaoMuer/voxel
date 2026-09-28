extends CanvasLayer
## All out-of-game screens: title, world creation, world list, settings, pause,
## death and the loading overlay.

signal new_world_requested(world_name: String, seed_value: int, creative: bool, distance: int, cheats: bool)
signal load_world_requested(dir_name: String)
signal delete_world_requested(dir_name: String)
signal resume_requested()
signal quit_to_title_requested()
signal save_requested()
signal respawn_requested()
signal settings_applied()

const SKINS_SCRIPT := preload("res://scripts/player_model.gd")

const SAVE_ROOT := "user://saves"

## World-list metrics. The panel is sized from these rather than from a fixed height,
## so a single save gets a single row's worth of panel and no empty box.
const WORLD_ROW_H := 46.0          # matches the height _button() builds
const WORLD_ROW_SEP := 8
const WORLD_SEP := 12
const WORLD_PAD := 18.0
const WORLD_MAX_LIST_H := 560.0    # ten rows; beyond that it scrolls

var screens: Dictionary = {}
var current := ""

var _seed_field: LineEdit
var _name_field: LineEdit
var _mode_buttons: Array = []
var _mode_creative := true
var _cheats_btn: Button
var _fog_btn: Button
var _fog_scale_label: Label
var _rd_slider: HSlider
var _rd_value: Label
var _world_list: VBoxContainer
var _world_panel: Panel
var _world_scroll: ScrollContainer
var _world_vbox: VBoxContainer
var _loading_bar: ProgressBar
var _loading_label: Label
var _quality_btn: Button
var _fs_btn: Button
var _vsync_btn: Button
var _bob_btn: Button
var _fps_btn: Button
var _skin_btn: Button
var _skin_file_btn: Button
var _skin_dialog: FileDialog
var _skin_error: Label
var _settings_return := "title"
var _root: Control
var _lang_btn: Button
var _pack_btn: Button


func _ready() -> void:
	layer = 20
	_rebuild()
	# every screen is generated from English source strings, so switching language
	# just throws the tree away and builds it again -- no per-control bookkeeping
	I18n.changed.connect(_rebuild)


## (Re)builds every screen from scratch. Also the language switch path, which is
## why all the cached control references are reset here.
func _rebuild() -> void:
	if _root != null and is_instance_valid(_root):
		remove_child(_root)
		_root.queue_free()
	screens = {}
	_mode_buttons = []
	_world_list = null
	_world_panel = null
	_world_scroll = null
	_world_vbox = null
	_root = Control.new()
	_root.name = "MenuRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_root.theme = Art.theme
	add_child(_root)

	screens["title"] = _build_title()
	screens["create"] = _build_create()
	screens["worlds"] = _build_worlds()
	screens["settings"] = _build_settings()
	screens["pause"] = _build_pause()
	screens["death"] = _build_death()
	screens["loading"] = _build_loading()
	for k in screens:
		var c: Control = screens[k]
		c.set_anchors_preset(Control.PRESET_FULL_RECT)
		c.visible = false
		_root.add_child(c)
	open_screen(current if current != "" else "title")


func open_screen(screen_name: String) -> void:
	for k in screens:
		(screens[k] as Control).visible = k == screen_name
	current = screen_name
	if screen_name == "worlds":
		_refresh_world_list()


func close_all() -> void:
	for k in screens:
		(screens[k] as Control).visible = false
	current = ""


# ================================================================ helpers
func _bg(alpha: float = 0.62) -> Control:
	var holder := Control.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dirt := Art.make_dirt_bg()
	dirt.modulate = Color(alpha, alpha, alpha * 1.05)
	holder.add_child(dirt)
	var vig := Art.make_vignette()
	vig.modulate = Color(1, 1, 1, 0.9)
	holder.add_child(vig)
	return holder


func _dark(alpha: float) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(0, 0, 0, alpha)
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _column(x: float, y: float, w: float, sep: int = 10) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.position = Vector2(x, y)
	v.custom_minimum_size = Vector2(w, 0)
	v.add_theme_constant_override("separation", sep)
	return v


func _button(text: String, w: float = 320.0) -> Button:
	var b := Button.new()
	b.text = I18n.t(text)
	b.custom_minimum_size = Vector2(w, 46)
	b.add_theme_font_size_override("font_size", PFont.M)
	b.pressed.connect(_on_ui_click)
	return b


func _on_ui_click() -> void:
	Sfx.play("click", -8.0)


func _title_label(text: String, size: int = PFont.L) -> Label:
	var l := Label.new()
	l.text = I18n.t(text)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	return l


func _row_label(text: String, w: float = 200.0) -> Label:
	var l := Label.new()
	l.text = I18n.t(text)
	l.custom_minimum_size = Vector2(w, 30)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _slider(minv: float, maxv: float, step: float, value: float, w: float = 240.0) -> HSlider:
	var s := HSlider.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(w, 30)
	return s


# ================================================================ title
func _build_title() -> Control:
	var c := Control.new()
	c.add_child(_bg(1.0))
	c.add_child(_dark(0.30))

	var logo := TextureRect.new()
	logo.texture = Art.make_logo("VOXELCRAFT", 6)
	logo.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	logo.size = Vector2(1280, 120)
	logo.position = Vector2(0, 66)
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(logo)

	var sub := _title_label("a voxel sandbox   -   dig, build, explore", PFont.S)
	sub.position = Vector2(0, 178)
	sub.size = Vector2(1280, 30)
	c.add_child(sub)

	var col := _column(480, 236, 320, 12)
	c.add_child(col)

	var b_new := _button("CREATE NEW WORLD")
	b_new.pressed.connect(_on_new_pressed)
	col.add_child(b_new)

	var b_load := _button("LOAD WORLD")
	b_load.pressed.connect(_on_load_pressed)
	col.add_child(b_load)

	var b_set := _button("SETTINGS")
	b_set.pressed.connect(_on_title_settings)
	col.add_child(b_set)

	var b_quit := _button("QUIT GAME")
	b_quit.pressed.connect(_on_quit_pressed)
	col.add_child(b_quit)

	var footer := _title_label(
		"WASD move   SPACE jump   MOUSE look   LMB dig   RMB place   E inventory   T chat   / command   F3 debug",
		PFont.S)
	footer.position = Vector2(0, 662)
	footer.size = Vector2(1280, 30)
	c.add_child(footer)
	return c


func _on_new_pressed() -> void:
	open_screen("create")


func _on_load_pressed() -> void:
	open_screen("worlds")


func _on_title_settings() -> void:
	_settings_return = "title"
	open_screen("settings")


func _on_quit_pressed() -> void:
	get_tree().quit()


# ================================================================ create world
func _build_create() -> Control:
	var c := Control.new()
	c.add_child(_bg(1.0))
	c.add_child(_dark(0.45))

	var panel := Panel.new()
	panel.position = Vector2(400, 30)
	panel.size = Vector2(480, 660)
	panel.add_theme_stylebox_override("panel", Art._sb_texture(Art.tex_panel, 6, 16))
	c.add_child(panel)

	# the page grew past a fixed panel (game mode, cheats, render distance, hint), so
	# it scrolls like the settings page instead of drawing over the screen edge
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(24, 18)
	scroll.custom_minimum_size = Vector2(432, 620)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(432, 0)
	v.add_theme_constant_override("separation", 10)
	scroll.add_child(v)

	v.add_child(_title_label("CREATE NEW WORLD"))

	v.add_child(_plain_label("World name"))
	_name_field = LineEdit.new()
	_name_field.text = "New World"
	_name_field.custom_minimum_size = Vector2(0, 42)
	v.add_child(_name_field)

	v.add_child(_plain_label("Seed (empty = random)"))
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	v.add_child(srow)
	_seed_field = LineEdit.new()
	_seed_field.custom_minimum_size = Vector2(320, 42)
	_seed_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	srow.add_child(_seed_field)
	var rnd := _button("Random", 104)
	rnd.pressed.connect(_on_random_seed)
	srow.add_child(rnd)

	v.add_child(_plain_label("Game mode"))
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 8)
	v.add_child(mrow)
	for mindex in 2:
		var creative := mindex == 0
		var b := _button("Creative" if creative else "Survival", 212)
		b.toggle_mode = true
		b.button_pressed = creative
		b.pressed.connect(_on_mode_pressed.bind(creative))
		mrow.add_child(b)
		_mode_buttons.append([b, creative])

	_cheats_btn = _toggle("Allow cheats (commands)", true, 432)
	_cheats_btn.pressed.connect(_on_cheats_pressed)
	v.add_child(_cheats_btn)

	v.add_child(_plain_label("Render distance"))
	_rd_slider = _slider(Settings.MIN_RD, Settings.max_render_distance(), 1,
		Settings.render_distance, 432)
	v.add_child(_rd_slider)
	_rd_value = Label.new()
	_rd_value.add_theme_font_size_override("font_size", PFont.S)
	_rd_value.text = I18n.tf("%d chunks", [Settings.render_distance])
	v.add_child(_rd_value)
	_rd_slider.value_changed.connect(_on_rd_changed)

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 8)
	v.add_child(brow)
	var create := _button("CREATE", 212)
	create.pressed.connect(_on_create_pressed)
	brow.add_child(create)
	var back := _button("BACK", 212)
	back.pressed.connect(_on_create_back)
	brow.add_child(back)

	var hint := Label.new()
	hint.text = I18n.t("Survival: health, fall damage, drowning, drops.\nCreative: double-tap SPACE to fly, instant mining,\nendless blocks in the inventory.")
	hint.add_theme_font_size_override("font_size", PFont.S)
	# Without wrapping, this label's longest line becomes the column's minimum width,
	# which stretches every row above it and pushes the seed row's Random button out
	# past the panel. Wrapping it keeps the column at its declared 432.
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(432, 0)
	v.add_child(hint)
	return c


func _plain_label(text: String) -> Label:
	var l := Label.new()
	l.text = I18n.t(text)
	return l


func _on_random_seed() -> void:
	_seed_field.text = str(randi() % 1000000)


func _on_mode_pressed(creative: bool) -> void:
	_mode_creative = creative
	for entry in _mode_buttons:
		(entry[0] as Button).button_pressed = entry[1] == creative


func _on_cheats_pressed() -> void:
	_cheats_btn.text = "%s: %s" % [I18n.t("Allow cheats (commands)"),
		I18n.t("ON" if _cheats_btn.button_pressed else "OFF")]


func _on_rd_changed(v: float) -> void:
	_rd_value.text = I18n.tf("%d chunks", [int(v)])


func _on_create_back() -> void:
	open_screen("title")


func _on_create_pressed() -> void:
	var nm := _name_field.text.strip_edges()
	if nm == "":
		nm = "New World"
	var s := _seed_field.text.strip_edges()
	var seed_value := 0
	if s == "":
		seed_value = randi() % 1000000
	elif s.is_valid_int():
		seed_value = int(s)
	else:
		seed_value = absi(s.hash()) % 1000000
	new_world_requested.emit(nm, seed_value, _mode_creative, int(_rd_slider.value),
		_cheats_btn.button_pressed)


# ================================================================ world list
func _build_worlds() -> Control:
	var c := Control.new()
	c.add_child(_bg(1.0))
	c.add_child(_dark(0.45))

	_world_panel = Panel.new()
	_world_panel.position = Vector2(340, 70)
	_world_panel.size = Vector2(600, 300)
	_world_panel.add_theme_stylebox_override("panel", Art._sb_texture(Art.tex_panel, 6, 16))
	c.add_child(_world_panel)

	_world_vbox = VBoxContainer.new()
	_world_vbox.position = Vector2(24, 18)
	_world_vbox.custom_minimum_size = Vector2(552, 0)
	_world_vbox.add_theme_constant_override("separation", WORLD_SEP)
	_world_panel.add_child(_world_vbox)
	_world_vbox.add_child(_title_label("SELECT A WORLD"))

	# The scroll area is sized to the list in _fit_world_panel: a fixed height left a
	# large empty box behind a single save and cut the list off at five. The scrollbar
	# only appears once the list is too tall for the screen.
	_world_scroll = ScrollContainer.new()
	_world_scroll.custom_minimum_size = Vector2(552, WORLD_ROW_H)
	_world_scroll.size = Vector2(552, WORLD_ROW_H)
	_world_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_world_vbox.add_child(_world_scroll)
	_world_list = VBoxContainer.new()
	_world_list.custom_minimum_size = Vector2(540, 0)
	_world_list.add_theme_constant_override("separation", WORLD_ROW_SEP)
	_world_scroll.add_child(_world_list)

	var back := _button("BACK", 552)
	back.pressed.connect(_on_create_back)
	_world_vbox.add_child(back)
	return c


## Sizes the panel to the list it actually holds, then centres it. Called after every
## refresh, so deleting a world shrinks the panel back down.
func _fit_world_panel() -> void:
	if _world_panel == null or _world_scroll == null or _world_vbox == null:
		return
	var content: float = _world_list.get_combined_minimum_size().y
	var list_h := clampf(content, WORLD_ROW_H, WORLD_MAX_LIST_H)
	_world_scroll.custom_minimum_size = Vector2(552, list_h)
	_world_scroll.size = Vector2(552, list_h)
	var title_h := 32.0
	if PFont.font != null:
		title_h = PFont.font.get_height(PFont.L)
	var panel_h := WORLD_PAD * 2.0 + title_h + WORLD_SEP + list_h + WORLD_SEP + WORLD_ROW_H
	_world_panel.size = Vector2(600, panel_h)
	_world_panel.position = Vector2(340, roundf((720.0 - panel_h) * 0.5))
	# the vbox is positioned absolutely, so it has to move with the panel
	_world_vbox.position = Vector2(24, WORLD_PAD)


func _refresh_world_list() -> void:
	for ch in _world_list.get_children():
		# remove_child as well as queue_free: a queued-free node stays in the tree
		# until the end of the frame, so it would still be counted when the panel is
		# measured below and the list would never shrink.
		_world_list.remove_child(ch)
		ch.queue_free()
	var dirs := _list_saves()
	if dirs.is_empty():
		var l := Label.new()
		l.text = I18n.t("   No saved worlds yet.")
		_world_list.add_child(l)
		_fit_world_panel()
		return
	for info in dirs:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_world_list.add_child(row)
		var play := _button("%s   (%s)" % [info["name"], I18n.t(str(info["mode"]))], 380)
		play.pressed.connect(_on_play_world.bind(str(info["dir"])))
		row.add_child(play)
		var del := _button("Delete", 150)
		del.pressed.connect(_on_delete_world.bind(str(info["dir"])))
		row.add_child(del)
	_fit_world_panel()


func _on_play_world(dir_name: String) -> void:
	load_world_requested.emit(dir_name)


func _on_delete_world(dir_name: String) -> void:
	delete_world_requested.emit(dir_name)


func _list_saves() -> Array:
	var out: Array = []
	var d := DirAccess.open(SAVE_ROOT)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if d.current_is_dir() and not f.begins_with("."):
			var meta_path := "%s/%s/level.json" % [SAVE_ROOT, f]
			var info := {"dir": f, "name": f, "mode": "Creative"}
			if FileAccess.file_exists(meta_path):
				var parsed = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
				if parsed is Dictionary:
					info["name"] = str(parsed.get("name", f))
					info["mode"] = "Creative" if bool(parsed.get("creative", true)) else "Survival"
			out.append(info)
		f = d.get_next()
	d.list_dir_end()
	out.sort_custom(_sort_by_name)
	return out


func _sort_by_name(a: Dictionary, b: Dictionary) -> bool:
	return str(a["name"]) < str(b["name"])


# ================================================================ settings
func _build_settings() -> Control:
	var c := Control.new()
	c.add_child(_bg(1.0))
	c.add_child(_dark(0.45))

	var panel := Panel.new()
	panel.position = Vector2(330, 30)
	panel.size = Vector2(620, 660)
	panel.add_theme_stylebox_override("panel", Art._sb_texture(Art.tex_panel, 6, 16))
	c.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(24, 16)
	scroll.custom_minimum_size = Vector2(572, 620)
	panel.add_child(scroll)

	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(556, 0)
	v.add_theme_constant_override("separation", 10)
	scroll.add_child(v)
	v.add_child(_title_label("SETTINGS"))

	# language sits at the very top: everything below it is written in whatever
	# language is selected, and picking one rebuilds the whole page instantly
	_lang_btn = _button("Language: %s" % I18n.LANG_NAMES[I18n.lang], 556)
	_lang_btn.pressed.connect(_on_lang_pressed)
	v.add_child(_lang_btn)

	v.add_child(_section("VIDEO"))
	v.add_child(_slider_row("Field of view", 50, 110, 1, Settings.fov, _on_fov_changed))
	v.add_child(_slider_row("Render distance", Settings.MIN_RD, Settings.max_render_distance(),
		1, Settings.render_distance, _on_rd_setting_changed))
	v.add_child(_slider_row("Mouse sensitivity", 1, 100, 1, Settings.sensitivity * 20000.0,
		_on_sensitivity_changed))

	_quality_btn = _button("%s: %s" % [I18n.t("Quality"), I18n.t(_quality_name(Settings.quality))], 556)
	_quality_btn.pressed.connect(_on_quality_pressed)
	v.add_child(_quality_btn)

	_pack_btn = _button("%s: %s" % [I18n.t("Render pack"), I18n.t(_pack_name(Settings.render_preset))], 556)
	_pack_btn.pressed.connect(_on_pack_pressed)
	v.add_child(_pack_btn)

	v.add_child(_maxfps_row())

	# fog is the thing that hides the edge of the loaded world, so it is also the
	# control that decides how far a large render distance actually reads
	_fog_btn = _toggle("Distant fog", Settings.fog_enabled)
	_fog_btn.pressed.connect(_on_fog_pressed)
	v.add_child(_fog_btn)
	v.add_child(_fog_scale_row())
	v.add_child(_slider_row("Chunk load budget", 2, 40, 1, Settings.chunk_budget_ms,
		_on_chunk_budget_changed))

	_fs_btn = _toggle("Fullscreen", Settings.fullscreen)
	_fs_btn.pressed.connect(_on_fullscreen_pressed)
	v.add_child(_fs_btn)

	_vsync_btn = _toggle("V-Sync", Settings.vsync)
	_vsync_btn.pressed.connect(_on_vsync_pressed)
	v.add_child(_vsync_btn)

	_bob_btn = _toggle("View bobbing", Settings.view_bob)
	_bob_btn.pressed.connect(_on_bob_pressed)
	v.add_child(_bob_btn)

	v.add_child(_section("PLAYER"))
	_skin_btn = _button(I18n.tf("Skin: %s   (press F5 for third person)", [_skin_name()]), 556)
	_skin_btn.pressed.connect(_on_skin_pressed)
	v.add_child(_skin_btn)

	_skin_file_btn = _button(_skin_file_label(), 556)
	_skin_file_btn.pressed.connect(_on_skin_file_pressed)
	v.add_child(_skin_file_btn)

	# a real file picker so a downloaded Minecraft skin can be dropped straight in
	_skin_dialog = FileDialog.new()
	_skin_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_skin_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_skin_dialog.title = I18n.t("Pick a Minecraft skin (64x64, 64x32 or an HD multiple)")
	_skin_dialog.add_filter("*.png", "PNG images")
	_skin_dialog.size = Vector2i(820, 560)
	_skin_dialog.file_selected.connect(_on_skin_file_selected)
	c.add_child(_skin_dialog)

	_skin_error = Label.new()
	_skin_error.add_theme_font_size_override("font_size", PFont.S)
	_skin_error.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	_skin_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_skin_error.custom_minimum_size = Vector2(556, 40)
	v.add_child(_skin_error)

	_fps_btn = _toggle("Show FPS", Settings.show_fps)
	_fps_btn.pressed.connect(_on_fps_pressed)
	v.add_child(_fps_btn)

	v.add_child(_section("AUDIO"))
	v.add_child(_slider_row("Master volume", 0, 100, 1, Settings.volume * 100.0,
		_on_master_changed))
	v.add_child(_slider_row("Music volume", 0, 100, 1, Settings.music_volume * 100.0,
		_on_music_changed))

	var back := _button("BACK", 556)
	back.pressed.connect(_on_settings_back)
	v.add_child(back)
	return c


func _quality_name(q: int) -> String:
	match q:
		0:
			return "Low"
		1:
			return "Medium"
	return "High"


func _pack_name(p: int) -> String:
	match p:
		1:
			return "Soft"
		2:
			return "Vibrant"
	return "Classic"


## A slider whose read-out says "Unlimited" at zero instead of "0", because a
## bare 0 next to a framerate reads like a bug.
func _maxfps_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_row_label("Max framerate", 200))
	var s := _slider(0, 240, 10, Settings.max_fps, 240)
	row.add_child(s)
	var val := Label.new()
	val.custom_minimum_size = Vector2(80, 30)
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val.text = _fps_text(Settings.max_fps)
	row.add_child(val)
	s.value_changed.connect(func(v: float) -> void:
		val.text = _fps_text(int(v))
		_on_maxfps_changed(v))
	return row


func _fps_text(n: int) -> String:
	return I18n.t("Unlimited") if n <= 0 else "%d" % n


func _on_maxfps_changed(v: float) -> void:
	Settings.max_fps = int(v)
	Settings.save_settings()
	Settings.apply_framerate()


## Fog distance is shown as a multiplier ("x1.00") rather than the raw 30..400 the
## slider stores, because the number that matters is how much further you see.
func _fog_scale_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_row_label("Fog distance", 200))
	var s := _slider(30, 400, 5, Settings.fog_scale * 100.0, 240)
	row.add_child(s)
	_fog_scale_label = Label.new()
	_fog_scale_label.custom_minimum_size = Vector2(80, 30)
	_fog_scale_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_fog_scale_label.text = "x%.2f" % Settings.fog_scale
	row.add_child(_fog_scale_label)
	s.value_changed.connect(_on_fog_scale_changed)
	return row


func _on_fog_scale_changed(v: float) -> void:
	Settings.fog_scale = clampf(v / 100.0, 0.3, 4.0)
	_fog_scale_label.text = "x%.2f" % Settings.fog_scale
	Settings.save_settings()
	settings_applied.emit()


func _on_fog_pressed() -> void:
	Settings.fog_enabled = _fog_btn.button_pressed
	_fog_btn.text = "%s: %s" % [I18n.t("Distant fog"),
		I18n.t("ON" if Settings.fog_enabled else "OFF")]
	Settings.save_settings()
	settings_applied.emit()


func _on_chunk_budget_changed(v: float) -> void:
	Settings.chunk_budget_ms = int(v)
	Settings.save_settings()


func _on_pack_pressed() -> void:
	Settings.render_preset = (Settings.render_preset + 1) % 3
	_pack_btn.text = "%s: %s" % [I18n.t("Render pack"), I18n.t(_pack_name(Settings.render_preset))]
	Settings.save_settings()
	settings_applied.emit()


func _on_lang_pressed() -> void:
	# next_lang() emits `changed`, which rebuilds this whole page -- so there is
	# nothing to update here afterwards, the button is replaced by a fresh one
	Settings.lang = I18n.next_lang()
	Settings.save_settings()


func _section(text: String) -> Label:
	var l := Label.new()
	l.text = I18n.t(text)
	l.add_theme_font_size_override("font_size", PFont.S)
	l.modulate = Color(0.75, 0.85, 1.0)
	return l


## Width defaults to the settings page's row width. The create-world page is a
## narrower panel, so it passes its own -- a 556-wide control there becomes the
## column's minimum width and shoves everything else outside the panel.
func _toggle(text: String, on: bool, w: float = 556.0) -> Button:
	var b := _button("%s: %s" % [I18n.t(text), I18n.t("ON" if on else "OFF")], w)
	b.toggle_mode = true
	b.button_pressed = on
	return b


func _slider_row(label: String, minv: float, maxv: float, step: float, value: float,
		handler: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_row_label(label, 200))
	var s := _slider(minv, maxv, step, value, 240)
	row.add_child(s)
	var val := Label.new()
	val.custom_minimum_size = Vector2(80, 30)
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val.text = str(int(value))
	row.add_child(val)
	s.value_changed.connect(_on_any_slider.bind(val, handler))
	return row


func _on_any_slider(v: float, val: Label, handler: Callable) -> void:
	val.text = str(int(v))
	handler.call(v)


func _on_fov_changed(v: float) -> void:
	Settings.fov = v
	Settings.save_settings()
	settings_applied.emit()


func _on_rd_setting_changed(v: float) -> void:
	Settings.render_distance = int(v)
	Settings.save_settings()
	settings_applied.emit()


func _on_sensitivity_changed(v: float) -> void:
	Settings.sensitivity = v / 20000.0
	Settings.save_settings()


func _on_master_changed(v: float) -> void:
	Settings.volume = v / 100.0
	Settings.save_settings()
	Settings.apply_audio()


func _on_music_changed(v: float) -> void:
	Settings.music_volume = v / 100.0
	Settings.save_settings()
	Settings.apply_audio()


func _on_quality_pressed() -> void:
	Settings.quality = (Settings.quality + 1) % 3
	if Settings.render_distance > Settings.max_render_distance():
		Settings.render_distance = Settings.max_render_distance()
	_quality_btn.text = "%s: %s" % [I18n.t("Quality"), I18n.t(_quality_name(Settings.quality))]
	Settings.save_settings()
	settings_applied.emit()


func _on_fullscreen_pressed() -> void:
	Settings.fullscreen = _fs_btn.button_pressed
	_fs_btn.text = "%s: %s" % [I18n.t("Fullscreen"), I18n.t("ON" if Settings.fullscreen else "OFF")]
	Settings.save_settings()
	Settings.apply_window()


func _on_vsync_pressed() -> void:
	Settings.vsync = _vsync_btn.button_pressed
	_vsync_btn.text = "%s: %s" % [I18n.t("V-Sync"), I18n.t("ON" if Settings.vsync else "OFF")]
	Settings.save_settings()
	Settings.apply_window()


func _on_bob_pressed() -> void:
	Settings.view_bob = _bob_btn.button_pressed
	_bob_btn.text = "%s: %s" % [I18n.t("View bobbing"), I18n.t("ON" if Settings.view_bob else "OFF")]
	Settings.save_settings()


func _on_fps_pressed() -> void:
	Settings.show_fps = _fps_btn.button_pressed
	_fps_btn.text = "%s: %s" % [I18n.t("Show FPS"), I18n.t("ON" if Settings.show_fps else "OFF")]
	Settings.save_settings()


func _skin_name() -> String:
	if Settings.player_skin_path != "":
		return "Custom"          # the file name lives on the button below
	return str(SKINS_SCRIPT.SKINS[wrapi(Settings.player_skin, 0, SKINS_SCRIPT.SKINS.size())]["name"])


func _on_skin_pressed() -> void:
	# cycling the preset also drops any imported skin, so the button always agrees
	# with what you actually look like
	Settings.player_skin_path = ""
	Settings.player_skin = wrapi(Settings.player_skin + 1, 0, SKINS_SCRIPT.SKINS.size())
	_refresh_skin_buttons()
	Settings.save_settings()
	settings_applied.emit()


func _skin_file_label() -> String:
	if Settings.player_skin_path == "":
		return I18n.t("Load skin file...   (64x64 / 64x32 PNG)")
	var nm := Settings.player_skin_path.get_file()
	if nm.length() > 26:
		nm = nm.substr(0, 25) + "."
	return I18n.tf("Skin file: %s", [nm])


func _refresh_skin_buttons() -> void:
	_skin_btn.text = I18n.tf("Skin: %s   (press F5 for third person)", [_skin_name()])
	_skin_file_btn.text = _skin_file_label()


func _on_skin_file_pressed() -> void:
	_skin_error.text = ""
	_skin_dialog.popup_centered()


func _on_skin_file_selected(path: String) -> void:
	# vet the file before committing, so a bad pick leaves the current skin alone
	var img := Image.new()
	if img.load(path) != OK:
		_skin_error.text = I18n.t("Could not read that file as an image.")
		return
	var err: String = SKINS_SCRIPT.skin_error(img)
	if err != "":
		_skin_error.text = I18n.tf("Not a Minecraft skin: %s.", [err])
		return
	_skin_error.text = ""
	Settings.player_skin_path = path
	_refresh_skin_buttons()
	Settings.save_settings()
	settings_applied.emit()


func _on_settings_back() -> void:
	Settings.save_settings()
	settings_applied.emit()
	open_screen(_settings_return)


# ================================================================ pause
func _build_pause() -> Control:
	var c := Control.new()
	c.add_child(_dark(0.55))
	var col := _column(480, 170, 320, 12)
	c.add_child(col)
	col.add_child(_title_label("GAME PAUSED"))
	var b_res := _button("BACK TO GAME")
	b_res.pressed.connect(_on_resume)
	col.add_child(b_res)
	var b_set := _button("SETTINGS")
	b_set.pressed.connect(_on_pause_settings)
	col.add_child(b_set)
	var b_save := _button("SAVE GAME")
	b_save.pressed.connect(_on_save)
	col.add_child(b_save)
	var b_quit := _button("SAVE AND QUIT TO TITLE")
	b_quit.pressed.connect(_on_quit_title)
	col.add_child(b_quit)

	var tip := _title_label("Coordinates, seed and chunk info are on the F3 screen.", PFont.S)
	tip.position = Vector2(0, 630)
	tip.size = Vector2(1280, 30)
	c.add_child(tip)
	return c


func _on_resume() -> void:
	resume_requested.emit()


func _on_pause_settings() -> void:
	_settings_return = "pause"
	open_screen("settings")


func _on_save() -> void:
	save_requested.emit()


func _on_quit_title() -> void:
	quit_to_title_requested.emit()


# ================================================================ death
func _build_death() -> Control:
	var c := Control.new()
	c.add_child(_dark(0.70))
	var col := _column(480, 230, 320, 14)
	c.add_child(col)
	var t := _title_label("YOU DIED!", PFont.XL)
	t.modulate = Color(1.0, 0.35, 0.30)
	col.add_child(t)
	col.add_child(_title_label("Respawn to keep building.", PFont.S))
	var b := _button("RESPAWN")
	b.pressed.connect(_on_respawn)
	col.add_child(b)
	var b2 := _button("QUIT TO TITLE")
	b2.pressed.connect(_on_quit_title)
	col.add_child(b2)
	return c


func _on_respawn() -> void:
	respawn_requested.emit()


# ================================================================ loading
func _build_loading() -> Control:
	var c := Control.new()
	c.add_child(_dark(0.90))
	var col := _column(390, 300, 500, 16)
	c.add_child(col)
	col.add_child(_title_label("GENERATING WORLD"))
	_loading_bar = ProgressBar.new()
	_loading_bar.custom_minimum_size = Vector2(500, 28)
	_loading_bar.max_value = 100.0
	_loading_bar.show_percentage = false
	col.add_child(_loading_bar)
	_loading_label = Label.new()
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.add_theme_font_size_override("font_size", PFont.S)
	col.add_child(_loading_label)
	return c


func set_loading(progress: float, text: String) -> void:
	if _loading_bar != null:
		_loading_bar.value = clampf(progress, 0.0, 100.0)
	if _loading_label != null:
		_loading_label.text = text