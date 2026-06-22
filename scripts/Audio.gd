# =============================================================================
# Audio.gd  (class_name GameAudio)
#
# All game audio, synthesized procedurally in code — no sound files. Three parts:
#
#   1. UFO WHISTLE  — a continuous theremin-style drone (real-time generator)
#                     that follows the saucer and rises in pitch when the beam
#                     fires. The classic "flying saucer" sound.
#   2. BIRDS        — short chirp phrases baked into a sample, played at random
#                     intervals from emitters placed up in the tree canopies
#                     (so chirps come from the forests around you).
#   3. COW MOO      — a stylised synth moo baked into a sample. Each cow owns a
#                     3D player (see Cow.gd); this class just bakes the shared
#                     AudioStreamWAV that every cow reuses.
#
# Sounds are built from raw PCM: we fill a float buffer in [-1, 1], normalise it,
# and pack it to 16-bit. The whistle instead streams samples live so it can
# react to the beam.
# =============================================================================
class_name GameAudio
extends Node

const RATE := 22050   # sample rate for everything (plenty for these sounds)

# --- UFO whistle (live-synthesised) ------------------------------------------
var _whistle_player: AudioStreamPlayer
var _whistle_playback: AudioStreamGeneratorPlayback
var _phase := 0.0     # oscillator phase (wrapped to avoid float drift)
var _t := 0.0         # elapsed time, drives the slow LFOs
var _cur_freq := 520.0 # smoothed base pitch

# --- Baked one-shot samples (shared) -----------------------------------------
var moo_stream: AudioStreamWAV       # handed to every cow
var _bird_stream: AudioStreamWAV
var _bird_emitters: Array[AudioStreamPlayer3D] = []
var _bird_countdown := 2.0


func _ready() -> void:
	moo_stream = render_moo(RATE)
	_bird_stream = render_bird_phrase(RATE)
	_build_whistle()


# -----------------------------------------------------------------------------
# UFO whistle: a streaming generator we feed every frame.
# -----------------------------------------------------------------------------
func _build_whistle() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.3
	_whistle_player = AudioStreamPlayer.new()
	_whistle_player.name = "Whistle"
	_whistle_player.stream = gen
	_whistle_player.volume_db = -15.0   # quiet background drone
	add_child(_whistle_player)
	_whistle_player.play()
	_whistle_playback = _whistle_player.get_stream_playback() as AudioStreamGeneratorPlayback


# Place a few bird emitters up in random tree canopies. Call after the trees
# have been spawned.
func setup_birds() -> void:
	var trees := get_tree().get_nodes_in_group("trees")
	trees.shuffle()
	var count: int = min(6, trees.size())
	for i in count:
		var emitter := AudioStreamPlayer3D.new()
		emitter.stream = _bird_stream
		emitter.volume_db = -5.0
		emitter.max_distance = 90.0
		emitter.unit_size = 14.0
		var tree: Node3D = trees[i]
		tree.add_child(emitter)
		emitter.position.y = 5.0   # up among the leaves
		_bird_emitters.append(emitter)


func _process(delta: float) -> void:
	_fill_whistle()
	_tick_birds(delta)


# Trigger a random bird to chirp every couple of seconds.
func _tick_birds(delta: float) -> void:
	if _bird_emitters.is_empty():
		return
	_bird_countdown -= delta
	if _bird_countdown <= 0.0:
		var emitter := _bird_emitters[randi() % _bird_emitters.size()]
		emitter.pitch_scale = randf_range(0.9, 1.3)   # vary the "bird"
		emitter.play()
		_bird_countdown = randf_range(1.5, 4.5)


# Stream the theremin: synthesise exactly as many frames as the buffer wants.
func _fill_whistle() -> void:
	if _whistle_playback == null:
		return

	# Pitch climbs while the tractor beam is firing.
	var saucer := get_tree().get_first_node_in_group("saucer") as Saucer
	var beaming := saucer != null and saucer.beam_active
	var target := 780.0 if beaming else 520.0
	_cur_freq = lerp(_cur_freq, target, 0.08)

	var frames := _whistle_playback.get_frames_available()
	if frames <= 0:
		return

	var buffer := PackedVector2Array()
	buffer.resize(frames)
	for i in frames:
		var slow := sin(_t * TAU * 0.13)   # very slow eerie wander
		var vib := sin(_t * TAU * 5.5)     # vibrato
		var f := _cur_freq + slow * 45.0 + vib * 18.0
		_phase += TAU * f / float(RATE)
		_phase = fmod(_phase, TAU)          # keep float precision over time
		var s := 0.55 * sin(_phase) + 0.18 * sin(2.0 * _phase) + 0.08 * sin(3.0 * _phase)
		var trem := 0.82 + 0.18 * sin(_t * TAU * 0.7)   # gentle tremolo
		s *= trem * 0.6
		buffer[i] = Vector2(s, s)
		_t += 1.0 / float(RATE)
	_whistle_playback.push_buffer(buffer)


# =============================================================================
# Sample baking (static so anyone can call them without an instance)
# =============================================================================

# Pack a float buffer in [-1, 1] into a mono 16-bit AudioStreamWAV.
static func _pcm16(samples: PackedFloat32Array, rate: int) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		var v := int(round(clampf(samples[i], -1.0, 1.0) * 32767.0))
		bytes.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = false
	wav.mix_rate = rate
	wav.data = bytes
	return wav


# Scale a buffer so its loudest sample hits `peak`. Returns the buffer (packed
# arrays are copy-on-write, so we must return rather than mutate in place).
static func _normalize(samples: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var m := 0.0
	for s in samples:
		m = maxf(m, absf(s))
	if m > 0.0001:
		var gain := peak / m
		for i in samples.size():
			samples[i] *= gain
	return samples


# A Gaussian "bump" used to fake vocal formants.
static func _bump(f: float, center: float, width: float) -> float:
	var x := (f - center) / width
	return exp(-x * x)


# Vowel-ish formant weighting for the moo (emphasis around 520 Hz & 900 Hz).
static func _formant_gain(f: float) -> float:
	return _bump(f, 520.0, 180.0) + 0.7 * _bump(f, 900.0, 240.0) + 0.25


# Bake a single "moo": a low fundamental with a rise-then-fall pitch contour,
# summed harmonics shaped by formants, and an attack/release envelope.
static func render_moo(rate: int) -> AudioStreamWAV:
	var dur := 0.95
	var n := int(dur * rate)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var phase := 0.0
	for i in n:
		var u := float(i) / float(n)                 # 0..1 progress
		var f0 := 150.0 + 55.0 * sin(u * PI) - 25.0 * u   # "mooOOoo" contour
		f0 += 3.0 * sin(u * 40.0)                    # tiny wobble
		phase += TAU * f0 / float(rate)
		var s := 0.0
		for h in range(1, 14):                       # harmonics 1..13
			s += (1.0 / float(h)) * _formant_gain(f0 * float(h)) * sin(phase * float(h))
		# Envelope: ~60 ms attack, ~300 ms release.
		var env := 1.0
		var atk := 0.06
		var rel := 0.30
		if u < atk / dur:
			env = u * dur / atk
		elif u > 1.0 - rel / dur:
			env = (1.0 - u) * dur / rel
		samples[i] = s * env
	samples = _normalize(samples, 0.9)
	return _pcm16(samples, rate)


# Bake a short phrase of three quick chirps (each a frequency-swept tone with a
# smooth envelope), separated by little gaps — a "tweet-tweet-tweet".
static func render_bird_phrase(rate: int) -> AudioStreamWAV:
	var total := int(0.62 * rate)
	var samples := PackedFloat32Array()
	samples.resize(total)
	# Each chirp: [start_sec, length_sec, freq_low, freq_high]
	var chirps := [
		[0.00, 0.07, 3800.0, 5200.0],
		[0.16, 0.06, 4200.0, 5600.0],
		[0.30, 0.08, 3600.0, 5000.0],
	]
	for c in chirps:
		var start := int(c[0] * rate)
		var clen := int(c[1] * rate)
		var f_lo: float = c[2]
		var f_hi: float = c[3]
		var phase := 0.0
		for i in clen:
			var idx := start + i
			if idx >= total:
				break
			var u := float(i) / float(clen)
			var f := f_lo + (f_hi - f_lo) * sin(u * PI)   # sweep up then down
			phase += TAU * f / float(rate)
			var s := sin(phase) + 0.3 * sin(2.0 * phase)
			samples[idx] += s * sin(PI * u) * 0.6          # smooth attack/decay
	samples = _normalize(samples, 0.85)
	return _pcm16(samples, rate)
