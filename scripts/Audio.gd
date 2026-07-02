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
var bell_stream: AudioStreamWAV      # alpine cowbell; handed to the cows that wear one
var ding_stream: AudioStreamWAV      # metallic ricochet; handed to the saucer (farmer hits)
var _bird_stream: AudioStreamWAV
var _bird_emitters: Array[AudioStreamPlayer3D] = []
var _bird_countdown := 2.0

# Supplied by the World: the player saucer, cached so the whistle doesn't scan the
# "saucer" group every frame just to read beam_active.
var saucer: Saucer = null


func _ready() -> void:
	moo_stream = render_moo(RATE)
	bell_stream = render_bell(RATE)
	ding_stream = render_ding(RATE)
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


# Create a small pool of bird emitters. They are NOT parented to trees (those
# stream in and out as the player flies); instead each is repositioned to a
# random nearby spot just before it chirps, so birdsong always seems to drift
# out of the trees and sky around you.
func setup_birds() -> void:
	for i in 6:
		var emitter := AudioStreamPlayer3D.new()
		emitter.stream = _bird_stream
		emitter.volume_db = -5.0
		emitter.max_distance = 90.0
		emitter.unit_size = 14.0
		add_child(emitter)
		_bird_emitters.append(emitter)


func _process(delta: float) -> void:
	_fill_whistle()
	_tick_birds(delta)


# Trigger a random bird to chirp every couple of seconds, from a fresh spot
# somewhere around the saucer (up among where the trees and sky are).
func _tick_birds(delta: float) -> void:
	if _bird_emitters.is_empty():
		return
	_bird_countdown -= delta
	if _bird_countdown <= 0.0:
		var emitter := _bird_emitters[randi() % _bird_emitters.size()]
		if saucer != null:
			var angle := randf() * TAU
			var dist := randf_range(20.0, 70.0)
			emitter.global_position = saucer.global_position + Vector3(
				cos(angle) * dist, randf_range(-6.0, 8.0), sin(angle) * dist)
		emitter.pitch_scale = randf_range(0.9, 1.3)   # vary the "bird"
		emitter.play()
		_bird_countdown = randf_range(1.5, 4.5)


# Stream the theremin: synthesise exactly as many frames as the buffer wants.
func _fill_whistle() -> void:
	if _whistle_playback == null:
		return

	# Pitch climbs while the tractor beam is firing.
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


# Bake an alpine cowbell. A struck metal bell is a sum of INHARMONIC partials
# (non-integer frequency ratios), each decaying exponentially — higher partials
# die faster, which is why a bell goes "clank...mmm". The two lowest partials sit
# at a ~1.48 ratio: that clash is the signature that reads as "cowbell" rather
# than "chime". A short noise burst at the very start is the clapper strike.
# Recipe tuned in the Sound Lab: 400 Hz, 1.0 s ring, 0.6 brightness, 0.65 strike.
static func render_bell(rate: int) -> AudioStreamWAV:
	var freq := 400.0
	var decay := 1.0
	var bright := 0.6
	var strike := 0.65
	var dur := decay + 0.06
	var n := int(dur * rate)
	var samples := PackedFloat32Array()
	samples.resize(n)
	# [frequency ratio, amplitude, decay-speed multiplier].
	var partials := [
		[1.000, 1.00, 1.0],
		[1.480, 0.95, 1.15],   # the cowbell-defining clash
		[2.670, 0.55, 1.9],
		[3.930, 0.38, 2.7],
		[5.430, 0.24, 3.6],
		[6.790, 0.16, 4.6],
	]
	for i in n:
		var t := float(i) / float(rate)
		var s := 0.0
		for p in partials:
			var ratio: float = p[0]
			var amp: float = p[1]
			var dmult: float = p[2]
			if ratio > 1.5:
				amp *= 0.25 + bright          # brightness scales the metallic clank
			s += amp * exp(-t * dmult / decay) * sin(TAU * freq * ratio * t)
		if t < 0.012:                          # clapper strike: a short noise tick
			var k := 1.0 - t / 0.012
			s += strike * (randf() * 2.0 - 1.0) * k * k * 1.2
		samples[i] = s
	samples = _normalize(samples, 0.9)
	return _pcm16(samples, rate)


# Bake a "ding" — a bullet smacking a tin can, NOT a tuned bell. The character
# is dull and percussive: a loud noisy THUNK at impact, a few LOW, hollow,
# inharmonic resonances that die almost immediately, a faint buzzy rattle (thin
# tin), and a slight downward pitch bend that gives the hollow "bonk". Short and
# cheap, not pretty.
static func render_ding(rate: int) -> AudioStreamWAV:
	var dur := 0.18
	var n := int(dur * rate)
	var samples := PackedFloat32Array()
	samples.resize(n)
	# Low, hollow, inharmonic tin resonances: [frequency Hz, amplitude, decay-speed].
	var partials := [
		[340.0, 1.00, 30.0],
		[560.0, 0.75, 38.0],
		[870.0, 0.45, 50.0],
		[1230.0, 0.25, 66.0],
	]
	for i in n:
		var t := float(i) / float(rate)
		var bend := 1.0 - 0.12 * (t / dur)        # slight pitch sag -> hollow "bonk"
		var s := 0.0
		for p in partials:
			var freq: float = p[0] * bend
			var amp: float = p[1]
			var dspeed: float = p[2]
			s += amp * exp(-t * dspeed) * sin(TAU * freq * t)
		# The impact: a sharp noisy thunk at the very start...
		s += (randf() * 2.0 - 1.0) * exp(-t * 55.0) * 1.1
		# ...plus a quick buzzy rattle bleeding through the thin tin.
		s += (randf() * 2.0 - 1.0) * exp(-t * 30.0) * 0.25 * sin(TAU * 180.0 * t)
		samples[i] = s
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
