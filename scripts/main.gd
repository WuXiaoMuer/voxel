extends Node3D
## Top level controller: mode state machine, world lifecycle, saves and the
## automated screenshot pass used to verify the build.

enum Mode { TITLE, LOADING, PLAY, PAUSE, DEATH }

const SAVE_ROOT := "user://saves"

var world: Node3D
var player
var sky: Node3D
var mobs: Node3D
var item_entities: Node3D
var particles: Node3D
var hud: CanvasLayer
var ui: CanvasLayer
var selection: MeshInstance3D
var crack: MeshInstance3D

var mode := Mode.TITLE
var world_name := ""
var world_dir := ""
var seed_value := 12345

var _inv_open := false
var _chat_open := false
## True while the box was opened as the backtick terminal, where a line without a
## leading "/" is still a command.
var _console_mode := false
## Whether this world allows commands. Creative worlds default to yes; a survival
## world asks on the create screen. Restored from the save on load.
var _cheats := true
var _capture := ""
var _capture_dir := "res://previews"
var _capture_seed := 1337
var _fps_smooth := 60.0
var _needs_spawn_fix := false
var _crack_mat: StandardMaterial3D
var _crack_stage := -1


## Stands in for the world's authority, to prove the seam really sees every
## requested block change and that the change comes back applied. Multiplayer
## installs a real one here; single player ships `world.Authority`.
class _RecordingAuthority:
	var requests := 0
	var applied := 0

	func request_edit(w, pos: Vector3i, id: int, record: bool, silent: bool = false) -> bool:
		requests += 1
		var ok: bool = w.apply_edit(pos, id, record, silent)
		if ok:
			on_applied(pos, id)
		return ok

	func on_applied(_pos: Vector3i, _id: int) -> void:
		applied += 1


func _ready() -> void:
	randomize()
	world = load("res://scripts/world.gd").new()
	world.name = "World"
	add_child(world)

	sky = load("res://scripts/sky.gd").new()
	sky.name = "Sky"
	add_child(sky)

	mobs = load("res://scripts/mobs.gd").new()
	mobs.name = "Mobs"
	add_child(mobs)
	mobs.setup(world)

	item_entities = load("res://scripts/item_entities.gd").new()
	item_entities.name = "ItemEntities"
	add_child(item_entities)

	particles = load("res://scripts/particles.gd").new()
	particles.name = "Particles"
	add_child(particles)

	player = load("res://scripts/player.gd").new()
	player.name = "Player"
	add_child(player)
	player.attach(world)
	player.place_at(Vector3(0, 80, 0))
	player.died.connect(_on_died)
	player.block_hit.connect(_on_block_hit)
	player.block_broken.connect(_on_block_broken)
	player.item_thrown.connect(_on_item_thrown)
	item_entities.setup(world, player)

	hud = load("res://scripts/hud.gd").new()
	hud.name = "HUD"
	add_child(hud)
	hud.build(player, world, sky)

	ui = load("res://scripts/ui.gd").new()
	ui.name = "UI"
	add_child(ui)
	ui.new_world_requested.connect(_on_new_world)
	ui.load_world_requested.connect(_on_load_world)
	ui.delete_world_requested.connect(_on_delete_world)
	ui.resume_requested.connect(_resume)
	ui.quit_to_title_requested.connect(_quit_to_title)
	ui.save_requested.connect(_save_game)
	ui.respawn_requested.connect(_respawn)
	ui.settings_applied.connect(_apply_settings)

	# The command console is bound to the live nodes rather than reaching for them
	# itself, which is what will let the same registry run server-side later.
	Commands.bind(player, world, sky, hud)
	Commands.output.connect(_on_command_output)
	_set_cheats(true)
	hud.chat_submitted.connect(_on_chat_submitted)
	hud.chat_canceled.connect(_close_chat)

	_build_selection()
	_build_crack()
	hud.set_debug(false)
	_enter_title()
	_parse_args()
	_check_capture()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture-dir="):
			_capture_dir = a.substr(14)
		elif a.begins_with("--seed="):
			_capture_seed = int(a.substr(7))
		elif a.begins_with("--skin="):
			Settings.player_skin_path = a.substr(7)
		elif a.begins_with("--lang="):
			# a command-line language override, for screenshots and for players who
			# want to pin a language without touching the settings file
			I18n.set_lang(a.substr(7))
		elif a == "--opaque-foliage":
			Blocks.mat_cutout.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			Blocks.mat_cross.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	# _parse_args runs after the player is built, so a --skin= given on the command
	# line has to be pushed into the model here
	if player != null:
		player.refresh_skin()


# ================================================================ selection box
func _build_selection() -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var c := [
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1),
		Vector3(1, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 0),
		Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1),
		Vector3(1, 1, 1), Vector3(0, 1, 1), Vector3(0, 1, 1), Vector3(0, 1, 0),
		Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(1, 1, 0),
		Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 0, 1), Vector3(0, 1, 1),
	]
	for p in c:
		im.surface_add_vertex(p)
	im.surface_end()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0, 0, 0, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = false
	selection = MeshInstance3D.new()
	selection.mesh = im
	selection.material_override = mat
	selection.visible = false
	selection.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(selection)


func _update_selection() -> void:
	if mode != Mode.PLAY:
		selection.visible = false
		return
	var hit: Dictionary = player.look_at_block()
	if hit.is_empty():
		selection.visible = false
		return
	var p: Vector3i = hit["pos"]
	selection.position = Vector3(float(p.x) - 0.002, float(p.y) - 0.002, float(p.z) - 0.002)
	selection.scale = Vector3(1.004, 1.004, 1.004)
	selection.visible = true


# ================================================================ block damage
## The crack overlay shader-less stand-in: a slightly oversized box carrying the
## current crack texture, drawn over the block being mined.
func _build_crack() -> void:
	_crack_mat = StandardMaterial3D.new()
	_crack_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_crack_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_crack_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_crack_mat.texture_repeat = false
	_crack_mat.vertex_color_use_as_albedo = false
	_crack_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_crack_mat.albedo_texture = Art.tex_crack[0]
	crack = MeshInstance3D.new()
	crack.mesh = Blocks.make_overlay_cube()
	crack.scale = Vector3(1.008, 1.008, 1.008)
	crack.material_override = _crack_mat
	crack.visible = false
	crack.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	crack.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(crack)


func _update_crack() -> void:
	if mode != Mode.PLAY:
		crack.visible = false
		return
	var f: float = player.dig_progress()
	if f <= 0.001:
		crack.visible = false
		_crack_stage = -1
		return
	var stage := clampi(int(f * 5.0), 0, 4)
	if stage != _crack_stage:
		_crack_stage = stage
		_crack_mat.albedo_texture = Art.tex_crack[stage]
	var p: Vector3i = player.dig_target_pos()
	crack.position = Vector3(float(p.x) + 0.5, float(p.y) + 0.5, float(p.z) + 0.5)
	crack.visible = true


func _on_block_hit(pos: Vector3i, id: int) -> void:
	particles.burst(_block_center(pos), Blocks.average_color(id), 3)


func _on_block_broken(pos: Vector3i, id: int) -> void:
	var at := _block_center(pos)
	particles.burst(at, Blocks.average_color(id), 12)
	if player.creative:
		return
	var drop: int = Blocks.drops[id]
	if drop > 0:
		item_entities.drop(drop, 1, Vector3(at.x, float(pos.y) + 0.25, at.z))
	# leaves occasionally cough up an apple, which is what feeds the hunger bar
	if id == Blocks.LEAVES and randf() < 0.08:
		item_entities.drop(Blocks.ITEM_APPLE, 1, Vector3(at.x, float(pos.y) + 0.25, at.z))


func _block_center(pos: Vector3i) -> Vector3:
	return Vector3(float(pos.x) + 0.5, float(pos.y) + 0.5, float(pos.z) + 0.5)


## Q throws the item out in front of the player, where it lands as a real entity
## you can walk back over.
func _on_item_thrown(id: int, count: int) -> void:
	var dir: Vector3 = player.look_dir()
	item_entities.drop(id, count, player.eye_position() + dir * 0.9,
		dir * 4.5 + Vector3(0.0, 2.0, 0.0))


# ================================================================ modes
func _enter_title() -> void:
	mode = Mode.TITLE
	if _chat_open:
		_close_chat()
	ui.open_screen("title")
	hud.visible = false
	player.set_input_enabled(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Sfx.stop_music()
	selection.visible = false
	crack.visible = false


func _on_new_world(nm: String, s: int, creative: bool, distance: int, cheats: bool = true) -> void:
	world_name = nm
	seed_value = s
	world_dir = _unique_dir(nm)
	_set_cheats(cheats)
	world.reset()
	mobs.reset()
	item_entities.reset()
	particles.clear()
	world.setup(s, distance)
	world.render_distance = clampi(distance, Settings.MIN_RD, Settings.max_render_distance())
	world.ao_enabled = Settings.quality > 0
	sky.set_render_distance(world.render_distance)
	player.creative = creative
	player.flying = false
	player.heal_all()
	player.reset_inventory()
	seed_value = s
	sky.time_of_day = 0.42
	player.place_at(world.terrain.find_spawn() + Vector3(0, 0.2, 0))
	_needs_spawn_fix = true
	if creative:
		player.fill_creative_hotbar()
	_begin_loading()


func _on_load_world(dir_name: String) -> void:
	var base := "%s/%s" % [SAVE_ROOT, dir_name]
	var meta := _read_json("%s/level.json" % base)
	if meta.is_empty():
		ui.open_screen("title")
		return
	world_dir = dir_name
	mobs.reset()
	item_entities.reset()
	particles.clear()
	world_name = str(meta.get("name", dir_name))
	seed_value = int(meta.get("seed", 12345))
	_set_cheats(bool(meta.get("cheats", true)))
	world.reset()
	world.setup(seed_value, int(meta.get("render_distance", Settings.render_distance)))
	world.render_distance = clampi(int(meta.get("render_distance", Settings.render_distance)),
		Settings.MIN_RD, Settings.max_render_distance())
	world.ao_enabled = Settings.quality > 0
	sky.set_render_distance(world.render_distance)
	sky.time_of_day = float(meta.get("time", 0.3))
	var ed := FileAccess.open("%s/edits.bin" % base, FileAccess.READ)
	if ed != null:
		world.load_edits(ed.get_buffer(ed.get_length()))
		ed.close()
	# the circuit file has to be read *after* the edits, or the circuit blocks it
	# refers to are not in the world yet and every one of them is dropped
	if world.circuit != null:
		world.circuit.clear()
		var cf := FileAccess.open("%s/circuit.bin" % base, FileAccess.READ)
		if cf != null:
			world.circuit.load_state(cf.get_buffer(cf.get_length()))
			cf.close()
	var ps = meta.get("player", {})
	if ps is Dictionary:
		player.reset_inventory()
		player.load_state(ps)
	_begin_loading()


func _on_delete_world(dir_name: String) -> void:
	var base := "%s/%s" % [SAVE_ROOT, dir_name]
	_remove_dir(base)
	ui.open_screen("worlds")


func _begin_loading() -> void:
	mode = Mode.LOADING
	ui.open_screen("loading")
	hud.visible = false
	player.set_input_enabled(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	selection.visible = false
	_run_loading()


func _run_loading() -> void:
	var t := 0.0
	while true:
		world.update_streaming(player.global_position)
		var p: float = world.progress()
		ui.set_loading(p * 100.0, "%d%%  -  %d chunks  -  seed %d" % [
			int(p * 100.0), world.loaded_chunks(), seed_value])
		if p >= 0.999 and world.idle():
			break
		t += get_process_delta_time()
		if t > 60.0:
			break
		await get_tree().process_frame
	# let the meshes settle
	for i in 3:
		await get_tree().process_frame
	_begin_play()


func _begin_play() -> void:
	mode = Mode.PLAY
	ui.close_all()
	hud.visible = true
	player.set_input_enabled(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Sfx.start_music()
	if _needs_spawn_fix:
		_needs_spawn_fix = false
		player.place_at(world.safe_spawn_near(player.global_position))
	_apply_settings(false)


func _pause() -> void:
	if mode != Mode.PLAY:
		return
	if _inv_open:
		_close_inventory()
	if _chat_open:
		_close_chat()
	mode = Mode.PAUSE
	ui.open_screen("pause")
	player.set_input_enabled(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _resume() -> void:
	if mode != Mode.PAUSE:
		return
	mode = Mode.PLAY
	ui.close_all()
	player.set_input_enabled(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _quit_to_title() -> void:
	_save_game()
	world.reset()
	mobs.reset()
	item_entities.reset()
	particles.clear()
	_enter_title()


func _respawn() -> void:
	player.respawn(world.safe_spawn_near(world.terrain.find_spawn()))
	mode = Mode.PLAY
	ui.close_all()
	player.set_input_enabled(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_died() -> void:
	mode = Mode.DEATH
	ui.open_screen("death")
	player.set_input_enabled(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.flash_hurt()


func _apply_settings(from_menu: bool = true) -> void:
	if player != null:
		player.apply_settings()
	if sky != null:
		sky.apply_quality()
		sky.apply_fog()
	# the render pack is a material + environment pairing, so both halves are
	# re-applied on every settings change
	Blocks.apply_render_preset(Settings.render_preset)
	if sky != null:
		sky.apply_render_preset(Settings.render_preset)
	if from_menu and world != null and world.terrain != null:
		var rd := clampi(Settings.render_distance, Settings.MIN_RD, Settings.max_render_distance())
		if rd != world.render_distance:
			world.render_distance = rd
			world.request_rebuild()
			if sky != null:
				sky.set_render_distance(rd)
		world.ao_enabled = Settings.quality > 0


# ================================================================ inventory
func _open_inventory() -> void:
	if mode != Mode.PLAY:
		return
	_inv_open = true
	hud.open_inventory(true)
	player.set_input_enabled(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_inventory() -> void:
	_inv_open = false
	hud.open_inventory(false)
	player.set_input_enabled(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ================================================================ chat & commands
## Cheats on means the player is a level-2 admin locally. With cheats off only the
## informational commands survive. In multiplayer this same switch is what the
## server would consult per sender, which is why the level lives on Commands and
## not on the player.
func _set_cheats(on: bool) -> void:
	_cheats = on
	Commands.cheats_enabled = on
	Commands.level = Commands.LEVEL_ADMIN if on else Commands.LEVEL_ANY


func _open_chat(prefix: String, console: bool = false) -> void:
	if mode != Mode.PLAY or _inv_open or hud.is_chat_open():
		return
	_chat_open = true
	_console_mode = console
	hud.open_chat(prefix)
	player.set_input_enabled(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## The backtick console: the same box, but it says hello and tells you where to
## start, the way a terminal should.
func _open_console() -> void:
	_open_chat("/", true)
	hud.chat_print(I18n.t("VoxelCraft console  -  /help lists commands"),
		Color(0.70, 0.85, 1.0))


func _close_chat() -> void:
	if not _chat_open:
		return
	_chat_open = false
	_console_mode = false
	hud.close_chat()
	if mode == Mode.PLAY and not _inv_open:
		player.set_input_enabled(true)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_chat_open() -> bool:
	return _chat_open


func _on_chat_submitted(text: String) -> void:
	hud.remember_line(text)
	var console := _console_mode
	_close_chat()
	var t := text.strip_edges()
	if t == "":
		return
	if console:
		# a terminal has no chat, so every line is a command, "/" or not
		Commands.run_command(t)
		return
	if t.begins_with("/"):
		Commands.execute_line(t)
		return
	# Single player: a plain message just goes into your own log. In multiplayer
	# this is the one line that becomes "broadcast chat to everyone else".
	hud.chat_print("<you> " + t, Color(1, 1, 1, 0.92))


func _on_command_output(text: String) -> void:
	hud.chat_print(text, Color(0.78, 0.90, 1.0))


# ================================================================ save / load
func _save_game() -> void:
	if world_dir == "":
		return
	var base := "%s/%s" % [SAVE_ROOT, world_dir]
	DirAccess.make_dir_recursive_absolute(base)
	var meta := {
		"name": world_name,
		"seed": seed_value,
		"creative": player.creative,
		"cheats": _cheats,
		"render_distance": world.render_distance,
		"time": sky.time_of_day,
		"player": player.save_state(),
		"saved_at": Time.get_datetime_string_from_system(),
	}
	var f := FileAccess.open("%s/level.json" % base, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(meta, "  "))
		f.close()
	var e := FileAccess.open("%s/edits.bin" % base, FileAccess.WRITE)
	if e != null:
		e.store_buffer(world.serialize_edits())
		e.close()
	# circuit state is not derivable from the blocks alone -- a lever's position and
	# a piston's arm are not in the voxel data -- so it gets its own file
	if world.circuit != null:
		var cf := FileAccess.open("%s/circuit.bin" % base, FileAccess.WRITE)
		if cf != null:
			cf.store_buffer(world.circuit.serialize())
			cf.close()
	if mode == Mode.PAUSE or mode == Mode.PLAY:
		hud.toast(I18n.tf("World saved  (%d blocks changed)", [world.edit_count()]))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return parsed
	return {}


func _unique_dir(nm: String) -> String:
	var clean := ""
	for i in nm.length():
		var c := nm[i]
		if c.is_valid_identifier() or c == "_" or c == "-" or c.is_valid_int():
			clean += c
		else:
			clean += "_"
	if clean == "":
		clean = "world"
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	return "%s_%s" % [clean, stamp]


func _remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir():
			d.remove(f)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


# ================================================================ leaving the window
## Taking the mouse out of the window, or the window out of focus, pauses the game and
## puts the pause screen up.
##
## This can only fire once a menu has released the cursor. While actually playing the mouse
## is `MOUSE_MODE_CAPTURED`, which is what first-person look needs -- the view is driven by
## relative motion, and relative motion only exists while the cursor is held -- so the
## cursor has no way out of the window mid-play. The order is therefore always: open a menu
## (which frees the cursor), take it somewhere else, and the world stops instead of running
## on behind the menu while nobody is watching it.
func _notification(what: int) -> void:
	# Not during a capture run: those drive the game from a script, and a window that
	# happens to be unfocused would pause them out from under their own assertions.
	if _capture != "":
		return
	match what:
		NOTIFICATION_WM_MOUSE_EXIT, NOTIFICATION_WM_WINDOW_FOCUS_OUT, \
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_leave_window()


## The behaviour itself, split from the trigger above so a scripted run can call it and
## assert on it. Coming back deliberately does nothing: a stray click on the window must
## not put the player back in the world mid-swing, so resuming stays a menu choice.
func _leave_window() -> void:
	if mode == Mode.PLAY:
		_pause()


# ================================================================ input
func _unhandled_input(event: InputEvent) -> void:
	if _capture != "":
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := (event as InputEventKey).keycode
	if k == KEY_F12:
		_save_screenshot()
		return
	if k == KEY_F3 and mode == Mode.PLAY:
		hud.set_debug(not hud.debug_visible)
		return
	match mode:
		Mode.PLAY:
			if k == KEY_ESCAPE:
				if _inv_open:
					_close_inventory()
				else:
					_pause()
			elif k == KEY_E:
				if _inv_open:
					_close_inventory()
				else:
					_open_inventory()
			elif k == KEY_F5:
				player.cycle_camera()
				hud.toast(I18n.tf("Camera: %s", [I18n.t(player.camera_mode_name())]))
			elif k == KEY_T:
				_open_chat("")
			elif k == KEY_SLASH:
				_open_chat("/")
			elif k == KEY_QUOTELEFT:
				_open_console()
			elif k >= KEY_1 and k <= KEY_9:
				player.select_slot(k - KEY_1)
		Mode.PAUSE:
			if k == KEY_ESCAPE:
				_resume()
		Mode.DEATH:
			if k == KEY_ENTER:
				_respawn()


func _save_screenshot() -> void:
	var dir := OS.get_user_data_dir() + "/screenshots"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/voxel_%d.png" % [dir, Time.get_ticks_msec()]
	get_viewport().get_texture().get_image().save_png(path)
	hud.toast(I18n.t("Screenshot saved"))


# ================================================================ frame
func _process(delta: float) -> void:
	_fps_smooth = lerpf(_fps_smooth, 1.0 / maxf(delta, 0.0001), clampf(delta * 6.0, 0.0, 1.0))
	if mode == Mode.PLAY or mode == Mode.LOADING:
		sky.advance(delta)
		var in_water: bool = player.head_in_water()
		sky.set_underwater(in_water and mode == Mode.PLAY, delta)
	if mode == Mode.PLAY:
		world.update_streaming(player.global_position)
		# the circuit solver only does work when a circuit block actually changed, so
		# this is a dictionary lookup on a quiet frame
		if world.circuit != null:
			world.circuit.update(delta)
		mobs.update(player.global_position, delta)
		item_entities.update(player.global_position, delta)
		particles.update(delta)
		_update_selection()
		_update_crack()
		# The overlay costs a raycast, a biome lookup, several Performance monitors and
		# a font measurement pass per line. Skip all of it on the frames it is off.
		if hud.debug_visible:
			hud.set_debug_text(_debug_text())


func _debug_text() -> String:
	var p: Vector3 = player.global_position
	var c := Vector2i(floori(p.x) >> 4, floori(p.z) >> 4)
	var lx := floori(p.x) & 15
	var lz := floori(p.z) & 15
	var bio: int = world.terrain.biome_at(floori(p.x), floori(p.z))
	var hit: Dictionary = player.look_at_block()
	var looking := "air"
	var light: int = world.highest_occluder(floori(p.x), floori(p.z)) - floori(p.y)
	if not hit.is_empty():
		var hp: Vector3i = hit["pos"]
		looking = "%s @ %d %d %d" % [Blocks.display_name(world.get_block(hp.x, hp.y, hp.z)),
			hp.x, hp.y, hp.z]
	var facing := "north"
	var y := fposmod(-player.yaw, TAU)
	if y < PI * 0.25 or y >= PI * 1.75:
		facing = "north"
	elif y < PI * 0.75:
		facing = "east"
	elif y < PI * 1.25:
		facing = "south"
	else:
		facing = "west"
	var lines := [
		"VoxelCraft  %d fps" % int(_fps_smooth),
		"XYZ %.2f / %.2f / %.2f" % [p.x, p.y, p.z],
		"Block %d %d %d   Chunk %d %d   local %d %d" % [
			floori(p.x), floori(p.y), floori(p.z), c.x, c.y, lx, lz],
		"Biome %s   Facing %s" % [world.terrain.biome_name(bio), facing],
		"Depth below surface %d   Sky light %.2f" % [light,
			clampf(1.0 - float(maxi(0, light)) * 0.085, 0.13, 1.0)],
		"Looking at: %s" % looking,
		"Time %s   %s" % [sky.clock_text(), "night" if sky.is_night() else "day"],
		"Chunks %d   Edits %d   Lights %d   Mobs %d   Drops %d" % [
			world.loaded_chunks(), world.edit_count(), world.torches.size(), mobs.count(),
			item_entities.count()],
		"Mode %s   RD %d   Seed %d" % [
			"creative" if player.creative else "survival", world.render_distance, seed_value],
		"Draw calls %d   Objects %d   VRAM %.0f MB" % [
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0],
	]
	return "\n".join(lines)


# ================================================================ self test
var _pass := 0
var _fail := 0
var _probe_dist := 0.0


## Walks in each of the four cardinal directions for a moment, optionally holding
## Ctrl, and records the top speed reached. Taking the best of four directions makes
## the probe immune to a tree happening to sit in front of the player.
func _sprint_probe(sprint: bool) -> void:
	_probe_dist = 0.0
	for k in 4:
		player.yaw = float(k) * PI * 0.5
		for i in 4:
			await get_tree().physics_frame
		Input.action_press("forward")
		if sprint:
			Input.action_press("sprint")
		for i in 26:
			await get_tree().physics_frame
			_probe_dist = maxf(_probe_dist, Vector2(player.velocity.x, player.velocity.z).length())
		Input.action_release("forward")
		Input.action_release("sprint")
		for i in 8:
			await get_tree().physics_frame


## True when the hotbar or backpack holds at least one of `id`.
func _inventory_has(id: int) -> bool:
	for list in [player.hotbar, player.inventory]:
		for stack in list:
			if int(stack["id"]) == id and int(stack["count"]) > 0:
				return true
	return false


## [same, opposite, triangles] — how many triangles have a cross-product normal
## that agrees with the declared vertex normals. Calibrate the expected count on a
## known-good box before trusting it on generated geometry.
func _winding_counts(v: PackedVector3Array, n: PackedVector3Array,
		idx: PackedInt32Array) -> Array:
	var same := 0
	var opposite := 0
	var t := 0
	while t + 2 < idx.size():
		var a: Vector3 = v[idx[t]]
		var b: Vector3 = v[idx[t + 1]]
		var c: Vector3 = v[idx[t + 2]]
		var geo: Vector3 = (b - a).cross(c - a)
		var declared: Vector3 = n[idx[t]] + n[idx[t + 1]] + n[idx[t + 2]]
		if geo.dot(declared) > 0.0:
			opposite += 1
		else:
			same += 1
		t += 3
	return [same, opposite, int(idx.size() / 3)]


func _check(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS  %s  %s" % [label, detail])
	else:
		_fail += 1
		print("  FAIL  %s  %s" % [label, detail])


func _run_selftest() -> void:
	print("=== selftest ===")
	# 1. world creation through the real menu signal path
	ui.new_world_requested.emit("Selftest", 4242, false, 4, true)
	await _wait_loaded()
	await _settle()
	# the player only starts falling once play mode enables input, so wait for a
	# genuinely settled state before asserting anything about the world
	for i in 900:
		if mode == Mode.PLAY and player.on_ground and player.velocity.length() < 0.05:
			break
		await get_tree().physics_frame
	_check("world loaded", world.loaded_chunks() > 100, "chunks=%d" % world.loaded_chunks())
	_check("survival mode", player.creative == false)
	_check("in play mode and grounded", mode == Mode.PLAY and player.on_ground,
		"mode=%d on_ground=%s" % [mode, str(player.on_ground)])

	# 2b. mouse look must work through the real event pipeline (GUI layers get first
	#     refusal on mouse events, so this is exactly the kind of bug that only a
	#     synthesised event can catch)
	var yaw_before: float = player.yaw
	var pitch_before: float = player.pitch
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	for i in 3:
		await get_tree().process_frame
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(160, 60)
	Input.parse_input_event(mm)
	for i in 4:
		await get_tree().process_frame
	_check("mouse look turns the view", absf(player.yaw - yaw_before) > 0.02,
		"dyaw=%.4f" % (player.yaw - yaw_before))
	_check("mouse look pitches the view", absf(player.pitch - pitch_before) > 0.02,
		"dpitch=%.4f" % (player.pitch - pitch_before))
	var wheel_before: int = player.selected
	var wb := InputEventMouseButton.new()
	wb.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wb.pressed = true
	Input.parse_input_event(wb)
	for i in 3:
		await get_tree().process_frame
	_check("mouse wheel cycles the hotbar", player.selected != wheel_before,
		"%d -> %d" % [wheel_before, player.selected])

	# 2. the player is standing on solid ground, not inside terrain. The footprint can
	#    straddle two columns, so test every cell under it rather than one.
	var box: AABB = player.feet_aabb()
	var fy := floori(player.global_position.y) - 1
	var supported := false
	var under := ""
	for x in range(floori(box.position.x), floori(box.position.x + box.size.x - 0.001) + 1):
		for z in range(floori(box.position.z), floori(box.position.z + box.size.z - 0.001) + 1):
			if world.is_solid(x, fy, z):
				supported = true
				under = Blocks.display_name(world.get_block(x, fy, z))
	_check("standing on solid block", supported and player.on_ground,
		"pos=(%.3f, %.3f, %.3f) under=%s" % [player.global_position.x,
			player.global_position.y, player.global_position.z, under])
	_check("not stuck in terrain", not player._collides_at(player.global_position))

	# 3. fall damage produces a hurt
	player.health = 20.0
	player.place_at(player.global_position + Vector3(0, 9, 0))
	for i in 30:
		await get_tree().physics_frame
	var left_ground: bool = not player.on_ground
	for i in 400:
		await get_tree().physics_frame
		if player.on_ground:
			break
	_check("fell and landed", left_ground and player.on_ground)
	_check("fall damage applied", player.health < 20.0 and player.health > 0.0,
		"health=%.1f" % player.health)
	player.heal_all()

	# 4. digging through the real input path, aimed at a block we build ourselves. The
	#    old version looked 57 degrees down and mined whatever the terrain happened to
	#    put in front of it, which is why this step went intermittently red: land on a
	#    narrow ledge and the ray misses everything within reach, so the "mined" cell
	#    is the (-999, 0, 0) fallback and every assertion below it cascades.
	player.health = 20.0
	player.place_at(world.safe_spawn_near(player.global_position))
	player.pitch = 0.0
	player.yaw = 0.0
	for i in 12:
		await get_tree().physics_frame
	var dx := floori(player.global_position.x)
	var dz := floori(player.global_position.z)
	var dy := floori(player.eye_position().y)
	# clear the lane, then a soft block three ahead at eye height
	world.set_block(dx, dy, dz - 1, Blocks.AIR)
	world.set_block(dx, dy, dz - 2, Blocks.AIR)
	world.set_block(dx, dy, dz - 3, Blocks.DIRT)
	for i in 3:
		await get_tree().physics_frame
	var target: Vector3i = player.look_at_block().get("pos", Vector3i(-999, 0, 0))
	_check("dig aims at the reference block", target == Vector3i(dx, dy, dz - 3),
		"target=%s want=%s" % [str(target), str(Vector3i(dx, dy, dz - 3))])
	var before_id: int = world.get_block(target.x, target.y, target.z)
	Input.action_press("attack")
	for i in 300:
		await get_tree().physics_frame
		if world.get_block(target.x, target.y, target.z) == Blocks.AIR:
			break
	Input.action_release("attack")
	var broke: bool = world.get_block(target.x, target.y, target.z) == Blocks.AIR
	_check("block broken by holding LMB", broke,
		"%s -> %s" % [Blocks.display_name(before_id),
			Blocks.display_name(world.get_block(target.x, target.y, target.z))])
	# the drop now pops out as an item entity, so the player has to walk onto it
	var drop: int = Blocks.drops[before_id]
	_check("broken block spawned a drop entity", item_entities.count() > 0,
		"%d alive" % item_entities.count())
	player.place_at(Vector3(float(target.x) + 0.5, float(target.y) + 0.6,
		float(target.z) + 0.5))
	var got := false
	for i in 120:
		await get_tree().physics_frame
		if _inventory_has(drop):
			got = true
			break
	_check("walking over the drop collects it", got, Blocks.display_name(drop))
	var leftover := ""
	for it in item_entities.items:
		if is_instance_valid(it):
			leftover += "%d " % int(it.item_id)
	_check("collected drop left no entity behind", item_entities.count() == 0,
		"%d alive: %s" % [item_entities.count(), leftover])

	# 5. placing through the real input path, aimed at a reference pillar we build
	#    ourselves. It faces +Z, the opposite way from the dig, so the pillar can never
	#    refill the hole the dig made -- the two steps would otherwise fight over the
	#    same cell, which is what the assertions below check for.
	Input.action_release("attack")
	for i in 4:
		await get_tree().physics_frame
	player.place_at(world.safe_spawn_near(player.global_position))
	player.pitch = 0.0
	player.yaw = PI
	for i in 12:
		await get_tree().physics_frame
	var px := floori(player.global_position.x)
	var pz := floori(player.global_position.z)
	var py := floori(player.eye_position().y)
	world.set_block(px, py, pz + 1, Blocks.AIR)
	world.set_block(px, py, pz + 2, Blocks.AIR)
	world.set_block(px, py, pz + 3, Blocks.STONE)
	player.hotbar[0] = {"id": Blocks.PLANKS, "count": 8}
	player.hotbar_changed.emit()
	player.select_slot(0)
	for i in 3:
		await get_tree().physics_frame
	var spot: Vector3i = player.look_at_block().get("prev", Vector3i(-999, 0, 0))
	_check("place aims at a fresh cell", spot == Vector3i(px, py, pz + 2) and spot != target,
		"spot=%s vs dig=%s" % [str(spot), str(target)])
	Input.action_press("use")
	for i in 6:
		await get_tree().physics_frame
	Input.action_release("use")
	_check("block placed with RMB", world.get_block(spot.x, spot.y, spot.z) == Blocks.PLANKS,
		"at %s" % str(spot))
	_check("stack consumed", int(player.hotbar[0]["count"]) == 7,
		"count=%d" % int(player.hotbar[0]["count"]))

	# 6. inventory + crafting through the real HUD handlers
	_open_inventory()
	_check("inventory opened", hud.is_inventory_open())
	player.crafting[0] = {"id": Blocks.LOG, "count": 2}
	hud.refresh_inventory()
	var res: Dictionary = player.craft_result()
	_check("recipe matched (log -> planks)", int(res["id"]) == Blocks.PLANKS and int(res["count"]) == 4,
		str(res))
	hud._on_inv_slot(200, MOUSE_BUTTON_LEFT)
	_check("result taken to cursor", int(player.cursor_stack["id"]) == Blocks.PLANKS
		and int(player.cursor_stack["count"]) == 4, str(player.cursor_stack))
	_check("ingredients consumed", int(player.crafting[0]["count"]) == 1)
	hud._on_inv_slot(300, MOUSE_BUTTON_LEFT)
	_check("creative palette still grants items", int(player.cursor_stack["count"]) == 64)
	player.cursor_stack = {"id": 0, "count": 0}
	_close_inventory()
	_check("inventory closed", not hud.is_inventory_open())

	# 7. save, quit to title, reload, and verify the edit survived
	world.set_block(spot.x, spot.y + 3, spot.z, Blocks.DIAMOND_ORE)
	_save_game()
	_check("save written", FileAccess.file_exists("user://saves/%s/level.json" % world_dir),
		world_dir)
	var saved_dir := world_dir
	_check("edits tracked", world.edit_count() > 0, "edits=%d" % world.edit_count())
	# the invented spot has to be in the edit log, or the reload below is asking the
	# world for something that was never recorded and the failure is a test artefact
	_check("the placed cell is in the edit log", world.edits.has(spot)
		and int(world.edits.get(spot, -1)) == Blocks.PLANKS,
		"spot=%s log=%s" % [str(spot), str(world.edits.get(spot, -1))])
	_quit_to_title()
	_check("back at title", mode == Mode.TITLE)
	ui.load_world_requested.emit(saved_dir)
	await _wait_loaded()
	await _settle()
	_check("reloaded same seed", seed_value == 4242, "seed=%d" % seed_value)
	_check("broken block still gone", world.get_block(target.x, target.y, target.z) == Blocks.AIR)
	_check("placed block still there", world.get_block(spot.x, spot.y, spot.z) == Blocks.PLANKS,
		Blocks.display_name(world.get_block(spot.x, spot.y, spot.z)))
	# the value is reported because the interesting failure is not "it changed" but *what*
	# it changed to: an edit that never reached the log comes back as whatever the
	# generator puts there, which is a different bug from one that arrived and was lost
	var ore_back: int = world.get_block(spot.x, spot.y + 3, spot.z)
	_check("diamond ore edit persisted", ore_back == Blocks.DIAMOND_ORE,
		"at %s got %s (id %d), edit logged as %d" % [str(Vector3i(spot.x, spot.y + 3, spot.z)),
			Blocks.display_name(ore_back), ore_back,
			int(world.edits.get(Vector3i(spot.x, spot.y + 3, spot.z), -1))])

	# 8. day/night
	sky.time_of_day = 0.0
	sky.update_sky(0.016)
	_check("midnight is dark", sky.sun.light_energy < 0.05, "energy=%.2f" % sky.sun.light_energy)
	sky.time_of_day = 0.5
	sky.update_sky(0.016)
	_check("noon is bright", sky.sun.light_energy > 1.0, "energy=%.2f" % sky.sun.light_energy)

	# 9b. player model / skin system
	player.model.set_skin(2)
	_check("skin system switches", player.model.skin_name() == "Ninja", player.model.skin_name())
	player.model.set_skin(Settings.player_skin)
	player.third_person = true
	for i in 8:
		await get_tree().physics_frame
	_check("player body visible in third person", player.model.visible
		and player.model.head.visible and player.model.leg_r != null)
	player.third_person = false
	for i in 4:
		await get_tree().physics_frame
	# first person keeps the limbs and drops the head and chest: the limbs are what you
	# see looking down, and the body has to stay *drawn* for any of it to cast a shadow
	_check("player body stays drawn in first person, minus the head and chest",
		player.model.visible and not player.model.head.visible
			and not player.model.torso.visible and player.model.leg_r.visible)

	# 9c. sprinting with Ctrl actually moves you faster than walking
	player.yaw = 0.0
	player.pitch = 0.0
	await _sprint_probe(false)
	var walk_d: float = _probe_dist
	await _sprint_probe(true)
	var run_d: float = _probe_dist
	_check("Ctrl sprint is faster than walking", run_d > walk_d * 1.15,
		"walk=%.2f sprint=%.2f blocks/s" % [walk_d, run_d])

	# 9d. mobs
	var t2 := 0.0
	while t2 < 12.0 and mobs.count() < 3:
		t2 += get_process_delta_time()
		await get_tree().process_frame
	for i in 90:                      # let them settle onto the ground
		await get_tree().process_frame
	_check("passive mobs spawn", mobs.count() > 0, "%d alive" % mobs.count())
	var grounded := 0
	var bad := 0
	for m in mobs.mobs:
		if not is_instance_valid(m) or not m.on_ground:
			continue
		grounded += 1
		# Check the whole footprint, not just the cell under the mob's centre: a mob
		# certifying on_ground while straddling a step rests on a neighbouring column,
		# and its centre column can be empty. This is the same straddle the player's
		# own "standing on solid block" check already has to allow for.
		var mx := floori(m.global_position.x)
		var mz := floori(m.global_position.z)
		var gy := floori(m.global_position.y) - 1
		var mob_supported := false
		for ox in range(-1, 2):
			for oz in range(-1, 2):
				if world.is_solid(mx + ox, gy, mz + oz):
					mob_supported = true
		if not mob_supported:
			bad += 1
	_check("mobs stand on solid ground", bad == 0 and grounded >= 3,
		"%d grounded, %d floating" % [grounded, bad])

	# 9. water
	var found_water := false
	for c in world.chunks.keys():
		for y in range(28, 34):
			if world.get_block(c.x * 16 + 8, y, c.y * 16 + 8) == Blocks.WATER:
				found_water = true
				break
		if found_water:
			break
	_check("water generated somewhere", found_water)

	# The save did its job several checks ago; take it away again at the very end.
	# Without this every run leaves another "Selftest_<timestamp>" world behind, and
	# they pile up in the load-world list until it is nothing but test worlds.
	_remove_dir("%s/%s" % [SAVE_ROOT, saved_dir])
	_check("the test cleans up the world it saved",
		not FileAccess.file_exists("%s/%s/level.json" % [SAVE_ROOT, saved_dir]), saved_dir)

	print("=== selftest: %d passed, %d failed ===" % [_pass, _fail])


# ================================================================ captures
## A few-second check of the held-item model: it needs no world, so it runs straight
## from the title screen and takes a fraction of the time of the full suite.
func _hand_test() -> void:
	print("=== hand test ===")
	_pass = 0
	_fail = 0

	# ---- the vertical section index helpers. `sec_of` / `ly_of` must floor toward
	# negative infinity, not truncate toward zero, or a block at y = -1 would be filed
	# into section 0 at the top of it instead of section -1 at the bottom. The world
	# floor is below zero now, so a mistake here would file the deepest blocks into the
	# section above and quietly destroy the bedrock layer.
	_check("a section index floors for negative y",
		VoxelTerrain.sec_of(-1) == -1 and VoxelTerrain.sec_of(-16) == -1
			and VoxelTerrain.sec_of(-17) == -2,
		"-1 -> %d, -16 -> %d, -17 -> %d" % [VoxelTerrain.sec_of(-1),
			VoxelTerrain.sec_of(-16), VoxelTerrain.sec_of(-17)])
	_check("and so does the y within it",
		VoxelTerrain.ly_of(-1) == 15 and VoxelTerrain.ly_of(-16) == 0
			and VoxelTerrain.ly_of(-17) == 15,
		"-1 -> %d, -16 -> %d, -17 -> %d" % [VoxelTerrain.ly_of(-1),
			VoxelTerrain.ly_of(-16), VoxelTerrain.ly_of(-17)])
	# a round trip is the property that actually matters: every y maps to exactly one
	# (section, ly) and back, across the whole intended range
	var round_trip := true
	for y in range(-64, 320):
		if (VoxelTerrain.sec_of(y) * 16 + VoxelTerrain.ly_of(y)) != y:
			round_trip = false
	_check("section plus ly round-trips every y, negatives included", round_trip,
		"y=-64..319")

	# The suite pokes Settings (framerate cap, fog, language) to prove those knobs
	# reach the engine. Snapshot them first: if any code path writes the config
	# during the run, the player's real settings must not be what gets saved.
	var saved_settings := {
		"max_fps": Settings.max_fps,
		"fog_scale": Settings.fog_scale,
		"fog_enabled": Settings.fog_enabled,
		"lang": Settings.lang,
	}
	# the world is empty at the title screen, and neither the body model nor the
	# item entities need one, so this runs in seconds instead of generating chunks
	player.creative = false
	player.reset_inventory()
	player.select_slot(0)
	# The held block is drawn in the body's own right hand and *nowhere else*. There used
	# to be a second, camera-mounted copy that existed only for first person; now that the
	# body is drawn in first person too that copy was a duplicate, so this is the single
	# place a held block can appear and the single thing worth asserting on.
	_check("an empty hand shows no block", not player.model.held.visible
		and player.model.held.mesh == null)

	# picking a block up into the slot you are holding must show it immediately
	player.give(Blocks.COBBLESTONE, 3)
	_check("picked-up block appears in the hand", player.model.held.mesh != null
		and player.model.held.visible, "slot0 id=%d x%d" % [
			int(player.hotbar[0]["id"]), int(player.hotbar[0]["count"])])

	# building until the stack runs out must clear it
	player.consume_selected(3)
	_check("empty stack clears the hand", not player.model.held.visible,
		"count=%d" % int(player.hotbar[0]["count"]))

	# switching to another slot shows that slot's block
	player.hotbar[1] = {"id": Blocks.PLANKS, "count": 2}
	player.hotbar_changed.emit()
	player.select_slot(1)
	_check("switching slot shows its block", player.model.held.mesh != null
		and player.model.held.visible)

	# dropping the last one must clear it too
	player.drop_selected()
	player.drop_selected()
	_check("dropping the last item clears the hand", not player.model.held.visible,
		"count=%d" % int(player.hotbar[1]["count"]))

	# a non-block item (a stick) has no 3D model, so the hand must stay empty
	player.hotbar[2] = {"id": Blocks.ITEM_STICK, "count": 4}
	player.hotbar_changed.emit()
	player.select_slot(2)
	_check("non-block item leaves the hand empty", player.model.held.mesh == null)

	# eating: food restores hunger and is consumed, a stick is not food
	player.hunger = 8.0
	player.select_slot(2)
	_check("a stick cannot be eaten", not player.eat_selected()
		and int(player.hotbar[2]["count"]) == 4)
	player.hotbar[3] = {"id": Blocks.ITEM_APPLE, "count": 2}
	player.hotbar_changed.emit()
	player.select_slot(3)
	_check("an apple can be eaten", player.eat_selected())
	_check("eating restores hunger", player.hunger == 12.0, "hunger=%.0f" % player.hunger)
	_check("eating consumes the item", int(player.hotbar[3]["count"]) == 1)
	player.hunger = 20.0
	_check("a full belly refuses food", not player.eat_selected())

	# The skin unwrap has to satisfy two things that the eye cannot check on a
	# 4 pixel limb, so both are asserted numerically. Geometry only — no reading of
	# skin colours — so it stays valid for imported Minecraft skins too.
	# checked on the arm that is actually in the model, not on a copy built for the
	# check: this is the mesh the player now sees in every camera mode
	var arm_mesh: ArrayMesh = player.model.arm_r.mesh
	var aa: Array = arm_mesh.surface_get_arrays(0)
	var av: PackedVector3Array = aa[Mesh.ARRAY_VERTEX]
	var au: PackedVector2Array = aa[Mesh.ARRAY_TEX_UV]
	# 1. the far end of the arm must sample the far end of its skin region. The
	#    first two faces are the top/bottom caps, which are flat in y, so only the
	#    four side faces (vertices 8..23) can answer this.
	var tip := 8
	var shoulder := 8
	for i in range(8, av.size()):
		if av[i].y < av[tip].y:
			tip = i
		if av[i].y > av[shoulder].y:
			shoulder = i
	_check("the arm's hand band is at the far end", au[tip].y > au[shoulder].y,
		"tip v=%.3f shoulder v=%.3f" % [au[tip].y, au[shoulder].y])
	# 2. every face's four UVs must fill its skin region. A collapsed quad smears
	#    the texture along a diagonal; measured against the quad's own bounding box
	#    so the check does not care how big the region is.
	var collapsed := 0
	for g in range(0, av.size(), 4):
		var wmin := 1e9
		var wmax := -1e9
		var hmin := 1e9
		var hmax := -1e9
		for k in 4:
			wmin = minf(wmin, au[g + k].x)
			wmax = maxf(wmax, au[g + k].x)
			hmin = minf(hmin, au[g + k].y)
			hmax = maxf(hmax, au[g + k].y)
		var area := 0.0
		for k in 4:
			var a2: Vector2 = au[g + k]
			var b2: Vector2 = au[g + (k + 1) % 4]
			area += a2.x * b2.y - b2.x * a2.y
		var filled := absf(area) * 0.5
		if (wmax - wmin) <= 0.0 or (hmax - hmin) <= 0.0 \
				or filled < (wmax - wmin) * (hmax - hmin) * 0.9:
			collapsed += 1
	_check("every skin face keeps a square UV quad", collapsed == 0,
		"%d of %d faces collapsed" % [collapsed, av.size() / 4])

	# Minecraft skin import: a modern 64x64, a legacy 64x32 (which has no left arm
	# or leg and must be filled in) and an HD multiple all have to install, while
	# a wrong size is refused with a reason rather than half-applied
	var modern := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	modern.fill(Color(0.2, 0.3, 0.9))
	_check("a 64x64 Minecraft skin loads", player.model.apply_skin_image(modern) == ""
		and player.model.custom and player.model.skin_name() == "Custom")
	var legacy := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	legacy.fill(Color(0.1, 0.1, 0.1))
	for y in range(16, 32):
		for x in range(16):
			legacy.set_pixel(x, y, Color(1, 0, 0))          # right leg painted red
	_check("a legacy 64x32 skin is accepted", player.model.apply_skin_image(legacy) == "")
	var conv: Image = player.model.skin_image()
	_check("legacy skin is upgraded to 64x64", conv != null and conv.get_height() == 64,
		str(conv.get_size()) if conv != null else "none")
	_check("the missing left leg is mirrored in",
		conv.get_pixel(20, 52).r > 0.8 and conv.get_pixel(20, 52).g < 0.2,
		str(conv.get_pixel(20, 52)))
	_check("an HD 128x128 skin is accepted",
		player.model.apply_skin_image(Image.create(128, 128, false, Image.FORMAT_RGBA8)) == "")
	_check("a wrong skin size is refused with a reason",
		player.model.apply_skin_image(Image.create(37, 41, false, Image.FORMAT_RGBA8)) != "")
	_check("a missing skin file is reported",
		player.model.load_skin_file("user://definitely_not_here.png") != "")
	# and the real thing: write a PNG to disk and load it back through the same
	# entry point the settings screen uses
	var tmp := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	tmp.fill(Color(0.1, 0.8, 0.2))
	tmp.save_png("user://handtest_skin.png")
	_check("a skin PNG loads from disk", player.model.load_skin_file("user://handtest_skin.png") == ""
		and player.model.custom and player.model.skin_image().get_pixel(3, 3).g > 0.7)
	DirAccess.remove_absolute("user://handtest_skin.png")
	player.model.set_skin(0)
	_check("presets still work after a custom skin", not player.model.custom
		and player.model.skin_name() == "Steve", player.model.skin_name())

	# F5 cycles first -> third (behind) -> second (front) and wraps around. The body is
	# drawn in all three now; the only thing that changes is the head, which first person
	# has to drop because the camera sits inside it. Getting that backwards is not a
	# crash, it is a view full of the inside of your own skull, so it is asserted.
	player.hotbar[5] = {"id": Blocks.COBBLESTONE, "count": 5}
	player.hotbar_changed.emit()
	player.select_slot(5)
	player.third_person = false
	# first person drops the head and the chest but keeps the limbs: the head because the
	# camera is inside it, the chest because its flat top covers the bottom of the view as
	# soon as you look down. The limbs staying drawn is also the whole reason a shadow
	# lands on the ground now.
	_check("first person keeps the limbs and drops the head and chest",
		player.cam_mode == 0 and not player.third_person and player.model.visible
			and not player.model.head.visible and not player.model.torso.visible
			and player.model.arm_r.visible and player.model.leg_r.visible
			and player.model.held.visible,
		player.camera_mode_name())
	player.cycle_camera()
	_check("third person draws the whole body",
		player.cam_mode == 1 and player.third_person and player.model.visible
			and player.model.head.visible and player.model.torso.visible
			and player.model.held.visible,
		player.camera_mode_name())
	player.cycle_camera()
	_check("second person is a front camera on the body",
		player.cam_mode == 2 and player.third_person and player.model.visible
			and player.model.head.visible and player.model.torso.visible
			and player.model.held.visible,
		player.camera_mode_name())
	# the camera itself is turned around in front view, but aiming has to keep
	# following the player's facing or mining and placing would flip backwards
	_check("aim ignores the second-person camera flip",
		player.look_dir().dot(Vector3(0, 0, -1)) > 0.9, str(player.look_dir()))
	player.cycle_camera()
	_check("F5 wraps back to first person, head hidden again",
		player.cam_mode == 0 and not player.model.head.visible,
		player.camera_mode_name())

	# a flipped cap or an inverted tiny box is invisible by eye on a 4 pixel limb,
	# so check the geometry numerically: every face must wind outward relative to
	# its declared normal, and every normal must point away from the box centre
	var an: PackedVector3Array = aa[Mesh.ARRAY_NORMAL]
	var ai: PackedInt32Array = aa[Mesh.ARRAY_INDEX]
	var centre := Vector3.ZERO
	for v in av:
		centre += v
	centre /= float(av.size())
	var inverted := 0
	var away := 0
	for i in av.size():
		if an[i].dot(av[i] - centre) > 0.0:
			away += 1
		else:
			inverted += 1
	_check("player model normals point outward", inverted == 0,
		"%d outward, %d inward" % [away, inverted])
	var bad_wind := 0
	var total_wind := 0
	var cal: Array = _winding_counts(av, an, ai)
	bad_wind = int(cal[1])
	total_wind = int(cal[2])
	var ref: ArrayMesh = Blocks.make_block_mesh(Blocks.STONE)
	var ra: Array = ref.surface_get_arrays(0)
	var rcal: Array = _winding_counts(ra[Mesh.ARRAY_VERTEX], ra[Mesh.ARRAY_NORMAL],
		ra[Mesh.ARRAY_INDEX])
	print("  [calibration] reference cube: %s   arm box: %s" % [str(rcal), str(cal)])
	_check("player model faces wind outward", bad_wind == 0,
		"%d of %d triangles inverted" % [bad_wind, total_wind])

	# --- model animation: the head aims where you look, a crouch tips the chest
	# forward, and a swing punches the arm forward. All three were inverted once.
	var mdl = player.model
	mdl.unpin_facing()
	mdl.look_yaw = 0.0
	mdl.animate(0.016, 0.0, true, false, false, 0.0, 0.0)     # settle the facing
	mdl.animate(0.016, 0.0, true, false, false, 0.6, 0.0)
	_check("looking up tilts the head up", mdl.neck.rotation.x > 0.3,
		"neck.x=%.2f" % mdl.neck.rotation.x)
	mdl.animate(0.016, 0.0, true, false, false, -0.6, 0.0)
	_check("looking down tilts the head down", mdl.neck.rotation.x < -0.3,
		"neck.x=%.2f" % mdl.neck.rotation.x)
	# and it has to turn on the neck, not on the head box: that box's own origin sits
	# at the crown, so rotating it there swings the whole skull around its top
	_check("the head is turned at the neck, not at the crown",
		absf(mdl.head.rotation.x) < 0.001 and absf(mdl.head.rotation.y) < 0.001)

	# crouching has to lean the chest over the hips, not push the hips out front
	mdl.animate(0.016, 0.0, true, true, false, 0.0, 0.0)
	var chest: Vector3 = mdl.torso_pivot.transform * mdl.torso.position
	_check("crouching tips the chest forward over the hips",
		chest.z < -0.005 and mdl.torso_pivot.rotation.x < 0.0,
		"chest z=%.3f lean=%.2f" % [chest.z, mdl.torso_pivot.rotation.x])
	mdl.animate(0.016, 0.0, true, false, false, 0.0, 0.0)
	_check("standing back up straightens the chest",
		absf(mdl.torso_pivot.rotation.x) < 0.001)

	# the head leads and the body follows: turn the look without moving the body
	mdl.look_yaw = mdl.body_yaw + 1.0
	mdl.animate(0.016, 0.0, true, false, false, 0.0, 0.0)
	_check("the head turns toward the look before the body does",
		absf(mdl.neck.rotation.y) > 0.5 and absf(mdl.rotation.y) > 0.3,
		"neck.y=%.2f body=%.2f" % [mdl.neck.rotation.y, mdl.rotation.y])
	# and while the neck is inside its limit the head points exactly along the look
	mdl.look_yaw = mdl.body_yaw + 0.6
	mdl.animate(0.016, 0.0, true, false, false, 0.0, 0.0)
	_check("the head points along the look, not along the body",
		absf(wrapf(mdl.rotation.y + mdl.neck.rotation.y, -PI, PI)) < 0.03,
		"offset=%.3f" % (mdl.rotation.y + mdl.neck.rotation.y))
	for i in 150:
		mdl.animate(1.0 / 60.0, 0.0, true, false, false, 0.0, 0.0)
	_check("the body catches up and the neck unwinds", absf(mdl.neck.rotation.y) < 0.05,
		"neck.y=%.2f" % mdl.neck.rotation.y)

	mdl.animate(0.016, 0.0, true, false, false, 0.0, 0.9)
	_check("a mining swing punches the arm forward", mdl.arm_r.rotation.x > 0.8,
		"arm_r.x=%.2f" % mdl.arm_r.rotation.x)

	# flying: the arms have to splay OUTWARD. An arm hangs below its shoulder pivot,
	# so the two arms need *opposite* Z signs to both open outward; giving them the
	# same sign folds both hands across the body's midline, which is exactly what the
	# flying pose used to do. Measured in the shoulder's own frame, so the body's
	# facing cannot flip the answer, and as a position rather than a rotation, so it
	# does not just restate the sign convention it is testing.
	mdl.animate(0.016, 0.0, false, false, true, 0.0, 0.0)
	var arm_probe := Vector3(0, -0.5, 0)      # a point partway down an arm
	var hand_r: Vector3 = mdl.arm_r.transform * arm_probe
	var hand_l: Vector3 = mdl.arm_l.transform * arm_probe
	var sh_r: Vector3 = mdl.arm_r.position
	var sh_l: Vector3 = mdl.arm_l.position
	_check("flying arms splay outward, not inward",
		hand_r.x > sh_r.x + 0.05 and hand_l.x < sh_l.x - 0.05,
		"right %.2f->%.2f left %.2f->%.2f" % [sh_r.x, hand_r.x, sh_l.x, hand_l.x])

	mdl.animate(0.016, 0.0, false, false, false, 0.0, 0.0)
	mdl.unpin_facing()

	# --- the crack overlay. It has to be centred on the face you are mining, which
	# needs two things: a BoxMesh that maps the texture across each face, and a
	# texture whose damage radiates out from its middle.
	var crack_uv: Array = crack.mesh.surface_get_arrays(0)
	var cuv: PackedVector2Array = crack_uv[Mesh.ARRAY_TEX_UV]
	var faces_ok := true
	var spans := ""
	for g in range(0, cuv.size(), 4):
		var u0 := 9.0
		var u1 := -9.0
		var v0 := 9.0
		var v1 := -9.0
		for k in 4:
			u0 = minf(u0, cuv[g + k].x)
			u1 = maxf(u1, cuv[g + k].x)
			v0 = minf(v0, cuv[g + k].y)
			v1 = maxf(v1, cuv[g + k].y)
		spans += "%.2fx%.2f " % [u1 - u0, v1 - v0]
		if absf(u1 - u0 - 1.0) > 0.01 or absf(v1 - v0 - 1.0) > 0.01 \
				or absf(u0) > 0.01 or absf(v0) > 0.01:
			faces_ok = false
	_check("the crack texture covers each block face once", faces_ok, spans)
	# the last stage must be darkest at its centre, since that is where it breaks from
	var late: Image = Art.crack_overlay(4)
	var mid: float = late.get_pixel(8, 8).a
	var corner: float = late.get_pixel(0, 0).a
	var outward := 0
	for yy in 16:
		for xx in 16:
			if Vector2(float(xx) - 7.5, float(yy) - 7.5).length() > 3.0 \
					and late.get_pixel(xx, yy).a > 0.2:
				outward += 1
	_check("the crack springs from the centre outward", mid > 0.9 and corner < 0.2
		and outward >= 8, "centre=%.2f corner=%.2f outward=%d px" % [mid, corner, outward])

	# --- a block placed while a section's mesh job is still in flight must not be lost.
	# The job lands and clears the section, so the section needs a revision to tell
	# "finished" from "finished, but stale". Getting this wrong looks like glass not
	# appearing until you place some other block.
	var rc := Vector2i(0, 0)
	var rsec := VoxelTerrain.sec_of(VoxelTerrain.SEA - 3)
	world.chunks[rc] = _make_ocean_chunk(true)
	var rch: Dictionary = world.chunks[rc]
	world._mark_dirty(rc, rsec)
	var stale_srev: int = int(rch["srev"][rsec])
	world._mark_dirty(rc, rsec)
	world._attach_mesh({"c": rc, "sec": rsec, "solid": world.new_buf(),
		"extra": world.new_buf(), "trans": world.new_buf(), "cross": world.new_buf(),
		"srev": stale_srev})
	_check("an edit made mid-job keeps the section dirty", rch["dirty"].has(rsec),
		"srev %d vs section srev %d" % [stale_srev, int(rch["srev"][rsec])])
	world._attach_mesh({"c": rc, "sec": rsec, "solid": world.new_buf(),
		"extra": world.new_buf(), "trans": world.new_buf(), "cross": world.new_buf(),
		"srev": int(rch["srev"][rsec])})
	_check("a clean job does finish the section", not rch["dirty"].has(rsec))
	world.chunks.erase(rc)

	# --- a result is published by the worker *before* the pool reports the task
	# completed, so the drain can attach it while its own key is still in `_jobs`. The
	# attach then sees a job in flight and leaves the chunk unfinished; the key leaves
	# `_jobs` on a later frame with no result left to attach it. Nothing would ever set
	# that chunk done again -- which is a loader stuck at 120 of 121 chunks, not 121.
	# The semaphore holds the task in flight so the window is hit every single time.
	world.chunks[rc] = _mk_chunk([[Vector3i(8, 16, 8), Blocks.STONE]])
	var hch: Dictionary = world.chunks[rc]
	var hsec := VoxelTerrain.sec_of(16)
	world._mark_dirty(rc, hsec)
	var hkey := Vector3i(rc.x, hsec, rc.y)
	var gate := Semaphore.new()
	world._jobs[hkey] = WorkerThreadPool.add_task(_hold_until.bind(gate), true, "test-held")
	world._results.append({"c": rc, "sec": hsec, "solid": world.new_buf(),
		"extra": world.new_buf(), "trans": world.new_buf(), "cross": world.new_buf(),
		"srev": int(hch["srev"][hsec])})
	world._drain_results()
	_check("a result that lands while its own task is still in flight leaves the chunk open",
		hch["dirty"].is_empty() and not bool(hch["meshed"]),
		"dirty=%s meshed=%s" % [str(hch["dirty"].keys()), str(hch["meshed"])])
	gate.post()
	# released, then waited on with `is_task_completed` alone: `wait_for_task_completion`
	# retires the id, and the drain has to be the one to retire it here
	var spin := 0
	while not WorkerThreadPool.is_task_completed(world._jobs[hkey]) and spin < 500:
		OS.delay_msec(2)
		spin += 1
	world._drain_results()
	_check("dropping that task's key then finishes the chunk off", bool(hch["meshed"]),
		"dirty=%s meshed=%s" % [str(hch["dirty"].keys()), str(hch["meshed"])])
	world._jobs.erase(hkey)
	world._results.clear()
	world.chunks.erase(rc)

	# --- section boundaries. A job is one 16-tall box now, so whether a face at the
	# top or bottom of that box is drawn depends on a block living in the *next* box.
	# Both halves of this are easy to get wrong in opposite directions: miss the
	# neighbour and every layer boundary grows a duplicate pair of faces; read the
	# neighbour wrong and a real face is culled away, leaving a hole.
	var stacked := Vector3i(8, 31, 8)
	var above := Vector3i(8, 32, 8)
	world.chunks[rc] = _mk_chunk([[stacked, Blocks.STONE], [above, Blocks.STONE]])
	var s_lo := _mesh_probe(world.chunks[rc], 1)
	var s_hi := _mesh_probe(world.chunks[rc], 2)
	# two separate cubes are 24 vertices each; stacked, the touching faces go and each
	# keeps 5 faces, so 40 is the correct total and 48 means both were drawn
	_check("a face against the section above is culled on both sides",
		_buf_verts(s_lo.get("solid", null)) + _buf_verts(s_hi.get("solid", null)) == 40,
		"%d + %d verts; 48 would mean the boundary faces were drawn twice"
			% [_buf_verts(s_lo.get("solid", null)), _buf_verts(s_hi.get("solid", null))])
	world.chunks.erase(rc)

	# --- and a write at the very bottom of a section has to re-mesh the section under
	# it, or that section keeps a stale face where the new block now sits
	var dirt := _mk_chunk([])
	world.chunks[rc] = dirt
	world.apply_edit(Vector3i(8, 16, 8), Blocks.STONE, false)
	var s16 := VoxelTerrain.sec_of(16)
	_check("a write on a section's bottom layer dirties the section below",
		dirt["dirty"].has(s16) and dirt["dirty"].has(s16 - 1),
		"dirty=%s" % str(dirt["dirty"].keys()))
	# ...and across a chunk corner it reaches the diagonal too, because ambient occlusion
	# samples the corners: up to 8 sections over 4 chunks for one block
	world.chunks[Vector2i(-1, -1)] = _mk_chunk([])
	world.chunks[Vector2i(-1, 0)] = _mk_chunk([])
	world.chunks[Vector2i(0, -1)] = _mk_chunk([])
	world.apply_edit(Vector3i(0, 0, 0), Blocks.STONE, false)
	var corners := 0
	for cc in [Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(0, 0)]:
		if not world.chunks[cc]["dirty"].is_empty():
			corners += 1
	_check("a block on a chunk corner dirties the diagonal neighbours too", corners == 4,
		"%d of 4 chunks dirtied" % corners)
	for cc in [Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(0, 0)]:
		world.chunks.erase(cc)

	# --- the ceiling is 320 now, and the sky is free: a section is allocated the first
	# time something is put in it, so a block at y=200 costs one section while the
	# hundreds of layers of empty air beneath it cost nothing at all
	world.chunks[rc] = _mk_chunk([])
	var sky_placed: bool = world.set_block(3, 200, 4, Blocks.STONE)
	_check("a block can be placed far above the old ceiling",
		sky_placed and world.get_block(3, 200, 4) == Blocks.STONE,
		"placed=%s read=%d" % [str(sky_placed), world.get_block(3, 200, 4)])
	_check("and only its own section gets allocated",
		world.chunks[rc]["sections"].has(VoxelTerrain.sec_of(200))
			and world.chunks[rc]["sections"].size() == 1,
		"sections=%s" % str(world.chunks[rc]["sections"].keys()))
	_check("a block above the ceiling is refused",
		not world.set_block(3, VoxelTerrain.MAX_Y, 4, Blocks.STONE))
	world.chunks.erase(rc)

	# --- the floor is at MIN_Y now and the rock under the caves is real, mineable stone.
	# Checked against a generated chunk rather than a fixture, because the claim is about
	# what the generator actually writes: bedrock across the floor, and a solid block of
	# stone above it that the buried-section skip can then recognise.
	var gen := VoxelTerrain.new(1337)
	var deep: Dictionary = gen.fill_chunk(0, 0)
	var deep_secs: Dictionary = deep["sections"]
	var floor_sec: int = VoxelTerrain.sec_of(VoxelTerrain.MIN_Y)
	_check("the generator fills from the world floor upward",
		deep_secs.has(floor_sec) and deep_secs.has(floor_sec + 3),
		"sections=%s" % str(deep_secs.keys()))
	var bed := 0
	for i in VoxelTerrain.CHUNK * VoxelTerrain.CHUNK:
		if deep_secs[floor_sec][i] == Blocks.BEDROCK:
			bed += 1
	_check("the world floor is bedrock right across", bed == 256, "%d of 256" % bed)
	var per := VoxelTerrain.SEC * VoxelTerrain.CHUNK * VoxelTerrain.CHUNK
	var cave_sec: int = VoxelTerrain.sec_of(VoxelTerrain.CAVE_FLOOR)
	var solid_deep := true
	for s in range(floor_sec, cave_sec):
		solid_deep = solid_deep and int(deep["occ"][s]) == per
	_check("the rock from the floor up to the cave floor is solid through and through",
		solid_deep, "occ=%s" % str(deep["occ"]))
	# ...and the caves really are carved from there upward, or the assertion above would
	# be vacuous -- it would pass just as well on a world with no caves at all
	_check("while the cave band above it is carved out",
		int(deep["occ"][cave_sec]) < per,
		"occ[%d]=%d" % [cave_sec, int(deep["occ"][cave_sec])])
	# the deep band has to carry ore of its own, or extending the world down would have
	# bought a bigger volume to mine through and nothing in it
	var ores := [Blocks.DIAMOND_ORE, Blocks.GOLD_ORE, Blocks.IRON_ORE, Blocks.COPPER_ORE,
		Blocks.COAL_ORE]
	var ore_below := 0
	for s in range(floor_sec, 0):
		if not deep_secs.has(s):
			continue
		var arr: PackedByteArray = deep_secs[s]
		for i in per:
			if ores.has(arr[i]):
				ore_below += 1
	_check("the deep band carries its own ore", ore_below > 0,
		"%d ore cells below y=0" % ore_below)
	# and the shallow bands must be exactly what they were, which is what stops the deep
	# band from having moved the surface world a block: same absolute thresholds, same
	# `v %` gates, and the copper override applied last
	_check("the shallow ore bands still map the way they always did",
		gen._ore_at(10, 0) == Blocks.DIAMOND_ORE and gen._ore_at(10, 2) == Blocks.GOLD_ORE
			and gen._ore_at(35, 2) == Blocks.IRON_ORE and gen._ore_at(60, 2) == Blocks.COAL_ORE
			and gen._ore_at(10, 1) == Blocks.COPPER_ORE,
		"10/0=%d 10/2=%d 35/2=%d 60/2=%d 10/1=%d" % [gen._ore_at(10, 0),
			gen._ore_at(10, 2), gen._ore_at(35, 2), gen._ore_at(60, 2), gen._ore_at(10, 1)])
	# the deep bands, as a readable spec: the deeper it is the better the ore, and the
	# `v %` gate is what keeps diamonds rare inside their own band
	_check("and the deep bands grade by depth",
		gen._ore_at(-50, 0) == Blocks.DIAMOND_ORE and gen._ore_at(-50, 1) == Blocks.GOLD_ORE
			and gen._ore_at(-30, 3) == Blocks.GOLD_ORE and gen._ore_at(-30, 2) == Blocks.IRON_ORE
			and gen._ore_at(-20, 0) == Blocks.IRON_ORE
			and gen._ore_at(-8, 0) == Blocks.COPPER_ORE,
		"-50/0=%d -50/1=%d -30/3=%d -30/2=%d -20/0=%d -8/0=%d" % [gen._ore_at(-50, 0),
			gen._ore_at(-50, 1), gen._ore_at(-30, 3), gen._ore_at(-30, 2),
			gen._ore_at(-20, 0), gen._ore_at(-8, 0)])
	world.chunks[rc] = world.new_chunk(deep_secs, deep["occ"])
	_check("a block can be mined out of the deep stone",
		world.set_block(3, VoxelTerrain.MIN_Y + 20, 4, Blocks.AIR)
			and world.get_block(3, VoxelTerrain.MIN_Y + 20, 4) == Blocks.AIR,
		"read=%d" % world.get_block(3, VoxelTerrain.MIN_Y + 20, 4))
	_check("a block below the world floor is refused",
		not world.set_block(3, VoxelTerrain.MIN_Y - 1, 4, Blocks.STONE))
	world.chunks.erase(rc)

	# --- a section that is solid through and through, inside solid neighbours on all six
	# sides, has no face a job could ever draw. It has to be recognised and finished on
	# the spot -- not queued and not scanned -- because that is what pays for a deep
	# world: otherwise every rebuild scans 4096 cells per solid section to build an empty
	# mesh. The count it is judged on also has to survive an edit, since filling a cave
	# in has to bury it and digging into one has to bring it back.
	var solid_ring: Array = [Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1),
		Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(1, 1)]
	var saved_center: Vector2i = world._center
	world._center = Vector2i(0, 0)
	for off in solid_ring:
		world.chunks[Vector2i(off.x, off.y)] = _filled_sections([1])
	world.chunks[Vector2i(0, 0)] = _filled_sections([0, 1, 2])
	_check("a solid section inside solid neighbours counts as buried",
		world._is_buried(Vector2i(0, 0), 1))
	_check("a neighbour that is missing un-buries it",
		not world._is_buried(Vector2i(-1, 0), 0),
		"a section the generator never made is air, so its neighbours are exposed")
	# a face is culled against the block on the far side, so the section above matters too
	world.chunks[Vector2i(0, 0)]["occ"][2] = 0
	_check("a section above that is not solid un-buries it", not world._is_buried(Vector2i(0, 0), 1))
	world.chunks[Vector2i(0, 0)]["occ"][2] = VoxelTerrain.CHUNK * VoxelTerrain.CHUNK \
		* VoxelTerrain.SEC
	# and an edit has to move that count, or a wall filled in never meshes and a block dug
	# out of one never comes back
	world.apply_edit(Vector3i(8, 20, 8), Blocks.AIR, false)
	_check("digging a block out of a solid section un-buries it",
		not world._is_buried(Vector2i(0, 0), 1),
		"occ=%d" % world._sec_occ(world.chunks[Vector2i(0, 0)], 1))
	world.apply_edit(Vector3i(8, 20, 8), Blocks.STONE, false)
	world._mark_dirty(Vector2i(0, 0), 1)
	world._submit_jobs(Vector3(8.0, 24.0, 8.0))
	_check("a buried section is finished with no job and no scan",
		not world.chunks[Vector2i(0, 0)]["dirty"].has(1) and world._jobs.is_empty()
			and bool(world.chunks[Vector2i(0, 0)]["meshed"]),
		"dirty=%s jobs=%d meshed=%s" % [str(world.chunks[Vector2i(0, 0)]["dirty"].keys()),
			world._jobs.size(), str(world.chunks[Vector2i(0, 0)]["meshed"])])
	for off in solid_ring:
		world.chunks.erase(Vector2i(off.x, off.y))
	world.chunks.erase(Vector2i(0, 0))
	world._center = saved_center

	# --- the world-authority seam: every *requested* change has to reach the
	# authority and come back applied. This is the hook multiplayer hangs prediction
	# and broadcast off, so it has to be real and observable in single player first.
	var seam_blocks := _mk_chunk([])
	world.chunks[Vector2i(0, 0)] = seam_blocks
	var auth := _RecordingAuthority.new()
	var default_auth = world.authority
	world.authority = auth
	var seam_placed: bool = world.set_block(3, 12, 4, Blocks.GLASS)
	_check("a block change is requested through the world authority",
		auth.requests == 1 and auth.applied == 1,
		"requests=%d applied=%d" % [auth.requests, auth.applied])
	_check("the authority's change actually lands",
		seam_placed and world.get_block(3, 12, 4) == Blocks.GLASS)

	# a plant sitting on top of a broken block is a *consequence* of that one edit, so
	# it must be applied with it rather than sent as a second request
	world.apply_edit(Vector3i(6, 13, 6), Blocks.TALL_GRASS, false)
	world.apply_edit(Vector3i(6, 12, 6), Blocks.STONE, false)
	auth.requests = 0
	auth.applied = 0
	world.set_block(6, 12, 6, Blocks.AIR)
	_check("breaking a block takes the plant above it in the same request",
		auth.requests == 1 and world.get_block(6, 13, 6) == Blocks.AIR,
		"requests=%d" % auth.requests)
	# nothing to change = no request at all, so a no-op never hits the network
	auth.requests = 0
	world.set_block(3, 12, 4, Blocks.GLASS)
	_check("re-placing the same block sends no request", auth.requests == 0,
		"requests=%d" % auth.requests)
	world.authority = default_auth
	world.chunks.erase(Vector2i(0, 0))

	# the hunger bar is mirrored, so a half drumstick fills from the right
	var fl := _half_food_lit(Art.tex_food_full.get_image())
	var fh := _half_food_lit(Art.tex_food_half.get_image())
	_check("the half drumstick fills from the right side", fh[0] == 0 and fh[1] > 3,
		"half left=%d right=%d" % [fh[0], fh[1]])
	_check("the full drumstick is filled on both sides", fl[0] > 3 and fl[1] > 3,
		"full left=%d right=%d" % [fl[0], fl[1]])
	# ...and the bar as a whole is mirrored: icon 0 is the rightmost and holds the
	# full ones, so hunger drains away from the left, as Minecraft's does
	player.creative = false
	player.hunger = 11.0
	hud.refresh_hunger()
	_check("the hunger bar fills from the right",
		hud.foods[0].position.x > hud.foods[9].position.x
			and hud.foods[0].texture == Art.tex_food_full
			and hud.foods[5].texture == Art.tex_food_half
			and hud.foods[9].texture == Art.tex_food_empty,
		"x0=%.0f x9=%.0f" % [hud.foods[0].position.x, hud.foods[9].position.x])
	player.creative = true
	player.hunger = 20.0
	hud.refresh_hunger()

	# dropped items: the manager must hand the stack over and retire the entity
	item_entities.reset()
	player.reset_inventory()
	item_entities.drop(Blocks.COBBLESTONE, 3, player.global_position + Vector3(0.3, 0, 0))
	_check("dropping an item creates an entity", item_entities.count() == 1)
	for i in 90:
		var it = item_entities.items[0] if item_entities.count() > 0 else null
		var where: Vector3 = it.global_position if it != null else player.global_position
		item_entities.update(where, 1.0 / 60.0)
		if item_entities.count() == 0:
			break
	_check("walking over the drop collects it", _inventory_has(Blocks.COBBLESTONE))
	_check("collected drop removes the entity", item_entities.count() == 0)
	item_entities.reset()

	# A chunk of nothing but water above its seabed must still mesh. The occluder
	# heightmap stops at the seabed, so a mesher that trusts it emits no water faces
	# out at sea and the ocean renders as a hole — only the shore chunks, whose map
	# reaches above sea level, show water at all.
	var ocean := _make_ocean_chunk(false)
	var probe := _mesh_probe(ocean, VoxelTerrain.sec_of(VoxelTerrain.SEA - 3))
	var trans = probe.get("trans", null)
	_check("a pure ocean chunk meshes its water surface", trans != null and not trans.empty(),
		"%d verts" % (trans.v.size() if trans != null else 0))
	var solid_buf = probe.get("solid", null)
	_check("the same chunk still meshes its seabed", solid_buf != null and not solid_buf.empty(),
		"%d verts" % (solid_buf.v.size() if solid_buf != null else 0))

	# The scan bound must count every block, not just occluders. A glass column and a
	# leaf platform stacked above a stone slab produce no occluders above the slab, so
	# a bound built from the occluder heightmap skips them and they render as air --
	# the "glass is invisible until I place another block" report. Assert numerically:
	# a small screenshot of a transparent block is exactly the kind of thing that
	# looks fine while being wrong.
	#
	# The tower deliberately straddles a section border (the glass top and the leaves
	# are in the section above the slab's), so this also covers a mesh that has to read
	# the section above it -- and the glass appears in *both* sections' buffers, which
	# is what makes a seam here obvious.
	var tower := _make_tower_chunk()
	var tsec := VoxelTerrain.sec_of(TOWER_SLAB)
	var tp := _mesh_probe(tower, tsec)
	var tp_up := _mesh_probe(tower, tsec + 1)
	var tv = tp.get("trans", null)
	var tv_up = tp_up.get("trans", null)
	var te = tp_up.get("extra", null)
	var glass_top := maxf(_buf_max_y(tv, tsec), _buf_max_y(tv_up, tsec + 1))
	# The slab is the last occluder, the glass spans slab+1..slab+8 so a complete mesh
	# reaches a vertex at slab+9, and the leaves at slab+10 reach slab+11. Under the old
	# `max(occluder_top + 1, SEA)` bound the scan stopped one block above the slab, so
	# these thresholds -- not "is the buffer non-empty" -- are what actually catch it.
	_check("glass above the last solid block meshes all the way up",
		glass_top >= float(TOWER_SLAB + 9), "max y=%.1f" % glass_top)
	_check("leaves above the last solid block still mesh",
		te != null and not te.empty() and _buf_max_y(te, tsec + 1) >= float(TOWER_LEAF_Y + 1),
		"%d verts, max y=%.1f" % [te.v.size() if te != null else 0,
			_buf_max_y(te, tsec + 1)])
	# and the bound really could not have come from the occluder heightmap: that stops
	# one block above the slab, while the sections carry the tower anyway
	var slab_col: int = world._build_hmap(tower["sections"])[8 + 8 * VoxelTerrain.CHUNK]
	_check("the scan bound cannot come from the occluder heightmap",
		slab_col == TOWER_SLAB + 1
			and tower["sections"].has(VoxelTerrain.sec_of(TOWER_LEAF_Y)),
		"hmap=%d sections=%d" % [slab_col, tower["sections"].size()])

	# The swing clock has to keep running whatever camera you are in, or the model's
	# arm stands still while you mine in third person.
	player.creative = true
	player.dead = false
	player.health = 20.0
	player.set_input_enabled(true)
	player.swing_t = 1.0
	player.swing = 0.0
	player.cam_mode = 1
	for i in 6:
		await get_tree().physics_frame
	var third_swing: float = player.swing
	player.swing_t = 1.0
	player.swing = 0.0
	player.cam_mode = 0
	for i in 6:
		await get_tree().physics_frame
	_check("the swing clock runs in third person as well as first",
		third_swing > 0.2 and player.swing > 0.2,
		"third=%.2f first=%.2f" % [third_swing, player.swing])

	# Vertical controls must not be inverted, in flight or in water.
	var sea := VoxelTerrain.SEA
	player.flying = true
	player.dead = false
	player.health = 20.0
	player.set_input_enabled(true)
	player.velocity = Vector3.ZERO
	Input.action_press("jump")
	for i in 12:
		await get_tree().physics_frame
	_check("Space flies upward", player.velocity.y > 1.0, "vy=%.2f" % player.velocity.y)
	Input.action_release("jump")
	Input.action_press("sneak")
	for i in 24:
		await get_tree().physics_frame
	_check("Shift flies downward", player.velocity.y < -1.0, "vy=%.2f" % player.velocity.y)
	Input.action_release("sneak")
	player.flying = false
	player.creative = false

	# Swapping in the ocean lets the swim code run against real voxels.
	var coast := _make_ocean_chunk(true)
	world.chunks[Vector2i(0, 0)] = coast
	player.place_at(Vector3(4.5, float(sea - 3), 8.5))
	for i in 6:
		await get_tree().physics_frame
	Input.action_press("jump")
	for i in 10:
		await get_tree().physics_frame
	_check("Space swims upward under water", player.velocity.y > 1.0,
		"vy=%.2f" % player.velocity.y)
	Input.action_release("jump")
	Input.action_press("sneak")
	for i in 12:
		await get_tree().physics_frame
	_check("Shift dives downward under water", player.velocity.y < -1.0,
		"vy=%.2f" % player.velocity.y)
	Input.action_release("sneak")

	# ...and then climb out: swim at the surface toward the bank holding Space. The
	# bank stands one block above the water, so this only works if the surface hop
	# is stronger than an ordinary jump.
	player.place_at(Vector3(7.0, float(sea - 1), 8.5))
	player.yaw = -PI * 0.5            # forward is +x, toward the bank
	player.velocity = Vector3.ZERO
	for i in 6:
		await get_tree().physics_frame
	Input.action_press("forward")
	Input.action_press("jump")
	var escaped := false
	for i in 260:
		await get_tree().physics_frame
		if player.on_ground and player.global_position.y >= float(sea + 1):
			escaped = true
			break
	Input.action_release("forward")
	Input.action_release("jump")
	_check("holding forward + Space climbs out onto the bank", escaped,
		"pos=(%.2f, %.2f, %.2f) on_ground=%s" % [player.global_position.x,
			player.global_position.y, player.global_position.z, str(player.on_ground)])

	# ---- the world list has to follow the number of saves
	# A fixed-height panel left a big empty box behind one save and cut the list off
	# at five, so the panel is measured from the rows it holds. The list is forced to
	# a known size first -- open_screen() refreshes it from whatever real saves are
	# on disk, which would otherwise dwarf the measurement.
	ui.open_screen("worlds")
	for ch in ui._world_list.get_children():
		ui._world_list.remove_child(ch)
		ch.queue_free()
	ui._fit_world_panel()
	var panel_empty: float = ui._world_panel.size.y
	for i in 3:
		var wrow := HBoxContainer.new()
		ui._world_list.add_child(wrow)
		var wb := Button.new()
		wb.custom_minimum_size = Vector2(380, 46)
		wrow.add_child(wb)
	ui._fit_world_panel()
	var panel_three: float = ui._world_panel.size.y
	_check("the world list panel grows with the number of saves",
		panel_three > panel_empty + 100.0,
		"none=%.0f three=%.0f" % [panel_empty, panel_three])
	for ch in ui._world_list.get_children():
		ui._world_list.remove_child(ch)
		ch.queue_free()
	ui._fit_world_panel()
	_check("and shrinks again when the saves go away",
		ui._world_panel.size.y < panel_three - 100.0,
		"three=%.0f none=%.0f" % [panel_three, ui._world_panel.size.y])
	ui.open_screen("title")

	# ---- creative mining is one swing per block. The dig loop used to break a block
	# on *every* frame the button was held, so a single click tunnelled through the
	# terrain: the block aimed at, then whatever stood behind it, and so on down the
	# line. The column here is deeper than one click can reach, so the count of blocks
	# taken measures the swing clock and nothing else.
	_build_dig_rig()
	var dig_before := _dig_column()
	var was_creative: bool = player.creative
	player.creative = true
	player.dead = false
	player.health = 20.0
	player.set_input_enabled(true)
	player.velocity = Vector3.ZERO
	player.place_at(Vector3(3.5, 21.0, 2.5))
	player.yaw = -PI * 0.5      # face +X, straight at the column
	player.pitch = 0.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_press("attack")
	for i in 10:
		await get_tree().physics_frame
	Input.action_release("attack")
	for i in 20:
		await get_tree().physics_frame
	var dig_gone := dig_before - _dig_column()
	_check("one creative click does not tunnel through the terrain", dig_gone <= 2,
		"%d blocks taken by one 10-frame click" % dig_gone)
	_check("but that click does break the block it aimed at", dig_gone >= 1,
		"gone=%d" % dig_gone)
	world.chunks.erase(Vector2i(0, 0))
	player.creative = was_creative
	player.place_at(Vector3(0.0, 40.0, 0.0))

	# ---- the power layer: a switch -> wire -> lamp loop, solved for real
	# This is the headline feature, so it is checked as a circuit and not as a set of
	# block ids: close the supply, require the wire to carry a decaying level, require
	# the load to switch, then open the switch and require it all to go dark again.
	_build_power_rig()
	var cw = world.circuit
	_check("placing a switch registers it with the solver", cw.nodes.has(_pw_switch))
	_check("every part of the rig is registered", cw.nodes.size() == 9,
		"n=%d inverter=%s" % [cw.nodes.size(), str(cw.nodes.has(_pw_inverter))])
	_check("a circuit with the switch open is dead", cw.level_at(_pw_lamp) == 0,
		"lamp=%d" % cw.level_at(_pw_lamp))
	# close the switch, exactly the way a right-click does
	world.set_place_look(Vector3(1, 0, 0))
	cw.interact(_pw_switch, Blocks.SWITCH)
	for i in 4:
		cw.update(0.016)
	_check("closing the switch powers the wire", cw.level_at(_pw_wire1) > 0,
		"wire=%d power=%d switch=%s" % [cw.level_at(_pw_wire1), cw.power.size(),
			str(cw.get_state(_pw_switch).get("on", false))])
	_check("the wire decays with distance, like a real line",
		cw.level_at(_pw_wire1) > cw.level_at(_pw_wire2)
			and cw.level_at(_pw_wire2) > cw.level_at(_pw_wire3),
		"%d > %d > %d" % [cw.level_at(_pw_wire1), cw.level_at(_pw_wire2),
			cw.level_at(_pw_wire3)])
	_check("the lamp lights when its input goes high", cw.level_at(_pw_lamp) > 0,
		"lamp=%d" % cw.level_at(_pw_lamp))
	_check("the lit lamp emits light",
		world.tile_override.get(_pw_lamp, -1) == Blocks.T_LAMP_ON,
		"tile=%d" % int(world.tile_override.get(_pw_lamp, -1)))

	# open it again: the whole run must go dark, including the lamp
	cw.interact(_pw_switch, Blocks.SWITCH)
	for i in 4:
		cw.update(0.016)
	_check("opening the switch drops the whole line", cw.level_at(_pw_wire3) == 0
		and cw.level_at(_pw_lamp) == 0,
		"wire3=%d lamp=%d" % [cw.level_at(_pw_wire3), cw.level_at(_pw_lamp)])
	_check("the lamp goes dark again",
		world.tile_override.get(_pw_lamp, -1) == Blocks.T_LAMP_OFF,
		"tile=%d" % int(world.tile_override.get(_pw_lamp, -1)))

	# A signal dies out after 15 blocks of wire, so a long line is not a free bus.
	# This one runs the full 16 cells of the chunk: the levels go 15, 14, ... 0.
	var line_lever := Vector3i(8, _pw_switch.y, 0)
	var line_near := Vector3i(9, _pw_switch.y, 1)
	var line_far := Vector3i(9, _pw_switch.y, 15)
	world.set_block(line_lever.x, line_lever.y, line_lever.z, Blocks.SWITCH, false)
	for z in 16:
		world.set_block(9, _pw_switch.y, z, Blocks.WIRE, false)
	cw.register(line_lever, Blocks.SWITCH)
	cw.interact(line_lever, Blocks.SWITCH)
	for i in 24:
		cw.update(0.016)
	_check("a wire run longer than 15 blocks carries nothing", cw.level_at(line_far) == 0,
		"far=%d near=%d" % [cw.level_at(line_far), cw.level_at(line_near)])
	_check("and the near end of that run is still nearly full strength",
		cw.level_at(line_near) >= 13, "near=%d" % cw.level_at(line_near))
	cw.interact(line_lever, Blocks.SWITCH)
	for i in 3:
		cw.update(0.016)

	# An inverter is a NOT gate: its output is live while its input is dead, and dark
	# when the input is driven. The input comes in from the side, because the inverter
	# stands on the block it reads -- pulling that block out would remove it too.
	var tin := _pw_inverter + Vector3i(1, 0, 0)
	world.set_block(tin.x, tin.y, tin.z, Blocks.BATTERY, false)
	cw.register(_pw_inverter, Blocks.INVERTER)
	for i in 4:
		cw.update(0.016)
	_check("an inverter is a NOT gate: a driven input turns its output off",
		not bool(cw.get_state(_pw_inverter).get("lit", true)),
		"lit=%s" % str(cw.get_state(_pw_inverter).get("lit", true)))
	world.set_block(tin.x, tin.y, tin.z, Blocks.AIR, false)
	for i in 4:
		cw.update(0.016)
	_check("and its output comes back when the input goes away",
		bool(cw.get_state(_pw_inverter).get("lit", false)),
		"lit=%s side=%d" % [str(cw.get_state(_pw_inverter).get("lit", false)),
			int(cw.power.get(tin, 0))])

	# A relay is a diode with a delay: it takes the input and re-drives it at full
	# strength after a couple of ticks, and it only passes signal one way
	var rin := _pw_relay - Vector3i(0, 0, 1)
	world.set_block(rin.x, rin.y, rin.z, Blocks.BATTERY, false)
	cw.register(_pw_relay, Blocks.RELAY)
	cw.state[_pw_relay]["facing"] = Vector3i(0, 0, 1)
	for i in 3:
		cw.update(0.016)
	_check("a relay takes a moment before it passes signal on",
		int(cw.power.get(_pw_relay, 0)) == 0,
		"out=%d delay=%.2f" % [int(cw.power.get(_pw_relay, 0)),
			float(cw.get_state(_pw_relay).get("delay", 0.0))])
	for i in 20:
		cw.update(0.016)
	_check("and then re-drives it at full strength",
		int(cw.power.get(_pw_relay, 0)) > 0,
		"out=%d" % int(cw.power.get(_pw_relay, 0)))

	# a piston is an actuator: powered, it shoves the block in front one cell on
	var pblock := _pw_piston + _pw_facing
	var pbeyond := pblock + _pw_facing
	world.set_block(pblock.x, pblock.y, pblock.z, Blocks.PLANKS, false)
	world.set_block(pbeyond.x, pbeyond.y, pbeyond.z, Blocks.AIR, false)
	cw.register(_pw_piston, Blocks.PISTON)
	cw.state[_pw_piston]["facing"] = _pw_facing
	cw.set_plate(_pw_plate, true)
	for i in 4:
		cw.update(0.016)
	_check("a pressure plate drives the piston",
		world.get_block(pbeyond.x, pbeyond.y, pbeyond.z) == Blocks.PLANKS,
		"beyond=%s" % Blocks.display_name(
			world.get_block(pbeyond.x, pbeyond.y, pbeyond.z)))
	cw.set_plate(_pw_plate, false)
	for i in 6:
		cw.update(0.016)
	_check("releasing the plate retracts the piston and puts the block back",
		world.get_block(pbeyond.x, pbeyond.y, pbeyond.z) == Blocks.AIR
			and world.get_block(pblock.x, pblock.y, pblock.z) == Blocks.PLANKS,
		"beyond=%s front=%s" % [
			Blocks.display_name(world.get_block(pbeyond.x, pbeyond.y, pbeyond.z)),
			Blocks.display_name(world.get_block(pblock.x, pblock.y, pblock.z))])

	# and the whole thing round-trips through the save format
	var cbuf: PackedByteArray = cw.serialize()
	_check("circuit state serializes", cbuf.size() > 4, "%d bytes" % cbuf.size())
	var saved_nodes: int = cw.nodes.size()
	cw.clear()
	_check("clearing wipes the solver", cw.nodes.is_empty() and cw.power.is_empty())
	cw.load_state(cbuf)
	_check("and it loads back", cw.nodes.size() == saved_nodes,
		"%d vs %d" % [cw.nodes.size(), saved_nodes])
	_teardown_power_rig()

	# ---- the crafting panel's hint list. It is generated from the recipe table, so
	# it must describe every recipe the matcher accepts -- the hand-written list it
	# replaced silently stopped at four.
	var hints: Array = player.recipe_lines()
	var hint_text := "\n".join(hints)
	_check("the crafting hint lists one line per recipe", hints.size() == player.RECIPES.size(),
		"%d lines for %d recipes" % [hints.size(), player.RECIPES.size()])
	# compared against the names the UI would actually show, so the check does not
	# depend on which language happens to be active
	_check("and it names the new power parts",
		hint_text.contains(Items.name_of(Blocks.RELAY))
			and hint_text.contains(Items.name_of(Blocks.PISTON))
			and hint_text.contains(Items.name_of(Blocks.INVERTER)),
		"n=%d relay=%s" % [hints.size(), Items.name_of(Blocks.RELAY)])

	# ---- language, framerate cap and render packs
	# the English source is also the key, so a missing translation still shows
	# English rather than a raw identifier
	I18n.set_lang("zh")
	_check("picking a language translates the UI", I18n.t("QUIT GAME") == "退出游戏",
		I18n.t("QUIT GAME"))
	_check("an unknown string falls back to English", I18n.t("zzz not a key") == "zzz not a key")
	_check("block names follow the language", Items.name_of(Blocks.STONE) == "石头",
		Items.name_of(Blocks.STONE))
	_check("item names follow the language", Items.name_of(Blocks.ITEM_APPLE) == "苹果",
		Items.name_of(Blocks.ITEM_APPLE))
	I18n.set_lang("en")
	_check("switching back restores English", I18n.t("QUIT GAME") == "QUIT GAME")

	Settings.max_fps = 60
	Settings.apply_framerate()
	_check("the framerate cap reaches the engine", Engine.max_fps == 60, "max_fps=%d" % Engine.max_fps)
	Settings.max_fps = 0
	Settings.apply_framerate()
	_check("zero means uncapped", Engine.max_fps == 0, "max_fps=%d" % Engine.max_fps)

	# a render pack has to move both halves: the terrain material and the sky
	Blocks.apply_render_preset(2)
	sky.apply_render_preset(2)
	_check("a render pack changes the terrain material",
		Blocks.mat_opaque.metallic_specular > 0.3 and Blocks.mat_water.roughness < 0.1,
		"spec=%.2f water_rough=%.2f" % [Blocks.mat_opaque.metallic_specular, Blocks.mat_water.roughness])
	Blocks.apply_render_preset(0)
	sky.apply_render_preset(0)
	_check("the classic pack restores the stock look",
		absf(Blocks.mat_opaque.metallic_specular - 0.22) < 0.001
			and absf(sky._base_saturation - 1.08) < 0.001,
		"spec=%.2f sat=%.2f" % [Blocks.mat_opaque.metallic_specular, sky._base_saturation])

	# ---- damage rules, the command console and the fog controls
	# the actual "creative got killed by a fall" bug: exercise _land() itself, not
	# just hurt(), because the fall path had its own `not flying` guard that forgot
	# about creative
	player.creative = true
	player.flying = false
	player.health = 20.0
	player._invuln = 0.0
	player._airborne = true
	player._fall_y = player.global_position.y + 12.0
	player._land()
	_check("creative survives a 12-block fall", player.health == 20.0,
		"health=%.1f" % player.health)

	player.creative = false
	player.health = 20.0
	player._invuln = 0.0
	player._airborne = true
	player._fall_y = player.global_position.y + 12.0
	player._land()
	_check("survival still takes fall damage", player.health < 20.0,
		"health=%.1f" % player.health)

	# forced damage is the /kill path, which has to work even in creative
	player.creative = true
	player.health = 20.0
	player._invuln = 0.0
	player.hurt(5.0, true)
	_check("forced damage still lands in creative", player.health < 20.0,
		"health=%.1f" % player.health)

	# commands, driven through the same entry point the chat box submits to
	player.creative = false
	player.reset_inventory()
	Commands.cheats_enabled = true
	Commands.level = Commands.LEVEL_ADMIN
	_check("a command line is recognised", Commands.execute_line("/give stone 7"))
	var stone := 0
	for sl in player.hotbar:
		if int(sl["id"]) == Blocks.STONE:
			stone += int(sl["count"])
	for sl2 in player.inventory:
		if int(sl2["id"]) == Blocks.STONE:
			stone += int(sl2["count"])
	_check("/give puts the items in the bag", stone == 7, "stone=%d" % stone)

	# the terminal path: no leading slash, because in a console everything is a
	# command
	player.reset_inventory()
	Commands.run_command("give cobblestone 4")
	var cobble := 0
	for sc in player.hotbar:
		if int(sc["id"]) == Blocks.COBBLESTONE:
			cobble += int(sc["count"])
	_check("the terminal runs a command without a slash", cobble == 4,
		"cobble=%d" % cobble)

	Commands.execute_line("/gamemode creative")
	_check("/gamemode switches to creative", player.creative)
	Commands.execute_line("/gamemode survival")
	_check("/gamemode switches back to survival", not player.creative)

	player.reset_inventory()
	Commands.cheats_enabled = false
	Commands.execute_line("/give stone 3")
	var stone2 := 0
	for sl3 in player.hotbar:
		if int(sl3["id"]) == Blocks.STONE:
			stone2 += int(sl3["count"])
	_check("cheats off blocks /give", stone2 == 0, "stone=%d" % stone2)
	Commands.cheats_enabled = true
	_check("an unknown command is reported, not crashed",
		Commands.execute_line("/definitelynotacommand"))
	_check("a plain message is not a command", not Commands.execute_line("hello there"))

	# the chat box itself: opens with a prefix, keeps a log, closes clean
	hud.chat_print("test line")
	_check("the chat log holds a line", hud._chat_entries.size() > 0,
		"%d lines" % hud._chat_entries.size())
	hud.open_chat("/")
	_check("the chat box opens with the command prefix",
		hud.is_chat_open() and hud.chat_input.text == "/")
	hud.close_chat()
	_check("the chat box closes again",
		not hud.is_chat_open() and not hud.chat_input.visible)

	# fog: the setting has to actually move the fog, and be switchable off
	Settings.fog_scale = 2.0
	sky.apply_fog()
	var fog_far: float = sky._fog_end
	Settings.fog_scale = 1.0
	sky.apply_fog()
	_check("the fog distance setting stretches the fog", fog_far > sky._fog_end,
		"x2=%.0f x1=%.0f" % [fog_far, sky._fog_end])
	Settings.fog_enabled = false
	sky.apply_fog()
	_check("distant fog can be switched off", not sky.env.fog_enabled)
	Settings.fog_enabled = true
	sky.apply_fog()

	# --- the mouse, and what happens when it leaves the window. First-person look needs the
	# cursor captured, so mid-play it has no way out of the window at all; the moment a menu
	# frees it the player can take it elsewhere, and the game has to stop rather than keep
	# running behind the menu. "A menu is open" is therefore the only reachable way to leave,
	# which is exactly the case worth asserting.
	mode = Mode.PLAY
	_open_inventory()
	_check("opening the inventory frees the cursor from the window",
		Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and _inv_open,
		"mouse_mode=%d" % Input.mouse_mode)
	_leave_window()
	_check("taking the mouse out of the window pauses the game", mode == Mode.PAUSE,
		"mode=%d" % mode)
	_check("and the pause screen is what comes up", ui.current == "pause", ui.current)
	# coming back must not resume by itself: a stray click must not drop the player back into
	# the world mid-swing, so getting back in stays a menu choice
	_leave_window()
	_check("staying away is idempotent, not a crash", mode == Mode.PAUSE, "mode=%d" % mode)
	# put the title screen back exactly as the rest of the run expects to find it
	_enter_title()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	mode = Mode.TITLE

	# leave the title screen exactly as we found it
	Settings.max_fps = int(saved_settings["max_fps"])
	Settings.fog_scale = float(saved_settings["fog_scale"])
	Settings.fog_enabled = bool(saved_settings["fog_enabled"])
	Settings.lang = str(saved_settings["lang"])
	Settings.apply_framerate()
	I18n.set_lang(Settings.lang)
	sky.apply_fog()
	world.chunks.erase(Vector2i(0, 0))
	world._results.clear()
	player.set_input_enabled(false)
	player.velocity = Vector3.ZERO
	player.creative = true
	player.reset_inventory()

	print("=== hand test: %d passed, %d failed ===" % [_pass, _fail])


## [left, right] counts of filled pixels in a drumstick icon, ignoring the black
## outline, so the mirrored half-icon can be checked for filling on the right.
func _half_food_lit(img: Image) -> Array:
	var left := 0
	var right := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and c.r > 0.4:
				if x < 3:
					left += 1
				else:
					right += 1
	return [left, right]


## Finds a column of deep ocean near the spawn, for the ocean preview. Walks
## outward in rings and takes the first column that sits well below sea level.
func _find_deep_ocean() -> Vector2:
	var t = world.terrain
	var base: Vector3 = t.find_spawn()
	var bx := int(base.x)
	var bz := int(base.z)
	for r in range(8, 320, 8):
		for a in 32:
			var ang := TAU * float(a) / 32.0
			var x := bx + int(cos(ang) * float(r))
			var z := bz + int(sin(ang) * float(r))
			if t.height_at(x, z) <= VoxelTerrain.SEA - 3:
				return Vector2(float(x) + 0.5, float(z) + 0.5)
	return Vector2(float(bx) + 0.5, float(bz) + 0.5)


# ================================================================ synthetic chunks
## Parks a worker task on a semaphore, so a test can decide when it finishes and hold
## it in the window between "published its result" and "the pool calls it completed".
func _hold_until(gate: Semaphore) -> void:
	gate.wait()


## Every fixture in this harness that needs a chunk of its own builds it through here.
## The storage layout then lives in exactly one place. While it was hand-rolled in five
## fixtures the layout was copied five times, and a missed copy fails as a test that
## passes for the wrong reason rather than as a build error.
##
## `writes` is a list of [Vector3i, block id], in chunk (0,0)'s coordinates.
func _mk_chunk(writes: Array) -> Dictionary:
	var sections: Dictionary = {}
	var ch := VoxelTerrain.CHUNK
	for w in writes:
		var p: Vector3i = w[0]
		var sec: int = VoxelTerrain.sec_of(p.y)
		# left untyped on purpose: a missing section reads as Nil, and a typed
		# PackedByteArray cannot be assigned Nil to be tested for it
		var arr = sections.get(sec)
		if arr == null:
			arr = PackedByteArray()
			arr.resize(ch * ch * VoxelTerrain.SEC)
			arr.fill(Blocks.AIR)
			sections[sec] = arr
		arr[(p.x & 15) + (p.z & 15) * ch + VoxelTerrain.ly_of(p.y) * ch * ch] = int(w[1])
		sections[sec] = arr
	var chunk: Dictionary = world.new_chunk(sections, world.count_occluders(sections))
	# a fixture is born finished: tests that want a dirty section say so themselves
	chunk["dirty"] = {}
	chunk["meshed"] = true
	return chunk


## A chunk whose named sections are stone from edge to edge -- the shape a deep, fully
## buried section has, and the only fixture that can make `_is_buried` true.
func _filled_sections(secs: Array) -> Dictionary:
	var writes: Array = []
	for sec in secs:
		var y0: int = int(sec) * VoxelTerrain.SEC
		_box(writes, 0, VoxelTerrain.CHUNK - 1, y0, y0 + VoxelTerrain.SEC - 1,
			0, VoxelTerrain.CHUNK - 1, Blocks.STONE)
	return _mk_chunk(writes)


## Appends a filled box of blocks to a `_mk_chunk` write list.
func _box(writes: Array, x0: int, x1: int, y0: int, y1: int, z0: int, z1: int,
		id: int) -> void:
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for z in range(z0, z1 + 1):
				writes.append([Vector3i(x, y, z), id])


## A throwaway chunk of ocean for the water tests: seabed at sea-4, water up to sea
## level, and optionally a solid one-block-high sand bank on its east side. Lets
## the mesher and the swim code be exercised without generating any terrain.
func _make_ocean_chunk(bank: bool) -> Dictionary:
	var ch := VoxelTerrain.CHUNK
	var sea := VoxelTerrain.SEA
	var writes: Array = []
	for lx in ch:
		for lz in ch:
			if bank and lx >= ch - 4:
				_box(writes, lx, lx, sea - 4, sea + 1, lz, lz, Blocks.SAND)
			else:
				writes.append([Vector3i(lx, sea - 4, lz), Blocks.SAND])
				_box(writes, lx, lx, sea - 3, sea, lz, lz, Blocks.WATER)
	var chunk := _mk_chunk(writes)
	# The heightmap is stated by hand rather than derived here, because *being*
	# occluder-only is the point of the fixture: it has to stop below the water
	# surface so the mesher cannot lean on it.
	var hmap: PackedInt32Array = chunk["hmap"]
	for lx in ch:
		for lz in ch:
			hmap[lx + lz * ch] = sea + 2 if (bank and lx >= ch - 4) else sea - 3
	chunk["hmap"] = hmap
	return chunk


## The circuit rig: a small stone platform inside a synthetic chunk, with a lever,
## three blocks of wire, a lamp, a torch, a repeater, a piston and a plate on it.
##
## Built in a chunk of its own rather than in the world, so the hand test stays fast
## and does not depend on where the terrain happens to be.
var _pw_switch := Vector3i(0, 0, 0)
var _pw_wire1 := Vector3i(0, 0, 0)
var _pw_wire2 := Vector3i(0, 0, 0)
var _pw_wire3 := Vector3i(0, 0, 0)
var _pw_lamp := Vector3i(0, 0, 0)
var _pw_inverter := Vector3i(0, 0, 0)
var _pw_relay := Vector3i(0, 0, 0)
var _pw_piston := Vector3i(0, 0, 0)
var _pw_plate := Vector3i(0, 0, 0)
var _pw_facing := Vector3i(0, 0, 1)


## A synthetic chunk with a stone floor and a deep stone column at eye height,
## straight ahead of the probe's stance. The column is longer than one click can
## reach, so counting what is left of it measures the swing clock.
func _build_dig_rig() -> void:
	var ch := VoxelTerrain.CHUNK
	var writes: Array = []
	_box(writes, 0, ch - 1, 20, 20, 0, ch - 1, Blocks.STONE)
	_box(writes, 5, 13, 22, 22, 2, 2, Blocks.STONE)
	world.chunks[Vector2i(0, 0)] = _mk_chunk(writes)


## How much of the dig rig's column is still standing.
func _dig_column() -> int:
	var n := 0
	for x in range(5, 14):
		if world.get_block(x, 22, 2) == Blocks.STONE:
			n += 1
	return n


func _build_power_rig() -> void:
	var ch := VoxelTerrain.CHUNK
	var floor_y := 20
	var writes: Array = []
	_box(writes, 0, ch - 1, floor_y, floor_y, 0, ch - 1, Blocks.STONE)
	world.chunks[Vector2i(0, 0)] = _mk_chunk(writes)
	world.ensure_circuit()
	world.circuit.clear()
	# a straight run: switch, wire, wire, wire, lamp, all sitting on the platform
	_pw_switch = Vector3i(2, floor_y + 1, 2)
	_pw_wire1 = Vector3i(3, floor_y + 1, 2)
	_pw_wire2 = Vector3i(4, floor_y + 1, 2)
	_pw_wire3 = Vector3i(5, floor_y + 1, 2)
	_pw_lamp = Vector3i(6, floor_y + 1, 2)
	_pw_inverter = Vector3i(2, floor_y + 1, 6)
	_pw_relay = Vector3i(4, floor_y + 1, 8)
	_pw_piston = Vector3i(2, floor_y + 1, 12)
	_pw_plate = Vector3i(1, floor_y + 1, 12)
	_pw_facing = Vector3i(1, 0, 0)
	for pair in [[_pw_switch, Blocks.SWITCH], [_pw_wire1, Blocks.WIRE],
			[_pw_wire2, Blocks.WIRE], [_pw_wire3, Blocks.WIRE],
			[_pw_lamp, Blocks.LAMP], [_pw_inverter, Blocks.INVERTER],
			[_pw_relay, Blocks.RELAY], [_pw_piston, Blocks.PISTON],
			[_pw_plate, Blocks.PRESSURE_PLATE]]:
		var p: Vector3i = pair[0]
		world.set_block(p.x, p.y, p.z, int(pair[1]), false)


## Puts the world back the way the test found it. The circuit blocks are registered
## globally, so leaving them behind would leak into every later check.
func _teardown_power_rig() -> void:
	for p in [_pw_switch, _pw_wire1, _pw_wire2, _pw_wire3, _pw_lamp, _pw_inverter,
			_pw_relay, _pw_piston, _pw_plate]:
		world.set_block(p.x, p.y, p.z, Blocks.AIR, false)
	world.circuit.clear()
	world.tile_override.clear()
	world.circuit_lit.clear()
	world.chunks.erase(Vector2i(0, 0))


## Runs the real mesher over one section of a synthetic chunk and returns its buffers.
## Built through `world._make_payload`, so a fixture is meshed under exactly the
## production rules. The chunk is installed for the duration, because the payload needs
## the section's neighbours to build its 3x3x3 snapshot.
func _mesh_probe(chunk: Dictionary, sec: int) -> Dictionary:
	var c := Vector2i(0, 0)
	var had: bool = world.chunks.has(c)
	var prev = world.chunks.get(c)
	world.chunks[c] = chunk
	var payload: Dictionary = world._make_payload(c, sec)
	world._results.clear()
	world._mesh_job(payload)
	var out: Dictionary = world._results[0] if not world._results.is_empty() else {}
	if had:
		world.chunks[c] = prev
	else:
		world.chunks.erase(c)
	return out


## Highest vertex y in a mesher buffer, in world coordinates, or -1 when the buffer is
## empty. A section mesh is built in section-local space, so the section's base has to
## be added back before it can be compared against a world y.
func _buf_max_y(b, sec: int) -> float:
	if b == null:
		return -1.0
	var m := -1.0
	for v in b.v:
		m = maxf(m, v.y)
	if m < 0.0:
		return -1.0
	return m + float(sec) * float(VoxelTerrain.SEC)


## How many vertices a mesher buffer holds, 0 when it is absent.
func _buf_verts(b) -> int:
	return b.v.size() if b != null else 0


## The tower fixture's geometry. Named so the assertions below can be stated as offsets
## from the slab instead of as bare numbers that stop meaning anything the moment the
## slab moves.
const TOWER_SLAB := 40
const TOWER_GLASS_TOP := TOWER_SLAB + 8      # glass spans slab+1 .. slab+8
const TOWER_LEAF_Y := TOWER_SLAB + 10


## A chunk that is deliberately a *worst case* for the mesher's scan bound: a flat
## stone slab with a glass column and a leaf platform stacked well above it. Neither
## glass nor leaves occlude, so a bound derived from the occluder heightmap stops at
## the slab and the whole tower is skipped -- which is the "glass renders as air"
## bug, reproduced without a world.
##
## The tower has to sit ABOVE sea level on purpose. The old bound was
## `max(occluder_top + 1, SEA)`, so anything under y=32 was meshed by the SEA clamp
## regardless and would have masked the bug: a tower built on the seabed "works"
## while the same tower on a hill does not.
func _make_tower_chunk() -> Dictionary:
	var ch := VoxelTerrain.CHUNK
	var writes: Array = []
	_box(writes, 0, ch - 1, TOWER_SLAB, TOWER_SLAB, 0, ch - 1, Blocks.STONE)
	_box(writes, 8, 8, TOWER_SLAB + 1, TOWER_GLASS_TOP, 8, 8, Blocks.GLASS)
	_box(writes, 6, 10, TOWER_LEAF_Y, TOWER_LEAF_Y, 6, 10, Blocks.LEAVES)
	return _mk_chunk(writes)


## Compares the triangle winding of the built-in BoxMesh (which renders correctly
## under Godot's default back-face culling) against our generated voxel cube.
func _winding_test() -> void:
	print("=== winding test ===")
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	var arr := bm.get_mesh_arrays()
	if arr.is_empty():
		print("  BoxMesh returned no arrays")
	else:
		_report_winding(arr[Mesh.ARRAY_VERTEX], arr[Mesh.ARRAY_INDEX], "BoxMesh (reference)")
	var mine := Blocks.make_block_mesh(Blocks.GRASS)
	var a2 := mine.surface_get_arrays(0)
	_report_winding(a2[Mesh.ARRAY_VERTEX], a2[Mesh.ARRAY_INDEX], "VoxelCraft cube")
	var cull := Blocks.mat_opaque.cull_mode
	print("  mat_opaque.cull_mode = %d  (0=back, 1=front, 2=disabled)" % cull)


func _report_winding(v: PackedVector3Array, idx: PackedInt32Array, label: String) -> void:
	var outward := 0
	var inward := 0
	var t := 0
	while t + 2 < idx.size():
		var a: Vector3 = v[idx[t]]
		var b: Vector3 = v[idx[t + 1]]
		var c: Vector3 = v[idx[t + 2]]
		var n := (b - a).cross(c - a)
		var centroid := (a + b + c) / 3.0
		if n.dot(centroid) > 0.0:
			outward += 1
		else:
			inward += 1
		t += 3
	print("  %-22s tris=%d  cross-points-outward=%d  inward=%d" % [
		label, int(t / 3), outward, inward])


func _check_capture() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--capture-ui":
			_capture = "ui"
		elif a == "--capture-world":
			_capture = "world"
		elif a == "--capture-play":
			_capture = "play"
		elif a == "--capture-inventory":
			_capture = "inventory"
		elif a == "--capture-settings":
			_capture = "settings"
		elif a == "--capture-cave":
			_capture = "cave"
		elif a == "--capture-night":
			_capture = "night"
		elif a == "--capture-aerial":
			_capture = "aerial"
		elif a == "--terrain-stats":
			_capture = "stats"
		elif a == "--diag":
			_capture = "diag"
		elif a == "--capture-down":
			_capture = "down"
		elif a == "--dump-atlas":
			_capture = "atlas"
		elif a == "--selftest":
			_capture = "selftest"
		elif a == "--winding":
			_capture = "winding"
		elif a == "--capture-third":
			_capture = "third"
		elif a == "--capture-mobs":
			_capture = "mobs"
		elif a == "--handtest":
			_capture = "handtest"
		elif a == "--capture-items":
			_capture = "items"
		elif a == "--capture-body":
			_capture = "body"
		elif a == "--capture-second":
			_capture = "second"
		elif a == "--capture-skin":
			_capture = "skin"
		elif a == "--capture-ocean":
			_capture = "ocean"
		elif a == "--capture-pose":
			_capture = "pose"
		elif a == "--capture-chat":
			_capture = "chat"
		elif a == "--capture-glass":
			_capture = "glass"
		elif a == "--capture-power":
			_capture = "power"
		elif a == "--capture-reload":
			_capture = "reload"
		elif a == "--capture-create":
			_capture = "create"
		elif a == "--capture-worlds":
			_capture = "worlds"
		elif a == "--perf":
			_capture = "perf"
		elif a == "--probe":
			_capture = "probe"
	if _capture == "":
		return
	_run_capture()


func _shot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var dir := _capture_dir
	DirAccess.make_dir_recursive_absolute(dir)
	get_viewport().get_texture().get_image().save_png("%s/%s" % [dir, file_name])
	print("shot -> ", file_name)


func _run_capture() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _capture == "stats":
		world.setup(_capture_seed, 5)
		_terrain_stats()
		get_tree().quit()
		return
	if _capture == "atlas":
		DirAccess.make_dir_recursive_absolute(_capture_dir)
		Blocks.atlas_tex.get_image().save_png("%s/atlas.png" % _capture_dir)
		for t in Blocks.TILES:
			Blocks.tile_images[t].save_png("%s/tile_%02d.png" % [_capture_dir, t])
		print("atlas dumped")
		get_tree().quit()
		return
	if _capture == "selftest":
		await _run_selftest()
		get_tree().quit()
		return
	if _capture == "winding":
		_winding_test()
		get_tree().quit()
		return
	if _capture == "handtest":
		await _hand_test()
		get_tree().quit()
		return
	if _capture == "probe":
		world.setup(4242, 4)
		for k in 3:
			var t0 := Time.get_ticks_usec()
			world.terrain.fill_chunk(40 + k * 7, 40)
			print("main fill_chunk #%d: %d us" % [k, Time.get_ticks_usec() - t0])
		for mode in 8:
			world.probe_all.clear()
			var jt1 := WorkerThreadPool.add_task(
				Callable(world, "probe_cpu").bind(0, mode), true, "p1")
			WorkerThreadPool.wait_for_task_completion(jt1)
			var one: int = world.probe_all[0]
			world.probe_all.clear()
			var t1 := Time.get_ticks_usec()
			var jts: Array = []
			for i in 8:
				jts.append(WorkerThreadPool.add_task(
					Callable(world, "probe_cpu").bind(i, mode), true, "p8"))
			for j in jts:
				WorkerThreadPool.wait_for_task_completion(j)
			var wall := Time.get_ticks_usec() - t1
			print("mode %d   1 thread %8d us   x8 wall %8d us   speedup %.2fx" % [
				mode, one, wall, float(one) * 8.0 / float(maxi(1, wall))])
		get_tree().quit()
		return
	if _capture == "perf":
		await _perf_run()
		get_tree().quit()
		return
	match _capture:
		"ui":
			await _shot("menu_title.png")
		"settings":
			ui.open_screen("settings")
			await get_tree().process_frame
			await _shot("menu_settings.png")
		"create":
			# the create-world page has to fit: it is the one that grew a cheats
			# toggle and started drawing past the bottom of its panel
			ui.open_screen("create")
			await get_tree().process_frame
			await get_tree().process_frame
			await _shot("menu_create.png")
		"worlds":
			# the save list, against whatever saves actually exist on this machine
			ui.open_screen("worlds")
			await get_tree().process_frame
			await get_tree().process_frame
			await _shot("menu_worlds.png")
		"world":
			_on_new_world("Preview", _capture_seed, true, 5)
			await _wait_loaded()
			sky.time_of_day = 0.50
			sky.running = false
			player.pitch = -0.22
			player.yaw = 0.5
			await _shot("world_day.png")
		"aerial":
			_on_new_world("Preview", _capture_seed, true, 6)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.creative = true
			player.flying = true
			player.place_at(Vector3(player.global_position.x, 76.0, player.global_position.z))
			player.pitch = -0.62
			player.yaw = 0.5
			await _settle()
			await _shot("world_aerial.png")
		"diag":
			_on_new_world("Preview", _capture_seed, true, 5)
			await _wait_loaded()
			_diag_dump()
			get_tree().quit()
			return
		"down":
			_on_new_world("Preview", _capture_seed, true, 5)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.place_at(world.safe_spawn_near(player.global_position))
			for i in 12:
				await get_tree().physics_frame
			player.pitch = -0.75
			player.yaw = 0.3
			for i in 3:
				await get_tree().process_frame
			await _shot("world_down.png")
		"third":
			_on_new_world("Preview", _capture_seed, true, 5)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.third_person = true
			player.pitch = -0.16
			player.yaw = 0.0
			player.hotbar[0] = {"id": Blocks.DIAMOND_ORE, "count": 64}
			player.hotbar_changed.emit()
			player.select_slot(0)
			for i in 20:
				await get_tree().physics_frame
			await _shot("player_third.png")
		"mobs":
			_on_new_world("Preview", _capture_seed, true, 5)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.third_person = true
			player.pitch = -0.14
			player.yaw = 0.0
			var kinds := ["pig", "sheep", "cow", "chicken"]
			for i in kinds.size():
				var want: Vector3 = player.global_position \
					+ Vector3(3.4 - float(i) * 2.3, 0.0, -5.0 - float(i % 2) * 1.6)
				mobs.spawn_at(kinds[i], world.safe_spawn_near(want))
			for i in 90:
				await get_tree().physics_frame
			await _shot("mobs.png")
		"play":
			_on_new_world("Preview", _capture_seed, false, 5)
			await _wait_loaded()
			player.pitch = -0.20
			_hud_demo()
			await _shot("play_hud.png")
		# dropped items on the ground, then a partly mined block (crack overlay)
		"items":
			_on_new_world("Preview", _capture_seed, false, 5)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.place_at(world.safe_spawn_near(player.global_position))
			await _settle()
			player.pitch = -0.42
			player.yaw = 0.3
			player.hotbar[0] = {"id": Blocks.ITEM_APPLE, "count": 5}
			player.hotbar[1] = {"id": Blocks.IRON_ORE, "count": 12}
			player.hotbar_changed.emit()
			player.select_slot(0)
			var look: Vector3 = Vector3(sin(player.yaw) * -1.0, 0.0, cos(player.yaw) * -1.0)
			var at: Vector3 = player.global_position + look * 2.4
			at.y = float(world.highest_occluder(floori(at.x), floori(at.z))) + 0.35
			var kinds := [Blocks.COBBLESTONE, Blocks.PLANKS, Blocks.LOG,
				Blocks.ITEM_DIAMOND, Blocks.ITEM_BREAD]
			for k in kinds.size():
				item_entities.drop(kinds[k], 3, at + Vector3(float(k - 2) * 0.75, 0.0, 0.0),
					Vector3(randf_range(-1.0, 1.0), 1.6, randf_range(-1.0, 1.0)))
			for i in 100:
				await get_tree().physics_frame
			await _shot("items.png")
			# build a wall two blocks ahead and mine it face on, so the crack
			# overlay and the debris are both square to the camera
			var wx := floori(player.global_position.x + look.x * 2.5)
			var wz := floori(player.global_position.z + look.z * 2.5)
			var wy := floori(player.global_position.y)
			for dx in range(-1, 2):
				for dy in range(0, 3):
					world.set_block(wx + dx, wy + dy, wz, Blocks.GRASS)
			player.pitch = 0.0
			player.yaw = 0.3
			for i in 8:
				await get_tree().physics_frame
			Input.action_press("attack")
			for i in 50:
				await get_tree().physics_frame
			await _shot("crack.png")
			Input.action_release("attack")
		# the camera looking back at the player from the front
		"second":
			_on_new_world("Preview", _capture_seed, false, 5)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.place_at(world.safe_spawn_near(player.global_position))
			await _settle()
			player.cam_mode = 2        # Cam.SECOND_FRONT
			player.pitch = -0.10
			player.yaw = 0.0
			player.hotbar[0] = {"id": Blocks.DIAMOND_ORE, "count": 64}
			player.hotbar_changed.emit()
			player.select_slot(0)
			for i in 24:
				await get_tree().physics_frame
			await _shot("second_person.png")
		# out over open water, looking along the surface rather than down at it
		"ocean":
			_on_new_world("Preview", _capture_seed, true, 6)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			var spot: Vector2 = _find_deep_ocean()
			player.creative = true
			player.flying = true
			player.place_at(Vector3(spot.x, float(VoxelTerrain.SEA + 3), spot.y))
			await _settle()
			player.pitch = -0.10
			player.yaw = 0.6
			for i in 20:
				await get_tree().physics_frame
			print("  ocean probe: at (%.1f, %.1f) sea=%d" % [spot.x, spot.y, VoxelTerrain.SEA])
			await _shot("ocean.png")
		# the model side-on, so the crouch lean and the arm swing can be judged by eye
		"pose":
			_on_new_world("Preview", _capture_seed, false, 5)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.place_at(world.safe_spawn_near(player.global_position))
			await _settle()
			player.cam_mode = 2                       # front camera
			player.model.pin_facing(PI * 0.5)         # ...with the body turned side-on
			player.pitch = 0.0
			player.yaw = 0.0
			player.reset_inventory()
			for i in 10:
				await get_tree().physics_frame
			await _shot("pose_stand.png")
			Input.action_press("sneak")
			for i in 12:
				await get_tree().physics_frame
			await _shot("pose_sneak.png")
			Input.action_release("sneak")
			player.hotbar[0] = {"id": Blocks.DIAMOND_ORE, "count": 64}
			player.hotbar_changed.emit()
			player.select_slot(0)
			Input.action_press("attack")
			for i in 20:
				await get_tree().physics_frame
			await _shot("pose_swing.png")
			Input.action_release("attack")
			# flying, seen from the front so the arms' splay is unambiguous: they used
			# to be rotated inward and folded across the body's midline
			player.model.pin_facing(0.0)
			player.reset_inventory()
			player.creative = true
			player.flying = true
			player.pitch = 0.0
			for i in 25:
				await get_tree().physics_frame
			await _shot("pose_fly.png")
			player.model.unpin_facing()
		# Proves the skin unwrap by painting every face of every box its own flat colour
		# and looking at the result from three angles. Green/red/blue/yellow are the
		# head's right/front/left/back: from the front we must see red, with the
		# character's right (green) side showing when the body is turned +90 degrees.
		"skin":
			_on_new_world("Preview", _capture_seed, false, 5)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.place_at(world.safe_spawn_near(player.global_position))
			await _settle()
			var err: String = player.model.apply_skin_image(_diagnostic_skin())
			print("  skin probe: diagnostic skin -> '%s'  name=%s" % [err, player.model.skin_name()])
			player.cam_mode = 2        # Cam.SECOND_FRONT
			player.pitch = 0.0
			player.yaw = 0.0
			player.reset_inventory()
			var angles := [0.0, PI * 0.5, -PI * 0.5]
			var labels := ["front", "right_side", "left_side"]
			for i in angles.size():
				player.model.pin_facing(angles[i])
				for k in 8:
					await get_tree().physics_frame
				await _shot("skin_%s.png" % labels[i])
			player.model.unpin_facing()
			player.model.set_skin(Settings.player_skin)
		# First person looking down at yourself: your own body, and the shadow it throws.
		# This is the view that used to show nothing but the ground, because the body was
		# hidden outright in first person -- and an invisible node casts no shadow, so it
		# took the shadow with it. Morning light rather than noon, so the shadow stretches
		# out to the side instead of hiding under your feet where it proves nothing.
		"body":
			_on_new_world("Preview", _capture_seed, false, 5)
			await _wait_loaded()
			sky.time_of_day = 0.42
			sky.running = false
			player.place_at(world.safe_spawn_near(player.global_position))
			await _settle()
			player.reset_inventory()
			player.pitch = -0.95
			player.yaw = 0.3
			for i in 20:
				await get_tree().physics_frame
			await _shot("first_person_body.png")
		"chat":
			# the console, with real command output in it: this is the visual proof
			# that the log, the tint and the input field all sit where they should
			_on_new_world("Preview", _capture_seed, true, 5)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.place_at(world.safe_spawn_near(player.global_position))
			await _settle()
			player.hotbar[0] = {"id": Blocks.PLANKS, "count": 8}
			player.hotbar_changed.emit()
			player.select_slot(0)
			player.pitch = -0.06
			player.yaw = 0.3
			_open_chat("/")
			_console_mode = true
			hud.chat_print("VoxelCraft console  -  /help lists commands",
				Color(0.70, 0.85, 1.0))
			Commands.run_command("/help")
			Commands.run_command("/pos")
			Commands.run_command("/give stone 7")
			hud.chat_input.text = "/time set night"
			hud.chat_input.caret_column = hud.chat_input.text.length()
			for i in 6:
				await get_tree().process_frame
			await _shot("chat_console.png")
		"glass":
			# non-occluding blocks stacked above the ground: a glass tower sitting on
			# the surface and a leaf platform floating in the air. Both used to fall
			# outside the mesher's scan bound and render as nothing at all.
			_on_new_world("Preview", _capture_seed, true, 5)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.place_at(world.safe_spawn_near(player.global_position))
			await _settle()
			var px := floori(player.global_position.x)
			var pz := floori(player.global_position.z)
			var by: int = world.highest_occluder(px, pz)
			# a glass tower standing on the ground beside the spawn...
			for y in range(by, by + 6):
				world.set_block(px + 2, y, pz, Blocks.GLASS)
			# ...and a wide leaf platform floating high in mid-air, with nothing under it
			for lx in range(px - 5, px):
				for lz in range(pz - 2, pz + 3):
					world.set_block(lx, by + 11, lz, Blocks.LEAVES)
			player.hotbar[0] = {"id": Blocks.GLASS, "count": 64}
			player.hotbar_changed.emit()
			player.select_slot(0)
			# View from a fixed vantage point in the air rather than from wherever the
			# spawn happens to be: standing on the ground, terrain and FOV fight over
			# whether both objects are in frame.
			player.creative = true
			player.flying = true
			player.place_at(Vector3(float(px) + 3.5, float(by + 15), float(pz) + 11.5))
			player.yaw = 0.0        # forward is -Z, back toward the spawn
			player.pitch = -0.55
			for i in 60:
				await get_tree().physics_frame
			await _shot("glass_tower.png")
		"reload":
			# create a world, save it, quit to the title and load it again: the one path
			# that runs world.reset() + setup() on a live world, so a leaked node or a
			# stale chunk here shows up as a second world that will not finish loading
			_on_new_world("Preview", _capture_seed, true, 4)
			await _wait_loaded()
			await _settle()
			player.place_at(world.safe_spawn_near(player.global_position))
			await _settle()
			var rx := floori(player.global_position.x)
			var rz := floori(player.global_position.z)
			var ry: int = world.highest_occluder(rx, rz)
			world.set_block(rx, ry, rz, Blocks.PLANKS)
			world.set_block(rx + 1, ry, rz, Blocks.WIRE)
			world.set_block(rx + 2, ry, rz, Blocks.SWITCH)
			# the selftest opens the inventory and crafts before its reload; mirror that
			# so the crash can be reproduced without running the whole suite
			player.crafting[0] = {"id": Blocks.LOG, "count": 3}
			player.crafting[4] = {"id": Blocks.PLANKS, "count": 6}
			_open_inventory()
			await get_tree().process_frame
			await get_tree().process_frame
			_close_inventory()
			await get_tree().process_frame
			_quit_to_title()
			await get_tree().process_frame
			ui.load_world_requested.emit(world_dir)
			await _wait_loaded()
			await _settle()
			await _shot("reload.png")
			# the save was only ever a fixture for this check: leaving it behind fills
			# the world list with Preview_* entries every time the capture runs
			_on_delete_world(world_dir)
		"power":
			# The power layer, energised. Everything here is driven by one switch: the
			# wire run decays into the lamp, a NOT gate sits on a battery, a relay
			# re-drives the line, and a plate fires a piston. A screenshot is the only
			# way to judge the new tiles' look.
			_on_new_world("Preview", _capture_seed, true, 6)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			player.place_at(world.safe_spawn_near(player.global_position))
			await _settle()
			# anchor the build inside the player's own chunk, so every set_block lands
			var px := floori(player.global_position.x / 16.0) * 16 + 2
			var pz := floori(player.global_position.z / 16.0) * 16 + 2
			# a level plinth: the ground here is sloped, so the deck is raised to the
			# highest column in the footprint and the air above it cleared, or grass
			# and flowers poke through the parts and the whole thing reads as a mess
			var by := 0
			for dx in range(-2, 14):
				for dz in range(-2, 7):
					by = maxi(by, world.highest_occluder(px + dx, pz + dz))
			for dx in range(-2, 14):
				for dz in range(-2, 7):
					for dy in range(-5, 0):
						world.set_block(px + dx, by + dy, pz + dz, Blocks.STONE_BRICK)
					for dy in range(0, 8):
						world.set_block(px + dx, by + dy, pz + dz, Blocks.AIR)
			# switch -> wire -> wire -> wire -> lamp
			world.set_block(px, by, pz, Blocks.SWITCH)
			for i in 3:
				world.set_block(px + 1 + i, by, pz, Blocks.WIRE)
			world.set_block(px + 4, by, pz, Blocks.LAMP)
			# a NOT gate standing on a cell
			world.set_block(px, by, pz + 2, Blocks.BATTERY)
			world.set_block(px, by + 1, pz + 2, Blocks.INVERTER)
			# a relay taking its input from a cell and re-driving a short wire
			world.set_place_look(Vector3(1, 0, 0))
			world.set_block(px + 1, by, pz + 3, Blocks.BATTERY)
			world.set_block(px + 2, by, pz + 3, Blocks.RELAY)
			world.set_block(px + 3, by, pz + 3, Blocks.WIRE)
			world.set_block(px + 4, by, pz + 3, Blocks.LAMP)
			# a plate firing a piston into a plank
			world.set_block(px + 8, by, pz + 3, Blocks.PRESSURE_PLATE)
			world.set_block(px + 9, by, pz + 3, Blocks.PISTON)
			world.set_block(px + 10, by, pz + 3, Blocks.PLANKS)
			world.circuit.interact(Vector3i(px, by, pz), Blocks.SWITCH)
			world.circuit.set_plate(Vector3i(px + 8, by, pz + 3), true)
			player.creative = true
			player.flying = true
			player.place_at(Vector3(float(px) + 5.0, float(by) + 4.2, float(pz) + 9.5))
			player.yaw = 0.0
			player.pitch = -0.72
			for i in 90:
				await get_tree().physics_frame
			await _shot("power.png")
		"cave":
			_on_new_world("Preview", _capture_seed, true, 5)
			await _wait_loaded()
			sky.time_of_day = 0.5
			sky.running = false
			await _dig_down()
			await _settle()
			await _shot("cave.png")
		"night":
			_on_new_world("Preview", _capture_seed, true, 5)
			await _wait_loaded()
			sky.time_of_day = 0.92
			sky.running = false
			player.pitch = -0.12
			await _shot("world_night.png")
		"inventory":
			_on_new_world("Preview", _capture_seed, true, 5)
			await _wait_loaded()
			player.hotbar[0] = {"id": Blocks.GRASS, "count": 64}
			player.hotbar[1] = {"id": Blocks.LOG, "count": 12}
			player.hotbar[2] = {"id": Blocks.COBBLESTONE, "count": 40}
			player.inventory[0] = {"id": Blocks.ITEM_COAL, "count": 9}
			player.inventory[1] = {"id": Blocks.ITEM_IRON, "count": 5}
			player.inventory[2] = {"id": Blocks.ITEM_DIAMOND, "count": 2}
			player.inventory[3] = {"id": Blocks.ITEM_STICK, "count": 16}
			player.inventory[4] = {"id": Blocks.ITEM_COPPER, "count": 32}
			player.inventory[5] = {"id": Blocks.RELAY, "count": 3}
			player.crafting[0] = {"id": Blocks.LOG, "count": 3}
			player.crafting[4] = {"id": Blocks.PLANKS, "count": 6}
			player.hotbar_changed.emit()
			_open_inventory()
			hud.refresh_inventory()
			await get_tree().process_frame
			# Hover a cell so the tooltip makes it into the shot. It only ever appears
			# under the pointer, so a screenshot has to be told where the pointer is.
			var hov: InvSlot = hud.inv_slots[5]
			Input.warp_mouse(hov.get_global_rect().get_center())
			hud._on_slot_hover(int(hov.item_id), hov.get_global_rect().end)
			await get_tree().process_frame
			await get_tree().process_frame
			await _shot("menu_inventory.png")
	print("capture done: ", _capture)
	get_tree().quit()


## A diagnostic Minecraft skin where every face of every box is a flat colour, so a
## screenshot says exactly which region landed on which side of the character.
## Head: green right, red front, blue left, yellow back, white top, near-black bottom.
func _diagnostic_skin() -> Image:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.22, 0.22, 0.22))
	# limbs: the whole 16x16 region one colour, so a side cannot be confused
	_paint_rect(img, 40, 16, 16, 16, Color(1, 0, 1))          # right arm = magenta
	_paint_rect(img, 32, 48, 16, 16, Color(0, 1, 1))          # left arm = cyan
	_paint_rect(img, 0, 16, 16, 16, Color(1, 0.5, 0))         # right leg = orange
	_paint_rect(img, 16, 48, 16, 16, Color(0.5, 0, 1))        # left leg = purple
	# head band, in Minecraft's order: right, front, left, back
	_paint_rect(img, 0, 8, 8, 8, Color(0, 1, 0))
	_paint_rect(img, 8, 8, 8, 8, Color(1, 0, 0))
	_paint_rect(img, 16, 8, 8, 8, Color(0, 0, 1))
	_paint_rect(img, 24, 8, 8, 8, Color(1, 1, 0))
	_paint_rect(img, 8, 0, 8, 8, Color(1, 1, 1))
	_paint_rect(img, 16, 0, 8, 8, Color(0.05, 0.05, 0.05))
	# torso band, same order but 4/8/4/8 wide
	_paint_rect(img, 16, 20, 4, 12, Color(0.5, 0, 0))
	_paint_rect(img, 20, 20, 8, 12, Color(0, 0.4, 0))
	_paint_rect(img, 28, 20, 4, 12, Color(0, 0, 0.5))
	_paint_rect(img, 32, 20, 8, 12, Color(0.5, 0.5, 0.5))
	return img


func _paint_rect(img: Image, x: int, y: int, w: int, h: int, c: Color) -> void:
	for j in range(y, y + h):
		for i in range(x, x + w):
			if i >= 0 and j >= 0 and i < img.get_width() and j < img.get_height():
				img.set_pixel(i, j, c)


func _diag_dump() -> void:
	var p: Vector3 = player.global_position
	var cc := Vector2i(floori(p.x) >> 4, floori(p.z) >> 4)
	print("=== diag ===")
	print("player pos ", p, " chunk ", cc)
	print("progress %.3f  chunks %d  rd %d" % [world.progress(), world.loaded_chunks(),
		world.render_distance])
	var zero := 0
	var meshed := 0
	for c in world.chunks.keys():
		if bool(world.chunks[c]["meshed"]):
			meshed += 1
		else:
			zero += 1
			if absi(c.x - cc.x) <= world.render_distance and absi(c.y - cc.y) <= world.render_distance:
				print("  STUCK ", c, " dirty=", world.chunks[c]["dirty"].keys(),
					" sections=", world.chunks[c]["sections"].keys(),
					" srev=", world.chunks[c]["srev"],
					" ready=", world._neighbourhood_ready(c),
					" jobs=", world._chunk_has_jobs(c))
	print("meshed %d   not meshed %d" % [meshed, zero])
	print("gen jobs %d/%d  gen queued %d/%d  gen pool %d  mesh jobs %d/%d" % [
		world._gen_jobs.size(), world.max_gen_jobs, world._gen_index, world._gen_list.size(),
		world._gen_pool.size(), world._jobs.size(), world.max_jobs])
	world.perf_report()
	var solid_v := 0
	var trans_v := 0
	var node_count := 0
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var c2 := Vector2i(cc.x + dx, cc.y + dz)
			if not world.chunks.has(c2):
				print("  chunk %s MISSING" % c2)
				continue
			var ch: Dictionary = world.chunks[c2]
			var sv := 0
			var surf := 0
			for sec in ch["nodes"]:
				var pair: Dictionary = ch["nodes"][sec]
				var ns = pair["solid"]
				if ns == null or not is_instance_valid(ns) or ns.mesh == null:
					continue
				node_count += 1
				for si in ns.mesh.get_surface_count():
					sv += ns.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX].size()
					surf += 1
			solid_v += sv
			print("  chunk %s meshed=%s sections=%d nodes=%d surfaces=%d verts=%d"
				% [c2, ch["meshed"], ch["sections"].size(), ch["nodes"].size(), surf, sv])
	print("total solid verts near player: ", solid_v, "  section nodes: ", node_count)
	# what is actually in the column under the player?
	var col := ""
	for y in range(floori(p.y) + 3, floori(p.y) - 8, -1):
		col += "%d:%s  " % [y, Blocks.display_name(world.get_block(floori(p.x), y, floori(p.z)))]
	print("column at player: ", col)
	var heights := ""
	for dx in range(-4, 5, 2):
		heights += "%d " % world.highest_occluder(floori(p.x) + dx, floori(p.z))
	print("hmap row: ", heights)


## Frame-time profile of chunk streaming. Flies the player forward so chunks are
## generated and meshed under the camera the way they are when walking, records the
## wall time of every frame, then prints the distribution plus the worst frames with
## their phase breakdown. Run with `--perf`; needs a window, not `--headless`.
func _perf_run() -> void:
	_on_new_world("Perf", _capture_seed, true, 6)
	await _wait_loaded()
	sky.running = false
	sky.time_of_day = 0.5
	player.creative = true
	player.flying = true
	player.pitch = -0.10
	player.yaw = 0.0
	# above the tallest terrain, so nothing can stop the flight part way through
	player.place_at(Vector3(player.global_position.x, 130.0, player.global_position.z))
	for i in 12:
		await get_tree().process_frame

	var deltas: Array = []
	var worst: Array = []
	var start_chunk: Vector2i = world._center
	Input.action_press("forward")
	Input.action_press("sprint")
	var prev := Time.get_ticks_usec()
	var guard := 0
	while deltas.size() < 600 and guard < 3000:
		guard += 1
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ms := float(now - prev) / 1000.0
		prev = now
		deltas.append(ms)
		# only record the breakdown on frames that would actually be felt, and cap the
		# list so a pathological run cannot eat all the memory
		if ms > 20.0 and worst.size() < 40 and not world.perf_last.is_empty():
			worst.append([ms, world.perf_last.duplicate()])
	Input.action_release("forward")
	Input.action_release("sprint")
	var end_chunk: Vector2i = world._center
	print("=== perf: %d frames, travelled %d chunks, rd %d ===" % [
		deltas.size(), maxi(absi(end_chunk.x - start_chunk.x), absi(end_chunk.y - start_chunk.y)),
		world.render_distance])
	_perf_summary(deltas)
	print("worst frames (ms -> us by phase):")
	for w in worst:
		var ph: Dictionary = w[1]
		print("  %7.1f  drain %5d  genapply %5d  rebuild %5d  gensub %5d  submit %5d  lights %5d  total %6d" % [
			float(w[0]), int(ph.get("drain", 0)), int(ph.get("genapply", 0)),
			int(ph.get("rebuild", 0)), int(ph.get("gensub", 0)), int(ph.get("submit", 0)),
			int(ph.get("lights", 0)), int(ph.get("total", 0))])
	world.perf_report()


func _perf_summary(deltas: Array) -> void:
	var sorted := deltas.duplicate()
	sorted.sort()
	var n := sorted.size()
	if n == 0:
		return
	var sum := 0.0
	for d in sorted:
		sum += float(d)
	var over := func(limit: float) -> int:
		var k := 0
		for d in sorted:
			if float(d) > limit:
				k += 1
		return k
	print("frame ms: mean %.2f  p50 %.2f  p95 %.2f  p99 %.2f  max %.2f" % [
		sum / float(n), float(sorted[n / 2]), float(sorted[int(n * 0.95)]),
		float(sorted[mini(n - 1, int(n * 0.99))]), float(sorted[n - 1])])
	print("  >16.7ms %d   >25ms %d   >33ms %d   >50ms %d" % [
		over.call(16.7), over.call(25.0), over.call(33.0), over.call(50.0)])


func _terrain_stats() -> void:
	var t = world.terrain
	if t == null:
		return
	var n := 0
	var above := 0
	var hmin := 999
	var hmax := -1
	var hsum := 0
	var biomes := {}
	var forest := 0
	var trees := 0
	var plants := 0
	var caves := 0
	for x in range(-120, 121, 3):
		for z in range(-120, 121, 3):
			var h: int = t.height_at(x, z)
			var b: int = t.biome_at(x, z)
			n += 1
			hsum += h
			hmin = mini(hmin, h)
			hmax = maxi(hmax, h)
			if h > t.SEA + 1:
				above += 1
			biomes[b] = int(biomes.get(b, 0)) + 1
			if not t.tree_at(x, z, h, b).is_empty():
				trees += 1
			if t.plant_at(x, z, b) != Blocks.AIR:
				plants += 1
	print("=== terrain stats (seed %d) ===" % _capture_seed)
	print("columns %d  min %d  max %d  avg %.1f  sea %d" % [n, hmin, hmax,
		float(hsum) / float(n), t.SEA])
	print("land above sea+1: %d / %d (%.1f%%)" % [above, n, 100.0 * float(above) / float(n)])
	print("biomes: ", biomes)
	print("tree columns %d (%.2f%%)  plant columns %d" % [trees, 100.0 * float(trees) / float(n), plants])
	var spawn: Vector3 = t.find_spawn()
	print("spawn: ", spawn, "  biome: ", t.biome_name(t.biome_at(int(spawn.x), int(spawn.z))))
	# sample a chunk to report block composition and cave volume
	var built: Dictionary = t.fill_chunk(0, 0)
	var sections: Dictionary = built["sections"]
	var counts := {}
	for sec in sections:
		for v in sections[sec]:
			counts[v] = int(counts.get(v, 0)) + 1
	# the cells no section covers are air, so they have to be counted in by hand or the
	# composition percentages silently describe only the layers that exist. Counted over
	# the span the sections actually occupy, not the whole world: the ceiling is 320 now,
	# and measuring against that would report a chunk as 99% air and say nothing.
	var sec_lo := 0
	var sec_hi := 0
	var first := true
	for sec in sections:
		sec_lo = int(sec) if first else mini(sec_lo, int(sec))
		sec_hi = int(sec) if first else maxi(sec_hi, int(sec))
		first = false
	var per := VoxelTerrain.SEC * VoxelTerrain.CHUNK * VoxelTerrain.CHUNK
	counts[Blocks.AIR] = int(counts.get(Blocks.AIR, 0)) \
		+ (sec_hi - sec_lo + 1) * per - sections.size() * per
	print("chunk(0,0) spans y %d..%d" % [sec_lo * VoxelTerrain.SEC,
		(sec_hi + 1) * VoxelTerrain.SEC - 1])
	var named := {}
	for k in counts:
		named[Blocks.display_name(k)] = counts[k]
	print("chunk(0,0) composition (%d sections): " % sections.size(), named)
	# count surface block ids
	world.chunks[Vector2i(0, 0)] = world.new_chunk(sections, built["occ"])
	var surf := {}
	for x in range(0, 16):
		for z in range(0, 16):
			var hh: int = t.height_at(x, z)
			var id: int = world.get_block(x, hh, z)
			surf[Blocks.display_name(id)] = int(surf.get(Blocks.display_name(id), 0)) + 1
	print("chunk(0,0) surface blocks: ", surf)
	world.chunks.erase(Vector2i(0, 0))
	print("cave noise: ", t.cave_stats())


func _hud_demo() -> void:
	player.hotbar[0] = {"id": Blocks.GRASS, "count": 64}
	player.hotbar[1] = {"id": Blocks.COBBLESTONE, "count": 48}
	player.hotbar[2] = {"id": Blocks.PLANKS, "count": 32}
	player.hotbar[3] = {"id": Blocks.LOG, "count": 19}
	player.hotbar[4] = {"id": Blocks.TORCH, "count": 12}
	player.hotbar[5] = {"id": Blocks.GLASS, "count": 64}
	player.hotbar[6] = {"id": Blocks.GLOWSTONE, "count": 8}
	player.health = 13.0
	player.hunger = 11.0
	player.hotbar_changed.emit()
	player.health_changed.emit()
	player.hunger_changed.emit()
	player.select_slot(1)
	hud.set_debug(true)


func _dig_down() -> void:
	var p: Vector3 = player.global_position
	var y0 := floori(p.y) - 16
	var x0 := floori(p.x)
	var z0 := floori(p.z)
	# a 3 wide, 3 tall corridor heading +X
	for i in range(-1, 21):
		for dy in 3:
			for dz in range(-1, 2):
				world.set_block(x0 + i, y0 + dy, z0 + dz, Blocks.AIR)
	# a shaft up to the surface so daylight spills in at the far end
	for i in range(-1, 21):
		for dy in 3:
			for dz in range(-1, 2):
				world.set_block(x0 + i, y0 + 3 + dy, z0 + dz, Blocks.STONE)
	# torches standing on the corridor floor
	for i in range(2, 20, 5):
		world.set_block(x0 + i, y0, z0 - 1, Blocks.TORCH)
	# reveal some ore in the walls
	for i in range(3, 19, 5):
		world.set_block(x0 + i, y0 + 1, z0 + 2, Blocks.DIAMOND_ORE)
		world.set_block(x0 + i + 1, y0 + 2, z0 + 2, Blocks.COAL_ORE)
		world.set_block(x0 + i - 1, y0, z0 + 2, Blocks.IRON_ORE)
	player.place_at(Vector3(float(x0) + 0.5, float(y0) + 0.2, float(z0) + 0.5))
	player.pitch = -0.05
	player.yaw = -PI * 0.5
	player.hotbar[4] = {"id": Blocks.TORCH, "count": 12}
	player.hotbar_changed.emit()
	world._light_timer = 0.0
	for i in 40:
		await get_tree().process_frame
		world.update_streaming(player.global_position)
	await get_tree().create_timer(0.3).timeout


func _settle() -> void:
	var t := 0.0
	while t < 40.0:
		world.update_streaming(player.global_position)
		var pending := 0
		for c in world.chunks.keys():
			if not bool(world.chunks[c]["meshed"]):
				pending += 1
		if pending == 0 and world.idle():
			break
		t += get_process_delta_time()
		await get_tree().process_frame
	for i in 6:
		await get_tree().process_frame
	world.update_streaming(player.global_position)


func _wait_loaded() -> void:
	var t := 0.0
	var last := 0.0
	while t < 60.0:
		world.update_streaming(player.global_position)
		if world.progress() >= 0.999 and world.idle():
			break
		t += get_process_delta_time()
		if t - last > 2.0:
			last = t
			print("  loading %.1fs  progress %.3f  chunks %d  jobs %d  gen %d/%d" % [
				t, world.progress(), world.loaded_chunks(), world._jobs.size(),
				world._gen_index, world._gen_list.size()])
		await get_tree().process_frame
	for i in 4:
		await get_tree().process_frame