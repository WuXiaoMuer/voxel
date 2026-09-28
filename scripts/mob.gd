extends Node3D
## A passive quadruped mob built from coloured boxes: wanders around, obeys
## gravity and voxel collision, bobs its head and legs while walking.

const PX := 0.0625     # one Minecraft mob-texture pixel in world units

const TYPES := {
	"pig": {
		"body": [10, 8, 16], "head": [8, 8, 8], "leg": [4, 6, 4],
		"body_col": "e0a0a0", "head_col": "e8b0b0", "leg_col": "cc8c8c",
		"snout": "b87070", "snout_size": [4, 3, 1], "sound": "mob_grunt",
		"health": 10.0,
	},
	"cow": {
		"body": [12, 10, 18], "head": [8, 8, 8], "leg": [4, 8, 4],
		"body_col": "4a3020", "head_col": "5a3c28", "leg_col": "33220f",
		"snout": "d8c8b8", "snout_size": [6, 4, 1], "sound": "mob_low",
		"health": 10.0,
	},
	"sheep": {
		"body": [12, 11, 16], "head": [6, 6, 8], "leg": [4, 6, 4],
		"body_col": "e8e8e8", "head_col": "d8c4ac", "leg_col": "c0aa94",
		"snout": "b09880", "snout_size": [4, 3, 1], "sound": "mob_bleat",
		"health": 8.0,
	},
	"chicken": {
		"body": [6, 6, 8], "head": [4, 6, 4], "leg": [2, 5, 2],
		"body_col": "f0f0f0", "head_col": "e8e8e8", "leg_col": "e8b020",
		"snout": "f0a020", "snout_size": [3, 2, 1], "sound": "mob_cluck",
		"health": 4.0,
	},
}

var world
var kind := "pig"
var def: Dictionary = {}

var velocity := Vector3.ZERO
var on_ground := false
var facing := 0.0
var _state := 0            # 0 idle, 1 walk
var _state_t := 2.0
var _dir := Vector3.ZERO
var _phase := 0.0
var _head: Node3D
var _legs: Array = []
var _sound_t := 4.0

var _w := 0.0
var _d := 0.0
var _h := 0.0
var _half := 0.0


func setup(w, k: String, pos: Vector3) -> void:
	world = w
	kind = k
	def = TYPES[k]
	var body: Array = def["body"]
	var leg: Array = def["leg"]
	_w = float(body[0]) * PX
	_d = float(body[2]) * PX
	_h = float(leg[1]) * PX + float(body[1]) * PX
	_half = _w * 0.5
	_build()
	global_position = pos
	facing = randf() * TAU
	rotation.y = facing


func _col(key: String) -> Color:
	return Color(str(def[key]))


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.1
	return m


func _box(size_px: Array, pos_px: Vector3, c: Color) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = Vector3(float(size_px[0]) * PX, float(size_px[1]) * PX, float(size_px[2]) * PX)
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.material_override = _mat(c)
	mi.position = Vector3(pos_px.x * PX, pos_px.y * PX, pos_px.z * PX)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


func _build() -> void:
	var body: Array = def["body"]
	var head: Array = def["head"]
	var leg: Array = def["leg"]
	var leg_h := float(leg[1])
	var body_c := _col("body_col")

	var body_pivot := Node3D.new()
	body_pivot.position = Vector3(0, (leg_h + float(body[1]) * 0.5) * PX, 0)
	add_child(body_pivot)
	body_pivot.add_child(_box(body, Vector3.ZERO, body_c))

	_head = Node3D.new()
	_head.position = Vector3(0, float(body[1]) * 0.35 * PX, (float(body[2]) * 0.5) * PX)
	body_pivot.add_child(_head)
	_head.add_child(_box(head, Vector3(0, float(head[1]) * 0.5, float(head[2]) * 0.5),
		_col("head_col")))
	var sn: Array = def["snout_size"]
	_head.add_child(_box(sn, Vector3(0, float(head[1]) * 0.35,
		float(head[2]) * 0.5 + float(sn[2]) * 0.5), _col("snout")))

	_legs.clear()
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var pivot := Node3D.new()
			pivot.position = Vector3(
				sx * (float(body[0]) * 0.5 - float(leg[0]) * 0.5) * PX,
				leg_h * PX,
				sz * (float(body[2]) * 0.5 - float(leg[2]) * 0.5) * PX)
			pivot.add_child(_box(leg, Vector3(0, -float(leg[1]) * 0.5, 0), _col("leg_col")))
			add_child(pivot)
			_legs.append(pivot)


func _aabb(p: Vector3) -> AABB:
	return AABB(Vector3(p.x - _half, p.y, p.z - _half), Vector3(_half * 2.0, _h, _half * 2.0))


func _blocked(p: Vector3) -> bool:
	var b := _aabb(p)
	var x0 := floori(b.position.x)
	var x1 := floori(b.position.x + b.size.x - 0.001)
	var y0 := floori(b.position.y)
	var y1 := floori(b.position.y + b.size.y - 0.001)
	var z0 := floori(b.position.z)
	var z1 := floori(b.position.z + b.size.z - 0.001)
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for z in range(z0, z1 + 1):
				if world.is_solid(x, y, z):
					return true
	return false


func tick(delta: float, player_pos: Vector3) -> void:
	if world == null:
		return
	_state_t -= delta
	if _state_t <= 0.0:
		if _state == 0:
			_state = 1
			_state_t = randf_range(2.0, 5.0)
			facing = randf() * TAU
		else:
			_state = 0
			_state_t = randf_range(1.5, 4.5)

	var speed := 0.0
	if _state == 1:
		speed = 1.35
		_dir = Vector3(sin(facing), 0, cos(facing))
		# turn away from the player so they do not pile up on you
		var away := global_position - player_pos
		away.y = 0.0
		if away.length() < 3.0 and away.length() > 0.01:
			facing = atan2(away.x, away.z)
			_dir = away.normalized()

	velocity.x = lerpf(velocity.x, _dir.x * speed, clampf(delta * 6.0, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, _dir.z * speed, clampf(delta * 6.0, 0.0, 1.0))
	velocity.y -= 28.0 * delta

	# horizontal move, reversing the wander direction when blocked
	var before := global_position
	global_position.x += velocity.x * delta
	global_position.z += velocity.z * delta
	if _blocked(global_position):
		global_position = before
		facing = randf() * TAU
		_dir = Vector3(sin(facing), 0, cos(facing))
		velocity.x = 0.0
		velocity.z = 0.0

	# vertical move
	on_ground = false
	var by := global_position
	global_position.y += velocity.y * delta
	if _blocked(global_position):
		global_position = by
		if velocity.y < 0.0:
			on_ground = true
		velocity.y = 0.0

	if global_position.y < float(VoxelTerrain.MIN_Y) - 4.0:
		global_position.y = world.rescue_y(floori(global_position.x), floori(global_position.z))

	rotation.y = lerp_angle(rotation.y, facing, clampf(delta * 5.0, 0.0, 1.0))
	_animate(delta, speed > 0.0 and on_ground)

	_sound_t -= delta
	if _sound_t <= 0.0:
		_sound_t = randf_range(9.0, 22.0)
		if global_position.distance_to(player_pos) < 22.0:
			Sfx.play(str(def["sound"]), -20.0, randf_range(0.9, 1.15))


func _animate(delta: float, walking: bool) -> void:
	if walking:
		_phase += delta * 9.0
	else:
		_phase = lerpf(_phase, round(_phase / PI) * PI, clampf(delta * 4.0, 0.0, 1.0))
	var s := sin(_phase)
	for i in _legs.size():
		var sign := 1.0 if (i == 0 or i == 3) else -1.0
		_legs[i].rotation.x = s * sign * 0.55 * (1.0 if walking else 0.15)
	if _head != null:
		_head.rotation.x = sin(_phase * 0.5) * 0.06 + (0.0 if walking else sin(_phase * 0.3) * 0.02)