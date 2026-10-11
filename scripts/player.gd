extends Node3D
## Player: AABB voxel collision (no physics bodies), look, digging, building,
## survival stats, creative flight and the held-item model.

const HALF := 0.3
const HEIGHT := 1.8
const EYE := 1.62
const GRAVITY := 32.0
const JUMP_V := 8.95
const WALK := 4.317
const SPRINT := 5.612
const SNEAK := 1.30
const FLY := 11.0
const FLY_FAST := 22.0
const SWIM := 2.6
const SWIM_UP := 3.4        # Space while submerged
const SWIM_DOWN := 2.6      # Shift while submerged, like Minecraft's dive
## A jump taken at the surface rather than a swim stroke. Ordinary jump height
## (about 1.25 blocks) is not quite enough to clear a one-block bank, which is
## exactly the shore the generator puts around every ocean.
const WATER_HOP := 11.0
const REACH := 4.6
const REACH_CREATIVE := 5.4
## How long one creative swing takes. Creative mining is instant, so without a swing
## clock the dig loop fired once per frame and a click took a column of blocks with it.
const CREATIVE_SWING := 0.28
const MAX_HEALTH := 20.0
const MAX_HUNGER := 20.0
const INVULN := 0.5
const DOUBLE_TAP := 0.32
const CLIMB := 3.2

## Where the first-person hand sits, in camera space. Minecraft does not show the body's own
## arm in first person: it draws a hand on the camera, near the bottom right, with the arm
## receding up and forward. A real arm hanging from the shoulder sits 0.66 below the eye, so
## it is never in shot -- posing it forward only fills the screen with a beam. These place a
## camera-mounted arm the way Minecraft does. `SHOULDER` is where the arm's pivot should end
## up; the rig root is derived from it in _ready, because the model's own root is at the feet.
const FP_HAND_SHOULDER := Vector3(0.45, -0.60, -0.35)
const FP_HAND_ROT := Vector3(2.415, 0.705, 0.0)
## The hand's size. It is a compromise between two complaints: at 0.81 a held block covered a
## fifth of the screen, at 0.72 the whole hand read as too small to be a hand at all. This
## sits between them, and `SHOULDER` above is raised from the old -0.75 so the hand sits
## higher in the corner instead of hanging off the bottom edge.
const FP_HAND_SCALE := 0.84
const FP_ARM_LOCAL := Vector3(0.33, 1.32, 0.0)

## A torch in the hand lights the world, the way a "dynamic lights" mod does in
## Minecraft -- and the way you would expect carrying a torch to work. One held light per
## camera mode, because the first-person hand is a viewmodel on the camera and the body's
## arm is out in the world.
const HELD_LIGHT := {
	"color": Color(1.0, 0.80, 0.52),
	"range": 13.0,
	"energy": 3.2,
	"offset": Vector3(0.0, -0.35, -0.15),
}

## How far in front of the body's centre the first-person camera sits, in blocks.
##
## This is what stops the chest from getting in the way. Seen from directly above, its flat
## top is a lid across the lower view; seen from in front of it, it is a chest, and -- more
## usefully -- the line of sight down to the legs and feet then passes *in front* of the
## chest instead of through it, so the chest stops hiding them.
##
## It cannot simply be pushed further without a decision being made, and this value is past
## that line. The body is only 0.22 deep, so from about 0.20 on, the chest is out of frame
## when you look down -- and looking down is the only time you would see it. That is
## accepted here on purpose: Minecraft draws no first-person body at all, so an eye pushed
## out to where the face is, with the chest gone, is *closer* to Minecraft than a centred
## eye that keeps a slab of shirt in the corner. Legs and feet still come into view when you
## look steeply down, because they sit a full 1.5 below the eye.
##
## It is also well inside the player's own 0.3 half-width, so the camera can never end up
## inside a wall the player is not already inside -- and it clears the chest's crouch lean,
## which swings the chest forward to about z = -0.21.
##
## What it does *not* survive is a wall you are standing against, and `_clear_of_blocks`
## deals with that: standing against a block puts its face 0.3 away, so a fixed 0.28 leaves
## the eye 0.02 from it, inside the camera's near plane, and the world goes see-through.
## The offset is therefore pulled in per-frame to whatever room there actually is.
const FP_CAM_FORWARD := 0.28

signal health_changed
signal hunger_changed
signal hotbar_changed
signal selected_changed
signal died
signal stats_changed(name: String)
signal xp_changed

## Where the camera sits. F5 cycles FIRST -> THIRD_BACK -> SECOND_FRONT.
enum Cam { FIRST, THIRD_BACK, SECOND_FRONT }
## Emitted while a block is being chipped at, once per dig tick.
signal block_hit(pos: Vector3i, id: int)
## Emitted the moment a block is removed, before anything is dropped.
signal block_broken(pos: Vector3i, id: int)
## Emitted when the player throws something out of the hotbar with Q.
signal item_thrown(id: int, count: int)

var world
var camera: Camera3D
var cam_pivot: Node3D
var model
## The arm-only copy of the model parented to the camera; see FP_HAND_POS.
var fp_hand
## The two held-torch lights: one on the camera hand, one on the body's right arm.
var held_light_fp: OmniLight3D
var held_light_body: OmniLight3D

var velocity := Vector3.ZERO
var on_ground := false
var flying := false
var creative := true
var input_enabled := true
var cam_mode := Cam.FIRST

## Derived from cam_mode so the old `third_person = true` call sites keep working.
var third_person: bool:
	get:
		return cam_mode != Cam.FIRST
	set(v):
		if not v:
			cam_mode = Cam.FIRST
		elif cam_mode == Cam.FIRST:
			cam_mode = Cam.THIRD_BACK

var health := MAX_HEALTH
var hunger := MAX_HUNGER
var exhaustion := 0.0
var air := 12.0
var damage_timer := 0.0
var regen_timer := 0.0
var dead := false
## Experience: `xp` is the progress into the current level, `level` the level itself.
## Levels are what the enchanting table spends; the points are just the bar.
var xp := 0
var level := 0

var yaw := 0.0
var pitch := 0.0
var bob := 0.0
var swing := 0.0
var swing_t := 0.0

var hotbar: Array = []       # 9 x {id:int, count:int}
var inventory: Array = []    # 27 x {id:int, count:int}
var crafting: Array = []     # 3x3 grid, 9 x {id, count}
var armor: Array = []        # 4 equipped pieces: helmet, chest, legs, boots
var selected := 0
var cursor_stack: Dictionary = {"id": 0, "count": 0}
## Light crafting-table gating: the inventory always shows the 3x3 grid, but a recipe
## whose shape is bigger than 2x2 only matches while this is true — which main sets when
## the player opens the grid from an actual crafting table.
var table_available := false

var _dig_progress := 0.0
var _dig_target := Vector3i(-9999, 0, 0)
var _place_cooldown := 0.0
var _break_cooldown := 0.0
var _airborne := false
var _fall_y := 0.0
var _last_space := -10.0
var _last_w_tap := -10.0
var _invuln := 0.0
var _step_dist := 0.0
var _sprint_toggle := false
var _reach := REACH
var mobs = null              # injected by main: the melee swing's mob raycast
var _starve_timer := 0.0

var _searching := {}


func _ready() -> void:
	for i in 9:
		hotbar.append(item_stack(0, 0))
	for i in 27:
		inventory.append(item_stack(0, 0))
	for i in 9:
		crafting.append(item_stack(0, 0))
	for i in 4:
		armor.append(item_stack(0, 0))
	cam_pivot = Node3D.new()
	cam_pivot.position = Vector3(0, EYE, 0)
	add_child(cam_pivot)
	camera = Camera3D.new()
	camera.fov = Settings.fov
	camera.near = 0.05
	camera.far = 900.0
	cam_pivot.add_child(camera)

	# The body is on screen in every camera mode, first person included: that is what you
	# see when you look down, and what casts your shadow.
	model = load("res://scripts/player_model.gd").new()
	model.name = "Body"
	add_child(model)
	refresh_skin()

	# The first-person hand: a second, arm-only copy of the model, parented to the camera.
	# The body still supplies the chest, legs and left arm you see when looking down; only
	# its right arm is hidden in first person, so the hand never shows up twice.
	fp_hand = load("res://scripts/player_model.gd").new()
	fp_hand.name = "FirstPersonHand"
	cam_pivot.add_child(fp_hand)
	fp_hand.rotation = FP_HAND_ROT
	fp_hand.scale = Vector3.ONE * FP_HAND_SCALE
	# the model's root is at the feet, so slide the rig back by where the shoulder sits
	# inside the model (rotated and scaled) to land the shoulder where we want it
	fp_hand.position = FP_HAND_SHOULDER \
		- Basis.from_euler(FP_HAND_ROT) * (FP_ARM_LOCAL * FP_HAND_SCALE)
	fp_hand.head.visible = false
	fp_hand.torso.visible = false
	fp_hand.arm_l.visible = false
	fp_hand.leg_r.visible = false
	fp_hand.leg_l.visible = false
	# the camera hand is a viewmodel, not part of the world: it must not throw a shadow
	# onto the ground a metre in front of the player, which is what an arm pinned to the
	# camera would otherwise do
	for part in [fp_hand.head, fp_hand.torso, fp_hand.arm_r, fp_hand.arm_l,
			fp_hand.leg_r, fp_hand.leg_l]:
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	refresh_skin()

	# the torch you are carrying. Two nodes, because the hand you can see in first person
	# is a viewmodel on the camera while the one you can see in third person is the body's
	# own arm; only the one belonging to the current camera mode is switched on.
	held_light_fp = _make_held_light()
	held_light_fp.position = HELD_LIGHT["offset"]
	fp_hand.arm_r.add_child(held_light_fp)
	held_light_body = _make_held_light()
	held_light_body.position = HELD_LIGHT["offset"]
	model.arm_r.add_child(held_light_body)

	refresh_hand()
	# the held model must follow *every* change to the hotbar: picking a block up
	# into the selected slot, running a stack out while building, dropping one, or
	# moving stacks around in the inventory screen
	hotbar_changed.connect(refresh_hand)


static func item_stack(id: int, count: int) -> Dictionary:
	return {"id": id, "count": count}


func _make_held_light() -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = HELD_LIGHT["color"]
	l.omni_range = HELD_LIGHT["range"]
	l.light_energy = HELD_LIGHT["energy"]
	l.omni_attenuation = 0.85
	l.shadow_enabled = false
	l.visible = false
	return l


## Switches the carried light on when the held item is something that glows (a torch, a
## glowstone block, a lamp) and off otherwise. Called from `refresh_hand`, which already
## runs on every hotbar change.
func _refresh_held_light() -> void:
	var id := selected_id()
	var lit: bool = id > 0 and Blocks.emission[id] > 0
	# the camera hand only exists in first person, the body's arm only outside it
	var first: bool = cam_mode == Cam.FIRST
	if held_light_fp != null:
		held_light_fp.visible = lit and first
	if held_light_body != null:
		held_light_body.visible = lit and not first


# ================================================================ setup
func attach(w) -> void:
	world = w


func set_input_enabled(v: bool) -> void:
	input_enabled = v
	if not v:
		velocity.x = 0.0
		velocity.z = 0.0
		_dig_progress = 0.0


func apply_settings() -> void:
	if camera != null:
		camera.fov = Settings.fov
	refresh_skin()


## Re-applies the configured skin: an imported Minecraft PNG wins over the preset.
func refresh_skin() -> void:
	if model != null:
		model.refresh_skin(Settings.player_skin, Settings.player_skin_path)
	if fp_hand != null:
		fp_hand.refresh_skin(Settings.player_skin, Settings.player_skin_path)


func place_at(pos: Vector3) -> void:
	global_position = pos
	# never leave the player embedded in terrain
	var guard := 0
	while world != null and _collides_at(global_position) and guard < 64:
		global_position.y += 1.0
		guard += 1
	velocity = Vector3.ZERO
	_fall_y = global_position.y
	_airborne = false


func respawn(pos: Vector3) -> void:
	health = MAX_HEALTH
	hunger = MAX_HUNGER
	exhaustion = 0.0
	air = 12.0
	dead = false
	velocity = Vector3.ZERO
	place_at(pos)
	health_changed.emit()
	hunger_changed.emit()


func reset_inventory() -> void:
	for i in 9:
		hotbar[i] = item_stack(0, 0)
	for i in 27:
		inventory[i] = item_stack(0, 0)
	for i in 9:
		crafting[i] = item_stack(0, 0)
	for i in 4:
		armor[i] = item_stack(0, 0)
	cursor_stack = item_stack(0, 0)
	selected = 0
	hotbar_changed.emit()
	selected_changed.emit()
	refresh_hand()


# ================================================================ helpers
func eye_position() -> Vector3:
	return cam_pivot.global_position


func look_dir() -> Vector3:
	# taken from the aim pivot, never from the camera: in front view the camera
	# itself is rotated 180 degrees to look back at the player
	return -cam_pivot.global_transform.basis.z


func cycle_camera() -> void:
	cam_mode = (cam_mode + 1) % 3
	_apply_view_visibility()


func camera_mode_name() -> String:
	match cam_mode:
		Cam.THIRD_BACK:
			return "third person (behind)"
		Cam.SECOND_FRONT:
			return "second person (front)"
	return "first person"


## What the camera is allowed to see, for the current mode. Applied straight away on a
## mode change or a hotbar change rather than on the next physics frame, so F5 feels
## instant and the state is checkable without a world.
##
## The body is never hidden as a whole, first person included: the chest, legs and left arm
## all stay on screen, so looking down shows your own body and the body always casts a
## shadow. Only the skull comes off in first person -- the camera sits inside it -- and the
## body's right arm gives way to the camera-mounted hand rig (`fp_hand`).
func _apply_view_visibility() -> void:
	if model != null:
		model.set_first_person(cam_mode == Cam.FIRST)
	if fp_hand != null:
		fp_hand.visible = cam_mode == Cam.FIRST
	# the carried torch follows the hand from one camera mode to the other
	_refresh_held_light()


## Pulls the camera in when a wall sits between it and the player. Without this the
## camera ends up inside the terrain and you see straight through the world.
func _free_camera_distance(local_dir: Vector3, want: float) -> float:
	if world == null:
		return want
	var dir: Vector3 = cam_pivot.global_transform.basis * local_dir
	if dir.length_squared() < 0.0001:
		return want
	var origin := eye_position()
	var hit: Dictionary = world.raycast(origin, dir.normalized(), want + 0.6)
	if hit.is_empty():
		return want
	var p: Vector3i = hit["pos"]
	return clampf(origin.distance_to(Vector3(p)) - 0.4, 0.35, want)


## Pulls the first-person forward offset in when a block is in the way.
##
## Without this the offset walks the eye into the wall you are standing against: at the full
## 0.28 the eye ends up 0.02 from a block face, which is inside the camera's 0.05 near plane,
## so the wall is clipped away and you see straight through the world. Crouching made it
## worse still, because the eye also drops towards the blocks at knee height.
##
## The margin is measured from where the ray meets the block, so the eye stops 0.12 short of
## the face -- comfortably outside the near plane. It is never backed off past the body's
## own centre, so the eye cannot slide back behind the head.
func _clear_of_blocks(want: float, eye_y: float) -> float:
	if want <= 0.0 or world == null:
		return want
	var look := -cam_pivot.global_transform.basis.z
	look.y = 0.0
	if look.length_squared() < 0.0001:
		return want
	look = look.normalized()
	var origin := global_position + Vector3(0.0, eye_y, 0.0)
	# the player's own half-width is 0.3, so a solid block can never be nearer than that;
	# reaching a little past the offset just gives the ray something to find
	var hit: Dictionary = world.raycast(origin, look, want + 0.34)
	if hit.is_empty():
		return want
	var p: Vector3i = hit["pos"]
	var face := origin.distance_to(Vector3(p) + Vector3(0.5, 0.5, 0.5)) - 0.5
	return clampf(face - 0.12, 0.0, want)


func feet_aabb() -> AABB:
	var p := global_position
	return AABB(Vector3(p.x - HALF, p.y, p.z - HALF), Vector3(HALF * 2, HEIGHT, HALF * 2))


func _collides_at(p: Vector3) -> bool:
	var box := AABB(Vector3(p.x - HALF, p.y, p.z - HALF), Vector3(HALF * 2, HEIGHT, HALF * 2))
	var x0 := floori(box.position.x)
	var x1 := floori(box.position.x + box.size.x - 0.0001)
	var y0 := floori(box.position.y)
	var y1 := floori(box.position.y + box.size.y - 0.0001)
	var z0 := floori(box.position.z)
	var z1 := floori(box.position.z + box.size.z - 0.0001)
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for z in range(z0, z1 + 1):
				# The span is the part of the cell the block actually fills: a full cube
				# is (0, 1), a slab half of that, a carpet a sixteenth. Testing the real
				# span, rather than "is it solid", is what lets you stand on a slab and
				# walk under a trapdoor mounted on a ceiling.
				var span: Vector2 = world.collide_span(x, y, z)
				if span == Vector2.ZERO:
					continue
				var lo := float(y) + span.x
				var hi := float(y) + span.y
				if box.position.y < hi - 0.0001 and box.position.y + box.size.y > lo + 0.0001:
					return true
	return false


## How high the player can step without jumping: enough to mount a slab, a stair or a
## carpet, not enough to mount a full block (which still needs a jump, as in Minecraft).
const STEP_HEIGHT := 0.55


## Tries to walk up onto a low block after a horizontal move was blocked. Raises the
## player by up to STEP_HEIGHT, taking the smallest lift that frees the move, and only
## while on the ground, so a jump is still needed for a full block and for anything with
## no headroom above it. Returns true when the step succeeded and the move stands.
func _try_step() -> bool:
	if not on_ground or flying:
		return false
	var y := global_position.y
	# ascending, so the move takes the smallest lift that clears the obstacle
	for h in [0.0625, 0.1875, 0.5, STEP_HEIGHT]:
		global_position.y = y + h
		if not _collides_at(global_position):
			return true
	global_position.y = y
	return false


func in_water() -> bool:
	var p := global_position
	return world.is_liquid(floori(p.x), floori(p.y + 0.4), floori(p.z)) \
		and not world.is_lava(floori(p.x), floori(p.y + 0.4), floori(p.z))


func head_in_water() -> bool:
	var p := eye_position()
	return world.is_liquid(floori(p.x), floori(p.y), floori(p.z)) \
		and not world.is_lava(floori(p.x), floori(p.y), floori(p.z))


## Lava is a liquid too, so `in_water` had to learn to exclude it: swimming and burning
## are not the same thing.
func in_lava() -> bool:
	var p := global_position
	return world.is_lava(floori(p.x), floori(p.y + 0.4), floori(p.z)) \
		or world.is_lava(floori(p.x), floori(p.y + 1.2), floori(p.z))


## True when any cell the player's body occupies is a ladder. Used for climbing and to
## suppress fall damage while hanging on one.
func on_ladder() -> bool:
	var box := feet_aabb()
	var x0 := floori(box.position.x)
	var x1 := floori(box.position.x + box.size.x - 0.0001)
	var y0 := floori(box.position.y)
	var y1 := floori(box.position.y + box.size.y - 0.0001)
	var z0 := floori(box.position.z)
	var z1 := floori(box.position.z + box.size.z - 0.0001)
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for z in range(z0, z1 + 1):
				if world.get_block(x, y, z) == Blocks.LADDER:
					return true
	return false


# ================================================================ input
func _input(event: InputEvent) -> void:
	# Mouse look lives in _input(), not _unhandled_input(): GUI controls (the menu
	# and HUD layers) get first refusal on mouse events and would otherwise swallow
	# every InputEventMouseMotion before the player ever sees it.
	if not input_enabled or dead:
		return
	# No mouse_mode test here: with the mouse unlocked the look still has to work from
	# relative motion, and while a panel is up `input_enabled` is already false, so that
	# is what keeps a menu from turning the camera.
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var s := Settings.sensitivity
		yaw -= mm.relative.x * s
		pitch -= mm.relative.y * s * (-1.0 if Settings.invert_y else 1.0)
		pitch = clampf(pitch, -PI / 2 + 0.01, PI / 2 - 0.01)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cycle_hotbar(-1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cycle_hotbar(1)


func _physics_process(delta: float) -> void:
	if world == null:
		return
	rotation.y = yaw
	cam_pivot.rotation.x = pitch

	if dead:
		velocity.y -= GRAVITY * delta
		_move_axis_y(velocity.y * delta, delta)
		global_position += Vector3(velocity.x, 0, velocity.z) * delta
		return

	if not input_enabled:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	var water := in_water()
	var lava := in_lava()
	# sprint: hold Ctrl, or double-tap forward like Minecraft
	if Input.is_action_just_pressed("forward"):
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_w_tap < DOUBLE_TAP:
			_sprint_toggle = true
		_last_w_tap = now
	if not Input.is_action_pressed("forward"):
		_sprint_toggle = false
	var want_sprint := (Input.is_action_pressed("sprint") or _sprint_toggle) \
		and Input.is_action_pressed("forward") and hunger > 6.0
	var want_sneak := Input.is_action_pressed("sneak")
	var move := Vector3.ZERO
	var yaw_basis := Basis(Vector3.UP, yaw)
	if Input.is_action_pressed("forward"):
		move += yaw_basis * Vector3(0, 0, -1)
	if Input.is_action_pressed("back"):
		move += yaw_basis * Vector3(0, 0, 1)
	if Input.is_action_pressed("left"):
		move += yaw_basis * Vector3(-1, 0, 0)
	if Input.is_action_pressed("right"):
		move += yaw_basis * Vector3(1, 0, 0)
	if move.length() > 0.001:
		move = move.normalized()

	var speed := WALK
	if flying:
		speed = FLY_FAST if want_sprint else FLY
	elif lava:
		# lava is thick: you barely make headway through it
		speed = SWIM * 0.3
	elif water:
		speed = SWIM
	elif want_sneak:
		speed = SNEAK
	elif want_sprint:
		speed = SPRINT
	if flying and want_sneak:
		speed = FLY * 0.4

	var target := move * speed
	# Ground control is snappy, the way Minecraft's is. Air control is deliberately weak:
	# in Minecraft a jump commits you to the direction you took off in, and being able to
	# steer freely through the air makes every gap trivially easy and reads as "floaty".
	var accel := 12.0 if (on_ground or flying or water) else 1.8
	velocity.x = lerpf(velocity.x, target.x, clampf(accel * delta, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, target.z, clampf(accel * delta, 0.0, 1.0))

	var jump_pressed := Input.is_action_just_pressed("jump")
	if jump_pressed:
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_space < DOUBLE_TAP:
			if creative:
				flying = not flying
				velocity.y = 0.0
		_last_space = now

	if flying:
		var up := 0.0
		if Input.is_action_pressed("jump"):
			up += 1.0
		if Input.is_action_pressed("sneak"):
			up -= 1.0
		velocity.y = lerpf(velocity.y, up * speed, clampf(10.0 * delta, 0.0, 1.0))
	elif lava:
		# you sink through lava and cannot stroke back out of it, in either direction
		velocity.y = lerpf(velocity.y, -1.4, clampf(6.0 * delta, 0.0, 1.0))
		velocity.x *= 0.6
		velocity.z *= 0.6
	elif water:
		# Space swims up and Shift dives; with the head clear of the water Space
		# becomes a real jump instead, so you can climb out onto the bank
		if Input.is_action_pressed("jump"):
			velocity.y = SWIM_UP if head_in_water() else WATER_HOP
		elif Input.is_action_pressed("sneak"):
			velocity.y = -SWIM_DOWN
		else:
			velocity.y -= GRAVITY * 0.22 * delta
		velocity.y = clampf(velocity.y, -6.0, WATER_HOP)
		# drag only the horizontal axis, or the stroke above would be damped away
		velocity.x *= 0.94
		velocity.z *= 0.94
	elif on_ladder():
		# climbing: Space goes up, Shift goes down, and letting go holds position
		var up := 0.0
		if Input.is_action_pressed("jump"):
			up = CLIMB
		elif Input.is_action_pressed("sneak"):
			up = -CLIMB
		velocity.y = up
	else:
		velocity.y -= GRAVITY * delta
		if (on_ground or _airborne) and Input.is_action_pressed("jump") and on_ground:
			velocity.y = JUMP_V
			exhaustion += 0.2

	var was_ground := on_ground
	_move_axis_x(velocity.x * delta)
	_move_axis_z(velocity.z * delta)
	on_ground = false
	_move_axis_y(velocity.y * delta, delta)

	if on_ground and not was_ground:
		_land()
	if not on_ground and velocity.y > 0.0:
		pass

	_update_fall(delta)
	_update_stats(delta, water)
	_update_view(delta, move.length() > 0.001, want_sneak)
	_update_swing(delta)
	_update_interaction(delta)
	_update_plates()

	if global_position.y < float(VoxelTerrain.MIN_Y) - 8.0:
		global_position.y = world.rescue_y(floori(global_position.x), floori(global_position.z))
		hurt(4.0)


## A pressure plate is a sensor: it reads whoever is standing on it. Only the cells
## the player's footprint actually covers, so walking past one does not trigger it.
func _update_plates() -> void:
	if world.circuit == null or not on_ground:
		return
	var box := feet_aabb()
	var y := floori(global_position.y) - 1
	for x in range(floori(box.position.x), floori(box.position.x + box.size.x - 0.001) + 1):
		for z in range(floori(box.position.z), floori(box.position.z + box.size.z - 0.001) + 1):
			if world.get_block(x, y, z) == Blocks.PRESSURE_PLATE:
				world.circuit.set_plate(Vector3i(x, y, z), true)


func _move_axis_x(amount: float) -> void:
	if amount == 0.0:
		return
	var n := maxi(1, int(ceil(absf(amount) / 0.2)))
	var step := amount / float(n)
	for i in n:
		var before := global_position
		global_position.x += step
		if _collides_at(global_position):
			# a low block is stepped onto rather than stopped by; a full block is not
			if _try_step():
				continue
			global_position = before
			velocity.x = 0.0
			return


func _move_axis_z(amount: float) -> void:
	if amount == 0.0:
		return
	var n := maxi(1, int(ceil(absf(amount) / 0.2)))
	var step := amount / float(n)
	for i in n:
		var before := global_position
		global_position.z += step
		if _collides_at(global_position):
			if _try_step():
				continue
			global_position = before
			velocity.z = 0.0
			return


func _move_axis_y(amount: float, delta: float) -> void:
	if amount == 0.0:
		if not flying:
			on_ground = false
		return
	var n := maxi(1, int(ceil(absf(amount) / 0.2)))
	var step := amount / float(n)
	for i in n:
		var before := global_position
		global_position.y += step
		if _collides_at(global_position):
			global_position = before
			if step < 0.0:
				on_ground = true
			velocity.y = 0.0
			return


func _land() -> void:
	if _airborne:
		_airborne = false
		var fall := _fall_y - global_position.y
		if fall > 3.2 and not flying and not creative:
			var dmg := fall - 3.2
			if dmg > 0.5:
				hurt(dmg)
				Sfx.play("hurt", -4.0)
	var block: int = world.get_block(floori(global_position.x), floori(global_position.y - 0.2),
		floori(global_position.z))
	Sfx.play_varied(Sfx.step_sound_for(block), -12.0, 0.1)


func _update_fall(delta: float) -> void:
	if on_ground or flying or in_water() or on_ladder():
		if _airborne:
			_airborne = false
		_fall_y = global_position.y
		return
	if not _airborne:
		_airborne = true
		_fall_y = global_position.y
	else:
		_fall_y = maxf(_fall_y, global_position.y)


func _update_stats(delta: float, water: bool) -> void:
	if _invuln > 0.0:
		_invuln -= delta
	# footsteps
	if on_ground and Vector2(velocity.x, velocity.z).length() > 1.2:
		_step_dist += Vector2(velocity.x, velocity.z).length() * delta
		if _step_dist > 2.4:
			_step_dist = 0.0
			var b: int = world.get_block(floori(global_position.x), floori(global_position.y - 0.2),
				floori(global_position.z))
			Sfx.play_varied(Sfx.step_sound_for(b), -16.0, 0.14)

	# lava burns. It is a liquid, so it has to be handled before the air/drowning branch,
	# which now correctly ignores it.
	if in_lava():
		_hurt_tick(4.0, delta)
		air = 12.0

	# drowning
	if head_in_water():
		air -= delta
		if air <= 0.0:
			air = 0.0
			_hurt_tick(2.0, delta)
		stats_changed.emit("air")
	else:
		if air < 12.0:
			air = minf(12.0, air + delta * 4.0)
			stats_changed.emit("air")

	# hunger: walking and sprinting burn food, a nearly full bar slowly heals you,
	# and an empty one hurts. Creative mode has no hunger, exactly like Minecraft.
	if not creative and not dead:
		var hspeed := Vector2(velocity.x, velocity.z).length()
		if on_ground and hspeed > 1.0:
			exhaustion += (0.1 if hspeed > WALK + 0.3 else 0.01) * hspeed * delta
		while exhaustion >= 4.0:
			exhaustion -= 4.0
			hunger = maxf(0.0, hunger - 1.0)
			hunger_changed.emit()
		if hunger <= 0.0:
			_starve_timer += delta
			if _starve_timer >= 4.0:
				_starve_timer = 0.0
				hurt(1.0)
		else:
			_starve_timer = 0.0

	# slow regeneration after a quiet period, but only while well fed
	if damage_timer > 0.0:
		damage_timer -= delta
	elif health < MAX_HEALTH and not dead and (creative or hunger >= 18.0):
		regen_timer += delta
		if regen_timer > 3.5:
			regen_timer = 0.0
			health = minf(MAX_HEALTH, health + 1.0)
			exhaustion += 6.0
			health_changed.emit()


var _hurt_accum := 0.0


func _hurt_tick(amount: float, delta: float) -> void:
	_hurt_accum += delta
	if _hurt_accum >= 0.9:
		_hurt_accum = 0.0
		hurt(amount)


func _update_view(delta: float, moving: bool, sneaking: bool) -> void:
	var target_bob := 0.0
	if Settings.view_bob and moving and on_ground and not flying:
		bob += delta * (10.0 if velocity.length() > WALK + 0.5 else 8.0)
		target_bob = sin(bob) * 0.045
	else:
		bob = lerpf(bob, 0.0, clampf(delta * 6.0, 0.0, 1.0))
	var eye := EYE + (target_bob if Settings.view_bob else 0.0)
	# Crouching drops the eye 0.35, which is Minecraft's own figures exactly: its eye sits
	# at 1.62 standing and 1.27 crouched.
	#
	# Deliberately *not* guarded by `not flying`, the way the rest of the crouch is. In
	# creative, double-tapping Space turns on flight, and in flight Shift descends -- so the
	# crouch never happened and the view never dipped, which reads as "sneaking is broken"
	# rather than as "you are flying". Dipping in flight too costs nothing and means Shift
	# always answers visually.
	if sneaking:
		eye -= 0.35
	# First person leans the eye forward to the face; every other mode keeps it centred on
	# the body, because the camera node itself is what gets offset out there. See
	# FP_CAM_FORWARD for why the first-person eye is not simply at the body's centre.
	var eye_fwd := FP_CAM_FORWARD if cam_mode == Cam.FIRST else 0.0
	if sneaking:
		# ...and a crouch pulls it back toward the body as well as down. Crouching with the
		# eye still out at the face leaves it hanging over your knees.
		eye_fwd *= 0.35
	eye_fwd = _clear_of_blocks(eye_fwd, eye)
	cam_pivot.position = cam_pivot.position.lerp(Vector3(0, eye, -eye_fwd),
		clampf(delta * 14.0, 0.0, 1.0))
	cam_pivot.position.x = cos(bob * 0.5) * 0.02 * (1.0 if moving else 0.0)

	# sprint feedback: a small field-of-view kick, like Minecraft
	var sprinting := moving and not sneaking and on_ground and not flying \
		and Vector2(velocity.x, velocity.z).length() > WALK + 0.4
	var target_fov := Settings.fov + (9.0 if sprinting else 0.0)
	camera.fov = lerpf(camera.fov, target_fov, clampf(delta * 7.0, 0.0, 1.0))

	if model != null:
		model.look_yaw = yaw
		model.animate(delta, Vector2(velocity.x, velocity.z).length(), on_ground,
			sneaking, flying, pitch, swing)
	# the camera is only ever moved and turned here; the aim stays on cam_pivot, so
	# mining and placing keep working while looking at yourself from the front
	match cam_mode:
		Cam.THIRD_BACK:
			camera.rotation = Vector3.ZERO
			camera.position = Vector3(0.0, 0.28,
				_free_camera_distance(Vector3(0.0, 0.28, 1.0), 3.6))
		Cam.SECOND_FRONT:
			camera.rotation = Vector3(0.0, PI, 0.0)
			camera.position = Vector3(0.0, 0.15,
				-_free_camera_distance(Vector3(0.0, 0.15, -1.0), 3.0))
		_:
			camera.rotation = Vector3.ZERO
			camera.position = Vector3.ZERO


## The mining swing clock. It drives the model's right arm, which is the arm you see in
## every camera mode now, so this has to run whether or not the body used to be drawn.
func _update_swing(delta: float) -> void:
	_apply_view_visibility()
	if swing_t > 0.0:
		swing_t = maxf(0.0, swing_t - delta * 4.5)
		swing = sin((1.0 - swing_t) * PI) * 0.9
	else:
		swing = lerpf(swing, 0.0, clampf(delta * 8.0, 0.0, 1.0))
	# the camera hand punches on the same clock as the body's arm
	if fp_hand != null:
		fp_hand.arm_r.rotation.x = -swing * 0.85


func _update_interaction(delta: float) -> void:
	if _place_cooldown > 0.0:
		_place_cooldown -= delta
	if _break_cooldown > 0.0:
		_break_cooldown -= delta
	if not input_enabled:
		return
	_reach = REACH_CREATIVE if creative else REACH

	if Input.is_action_just_pressed("drop"):
		drop_selected()

	if Input.is_action_pressed("attack"):
		var hit: Dictionary = world.raycast(eye_position(), look_dir(), _reach)
		# A swing hits whatever is nearest under the crosshair. A mob standing in front of
		# a block is hit instead of the block; a mob behind a wall is not, so you cannot dig
		# through terrain into a mob's face, and a mob can never make digging stall.
		if mobs != null:
			var m = mobs.raycast_mob(eye_position(), look_dir(), _reach)
			if m != null:
				var mob_d: float = eye_position().distance_to(
					m.global_position + Vector3(0, float(m._h) * 0.5, 0))
				var block_d := _reach + 1.0
				if not hit.is_empty():
					var bp0: Vector3i = hit["pos"]
					block_d = eye_position().distance_to(Vector3(bp0) + Vector3(0.5, 0.5, 0.5))
				if mob_d <= block_d:
					if _break_cooldown <= 0.0:
						_break_cooldown = 0.35
						swing_t = 1.0
						Sfx.play_varied("dig", -10.0, 0.12)
						m.hurt_mob(Gear.damage_of(selected_id())
							+ Gear.ench_damage_bonus(hotbar[selected]), global_position)
						if Gear.is_tool(selected_id()):
							tool_damage_selected(1)
					_dig_progress = 0.0
					return
		if hit.is_empty():
			_dig_progress = 0.0
			return
		var pos: Vector3i = hit["pos"]
		var id: int = world.get_block(pos.x, pos.y, pos.z)
		var hard := Blocks.hardness[id]
		if hard < 0.0:
			_dig_progress = 0.0
			return
		if creative:
			# One swing, one block. Without this the loop broke a block on *every*
			# frame the button was down, so a single click tunnelled straight through
			# whatever stood behind the block you aimed at.
			if _break_cooldown <= 0.0:
				_break_block(pos, id)
				_break_cooldown = CREATIVE_SWING
			_dig_progress = 0.0
			return
		if pos != _dig_target:
			_dig_target = pos
			_dig_progress = 0.0
		_dig_progress += delta
		if fmod(_dig_progress, 0.22) < delta:
			Sfx.play_varied("dig", -14.0, 0.15)
			block_hit.emit(pos, id)
		swing_t = maxf(swing_t, 0.35)
		if _dig_progress >= _dig_need(id):
			_break_block(pos, id)
			_dig_progress = 0.0
			# a tool wears with every block it breaks
			if Gear.is_tool(selected_id()):
				tool_damage_selected(1)
	else:
		_dig_progress = 0.0
		_dig_target = Vector3i(-9999, 0, 0)

	if Input.is_action_pressed("use") and _place_cooldown <= 0.0:
		_place_cooldown = 0.20
		if not eat_selected():
			_try_place()

	if Input.is_action_just_pressed("pick"):
		var hit2: Dictionary = world.raycast(eye_position(), look_dir(), _reach)
		if not hit2.is_empty():
			var p: Vector3i = hit2["pos"]
			pick_block(world.get_block(p.x, p.y, p.z))


func _break_block(pos: Vector3i, id: int) -> void:
	# a bed is two cells: break either half and the other goes with it, or you are left
	# with a headless mattress you cannot sleep in and cannot pick up as a whole
	if id == Blocks.BED or id == Blocks.BED_HEAD:
		var bf: Vector3i = world.facing_override.get(pos, Vector3i(0, 0, 1))
		var other: Vector3i = pos + bf if id == Blocks.BED else pos - bf
		var want: int = Blocks.BED_HEAD if id == Blocks.BED else Blocks.BED
		if world.get_block(other.x, other.y, other.z) == want:
			world.set_block(other.x, other.y, other.z, Blocks.AIR)
	world.set_block(pos.x, pos.y, pos.z, Blocks.AIR)
	Sfx.play("break", -6.0, randf_range(0.92, 1.08))
	swing_t = 1.0
	# the drop, the particles and the leaves-apple roll all live in main.gd, which
	# owns the item-entity and particle managers
	block_broken.emit(pos, id)


## A bucket picks a fluid up or pours one out, in place: the held bucket becomes its
## filled or empty self rather than leaving a hole in the hotbar. Only *sources* can be
## scooped -- a flowing tongue is not a thing you can pick up, which is what stops one
## bucket from deleting an ocean.
func _bucket_action(hit: Dictionary, hp: Vector3i, hid: int) -> bool:
	var id := selected_id()
	if id == Blocks.ITEM_BUCKET:
		if (hid == Blocks.WATER or hid == Blocks.LAVA) and world.is_fluid_source(hp):
			var filled := Blocks.ITEM_WATER_BUCKET if hid == Blocks.WATER \
				else Blocks.ITEM_LAVA_BUCKET
			world.set_block(hp.x, hp.y, hp.z, Blocks.AIR)
			swap_selected(filled)
			Sfx.play("splash", -8.0, randf_range(0.9, 1.1))
			swing_t = 0.9
			return true
		return false
	if id != Blocks.ITEM_WATER_BUCKET and id != Blocks.ITEM_LAVA_BUCKET:
		return false
	var cell: Vector3i = hit["prev"]
	if cell.y < VoxelTerrain.MIN_Y or cell.y >= VoxelTerrain.MAX_Y:
		return false
	var existing: int = world.get_block(cell.x, cell.y, cell.z)
	if existing != Blocks.AIR and Blocks.kind[existing] != Blocks.K_CROSS:
		return false
	# never pour lava into the space you are standing in
	if feet_aabb().intersects(AABB(Vector3(cell), Vector3.ONE)):
		return false
	var fluid_id := Blocks.WATER if id == Blocks.ITEM_WATER_BUCKET else Blocks.LAVA
	world.set_block(cell.x, cell.y, cell.z, fluid_id)
	swap_selected(Blocks.ITEM_BUCKET)
	Sfx.play("splash", -8.0, randf_range(0.9, 1.1))
	swing_t = 0.9
	return true


## Replaces what the selected slot holds, keeping its size. Used by the bucket, which
## swaps itself for its filled or empty form in place.
func swap_selected(new_id: int) -> void:
	var s: Dictionary = hotbar[selected]
	s["id"] = new_id
	if int(s["count"]) <= 0:
		s["count"] = 1
	hotbar_changed.emit()


## Hoe and seeds act on the ground: a hoe turns dirt or grass into farmland, and seeds
## plant a crop on the farmland they are aimed at from above.
func _farm_action(hit: Dictionary, hp: Vector3i, hid: int) -> bool:
	var id := selected_id()
	if id <= 0:
		return false
	if Gear.tool_kind(id) == Gear.HOE and (hid == Blocks.GRASS or hid == Blocks.DIRT):
		world.set_block(hp.x, hp.y, hp.z, Blocks.FARMLAND)
		Sfx.play_varied("dig", -10.0, 0.1)
		swing_t = 0.9
		tool_damage_selected(1)
		return true
	if id == Blocks.ITEM_SEEDS and hid == Blocks.FARMLAND:
		var cell: Vector3i = hit["prev"]
		# only on the top face, so a side-on click does not plant a floating crop
		if cell == Vector3i(hp.x, hp.y + 1, hp.z) \
				and world.get_block(cell.x, cell.y, cell.z) == Blocks.AIR:
			world.set_block(cell.x, cell.y, cell.z, Blocks.WHEAT_0)
			Sfx.play_varied("place", -12.0, 0.1)
			swing_t = 0.9
			consume_selected(1)
			return true
	return false


## Items that do something other than place a block. Right now that is the ender pearl:
## thrown at whatever the crosshair is on, and you arrive where it lands. It lands short of
## the block face so you are never teleported into the block you were aiming at.
func _item_use(hit: Dictionary) -> bool:
	if selected_id() != Blocks.ITEM_ENDER_PEARL:
		return false
	var eye := eye_position()
	var dir := look_dir()
	var target: Vector3
	if hit.is_empty():
		target = eye + dir * 40.0
	else:
		var hp: Vector3i = hit["pos"]
		target = Vector3(hp) + Vector3(0.5, 0.5, 0.5) - dir * 1.5
	var spot: Vector3 = world.safe_spawn_near(target)
	global_position = spot
	velocity = Vector3.ZERO
	consume_selected(1)
	swing_t = 0.9
	Sfx.play("splash", -5.0, 1.5)
	return true


func _try_place() -> void:
	var hit: Dictionary = world.raycast(eye_position(), look_dir(), _reach)
	# A villager under the crosshair is spoken to, not built over: right-click opens the
	# trade screen. Answered here, before the block dispatch, so a villager standing on a
	# block still trades rather than the block behind them being operated.
	if mobs != null:
		var vm = mobs.raycast_mob(eye_position(), look_dir(), _reach)
		if vm != null and str(vm.kind) == "villager":
			var vd: float = eye_position().distance_to(
				vm.global_position + Vector3(0, float(vm._h) * 0.5, 0))
			var bd := _reach + 1.0
			if not hit.is_empty():
				var bp: Vector3i = hit["pos"]
				bd = eye_position().distance_to(Vector3(bp) + Vector3(0.5, 0.5, 0.5))
			if vd <= bd:
				swing_t = 0.9
				vm.interact()
				return
	# A block that wants the click is operated, not covered up: a lever flips, a chest
	# opens, a door swings, a furnace lights up. Only when nothing under the crosshair
	# wants the click does this fall through to placing a block.
	if not hit.is_empty():
		var hp: Vector3i = hit["pos"]
		var hid: int = world.get_block(hp.x, hp.y, hp.z)
		if world.interact_block(hp, hid):
			swing_t = 0.9
			Sfx.play("click", -10.0, randf_range(0.95, 1.05))
			return
		# a hoe tills soil and seeds plant into farmland, rather than placing a block
		if _farm_action(hit, hp, hid):
			return
		# and a bucket fills from, or pours into, a fluid cell
		if _bucket_action(hit, hp, hid):
			return

	# an item that is used rather than placed, right where it is held
	if _item_use(hit):
		return

	var stack: Dictionary = hotbar[selected]
	var id: int = stack["id"]
	if id <= 0 or not Blocks.is_block_item(id):
		return
	if not creative and int(stack["count"]) <= 0:
		return
	if hit.is_empty():
		return
	var cell: Vector3i = hit["prev"]
	if cell.y < VoxelTerrain.MIN_Y or cell.y >= VoxelTerrain.MAX_Y:
		return
	# never build inside the player
	var box := feet_aabb()
	if box.intersects(AABB(Vector3(cell), Vector3.ONE)):
		return
	var existing: int = world.get_block(cell.x, cell.y, cell.z)
	if existing != Blocks.AIR and Blocks.kind[existing] != Blocks.K_CROSS:
		return
	# crossed plants, floor plates, carpets and beds all need something to stand on
	var k := Blocks.kind[id]
	if (k == Blocks.K_CROSS or k == Blocks.K_FLAT or k == Blocks.K_CARPET
			or k == Blocks.K_BED) \
			and not world.is_solid(cell.x, cell.y - 1, cell.z):
		return
	# tell the world which way we were looking, so a piston or repeater points away
	# from the player rather than always the same way
	world.set_place_look(look_dir())
	# ...and, for the shapes whose exact half matters, which way this one placement sits:
	# a slab or a trapdoor mounted on the underside of a block goes in the top half. Every
	# placement sets this, zero included, so the previous block's facing never leaks in.
	var normal: Vector3i = hit.get("normal", Vector3i.ZERO)
	var pfdir := Vector3i.ZERO
	if normal.y < 0 and (k == Blocks.K_SLAB or k == Blocks.K_TRAPDOOR):
		pfdir = Vector3i(0, 1, 0)
	world.set_place_facing(pfdir)
	if world.set_block(cell.x, cell.y, cell.z, id):
		Sfx.play("place", -8.0, randf_range(0.94, 1.06))
		swing_t = 0.9
		# a door is two blocks tall: the upper half comes with it, or one block would
		# leave a doorway you could walk through at head height
		if id == Blocks.DOOR:
			var up := Vector3i(cell.x, cell.y + 1, cell.z)
			if world.get_block(up.x, up.y, up.z) == Blocks.AIR:
				world.set_block(up.x, up.y, up.z, Blocks.DOOR)
		# a bed is two cells: the far half is the head, and it comes with the foot. It is
		# placed along the facing the world just recorded, so the pillow ends up at the far
		# end rather than on top of the foot.
		if id == Blocks.BED:
			var hc: Vector3i = cell + world.placement_facing()
			if world.get_block(hc.x, hc.y, hc.z) == Blocks.AIR \
					and not feet_aabb().intersects(AABB(Vector3(hc), Vector3.ONE)):
				world.set_block(hc.x, hc.y, hc.z, Blocks.BED_HEAD)
		if not creative:
			consume_selected(1)


# ================================================================ inventory
func give(id: int, count: int) -> void:
	if id <= 0 or count <= 0:
		return
	var maxs := Items.max_stack(id)
	# top up existing stacks first
	for list in [hotbar, inventory]:
		for s in list:
			if int(s["id"]) == id and int(s["count"]) < maxs:
				var room: int = maxs - int(s["count"])
				var add: int = mini(room, count)
				s["count"] = int(s["count"]) + add
				count -= add
				if count <= 0:
					hotbar_changed.emit()
					return
	for list2 in [hotbar, inventory]:
		for s in list2:
			if int(s["id"]) == 0:
				s["id"] = id
				var add2: int = mini(maxs, count)
				s["count"] = add2
				# a tool or piece of armour arrives with a full durability bar
				var maxd := Gear.max_durability(id)
				if maxd > 0:
					s["dur"] = maxd
				count -= add2
				if count <= 0:
					hotbar_changed.emit()
					return
	hotbar_changed.emit()


## True when there is room for at least one `id` in the backpack or hotbar. Used
## by the item entities so a full inventory does not silently eat a drop.
func can_accept(id: int) -> bool:
	if id <= 0:
		return false
	var maxs := Items.max_stack(id)
	for list in [hotbar, inventory]:
		for s in list:
			if int(s["id"]) == 0:
				return true
			if int(s["id"]) == id and int(s["count"]) < maxs:
				return true
	return false


## How many of `id` the player is carrying, hotbar and backpack together. Trading needs
## to ask "do they have enough?" before it takes anything.
func count_of(id: int) -> int:
	var n := 0
	for list in [hotbar, inventory]:
		for s in list:
			if int(s["id"]) == id:
				n += int(s["count"])
	return n


## Takes up to `n` of `id` out of the hotbar and backpack, draining each stack it finds
## until the count is met. Returns how many were actually removed, which is at most `n`.
func remove_count(id: int, n: int) -> int:
	var want := n
	var removed := 0
	for list in [hotbar, inventory]:
		for s in list:
			if want <= 0:
				break
			if int(s["id"]) != id:
				continue
			var take: int = mini(int(s["count"]), want)
			s["count"] = int(s["count"]) - take
			if int(s["count"]) <= 0:
				s["id"] = 0
			want -= take
			removed += take
	if removed > 0:
		hotbar_changed.emit()
	return removed


func consume_selected(n: int) -> void:
	var s: Dictionary = hotbar[selected]
	s["count"] = maxi(0, int(s["count"]) - n)
	if int(s["count"]) == 0:
		s["id"] = 0
	hotbar_changed.emit()


## Eats the selected item if it is food and we are not already full. Returns true
## when something was actually eaten, so the caller knows not to place a block.
func eat_selected() -> bool:
	var id := selected_id()
	var food := Blocks.food_value(id)
	if food <= 0:
		return false
	if not creative and hunger >= MAX_HUNGER:
		return false
	hunger = minf(MAX_HUNGER, hunger + float(food))
	hunger_changed.emit()
	consume_selected(1)
	swing_t = maxf(swing_t, 0.5)
	Sfx.play("eat", -7.0, randf_range(0.94, 1.08))
	return true


func drop_selected() -> void:
	var s: Dictionary = hotbar[selected]
	var id := int(s["id"])
	if id == 0:
		return
	s["count"] = maxi(0, int(s["count"]) - 1)
	if int(s["count"]) == 0:
		s["id"] = 0
	hotbar_changed.emit()
	item_thrown.emit(id, 1)


func pick_block(id: int) -> void:
	if id <= 0:
		return
	for i in 9:
		if int(hotbar[i]["id"]) == id:
			selected = i
			selected_changed.emit()
			return
	for i in 9:
		if int(hotbar[i]["id"]) == 0:
			hotbar[i]["id"] = id
			hotbar[i]["count"] = 1 if not creative else 64
			hotbar_changed.emit()
			selected = i
			selected_changed.emit()
			return


func cycle_hotbar(dir: int) -> void:
	selected = (selected + dir + 9) % 9
	selected_changed.emit()
	refresh_hand()


func select_slot(i: int) -> void:
	selected = clampi(i, 0, 8)
	selected_changed.emit()
	refresh_hand()


func selected_id() -> int:
	return int(hotbar[selected]["id"])


func set_mobs(m) -> void:
	mobs = m


# ================================================================ experience
## The points needed to reach the next level, Minecraft's curve: cheap early, steeper
## after fifteen, steepest after thirty.
func xp_to_next() -> int:
	if level >= 30:
		return 112 + (level - 30) * 9
	if level >= 15:
		return 37 + (level - 15) * 5
	return 7 + level * 2


func add_xp(n: int) -> void:
	if n <= 0:
		return
	xp += n
	while xp >= xp_to_next() and level < 1000:
		xp -= xp_to_next()
		level += 1
	xp_changed.emit()


## Spends `n` levels, for the enchanting table. False (and no change) when the player
## does not have them.
func spend_levels(n: int) -> bool:
	if n <= 0 or level < n:
		return false
	level -= n
	xp_changed.emit()
	return true


## The stack in the selected hotbar slot, for reading enchantments off it.
func selected_stack() -> Dictionary:
	return hotbar[selected]


## Wear the selected tool down by `n`. A tool that reaches zero wears out and leaves the
## hand. Stacks of one (tools, armour) each carry their own `dur`; everything else has
## no durability to lose.
func tool_damage_selected(n: int) -> void:
	var s: Dictionary = hotbar[selected]
	var id := int(s["id"])
	var maxd := Gear.max_durability(id)
	if maxd <= 0:
		return
	# Unbreaking: a level of N skips the wear with probability N/(N+1)
	if Gear.unbreaking_skips(s):
		return
	var d := int(s.get("dur", maxd)) - n
	if d <= 0:
		s["id"] = 0
		s["count"] = 0
		s.erase("dur")
		Sfx.play("tool_break", -8.0)
	else:
		s["dur"] = d
	hotbar_changed.emit()
	# a tool that just broke leaves the hand
	if int(s["id"]) != id:
		refresh_hand()


## Puts whatever is in the selected slot into the model's right hand: a block cube, a
## tool, or nothing.
func refresh_hand() -> void:
	var id := selected_id()
	# Both rigs get it: the body's hand for third person, the camera hand for first, so
	# what you hold is the same thing from either side of the F5 cycle.
	for m in [model, fp_hand]:
		if m == null:
			continue
		var is_fp: bool = m == fp_hand
		if id > 0 and Blocks.is_block_item(id):
			m.set_held_block(id, is_fp)
			m.set_held_item(0)
		elif Gear.is_tool(id):
			m.set_held_block(0)
			m.set_held_item(id)
		else:
			m.set_held_block(0)
			m.set_held_item(0)
	_refresh_held_light()
	_apply_view_visibility()


## Fills the hotbar with a starter palette (creative mode convenience).
func fill_creative_hotbar() -> void:
	var order := [Blocks.GRASS, Blocks.DIRT, Blocks.STONE, Blocks.COBBLESTONE, Blocks.PLANKS,
		Blocks.LOG, Blocks.LEAVES, Blocks.SAND, Blocks.GLASS]
	for i in order.size():
		hotbar[i]["id"] = order[i]
		hotbar[i]["count"] = 64
	hotbar_changed.emit()
	refresh_hand()


# ================================================================ damage
## `force` is for the things that kill even a creative player, i.e. `/kill`.
## Everything else -- falls, drowning, starvation, the void -- is ignored in
## creative, which is what "creative" is supposed to mean.
func hurt(amount: float, force: bool = false) -> void:
	if dead or _invuln > 0.0:
		return
	if creative and not force:
		return
	# armour absorbs a fraction of the hit, and wears down doing it. Protection adds to
	# that fraction, on top of the armour points.
	var reduction := minf(Gear.armor_reduction(armor) + Gear.ench_protection(armor), 0.9)
	if reduction > 0.0:
		amount *= 1.0 - reduction
		_wear_armor()
	health -= amount
	_invuln = INVULN
	damage_timer = 6.0
	regen_timer = 0.0
	health_changed.emit()
	if health <= 0.0:
		health = 0.0
		dead = true
		Sfx.play("death", -3.0)
		died.emit()


## Wear every equipped piece down by one point (Minecraft does this per hit, only for
## worn pieces; here every piece on the body takes the wear).
func _wear_armor() -> void:
	var changed := false
	for s in armor:
		var id := int(s["id"])
		var maxd := Gear.max_durability(id)
		if maxd <= 0:
			continue
		if Gear.unbreaking_skips(s):
			continue
		var d := int(s.get("dur", maxd)) - 1
		if d <= 0:
			s["id"] = 0
			s["count"] = 0
			s.erase("dur")
		else:
			s["dur"] = d
		changed = true
	if changed:
		hotbar_changed.emit()


## Kills the player regardless of mode, for the `/kill` command.
func kill() -> void:
	_invuln = 0.0
	hurt(MAX_HEALTH * 10.0, true)


func heal_all() -> void:
	health = MAX_HEALTH
	hunger = MAX_HUNGER
	exhaustion = 0.0
	air = 12.0
	health_changed.emit()
	hunger_changed.emit()


func fall_distance() -> float:
	return maxf(0.0, _fall_y - global_position.y)


# ================================================================ crafting
## Every recipe is data: a 3x3 shaped pattern with a key, or a shapeless set. Adding
## a recipe is one line here and nothing else -- the matcher, the result slot and the
## inventory drag-and-drop all work off this table.
const RECIPES := [
	# --- basics
	{"type": "shapeless", "in": [Blocks.LOG], "out": [Blocks.PLANKS, 4]},
	{"type": "shapeless", "in": [Blocks.BIRCH_LOG], "out": [Blocks.BIRCH_PLANKS, 4]},
	{"type": "shapeless", "in": [Blocks.ITEM_COAL, Blocks.ITEM_STICK], "out": [Blocks.TORCH, 4]},
	{"type": "shaped", "pattern": ["P", "P"], "key": {"P": Blocks.PLANKS},
		"out": [Blocks.ITEM_STICK, 4]},
	{"type": "shaped", "pattern": ["PP", "PP"], "key": {"P": Blocks.PLANKS},
		"out": [Blocks.CRAFTING_TABLE, 1]},
	{"type": "shaped", "pattern": ["C", "S"], "key": {"C": Blocks.COBBLESTONE, "S": Blocks.ITEM_STICK},
		"out": [Blocks.SWITCH, 1]},
	{"type": "shaped", "pattern": ["S"], "key": {"S": Blocks.STONE_BRICK},
		"out": [Blocks.BUTTON, 1]},

	# --- building blocks
	{"type": "shaped", "pattern": ["SS", "SS"], "key": {"S": Blocks.STONE},
		"out": [Blocks.STONE_BRICK, 4]},
	{"type": "shaped", "pattern": ["SSS", "SSS", "SSS"], "key": {"S": Blocks.ITEM_IRON},
		"out": [Blocks.IRON_BLOCK, 1]},
	{"type": "shaped", "pattern": ["GGG", "GGG", "GGG"], "key": {"G": Blocks.ITEM_GOLD},
		"out": [Blocks.GOLD_BLOCK, 1]},
	{"type": "shaped", "pattern": ["DDD", "DDD", "DDD"], "key": {"D": Blocks.ITEM_DIAMOND},
		"out": [Blocks.DIAMOND_BLOCK, 1]},
	{"type": "shaped", "pattern": ["SSS", "SSS"], "key": {"S": Blocks.ITEM_STICK},
		"out": [Blocks.FENCE, 3]},
	{"type": "shaped", "pattern": ["S S", "SSS", "S S"], "key": {"S": Blocks.ITEM_STICK},
		"out": [Blocks.LADDER, 3]},
	{"type": "shaped", "pattern": ["PPP", "PPP"], "key": {"P": Blocks.PLANKS},
		"out": [Blocks.DOOR, 1]},
	{"type": "shaped", "pattern": ["PPP", "P P", "PPP"], "key": {"P": Blocks.PLANKS},
		"out": [Blocks.CHEST, 1]},
	{"type": "shaped", "pattern": ["GG", "GG"], "key": {"G": Blocks.GLASS},
		"out": [Blocks.GLASS_PANE, 16]},

	# --- the power system. Copper is the conductor, so everything is built out of it,
	# exactly as a real board is built out of copper and doped silicon. The wire comes
	# first: without it nothing else in this group can be wired up.
	{"type": "shapeless", "in": [Blocks.ITEM_COPPER], "out": [Blocks.WIRE, 4]},
	{"type": "shapeless", "in": [Blocks.BATTERY], "out": [Blocks.ITEM_COPPER, 9]},
	{"type": "shaped", "pattern": ["RRR", "RRR", "RRR"], "key": {"R": Blocks.ITEM_COPPER},
		"out": [Blocks.BATTERY, 1]},
	{"type": "shaped", "pattern": ["R", "S"], "key": {"R": Blocks.ITEM_COPPER, "S": Blocks.ITEM_STICK},
		"out": [Blocks.INVERTER, 1]},
	{"type": "shaped", "pattern": ["RSR"], "key": {"R": Blocks.ITEM_COPPER, "S": Blocks.STONE},
		"out": [Blocks.RELAY, 1]},
	{"type": "shaped", "pattern": [" R ", "RGR"], "key": {"R": Blocks.ITEM_COPPER, "G": Blocks.GLOWSTONE},
		"out": [Blocks.LAMP, 1]},
	{"type": "shaped", "pattern": ["SSS", "RRR", "SSS"], "key": {"S": Blocks.PLANKS,
		"R": Blocks.ITEM_COPPER}, "out": [Blocks.PRESSURE_PLATE, 1]},
	{"type": "shaped", "pattern": ["PPP", "CIC", "CIC"], "key": {"P": Blocks.PLANKS,
		"C": Blocks.COBBLESTONE, "I": Blocks.ITEM_IRON}, "out": [Blocks.PISTON, 1]},

	# --- furnace & food
	{"type": "shaped", "pattern": ["CCC", "C C", "CCC"], "key": {"C": Blocks.COBBLESTONE},
		"out": [Blocks.FURNACE, 1]},
	{"type": "shaped", "pattern": ["WWW"], "key": {"W": Blocks.ITEM_WHEAT},
		"out": [Blocks.ITEM_BREAD, 1]},
	{"type": "shaped", "pattern": ["I I", " I "], "key": {"I": Blocks.ITEM_IRON},
		"out": [Blocks.ITEM_BUCKET, 1]},

	# --- tools: the same three shapes in a different material per tier
	{"type": "shaped", "pattern": ["MMM", " S ", " S "], "key": {"M": Blocks.PLANKS, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_WOOD_PICK, 1]},
	{"type": "shaped", "pattern": ["MM", "MS", " S"], "key": {"M": Blocks.PLANKS, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_WOOD_AXE, 1]},
	{"type": "shaped", "pattern": ["M", "S", "S"], "key": {"M": Blocks.PLANKS, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_WOOD_SHOVEL, 1]},
	{"type": "shaped", "pattern": ["M", "M", "S"], "key": {"M": Blocks.PLANKS, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_WOOD_SWORD, 1]},
	{"type": "shaped", "pattern": ["MM", " S", " S"], "key": {"M": Blocks.PLANKS, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_WOOD_HOE, 1]},
	{"type": "shaped", "pattern": ["MMM", " S ", " S "], "key": {"M": Blocks.COBBLESTONE, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_STONE_PICK, 1]},
	{"type": "shaped", "pattern": ["MM", "MS", " S"], "key": {"M": Blocks.COBBLESTONE, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_STONE_AXE, 1]},
	{"type": "shaped", "pattern": ["M", "S", "S"], "key": {"M": Blocks.COBBLESTONE, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_STONE_SHOVEL, 1]},
	{"type": "shaped", "pattern": ["M", "M", "S"], "key": {"M": Blocks.COBBLESTONE, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_STONE_SWORD, 1]},
	{"type": "shaped", "pattern": ["MM", " S", " S"], "key": {"M": Blocks.COBBLESTONE, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_STONE_HOE, 1]},
	{"type": "shaped", "pattern": ["MMM", " S ", " S "], "key": {"M": Blocks.ITEM_IRON, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_IRON_PICK, 1]},
	{"type": "shaped", "pattern": ["MM", "MS", " S"], "key": {"M": Blocks.ITEM_IRON, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_IRON_AXE, 1]},
	{"type": "shaped", "pattern": ["M", "S", "S"], "key": {"M": Blocks.ITEM_IRON, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_IRON_SHOVEL, 1]},
	{"type": "shaped", "pattern": ["M", "M", "S"], "key": {"M": Blocks.ITEM_IRON, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_IRON_SWORD, 1]},
	{"type": "shaped", "pattern": ["MM", " S", " S"], "key": {"M": Blocks.ITEM_IRON, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_IRON_HOE, 1]},
	{"type": "shaped", "pattern": ["MMM", " S ", " S "], "key": {"M": Blocks.ITEM_DIAMOND, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_DIAMOND_PICK, 1]},
	{"type": "shaped", "pattern": ["MM", "MS", " S"], "key": {"M": Blocks.ITEM_DIAMOND, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_DIAMOND_AXE, 1]},
	{"type": "shaped", "pattern": ["M", "S", "S"], "key": {"M": Blocks.ITEM_DIAMOND, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_DIAMOND_SHOVEL, 1]},
	{"type": "shaped", "pattern": ["M", "M", "S"], "key": {"M": Blocks.ITEM_DIAMOND, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_DIAMOND_SWORD, 1]},
	{"type": "shaped", "pattern": ["MM", " S", " S"], "key": {"M": Blocks.ITEM_DIAMOND, "S": Blocks.ITEM_STICK}, "out": [Blocks.ITEM_DIAMOND_HOE, 1]},

	# --- armour: leather first, then iron and diamond
	{"type": "shaped", "pattern": ["MMM", "M M"], "key": {"M": Blocks.ITEM_LEATHER}, "out": [Blocks.ITEM_LEATHER_HELMET, 1]},
	{"type": "shaped", "pattern": ["M M", "MMM", "MMM"], "key": {"M": Blocks.ITEM_LEATHER}, "out": [Blocks.ITEM_LEATHER_CHESTPLATE, 1]},
	{"type": "shaped", "pattern": ["MMM", "M M", "M M"], "key": {"M": Blocks.ITEM_LEATHER}, "out": [Blocks.ITEM_LEATHER_LEGGINGS, 1]},
	{"type": "shaped", "pattern": ["M M", "M M"], "key": {"M": Blocks.ITEM_LEATHER}, "out": [Blocks.ITEM_LEATHER_BOOTS, 1]},
	{"type": "shaped", "pattern": ["MMM", "M M"], "key": {"M": Blocks.ITEM_IRON}, "out": [Blocks.ITEM_IRON_HELMET, 1]},
	{"type": "shaped", "pattern": ["M M", "MMM", "MMM"], "key": {"M": Blocks.ITEM_IRON}, "out": [Blocks.ITEM_IRON_CHESTPLATE, 1]},
	{"type": "shaped", "pattern": ["MMM", "M M", "M M"], "key": {"M": Blocks.ITEM_IRON}, "out": [Blocks.ITEM_IRON_LEGGINGS, 1]},
	{"type": "shaped", "pattern": ["M M", "M M"], "key": {"M": Blocks.ITEM_IRON}, "out": [Blocks.ITEM_IRON_BOOTS, 1]},
	{"type": "shaped", "pattern": ["MMM", "M M"], "key": {"M": Blocks.ITEM_DIAMOND}, "out": [Blocks.ITEM_DIAMOND_HELMET, 1]},
	{"type": "shaped", "pattern": ["M M", "MMM", "MMM"], "key": {"M": Blocks.ITEM_DIAMOND}, "out": [Blocks.ITEM_DIAMOND_CHESTPLATE, 1]},
	{"type": "shaped", "pattern": ["MMM", "M M", "M M"], "key": {"M": Blocks.ITEM_DIAMOND}, "out": [Blocks.ITEM_DIAMOND_LEGGINGS, 1]},
	{"type": "shaped", "pattern": ["M M", "M M"], "key": {"M": Blocks.ITEM_DIAMOND}, "out": [Blocks.ITEM_DIAMOND_BOOTS, 1]},

	# --- building shapes: stairs, slabs, trapdoors, gates and signs
	{"type": "shaped", "pattern": ["SSS"], "key": {"S": Blocks.STONE}, "out": [Blocks.SLAB, 6]},
	{"type": "shaped", "pattern": ["SSS"], "key": {"S": Blocks.PLANKS}, "out": [Blocks.SLAB_WOOD, 6]},
	{"type": "shaped", "pattern": ["SSS"], "key": {"S": Blocks.COBBLESTONE}, "out": [Blocks.SLAB_COBBLE, 6]},
	{"type": "shaped", "pattern": ["S  ", "SS ", "SSS"], "key": {"S": Blocks.STONE}, "out": [Blocks.STAIRS, 4]},
	{"type": "shaped", "pattern": ["S  ", "SS ", "SSS"], "key": {"S": Blocks.PLANKS}, "out": [Blocks.STAIRS_WOOD, 4]},
	{"type": "shaped", "pattern": ["S  ", "SS ", "SSS"], "key": {"S": Blocks.COBBLESTONE}, "out": [Blocks.STAIRS_COBBLE, 4]},
	{"type": "shaped", "pattern": ["PP", "PP", "PP"], "key": {"P": Blocks.PLANKS}, "out": [Blocks.TRAPDOOR, 2]},
	{"type": "shaped", "pattern": ["SPS", "SPS"], "key": {"S": Blocks.ITEM_STICK, "P": Blocks.PLANKS}, "out": [Blocks.FENCE_GATE, 1]},
	{"type": "shaped", "pattern": ["PPP", "PPP", " S "], "key": {"P": Blocks.PLANKS, "S": Blocks.ITEM_STICK}, "out": [Blocks.SIGN, 3]},

	# --- wool, dye and carpet
	{"type": "shaped", "pattern": ["SS", "SS"], "key": {"S": Blocks.ITEM_STRING}, "out": [Blocks.WOOL_0, 1]},
	{"type": "shaped", "pattern": ["WWW", "PPP"], "key": {"W": Blocks.WOOL_0, "P": Blocks.PLANKS}, "out": [Blocks.BED, 1]},
	{"type": "shaped", "pattern": [" D ", "OOO", "OOO"], "key": {"D": Blocks.ITEM_DIAMOND, "O": Blocks.OBSIDIAN}, "out": [Blocks.ENCHANTING_TABLE, 1]},
	{"type": "shaped", "pattern": ["SS"], "key": {"S": Blocks.WOOL_0}, "out": [Blocks.CARPET_0, 3]},
	{"type": "shapeless", "in": [Blocks.FLOWER_RED], "out": [Blocks.ITEM_DYE_14, 1]},
	{"type": "shapeless", "in": [Blocks.FLOWER_YELLOW], "out": [Blocks.ITEM_DYE_4, 1]},
	# one recipe per dye: a white wool takes the colour of whatever dye it is soaked in
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_1], "out": [Blocks.WOOL_1, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_2], "out": [Blocks.WOOL_2, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_3], "out": [Blocks.WOOL_3, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_4], "out": [Blocks.WOOL_4, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_5], "out": [Blocks.WOOL_5, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_6], "out": [Blocks.WOOL_6, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_7], "out": [Blocks.WOOL_7, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_8], "out": [Blocks.WOOL_8, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_9], "out": [Blocks.WOOL_9, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_10], "out": [Blocks.WOOL_10, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_11], "out": [Blocks.WOOL_11, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_12], "out": [Blocks.WOOL_12, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_13], "out": [Blocks.WOOL_13, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_14], "out": [Blocks.WOOL_14, 1]},
	{"type": "shapeless", "in": [Blocks.WOOL_0, Blocks.ITEM_DYE_15], "out": [Blocks.WOOL_15, 1]},
]


## A readable one-line summary of every recipe, for the crafting panel's hint list.
## Derived from the table itself rather than hand-written, so adding a recipe can
## never leave the hint list describing something the matcher no longer accepts.
func recipe_lines() -> Array:
	var lines: Array = []
	for r in RECIPES:
		var parts: Array = []
		if r["type"] == "shapeless":
			for v in r["in"]:
				parts.append(_counted_name(int(v)))
		else:
			var key: Dictionary = r["key"]
			var tally: Dictionary = {}
			for row in r["pattern"]:
				for ch in row:
					if ch == " ":
						continue
					var id: int = int(key[ch])
					tally[id] = int(tally.get(id, 0)) + 1
			for id in tally:
				parts.append(_counted_name(int(id), int(tally[id])))
		var o: Array = r["out"]
		lines.append("%s  >  %s" % [" + ".join(parts),
			_counted_name(int(o[0]), int(o[1]))])
	return lines


func _counted_name(id: int, n: int = 1) -> String:
	var nm := Items.name_of(id)
	return nm if n <= 1 else "%s x%d" % [nm, n]


func craft_result() -> Dictionary:
	var ids: Array = []
	for i in 9:
		ids.append(int(crafting[i]["id"]))
	var shaped := _match_shaped(ids)
	if not shaped.is_empty():
		return shaped
	var flat := _match_shapeless(ids)
	if not flat.is_empty():
		return flat
	return {"id": 0, "count": 0}


func _match_shaped(ids: Array) -> Dictionary:
	var minx := 3
	var maxx := -1
	var miny := 3
	var maxy := -1
	for y in 3:
		for x in 3:
			if int(ids[y * 3 + x]) != 0:
				minx = mini(minx, x)
				maxx = maxi(maxx, x)
				miny = mini(miny, y)
				maxy = maxi(maxy, y)
	if maxx < 0:
		return {}
	var w := maxx - minx + 1
	var h := maxy - miny + 1
	# a recipe that needs the full 3x3 board only works at a crafting table
	if (w > 2 or h > 2) and not table_available:
		return {}
	for r in RECIPES:
		if r["type"] != "shaped":
			continue
		var pattern: Array = r["pattern"]
		if pattern.size() != h or pattern[0].length() != w:
			continue
		var key: Dictionary = r["key"]
		var good := true
		for y in h:
			for x in w:
				var ch: String = pattern[y][x]
				var expect := 0
				if ch != " ":
					expect = int(key[ch])
				if int(ids[(miny + y) * 3 + (minx + x)]) != expect:
					good = false
					break
			if not good:
				break
		if good:
			var o: Array = r["out"]
			return {"id": int(o[0]), "count": int(o[1])}
	return {}


func _match_shapeless(ids: Array) -> Dictionary:
	var have: Array = []
	for v in ids:
		if int(v) != 0:
			have.append(int(v))
	if have.is_empty():
		return {}
	have.sort()
	for r in RECIPES:
		if r["type"] != "shapeless":
			continue
		var want: Array = []
		for v in r["in"]:
			want.append(int(v))
		want.sort()
		# an ingredient list longer than the 2x2 corner also needs the table
		if want.size() > 4 and not table_available:
			continue
		if want == have:
			var o: Array = r["out"]
			return {"id": int(o[0]), "count": int(o[1])}
	return {}


func consume_crafting() -> void:
	for s in crafting:
		var n := int(s["count"])
		if n > 0:
			s["count"] = n - 1
			if int(s["count"]) == 0:
				s["id"] = 0


func notify_inventory_changed() -> void:
	hotbar_changed.emit()


func dig_progress() -> float:
	if _dig_progress <= 0.0:
		return 0.0
	var id: int = world.get_block(_dig_target.x, _dig_target.y, _dig_target.z)
	var hard := Blocks.hardness[id]
	if hard <= 0.0:
		return 0.0
	return clampf(_dig_progress / _dig_need(id), 0.0, 1.0)


## The time (in dig-seconds) a block takes with the tool currently in hand. A matching
## tool divides the base time by its speed; a bare hand or a wrong tool is the base.
func _dig_need(id: int) -> float:
	var base := 0.35 + Blocks.hardness[id] * 1.1
	var spd := Gear.speed_for(selected_id(), id)
	# Efficiency speeds up the tool it is on, but only the block that tool is right for
	if spd > 1.0:
		spd *= Gear.ench_speed_mult(hotbar[selected])
	return base / maxf(1.0, spd)


## The block currently being mined, so the HUD can draw the crack overlay there.
func dig_target_pos() -> Vector3i:
	return _dig_target


func look_at_block() -> Dictionary:
	if world == null:
		return {}
	return world.raycast(eye_position(), look_dir(), _reach)


# ================================================================ save / load
func save_state() -> Dictionary:
	var inv: Array = []
	for s in inventory:
		inv.append(_cell_save(s))
	var hb: Array = []
	for s in hotbar:
		hb.append(_cell_save(s))
	var ar: Array = []
	for s in armor:
		ar.append(_cell_save(s))
	return {
		"pos": [global_position.x, global_position.y, global_position.z],
		"yaw": yaw, "pitch": pitch,
		"health": health, "air": air,
		"hunger": hunger, "exhaustion": exhaustion,
		"xp": xp, "level": level,
		"creative": creative, "flying": flying,
		"selected": selected,
		"hotbar": hb, "inventory": inv, "armor": ar,
		"cursor": [int(cursor_stack["id"]), int(cursor_stack["count"])],
	}


## A saved cell is [id, count], plus a third durability entry when the item has one and
## a fourth `ench` dictionary when it is enchanted. The dictionary is JSON-safe (string
## keys, int values), so it rides along in the same file.
func _cell_save(s: Dictionary) -> Array:
	var id := int(s["id"])
	if id > 0 and Gear.max_durability(id) > 0:
		var cell := [id, int(s["count"]), int(s.get("dur", Gear.max_durability(id)))]
		if s.has("ench"):
			cell.append(s["ench"])
		return cell
	return [id, int(s["count"])]


func _cell_load(cell: Array) -> Dictionary:
	var st := item_stack(int(cell[0]), int(cell[1]))
	if cell.size() > 2 and int(cell[0]) > 0:
		st["dur"] = int(cell[2])
	if cell.size() > 3 and cell[3] is Dictionary and int(cell[0]) > 0:
		st["ench"] = cell[3]
	return st


func load_state(d: Dictionary) -> void:
	var p: Array = d.get("pos", [0, 70, 0])
	global_position = Vector3(p[0], p[1], p[2])
	yaw = float(d.get("yaw", 0.0))
	pitch = float(d.get("pitch", 0.0))
	health = float(d.get("health", MAX_HEALTH))
	hunger = float(d.get("hunger", MAX_HUNGER))
	exhaustion = float(d.get("exhaustion", 0.0))
	xp = int(d.get("xp", 0))
	level = int(d.get("level", 0))
	air = float(d.get("air", 12.0))
	creative = bool(d.get("creative", true))
	flying = bool(d.get("flying", false))
	selected = int(d.get("selected", 0))
	var hb: Array = d.get("hotbar", [])
	for i in mini(9, hb.size()):
		hotbar[i] = _cell_load(hb[i])
	var inv: Array = d.get("inventory", [])
	for i in mini(27, inv.size()):
		inventory[i] = _cell_load(inv[i])
	var ar: Array = d.get("armor", [])
	for i in mini(4, ar.size()):
		armor[i] = _cell_load(ar[i])
	var cur: Array = d.get("cursor", [0, 0])
	cursor_stack = item_stack(int(cur[0]), int(cur[1]))
	dead = false
	health_changed.emit()
	hunger_changed.emit()
	hotbar_changed.emit()
	selected_changed.emit()
	refresh_hand()