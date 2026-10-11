extends Node3D
## Sky, sun/moon, day-night cycle, fog and the underwater look.

const DAY_LENGTH := 900.0     # seconds for a full cycle

var world_env: WorldEnvironment
var env: Environment
var sky_mat: ProceduralSkyMaterial
var sun: DirectionalLight3D
var moon: DirectionalLight3D

var time_of_day := 0.30        # 0 = midnight, 0.25 = sunrise, 0.5 = noon
var running := true
var underwater := false
var _underwater_blend := 0.0
var _fog_begin := 34.0
var _fog_end := 100.0
## Fog values derived purely from the render distance, before the player's
## `fog_scale` multiplier. Kept separately so the setting can be changed (or reset)
## without losing the auto-computed base.
var _auto_fog_begin := 34.0
var _auto_fog_end := 100.0
## Saturation of the current render pack. The underwater look tints relative to
## this rather than to a hard-coded value, so a pack change survives a dive.
var _base_saturation := 1.08

## Weather. It changes on its own clock: long clear spells, shorter rain, and the odd
## thunderstorm. `rain_level` is a 0..1 blend so the sky darkens and the rain fades in
## rather than snapping, and `_flash` is the brief brightening of a lightning strike.
enum Weather { CLEAR, RAIN, THUNDER }
var weather := Weather.CLEAR
var weather_timer := 60.0
var rain_level := 0.0
var _flash := 0.0
const WEATHER_MIN := 35.0
const WEATHER_MAX := 120.0


func is_raining() -> bool:
	return weather != Weather.CLEAR


func is_thundering() -> bool:
	return weather == Weather.THUNDER


## How bright the last lightning strike still is, 0..1.
func thunder_flash() -> float:
	return _flash


func set_weather(w: int, instantly: bool = false) -> void:
	weather = w
	weather_timer = randf_range(WEATHER_MIN, WEATHER_MAX)
	if instantly:
		rain_level = 0.0 if w == Weather.CLEAR else 1.0
		_flash = 0.0


func _advance_weather(delta: float) -> void:
	weather_timer -= delta
	if weather_timer <= 0.0:
		if weather == Weather.CLEAR:
			# a storm is rarer than ordinary rain
			set_weather(Weather.THUNDER if randf() < 0.25 else Weather.RAIN)
		else:
			set_weather(Weather.CLEAR)
	var target := 0.0 if weather == Weather.CLEAR else 1.0
	rain_level = lerpf(rain_level, target, clampf(delta * 0.4, 0.0, 1.0))
	if weather == Weather.THUNDER and rain_level > 0.8 and randf() < delta * 0.30:
		_flash = 1.0
	_flash = maxf(0.0, _flash - delta * 4.0)


## Depth fog fades the terrain into the horizon colour right at the render
## distance, so the edge of the loaded world is never visible.
func set_render_distance(rd: int) -> void:
	_auto_fog_end = maxf(56.0, float(rd) * 16.0 - 6.0)
	_auto_fog_begin = maxf(22.0, _auto_fog_end * 0.45)
	apply_fog()


## The user-facing half of the fog: `fog_scale` stretches how far you can see
## before the haze swallows the world (the knob that matters when you crank the
## render distance up), and `fog_enabled` removes the distant haze entirely.
func apply_fog() -> void:
	if env == null:
		return
	env.fog_enabled = Settings.fog_enabled
	var s := clampf(Settings.fog_scale, 0.3, 4.0)
	_fog_end = _auto_fog_end * s
	_fog_begin = minf(_auto_fog_begin * s, _fog_end * 0.9)

const SKY_DAY_TOP := Color(0.36, 0.58, 0.95)
const SKY_DAY_HORIZON := Color(0.70, 0.84, 0.98)
const SKY_NIGHT_TOP := Color(0.02, 0.03, 0.09)
const SKY_NIGHT_HORIZON := Color(0.05, 0.07, 0.16)
const SKY_DUSK_TOP := Color(0.16, 0.20, 0.44)
const SKY_DUSK_HORIZON := Color(0.92, 0.50, 0.28)
const GROUND_DAY := Color(0.36, 0.33, 0.28)
const GROUND_NIGHT := Color(0.03, 0.04, 0.06)
const FOG_DAY := Color(0.72, 0.84, 0.97)
const FOG_NIGHT := Color(0.04, 0.05, 0.11)
const FOG_DUSK := Color(0.80, 0.55, 0.40)

## Sky light at noon and at midnight. Minecraft's daylight is directional enough that a
## block's top and its sides read as different shades; a near-full ambient flattens that
## out and the terrain turns into one flat green. The midnight floor stays well clear of
## zero so a night is *dim*, not unplayably black, and a torch still has something to be
## brighter than.
const AMBIENT_DAY := 0.62
const AMBIENT_NIGHT := 0.34
## The sun's own strength at noon. Raised alongside the lower ambient: contrast has to come
## from somewhere, and taking it out of the ambient without putting it back in the sun
## just makes the world dark.
const SUN_DAY := 1.45
## Moonlight, so a night has shape instead of being a black silhouette.
const MOON_NIGHT := 0.30


func _ready() -> void:
	world_env = WorldEnvironment.new()
	env = Environment.new()
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_curve = 0.18
	sky_mat.ground_curve = 0.12
	sky_mat.sun_angle_max = 3.0
	sky_mat.sun_curve = 0.08

	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 1.0

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.tonemap_white = 6.0

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = 34.0
	env.fog_depth_end = 100.0
	env.fog_depth_curve = 1.0
	env.fog_density = 1.0
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.35

	env.ssao_enabled = false
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 1.1
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	env.adjustment_contrast = 1.04

	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.14
	sun.shadow_normal_bias = 3.0
	sun.light_angular_distance = 0.6
	add_child(sun)

	moon = DirectionalLight3D.new()
	moon.shadow_enabled = false
	moon.light_color = Color(0.60, 0.70, 1.0)
	moon.light_energy = 0.0
	add_child(moon)

	apply_quality()
	update_sky(0.0)


func apply_quality() -> void:
	var size := Settings.shadow_size()
	sun.shadow_enabled = size > 0
	ProjectSettings.set_setting("rendering/lights_and_shadows/directional_shadow/size", maxi(1024, size))
	sun.directional_shadow_max_distance = Settings.shadow_distance()


## The environment half of a render pack. Called alongside
## Blocks.apply_render_preset so the terrain materials and the atmosphere always
## agree. 0 Classic is exactly the values the environment was first built with.
func apply_render_preset(preset: int) -> void:
	match preset:
		1:   # Soft: flat and gentle, strong bloom tamed
			env.tonemap_exposure = 1.12
			env.glow_intensity = 0.18
			env.glow_bloom = 0.04
			env.ssao_enabled = false
			_base_saturation = 0.96
			env.adjustment_saturation = _base_saturation
			env.adjustment_contrast = 0.98
		2:   # Vibrant: bright, saturated, contact shadows on for punch
			env.tonemap_exposure = 1.0
			env.glow_intensity = 0.55
			env.glow_bloom = 0.14
			env.glow_hdr_threshold = 1.0
			env.ssao_enabled = true
			_base_saturation = 1.28
			env.adjustment_saturation = _base_saturation
			env.adjustment_contrast = 1.10
		_:   # Classic
			env.tonemap_exposure = 1.05
			env.glow_intensity = 0.35
			env.glow_bloom = 0.08
			env.glow_hdr_threshold = 1.1
			env.ssao_enabled = false
			_base_saturation = 1.08
			env.adjustment_saturation = _base_saturation
			env.adjustment_contrast = 1.04


func advance(delta: float) -> void:
	if running:
		time_of_day = fmod(time_of_day + delta / DAY_LENGTH, 1.0)
		_advance_weather(delta)
	update_sky(delta)


func update_sky(delta: float) -> void:
	var a := (time_of_day - 0.25) * TAU
	var elev := sin(a)
	var day := smoothstep(0.02, 0.32, elev)
	var night := smoothstep(-0.06, -0.30, elev)
	var dusk := 1.0 - day - night
	dusk = clampf(dusk, 0.0, 1.0)

	var top := SKY_DAY_TOP.lerp(SKY_NIGHT_TOP, night).lerp(SKY_DUSK_TOP, dusk * 0.8)
	var horizon := SKY_DAY_HORIZON.lerp(SKY_NIGHT_HORIZON, night).lerp(SKY_DUSK_HORIZON, dusk * 0.85)
	var ground := GROUND_DAY.lerp(GROUND_NIGHT, night)
	var fogc := FOG_DAY.lerp(FOG_NIGHT, night).lerp(FOG_DUSK, dusk * 0.7)

	# a storm drains the colour out of the sky and flattens the light
	var wet := rain_level
	if wet > 0.001:
		top = top.lerp(Color(0.13, 0.15, 0.18), wet * 0.85)
		horizon = horizon.lerp(Color(0.30, 0.32, 0.35), wet * 0.80)
		ground = ground.lerp(Color(0.12, 0.12, 0.13), wet * 0.60)
		fogc = fogc.lerp(Color(0.36, 0.38, 0.41), wet * 0.85)

	sky_mat.sky_top_color = top
	sky_mat.sky_horizon_color = horizon
	sky_mat.ground_bottom_color = ground
	sky_mat.ground_horizon_color = horizon.lerp(ground, 0.5)

	var sun_pos := Vector3(cos(a) * 120.0, elev * 120.0, 40.0)
	sun.look_at_from_position(sun_pos, Vector3.ZERO, Vector3.UP)
	sun.light_energy = lerpf(0.0, SUN_DAY, day) * lerpf(1.0, 0.35, wet)
	sun.light_color = Color(1.0, 0.97, 0.90).lerp(Color(1.0, 0.62, 0.34), dusk)

	var moon_pos := Vector3(-cos(a) * 120.0, -elev * 120.0, 40.0)
	moon.look_at_from_position(moon_pos, Vector3.ZERO, Vector3.UP)
	moon.light_energy = lerpf(0.0, MOON_NIGHT, night)

	env.ambient_light_energy = lerpf(AMBIENT_NIGHT, AMBIENT_DAY, day) * lerpf(1.0, 0.65, wet)
	var target_fog := fogc
	var target_amb := env.ambient_light_energy
	var fb := _fog_begin
	var fe := _fog_end

	if _underwater_blend > 0.001:
		target_fog = target_fog.lerp(Color(0.08, 0.22, 0.42), _underwater_blend)
		target_amb = lerpf(target_amb, 0.45, _underwater_blend)
		fb = lerpf(fb, 0.0, _underwater_blend)
		fe = lerpf(fe, 16.0, _underwater_blend)
		env.adjustment_saturation = lerpf(_base_saturation, _base_saturation * 0.79,
			_underwater_blend)

	if _flash > 0.001:
		# a lightning strike washes the world white for a moment
		target_fog = target_fog.lerp(Color(0.90, 0.92, 1.0), _flash * 0.7)
		target_amb += _flash * 0.9

	env.fog_light_color = target_fog
	env.fog_depth_begin = fb
	env.fog_depth_end = fe
	env.ambient_light_energy = target_amb


func set_underwater(active: bool, delta: float) -> void:
	var target := 1.0 if active else 0.0
	var prev := _underwater_blend
	_underwater_blend = lerpf(_underwater_blend, target, clampf(delta * 6.0, 0.0, 1.0))
	if absf(_underwater_blend - target) < 0.01:
		_underwater_blend = target
	underwater = _underwater_blend > 0.5
	if absf(prev - _underwater_blend) > 0.002:
		update_sky(delta)


func is_night() -> bool:
	var a := (time_of_day - 0.25) * TAU
	return sin(a) < -0.05


func clock_text() -> String:
	var total := time_of_day * 24.0
	var h := int(total) % 24
	var m := int((total - float(int(total))) * 60.0)
	return "%02d:%02d" % [h, m]