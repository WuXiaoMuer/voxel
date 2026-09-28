extends Node3D
## One dropped item lying on the ground: a small spinning block model, or a flat
## icon billboard for pure items. Falls under gravity, settles, bobs, and is
## collected by walking over it.

const SIZE := 0.26          # edge of the dropped cube in blocks
const GRAVITY := 26.0
const PICKUP_H := 1.15      # horizontal radius the player collects from
const PICKUP_AGE := 0.5     # seconds before it can be grabbed

var world
var item_id := 0
var count := 1
var age := 0.0
var velocity := Vector3.ZERO
var on_ground := false

var _body: Node3D
var _spin := 0.0
var _phase := 0.0


func setup(w, id: int, n: int, pos: Vector3, vel: Vector3 = Vector3.ZERO) -> void:
	world = w
	item_id = id
	count = n
	_build()
	global_position = pos
	velocity = vel
	_spin = randf() * TAU
	_phase = randf() * TAU


func _build() -> void:
	# everything hangs off _body so the spin/bob animation never fights the
	# collision position stored on this node
	_body = Node3D.new()
	add_child(_body)
	if Blocks.is_block_item(item_id):
		var mi := MeshInstance3D.new()
		mi.mesh = Blocks.make_block_mesh(item_id)
		mi.scale = Vector3(SIZE, SIZE, SIZE)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_body.add_child(mi)
	else:
		var sp := Sprite3D.new()
		sp.texture = Items.icon(item_id)
		sp.pixel_size = 0.0125
		sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sp.shaded = false
		sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		sp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_body.add_child(sp)
	_body.position = Vector3(0, SIZE * 0.5, 0)


func tick(delta: float, player_pos: Vector3) -> void:
	age += delta
	velocity.y = maxf(velocity.y - GRAVITY * delta, -30.0)

	var before := global_position
	global_position.y += velocity.y * delta
	if _blocked(global_position):
		global_position = before
		if velocity.y < 0.0:
			on_ground = true
		velocity.y = 0.0
	else:
		on_ground = false

	velocity.x = lerpf(velocity.x, 0.0, clampf(delta * 5.0, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, 0.0, clampf(delta * 5.0, 0.0, 1.0))
	if absf(velocity.x) > 0.001 or absf(velocity.z) > 0.001:
		var b2 := global_position
		global_position.x += velocity.x * delta
		global_position.z += velocity.z * delta
		if _blocked(global_position):
			global_position = b2
			velocity.x = 0.0
			velocity.z = 0.0

	_spin += delta * 1.1
	_phase += delta * 2.6
	_body.rotation.y = _spin
	var bob := (sin(_phase) * 0.045) if on_ground else 0.0
	_body.position.y = SIZE * 0.5 + bob

	if global_position.y < float(VoxelTerrain.MIN_Y) - 2.0:
		queue_free()


func _blocked(p: Vector3) -> bool:
	var h := SIZE * 0.45
	var x0 := floori(p.x - h)
	var x1 := floori(p.x + h)
	var y0 := floori(p.y)
	var y1 := floori(p.y + SIZE)
	var z0 := floori(p.z - h)
	var z1 := floori(p.z + h)
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for z in range(z0, z1 + 1):
				if world.is_solid(x, y, z):
					return true
	return false


## True once the item is old enough and the player is standing close enough.
func in_reach(player_pos: Vector3) -> bool:
	if age < PICKUP_AGE:
		return false
	var dx := global_position.x - player_pos.x
	var dz := global_position.z - player_pos.z
	if dx * dx + dz * dz > PICKUP_H * PICKUP_H:
		return false
	var dy := global_position.y - player_pos.y
	return dy > -1.5 and dy < 2.0