extends Node3D
## Spawns, updates and despawns passive mobs around the player.

const MAX_MOBS := 14
const SPAWN_MIN := 18.0
const SPAWN_MAX := 44.0
const DESPAWN := 96.0
const KINDS := ["pig", "pig", "sheep", "cow", "chicken"]

var world
var mobs: Array = []
var _timer := 1.5
var _script := preload("res://scripts/mob.gd")


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


## Spawn a specific animal at a spot (used by the preview pass).
func spawn_at(kind: String, pos: Vector3):
	var m = _script.new()
	add_child(m)
	m.setup(world, kind, pos)
	mobs.append(m)
	return m


func update(player_pos: Vector3, delta: float) -> void:
	if world == null:
		return
	var alive: Array = []
	for m in mobs:
		if not is_instance_valid(m):
			continue
		if m.global_position.distance_to(player_pos) > DESPAWN:
			m.queue_free()
			continue
		m.tick(delta, player_pos)
		alive.append(m)
	mobs = alive

	_timer -= delta
	if _timer <= 0.0:
		_timer = randf_range(1.2, 3.0)
		if mobs.size() < MAX_MOBS:
			_try_spawn(player_pos)


func _try_spawn(player_pos: Vector3) -> void:
	for attempt in 8:
		var ang := randf() * TAU
		var dist := randf_range(SPAWN_MIN, SPAWN_MAX)
		var x := floori(player_pos.x + cos(ang) * dist)
		var z := floori(player_pos.z + sin(ang) * dist)
		# Asked directly rather than inferred from the heightmap: the old test was
		# `highest_occluder >= HEIGHT`, which only ever meant "not loaded" because the
		# ceiling sat just above the terrain. At 320 it never fires, and mobs would
		# spawn into chunks that have not been generated.
		if not world.chunks.has(Vector2i(x >> 4, z >> 4)):
			continue
		var spot: Vector3 = world.safe_spawn_near(Vector3(float(x) + 0.5, 0, float(z) + 0.5))
		var gy := floori(spot.y)
		var ground: int = world.get_block(floori(spot.x), gy - 1, floori(spot.z))
		if ground != Blocks.GRASS:
			continue
		if world.get_block(floori(spot.x), gy, floori(spot.z)) != Blocks.AIR:
			continue
		var m = _script.new()
		add_child(m)
		m.setup(world, KINDS[randi() % KINDS.size()], spot)
		mobs.append(m)
		return