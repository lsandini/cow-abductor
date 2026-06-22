# =============================================================================
# World.gd
#
# The root of the game. Attached to the Main scene, it procedurally assembles
# everything at startup:
#   - input actions (WASD / mouse / beam)
#   - the sky + fog environment that fakes an endless landscape
#   - the sun (directional light)
#   - a large tiled ground plane (a shader draws the repeating "tiles")
#   - scattered cows and trees
#   - the player's flying saucer
#   - the on-screen UI (minimap + HUD)
#
# There are no win/lose conditions: it is a relaxed sandbox. When a cow is
# abducted we simply spawn a fresh one elsewhere so the pasture never empties.
# =============================================================================
extends Node3D

# --- Tweakable world parameters (editable in the Inspector) ------------------
@export var area_half: float = 180.0   # cows/trees spawn within +/- this on X and Z
@export var ground_size: float = 700.0 # side length of the visible ground plane
@export var cow_count: int = 22        # how many cows roam at once
@export var fog_density: float = 0.003 # higher = thicker fog / closer horizon

# --- Trees / forests ---------------------------------------------------------
@export var forest_count: int = 12     # number of little tree clusters
@export var forest_radius: float = 24.0 # rough spread of each cluster
@export var trees_per_forest_min: int = 8
@export var trees_per_forest_max: int = 30
@export var scattered_trees: int = 30  # lone trees sprinkled between the forests

# --- Terrain shape -----------------------------------------------------------
@export var terrain_amplitude: float = 15.0  # max hill/valley height (rolling, not alpine)
@export var terrain_frequency: float = 0.006 # lower = broader, smoother hills
@export var ground_segments: int = 150       # ground mesh resolution per side

# Colour shared by the fog and the sky horizon. Matching them is the trick that
# makes the ground melt seamlessly into the sky, hiding the world's edges.
const HORIZON_COLOR := Color(0.74, 0.80, 0.86)

var _captured_count: int = 0           # running tally of abducted cows
var _hud_label: Label                  # top-left status text
var _terrain := FastNoiseLite.new()    # the single source of truth for ground height


func _ready() -> void:
	randomize()                        # different cow/tree layout every run
	_setup_input()
	_setup_terrain()                   # must come before anything that samples height
	_build_environment()
	_build_sun()
	_build_ground()
	_spawn_trees()
	_spawn_cows()
	_build_saucer()
	_build_ui()


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
# physical_key is typed as the Key enum so it flows into physical_keycode
# (also a Key) without an int->enum conversion warning.
func _add_key_action(action: String, physical_key: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = physical_key
	InputMap.action_add_event(action, ev)


# -----------------------------------------------------------------------------
# Environment: procedural sky + depth fog. The fog fades distant geometry into
# the horizon colour, selling the illusion of an infinite plain.
# -----------------------------------------------------------------------------
func _build_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.38, 0.56, 0.86)
	sky_material.sky_horizon_color = HORIZON_COLOR
	sky_material.ground_horizon_color = HORIZON_COLOR
	sky_material.ground_bottom_color = HORIZON_COLOR

	var sky := Sky.new()
	sky.sky_material = sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6

	# Distance fog tinted to match the horizon.
	env.fog_enabled = true
	env.fog_light_color = HORIZON_COLOR
	env.fog_density = fog_density
	env.fog_sky_affect = 0.3   # let the fog blend slightly into the sky too

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)


# -----------------------------------------------------------------------------
# Sun: a single angled directional light with soft shadows.
# -----------------------------------------------------------------------------
func _build_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)


# -----------------------------------------------------------------------------
# Terrain height field. FastNoiseLite gives smooth, layered noise; we keep the
# amplitude small so the world is gently rolling — no canyons, no mountains.
# This function is the ONE source of truth: the ground mesh, the cows and the
# trees all read their height from get_height(), so nothing ever floats or sinks.
# -----------------------------------------------------------------------------
func _setup_terrain() -> void:
	_terrain.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_terrain.seed = randi()
	_terrain.frequency = terrain_frequency
	_terrain.fractal_type = FastNoiseLite.FRACTAL_FBM
	_terrain.fractal_octaves = 3      # a couple of octaves for natural variation
	_terrain.fractal_gain = 0.5
	_terrain.fractal_lacunarity = 2.0


# World-space ground height at (x, z). get_noise_2d returns ~[-1, 1].
func get_height(x: float, z: float) -> float:
	return _terrain.get_noise_2d(x, z) * terrain_amplitude


# Upward surface normal at (x, z), derived analytically from the height field
# (central differences). Always points up, so lighting is correct regardless of
# triangle winding.
func _ground_normal(x: float, z: float) -> Vector3:
	var e := 1.0   # sampling step for the slope estimate
	var hx := get_height(x - e, z) - get_height(x + e, z)
	var hz := get_height(x, z - e) - get_height(x, z + e)
	return Vector3(hx, 2.0 * e, hz).normalized()


# -----------------------------------------------------------------------------
# Ground: a displaced grid mesh built from the height field. A custom spatial
# shader paints a two-tone checkerboard from world position for the "tiles" look
# and a strong sense of motion; the mesh's own normals shade the hills.
# -----------------------------------------------------------------------------
func _build_ground() -> void:
	var half := ground_size / 2.0
	var step := ground_size / float(ground_segments)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Lay down a grid of vertices, each pushed up/down by the height field and
	# given its analytic normal so the lighting is smooth.
	for j in range(ground_segments + 1):
		for i in range(ground_segments + 1):
			var x := -half + i * step
			var z := -half + j * step
			st.set_uv(Vector2(float(i), float(j)))
			st.set_normal(_ground_normal(x, z))
			st.add_vertex(Vector3(x, get_height(x, z), z))

	# Stitch the grid into two triangles per quad.
	var row := ground_segments + 1
	for j in range(ground_segments):
		for i in range(ground_segments):
			var a := j * row + i
			var b := a + 1
			var c := a + row
			var d := c + 1
			st.add_index(a); st.add_index(c); st.add_index(b)
			st.add_index(b); st.add_index(c); st.add_index(d)

	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_disabled;

// Stylised-but-natural grass. Colour comes from layered value noise keyed to
// world position (so it never repeats visibly), with drier and earthier patches
// mixed in and a little dirt showing on the steeper slopes. No textures needed.

uniform vec3 grass_low  : source_color = vec3(0.20, 0.34, 0.15); // lush / shaded
uniform vec3 grass_high : source_color = vec3(0.44, 0.55, 0.28); // sunlit blades
uniform vec3 grass_dry  : source_color = vec3(0.56, 0.55, 0.30); // dry/yellowed
uniform vec3 dirt_color : source_color = vec3(0.40, 0.31, 0.20); // bare earth

varying vec3 world_pos;
varying vec3 world_normal;

// --- cheap value-noise FBM -------------------------------------------------
float hash(vec2 p) {
	p = fract(p * vec2(127.34, 311.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);          // smootherstep blend
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += amp * vnoise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return v;
}

void vertex() {
	// World-space position and normal, so the pattern and slope are stable.
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 wp = world_pos.xz;

	float macro  = fbm(wp * 0.020);                 // broad lush/sunlit variation
	float detail = fbm(wp * 0.220);                 // fine blade-level grain

	// Base grass: blend lush <-> sunlit by the broad noise, then grain it.
	vec3 grass = mix(grass_low, grass_high, macro);
	grass *= 0.82 + 0.36 * detail;

	// Dry, yellowed meadows in some regions.
	float dry = smoothstep(0.55, 0.78, fbm(wp * 0.012 + vec2(31.0, 17.0)));
	grass = mix(grass, grass_dry, dry * 0.55);

	// Bare-earth patches, edges broken up by the fine grain.
	float patch = smoothstep(0.58, 0.72, fbm(wp * 0.035 + vec2(60.0, 5.0)));
	// A little dirt on the steeper faces too (terrain is gentle, so low thresholds).
	float slope = 1.0 - clamp(world_normal.y, 0.0, 1.0);
	float dirt_amt = max(patch, smoothstep(0.05, 0.16, slope));
	dirt_amt *= 0.7 + 0.5 * detail;

	vec3 col = mix(grass, dirt_color, clamp(dirt_amt, 0.0, 1.0));

	ALBEDO = col;
	ROUGHNESS = 1.0;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader

	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = st.commit()
	ground.material_override = mat
	add_child(ground)


# -----------------------------------------------------------------------------
# Trees: grouped into little forests so cows can hide under the canopies, with a
# scattering of lone trees in between to break up the open ground.
# -----------------------------------------------------------------------------
func _spawn_trees() -> void:
	# Forest clusters: pick a centre, then scatter a clump of trees around it.
	for f in forest_count:
		var center := _random_ground_position()
		var count := randi_range(trees_per_forest_min, trees_per_forest_max)
		for i in count:
			# Uniform-ish disc sampling (sqrt keeps trees from bunching at centre).
			var angle := randf() * TAU
			var dist := sqrt(randf()) * forest_radius
			var pos := center + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
			_plant_tree(pos)

	# Lone trees sprinkled across the open pasture.
	for i in scattered_trees:
		_plant_tree(_random_ground_position())


# Place one tree at (x, z), clamped to the pasture and sat on the terrain.
func _plant_tree(pos: Vector3) -> void:
	pos.x = clampf(pos.x, -area_half, area_half)
	pos.z = clampf(pos.z, -area_half, area_half)
	pos.y = get_height(pos.x, pos.z)
	var tree := _make_tree()
	tree.position = pos
	tree.rotation.y = randf() * TAU
	tree.add_to_group("trees")
	add_child(tree)


# Build one tree from primitives, with a little random size and tint so a forest
# doesn't look like rows of identical clones.
func _make_tree() -> Node3D:
	var tree := Node3D.new()
	tree.name = "Tree"
	tree.scale = Vector3.ONE * randf_range(0.8, 1.5)

	# Trunk: a thin brown cylinder.
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.3
	trunk_mesh.bottom_radius = 0.4
	trunk_mesh.height = 2.5
	var trunk := MeshInstance3D.new()
	trunk.mesh = trunk_mesh
	trunk.material_override = _solid_material(Color(0.40, 0.26, 0.13))
	trunk.position.y = 1.25
	tree.add_child(trunk)

	# Foliage: a green cone (a cylinder with a zero-radius top). Slightly varied
	# green so each tree reads a little differently.
	var green := Color(0.16, 0.42, 0.18).lerp(Color(0.22, 0.50, 0.20), randf())
	var leaves_mesh := CylinderMesh.new()
	leaves_mesh.top_radius = 0.0
	leaves_mesh.bottom_radius = 2.0
	leaves_mesh.height = 4.0
	var leaves := MeshInstance3D.new()
	leaves.mesh = leaves_mesh
	leaves.material_override = _solid_material(green)
	leaves.position.y = 4.5
	tree.add_child(leaves)

	return tree


# -----------------------------------------------------------------------------
# Cows: spawned from the Cow class. Each one wanders on its own.
# -----------------------------------------------------------------------------
func _spawn_cows() -> void:
	for i in cow_count:
		_spawn_one_cow()


func _spawn_one_cow() -> void:
	var cow := Cow.new()
	cow.area_half = area_half
	# Hand the cow the height sampler so it can walk over hills and valleys.
	cow.ground_sampler = Callable(self, "get_height")
	var pos := _random_ground_position()
	pos.y = get_height(pos.x, pos.z)
	cow.position = pos
	cow.add_to_group("cows")
	# When this cow is abducted, tally it and replace it so the field stays busy.
	cow.captured.connect(_on_cow_captured)
	add_child(cow)


func _on_cow_captured() -> void:
	_captured_count += 1
	_update_hud()
	_spawn_one_cow()   # keep the world populated — there is no "running out".


# -----------------------------------------------------------------------------
# Saucer: the player. It carries its own orbit camera and tractor beam.
# -----------------------------------------------------------------------------
func _build_saucer() -> void:
	var saucer := Saucer.new()
	saucer.name = "Saucer"
	# Give the saucer the height sampler so it hovers at a fixed clearance above
	# whatever ground is directly below it. Set before add_child so _ready() can
	# use it for the starting altitude.
	saucer.ground_sampler = Callable(self, "get_height")
	saucer.add_to_group("saucer")
	add_child(saucer)


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
	minimap.anchor_left = 1.0
	minimap.anchor_top = 1.0
	minimap.anchor_right = 1.0
	minimap.anchor_bottom = 1.0
	minimap.offset_left = -200.0
	minimap.offset_top = -200.0
	minimap.offset_right = -20.0
	minimap.offset_bottom = -20.0
	layer.add_child(minimap)

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
	_hud_label.text = "Cows abducted: %d\n\nWASD  move\nMouse  look\nSpace / Left-click  tractor beam\nEsc  free the mouse" % _captured_count


# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------

# A flat, fully-coloured material used by most props.
func _solid_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


# Pick a random spot on the ground within the spawn area.
func _random_ground_position() -> Vector3:
	return Vector3(
		randf_range(-area_half, area_half),
		0.0,
		randf_range(-area_half, area_half)
	)
