extends Node3D
## Chunk streaming, mesh building (with baked ambient occlusion + heightmap sky
## light), block edits, voxel raycasting and persistence.
##
## Meshing runs on worker threads. A worker only ever touches the immutable
## payload handed to it, never the live `chunks` dictionary.

const CHUNK := 16
const SEC := VoxelTerrain.SEC
const MIN_Y := VoxelTerrain.MIN_Y
const MAX_Y := VoxelTerrain.MAX_Y

## Vertex buffer for one material group.
class Buf:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var c := PackedColorArray()
	var idx := PackedInt32Array()

	func face(f: int, base: Vector3, r: Rect2, c0: Color, c1: Color, c2: Color, c3: Color) -> void:
		var fv: Array = Blocks.FACE_VERTS[f]
		var fu: Array = Blocks.FACE_UV[f]
		var nrm := Vector3(Blocks.FACE_DIRS[f])
		var b := v.size()
		for i in 4:
			v.append(fv[i] + base)
			n.append(nrm)
			var t: Vector2 = fu[i]
			uv.append(r.position + Vector2(t.x * r.size.x, t.y * r.size.y))
			var col := c0
			if i == 1:
				col = c1
			elif i == 2:
				col = c2
			elif i == 3:
				col = c3
			c.append(col)
		# Godot's front face winding is clockwise seen from outside
		idx.append_array([b, b + 2, b + 1, b, b + 3, b + 2])

	func cross(base: Vector3, r: Rect2, col: Color) -> void:
		var quads := [
			[Vector3(0, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 0)],
			[Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 0)],
		]
		var quv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
		for q in quads:
			var b := v.size()
			for i in 4:
				var p: Vector3 = q[i]
				v.append(p + base)
				n.append(Vector3(0, 1, 0))
				var t: Vector2 = quv[i]
				uv.append(r.position + Vector2(t.x * r.size.x, t.y * r.size.y))
				c.append(col)
			idx.append_array([b, b + 2, b + 1, b, b + 3, b + 2])

	func empty() -> bool:
		return idx.is_empty()

	## A horizontal plate lying just above the floor of the cell: wire, switches,
	## pressure plates and relays. One quad only. It used to carry a second quad at
	## y = 0 as well, which is exactly where the top face of the block underneath
	## sits, so the two coplanar faces z-fought and the wire looked like it had been
	## laid down twice. Nothing is lost by dropping it: the material is
	## cull-disabled, so this one quad is visible from below as well.
	func plate(base: Vector3, r: Rect2, col: Color) -> void:
		var top := 0.08
		var q := [Vector3(0, top, 0), Vector3(1, top, 0), Vector3(1, top, 1), Vector3(0, top, 1)]
		var quv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
		var b := v.size()
		for i in 4:
			var p: Vector3 = q[i]
			v.append(p + base)
			n.append(Vector3(0, 1, 0))
			var t: Vector2 = quv[i]
			uv.append(r.position + Vector2(t.x * r.size.x, t.y * r.size.y))
			c.append(col)
		idx.append_array([b, b + 2, b + 1, b, b + 3, b + 2])


	## A thin slab with real thickness: a door leaf or a ladder, like Minecraft's 3/16-block
	## door. `axis` picks which horizontal direction is the thin one (0 = X, 1 = Z), `pos`
	## is where the slab sits on that axis, and `thickness` is how thick it is. All six
	## faces are emitted, so it reads as a solid plank from every angle instead of a sheet.
	func panel(base: Vector3, r: Rect2, col: Color, axis: int, pos: float, thickness: float) -> void:
		# A thin slab with real thickness: a door leaf or a ladder, like Minecraft's
		# 3/16-block door. The six faces are built from the same FACE_VERTS templates the
		# cube and box paths use, with the two planes of the thin axis substituted in.
		#
		# That matters. These were hand-written quads once, and three of the six ran
		# *against* Godot's winding. A door hid it -- its material is cull-disabled -- but an
		# open trapdoor shares the opaque buffer, which culls back faces, so those three
		# faces were thrown away and you looked straight through the board from the side.
		var h := thickness * 0.5
		var lo := pos - h
		var hi := pos + h
		for f in 6:
			var nrm := Vector3(Blocks.FACE_DIRS[f])
			var vb := v.size()
			for i in 4:
				var t: Vector3 = Blocks.FACE_VERTS[f][i]
				var p := t
				if axis == 0:
					p.x = lo if t.x < 0.5 else hi
				elif axis == 1:
					p.z = lo if t.z < 0.5 else hi
				else:
					p.y = lo if t.y < 0.5 else hi
				v.append(p + base)
				n.append(nrm)
				var u: Vector2 = Blocks.FACE_UV[f][i]
				uv.append(r.position + Vector2(u.x * r.size.x, u.y * r.size.y))
				c.append(col)
			idx.append_array([vb, vb + 2, vb + 1, vb, vb + 3, vb + 2])


	## An axis-aligned box between two cell-local corners, all six faces emitted. This is
	## what the non-cube shapes are built from: a slab is one box, a stair is two. `r` is
	## the side tile (a half-height slab passes the lower half of the tile so the grain
	## is not squashed), and `r_cap` is the tile for the top and bottom faces, which show
	## the full texture. Face shading matches the cube path, so a half block sits in the
	## same light as the blocks around it.
	func box(a: Vector3, b: Vector3, r: Rect2, col: Color, r_cap: Rect2 = Rect2()) -> void:
		for f in 6:
			var rr := r
			if (f == 2 or f == 3) and r_cap.size != Vector2.ZERO:
				rr = r_cap
			var nrm := Vector3(Blocks.FACE_DIRS[f])
			var sh: float = Blocks.FACE_SHADE[f]
			var fc := Color(col.r * sh, col.g * sh, col.b * sh, col.a)
			var base := v.size()
			for i in 4:
				var t: Vector3 = Blocks.FACE_VERTS[f][i]
				v.append(Vector3(a.x + t.x * (b.x - a.x), a.y + t.y * (b.y - a.y),
					a.z + t.z * (b.z - a.z)))
				n.append(nrm)
				var u: Vector2 = Blocks.FACE_UV[f][i]
				uv.append(rr.position + Vector2(u.x * rr.size.x, u.y * rr.size.y))
				c.append(fc)
			idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])


	## One fluid cell: a box whose top sits at y = h rather than y = 1, so a flowing tongue
	## is visibly shallower than a source. `mask` selects the faces to draw (bit 0 +X,
	## 1 -X, 2 top, 3 bottom, 4 +Z, 5 -Z, matching `Blocks.FACE_*`). Side faces crop their
	## tile vertically to the top `h` of it, so a shallow cell is not a squashed picture of
	## a full one, and the winding stays the same as `face()`.
	func fluid(base: Vector3, r: Rect2, tint: Color, h: float, mask: int,
			use_shade: bool = true) -> void:
		for f in 6:
			if (mask & (1 << f)) == 0:
				continue
			var fv: Array = Blocks.FACE_VERTS[f]
			var fu: Array = Blocks.FACE_UV[f]
			var nrm := Vector3(Blocks.FACE_DIRS[f])
			# the face shade the solid path applies, so a water surface is lit like the
			# ground it sits on. Skipped for an emissive fluid: lava is its own light and
			# must not have its sides darkened.
			var shade_col := tint
			if use_shade:
				var sh: float = Blocks.FACE_SHADE[f]
				shade_col = Color(tint.r * sh, tint.g * sh, tint.b * sh, tint.a)
			var b := v.size()
			for i in 4:
				var p: Vector3 = fv[i]
				var t: Vector2 = fu[i]
				if f == 2:
					p.y = h
				elif f != 3:
					p.y *= h
					t.y *= h
				v.append(p + base)
				n.append(nrm)
				uv.append(r.position + Vector2(t.x * r.size.x, t.y * r.size.y))
				c.append(shade_col)
			idx.append_array([b, b + 2, b + 1, b, b + 3, b + 2])


## A fresh vertex buffer. Exposed so tests can drive `_attach_mesh` directly.
func new_buf() -> Buf:
	return Buf.new()


var seed_value := 12345
var terrain: VoxelTerrain
var render_distance := 6
var ao_enabled := true
var ao_strength := 0.34

## The circuit solver. Owns all power-layer state; world.gd only tells it when a
## circuit block appears, changes or goes away.
var circuit
## pos -> tile id, for blocks whose *look* changes without their id changing: a
## switch that has been flipped, a lamp that has lit up, a wire that has gone live.
var tile_override: Dictionary = {}
## pos -> Vector3i, which way a thin panel (a door leaf, a ladder) faces. Written when
## the panel is placed, from where the placer was looking, so the mesher can thin it
## along the right axis instead of drawing a cube.
var facing_override: Dictionary = {}
## pos -> bool, the lit state of lamps and piston arms, read when placing lights.
var circuit_lit: Dictionary = {}

## pos -> the text written on a sign. A sign is a block like any other, but the words on
## it are state no block id can carry, so they get their own dictionary and their own
## small save file, the way facings and fluid levels do. The floating label that shows
## the text is a Node3D kept in step with the streaming by `sync_sign_labels`.
var sign_text: Dictionary = {}
var _sign_labels: Dictionary = {}    # Vector3i -> Label3D

## The fluid simulation's state: pos -> level (1..7) for every cell that is *flowing*
## rather than a source. A cell holding WATER or LAVA that is absent from here is a
## source (level 8) and never drains -- which is what keeps the generated oceans free of
## any per-cell record at all, and what makes a placed bucket a real source.
##
## Cells whose level might change are queued in `_fluid_queue`; the tick only ever looks
## at those, so a still ocean costs nothing however big it is.
var fluid: Dictionary = {}
var _fluid_queue: Dictionary = {}
var _fluid_timer := 0.0
## How far a fluid spreads horizontally from its source. Water reaches seven cells (MC's
## number); lava only three, so a lava lake stays a lake instead of flooding the cave.
const FLUID_SPREAD := 7
const LAVA_SPREAD := 3

## One chunk column: `sections` holds only the 16-tall slices that contain something,
## so the sky above the terrain and the stone deep underground cost nothing until
## something is actually put there. `hmap` is the per-column occluder top that the sky
## light and the spawner read.
var chunks: Dictionary = {}          # Vector2i -> {sections, hmap, dirty, srev, nodes, meshed}
var edits: Dictionary = {}           # Vector3i -> id
var edits_by_chunk: Dictionary = {}  # Vector2i -> {Vector3i: id}
var torches: Dictionary = {}         # Vector3i -> block id

## Block tables, held once instead of read through the `Blocks` autoload.
##
## The mesher is the hottest code in the game -- a section is 4096 cells and up to six
## faces each, and every face asks for the occluder, a tile id and an AO mask. `Blocks` is
## an autoload, so `Blocks.tile_side[id]` is a named-global lookup that hands back a
## *copy* of the PackedInt32Array, and copying it bumps a reference count that every
## worker thread shares. Eight threads doing that fight over one cache line and mesh the
## world *slower* than one thread does; measured, eight workers got 0.45x the throughput
## of one. Read once into plain members, the same loop is three times faster on a single
## thread and scales to five times across eight.
var _t_occluder: PackedByteArray = Blocks.occluder
var _t_kind: PackedByteArray = Blocks.kind
var _t_emission: PackedByteArray = Blocks.emission
var _t_tile_top: PackedInt32Array = Blocks.tile_top
var _t_tile_bottom: PackedInt32Array = Blocks.tile_bottom
var _t_tile_side: PackedInt32Array = Blocks.tile_side
var _t_tile_uv: Array = Blocks.tile_uv
var _t_face_ao: Array = Blocks.FACE_AO
var _t_face_dirs: Array = Blocks.FACE_DIRS
var _t_face_shade: Array = Blocks.FACE_SHADE
var _t_air := Blocks.AIR
var _t_bedrock := Blocks.BEDROCK
var _t_lava := Blocks.LAVA
var _t_liquid: PackedByteArray = Blocks.liquid

signal chunk_ready(c: Vector2i)

## How many section jobs may be in flight at once. A section job is 1/16th of the
## meshing work a whole-column job used to be, so the batch has to be one per worker
## thread rather than the old fixed six -- otherwise fifteen idle threads wait on one.
var max_jobs := 6

var _center := Vector2i(99999, 99999)
var _jobs: Dictionary = {}           # Vector2i -> task id
var _results: Array = []
var _mutex := Mutex.new()
var _gen_pending := false
var _gen_list: Array = []            # [[dist2, Vector2i]], nearest first
var _gen_index := 0
var _loading := true

## Chunk *columns* being built by the generator on the pool, and the columns waiting to
## be turned into chunks. Generating one column is ~110ms of GDScript -- twenty times
## the whole frame budget -- so it cannot run on the main thread: doing so made the game
## hitch for a fifth of a second on every frame it happened to generate one. A worker
## only produces the raw noise bytes. The edit replay and the circuit registration stay
## here, because they touch live dictionaries a worker must never see.
var max_gen_jobs := 4
var _gen_jobs: Dictionary = {}       # Vector2i -> task id
var _gen_results: Array = []
## One generator per in-flight job. Shared noise objects would be a data race, so each
## job gets its own; they are recycled rather than rebuilt on every chunk.
var _gen_pool: Array = []

var _lights: Array[OmniLight3D] = []
var _light_timer := 0.0

## Per-frame cost breakdown, only collected when the game is started with `--perf`.
## Off by default so a normal frame pays nothing but one `if` per phase.
var perf_on := false
var perf_phase: Dictionary = {}     # name -> [total us, max us, calls]
var perf_last: Dictionary = {}      # the most recent call's phase costs, per frame
## Generation runs off-thread, so its cost is counted there and reported here.
var perf_gen_us := 0
var perf_gen_max := 0
var perf_gen_chunks := 0


func _perf(name: String, us: int) -> void:
	if not perf_on:
		return
	var e = perf_phase.get(name)
	if e == null:
		e = [0, 0, 0]
		perf_phase[name] = e
	e[0] = int(e[0]) + us
	if us > int(e[1]):
		e[1] = us
	e[2] = int(e[2]) + 1


func perf_report() -> void:
	print("=== streaming perf (us) ===")
	for name in perf_phase:
		var e: Array = perf_phase[name]
		print("  %-8s total %8d  max %7d  calls %d  avg %.0f" % [
			name, int(e[0]), int(e[1]), int(e[2]),
			float(e[0]) / float(maxi(1, int(e[2])))])
	print("  %-8s total %8d  max %7d  chunks %d  avg %.0f   (worker threads)" % [
		"genfill", perf_gen_us, perf_gen_max, perf_gen_chunks,
		float(perf_gen_us) / float(maxi(1, perf_gen_chunks))])


## Build the circuit solver on demand. `setup()` calls this, but so does the test
## harness, which drives the world straight from the title screen without ever
## starting a real game.
func ensure_circuit() -> void:
	if circuit != null:
		return
	circuit = load("res://scripts/circuit.gd").new()
	circuit.name = "Circuit"
	add_child(circuit)
	circuit.setup(self)


func setup(s: int, distance: int) -> void:
	seed_value = s
	perf_on = OS.get_cmdline_user_args().has("--perf")
	perf_phase.clear()
	terrain = VoxelTerrain.new(s)
	perf_gen_us = 0
	perf_gen_max = 0
	perf_gen_chunks = 0
	render_distance = clampi(distance, Settings.MIN_RD, Settings.max_render_distance())
	# Deliberately *below* the core count. This pool scales negatively: every in-flight
	# job holds its own noise objects and vertex buffers, and once enough of them run at
	# once the allocator and the memory bus thrash badly enough that the pool does less
	# work per second the more threads it is given. Measured on a 24-thread machine
	# streaming a render distance of 4: 31 jobs took 21.1s, 12 took 8.1s, 9 took 6.3s,
	# 6 took 7.3s. The generators' own fill_chunk is ~13ms of work, yet it wall-clocked at
	# 364ms under 31 jobs and 32ms under 9 -- the threads were not the limit, contention
	# was. Nine jobs is the sweet spot, so the caps are a contention limit, not a
	# parallelism one, and they do not simply follow the core count.
	max_jobs = clampi(OS.get_processor_count() / 4, 4, 8)
	max_gen_jobs = clampi(OS.get_processor_count() / 8, 2, 3)
	ensure_circuit()
	# Guarded rather than unconditional: `setup` runs again on every world load, and
	# without this the light pool grew by 14 nodes per load and the old ones were
	# never freed.
	#
	# 28 rather than 14: a torch only lights what the pool can reach, so with 14 the
	# player could stand in a lit room and watch the far half of it go dark.
	if _lights.is_empty():
		for i in 28:
			var l := OmniLight3D.new()
			l.light_energy = 3.2
			l.light_color = Color(1.0, 0.80, 0.52)
			l.omni_range = 11.0
			l.omni_attenuation = 0.85
			l.shadow_enabled = false
			l.visible = false
			add_child(l)
			_lights.append(l)


func reset() -> void:
	for j in _jobs.values():
		WorkerThreadPool.wait_for_task_completion(j)
	_jobs.clear()
	for j in _gen_jobs.values():
		WorkerThreadPool.wait_for_task_completion(j)
	_gen_jobs.clear()
	_mutex.lock()
	_results.clear()
	_gen_results.clear()
	_mutex.unlock()
	_gen_pool.clear()
	for c in chunks.keys():
		_free_nodes(chunks[c])
	chunks.clear()
	edits.clear()
	edits_by_chunk.clear()
	torches.clear()
	tile_override.clear()
	facing_override.clear()
	circuit_lit.clear()
	fluid.clear()
	_fluid_queue.clear()
	_fluid_timer = 0.0
	sign_text.clear()
	for lb in _sign_labels.values():
		if is_instance_valid(lb):
			lb.queue_free()
	_sign_labels.clear()
	for l in _lights:
		if is_instance_valid(l):
			l.queue_free()
	_lights.clear()
	if circuit != null:
		circuit.clear()
	_center = Vector2i(99999, 99999)
	_gen_pending = false
	_gen_list = []
	_gen_index = 0
	_loading = true


func _exit_tree() -> void:
	# never let a worker outlive this node
	for d in [_jobs, _gen_jobs]:
		if not d.is_empty():
			for j in d.values():
				WorkerThreadPool.wait_for_task_completion(j)
			d.clear()


## Frees every mesh node this chunk owns. Per section now, so a chunk holds a handful
## of small nodes rather than one column-sized pair.
func _free_nodes(ch: Dictionary) -> void:
	if not ch.has("nodes"):
		return
	for sec in ch["nodes"]:
		var pair: Dictionary = ch["nodes"][sec]
		for key in ["solid", "trans", "lava"]:
			var n = pair.get(key)
			if n != null and is_instance_valid(n):
				n.queue_free()
	ch["nodes"].clear()


# ================================================================ block access
## A section that is not there is air. That is what makes the sky free, and it is why
## every read has to go through here rather than index the storage directly.
func _sec_get(ch: Dictionary, sec: int, idx: int) -> int:
	var arr = ch["sections"].get(sec)
	if arr == null:
		return Blocks.AIR
	return arr[idx]


## The section's array, created full of air if this is the first block to land in it.
## Writing above the terrain and replaying a save both land on sections that the
## generator never produced.
func _sec_ensure(ch: Dictionary, sec: int) -> PackedByteArray:
	var arr = ch["sections"].get(sec)
	if arr != null:
		return arr
	var fresh := PackedByteArray()
	fresh.resize(CHUNK * CHUNK * SEC)
	fresh.fill(Blocks.AIR)
	ch["sections"][sec] = fresh
	return fresh


func get_block(x: int, y: int, z: int) -> int:
	if y < MIN_Y or y >= MAX_Y:
		return Blocks.AIR
	var c := Vector2i(x >> 4, z >> 4)
	if not chunks.has(c):
		return Blocks.AIR
	return _sec_get(chunks[c], y >> 4, (x & 15) + (z & 15) * CHUNK \
		+ (y & 15) * CHUNK * CHUNK)


func is_solid(x: int, y: int, z: int) -> bool:
	return Blocks.solid[get_block(x, y, z)] == 1


## The vertical span a block occupies inside its own cell, as (bottom, top) in 0..1, or
## zero when the cell does not block the player. Full cubes are (0, 1); a slab is half a
## cell, a carpet a sixteenth. Which half a slab sits in, and which way a trapdoor is
## hinged, come from the per-position facing record, so this cannot be a plain table.
##
## Collision is what makes stairs usable: with a half-height span a run of stairs is
## climbed by the ordinary walking step-up, exactly as it is in Minecraft.
func collide_span(x: int, y: int, z: int) -> Vector2:
	var id := get_block(x, y, z)
	if id == Blocks.AIR or Blocks.solid[id] != 1:
		return Vector2.ZERO
	match Blocks.kind[id]:
		Blocks.K_SLAB:
			var f: Vector3i = facing_override.get(Vector3i(x, y, z), Vector3i(0, 0, 1))
			return Vector2(0.5, 1.0) if f.y > 0 else Vector2(0.0, 0.5)
		Blocks.K_STAIRS:
			return Vector2(0.0, 0.5)
		Blocks.K_TRAPDOOR:
			var f2: Vector3i = facing_override.get(Vector3i(x, y, z), Vector3i(0, 0, 1))
			return Vector2(0.8125, 1.0) if f2.y > 0 else Vector2(0.0, 0.1875)
		Blocks.K_BED:
			return Vector2(0.0, 0.5625)
	return Vector2(0.0, 1.0)


func is_liquid(x: int, y: int, z: int) -> bool:
	return Blocks.liquid[get_block(x, y, z)] == 1


## Lava is a liquid too, so `is_liquid` alone cannot tell the two apart -- and the player
## swims in one of them and burns in the other.
func is_lava(x: int, y: int, z: int) -> bool:
	return get_block(x, y, z) == Blocks.LAVA


## A fluid cell is a *source* when nothing has recorded a level for it: it never drains.
## A bucket places a source, and worldgen fills the oceans with them.
func is_fluid_source(pos: Vector3i) -> bool:
	return not fluid.has(pos)


# ================================================================ fluids
## The fluid simulation. It is a pull-based cellular automaton rather than a push one:
## each queued cell recomputes its own level from its neighbours, so it does not matter
## in what order the queue is drained and a value can never be written twice in one tick.
##
## A source is level 8 and never changes; everything else is `min(limit, best support)`,
## where horizontal support is `neighbour - 1` (so a run decays one per block, exactly
## like the power wires) and vertical support is the level of the cell above (a falling
## column keeps its strength). A cell whose support reaches zero is gone -- which is what
## makes a spill dry up when the bucket that started it is taken away.
##
## Nothing here scans the world: only cells in `_fluid_queue` are ever looked at, so a
## still ocean costs nothing no matter how large it is.
const _FLUID_DIRS := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]


## Wakes a cell and its six neighbours. Called from every edit, and by the tick itself.
func wake_fluid(pos: Vector3i) -> void:
	_fluid_queue[pos] = true
	for d in _NEIGHBOURS6:
		_fluid_queue[pos + d] = true


func _mark_dirty_pos(pos: Vector3i) -> void:
	var c := Vector2i(pos.x >> 4, pos.z >> 4)
	if chunks.has(c):
		_mark_dirty(c, pos.y >> 4)


## The sim's own write. `silent` keeps it out of the circuit solver, which must not be
## re-entered from a write the solver did not make.
func _set_fluid(pos: Vector3i, id: int) -> void:
	set_block(pos.x, pos.y, pos.z, id, true, true)


func _fluid_limit(is_lava: bool) -> int:
	return LAVA_SPREAD if is_lava else FLUID_SPREAD


## One fluid tick on its own slow clock, over a bounded slice of the queue. A big spill
## therefore spreads over several ticks instead of stalling a frame.
func step_fluids(delta: float) -> void:
	_fluid_timer -= delta
	if _fluid_timer > 0.0 or _fluid_queue.is_empty():
		return
	_fluid_timer = 0.2
	var budget := 512
	var todo: Array = _fluid_queue.keys()
	_fluid_queue.clear()
	for pos in todo:
		if budget <= 0:
			_fluid_queue[pos] = true
			continue
		budget -= 1
		_fluid_tick_cell(pos)


func _fluid_tick_cell(pos: Vector3i) -> void:
	var id := get_block(pos.x, pos.y, pos.z)
	if id == Blocks.AIR or Blocks.kind[id] == Blocks.K_CROSS:
		_fluid_spread_into(pos)
		return
	if _t_liquid[id] != 1:
		return
	var is_lava := id == _t_lava

	# water meeting lava sets it: a source freezes to obsidian, a flowing tongue to plain
	# cobblestone. Checked before the source early-out, because a source is exactly the
	# case that must still react.
	if is_lava and _touches_water(pos):
		_set_fluid(pos, Blocks.OBSIDIAN if is_fluid_source(pos) else Blocks.COBBLESTONE)
		fluid.erase(pos)
		wake_fluid(pos)
		return

	if is_fluid_source(pos):
		wake_fluid(pos)
		return

	var lvl := int(fluid.get(pos, 1))
	var support := _fluid_support(pos, id, is_lava)
	if support <= 0:
		fluid.erase(pos)
		_set_fluid(pos, Blocks.AIR)
		wake_fluid(pos)
		return
	if support != lvl:
		fluid[pos] = support
		_mark_dirty_pos(pos)
	wake_fluid(pos)


## How strong a flowing cell's supply is. Vertical support carries the level of the cell
## above (a waterfall keeps its strength all the way down); horizontal support is the
## best neighbour's level minus one. Capped at the fluid's reach, which is what stops a
## falling column from turning into an endless source.
func _fluid_support(pos: Vector3i, id: int, is_lava: bool) -> int:
	var limit := _fluid_limit(is_lava)
	var above := pos + Vector3i(0, 1, 0)
	if get_block(above.x, above.y, above.z) == id:
		return mini(limit, int(fluid.get(above, 8)))
	var best := 0
	for d in _FLUID_DIRS:
		var n: Vector3i = pos + d
		if get_block(n.x, n.y, n.z) == id:
			best = maxi(best, int(fluid.get(n, 8)) - 1)
	return mini(limit, best)


## An empty (or plant-filled) cell that a neighbour may be about to flood.
func _fluid_spread_into(pos: Vector3i) -> void:
	var lvl := _fluid_fill_level(pos, Blocks.WATER, false)
	var id := Blocks.WATER
	var lava_lvl := _fluid_fill_level(pos, Blocks.LAVA, true)
	if lava_lvl > lvl:
		lvl = lava_lvl
		id = Blocks.LAVA
	if lvl <= 0:
		return
	# the level has to be recorded before the block lands, or the write would be taken
	# for a fresh source and the tongue would never dry
	fluid[pos] = lvl
	_set_fluid(pos, id)


func _fluid_fill_level(pos: Vector3i, id: int, is_lava: bool) -> int:
	var limit := _fluid_limit(is_lava)
	var above := pos + Vector3i(0, 1, 0)
	if get_block(above.x, above.y, above.z) == id:
		return mini(limit, int(fluid.get(above, 8)))
	var best := 0
	for d in _FLUID_DIRS:
		var n: Vector3i = pos + d
		if get_block(n.x, n.y, n.z) == id:
			best = maxi(best, int(fluid.get(n, 8)) - 1)
	return mini(limit, best)


func _touches_water(pos: Vector3i) -> bool:
	for d in _NEIGHBOURS6:
		var n: Vector3i = pos + d
		if get_block(n.x, n.y, n.z) == Blocks.WATER:
			return true
	return false


## One past the highest occluder in that column, or MIN_Y when there is none.
func highest_occluder(x: int, z: int) -> int:
	var c := Vector2i(x >> 4, z >> 4)
	if not chunks.has(c):
		return MIN_Y
	var hmap: PackedInt32Array = chunks[c]["hmap"]
	return hmap[(x & 15) + (z & 15) * CHUNK]


# ================================================================ world authority
## Every *requested* block change -- a player placing or breaking, a command --
## goes through `set_block`, which hands it to the authority. Worldgen and save
## loading write bytes directly and deliberately bypass it, because those are not
## requests, they are the world being built.
##
## Single player uses `Authority`, where the request simply *is* the change.
## Multiplayer swaps in a subclass that predicts locally, asks the host, and
## reconciles when the answer arrives -- and nothing outside these two methods has
## to know which one is installed.
signal block_changed(pos: Vector3i, id: int)
signal container_opened(pos: Vector3i)
signal furnace_opened(pos: Vector3i)
signal table_opened(pos: Vector3i)
## Emitted when a sign is right-clicked, so the UI can ask for its text.
signal sign_opened(pos: Vector3i)
## Emitted when a bed is right-clicked, so main can try to sleep.
signal bed_used(pos: Vector3i)
## Emitted when an enchanting table is right-clicked.
signal enchant_opened(pos: Vector3i)

var authority = null
var containers = null       # the chest/furnace store, injected by main


class Authority:
	## Ask for a change. Returns true when it is real.
	func request_edit(w, pos: Vector3i, id: int, record: bool, silent: bool = false) -> bool:
		var ok: bool = w.apply_edit(pos, id, record, silent)
		if ok:
			on_applied(pos, id)
		return ok

	## The change is now real. A network layer broadcasts it from here.
	func on_applied(_pos: Vector3i, _id: int) -> void:
		pass


func set_block(x: int, y: int, z: int, id: int, record: bool = true,
		silent: bool = false) -> bool:
	if y < MIN_Y or y >= MAX_Y:
		return false
	if not chunks.has(Vector2i(x >> 4, z >> 4)):
		return false
	# A request that would change nothing is not a request. Checked here rather than
	# in apply_edit so it never reaches the authority: a multiplayer client would
	# otherwise send a packet every frame the button is held down.
	if get_block(x, y, z) == id:
		return false
	if authority == null:
		authority = Authority.new()
	return authority.request_edit(self, Vector3i(x, y, z), id, record, silent)


## The single right-click dispatch: doors toggle, a chest or furnace asks the UI to
## open, and everything else falls through to the circuit solver. Returns true when the
## click was consumed (so the player does not then try to place a block).
func interact_block(pos: Vector3i, id: int) -> bool:
	match id:
		Blocks.DOOR, Blocks.DOOR_OPEN:
			_toggle_door(pos)
			return true
		Blocks.CHEST:
			if containers != null:
				containers.chest_at(pos)
			container_opened.emit(pos)
			return true
		Blocks.FURNACE, Blocks.FURNACE_LIT:
			if containers != null:
				containers.furnace_at(pos)
			furnace_opened.emit(pos)
			return true
		Blocks.CRAFTING_TABLE:
			table_opened.emit(pos)
			return true
		Blocks.TRAPDOOR, Blocks.TRAPDOOR_OPEN:
			_toggle_trapdoor(pos)
			return true
		Blocks.FENCE_GATE, Blocks.FENCE_GATE_OPEN:
			_toggle_gate(pos)
			return true
		Blocks.SIGN, Blocks.SIGN_WALL:
			sign_opened.emit(pos)
			return true
		Blocks.BED, Blocks.BED_HEAD:
			bed_used.emit(pos)
			return true
		Blocks.ENCHANTING_TABLE:
			enchant_opened.emit(pos)
			return true
	if circuit != null:
		return circuit.interact(pos, id)
	return false


## A trapdoor swings on its hinge the way a door does: closed becomes the upright board,
## open becomes the flat hatch. The facing (which edge the hinge is on, and whether the
## hatch is mounted on the floor or the ceiling) is already recorded, so the id swap is
## all that changes.
func _toggle_trapdoor(pos: Vector3i) -> void:
	var open := get_block(pos.x, pos.y, pos.z) == Blocks.TRAPDOOR_OPEN
	set_block(pos.x, pos.y, pos.z, Blocks.TRAPDOOR if open else Blocks.TRAPDOOR_OPEN)


## A gate is a door in a fence: closed it blocks, open it swings aside.
func _toggle_gate(pos: Vector3i) -> void:
	var open := get_block(pos.x, pos.y, pos.z) == Blocks.FENCE_GATE_OPEN
	set_block(pos.x, pos.y, pos.z, Blocks.FENCE_GATE if open else Blocks.FENCE_GATE_OPEN)


## The text on a sign, or "" when it has none. An empty string clears the sign.
func sign_text_at(pos: Vector3i) -> String:
	return str(sign_text.get(pos, ""))


func set_sign_text(pos: Vector3i, text: String) -> void:
	var t := text.strip_edges()
	if t == "":
		sign_text.erase(pos)
		_remove_sign_label(pos)
	else:
		sign_text[pos] = t
		_refresh_sign_label(pos)


## Keeps the floating labels in step with the camera: a label is created for every sign
## within streaming range and freed for one that is out of range or no longer has text.
## Called from main every so often, not per frame, because the set of signs is small and
## walking it is not.
func sync_sign_labels(center: Vector3) -> void:
	var reach := float((render_distance + 1) * CHUNK)
	for pos in sign_text.keys():
		var near := (Vector3(pos) + Vector3(0.5, 0.5, 0.5)).distance_to(center) <= reach
		if not near:
			_remove_sign_label(pos)
		elif not _sign_labels.has(pos):
			_refresh_sign_label(pos)
	for pos in _sign_labels.keys():
		if not sign_text.has(pos):
			_remove_sign_label(pos)


func _refresh_sign_label(pos: Vector3i) -> void:
	_remove_sign_label(pos)
	if not sign_text.has(pos):
		return
	var lb := Label3D.new()
	lb.text = str(sign_text[pos])
	lb.position = Vector3(pos) + Vector3(0.5, 0.86, 0.5)
	lb.pixel_size = 0.016
	lb.modulate = Color(0.08, 0.06, 0.04)
	lb.outline_size = 6
	lb.outline_modulate = Color(0.90, 0.84, 0.68, 0.55)
	lb.no_depth_test = false
	lb.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lb.render_priority = 1
	lb.width = 200
	add_child(lb)
	_sign_labels[pos] = lb


func _remove_sign_label(pos: Vector3i) -> void:
	if _sign_labels.has(pos):
		var lb = _sign_labels[pos]
		if is_instance_valid(lb):
			lb.queue_free()
		_sign_labels.erase(pos)


## A door is two blocks tall and swings on its hinge. Opening turns the leaf a quarter
## turn — the mesher thins the panel along the new axis, so it lies along the wall you
## walked through — and closing turns it back. Both halves turn together.
func _toggle_door(pos: Vector3i) -> void:
	var opening := get_block(pos.x, pos.y, pos.z) == Blocks.DOOR
	var new_id := Blocks.DOOR_OPEN if opening else Blocks.DOOR
	var cells: Array = [pos]
	for dy in [-1, 1]:
		var nb := Vector3i(pos.x, pos.y + dy, pos.z)
		if _is_door(get_block(nb.x, nb.y, nb.z)):
			cells.append(nb)
	for c in cells:
		var cur: Vector3i = facing_override.get(c, _panel_facing())
		facing_override[c] = _rotate_quarter(cur, opening)
		set_block(c.x, c.y, c.z, new_id)


func _is_door(id: int) -> bool:
	return id == Blocks.DOOR or id == Blocks.DOOR_OPEN


## A quarter turn of a horizontal facing about the vertical axis: +X -> -Z -> -X -> +Z.
func _rotate_quarter(d: Vector3i, ccw: bool) -> Vector3i:
	if ccw:
		return Vector3i(-d.z, 0, d.x)
	return Vector3i(d.z, 0, -d.x)


## The actual mutation: the only place a chunk's blocks change outside worldgen.
## Called by the authority, never by callers directly.
##
## `silent` marks a write made *by* the circuit solver rather than by a player: a
## piston extending, a lamp swapping its face. Those must not re-enter the solver,
## or a piston would trigger the solve that extends it, forever.
func apply_edit(pos: Vector3i, id: int, record: bool = true, silent: bool = false) -> bool:
	var x := pos.x
	var y := pos.y
	var z := pos.z
	if y < MIN_Y or y >= MAX_Y:
		return false
	var c := Vector2i(x >> 4, z >> 4)
	if not chunks.has(c):
		return false
	var ch: Dictionary = chunks[c]
	var sec := y >> 4
	var lx := x & 15
	var lz := z & 15
	var idx := lx + lz * CHUNK + (y & 15) * CHUNK * CHUNK
	var blocks: PackedByteArray = _sec_ensure(ch, sec)
	var old := blocks[idx]
	if old == id:
		return false

	# a plant floating on top of the removed block goes away too. Applied directly
	# rather than re-requested: it is a consequence of this one change, so a remote
	# authority should ship it as part of the same edit, not as a second request.
	if id == Blocks.AIR:
		# a plant resting on the removed block goes with it, and so does the other half
		# of a two-tall door
		var above := get_block(x, y + 1, z)
		if Blocks.kind[above] == Blocks.K_CROSS or _is_door(above):
			apply_edit(Vector3i(x, y + 1, z), Blocks.AIR, record, silent)
		if _is_door(get_block(x, y - 1, z)):
			apply_edit(Vector3i(x, y - 1, z), Blocks.AIR, record, silent)

	blocks[idx] = id
	ch["sections"][sec] = blocks
	# the occluder tally follows the write, which is what lets `_is_buried` stay honest
	# without rescanning the section: a wall filled in makes it buried, a block dug out
	# of it makes it not
	ch["occ"][sec] = _sec_occ(ch, sec) + _t_occluder[id] - _t_occluder[old]

	if record:
		edits[pos] = id
		var ebc: Dictionary = edits_by_chunk.get(c, {})
		ebc[pos] = id
		edits_by_chunk[c] = ebc

	if Blocks.emission[old] > 0:
		torches.erase(pos)
	if Blocks.emission[id] > 0:
		torches[pos] = id
		_light_timer = 0.0

	# a block whose *look* can change keeps a tile override; anything else drops the
	# one it may have had, so a switch broken and replaced comes back open
	if not _tile_can_change(id):
		tile_override.erase(pos)
	if not _tile_can_change(old):
		tile_override.erase(pos)

	# a thin panel or a non-cube shape remembers which way it faces: a fresh placement
	# takes it from where the placer looked (or from the explicit facing the placer set
	# for a slab's half or a trapdoor's hinge); a door being opened, or a stair whose id
	# does not change, keeps the one it has.
	if Blocks.uses_facing(Blocks.kind[id]):
		if not facing_override.has(pos) or not Blocks.uses_facing(Blocks.kind[old]):
			facing_override[pos] = _panel_facing()
	else:
		facing_override.erase(pos)

	# breaking a sign takes its words with it, so a new sign in the same cell does not
	# inherit the last one's text
	if id == Blocks.AIR and (old == Blocks.SIGN or old == Blocks.SIGN_WALL):
		sign_text.erase(pos)
		_remove_sign_label(pos)

	# keep the circuit solver's picture of the world in step, then let it re-solve
	# around this position. Never from a silent write: that write came *from* the
	# solver, and re-entering would never terminate.
	if circuit != null and not silent:
		if Blocks.circuit_kind(id) == 0:
			circuit.unregister(pos)
		else:
			circuit.register(pos, id, _facing_for_place(pos, id))
		circuit.mark(pos)
	elif circuit != null:
		if Blocks.circuit_kind(id) == 0:
			circuit.unregister(pos)

	# fluid bookkeeping. A cell that stops being a fluid drops its level; a fluid placed
	# by hand (a bucket) is a *source*, so it must not inherit a level from whatever
	# flowed here before. The sim's own writes are silent and manage their own levels.
	if _t_liquid[id] != 1:
		fluid.erase(pos)
	elif not silent:
		fluid.erase(pos)
	if not silent:
		wake_fluid(pos)

	_recompute_column(ch, lx, lz)
	_dirty_cells_around(pos)
	block_changed.emit(pos, id)
	return true


## True for blocks whose tile can change without their id changing, so the mesh
## must remember which face they are currently showing.
func _tile_can_change(id: int) -> bool:
	return Blocks.circuit_kind(id) != 0


## Which way a directional component points when it is first placed. The player's
## look is the only sensible input at that moment; `player` may be null during a
## load, in which case the component keeps the default.
func _facing_for_place(pos: Vector3i, id: int) -> Vector3i:
	if circuit == null:
		return Vector3i(0, 0, 1)
	var look := _place_look
	if look.length_squared() < 0.0001:
		return Vector3i(0, 0, 1)
	return circuit.facing_from_look(look)


## Which way a thin panel is placed: the explicit facing the placer set for this one
## placement if there is one (a slab's half, a trapdoor's hinge, a stair's ascent),
## otherwise the placer's look snapped to the nearest horizontal axis, so a door you
## place facing north has its leaf across the east-west axis. Falls back to +Z when
## there is no look (a load, or a test).
func _panel_facing() -> Vector3i:
	if _place_facing != Vector3i.ZERO:
		return _place_facing
	var look := _place_look
	if look.length_squared() < 0.0001:
		return Vector3i(0, 0, 1)
	if absf(look.x) >= absf(look.z):
		return Vector3i(1 if look.x > 0.0 else -1, 0, 0)
	return Vector3i(0, 0, 1 if look.z > 0.0 else -1)


## Set by the player just before placing, so the world knows which way the placer
## was looking without holding a reference to the player.
var _place_look := Vector3.ZERO
## Set by the player just before placing a block whose exact half or hinge matters: a
## slab mounted on a ceiling (y = 1) or a trapdoor hinged on an edge. Zero means "derive
## it from the look", which is what a door and a ladder do.
var _place_facing := Vector3i.ZERO


func set_place_look(dir: Vector3) -> void:
	_place_look = dir


func set_place_facing(v: Vector3i) -> void:
	_place_facing = v


## Which way the placement in flight faces, by the same rule `apply_edit` uses. A caller
## that needs to place a companion block (a bed's head, two cells on) asks this instead of
## re-deriving the facing and getting a different answer.
func placement_facing() -> Vector3i:
	return _panel_facing()


## Sections of a chunk, highest first. Sorting is what makes "walk down from the top"
## a plain loop instead of a full-height scan.
func _sections_top_down(ch: Dictionary) -> Array:
	var secs: Array = ch["sections"].keys()
	secs.sort()
	secs.reverse()
	return secs


func _recompute_column(ch: Dictionary, lx: int, lz: int) -> void:
	var hmap: PackedInt32Array = ch["hmap"]
	var sections: Dictionary = ch["sections"]
	var base := lx + lz * CHUNK
	var top := MIN_Y
	var got_occ := false
	for sec in _sections_top_down(ch):
		var arr: PackedByteArray = sections[sec]
		var ybase: int = int(sec) * SEC
		for ly in range(SEC - 1, -1, -1):
			var id: int = arr[base + ly * CHUNK * CHUNK]
			if id == Blocks.AIR:
				continue
			if Blocks.occluder[id] == 1:
				top = ybase + ly + 1
				got_occ = true
				break
		if got_occ:
			break
	hmap[base] = top
	ch["hmap"] = hmap


## Per column, one past the highest occluder, or MIN_Y when the column is bare.
func _build_hmap(sections: Dictionary) -> PackedInt32Array:
	var hmap := PackedInt32Array()
	hmap.resize(CHUNK * CHUNK)
	hmap.fill(MIN_Y)
	var secs: Array = sections.keys()
	secs.sort()
	secs.reverse()          # highest section first, so the first hit is the answer
	for sec in secs:
		var arr: PackedByteArray = sections[sec]
		var ybase: int = int(sec) * SEC
		for lx in CHUNK:
			for lz in CHUNK:
				var base := lx + lz * CHUNK
				if hmap[base] != MIN_Y:
					continue    # this column is already settled by a higher section
				for ly in range(SEC - 1, -1, -1):
					if Blocks.occluder[arr[base + ly * CHUNK * CHUNK]] == 1:
						hmap[base] = ybase + ly + 1
						break
	return hmap


# ================================================================ streaming
func update_streaming(player_pos: Vector3) -> void:
	var _start := Time.get_ticks_usec()
	var _t := _start
	var _ph: Dictionary = {}
	var pc := Vector2i(floori(player_pos.x) >> 4, floori(player_pos.z) >> 4)
	if pc != _center:
		_center = pc
		_gen_pending = true

	_drain_results()
	_perf("drain", Time.get_ticks_usec() - _t)
	if perf_on:
		_ph["drain"] = Time.get_ticks_usec() - _t
	_t = Time.get_ticks_usec()

	# Generated columns land here and become chunks. Bounded by the budget setting, so a
	# burst of columns finishing together cannot dump a dozen chunk records into one frame.
	_drain_gen()
	_perf("genapply", Time.get_ticks_usec() - _t)
	if perf_on:
		_ph["genapply"] = Time.get_ticks_usec() - _t
	_t = Time.get_ticks_usec()

	if _gen_pending:
		_gen_pending = false
		_rebuild_gen_list()
		_unload_far_chunks()
	_perf("rebuild", Time.get_ticks_usec() - _t)
	if perf_on:
		_ph["rebuild"] = Time.get_ticks_usec() - _t
	_t = Time.get_ticks_usec()

	# Generation itself happens on the pool; this only hands out the work. It is a scan of
	# the gen list, not a cost worth budgeting.
	_submit_gen_jobs()
	if _gen_index < _gen_list.size() or not _gen_jobs.is_empty():
		_loading = true
	elif _loading:
		_loading = false
	_perf("gensub", Time.get_ticks_usec() - _t)
	if perf_on:
		_ph["gensub"] = Time.get_ticks_usec() - _t
	_t = Time.get_ticks_usec()

	# Topped up rather than submitted in waves. A section job is small, so waiting for
	# a whole batch to land before queueing the next one leaves the pool idle between
	# batches and costs a frame of latency per batch.
	_submit_jobs(player_pos)
	_perf("submit", Time.get_ticks_usec() - _t)
	if perf_on:
		_ph["submit"] = Time.get_ticks_usec() - _t
	_t = Time.get_ticks_usec()
	_update_lights(player_pos)
	_perf("lights", Time.get_ticks_usec() - _t)
	if perf_on:
		_ph["lights"] = Time.get_ticks_usec() - _t
		_ph["total"] = Time.get_ticks_usec() - _start
		perf_last = _ph


func idle() -> bool:
	return _jobs.is_empty() and _gen_jobs.is_empty() and _gen_index >= _gen_list.size()


## Ask for the chunk queues to be rebuilt (after a render distance change).
func request_rebuild() -> void:
	_gen_pending = true


## 0..1 fraction of the chunks in range that already have a mesh.
func progress() -> float:
	var total := 0
	var done := 0
	var r := render_distance
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			total += 1
			var c := Vector2i(_center.x + dx, _center.y + dz)
			if chunks.has(c) and bool(chunks[c]["meshed"]):
				done += 1
	if total == 0:
		return 1.0
	return float(done) / float(total)


func loaded_chunks() -> int:
	return chunks.size()


func _rebuild_gen_list() -> void:
	_gen_list = []
	var r := render_distance + 1
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var c := Vector2i(_center.x + dx, _center.y + dz)
			if chunks.has(c):
				continue
			_gen_list.append([dx * dx + dz * dz, c])
	_gen_list.sort_custom(func(a, b): return a[0] < b[0])
	_gen_index = 0


## Hands the pool as much of the gen list as it has room for. Ordered by the list, which
## is sorted nearest-first, so the chunks right around the player are built before the
## horizon. A column already in flight is skipped rather than queued twice.
func _submit_gen_jobs() -> void:
	var room := max_gen_jobs - _gen_jobs.size()
	while room > 0 and _gen_index < _gen_list.size():
		var c: Vector2i = _gen_list[_gen_index][1]
		_gen_index += 1
		if chunks.has(c) or _gen_jobs.has(c):
			continue
		_gen_jobs[c] = WorkerThreadPool.add_task(
			Callable(self, "_gen_job").bind(c, _take_gen()), true, "gen %d,%d" % [c.x, c.y])
		room -= 1


## One generator per in-flight job: they own noise objects, and two threads sampling the
## same FastNoiseLite would be a data race. Recycled, because the per-chunk `fill_chunk`
## dwarfs the cost of building one anyway.
func _take_gen() -> VoxelTerrain:
	if _gen_pool.is_empty():
		return VoxelTerrain.new(seed_value)
	return _gen_pool.pop_back()


## Runs on a worker thread. Produces the raw column and nothing else: the edit replay and
## the circuit registration both touch live dictionaries and stay on the main thread.
func _gen_job(c: Vector2i, gen: VoxelTerrain) -> void:
	var t := Time.get_ticks_usec()
	var built: Dictionary = gen.fill_chunk(c.x, c.y)
	var us := Time.get_ticks_usec() - t
	_mutex.lock()
	_gen_results.append({"c": c, "built": built, "gen": gen})
	perf_gen_us += us
	perf_gen_max = maxi(perf_gen_max, us)
	perf_gen_chunks += 1
	_mutex.unlock()


## Turns finished columns into chunks, up to the per-frame budget.
##
## The budget is what stops a burst -- eight columns landing on the same frame -- from
## costing eight chunk records' worth of main-thread time at once. Anything left over is
## put back at the head of the queue, in order, so nothing is dropped.
func _drain_gen() -> void:
	var finished: Array = []
	for c in _gen_jobs.keys():
		if WorkerThreadPool.is_task_completed(_gen_jobs[c]):
			WorkerThreadPool.wait_for_task_completion(_gen_jobs[c])
			finished.append(c)
	for c in finished:
		_gen_jobs.erase(c)
	if _gen_jobs.is_empty() and finished.is_empty() and _gen_results.is_empty():
		return
	_mutex.lock()
	var res := _gen_results
	_gen_results = []
	_mutex.unlock()
	var budget := Time.get_ticks_msec() + Settings.chunk_budget_ms
	for i in res.size():
		var item: Dictionary = res[i]
		_give_gen(item["gen"])
		var c: Vector2i = item["c"]
		# The player may have walked away while this was generating. Dropped rather than
		# built, because `_unload_far_chunks` would only free it again a moment later.
		if maxi(absi(c.x - _center.x), absi(c.y - _center.y)) <= render_distance + 4:
			_finish_gen(c, item["built"])
		if Time.get_ticks_msec() > budget and i + 1 < res.size():
			_mutex.lock()
			_gen_results = res.slice(i + 1) + _gen_results
			_mutex.unlock()
			return


func _give_gen(gen: VoxelTerrain) -> void:
	_gen_pool.append(gen)


var probe_all: Array = []


func _nop(v: int) -> int:
	return v


## TEMPORARY probe: measures which forms of table access survive being run on eight worker
## threads. speedup 8.0x = perfect, 1.0x = no gain, below 1.0x = running eight threads is
## slower than one, which is what the generator and the mesher were doing.
func probe_cpu(slot: int, mode: int) -> void:
	var n := 500000
	var t := Time.get_ticks_usec()
	if mode == 0:
		var s := 0
		for i in n:
			s += Blocks.STONE
	elif mode == 1:
		var s2 := 0
		var stone := Blocks.STONE
		for i in n:
			s2 += stone
	elif mode == 2:
		var s3 := 0
		for i in n:
			s3 += Blocks.occluder[i & 15]
	elif mode == 3:
		var s4 := 0
		var occ := _t_occluder
		for i in n:
			s4 += occ[i & 15]
	elif mode == 4:
		var s5 := 0
		for i in n:
			s5 += int(Blocks.tile_rect(i & 15).size.x)
	elif mode == 5:
		var s6 := 0
		for i in n:
			s6 += int(_tile_rect(i & 15).size.x)
	elif mode == 6:
		var s7 := 0
		for i in n:
			s7 += _nop(i)
	elif mode == 7:
		var s8 := 0
		for i in n:
			s8 += VoxelTerrain.CHUNK
	probe_all.append(Time.get_ticks_usec() - t)


## The main-thread half of generation: replay the edits recorded for this chunk, tell the
## circuit solver about any circuit part among them, and store the chunk.
func _finish_gen(c: Vector2i, built: Dictionary) -> void:
	if chunks.has(c):
		return
	var sections: Dictionary = built["sections"]
	var occ: Dictionary = built["occ"]
	if edits_by_chunk.has(c):
		var ebc: Dictionary = edits_by_chunk[c]
		for pos in ebc.keys():
			var y: int = pos.y
			if y < MIN_Y or y >= MAX_Y:
				continue
			# an edit can sit in a section the generator never made -- anything the
			# player built above the canopy, and anything a save recorded up there
			var sec := y >> 4
			var arr = sections.get(sec)
			if arr == null:
				arr = PackedByteArray()
				arr.resize(CHUNK * CHUNK * SEC)
				arr.fill(Blocks.AIR)
				sections[sec] = arr
			arr[(pos.x & 15) + (pos.z & 15) * CHUNK + (y & 15) * CHUNK * CHUNK] = ebc[pos]
			sections[sec] = arr
			# an edit that placed a circuit part has to be re-registered with the
			# solver, or a world loaded from a save has dead switches and dark lamps
			if circuit != null and Blocks.circuit_kind(int(ebc[pos])) != 0:
				circuit.register(pos, int(ebc[pos]))
		# The replay wrote bytes the generator's tally knows nothing about, so the tally
		# is rebuilt rather than trusted. Only edited chunks reach this, so a fresh world
		# skips the scan entirely and is not slowed down by a count it never reads.
		occ = count_occluders(sections)
	chunks[c] = new_chunk(sections, occ)


## A fresh chunk record around some sections. Public and used from three places -- the
## generator, the test harness and the terrain-stats dump -- because the layout has
## enough keys that a hand-written copy drifts and the drift shows up as one caller
## silently missing a field.
##
## Every section starts out needing a mesh, so `dirty` begins as the full set.
func new_chunk(sections: Dictionary, occ: Dictionary = {}) -> Dictionary:
	return {
		"sections": sections,
		"occ": occ,
		"hmap": _build_hmap(sections),
		"dirty": _all_sections(sections),
		"srev": {},
		"nodes": {},
		"meshed": false,
	}


## How many cells of a section occlude, or 0 when the section is not there. Kept as a
## count rather than a flag so `apply_edit` can maintain it the way the generator's
## volume does -- read the old value, add the difference -- instead of rescanning.
func _sec_occ(ch: Dictionary, sec: int) -> int:
	return int(ch["occ"].get(sec, 0))


## Recounts a whole chunk of sections. Only needed where the sections were written by
## something other than the generator's volume -- a save replay, and test fixtures.
func count_occluders(sections: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var per := SEC * CHUNK * CHUNK
	for sec in sections:
		var arr: PackedByteArray = sections[sec]
		var n := 0
		for i in per:
			if _t_occluder[arr[i]] == 1:
				n += 1
		out[int(sec)] = n
	return out


## Whether a section has no face worth meshing: every one of its cells occludes, and so
## does every cell of each of its six neighbours. Its interior faces are then culled by
## the section itself and its boundary faces by the neighbour on the far side, so a job
## on it could only ever produce an empty mesh.
##
## Deliberately the *same* predicate the mesher culls with, `occluder == 1`, so the two
## can never disagree about whether a face exists. A neighbour that is absent counts as
## air and therefore as not buried, which is what keeps a cave open to the sky meshed.
func _is_buried(c: Vector2i, sec: int) -> bool:
	if not _sec_full(c, sec):
		return false
	for d in _NEIGHBOURS6:
		if d.y == 0:
			if not _sec_full(Vector2i(c.x + d.x, c.y + d.z), sec):
				return false
		elif not _sec_full(c, sec + d.y):
			return false
	return true


func _sec_full(c: Vector2i, sec: int) -> bool:
	# Anything wholly below the world floor counts as full, because that is what the
	# mesher reads down there: `_nb_get` answers BEDROCK below MIN_Y so the bottom layer
	# of the world has its downward faces culled. Without this the deepest real section
	# could never be skipped -- it would look out onto a neighbour that is not there.
	if (sec + 1) * SEC <= MIN_Y:
		return true
	if not chunks.has(c):
		return false
	return _sec_occ(chunks[c], sec) == CHUNK * CHUNK * SEC


## Marks a buried section done, with no job and no scan behind it.
##
## Goes through `_attach_mesh` with empty buffers rather than just erasing the dirty key:
## that path already knows how to drop a mesh this section may still be showing -- a
## cave the player fills in becomes buried -- and it is the one place that erases the key
## and recomputes whether the chunk is finished, in that order. Erasing the key anywhere
## else would leave the chunk looking unfinished until something unrelated nudged it.
func _finish_buried(c: Vector2i, sec: int) -> void:
	if not chunks.has(c):
		return
	_attach_mesh({"c": c, "sec": sec, "solid": Buf.new(), "extra": Buf.new(),
		"trans": Buf.new(), "cross": Buf.new(), "flat": Buf.new(), "lava": Buf.new(),
		"srev": int(chunks[c]["srev"].get(sec, 0))})


const _NEIGHBOURS6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]


## {section: true} for every section present, which is what `dirty` holds.
func _all_sections(sections: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for sec in sections:
		out[int(sec)] = true
	return out


func _unload_far_chunks() -> void:
	var limit := render_distance + 4
	var doomed: Array = []
	for c in chunks.keys():
		if absi(c.x - _center.x) > limit or absi(c.y - _center.y) > limit:
			doomed.append(c)
	for c in doomed:
		_free_nodes(chunks[c])
		chunks.erase(c)


# ================================================================ job submission
## One job is one (chunk, section) box, not a whole column. That is the point of the
## split: a job touches 16x16x16 cells whatever the world height is, and a single edit
## re-queues the one box it landed in instead of the whole column.
func _submit_jobs(player_pos: Vector3) -> void:
	# Room left in the pool, not "the batch is empty": jobs already running keep their
	# threads and the free ones get the next candidates straight away.
	var room := max_jobs - _jobs.size()
	if room <= 0:
		return
	var cand: Array = []
	var buried: Array = []
	var r := render_distance
	var psec := floori(player_pos.y) >> 4
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var c := Vector2i(_center.x + dx, _center.y + dz)
			if not chunks.has(c):
				continue
			var dirty: Dictionary = chunks[c]["dirty"]
			if dirty.is_empty():
				continue
			if not _neighbourhood_ready(c):
				continue
			var dist := dx * dx + dz * dz
			for sec in dirty:
				# A section already being meshed must not be queued twice, or two
				# workers whoever lands second would throw the first one's result away.
				# Checked before the buried test as well, and not just for tidiness: a
				# section can become buried while its own job is still running, and
				# finishing it now would be undone the moment that job landed and drew
				# its stale faces onto a section that is meant to be solid.
				if _jobs.has(Vector3i(c.x, int(sec), c.y)):
					continue
				# Nothing to draw, so there is nothing to wait for: a deep solid section
				# is finished by recognising it. Deferring the decision to a job would
				# mean scanning 4096 cells to produce an empty mesh -- which is most of
				# the cost of the deep world, paid once per section per rebuild.
				if _is_buried(c, int(sec)):
					buried.append([c, int(sec)])
					continue
				# distance first, then whichever section is closest to eye level, so
				# the ground under the player is meshed before the sky above it
				cand.append([[dist, -absi(int(sec) - psec)], c, int(sec)])
	for b in buried:
		_finish_buried(b[0], b[1])
	if cand.is_empty():
		return
	cand.sort_custom(func(a, b):
		if a[0][0] != b[0][0]:
			return a[0][0] < b[0][0]
		return a[0][1] < b[0][1])
	var n := mini(room, cand.size())
	for i in n:
		var c: Vector2i = cand[i][1]
		var sec: int = cand[i][2]
		var payload := _make_payload(c, sec)
		var key := Vector3i(c.x, sec, c.y)
		var jt := WorkerThreadPool.add_task(Callable(self, "_mesh_job").bind(payload), true,
			"mesh %d,%d,%d" % [c.x, sec, c.y])
		_jobs[key] = jt


func _neighbourhood_ready(c: Vector2i) -> bool:
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if not chunks.has(Vector2i(c.x + dx, c.y + dz)):
				return false
	return true


## Immutable snapshot of one section and everything its mesh can read: the 3x3x3 block
## of sections around it, and the 9 columns' occluder heightmaps for the sky light.
##
## The snapshot has to be 3x3x3, not "9 horizontal neighbours plus the sections above
## and below". Face culling only ever looks one cell away horizontally, but ambient
## occlusion samples the *corners*: see `Blocks.FACE_AO`, where a face's sample offsets
## include things like (1, -1, 0). A block on a chunk's horizontal edge whose face sits
## in the section above it therefore reads the diagonal -- the neighbouring chunk's
## neighbouring section -- and a payload without that diagonal returns air there, which
## shows up as one bright block in an otherwise shaded corner.
func _make_payload(c: Vector2i, sec: int) -> Dictionary:
	var nb: Array = []
	for dy in range(-1, 2):
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var cc := Vector2i(c.x + dx, c.y + dz)
				var arr = null
				if chunks.has(cc):
					arr = chunks[cc]["sections"].get(sec + dy)
				nb.append(arr)
	var hm: Array = []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var cc := Vector2i(c.x + dx, c.y + dz)
			hm.append(chunks[cc]["hmap"] if chunks.has(cc) else null)
	return {"c": c, "sec": sec, "nb": nb, "hm": hm,
		"srev": int(chunks[c]["srev"].get(sec, 0)), "tiles": _local_tiles(c, sec),
		"facing": _local_facing(c, sec), "fluid": _local_fluid(c, sec)}


## The tile overrides that fall inside one section, keyed by section-local position.
## Built here on the main thread so the worker never touches the live dictionary.
##
## The key is `ly`, not the world y, so two overrides a section apart would collide --
## hence the section filter, which is not an optimisation but a correctness requirement.
func _local_tiles(c: Vector2i, sec: int) -> Dictionary:
	var out: Dictionary = {}
	if tile_override.is_empty():
		return out
	var x0 := c.x << 4
	var z0 := c.y << 4
	for pos in tile_override.keys():
		if pos.x < x0 or pos.x >= x0 + CHUNK or pos.z < z0 or pos.z >= z0 + CHUNK:
			continue
		if (pos.y >> 4) != sec:
			continue
		out[Vector3i(pos.x - x0, pos.y & 15, pos.z - z0)] = int(tile_override[pos])
	return out


## The panel facings that fall inside one section, keyed by section-local position, for
## the same reason the tiles are: the worker must never read the live dictionary.
func _local_facing(c: Vector2i, sec: int) -> Dictionary:
	var out: Dictionary = {}
	if facing_override.is_empty():
		return out
	var x0 := c.x << 4
	var z0 := c.y << 4
	for pos in facing_override.keys():
		if pos.x < x0 or pos.x >= x0 + CHUNK or pos.z < z0 or pos.z >= z0 + CHUNK:
			continue
		if (pos.y >> 4) != sec:
			continue
		out[Vector3i(pos.x - x0, pos.y & 15, pos.z - z0)] = facing_override[pos]
	return out


## The flowing-fluid levels inside one section, keyed by section-local position for the
## same reason as tiles and facings: the worker must never read the live `fluid`
## dictionary, which the main thread rewrites on every tick.
func _local_fluid(c: Vector2i, sec: int) -> Dictionary:
	var out: Dictionary = {}
	if fluid.is_empty():
		return out
	var x0 := c.x << 4
	var z0 := c.y << 4
	for pos in fluid.keys():
		if pos.x < x0 or pos.x >= x0 + CHUNK or pos.z < z0 or pos.z >= z0 + CHUNK:
			continue
		if (pos.y >> 4) != sec:
			continue
		out[Vector3i(pos.x - x0, pos.y & 15, pos.z - z0)] = int(fluid[pos])
	return out


func _drain_results() -> void:
	var finished: Array = []
	for c in _jobs.keys():
		if WorkerThreadPool.is_task_completed(_jobs[c]):
			WorkerThreadPool.wait_for_task_completion(_jobs[c])
			finished.append(c)
	for key in finished:
		_jobs.erase(key)
	_mutex.lock()
	var res := _results.duplicate()
	_results.clear()
	_mutex.unlock()
	for item in res:
		_attach_mesh(item)

	# Results are drained in bulk, but a key only leaves `_jobs` once the pool reports
	# its task completed -- and a worker publishes its result *before* the pool gets
	# around to that. So a result can be attached while its own key is still in `_jobs`:
	# the attach sees a job in flight, leaves the chunk unfinished, and the key is then
	# dropped on a later frame with no result left to attach. The chunk would stay
	# unfinished forever, which is what a loader hanging at 120/121 chunks looked like.
	# Recomputing after the keys are gone closes that window; it is a no-op otherwise.
	for key in finished:
		_refresh_meshed(Vector2i(key.x, key.z))


# ================================================================ meshing
## Meshes one section. `payload.nb` is indexed `(dx+1) + (dz+1)*3 + (dy+1)*9`, and a
## null entry means that section does not exist, which is air.
##
## There is no vertical scan bound any more: a section is 16 layers, empty sections are
## never queued, and the loop simply walks all of it.
func _mesh_job(p: Dictionary) -> void:
	var sec: int = p["sec"]
	var ox: int = p["c"].x * CHUNK
	var oz: int = p["c"].y * CHUNK
	var oy: int = sec * SEC
	# six buffers: solid, cutout, translucent, cross, flat, lava. Lava needs its own
	# because it is opaque where water is not, so it cannot share the water material.
	var bufs := [Buf.new(), Buf.new(), Buf.new(), Buf.new(), Buf.new(), Buf.new()]
	var tiles: Dictionary = p["tiles"]
	var facings: Dictionary = p.get("facing", {})
	var fluids: Dictionary = p.get("fluid", {})
	var liq_tab := _t_liquid
	# Local aliases for the tables this loop hammers. Reading them off `self` is fine, but
	# a local is one less indirection in the innermost of the 4096 iterations.
	var occ_tab := _t_occluder
	var kind_tab := _t_kind
	var emit_tab := _t_emission
	var dirs := _t_face_dirs
	var shades := _t_face_shade

	for ly in SEC:
		for lx in CHUNK:
			for lz in CHUNK:
				var id := _nb_get(p, lx, ly, lz)
				if id == _t_air:
					continue
				var k := kind_tab[id]
				var col_light := _sky_light(p, ox + lx, oz + lz, oy + ly)
				var lpos := Vector3(lx, ly, lz)
				if liq_tab[id] == 1:
					# A fluid cell is a box that stops at its own level, not a full cube.
					# A face is drawn unless the neighbour hides it: sides go against an
					# occluder or the same fluid, the surface goes under the same fluid,
					# and the underside goes onto the same fluid or a solid. A source (a
					# cell with no recorded level) is full height, which is why the oceans
					# mesh exactly as they always did.
					var is_lava := id == _t_lava
					var lvl := int(fluids.get(Vector3i(lx, ly, lz), 8))
					var fh := 1.0 if is_lava else float(lvl) / 8.0
					var mask := 0
					for f in [0, 1, 4, 5]:
						var fdir: Vector3i = dirs[f]
						var nid := _nb_get(p, lx + fdir.x, ly + fdir.y, lz + fdir.z)
						if occ_tab[nid] != 1 and nid != id:
							mask |= 1 << f
					var upid := _nb_get(p, lx, ly + 1, lz)
					if occ_tab[upid] != 1 and upid != id:
						mask |= 1 << 2
					var dnid := _nb_get(p, lx, ly - 1, lz)
					if occ_tab[dnid] != 1 and dnid != id:
						mask |= 1 << 3
					if mask != 0:
						var fcol := Color(1.0, 1.0, 1.0) if emit_tab[id] > 0 \
							else Color(col_light, col_light, col_light)
						bufs[5 if is_lava else 2].fluid(Vector3(lx, ly, lz),
							_tile_rect(_t_tile_top[id]), fcol, fh, mask, emit_tab[id] == 0)
					continue
				if k == Blocks.K_CROSS:
					bufs[3].cross(Vector3(lx, ly, lz),
						_tile_rect(_tile_of(tiles, lx, ly, lz, id)),
						Color(col_light, col_light, col_light))
					continue
				if k == Blocks.K_FLAT:
					# a plate on the floor: one flat quad, never face-culled. It sits
					# inside the cell of the block it rests on, so there is nothing to
					# hide behind and no neighbour test worth doing.
					var lit := col_light
					if emit_tab[id] > 0:
						lit = 1.0
					bufs[4].plate(Vector3(lx, ly, lz),
						_tile_rect(_tile_of(tiles, lx, ly, lz, id)),
						Color(lit, lit, lit))
					continue
				if k == Blocks.K_PANEL:
					# a thin slab with real thickness (Minecraft's door is 3/16 of a
					# block). It is thinned along the axis it faces and pushed against
					# the wall for a ladder; a door leaf sits through the cell.
					var plit := col_light
					if emit_tab[id] > 0:
						plit = 1.0
					var fd: Vector3i = facings.get(Vector3i(lx, ly, lz), Vector3i(0, 0, 1))
					var axis := 1
					var comp := float(fd.z)
					if fd.x != 0:
						axis = 0
						comp = float(fd.x)
					# flush to the edge the panel faces, like Minecraft's door and ladder
					var plane := 0.5 + 0.40 * comp
					bufs[3].panel(Vector3(lx, ly, lz),
						_tile_rect(_tile_of(tiles, lx, ly, lz, id, _t_tile_top[id])),
						Color(plit, plit, plit), axis, plane, 0.1875)
					continue
				if k == Blocks.K_SLAB:
					# a half-height box. `fd.y > 0` means the top half, which is what a
					# slab placed on a ceiling gets; the sides pass the matching half of
					# the tile so the grain is not stretched, while the top face shows
					# the whole texture.
					var slit := col_light
					if emit_tab[id] > 0:
						slit = 1.0
					var sfd: Vector3i = facings.get(Vector3i(lx, ly, lz), Vector3i(0, 0, 1))
					var sr := _tile_rect(_tile_of(tiles, lx, ly, lz, id))
					var sc := Color(slit, slit, slit)
					if sfd.y > 0:
						bufs[0].box(lpos + Vector3(0, 0.5, 0), lpos + Vector3(1, 1, 1),
							_half_rect(sr, false), sc, sr)
					else:
						bufs[0].box(lpos, lpos + Vector3(1, 0.5, 1),
							_half_rect(sr, true), sc, sr)
					continue
				if k == Blocks.K_STAIRS:
					# the lower half of the cell plus the upper half of whichever side the
					# stair rises toward (its facing), giving the classic L profile. The
					# collision is treated as the lower half only, so a run of stairs is
					# climbed by the ordinary walking step-up rather than a jump.
					var tlit2 := col_light
					if emit_tab[id] > 0:
						tlit2 = 1.0
					var tfd: Vector3i = facings.get(Vector3i(lx, ly, lz), Vector3i(0, 0, 1))
					var tr := _tile_rect(_tile_of(tiles, lx, ly, lz, id))
					var tc := Color(tlit2, tlit2, tlit2)
					bufs[0].box(lpos, lpos + Vector3(1, 0.5, 1), _half_rect(tr, true), tc, tr)
					var qa := lpos + Vector3(0, 0.5, 0)
					var qb := lpos + Vector3(1, 1, 1)
					if tfd.x > 0:
						qa.x = lpos.x + 0.5
					elif tfd.x < 0:
						qb.x = lpos.x + 0.5
					elif tfd.z > 0:
						qa.z = lpos.z + 0.5
					else:
						qb.z = lpos.z + 0.5
					bufs[0].box(qa, qb, _half_rect(tr, false), tc, tr)
					continue
				if k == Blocks.K_TRAPDOOR:
					# a hatch: flat and thin when closed, an upright board hinged on the
					# edge it faces when open. `fd.y > 0` is a ceiling-mounted hatch.
					var tlit3 := col_light
					if emit_tab[id] > 0:
						tlit3 = 1.0
					var hfd: Vector3i = facings.get(Vector3i(lx, ly, lz), Vector3i(0, 0, 1))
					var hr := _tile_rect(_tile_of(tiles, lx, ly, lz, id))
					var hc := Color(tlit3, tlit3, tlit3)
					if id == Blocks.TRAPDOOR_OPEN:
						var haxis := 1
						var hcomp := float(hfd.z)
						if hfd.x != 0:
							haxis = 0
							hcomp = float(hfd.x)
						bufs[0].panel(lpos, hr, hc, haxis, 0.5 + 0.40 * hcomp, 0.1875)
					elif hfd.y > 0:
						bufs[0].box(lpos + Vector3(0, 0.8125, 0), lpos + Vector3(1, 1, 1),
							hr, hc, hr)
					else:
						bufs[0].box(lpos, lpos + Vector3(1, 0.1875, 1), hr, hc, hr)
					continue
				if k == Blocks.K_CARPET:
					# a 1/16 layer of cloth laid over the block below
					var clit := col_light
					if emit_tab[id] > 0:
						clit = 1.0
					var cr := _tile_rect(_tile_of(tiles, lx, ly, lz, id))
					bufs[0].box(lpos, lpos + Vector3(1, 0.0625, 1), cr,
						Color(clit, clit, clit), cr)
					continue
				if k == Blocks.K_BED:
					# Three pieces, not one box, because one box is exactly what made a
					# bed look like a red block with a picture of a pillow on all six
					# faces. The frame is inset so it reads as legs under an overhanging
					# mattress, and the pillow is a real lump at the head end -- so the
					# silhouette says "bed" before the texture does.
					var bed_lit := col_light
					if emit_tab[id] > 0:
						bed_lit = 1.0
					var bt := _tile_rect(_tile_of(tiles, lx, ly, lz, id))
					var bs := _tile_rect(Blocks.T_BED_SIDE)
					var bp := _tile_rect(Blocks.T_BED_PILLOW)
					var bwood := _tile_rect(Blocks.T_PLANKS)
					var bcolr := Color(bed_lit, bed_lit, bed_lit)
					var bfd: Vector3i = facings.get(Vector3i(lx, ly, lz), Vector3i(0, 0, 1))
					# the frame: a small plinth under the mattress, inset all round
					bufs[0].box(lpos + Vector3(0.0625, 0.0, 0.0625),
						lpos + Vector3(0.9375, 0.1875, 0.9375), bwood, bcolr, bwood)
					# the mattress: full footprint, overhanging the frame, blanket on top
					bufs[0].box(lpos + Vector3(0, 0.1875, 0),
						lpos + Vector3(1, 0.5625, 1), bs, bcolr, bt)
					# the pillow, on the head half only. A bed is two cells now: the foot is
					# the same mattress without a pillow, and the pillow is what tells the
					# two ends of the bed apart. `bfd` is where the placer was looking, so
					# the head is the far end from whoever put it down.
					if id == Blocks.BED_HEAD:
						var along_x := bfd.x != 0
						var pmin := 0.6875
						var pmax := 0.9375
						if (along_x and bfd.x < 0) or (not along_x and bfd.z < 0):
							pmin = 1.0 - 0.9375
							pmax = 1.0 - 0.6875
						var a_lo := Vector3(0.125, 0.5625, 0.125)
						var a_hi := Vector3(0.875, 0.625, 0.875)
						if along_x:
							a_lo.x = pmin
							a_hi.x = pmax
						else:
							a_lo.z = pmin
							a_hi.z = pmax
						bufs[0].box(lpos + a_lo, lpos + a_hi, bp, bcolr, bp)
					continue
				if k == Blocks.K_FENCE:
					# A centre post with two rails on each side. The shape *is* the fence
					# now: the old version was a full cube wearing the fence silhouette, so
					# a run of fences drew as a jumble of intersecting panels.
					var flit := col_light
					if emit_tab[id] > 0:
						flit = 1.0
					var fr := _tile_rect(Blocks.T_PLANKS)
					var fc := Color(flit, flit, flit)
					bufs[3].box(lpos + Vector3(0.4375, 0, 0.4375),
						lpos + Vector3(0.5625, 1, 0.5625), fr, fc, fr)
					for ri in [0, 1, 4, 5]:
						var rdir: Vector3i = dirs[ri]
						var rnid := _nb_get(p, lx + rdir.x, ly, lz + rdir.z)
						# a rail only reaches where there is something to join: another
						# fence, a gate, or a solid. Reaching into open air is what made a
						# lone post look like a plus sign.
						if occ_tab[rnid] != 1 and rnid != id and rnid != Blocks.FENCE_GATE \
								and rnid != Blocks.FENCE_GATE_OPEN:
							continue
						for ry in [0.3125, 0.6875]:
							var rlo := lpos + Vector3(0.4375, ry, 0.4375)
							var rhi := lpos + Vector3(0.5625, ry + 0.125, 0.5625)
							if rdir.x > 0:
								rhi.x = lpos.x + 1.0
							elif rdir.x < 0:
								rlo.x = lpos.x
							elif rdir.z > 0:
								rhi.z = lpos.z + 1.0
							else:
								rlo.z = lpos.z
							bufs[3].box(rlo, rhi, fr, fc, fr)
					continue
				if k == Blocks.K_GATE:
					# A gate is a thin panel lying across the fence line, so you walk through
					# it along the axis it faces: the same idea as a door leaf, centred in
					# the cell rather than pushed to one edge.
					var glit := col_light
					if emit_tab[id] > 0:
						glit = 1.0
					var gfd: Vector3i = facings.get(Vector3i(lx, ly, lz), Vector3i(0, 0, 1))
					var gaxis := 1
					if gfd.x != 0:
						gaxis = 0
					bufs[3].panel(Vector3(lx, ly, lz),
						_tile_rect(_tile_of(tiles, lx, ly, lz, id, _t_tile_top[id])),
						Color(glit, glit, glit), gaxis, 0.5, 0.1875)
					continue
				var buf: Buf = bufs[k]
				for f in 6:
					var d: Vector3i = dirs[f]
					var nid := _nb_get(p, lx + d.x, ly + d.y, lz + d.z)
					if occ_tab[nid] == 1 or nid == id:
						continue
					var tile := _t_tile_side[id]
					if f == 2:
						tile = _t_tile_top[id]
					elif f == 3:
						tile = _t_tile_bottom[id]
					tile = _tile_of(tiles, lx, ly, lz, id, tile)
					var r := _tile_rect(tile)
					var lt2: float = col_light * shades[f]
					if emit_tab[id] > 0:
						lt2 = 1.0
					var c0 := Color(lt2, lt2, lt2)
					var c1 := c0
					var c2 := c0
					var c3 := c0
					if ao_enabled and k == Blocks.K_CUBE:
						var aos: Array = _t_face_ao[f]
						for i in 4:
							var o: Array = aos[i]
							var s1 := _occ(p, lx, ly, lz, o[0].x, o[0].y, o[0].z)
							var s2 := _occ(p, lx, ly, lz, o[1].x, o[1].y, o[1].z)
							var cn := _occ(p, lx, ly, lz, o[2].x, o[2].y, o[2].z)
							var occ := 3
							if s1 and s2:
								occ = 0
							else:
								occ = 3 - int(s1) - int(s2) - int(cn)
							var f2 := 1.0 - float(3 - occ) / 3.0 * ao_strength
							var cc := Color(lt2 * f2, lt2 * f2, lt2 * f2)
							if i == 0:
								c0 = cc
							elif i == 1:
								c1 = cc
							elif i == 2:
								c2 = cc
							else:
								c3 = cc
					buf.face(f, lpos, r, c0, c1, c2, c3)

	_mutex.lock()
	_results.append({"c": p["c"], "sec": sec, "solid": bufs[0], "extra": bufs[1],
		"trans": bufs[2], "cross": bufs[3], "flat": bufs[4], "lava": bufs[5],
		"srev": int(p.get("srev", 0))})
	_mutex.unlock()


## `Blocks.tile_rect` reached through the autoload is an `Object::callp` in the innermost
## loop of the mesher -- once per face, so six times per solid cell. Same table, read
## straight out of a held reference instead.
func _tile_rect(t: int) -> Rect2:
	return _t_tile_uv[clampi(t, 0, _t_tile_uv.size() - 1)]


## The top or bottom half of a tile's rect. V grows downward, so the bottom half of a
## block (y 0..0.5) samples V 0.5..1. Used by the slab and stair side faces so a half
## block shows half the texture rather than a squashed whole.
func _half_rect(r: Rect2, bottom: bool) -> Rect2:
	return Rect2(r.position + Vector2(0.0, r.size.y * 0.5 if bottom else 0.0),
		Vector2(r.size.x, r.size.y * 0.5))


## The tile a block face should be drawn with, honouring the lit/on override. The
## overrides arrive in the payload rather than being read from `tile_override` here:
## this runs on a worker thread, and the main thread writes that dictionary whenever
## a switch is flipped. The payload is the immutable snapshot the worker is allowed
## to touch.
func _tile_of(tiles: Dictionary, lx: int, ly: int, lz: int, id: int, fallback: int = -1) -> int:
	var base := fallback if fallback >= 0 else _t_tile_top[id]
	if Blocks.circuit_kind(id) == 0:
		return base
	var t = tiles.get(Vector3i(lx, ly, lz), -1)
	if int(t) >= 0:
		return int(t)
	return base


## Reads a block through the payload, crossing chunk borders horizontally and section
## borders vertically. `ly` is section-local and may be -1 or 16 to mean the section
## below or above.
##
## Below the world floor this reports bedrock rather than air, so the bottom layer of
## the bottom section has its downward face culled. Without that the world grows a
## downward-facing quad for every one of the 256 columns of every bottom section.
func _nb_get(p: Dictionary, lx: int, ly: int, lz: int) -> int:
	var dx := 0
	var dz := 0
	var dy := 0
	if lx < 0:
		dx = -1
	elif lx >= CHUNK:
		dx = 1
	if lz < 0:
		dz = -1
	elif lz >= CHUNK:
		dz = 1
	if ly < 0:
		dy = -1
	elif ly >= SEC:
		dy = 1
	var y := (int(p["sec"]) + dy) * SEC + (ly & 15)
	if y < MIN_Y:
		return _t_bedrock
	if y >= MAX_Y:
		return _t_air
	var nb = p["nb"][(dx + 1) + (dz + 1) * 3 + (dy + 1) * 9]
	if nb == null:
		return _t_air
	return nb[(lx & 15) + (lz & 15) * CHUNK + (ly & 15) * CHUNK * CHUNK]


func _occ(p: Dictionary, lx: int, ly: int, lz: int, dx: int, dy: int, dz: int) -> bool:
	return _t_occluder[_nb_get(p, lx + dx, ly + dy, lz + dz)] == 1


func _surf(p: Dictionary, wx: int, wz: int) -> int:
	var cx := wx >> 4
	var cz := wz >> 4
	var cpos: Vector2i = p["c"]
	var dx: int = cx - cpos.x
	var dz: int = cz - cpos.y
	if dx < -1 or dx > 1 or dz < -1 or dz > 1:
		return MAX_Y
	var hm: PackedInt32Array = p["hm"][(dx + 1) + (dz + 1) * 3]
	if hm == null:
		return MAX_Y
	return hm[(wx & 15) + (wz & 15) * CHUNK]


## Sky light baked into vertex colours, from how deep the block sits below its own
## column's surface. Above ground = full brightness, deep underground = dark.
##
## `y` is the absolute world y, which the caller reconstructs from the section and the
## layer within it -- the heightmap it is compared against is absolute too.
func _sky_light(p: Dictionary, wx: int, wz: int, y: int) -> float:
	var h := _surf(p, wx, wz)
	var depth := float(maxi(0, h - y)) - 0.5
	return clampf(1.0 - maxf(0.0, depth) * 0.075, 0.22, 1.0)


func _attach_mesh(item: Dictionary) -> void:
	var c: Vector2i = item["c"]
	var sec: int = item["sec"]
	if not chunks.has(c):
		return
	var ch: Dictionary = chunks[c]
	var solid: Buf = item["solid"]
	var extra: Buf = item["extra"]
	var crossb: Buf = item["cross"]
	var trans: Buf = item["trans"]
	var flatb: Buf = item.get("flat", null)
	var lavab: Buf = item.get("lava", null)

	# Reuse this section's existing nodes. Building and breaking blocks remeshes a
	# section constantly, and freeing + re-adding a MeshInstance3D every time is pure
	# churn; swapping the mesh on the node that is already there is free.
	var want_solid := not solid.empty() or not extra.empty() or not crossb.empty() \
		or (flatb != null and not flatb.empty())
	var mi := _mesh_node(ch, sec, c, "solid", want_solid)
	if mi != null:
		if want_solid:
			var mesh := ArrayMesh.new()
			if not solid.empty():
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(solid))
				mesh.surface_set_material(mesh.get_surface_count() - 1, Blocks.mat_opaque)
			if not extra.empty():
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(extra))
				mesh.surface_set_material(mesh.get_surface_count() - 1, Blocks.mat_cutout)
			if not crossb.empty():
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(crossb))
				mesh.surface_set_material(mesh.get_surface_count() - 1, Blocks.mat_cross)
			if flatb != null and not flatb.empty():
				# the cross material: alpha-scissor, cull disabled. Wire and plates are
				# drawn with transparent corners and emitted as two single-sided faces, so
				# they need the scissor and must not be back-face culled.
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(flatb))
				mesh.surface_set_material(mesh.get_surface_count() - 1, Blocks.mat_cross)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			mi.mesh = mesh
			mi.visible = true
		else:
			mi.mesh = null
			mi.visible = false

	var mt := _mesh_node(ch, sec, c, "trans", not trans.empty())
	if mt != null:
		if not trans.empty():
			var mesh2 := ArrayMesh.new()
			mesh2.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(trans))
			mesh2.surface_set_material(0, Blocks.mat_water)
			mt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mt.mesh = mesh2
			mt.visible = true
		else:
			mt.mesh = null
			mt.visible = false

	var ml := _mesh_node(ch, sec, c, "lava", lavab != null and not lavab.empty())
	if ml != null:
		if lavab != null and not lavab.empty():
			var mesh3 := ArrayMesh.new()
			mesh3.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(lavab))
			mesh3.surface_set_material(0, Blocks.mat_lava)
			ml.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			ml.mesh = mesh3
			ml.visible = true
		else:
			ml.mesh = null
			ml.visible = false

	# Only call this section finished if nothing has changed since the snapshot was
	# taken. Otherwise leave it dirty so it is queued again and the edit shows up.
	if int(ch["srev"].get(sec, 0)) == int(item.get("srev", -1)):
		ch["dirty"].erase(sec)
	chunks[c] = ch
	_refresh_meshed(c)
	chunk_ready.emit(c)


## The section's mesh node, created on first use and kept for reuse afterwards. Only
## built when there is something to draw: a node per empty section would double the
## draw calls for no pixels, and empty sections are the majority of a tall world.
func _mesh_node(ch: Dictionary, sec: int, c: Vector2i, kind: String, want: bool) -> MeshInstance3D:
	var nodes: Dictionary = ch["nodes"]
	var pair = nodes.get(sec)
	if pair == null:
		if not want:
			return null
		pair = {"solid": null, "trans": null, "lava": null}
		nodes[sec] = pair
	if pair[kind] == null:
		var mi := MeshInstance3D.new()
		mi.position = Vector3(c.x * CHUNK, sec * SEC, c.y * CHUNK)
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		pair[kind] = mi
		add_child(mi)
	return pair[kind]


func _arrays(b: Buf) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = b.v
	arrays[Mesh.ARRAY_NORMAL] = b.n
	arrays[Mesh.ARRAY_TEX_UV] = b.uv
	arrays[Mesh.ARRAY_COLOR] = b.c
	arrays[Mesh.ARRAY_INDEX] = b.idx
	return arrays


## Whether this chunk still has a job in flight, by section.
func _chunk_has_jobs(c: Vector2i) -> bool:
	for key in _jobs:
		if key.x == c.x and key.z == c.y:
			return true
	return false


## Recomputes whether the chunk counts as loaded. Derived rather than tracked, so it
## cannot drift: nothing pending and no job in flight means there is nothing left to
## build. `_mark_dirty` clears it, and this only ever sets it back.
func _refresh_meshed(c: Vector2i) -> void:
	if not chunks.has(c):
		return
	var ch: Dictionary = chunks[c]
	if ch["dirty"].is_empty() and not _chunk_has_jobs(c):
		ch["meshed"] = true


## Queues a section for re-meshing and bumps its revision. Meshing happens on a worker
## thread, so a block placed while that section's job is still in flight would otherwise
## be thrown away: the job lands, clears the section, and the edit never shows up until
## something else happens to dirty it again.
func _mark_dirty(c: Vector2i, sec: int) -> void:
	if not chunks.has(c):
		return
	var ch: Dictionary = chunks[c]
	ch["dirty"][sec] = true
	ch["srev"][sec] = int(ch["srev"].get(sec, 0)) + 1
	ch["meshed"] = false
	chunks[c] = ch


## Marks every section whose mesh could change because of one edit.
##
## That is not just the edited block's own section. A face is culled against the block
## in the neighbouring cell, and ambient occlusion samples the eight cells around the
## corner, so the whole 3x3x3 neighbourhood of cells has to be rebuilt. Across a chunk
## border and a section border that reaches the neighbouring chunk's neighbouring
## section as well, so the worst case is 2x2 chunks by 2 sections -- 8 sections -- and
## the common case is 1.
func _dirty_cells_around(pos: Vector3i) -> void:
	var seen := {}
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var y := pos.y + dy
			if y < MIN_Y or y >= MAX_Y:
				continue
			for dz in range(-1, 2):
				var key := Vector3i((pos.x + dx) >> 4, y >> 4, (pos.z + dz) >> 4)
				if seen.has(key):
					continue
				seen[key] = true
				_mark_dirty(Vector2i(key.x, key.z), key.y)


# ================================================================ raycast
## Voxel DDA. Returns {} or {pos: Vector3i, normal: Vector3i, prev: Vector3i}.
func raycast(origin: Vector3, dir: Vector3, max_dist: float, hit_liquid: bool = false) -> Dictionary:
	var x := floori(origin.x)
	var y := floori(origin.y)
	var z := floori(origin.z)
	var step := Vector3i(
		1 if dir.x > 0.0 else (-1 if dir.x < 0.0 else 0),
		1 if dir.y > 0.0 else (-1 if dir.y < 0.0 else 0),
		1 if dir.z > 0.0 else (-1 if dir.z < 0.0 else 0))
	var t_delta := Vector3(
		absf(1.0 / dir.x) if dir.x != 0.0 else 1e30,
		absf(1.0 / dir.y) if dir.y != 0.0 else 1e30,
		absf(1.0 / dir.z) if dir.z != 0.0 else 1e30)
	var t_max := Vector3(
		_bound(origin.x, x, step.x) * t_delta.x,
		_bound(origin.y, y, step.y) * t_delta.y,
		_bound(origin.z, z, step.z) * t_delta.z)
	var normal := Vector3i.ZERO
	var t := 0.0
	var guard := 0
	while t <= max_dist and guard < 400:
		guard += 1
		var id := get_block(x, y, z)
		if id != Blocks.AIR:
			var ok := true
			if Blocks.liquid[id] == 1 and not hit_liquid:
				ok = false
			if Blocks.kind[id] == Blocks.K_CROSS:
				ok = false
			if ok:
				return {"pos": Vector3i(x, y, z), "normal": normal,
					"prev": Vector3i(x, y, z) + normal}
		if t_max.x < t_max.y and t_max.x < t_max.z:
			x += step.x
			t = t_max.x
			t_max.x += t_delta.x
			normal = Vector3i(-step.x, 0, 0)
		elif t_max.y < t_max.z:
			y += step.y
			t = t_max.y
			t_max.y += t_delta.y
			normal = Vector3i(0, -step.y, 0)
		else:
			z += step.z
			t = t_max.z
			t_max.z += t_delta.z
			normal = Vector3i(0, 0, -step.z)
	return {}


func _bound(origin: float, cell: int, step: int) -> float:
	if step > 0:
		return float(cell + 1) - origin
	if step < 0:
		return origin - float(cell)
	return 1e30


# ================================================================ torch lights
func _update_lights(player_pos: Vector3) -> void:
	_light_timer -= get_process_delta_time()
	if _light_timer > 0.0:
		return
	_light_timer = 0.35
	# Two kinds of light: the blocks that always glow (torches, glowstone) and the
	# ones a circuit has switched on (lamps, a piston arm). The second set changes at
	# runtime, which is why it is a separate dictionary rather than an id lookup.
	var sources: Array = []
	for pos in torches.keys():
		sources.append(pos)
	for pos in circuit_lit.keys():
		if bool(circuit_lit[pos]) and not torches.has(pos):
			sources.append(pos)
	if sources.is_empty():
		for l in _lights:
			l.visible = false
		return
	var near: Array = []
	# 40 blocks, not 24: a torch just outside the old radius lit nothing at all, so
	# walking toward a lit area it would pop in and out rather than brighten
	for pos in sources:
		var d := Vector3(pos).distance_squared_to(player_pos)
		if d < 1600.0:
			near.append([d, pos])
	near.sort_custom(func(a, b): return a[0] < b[0])
	for i in _lights.size():
		if i < near.size():
			var p: Vector3i = near[i][1]
			_lights[i].position = Vector3(float(p.x) + 0.5, float(p.y) + 0.6, float(p.z) + 0.5)
			var id: int = get_block(p.x, p.y, p.z)
			var bright: bool = Blocks.emission[id] >= 15 or bool(circuit_lit.get(p, false))
			# a torch reaches about thirteen blocks in Minecraft, and the falloff is
			# gentle enough that the floor right under it is clearly lit
			_lights[i].omni_range = 15.0 if bright else 13.0
			_lights[i].light_energy = 4.4 if bright else 3.6
			_lights[i].visible = true
		else:
			_lights[i].visible = false


## Where anything that fell out of the world gets put back: just above the ground in
## that column, or over the sea when that ground is not loaded. Deliberately *not* the
## world ceiling, which is 320 now -- rescuing to there would drop the player for
## nearly three hundred blocks, which no survival player survives.
func rescue_y(x: int, z: int) -> float:
	return maxf(float(highest_occluder(x, z)) + 2.0, float(VoxelTerrain.SEA) + 8.0)


## Resolves a standable spot near `pos` against the actual generated blocks: solid
## ground below, two blocks of headroom, and never on top of a tree or in water.
## Used after a world finishes loading so the player can never be stranded on a
## canopy or embedded in a trunk.
func safe_spawn_near(pos: Vector3) -> Vector3:
	var bx := floori(pos.x)
	var bz := floori(pos.z)
	for radius in range(0, 10):
		var steps := maxi(1, radius * 8)
		for a in range(0, steps):
			var ang := TAU * float(a) / float(steps)
			var x := bx + int(round(cos(ang) * float(radius)))
			var z := bz + int(round(sin(ang) * float(radius)))
			var top := mini(highest_occluder(x, z), MAX_Y - 4)
			for y in range(top, 1, -1):
				var below := get_block(x, y - 1, z)
				if Blocks.solid[below] == 0:
					continue
				if below == Blocks.LEAVES or below == Blocks.LOG or below == Blocks.WATER:
					continue
				if Blocks.solid[get_block(x, y, z)] == 1:
					continue
				if Blocks.solid[get_block(x, y + 1, z)] == 1:
					continue
				return Vector3(float(x) + 0.5, float(y) + 0.02, float(z) + 0.5)
	return pos


# ================================================================ persistence
func edit_count() -> int:
	return edits.size()


func serialize_edits() -> PackedByteArray:
	var buf := PackedByteArray()
	var n := edits.size()
	buf.resize(4 + n * 13)
	buf.encode_s32(0, n)
	var i := 0
	for pos in edits.keys():
		var off := 4 + i * 13
		buf.encode_s32(off, pos.x)
		buf.encode_s32(off + 4, pos.y)
		buf.encode_s32(off + 8, pos.z)
		buf.encode_u8(off + 12, edits[pos])
		i += 1
	return buf


func load_edits(buf: PackedByteArray) -> void:
	if buf.size() < 4:
		return
	var n := buf.decode_s32(0)
	for i in n:
		var off := 4 + i * 13
		if off + 13 > buf.size():
			break
		var pos := Vector3i(buf.decode_s32(off), buf.decode_s32(off + 4), buf.decode_s32(off + 8))
		var id := buf.decode_u8(off + 12)
		edits[pos] = id
		if Blocks.emission[id] > 0:
			torches[pos] = id
		var c := Vector2i(pos.x >> 4, pos.z >> 4)
		var ebc: Dictionary = edits_by_chunk.get(c, {})
		ebc[pos] = id
		edits_by_chunk[c] = ebc


## Which way each thin panel faces is not derivable from the block ids, so it gets its
## own small file, the way circuit state does. 16 bytes an entry: pos + a signed direction.
func serialize_facing() -> PackedByteArray:
	var buf := PackedByteArray()
	var n := facing_override.size()
	buf.resize(4 + n * 16)
	buf.encode_s32(0, n)
	var i := 0
	for pos in facing_override.keys():
		var off := 4 + i * 16
		buf.encode_s32(off, pos.x)
		buf.encode_s32(off + 4, pos.y)
		buf.encode_s32(off + 8, pos.z)
		var f: Vector3i = facing_override[pos]
		buf.encode_s8(off + 12, f.x)
		buf.encode_s8(off + 13, f.y)
		buf.encode_s8(off + 14, f.z)
		i += 1
	return buf


func load_facing(buf: PackedByteArray) -> void:
	if buf.size() < 4:
		return
	var n := buf.decode_s32(0)
	for i in n:
		var off := 4 + i * 16
		if off + 16 > buf.size():
			break
		var pos := Vector3i(buf.decode_s32(off), buf.decode_s32(off + 4), buf.decode_s32(off + 8))
		facing_override[pos] = Vector3i(buf.decode_s8(off + 12), buf.decode_s8(off + 13),
			buf.decode_s8(off + 14))


## The words on each sign, in their own file the way facings are: a sign's text is not
## derivable from its block id. 77 bytes an entry: pos (12) + a one-byte length + 64 bytes
## of text. The text is clipped to 16 characters first, so a multi-byte line is never cut
## in the middle of a character.
func serialize_signs() -> PackedByteArray:
	var buf := PackedByteArray()
	var n := sign_text.size()
	buf.resize(4 + n * 77)
	buf.encode_s32(0, n)
	var i := 0
	for pos in sign_text.keys():
		var off := 4 + i * 77
		buf.encode_s32(off, pos.x)
		buf.encode_s32(off + 4, pos.y)
		buf.encode_s32(off + 8, pos.z)
		var b := str(sign_text[pos]).substr(0, 16).to_utf8_buffer()
		var ln := mini(b.size(), 64)
		buf.encode_u8(off + 12, ln)
		for k in ln:
			buf.encode_u8(off + 13 + k, b[k])
		i += 1
	return buf


func load_signs(buf: PackedByteArray) -> void:
	if buf.size() < 4:
		return
	var n := buf.decode_s32(0)
	for i in n:
		var off := 4 + i * 77
		if off + 77 > buf.size():
			break
		var pos := Vector3i(buf.decode_s32(off), buf.decode_s32(off + 4), buf.decode_s32(off + 8))
		var ln := buf.decode_u8(off + 12)
		var raw := PackedByteArray()
		for k in ln:
			raw.append(buf.decode_u8(off + 13 + k))
		sign_text[pos] = raw.get_string_from_utf8()


## A flowing fluid cell and a source hold the same block id, so the levels cannot be
## recovered from the blocks and get their own file, the way facings do. 13 bytes each.
func serialize_fluid() -> PackedByteArray:
	var buf := PackedByteArray()
	var n := fluid.size()
	buf.resize(4 + n * 13)
	buf.encode_s32(0, n)
	var i := 0
	for pos in fluid.keys():
		var off := 4 + i * 13
		buf.encode_s32(off, pos.x)
		buf.encode_s32(off + 4, pos.y)
		buf.encode_s32(off + 8, pos.z)
		buf.encode_u8(off + 12, int(fluid[pos]))
		i += 1
	return buf


func load_fluid(buf: PackedByteArray) -> void:
	if buf.size() < 4:
		return
	var n := buf.decode_s32(0)
	for i in n:
		var off := 4 + i * 13
		if off + 13 > buf.size():
			break
		var pos := Vector3i(buf.decode_s32(off), buf.decode_s32(off + 4), buf.decode_s32(off + 8))
		fluid[pos] = buf.decode_u8(off + 12)
		# queued so the sim re-settles a body of water that was flowing when it was saved
		_fluid_queue[pos] = true