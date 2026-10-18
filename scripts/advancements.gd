extends Node
## The advancement system: a list of milestones the player can reach, the rules that
## test each one against the events the game already emits, and the state that records
## what has been earned.
##
## An advancement is data, not code. Each entry names a group, an icon (an existing
## item or block id, so the icon renderer draws it), a name and a description, and the
## event that can earn it. `on` is one event name or several; `want` optionally lists
## the values that count (block ids for break/place, item ids for craft/obtain/smelt,
## species names for kill); `goal` turns a single event into a counted one; `min`
## unlocks on a value reaching a threshold instead of firing an event.
##
## Everything funnels through `trigger(event, value)`, so adding a milestone is one
## line in `_ready` and one call site that was already there -- no per-advancement
## plumbing in the systems that mine, build, craft or fight.

signal unlocked(id: String)      # an advancement was just earned
signal progressed(id: String)    # progress on a counted goal changed

## The groups, in display order. `name` is the English source string; the UI runs it
## through I18n, like every other string.
const GROUPS := [
	{"id": "start", "name": "Getting Started"},
	{"id": "mining", "name": "Mining"},
	{"id": "building", "name": "Building"},
	{"id": "farm", "name": "Husbandry"},
	{"id": "adventure", "name": "Adventure"},
	{"id": "industry", "name": "Industry"},
]

var _defs: Array = []            # in construction order, which is display order
var _by_id: Dictionary = {}      # id -> definition
var _by_event: Dictionary = {}   # event name -> Array of definitions
var _done: Dictionary = {}       # id -> true
var _progress: Dictionary = {}   # id -> int, for counted goals


func _ready() -> void:
	_build()


## The definitions. Every icon is a real id, so `Items.icon` can draw it.
func _build() -> void:
	_defs = [
		# ---- getting started
		_d("root", "start", Blocks.GRASS, "VoxelCraft",
			"Break your first block.", "break"),
		_d("wood", "start", Blocks.LOG, "Getting Wood",
			"Pick up a log from a tree.", "obtain", {"want": [Blocks.LOG, Blocks.BIRCH_LOG]}),
		_d("bench", "start", Blocks.CRAFTING_TABLE, "Benchmarking",
			"Craft a crafting table.", ["craft", "place"], {"want": [Blocks.CRAFTING_TABLE]}),
		_d("stick", "start", Blocks.ITEM_STICK, "A Stick to Build With",
			"Craft a stick.", "craft", {"want": [Blocks.ITEM_STICK]}),
		_d("wood_pick", "start", Blocks.ITEM_WOOD_PICK, "Time to Mine",
			"Craft a wooden pickaxe.", "craft", {"want": [Blocks.ITEM_WOOD_PICK]}),
		_d("stone_pick", "start", Blocks.ITEM_STONE_PICK, "Getting an Upgrade",
			"Craft a stone pickaxe.", "craft", {"want": [Blocks.ITEM_STONE_PICK]}),
		_d("cobble", "start", Blocks.COBBLESTONE, "Stone Age",
			"Pick up cobblestone.", "obtain", {"want": [Blocks.COBBLESTONE]}),

		# ---- mining
		_d("coal", "mining", Blocks.ITEM_COAL, "Fuel Up",
			"Pick up a lump of coal.", "obtain", {"want": [Blocks.ITEM_COAL]}),
		_d("iron", "mining", Blocks.ITEM_IRON, "Acquire Hardware",
			"Smelt or find an iron ingot.", ["obtain", "smelt"], {"want": [Blocks.ITEM_IRON]}),
		_d("copper", "mining", Blocks.ITEM_COPPER, "Conductive",
			"Get a copper ingot.", ["obtain", "smelt"], {"want": [Blocks.ITEM_COPPER]}),
		_d("gold", "mining", Blocks.ITEM_GOLD, "Gold Rush",
			"Get a gold ingot.", ["obtain", "smelt"], {"want": [Blocks.ITEM_GOLD]}),
		_d("diamond", "mining", Blocks.ITEM_DIAMOND, "Diamonds!",
			"Pick up a diamond.", "obtain", {"want": [Blocks.ITEM_DIAMOND]}),
		_d("obsidian", "mining", Blocks.OBSIDIAN, "Very Hard",
			"Mine a block of obsidian.", "break", {"want": [Blocks.OBSIDIAN]}),
		_d("miner", "mining", Blocks.ITEM_IRON_PICK, "Miner",
			"Break 100 blocks.", "break", {"goal": 100}),

		# ---- building
		_d("torch", "building", Blocks.TORCH, "Torchlight",
			"Make a torch.", ["craft", "place"], {"want": [Blocks.TORCH]}),
		_d("furnace", "building", Blocks.FURNACE, "Hot Topic",
			"Craft a furnace.", ["craft", "place"], {"want": [Blocks.FURNACE]}),
		_d("chest", "building", Blocks.CHEST, "Safe Storage",
			"Craft a chest.", ["craft", "place"], {"want": [Blocks.CHEST]}),
		_d("ladder", "building", Blocks.LADDER, "On the Up",
			"Place a ladder.", "place", {"want": [Blocks.LADDER]}),
		_d("door", "building", Blocks.DOOR, "Home Sweet Home",
			"Place a door.", "place", {"want": [Blocks.DOOR]}),
		_d("glowstone", "building", Blocks.GLOWSTONE, "Bright Idea",
			"Get a block of glowstone.", "obtain", {"want": [Blocks.GLOWSTONE]}),
		_d("builder", "building", Blocks.PLANKS, "Architect",
			"Place 200 blocks.", "place", {"goal": 200}),

		# ---- husbandry
		_d("seeds", "farm", Blocks.ITEM_SEEDS, "Planting",
			"Pick up wheat seeds.", "obtain", {"want": [Blocks.ITEM_SEEDS]}),
		_d("hoe", "farm", Blocks.ITEM_WOOD_HOE, "Tilling",
			"Craft a hoe.", "craft", {"want": [Blocks.ITEM_WOOD_HOE]}),
		_d("bread", "farm", Blocks.ITEM_BREAD, "Baking Bread",
			"Bake bread from wheat.", "craft", {"want": [Blocks.ITEM_BREAD]}),
		_d("wool", "farm", Blocks.WOOL_0, "Shear Delight",
			"Get a block of wool.", "obtain", {"want": [Blocks.WOOL_0]}),
		_d("cooked", "farm", Blocks.ITEM_BEEF_COOKED, "Meal Time",
			"Cook meat in a furnace.", ["obtain", "smelt"],
			{"want": [Blocks.ITEM_BEEF_COOKED, Blocks.ITEM_PORKCHOP_COOKED,
				Blocks.ITEM_CHICKEN_COOKED]}),
		_d("bucket", "farm", Blocks.ITEM_BUCKET, "Handy Bucket",
			"Craft a bucket.", "craft", {"want": [Blocks.ITEM_BUCKET]}),

		# ---- adventure
		_d("sword", "adventure", Blocks.ITEM_IRON_SWORD, "Sharp",
			"Craft a sword.", "craft",
			{"want": [Blocks.ITEM_WOOD_SWORD, Blocks.ITEM_STONE_SWORD,
				Blocks.ITEM_IRON_SWORD, Blocks.ITEM_DIAMOND_SWORD]}),
		_d("hunter", "adventure", Blocks.ITEM_IRON_SWORD, "Monster Hunter",
			"Kill a hostile mob.", "kill",
			{"want": ["zombie", "skeleton", "spider", "creeper", "slime", "enderman"]}),
		_d("bone", "adventure", Blocks.ITEM_BONE, "Bone Collector",
			"Pick up a bone.", "obtain", {"want": [Blocks.ITEM_BONE]}),
		_d("pearl", "adventure", Blocks.ITEM_ENDER_PEARL, "All the Ender",
			"Get an ender pearl.", "obtain", {"want": [Blocks.ITEM_ENDER_PEARL]}),
		_d("merchant", "adventure", Blocks.ITEM_EMERALD, "Trade Up",
			"Trade with a villager.", "trade"),
		_d("dreamer", "adventure", Blocks.BED, "Sweet Dreams",
			"Sleep through the night.", "sleep"),
		_d("enchanter", "adventure", Blocks.ENCHANTING_TABLE, "Enchanted",
			"Enchant a tool or a piece of armour.", "enchant"),
		_d("experienced", "adventure", Blocks.ITEM_DIAMOND, "Experienced",
			"Reach experience level 10.", "level", {"min": 10}),

		# ---- industry
		_d("wire", "industry", Blocks.WIRE, "Copper Conductor",
			"Draw wire from a copper ingot.", "craft", {"want": [Blocks.WIRE]}),
		_d("battery", "industry", Blocks.BATTERY, "Power Cell",
			"Craft a battery.", "craft", {"want": [Blocks.BATTERY]}),
		_d("relay", "industry", Blocks.RELAY, "Wired Up",
			"Craft a signal relay.", ["craft", "place"], {"want": [Blocks.RELAY]}),
		_d("lamp", "industry", Blocks.LAMP, "Let There Be Light",
			"Craft a lamp.", ["craft", "place"], {"want": [Blocks.LAMP]}),
		_d("piston", "industry", Blocks.PISTON, "Moving Parts",
			"Craft a piston.", ["craft", "place"], {"want": [Blocks.PISTON]}),

		# ---- the husbandry, fishing, explosives and potion content
		_d("breed", "farm", Blocks.ITEM_CARROT, "Two by Two",
			"Breed a pair of animals with the food they eat.", "breed"),
		_d("carrot", "farm", Blocks.ITEM_CARROT, "Root Crop",
			"Harvest a carrot.", "obtain", {"want": [Blocks.ITEM_CARROT]}),
		_d("potato", "farm", Blocks.ITEM_POTATO, "Underground Harvest",
			"Dig up a potato.", "obtain", {"want": [Blocks.ITEM_POTATO]}),
		_d("baked", "farm", Blocks.ITEM_BAKED_POTATO, "Hot Potato",
			"Bake a potato in a furnace.", ["obtain", "smelt"],
			{"want": [Blocks.ITEM_BAKED_POTATO]}),
		_d("fish", "farm", Blocks.ITEM_FISH_RAW, "Gone Fishing",
			"Catch or cook a fish.", ["obtain", "smelt"],
			{"want": [Blocks.ITEM_FISH_RAW, Blocks.ITEM_FISH_COOKED]}),
		_d("flint", "adventure", Blocks.ITEM_FLINT, "Spark",
			"Pick a shard of flint out of gravel.", "obtain", {"want": [Blocks.ITEM_FLINT]}),
		_d("wolf", "adventure", Blocks.ITEM_BONE, "Best Friend",
			"Tame a wolf with a bone.", "tame"),
		_d("boom", "industry", Blocks.TNT, "Boom!",
			"Light a block of TNT and let it blow.", "tnt"),
		_d("alchemist", "industry", Blocks.ITEM_POTION_NIGHT, "Alchemist",
			"Brew a potion and drink it.", "potion"),
		_d("dispenser", "industry", Blocks.DISPENSER, "Automatic",
			"Craft a dispenser.", ["craft", "place"], {"want": [Blocks.DISPENSER]}),
	]

	_by_id = {}
	_by_event = {}
	for d in _defs:
		_by_id[d["id"]] = d
		var ev = d["on"]
		var events: Array = ev if ev is Array else [ev]
		for e in events:
			if not _by_event.has(e):
				_by_event[e] = []
			_by_event[e].append(d)


func _d(id: String, group: String, icon: int, name: String, desc: String, on,
		opts: Dictionary = {}) -> Dictionary:
	var d := {"id": id, "group": group, "icon": icon, "name": name, "desc": desc, "on": on}
	for k in opts:
		d[k] = opts[k]
	return d


# ================================================================ events
## Test every advancement that listens for `event` against this occurrence. Safe to
## call on every frame: only definitions whose event matched are even looked at, and a
## finished one is skipped on the first line.
func trigger(event: String, value = null) -> void:
	var list: Array = _by_event.get(event, [])
	if list.is_empty():
		return
	for d in list:
		var id: String = d["id"]
		if _done.has(id):
			continue
		if d.has("min") and value != null and int(value) < int(d["min"]):
			continue
		if d.has("want"):
			var w: Array = d["want"]
			if w.size() > 0 and not w.has(value):
				continue
		var goal := int(d.get("goal", 1))
		if goal <= 1:
			_grant(id)
		else:
			_progress[id] = int(_progress.get(id, 0)) + 1
			progressed.emit(id)
			if int(_progress[id]) >= goal:
				_grant(id)


func _grant(id: String) -> void:
	if _done.has(id) or not _by_id.has(id):
		return
	_done[id] = true
	unlocked.emit(id)


## Grants an advancement outright, for the console and for tests.
func grant(id: String) -> bool:
	if not _by_id.has(id) or _done.has(id):
		return false
	_grant(id)
	return true


## Grants everything not yet earned and returns how many were new. Backs the console's
## `/advancement grant all`.
func grant_all() -> int:
	var n := 0
	for d in _defs:
		var id: String = d["id"]
		if not _done.has(id):
			_grant(id)
			n += 1
	return n


## Takes an advancement back, for the console. True when it had been earned.
func revoke(id: String) -> bool:
	if not _done.has(id):
		return false
	_done.erase(id)
	return true


# ================================================================ queries
func is_done(id: String) -> bool:
	return _done.has(id)


func progress_of(id: String) -> int:
	return int(_progress.get(id, 0))


## Sets a counted goal's progress without firing an event. For screenshots and for a
## future console command that wants to show a partly-complete bar.
func set_progress(id: String, n: int) -> void:
	if _by_id.has(id):
		_progress[id] = maxi(0, n)


func def_of(id: String) -> Dictionary:
	return _by_id.get(id, {})


func defs() -> Array:
	return _defs


func done_count() -> int:
	return _done.size()


func total() -> int:
	return _defs.size()


## Every definition in one group, in construction order.
func group_defs(group: String) -> Array:
	var out: Array = []
	for d in _defs:
		if d["group"] == group:
			out.append(d)
	return out


# ================================================================ persistence
func reset() -> void:
	_done = {}
	_progress = {}


func serialize() -> Dictionary:
	var ids: Array = _done.keys()
	ids.sort()
	return {"done": ids, "prog": _progress}


func load_from(state: Dictionary) -> void:
	_done = {}
	_progress = {}
	var ids = state.get("done", [])
	if ids is Array:
		for id in ids:
			# a save made before a milestone was renamed simply drops that entry
			if _by_id.has(str(id)):
				_done[str(id)] = true
	var prog = state.get("prog", {})
	if prog is Dictionary:
		for id in prog:
			if _by_id.has(str(id)):
				_progress[str(id)] = int(prog[id])
