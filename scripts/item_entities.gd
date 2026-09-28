extends Node3D
## Spawns, merges, updates and despawns dropped item entities around the player.

const MAX_ITEMS := 140
const DESPAWN := 64.0
const MERGE_RADIUS := 0.85
const MERGE_EVERY := 0.4

var world
var player
var items: Array = []

var _script := preload("res://scripts/item_entity.gd")
var _merge_t := MERGE_EVERY


func setup(w, p) -> void:
	world = w
	player = p


func reset() -> void:
	for it in items:
		if is_instance_valid(it):
			it.queue_free()
	items.clear()
	_merge_t = MERGE_EVERY


func count() -> int:
	return items.size()


## Throws `n` of `id` on the ground at `pos`. When the ground is already littered
## the drop goes straight into the inventory instead, so a big cave-in cannot
## spawn hundreds of nodes.
func drop(id: int, n: int, pos: Vector3, vel: Vector3 = Vector3.ZERO) -> void:
	if id <= 0 or n <= 0:
		return
	if items.size() >= MAX_ITEMS:
		player.give(id, n)
		return
	var it = _script.new()
	add_child(it)
	var jitter := Vector3(randf_range(-0.16, 0.16), 0.0, randf_range(-0.16, 0.16))
	it.setup(world, id, n, pos + jitter, vel)
	items.append(it)


func update(player_pos: Vector3, delta: float) -> void:
	if world == null:
		return
	var alive: Array = []
	for it in items:
		if not is_instance_valid(it):
			continue
		it.tick(delta, player_pos)
		if it.global_position.distance_squared_to(player_pos) > DESPAWN * DESPAWN:
			it.queue_free()
			continue
		if it.in_reach(player_pos) and player.can_accept(it.item_id):
			player.give(it.item_id, it.count)
			Sfx.play("pop", -11.0, randf_range(1.05, 1.35))
			it.queue_free()
			continue
		alive.append(it)
	items = alive

	_merge_t -= delta
	if _merge_t <= 0.0:
		_merge_t = MERGE_EVERY
		_merge(player_pos)


## Folds identical stacks that have come to rest on top of each other into one
## entity, the way Minecraft keeps a full chest of cobblestone from turning into
## an entity soup.
func _merge(player_pos: Vector3) -> void:
	var maxs := 0
	var keep: Array = []
	for it in items:
		if not is_instance_valid(it):
			continue
		if not it.on_ground or it.item_id <= 0:
			keep.append(it)
			continue
		var merged := false
		for other in keep:
			if other.item_id != it.item_id:
				continue
			maxs = Items.max_stack(it.item_id)
			if int(other.count) >= maxs:
				continue
			if other.global_position.distance_to(it.global_position) > MERGE_RADIUS:
				continue
			other.count = mini(maxs, int(other.count) + int(it.count))
			it.queue_free()
			merged = true
			break
		if not merged:
			keep.append(it)
	items = keep