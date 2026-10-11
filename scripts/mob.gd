extends Node3D
## A mob built from coloured boxes. Passive animals (pig / cow / sheep / chicken)
## wander and avoid the player; hostile mobs (zombie / skeleton / spider / creeper)
## hunt, attack and can be killed. Two body shapes are supported: a quadruped and an
## upright humanoid, both assembled from the same box helper.

const PX := 0.0625     # one Minecraft mob-texture pixel in world units

const TYPES := {
	# ---- passive quadrupeds
	"pig": {
		"shape": "quad", "hostile": false, "burn": false, "speed": 1.35,
		"body": [10, 8, 16], "head": [8, 8, 8], "leg": [4, 6, 4],
		"body_col": "e0a0a0", "head_col": "e8b0b0", "leg_col": "cc8c8c",
		"snout": "b87070", "snout_size": [4, 3, 1], "sound": "mob_grunt",
		"health": 10.0,
	},
	"cow": {
		"shape": "quad", "hostile": false, "burn": false, "speed": 1.35,
		"body": [12, 10, 18], "head": [8, 8, 8], "leg": [4, 8, 4],
		"body_col": "4a3020", "head_col": "5a3c28", "leg_col": "33220f",
		"snout": "d8c8b8", "snout_size": [6, 4, 1], "sound": "mob_low",
		"health": 10.0,
	},
	"sheep": {
		"shape": "quad", "hostile": false, "burn": false, "speed": 1.35,
		"body": [12, 11, 16], "head": [6, 6, 8], "leg": [4, 6, 4],
		"body_col": "e8e8e8", "head_col": "d8c4ac", "leg_col": "c0aa94",
		"snout": "b09880", "snout_size": [4, 3, 1], "sound": "mob_bleat",
		"health": 8.0,
	},
	"chicken": {
		"shape": "quad", "hostile": false, "burn": false, "speed": 1.35,
		"body": [6, 6, 8], "head": [4, 6, 4], "leg": [2, 5, 2],
		"body_col": "f0f0f0", "head_col": "e8e8e8", "leg_col": "e8b020",
		"snout": "f0a020", "snout_size": [3, 2, 1], "sound": "mob_cluck",
		"health": 4.0,
	},
	# ---- hostile
	"zombie": {
		"shape": "human", "hostile": true, "burn": true, "speed": 1.9,
		"atk_dmg": 3.0, "atk_range": 1.7, "health": 20.0,
		"body": [8, 12, 4], "head": [8, 8, 8], "leg": [4, 12, 4], "arms": [4, 12, 4],
		"body_col": "2f5a4a", "head_col": "3f7a52", "leg_col": "2a2f5a",
		"arm_col": "3f7a52", "sound": "mob_grunt",
	},
	"skeleton": {
		"shape": "human", "hostile": true, "burn": true, "speed": 1.9,
		"atk_dmg": 0.0, "atk_range": 14.0, "health": 20.0,
		"body": [8, 12, 4], "head": [8, 8, 8], "leg": [4, 12, 4], "arms": [4, 12, 4],
		"body_col": "d8d8d0", "head_col": "e8e8e0", "leg_col": "d0d0c8",
		"arm_col": "d8d8d0", "sound": "mob_low",
	},
	"spider": {
		"shape": "quad", "hostile": true, "burn": false, "speed": 2.4,
		"atk_dmg": 2.0, "atk_range": 1.5, "health": 16.0,
		"body": [10, 8, 14], "head": [6, 6, 6], "leg": [3, 8, 3],
		"body_col": "241414", "head_col": "361f1f", "leg_col": "140a0a",
		"snout": "8a1010", "snout_size": [3, 2, 1], "sound": "mob_low",
	},
	"creeper": {
		"shape": "human", "hostile": true, "burn": false, "speed": 2.0,
		"atk_dmg": 0.0, "atk_range": 2.4, "health": 20.0,
		"body": [8, 12, 4], "head": [8, 8, 8], "leg": [4, 6, 4],
		"body_col": "3aa02a", "head_col": "4ab83a", "leg_col": "2a8018",
		"sound": "mob_low",
	},
	# a slime is a bouncing green blob rather than a real quadruped: the body box is
	# large and the legs are stubs, which is close enough at this scale
	"slime": {
		"shape": "quad", "hostile": true, "burn": false, "speed": 1.5,
		"atk_dmg": 2.0, "atk_range": 1.6, "health": 16.0,
		"body": [12, 12, 12], "head": [8, 8, 8], "leg": [4, 4, 4],
		"body_col": "58c04a", "head_col": "6ad05a", "leg_col": "4aa83c",
		"snout": "3a8830", "snout_size": [4, 2, 1], "sound": "mob_low",
	},
	# a tall, thin, near-black figure with long limbs
	"enderman": {
		"shape": "human", "hostile": true, "burn": false, "speed": 2.6,
		"atk_dmg": 5.0, "atk_range": 2.0, "health": 40.0,
		"body": [8, 14, 4], "head": [8, 8, 8], "leg": [4, 18, 4], "arms": [4, 18, 4],
		"body_col": "12121a", "head_col": "18181f", "leg_col": "0c0c12",
		"arm_col": "18181f", "sound": "mob_low",
	},
	# ---- villagers. They are *not* in mobs.gd's PASSIVE roster: the wild spawner would
	# drop them on any patch of grass. They belong to a village, so mobs.gd spawns them
	# against a village centre instead. A robe-brown body and a big nose are all it takes
	# to read as a villager, and `flee: false` keeps them from running away from you.
	"villager": {
		"shape": "human", "hostile": false, "burn": false, "speed": 1.15, "flee": false,
		"health": 20.0,
		"body": [8, 12, 4], "head": [8, 8, 8], "leg": [4, 12, 4], "arms": [4, 12, 4],
		"body_col": "6b4a2f", "head_col": "c08a5a", "leg_col": "4a3421",
		# the arms are the robe, not bare skin: a villager's hands are tucked into the
		# sleeves and folded across the chest, so a skin-coloured arm reads as a person
		# with their arms hanging at their sides
		"arm_col": "5a3a22", "sound": "mob_grunt",
		"nose": "b07f52", "nose_size": [2, 2, 2],
	},
}

signal died(kind: String, pos: Vector3)
signal fired(origin: Vector3, dir: Vector3)
signal exploded(pos: Vector3, radius: float)
## Right-clicked (a villager is talked to). Routed out through mobs.gd so main can open
## the trade screen; the mob itself knows nothing about trading.
signal used(mob)

var world
var player = null
var particles = null
var kind := "pig"
var def: Dictionary = {}
## A villager's trade, chosen by its position, not by its kind: "Farmer", "Butcher",
## "Smith" or "Mason". Blank for every other mob.
var profession := ""

var velocity := Vector3.ZERO
var on_ground := false
var facing := 0.0
var health := 10.0
var burning := false
var _state := 0            # 0 idle, 1 walk
var _state_t := 2.0
var _dir := Vector3.ZERO
var _phase := 0.0
var _head: Node3D
var _legs: Array = []
var _arms: Array = []
var _parts: Array = []     # [{mesh, base: Color}] for the hurt flash
var _sound_t := 4.0
var _atk_cd := 0.0
var _fuse := 0.0
var _leap_cd := 0.0
var _burn_t := 0.0
var _hurt_t := 0.0

var _w := 0.0
var _d := 0.0
var _h := 0.0
var _half := 0.0


func is_hostile() -> bool:
	return bool(def.get("hostile", false))


## A right-click landed on this mob. Villagers answer it; nothing else cares.
func interact() -> void:
	used.emit(self)


func setup(w, k: String, pos: Vector3) -> void:
	world = w
	kind = k
	def = TYPES[k]
	health = float(def.get("health", 10.0))
	if def.get("shape", "quad") == "human":
		var body: Array = def["body"]
		var leg: Array = def["leg"]
		var head: Array = def["head"]
		_w = float(body[0]) * PX
		if def.has("arms"):
			_w += float(def["arms"][0]) * 2.0 * PX
		_d = float(body[2]) * PX
		_h = (float(leg[1]) + float(body[1]) + float(head[1])) * PX
	else:
		var body2: Array = def["body"]
		var leg2: Array = def["leg"]
		_w = float(body2[0]) * PX
		_d = float(body2[2]) * PX
		_h = float(leg2[1]) * PX + float(body2[1]) * PX
	_half = _w * 0.5
	_build()
	global_position = pos
	facing = randf() * TAU
	rotation.y = facing


func _col(key: String) -> Color:
	return Color(str(def.get(key, "888888")))


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
	_parts.append({"mesh": mi, "base": c})
	return mi


func _build() -> void:
	if def.get("shape", "quad") == "human":
		_build_human()
	else:
		_build_quad()


func _build_quad() -> void:
	var body: Array = def["body"]
	var head: Array = def["head"]
	var leg: Array = def["leg"]
	var leg_h := float(leg[1])

	var body_pivot := Node3D.new()
	body_pivot.position = Vector3(0, (leg_h + float(body[1]) * 0.5) * PX, 0)
	add_child(body_pivot)
	body_pivot.add_child(_box(body, Vector3.ZERO, _col("body_col")))

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


func _build_human() -> void:
	var body: Array = def["body"]
	var head: Array = def["head"]
	var leg: Array = def["leg"]
	var leg_h := float(leg[1])
	var body_h := float(body[1])

	# legs hang from the hips
	_legs.clear()
	for sx in [-1.0, 1.0]:
		var pivot := Node3D.new()
		pivot.position = Vector3(sx * float(leg[0]) * 0.5 * PX, leg_h * PX, 0)
		pivot.add_child(_box(leg, Vector3(0, -leg_h * 0.5, 0), _col("leg_col")))
		add_child(pivot)
		_legs.append(pivot)

	# torso pivots at the waist
	var torso := Node3D.new()
	torso.position = Vector3(0, leg_h * PX, 0)
	add_child(torso)
	torso.add_child(_box(body, Vector3(0, body_h * 0.5, 0), _col("body_col")))

	# arms hang from the shoulders
	_arms.clear()
	if def.has("arms"):
		var arm: Array = def["arms"]
		for sx2 in [-1.0, 1.0]:
			var ap := Node3D.new()
			ap.position = Vector3(sx2 * (float(body[0]) * 0.5 + float(arm[0]) * 0.5) * PX,
				(body_h - float(arm[1]) * 0.5) * PX, 0)
			ap.add_child(_box(arm, Vector3(0, -float(arm[1]) * 0.5, 0), _col("arm_col")))
			torso.add_child(ap)
			_arms.append(ap)

	_head = Node3D.new()
	_head.position = Vector3(0, (body_h + float(head[1]) * 0.5) * PX, 0)
	torso.add_child(_head)
	_head.add_child(_box(head, Vector3.ZERO, _col("head_col")))
	# a villager's nose: the one box that makes an otherwise generic humanoid read as a
	# villager rather than as a player, so it is hung just below centre and pushed out
	# past the front face of the head
	if def.has("nose"):
		var ns: Array = def["nose_size"]
		_head.add_child(_box(ns, Vector3(0, -1.0,
			float(head[2]) * 0.5 + float(ns[2]) * 0.5), _col("nose")))


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


# ================================================================ combat
## Take a hit: flash red, get knocked back, and die at zero health.
func hurt_mob(amount: float, from: Vector3 = Vector3.ZERO) -> void:
	if health <= 0.0:
		return
	health -= amount
	_hurt_t = 0.28
	if from != Vector3.ZERO:
		var away := global_position - from
		away.y = 0.0
		if away.length() > 0.01:
			away = away.normalized()
			velocity.x += away.x * 5.0
			velocity.z += away.z * 5.0
			velocity.y = maxf(velocity.y, 4.0)
	Sfx.play("mob_hurt", -14.0, randf_range(0.95, 1.1))
	if health <= 0.0:
		die()


func die() -> void:
	if particles != null:
		particles.burst(global_position + Vector3(0, _h * 0.5, 0), _col("body_col"), 12)
	Sfx.play("mob_die", -12.0)
	died.emit(kind, global_position)
	queue_free()


## Daylight burning: a hostile that does not survive the sun loses a heart a second.
func burn_tick(delta: float) -> void:
	burning = true
	_burn_t -= delta
	if _burn_t <= 0.0:
		_burn_t = 1.0
		if particles != null:
			particles.burst(global_position + Vector3(0, _h * 0.7, 0), Color(1.0, 0.6, 0.15), 4)
		hurt_mob(1.0)


func tick(delta: float, player_pos: Vector3) -> void:
	if world == null:
		return
	_hurt_t = maxf(0.0, _hurt_t - delta)
	_atk_cd = maxf(0.0, _atk_cd - delta)
	_leap_cd = maxf(0.0, _leap_cd - delta)

	var speed := 0.0
	if is_hostile():
		speed = _tick_hostile(delta, player_pos)
	else:
		speed = _tick_passive(delta, player_pos)

	velocity.x = lerpf(velocity.x, _dir.x * speed, clampf(delta * 6.0, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, _dir.z * speed, clampf(delta * 6.0, 0.0, 1.0))
	velocity.y -= 28.0 * delta

	# horizontal move, reversing the direction when blocked
	var before := global_position
	global_position.x += velocity.x * delta
	global_position.z += velocity.z * delta
	if _blocked(global_position):
		global_position = before
		if is_hostile():
			# sidestep rather than spin: keep pushing at the player
			facing += randf_range(-1.2, 1.2)
		else:
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
	_flash()

	if not is_hostile():
		_sound_t -= delta
		if _sound_t <= 0.0:
			_sound_t = randf_range(9.0, 22.0)
			if global_position.distance_to(player_pos) < 22.0:
				Sfx.play(str(def["sound"]), -20.0, randf_range(0.9, 1.15))


func _tick_passive(delta: float, player_pos: Vector3) -> float:
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
		speed = float(def.get("speed", 1.35))
		_dir = Vector3(sin(facing), 0, cos(facing))
		# turn away from the player so they do not pile up on you. Villagers are the
		# exception: a shopkeeper that bolts the moment you walk up cannot be traded with.
		if bool(def.get("flee", true)):
			var away := global_position - player_pos
			away.y = 0.0
			if away.length() < 3.0 and away.length() > 0.01:
				facing = atan2(away.x, away.z)
				_dir = away.normalized()
	return speed


func _tick_hostile(delta: float, player_pos: Vector3) -> float:
	var to_player := player_pos - global_position
	to_player.y = 0.0
	var dist := to_player.length()
	var speed := float(def.get("speed", 1.9))
	if dist > 0.01:
		_dir = to_player.normalized()
		facing = atan2(_dir.x, _dir.z)
	else:
		_dir = Vector3.ZERO

	match kind:
		"skeleton":
			# hold a firing line: close in when far, back off when too close
			if dist > 12.0:
				pass
			elif dist < 6.0:
				_dir = -_dir
			else:
				_dir = Vector3.ZERO
				speed = 0.0
			if dist <= float(def.get("atk_range", 14.0)) and _atk_cd <= 0.0 \
					and _has_line_of_sight(player_pos):
				_atk_cd = 2.0
				var aim := (player_pos - global_position).normalized()
				aim.y += 0.12
				fired.emit(global_position + Vector3(0, _h * 0.75, 0), aim.normalized())
		"creeper":
			if dist < float(def.get("atk_range", 2.4)):
				speed = 0.0
				_dir = Vector3.ZERO
				_fuse += delta
				var s := 1.0 + clampf(_fuse / 1.5, 0.0, 1.0) * 0.5
				scale = Vector3(s, 1.0 + clampf(_fuse / 1.5, 0.0, 1.0) * 0.25, s)
				if _fuse >= 1.5:
					exploded.emit(global_position, 3.0)
					queue_free()
			else:
				_fuse = maxf(0.0, _fuse - delta * 1.5)
				scale = Vector3.ONE
		"spider":
			if dist < float(def.get("atk_range", 1.5)) and _atk_cd <= 0.0:
				_atk_cd = 1.0
				if player != null and player.has_method("hurt"):
					player.hurt(float(def.get("atk_dmg", 2.0)))
			elif dist < 5.0 and on_ground and _leap_cd <= 0.0:
				_leap_cd = 2.2
				velocity.y = 7.0
		_:
			# zombie and any other melee hostile
			if dist < float(def.get("atk_range", 1.7)) and _atk_cd <= 0.0:
				_atk_cd = 1.0
				if player != null and player.has_method("hurt"):
					player.hurt(float(def.get("atk_dmg", 3.0)))
	return speed


func _has_line_of_sight(player_pos: Vector3) -> bool:
	if world == null or not world.has_method("raycast"):
		return true
	var eye := global_position + Vector3(0, _h * 0.75, 0)
	var dir := (player_pos + Vector3(0, 1.0, 0)) - eye
	var dist := dir.length()
	if dist < 0.01:
		return true
	var hit: Dictionary = world.raycast(eye, dir / dist, dist)
	return hit.is_empty()


func _flash() -> void:
	var f := _hurt_t / 0.28
	for p in _parts:
		var base: Color = p["base"]
		var mi: MeshInstance3D = p["mesh"]
		var want: Color = base.lerp(Color(1.0, 0.25, 0.25), f) if f > 0.0 else base
		(mi.material_override as StandardMaterial3D).albedo_color = want


func _animate(delta: float, walking: bool) -> void:
	if walking:
		_phase += delta * 9.0
	else:
		_phase = lerpf(_phase, round(_phase / PI) * PI, clampf(delta * 4.0, 0.0, 1.0))
	var s := sin(_phase)
	for i in _legs.size():
		var sign := 1.0 if (i == 0 or i == 3) else -1.0
		_legs[i].rotation.x = s * sign * 0.55 * (1.0 if walking else 0.15)
	for i in _arms.size():
		var asign := 1.0 if i == 0 else -1.0
		if kind == "villager":
			# folded across the chest and tucked into the robe, the way a villager stands:
			# no swing, because a shopkeeper does not pump their arms while pottering about
			_arms[i].rotation.x = -1.15
			_arms[i].rotation.z = asign * 0.35
		else:
			_arms[i].rotation.x = s * asign * 0.5 * (1.0 if walking else 0.1) - 0.1
	if _head != null:
		_head.rotation.x = sin(_phase * 0.5) * 0.06 + (0.0 if walking else sin(_phase * 0.3) * 0.02)