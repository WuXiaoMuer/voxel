extends Node
## Chest contents and furnace state, keyed by block position. A chest is a plain array
## of 27 slots; a furnace holds an input, a fuel slot, an output and a burn/cook clock.
## Furnaces are ticked here once a frame; their lit appearance is carried by swapping
## the block id (FURNACE <-> FURNACE_LIT) without recording an edit, so the save stays
## small and an unlit furnace reloads correctly.

const CHEST_SIZE := 27
const COOK_TIME := 8.0

signal changed

var world
var player = null
var item_entities = null
var chests: Dictionary = {}     # Vector3i -> Array(27) of {id, count}
var furnaces: Dictionary = {}   # Vector3i -> {input, fuel, output, burn, burn_max, cook}


func setup(w) -> void:
	world = w


func reset() -> void:
	chests.clear()
	furnaces.clear()


# ================================================================ access
func chest_at(pos: Vector3i) -> Array:
	if not chests.has(pos):
		chests[pos] = _empty(CHEST_SIZE)
	return chests[pos]


func has_chest(pos: Vector3i) -> bool:
	return chests.has(pos)


func furnace_at(pos: Vector3i) -> Dictionary:
	if not furnaces.has(pos):
		furnaces[pos] = {"input": _cell(), "fuel": _cell(), "output": _cell(),
			"burn": 0.0, "burn_max": 0.0, "cook": 0.0}
	return furnaces[pos]


func has_furnace(pos: Vector3i) -> bool:
	return furnaces.has(pos)


## When a chest or furnace block is removed: drop its contents and forget it.
func remove(pos: Vector3i) -> void:
	if chests.has(pos):
		_spill(chests[pos], pos)
		chests.erase(pos)
	if furnaces.has(pos):
		var f: Dictionary = furnaces[pos]
		for key in ["input", "fuel", "output"]:
			_spill([f[key]], pos)
		furnaces.erase(pos)


func _spill(cells: Array, pos: Vector3i) -> void:
	if item_entities == null:
		return
	var at := Vector3(float(pos.x) + 0.5, float(pos.y) + 0.5, float(pos.z) + 0.5)
	for c in cells:
		if int(c["id"]) > 0 and int(c["count"]) > 0:
			item_entities.drop(int(c["id"]), int(c["count"]), at)


# ================================================================ furnace tick
func update(delta: float) -> void:
	if world == null or furnaces.is_empty():
		return
	for k in furnaces.keys():
		var pos: Vector3i = k
		_tick_furnace(pos, delta)


func _tick_furnace(pos: Vector3i, delta: float) -> void:
	var f: Dictionary = furnaces[pos]
	var inp: Dictionary = f["input"]
	var out: Dictionary = f["output"]
	var out_id := int(Gear.SMELTING.get(int(inp["id"]), 0))
	var can := out_id > 0 and (int(out["id"]) == 0
		or (int(out["id"]) == out_id and int(out["count"]) < 64))
	var was_lit := float(f["burn"]) > 0.0

	# feed the fire when it has gone out and there is work to do
	if float(f["burn"]) <= 0.0 and can and int(f["fuel"]["id"]) > 0:
		var burn := float(Gear.FUEL.get(int(f["fuel"]["id"]), 0.0))
		if burn > 0.0:
			f["burn"] = burn
			f["burn_max"] = burn
			_consume_one(f["fuel"])

	if float(f["burn"]) > 0.0:
		f["burn"] = float(f["burn"]) - delta

	if can and float(f["burn"]) > 0.0:
		f["cook"] = float(f["cook"]) + delta
		if float(f["cook"]) >= COOK_TIME:
			f["cook"] = 0.0
			if int(out["id"]) == 0:
				out["id"] = out_id
				out["count"] = 0
			out["count"] = int(out["count"]) + 1
			_consume_one(inp)
	else:
		f["cook"] = 0.0

	var lit := float(f["burn"]) > 0.0
	_apply_lit(pos, lit)
	if lit != was_lit:
		changed.emit()


func _consume_one(cell: Dictionary) -> void:
	cell["count"] = int(cell["count"]) - 1
	if int(cell["count"]) <= 0:
		cell["id"] = 0
		cell["count"] = 0


## Swap the block between FURNACE and FURNACE_LIT. Not recorded as an edit (record=false)
## so the lit state never grows the save, and silent so it does not feed the circuit.
func _apply_lit(pos: Vector3i, lit: bool) -> void:
	if not world.chunks.has(Vector2i(pos.x >> 4, pos.z >> 4)):
		return
	var cur: int = world.get_block(pos.x, pos.y, pos.z)
	if lit and cur == Blocks.FURNACE:
		world.set_block(pos.x, pos.y, pos.z, Blocks.FURNACE_LIT, false, true)
	elif not lit and cur == Blocks.FURNACE_LIT:
		world.set_block(pos.x, pos.y, pos.z, Blocks.FURNACE, false, true)


# ================================================================ persistence
func serialize() -> PackedByteArray:
	var body := PackedByteArray()
	var n := 0
	for k in chests.keys():
		var arr: Array = chests[k]
		if not _has_items(arr):
			continue
		body.append(0)
		body.append_array(_s32(k.x))
		body.append_array(_s32(k.y))
		body.append_array(_s32(k.z))
		body.append(CHEST_SIZE)
		for c in arr:
			body.append_array(_cell_bytes(c))
		n += 1
	for k2 in furnaces.keys():
		var f: Dictionary = furnaces[k2]
		body.append(1)
		body.append_array(_s32(k2.x))
		body.append_array(_s32(k2.y))
		body.append_array(_s32(k2.z))
		for key in ["input", "fuel", "output"]:
			body.append_array(_cell_bytes(f[key]))
		body.append_array(_f32(float(f["burn"])))
		body.append_array(_f32(float(f["cook"])))
		n += 1
	var out := PackedByteArray()
	out.append_array("VCB1".to_ascii_buffer())
	out.append_array(_s32(n))
	out.append_array(body)
	return out


func load_state(buf: PackedByteArray) -> void:
	if buf.size() < 8:
		return
	if buf.slice(0, 4).get_string_from_ascii() != "VCB1":
		return
	chests.clear()
	furnaces.clear()
	var n := buf.decode_s32(4)
	var off := 8
	for i in n:
		if off + 13 > buf.size():
			break
		var t := buf.decode_u8(off)
		off += 1
		var pos := Vector3i(buf.decode_s32(off), buf.decode_s32(off + 4), buf.decode_s32(off + 8))
		off += 12
		if t == 0:
			var cnt := buf.decode_u8(off)
			off += 1
			var arr: Array = []
			for j in cnt:
				arr.append(_read_cell(buf, off))
				off += 4
			chests[pos] = arr
		elif t == 1:
			var inp := _read_cell(buf, off)
			off += 4
			var fu := _read_cell(buf, off)
			off += 4
			var ou := _read_cell(buf, off)
			off += 4
			var burn := buf.decode_float(off)
			off += 4
			var cook := buf.decode_float(off)
			off += 4
			furnaces[pos] = {"input": inp, "fuel": fu, "output": ou,
				"burn": burn, "burn_max": burn, "cook": cook}


## Drop any record whose block is no longer a chest or furnace (the block was removed
## before this file was written, or the world was edited between saves).
func prune() -> void:
	if world == null:
		return
	for k in chests.keys():
		if world.get_block(k.x, k.y, k.z) != Blocks.CHEST:
			chests.erase(k)
	for k2 in furnaces.keys():
		var id: int = world.get_block(k2.x, k2.y, k2.z)
		if id != Blocks.FURNACE and id != Blocks.FURNACE_LIT:
			furnaces.erase(k2)


func _has_items(arr: Array) -> bool:
	for c in arr:
		if int(c["id"]) > 0:
			return true
	return false


func _cell() -> Dictionary:
	return {"id": 0, "count": 0}


func _empty(n: int) -> Array:
	var a: Array = []
	for i in n:
		a.append(_cell())
	return a


func _cell_bytes(c: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u16(0, int(c["id"]))
	b.encode_u16(2, int(c["count"]))
	return b


func _read_cell(buf: PackedByteArray, off: int) -> Dictionary:
	return {"id": buf.decode_u16(off), "count": buf.decode_u16(off + 2)}


func _s32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_s32(0, v)
	return b


func _f32(v: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return b