extends Node
## Persistent options + the InputMap, which is built in code so the project file
## stays readable.

const PATH := "user://settings.cfg"

var fov := 75.0
var sensitivity := 0.0022
var invert_y := false
var volume := 0.85
var music_volume := 0.45
var render_distance := 6
var fullscreen := false
var vsync := true
var view_bob := true
var quality := 2            # 0 low, 1 medium, 2 high
var show_fps := false
var max_fps := 0            # 0 = uncapped
var render_preset := 0      # 0 Classic, 1 Soft, 2 Vibrant
var lang := "en"            # "en" or "zh"
## Fog is what hides the edge of the loaded world. Stretching it lets you see
## further at the cost of watching chunks pop in; 1.0 is the tuned default.
var fog_enabled := true
var fog_scale := 1.0
## How many milliseconds a frame may spend generating new chunks. Raising it
## streams a large render distance in faster, at the cost of frame time.
var chunk_budget_ms := 12
var auto_jump := false
var player_skin := 0
var player_skin_path := ""      # a real Minecraft skin PNG, when one is chosen

const MIN_RD := 3
const MAX_RD := 16


func _ready() -> void:
	_install_input()
	load_settings()
	I18n.lang = lang
	apply_window()
	apply_audio()
	apply_framerate()


# ================================================================ input
func _install_input() -> void:
	var defs := {
		"forward": [KEY_W, KEY_UP],
		"back": [KEY_S, KEY_DOWN],
		"left": [KEY_A, KEY_LEFT],
		"right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_SPACE],
		"sneak": [KEY_SHIFT],
		"sprint": [KEY_CTRL],
		"inventory": [KEY_E],
		"drop": [KEY_Q],
		"pause": [KEY_ESCAPE],
		"debug": [KEY_F3],
		"screenshot": [KEY_F12],
		"toggle_view": [KEY_F5],
		"zoom": [KEY_C],
		"pick": [],
	}
	for name in defs:
		if not InputMap.has_action(name):
			InputMap.add_action(name)
		for k in defs[name]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			if not InputMap.action_has_event(name, ev):
				InputMap.action_add_event(name, ev)

	for i in 9:
		var a := "hotbar_%d" % (i + 1)
		if not InputMap.has_action(a):
			InputMap.add_action(a)
		var ev2 := InputEventKey.new()
		ev2.physical_keycode = KEY_1 + i
		if not InputMap.action_has_event(a, ev2):
			InputMap.action_add_event(a, ev2)

	var mouse := {
		"attack": MOUSE_BUTTON_LEFT,
		"use": MOUSE_BUTTON_RIGHT,
	}
	for name2 in mouse:
		if not InputMap.has_action(name2):
			InputMap.add_action(name2)
		var mb := InputEventMouseButton.new()
		mb.button_index = mouse[name2]
		if not InputMap.action_has_event(name2, mb):
			InputMap.action_add_event(name2, mb)

	var pick_btn := InputEventMouseButton.new()
	pick_btn.button_index = MOUSE_BUTTON_MIDDLE
	if not InputMap.action_has_event("pick", pick_btn):
		InputMap.action_add_event("pick", pick_btn)

	for wname in ["wheel_up", "wheel_down"]:
		if not InputMap.has_action(wname):
			InputMap.add_action(wname)
	var wu := InputEventMouseButton.new()
	wu.button_index = MOUSE_BUTTON_WHEEL_UP
	if not InputMap.action_has_event("wheel_up", wu):
		InputMap.action_add_event("wheel_up", wu)
	var wd := InputEventMouseButton.new()
	wd.button_index = MOUSE_BUTTON_WHEEL_DOWN
	if not InputMap.action_has_event("wheel_down", wd):
		InputMap.action_add_event("wheel_down", wd)


# ================================================================ persistence
func load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return
	fov = float(cf.get_value("video", "fov", fov))
	sensitivity = float(cf.get_value("input", "sensitivity", sensitivity))
	invert_y = bool(cf.get_value("input", "invert_y", invert_y))
	volume = float(cf.get_value("audio", "volume", volume))
	music_volume = float(cf.get_value("audio", "music", music_volume))
	render_distance = int(cf.get_value("video", "render_distance", render_distance))
	fullscreen = bool(cf.get_value("video", "fullscreen", fullscreen))
	vsync = bool(cf.get_value("video", "vsync", vsync))
	view_bob = bool(cf.get_value("video", "view_bob", view_bob))
	quality = int(cf.get_value("video", "quality", quality))
	show_fps = bool(cf.get_value("video", "show_fps", show_fps))
	max_fps = int(cf.get_value("video", "max_fps", max_fps))
	render_preset = int(cf.get_value("video", "render_preset", render_preset))
	lang = str(cf.get_value("video", "lang", lang))
	if not I18n.LANGS.has(lang):
		lang = "en"
	fog_enabled = bool(cf.get_value("video", "fog_enabled", fog_enabled))
	fog_scale = clampf(float(cf.get_value("video", "fog_scale", fog_scale)), 0.3, 4.0)
	chunk_budget_ms = clampi(int(cf.get_value("video", "chunk_budget_ms", chunk_budget_ms)), 2, 40)
	auto_jump = bool(cf.get_value("game", "auto_jump", auto_jump))
	player_skin = int(cf.get_value("game", "player_skin", player_skin))
	player_skin_path = str(cf.get_value("game", "player_skin_path", player_skin_path))
	render_distance = clampi(render_distance, MIN_RD, MAX_RD)


func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("video", "fov", fov)
	cf.set_value("video", "render_distance", render_distance)
	cf.set_value("video", "fullscreen", fullscreen)
	cf.set_value("video", "vsync", vsync)
	cf.set_value("video", "view_bob", view_bob)
	cf.set_value("video", "quality", quality)
	cf.set_value("video", "show_fps", show_fps)
	cf.set_value("video", "max_fps", max_fps)
	cf.set_value("video", "render_preset", render_preset)
	cf.set_value("video", "lang", lang)
	cf.set_value("video", "fog_enabled", fog_enabled)
	cf.set_value("video", "fog_scale", fog_scale)
	cf.set_value("video", "chunk_budget_ms", chunk_budget_ms)
	cf.set_value("input", "sensitivity", sensitivity)
	cf.set_value("input", "invert_y", invert_y)
	cf.set_value("audio", "volume", volume)
	cf.set_value("audio", "music", music_volume)
	cf.set_value("game", "auto_jump", auto_jump)
	cf.set_value("game", "player_skin", player_skin)
	cf.set_value("game", "player_skin_path", player_skin_path)
	cf.save(PATH)


# ================================================================ application
func apply_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)


func apply_audio() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(clampf(volume, 0.0, 1.0)))
	Sfx.set_music_volume(music_volume)


## 0 means "let the driver run free"; anything else clamps the render rate, which
## is how you stop a laptop fan from spinning up on a lightweight scene.
func apply_framerate() -> void:
	Engine.max_fps = maxi(0, max_fps)


func shadow_size() -> int:
	match quality:
		0:
			return 0
		1:
			return 2048
	return 4096


func msaa_level() -> int:
	match quality:
		0:
			return 0
		1:
			return 1
	return 2


func max_render_distance() -> int:
	match quality:
		0:
			return 6
		1:
			return 10
	return 16


func shadow_distance() -> float:
	match quality:
		0:
			return 32.0
		1:
			return 64.0
	return 96.0