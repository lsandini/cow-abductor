# =============================================================================
# World.gd
#
# The root of the game. Attached to the Main scene, it procedurally assembles
# everything at startup:
#   - input actions (WASD / mouse / beam)
#   - the sky + fog environment that fades the streaming world into the horizon
#   - the sun (directional light)
#   - the Terrain node, which streams an ENDLESS ground (chunks built/freed as
#     you fly) along with its trees, rocks, bushes and water
#   - a roaming herd of cows that follows the player so the pasture never empties
#   - the player's flying saucer
#   - the on-screen UI (minimap + HUD)
#
# There are no win/lose conditions: it is a relaxed sandbox. The Terrain owns
# the world's SHAPE (height) and CHARACTER (biome); World owns the actors (cows,
# saucer) and the UI, and keeps the herd gathered around wherever you fly.
# =============================================================================
extends Node3D

# --- Herd (cows follow the player so the world is never empty) ----------------
@export var cow_count: int = 22            # how many cows roam near you at once
@export var cow_despawn_radius: float = 220.0  # past this from the saucer, a cow is recycled
@export var spawn_radius_min: float = 70.0     # cows reappear in a ring this near...
@export var spawn_radius_max: float = 170.0    # ...to this far from the saucer

# --- Farmers (guard the herd; shoot at the saucer when it beams their cows) ----
@export var farmer_count: int = 6          # how many farmers roam near you at once

# --- Environment --------------------------------------------------------------
@export var fog_density: float = 0.0026    # higher = thicker fog / closer horizon

# Colour shared by the fog and the sky horizon. Matching them is the trick that
# makes the streaming ground melt seamlessly into the sky, hiding the loading edge.
const HORIZON_COLOR := Color(0.74, 0.80, 0.86)

var _captured_count: int = 0           # running tally of abducted cows
var _hits_taken: int = 0               # running tally of farmer rifle hits taken
var _elapsed: float = 0.0              # seconds since the session started
var _last_hud_second: int = -1         # last whole-second the HUD text was rebuilt at
var _hud_label: Label                  # top-left status text
var _terrain: Terrain                  # the streaming, infinite world
var _saucer: Saucer                    # the player (cows/birds gather around it)
var _sky_material: ShaderMaterial      # sky shader; its sun_dir is aimed at the sun light
# Preloaded rather than referenced by class_name so the type always resolves,
# even before the editor has rescanned and registered the global class.
const GameAudioScript := preload("res://scripts/Audio.gd")
var _audio: GameAudioScript            # procedural sound (whistle, birds, moos)


func _ready() -> void:
	randomize()                        # different world seed / cow layout every run
	_setup_input()
	_build_environment()
	_build_sun()
	_build_terrain()                   # noise is ready immediately; chunks stream in
	_build_audio()                     # bakes the moo/bird samples; starts the whistle
	_audio.setup_birds()               # roaming bird emitters (no longer tied to trees)
	_build_saucer()                    # hovers using the terrain height sampler
	_terrain.set_target(_saucer)       # start streaming the world around the saucer
	_spawn_cows()                      # herd gathers around the saucer
	_spawn_farmers()                   # a few farmers stand guard among the cows
	_build_ui()


# Keep the herd gathered around the player as it flies across the endless world,
# tick the session clock, and refresh the HUD (the elapsed time changes constantly).
func _process(delta: float) -> void:
	_elapsed += delta
	_recycle_cows()
	_recycle_farmers()   # after the cows, so farmers relocate beside the gathered herd
	# The only per-frame-changing HUD value is the clock, and it only ticks whole
	# seconds — so rebuild the label at most once a second instead of every frame.
	# Counts refresh instantly via their own _update_hud() calls (capture / hit).
	if int(_elapsed) != _last_hud_second:
		_update_hud()


# -----------------------------------------------------------------------------
# Input: register the actions in code so the project works without any manual
# editor setup. Physical keycodes are used so WASD stays in the same spot on
# non-QWERTY keyboard layouts.
# -----------------------------------------------------------------------------
func _setup_input() -> void:
	_add_key_action("move_forward", KEY_W)
	_add_key_action("move_back", KEY_S)
	_add_key_action("move_left", KEY_A)
	_add_key_action("move_right", KEY_D)

	# Altitude: Z raises the hover height, X lowers it (next to WASD so the left
	# hand never leaves the flight keys).
	_add_key_action("altitude_up", KEY_Z)
	_add_key_action("altitude_down", KEY_X)

	# The tractor beam can be fired with Space OR the left mouse button.
	if not InputMap.has_action("beam"):
		InputMap.add_action("beam")
	var space := InputEventKey.new()
	space.physical_keycode = KEY_SPACE
	InputMap.action_add_event("beam", space)
	var lmb := InputEventMouseButton.new()
	lmb.button_index = MOUSE_BUTTON_LEFT
	InputMap.action_add_event("beam", lmb)


# Helper: create a single-key action if it does not already exist.
func _add_key_action(action: String, physical_key: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = physical_key
	InputMap.action_add_event(action, ev)


# -----------------------------------------------------------------------------
# Environment: a sky with a procedural mountain-range backdrop, plus light fog.
# The sky is a sphere at infinity that always stays centred on the camera, so a
# shader painting distant ranges onto it gives the look of a cylinder/dome of
# scenery around the saucer — but with correct parallax (the ranges hold their
# bearing as you fly) and no geometry to clip the streaming ground. A little fog
# still melts the terrain's loading edge into the horizon haze, out of which the
# mountains rise.
# -----------------------------------------------------------------------------
func _build_environment() -> void:
	_sky_material = _make_sky_material()
	var sky := Sky.new()
	sky.sky_material = _sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.4   # lower fill so the sun's shadows actually read

	# Distance fog tinted to match the horizon, so the far terrain edge fades into
	# the same haze the mountains sit behind.
	env.fog_enabled = true
	env.fog_light_color = HORIZON_COLOR
	env.fog_density = fog_density
	env.fog_sky_affect = 0.0   # don't fog the sky itself — keep the mountains crisp

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)


# A sky shader that draws two layered ridgelines of distant mountains around the
# whole horizon. The ridge height is noise sampled on the azimuth CIRCLE, so it
# wraps seamlessly (no join behind you), and each range fades into the horizon
# haze toward its foot for atmospheric depth.
func _make_sky_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type sky;

// The mountains are the MOST DISTANT thing in the scene, so aerial perspective
// makes them pale and low-contrast — only a touch darker/bluer than the horizon
// haze, fading lighter (and toward the haze) the farther back they sit. The
// nearer range is a hair darker than the far one, giving smooth, monotonic depth
// that continues the fog's haze rather than fighting it.
uniform vec3 sky_top     : source_color = vec3(0.36, 0.56, 0.86);
uniform vec3 sky_horizon : source_color = vec3(0.74, 0.80, 0.86); // == World HORIZON_COLOR
uniform vec3 mtn_near    : source_color = vec3(0.60, 0.66, 0.75); // nearer  = slightly darker
uniform vec3 mtn_far     : source_color = vec3(0.67, 0.73, 0.81); // farther = paler, hazier
uniform vec3 sun_dir = vec3(0.0, 0.57, 0.82);                     // direction TO the sun (set by World)

// A rounded ridge height in [0,1] from INTEGER harmonics of the view azimuth.
// Every term is exactly 2*PI-periodic in `az`, so the silhouette wraps with no
// seam. Used for the gentle nearer foothills. `f0` sets how many humps encircle
// you; `phase` decorrelates the layers.
float ridge_h(float az, float f0, float phase) {
	float s =
		  0.50 * sin(az * f0              + phase)
		+ 0.25 * sin(az * (f0 * 2.0 + 1.0) + phase * 1.7)
		+ 0.16 * sin(az * (f0 * 4.0 + 1.0) + phase * 2.3)
		+ 0.09 * sin(az * (f0 * 7.0 + 1.0) + phase * 3.1);
	return 0.5 + 0.5 * s;   // -> [0, 1]
}

// A more alpine ridgeline for the FAR range: ridged waves (1-|sin|) give cusped
// peaks instead of round humps, with a couple of octaves of crag detail — jagged
// but not noisy. Integer frequencies keep it seamless.
float ridge_alpine(float az, float f0, float phase) {
	float v = 0.0;
	float amp = 0.60;
	float freq = f0;
	for (int i = 0; i < 3; i++) {
		float t = sin(az * freq + phase * (1.0 + float(i) * 0.7));
		v += amp * (1.0 - abs(t));   // cusped peak where the wave crosses zero
		freq = freq * 2.0 + 1.0;     // stays integer -> stays seamless
		amp *= 0.45;
	}
	return v;
}

// Composite one mountain range over the running sky colour. The range fades into
// the horizon haze toward its foot so it melts into the fog, not a hard edge.
vec3 add_range(vec3 col, float elev, float ridge, vec3 range_col) {
	float inside = 1.0 - smoothstep(ridge - 0.0035, ridge + 0.0035, elev); // 1 below ridge
	float lift = smoothstep(-0.05, ridge + 0.02, elev);                    // 0 at foot -> 1 at crest
	vec3 mc = mix(sky_horizon, range_col, lift);
	return mix(col, mc, inside);
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float elev = dir.y;
	float az = atan(dir.x, dir.z);

	// Base gradient: horizon haze up to blue overhead.
	vec3 col = mix(sky_horizon, sky_top, pow(clamp(elev, 0.0, 1.0), 0.5));

	// The sun, drawn onto the dome at sun_dir (handed in by World from the light).
	// Done before the mountains so a low sun would be correctly hidden by a ridge.
	{
		float d = dot(dir, normalize(sun_dir));
		float glow = pow(max(d, 0.0), 40.0) * 0.9;      // bright inner glow
		float halo = pow(max(d, 0.0), 3.0) * 0.28;      // broad soft halo, easy to spot
		col += vec3(1.0, 0.93, 0.78) * (glow + halo);   // additive warm glow + halo
		float disc = smoothstep(0.9988, 0.9994, d);     // ~2.5 deg solar disc, on top
		col = mix(col, vec3(1.0, 0.96, 0.85), disc);    // warm-white disc
	}

	// Farther range first: jagged alpine silhouette (paler, peaks high)...
	col = add_range(col, elev, 0.012 + 0.155 * ridge_alpine(az, 5.0, 0.0), mtn_far);
	// ...then the nearer range over it: the original gentle, rounded foothills.
	col = add_range(col, elev, 0.004 + 0.085 * ridge_h(az, 6.0, 2.5), mtn_near);

	COLOR = col;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


# -----------------------------------------------------------------------------
# Sun: a single angled directional light with soft shadows.
# -----------------------------------------------------------------------------
func _build_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-35.0, -35.0, 0.0)   # ~35 deg elevation: in view when you look up, and offsets shadows nicely
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	# Keep the shadow map focused near the camera so the saucer's small offset
	# shadow gets enough resolution to land on the open ground, not just on props.
	sun.directional_shadow_max_distance = 120.0
	# The saucer hovers ~15 units above the ground, so the default bias pushes its
	# shadow clean off the flat terrain (peter-panning) while props closer to the
	# caster still catch it. Lower the bias so the shadow lands on open ground too.
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 0.8
	add_child(sun)

	# Aim the sky's sun disc exactly at this light. The direction TO the sun is the
	# light's +Z axis (it shines along -Z), so we hand that to the sky shader
	# directly instead of relying on the renderer's LIGHT0 plumbing.
	_sky_material.set_shader_parameter("sun_dir", sun.global_transform.basis.z)


# -----------------------------------------------------------------------------
# Terrain: the streaming, infinite world. It owns the height/biome noise, so it
# is the single source of truth that the saucer and cows sample for ground height.
# -----------------------------------------------------------------------------
func _build_terrain() -> void:
	_terrain = Terrain.new()
	_terrain.name = "Terrain"
	add_child(_terrain)   # _ready() sets up its noise so get_height() works at once


# -----------------------------------------------------------------------------
# Cows: a fixed-size herd that follows the player. Each cow wanders on its own;
# any that drifts too far gets quietly relocated to a ring around the saucer, so
# there are always cows nearby no matter how far you fly.
# -----------------------------------------------------------------------------
func _spawn_cows() -> void:
	for i in cow_count:
		_spawn_one_cow()


func _spawn_one_cow() -> void:
	var cow := Cow.new()
	# Hand the cow the height sampler and water level so it walks the hills and
	# steers clear of the ponds.
	cow.ground_sampler = Callable(_terrain, "get_height")
	cow.water_level = _terrain.water_level
	cow.moo_stream = _audio.moo_stream   # shared baked moo sample
	cow.bell_stream = _audio.bell_stream # shared bell; only some cows end up wearing one
	cow.position = _ring_position_near_saucer()
	cow.add_to_group("cows")
	# When this cow is abducted, tally it and replace it so the field stays busy.
	cow.captured.connect(_on_cow_captured)
	add_child(cow)


# Move any cow that has wandered (or been left) too far behind into a fresh spot
# around the saucer. This is what makes the herd "follow" the player.
func _recycle_cows() -> void:
	if _saucer == null:
		return
	var sp := _saucer.global_position
	var max_d2 := cow_despawn_radius * cow_despawn_radius
	for cow in get_tree().get_nodes_in_group("cows"):
		var dx: float = cow.global_position.x - sp.x
		var dz: float = cow.global_position.z - sp.z
		if dx * dx + dz * dz > max_d2:
			cow.position = _ring_position_near_saucer()


# A ground position in a ring around the saucer, nudged out of any water.
func _ring_position_near_saucer() -> Vector3:
	var center := _saucer.global_position if _saucer != null else Vector3.ZERO
	var pos := Vector3.ZERO
	# A few tries to avoid dropping a cow in a pond; good enough if all fail.
	for attempt in 6:
		var angle := randf() * TAU
		var dist := randf_range(spawn_radius_min, spawn_radius_max)
		pos = center + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
		pos.y = _terrain.get_height(pos.x, pos.z)
		if pos.y >= _terrain.water_level + 0.5:
			break
	return pos


func _on_cow_captured() -> void:
	_captured_count += 1
	_update_hud()
	_spawn_one_cow()   # keep the world populated — there is no "running out".


# A farmer's rifle shot landed (harmless): bump the HUD tally and refresh it now.
func _on_saucer_hit() -> void:
	_hits_taken += 1
	_update_hud()


# -----------------------------------------------------------------------------
# Farmers: a handful of guards that stand among the cows and shoot at the saucer
# (harmlessly) when it tries to beam one up. Like the cows they follow the player
# — any farmer left too far behind is relocated beside the herd.
# -----------------------------------------------------------------------------
func _spawn_farmers() -> void:
	for i in farmer_count:
		_spawn_one_farmer()


func _spawn_one_farmer() -> void:
	var farmer := Farmer.new()
	farmer.ground_sampler = Callable(_terrain, "get_height")
	farmer.water_level = _terrain.water_level
	farmer.saucer = _saucer   # cached ref instead of a per-frame group lookup
	farmer.position = _farmer_position()
	farmer.add_to_group("farmers")
	add_child(farmer)


# Relocate any farmer that has drifted too far behind to a spot beside the herd.
func _recycle_farmers() -> void:
	if _saucer == null:
		return
	var sp := _saucer.global_position
	var max_d2 := cow_despawn_radius * cow_despawn_radius
	for farmer in get_tree().get_nodes_in_group("farmers"):
		var dx: float = farmer.global_position.x - sp.x
		var dz: float = farmer.global_position.z - sp.z
		if dx * dx + dz * dz > max_d2:
			farmer.position = _farmer_position()


# A dry ground spot a few metres from one of the cows (so farmers guard the herd).
# Falls back to the cow-spawn ring if there are no cows or no dry spot is found.
func _farmer_position() -> Vector3:
	var cows := get_tree().get_nodes_in_group("cows")
	if not cows.is_empty():
		for attempt in 6:
			var cow: Node3D = cows[randi() % cows.size()]
			var angle := randf() * TAU
			var dist := randf_range(3.0, 9.0)
			var pos := cow.global_position + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
			pos.y = _terrain.get_height(pos.x, pos.z)
			if pos.y >= _terrain.water_level + 0.5:
				return pos
	return _ring_position_near_saucer()


# -----------------------------------------------------------------------------
# Audio: the procedural sound manager (UFO whistle, birds, baked moo sample).
# -----------------------------------------------------------------------------
func _build_audio() -> void:
	_audio = GameAudioScript.new()
	_audio.name = "Audio"
	add_child(_audio)


# -----------------------------------------------------------------------------
# Saucer: the player. It carries its own orbit camera and tractor beam.
# -----------------------------------------------------------------------------
func _build_saucer() -> void:
	_saucer = Saucer.new()
	_saucer.name = "Saucer"
	# Give the saucer the height sampler so it hovers at a fixed clearance above
	# whatever ground is directly below it. Set before add_child so _ready() can
	# use it for the starting altitude.
	_saucer.ground_sampler = Callable(_terrain, "get_height")
	_saucer.ding_stream = _audio.ding_stream   # metallic "ding" when a farmer's shot lands
	_saucer.add_to_group("saucer")
	add_child(_saucer)
	_saucer.hit.connect(_on_saucer_hit)   # tally rifle hits for the HUD
	_audio.saucer = _saucer   # cached ref: the whistle reads beam_active every frame


# -----------------------------------------------------------------------------
# UI: a CanvasLayer holding the minimap (bottom-right) and a HUD label
# (top-left) that shows the abduction count and the controls.
# -----------------------------------------------------------------------------
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)

	# Minimap, pinned to the bottom-right corner with a 20px margin.
	var minimap := Minimap.new()
	minimap.name = "Minimap"
	minimap.saucer = _saucer      # cached refs instead of per-frame group scans
	minimap.terrain = _terrain    # tree positions for the radar dots
	minimap.anchor_left = 1.0
	minimap.anchor_top = 1.0
	minimap.anchor_right = 1.0
	minimap.anchor_bottom = 1.0
	minimap.offset_left = -200.0
	minimap.offset_top = -200.0
	minimap.offset_right = -20.0
	minimap.offset_bottom = -20.0
	layer.add_child(minimap)

	# Compass heading tape, centred along the top of the screen.
	var compass := HeadingTape.new()
	compass.name = "HeadingTape"
	compass.anchor_left = 0.5
	compass.anchor_right = 0.5
	compass.anchor_top = 0.0
	compass.anchor_bottom = 0.0
	compass.offset_left = -260.0
	compass.offset_right = 260.0
	compass.offset_top = 14.0
	compass.offset_bottom = 66.0
	compass.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never intercept beam clicks
	layer.add_child(compass)

	# Speed (left) + altitude (right) readouts: a full-screen overlay that draws
	# itself flush to each edge, matching the compass's light style.
	var readouts := FlightReadouts.new()
	readouts.name = "FlightReadouts"
	readouts.anchor_right = 1.0
	readouts.anchor_bottom = 1.0
	readouts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(readouts)

	# HUD text in the top-left.
	_hud_label = Label.new()
	_hud_label.name = "Hud"
	_hud_label.position = Vector2(16, 12)
	_hud_label.add_theme_color_override("font_color", Color.WHITE)
	_hud_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud_label.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hud_label)
	_update_hud()


func _update_hud() -> void:
	_last_hud_second = int(_elapsed)
	var minutes := int(_elapsed) / 60
	var seconds := int(_elapsed) % 60
	_hud_label.text = "Cows abducted: %d\nHits taken: %d\nTime: %d:%02d\n\nWASD  move\nZ / X  altitude\nMouse  look\nSpace / Left-click  tractor beam\nEsc  free the mouse" % [_captured_count, _hits_taken, minutes, seconds]
