extends Node
## All audio is synthesised into AudioStreamWAV buffers at startup: no audio
## files ship with the project.

const RATE := 22050

var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _music: AudioStreamPlayer
var _sounds: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _music_volume := 0.45


func _ready() -> void:
	_rng.seed = 90210
	for i in 20:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)
	_music = AudioStreamPlayer.new()
	_music.bus = "Master"
	_music.volume_db = -60.0
	add_child(_music)
	_build_sounds()


# ================================================================ public api
func play(name: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if not _sounds.has(name):
		return
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = _sounds[name]
	p.volume_db = volume_db
	p.pitch_scale = clampf(pitch, 0.4, 2.5)
	p.play()


func play_varied(name: String, volume_db: float = 0.0, spread: float = 0.12) -> void:
	play(name, volume_db, 1.0 + _rng.randf_range(-spread, spread))


func start_music() -> void:
	if _music.playing:
		return
	_music.stream = _sounds.get("music")
	_music.play()


func stop_music() -> void:
	_music.stop()


func set_music_volume(v: float) -> void:
	_music_volume = clampf(v, 0.0, 1.0)
	if _music != null:
		_music.volume_db = -80.0 if _music_volume <= 0.001 else linear_to_db(_music_volume * 0.8)


func music_volume() -> float:
	return _music_volume


# ================================================================ synth helpers
func _blank(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	return a


func _noise(dur: float, decay: float, lp: float, gain: float, seed: int, tone_f: float = 0.0) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := _blank(n)
	var r := RandomNumberGenerator.new()
	r.seed = seed
	var y := 0.0
	for i in n:
		var t := float(i) / float(RATE)
		var env := exp(-decay * t)
		var s := r.randf_range(-1.0, 1.0)
		if tone_f > 0.0:
			s = s * 0.45 + sin(TAU * tone_f * t) * 0.8
		y += (s - y) * lp
		out[i] = y * env * gain
	return out


func _tone(f0: float, f1: float, dur: float, decay: float, gain: float, kind: int = 0) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := _blank(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / float(RATE)
		var k := t / maxf(dur, 0.0001)
		var f := lerpf(f0, f1, k)
		phase += TAU * f / float(RATE)
		var s := 0.0
		match kind:
			1:
				s = 1.0 if sin(phase) >= 0.0 else -1.0
			2:
				s = asin(sin(phase)) * 2.0 / PI
			_:
				s = sin(phase)
		out[i] = s * exp(-decay * t) * gain
	return out


func _mix(parts: Array) -> PackedFloat32Array:
	var n := 0
	for p in parts:
		n = maxi(n, p.size())
	var out := _blank(n)
	for p in parts:
		for i in p.size():
			out[i] += p[i]
	for i in n:
		out[i] = clampf(out[i], -1.0, 1.0)
	return out


func _wav(samples: PackedFloat32Array, loop: bool = false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	if loop:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = samples.size()
	return s


# ================================================================ sound design
func _build_sounds() -> void:
	_sounds["step_hard"] = _wav(_mix([
		_noise(0.07, 34.0, 0.30, 0.55, 11),
		_noise(0.05, 55.0, 0.75, 0.22, 12),
	]), false)
	_sounds["step_soft"] = _wav(_noise(0.09, 26.0, 0.14, 0.60, 21), false)
	_sounds["step_wood"] = _wav(_mix([
		_noise(0.06, 40.0, 0.45, 0.40, 31),
		_tone(220.0, 140.0, 0.06, 40.0, 0.18, 2),
	]), false)
	_sounds["step_snow"] = _wav(_noise(0.10, 22.0, 0.10, 0.45, 41), false)

	_sounds["dig"] = _wav(_noise(0.10, 22.0, 0.28, 0.45, 51), false)
	_sounds["break"] = _wav(_mix([
		_noise(0.34, 11.0, 0.45, 0.70, 61),
		_noise(0.18, 26.0, 0.85, 0.32, 62),
	]), false)
	_sounds["place"] = _wav(_mix([
		_noise(0.11, 28.0, 0.35, 0.62, 71),
		_tone(180.0, 90.0, 0.09, 30.0, 0.22, 2),
	]), false)
	_sounds["pop"] = _wav(_tone(420.0, 900.0, 0.10, 22.0, 0.35, 0), false)
	_sounds["click"] = _wav(_tone(880.0, 880.0, 0.045, 55.0, 0.28, 1), false)
	_sounds["hurt"] = _wav(_mix([
		_tone(340.0, 130.0, 0.26, 9.0, 0.42, 1),
		_noise(0.18, 20.0, 0.5, 0.22, 81),
	]), false)
	_sounds["death"] = _wav(_mix([
		_tone(300.0, 70.0, 0.85, 3.2, 0.45, 1),
		_tone(150.0, 45.0, 0.9, 3.0, 0.30, 1),
	]), false)
	_sounds["splash"] = _wav(_mix([
		_noise(0.42, 8.0, 0.55, 0.55, 91, 300.0),
		_noise(0.30, 14.0, 0.30, 0.30, 92),
	]), false)
	_sounds["craft"] = _wav(_mix([
		_tone(523.0, 523.0, 0.12, 12.0, 0.30, 2),
		_tone(659.0, 659.0, 0.12, 12.0, 0.30, 2),
	]), false)
	_sounds["eat"] = _wav(_mix([
		_noise(0.09, 30.0, 0.32, 0.38, 121),
		_noise(0.07, 48.0, 0.62, 0.22, 122),
	]), false)
	_sounds["levelup"] = _wav(_mix([
		_tone(523.0, 523.0, 0.55, 3.4, 0.28, 0),
		_tone(659.0, 659.0, 0.55, 3.4, 0.24, 0),
		_tone(784.0, 784.0, 0.60, 3.0, 0.24, 0),
	]), false)
	_sounds["music"] = _wav(_make_music(), true)

	# passive mob voices
	_sounds["mob_grunt"] = _wav(_mix([
		_tone(240.0, 170.0, 0.34, 8.0, 0.34, 1),
		_noise(0.22, 16.0, 0.35, 0.20, 111),
	]), false)
	_sounds["mob_low"] = _wav(_mix([
		_tone(150.0, 105.0, 0.72, 4.0, 0.36, 1),
		_tone(75.0, 52.0, 0.72, 4.0, 0.22, 1),
	]), false)
	_sounds["mob_bleat"] = _wav(_mix([
		_tone(430.0, 360.0, 0.42, 6.0, 0.26, 2),
		_tone(645.0, 540.0, 0.42, 7.5, 0.12, 2),
	]), false)
	_sounds["mob_cluck"] = _wav(_mix([
		_tone(900.0, 1500.0, 0.07, 40.0, 0.22, 1),
		_noise(0.05, 50.0, 0.9, 0.10, 112),
	]), false)

	# combat
	_sounds["mob_hurt"] = _wav(_mix([
		_tone(300.0, 170.0, 0.18, 16.0, 0.36, 1),
		_noise(0.12, 30.0, 0.5, 0.18, 131),
	]), false)
	_sounds["mob_die"] = _wav(_mix([
		_tone(320.0, 80.0, 0.55, 5.5, 0.42, 1),
		_tone(160.0, 55.0, 0.6, 5.0, 0.24, 1),
	]), false)
	_sounds["explode"] = _wav(_mix([
		_noise(0.75, 6.0, 0.22, 0.90, 141),
		_noise(0.55, 11.0, 0.55, 0.55, 142),
		_tone(90.0, 35.0, 0.7, 5.0, 0.42, 1),
	]), false)
	_sounds["fuse"] = _wav(_noise(0.35, 8.0, 0.75, 0.30, 151, 1800.0), false)
	_sounds["bow"] = _wav(_mix([
		_tone(600.0, 1300.0, 0.12, 26.0, 0.30, 2),
		_noise(0.08, 40.0, 0.6, 0.16, 152),
	]), false)
	_sounds["tool_break"] = _wav(_mix([
		_noise(0.22, 18.0, 0.7, 0.45, 161),
		_tone(520.0, 120.0, 0.18, 20.0, 0.22, 2),
	]), false)


## A slow, unobtrusive pad progression that loops seamlessly.
func _make_music() -> PackedFloat32Array:
	var bars := 8
	var beat := 2.0
	var total := int(float(bars) * beat * float(RATE))
	var out := _blank(total)
	# Am - F - C - G  (in semitones from A3)
	var roots := [0, -4, 3, -2]
	var third := [3, 4, 4, 4]
	var fifth := [7, 7, 7, 7]
	var base_freq := 220.0
	var r := RandomNumberGenerator.new()
	r.seed = 31337
	for bi in bars:
		var chord := bi % 4
		var start := int(float(bi) * beat * float(RATE))
		var length := int(beat * float(RATE))
		var notes := [roots[chord], roots[chord] + third[chord], roots[chord] + fifth[chord],
			roots[chord] + 12]
		for ni in notes.size():
			var semi: int = notes[ni]
			var f := base_freq * pow(2.0, float(semi) / 12.0)
			if ni == 3:
				f *= 0.5
			var amp := 0.10 if ni < 3 else 0.05
			var vib := r.randf_range(0.15, 0.35)
			var phase := 0.0
			for i in length:
				var idx := start + i
				if idx >= total:
					break
				var k := float(i) / float(length)
				var env := sin(PI * clampf(k, 0.0, 1.0))
				env = pow(env, 0.6)
				var t := float(i) / float(RATE)
				var lfo := 1.0 + sin(TAU * 0.13 * t + float(ni)) * 0.0016 * vib
				phase += TAU * f * lfo / float(RATE)
				out[idx] += sin(phase) * env * amp
		# a sparse bell on the off-beat
		if bi % 2 == 1:
			var bf := base_freq * 4.0 * pow(2.0, float(roots[chord]) / 12.0)
			var bstart := start + int(0.75 * float(RATE))
			for i in int(1.2 * float(RATE)):
				var idx2 := bstart + i
				if idx2 >= total:
					break
				var t2 := float(i) / float(RATE)
				out[idx2] += sin(TAU * bf * t2) * exp(-3.6 * t2) * 0.055
				out[idx2] += sin(TAU * bf * 2.0 * t2) * exp(-6.0 * t2) * 0.02
	for i in total:
		out[i] = clampf(out[i] * 0.9, -1.0, 1.0)
	return out


# ================================================================ material mapping
func step_sound_for(block_id: int) -> String:
	match block_id:
		Blocks.STONE, Blocks.COBBLESTONE, Blocks.BEDROCK, Blocks.COAL_ORE, Blocks.IRON_ORE, \
		Blocks.GOLD_ORE, Blocks.DIAMOND_ORE, Blocks.OBSIDIAN, Blocks.BRICK, Blocks.SANDSTONE, \
		Blocks.GLOWSTONE, Blocks.FURNACE, Blocks.FURNACE_LIT:
			return "step_hard"
		Blocks.PLANKS, Blocks.LOG, Blocks.CRAFTING_TABLE, Blocks.CHEST, Blocks.DOOR, \
		Blocks.DOOR_OPEN, Blocks.FENCE, Blocks.LADDER:
			return "step_wood"
		Blocks.SNOW:
			return "step_snow"
		Blocks.SAND, Blocks.GRAVEL, Blocks.DIRT, Blocks.GRASS, Blocks.LEAVES, Blocks.TALL_GRASS, \
		Blocks.FLOWER_RED, Blocks.FLOWER_YELLOW, Blocks.CACTUS, Blocks.FARMLAND:
			return "step_soft"
	return "step_soft"