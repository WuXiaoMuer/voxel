extends Node3D
## Spawns, updates and despawns mobs around the player. Passive animals wander by day
## and night; hostile mobs hunt at night (and in the dark), then burn away in daylight.

const MAX_PASSIVE := 14
const MAX_HOSTILE := 10
## Villagers are counted apart from the animals: a village keeps its own little crowd,
## and those must not eat into the wildlife budget.
const MAX_VILLAGERS := 8
## Wolves are their own small population: they live in the woods, not on the farm.
const MAX_WOLVES := 5
## A village keeps a guard or two, and there is never more than one trader about.
const MAX_GOLEMS := 2
const MAX_TRADERS := 1
## The species that can be bred by feeding them, and the two adults a pair needs.
const BREEDABLE := ["pig", "cow", "sheep", "chicken"]
const SPAWN_MIN := 18.0
const SPAWN_MAX := 44.0
const DESPAWN := 96.0
const PASSIVE := ["pig", "pig", "sheep", "cow", "chicken"]
const HOSTILE := ["zombie", "zombie", "skeleton", "spider", "creeper", "slime",
	"enderman"]
## The nether's own roster. The surface's HOSTILE list holds no pigman or blaze, and this
## one holds no overworld mob: each dimension rolls only what belongs to it, so a nether
## mob can never walk out onto the grass at dusk and a zombie never turns up in the lava.
const NETHER := ["pigman", "pigman", "blaze"]
## A villager's trade, picked from where it stands rather than from anything stored, so
## the same village always has the same shopkeepers without a save file.
const PROFESSIONS := ["Farmer", "Butcher", "Smith", "Mason"]
## How close a village centre has to be for villagers to be spawned around the player.
const VILLAGE_REACH := 100

signal mob_died(kind: String, pos: Vector3)
signal exploded(pos: Vector3, radius: float)
## A villager was right-clicked. main listens and opens the trade screen.
signal villager_used(mob)

var world
var player = null
var particles = null
var projectiles = null
var mobs: Array = []
var _timer := 1.5
var _script := preload("res://scripts/mob.gd")
## Names every mob the host spawns, so a spawn / death / hit event can point at one body
## on the other machines. Only the host ever hands these out.
var _next_net_id := 1


func setup(w) -> void:
	world = w


func reset() -> void:
	for m in mobs:
		if is_instance_valid(m):
			m.queue_free()
	mobs.clear()
	_timer = 1.5


func count() -> int:
	return mobs.size()


func count_hostile() -> int:
	var n := 0
	for m in mobs:
		if is_instance_valid(m) and m.is_hostile():
			n += 1
	return n


## Build one mob, wire it up and add it to the world. Everything that spawns a mob goes
## through here, so the signals, the manager back-reference and the villager trade are
## never missed on one path and forgotten on another.
func _spawn(kind: String, pos: Vector3):
	var m = _script.new()
	add_child(m)
	m.setup(world, kind, pos)
	if kind == "villager":
		m.profession = _profession_at(pos)
	elif kind == "wandering_trader":
		# one trade, wherever it happens to be standing
		m.profession = "Trader"
	m.player = player
	m.particles = particles
	m.manager = self
	m.died.connect(_on_mob_died)
	m.fired.connect(_on_mob_fired)
	m.exploded.connect(_on_mob_exploded)
	m.used.connect(_on_mob_used)
	m.net_id = _next_net_id
	_next_net_id += 1
	mobs.append(m)
	# tell the clients a mob appeared, so they can show the same body. Guarded inside,
	# so single player and the client side of it pay nothing.
	if _net_is_host():
		Net.announce_mob_spawn(int(m.net_id), kind, pos)
	return m


## Spawn a specific mob at a spot (used by the preview pass and the tests).
func spawn_at(kind: String, pos: Vector3):
	return _spawn(kind, pos)


## Whether this machine owns the mob population -- and therefore makes the spawning
## decisions. True in single player and on the host; false for a client, which only
## draws the bodies it is told about. This is the one gate the whole spawner sits behind.
func local_spawning_enabled() -> bool:
	return not Net.is_active() or Net.role == Net.Role.HOST


func _net_is_host() -> bool:
	return Net.is_active() and Net.role == Net.Role.HOST


## The host telling us one of its mobs took a hit.
func report_hurt(m) -> void:
	if _net_is_host():
		Net.announce_mob_hurt(int(m.net_id))


## The host telling us one of its mobs died.
func report_died(m) -> void:
	if _net_is_host():
		Net.announce_mob_died(int(m.net_id))


## The mob with this net id, or null. Replication addresses mobs by id, not by identity.
func mob_with_id(net_id: int):
	for m in mobs:
		if is_instance_valid(m) and int(m.net_id) == net_id:
			return m
	return null


## The host spawned a mob: build a body for it here. It runs no AI and drops nothing --
## that is the host's business -- so it is a remote mob.
func replicate_spawn(net_id: int, kind: String, pos: Vector3):
	var existing = mob_with_id(net_id)
	if existing != null:
		return existing
	var m = _spawn(kind, pos)
	m.remote = true
	m.net_id = net_id
	return m


## The host killed a mob: take the body away. The drop is the host's, so nothing falls
## here, and the death is not re-reported.
func replicate_died(net_id: int) -> void:
	for i in range(mobs.size() - 1, -1, -1):
		var m = mobs[i]
		if is_instance_valid(m) and int(m.net_id) == net_id:
			m.queue_free()
			mobs.remove_at(i)


## The host hit a mob: flash the body so the hit is visible here.
func replicate_hurt(net_id: int) -> void:
	var m = mob_with_id(net_id)
	if m != null:
		m._hurt_t = 0.28
		m._flash()


## Which trade a villager standing at `pos` keeps. Read off the column it stands in, so
## it survives the mob being despawned and spawned again elsewhere in the same village.
func _profession_at(pos: Vector3) -> String:
	var h := absi(floori(pos.x) * 31 + floori(pos.z) * 17)
	return PROFESSIONS[h % PROFESSIONS.size()]


func update(player_pos: Vector3, delta: float, night: bool = false) -> void:
	if world == null:
		return
	var alive: Array = []
	for m in mobs:
		if not is_instance_valid(m):
			continue
		# a remote body is only drawn here: it runs no AI, it never despawns on our
		# distance, it only keeps its hit flash ticking down
		if m.remote:
			m.tick_remote(delta)
			alive.append(m)
			continue
		if not m.tamed and m.global_position.distance_to(player_pos) > DESPAWN:
			m.queue_free()
			continue
		_tick_environment(m, delta, night)
		m.tick(delta, player_pos)
		alive.append(m)
	mobs = alive
	_tick_breeding(delta)

	_timer -= delta
	if _timer <= 0.0:
		_timer = randf_range(1.2, 3.0)
		# the spawner is the host's (or single player's) alone. A client never rolls a
		# mob of its own -- it only ever shows the bodies the host hands it.
		if not local_spawning_enabled():
			return
		if _count_kind(false) < MAX_PASSIVE:
			_try_spawn(player_pos, false)
		# hostiles only appear at night, or deep underground where it is dark anyway
		if night and _count_kind(true) < MAX_HOSTILE:
			_try_spawn(player_pos, true)
		# villagers are tied to a village rather than to the wild, so they get their own
		# spawner. Rolled rather than forced so the walk into a village fills in over a
		# few seconds instead of appearing all at once.
		if _count_of("villager") < MAX_VILLAGERS and randf() < 0.5:
			_try_spawn_at_village(player_pos, "villager")
		# a village's guard is rolled much more rarely: a golem is a landmark, not a crowd
		if _count_of("iron_golem") < MAX_GOLEMS and randf() < 0.08:
			_try_spawn_at_village(player_pos, "iron_golem")
		# wolves live in the woods, so they are rolled separately from the farm animals
		if _count_of("wolf") < MAX_WOLVES and randf() < 0.35:
			_try_spawn_wolf(player_pos)
		# and a trader turns up on its own, rarely, wherever you happen to be standing
		if _count_of("wandering_trader") < MAX_TRADERS and randf() < 0.04:
			_try_spawn_trader(player_pos)


## The mobs of one species currently alive.
func _count_of(kind: String) -> int:
	var n := 0
	for m in mobs:
		if is_instance_valid(m) and str(m.kind) == kind:
			n += 1
	return n


## Villagers appear around the nearest village centre, not around the player: a village
## is the only place they make sense, and spawning them on the ring the animals use
## would scatter shopkeepers across empty fields. The guard uses the same ring, because a
## golem belongs to the village it is guarding just as much as the shopkeepers do.
func _try_spawn_at_village(player_pos: Vector3, kind: String) -> void:
	# villages are an overworld thing: the nether has no villagers, and `nearest_village`
	# would otherwise answer off the overworld's own noise and drop shopkeepers in the lava
	if world.dimension == 1:
		return
	if world.terrain == null or not world.terrain.has_method("nearest_village"):
		return
	var v = world.terrain.nearest_village(floori(player_pos.x), floori(player_pos.z),
		VILLAGE_REACH)
	if v == null:
		return
	for attempt in 6:
		var x: int = int(v["ox"]) + randi_range(-14, 14)
		var z: int = int(v["oz"]) + randi_range(-14, 14)
		if not world.chunks.has(Vector2i(x >> 4, z >> 4)):
			continue
		var spot: Vector3 = world.safe_spawn_near(Vector3(float(x) + 0.5, 0, float(z) + 0.5))
		var gx := floori(spot.x)
		var gy := floori(spot.y)
		var gz := floori(spot.z)
		if world.get_block(gx, gy, gz) != Blocks.AIR or not world.is_solid(gx, gy - 1, gz):
			continue
		spawn_at(kind, spot)
		return


## A trader turns up near the player rather than in a village, on grass like the animals --
## but it is deliberately not in their roster, so the ordinary farm roll never produces one.
func _try_spawn_trader(player_pos: Vector3) -> void:
	for attempt in 8:
		var ang := randf() * TAU
		var dist := randf_range(SPAWN_MIN, SPAWN_MAX)
		var x := floori(player_pos.x + cos(ang) * dist)
		var z := floori(player_pos.z + sin(ang) * dist)
		if not world.chunks.has(Vector2i(x >> 4, z >> 4)):
			continue
		var spot: Vector3 = world.safe_spawn_near(Vector3(float(x) + 0.5, 0, float(z) + 0.5))
		var gx := floori(spot.x)
		var gy := floori(spot.y)
		var gz := floori(spot.z)
		if world.get_block(gx, gy, gz) != Blocks.AIR:
			continue
		if world.get_block(gx, gy - 1, gz) != Blocks.GRASS:
			continue
		spawn_at("wandering_trader", spot)
		return


## The hostiles the current dimension spawns. The overworld and the nether keep separate
## rosters, and the spawner reads the one that matches the world it is running in.
func hostile_roster() -> Array:
	if world != null and world.dimension == 1:
		return NETHER
	return HOSTILE


func _count_kind(hostile: bool) -> int:
	var n := 0
	for m in mobs:
		if is_instance_valid(m) and m.is_hostile() == hostile:
			n += 1
	return n


## Daylight burns hostiles that are exposed to the sky; they despawn at zero health.
func _tick_environment(m, delta: float, night: bool) -> void:
	if not m.is_hostile():
		return
	if not bool(m.def.get("burn", false)) or night:
		return
	var x := floori(m.global_position.x)
	var z := floori(m.global_position.z)
	var y := floori(m.global_position.y)
	if world.highest_occluder(x, z) <= y:
		m.burn_tick(delta)


func _try_spawn(player_pos: Vector3, hostile: bool) -> void:
	var list: Array = hostile_roster() if hostile else PASSIVE
	for attempt in 8:
		var ang := randf() * TAU
		var dist := randf_range(SPAWN_MIN, SPAWN_MAX)
		var x := floori(player_pos.x + cos(ang) * dist)
		var z := floori(player_pos.z + sin(ang) * dist)
		if not world.chunks.has(Vector2i(x >> 4, z >> 4)):
			continue
		var spot: Vector3 = world.safe_spawn_near(Vector3(float(x) + 0.5, 0, float(z) + 0.5))
		var gy := floori(spot.y)
		var gx := floori(spot.x)
		var gz := floori(spot.z)
		if world.get_block(gx, gy, gz) != Blocks.AIR:
			continue
		if hostile:
			# hostiles only need solid ground, not grass — they spawn in the dark
			if not world.is_solid(gx, gy - 1, gz):
				continue
		elif world.get_block(gx, gy - 1, gz) != Blocks.GRASS:
			continue
		_spawn(list[randi() % list.size()], spot)
		return


## Wolves spawn in woodland only, on grass like the farm animals.
func _try_spawn_wolf(player_pos: Vector3) -> void:
	if world.terrain == null:
		return
	for attempt in 8:
		var ang := randf() * TAU
		var dist := randf_range(SPAWN_MIN, SPAWN_MAX)
		var x := floori(player_pos.x + cos(ang) * dist)
		var z := floori(player_pos.z + sin(ang) * dist)
		if not world.chunks.has(Vector2i(x >> 4, z >> 4)):
			continue
		var bio: int = world.terrain.biome_at(x, z)
		if bio != VoxelTerrain.B_FOREST and bio != VoxelTerrain.B_BIRCH_FOREST:
			continue
		var spot: Vector3 = world.safe_spawn_near(Vector3(float(x) + 0.5, 0, float(z) + 0.5))
		var gx := floori(spot.x)
		var gy := floori(spot.y)
		var gz := floori(spot.z)
		if world.get_block(gx, gy, gz) != Blocks.AIR:
			continue
		if world.get_block(gx, gy - 1, gz) != Blocks.GRASS:
			continue
		_spawn("wolf", spot)
		return


## Two adults of the same species that both want to breed, standing close together, make
## one baby and go quiet for a while. Pairing happens here because no single mob can see
## the others.
func _tick_breeding(delta: float) -> void:
	var ready: Array = []
	for m in mobs:
		if not is_instance_valid(m) or m.remote:
			continue
		m.love_t = maxf(0.0, m.love_t - delta)
		if m.love_t > 0.0 and not m.baby and BREEDABLE.has(str(m.kind)):
			ready.append(m)
	var used: Dictionary = {}
	for i in ready.size():
		var a = ready[i]
		if used.has(a):
			continue
		for j in range(i + 1, ready.size()):
			var b = ready[j]
			if used.has(b) or str(b.kind) != str(a.kind):
				continue
			if a.global_position.distance_to(b.global_position) > 6.0:
				continue
			used[a] = true
			used[b] = true
			a.love_t = 0.0
			b.love_t = 0.0
			a._breed_cd = 30.0
			b._breed_cd = 30.0
			var baby = _spawn(str(a.kind), a.global_position + Vector3(0, 0.1, 0))
			baby.make_baby()
			Advancements.trigger("breed", str(a.kind))
			return


## The mob whose body a ray from `origin` along `dir` first hits, or null. Used by the
## player's melee swing to tell a mob from a block.
func raycast_mob(origin: Vector3, dir: Vector3, reach: float):
	var best = null
	var best_t := reach
	for m in mobs:
		if not is_instance_valid(m) or m.remote:
			continue
		var to: Vector3 = m.global_position + Vector3(0, float(m._h) * 0.5, 0) - origin
		var t: float = to.dot(dir)
		if t < 0.0 or t > best_t:
			continue
		var closest: Vector3 = origin + dir * t
		var radius: float = maxf(float(m._half), 0.3) + 0.15
		if closest.distance_to(m.global_position + Vector3(0, float(m._h) * 0.5, 0)) <= radius:
			best = m
			best_t = t
	return best


func _on_mob_used(mob) -> void:
	villager_used.emit(mob)


func _on_mob_died(kind: String, pos: Vector3) -> void:
	mob_died.emit(kind, pos)


func _on_mob_fired(origin: Vector3, dir: Vector3) -> void:
	if projectiles != null:
		projectiles.spawn(origin, dir, 26.0, 4.0, false)


func _on_mob_exploded(pos: Vector3, radius: float) -> void:
	exploded.emit(pos, radius)