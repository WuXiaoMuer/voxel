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

signal health_changed
signal hunger_changed
signal hotbar_changed
signal selected_changed
signal died
signal stats_changed(name: String)

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
	# see when you look down, and what casts your shadow. There used to be a second,
	# camera-mounted arm and a floating block cube doing duty as "the first person hand";
	# with a real body visible they were a duplicate, so the body's own arm -- which
	# already carries the held block -- is the only thing drawing it now.
	model = load("res://scripts/player_model.gd").new()
	model.name = "Body"
	add_child(model)
	refresh_skin()

	refresh_hand()
	# the held model must follow *every* change to the hotbar: picking a block up
	# into the selected slot, running a stack out while building, dropping one, or
	# moving stacks around in the inventory screen
	hotbar_changed.connect(refresh_hand)


static func item_stack(id: int, count: int) -> Dictionary:
	return {"id": id, "count": count}


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
## The body is never hidden as a whole. First person takes off the head and the chest --
## see `player_model.set_first_person` for why the chest has to go too -- but keeps the
## arms and legs drawn. Keeping them drawn is also what makes a shadow land on the
## ground: an invisible node casts no shadow, and hiding the whole body was why first
## person used to have none.
func _apply_view_visibility() -> void:
	if model != null:
		model.set_first_person(cam_mode == Cam.FIRST)


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
				if world.is_solid(x, y, z):
					return true
	return false


func in_water() -> bool:
	var p := global_position
	return world.is_liquid(floori(p.x), floori(p.y + 0.4), floori(p.z))


func head_in_water() -> bool:
	var p := eye_position()
	return world.is_liquid(floori(p.x), floori(p.y), floori(p.z))


func in_lava() -> bool:
	return false


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
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
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
	elif water:
		speed = SWIM
	elif want_sneak:
		speed = SNEAK
	elif want_sprint:
		speed = SPRINT
	if flying and want_sneak:
		speed = FLY * 0.4

	var target := move * speed
	var accel := 12.0 if (on_ground or flying or water) else 3.0
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
	if sneaking and not flying:
		eye -= 0.24
	cam_pivot.position = cam_pivot.position.lerp(Vector3(0, eye, 0), clampf(delta * 14.0, 0.0, 1.0))
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
						m.hurt_mob(Gear.damage_of(selected_id()), global_position)
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
	world.set_block(pos.x, pos.y, pos.z, Blocks.AIR)
	Sfx.play("break", -6.0, randf_range(0.92, 1.08))
	swing_t = 1.0
	# the drop, the particles and the leaves-apple roll all live in main.gd, which
	# owns the item-entity and particle managers
	block_broken.emit(pos, id)


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


func _try_place() -> void:
	var hit: Dictionary = world.raycast(eye_position(), look_dir(), _reach)
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
	# crossed plants and floor plates both need something to stand on
	var k := Blocks.kind[id]
	if (k == Blocks.K_CROSS or k == Blocks.K_FLAT) \
			and not world.is_solid(cell.x, cell.y - 1, cell.z):
		return
	# tell the world which way we were looking, so a piston or repeater points away
	# from the player rather than always the same way
	world.set_place_look(look_dir())
	if world.set_block(cell.x, cell.y, cell.z, id):
		Sfx.play("place", -8.0, randf_range(0.94, 1.06))
		swing_t = 0.9
		# a door is two blocks tall: the upper half comes with it, or one block would
		# leave a doorway you could walk through at head height
		if id == Blocks.DOOR:
			var up := Vector3i(cell.x, cell.y + 1, cell.z)
			if world.get_block(up.x, up.y, up.z) == Blocks.AIR:
				world.set_block(up.x, up.y, up.z, Blocks.DOOR)
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


## Wear the selected tool down by `n`. A tool that reaches zero wears out and leaves the
## hand. Stacks of one (tools, armour) each carry their own `dur`; everything else has
## no durability to lose.
func tool_damage_selected(n: int) -> void:
	var s: Dictionary = hotbar[selected]
	var id := int(s["id"])
	var maxd := Gear.max_durability(id)
	if maxd <= 0:
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
	if model != null:
		if id > 0 and Blocks.is_block_item(id):
			model.set_held_block(id)
			model.set_held_item(0)
		elif Gear.is_tool(id):
			model.set_held_block(0)
			model.set_held_item(id)
		else:
			model.set_held_block(0)
			model.set_held_item(0)
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
	# armour absorbs a fraction of the hit, and wears down doing it
	var reduction := Gear.armor_reduction(armor)
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
	return base / maxf(1.0, Gear.speed_for(selected_id(), id))


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
		"creative": creative, "flying": flying,
		"selected": selected,
		"hotbar": hb, "inventory": inv, "armor": ar,
		"cursor": [int(cursor_stack["id"]), int(cursor_stack["count"])],
	}


## A saved cell is [id, count], plus a third durability entry when the item has one.
func _cell_save(s: Dictionary) -> Array:
	var id := int(s["id"])
	if id > 0 and Gear.max_durability(id) > 0:
		return [id, int(s["count"]), int(s.get("dur", Gear.max_durability(id)))]
	return [id, int(s["count"])]


func _cell_load(cell: Array) -> Dictionary:
	var st := item_stack(int(cell[0]), int(cell[1]))
	if cell.size() > 2 and int(cell[0]) > 0:
		st["dur"] = int(cell[2])
	return st


func load_state(d: Dictionary) -> void:
	var p: Array = d.get("pos", [0, 70, 0])
	global_position = Vector3(p[0], p[1], p[2])
	yaw = float(d.get("yaw", 0.0))
	pitch = float(d.get("pitch", 0.0))
	health = float(d.get("health", MAX_HEALTH))
	hunger = float(d.get("hunger", MAX_HUNGER))
	exhaustion = float(d.get("exhaustion", 0.0))
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