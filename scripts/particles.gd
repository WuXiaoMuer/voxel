extends Node3D
## Block break/hit particles: a handful of tiny coloured cubes that fly apart,
## spin and vanish. Deliberately unpooled — a burst is at most a dozen nodes and
## they all die within a second.

const LIFE := 0.8
const GRAVITY := 24.0
const CUBE := 0.085

var _chunks: Array = []
var _cube: BoxMesh
var _mats: Dictionary = {}


func _ready() -> void:
	_cube = BoxMesh.new()
	_cube.size = Vector3(CUBE, CUBE, CUBE)


## One material per colour, reused. Every hit used to allocate a fresh material,
## which with a fast pickaxe is a lot of churn for a handful of block colours.
func _material(c: Color) -> StandardMaterial3D:
	var key := c.to_rgba32()
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.15
	_mats[key] = m
	return m


func clear() -> void:
	for c in _chunks:
		var n = c["n"]
		if is_instance_valid(n):
			n.queue_free()
	_chunks.clear()
	_mats.clear()


## Spawns `n` chips of `color` around `pos`.
func burst(pos: Vector3, color: Color, n: int) -> void:
	if _cube == null:
		_ready()
	var mat := _material(color)
	for i in n:
		var mi := MeshInstance3D.new()
		mi.mesh = _cube
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mi.position = pos + Vector3(randf_range(-0.34, 0.34), randf_range(-0.34, 0.34),
			randf_range(-0.34, 0.34))
		add_child(mi)
		_chunks.append({
			"n": mi,
			"v": Vector3(randf_range(-1.7, 1.7), randf_range(0.8, 2.8), randf_range(-1.7, 1.7)),
			"t": LIFE * randf_range(0.7, 1.0),
			"s": Vector3(randf_range(-7.0, 7.0), randf_range(-7.0, 7.0), randf_range(-7.0, 7.0)),
		})


func update(delta: float) -> void:
	if _chunks.is_empty():
		return
	var alive: Array = []
	for c in _chunks:
		var n = c["n"]
		if not is_instance_valid(n):
			continue
		c["t"] = float(c["t"]) - delta
		if float(c["t"]) <= 0.0:
			n.queue_free()
			continue
		var v: Vector3 = c["v"]
		v.y -= GRAVITY * delta
		c["v"] = v
		n.position += v * delta
		n.rotation += c["s"] * delta
		alive.append(c)
	_chunks = alive