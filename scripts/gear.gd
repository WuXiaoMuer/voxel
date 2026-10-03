extends Node
## Gear database: tools, armour, the smelting and fuel tables, and the block -> tool
## rules. Built in _ready() rather than declared as const because the keys are the
## Blocks autoload's constants, which are not compile-time constants — the same
## reason Items.DESC is built at runtime.

# tool kinds
const PICK := 0
const AXE := 1
const SHOVEL := 2
const SWORD := 3
const HOE := 4

# armour slots
const SLOT_HELMET := 0
const SLOT_CHEST := 1
const SLOT_LEGS := 2
const SLOT_BOOTS := 3

const MAX_ARMOR_POINTS := 20.0

var TOOLS: Dictionary = {}      # item id -> {kind, tier, speed, dmg, dur}
var ARMOR: Dictionary = {}      # item id -> {slot, points, dur, set}
var SMELTING: Dictionary = {}   # input id -> output id
var FUEL: Dictionary = {}       # item id -> burn seconds
var REQUIRES: Dictionary = {}   # block id -> [tool kind, min tier] needed to drop
var TOOL_FOR: Dictionary = {}   # block id -> the tool kind that mines it faster


func _ready() -> void:
	_build()


func _build() -> void:
	var tiers := {
		"wood": {"tier": 0, "speed": 2.0, "dur": 60, "dmg": [2, 3, 2, 4, 1]},
		"stone": {"tier": 1, "speed": 4.0, "dur": 132, "dmg": [3, 4, 3, 5, 1]},
		"iron": {"tier": 2, "speed": 6.0, "dur": 251, "dmg": [4, 5, 4, 6, 1]},
		"diamond": {"tier": 3, "speed": 8.0, "dur": 1562, "dmg": [5, 6, 5, 7, 1]},
	}
	var ids := {
		"wood": [Blocks.ITEM_WOOD_PICK, Blocks.ITEM_WOOD_AXE, Blocks.ITEM_WOOD_SHOVEL, Blocks.ITEM_WOOD_SWORD, Blocks.ITEM_WOOD_HOE],
		"stone": [Blocks.ITEM_STONE_PICK, Blocks.ITEM_STONE_AXE, Blocks.ITEM_STONE_SHOVEL, Blocks.ITEM_STONE_SWORD, Blocks.ITEM_STONE_HOE],
		"iron": [Blocks.ITEM_IRON_PICK, Blocks.ITEM_IRON_AXE, Blocks.ITEM_IRON_SHOVEL, Blocks.ITEM_IRON_SWORD, Blocks.ITEM_IRON_HOE],
		"diamond": [Blocks.ITEM_DIAMOND_PICK, Blocks.ITEM_DIAMOND_AXE, Blocks.ITEM_DIAMOND_SHOVEL, Blocks.ITEM_DIAMOND_SWORD, Blocks.ITEM_DIAMOND_HOE],
	}
	for tier_name in ids:
		var t: Dictionary = tiers[tier_name]
		var arr: Array = ids[tier_name]
		for kind in 5:
			TOOLS[arr[kind]] = {
				"kind": kind, "tier": int(t["tier"]), "speed": float(t["speed"]),
				"dmg": int(t["dmg"][kind]), "dur": int(t["dur"]), "set": tier_name,
			}

	var sets := {
		"leather": {"points": [1, 3, 2, 1], "dur": [55, 80, 75, 65]},
		"iron": {"points": [2, 6, 5, 2], "dur": [165, 240, 225, 195]},
		"diamond": {"points": [3, 8, 6, 3], "dur": [363, 528, 495, 429]},
	}
	var armor_ids := {
		"leather": [Blocks.ITEM_LEATHER_HELMET, Blocks.ITEM_LEATHER_CHESTPLATE, Blocks.ITEM_LEATHER_LEGGINGS, Blocks.ITEM_LEATHER_BOOTS],
		"iron": [Blocks.ITEM_IRON_HELMET, Blocks.ITEM_IRON_CHESTPLATE, Blocks.ITEM_IRON_LEGGINGS, Blocks.ITEM_IRON_BOOTS],
		"diamond": [Blocks.ITEM_DIAMOND_HELMET, Blocks.ITEM_DIAMOND_CHESTPLATE, Blocks.ITEM_DIAMOND_LEGGINGS, Blocks.ITEM_DIAMOND_BOOTS],
	}
	for set_name in armor_ids:
		var s: Dictionary = sets[set_name]
		var arr2: Array = armor_ids[set_name]
		for slot in 4:
			ARMOR[arr2[slot]] = {
				"slot": slot, "points": int(s["points"][slot]),
				"dur": int(s["dur"][slot]), "set": set_name,
			}

	SMELTING = {
		Blocks.IRON_ORE: Blocks.ITEM_IRON,
		Blocks.GOLD_ORE: Blocks.ITEM_GOLD,
		Blocks.COPPER_ORE: Blocks.ITEM_COPPER,
		Blocks.SAND: Blocks.GLASS,
		Blocks.COBBLESTONE: Blocks.STONE,
		Blocks.LOG: Blocks.ITEM_COAL,          # charcoal
		Blocks.ITEM_PORKCHOP_RAW: Blocks.ITEM_PORKCHOP_COOKED,
		Blocks.ITEM_BEEF_RAW: Blocks.ITEM_BEEF_COOKED,
		Blocks.ITEM_CHICKEN_RAW: Blocks.ITEM_CHICKEN_COOKED,
	}
	FUEL = {
		Blocks.ITEM_COAL: 80.0,
		Blocks.LOG: 15.0,
		Blocks.PLANKS: 15.0,
		Blocks.CRAFTING_TABLE: 15.0,
		Blocks.ITEM_STICK: 5.0,
	}

	# a block on this list drops nothing without the right tool; everything else drops
	# with a bare hand (a shovel or axe only makes those blocks *faster*, as in Minecraft)
	REQUIRES = {
		Blocks.STONE: [PICK, 0], Blocks.COBBLESTONE: [PICK, 0],
		Blocks.STONE_BRICK: [PICK, 0], Blocks.SANDSTONE: [PICK, 0],
		Blocks.BRICK: [PICK, 0], Blocks.FURNACE: [PICK, 0],
		Blocks.IRON_ORE: [PICK, 1], Blocks.COPPER_ORE: [PICK, 1],
		Blocks.IRON_BLOCK: [PICK, 1],
		Blocks.GOLD_ORE: [PICK, 2], Blocks.DIAMOND_ORE: [PICK, 2],
		Blocks.GOLD_BLOCK: [PICK, 2], Blocks.DIAMOND_BLOCK: [PICK, 2],
		Blocks.OBSIDIAN: [PICK, 3],
	}
	TOOL_FOR = {
		Blocks.STONE: PICK, Blocks.COBBLESTONE: PICK, Blocks.STONE_BRICK: PICK,
		Blocks.SANDSTONE: PICK, Blocks.BRICK: PICK, Blocks.FURNACE: PICK,
		Blocks.FURNACE_LIT: PICK, Blocks.IRON_ORE: PICK, Blocks.GOLD_ORE: PICK,
		Blocks.DIAMOND_ORE: PICK, Blocks.COAL_ORE: PICK, Blocks.COPPER_ORE: PICK,
		Blocks.IRON_BLOCK: PICK, Blocks.GOLD_BLOCK: PICK, Blocks.DIAMOND_BLOCK: PICK,
		Blocks.OBSIDIAN: PICK, Blocks.ICE: PICK,
		Blocks.LOG: AXE, Blocks.PLANKS: AXE, Blocks.CRAFTING_TABLE: AXE,
		Blocks.CHEST: AXE, Blocks.DOOR: AXE, Blocks.DOOR_OPEN: AXE,
		Blocks.FENCE: AXE, Blocks.LADDER: AXE,
		Blocks.DIRT: SHOVEL, Blocks.GRASS: SHOVEL, Blocks.SAND: SHOVEL,
		Blocks.GRAVEL: SHOVEL, Blocks.SNOW: SHOVEL, Blocks.FARMLAND: SHOVEL,
	}


func is_tool(id: int) -> bool:
	return TOOLS.has(id)


func is_armor(id: int) -> bool:
	return ARMOR.has(id)


func tool_kind(id: int) -> int:
	return int(TOOLS[id]["kind"]) if TOOLS.has(id) else -1


func tier_of(id: int) -> int:
	return int(TOOLS[id]["tier"]) if TOOLS.has(id) else -1


func armor_slot(id: int) -> int:
	return int(ARMOR[id]["slot"]) if ARMOR.has(id) else -1


## The durability a fresh copy of this tool/armour starts with (0 for anything else).
func max_durability(id: int) -> int:
	if TOOLS.has(id):
		return int(TOOLS[id]["dur"])
	if ARMOR.has(id):
		return int(ARMOR[id]["dur"])
	return 0


## Melee damage of whatever is held: a tool's own damage, or a bare fist.
func damage_of(id: int) -> float:
	if TOOLS.has(id):
		return float(TOOLS[id]["dmg"])
	return 1.0


## Mining speed multiplier of the held tool against a given block. A tool only speeds up
## the blocks it is the right kind for; a bare hand or a wrong tool is 1.0.
func speed_for(tool_id: int, block_id: int) -> float:
	if TOOLS.has(tool_id):
		if int(TOOL_FOR.get(block_id, -1)) == int(TOOLS[tool_id]["kind"]):
			return float(TOOLS[tool_id]["speed"])
	return 1.0


## What a block drops when broken with the given tool. Blocks that *require* a tool
## yield nothing (-1) without the right kind and tier; everything else falls back to the
## block's own drop.
func drop_for(block_id: int, tool_id: int) -> int:
	if REQUIRES.has(block_id):
		var req: Array = REQUIRES[block_id]
		if TOOLS.has(tool_id) and int(TOOLS[tool_id]["kind"]) == int(req[0]) \
				and int(TOOLS[tool_id]["tier"]) >= int(req[1]):
			return Blocks.drops[block_id]
		return -1
	return Blocks.drops[block_id]


## Total armour points of an armour array (four slots, each {id,count,dur} or null).
func armor_points(armor: Array) -> int:
	var total := 0
	for cell in armor:
		if cell == null:
			continue
		var id := int(cell.get("id", 0))
		if ARMOR.has(id):
			total += int(ARMOR[id]["points"])
	return total


## Fraction of incoming damage the armour set absorbs (Minecraft's points / 25, capped).
func armor_reduction(armor: Array) -> float:
	return minf(float(armor_points(armor)), MAX_ARMOR_POINTS) / 25.0