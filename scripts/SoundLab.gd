# =============================================================================
# SoundLab.gd  —  procedural-synthesis bench (NOT part of the game)
#
# Open scenes/SoundLab.tscn and press F6 (Run Current Scene) to prototype new
# *code-synthesised* sounds before touching the real Audio.gd. No sample files,
# no imported assets — every sound is baked from raw PCM, exactly like the game.
# Running this never changes Main.tscn / the real game.
#
# Two instruments so far:
#   MOO  — vowel-morph moo (m->oo->aw) with roughness + breath. The recipe we
#          liked is preset 3 ("breathy / rough"), which is also the moo default.
#   BELL — alpine cowbell: two inharmonic partials at a ~1.48 ratio (the classic
#          "cowbell" signature) + upper metallic partials + a strike transient,
#          under a fast exponential decay. Clonky, not a pure ringing bell.
#
# Auditions through the SAME 3D path a cow uses (distance + randomised pitch).
# Tell me the instrument + preset + knob values you like and I lock that recipe
# into Audio.gd. The synths are _render_moo() / _render_bell() below.
# =============================================================================
extends Node3D

const RATE := 22050

# --- Mirror Cow.gd's 3D player so the preview is faithful. -------------------
const COW_MAX_DISTANCE := 80.0
const COW_UNIT_SIZE := 12.0
const COW_VOLUME_DB := -3.0
const COW_PITCH_IDLE := Vector2(0.85, 1.12)
const COW_PITCH_PANIC := Vector2(1.3, 1.6)

var _instrument := "bell"   # "moo" or "bell" (start on bell — that's today's job)

# --- MOO knobs (default = the preset-3 recipe we liked) ----------------------
var _moo_fund := 100.0
var _moo_rough := 0.35
var _moo_breath := 0.25
var _moo_length := 1.45

# --- BELL knobs --------------------------------------------------------------
var _bell_freq := 520.0     # Hz, base partial
var _bell_decay := 0.25     # s, ring time (short = clonky/damped)
var _bell_bright := 0.40    # 0..1, level of the upper metallic partials
var _bell_strike := 0.50    # 0..1, the noisy clapper "tick" at onset

var _preset_name := "alpine clonk"

# --- Audition context --------------------------------------------------------
var _sim_distance := 15.0
var _pitch_mode := 1        # 0 fixed, 1 idle-random, 2 panic-random
var _last_pitch := 1.0
var _use_original := false  # moo preset 1 plays the unmodified current game moo

var _source := AudioStreamPlayer3D.new()
var _flat := AudioStreamPlayer.new()
var _label: Label
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	var cam := Camera3D.new()
	cam.current = true
	add_child(cam)
	_source.max_distance = COW_MAX_DISTANCE
	_source.unit_size = COW_UNIT_SIZE
	_source.volume_db = COW_VOLUME_DB
	add_child(_source)
	add_child(_flat)
	_build_ui()
	_refresh()


# =============================================================================
# MOO synth  (vowel morph m -> oo -> aw, optional roughness + breath)
# =============================================================================
func _render_moo() -> AudioStreamWAV:
	var n := int(_moo_length * RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var phase := 0.0
	var lp := 0.0
	for i in n:
		var u := float(i) / float(n)
		var f0 := _moo_fund * _contour(u)
		f0 *= 1.0 + _moo_rough * 0.02 * (_rng.randf() * 2.0 - 1.0)
		phase += TAU * f0 / float(RATE)
		var f1 := _morph(u, 280.0, 350.0, 620.0)
		var f2 := _morph(u, 900.0, 760.0, 1080.0)
		var s := 0.0
		for h in range(1, 18):
			s += (1.0 / float(h)) * _formant(f0 * float(h), f1, f2) * sin(phase * float(h))
		if _moo_rough > 0.0:
			s += _moo_rough * 0.35 * sin(phase * 0.5)
		if _moo_breath > 0.0:
			var noise := _rng.randf() * 2.0 - 1.0
			lp += (noise - lp) * 0.10
			var breath_env := exp(-u * 6.0) + 0.4 * u * u
			s += _moo_breath * 0.6 * lp * breath_env
		if _moo_rough > 0.0:
			var t := float(i) / float(RATE)
			s *= 1.0 - _moo_rough * 0.5 * (0.5 + 0.5 * sin(TAU * 33.0 * t))
		s *= _amp_env(u)
		samples[i] = s
	samples = _normalize(samples, 0.92)
	return _pcm16(samples, RATE)


func _contour(u: float) -> float:
	if u < 0.20:
		return lerpf(0.90, 1.12, smoothstep(0.0, 1.0, u / 0.20))
	elif u < 0.55:
		return 1.12
	elif u < 0.85:
		return lerpf(1.12, 0.92, (u - 0.55) / 0.30)
	else:
		return lerpf(0.92, 0.78, (u - 0.85) / 0.15)


func _morph(u: float, a: float, b: float, c: float) -> float:
	if u < 0.45:
		return lerpf(a, b, smoothstep(0.0, 1.0, u / 0.45))
	else:
		return lerpf(b, c, smoothstep(0.0, 1.0, (u - 0.45) / 0.55))


func _formant(f: float, c1: float, c2: float) -> float:
	return _bump(f, c1, 140.0) + 0.7 * _bump(f, c2, 220.0) + 0.18


func _amp_env(u: float) -> float:
	var atk := 0.12
	var rel := 0.38
	if u < atk:
		return smoothstep(0.0, 1.0, u / atk)
	elif u > 1.0 - rel:
		return smoothstep(0.0, 1.0, (1.0 - u) / rel)
	return 1.0


# =============================================================================
# BELL synth  (alpine cowbell)
#
# A struck metal bell is a sum of INHARMONIC partials (non-integer frequency
# ratios), each decaying exponentially — higher partials die faster, which is
# why a bell goes "clank...mmm". The two lowest partials sit at a ~1.48 ratio:
# that specific clash is the signature that makes the ear hear "cowbell" rather
# than "chime". A short noise burst at the very start is the clapper strike.
# =============================================================================
func _render_bell() -> AudioStreamWAV:
	var dur := _bell_decay + 0.06
	var n := int(dur * RATE)
	var samples := PackedFloat32Array()
	samples.resize(n)

	# Partials: [frequency ratio, amplitude, decay-speed multiplier].
	# 1.0 + 1.48 are the body; the rest are sparse, fast-dying metallic clank.
	var partials := [
		[1.000, 1.00, 1.0],
		[1.480, 0.95, 1.15],   # the cowbell-defining clash
		[2.670, 0.55, 1.9],
		[3.930, 0.38, 2.7],
		[5.430, 0.24, 3.6],
		[6.790, 0.16, 4.6],
	]

	for i in n:
		var t := float(i) / float(RATE)
		var s := 0.0
		for p in partials:
			var ratio: float = p[0]
			var amp: float = p[1]
			var dmult: float = p[2]
			# Upper partials (ratio>1.48) are scaled by brightness so the knob
			# moves between dull "dunder" and bright metallic clank.
			if ratio > 1.5:
				amp *= 0.25 + _bell_bright
			var env := exp(-t * dmult / _bell_decay)
			s += amp * env * sin(TAU * _bell_freq * ratio * t)
		# Clapper strike: a very short, fast-decaying noise tick.
		if _bell_strike > 0.0 and t < 0.012:
			var k := 1.0 - t / 0.012
			s += _bell_strike * (_rng.randf() * 2.0 - 1.0) * k * k * 1.2
		samples[i] = s

	samples = _normalize(samples, 0.92)
	return _pcm16(samples, RATE)


# =============================================================================
# Shared PCM helpers
# =============================================================================
static func _bump(f: float, center: float, width: float) -> float:
	var x := (f - center) / width
	return exp(-x * x)


static func _normalize(samples: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var m := 0.0
	for s in samples:
		m = maxf(m, absf(s))
	if m > 0.0001:
		var gain := peak / m
		for i in samples.size():
			samples[i] *= gain
	return samples


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


# =============================================================================
# Presets — starting points you then fine-tune with the live knobs.
# =============================================================================
func _apply_preset(idx: int) -> void:
	_use_original = false
	if _instrument == "moo":
		match idx:
			1:
				_use_original = true
				_preset_name = "MOO: ORIGINAL (current game moo)"
			2:
				_moo_fund = 110.0; _moo_rough = 0.0; _moo_breath = 0.05; _moo_length = 1.30
				_preset_name = "MOO: clean vowel-morph"
			3:
				_moo_fund = 100.0; _moo_rough = 0.35; _moo_breath = 0.25; _moo_length = 1.45
				_preset_name = "MOO: breathy / rough (the keeper)"
			4:
				_moo_fund = 95.0;  _moo_rough = 0.15; _moo_breath = 0.10; _moo_length = 1.60
				_preset_name = "MOO: distant lowing"
	else:
		match idx:
			1:
				_bell_freq = 520.0; _bell_decay = 0.25; _bell_bright = 0.40; _bell_strike = 0.50
				_preset_name = "BELL: alpine clonk"
			2:
				_bell_freq = 600.0; _bell_decay = 0.70; _bell_bright = 0.60; _bell_strike = 0.35
				_preset_name = "BELL: ringing"
			3:
				_bell_freq = 880.0; _bell_decay = 0.18; _bell_bright = 0.80; _bell_strike = 0.60
				_preset_name = "BELL: small tinkle"
			4:
				_bell_freq = 360.0; _bell_decay = 0.35; _bell_bright = 0.25; _bell_strike = 0.45
				_preset_name = "BELL: deep dunder"
	_refresh()


# =============================================================================
# Input
# =============================================================================
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_M: _instrument = "moo"; _apply_preset(3); _refresh()
		KEY_B: _instrument = "bell"; _apply_preset(1); _refresh()
		KEY_1: _apply_preset(1)
		KEY_2: _apply_preset(2)
		KEY_3: _apply_preset(3)
		KEY_4: _apply_preset(4)
		KEY_SPACE: _play(true)
		KEY_F: _play(false)
		KEY_Q: _knob(0, +1)
		KEY_A: _knob(0, -1)
		KEY_W: _knob(1, +1)
		KEY_S: _knob(1, -1)
		KEY_E: _knob(2, +1)
		KEY_D: _knob(2, -1)
		KEY_T: _knob(3, +1)
		KEY_G: _knob(3, -1)
		KEY_UP, KEY_BRACKETRIGHT: _sim_distance = minf(_sim_distance + 5.0, COW_MAX_DISTANCE); _refresh()
		KEY_DOWN, KEY_BRACKETLEFT: _sim_distance = maxf(_sim_distance - 5.0, 1.0); _refresh()
		KEY_P: _pitch_mode = (_pitch_mode + 1) % 3; _refresh()


# Knob index 0..3 maps to different params per instrument; dir is +1/-1.
func _knob(idx: int, dir: float) -> void:
	if _instrument == "moo":
		match idx:
			0: _moo_fund = clampf(_moo_fund + dir * 5.0, 60.0, 220.0)
			1: _moo_rough = clampf(_moo_rough + dir * 0.1, 0.0, 1.0)
			2: _moo_breath = clampf(_moo_breath + dir * 0.05, 0.0, 1.0)
			3: _moo_length = clampf(_moo_length + dir * 0.1, 0.4, 3.0)
	else:
		match idx:
			0: _bell_freq = clampf(_bell_freq + dir * 20.0, 180.0, 1400.0)
			1: _bell_decay = clampf(_bell_decay + dir * 0.05, 0.08, 1.5)
			2: _bell_bright = clampf(_bell_bright + dir * 0.1, 0.0, 1.0)
			3: _bell_strike = clampf(_bell_strike + dir * 0.1, 0.0, 1.0)
	_refresh()


func _next_pitch() -> float:
	match _pitch_mode:
		1: return _rng.randf_range(COW_PITCH_IDLE.x, COW_PITCH_IDLE.y)
		2: return _rng.randf_range(COW_PITCH_PANIC.x, COW_PITCH_PANIC.y)
		_: return 1.0


func _play(spatial: bool) -> void:
	var stream: AudioStream
	if _instrument == "moo" and _use_original:
		stream = GameAudio.render_moo(RATE)
	elif _instrument == "moo":
		stream = _render_moo()
	else:
		stream = _render_bell()
	_last_pitch = _next_pitch()
	if spatial:
		_source.stream = stream
		_source.position = Vector3(0.0, 0.0, -_sim_distance)
		_source.pitch_scale = _last_pitch
		_source.play()
	else:
		_flat.stream = stream
		_flat.pitch_scale = _last_pitch
		_flat.play()
	_refresh()


# =============================================================================
# UI
# =============================================================================
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.65)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	layer.add_child(bg)
	_label = Label.new()
	_label.position = Vector2(24, 20)
	_label.add_theme_font_size_override("font_size", 18)
	layer.add_child(_label)


func _pitch_mode_name() -> String:
	match _pitch_mode:
		1: return "idle random 0.85-1.12"
		2: return "panic random 1.3-1.6"
		_: return "fixed 1.0"


func _refresh() -> void:
	var L := PackedStringArray()
	L.append("=== SOUND LAB ===  (audition only — game untouched)")
	L.append("")
	L.append("Instrument:  %s        (M = moo,  B = bell)" % _instrument.to_upper())
	L.append("Preset:      %s        (1-4 to load)" % _preset_name)
	L.append("")
	if _instrument == "moo" and _use_original:
		L.append("  [playing the unmodified current game moo — pure A/B reference]")
	elif _instrument == "moo":
		L.append("  fundamental : %5.0f Hz   (Q/A)" % _moo_fund)
		L.append("  roughness   : %5.2f      (W/S)" % _moo_rough)
		L.append("  breath      : %5.2f      (E/D)" % _moo_breath)
		L.append("  length      : %5.2f s    (T/G)" % _moo_length)
	else:
		L.append("  base freq   : %5.0f Hz   (Q/A)" % _bell_freq)
		L.append("  decay/ring  : %5.2f s    (W/S)" % _bell_decay)
		L.append("  brightness  : %5.2f      (E/D)" % _bell_bright)
		L.append("  strike tick : %5.2f      (T/G)" % _bell_strike)
	L.append("")
	L.append("  distance    : %3d m       (UP/DOWN or [ ], max %d)" % [int(_sim_distance), int(COW_MAX_DISTANCE)])
	L.append("  pitch mode  : %s   (P)    last: %.2fx" % [_pitch_mode_name(), _last_pitch])
	L.append("")
	L.append("PLAY:  SPACE = through cow 3D path     F = flat/raw")
	L.append("")
	L.append("Tell me the instrument + preset + knob values you like; I lock them into Audio.gd.")
	_label.text = "\n".join(L)
