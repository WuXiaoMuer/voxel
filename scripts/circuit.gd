extends Node
## The power layer: a signal-propagation solver for the electrical blocks.
##
## Everything here is modelled on real electronics, deliberately:
##
##   switch / button / pressure plate / battery  ->  a supply (a knife switch, a
##                                                   momentary switch, a sensor and
##                                                   a cell that is always live)
##   wire                                        ->  a conductor: it carries a level
##                                                   0..15 and loses 1 per block,
##                                                   exactly like resistive loss down
##                                                   a line
##   inverter                                    ->  a NOT gate
##   relay                                       ->  a diode with a propagation
##                                                   delay: signal flows one way only,
##                                                   after N ticks, re-driven at full
##                                                   strength
##   lamp                                        ->  an indicator (an LED)
##   piston                                      ->  an actuator (a solenoid)
##
## A solid block that sits next to a live wire becomes *charged*, which is how a lamp
## or an inverter placed on top of it gets its supply -- the same role a copper pad
## plays on a real board. Charged blocks do not carry the signal any further, which
## is what keeps a circuit from shorting through the ground.
##
## The solver is a fixed-point iteration: build the network, push power out from the
## supplies, update every component from the result, and repeat if any component
## changed state (an inverter turning off can change the network it is part of). It is
## capped at MAX_PASSES so an oscillator settles into a visible blink instead of
## hanging the game.

## Longest a wire run can be before the signal dies out entirely.
const MAX_LEVEL := 15
## The solver's tick. Components with a delay count these down.
const TICK := 0.1
## Propagation delay of a relay, in ticks.
const RELAY_DELAY := 2
## How long a button stays down, in seconds.
const BUTTON_TIME := 1.5
## How long a pressure plate stays down after the last frame something stood on it.
const PLATE_LEASE := 0.2
## Cap on the fixed-point iteration, so a feedback loop blinks rather than hangs.
const MAX_PASSES := 8
## How far a network may spread from where it was touched.
const MAX_RADIUS := 48

var world

## Computed signal level per position, 0..15. Rebuilt from scratch on every solve.
var power: Dictionary = {}
## Persistent per-block state: switch on/off, button timer, relay delay,
## piston extended, and the facing of every directional component.
var state: Dictionary = {}
## Positions whose block is a circuit part, so a solve can find them quickly.
var nodes: Dictionary = {}

var _dirty: Dictionary = {}
var _pending := false


func setup(w) -> void:
	world = w


# ================================================================ classification
func is_source(id: int) -> bool:
	return id == Blocks.SWITCH or id == Blocks.BUTTON or id == Blocks.PRESSURE_PLATE \
		or id == Blocks.BATTERY or id == Blocks.INVERTER


func is_consumer(id: int) -> bool:
	return id == Blocks.LAMP or id == Blocks.PISTON


func is_wire(id: int) -> bool:
	return id == Blocks.WIRE


func is_circuit(id: int) -> bool:
	return is_source(id) or is_consumer(id) or is_wire(id) or id == Blocks.RELAY


## Blocks that can become charged by a neighbouring wire. Anything that hides the
## face of its neighbour is solid enough to act as a conductor.
func conducts(id: int) -> bool:
	return id > 0 and id < 256 and Blocks.occluder[id] == 1 \
		and not is_circuit(id)


## Components that need to remember which way they point.
func is_directional(id: int) -> bool:
	return id == Blocks.PISTON or id == Blocks.RELAY


# ================================================================ state
func default_state(id: int, facing: Vector3i = Vector3i(0, 0, 1)) -> Dictionary:
	return {
		"on": false,          # switch / button / plate
		"timer": 0.0,         # button auto-release, plate lease
		"delay": 0.0,         # relay: seconds left before it re-drives
		"target": 0,          # relay: the level it is counting toward
		"extended": false,    # piston
		"facing": facing,     # piston / relay
		"lit": id == Blocks.INVERTER,   # an inverter starts lit, with no input
	}


func get_state(pos: Vector3i) -> Dictionary:
	return state.get(pos, {})


## Records a circuit block. Called when one is placed, and when a chunk is meshed
## from a save.
func register(pos: Vector3i, id: int, facing: Vector3i = Vector3i(0, 0, 1)) -> void:
	if not is_circuit(id):
		return
	nodes[pos] = id
	if not state.has(pos):
		state[pos] = default_state(id, facing)
	mark(pos)


func unregister(pos: Vector3i) -> void:
	nodes.erase(pos)
	state.erase(pos)
	power.erase(pos)
	mark(pos)


## Queues a re-solve around a position. Never solves inline: a solve can place
## blocks (a piston extends), which would otherwise recurse.
func mark(pos: Vector3i) -> void:
	_dirty[pos] = true
	_pending = true


func has_pending() -> bool:
	return _pending


## Solves every queued region. Called once per frame by main; the work itself only
## happens when something actually changed.
func update(delta: float) -> void:
	_tick_timers(delta)
	if not _pending:
		return
	var seeds: Array = _dirty.keys()
	_dirty.clear()
	_pending = false
	for s in seeds:
		solve(s)


# ================================================================ solving
## Recomputes the network reachable from `seed` and applies the result.
func solve(seed: Vector3i) -> void:
	var net := _collect(seed)
	if net.is_empty():
		return
	for pass_i in MAX_PASSES:
		var before := _snapshot_states(net)
		_propagate(net)
		_apply_components(net)
		if _snapshot_states(net) == before:
			break


## Every circuit part connected to `seed`, plus the solid blocks that a wire in the
## network touches (they can be charged, and components sitting on them read that).
func _collect(seed: Vector3i) -> Dictionary:
	var found: Dictionary = {}
	if not nodes.has(seed):
		# the seed may be a block that was just removed, or plain ground next to a
		# circuit; look at its neighbours instead
		for d in _NEIGHBOURS6:
			if nodes.has(seed + d):
				found[seed + d] = true
	else:
		found[seed] = true
	if found.is_empty():
		return {}

	var queue: Array = found.keys()
	var head := 0
	var conductors: Dictionary = {}
	while head < queue.size():
		var p: Vector3i = queue[head]
		head += 1
		if (p - seed).length() > MAX_RADIUS:
			continue
		var id: int = int(nodes.get(p, Blocks.AIR))
		if id == Blocks.AIR:
			continue
		for d in _NEIGHBOURS6:
			var q: Vector3i = p + d
			if found.has(q):
				continue
			var nid: int = int(nodes.get(q, 0))
			if nid == 0:
				# a neighbour that is not a circuit part: a wire charges the solid
				# block it touches, and a component reads the block it is attached to
				var bid: int = world.get_block(q.x, q.y, q.z)
				if conducts(bid):
					conductors[q] = true
				continue
			found[q] = true
			queue.append(q)
	var out := {"circuits": found, "conductors": conductors}
	return out


func _snapshot_states(net: Dictionary) -> String:
	var parts: Array = []
	for p in net["circuits"]:
		var s: Dictionary = state.get(p, {})
		parts.append("%s:%s:%s:%s" % [str(p), str(s.get("on", false)),
			str(s.get("lit", false)), str(s.get("extended", false))])
	parts.sort()
	return "|".join(parts)


## Pushes power out from every source, then lets wires decay it.
##
## Two phases on purpose. First the sources and the solid blocks they charge, then
## the wires. Doing it in one pass would let a wire that is about to be switched off
## feed a block that feeds the wire that switches it off, and the answer would
## depend on dictionary order.
func _propagate(net: Dictionary) -> void:
	var circuits: Dictionary = net["circuits"]
	var conductors: Dictionary = net["conductors"]
	# Clear only this network. `update` solves several seeds in a row, and a global
	# wipe would throw away the levels the previous seed's (unrelated) network had
	# just computed.
	for p in circuits:
		power.erase(p)
	for p in conductors:
		power.erase(p)

	# --- phase 1a: the plain supplies drive their own cell at full level. An inverter
	# is deliberately left out: it has to read an input, so it must come after the
	# supplies it might be reading from are already live.
	var frontier: Array = []
	for p in circuits:
		var id: int = int(nodes[p])
		if id == Blocks.INVERTER:
			continue
		if id == Blocks.BATTERY:
			# a cell, not a switch: it is always live
			power[p] = MAX_LEVEL
			frontier.append(p)
		elif is_source(id):
			var st: Dictionary = state.get(p, {})
			if bool(st.get("on", false)):
				power[p] = MAX_LEVEL
				frontier.append(p)
	if not frontier.is_empty():
		_charge_conductors(frontier, net, conductors)

	# --- phase 1b: now every inverter can read its input and decide
	var inverters: Array = []
	for p in circuits:
		if int(nodes[p]) != Blocks.INVERTER:
			continue
		# an inverter: it drives its own cell only while its input is dead
		var below: Vector3i = p + Vector3i(0, -1, 0)
		var s: Dictionary = state.get(p, {})
		s["lit"] = _input_level(p, net, below) == 0
		state[p] = s
		if bool(s["lit"]):
			power[p] = MAX_LEVEL
			inverters.append(p)
	if not inverters.is_empty():
		_charge_conductors(inverters, net, conductors)

	# --- phase 2: wires carry the signal, losing 1 per block
	var wires: Array = []
	for p in circuits:
		if is_wire(int(nodes[p])):
			wires.append(p)
	var changed := true
	var guard := 0
	while changed and guard < MAX_LEVEL + 2:
		changed = false
		guard += 1
		for p in wires:
			var best := 0
			for d in _NEIGHBOURS6:
				var q: Vector3i = p + d
				var lvl: int = int(power.get(q, 0))
				if lvl <= 0:
					continue
				var qid: int = int(nodes.get(q, 0))
				# A plain solid block never drives a wire, even when a wire has
				# charged it. Otherwise the pad under one wire would feed the next
				# wire at full strength and a line would never decay -- a short
				# through the ground. Only a wire (losing a level per block) or a
				# component's own output can drive one.
				if qid == 0:
					continue
				var here: int = lvl - 1 if is_wire(qid) else lvl
				best = maxi(best, here)
			if best > int(power.get(p, 0)):
				power[p] = best
				changed = true
		# a wire's level also charges whatever solid block it touches
		if changed:
			_charge_conductors(wires, net, conductors)

	# --- a relay is a diode: input behind, output in front, after a delay
	for p in circuits:
		if int(nodes[p]) != Blocks.RELAY:
			continue
		var st2: Dictionary = state.get(p, {})
		var facing: Vector3i = st2.get("facing", Vector3i(0, 0, 1))
		var back: Vector3i = p - facing
		var front: Vector3i = p + facing
		var driven: int = int(power.get(back, 0))
		if driven <= 0:
			driven = _conductor_level(back)
		var lvl2 := MAX_LEVEL if driven > 0 else 0
		if lvl2 != int(st2.get("target", 0)):
			# The input changed: start (or restart) the propagation delay. The
			# output keeps its old value until the delay has run out -- that gap
			# is the whole point of a relay.
			st2["target"] = lvl2
			if float(st2.get("delay", 0.0)) <= 0.0:
				st2["delay"] = RELAY_DELAY * TICK
			state[p] = st2
		power[p] = int(st2.get("out", 0))
		# a relay re-drives its output at full strength, whatever came in
		if power[p] > 0 and (circuits.has(front) or conductors.has(front)):
			power[front] = maxi(int(power.get(front, 0)), int(power[p]))


## A solid block next to a live wire becomes charged at that wire's level. It does
## not decay and does not propagate any further.
func _charge_conductors(from: Array, net: Dictionary, conductors: Dictionary) -> void:
	for p in from:
		var lvl: int = int(power.get(p, 0))
		if lvl <= 0:
			continue
		for d in _NEIGHBOURS6:
			var q: Vector3i = p + d
			if conductors.has(q):
				power[q] = maxi(int(power.get(q, 0)), lvl)


func _conductor_level(pos: Vector3i) -> int:
	return int(power.get(pos, 0))


## The signal arriving at a component from outside itself.
func _input_level(pos: Vector3i, net: Dictionary, also: Vector3i) -> int:
	var best := int(power.get(also, 0))
	for d in _NEIGHBOURS6:
		var q: Vector3i = pos + d
		if q == also:
			continue
		var qid: int = int(nodes.get(q, 0))
		# only a wire or another component's output can drive this cell; a solid
		# block drives it only through its own charged level
		if qid == 0 or is_wire(qid) or is_source(qid) or qid == Blocks.RELAY:
			best = maxi(best, int(power.get(q, 0)))
		if best >= MAX_LEVEL:
			break
	return best


## Reads the level a component sees: its own cell, the block it sits on, or a
## component that drives straight into it from a neighbouring cell.
##
## A wire is the exception: its level *is* the signal it carries, so asking what a
## wire "sees" would just echo its own neighbour back at full strength and erase the
## decay.
func level_at(pos: Vector3i) -> int:
	if is_wire(int(nodes.get(pos, 0))):
		return int(power.get(pos, 0))
	var best: int = int(power.get(pos, 0))
	var below: Vector3i = pos + Vector3i(0, -1, 0)
	if conducts(world.get_block(below.x, below.y, below.z)):
		best = maxi(best, int(power.get(below, 0)))
	for d in _NEIGHBOURS6:
		var q: Vector3i = pos + d
		var qid: int = int(nodes.get(q, 0))
		if is_wire(qid) or is_source(qid) or qid == Blocks.RELAY:
			best = maxi(best, int(power.get(q, 0)))
		if best >= MAX_LEVEL:
			break
	return best


# ================================================================ components
func _apply_components(net: Dictionary) -> void:
	for p in net["circuits"]:
		var id: int = int(nodes[p])
		match id:
			Blocks.LAMP:
				var on := level_at(p) > 0
				if world.get_block(p.x, p.y, p.z) == Blocks.LAMP and on:
					world.set_block(p.x, p.y, p.z, Blocks.LAMP, true, true)
				# the lit lamp is the same block with a different tile, so the
				# visual state lives in the tile swap rather than in a second id
				_tile_swap(p, Blocks.LAMP, Blocks.T_LAMP_ON if on else Blocks.T_LAMP_OFF)
				world.circuit_lit[p] = on
			Blocks.PISTON:
				_apply_piston(p, level_at(p) > 0)
			Blocks.INVERTER:
				_tile_swap(p, Blocks.INVERTER,
					Blocks.T_INV_ON if bool(state.get(p, {}).get("lit", true)) \
					else Blocks.T_INV_OFF)
			Blocks.RELAY:
				var s: Dictionary = state.get(p, {})
				var powered: bool = int(s.get("out", 0)) > 0
				_tile_swap(p, Blocks.RELAY,
					Blocks.T_RELAY_ON if powered else Blocks.T_RELAY_OFF)
			Blocks.SWITCH:
				var st: Dictionary = state.get(p, {})
				_tile_swap(p, Blocks.SWITCH,
					Blocks.T_SWITCH_ON if bool(st.get("on", false)) else Blocks.T_SWITCH_OFF)
			Blocks.BUTTON:
				var st2: Dictionary = state.get(p, {})
				_tile_swap(p, Blocks.BUTTON,
					Blocks.T_BUTTON_ON if bool(st2.get("on", false)) else Blocks.T_BUTTON_OFF)
			Blocks.PRESSURE_PLATE:
				var st3: Dictionary = state.get(p, {})
				_tile_swap(p, Blocks.PRESSURE_PLATE,
					Blocks.T_PLATE_ON if bool(st3.get("on", false)) else Blocks.T_PLATE_OFF)
			Blocks.WIRE:
				_tile_swap(p, Blocks.WIRE,
					Blocks.T_WIRE_ON if int(power.get(p, 0)) > 0 else Blocks.T_WIRE_OFF)


## Swaps a block's rendered tile without touching the world data. Circuit blocks
## are one block id with two faces (off/on), not two ids, so a switch does not stop
## being a switch when you flip it.
func _tile_swap(pos: Vector3i, id: int, tile: int) -> void:
	if world.get_block(pos.x, pos.y, pos.z) != id:
		return
	if world.tile_override.get(pos, -1) == tile:
		return
	world.tile_override[pos] = tile
	world._mark_dirty(Vector2i(pos.x >> 4, pos.z >> 4), pos.y >> 4)


## A piston pushes the block in front of it one cell forward when it is powered, and
## pulls it back when it is released. The pushed block is remembered so the retract
## can put it back where it came from.
func _apply_piston(pos: Vector3i, powered: bool) -> void:
	var st: Dictionary = state.get(pos, {})
	var extended: bool = bool(st.get("extended", false))
	if powered == extended:
		return
	var facing: Vector3i = st.get("facing", Vector3i(0, 0, 1))
	var front: Vector3i = pos + facing
	var beyond: Vector3i = front + facing
	if powered:
		var pushed: int = world.get_block(front.x, front.y, front.z)
		# only a single movable block is pushed, and only into empty space
		if world.get_block(beyond.x, beyond.y, beyond.z) != Blocks.AIR:
			return
		if pushed != Blocks.AIR and not _movable(pushed):
			return
		if pushed != Blocks.AIR:
			world.set_block(front.x, front.y, front.z, Blocks.AIR, false, true)
			world.set_block(beyond.x, beyond.y, beyond.z, pushed, false, true)
			st["pushed"] = pushed
		# the arm itself occupies the cell in front
		world.set_block(front.x, front.y, front.z, Blocks.PISTON, false, true)
		world.circuit_lit[front] = true
		st["extended"] = true
	else:
		if world.get_block(front.x, front.y, front.z) == Blocks.PISTON:
			world.set_block(front.x, front.y, front.z, Blocks.AIR, false, true)
		var pushed2: int = int(st.get("pushed", 0))
		if pushed2 != 0 and world.get_block(beyond.x, beyond.y, beyond.z) == pushed2:
			world.set_block(beyond.x, beyond.y, beyond.z, Blocks.AIR, false, true)
			world.set_block(front.x, front.y, front.z, pushed2, false, true)
		st["pushed"] = 0
		st["extended"] = false
	state[pos] = st


## What a piston is allowed to shove. Bedrock and other circuit parts are bolted
## down; everything else moves.
func _movable(id: int) -> bool:
	if id == Blocks.AIR or id == Blocks.BEDROCK:
		return false
	if is_circuit(id):
		return false
	return true


# ================================================================ timers
## Buttons spring back on their own, relays count their delay down, and pressure
## plates are re-read from whoever is standing on them.
func _tick_timers(delta: float) -> void:
	for p in state.keys():
		var id: int = int(nodes.get(p, 0))
		var st: Dictionary = state[p]
		if id == Blocks.BUTTON and bool(st.get("on", false)):
			st["timer"] = float(st.get("timer", 0.0)) - delta
			if float(st["timer"]) <= 0.0:
				st["on"] = false
				mark(p)
		elif id == Blocks.RELAY and float(st.get("delay", 0.0)) > 0.0:
			st["delay"] = float(st["delay"]) - delta
			if float(st["delay"]) <= 0.0:
				st["delay"] = 0.0
				st["out"] = int(st.get("target", 0))
				mark(p)
		elif id == Blocks.PRESSURE_PLATE and bool(st.get("on", false)):
			# the player re-asserts the plate every physics frame while standing on
			# it, so this is a short lease rather than a latch: step off and the
			# signal drops by itself, with no need to hunt for "what left the plate"
			st["timer"] = float(st.get("timer", 0.0)) - delta
			if float(st["timer"]) <= 0.0:
				st["on"] = false
				mark(p)


## A plate is a sensor: it reports whatever is standing on it.
func set_plate(pos: Vector3i, pressed: bool) -> void:
	var st: Dictionary = state.get(pos, {})
	if pressed:
		# refreshed every frame while occupied; the lease is a few frames long
		st["timer"] = PLATE_LEASE
		if not bool(st.get("on", false)):
			st["on"] = true
			state[pos] = st
			mark(pos)
		else:
			state[pos] = st
		return
	if bool(st.get("on", false)):
		st["on"] = false
		state[pos] = st
		mark(pos)


# ================================================================ interaction
## Called when a player right-clicks a circuit block. Returns true when the click
## was consumed, so it does not also place a block.
func interact(pos: Vector3i, id: int) -> bool:
	match id:
		Blocks.SWITCH:
			var st: Dictionary = state.get(pos, {})
			st["on"] = not bool(st.get("on", false))
			state[pos] = st
			mark(pos)
			return true
		Blocks.BUTTON:
			var st2: Dictionary = state.get(pos, {})
			st2["on"] = true
			st2["timer"] = BUTTON_TIME
			state[pos] = st2
			mark(pos)
			return true
		Blocks.RELAY:
			# right-clicking a relay nudges its facing, so a diode can be aimed
			# without breaking and replacing it
			var st3: Dictionary = state.get(pos, {})
			st3["facing"] = _next_facing(st3.get("facing", Vector3i(0, 0, 1)))
			state[pos] = st3
			mark(pos)
			return true
	return false


func _next_facing(f: Vector3i) -> Vector3i:
	var i := _NEIGHBOURS4.find(f)
	return _NEIGHBOURS4[(i + 1) % _NEIGHBOURS4.size()]


## Which way a freshly placed component points: away from the player, on the
## horizontal plane, the way Minecraft does it.
func facing_from_look(look: Vector3) -> Vector3i:
	var ax := absf(look.x)
	var az := absf(look.z)
	if ax >= az:
		return Vector3i(1 if look.x > 0.0 else -1, 0, 0)
	return Vector3i(0, 0, 1 if look.z > 0.0 else -1)


# ================================================================ persistence
func serialize() -> PackedByteArray:
	var buf := PackedByteArray()
	var entries: Array = []
	for p in state.keys():
		var id: int = int(nodes.get(p, 0))
		if id == 0:
			continue
		entries.append([p, id])
	buf.resize(4 + entries.size() * 22)
	buf.encode_s32(0, entries.size())
	var i := 0
	for e in entries:
		var p: Vector3i = e[0]
		var st: Dictionary = state[p]
		var f: Vector3i = st.get("facing", Vector3i(0, 0, 1))
		var off := 4 + i * 22
		buf.encode_s32(off, p.x)
		buf.encode_s32(off + 4, p.y)
		buf.encode_s32(off + 8, p.z)
		buf.encode_u8(off + 12, int(e[1]))
		buf.encode_u8(off + 13, 1 if bool(st.get("on", false)) else 0)
		buf.encode_u8(off + 14, 1 if bool(st.get("extended", false)) else 0)
		buf.encode_u8(off + 15, int(st.get("out", 0)))
		buf.encode_s8(off + 16, f.x)
		buf.encode_s8(off + 17, f.y)
		buf.encode_s8(off + 18, f.z)
		buf.encode_u8(off + 19, int(st.get("pushed", 0)))
		buf.encode_u16(off + 20, 0)
		i += 1
	return buf


func load_state(buf: PackedByteArray) -> void:
	if buf.size() < 4:
		return
	var n := buf.decode_s32(0)
	for i in n:
		var off := 4 + i * 22
		if off + 22 > buf.size():
			break
		var p := Vector3i(buf.decode_s32(off), buf.decode_s32(off + 4), buf.decode_s32(off + 8))
		var id := buf.decode_u8(off + 12)
		nodes[p] = id
		state[p] = {
			"on": buf.decode_u8(off + 13) == 1,
			"extended": buf.decode_u8(off + 14) == 1,
			"out": buf.decode_u8(off + 15),
			"facing": Vector3i(buf.decode_s8(off + 16), buf.decode_s8(off + 17),
				buf.decode_s8(off + 18)),
			"pushed": buf.decode_u8(off + 19),
			"timer": 0.0,
			"delay": 0.0,
			"target": buf.decode_u8(off + 15),
			"lit": true,
		}
		mark(p)


func clear() -> void:
	power.clear()
	state.clear()
	nodes.clear()
	_dirty.clear()
	_pending = false


const _NEIGHBOURS6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const _NEIGHBOURS4 := [Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(-1, 0, 0),
	Vector3i(0, 0, -1)]
