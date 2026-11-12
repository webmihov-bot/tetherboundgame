extends Node
## ProceduralSoundscape - everything you hear is synthesized here, live.
## No audio files. One AudioStreamGenerator, filled every frame with:
##   - a detuned saw drone (A1 + fifth)
##   - an arpeggiated bassline (A minor pentatonic, 104 bpm eighth notes)
##   - sine chimes, denser and louder near Harmonic Cores
##   - a sub-bass storm rumble
##   - one-shot voices for chords, thunder and the anchor clunk
## Gameplay drives it: tether tension opens the low-pass filter, core
## proximity adds the melodic layer, storm intensity adds the rumble.

const RATE := 22050.0
const SCALE: Array[int] = [0, 3, 5, 7, 10, 12, 15, 17, 19, 22, 24]
const ARP: Array[int] = [0, 0, 12, 7, 0, 10, 12, 3]
const CHORDS: Array = [[0, 3, 7, 12], [-4, 0, 3, 8], [-2, 2, 5, 10]]

@export var master_volume_db := -7.0

var tension := 0.0
var core_proximity := 0.0
var storm := 0.2

var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _game: Node
var _voices: Array = []  # each: [frequency, phase, amplitude, decay per sample]
var _d1 := 0.0
var _d2 := 0.0
var _d3 := 0.0
var _lp1 := 0.0
var _lp2 := 0.0
var _bass_phase := 0.0
var _bass_freq := 55.0
var _bass_env := 0.0
var _step := -1
var _step_time := 0.0
var _rumble_phase := 0.0
var _rumble_noise := 0.0
var _noise_amp := 0.0
var _noise_lp := 0.0
var _chime_timer := 2.0
var _smooth_tension := 0.0
var _smooth_core := 0.0
var _smooth_storm := 0.2


func _ready() -> void:
	_game = get_tree().get_first_node_in_group("game")
	if NetworkManager.is_headless():
		set_process(false)
		return
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = RATE
	stream.buffer_length = 0.12
	_player = AudioStreamPlayer.new()
	_player.stream = stream
	_player.volume_db = master_volume_db
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback


# ------------------------------------------------------------- one-shots

func _add_voice(freq: float, amp: float, seconds: float) -> void:
	if _playback == null:
		return
	if _voices.size() > 14:
		_voices.remove_at(0)
	_voices.append([freq, 0.0, amp, exp(-1.0 / (RATE * maxf(seconds, 0.01)))])


func _note(semitones: int, base: float = 220.0) -> float:
	return base * pow(2.0, float(semitones) / 12.0)


func play_chime(semitones: int, amp: float = 0.15) -> void:
	_add_voice(_note(semitones, 440.0), amp, 0.9)
	_add_voice(_note(semitones, 880.0) * 1.003, amp * 0.35, 0.5)


func play_chord(idx: int) -> void:
	var chord: Array = CHORDS[clampi(idx, 0, CHORDS.size() - 1)]
	for semis in chord:
		_add_voice(_note(int(semis)), 0.16, 1.6)
	_add_voice(_note(int(chord[0]), 110.0), 0.2, 2.0)


func play_thunder() -> void:
	_noise_amp = maxf(_noise_amp, 0.7)
	_add_voice(46.0, 0.45, 1.2)


## Hull crash: a deep thud and scraping noise, bigger with strength 0..1.
func play_crash(strength: float) -> void:
	_noise_amp = maxf(_noise_amp, 0.25 + strength * 0.55)
	_add_voice(38.0, 0.35 + strength * 0.3, 0.5 + strength * 0.8)
	_add_voice(57.0, 0.2, 0.25)
	_add_voice(131.0 + strength * 40.0, 0.12, 0.12)


func play_clunk() -> void:
	_noise_amp = maxf(_noise_amp, 0.18)
	_add_voice(92.0, 0.4, 0.12)
	_add_voice(184.0, 0.15, 0.06)


# --------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if _playback == null:
		return
	var target_tension := 0.0
	var target_core := 0.0
	if _game != null:
		storm = float(_game.storm)
		var local: Node3D = _game.get_local_player()
		if local != null:
			target_tension = maxf(float(local.tension), float(_game.tether.charge) * 0.6)
			var core: Variant = _game.world.nearest_core(local.global_position)
			if core != null:
				target_core = clampf(1.0 - local.global_position.distance_to(core) / 45.0, 0.0, 1.0)
	tension = target_tension
	core_proximity = target_core
	_smooth_tension = lerpf(_smooth_tension, tension, clampf(delta * 5.0, 0.0, 1.0))
	_smooth_core = lerpf(_smooth_core, core_proximity, clampf(delta * 2.0, 0.0, 1.0))
	_smooth_storm = lerpf(_smooth_storm, storm, clampf(delta * 1.0, 0.0, 1.0))

	_chime_timer -= delta
	if _chime_timer <= 0.0:
		_chime_timer = lerpf(3.2, 0.3, _smooth_core) * randf_range(0.7, 1.3)
		if _smooth_core > 0.05 or randf() < 0.35:
			var semis: int = SCALE[randi() % SCALE.size()]
			play_chime(semis, 0.05 + 0.16 * _smooth_core)
	_fill()


func _fill() -> void:
	var frames := mini(_playback.get_frames_available(), 4096)
	if frames <= 0:
		return
	var buffer := PackedVector2Array()
	buffer.resize(frames)

	var dt := 1.0 / RATE
	var cutoff := lerpf(320.0, 5200.0, clampf(_smooth_tension, 0.0, 1.0))
	var alpha := 1.0 - exp(-TAU * cutoff / RATE)
	var step_len := 60.0 / 104.0 / 2.0
	var bass_decay := exp(-dt * 7.0)
	var storm_gain := _smooth_storm * 0.55
	var bass_gain := 0.26 + 0.1 * _smooth_tension

	var d1 := _d1
	var d2 := _d2
	var d3 := _d3
	var lp1 := _lp1
	var lp2 := _lp2
	var bass_phase := _bass_phase
	var bass_freq := _bass_freq
	var bass_env := _bass_env
	var step_time := _step_time
	var rumble_phase := _rumble_phase
	var rumble_noise := _rumble_noise
	var noise_amp := _noise_amp
	var noise_lp := _noise_lp
	var voice_count := _voices.size()

	for i in frames:
		# Drone: two detuned saws on A1 and a quieter fifth.
		d1 += 55.0 * dt
		if d1 >= 1.0:
			d1 -= 1.0
		d2 += 55.42 * dt
		if d2 >= 1.0:
			d2 -= 1.0
		d3 += 82.41 * dt
		if d3 >= 1.0:
			d3 -= 1.0
		var x := (d1 + d2 - 1.0) * 0.44 + (d3 * 2.0 - 1.0) * 0.12

		# Arpeggiated bass.
		step_time += dt
		if step_time >= step_len:
			step_time -= step_len
			_step = (_step + 1) % 16
			var semis: int = ARP[_step % 8]
			if _step >= 8 and _step % 4 == 3:
				semis += 12
			bass_freq = 55.0 * pow(2.0, float(semis) / 12.0)
			bass_env = 1.0
		bass_phase += bass_freq * dt
		if bass_phase >= 1.0:
			bass_phase -= 1.0
		var square := 1.0 if bass_phase < 0.5 else -1.0
		x += (square * 0.5 + (bass_phase * 2.0 - 1.0) * 0.5) * bass_env * bass_gain
		bass_env *= bass_decay

		# Two-pole low-pass; tether tension opens it up.
		lp1 += alpha * (x - lp1)
		lp2 += alpha * (lp1 - lp2)
		var s := lp2

		# Storm: sub-bass rumble with slow random swell.
		rumble_phase += 37.0 * dt
		if rumble_phase >= 1.0:
			rumble_phase -= 1.0
		rumble_noise += 0.0015 * (randf() * 2.0 - 1.0 - rumble_noise)
		s += sin(rumble_phase * TAU) * storm_gain * (0.6 + rumble_noise * 12.0)

		# Chimes, chords and other one-shot sine voices.
		for v in voice_count:
			var voice: Array = _voices[v]
			var phase: float = voice[1]
			var amp: float = voice[2]
			s += sin(phase * TAU) * amp
			phase += float(voice[0]) * dt
			if phase >= 1.0:
				phase -= 1.0
			voice[1] = phase
			voice[2] = amp * float(voice[3])

		# Thunder / impact noise burst.
		if noise_amp > 0.001:
			noise_lp += 0.12 * (randf() * 2.0 - 1.0 - noise_lp)
			s += noise_lp * noise_amp * 2.0
			noise_amp *= 0.99975

		s = clampf(s * 0.8, -1.0, 1.0)
		buffer[i] = Vector2(s, s)

	_d1 = d1
	_d2 = d2
	_d3 = d3
	_lp1 = lp1
	_lp2 = lp2
	_bass_phase = bass_phase
	_bass_freq = bass_freq
	_bass_env = bass_env
	_step_time = step_time
	_rumble_phase = rumble_phase
	_rumble_noise = rumble_noise
	_noise_amp = noise_amp
	_noise_lp = noise_lp
	for v in range(_voices.size() - 1, -1, -1):
		if float(_voices[v][2]) < 0.0008:
			_voices.remove_at(v)
	_playback.push_buffer(buffer)
