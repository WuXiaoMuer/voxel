extends Node
## Chat commands and the console/terminal behind them.
##
## Commands are registered with a name, a usage line, a permission level and a
## handler, so the set is data rather than a match statement. That is deliberate:
## the plan for multiplayer is that this same registry becomes the server's admin
## surface, where the permission level is checked against the *sender's* operator
## level instead of the local player's.
##
## Output goes out through the `output` signal, which the HUD prints into the chat
## log. Nothing here touches the screen directly.

## Emitted for every line the player should see: command echo and command output.
signal output(text: String)

## Permission levels, lowest first. Multiplayer will map these onto operator
## levels the same way Minecraft does: level 0 is everyone, 1 is a trusted
## operator, 2 is the server admin.
const LEVEL_ANY := 0
const LEVEL_OP := 1
const LEVEL_ADMIN := 2

var player
var world
var sky
var hud

## The local player's level. Single player with cheats allowed is the admin.
var level := LEVEL_ADMIN
## Whether commands may run at all. Set from the world's "allow cheats" flag.
var cheats_enabled := true

var _registry: Dictionary = {}     # name -> {usage, help, level, handler}
var _aliases: Dictionary = {}      # alias -> name
var _order: Array = []             # registration order, for /help
var _name_to_id: Dictionary = {}   # lower-case block/item name -> id


func _ready() -> void:
	_build_name_index()
	_register_all()


func bind(p, w, s, h) -> void:
	player = p
	world = w
	sky = s
	hud = h


# ================================================================ registry
func register(name: String, usage: String, help: String, lvl: int, handler: Callable,
		aliases: Array = []) -> void:
	_registry[name] = {"usage": usage, "help": help, "level": lvl, "handler": handler}
	if not _order.has(name):
		_order.append(name)
	for a in aliases:
		_aliases[str(a)] = name


func has_command(name: String) -> bool:
	return _registry.has(_resolve(name))


func _resolve(name: String) -> String:
	var n := name.to_lower()
	if _registry.has(n):
		return n
	return str(_aliases.get(n, ""))


## Command names in registration order, for tab completion and `/help`.
func command_names() -> Array:
	return _order.duplicate()


## Executes one line of chat input. Only a line that starts with "/" is a command;
## anything else is a chat message and returns false so the caller can send it.
func execute_line(line: String) -> bool:
	var text := line.strip_edges()
	if not text.begins_with("/"):
		return false
	_dispatch(text.substr(1))
	return true


## The terminal path: no "/" needed, because in a console everything is a command.
func run_command(line: String) -> void:
	var text := line.strip_edges()
	if text.begins_with("/"):
		text = text.substr(1)
	_dispatch(text)


func _dispatch(text: String) -> void:
	var parts := _tokenize(text)
	if parts.is_empty():
		return
	var name := parts[0].to_lower()
	var args: Array = parts.slice(1)

	var key := _resolve(name)
	if key == "":
		output.emit(I18n.tf("Unknown command: %s. Try /help.", [name]))
		return
	if not cheats_enabled and int(_registry[key]["level"]) > LEVEL_ANY:
		output.emit(I18n.t("Cheats are disabled for this world."))
		return
	if int(_registry[key]["level"]) > level:
		output.emit(I18n.tf("%s needs a higher permission level.", ["/" + key]))
		return
	var handler: Callable = _registry[key]["handler"]
	handler.call(args)


func _tokenize(text: String) -> PackedStringArray:
	# whitespace separated, with "double quoted" runs kept as one token so a name
	# like "Oak Planks" survives
	var out := PackedStringArray()
	var cur := ""
	var quoted := false
	for i in text.length():
		var ch := text[i]
		if ch == "\"":
			quoted = not quoted
			continue
		if ch == " " and not quoted:
			if cur != "":
				out.append(cur)
				cur = ""
			continue
		cur += ch
	if cur != "":
		out.append(cur)
	return out


func say(text: String) -> void:
	output.emit(text)


# ================================================================ name lookup
func _build_name_index() -> void:
	for id in Blocks.names.size():
		var nm := str(Blocks.names[id])
		if nm == "":
			continue
		_name_to_id[_key_of(nm)] = id


func _key_of(s: String) -> String:
	return s.to_lower().replace(" ", "").replace("_", "")


## Resolves a block or item name (or a numeric id) to an id, or -1.
func find_id(name: String) -> int:
	if name.is_valid_int():
		return int(name)
	return int(_name_to_id.get(_key_of(name), -1))


func _arg_float(args: Array, idx: int, fallback: float) -> float:
	if idx >= args.size():
		return fallback
	var s := str(args[idx])
	return float(s) if s.is_valid_float() else fallback


# ================================================================ commands
func _register_all() -> void:
	register("help", "/help [command]", "List commands, or explain one.",
		LEVEL_ANY, _cmd_help)
	register("pos", "/pos", "Print your coordinates and the chunk you are in.",
		LEVEL_ANY, _cmd_pos)
	register("seed", "/seed", "Print the world seed.", LEVEL_ANY, _cmd_seed)
	register("gamemode", "/gamemode <creative|survival>",
		"Switch between creative and survival without restarting.",
		LEVEL_OP, _cmd_gamemode, ["gm"])
	register("give", "/give <block> [count]", "Put a stack of a block or item in your bag.",
		LEVEL_OP, _cmd_give)
	register("clear", "/clear", "Empty the backpack, hotbar and crafting grid.",
		LEVEL_OP, _cmd_clear)
	register("time", "/time set <day|noon|night|midnight|0..1>",
		"Set the time of day.", LEVEL_OP, _cmd_time)
	register("weather", "/weather <clear|rain>", "Accepted for completeness.",
		LEVEL_OP, _cmd_weather)
	register("tp", "/tp <x> <y> <z>", "Teleport to a position.",
		LEVEL_OP, _cmd_tp, ["teleport"])
	register("spawn", "/spawn", "Teleport back to the world spawn.",
		LEVEL_OP, _cmd_spawn)
	register("fly", "/fly [on|off]", "Toggle flight (creative only).",
		LEVEL_OP, _cmd_fly)
	register("heal", "/heal", "Refill health and hunger.", LEVEL_OP, _cmd_heal)
	register("kill", "/kill", "Kill yourself, even in creative.",
		LEVEL_OP, _cmd_kill)
	register("fog", "/fog <scale|auto>", "Stretch or reset the distant fog.",
		LEVEL_OP, _cmd_fog)
	register("rd", "/rd <chunks>", "Set the render distance for this world.",
		LEVEL_OP, _cmd_rd, ["renderdistance"])


func _cmd_help(args: Array) -> void:
	if args.size() > 0:
		var key := _resolve(str(args[0]))
		if key == "":
			output.emit(I18n.tf("Unknown command: %s.", [str(args[0])]))
			return
		var e: Dictionary = _registry[key]
		output.emit("%s  -  %s  [%s]" % [e["usage"], e["help"], _level_name(int(e["level"]))])
		return
	output.emit(I18n.tf("%d commands. Type /help <command> for detail.",
		[_order.size()]))
	for n in _order:
		var e2: Dictionary = _registry[n]
		if int(e2["level"]) <= level:
			output.emit("  %s" % e2["usage"])


func _level_name(l: int) -> String:
	match l:
		LEVEL_ADMIN:
			return "admin"
		LEVEL_OP:
			return "operator"
	return "everyone"


func _cmd_pos(_args: Array) -> void:
	var p: Vector3 = player.global_position
	var c := Vector2i(floori(p.x) >> 4, floori(p.z) >> 4)
	output.emit(I18n.tf("Position: %.1f %.1f %.1f  (chunk %d %d, %s)", [
		p.x, p.y, p.z, c.x, c.y,
		"creative" if player.creative else "survival"]))


func _cmd_seed(_args: Array) -> void:
	output.emit(I18n.tf("Seed: %d", [world.seed_value]))


func _cmd_gamemode(args: Array) -> void:
	if args.is_empty():
		output.emit("/gamemode <creative|survival>")
		return
	var want := str(args[0]).to_lower()
	var creative := false
	match want:
		"creative", "c", "1":
			creative = true
		"survival", "s", "0":
			creative = false
		_:
			output.emit("/gamemode <creative|survival>")
			return
	player.creative = creative
	if not creative:
		player.flying = false
	player.hunger_changed.emit()
	if creative:
		player.fill_creative_hotbar()
	output.emit(I18n.tf("Game mode set to %s.", [I18n.t("Creative" if creative else "Survival")]))


func _cmd_give(args: Array) -> void:
	if args.is_empty():
		output.emit("/give <block> [count]")
		return
	var id := find_id(str(args[0]))
	if id <= 0:
		output.emit(I18n.tf("No block or item named %s.", [str(args[0])]))
		return
	var count := int(_arg_float(args, 1, 64.0))
	count = clampi(count, 1, 6400)
	player.give(id, count)
	output.emit(I18n.tf("Gave %d x %s.", [count, Items.name_of(id)]))


func _cmd_clear(_args: Array) -> void:
	player.reset_inventory()
	output.emit(I18n.t("Inventory cleared."))


func _cmd_time(args: Array) -> void:
	var v := str(args[0]).to_lower() if args.size() > 0 else ""
	if v == "set" and args.size() > 1:
		v = str(args[1]).to_lower()
	var t := -1.0
	match v:
		"day", "morning":
			t = 0.30
		"noon":
			t = 0.50
		"sunset", "dusk":
			t = 0.75
		"night":
			t = 0.85
		"midnight":
			t = 0.0
		"sunrise", "dawn":
			t = 0.25
	if t < 0.0 and v.is_valid_float():
		t = fposmod(float(v), 1.0)
	if t < 0.0:
		output.emit("/time set <day|noon|night|midnight|0..1>")
		return
	sky.time_of_day = t
	output.emit(I18n.tf("Time set to %.2f.", [t]))


func _cmd_weather(_args: Array) -> void:
	output.emit(I18n.t("There is no weather yet; the sky is always clear."))


func _cmd_tp(args: Array) -> void:
	if args.size() < 3:
		output.emit("/tp <x> <y> <z>")
		return
	if not (str(args[0]).is_valid_float() and str(args[1]).is_valid_float()
			and str(args[2]).is_valid_float()):
		output.emit("/tp <x> <y> <z>")
		return
	# Clamped to the world's own bounds: without this, `/tp 0 5000 0` puts the player
	# above the ceiling, where there is no block to land on and nothing to stop the fall.
	var p := Vector3(float(args[0]),
		clampf(float(args[1]), float(VoxelTerrain.MIN_Y), float(VoxelTerrain.MAX_Y - 1)),
		float(args[2]))
	player.place_at(p)
	player.velocity = Vector3.ZERO
	output.emit(I18n.tf("Teleported to %.1f %.1f %.1f.", [p.x, p.y, p.z]))


func _cmd_spawn(_args: Array) -> void:
	var p: Vector3 = world.terrain.find_spawn()
	player.place_at(world.safe_spawn_near(p + Vector3(0, 1, 0)))
	player.velocity = Vector3.ZERO
	output.emit(I18n.t("Teleported to the world spawn."))


func _cmd_fly(args: Array) -> void:
	if not player.creative:
		output.emit(I18n.t("Flight is creative-only. Try /gamemode creative."))
		return
	var want := str(args[0]).to_lower() if args.size() > 0 else ("off" if player.flying else "on")
	player.flying = want in ["on", "true", "1", "yes"]
	output.emit(I18n.tf("Flight %s.", [I18n.t("ON" if player.flying else "OFF")]))


func _cmd_heal(_args: Array) -> void:
	player.heal_all()
	output.emit(I18n.t("Health and hunger restored."))


func _cmd_kill(_args: Array) -> void:
	player.kill()
	output.emit(I18n.t("You died."))


func _cmd_fog(args: Array) -> void:
	if args.is_empty() or str(args[0]).to_lower() == "auto":
		Settings.fog_scale = 1.0
		Settings.save_settings()
		sky.apply_fog()
		output.emit(I18n.t("Fog reset to automatic."))
		return
	var v := _arg_float(args, 0, -1.0)
	if v <= 0.0:
		output.emit("/fog <scale|auto>   (scale 0.3 - 4.0, higher sees further)")
		return
	Settings.fog_scale = clampf(v, 0.3, 4.0)
	Settings.save_settings()
	sky.apply_fog()
	output.emit(I18n.tf("Fog distance scale set to %.2f.", [Settings.fog_scale]))


func _cmd_rd(args: Array) -> void:
	if args.is_empty() or not str(args[0]).is_valid_int():
		output.emit("/rd <chunks>")
		return
	var rd := clampi(int(args[0]), Settings.MIN_RD, Settings.max_render_distance())
	world.render_distance = rd
	world.request_rebuild()
	sky.set_render_distance(rd)
	output.emit(I18n.tf("Render distance set to %d chunks.", [rd]))