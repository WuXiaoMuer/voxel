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
## pos -> bool, the lit state of lamps and piston arms, read when placing lights.
var circuit_lit: Dictionary = {}

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
	# One job per worker thread, so the pool is never the bottleneck. Capped because
	# every in-flight job holds its section's vertex buffers until it lands.
	max_jobs = clampi(OS.get_processor_count() - 1, 6, 32)
	# Half the pool generates, the rest keeps meshing. Meshing has to keep up with
	# generation or a chunk appears with no mesh on it, and it is the cheaper of the two:
	# a column costs ~110ms while a section costs a few.
	max_gen_jobs = clampi(OS.get_processor_count() / 2, 2, 8)
	ensure_circuit()
	# Guarded rather than unconditional: `setup` runs again on every world load, and
	# without this the light pool grew by 14 nodes per load and the old ones were
	# never freed.
	if _lights.is_empty():
		for i in 14:
			var l := OmniLight3D.new()
			l.light_energy = 3.4
			l.light_color = Color(1.0, 0.80, 0.52)
			l.omni_range = 9.5
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
	circuit_lit.clear()
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
		for key in ["solid", "trans"]:
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


func is_liquid(x: int, y: int, z: int) -> bool:
	return Blocks.liquid[get_block(x, y, z)] == 1


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

var authority = null


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
	if id == Blocks.AIR and Blocks.kind[get_block(x, y + 1, z)] == Blocks.K_CROSS:
		apply_edit(Vector3i(x, y + 1, z), Blocks.AIR, record, silent)

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


## Set by the player just before placing, so the world knows which way the placer
## was looking without holding a reference to the player.
var _place_look := Vector3.ZERO


func set_place_look(dir: Vector3) -> void:
	_place_look = dir


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
		"trans": Buf.new(), "cross": Buf.new(), "flat": Buf.new(),
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
		"srev": int(chunks[c]["srev"].get(sec, 0)), "tiles": _local_tiles(c, sec)}


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
	var bufs := [Buf.new(), Buf.new(), Buf.new(), Buf.new(), Buf.new()]
	var tiles: Dictionary = p["tiles"]
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
				var buf: Buf = bufs[k]
				var lpos := Vector3(lx, ly, lz)
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
		"trans": bufs[2], "cross": bufs[3], "flat": bufs[4],
		"srev": int(p.get("srev", 0))})
	_mutex.unlock()


## `Blocks.tile_rect` reached through the autoload is an `Object::callp` in the innermost
## loop of the mesher -- once per face, so six times per solid cell. Same table, read
## straight out of a held reference instead.
func _tile_rect(t: int) -> Rect2:
	return _t_tile_uv[clampi(t, 0, _t_tile_uv.size() - 1)]


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
		pair = {"solid": null, "trans": null}
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
	for pos in sources:
		var d := Vector3(pos).distance_squared_to(player_pos)
		if d < 576.0:
			near.append([d, pos])
	near.sort_custom(func(a, b): return a[0] < b[0])
	for i in _lights.size():
		if i < near.size():
			var p: Vector3i = near[i][1]
			_lights[i].position = Vector3(float(p.x) + 0.5, float(p.y) + 0.6, float(p.z) + 0.5)
			var id: int = get_block(p.x, p.y, p.z)
			var bright: bool = Blocks.emission[id] >= 15 or bool(circuit_lit.get(p, false))
			_lights[i].omni_range = 12.0 if bright else 9.5
			_lights[i].light_energy = 4.6 if bright else 3.4
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