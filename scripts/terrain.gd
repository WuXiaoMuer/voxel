class_name VoxelTerrain
extends RefCounted
## Deterministic voxel terrain: heightfield continents, biomes, caves, ore veins,
## trees, plants and oceans. Pure data in, block ids out.

# ---------------------------------------------------------------- vertical layout
# The world is a stack of 16-tall sections. MIN_Y / MAX_Y are the *world* bounds, and
# the ones every other file should read. Only the sections that hold something are
# allocated, so the sky above the terrain costs nothing and the ceiling can be raised
# without paying for it.
const SEC := 16
const MIN_Y := -64
const MAX_Y := 320
const SECTIONS := (MAX_Y - MIN_Y) / SEC

## The tallest the heightfield may reach. Pinned to the value it had when the world
## was 80 tall, *not* written as `MAX_Y - 8`: the raw noise peaks near y=89, so letting
## the clamp follow the ceiling would grow every mountain by seventeen blocks and pull
## the biome thresholds (mountain above 62, snow above 68) and every spawn and test
## threshold out from under the world they were calibrated on.
const CRUST_MAX := 72

const SEA := 32
const CHUNK := 16

## The band caves are carved in. The floor of it is what the deep world added: above 4
## the range is the one this generator always had, so the surface stays untouched.
const CAVE_FLOOR := -24
const CAVE_CEIL := 58


## The section a world y sits in.
static func sec_of(y: int) -> int:
	return y >> 4


## The y within its section, 0..15.
##
## `>>` and `&`, never `/ 16` and `% 16`: integer division in GDScript truncates
## toward zero, so -1 / 16 is 0 and -1 % 16 is -1, which would silently file the block
## below y=0 into section 0 at the top. Shifts floor toward negative infinity, so
## -1 >> 4 is -1 and -1 & 15 is 15, which is what a section lookup needs. The world
## only goes negative once MIN_Y does, so this is asserted in the hand test today.
static func ly_of(y: int) -> int:
	return y & 15

const B_OCEAN := 0
const B_BEACH := 1
const B_PLAINS := 2
const B_FOREST := 3
const B_DESERT := 4
const B_SNOWY := 5
const B_MOUNTAIN := 6
## A second kind of forest rather than a second kind of tree: what you find underfoot
## tells you which one you are in, so a birch wood is birch, not "forest, again".
const B_BIRCH_FOREST := 7

## Tree kinds, as carried in `tree_at`'s "kind".
const TREE_OAK := 0
const TREE_CACTUS := 1
const TREE_BIRCH := 2

## Villages sit on a coarse grid, one candidate per cell. A cell either holds a village
## or it does not, and everything about that village -- where it is, how high its terrace
## sits, which way each house faces -- is a pure function of the cell and the seed. That
## is what lets every chunk that touches a village stamp the same blocks independently and
## in any thread, with `_put` discarding whatever falls outside the chunk.
const VILLAGE_CELL := 112
## How far a village's terrace and its outermost walls reach from the centre.
const VILLAGE_RADIUS := 26
## How many layers of ground above the terrace are cleared inside that disc. Any hill
## taller than this is left standing, which is the price of not sampling every column of
## the disc just to size the chunk's buffer.
const VILLAGE_CLEAR := 22
## Chance, out of 1000 cells, that a cell holds a village.
const VILLAGE_CHANCE := 180

var seed_value := 0

var _n_cont := FastNoiseLite.new()
var _n_hill := FastNoiseLite.new()
var _n_detail := FastNoiseLite.new()
var _n_temp := FastNoiseLite.new()
var _n_humid := FastNoiseLite.new()
var _n_cave := FastNoiseLite.new()
var _n_cave2 := FastNoiseLite.new()
## Two jobs: which kind of forest grows here, and how thick it is. A single low-frequency
## field means a wood has groves and clearings instead of an even sprinkle of trunks.
var _n_forest := FastNoiseLite.new()


func _init(s: int) -> void:
	seed_value = s
	_n_cont.seed = s
	_n_cont.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_cont.frequency = 0.0022
	_n_cont.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_cont.fractal_octaves = 4
	_n_cont.fractal_gain = 0.5

	_n_hill.seed = s + 1
	_n_hill.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_hill.frequency = 0.017
	_n_hill.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_hill.fractal_octaves = 3

	_n_detail.seed = s + 2
	_n_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_detail.frequency = 0.075
	_n_detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_detail.fractal_octaves = 2

	_n_temp.seed = s + 3
	_n_temp.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_temp.frequency = 0.0035
	_n_temp.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_temp.fractal_octaves = 2

	_n_humid.seed = s + 4
	_n_humid.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_humid.frequency = 0.0042
	_n_humid.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_humid.fractal_octaves = 2

	_n_forest.seed = s + 7
	_n_forest.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_forest.frequency = 0.010
	_n_forest.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_forest.fractal_octaves = 2

	_n_cave.seed = s + 5
	_n_cave.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_cave.frequency = 0.038
	_n_cave.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_cave.fractal_octaves = 2

	_n_cave2.seed = s + 6
	_n_cave2.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_cave2.frequency = 0.021
	_n_cave2.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_cave2.fractal_octaves = 3


# ================================================================ hashing
func hash3(a: int, b: int, c: int) -> int:
	var x := (a * 374761393 + b * 668265263 + c * 1442695040) & 0x7fffffff
	x = ((x ^ (x >> 13)) * 1274126177) & 0x7fffffff
	x = (x ^ (x >> 16)) & 0x7fffffff
	return x


# ================================================================ fields
func height_at(wx: int, wz: int) -> int:
	var cont := _n_cont.get_noise_2d(float(wx), float(wz))
	var hills := _n_hill.get_noise_2d(float(wx), float(wz))
	var det := _n_detail.get_noise_2d(float(wx), float(wz))
	var h := 0.0
	if cont < -0.22:
		# ocean basin: falls away quickly past the shoreline
		h = float(SEA) + (cont + 0.22) * 52.0
	else:
		h = float(SEA) + 8.0 + cont * 13.0
		var mountain := smoothstep(0.26, 0.60, cont)
		h += mountain * 30.0 * (0.5 + 0.5 * hills)
		h += hills * 4.0 * (1.0 - mountain * 0.7)
		h += det * 1.9
	return clampi(int(h), 3, CRUST_MAX)


func temperature_at(wx: int, wz: int) -> float:
	return _n_temp.get_noise_2d(float(wx), float(wz))


func humidity_at(wx: int, wz: int) -> float:
	return _n_humid.get_noise_2d(float(wx), float(wz))


## Which wood grows here, and how thick. Positive is birch, and the further from zero the
## better the growing.
func forest_at(wx: int, wz: int) -> float:
	return _n_forest.get_noise_2d(float(wx), float(wz))


func biome_at(wx: int, wz: int) -> int:
	return biome_from_height(wx, wz, height_at(wx, wz))


## The biome, when the caller has already sampled the height. `fill_chunk` needs both for
## every column of its heightfield cache, and `biome_at` would otherwise evaluate the three
## `height_at` noise samples a second time -- a third of the generator's height cost, spent
## twice, in its hottest loop.
func biome_from_height(wx: int, wz: int, h: int) -> int:
	if h > 62:
		return B_MOUNTAIN
	if h < SEA - 1:
		return B_OCEAN
	if h <= SEA + 1:
		return B_BEACH
	var t := temperature_at(wx, wz)
	var hum := humidity_at(wx, wz)
	if t > 0.24 and hum < 0.02:
		return B_DESERT
	if t < -0.30:
		return B_SNOWY
	if hum > 0.10:
		# The forest field decides which wood, so the boundary between an oak wood and a
		# birch wood is a winding edge rather than a straight line across the map.
		if forest_at(wx, wz) > 0.05:
			return B_BIRCH_FOREST
		return B_FOREST
	return B_PLAINS


## Returns [top, subsurface, deep] block ids for a surface column.
func _column_blocks(bio: int, h: int) -> Array:
	# deep is always stone; only the top layers change with the biome
	match bio:
		B_OCEAN:
			if h > SEA - 6:
				return [Blocks.SAND, Blocks.SAND, Blocks.STONE]
			return [Blocks.GRAVEL, Blocks.DIRT, Blocks.STONE]
		B_BEACH:
			return [Blocks.SAND, Blocks.SANDSTONE, Blocks.STONE]
		B_DESERT:
			return [Blocks.SAND, Blocks.SANDSTONE, Blocks.STONE]
		B_SNOWY:
			return [Blocks.SNOW, Blocks.DIRT, Blocks.STONE]
		B_MOUNTAIN:
			if h > 68:
				return [Blocks.SNOW, Blocks.STONE, Blocks.STONE]
			if h > 56:
				return [Blocks.STONE, Blocks.STONE, Blocks.STONE]
			return [Blocks.GRASS, Blocks.DIRT, Blocks.STONE]
	return [Blocks.GRASS, Blocks.DIRT, Blocks.STONE]


# ================================================================ trees & plants
## Returns {} or {"trunk": int, "y": int, "kind": int}.
##
## Density is the whole game here. A canopy reaches two blocks out, so one trunk already
## shades twenty-five columns; at the old 9%-of-columns rate the canopies of a forest
## closed into a single green roof with no sky in it, which is what "too many trees"
## looked like. These rates leave real gaps to walk through, and `forest_at` then makes
## them uneven -- thick groves and open clearings in the same wood, rather than an even
## sprinkle over the whole map.
func tree_at(wx: int, wz: int, h: int, bio: int) -> Dictionary:
	if h <= SEA:
		return {}
	var r := hash3(wx, 91, wz) % 10000
	var f := forest_at(wx, wz) if (bio == B_FOREST or bio == B_BIRCH_FOREST) else 0.0
	match bio:
		B_FOREST:
			# a grove runs several times the density of the open parts of the wood
			if r < 120 + int(maxf(0.0, -f) * 700.0):
				return {"trunk": 4 + hash3(wx, 7, wz) % 3, "y": h, "kind": TREE_OAK}
		B_BIRCH_FOREST:
			# a birch wood stays open even at its thickest: it is the sparse, walkable
			# contrast to the oak wood's closed groves, not just oak in another colour
			if r < 80 + int(maxf(0.0, f) * 260.0):
				return {"trunk": 4 + hash3(wx, 7, wz) % 3, "y": h, "kind": TREE_BIRCH}
		B_PLAINS:
			if r < 25:
				return {"trunk": 4 + hash3(wx, 7, wz) % 2, "y": h, "kind": TREE_OAK}
		B_SNOWY:
			if r < 80:
				return {"trunk": 5 + hash3(wx, 7, wz) % 3, "y": h, "kind": TREE_OAK}
		B_MOUNTAIN:
			if r < 40 and h < 62:
				return {"trunk": 4 + hash3(wx, 7, wz) % 2, "y": h, "kind": TREE_OAK}
		B_DESERT:
			if r < 70:
				return {"trunk": 2 + hash3(wx, 7, wz) % 2, "y": h, "kind": TREE_CACTUS}
	return {}


func plant_at(wx: int, wz: int, bio: int) -> int:
	if bio != B_PLAINS and bio != B_FOREST and bio != B_BIRCH_FOREST:
		return Blocks.AIR
	# a birch wood is a wood, so it is grassed over the same way an oak one is, only a
	# little thinner underfoot
	var r := hash3(wx, 311, wz) % 1000
	var grass_cut := 150 if bio == B_BIRCH_FOREST else 190
	if r < grass_cut:
		return Blocks.TALL_GRASS
	if r < grass_cut + 25:
		return Blocks.FLOWER_RED
	if r < grass_cut + 45:
		return Blocks.FLOWER_YELLOW
	return Blocks.AIR


# ================================================================ chunk fill
## One chunk column under construction, in 16-tall sections.
##
## The generator is a long sequence of overlapping passes, so during the build it works
## on one flat buffer spanning only the layers that can hold anything (the world floor
## up to the tallest canopy in range plus room for the crown). Air above that is what an
## *absent* section means, so nothing is allocated for the sky.
##
## `out()` then slices the buffer into the non-empty sections, which is the form the
## world stores. Sections that came out all air are dropped there rather than here.
class Volume:
	var base_y: int                 # world y of the buffer's bottom layer
	var ny: int                     # layers held, a multiple of SEC
	var data: PackedByteArray
	var nonair: PackedInt32Array    # per section: cells that are not air
	var occ: PackedInt32Array       # per section: cells that occlude
	## `Blocks` is an autoload, so `Blocks.occluder[id]` is a named-global lookup that has
	## to hand back a copy of the PackedByteArray -- and copying it bumps a reference count
	## that every worker thread then fights over the same cache line for. Held once here,
	## the column pass is three times faster on a single thread and, far more importantly,
	## it speeds up when more threads run it instead of slowing down.
	var occ_tab: PackedByteArray
	var air := 0

	func _init(b: int, n: int) -> void:
		base_y = b
		ny = n
		occ_tab = Blocks.occluder
		air = Blocks.AIR
		data = PackedByteArray()
		data.resize(VoxelTerrain.CHUNK * VoxelTerrain.CHUNK * n)
		data.fill(air)
		nonair.resize(n / VoxelTerrain.SEC)
		occ.resize(n / VoxelTerrain.SEC)

	func holds(y: int) -> bool:
		return y >= base_y and y < base_y + ny

	## Named `at` / `put` rather than `get` / `set`: those two are what `Object` already
	## calls for property access, and overriding them with a different signature is a
	## parse error.
	func at(x: int, y: int, z: int) -> int:
		if not holds(y):
			return air
		var c := VoxelTerrain.CHUNK
		return data[(x & 15) + (z & 15) * c + (y - base_y) * c * c]

	func put(x: int, y: int, z: int, id: int) -> void:
		if not holds(y):
			return
		var c := VoxelTerrain.CHUNK
		var idx := (x & 15) + (z & 15) * c + (y - base_y) * c * c
		var old: int = data[idx]
		if old == id:
			return
		data[idx] = id
		var si := (y - base_y) >> 4
		if old == air:
			nonair[si] += 1
		if id == air:
			nonair[si] -= 1
		# keeping the occluder tally here is free -- the write already knows the old
		# value -- and it is what lets a solid deep section be skipped later instead of
		# being scanned to discover it has no visible face
		occ[si] += occ_tab[id] - occ_tab[old]

	## Fills a vertical run of one column in a single call.
	##
	## A GDScript method call costs more than the dozen instructions `put` does, and the
	## column pass made 135 of them per column and 256 columns per chunk -- 34,000 calls to
	## write one chunk, all of them strictly in a row. Measured on eight threads, a loop of
	## calls runs *slower* than on one, so this is not only a constant factor: it is the
	## difference between the generator using the pool and fighting it.
	func put_run(x: int, z: int, y0: int, y1: int, id: int) -> void:
		var c := VoxelTerrain.CHUNK
		var step := c * c
		var col := (x & 15) + (z & 15) * c
		var lo := maxi(y0, base_y)
		var hi := mini(y1, base_y + ny)
		if hi <= lo:
			return
		var idx := col + (lo - base_y) * step
		var oid := occ_tab[id]
		for y in range(lo, hi):
			var old: int = data[idx]
			if old != id:
				data[idx] = id
				var si := (y - base_y) >> 4
				if old == air:
					nonair[si] += 1
				elif id == air:
					nonair[si] -= 1
				occ[si] += oid - occ_tab[old]
			idx += step

	## What the world stores: the section's non-empty slices keyed by section index,
	## plus how many cells in each section occlude. A section that holds nothing but air
	## is absent, not empty -- callers must treat a missing key as air.
	##
	## The occluder count goes out because it is what tells the world a deep section is
	## solid through and through and so has no face worth meshing. It is free here and
	## would cost a full 4096-cell scan to recover anywhere else.
	func out() -> Dictionary:
		var res := {}
		var counts := {}
		var nsec := ny / VoxelTerrain.SEC
		var per := VoxelTerrain.SEC * VoxelTerrain.CHUNK * VoxelTerrain.CHUNK
		var first := VoxelTerrain.sec_of(base_y)
		for si in nsec:
			counts[first + si] = occ[si]
			if nonair[si] == 0:
				continue
			res[first + si] = data.slice(si * per, (si + 1) * per)
		return {"sections": res, "occ": counts}


## Builds a chunk column and returns:
##   {"sections": {section: PackedByteArray(4096)}, "occ": {section: occluder count}}
## with section arrays indexed lx + lz*16 + ly*256.
func fill_chunk(cx: int, cz: int) -> Dictionary:
	const M := 3              # margin for trees whose canopy crosses the border
	const EW := CHUNK + M * 2

	var hcache := PackedInt32Array()
	hcache.resize(EW * EW)
	var bcache := PackedInt32Array()
	bcache.resize(EW * EW)
	var ox := cx * CHUNK
	var oz := cz * CHUNK
	# Which villages reach this chunk, and how high their roofs stand, so the volume is
	# tall enough for a village that sits higher than anything inside the chunk itself.
	var villages := villages_for_chunk(cx, cz)
	var vtop := MIN_Y
	for v in villages:
		vtop = maxi(vtop, int(v["plat"]) + VILLAGE_CLEAR)
	var tallest := MIN_Y
	for ex in EW:
		for ez in EW:
			var wx := ox + ex - M
			var wz := oz + ez - M
			var hv := height_at(wx, wz)
			hcache[ex + ez * EW] = hv
			bcache[ex + ez * EW] = biome_from_height(wx, wz, hv)
			tallest = maxi(tallest, hv)

	# Tall enough for the tallest canopy plus its crown cross, and for the sea: an
	# all-ocean chunk has a low `tallest` but still carries water up to SEA + 1.
	const CANOPY := 14
	var top := mini(MAX_Y - 1, maxi(maxi(tallest + CANOPY, SEA + 1), vtop))
	var sec_lo := sec_of(MIN_Y)
	var sec_hi := sec_of(top)
	var volume := Volume.new(sec_lo * SEC, (sec_hi - sec_lo + 1) * SEC)

	# ---- terrain columns
	for lx in CHUNK:
		for lz in CHUNK:
			var ei := (lx + M) + (lz + M) * EW
			var h: int = hcache[ei]
			var bio: int = bcache[ei]
			var col := _column_blocks(bio, h)
			var top_id: int = col[0]
			var sub: int = col[1]
			volume.put_run(lx, lz, MIN_Y + 1, h - 3, Blocks.STONE)
			volume.put_run(lx, lz, maxi(MIN_Y + 1, h - 3), h, sub)
			volume.put(lx, h, lz, top_id)
			volume.put(lx, MIN_Y, lz, Blocks.BEDROCK)
			if hash3(ox + lx, 5, oz + lz) % 4 == 0:
				volume.put(lx, MIN_Y + 1, lz, Blocks.BEDROCK)

	_place_ore_veins(cx, cz, volume, hcache, EW, M)
	_carve_caves(cx, cz, volume, hcache, EW, M)
	_fill_lava(volume, hcache, EW, M)
	_fill_water(volume, hcache, EW, M)
	_place_trees(cx, cz, volume, hcache, bcache, EW, M)
	_place_plants(cx, cz, volume, hcache, bcache, EW, M)
	# last, so the terrace overwrites any tree or plant that grew where the village stands
	_place_village(cx, cz, volume, villages)
	return volume.out()


## The lava sea at the bottom of the world. Everything the caves opened below the lava
## line becomes lava, which is where a player goes to fill a bucket. Filled *after* the
## carving, so it settles into the caves rather than being cut through by them, and
## before the water, so a flooded cave is still water.
const LAVA_SEA := -50


func _fill_lava(volume: Volume, hcache: PackedInt32Array, EW: int, M: int) -> void:
	for lx in CHUNK:
		for lz in CHUNK:
			var h: int = hcache[(lx + M) + (lz + M) * EW]
			var top := mini(LAVA_SEA, h)
			for y in range(MIN_Y + 1, top):
				if volume.at(lx, y, lz) == Blocks.AIR:
					volume.put(lx, y, lz, Blocks.LAVA)


func _fill_water(volume: Volume, hcache: PackedInt32Array, EW: int, M: int) -> void:
	for lx in CHUNK:
		for lz in CHUNK:
			var h: int = hcache[(lx + M) + (lz + M) * EW]
			if h >= SEA:
				continue
			for y in range(h + 1, SEA + 1):
				if volume.at(lx, y, lz) == Blocks.AIR:
					volume.put(lx, y, lz, Blocks.WATER)


func _carve_caves(cx: int, cz: int, volume: Volume, hcache: PackedInt32Array,
		EW: int, M: int) -> void:
	var ox := cx * CHUNK
	var oz := cz * CHUNK
	var y0 := CAVE_FLOOR
	var y1 := CAVE_CEIL
	var y := y0
	while y <= y1:
		for lx in range(0, CHUNK, 2):
			for lz in range(0, CHUNK, 2):
				var ei := (lx + M) + (lz + M) * EW
				var h: int = hcache[ei]
				if y >= h - 1:
					continue
				if h <= SEA + 1 and y > h - 5:
					continue
				var n := carve_here(ox + lx, y, oz + lz)
				if not n:
					continue
				for dy in 2:
					for dx in 2:
						for dz in 2:
							var px := lx + dx
							var pz := lz + dz
							var py := y + dy
							if px >= CHUNK or pz >= CHUNK or py >= MAX_Y:
								continue
							if py < MIN_Y + 1 or py > h - 1:
								continue
							var hei: int = hcache[(px + M) + (pz + M) * EW]
							if py > hei - 1:
								continue
							volume.put(px, py, pz, Blocks.AIR)
		y += 2


func _place_ore_veins(cx: int, cz: int, volume: Volume, hcache: PackedInt32Array,
		EW: int, M: int) -> void:
	# Two bands rather than one loop over the whole crust. The band above sea level is
	# the original one, untouched, so the surface world keeps exactly the ore it had; the
	# deep band is added on top of it. Looping over the whole crust instead would have
	# spread the same 26 veins over three times the rock and quietly thinned out the
	# shallow game to pay for the deep one.
	_ore_band(cx, cz, volume, hcache, EW, M, 4, MAX_Y, 26, 0)
	_ore_band(cx, cz, volume, hcache, EW, M, MIN_Y + 8, -5, 30, 1)


## Which ore a vein is, from how deep it sits. Absolute y rather than depth below the
## surface, so "diamonds are below y = -40" holds in every column and a player can learn
## it. Rarity comes from the `v %` gates rather than from narrow bands, so each ore
## still turns up across its whole depth instead of in one thin slice.
##
## The branches above y = 0 are the ones this generator always had, kept exactly as they
## were: every vein below sea level is decided by a branch that was already there, so
## giving the deep world its own ore could not move a single block of the shallow one.
func _ore_at(y: int, v: int) -> int:
	var id := Blocks.COAL_ORE
	if y < -40:
		id = Blocks.DIAMOND_ORE if v % 4 == 0 else Blocks.GOLD_ORE
	elif y < -24:
		id = Blocks.GOLD_ORE if v % 3 == 0 else Blocks.IRON_ORE
	elif y < -12:
		id = Blocks.IRON_ORE if v % 4 == 0 else Blocks.COPPER_ORE
	elif y < 0:
		id = Blocks.COPPER_ORE if v % 2 == 0 else Blocks.COAL_ORE
	elif y < 15 and v % 3 == 0:
		id = Blocks.DIAMOND_ORE
	elif y < 29 and v % 2 == 0:
		id = Blocks.GOLD_ORE
	elif y < 47:
		id = Blocks.IRON_ORE
	# Copper is the odd one out: it is common rather than rare, and it is what the wire --
	# and so the whole power layer -- is drawn from, so it gets its own band low down
	# instead of competing with the other ores for the same veins.
	#
	# Guarded to y >= 0 so it applies to exactly the veins it always did: the bands above
	# decide the deep world now, and an override with no floor to it was turning a quarter
	# of the veins in the diamond band into copper fifty blocks below anywhere copper was
	# ever meant to be found.
	if v % 4 == 1 and y >= 0 and y < 26:
		id = Blocks.COPPER_ORE
	return id


## Scatters veins through `y_lo .. min(surface - 3, y_cap)`.
##
## `salt` decorrelates the two bands: without it every deep vein would sit directly
## under a shallow one, because both pick their column from the same hash inputs.
func _ore_band(cx: int, cz: int, volume: Volume, hcache: PackedInt32Array,
		EW: int, M: int, y_lo: int, y_cap: int, count: int, salt: int) -> void:
	var ox := cx * CHUNK
	var oz := cz * CHUNK
	for v in count:
		var hx := hash3(ox + v + salt * 91, 1000 + v, oz)
		var lx := hx % CHUNK
		var lz := (hash3(ox, 2000 + v + salt * 77, oz) % CHUNK)
		var h: int = hcache[(lx + M) + (lz + M) * EW]
		var maxy := maxi(y_lo + 2, mini(h - 3, y_cap))
		var y := y_lo + hash3(ox + v, 3000 + v + salt * 53, oz + v) % maxi(1, maxy - y_lo)
		var id := _ore_at(y, v)
		var rad := 1 + hash3(ox, 4000 + v + salt * 37, oz) % 2
		for dy in range(-rad, rad + 1):
			for dx in range(-rad, rad + 1):
				for dz in range(-rad, rad + 1):
					var px := lx + dx
					var pz := lz + dz
					var py := y + dy
					if px < 0 or pz < 0 or px >= CHUNK or pz >= CHUNK:
						continue
					if py < MIN_Y + 2 or py >= MAX_Y:
						continue
					if absi(dx) + absi(dy) + absi(dz) > rad + 1:
						continue
					if volume.at(px, py, pz) == Blocks.STONE:
						volume.put(px, py, pz, id)


func _place_trees(cx: int, cz: int, volume: Volume, hcache: PackedInt32Array,
		bcache: PackedInt32Array, EW: int, M: int) -> void:
	var ox := cx * CHUNK
	var oz := cz * CHUNK
	for ex in EW:
		for ez in EW:
			var ei := ex + ez * EW
			var h: int = hcache[ei]
			var bio: int = bcache[ei]
			var wx := ox + ex - M
			var wz := oz + ez - M
			var t := tree_at(wx, wz, h, bio)
			if t.is_empty():
				continue
			var lx := ex - M
			var lz := ez - M
			var kind: int = t["kind"]
			var th: int = t["trunk"]
			var by: int = t["y"]
			if kind == TREE_CACTUS:
				for i in th:
					_put(volume, lx, by + 1 + i, lz, Blocks.CACTUS, false)
				continue
			var log_id := Blocks.BIRCH_LOG if kind == TREE_BIRCH else Blocks.LOG
			var leaf_id := Blocks.BIRCH_LEAVES if kind == TREE_BIRCH else Blocks.LEAVES
			for i in th:
				_put(volume, lx, by + 1 + i, lz, log_id, false)
			var topy := by + th
			if kind == TREE_BIRCH:
				# a birch is a slimmer tree than an oak: a tall bare trunk with a smaller
				# crown only at the very top, which is what makes a birch wood read as
				# airy next to the low, broad oaks
				for dy in 3:
					var yy := topy - 1 + dy
					var rad := 1 if dy == 0 else (2 if dy == 1 else 1)
					for dx in range(-rad, rad + 1):
						for dz in range(-rad, rad + 1):
							if absi(dx) == rad and absi(dz) == rad and dy != 1:
								continue
							_put(volume, lx + dx, yy, lz + dz, leaf_id, true)
				for d in 4:
					var dx3: int = [-1, 1, 0, 0][d]
					var dz3: int = [0, 0, -1, 1][d]
					_put(volume, lx + dx3, topy + 2, lz + dz3, leaf_id, true)
				_put(volume, lx, topy + 2, lz, leaf_id, true)
				continue
			for dy in 4:
				var yy := topy - 2 + dy
				var rad := 2 if dy <= 1 else 1
				for dx in range(-rad, rad + 1):
					for dz in range(-rad, rad + 1):
						if absi(dx) == rad and absi(dz) == rad:
							if dy <= 1 and hash3(wx + dx, yy, wz + dz) % 100 < 55:
								continue
						_put(volume, lx + dx, yy, lz + dz, leaf_id, true)
			for d in 4:
				var dx2: int = [-1, 1, 0, 0][d]
				var dz2: int = [0, 0, -1, 1][d]
				_put(volume, lx + dx2, topy + 2, lz + dz2, leaf_id, true)
			_put(volume, lx, topy + 2, lz, leaf_id, true)


func _place_plants(cx: int, cz: int, volume: Volume, hcache: PackedInt32Array,
		bcache: PackedInt32Array, EW: int, M: int) -> void:
	var ox := cx * CHUNK
	var oz := cz * CHUNK
	for lx in CHUNK:
		for lz in CHUNK:
			var ei := (lx + M) + (lz + M) * EW
			var h: int = hcache[ei]
			var bio: int = bcache[ei]
			if h >= MAX_Y - 2:
				continue
			if volume.at(lx, h, lz) != Blocks.GRASS:
				continue
			var p := plant_at(ox + lx, oz + lz, bio)
			if p == Blocks.AIR:
				continue
			if volume.at(lx, h + 1, lz) == Blocks.AIR:
				volume.put(lx, h + 1, lz, p)


func _put(volume: Volume, lx: int, y: int, lz: int, id: int, only_air: bool) -> void:
	if lx < 0 or lz < 0 or lx >= CHUNK or lz >= CHUNK or y < MIN_Y or y >= MAX_Y:
		return
	if only_air and volume.at(lx, y, lz) != Blocks.AIR:
		return
	volume.put(lx, y, lz, id)


# ================================================================ villages
## A hash that folds in the world seed, so a village moves when the seed does. `hash3`
## deliberately ignores the seed (tree positions are the same on every world); villages
## should not be, or every world would hide its villages in the same places.
func _vhash(a: int, b: int) -> int:
	return hash3(a + seed_value * 131, 9001, b - seed_value * 37)


## The village in grid cell (gx, gz), or {} if that cell holds none. Deterministic in
## (gx, gz, seed): any chunk, on any thread, gets the same answer, which is what makes
## the per-chunk stamping safe.
func village_at(gx: int, gz: int) -> Dictionary:
	if _vhash(gx, gz) % 1000 >= VILLAGE_CHANCE:
		return {}
	var pad := (VILLAGE_CELL - VILLAGE_RADIUS * 2) / 2
	var ox := gx * VILLAGE_CELL + pad + _vhash(gx * 3 + 1, gz) % (VILLAGE_CELL - pad * 2)
	var oz := gz * VILLAGE_CELL + pad + _vhash(gx, gz * 5 + 2) % (VILLAGE_CELL - pad * 2)
	var h := height_at(ox, oz)
	var bio := biome_from_height(ox, oz, h)
	# no villages in the sea or on a cliff: a terrace needs a reasonably flat, dry start
	if h <= SEA + 2 or h > 56 or bio == B_OCEAN or bio == B_MOUNTAIN:
		return {}
	return {"gx": gx, "gz": gz, "ox": ox, "oz": oz, "plat": h, "bio": bio}


## Every village whose terrace can reach the chunk at (cx, cz). Called once per chunk,
## before the volume is sized, so its top can be raised to fit a village that stands on
## higher ground than anything inside the chunk itself.
func villages_for_chunk(cx: int, cz: int) -> Array:
	var out: Array = []
	var x0 := cx * CHUNK - VILLAGE_RADIUS
	var x1 := cx * CHUNK + CHUNK + VILLAGE_RADIUS
	var z0 := cz * CHUNK - VILLAGE_RADIUS
	var z1 := cz * CHUNK + CHUNK + VILLAGE_RADIUS
	for gx in range(floori(float(x0) / float(VILLAGE_CELL)),
			floori(float(x1) / float(VILLAGE_CELL)) + 1):
		for gz in range(floori(float(z0) / float(VILLAGE_CELL)),
				floori(float(z1) / float(VILLAGE_CELL)) + 1):
			var v := village_at(gx, gz)
			if not v.is_empty():
				out.append(v)
	return out


## The nearest village centre within `max_dist` of (wx, wz), or null. Used by the mob
## spawner to know where villagers belong.
func nearest_village(wx: int, wz: int, max_dist: int):
	var best = null
	var best_d := max_dist * max_dist
	for gx in range(floori(float(wx - max_dist) / float(VILLAGE_CELL)),
			floori(float(wx + max_dist) / float(VILLAGE_CELL)) + 1):
		for gz in range(floori(float(wz - max_dist) / float(VILLAGE_CELL)),
				floori(float(wz + max_dist) / float(VILLAGE_CELL)) + 1):
			var v := village_at(gx, gz)
			if v.is_empty():
				continue
			var dx: int = int(v["ox"]) - wx
			var dz: int = int(v["oz"]) - wz
			var d := dx * dx + dz * dz
			if d <= best_d:
				best_d = d
				best = v
	return best


## Stamps every village that touches this chunk. Runs *after* the trees and plants so the
## terrace simply overwrites whatever grew where the village now stands.
func _place_village(cx: int, cz: int, volume: Volume, villages: Array) -> void:
	var chx := cx * CHUNK
	var chz := cz * CHUNK
	for v in villages:
		var ox: int = v["ox"]
		var oz: int = v["oz"]
		var plat: int = v["plat"]
		var r := VILLAGE_RADIUS
		# ---- terrace: level the ground in a disc around the centre
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if dx * dx + dz * dz > r * r:
					continue
				var lx := ox + dx - chx
				var lz := oz + dz - chz
				if lx < 0 or lz < 0 or lx >= CHUNK or lz >= CHUNK:
					continue
				var h := height_at(ox + dx, oz + dz)
				if h <= SEA + 1:
					continue
				# clear everything above the terrace, then fill any hollow up to it
				for y in range(plat + 1, mini(plat + VILLAGE_CLEAR, MAX_Y)):
					if volume.at(lx, y, lz) != Blocks.AIR:
						volume.put(lx, y, lz, Blocks.AIR)
				for y in range(h + 1, plat):
					volume.put(lx, y, lz, Blocks.DIRT)
				volume.put(lx, plat, lz, _village_ground(v["bio"], dx, dz))
		# ---- the well and its lamp posts at the centre
		_place_well(volume, chx, chz, ox, oz, plat)
		# ---- houses, doors facing the centre
		var homes := [Vector2i(-13, -13), Vector2i(13, -13), Vector2i(-13, 13),
			Vector2i(13, 13), Vector2i(-3, 17), Vector2i(-3, -17)]
		for i in homes.size():
			var off: Vector2i = homes[i]
			var hx := ox + off.x
			var hz := oz + off.y
			var door := Vector2i.ZERO
			if absi(off.x) >= absi(off.y):
				door = Vector2i(-signi(off.x), 0)
			else:
				door = Vector2i(0, -signi(off.y))
			_house(volume, chx, chz, hx, hz, plat, door)
		# ---- a pair of fenced wheat fields either side of the plaza
		_place_farm(volume, chx, chz, ox - 13, oz - 4, plat, 9, 9)
		_place_farm(volume, chx, chz, ox + 5, oz - 4, plat, 9, 9)


## The surface of a village column: a gravel path on the two axes, grass (or sand in a
## desert) everywhere else.
func _village_ground(bio: int, dx: int, dz: int) -> int:
	if absi(dx) <= 1 or absi(dz) <= 1:
		return Blocks.GRAVEL
	if bio == B_DESERT:
		return Blocks.SAND
	return Blocks.GRASS


## The central well: a stone-brick paving with a water shaft and four lamp posts, which
## is both the village's landmark and its meeting place.
func _place_well(volume: Volume, chx: int, chz: int, ox: int, oz: int, plat: int) -> void:
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			if absi(dx) == 3 or absi(dz) == 3:
				_put(volume, ox + dx - chx, plat, oz + dz - chz, Blocks.STONE_BRICK, false)
	# the shaft, so the well has water in it rather than a stone plug
	for dy in range(4):
		_put(volume, ox - chx, plat - dy, oz - chz, Blocks.WATER, false)
	for d in [Vector2i(-2, -2), Vector2i(2, -2), Vector2i(-2, 2), Vector2i(2, 2)]:
		_put(volume, ox + d.x - chx, plat, oz + d.y - chz, Blocks.STONE_BRICK, false)
	# a lamp post on each corner of the paving: a fence with a glowstone on top
	for d2 in [Vector2i(-3, -3), Vector2i(3, -3), Vector2i(-3, 3), Vector2i(3, 3)]:
		_put(volume, ox + d2.x - chx, plat + 1, oz + d2.y - chz, Blocks.FENCE, false)
		_put(volume, ox + d2.x - chx, plat + 2, oz + d2.y - chz, Blocks.GLOWSTONE, false)


## A 7x7 cottage: cobble floor, log corners, plank walls with a window on each side, a
## two-high doorway on `door`, a flat slab roof, and a torch, bed, table and chest inside.
func _house(volume: Volume, chx: int, chz: int, hx: int, hz: int, plat: int,
		door: Vector2i) -> void:
	var y0 := plat + 1
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			_put(volume, hx + dx - chx, plat, hz + dz - chz, Blocks.COBBLESTONE, false)
			if absi(dx) != 3 and absi(dz) != 3:
				continue
			for dy in 3:
				var corner := absi(dx) == 3 and absi(dz) == 3
				var id := Blocks.LOG if corner else Blocks.PLANKS
				# a doorway punched over the wall, and a window at head height elsewhere
				var is_door := Vector2i(dx, dz) == door * 3
				if is_door and dy < 2:
					id = Blocks.AIR
				elif not is_door and dy == 1 and (absi(dx) == 0 or absi(dz) == 0) \
						and absi(dx) != absi(dz):
					id = Blocks.GLASS
				_put(volume, hx + dx - chx, y0 + dy, hz + dz - chz, id, false)
	# the roof, overhanging one block past the walls
	for dx in range(-4, 5):
		for dz in range(-4, 5):
			_put(volume, hx + dx - chx, y0 + 3, hz + dz - chz, Blocks.SLAB_WOOD, false)
	# furniture: a torch on the floor, a bed in one corner, a table and a chest opposite
	_put(volume, hx + 1 - chx, y0, hz - 2 - chz, Blocks.TORCH, false)
	_put(volume, hx - 2 - chx, y0, hz - 2 - chz, Blocks.BED, false)
	# the far half, so the village bed is two cells with a pillow at the head. The default
	# facing points +z, which is the axis the head is laid out along here.
	_put(volume, hx - 2 - chx, y0, hz - 1 - chz, Blocks.BED_HEAD, false)
	_put(volume, hx + 2 - chx, y0, hz + 2 - chz, Blocks.CRAFTING_TABLE, false)
	_put(volume, hx - 2 - chx, y0, hz + 2 - chz, Blocks.CHEST, false)


## A fenced field: rows of farmland with a water channel down the middle and wheat at
## mixed stages, so a village feeds itself rather than just decorating the view.
func _place_farm(volume: Volume, chx: int, chz: int, fx: int, fz: int, plat: int,
		w: int, d: int) -> void:
	for dx in range(w):
		for dz in range(d):
			if dx == w / 2:
				_put(volume, fx + dx - chx, plat, fz + dz - chz, Blocks.WATER, false)
				continue
			_put(volume, fx + dx - chx, plat, fz + dz - chz, Blocks.FARMLAND, false)
			var stage := 1 + hash3(fx + dx, 61, fz + dz) % 3
			_put(volume, fx + dx - chx, plat + 1, fz + dz - chz, Blocks.WHEAT_0 + stage, false)
	for dx in range(-1, w + 1):
		_put(volume, fx + dx - chx, plat + 1, fz - 1 - chz, Blocks.FENCE, false)
		_put(volume, fx + dx - chx, plat + 1, fz + d - chz, Blocks.FENCE, false)
	for dz2 in range(d):
		_put(volume, fx - 1 - chx, plat + 1, fz + dz2 - chz, Blocks.FENCE, false)
		_put(volume, fx + w - chx, plat + 1, fz + dz2 - chz, Blocks.FENCE, false)


## Carving rule: a thin shell around the zero-crossing of the noise gives winding
## tunnels rather than blobs.
const CAVE_TUNNEL := 0.026
const CAVE_CAVERN := 0.016

func carve_here(x: int, y: int, z: int) -> bool:
	var a := _n_cave.get_noise_3d(float(x), float(y), float(z))
	if absf(a) < CAVE_TUNNEL:
		return true
	var b := _n_cave2.get_noise_3d(float(x), float(y), float(z))
	return absf(b) < CAVE_CAVERN


## Diagnostic: how much of the underground the current rule would carve.
func cave_stats() -> Dictionary:
	var n := 0
	var carved := 0
	for x in range(0, 64, 4):
		for y in range(CAVE_FLOOR, CAVE_CEIL, 3):
			for z in range(0, 64, 4):
				n += 1
				if carve_here(x, y, z):
					carved += 1
	return {"n": n, "carved": carved, "carve_frac": float(carved) / float(n)}


func biome_name(b: int) -> String:
	match b:
		B_OCEAN:
			return "Ocean"
		B_BEACH:
			return "Beach"
		B_PLAINS:
			return "Plains"
		B_FOREST:
			return "Forest"
		B_BIRCH_FOREST:
			return "Birch Forest"
		B_DESERT:
			return "Desert"
		B_SNOWY:
			return "Snowy Tundra"
		B_MOUNTAIN:
			return "Mountains"
	return "Unknown"


# ================================================================ spawn
## Finds a comfortable place to spawn near the origin (dry, reasonably flat land).
func find_spawn() -> Vector3:
	var best := Vector3.ZERO
	var best_score := -1e9
	for radius in range(0, 90, 2):
		for a in range(0, maxi(1, radius * 6)):
			var ang := TAU * float(a) / float(maxi(1, radius * 6))
			var wx := int(cos(ang) * float(radius))
			var wz := int(sin(ang) * float(radius))
			var h := height_at(wx, wz)
			if h <= SEA + 1 or h > 58:
				continue
			var bio := biome_at(wx, wz)
			if bio == B_OCEAN:
				continue
			# never spawn inside a tree or under a canopy: a trunk within 4 columns can
			# still hang leaves directly over the spawn column
			var blocked := false
			for dx in range(-4, 5):
				for dz in range(-4, 5):
					var nh0 := height_at(wx + dx, wz + dz)
					var nb0 := biome_at(wx + dx, wz + dz)
					if not tree_at(wx + dx, wz + dz, nh0, nb0).is_empty():
						blocked = true
			if blocked:
				continue
			# prefer flat, dry ground with dry ground all around
			var flat := 0
			var dry := 0
			for dx in range(-3, 4):
				for dz in range(-3, 4):
					var nh := height_at(wx + dx, wz + dz)
					if nh > SEA + 1:
						dry += 1
					flat -= absi(nh - h)
			var score := float(dry) * 3.0 + float(flat) * 0.6 - float(radius) * 0.35
			if score > best_score:
				best_score = score
				best = Vector3(float(wx) + 0.5, float(h) + 1.2, float(wz) + 0.5)
			if best_score > 120.0:
				return best
		if best_score > 120.0:
			break
	if best_score > -1e8:
		return best
	return Vector3(0.5, float(SEA + 8), 0.5)