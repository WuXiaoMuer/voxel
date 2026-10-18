extends Node3D
## One rideable vehicle: a minecart that rolls on the ground, or a boat that floats on
## water. Both are driven the same way -- the rider steers, and the vehicle does its own
## gravity, float, drag and collision -- so the two share one script and differ only in
## what they float on, how fast they go and how they are drawn.

const GRAVITY := 28.0
const CART_SPEED := 7.0
## A cart on a rail is the point of laying a rail: the same push carries it much further.
const CART_RAIL_SPEED := 11.0
const BOAT_SPEED := 5.5
## How quickly a cart coasts to a stop with nobody pushing it.
const COAST := 1.6
## Half-extents of the collision box. A cart is a little narrower than a block and about
## knee high; a boat is wider and lower, sitting in the water rather than on it.
const CART_HALF := Vector3(0.42, 0.34, 0.42)
const BOAT_HALF := Vector3(0.48, 0.28, 0.48)

var world
var kind := "minecart"
var velocity := Vector3.ZERO
var on_ground := false
var facing := 0.0
var rider = null

var _body: Node3D


func setup(w, k: String, pos: Vector3) -> void:
	world = w
	kind = k
	_build()
	global_position = pos


## Where the rider sits: just above the floor of the vehicle, so the eye ends up about
## where it would if you were standing in it.
func seat() -> Vector3:
	return global_position + Vector3(0, 0.15, 0)


func half() -> Vector3:
	return BOAT_HALF if kind == "boat" else CART_HALF


## The rider's input, applied once a frame while somebody is aboard. An empty `move` is a
## cart or a boat coasting, which is why it is handled here rather than in `tick`.
func drive(move: Vector3, delta: float) -> void:
	if move.length_squared() < 0.0001:
		return
	facing = atan2(move.x, move.z)
	var want := move.normalized() * top_speed()
	var accel := 4.0 if kind == "boat" else 6.5
	velocity.x = lerpf(velocity.x, want.x, clampf(accel * delta, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, want.z, clampf(accel * delta, 0.0, 1.0))


func top_speed() -> float:
	if kind == "boat":
		return BOAT_SPEED
	var below := global_position - Vector3(0, 0.3, 0)
	if world.get_block(floori(below.x), floori(below.y), floori(below.z)) == Blocks.RAIL:
		return CART_RAIL_SPEED
	return CART_SPEED


func tick(delta: float) -> void:
	if kind == "boat":
		if _floating():
			# a boat sits on the water: it does not fall, and it is dragged hard by it
			velocity.y = lerpf(velocity.y, 0.0, clampf(9.0 * delta, 0.0, 1.0))
			velocity.x = lerpf(velocity.x, 0.0, clampf(1.1 * delta, 0.0, 1.0))
			velocity.z = lerpf(velocity.z, 0.0, clampf(1.1 * delta, 0.0, 1.0))
		else:
			velocity.y -= GRAVITY * delta
	else:
		velocity.y -= GRAVITY * delta
		if rider == null and on_ground:
			velocity.x = lerpf(velocity.x, 0.0, clampf(COAST * delta, 0.0, 1.0))
			velocity.z = lerpf(velocity.z, 0.0, clampf(COAST * delta, 0.0, 1.0))

	# Collision is resolved one axis at a time, from where the vehicle started this frame.
	# Doing it in one lump made a cart running along a wall come to a dead stop and then
	# refuse to move again, because the blocked test saw the whole new position at once.
	var before := global_position
	var dx := Vector3(velocity.x, 0, 0) * delta
	var dz := Vector3(0, 0, velocity.z) * delta
	var dy := Vector3(0, velocity.y, 0) * delta
	global_position = before + dx
	if _blocked(global_position):
		global_position.x = before.x
		velocity.x = 0.0
	global_position += dz
	if _blocked(global_position):
		global_position.z = before.z
		velocity.z = 0.0
	var was_ground := on_ground
	global_position += dy
	if _blocked(global_position):
		global_position.y = before.y
		velocity.y = 0.0
		on_ground = true
	else:
		on_ground = false
	# a cart that lands hard scatters a little dust, and a landing is worth hearing
	if on_ground and not was_ground:
		Sfx.play("step", -16.0, 0.7)

	rotation.y = facing
	if global_position.y < float(VoxelTerrain.MIN_Y) - 2.0:
		queue_free()


func _floating() -> bool:
	var p := global_position
	return world.get_block(floori(p.x), floori(p.y), floori(p.z)) == Blocks.WATER \
		or world.get_block(floori(p.x), floori(p.y - 1.0), floori(p.z)) == Blocks.WATER


func _blocked(p: Vector3) -> bool:
	var h := half()
	var x0 := floori(p.x - h.x)
	var x1 := floori(p.x + h.x)
	var z0 := floori(p.z - h.z)
	var z1 := floori(p.z + h.z)
	var y0 := floori(p.y)
	var y1 := floori(p.y + h.y * 2.0)
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for z in range(z0, z1 + 1):
				if world.is_solid(x, y, z):
					return true
	return false


# ================================================================ model
## A cart is an open iron box: a floor, four walls and a rim. A boat is a wooden hull the
## same shape in brown, which is what tells the two apart at a glance.
func _build() -> void:
	_body = Node3D.new()
	add_child(_body)
	var boat := kind == "boat"
	var iron := Color(0.62, 0.62, 0.66) if not boat else Color(0.55, 0.36, 0.18)
	var side := Color(0.50, 0.50, 0.54) if not boat else Color(0.44, 0.28, 0.13)
	var floor_c := Color(0.42, 0.42, 0.46) if not boat else Color(0.38, 0.24, 0.11)
	var h := half()
	_box(Vector3(h.x * 2.0, 0.08, h.z * 2.0), Vector3(0, 0.04, 0), floor_c)
	_box(Vector3(h.x * 2.0, 0.34, 0.08), Vector3(0, 0.17, h.z), side)
	_box(Vector3(h.x * 2.0, 0.34, 0.08), Vector3(0, 0.17, -h.z), side)
	_box(Vector3(0.08, 0.34, h.z * 2.0), Vector3(h.x, 0.17, 0), side)
	_box(Vector3(0.08, 0.34, h.z * 2.0), Vector3(-h.x, 0.17, 0), side)
	# a rim just proud of the walls, which is what stops the box reading as a plain block
	_box(Vector3(h.x * 2.0 + 0.06, 0.06, h.z * 2.0 + 0.06), Vector3(0, 0.36, 0), iron)


func _box(size: Vector3, pos: Vector3, c: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.roughness = 0.7 if kind == "boat" else 0.9
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.position = pos
	_body.add_child(mi)
