extends Node
## Block database + fully procedural 16x16 texture atlas.
## Every pixel of the game's world texture is generated at runtime, no assets.

const TILE := 16          # texture size
const PAD := 2            # gutter used to keep mipmaps from bleeding
const CELL := TILE + PAD * 2
const COLS := 8
const ROWS := 8
const TILES := 62

# ---------------------------------------------------------------- block ids
const AIR := 0
const STONE := 1
const GRASS := 2
const DIRT := 3
const COBBLESTONE := 4
const PLANKS := 5
const LOG := 6
const LEAVES := 7
const SAND := 8
const GLASS := 9
const WATER := 10
const BEDROCK := 11
const COAL_ORE := 12
const IRON_ORE := 13
const GOLD_ORE := 14
const DIAMOND_ORE := 15
const GRAVEL := 16
const SANDSTONE := 17
const BRICK := 18
const GLOWSTONE := 19
const OBSIDIAN := 20
const SNOW := 21
const ICE := 22
const TALL_GRASS := 23
const FLOWER_RED := 24
const FLOWER_YELLOW := 25
const CACTUS := 26
const TORCH := 27
const CRAFTING_TABLE := 28
const STONE_BRICK := 29
const IRON_BLOCK := 30
const GOLD_BLOCK := 31
const DIAMOND_BLOCK := 32
# ---------------------------------------------------------------- electrical ids
# The circuit set is a small power system, so it is named like one: copper ore and
# copper ingots make the wire, a battery is the always-on supply, an inverter is the
# NOT gate and a relay is the diode with a delay. The numeric ids never changed, so
# worlds saved under the old names still load.
const COPPER_ORE := 33
const BATTERY := 34
const WIRE := 35
const INVERTER := 36
const SWITCH := 37
const LAMP := 38
const RELAY := 39
const BUTTON := 40
const PISTON := 41
const PRESSURE_PLATE := 42
const CHEST := 43
const LADDER := 44
const FENCE := 45
const GLASS_PANE := 46
const DOOR := 47

# ---------------------------------------------------------------- item ids
const ITEM_STICK := 256
const ITEM_COAL := 257
const ITEM_IRON := 258
const ITEM_GOLD := 259
const ITEM_DIAMOND := 260
const ITEM_APPLE := 261
const ITEM_BREAD := 262
const ITEM_COPPER := 263
const ITEM_PISTON_ARM := 264

# ---------------------------------------------------------------- tile ids
const T_GRASS_TOP := 0
const T_GRASS_SIDE := 1
const T_DIRT := 2
const T_STONE := 3
const T_COBBLE := 4
const T_SAND := 5
const T_SANDSTONE_TOP := 6
const T_SANDSTONE_SIDE := 7
const T_LOG_SIDE := 8
const T_LOG_TOP := 9
const T_LEAVES := 10
const T_PLANKS := 11
const T_WATER := 12
const T_GLASS := 13
const T_BEDROCK := 14
const T_COAL := 15
const T_IRON := 16
const T_GOLD := 17
const T_DIAMOND := 18
const T_GRAVEL := 19
const T_BRICK := 20
const T_GLOWSTONE := 21
const T_OBSIDIAN := 22
const T_SNOW := 23
const T_ICE := 24
const T_TALLGRASS := 25
const T_FLOWER_RED := 26
const T_FLOWER_YELLOW := 27
const T_CACTUS_SIDE := 28
const T_CACTUS_TOP := 29
const T_TORCH := 30
const T_CRAFT_TOP := 31
const T_CRAFT_SIDE := 32
const T_IRON_BLOCK := 33
const T_GOLD_BLOCK := 34
const T_DIAMOND_BLOCK := 35
const T_STONE_BRICK := 36
const T_COPPER_ORE := 37
const T_BATTERY := 38
const T_WIRE_OFF := 39
const T_WIRE_ON := 40
const T_INV_OFF := 41
const T_INV_ON := 42
const T_SWITCH_OFF := 43
const T_SWITCH_ON := 44
const T_LAMP_OFF := 45
const T_LAMP_ON := 46
const T_RELAY_OFF := 47
const T_RELAY_ON := 48
const T_BUTTON_OFF := 49
const T_BUTTON_ON := 50
const T_PISTON_SIDE := 51
const T_PISTON_FACE := 52
const T_PLATE_OFF := 53
const T_PLATE_ON := 54
const T_CHEST_TOP := 55
const T_CHEST_SIDE := 56
const T_CHEST_FRONT := 57
const T_LADDER := 58
const T_FENCE := 59
const T_DOOR := 60
const T_PANE := 61

# kind: 0 = normal cube, 1 = alpha-cutout cube (leaves), 2 = translucent (water/glass/ice),
#       3 = crossed billboard (plants / torch), 4 = flat plate on the floor (dust, plate)
const K_CUBE := 0
const K_CUTOUT := 1
const K_TRANSLUCENT := 2
const K_CROSS := 3
const K_FLAT := 4

var defs: Array = []                 # id -> definition dictionary
var names: PackedStringArray = []
var solid: PackedByteArray = []      # blocks player movement
var occluder: PackedByteArray = []   # hides neighbouring faces / casts AO
var kind: PackedByteArray = []
var emission: PackedByteArray = []
var hardness: PackedFloat32Array = []
var drops: PackedInt32Array = []
var liquid: PackedByteArray = []
var tile_top: PackedInt32Array = []
var tile_bottom: PackedInt32Array = []
var tile_side: PackedInt32Array = []

var atlas_tex: ImageTexture
var tile_uv: Array = []              # tile id -> Rect2 (uv space)
var tile_images: Array = []          # tile id -> Image (used to build item icons)

var mat_opaque: StandardMaterial3D
var mat_cutout: StandardMaterial3D
var mat_water: StandardMaterial3D
var mat_cross: StandardMaterial3D


func _ready() -> void:
	_build_defs()
	_build_atlas()
	_build_materials()


# ================================================================ definitions
func _def(id: int, nm: String, faces, k: int, hard: float, drop_id: int, em: int = 0) -> void:
	var faces_arr: Array = faces if faces is Array else [faces, faces, faces]
	defs[id] = {
		"id": id, "name": nm,
		"top": int(faces_arr[0]), "bottom": int(faces_arr[1]), "side": int(faces_arr[2]),
		"kind": k, "hardness": hard, "drop": drop_id, "emission": em,
	}


func _build_defs() -> void:
	defs.resize(512)
	names.resize(512)
	solid.resize(512)
	occluder.resize(512)
	kind.resize(512)
	emission.resize(512)
	hardness.resize(512)
	drops.resize(512)
	liquid.resize(512)
	tile_top.resize(512)
	tile_bottom.resize(512)
	tile_side.resize(512)
	for i in 512:
		names[i] = ""
		drops[i] = -1
		tile_top[i] = T_STONE
		tile_bottom[i] = T_STONE
		tile_side[i] = T_STONE

	_def(AIR, "Air", T_STONE, K_CUBE, 0.0, -1)
	_def(STONE, "Stone", T_STONE, K_CUBE, 1.5, COBBLESTONE)
	_def(GRASS, "Grass Block", [T_GRASS_TOP, T_DIRT, T_GRASS_SIDE], K_CUBE, 0.6, DIRT)
	_def(DIRT, "Dirt", T_DIRT, K_CUBE, 0.5, DIRT)
	_def(COBBLESTONE, "Cobblestone", T_COBBLE, K_CUBE, 2.0, COBBLESTONE)
	_def(PLANKS, "Oak Planks", T_PLANKS, K_CUBE, 2.0, PLANKS)
	_def(LOG, "Oak Log", [T_LOG_TOP, T_LOG_TOP, T_LOG_SIDE], K_CUBE, 2.0, LOG)
	_def(LEAVES, "Oak Leaves", T_LEAVES, K_CUTOUT, 0.2, LEAVES)
	_def(SAND, "Sand", T_SAND, K_CUBE, 0.5, SAND)
	_def(GLASS, "Glass", T_GLASS, K_TRANSLUCENT, 0.3, GLASS)
	_def(WATER, "Water", T_WATER, K_TRANSLUCENT, 100.0, -1)
	_def(BEDROCK, "Bedrock", T_BEDROCK, K_CUBE, -1.0, -1)
	_def(COAL_ORE, "Coal Ore", T_COAL, K_CUBE, 3.0, ITEM_COAL)
	_def(IRON_ORE, "Iron Ore", T_IRON, K_CUBE, 3.0, ITEM_IRON)
	_def(GOLD_ORE, "Gold Ore", T_GOLD, K_CUBE, 3.0, ITEM_GOLD)
	_def(DIAMOND_ORE, "Diamond Ore", T_DIAMOND, K_CUBE, 3.0, ITEM_DIAMOND)
	_def(GRAVEL, "Gravel", T_GRAVEL, K_CUBE, 0.6, GRAVEL)
	_def(SANDSTONE, "Sandstone", [T_SANDSTONE_TOP, T_SANDSTONE_TOP, T_SANDSTONE_SIDE], K_CUBE, 0.8, SANDSTONE)
	_def(BRICK, "Bricks", T_BRICK, K_CUBE, 2.0, BRICK)
	_def(GLOWSTONE, "Glowstone", T_GLOWSTONE, K_CUBE, 0.3, GLOWSTONE, 15)
	_def(OBSIDIAN, "Obsidian", T_OBSIDIAN, K_CUBE, 12.0, OBSIDIAN)
	_def(SNOW, "Snow Block", T_SNOW, K_CUBE, 0.2, SNOW)
	_def(ICE, "Ice", T_ICE, K_TRANSLUCENT, 0.4, ICE)
	_def(TALL_GRASS, "Grass", T_TALLGRASS, K_CROSS, 0.05, -1)
	_def(FLOWER_RED, "Poppy", T_FLOWER_RED, K_CROSS, 0.05, FLOWER_RED)
	_def(FLOWER_YELLOW, "Dandelion", T_FLOWER_YELLOW, K_CROSS, 0.05, FLOWER_YELLOW)
	_def(CACTUS, "Cactus", [T_CACTUS_TOP, T_CACTUS_TOP, T_CACTUS_SIDE], K_CUBE, 0.4, CACTUS)
	_def(TORCH, "Torch", T_TORCH, K_CROSS, 0.05, TORCH, 14)
	_def(CRAFTING_TABLE, "Crafting Table", [T_CRAFT_TOP, T_PLANKS, T_CRAFT_SIDE], K_CUBE, 2.0, CRAFTING_TABLE)

	# ---- building blocks
	_def(STONE_BRICK, "Stone Bricks", T_STONE_BRICK, K_CUBE, 2.0, STONE_BRICK)
	_def(IRON_BLOCK, "Block of Iron", T_IRON_BLOCK, K_CUBE, 4.0, IRON_BLOCK)
	_def(GOLD_BLOCK, "Block of Gold", T_GOLD_BLOCK, K_CUBE, 3.0, GOLD_BLOCK)
	_def(DIAMOND_BLOCK, "Block of Diamond", T_DIAMOND_BLOCK, K_CUBE, 4.0, DIAMOND_BLOCK)
	_def(FENCE, "Oak Fence", T_FENCE, K_CUTOUT, 1.5, FENCE)
	_def(LADDER, "Ladder", T_LADDER, K_CUTOUT, 0.4, LADDER)
	_def(GLASS_PANE, "Glass Pane", T_PANE, K_TRANSLUCENT, 0.3, GLASS_PANE)
	_def(DOOR, "Oak Door", T_DOOR, K_CUTOUT, 2.0, DOOR)
	_def(CHEST, "Chest", [T_CHEST_TOP, T_CHEST_TOP, T_CHEST_SIDE], K_CUBE, 2.0, CHEST)

	# ---- power system. Every one of these is a real analogue of an electrical part,
	# which is the point: a switch is a knife switch, the wire is the conductor, a
	# battery is the always-on supply, an inverter is a NOT gate, a relay is a diode
	# with a delay, a piston is an actuator, a pressure plate is a sensor, and a lamp
	# is the indicator.
	_def(COPPER_ORE, "Copper Ore", T_COPPER_ORE, K_CUBE, 3.0, ITEM_COPPER)
	_def(BATTERY, "Battery", T_BATTERY, K_CUBE, 3.0, BATTERY)
	_def(WIRE, "Wire", T_WIRE_OFF, K_FLAT, 0.0, WIRE)
	_def(INVERTER, "Inverter", T_INV_ON, K_CROSS, 0.05, INVERTER)
	_def(SWITCH, "Switch", T_SWITCH_OFF, K_FLAT, 0.5, SWITCH)
	_def(LAMP, "Lamp", T_LAMP_OFF, K_CUBE, 0.3, LAMP)
	_def(RELAY, "Signal Relay", T_RELAY_OFF, K_FLAT, 0.3, RELAY)
	_def(BUTTON, "Button", T_BUTTON_OFF, K_FLAT, 0.5, BUTTON)
	_def(PISTON, "Piston", [T_PISTON_FACE, T_STONE, T_PISTON_SIDE], K_CUBE, 1.5, PISTON)
	_def(PRESSURE_PLATE, "Pressure Plate", T_PLATE_OFF, K_FLAT, 0.3, PRESSURE_PLATE)

	# non-block items share the same id space so an inventory slot is just an int
	names[ITEM_STICK] = "Stick"
	names[ITEM_COAL] = "Coal"
	names[ITEM_IRON] = "Iron Ingot"
	names[ITEM_GOLD] = "Gold Ingot"
	names[ITEM_DIAMOND] = "Diamond"
	names[ITEM_APPLE] = "Apple"
	names[ITEM_BREAD] = "Bread"
	names[ITEM_COPPER] = "Copper Ingot"
	names[ITEM_PISTON_ARM] = "Piston Arm"

	for id in range(0, 512):
		var d = defs[id]
		if d == null:
			continue
		kind[id] = int(d["kind"])
		hardness[id] = float(d["hardness"])
		drops[id] = int(d["drop"])
		emission[id] = int(d["emission"])
		tile_top[id] = int(d["top"])
		tile_bottom[id] = int(d["bottom"])
		tile_side[id] = int(d["side"])
		if id != AIR and str(d["name"]) != "":
			names[id] = str(d["name"])

	# movement blocking: everything except air, water and plants
	for id in range(0, 512):
		if defs[id] == null:
			continue
		solid[id] = 0
		occluder[id] = 0
		liquid[id] = 0
		match kind[id]:
			K_CUBE:
				solid[id] = 1
				occluder[id] = 1
			K_CUTOUT:
				solid[id] = 1
			K_TRANSLUCENT:
				if id != WATER:
					solid[id] = 1
			K_FLAT:
				# dust and plates lie on the floor: you walk over them, so they must
				# not block movement, and they must not occlude either or they would
				# cut a hole in the face of the block they sit on
				pass
		if id == WATER:
			liquid[id] = 1
	# a few blocks override the kind default
	# a fence is a solid obstacle even though it is drawn as a cutout post
	solid[FENCE] = 1
	# a ladder is climbable, which means you can walk *into* its cell
	solid[LADDER] = 0
	# glass panes and doors are solid to walk into, but see-through
	solid[GLASS_PANE] = 1
	solid[DOOR] = 1
	occluder[DOOR] = 0
	# air must never occlude and never block movement
	solid[AIR] = 0
	occluder[AIR] = 0
	kind[AIR] = K_CUBE


func is_block_item(id: int) -> bool:
	return id > 0 and id < 256 and defs[id] != null


## Circuit role, so the solver and the mesher agree on what a block is:
##   0 = not part of a circuit
##   1 = wire (carries a level, decays with distance)
##   2 = source (drives a level into its own cell)
##   3 = consumer (reacts to a level)
##   4 = diode (repeater: input behind, output in front, delayed)
func circuit_kind(id: int) -> int:
	match id:
		WIRE:
			return 1
		SWITCH, BUTTON, PRESSURE_PLATE, BATTERY, INVERTER:
			return 2
		LAMP, PISTON:
			return 3
		RELAY:
			return 4
	return 0


## The block a component's lit state should be rendered with, or -1 when it renders
## the same either way.
func lit_tile(id: int, on: bool) -> int:
	match id:
		WIRE:
			return T_WIRE_ON if on else T_WIRE_OFF
		INVERTER:
			return T_INV_ON if on else T_INV_OFF
		SWITCH:
			return T_SWITCH_ON if on else T_SWITCH_OFF
		LAMP:
			return T_LAMP_ON if on else T_LAMP_OFF
		RELAY:
			return T_RELAY_ON if on else T_RELAY_OFF
		BUTTON:
			return T_BUTTON_ON if on else T_BUTTON_OFF
		PRESSURE_PLATE:
			return T_PLATE_ON if on else T_PLATE_OFF
	return -1


## Hunger restored by eating this item, 0 when it is not food.
func food_value(id: int) -> int:
	match id:
		ITEM_APPLE:
			return 4
		ITEM_BREAD:
			return 6
	return 0


var _avg_colors: Dictionary = {}


## A representative colour for a block/item, used by the break particles. Cached
## because averaging a 16x16 tile every hit would be wasteful.
func average_color(id: int) -> Color:
	if _avg_colors.has(id):
		return _avg_colors[id]
	var c := Color(0.6, 0.6, 0.6)
	var tile := -1
	if is_block_item(id):
		tile = int(defs[id]["top"])
	if tile >= 0 and tile < tile_images.size():
		var img: Image = tile_images[tile]
		var sr := 0.0
		var sg := 0.0
		var sb := 0.0
		var n := 0
		for y in TILE:
			for x in TILE:
				var px := img.get_pixel(x, y)
				if px.a <= 0.1:
					continue
				sr += px.r
				sg += px.g
				sb += px.b
				n += 1
		if n > 0:
			c = Color(sr / float(n), sg / float(n), sb / float(n))
	elif id == ITEM_APPLE:
		c = Color(0.80, 0.16, 0.14)
	elif id == ITEM_BREAD:
		c = Color(0.68, 0.46, 0.22)
	_avg_colors[id] = c
	return c


func display_name(id: int) -> String:
	if id < 0 or id >= names.size():
		return "?"
	var n := names[id]
	return n if n != "" else "?"


# ================================================================ texture atlas
func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


func _flat(img: Image, base: Color, amt: float, seed: int) -> void:
	var r := _rng(seed)
	for y in TILE:
		for x in TILE:
			var f := 1.0 + r.randf_range(-amt, amt)
			img.set_pixel(x, y, Color(
				clampf(base.r * f, 0.0, 1.0),
				clampf(base.g * f, 0.0, 1.0),
				clampf(base.b * f, 0.0, 1.0), base.a))


func _blob(img: Image, cx: int, cy: int, r: int, c: Color) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if x < 0 or y < 0 or x >= TILE or y >= TILE:
				continue
			var dx := (x - cx) * 1.0
			var dy := (y - cy) * 1.0
			if dx * dx + dy * dy <= r * r + 0.6:
				img.set_pixel(x, y, c)


func _ore(base_tile: int, ore_color: Color, seed: int) -> Image:
	var img: Image = _tile_image(base_tile)
	var r := _rng(seed)
	for i in 4 + r.randi_range(0, 2):
		var cx := r.randi_range(1, TILE - 2)
		var cy := r.randi_range(1, TILE - 2)
		var rr := r.randi_range(1, 2)
		var tint := r.randf_range(0.85, 1.15)
		_blob(img, cx, cy, rr, Color(
			clampf(ore_color.r * tint, 0, 1),
			clampf(ore_color.g * tint, 0, 1),
			clampf(ore_color.b * tint, 0, 1), 1.0))
	return img


func _tile_image(id: int) -> Image:
	var img := Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var r := _rng(1000 + id)
	match id:
		T_GRASS_TOP:
			_flat(img, Color(0.36, 0.62, 0.24), 0.13, 11)
			for i in 26:
				var x := r.randi_range(0, TILE - 1)
				var y := r.randi_range(0, TILE - 1)
				img.set_pixel(x, y, Color(0.30, 0.54, 0.20))
			for i in 14:
				var x2 := r.randi_range(0, TILE - 1)
				var y2 := r.randi_range(0, TILE - 1)
				img.set_pixel(x2, y2, Color(0.44, 0.70, 0.28))
		T_GRASS_SIDE:
			_flat(img, Color(0.42, 0.30, 0.19), 0.14, 12)
			for x in TILE:
				var d := 3 + r.randi_range(0, 2)
				for y in d:
					var f := 1.0 + r.randf_range(-0.10, 0.10)
					img.set_pixel(x, y, Color(0.36 * f, 0.62 * f, 0.24 * f))
				if d < TILE:
					img.set_pixel(x, d, Color(0.30, 0.52, 0.20))
		T_DIRT:
			_flat(img, Color(0.42, 0.30, 0.19), 0.16, 13)
			for i in 20:
				img.set_pixel(r.randi_range(0, 15), r.randi_range(0, 15), Color(0.35, 0.25, 0.15))
		T_STONE:
			_flat(img, Color(0.50, 0.50, 0.50), 0.10, 14)
			for i in 8:
				_blob(img, r.randi_range(1, 14), r.randi_range(1, 14), 1, Color(0.44, 0.44, 0.44))
		T_COBBLE:
			_flat(img, Color(0.38, 0.38, 0.38), 0.05, 15)
			var cells := [Vector2i(0, 0), Vector2i(8, 0), Vector2i(0, 8), Vector2i(8, 8),
				Vector2i(4, 4), Vector2i(12, 4), Vector2i(4, 12), Vector2i(12, 12)]
			for c in cells:
				var cx: int = c.x
				var cy: int = c.y
				for y in range(cy, cy + 8):
					for x in range(cx, cx + 8):
						var edge := x == cx or y == cy or x == cx + 7 or y == cy + 7
						var f := 1.0 + r.randf_range(-0.09, 0.14)
						var v := (0.42 if edge else 0.62) * f
						img.set_pixel(x % TILE, y % TILE, Color(v, v, v * 1.02))
		T_SAND:
			_flat(img, Color(0.85, 0.80, 0.60), 0.06, 16)
		T_SANDSTONE_TOP:
			_flat(img, Color(0.86, 0.82, 0.64), 0.05, 17)
			for i in 10:
				img.set_pixel(r.randi_range(0, 15), r.randi_range(0, 15), Color(0.80, 0.76, 0.58))
		T_SANDSTONE_SIDE:
			_flat(img, Color(0.84, 0.80, 0.62), 0.05, 18)
			for x in TILE:
				for y in [0, 1, 6, 7, 12, 13, 15]:
					img.set_pixel(x, y, Color(0.76, 0.72, 0.55))
		T_LOG_SIDE:
			_flat(img, Color(0.40, 0.29, 0.16), 0.10, 19)
			for x in TILE:
				if x % 5 == 2:
					for y in TILE:
						img.set_pixel(x, y, Color(0.31, 0.22, 0.11))
				elif x % 5 == 4:
					for y in TILE:
						img.set_pixel(x, y, Color(0.48, 0.35, 0.19))
		T_LOG_TOP:
			_flat(img, Color(0.60, 0.46, 0.28), 0.06, 20)
			for rr in [7, 5, 3, 1]:
				var col := Color(0.46, 0.34, 0.20)
				for a in 64:
					var ang := TAU * a / 64.0
					var x := int(7.5 + cos(ang) * rr)
					var y := int(7.5 + sin(ang) * rr)
					if x >= 0 and y >= 0 and x < TILE and y < TILE:
						img.set_pixel(x, y, col)
			_blob(img, 8, 8, 1, Color(0.52, 0.38, 0.22))
		T_LEAVES:
			_flat(img, Color(0.28, 0.50, 0.18), 0.22, 21)
			for i in 34:
				img.set_pixel(r.randi_range(0, 15), r.randi_range(0, 15), Color(0.20, 0.38, 0.13))
			for i in 3:
				var x := r.randi_range(0, 15)
				var y := r.randi_range(0, 15)
				img.set_pixel(x, y, Color(0, 0, 0, 0))
		T_PLANKS:
			_flat(img, Color(0.62, 0.46, 0.26), 0.07, 22)
			for y in TILE:
				if y % 4 == 3:
					for x in TILE:
						img.set_pixel(x, y, Color(0.44, 0.32, 0.17))
			for i in 22:
				var x2 := r.randi_range(0, 15)
				img.set_pixel(x2, r.randi_range(0, 15), Color(0.55, 0.40, 0.22))
			for y2 in TILE:
				var px := (y2 / 4) * 5 + 2
				if px < TILE:
					img.set_pixel(px, y2, Color(0.46, 0.33, 0.18))
		T_WATER:
			_flat(img, Color(0.20, 0.40, 0.85, 0.72), 0.07, 23)
			for x in TILE:
				var y := int(5.0 + sin(x * 0.7) * 1.6)
				img.set_pixel(x, y, Color(0.34, 0.55, 0.95, 0.80))
				var y3 := int(11.0 + sin(x * 0.5 + 1.2) * 1.4)
				img.set_pixel(x, y3, Color(0.30, 0.52, 0.92, 0.78))
		T_GLASS:
			_flat(img, Color(0.85, 0.93, 0.97, 0.12), 0.02, 24)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.92, 0.97, 1.0, 0.85))
				img.set_pixel(i, TILE - 1, Color(0.92, 0.97, 1.0, 0.85))
				img.set_pixel(0, i, Color(0.92, 0.97, 1.0, 0.85))
				img.set_pixel(TILE - 1, i, Color(0.92, 0.97, 1.0, 0.85))
			for i in 7:
				img.set_pixel(3 + i, 12 - i, Color(1, 1, 1, 0.55))
		T_BEDROCK:
			_flat(img, Color(0.30, 0.30, 0.32), 0.30, 25)
			for i in 26:
				_blob(img, r.randi_range(0, 15), r.randi_range(0, 15), 1, Color(0.16, 0.16, 0.18))
		T_COAL:
			img = _ore(T_STONE, Color(0.12, 0.12, 0.12), 26)
		T_IRON:
			img = _ore(T_STONE, Color(0.78, 0.58, 0.42), 27)
		T_GOLD:
			img = _ore(T_STONE, Color(0.95, 0.80, 0.25), 28)
		T_DIAMOND:
			img = _ore(T_STONE, Color(0.35, 0.92, 0.92), 29)
		T_GRAVEL:
			_flat(img, Color(0.47, 0.44, 0.42), 0.20, 30)
			for i in 40:
				var v := r.randf_range(0.30, 0.62)
				_blob(img, r.randi_range(0, 15), r.randi_range(0, 15), 1, Color(v, v * 0.95, v * 0.9))
		T_BRICK:
			_flat(img, Color(0.72, 0.72, 0.70), 0.04, 31)
			for row in 4:
				var oy := row * 4
				var off := 0 if row % 2 == 0 else 8
				for bx in range(-1, 3):
					var ox := bx * 8 + off
					for y in range(oy + 1, oy + 4):
						for x in range(ox + 1, ox + 8):
							var f := 1.0 + r.randf_range(-0.07, 0.07)
							if x >= 0 and x < TILE and y >= 0 and y < TILE:
								img.set_pixel(x, y, Color(0.60 * f, 0.26 * f, 0.20 * f))
		T_GLOWSTONE:
			_flat(img, Color(0.85, 0.70, 0.34), 0.12, 32)
			for i in 22:
				_blob(img, r.randi_range(0, 15), r.randi_range(0, 15), r.randi_range(1, 2), Color(1.0, 0.94, 0.62))
		T_OBSIDIAN:
			_flat(img, Color(0.11, 0.08, 0.17), 0.35, 33)
			for i in 16:
				img.set_pixel(r.randi_range(0, 15), r.randi_range(0, 15), Color(0.26, 0.18, 0.40))
		T_SNOW:
			_flat(img, Color(0.94, 0.96, 0.98), 0.04, 34)
			for i in 10:
				img.set_pixel(r.randi_range(0, 15), r.randi_range(0, 15), Color(0.86, 0.90, 0.96))
		T_ICE:
			_flat(img, Color(0.62, 0.80, 0.95, 0.80), 0.06, 35)
			for i in 6:
				var x := r.randi_range(0, 12)
				var y := r.randi_range(0, 12)
				for j in 4:
					img.set_pixel(x + j, y + j, Color(0.85, 0.94, 1.0, 0.85))
		T_TALLGRASS:
			for i in 9:
				var x := r.randi_range(1, TILE - 2)
				var h := r.randi_range(5, 11)
				var y0 := TILE - 1
				for y in range(y0, max(0, y0 - h), -1):
					var f := 1.0 - float(y0 - y) * 0.02
					img.set_pixel(x, y, Color(0.30 * f, 0.56 * f, 0.20 * f))
					if r.randf() < 0.25 and x + 1 < TILE:
						img.set_pixel(x + 1, y, Color(0.26 * f, 0.48 * f, 0.17 * f))
		T_FLOWER_RED:
			_stem(img, r)
			for p in [Vector2i(5, 4), Vector2i(9, 4), Vector2i(7, 2), Vector2i(7, 6), Vector2i(7, 4)]:
				img.set_pixel(p.x, p.y, Color(0.85, 0.18, 0.16))
			img.set_pixel(6, 4, Color(0.95, 0.35, 0.30))
			img.set_pixel(8, 3, Color(0.70, 0.12, 0.12))
		T_FLOWER_YELLOW:
			_stem(img, r)
			for p in [Vector2i(5, 4), Vector2i(9, 4), Vector2i(7, 2), Vector2i(7, 6)]:
				img.set_pixel(p.x, p.y, Color(0.95, 0.88, 0.20))
			img.set_pixel(7, 4, Color(0.85, 0.65, 0.12))
			img.set_pixel(6, 4, Color(1.0, 0.95, 0.45))
		T_CACTUS_SIDE:
			_flat(img, Color(0.24, 0.50, 0.24), 0.08, 36)
			for y in TILE:
				img.set_pixel(3, y, Color(0.17, 0.38, 0.17))
				img.set_pixel(12, y, Color(0.17, 0.38, 0.17))
				img.set_pixel(0, y, Color(0.18, 0.40, 0.18))
				img.set_pixel(15, y, Color(0.18, 0.40, 0.18))
			for i in 12:
				img.set_pixel(r.randi_range(1, 14), r.randi_range(0, 15), Color(0.82, 0.84, 0.72))
		T_CACTUS_TOP:
			_flat(img, Color(0.28, 0.56, 0.26), 0.08, 37)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.18, 0.40, 0.18))
				img.set_pixel(i, TILE - 1, Color(0.18, 0.40, 0.18))
				img.set_pixel(0, i, Color(0.18, 0.40, 0.18))
				img.set_pixel(TILE - 1, i, Color(0.18, 0.40, 0.18))
		T_TORCH:
			for y in range(6, 16):
				img.set_pixel(7, y, Color(0.45, 0.31, 0.16))
				img.set_pixel(8, y, Color(0.38, 0.26, 0.13))
			for y in range(2, 7):
				img.set_pixel(7, y, Color(1.0, 0.82, 0.30, 0.95))
				img.set_pixel(8, y, Color(1.0, 0.72, 0.20, 0.95))
			img.set_pixel(6, 4, Color(1.0, 0.92, 0.55, 0.9))
			img.set_pixel(9, 4, Color(1.0, 0.92, 0.55, 0.9))
			img.set_pixel(7, 1, Color(1.0, 0.95, 0.70, 0.85))
		T_CRAFT_TOP:
			_flat(img, Color(0.62, 0.46, 0.26), 0.06, 38)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.40, 0.29, 0.15))
				img.set_pixel(i, TILE - 1, Color(0.40, 0.29, 0.15))
				img.set_pixel(0, i, Color(0.40, 0.29, 0.15))
				img.set_pixel(TILE - 1, i, Color(0.40, 0.29, 0.15))
			for i in TILE:
				img.set_pixel(i, 5, Color(0.45, 0.33, 0.18))
				img.set_pixel(i, 10, Color(0.45, 0.33, 0.18))
				img.set_pixel(5, i, Color(0.45, 0.33, 0.18))
				img.set_pixel(10, i, Color(0.45, 0.33, 0.18))
		T_CRAFT_SIDE:
			_flat(img, Color(0.58, 0.43, 0.24), 0.06, 39)
			for y in TILE:
				if y % 5 == 4:
					for x in TILE:
						img.set_pixel(x, y, Color(0.42, 0.30, 0.16))
			for i in 5:
				img.set_pixel(3 + i, 4 + i, Color(0.34, 0.24, 0.13))
				img.set_pixel(4 + i, 4 + i, Color(0.34, 0.24, 0.13))
			for i in 6:
				img.set_pixel(9, 10 + i, Color(0.34, 0.24, 0.13))
				img.set_pixel(10, 10 + i, Color(0.30, 0.21, 0.12))
			for i in 5:
				img.set_pixel(8 + i, 11, Color(0.55, 0.55, 0.58))
		T_IRON_BLOCK:
			_flat(img, Color(0.86, 0.86, 0.88), 0.05, 40)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.70, 0.70, 0.73))
				img.set_pixel(i, TILE - 1, Color(0.66, 0.66, 0.70))
				img.set_pixel(0, i, Color(0.70, 0.70, 0.73))
				img.set_pixel(TILE - 1, i, Color(0.66, 0.66, 0.70))
			for i in 8:
				img.set_pixel(4 + i, 4, Color(0.94, 0.94, 0.96))
				img.set_pixel(4 + i, 11, Color(0.72, 0.72, 0.75))
		T_GOLD_BLOCK:
			_flat(img, Color(0.95, 0.80, 0.26), 0.06, 41)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.78, 0.63, 0.16))
				img.set_pixel(i, TILE - 1, Color(0.72, 0.58, 0.14))
				img.set_pixel(0, i, Color(0.78, 0.63, 0.16))
				img.set_pixel(TILE - 1, i, Color(0.72, 0.58, 0.14))
			for i in 8:
				img.set_pixel(4 + i, 4, Color(1.0, 0.94, 0.55))
				img.set_pixel(4 + i, 11, Color(0.82, 0.66, 0.18))
		T_DIAMOND_BLOCK:
			_flat(img, Color(0.36, 0.90, 0.90), 0.07, 42)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.22, 0.68, 0.70))
				img.set_pixel(i, TILE - 1, Color(0.20, 0.62, 0.66))
				img.set_pixel(0, i, Color(0.22, 0.68, 0.70))
				img.set_pixel(TILE - 1, i, Color(0.20, 0.62, 0.66))
			for i in 6:
				img.set_pixel(3 + i, 3 + i, Color(0.80, 1.0, 1.0))
				img.set_pixel(4 + i, 3 + i, Color(0.80, 1.0, 1.0))
				img.set_pixel(3 + i, 12 - i, Color(0.62, 0.95, 0.95))
		T_STONE_BRICK:
			_flat(img, Color(0.48, 0.48, 0.49), 0.06, 43)
			# four courses, offset like real brickwork
			for row in 4:
				var oy := row * 4
				var off := 0 if row % 2 == 0 else 8
				for bx in range(-1, 3):
					var ox := bx * 8 + off
					for x in range(ox, ox + 8):
						img.set_pixel(posmod(x, TILE), oy, Color(0.34, 0.34, 0.35))
						img.set_pixel(posmod(x, TILE), oy + 3, Color(0.34, 0.34, 0.35))
					img.set_pixel(posmod(ox + 7, TILE), oy + 1, Color(0.34, 0.34, 0.35))
					img.set_pixel(posmod(ox + 7, TILE), oy + 2, Color(0.34, 0.34, 0.35))
		T_COPPER_ORE:
			img = _ore(T_STONE, Color(0.82, 0.48, 0.20), 44)
		T_BATTERY:
			# a cell: dark case, copper end caps, and a charge mark across the middle
			_flat(img, Color(0.24, 0.25, 0.28), 0.05, 45)
			for x in TILE:
				for y in range(0, 3):
					img.set_pixel(x, y, Color(0.78, 0.48, 0.20))
				for y in range(13, 16):
					img.set_pixel(x, y, Color(0.56, 0.33, 0.13))
			for y in range(3, 13):
				img.set_pixel(1, y, Color(0.78, 0.48, 0.20))
				img.set_pixel(14, y, Color(0.78, 0.48, 0.20))
			for x in range(5, 11):
				img.set_pixel(x, 7, Color(0.98, 0.84, 0.36))
				img.set_pixel(x, 8, Color(0.98, 0.84, 0.36))
			for y in range(4, 12):
				img.set_pixel(4, y, Color(0.34, 0.35, 0.39))
				img.set_pixel(11, y, Color(0.34, 0.35, 0.39))
		T_WIRE_OFF:
			_wire(img, false)
		T_WIRE_ON:
			_wire(img, true)
		T_INV_OFF:
			_inverter(img, false)
		T_INV_ON:
			_inverter(img, true)
		T_SWITCH_OFF:
			_switch_tex(img, false)
		T_SWITCH_ON:
			_switch_tex(img, true)
		T_LAMP_OFF:
			_flat(img, Color(0.44, 0.32, 0.22), 0.08, 46)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.30, 0.22, 0.15))
				img.set_pixel(i, TILE - 1, Color(0.30, 0.22, 0.15))
				img.set_pixel(0, i, Color(0.30, 0.22, 0.15))
				img.set_pixel(TILE - 1, i, Color(0.30, 0.22, 0.15))
			for yy in range(3, 13):
				for xx in range(3, 13):
					img.set_pixel(xx, yy, Color(0.30, 0.20, 0.16))
			for i in 5:
				img.set_pixel(4 + i, 4 + i, Color(0.38, 0.26, 0.20))
		T_LAMP_ON:
			_flat(img, Color(0.98, 0.82, 0.50), 0.06, 47)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.52, 0.38, 0.22))
				img.set_pixel(i, TILE - 1, Color(0.52, 0.38, 0.22))
				img.set_pixel(0, i, Color(0.52, 0.38, 0.22))
				img.set_pixel(TILE - 1, i, Color(0.52, 0.38, 0.22))
			for yy in range(3, 13):
				for xx in range(3, 13):
					var f := 1.0 + r.randf_range(-0.05, 0.05)
					img.set_pixel(xx, yy, Color(1.0 * f, 0.90 * f, 0.58 * f))
			for i in 6:
				img.set_pixel(4 + i, 4 + i, Color(1.0, 1.0, 0.86))
				img.set_pixel(4 + i, 3 + i, Color(1.0, 1.0, 0.86))
		T_RELAY_OFF:
			_relay(img, Color(0.62, 0.40, 0.19))
		T_RELAY_ON:
			_relay(img, Color(1.0, 0.78, 0.32))
		T_BUTTON_OFF:
			_button(img, Color(0.72, 0.48, 0.22))
		T_BUTTON_ON:
			_button(img, Color(1.0, 0.78, 0.34))
		T_PISTON_SIDE:
			_flat(img, Color(0.52, 0.50, 0.46), 0.07, 48)
			for y in range(0, 5):
				for x in TILE:
					img.set_pixel(x, y, Color(0.62, 0.46, 0.26))
			for x in TILE:
				img.set_pixel(x, 5, Color(0.40, 0.29, 0.15))
			for i in 6:
				img.set_pixel(2 + i, 9, Color(0.72, 0.72, 0.74))
				img.set_pixel(2 + i, 13, Color(0.40, 0.40, 0.42))
		T_PISTON_FACE:
			_flat(img, Color(0.62, 0.46, 0.26), 0.06, 49)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.40, 0.29, 0.15))
				img.set_pixel(i, TILE - 1, Color(0.40, 0.29, 0.15))
				img.set_pixel(0, i, Color(0.40, 0.29, 0.15))
				img.set_pixel(TILE - 1, i, Color(0.40, 0.29, 0.15))
			for yy in range(3, 13):
				for xx in range(3, 13):
					img.set_pixel(xx, yy, Color(0.74, 0.74, 0.76))
			for i in 4:
				img.set_pixel(5 + i, 5 + i, Color(0.86, 0.86, 0.88))
		T_PLATE_OFF:
			_plate(img, Color(0.60, 0.58, 0.55))
		T_PLATE_ON:
			_plate(img, Color(0.78, 0.74, 0.70))
		T_CHEST_TOP:
			_flat(img, Color(0.62, 0.44, 0.22), 0.05, 50)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.40, 0.28, 0.14))
				img.set_pixel(i, TILE - 1, Color(0.40, 0.28, 0.14))
				img.set_pixel(0, i, Color(0.40, 0.28, 0.14))
				img.set_pixel(TILE - 1, i, Color(0.40, 0.28, 0.14))
			for x in TILE:
				img.set_pixel(x, 8, Color(0.46, 0.32, 0.16))
		T_CHEST_SIDE:
			_flat(img, Color(0.60, 0.43, 0.22), 0.05, 51)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.38, 0.27, 0.13))
				img.set_pixel(i, TILE - 1, Color(0.38, 0.27, 0.13))
				img.set_pixel(0, i, Color(0.38, 0.27, 0.13))
				img.set_pixel(TILE - 1, i, Color(0.38, 0.27, 0.13))
			for y in range(1, 8):
				img.set_pixel(7, y, Color(0.44, 0.31, 0.16))
				img.set_pixel(8, y, Color(0.44, 0.31, 0.16))
		T_CHEST_FRONT:
			_flat(img, Color(0.60, 0.43, 0.22), 0.05, 52)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.38, 0.27, 0.13))
				img.set_pixel(i, TILE - 1, Color(0.38, 0.27, 0.13))
				img.set_pixel(0, i, Color(0.38, 0.27, 0.13))
				img.set_pixel(TILE - 1, i, Color(0.38, 0.27, 0.13))
			for x in TILE:
				img.set_pixel(x, 8, Color(0.44, 0.31, 0.16))
			# the latch
			for yy in range(6, 11):
				for xx in range(7, 9):
					img.set_pixel(xx, yy, Color(0.82, 0.76, 0.36))
			img.set_pixel(7, 8, Color(0.42, 0.38, 0.16))
			img.set_pixel(8, 8, Color(0.42, 0.38, 0.16))
		T_LADDER:
			for y in TILE:
				img.set_pixel(3, y, Color(0.48, 0.34, 0.17))
				img.set_pixel(4, y, Color(0.40, 0.28, 0.14))
				img.set_pixel(11, y, Color(0.48, 0.34, 0.17))
				img.set_pixel(12, y, Color(0.40, 0.28, 0.14))
			for y in [1, 5, 9, 13]:
				for x in range(4, 12):
					img.set_pixel(x, y, Color(0.54, 0.39, 0.20))
					img.set_pixel(x, y + 1, Color(0.44, 0.31, 0.16))
		T_FENCE:
			for y in TILE:
				img.set_pixel(3, y, Color(0.48, 0.34, 0.17))
				img.set_pixel(4, y, Color(0.40, 0.28, 0.14))
				img.set_pixel(11, y, Color(0.48, 0.34, 0.17))
				img.set_pixel(12, y, Color(0.40, 0.28, 0.14))
			for y in [5, 10]:
				for x in range(3, 13):
					img.set_pixel(x, y, Color(0.54, 0.39, 0.20))
					img.set_pixel(x, y + 1, Color(0.42, 0.30, 0.15))
		T_DOOR:
			_flat(img, Color(0.60, 0.44, 0.23), 0.05, 53)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.38, 0.27, 0.13))
				img.set_pixel(i, TILE - 1, Color(0.38, 0.27, 0.13))
				img.set_pixel(0, i, Color(0.38, 0.27, 0.13))
				img.set_pixel(TILE - 1, i, Color(0.38, 0.27, 0.13))
			for x in range(3, 13):
				img.set_pixel(x, 5, Color(0.46, 0.33, 0.17))
				img.set_pixel(x, 10, Color(0.46, 0.33, 0.17))
			# handle
			for yy in range(6, 10):
				img.set_pixel(11, yy, Color(0.80, 0.74, 0.34))
			img.set_pixel(11, 6, Color(0.55, 0.50, 0.22))
		T_PANE:
			_flat(img, Color(0.85, 0.93, 0.97, 0.10), 0.02, 54)
			for i in TILE:
				img.set_pixel(i, 0, Color(0.90, 0.96, 1.0, 0.80))
				img.set_pixel(i, TILE - 1, Color(0.90, 0.96, 1.0, 0.80))
			for i in TILE:
				img.set_pixel(0, i, Color(0.90, 0.96, 1.0, 0.55))
				img.set_pixel(TILE - 1, i, Color(0.90, 0.96, 1.0, 0.55))
			for i in 6:
				img.set_pixel(4 + i, 10 - i, Color(1, 1, 1, 0.45))
	return img


## A wire laid on the floor: a copper conductor inside a dark sheath, drawn as a cross
## so a run of them reads as one connected circuit from any direction. Only the core
## changes when it is live, so a powered run glows like current in a cable instead of
## changing colour altogether.
func _wire(img: Image, live: bool) -> void:
	var rim := Color(0.16, 0.13, 0.12)
	var core := Color(1.0, 0.78, 0.32) if live else Color(0.62, 0.40, 0.19)
	# the sheath first, so the conductor can be drawn over it unbroken
	for x in TILE:
		img.set_pixel(x, 6, rim)
		img.set_pixel(x, 9, rim)
	for y in TILE:
		img.set_pixel(6, y, rim)
		img.set_pixel(9, y, rim)
	for x in TILE:
		img.set_pixel(x, 7, core)
		img.set_pixel(x, 8, core)
	for y in TILE:
		img.set_pixel(7, y, core)
		img.set_pixel(8, y, core)
	if live:
		_blob(img, 7, 7, 1, Color(1.0, 0.94, 0.66))


## An inverter: a small ceramic package on two legs with an indicator window. It lights
## when it is driving its output, which is when its input is *dead* -- the NOT gate.
func _inverter(img: Image, on: bool) -> void:
	for y in range(12, 16):
		img.set_pixel(6, y, Color(0.62, 0.62, 0.66))
		img.set_pixel(9, y, Color(0.62, 0.62, 0.66))
	for y in range(5, 13):
		for x in range(4, 12):
			img.set_pixel(x, y, Color(0.20, 0.21, 0.24))
	for x in range(4, 12):
		img.set_pixel(x, 5, Color(0.32, 0.33, 0.37))
		img.set_pixel(x, 12, Color(0.12, 0.12, 0.14))
	var lit := Color(1.0, 0.86, 0.42) if on else Color(0.27, 0.22, 0.17)
	for y in range(7, 11):
		for x in range(6, 10):
			img.set_pixel(x, y, lit)
	if on:
		img.set_pixel(7, 8, Color(1.0, 1.0, 0.88))
		img.set_pixel(8, 9, Color(1.0, 1.0, 0.88))


## A switch: a metal base carrying two copper contacts, with a blade that tips onto
## one of them. Standing up it is open; lying across both it is closed.
func _switch_tex(img: Image, on: bool) -> void:
	for y in range(5, 12):
		for x in range(3, 13):
			img.set_pixel(x, y, Color(0.44, 0.43, 0.42))
	for x in range(3, 13):
		img.set_pixel(x, 5, Color(0.58, 0.57, 0.56))
		img.set_pixel(x, 11, Color(0.30, 0.29, 0.28))
	for y in range(6, 11):
		img.set_pixel(4, y, Color(0.80, 0.50, 0.21))
		img.set_pixel(11, y, Color(0.80, 0.50, 0.21))
	var bx := 9 if on else 5
	for y in range(4, 10):
		img.set_pixel(bx, y, Color(0.92, 0.64, 0.27))
		img.set_pixel(bx + 1, y, Color(0.74, 0.48, 0.18))
	img.set_pixel(bx, 3, Color(0.98, 0.74, 0.36))
	img.set_pixel(bx + 1, 3, Color(0.82, 0.58, 0.24))


## A signal relay: a ceramic slab carrying the wire in and out, with a diode symbol in
## the middle pointing the way the signal travels.
func _relay(img: Image, col: Color) -> void:
	for y in range(3, 13):
		for x in range(2, 14):
			img.set_pixel(x, y, Color(0.34, 0.35, 0.38))
	for x in range(2, 14):
		img.set_pixel(x, 3, Color(0.48, 0.49, 0.53))
		img.set_pixel(x, 12, Color(0.20, 0.21, 0.23))
	# wire in, wire out
	for x in range(2, 6):
		img.set_pixel(x, 7, col)
		img.set_pixel(x, 8, col)
	for x in range(10, 14):
		img.set_pixel(x, 7, col)
		img.set_pixel(x, 8, col)
	# the diode triangle, pointing the way the signal travels
	for i in 4:
		for y in range(7 - i, 9 + i):
			img.set_pixel(6 + i, y, col.lightened(0.3))
	for y in range(5, 11):
		img.set_pixel(10, y, col.darkened(0.2))


func _button(img: Image, col: Color) -> void:
	for y in range(4, 12):
		for x in range(4, 12):
			img.set_pixel(x, y, Color(0.48, 0.48, 0.50))
	for x in range(4, 12):
		img.set_pixel(x, 4, Color(0.34, 0.34, 0.36))
		img.set_pixel(x, 11, Color(0.34, 0.34, 0.36))
	for y in range(6, 10):
		for x in range(6, 10):
			img.set_pixel(x, y, col)


func _plate(img: Image, col: Color) -> void:
	for y in range(2, 14):
		for x in range(2, 14):
			img.set_pixel(x, y, col)
	for x in range(2, 14):
		img.set_pixel(x, 2, col.darkened(0.3))
		img.set_pixel(x, 13, col.darkened(0.3))
	for y in range(2, 14):
		img.set_pixel(2, y, col.darkened(0.3))
		img.set_pixel(13, y, col.darkened(0.3))


func _stem(img: Image, r: RandomNumberGenerator) -> void:
	var lean := 0
	for y in range(15, 5, -1):
		img.set_pixel(7 + lean, y, Color(0.28, 0.52, 0.20))
		if r.randf() < 0.35:
			lean = clampi(lean + (1 if r.randf() < 0.5 else -1), -1, 1)
	if lean != 0:
		img.set_pixel(7, 13, Color(0.32, 0.58, 0.24))


func _build_atlas() -> void:
	var w := COLS * CELL
	var h := ROWS * CELL
	var atlas := Image.create(w, h, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	for t in TILES:
		var src := _tile_image(t)
		tile_images.append(src)
		var col := t % COLS
		var row := t / COLS
		var ox := col * CELL
		var oy := row * CELL
		for y in CELL:
			for x in CELL:
				var sx := clampi(x - PAD, 0, TILE - 1)
				var sy := clampi(y - PAD, 0, TILE - 1)
				atlas.set_pixel(ox + x, oy + y, src.get_pixel(sx, sy))
		tile_uv.append(Rect2(
			float(col * CELL + PAD) / float(w),
			float(row * CELL + PAD) / float(h),
			float(TILE) / float(w),
			float(TILE) / float(h)))
	atlas.generate_mipmaps()
	atlas_tex = ImageTexture.create_from_image(atlas)


func tile_rect(t: int) -> Rect2:
	return tile_uv[clampi(t, 0, tile_uv.size() - 1)]


func _build_materials() -> void:
	mat_opaque = _base_material()
	mat_opaque.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	mat_cutout = _base_material()
	mat_cutout.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat_cutout.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat_cutout.alpha_scissor_threshold = 0.5

	mat_water = _base_material()
	mat_water.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat_water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_water.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat_water.roughness = 0.15
	mat_water.metallic = 0.25
	mat_water.metallic_specular = 0.9

	mat_cross = _base_material()
	mat_cross.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat_cross.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat_cross.alpha_scissor_threshold = 0.5
	mat_cross.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat_cross.roughness = 0.9


func _base_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = atlas_tex
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.22
	m.texture_repeat = false
	return m


func material_for_kind(k: int) -> StandardMaterial3D:
	match k:
		K_CUTOUT:
			return mat_cutout
		K_TRANSLUCENT:
			return mat_water
		K_CROSS:
			return mat_cross
	return mat_opaque


## Built-in "shader packs". The project ships no external assets, so instead of a
## pack loader these are three hand-tuned looks applied straight onto the shared
## terrain materials. The environment side (glow, saturation, exposure) lives in
## sky.gd::apply_render_preset -- the two are always changed together.
##
## 0 Classic  the stock look, exactly as the materials were first built
## 1 Soft     flatter, matte, a touch darker: easier on the eyes at night
## 2 Vibrant  punchy and glossy, strong sun and shiny water
func apply_render_preset(preset: int) -> void:
	var mats := [mat_opaque, mat_cutout, mat_cross]
	var spec := 0.22
	var tint := Color(1, 1, 1)
	var rough := 1.0

	match preset:
		1:
			spec = 0.10
			tint = Color(0.94, 0.94, 0.96)
			rough = 1.0
		2:
			spec = 0.42
			tint = Color(1.06, 1.02, 0.96)
			rough = 0.92

	for m in mats:
		m.albedo_color = tint
		m.metallic_specular = spec
		m.roughness = rough

	# water is the one surface where the pack changes the read the most: soft makes
	# it matte and calm, vibrant makes it mirror-like
	match preset:
		1:
			mat_water.roughness = 0.38
			mat_water.metallic = 0.10
			mat_water.metallic_specular = 0.55
			mat_water.albedo_color = Color(0.95, 0.97, 1.0)
		2:
			mat_water.roughness = 0.06
			mat_water.metallic = 0.55
			mat_water.metallic_specular = 1.0
			mat_water.albedo_color = Color(1.0, 1.0, 1.0)
		_:
			mat_water.roughness = 0.15
			mat_water.metallic = 0.25
			mat_water.metallic_specular = 0.9
			mat_water.albedo_color = Color(1, 1, 1)


# ================================================================ cube geometry
# p0..p3 run clockwise seen from outside (Godot's front-face winding).
const FACE_DIRS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
const FACE_VERTS := [
	[Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
	[Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0)],
	[Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
	[Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)],
	[Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)],
	[Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)],
]
const FACE_UV := [
	[Vector2(0, 1), Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)],
	[Vector2(1, 1), Vector2(0, 1), Vector2(0, 0), Vector2(1, 0)],
	[Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)],
	[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)],
	[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)],
	[Vector2(0, 1), Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)],
]
const FACE_SHADE := [0.62, 0.62, 1.0, 0.50, 0.82, 0.82]
const FACE_AO := [
	[[Vector3i(1, -1, 0), Vector3i(1, 0, -1), Vector3i(1, -1, -1)],
	 [Vector3i(1, 1, 0), Vector3i(1, 0, -1), Vector3i(1, 1, -1)],
	 [Vector3i(1, 1, 0), Vector3i(1, 0, 1), Vector3i(1, 1, 1)],
	 [Vector3i(1, -1, 0), Vector3i(1, 0, 1), Vector3i(1, -1, 1)]],
	[[Vector3i(-1, 0, -1), Vector3i(-1, -1, 0), Vector3i(-1, -1, -1)],
	 [Vector3i(-1, 0, 1), Vector3i(-1, -1, 0), Vector3i(-1, -1, 1)],
	 [Vector3i(-1, 0, 1), Vector3i(-1, 1, 0), Vector3i(-1, 1, 1)],
	 [Vector3i(-1, 0, -1), Vector3i(-1, 1, 0), Vector3i(-1, 1, -1)]],
	[[Vector3i(0, 1, -1), Vector3i(-1, 1, 0), Vector3i(-1, 1, -1)],
	 [Vector3i(0, 1, 1), Vector3i(-1, 1, 0), Vector3i(-1, 1, 1)],
	 [Vector3i(0, 1, 1), Vector3i(1, 1, 0), Vector3i(1, 1, 1)],
	 [Vector3i(0, 1, -1), Vector3i(1, 1, 0), Vector3i(1, 1, -1)]],
	[[Vector3i(-1, -1, 0), Vector3i(0, -1, -1), Vector3i(-1, -1, -1)],
	 [Vector3i(1, -1, 0), Vector3i(0, -1, -1), Vector3i(1, -1, -1)],
	 [Vector3i(1, -1, 0), Vector3i(0, -1, 1), Vector3i(1, -1, 1)],
	 [Vector3i(-1, -1, 0), Vector3i(0, -1, 1), Vector3i(-1, -1, 1)]],
	[[Vector3i(-1, 0, 1), Vector3i(0, -1, 1), Vector3i(-1, -1, 1)],
	 [Vector3i(1, 0, 1), Vector3i(0, -1, 1), Vector3i(1, -1, 1)],
	 [Vector3i(1, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1)],
	 [Vector3i(-1, 0, 1), Vector3i(0, 1, 1), Vector3i(-1, 1, 1)]],
	[[Vector3i(0, -1, -1), Vector3i(-1, 0, -1), Vector3i(-1, -1, -1)],
	 [Vector3i(0, 1, -1), Vector3i(-1, 0, -1), Vector3i(-1, 1, -1)],
	 [Vector3i(0, 1, -1), Vector3i(1, 0, -1), Vector3i(1, 1, -1)],
	 [Vector3i(0, -1, -1), Vector3i(1, 0, -1), Vector3i(1, -1, -1)]],
]

## A plain unit cube centred on the origin with every face mapped to the full 0..1 UV
## square. Overlays that draw their own picture — the mining crack — need this:
## Godot's BoxMesh cube-maps its UVs into a 3x2 layout, so a texture drawn to fill one
## face comes out sliced to a third of its width and shifted off centre.
func make_overlay_cube() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for f in 6:
		var base := verts.size()
		for i in 4:
			verts.append(FACE_VERTS[f][i] - Vector3(0.5, 0.5, 0.5))
			norms.append(Vector3(FACE_DIRS[f]))
			uvs.append(FACE_UV[f][i])
		idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Builds a stand-alone cube (or crossed quads) mesh for a single block, centred on
## the origin. Used for the item held in the player's hand.
func make_block_mesh(id: int) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()

	if kind[id] == K_CROSS:
		var t0 := tile_rect(int(defs[id]["top"]))
		var quads := [
			[Vector3(0, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 0)],
			[Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 0)],
		]
		var quv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
		for q in quads:
			var base := verts.size()
			for i in 4:
				var v: Vector3 = q[i]
				verts.append(v - Vector3(0.5, 0.5, 0.5))
				norms.append(Vector3(0, 1, 0))
				uvs.append(t0.position + Vector2(quv[i].x * t0.size.x, quv[i].y * t0.size.y))
				cols.append(Color(1, 1, 1))
			idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
	else:
		for f in 6:
			var tile := int(defs[id]["top"])
			if f == 2:
				tile = int(defs[id]["top"])
			elif f == 3:
				tile = int(defs[id]["bottom"])
			else:
				tile = int(defs[id]["side"])
			var r := tile_rect(tile)
			var shade: float = FACE_SHADE[f]
			var base := verts.size()
			for i in 4:
				var v: Vector3 = FACE_VERTS[f][i]
				var uv: Vector2 = FACE_UV[f][i]
				verts.append(v - Vector3(0.5, 0.5, 0.5))
				norms.append(Vector3(FACE_DIRS[f]))
				uvs.append(r.position + Vector2(uv.x * r.size.x, uv.y * r.size.y))
				cols.append(Color(shade, shade, shade))
			idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material_for_kind(kind[id]))
	return mesh