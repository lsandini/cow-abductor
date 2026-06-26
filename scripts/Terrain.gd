# =============================================================================
# Terrain.gd  (class_name Terrain)
#
# The infinite, streaming world. This single node is the source of truth for
# ground SHAPE (height), CHARACTER (biome) and everything that decorates it.
#
# How "infinite" works:
#   - Height/biome come from FastNoiseLite, which can be sampled at ANY (x, z).
#     So the world is mathematically infinite already; the only finite thing is
#     the geometry we actually build.
#   - We therefore stream the geometry: the world is divided into square CHUNKS
#     and we keep a square of chunks loaded around a target (the saucer). As the
#     target flies, chunks entering range are built and chunks leaving range are
#     freed, a couple per frame so there is no hitch.
#   - Distant fog (set up in World) hides the loading edge, so the player only
#     ever sees a seamless, endless pasture.
#
# Each chunk owns its own ground mesh AND its props (trees / rocks / bushes),
# scattered with a per-chunk seeded RNG so flying away and back regenerates the
# EXACT same scenery in the EXACT same spot — no popping or reshuffling.
#
# Water is a single large translucent plane at a fixed height that follows the
# target; terrain below that height reads as ponds/lakes in the valleys.
# =============================================================================
class_name Terrain
extends Node3D

# --- Streaming -------------------------------------------------------------
@export var chunk_size: float = 130.0      # world side length of one chunk
@export var chunk_segments: int = 22       # mesh resolution per chunk side
@export var view_radius: int = 4           # chunks kept loaded in each direction
@export var builds_per_frame: int = 2      # how many chunks we may build per frame

# --- Base rolling terrain --------------------------------------------------
@export var terrain_amplitude: float = 26.0  # hill/valley height (rolling, not flat)
@export var terrain_frequency: float = 0.006 # lower = broader, smoother hills

# --- Occasional mountains (a separate low-frequency band) ------------------
@export var mountain_amplitude: float = 85.0  # how tall the rare massifs get
@export var mountain_frequency: float = 0.0013 # lower = larger, rarer ranges
@export var mountain_threshold: float = 0.20  # only noise above this becomes rock

# --- Biomes (lush <-> dry regions) -----------------------------------------
@export var biome_frequency: float = 0.002  # lower = larger biome regions
# Overall tree abundance. This is the knob to turn for "more/fewer trees" —
# biome_frequency only changes the SIZE of the green regions, not how many trees
# grow in them. Scales every chunk's tree count; raise it for denser forests.
@export var tree_density: float = 1.6
# Per-chunk probability of a Swiss chalet (with its flag). Kept low so they stay
# a scarce, special landmark dotted across the meadows.
@export var chalet_chance: float = 0.1

# --- Water -----------------------------------------------------------------
@export var water_level: float = -8.0      # terrain below this floods

# The three independent noise fields. Separate seeds (derived from one world
# seed) keep hills, mountains and biomes from lining up suspiciously.
var _base := FastNoiseLite.new()
var _mountain := FastNoiseLite.new()
var _biome := FastNoiseLite.new()
var _world_seed: int = 0

# Streaming state.
var _target: Node3D                        # the node we keep chunks around
var _chunks: Dictionary = {}               # Vector2i -> chunk root Node3D
var _build_queue: Array = []               # Vector2i coords waiting to be built
var _current_chunk := Vector2i(2147483647, 2147483647)  # forces a first refresh
var _ground_material: ShaderMaterial       # shared by every chunk's ground mesh
var _water: MeshInstance3D

# Shared prop materials (cached so we don't allocate one per tree/rock).
var _trunk_mat: StandardMaterial3D
var _rock_mat: StandardMaterial3D


func _ready() -> void:
	_world_seed = randi()
	_setup_noise()
	_ground_material = _make_ground_material()
	_trunk_mat = _solid_material(Color(0.40, 0.26, 0.13))
	_rock_mat = _solid_material(Color(0.42, 0.40, 0.38))
	_build_water()


# Configure the three noise fields. The base field matches the original gentle
# pasture; the mountain and biome fields are broad and slow.
func _setup_noise() -> void:
	_base.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_base.seed = _world_seed
	_base.frequency = terrain_frequency
	_base.fractal_type = FastNoiseLite.FRACTAL_FBM
	_base.fractal_octaves = 3
	_base.fractal_gain = 0.5
	_base.fractal_lacunarity = 2.0

	_mountain.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_mountain.seed = _world_seed + 1
	_mountain.frequency = mountain_frequency
	_mountain.fractal_type = FastNoiseLite.FRACTAL_FBM
	_mountain.fractal_octaves = 4

	_biome.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_biome.seed = _world_seed + 2
	_biome.frequency = biome_frequency
	_biome.fractal_type = FastNoiseLite.FRACTAL_FBM
	_biome.fractal_octaves = 2


# -----------------------------------------------------------------------------
# The source-of-truth samplers. Everything (ground mesh, props, cows, saucer)
# reads height from here, so nothing ever floats or sinks.
# -----------------------------------------------------------------------------

# World-space ground height at (x, z): gentle hills plus the occasional massif.
func get_height(x: float, z: float) -> float:
	var h := _base.get_noise_2d(x, z) * terrain_amplitude
	# Mountains: take only the upper slice of the mountain band and square it, so
	# most of the world is flat-ish and tall rock appears only in rare clumps.
	var m := _mountain.get_noise_2d(x, z)               # ~[-1, 1]
	m = maxf(m - mountain_threshold, 0.0) / (1.0 - mountain_threshold)  # [0, 1]
	h += m * m * mountain_amplitude
	return h


# Biome "lushness" at (x, z): 0 = dry/sparse, 1 = lush/green. Drives both the
# grass colour (via vertex colour) and how many trees vs rocks a chunk scatters.
func get_biome(x: float, z: float) -> float:
	return clampf(_biome.get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0)


# Upward surface normal at (x, z) from central differences on the height field.
func _ground_normal(x: float, z: float) -> Vector3:
	var e := 1.0
	var hx := get_height(x - e, z) - get_height(x + e, z)
	var hz := get_height(x, z - e) - get_height(x, z + e)
	return Vector3(hx, 2.0 * e, hz).normalized()


# -----------------------------------------------------------------------------
# Streaming
# -----------------------------------------------------------------------------

# Called once by the World after the saucer exists. Builds the immediate area
# right away (so we never start in a void) and starts following the target.
func set_target(node: Node3D) -> void:
	_target = node
	_current_chunk = _chunk_of(node.global_position)
	_refresh_desired()
	# Synchronously build the close ring so the player spawns on solid ground;
	# the rest streams in over the next frames behind the fog.
	var tc := _current_chunk
	for c in _build_queue.duplicate():
		if absi(c.x - tc.x) <= 2 and absi(c.y - tc.y) <= 2:
			_build_chunk(c)
	_build_queue = _build_queue.filter(func(c): return not _chunks.has(c))


func _process(_delta: float) -> void:
	if _target == null:
		return
	# Keep the water plane centred under the player so it appears to extend forever.
	_water.global_position = Vector3(_target.global_position.x, water_level, _target.global_position.z)

	# Re-plan the loaded set only when we cross into a new chunk.
	var tc := _chunk_of(_target.global_position)
	if tc != _current_chunk:
		_current_chunk = tc
		_refresh_desired()
	_drain_build_queue()


# Which chunk coordinate a world position falls in.
func _chunk_of(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / chunk_size), floori(pos.z / chunk_size))


# Decide which chunks SHOULD be loaded around the current chunk: free the ones
# that drifted too far, and queue the missing ones (nearest first).
func _refresh_desired() -> void:
	var tc := _current_chunk

	# Free chunks beyond the view radius (+1 of hysteresis so we don't thrash
	# right at the boundary).
	for coord in _chunks.keys():
		if absi(coord.x - tc.x) > view_radius + 1 or absi(coord.y - tc.y) > view_radius + 1:
			_chunks[coord].queue_free()
			_chunks.erase(coord)

	# Drop any queued-but-now-too-far coords.
	_build_queue = _build_queue.filter(func(c):
		return absi(c.x - tc.x) <= view_radius and absi(c.y - tc.y) <= view_radius)

	# Queue everything in range we don't already have / haven't queued.
	for dz in range(-view_radius, view_radius + 1):
		for dx in range(-view_radius, view_radius + 1):
			var c := Vector2i(tc.x + dx, tc.y + dz)
			if not _chunks.has(c) and not _build_queue.has(c):
				_build_queue.append(c)

	# Build the closest chunks first so the world fills in outward from the player.
	_build_queue.sort_custom(func(a, b): return _dist2(a, tc) < _dist2(b, tc))


# Build a few queued chunks this frame, staying within the per-frame budget.
func _drain_build_queue() -> void:
	var budget := builds_per_frame
	while budget > 0 and not _build_queue.is_empty():
		var c: Vector2i = _build_queue.pop_front()
		if _chunks.has(c):
			continue
		_build_chunk(c)
		budget -= 1


func _dist2(c: Vector2i, tc: Vector2i) -> int:
	var dx := c.x - tc.x
	var dz := c.y - tc.y
	return dx * dx + dz * dz


# -----------------------------------------------------------------------------
# Chunk construction: one ground mesh (in world space) plus scattered props.
# The chunk root sits at the origin, so its world-space children need no offset
# and all free together when the chunk unloads.
# -----------------------------------------------------------------------------
func _build_chunk(coord: Vector2i) -> void:
	var chunk := Node3D.new()
	chunk.name = "Chunk_%d_%d" % [coord.x, coord.y]

	var ground := MeshInstance3D.new()
	ground.mesh = _build_ground_mesh(coord)
	ground.material_override = _ground_material
	chunk.add_child(ground)

	_scatter_props(chunk, coord)

	add_child(chunk)
	_chunks[coord] = chunk


# A displaced grid for one chunk, built in WORLD space so adjacent chunks share
# identical edge vertices and normals (seamless). Each vertex carries its biome
# lushness in vertex-colour red, which the ground shader reads.
func _build_ground_mesh(coord: Vector2i) -> Mesh:
	var seg := chunk_segments
	var step := chunk_size / float(seg)
	var ox := coord.x * chunk_size
	var oz := coord.y * chunk_size

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for j in range(seg + 1):
		for i in range(seg + 1):
			var x := ox + i * step
			var z := oz + j * step
			st.set_color(Color(get_biome(x, z), 0.0, 0.0, 1.0))
			st.set_uv(Vector2(float(i), float(j)))
			st.set_normal(_ground_normal(x, z))
			st.add_vertex(Vector3(x, get_height(x, z), z))

	var row := seg + 1
	for j in range(seg):
		for i in range(seg):
			var a := j * row + i
			var b := a + 1
			var c := a + row
			var d := c + 1
			# Wound so the top face is front-facing (geometric normal points UP),
			# which keeps shadow normal-bias offsetting toward the light so the
			# ground actually receives cast shadows (e.g. the saucer's).
			st.add_index(a); st.add_index(b); st.add_index(c)
			st.add_index(b); st.add_index(d); st.add_index(c)

	return st.commit()


# -----------------------------------------------------------------------------
# Props: deterministic per-chunk scatter. Lush chunks favour clustered trees;
# dry chunks favour rocks. A few bushes everywhere. Nothing is placed in water.
# -----------------------------------------------------------------------------
func _scatter_props(parent: Node3D, coord: Vector2i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _chunk_seed(coord)

	var ox := coord.x * chunk_size
	var oz := coord.y * chunk_size
	# Overall character of this chunk, sampled at its centre.
	var lush := get_biome(ox + chunk_size * 0.5, oz + chunk_size * 0.5)
	# Tree growth still favours lush ground, but with a floor so dry chunks aren't
	# bald — then scaled by the overall tree_density knob. (0.35 .. 1.0) * density.
	var tree_lush := (0.35 + 0.65 * lush) * tree_density

	# Tree clusters (little forests) — count scales with how tree-friendly the chunk is.
	var clusters := int(round(rng.randf_range(0.0, 4.0) * tree_lush))
	for cl in clusters:
		var cx := ox + rng.randf() * chunk_size
		var cz := oz + rng.randf() * chunk_size
		var n := rng.randi_range(6, 14)
		for t in n:
			var angle := rng.randf() * TAU
			var dist := sqrt(rng.randf()) * 18.0
			_place_prop(parent, "tree", cx + cos(angle) * dist, cz + sin(angle) * dist, rng)

	# Lone trees scattered between the clusters.
	for t in int(round(rng.randf_range(0.0, 5.0) * tree_lush)):
		_place_prop(parent, "tree", ox + rng.randf() * chunk_size, oz + rng.randf() * chunk_size, rng)

	# Rocks — more common on dry/barren ground.
	for r in int(round(rng.randf_range(0.0, 4.0) * (1.0 - lush))):
		_place_prop(parent, "rock", ox + rng.randf() * chunk_size, oz + rng.randf() * chunk_size, rng)

	# Bushes sprinkled everywhere to break up the grass.
	for b in rng.randi_range(0, 4):
		_place_prop(parent, "bush", ox + rng.randf() * chunk_size, oz + rng.randf() * chunk_size, rng)

	# A rare Swiss chalet with its flag — only on gentle meadow ground, never in
	# water or up among the alpine rock.
	if rng.randf() < chalet_chance:
		var hx := ox + rng.randf() * chunk_size
		var hz := oz + rng.randf() * chunk_size
		var hh := get_height(hx, hz)
		if hh >= water_level + 0.6 and hh < 40.0:
			var chalet := _make_chalet(rng)
			chalet.position = Vector3(hx, hh - 0.2, hz)   # nestle slightly into the slope
			chalet.rotation.y = rng.randf() * TAU
			parent.add_child(chalet)


# Sit a prop on the terrain at (x, z), skipping anything that would stand in
# water. Trees join the "trees" group so the minimap and birdsong can find them.
func _place_prop(parent: Node3D, kind: String, x: float, z: float, rng: RandomNumberGenerator) -> void:
	var h := get_height(x, z)
	if h < water_level + 0.6:
		return
	var node: Node3D
	match kind:
		"tree": node = _make_tree(rng)
		"rock": node = _make_rock(rng)
		_:      node = _make_bush(rng)
	node.position = Vector3(x, h, z)
	node.rotation.y = rng.randf() * TAU
	if kind == "tree":
		node.add_to_group("trees")
	parent.add_child(node)


# A stable seed for one chunk, mixing the chunk coords with the world seed so
# every chunk scatters the same way every time it loads.
func _chunk_seed(coord: Vector2i) -> int:
	var h := _world_seed
	h = (h * 73856093) ^ (coord.x * 19349663) ^ (coord.y * 83492791)
	return h


# -----------------------------------------------------------------------------
# Prop builders (deterministic — they draw all randomness from the passed rng).
# -----------------------------------------------------------------------------
func _make_tree(rng: RandomNumberGenerator) -> Node3D:
	var tree := Node3D.new()
	tree.name = "Tree"
	tree.scale = Vector3.ONE * rng.randf_range(0.8, 1.5)

	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.3
	trunk_mesh.bottom_radius = 0.4
	trunk_mesh.height = 2.5
	var trunk := MeshInstance3D.new()
	trunk.mesh = trunk_mesh
	trunk.material_override = _trunk_mat
	trunk.position.y = 1.25
	tree.add_child(trunk)

	var green := Color(0.16, 0.42, 0.18).lerp(Color(0.22, 0.50, 0.20), rng.randf())
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


# A rock: two or three squashed, overlapping grey spheres so it reads as a
# lumpy boulder rather than a clean ball.
func _make_rock(rng: RandomNumberGenerator) -> Node3D:
	var rock := Node3D.new()
	rock.name = "Rock"
	var lumps := rng.randi_range(2, 3)
	for i in lumps:
		var s := SphereMesh.new()
		s.radius = rng.randf_range(0.5, 1.1)
		s.height = s.radius * 2.0
		var inst := MeshInstance3D.new()
		inst.mesh = s
		inst.material_override = _rock_mat
		inst.position = Vector3(rng.randf_range(-0.5, 0.5), rng.randf_range(0.1, 0.4), rng.randf_range(-0.5, 0.5))
		inst.scale = Vector3(rng.randf_range(0.9, 1.3), rng.randf_range(0.6, 0.9), rng.randf_range(0.9, 1.3))
		rock.add_child(inst)
	return rock


# A bush: a small clump of green spheres.
func _make_bush(rng: RandomNumberGenerator) -> Node3D:
	var bush := Node3D.new()
	bush.name = "Bush"
	var green := Color(0.18, 0.38, 0.16).lerp(Color(0.26, 0.46, 0.20), rng.randf())
	var mat := _solid_material(green)
	var blobs := rng.randi_range(2, 4)
	for i in blobs:
		var s := SphereMesh.new()
		s.radius = rng.randf_range(0.35, 0.6)
		s.height = s.radius * 2.0
		var inst := MeshInstance3D.new()
		inst.mesh = s
		inst.material_override = mat
		inst.position = Vector3(rng.randf_range(-0.4, 0.4), rng.randf_range(0.3, 0.6), rng.randf_range(-0.4, 0.4))
		bush.add_child(inst)
	return bush


# A little Swiss chalet: timber walls under a hip roof with a chimney, and a
# flag on a pole planted beside it.
func _make_chalet(rng: RandomNumberGenerator) -> Node3D:
	var chalet := Node3D.new()
	chalet.name = "Chalet"

	var wall_mat := _solid_material(Color(0.82, 0.72, 0.55))   # warm timber walls
	var roof_mat := _solid_material(Color(0.32, 0.17, 0.13))   # dark red-brown roof

	# Walls.
	var walls_mesh := BoxMesh.new()
	walls_mesh.size = Vector3(2.8, 2.0, 2.4)
	var walls := MeshInstance3D.new()
	walls.mesh = walls_mesh
	walls.material_override = wall_mat
	walls.position.y = 1.0
	chalet.add_child(walls)

	# Hip (pyramid) roof: a 4-sided cone turned 45 deg to sit square on the walls.
	var roof_mesh := CylinderMesh.new()
	roof_mesh.top_radius = 0.0
	roof_mesh.bottom_radius = 2.0
	roof_mesh.height = 1.4
	roof_mesh.radial_segments = 4
	var roof := MeshInstance3D.new()
	roof.mesh = roof_mesh
	roof.material_override = roof_mat
	roof.position.y = 2.7
	roof.rotation.y = PI / 4.0
	chalet.add_child(roof)

	# A little chimney.
	var chimney_mesh := BoxMesh.new()
	chimney_mesh.size = Vector3(0.34, 0.7, 0.34)
	var chimney := MeshInstance3D.new()
	chimney.mesh = chimney_mesh
	chimney.material_override = roof_mat
	chimney.position = Vector3(0.7, 2.8, 0.4)
	chalet.add_child(chimney)

	# The flag on its pole, planted beside the cottage.
	var flag := _make_flag()
	flag.position = Vector3(2.5, 0.0, 0.6)
	chalet.add_child(flag)

	return chalet


# A small Swiss flag (red field with a white cross) on a slim pole.
func _make_flag() -> Node3D:
	var flag := Node3D.new()
	flag.name = "Flag"

	# Pole.
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.05
	pole_mesh.bottom_radius = 0.06
	pole_mesh.height = 4.0
	var pole := MeshInstance3D.new()
	pole.mesh = pole_mesh
	pole.material_override = _solid_material(Color(0.72, 0.72, 0.74))
	pole.position.y = 2.0
	flag.add_child(pole)

	# Red field, hanging from near the top of the pole.
	var field_pos := Vector3(0.55, 3.4, 0.0)
	var red := MeshInstance3D.new()
	var red_mesh := BoxMesh.new()
	red_mesh.size = Vector3(1.0, 1.0, 0.04)
	red.mesh = red_mesh
	red.material_override = _solid_material(Color(0.83, 0.10, 0.13))
	red.position = field_pos
	flag.add_child(red)

	# White cross: two bars that poke through both faces so it reads from either side.
	var white := _solid_material(Color(0.96, 0.96, 0.96))
	var bar_v := MeshInstance3D.new()
	var bar_v_mesh := BoxMesh.new()
	bar_v_mesh.size = Vector3(0.2, 0.6, 0.1)
	bar_v.mesh = bar_v_mesh
	bar_v.material_override = white
	bar_v.position = field_pos
	flag.add_child(bar_v)

	var bar_h := MeshInstance3D.new()
	var bar_h_mesh := BoxMesh.new()
	bar_h_mesh.size = Vector3(0.6, 0.2, 0.1)
	bar_h.mesh = bar_h_mesh
	bar_h.material_override = white
	bar_h.position = field_pos
	flag.add_child(bar_h)

	return flag


# -----------------------------------------------------------------------------
# Water: one big translucent plane the World keeps centred under the player.
# Everything below water_level looks submerged, giving ponds in the valleys.
# -----------------------------------------------------------------------------
func _build_water() -> void:
	var span := (2 * view_radius + 1) * chunk_size * 1.2
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(span, span)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.34, 0.50, 0.62)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.04         # near-mirror so it catches the sky/horizon
	mat.metallic = 0.0
	mat.metallic_specular = 0.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_water = MeshInstance3D.new()
	_water.name = "Water"
	_water.mesh = mesh
	_water.material_override = mat
	_water.position.y = water_level
	add_child(_water)


# -----------------------------------------------------------------------------
# Shared materials / shader
# -----------------------------------------------------------------------------
func _solid_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


# The procedural grass/rock shader. Colour is layered value-noise keyed to world
# position (so it never visibly repeats across chunks), pushed toward dry yellow
# in dry biomes (vertex-colour red), with bare earth on patches/slopes, grey
# rock on steep mountain faces and a dusting of snow on the highest peaks.
func _make_ground_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_disabled;

uniform vec3 grass_low  : source_color = vec3(0.20, 0.34, 0.15); // lush / shaded
uniform vec3 grass_high : source_color = vec3(0.44, 0.55, 0.28); // sunlit blades
uniform vec3 grass_dry  : source_color = vec3(0.62, 0.58, 0.32); // dry/yellowed
uniform vec3 dirt_color : source_color = vec3(0.40, 0.31, 0.20); // bare earth
uniform vec3 rock_color : source_color = vec3(0.42, 0.40, 0.38); // mountain rock
uniform vec3 snow_color : source_color = vec3(0.92, 0.94, 0.97); // peak snow

varying vec3 world_pos;
varying vec3 world_normal;
varying float v_lush;   // 0 = dry biome, 1 = lush biome (from vertex colour)

float hash(vec2 p) {
	p = fract(p * vec2(127.34, 311.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
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
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_lush = COLOR.r;
}

void fragment() {
	vec2 wp = world_pos.xz;

	float macro  = fbm(wp * 0.020);
	float detail = fbm(wp * 0.220);

	// Base grass, grained by the fine noise.
	vec3 grass = mix(grass_low, grass_high, macro);
	grass *= 0.82 + 0.36 * detail;

	// Dry biomes yellow out; a little local noise softens the biome edge.
	float dry = clamp((1.0 - v_lush) * (0.7 + 0.6 * fbm(wp * 0.010 + vec2(31.0, 17.0))), 0.0, 1.0);
	grass = mix(grass, grass_dry, dry * 0.7);

	// Bare-earth patches and a little dirt on gentle slopes.
	float patch = smoothstep(0.58, 0.72, fbm(wp * 0.035 + vec2(60.0, 5.0)));
	float slope = 1.0 - clamp(world_normal.y, 0.0, 1.0);
	float dirt_amt = max(patch, smoothstep(0.05, 0.16, slope));
	dirt_amt *= 0.7 + 0.5 * detail;
	vec3 col = mix(grass, dirt_color, clamp(dirt_amt, 0.0, 1.0));

	// Grey rock on the steeper, higher mountain faces (kept above ordinary hills).
	float rocky = smoothstep(0.22, 0.5, slope) * smoothstep(34.0, 70.0, world_pos.y);
	col = mix(col, rock_color, clamp(rocky, 0.0, 1.0));

	// Snow dusting on the flatter tops of the very highest peaks.
	float snow = smoothstep(66.0, 105.0, world_pos.y) * clamp(world_normal.y, 0.0, 1.0);
	col = mix(col, snow_color, snow);

	ALBEDO = col;
	ROUGHNESS = 1.0;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat
