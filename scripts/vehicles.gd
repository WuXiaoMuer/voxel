extends Node3D
## The vehicle layer: the carts and boats in the world, their update loop, and the raycast
## the player's right-click uses to find one. Deliberately close to mobs.gd: a vehicle is
## a thing standing in the world that you can aim at and interact with, and everything that
## spawns one goes through `spawn()` so nothing misses the wiring.

const DESPAWN := 96.0

var world
var player = null
var vehicles: Array = []

var _script := preload("res://scripts/vehicle.gd")


func setup(w) -> void:
	world = w


func reset() -> void:
	for v in vehicles:
		if is_instance_valid(v):
			v.queue_free()
	vehicles.clear()


func count() -> int:
	return vehicles.size()


## Put a vehicle in the world. Returns the node so a caller can act on it straight away.
func spawn(kind: String, pos: Vector3):
	var v = _script.new()
	add_child(v)
	v.setup(world, kind, pos)
	v.rider = null
	vehicles.append(v)
	return v


func update(player_pos: Vector3, delta: float) -> void:
	if world == null:
		return
	var alive: Array = []
	for v in vehicles:
		if not is_instance_valid(v):
			continue
		v.tick(delta)
		# a vehicle nobody is riding and nobody is near is not worth simulating
		if v.rider == null and v.global_position.distance_to(player_pos) > DESPAWN:
			v.queue_free()
			continue
		alive.append(v)
	vehicles = alive


## The vehicle a ray from `origin` along `dir` first hits, or null. Used by the player's
## right-click to tell a cart from a block, the same way `mobs.raycast_mob` does.
func raycast_vehicle(origin: Vector3, dir: Vector3, reach: float):
	var best = null
	var best_t := reach
	for v in vehicles:
		if not is_instance_valid(v):
			continue
		var to: Vector3 = v.global_position + Vector3(0, v.half().y, 0) - origin
		var t: float = to.dot(dir)
		if t < 0.0 or t > best_t:
			continue
		var closest: Vector3 = origin + dir * t
		var radius: float = maxf(v.half().x, v.half().z) + 0.2
		if closest.distance_to(v.global_position + Vector3(0, v.half().y, 0)) <= radius:
			best = v
			best_t = t
	return best
