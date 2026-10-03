extends Node3D
## Procedural Minecraft-style humanoid player model: six boxes textured from a
## generated 64x64 skin, plus a walk/idle/sneak animation. Doubles as the skin
## system (several generated presets, selectable in Settings).

const PIXEL := 0.055          # one skin pixel in world units (32 px ≈ 1.76 m)
## How far the neck can twist away from the shoulders, in radians (Minecraft's 75
## degrees). Past this the body has to turn to keep up, which is what makes a quick
## look-around read as "the head turned, then the shoulders followed".
const HEAD_LIMIT := 1.31

## skin, hair, shirt, pants, shoes, eye
const SKINS := [
	{"name": "Steve", "skin": "c99a6b", "hair": "3b2a1a", "shirt": "00aaaa",
		"pants": "3b3b8c", "shoes": "4b4b4b", "eye": "2b3b8c"},
	{"name": "Alex", "skin": "e8b98a", "hair": "c77e32", "shirt": "4bb04b",
		"pants": "6b4a2a", "shoes": "6b4b2b", "eye": "3f6b2f"},
	{"name": "Ninja", "skin": "c99a6b", "hair": "111114", "shirt": "22222c",
		"pants": "17171f", "shoes": "0d0d12", "eye": "cc2222"},
	{"name": "Miner", "skin": "d8a878", "hair": "8b5a2b", "shirt": "b0b0b8",
		"pants": "4a4a55", "shoes": "303038", "eye": "334455"},
	{"name": "Gold", "skin": "f0c070", "hair": "ffd24a", "shirt": "c89020",
		"pants": "8a6010", "shoes": "604000", "eye": "5a3a00"},
	{"name": "Slime", "skin": "7ed957", "hair": "4c9e2e", "shirt": "5ac24a",
		"pants": "3e8c34", "shoes": "2e6b26", "eye": "1d3d18"},
]

var skin_index := 0

var head: MeshInstance3D
var torso: MeshInstance3D
var torso_pivot: Node3D
var neck: Node3D
var arm_r: MeshInstance3D
var arm_l: MeshInstance3D
var leg_r: MeshInstance3D
var leg_l: MeshInstance3D

var _arm_shoulder: Node3D
var _mat: StandardMaterial3D
var _phase := 0.0
var _swing := 0.0
var _skin_tex: ImageTexture

## Where the player is looking, and where the body has actually turned to. The body
## eases toward the look and the head makes up the difference, so the head leads.
var look_yaw := 0.0
var body_yaw := 0.0
var pinned := false
var pinned_yaw := 0.0
var _facing_init := false


func _ready() -> void:
	_mat = StandardMaterial3D.new()
	_mat.roughness = 1.0
	_mat.metallic = 0.0
	_mat.metallic_specular = 0.15
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_mat.texture_repeat = false
	_mat.vertex_color_use_as_albedo = false

	# pivot groups so limbs rotate around their top edge, like Minecraft
	var hip := Node3D.new()
	hip.position = Vector3(0, 12.0 * PIXEL, 0)
	add_child(hip)

	# +x is the character's RIGHT (the model faces -z), so the right arm and leg sit
	# there and use Minecraft's right-hand skin regions
	leg_r = _part("leg_r", 0, 16, 4, 12, 4, Vector3(2, 0, 0))
	leg_l = _part("leg_l", 16, 48, 4, 12, 4, Vector3(-2, 0, 0))
	hip.add_child(leg_r)
	hip.add_child(leg_l)

	# The torso pivots at the HIPS, not at the shoulders. Its box hangs below its
	# origin, so rotating about the shoulders swings the hips out in front; pivoting
	# at the hips tips the chest forward instead, which is what a crouch should do.
	torso_pivot = Node3D.new()
	torso_pivot.position = Vector3(0, 12.0 * PIXEL, 0)
	add_child(torso_pivot)
	torso = _part("torso", 16, 16, 8, 12, 4, Vector3(0, 12, 0))
	torso_pivot.add_child(torso)

	# arms and head ride on the chest, so they lean with it like Minecraft's do
	_arm_shoulder = Node3D.new()
	_arm_shoulder.position = Vector3(0, 12.0 * PIXEL, 0)
	torso_pivot.add_child(_arm_shoulder)
	arm_r = _part("arm_r", 40, 16, 4, 12, 4, Vector3(6, 0, 0))
	arm_l = _part("arm_l", 32, 48, 4, 12, 4, Vector3(-6, 0, 0))
	_arm_shoulder.add_child(arm_r)
	_arm_shoulder.add_child(arm_l)

	# pivot at the neck so the head turns around its base; the box sits above it
	neck = Node3D.new()
	neck.position = Vector3(0, 12.0 * PIXEL, 0)
	torso_pivot.add_child(neck)
	head = _part("head", 0, 0, 8, 8, 8, Vector3(0, 8, 0))
	neck.add_child(head)

	set_skin(skin_index)

	# the block currently held, in the right hand -- now the *only* place a held block is
	# drawn, since first person shows the body too and no longer overlays a copy on the
	# camera
	held = MeshInstance3D.new()
	held.visible = false
	held.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	held.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	arm_r.add_child(held)

	# a tool in the same hand: a wooden shaft with a small head that changes colour and
	# shape with the material and the kind of tool
	held_tool = Node3D.new()
	held_tool.visible = false
	arm_r.add_child(held_tool)
	var shaft := MeshInstance3D.new()
	var sb := BoxMesh.new()
	sb.size = Vector3(0.045, 0.52, 0.045)
	shaft.mesh = sb
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.45, 0.30, 0.15)
	sm.roughness = 1.0
	sm.metallic = 0.0
	shaft.material_override = sm
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shaft.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	held_tool.add_child(shaft)
	held_head = MeshInstance3D.new()
	var hbm := BoxMesh.new()
	hbm.size = Vector3(0.20, 0.10, 0.06)
	held_head.mesh = hbm
	held_head.position = Vector3(0, 0.28, 0)
	var hm2 := StandardMaterial3D.new()
	hm2.albedo_color = Color(0.7, 0.7, 0.7)
	hm2.roughness = 0.8
	hm2.metallic = 0.3
	held_head.material_override = hm2
	held_head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	held_head.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	held_tool.add_child(held_head)


var held: MeshInstance3D
var held_tool: Node3D
var held_head: MeshInstance3D


## Shows a small copy of `id` in the right hand. Pass 0 to hide it. Kept in sync by
## player.refresh_hand().
func set_held_block(id: int) -> void:
	if held == null:
		return
	if held_tool != null:
		held_tool.visible = false
	if id <= 0 or not Blocks.is_block_item(id):
		held.visible = false
		held.mesh = null
		return
	held.mesh = Blocks.make_block_mesh(id)
	held.scale = Vector3(0.2, 0.2, 0.2)
	# clear of the arm on every axis, so the block reads from behind as well as
	# from the front instead of being swallowed by the sleeve. arm_r is the +x arm,
	# so +x is outward.
	held.position = Vector3(0.05, -0.72, -0.17)
	held.visible = true


## Shows a small tool in the right hand: the head's colour follows the material tier and
## the shape follows the tool kind. Pass 0 (or any non-tool) to hide it.
func set_held_item(id: int) -> void:
	if held_tool == null:
		return
	if id <= 0 or not Gear.is_tool(id):
		# only the tool is ours to hide: the block hand is set_held_block's to clear
		held_tool.visible = false
		return
	if held != null:
		held.visible = false
		held.mesh = null
	var tier := Gear.tier_of(id)
	var col := Color(0.62, 0.46, 0.26)
	match tier:
		1:
			col = Color(0.60, 0.60, 0.63)
		2:
			col = Color(0.86, 0.86, 0.90)
		3:
			col = Color(0.36, 0.90, 0.92)
	(held_head.material_override as StandardMaterial3D).albedo_color = col
	# a pick/axe/shovel head is a wide block; a sword/hoe wants a flat blade
	var kind := Gear.tool_kind(id)
	var hb: BoxMesh = held_head.mesh
	if kind == Gear.SWORD or kind == Gear.HOE:
		hb.size = Vector3(0.06, 0.34, 0.04)
		held_head.position = Vector3(0, 0.34, 0)
	else:
		hb.size = Vector3(0.22, 0.10, 0.06)
		held_head.position = Vector3(0, 0.28, 0)
	held_tool.position = Vector3(0.05, -0.72, -0.17)
	held_tool.visible = true


## The skin rectangle each of a box's six faces samples, ordered top, bottom, -x,
## +z, +x, -z. Minecraft's unwrap band runs [right, front, left, back]; the model
## faces -z, so its LEFT side is -x and takes the third band slot while +x (the
## right side) takes the first. Swapping those two is invisible on a symmetric
## skin and obvious on a real one.
func box_regions(u: int, v: int, w: int, h: int, d: int) -> Array:
	return [
		[u + d, v, w, d],                 # top
		[u + d + w, v, w, d],             # bottom
		[u + d + w, v + d, d, h],         # -x  (the character's left)
		[u + d + w + d, v + d, w, h],     # +z  (back)
		[u, v + d, d, h],                 # +x  (the character's right)
		[u + d, v + d, w, h],             # -z  (front)
	]


func _axis(p: Vector3, name: String) -> float:
	match name:
		"x":
			return p.x
		"y":
			return p.y
	return p.z


## Builds one textured box. UVs follow the classic Minecraft skin unwrap:
## region width = 2*(w+d), height = d+h, with top/bottom between the side faces.
func _part(_n: String, u: int, v: int, w: int, h: int, d: int, offset_px: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _part_mesh(u, v, w, h, d)
	mi.position = offset_px * PIXEL
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


func _part_mesh(u: int, v: int, w: int, h: int, d: int) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	const TEX := 64.0

	var regs := box_regions(u, v, w, h, d)
	# Each face carries the *names* of the two player-space axes that its skin
	# region spans, and the UV corners are read straight off the corner position.
	# A single shared UV table cannot work here: the caps span x/z while the sides
	# span x/y or z/y, so any fixed table either collapses the quad onto a diagonal
	# or rotates the texture 90 degrees. Deriving it per face makes both impossible.
	# "ua"/"va" also match the orientation of Blocks.FACE_UV, so nothing is mirrored.
	var faces := [
		# the top cap (normal +Y) sits at the box's origin, the bottom cap at -h
		{"r": regs[0], "v": [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0)],
			"n": Vector3(0, 1, 0), "ua": "x", "va": "z"},
		{"r": regs[1], "v": [Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)],
			"n": Vector3(0, -1, 0), "ua": "x", "va": "z"},
		{"r": regs[2], "v": [Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(0, 0, 1), Vector3(0, 0, 0)],
			"n": Vector3(-1, 0, 0), "ua": "z", "va": "y"},
		{"r": regs[3], "v": [Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 0, 1), Vector3(0, 0, 1)],
			"n": Vector3(0, 0, 1), "ua": "x", "va": "y"},
		{"r": regs[4], "v": [Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
			"n": Vector3(1, 0, 0), "ua": "z", "va": "y"},
		{"r": regs[5], "v": [Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0), Vector3(0, 0, 0)],
			"n": Vector3(0, 0, -1), "ua": "x", "va": "y"},
	]
	for f in faces:
		var r: Array = f["r"]
		var base := verts.size()
		var corners: Array = f["v"]
		for i in 4:
			var p: Vector3 = corners[i]
			# model space: +x right, +y up, +z front; boxes hang below their origin
			var local := Vector3(
				(p.x - 0.5) * float(w),
				-p.y * float(h),
				(p.z - 0.5) * float(d)) * PIXEL
			verts.append(local)
			norms.append(f["n"])
			var t := Vector2(_axis(p, f["ua"]), _axis(p, f["va"]))
			uvs.append(Vector2(
				(float(r[0]) + t.x * float(r[2])) / TEX,
				(float(r[1]) + t.y * float(r[3])) / TEX))
		idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _mat)
	return mesh


# ================================================================ skins
func set_skin(i: int) -> void:
	skin_index = wrapi(i, 0, SKINS.size())
	_skin_tex = ImageTexture.create_from_image(_make_skin(SKINS[skin_index]))
	_mat.albedo_texture = _skin_tex
	custom = false


func skin_name() -> String:
	if custom:
		return "Custom"
	return str(SKINS[skin_index]["name"])


## The skin texture currently installed, as an Image.
func skin_image() -> Image:
	if _skin_tex == null:
		return null
	return _skin_tex.get_image()


# ================================================================ custom skins
var custom_path := ""
var custom := false


## Applies whichever skin is configured: a real Minecraft PNG when one is set and
## readable, otherwise the generated preset at `preset`.
func refresh_skin(preset: int, path: String) -> void:
	custom_path = path
	skin_index = wrapi(preset, 0, SKINS.size())
	if custom_path != "" and load_skin_file(custom_path) == "":
		return
	set_skin(skin_index)


## Loads a real Minecraft skin file. Accepts the modern 64x64 layout, the legacy
## 64x32 one and HD multiples (128x128, 256x256 ...). Returns "" on success, or a
## short reason on failure.
func load_skin_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "no such file"
	var img := Image.new()
	if img.load(path) != OK:
		return "not a readable image"
	return apply_skin_image(img)


## Installs an already-decoded image as the skin, converting the legacy 2:1 layout
## to the modern one first. Our UVs are normalised, so an HD skin needs no resize.
func apply_skin_image(img: Image) -> String:
	var err := skin_error(img)
	if err != "":
		return err
	if img.get_height() == img.get_width() / 2:
		img = _upgrade_legacy(img)
	img.convert(Image.FORMAT_RGBA8)
	_skin_tex = ImageTexture.create_from_image(img)
	_mat.albedo_texture = _skin_tex
	custom = true
	return ""


## "" when `img` is usable as a Minecraft skin, otherwise a short reason. Static so
## the settings screen can vet a file before committing to it, without having to
## instantiate a whole player model just to ask.
static func skin_error(img: Image) -> String:
	if img == null:
		return "no image"
	var w := img.get_width()
	var h := img.get_height()
	if w < 64 or h < 32:
		return "must be at least 64x32"
	if w % 64 != 0:
		return "width must be a multiple of 64"
	if h == w / 2:
		return ""                       # legacy 64x32, upgraded on install
	if h != w:
		return "must be square or 2:1"
	if h % 64 != 0:
		return "height must be a multiple of 64"
	return ""


## Upgrades a legacy 2:1 skin (64x32 or 128x64) to the modern square layout by
## copying the right arm and leg into the empty left slots, mirrored.
func _upgrade_legacy(src: Image) -> Image:
	var s := src.get_width() / 64
	var out := Image.create(src.get_width(), src.get_width(), false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	out.blit_rect(src, Rect2i(0, 0, src.get_width(), src.get_height()), Vector2i.ZERO)
	_mirror_limb(out, Vector2i(0, 16), Vector2i(16, 48), 4, 12, 4, s)     # leg
	_mirror_limb(out, Vector2i(40, 16), Vector2i(32, 48), 4, 12, 4, s)    # arm
	return out


## Copies one limb unwrap onto another as a true reflection across the body plane:
## every face is flipped left-to-right, and the two side faces swap places because
## the reflection turns the right limb's outside into the left limb's outside.
func _mirror_limb(img: Image, src: Vector2i, dst: Vector2i, w: int, h: int, d: int, s: int) -> void:
	var a: Array = box_regions(src.x, src.y, w, h, d)
	var b: Array = box_regions(dst.x, dst.y, w, h, d)
	var mirror := [0, 1, 4, 3, 2, 5]      # top, bottom have no handedness to swap
	for i in a.size():
		var ra: Array = a[mirror[i]]
		var rb: Array = b[i]
		var rw := int(ra[2]) * s
		var rh := int(ra[3]) * s
		for y in rh:
			for x in rw:
				var sx := int(ra[0]) * s + (rw - 1 - x)
				var sy := int(ra[1]) * s + y
				var dx := int(rb[0]) * s + x
				var dy := int(rb[1]) * s + y
				if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
					continue
				if dx < 0 or dy < 0 or dx >= img.get_width() or dy >= img.get_height():
					continue
				img.set_pixel(dx, dy, img.get_pixel(sx, sy))


func _col(key: String) -> Color:
	return Color(str(SKINS[skin_index][key]))


func _make_skin(p: Dictionary) -> Image:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var skin := Color(str(p["skin"]))
	var hair := Color(str(p["hair"]))
	var shirt := Color(str(p["shirt"]))
	var pants := Color(str(p["pants"]))
	var shoes := Color(str(p["shoes"]))
	var eye := Color(str(p["eye"]))

	# head: hair all over, skin on the face
	_fill(img, 0, 0, 32, 16, hair)
	_fill(img, 8, 8, 8, 8, skin)
	# eyes and mouth on the face
	_fill(img, 9, 12, 2, 1, Color(0.95, 0.95, 0.95))
	_fill(img, 13, 12, 2, 1, Color(0.95, 0.95, 0.95))
	img.set_pixel(10, 12, eye)
	img.set_pixel(13, 12, eye)
	_fill(img, 10, 14, 4, 1, Color(0.45, 0.30, 0.22))
	_fill(img, 8, 8, 8, 1, hair)

	# torso: shirt with a belt at the bottom of the front face (region y 20..32)
	_fill(img, 16, 16, 24, 16, shirt)
	_fill(img, 20, 30, 8, 2, shirt.darkened(0.30))

	# arms: sleeve on top, bare hands at the bottom. Side faces live in the band
	# x in [u, u+16], y in [v+d, v+d+h]; the last 4 rows are the hands.
	for region in [[40, 16], [32, 48]]:
		var u: int = region[0]
		var v: int = region[1]
		_fill(img, u, v, 16, 16, shirt)
		_fill(img, u, v + 12, 16, 4, skin)
		_fill(img, u + 8, v, 4, 4, skin)       # bottom face

	# legs: trousers with shoes
	for region2 in [[0, 16], [16, 48]]:
		var u2: int = region2[0]
		var v2: int = region2[1]
		_fill(img, u2, v2, 16, 16, pants)
		_fill(img, u2, v2 + 12, 16, 4, shoes)
		_fill(img, u2 + 8, v2, 4, 4, shoes)

	# a little cloth noise so the flat colours read as fabric
	var r := RandomNumberGenerator.new()
	r.seed = 4711 + skin_index
	for y in 64:
		for x in 64:
			var c := img.get_pixel(x, y)
			if c.a <= 0.0:
				continue
			var f := 1.0 + r.randf_range(-0.07, 0.07)
			img.set_pixel(x, y, Color(clampf(c.r * f, 0, 1), clampf(c.g * f, 0, 1),
				clampf(c.b * f, 0, 1), 1.0))
	return img


func _fill(img: Image, x: int, y: int, w: int, h: int, c: Color) -> void:
	for j in range(y, y + h):
		for i in range(x, x + w):
			if i >= 0 and j >= 0 and i < img.get_width() and j < img.get_height():
				img.set_pixel(i, j, Color(c.r, c.g, c.b, 1.0))


# ================================================================ animation
## Holds the body at a fixed offset from the look. Used by the verification captures,
## which need to photograph the model square on from a particular side.
func pin_facing(offset: float) -> void:
	pinned = true
	pinned_yaw = offset


func unpin_facing() -> void:
	pinned = false
	_facing_init = false


## What first person has to take off, and why it is two parts rather than one:
##
##  * the **skull**, because the camera rides at the eye line (1.62 up) and the head box
##    spans 1.32 to 1.76, so leaving it on puts the view inside its own head;
##  * the **chest**, because its top and the tops of both arms are one flat, coplanar,
##    same-coloured plane 0.30 below the eye and 0.88 wide. From the eye that plane
##    subtends enough of the screen to cover the bottom third of the view as soon as you
##    look down more than about thirty degrees -- which is most of the time you are mining
##    or building. It does not read as a chest; it reads as a shutter over the ground.
##
## Arms and legs stay. They are what you actually want to see when you look down, they sit
## out at the sides and below, and being narrow they leave the ground in front of you
## visible. The body is still drawn the whole time, so it still casts a shadow.
func set_first_person(v: bool) -> void:
	head.visible = not v
	torso.visible = not v


## speed: horizontal speed in blocks/s. pitch: the player's look pitch.
func animate(delta: float, speed: float, grounded: bool, sneaking: bool,
		flying: bool, pitch: float, swing: float) -> void:
	_swing = swing
	_phase += delta * clampf(speed * 1.7, 0.0, 12.0)
	var amp := clampf(speed / 5.0, 0.0, 1.0) * 0.85
	if not grounded:
		amp = 0.15
	if sneaking and grounded:
		amp *= 0.45

	var s := sin(_phase)
	leg_r.rotation.x = s * amp
	leg_l.rotation.x = -s * amp
	var arm_amp := amp * 0.75
	# a mining swing punches the right arm forward. The arm hangs below its pivot, so
	# a positive x rotation is forward — negative would swing it out behind you.
	arm_r.rotation.x = -s * arm_amp + _swing * 1.9
	arm_l.rotation.x = s * arm_amp
	# idle sway
	arm_r.rotation.z = sin(_phase * 0.5) * 0.04 - 0.04
	arm_l.rotation.z = -sin(_phase * 0.5) * 0.04 + 0.04

	# crouch: tip the chest forward about the hips and drop the shoulders a little
	var lean := -0.32 if (sneaking and grounded) else 0.0
	torso_pivot.rotation.x = lean
	_arm_shoulder.position.y = 12.0 * PIXEL + (lean * 0.15 if lean < 0.0 else 0.0)

	# The head points where you look: up and down, and left and right. The body eases
	# toward the look rather than snapping to it, so a quick turn shows the head
	# leading and the shoulders following. Minecraft clamps the neck at 75 degrees,
	# which is what keeps the body turning to keep up.
	if pinned:
		rotation.y = pinned_yaw
		neck.rotation.y = 0.0
	elif not _facing_init:
		# spawn: start the body already facing the right way instead of spinning
		_facing_init = true
		body_yaw = look_yaw
		rotation.y = 0.0
		neck.rotation.y = 0.0
	else:
		body_yaw = lerp_angle(body_yaw, look_yaw, clampf(delta * 7.0, 0.0, 1.0))
		rotation.y = wrapf(body_yaw - look_yaw, -PI, PI)
		neck.rotation.y = clampf(wrapf(look_yaw - body_yaw, -PI, PI), -HEAD_LIMIT, HEAD_LIMIT)
	# Turned on the NECK, not on the head box: the box's own origin sits at the top
	# of the skull, so rotating it there swings the whole head around its crown. The
	# chest is tilted too, so undo that here to keep the gaze level.
	neck.rotation.x = clampf(pitch, -1.05, 1.05) - lean

	if flying:
		leg_r.rotation.x = 0.15
		leg_l.rotation.x = -0.15
		# An arm hangs below its shoulder pivot, so a positive Z rotation swings its
		# hand toward +X. arm_r is the +X arm and arm_l the -X one, so the two need
		# *opposite* signs to both splay outward -- the same sign on both pulls both
		# hands across the body's midline, which is what made the flying pose look
		# like the arms were folded inward.
		arm_r.rotation.z = 0.5
		arm_l.rotation.z = -0.5