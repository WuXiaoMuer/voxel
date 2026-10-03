extends Node3D
## Arrows — the game's only projectile, fired by skeletons. Each one arcs under
## gravity, sticks into the first solid block it meets, and hurts whatever living
## thing it passes through. A projectile system kept apart from the mobs so a future
## player bow can reuse it.

const GRAVITY := 20.0
const MAX_ARROWS := 40

var world
var player = null
var mobs = null
var particles = null
var arrows: Array = []


func setup(w) -> void:
	world = w


func clear() -> void:
	for a in arrows:
		if is_instance_valid(a["node"]):
			a["node"].queue_free()
	arrows.clear()


## Launch an arrow from `pos` along `dir`. `from_player` decides who it can hit.
func spawn(pos: Vector3, dir: Vector3, speed: float, dmg: float, from_player: bool) -> void:
	if arrows.size() >= MAX_ARROWS:
		return
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.06, 0.5)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.58, 0.46, 0.28)
	mat.roughness = 1.0
	mat.metallic = 0.0
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)
	mi.global_position = pos
	_aim(mi, pos, dir)
	arrows.append({
		"node": mi, "vel": dir * speed, "dmg": dmg,
		"from_player": from_player, "life": 8.0,
	})


func _aim(mi: MeshInstance3D, from: Vector3, dir: Vector3) -> void:
	if dir.length() < 0.001:
		return
	var up := Vector3.UP
	if absf(dir.normalized().y) > 0.99:
		up = Vector3.RIGHT
	mi.look_at(from + dir, up)


func update(player_pos: Vector3, delta: float) -> void:
	if world == null:
		return
	var alive: Array = []
	for a in arrows:
		var node: MeshInstance3D = a["node"]
		if not is_instance_valid(node):
			continue
		var vel: Vector3 = a["vel"]
		vel.y -= GRAVITY * delta
		a["vel"] = vel
		var from := node.global_position
		var to := from + vel * delta

		if _hit_block(to):
			_impact(to)
			node.queue_free()
			continue
		if _hit_body(a, from, to, player_pos):
			node.queue_free()
			continue

		node.global_position = to
		_aim(node, to, vel)
		a["life"] = float(a["life"]) - delta
		if float(a["life"]) <= 0.0:
			node.queue_free()
			continue
		alive.append(a)
	arrows = alive


func _hit_block(p: Vector3) -> bool:
	return world.is_solid(floori(p.x), floori(p.y), floori(p.z))


func _hit_body(a: Dictionary, from: Vector3, to: Vector3, player_pos: Vector3) -> bool:
	if bool(a["from_player"]):
		if mobs == null:
			return false
		for m in mobs.mobs:
			if not is_instance_valid(m):
				continue
			var c: Vector3 = m.global_position + Vector3(0, m._h * 0.5, 0)
			if _segment_hits(to, c, maxf(m._half, 0.3) + 0.2):
				m.hurt_mob(float(a["dmg"]), from)
				_impact(to)
				return true
		return false
	# a hostile arrow can hit the player
	if player != null and is_instance_valid(player):
		var pc: Vector3 = player.global_position + Vector3(0, 0.9, 0)
		if _segment_hits(to, pc, 0.65):
			if player.has_method("hurt"):
				player.hurt(float(a["dmg"]))
			_impact(to)
			return true
	return false


func _segment_hits(p: Vector3, centre: Vector3, radius: float) -> bool:
	return p.distance_to(centre) <= radius


func _impact(p: Vector3) -> void:
	if particles != null:
		particles.burst(p, Color(0.7, 0.65, 0.55), 4)