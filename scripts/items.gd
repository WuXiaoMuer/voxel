extends Node
## Item database. A slot in the inventory is just an integer id: 1..255 are
## placeable blocks, 256+ are pure items. Icons are generated as isometric cubes.

var _icons: Dictionary = {}


func max_stack(id: int) -> int:
	# tools and armour do not stack — each copy carries its own durability
	if Gear.is_tool(id) or Gear.is_armor(id):
		return 1
	# a bucket turns into its filled or empty self in place, so it is kept unstacked
	if id == Blocks.ITEM_BUCKET or id == Blocks.ITEM_WATER_BUCKET \
			or id == Blocks.ITEM_LAVA_BUCKET:
		return 1
	return 64


func name_of(id: int) -> String:
	# block and item names are part of the UI, so they follow the language too
	return I18n.t(Blocks.display_name(id))


## A one-line description for the hover tooltip. Kept short: the tooltip is a
## single caption under the name, not a manual.
func describe(id: int) -> String:
	var d := str(DESC.get(id, ""))
	if d == "":
		return I18n.t("A block. Place it, or build with it." if is_block(id) \
			else "An item.")
	return I18n.t(d)


## What each item is for. Anything not listed falls back to a generic line, so a
## new block never shows an empty tooltip.
##
## Built in _ready() rather than declared `const`: the keys are the Blocks autoload's
## constants, and an autoload's members are not compile-time constants.
var DESC: Dictionary = {}


func _ready() -> void:
	DESC = {
		Blocks.GRASS: "Soil with a grass top. Drops dirt when mined.",
		Blocks.DIRT: "Plain soil. Cheap, and everywhere.",
		Blocks.STONE: "Mined stone. Drops cobblestone.",
		Blocks.COBBLESTONE: "Rough stone. The workhorse building block.",
		Blocks.PLANKS: "Sawn planks. Crafted from a log.",
		Blocks.LOG: "Raw wood. Craft it into planks, or build with it.",
		Blocks.LEAVES: "Leafy canopy. Sometimes hides an apple.",
		Blocks.SAND: "Fine sand. Found on beaches and in deserts.",
		Blocks.GLASS: "Transparent. See-through building material.",
		Blocks.SANDSTONE: "Compacted sand. A desert building block.",
		Blocks.BRICK: "Fired clay bricks.",
		Blocks.GLOWSTONE: "Glows brightly. Lights up a room.",
		Blocks.OBSIDIAN: "Very hard volcanic glass.",
		Blocks.SNOW: "Packed snow.",
		Blocks.ICE: "Slippery frozen water.",
		Blocks.CACTUS: "A desert plant. Mind the spines.",
		Blocks.TORCH: "A small light source.",
		Blocks.CRAFTING_TABLE: "A workbench for 3x3 crafting.",
		Blocks.COAL_ORE: "Ore. Drops coal.",
		Blocks.IRON_ORE: "Ore. Drops raw iron.",
		Blocks.GOLD_ORE: "Ore. Drops gold.",
		Blocks.DIAMOND_ORE: "Ore. Drops diamonds.",
		Blocks.GRAVEL: "Loose stones.",
		Blocks.BEDROCK: "Unbreakable. The floor of the world.",
		Blocks.ITEM_STICK: "A stick. Tool handles and torches.",
		Blocks.ITEM_COAL: "Fuel, and a torch ingredient.",
		Blocks.ITEM_IRON: "Refined iron.",
		Blocks.ITEM_GOLD: "Refined gold.",
		Blocks.ITEM_DIAMOND: "Hard and rare.",
		Blocks.ITEM_APPLE: "Food. Restores 4 hunger.",
		Blocks.ITEM_BREAD: "Baked food. Restores 6 hunger.",
		Blocks.STONE_BRICK: "Cut stone. A tidy building block.",
		Blocks.IRON_BLOCK: "Nine iron in one block. Storage, or a sturdy build.",
		Blocks.GOLD_BLOCK: "Nine gold in one block.",
		Blocks.DIAMOND_BLOCK: "Nine diamonds in one block.",
		Blocks.FENCE: "A fence. Keeps things in, and out.",
		Blocks.LADDER: "Climb a wall with it.",
		Blocks.GLASS_PANE: "A thin pane of glass.",
		Blocks.DOOR: "A door. Right-click to open it.",
		Blocks.CHEST: "A chest for storage.",
		Blocks.COPPER_ORE: "Ore. Drops copper, the metal the wire is drawn from.",
		Blocks.BATTERY: "A cell. Always live, so wire it straight to a load.",
		Blocks.ITEM_COPPER: "Refined copper. The conductor the wire is made of.",
		Blocks.WIRE: "Copper conductor laid on the ground. It drops 1 level per block, "
			+ "so a run dies out after 15.",
		Blocks.INVERTER: "A NOT gate. Its output is live while its input is dead, and "
			+ "dark when the input is driven.",
		Blocks.SWITCH: "A knife switch. Right-click to open or close the circuit.",
		Blocks.BUTTON: "A momentary switch. Springs back on its own.",
		Blocks.PRESSURE_PLATE: "A sensor. Live while something stands on it.",
		Blocks.RELAY: "A diode with a delay: passes signal one way, at full "
			+ "strength, after a short wait. Right-click to aim it.",
		Blocks.LAMP: "An indicator. Lights up when powered.",
		Blocks.PISTON: "An actuator. Powered, it shoves the block in front one cell on.",
		Blocks.FURNACE: "A furnace. Smelt ores into ingots and cook food with fuel.",
		Blocks.FARMLAND: "Tilled soil. Plant seeds on it and they grow into wheat.",
		Blocks.WHEAT_0: "Growing wheat. It ripens in stages — harvest only when golden.",
		Blocks.WHEAT_1: "Growing wheat. It ripens in stages — harvest only when golden.",
		Blocks.WHEAT_2: "Growing wheat. It ripens in stages — harvest only when golden.",
		Blocks.WHEAT_3: "Ripe wheat. Harvest it for wheat and more seeds.",
		Blocks.ITEM_ROTTEN_FLESH: "Food, barely. Eaten when nothing better is around.",
		Blocks.ITEM_BONE: "A bone. Skeletons leave them behind.",
		Blocks.ITEM_ARROW: "Ammunition. Skeletons fire them at you.",
		Blocks.ITEM_STRING: "Thread. Spiders drop it.",
		Blocks.ITEM_GUNPOWDER: "Explosive dust. Creepers leave it behind.",
		Blocks.ITEM_SEEDS: "Plant these on farmland to grow wheat.",
		Blocks.ITEM_WHEAT: "Grain. Bake three in a row into bread.",
		Blocks.ITEM_LEATHER: "Hide from cows. Armour can be made from it.",
		Blocks.ITEM_FEATHER: "A feather. Chickens drop them.",
		Blocks.ITEM_PORKCHOP_RAW: "Raw pork. Cook it in a furnace first.",
		Blocks.ITEM_PORKCHOP_COOKED: "Cooked pork. A filling meal.",
		Blocks.ITEM_BEEF_RAW: "Raw beef. Cook it in a furnace first.",
		Blocks.ITEM_BEEF_COOKED: "Steak. The best meal in the game.",
		Blocks.ITEM_CHICKEN_RAW: "Raw chicken. Cook it before eating.",
		Blocks.ITEM_CHICKEN_COOKED: "Cooked chicken. Tasty and safe.",
		Blocks.ITEM_BUCKET: "An empty bucket. Right-click water or lava to fill it.",
		Blocks.ITEM_WATER_BUCKET: "A bucket of water. Right-click to pour it out.",
		Blocks.ITEM_LAVA_BUCKET: "A bucket of lava. Pour it, but do not stand in it.",
		Blocks.SLAB: "Half-height stone. Walk onto it without jumping.",
		Blocks.SLAB_WOOD: "Half-height planks.",
		Blocks.SLAB_COBBLE: "Half-height cobblestone.",
		Blocks.STAIRS: "Stairs. Placed facing away from you, and climbed without a jump.",
		Blocks.STAIRS_WOOD: "Wooden stairs.",
		Blocks.STAIRS_COBBLE: "Cobblestone stairs.",
		Blocks.TRAPDOOR: "A hatch. Right-click to swing it up or lay it flat.",
		Blocks.FENCE_GATE: "A gate in a fence. Right-click to open it.",
		Blocks.SIGN: "A sign. Right-click to write on it.",
		Blocks.WOOL_0: "Woven cloth, dyed any of sixteen colours.",
		Blocks.CARPET_0: "A thin covering of cloth for the floor.",
		Blocks.BED: "Sleep in it at night to skip to morning, and to set your respawn.",
		Blocks.ITEM_SLIME_BALL: "A blob of slime. Slimes drop them.",
		Blocks.ITEM_ENDER_PEARL: "A pearl from an Enderman.",
		Blocks.ITEM_EMERALD: "The villagers' coin. Earn it by trading, spend it on goods.",
		Blocks.ENCHANTING_TABLE: "Spend levels to enchant the tool or armour you hold.",
		Blocks.CARROT_0: "Growing carrots. Ripe when the root shows at the soil.",
		Blocks.CARROT_1: "Growing carrots. Ripe when the root shows at the soil.",
		Blocks.CARROT_2: "Growing carrots. Ripe when the root shows at the soil.",
		Blocks.CARROT_3: "Ripe carrots. Harvest them, then plant one to keep the field going.",
		Blocks.POTATO_0: "Growing potatoes. Ripe when the tubers show at the soil.",
		Blocks.POTATO_1: "Growing potatoes. Ripe when the tubers show at the soil.",
		Blocks.POTATO_2: "Growing potatoes. Ripe when the tubers show at the soil.",
		Blocks.POTATO_3: "Ripe potatoes. Harvest them, then plant one to keep the field going.",
		Blocks.TNT: "An explosive block. Light the fuse with flint and steel.",
		Blocks.DISPENSER: "Right-click it holding an arrow to launch one forward.",
		Blocks.ITEM_CARROT: "Food. Plant one on farmland to grow more.",
		Blocks.ITEM_POTATO: "Food, and better baked. Plant one to grow more.",
		Blocks.ITEM_BAKED_POTATO: "A baked potato. The filling meal of the root cellar.",
		Blocks.ITEM_SHEARS: "Right-click a sheep to cut its wool; the fleece grows back.",
		Blocks.ITEM_FLINT: "A hard shard knocked out of gravel. Half of flint and steel.",
		Blocks.ITEM_FLINT_STEEL: "Right-click a TNT block to light its fuse.",
		Blocks.ITEM_FISHING_ROD: "Right-click water to cast; right-click again to reel in.",
		Blocks.ITEM_FISH_RAW: "Raw fish. Cook it in a furnace before eating.",
		Blocks.ITEM_FISH_COOKED: "Cooked fish. A light meal that stacks well.",
		Blocks.ITEM_POTION_SWIFTNESS: "Drink to move faster for about two minutes.",
		Blocks.ITEM_POTION_REGEN: "Drink to heal steadily for about half a minute.",
		Blocks.ITEM_POTION_STRENGTH: "Drink to hit much harder for about two minutes.",
		Blocks.ITEM_POTION_NIGHT: "Drink to see in the dark for about three minutes.",
		Blocks.ITEM_POTION_SPLASH_SWIFTNESS: "Throw it to speed up everything close by.",
		Blocks.ITEM_POTION_SPLASH_REGEN: "Throw it to heal everything close by.",
		Blocks.ITEM_POTION_SPLASH_STRENGTH: "Throw it to strengthen everything close by.",
		Blocks.ITEM_POTION_SPLASH_NIGHT: "Throw it to light the dark around everything close by.",
		Blocks.ITEM_BOW: "Hold right-click to draw it, then let go to loose an arrow.",
		Blocks.ANVIL: "Right-click with a worn tool to repair it for experience levels.",
		Blocks.BREWING_STAND: "Right-click holding a reagent to brew the potion it makes, "
			+ "for a pane of glass.",
		Blocks.HOPPER: "Takes an item out of the container above and puts it in the one below.",
		Blocks.OBSERVER: "Watches the block it faces and pulses for a moment whenever it "
			+ "changes. Right-click to aim it.",
		Blocks.COMPARATOR: "Drives a level set by how full the container behind it is. "
			+ "Right-click to aim it.",
		Blocks.BEACON: "On a 3x3 base of iron, gold or diamond blocks it heals everyone "
			+ "close by. It lights the room either way.",
		Blocks.RAIL: "A track. A cart rolls along one much faster than over plain ground.",
		Blocks.ITEM_MINECART: "Place it on the ground, then right-click to ride. Rails "
			+ "carry it faster.",
		Blocks.ITEM_BOAT: "Place it on water, then right-click to ride.",
		Blocks.NETHERRACK: "Soft, blood-red rock. The bulk of the nether's ground.",
		Blocks.SOUL_SAND: "A slow, sucking patch of nether ground. You wade through it.",
		Blocks.NETHER_BRICK_BLOCK: "Dark, tightly laid nether bricks.",
		Blocks.MAGMA: "Cooling lava. It burns whatever stands on it bright enough to.",
		Blocks.NETHER_QUARTZ_ORE: "Red rock shot through with white quartz veins.",
		Blocks.NETHER_PORTAL: "A lit doorway between the overworld and the nether.",
		Blocks.ITEM_NETHER_QUARTZ: "The quartz ore's drop. A pale crafting crystal.",
		Blocks.ITEM_NETHER_BRICK: "Smelted from netherrack. Four press into a brick block.",
	}


func is_block(id: int) -> bool:
	return Blocks.is_block_item(id)


func icon(id: int) -> Texture2D:
	if _icons.has(id):
		return _icons[id]
	var t: ImageTexture
	if id <= 0:
		t = null
	elif Blocks.is_block_item(id):
		t = _tex(_iso_icon(id, 40))
	else:
		t = _tex(_item_icon(id, 40))
	_icons[id] = t
	return t


func icon_for(id: int, size: int) -> Texture2D:
	if id <= 0:
		return null
	if Blocks.is_block_item(id):
		return _tex(_iso_icon(id, size))
	return _tex(_item_icon(id, size))


# ================================================================ helpers
func _tex(img: Image) -> ImageTexture:
	return ImageTexture.create_from_image(img)


func _img(w: int, h: int) -> Image:
	return Image.create(w, h, false, Image.FORMAT_RGBA8)


func _sample(tile_img: Image, u: float, v: float) -> Color:
	var x := clampi(int(u * float(Blocks.TILE)), 0, Blocks.TILE - 1)
	var y := clampi(int(v * float(Blocks.TILE)), 0, Blocks.TILE - 1)
	return tile_img.get_pixel(x, y)


func _shade(c: Color, f: float) -> Color:
	return Color(clampf(c.r * f, 0, 1), clampf(c.g * f, 0, 1), clampf(c.b * f, 0, 1), c.a)


# ================================================================ isometric block icon
func _iso_icon(block_id: int, size: int) -> Image:
	var d: Dictionary = Blocks.defs[block_id]
	var k := int(d["kind"])
	if k == Blocks.K_CROSS:
		return _flat_icon(int(d["top"]), size)

	# The icon is built from the block's real shape, not from a full cube. Drawing every
	# non-cube kind as a cube made a slab, a stair, a trapdoor and a bed all look like
	# plain blocks in the palette and the hotbar -- the icon said nothing about the shape
	# you were actually about to place.
	var boxes := _icon_boxes(block_id, k)
	if boxes.is_empty():
		return _flat_icon(int(d["side"]), size)

	var img := _img(size, size)
	img.fill(Color(0, 0, 0, 0))
	_iso_boxes(img, boxes, Blocks.tile_images[int(d["top"])],
		Blocks.tile_images[int(d["side"])])
	_outline(img)
	return img


## The unit-cell boxes a kind is drawn from, in 0..1 block space. A cube is one box; the
## rest are the shapes the mesher already builds, so the icon and the world agree.
func _icon_boxes(block_id: int, kind: int) -> Array:
	match kind:
		Blocks.K_TRANSLUCENT:
			# glass is a cube, but a pane is a thin pane: same kind, so the shape has to
			# come from the id
			if block_id == Blocks.GLASS_PANE:
				return [[Vector3(0, 0, 0.40625), Vector3(1, 1, 0.59375)]]
		Blocks.K_SLAB:
			return [[Vector3(0, 0, 0), Vector3(1, 0.5, 1)]]
		Blocks.K_STAIRS:
			return [[Vector3(0, 0, 0), Vector3(1, 0.5, 1)],
				[Vector3(0, 0.5, 0), Vector3(1, 1, 0.5)]]
		Blocks.K_TRAPDOOR:
			return [[Vector3(0, 0, 0), Vector3(1, 0.1875, 1)]]
		Blocks.K_PANEL:
			return [[Vector3(0, 0, 0.40625), Vector3(1, 1, 0.59375)]]
		Blocks.K_CARPET, Blocks.K_FLAT:
			return [[Vector3(0, 0, 0), Vector3(1, 0.0625, 1)]]
		Blocks.K_BED:
			return [[Vector3(0, 0, 0), Vector3(1, 0.5625, 1)]]
		Blocks.K_FENCE:
			return [[Vector3(0.4375, 0, 0.4375), Vector3(0.5625, 1, 0.5625)],
				[Vector3(0, 0.375, 0.4375), Vector3(1, 0.5, 0.5625)],
				[Vector3(0, 0.6875, 0.4375), Vector3(1, 0.8125, 0.5625)]]
		Blocks.K_GATE:
			return [[Vector3(0, 0, 0.40625), Vector3(1, 1, 0.59375)]]
	return [[Vector3(0, 0, 0), Vector3(1, 1, 1)]]


## A grid point (0..1 block space) in isometric screen space, before centring.
func _iso_point(v: Vector3, k: float) -> Vector2:
	return Vector2((v.x - v.z) * 0.866, (v.x + v.z) * 0.5 - v.y) * k


## Draws a set of axis-aligned boxes as an isometric icon. The shapes are measured first
## and centred, so a short slab fills the icon as well as a tall cube does, and the boxes
## are painted back to front so a nearer piece overlaps a farther one.
func _iso_boxes(img: Image, boxes: Array, tex_top: Image, tex_side: Image) -> void:
	var s := float(img.get_width())
	var k := s * 0.42
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for b in boxes:
		var mn: Vector3 = b[0]
		var mx: Vector3 = b[1]
		for x in [mn.x, mx.x]:
			for y in [mn.y, mx.y]:
				for z in [mn.z, mx.z]:
					var p := _iso_point(Vector3(x, y, z), k)
					lo = lo.min(p)
					hi = hi.max(p)
	var off := Vector2(s * 0.5, s * 0.5) - (lo + hi) * 0.5 + Vector2(0, k * 0.05)
	var order: Array = boxes.duplicate()
	order.sort_custom(func(a, b2) -> bool:
		return (a[0].x + a[0].y + a[0].z) < (b2[0].x + b2[0].y + b2[0].z))
	for b3 in order:
		_iso_box(img, b3[0], b3[1], k, off, tex_top, tex_side)


func _iso_box(img: Image, mn: Vector3, mx: Vector3, k: float, off: Vector2,
		tex_top: Image, tex_side: Image) -> void:
	# the two faces toward the camera, then the top over both of them
	var fx := off + _iso_point(Vector3(mx.x, mx.y, mn.z), k)
	_fill_para(img, fx,
		_iso_point(Vector3(mx.x, mx.y, mx.z), k) - _iso_point(Vector3(mx.x, mx.y, mn.z), k),
		_iso_point(Vector3(mx.x, mn.y, mn.z), k) - _iso_point(Vector3(mx.x, mx.y, mn.z), k),
		tex_side, 0.80)
	var fz := off + _iso_point(Vector3(mn.x, mx.y, mx.z), k)
	_fill_para(img, fz,
		_iso_point(Vector3(mx.x, mx.y, mx.z), k) - _iso_point(Vector3(mn.x, mx.y, mx.z), k),
		_iso_point(Vector3(mn.x, mn.y, mx.z), k) - _iso_point(Vector3(mn.x, mx.y, mx.z), k),
		tex_side, 0.60)
	var ft := off + _iso_point(Vector3(mn.x, mx.y, mn.z), k)
	_fill_para(img, ft,
		_iso_point(Vector3(mx.x, mx.y, mn.z), k) - _iso_point(Vector3(mn.x, mx.y, mn.z), k),
		_iso_point(Vector3(mn.x, mx.y, mx.z), k) - _iso_point(Vector3(mn.x, mx.y, mn.z), k),
		tex_top, 1.0)


func _fill_para(img: Image, o: Vector2, e1: Vector2, e2: Vector2, tile: Image,
		shade: float) -> void:
	var size := img.get_width()
	var pts := [o, o + e1, o + e1 + e2, o + e2]
	var minx := 1e9
	var maxx := -1e9
	var miny := 1e9
	var maxy := -1e9
	for p in pts:
		minx = minf(minx, p.x)
		maxx = maxf(maxx, p.x)
		miny = minf(miny, p.y)
		maxy = maxf(maxy, p.y)
	var x0 := clampi(int(floor(minx)) - 1, 0, size - 1)
	var x1 := clampi(int(ceil(maxx)) + 1, 0, size - 1)
	var y0 := clampi(int(floor(miny)) - 1, 0, size - 1)
	var y1 := clampi(int(ceil(maxy)) + 1, 0, size - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var p := Vector2(float(x) + 0.5, float(y) + 0.5) - o
			var c1 := _coord(p, e1, e2)
			if c1.x < 0.0 or c1.x > 1.0 or c1.y < 0.0 or c1.y > 1.0:
				continue
			var col := _sample(tile, c1.x, c1.y)
			if col.a <= 0.01:
				continue
			img.set_pixel(x, y, Color(_shade(col, shade).r, _shade(col, shade).g, _shade(col, shade).b, col.a))


func _coord(p: Vector2, e1: Vector2, e2: Vector2) -> Vector2:
	var det := e1.x * e2.y - e2.x * e1.y
	if absf(det) < 0.0001:
		return Vector2(-1, -1)
	return Vector2((p.x * e2.y - p.y * e2.x) / det, (e1.x * p.y - e1.y * p.x) / det)


func _outline(img: Image) -> void:
	var size := img.get_width()
	var copy := img.duplicate() as Image
	for y in size:
		for x in size:
			if copy.get_pixel(x, y).a > 0.4:
				continue
			var touch := false
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx := x + dx
					var ny := y + dy
					if nx < 0 or ny < 0 or nx >= size or ny >= size:
						continue
					if copy.get_pixel(nx, ny).a > 0.4:
						touch = true
			if touch:
				img.set_pixel(x, y, Color(0, 0, 0, 0.35))


func _flat_icon(tile: int, size: int) -> Image:
	var img := _img(size, size)
	img.fill(Color(0, 0, 0, 0))
	if tile < 0 or tile >= Blocks.tile_images.size():
		return img
	var src: Image = Blocks.tile_images[tile]
	var s := float(size) / float(Blocks.TILE)
	for y in size:
		for x in size:
			var c := src.get_pixel(int(float(x) / s), int(float(y) / s))
			img.set_pixel(x, y, c)
	return img


# ================================================================ pure item icons
func _item_icon(id: int, size: int) -> Image:
	var img := _img(size, size)
	img.fill(Color(0, 0, 0, 0))
	var k := float(size) / 16.0

	# these tools have shapes specific enough to draw by hand rather than through the
	# generic pick/axe/sword outline
	if id == Blocks.ITEM_SHEARS:
		_shears_icon(img, k)
		return img
	if id == Blocks.ITEM_FLINT_STEEL:
		_flint_steel_icon(img, k)
		return img
	if id == Blocks.ITEM_FISHING_ROD:
		_fishing_rod_icon(img, k)
		return img
	if id == Blocks.ITEM_BOW:
		_bow_icon(img, k)
		return img
	if id == Blocks.ITEM_MINECART:
		_vehicle_icon(img, k, Color(0.62, 0.62, 0.66), Color(0.44, 0.44, 0.48))
		return img
	if id == Blocks.ITEM_BOAT:
		_vehicle_icon(img, k, Color(0.58, 0.38, 0.19), Color(0.40, 0.25, 0.12))
		return img
	# every potion shares one flask; only the liquid, and whether it splashes, differ
	if id >= Blocks.ITEM_POTION_SWIFTNESS and id <= Blocks.ITEM_POTION_SPLASH_NIGHT:
		_potion_icon(img, k, _potion_color(id), id >= Blocks.ITEM_POTION_SPLASH_SWIFTNESS)
		return img

	# tools and armour are drawn parametrically from their kind/slot and material tier
	if Gear.is_tool(id):
		_tool_icon(img, k, Gear.tool_kind(id), _tool_head(id), _tool_dark(id))
		return img
	if Gear.is_armor(id):
		_armor_icon(img, k, Gear.armor_slot(id), _armor_col(id), _armor_edge(id))
		return img

	# dyes: a little cloth pouch of pigment, in the colour it dyes wool
	if id >= Blocks.ITEM_DYE_0 and id <= Blocks.ITEM_DYE_15:
		_dye_icon(img, k, Blocks.WOOL_COLORS[id - Blocks.ITEM_DYE_0])
		return img

	match id:
		Blocks.ITEM_STICK:
			for i in 13:
				var x := 3 + i
				var y := 13 - i
				_px(img, x, y, k, Color(0.45, 0.30, 0.15))
				_px(img, x + 1, y, k, Color(0.55, 0.38, 0.20))
				_px(img, x, y + 1, k, Color(0.36, 0.24, 0.12))
		Blocks.ITEM_COAL:
			_blob_px(img, 8, 9, 4, k, Color(0.13, 0.13, 0.15))
			_blob_px(img, 7, 8, 2, k, Color(0.24, 0.24, 0.27))
			_blob_px(img, 5, 11, 2, k, Color(0.10, 0.10, 0.12))
		Blocks.ITEM_IRON:
			_ingot(img, k, Color(0.86, 0.86, 0.88), Color(0.62, 0.62, 0.66))
		Blocks.ITEM_GOLD:
			_ingot(img, k, Color(0.99, 0.90, 0.32), Color(0.76, 0.60, 0.14))
		Blocks.ITEM_DIAMOND:
			_gem(img, k, Color(0.35, 0.92, 0.90), Color(0.15, 0.62, 0.66))
		Blocks.ITEM_APPLE:
			_blob_px(img, 8, 9, 4, k, Color(0.78, 0.14, 0.12))
			_blob_px(img, 7, 8, 2, k, Color(0.90, 0.26, 0.20))
			_px(img, 8, 4, k, Color(0.42, 0.28, 0.14))
			_px(img, 9, 5, k, Color(0.42, 0.28, 0.14))
			_px(img, 6, 6, k, Color(0.30, 0.55, 0.22))
			_px(img, 5, 7, k, Color(0.26, 0.48, 0.19))
			_px(img, 6, 8, k, Color(1, 1, 1, 0.55))
		Blocks.ITEM_BREAD:
			for y in range(6, 13):
				var half := 4 - int((y - 6) * 0.3)
				for x in range(8 - half, 8 + half):
					var c := Color(0.74, 0.52, 0.26) if y < 10 else Color(0.58, 0.38, 0.17)
					_px(img, x, y, k, c)
			for x in range(5, 11):
				_px(img, x, 6, k, Color(0.86, 0.66, 0.36))
			_px(img, 6, 9, k, Color(0.50, 0.32, 0.14))
			_px(img, 9, 11, k, Color(0.50, 0.32, 0.14))
		# ---- mob drops
		Blocks.ITEM_ROTTEN_FLESH:
			_blob_px(img, 8, 9, 4, k, Color(0.52, 0.36, 0.28))
			_blob_px(img, 7, 8, 2, k, Color(0.62, 0.30, 0.28))
			_px(img, 6, 11, k, Color(0.40, 0.50, 0.28))
		Blocks.ITEM_BONE:
			for i in 9:
				_px(img, 5 + i, 11 - i, k, Color(0.92, 0.90, 0.82))
				_px(img, 6 + i, 11 - i, k, Color(0.80, 0.78, 0.70))
			_blob_px(img, 4, 12, 2, k, Color(0.92, 0.90, 0.82))
			_blob_px(img, 12, 4, 2, k, Color(0.92, 0.90, 0.82))
		Blocks.ITEM_ARROW:
			for i in 12:
				_px(img, 3 + i, 13 - i, k, Color(0.60, 0.46, 0.28))
			_blob_px(img, 12, 4, 2, k, Color(0.78, 0.80, 0.82))
			_px(img, 3, 13, k, Color(0.90, 0.90, 0.90))
			_px(img, 2, 12, k, Color(0.90, 0.90, 0.90))
			_px(img, 4, 13, k, Color(0.90, 0.90, 0.90))
			_px(img, 3, 14, k, Color(0.90, 0.90, 0.90))
		Blocks.ITEM_STRING:
			for i in 12:
				_px(img, 8 + int(sin(i * 0.9) * 3.0), 4 + i, k, Color(0.92, 0.92, 0.90))
		Blocks.ITEM_GUNPOWDER:
			_blob_px(img, 8, 10, 3, k, Color(0.34, 0.34, 0.36))
			_blob_px(img, 6, 8, 1, k, Color(0.48, 0.48, 0.50))
			_blob_px(img, 10, 12, 1, k, Color(0.24, 0.24, 0.26))
		Blocks.ITEM_SEEDS:
			for p in [Vector2i(6, 8), Vector2i(9, 10), Vector2i(7, 12), Vector2i(10, 7)]:
				_px(img, p.x, p.y, k, Color(0.66, 0.74, 0.32))
				_px(img, p.x, p.y + 1, k, Color(0.48, 0.58, 0.22))
		Blocks.ITEM_WHEAT:
			for y in range(3, 14):
				_px(img, 8, y, k, Color(0.72, 0.60, 0.22))
			for p in [Vector2i(6, 5), Vector2i(10, 6), Vector2i(6, 8), Vector2i(10, 9), Vector2i(6, 11), Vector2i(10, 12)]:
				_px(img, p.x, p.y, k, Color(0.86, 0.74, 0.28))
				_px(img, p.x, p.y + 1, k, Color(0.70, 0.58, 0.20))
		Blocks.ITEM_LEATHER:
			_blob_px(img, 8, 9, 4, k, Color(0.62, 0.42, 0.24))
			_blob_px(img, 7, 8, 2, k, Color(0.72, 0.52, 0.30))
			_px(img, 6, 12, k, Color(0.50, 0.32, 0.18))
		Blocks.ITEM_FEATHER:
			for i in 10:
				_px(img, 4 + i, 13 - i, k, Color(0.92, 0.92, 0.94))
			for i in 6:
				_px(img, 6 + i, 8 - i, k, Color(0.80, 0.82, 0.88))
			_px(img, 4, 13, k, Color(0.60, 0.60, 0.62))
		Blocks.ITEM_PORKCHOP_RAW:
			_meat(img, k, Color(0.88, 0.52, 0.52), Color(0.72, 0.36, 0.36))
		Blocks.ITEM_PORKCHOP_COOKED:
			_meat(img, k, Color(0.72, 0.44, 0.24), Color(0.56, 0.32, 0.16))
		Blocks.ITEM_BEEF_RAW:
			_meat(img, k, Color(0.78, 0.24, 0.24), Color(0.58, 0.16, 0.16))
		Blocks.ITEM_BEEF_COOKED:
			_meat(img, k, Color(0.60, 0.34, 0.18), Color(0.44, 0.24, 0.12))
		Blocks.ITEM_CHICKEN_RAW:
			_meat(img, k, Color(0.90, 0.74, 0.66), Color(0.74, 0.58, 0.50))
		Blocks.ITEM_CHICKEN_COOKED:
			_meat(img, k, Color(0.80, 0.58, 0.34), Color(0.62, 0.42, 0.22))
		Blocks.ITEM_BUCKET:
			_bucket_icon(img, k, Color(0, 0, 0, 0))
		Blocks.ITEM_WATER_BUCKET:
			_bucket_icon(img, k, Color(0.24, 0.46, 0.88))
		Blocks.ITEM_LAVA_BUCKET:
			_bucket_icon(img, k, Color(0.96, 0.44, 0.08))
		Blocks.ITEM_SLIME_BALL:
			_blob_px(img, 8, 9, 4, k, Color(0.42, 0.78, 0.32))
			_blob_px(img, 7, 8, 2, k, Color(0.58, 0.90, 0.44))
			_px(img, 6, 11, k, Color(0.32, 0.64, 0.24))
			_px(img, 9, 6, k, Color(1, 1, 1, 0.5))
		Blocks.ITEM_ENDER_PEARL:
			_gem(img, k, Color(0.35, 0.82, 0.74), Color(0.12, 0.44, 0.46))
		Blocks.ITEM_EMERALD:
			_gem(img, k, Color(0.24, 0.86, 0.40), Color(0.05, 0.52, 0.24))
		Blocks.ITEM_CARROT:
			# a tapered orange root under a tuft of leaves
			for y in range(4, 14):
				var half := maxi(1, 4 - int((y - 4) * 0.35))
				for x in range(8 - half, 8 + half):
					_px(img, x, y, k, Color(0.94, 0.52, 0.14) if x > 7 else Color(0.80, 0.40, 0.10))
			_px(img, 6, 3, k, Color(0.34, 0.62, 0.22))
			_px(img, 8, 2, k, Color(0.34, 0.62, 0.22))
			_px(img, 10, 3, k, Color(0.34, 0.62, 0.22))
		Blocks.ITEM_POTATO:
			_blob_px(img, 8, 9, 4, k, Color(0.80, 0.68, 0.44))
			_blob_px(img, 7, 8, 2, k, Color(0.88, 0.78, 0.54))
			_px(img, 6, 12, k, Color(0.60, 0.48, 0.28))
			_px(img, 10, 7, k, Color(0.64, 0.52, 0.32))
		Blocks.ITEM_BAKED_POTATO:
			_blob_px(img, 8, 9, 4, k, Color(0.62, 0.44, 0.24))
			_blob_px(img, 7, 8, 2, k, Color(0.72, 0.54, 0.32))
			_px(img, 6, 12, k, Color(0.44, 0.30, 0.16))
			_px(img, 10, 7, k, Color(0.50, 0.36, 0.20))
		Blocks.ITEM_FISH_RAW:
			_fish_icon(img, k, Color(0.70, 0.78, 0.86))
		Blocks.ITEM_FISH_COOKED:
			_fish_icon(img, k, Color(0.74, 0.52, 0.26))
		Blocks.ITEM_NETHER_QUARTZ:
			# a pale, faceted crystal shard
			for i in 9:
				_px(img, 4 + i, 12 - i, k, Color(0.92, 0.90, 0.94))
				_px(img, 5 + i, 12 - i, k, Color(0.80, 0.78, 0.86))
			_blob_px(img, 5, 5, 2, k, Color(0.96, 0.95, 0.99))
			_px(img, 7, 7, k, Color(1, 1, 1, 0.7))
		Blocks.ITEM_NETHER_BRICK:
			# a single dark brick, laid flat
			for y in range(6, 11):
				for x in range(3, 13):
					_px(img, x, y, k, Color(0.30, 0.18, 0.19) if ((x + y) & 1) == 0
						else Color(0.26, 0.15, 0.16))
			for x in range(4, 12):
				_px(img, x, 12, k, Color(0.20, 0.12, 0.13))
			for x in range(3, 13):
				_px(img, x, 5, k, Color(0.38, 0.24, 0.25))
		_:
			_blob_px(img, 8, 8, 4, k, Color(0.6, 0.6, 0.65))
	return img


## A small steel bucket, optionally filled. The fill is drawn just under the rim so a full
## bucket still reads as "a bucket with something in it" rather than a solid bar.
func _bucket_icon(img: Image, k: int, fill: Color) -> void:
	var steel := Color(0.74, 0.76, 0.80)
	var dark := Color(0.50, 0.52, 0.56)
	for x in range(4, 12):
		_px(img, x, 5, k, steel)
	for y in range(6, 13):
		var inset := (y - 6) / 4
		for x in range(4 + inset, 12 - inset):
			_px(img, x, y, k, dark if ((x + y) & 1) == 0 else steel)
	if fill.a > 0.0:
		for y in range(6, 10):
			for x in range(5, 11):
				_px(img, x, y, k, fill)
	# the handle arc, above the rim
	for x in range(4, 12):
		if x < 6 or x > 9:
			_px(img, x, 3, k, dark)


## Shears: two grey blades meeting at a pivot, with the handles below it.
func _shears_icon(img: Image, k: float) -> void:
	var steel := Color(0.78, 0.80, 0.84)
	var dark := Color(0.46, 0.48, 0.52)
	for i in 7:
		_px(img, 4 + i, 3 + i, k, steel)
		_px(img, 11 - i, 3 + i, k, steel)
	_blob_px(img, 8, 10, 2, k, dark)
	_px(img, 6, 12, k, dark)
	_px(img, 7, 13, k, dark)
	_px(img, 10, 12, k, dark)
	_px(img, 9, 13, k, dark)


## Flint and steel: a steel striker over a dark flint shard.
func _flint_steel_icon(img: Image, k: float) -> void:
	var steel := Color(0.62, 0.64, 0.68)
	for x in range(3, 11):
		_px(img, x, 4, k, steel)
		_px(img, x, 5, k, steel.darkened(0.2))
	for y in range(6, 12):
		_px(img, 3, y, k, steel.darkened(0.15))
	_blob_px(img, 9, 10, 4, k, Color(0.30, 0.30, 0.34))
	_blob_px(img, 8, 9, 2, k, Color(0.44, 0.44, 0.48))


## A fishing rod: a long rod with a line down from its tip and a small hook.
func _fishing_rod_icon(img: Image, k: float) -> void:
	for i in 12:
		_px(img, 3 + i, 13 - i, k, Color(0.42, 0.28, 0.14))
		_px(img, 4 + i, 13 - i, k, Color(0.54, 0.37, 0.19))
	for y in range(3, 12):
		_px(img, 14, y, k, Color(0.86, 0.86, 0.88))
	_px(img, 13, 12, k, Color(0.70, 0.70, 0.74))
	_px(img, 13, 13, k, Color(0.55, 0.55, 0.60))


## A cart or a boat: an open U seen from the side, with a rim along the top. Both are the
## same shape in different materials, which is exactly what the two models in the world are.
func _vehicle_icon(img: Image, k: float, body: Color, edge: Color) -> void:
	# the hull: a shallow V, wider at the top than at the keel
	for y in range(6, 13):
		var inset := 3 - int((y - 6) * 0.5)
		for x in range(2 + inset, 14 - inset):
			_px(img, x, y, k, body)
	for x in range(3, 13):
		_px(img, x, 5, k, edge)
	# the rim, and a dark line where the inside meets the near wall
	for x in range(2, 14):
		_px(img, x, 4, k, edge)
	for x in range(5, 11):
		_px(img, x, 7, k, edge.darkened(0.25))


## A bow: a limb curving out to the right with the string drawn straight between its tips.
## The icon cannot show a draw, so the resting shape has to carry the meaning on its own.
func _bow_icon(img: Image, k: float) -> void:
	for i in 13:
		var y := 2 + i
		var dx := int(round(sin(float(i) / 12.0 * PI) * 5.0))
		_px(img, 4 + dx, y, k, Color(0.50, 0.33, 0.16))
		_px(img, 5 + dx, y, k, Color(0.62, 0.43, 0.22))
	# the grip, where the limb is thickest
	_px(img, 8, 8, k, Color(0.34, 0.21, 0.10))
	_px(img, 9, 8, k, Color(0.34, 0.21, 0.10))
	# the string, tip to tip
	for y in range(2, 15):
		_px(img, 4, y, k, Color(0.86, 0.86, 0.88))


## A fish: a rounded body with a tail fin and one dark eye.
func _fish_icon(img: Image, k: float, body: Color) -> void:
	_blob_px(img, 8, 8, 4, k, body)
	_blob_px(img, 7, 7, 2, k, body.lightened(0.16))
	for dy in [-1, 0, 1]:
		_px(img, 3, 8 + dy, k, body.darkened(0.18))
	_px(img, 10, 7, k, Color(0.10, 0.10, 0.12))


## The liquid colour of a potion, by id.
func _potion_color(id: int) -> Color:
	match id:
		Blocks.ITEM_POTION_SWIFTNESS, Blocks.ITEM_POTION_SPLASH_SWIFTNESS:
			return Color(0.36, 0.72, 0.96)
		Blocks.ITEM_POTION_REGEN, Blocks.ITEM_POTION_SPLASH_REGEN:
			return Color(0.92, 0.38, 0.62)
		Blocks.ITEM_POTION_STRENGTH, Blocks.ITEM_POTION_SPLASH_STRENGTH:
			return Color(0.86, 0.20, 0.22)
	return Color(0.28, 0.26, 0.64)


## A potion flask: a corked bottle with liquid in it. A splash variant scatters a few
## droplets off the neck, so the two are told apart at a glance in the hotbar.
func _potion_icon(img: Image, k: float, liquid: Color, splash: bool) -> void:
	var glass := Color(0.80, 0.84, 0.88)
	for y in range(5, 8):
		for x in range(7, 10):
			_px(img, x, y, k, glass)
	for y in range(8, 14):
		var half := 2 + int((y - 8) * 0.7)
		for x in range(8 - half, 8 + half):
			_px(img, x, y, k, glass)
	for y in range(9, 13):
		var half2 := 1 + int((y - 8) * 0.7)
		for x in range(8 - half2, 8 + half2):
			_px(img, x, y, k, liquid)
	for x in range(7, 10):
		_px(img, x, 4, k, Color(0.56, 0.38, 0.20))
	if splash:
		_px(img, 5, 6, k, liquid)
		_px(img, 11, 6, k, liquid)
		_px(img, 4, 10, k, liquid)


## A small cloth pouch of dye, tied at the neck, in the colour it dyes wool.
func _dye_icon(img: Image, k: float, col: Color) -> void:
	var tie := Color(0.44, 0.32, 0.18)
	_blob_px(img, 8, 10, 4, k, col)
	_blob_px(img, 7, 9, 3, k, col.lightened(0.12))
	# the cinched neck and the drawstring
	for x in range(5, 12):
		_px(img, x, 6, k, tie)
	for y in range(4, 7):
		_px(img, 7, y, k, tie)
		_px(img, 8, y, k, tie)
	_px(img, 5, 5, k, tie.lightened(0.15))
	_px(img, 10, 5, k, tie.lightened(0.15))
	_px(img, 6, 12, k, col.darkened(0.25))


func _px(img: Image, x: int, y: int, k: float, c: Color) -> void:
	var n := maxi(1, int(round(k)))
	for dy in n:
		for dx in n:
			var px := int(x * k) + dx
			var py := int(y * k) + dy
			if px >= 0 and py >= 0 and px < img.get_width() and py < img.get_height():
				img.set_pixel(px, py, c)


func _blob_px(img: Image, cx: int, cy: int, r: int, k: float, c: Color) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			var dx := float(x - cx)
			var dy := float(y - cy)
			if dx * dx + dy * dy <= float(r * r) + 0.4:
				_px(img, x, y, k, c)


func _ingot(img: Image, k: float, light: Color, dark: Color) -> void:
	for y in range(6, 13):
		var half := 3 + int((y - 6) * 0.55)
		for x in range(8 - half, 8 + half):
			var c := light if y < 9 else dark
			_px(img, x, y, k, c)
	for x in range(4, 12):
		_px(img, x, 6, k, Color(1, 1, 1, 0.55))


func _gem(img: Image, k: float, light: Color, dark: Color) -> void:
	for y in range(4, 13):
		var d := absi(y - 8)
		var half := maxi(1, 5 - d)
		for x in range(8 - half, 8 + half):
			var c := light if (x + y) % 3 != 0 else dark
			_px(img, x, y, k, c)
	_px(img, 6, 6, k, Color(1, 1, 1, 0.85))
	_px(img, 7, 6, k, Color(1, 1, 1, 0.85))


# ================================================================ tool & armour icons
func _tool_head(id: int) -> Color:
	match Gear.tier_of(id):
		0:
			return Color(0.62, 0.46, 0.26)   # wood
		1:
			return Color(0.60, 0.60, 0.63)   # stone
		2:
			return Color(0.86, 0.86, 0.90)   # iron
		3:
			return Color(0.36, 0.90, 0.92)   # diamond
	return Color(0.6, 0.6, 0.6)


func _tool_dark(id: int) -> Color:
	return _shade(_tool_head(id), 0.7)


func _armor_col(id: int) -> Color:
	match str(Gear.ARMOR[id]["set"]):
		"leather":
			return Color(0.60, 0.40, 0.24)
		"iron":
			return Color(0.82, 0.82, 0.87)
		"diamond":
			return Color(0.38, 0.86, 0.86)
	return Color(0.7, 0.7, 0.7)


func _armor_edge(id: int) -> Color:
	return _shade(_armor_col(id), 0.68)


## A tool drawn from its kind and material colour: a wooden handle plus a head whose
## shape reads as pick / axe / shovel / sword / hoe at a glance.
func _tool_icon(img: Image, k: float, kind: int, head: Color, dark: Color) -> void:
	if kind == Gear.SWORD or kind == Gear.HOE:
		# these are held straight: a vertical handle down the middle
		for i in 6:
			_px(img, 8, 15 - i, k, Color(0.45, 0.30, 0.15))
			_px(img, 7, 15 - i, k, Color(0.55, 0.38, 0.20))
	else:
		# a diagonal handle from the lower left to the middle
		for i in 12:
			_px(img, 3 + i, 15 - i, k, Color(0.45, 0.30, 0.15))
			_px(img, 4 + i, 15 - i, k, Color(0.55, 0.38, 0.20))
	match kind:
		Gear.PICK:
			for x in range(4, 13):
				var d := absi(x - 8)
				_px(img, x, 2 + d, k, head if d < 4 else dark)
				_px(img, x, 1 + d, k, dark)
		Gear.AXE:
			_blob_px(img, 12, 5, 3, k, head)
			_blob_px(img, 11, 4, 2, k, dark)
		Gear.SHOVEL:
			_blob_px(img, 12, 4, 3, k, head)
			_px(img, 11, 6, k, dark)
		Gear.SWORD:
			for y in range(3, 10):
				_px(img, 8, y, k, head)
				_px(img, 7, y, k, dark)
			for x in range(5, 12):
				_px(img, x, 10, k, Color(0.52, 0.42, 0.22))
			_px(img, 8, 11, k, dark)
		Gear.HOE:
			for x in range(4, 13):
				_px(img, x, 2, k, head)
				_px(img, x, 3, k, dark)


## A piece of armour drawn from its slot and material colour.
func _armor_icon(img: Image, k: float, slot: int, c: Color, e: Color) -> void:
	match slot:
		Gear.SLOT_HELMET:
			for y in range(4, 12):
				var half := 5 - absi(y - 7)
				for x in range(8 - half, 8 + half):
					_px(img, x, y, k, c if y < 8 else e)
		Gear.SLOT_CHEST:
			for y in range(4, 13):
				for x in range(3, 13):
					if y < 6 and (x < 5 or x > 10):
						continue
					_px(img, x, y, k, c if (x + y) % 5 != 0 else e)
		Gear.SLOT_LEGS:
			for y in range(4, 13):
				for x in range(5, 11):
					if y > 8 and x > 7:
						continue
					_px(img, x, y, k, c if y < 8 else e)
		Gear.SLOT_BOOTS:
			for y in range(8, 14):
				for x in range(4, 12):
					_px(img, x, y, k, c if y < 12 else e)


## A cut of meat: a rounded body with a lighter marbling highlight.
func _meat(img: Image, k: float, body: Color, shade: Color) -> void:
	_blob_px(img, 8, 9, 4, k, body)
	_blob_px(img, 7, 8, 2, k, shade)
	_px(img, 6, 11, k, shade)
	_px(img, 10, 7, k, Color(1, 1, 1, 0.35))