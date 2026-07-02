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
@export var chunk_segments: int = 36       # mesh resolution per chunk side
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
# Per-chunk probability of a Swiss chalet (with its flag). The world is large and
# fog hides all but the nearest chunks, so a low value means you rarely stumble on
# one near you. 0.3 keeps them special but actually findable; lower it once you've
# confirmed the look (0.1-0.15 for properly scarce).
@export var chalet_chance: float = 0.3

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

# Shared prop materials (cached so we don't allocate one per tree/rock/bush).
var _trunk_mat: StandardMaterial3D
var _rock_mat: StandardMaterial3D
var _leaf_mat: StandardMaterial3D    # tree foliage; per-tree green rides in the instance colour
var _bush_mat: StandardMaterial3D    # bush blobs; per-bush green rides in the instance colour
var _fence_mat: StandardMaterial3D   # split-rail fence (a constant brown, shared by every chalet)

# Canonical prop meshes, shared by every chunk's MultiMeshes so a chunk build
# allocates NO mesh or material resources — it only writes per-instance
# transforms/colours into a handful of MultiMeshInstance3Ds (one draw call each).
var _trunk_mesh: CylinderMesh
var _leaf_mesh: CylinderMesh          # foliage cone (top_radius 0)
var _rock_lump_mesh: SphereMesh       # unit sphere; per-lump radius/squash via instance scale
var _bush_blob_mesh: SphereMesh       # unit sphere; per-blob radius via instance scale
var _post_mesh: BoxMesh               # fence post
var _rail_mesh: BoxMesh               # fence rail, unit-length in X (instance scales X to the span)

# World-space tree positions per loaded chunk, so the minimap can still draw tree
# dots now that trees are MultiMesh instances rather than individual nodes.
var _tree_positions: Dictionary = {}   # Vector2i -> PackedVector3Array


func _ready() -> void:
	_world_seed = randi()
	_setup_noise()
	_ground_material = _make_ground_material()
	_trunk_mat = _solid_material(Color(0.40, 0.26, 0.13))
	_rock_mat = _solid_material(Color(0.42, 0.40, 0.38))
	_leaf_mat = _vertex_color_material()
	_bush_mat = _vertex_color_material()
	_fence_mat = _solid_material(Color(0.40, 0.29, 0.19))
	_build_canonical_meshes()
	_build_water()


# The one-time canonical prop meshes. Dimensions mirror the old per-prop builders
# exactly, so silhouettes are unchanged; per-instance size variation that used to
# live in the mesh (rock/bush radius) now rides in the instance transform's scale.
func _build_canonical_meshes() -> void:
	_trunk_mesh = CylinderMesh.new()
	_trunk_mesh.top_radius = 0.3
	_trunk_mesh.bottom_radius = 0.4
	_trunk_mesh.height = 2.5

	_leaf_mesh = CylinderMesh.new()
	_leaf_mesh.top_radius = 0.0
	_leaf_mesh.bottom_radius = 2.0
	_leaf_mesh.height = 4.0

	_rock_lump_mesh = SphereMesh.new()   # unit sphere (radius 1)
	_rock_lump_mesh.radius = 1.0
	_rock_lump_mesh.height = 2.0

	_bush_blob_mesh = SphereMesh.new()   # unit sphere (radius 1)
	_bush_blob_mesh.radius = 1.0
	_bush_blob_mesh.height = 2.0

	_post_mesh = BoxMesh.new()
	_post_mesh.size = Vector3(0.16, 1.5, 0.16)

	_rail_mesh = BoxMesh.new()
	_rail_mesh.size = Vector3(1.0, 0.12, 0.08)   # unit length in X; instance scales it to the span


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
			_tree_positions.erase(coord)   # drop the freed chunk's minimap tree dots

	# Drop any queued-but-now-too-far coords.
	_build_queue = _build_queue.filter(func(c):
		return absi(c.x - tc.x) <= view_radius and absi(c.y - tc.y) <= view_radius)

	# Queue everything in range we don't already have / haven't queued. A local set
	# mirrors the queue so the membership test is O(1) instead of a linear scan per
	# candidate (the double loop probes (2*view_radius+1)^2 coords every refresh).
	var queued := {}
	for c in _build_queue:
		queued[c] = true
	for dz in range(-view_radius, view_radius + 1):
		for dx in range(-view_radius, view_radius + 1):
			var c := Vector2i(tc.x + dx, tc.y + dz)
			if not _chunks.has(c) and not queued.has(c):
				_build_queue.append(c)
				queued[c] = true

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

	# Sample ONE height grid with a one-vertex apron on every side, so each vertex's
	# height AND its normal both read from this array instead of re-sampling the
	# noise ~11x per vertex. Grid width w = seg + 3 (seg+1 vertices + 1 apron each
	# side); grid cell (gi, gj) maps to world (coord*seg + gi - 1).
	var w := seg + 3
	var heights := PackedFloat32Array()
	heights.resize(w * w)
	for gj in range(w):
		for gi in range(w):
			# Index from the GLOBAL grid so a chunk's edge column lands on EXACTLY the
			# same float coordinate as the neighbour's — identical heights and normals
			# on both sides, no seam. (Offsetting i*step from a per-chunk origin instead
			# leaves a sub-unit float mismatch that shows as a faint grid line.)
			var gx := (coord.x * seg + gi - 1) * step
			var gz := (coord.y * seg + gj - 1) * step
			heights[gj * w + gi] = get_height(gx, gz)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for j in range(seg + 1):
		for i in range(seg + 1):
			var x := (coord.x * seg + i) * step
			var z := (coord.y * seg + j) * step
			var idx := (j + 1) * w + (i + 1)
			# Central differences on the grid (spacing = step). Same sign convention
			# as the old _ground_normal: (h_left - h_right, 2*spacing, h_near - h_far),
			# so the normal still points up and edge normals stay identical to neighbours.
			var hxl := heights[idx - 1]      # x - step
			var hxr := heights[idx + 1]      # x + step
			var hzn := heights[idx - w]      # z - step
			var hzf := heights[idx + w]      # z + step
			st.set_color(Color(get_biome(x, z), 0.0, 0.0, 1.0))
			st.set_uv(Vector2(float(i), float(j)))
			st.set_normal(Vector3(hxl - hxr, 2.0 * step, hzn - hzf).normalized())
			st.add_vertex(Vector3(x, heights[idx], z))

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
#
# Scatter collects per-prop TRANSFORMS (and colours) into a _Scatter buffer, then
# flushes each prop type into a single MultiMeshInstance3D — so a lush chunk is a
# handful of draw calls instead of hundreds of nodes. Chalets stay node-built
# (rare); their split-rail fence joins the MultiMesh path.
# -----------------------------------------------------------------------------

# Accumulates one chunk's scatter. Transforms are world-space (the chunk root
# sits at the origin, so local == world). min_y/max_y bound a custom AABB.
class _Scatter:
	var trunks: Array[Transform3D] = []
	var leaves: Array[Transform3D] = []
	var leaf_colors: PackedColorArray = PackedColorArray()
	var rocks: Array[Transform3D] = []
	var bushes: Array[Transform3D] = []
	var bush_colors: PackedColorArray = PackedColorArray()
	var posts: Array[Transform3D] = []
	var rails: Array[Transform3D] = []
	var tree_positions: PackedVector3Array = PackedVector3Array()
	var min_y: float = INF
	var max_y: float = -INF

	func note_y(lo: float, hi: float) -> void:
		min_y = minf(min_y, lo)
		max_y = maxf(max_y, hi)


func _scatter_props(parent: Node3D, coord: Vector2i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _chunk_seed(coord)
	var s := _Scatter.new()

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
			_place_prop(s, "tree", cx + cos(angle) * dist, cz + sin(angle) * dist, rng)

	# Lone trees scattered between the clusters.
	for t in int(round(rng.randf_range(0.0, 5.0) * tree_lush)):
		_place_prop(s, "tree", ox + rng.randf() * chunk_size, oz + rng.randf() * chunk_size, rng)

	# Rocks — sparse on lush pasture, common on dry/barren ground.
	var barren := 1.0 - lush
	for r in int(round(rng.randf_range(0.0, 3.0) + barren * 6.0)):
		_place_prop(s, "rock", ox + rng.randf() * chunk_size, oz + rng.randf() * chunk_size, rng)

	# In the most barren chunks, occasionally drop a scree field — a tight cluster
	# of rocks that reads as a stony patch matching the bare ground texture.
	if barren > 0.5 and rng.randf() < barren * 0.55:
		var sx := ox + rng.randf() * chunk_size
		var sz := oz + rng.randf() * chunk_size
		for i in rng.randi_range(4, 9):
			var a := rng.randf() * TAU
			var d := sqrt(rng.randf()) * 7.0
			_place_prop(s, "rock", sx + cos(a) * d, sz + sin(a) * d, rng)

	# Bushes sprinkled everywhere to break up the grass.
	for b in rng.randi_range(0, 4):
		_place_prop(s, "bush", ox + rng.randf() * chunk_size, oz + rng.randf() * chunk_size, rng)

	# A rare Swiss chalet with its flag — only on gentle meadow ground, never in
	# water or up among the alpine rock.
	if rng.randf() < chalet_chance:
		var hx := ox + rng.randf() * chunk_size
		var hz := oz + rng.randf() * chunk_size
		var hh := get_height(hx, hz)
		if hh >= water_level + 0.6 and hh < 40.0:
			var chalet := _make_chalet(rng)
			var rot := rng.randf() * TAU
			chalet.position = Vector3(hx, hh - 0.2, hz)   # nestle slightly into the slope
			chalet.rotation.y = rot
			parent.add_child(chalet)
			# The fence is built in world space (each post sampled against the
			# terrain) so it hugs the slope instead of floating.
			_build_fence(s, hx, hz, rot, rng)

	_flush_scatter(parent, coord, s)


# Build a prop's world transform at (x, z) — skipping anything that would stand
# in water — and append its per-part instance transforms to the scatter buffer.
func _place_prop(s: _Scatter, kind: String, x: float, z: float, rng: RandomNumberGenerator) -> void:
	var h := get_height(x, z)
	if h < water_level + 0.6:
		return
	var yaw := rng.randf() * TAU
	match kind:
		"tree": _scatter_tree(s, x, h, z, yaw, rng)
		"rock": _scatter_rock(s, x, h, z, yaw, rng)
		_:      _scatter_bush(s, x, h, z, yaw, rng)


# Turn the collected transforms into one MultiMeshInstance3D per prop type.
func _flush_scatter(parent: Node3D, coord: Vector2i, s: _Scatter) -> void:
	# The whole MultiMesh is culled as one unit against this AABB (there is no
	# per-instance culling), so set it to the chunk column with headroom: vertical
	# room for the tallest scaled tree / sunk posts, and a horizontal margin for
	# props whose foliage overhangs the chunk edge (so an overhanging prop is never
	# culled with the chunk). Set explicitly to skip the engine's AABB recompute.
	const MARGIN := 4.0
	var aabb := AABB(
		Vector3(coord.x * chunk_size - MARGIN, s.min_y - 2.0, coord.y * chunk_size - MARGIN),
		Vector3(chunk_size + 2.0 * MARGIN, (s.max_y - s.min_y) + 20.0, chunk_size + 2.0 * MARGIN))
	var no_colors := PackedColorArray()
	_add_multimesh(parent, _trunk_mesh, _trunk_mat, s.trunks, no_colors, aabb)
	_add_multimesh(parent, _leaf_mesh, _leaf_mat, s.leaves, s.leaf_colors, aabb)
	_add_multimesh(parent, _rock_lump_mesh, _rock_mat, s.rocks, no_colors, aabb)
	_add_multimesh(parent, _bush_blob_mesh, _bush_mat, s.bushes, s.bush_colors, aabb)
	_add_multimesh(parent, _post_mesh, _fence_mat, s.posts, no_colors, aabb)
	_add_multimesh(parent, _rail_mesh, _fence_mat, s.rails, no_colors, aabb)
	_tree_positions[coord] = s.tree_positions   # for the minimap radar


# Create a MultiMeshInstance3D for one prop type, if any instances were placed.
# `colors` empty => no per-instance colour (a solid shared material).
func _add_multimesh(parent: Node3D, mesh: Mesh, mat: Material,
		xforms: Array[Transform3D], colors: PackedColorArray, aabb: AABB) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var use_col := not colors.is_empty()
	if use_col:
		mm.use_colors = true          # must be set while instance_count is still 0
	mm.mesh = mesh
	mm.instance_count = xforms.size() # allocates/clears the buffer — set exactly once
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		if use_col:
			mm.set_instance_color(i, colors[i])
	mm.custom_aabb = aabb
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.material_override = mat
	parent.add_child(inst)


# World-space tree positions of every loaded chunk, for the minimap radar (trees
# are MultiMesh instances now, not nodes, so they aren't in a scene group).
func get_tree_position_chunks() -> Array:
	return _tree_positions.values()


# A stable seed for one chunk, mixing the chunk coords with the world seed so
# every chunk scatters the same way every time it loads.
func _chunk_seed(coord: Vector2i) -> int:
	var h := _world_seed
	h = (h * 73856093) ^ (coord.x * 19349663) ^ (coord.y * 83492791)
	return h


# -----------------------------------------------------------------------------
# Prop scatterers (deterministic — they draw all randomness from the passed rng).
# Each appends per-part instance transforms (matching the old node hierarchies'
# parent x child composition) to the scatter buffer.
# -----------------------------------------------------------------------------

# A tree: a trunk cylinder plus a foliage cone, both riding a base transform that
# carries the tree's yaw and a uniform 0.8..1.5 size (as the old root node did).
func _scatter_tree(s: _Scatter, x: float, h: float, z: float, yaw: float, rng: RandomNumberGenerator) -> void:
	var scl := rng.randf_range(0.8, 1.5)
	var green := Color(0.16, 0.42, 0.18).lerp(Color(0.22, 0.50, 0.20), rng.randf())
	var base := Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3.ONE * scl), Vector3(x, h, z))
	s.trunks.append(base * Transform3D(Basis.IDENTITY, Vector3(0.0, 1.25, 0.0)))
	s.leaves.append(base * Transform3D(Basis.IDENTITY, Vector3(0.0, 4.5, 0.0)))
	s.leaf_colors.append(green)
	s.tree_positions.append(Vector3(x, h, z))
	s.note_y(h, h + 6.5 * scl)   # cone top sits at local y = 4.5 + 2.0


# A rock: two or three squashed, overlapping grey spheres so it reads as a lumpy
# boulder rather than a clean ball. Per-lump radius/squash rides in the scale.
func _scatter_rock(s: _Scatter, x: float, h: float, z: float, yaw: float, rng: RandomNumberGenerator) -> void:
	var root := Transform3D(Basis(Vector3.UP, yaw), Vector3(x, h, z))
	var lumps := rng.randi_range(2, 3)
	for i in lumps:
		var r := rng.randf_range(0.5, 1.1)
		var off := Vector3(rng.randf_range(-0.5, 0.5), rng.randf_range(0.1, 0.4), rng.randf_range(-0.5, 0.5))
		var squash := Vector3(rng.randf_range(0.9, 1.3), rng.randf_range(0.6, 0.9), rng.randf_range(0.9, 1.3))
		s.rocks.append(root * Transform3D(Basis.from_scale(Vector3(r, r, r) * squash), off))
	s.note_y(h, h + 1.5)


# A bush: a small clump of green spheres sharing one per-bush green.
func _scatter_bush(s: _Scatter, x: float, h: float, z: float, yaw: float, rng: RandomNumberGenerator) -> void:
	var green := Color(0.18, 0.38, 0.16).lerp(Color(0.26, 0.46, 0.20), rng.randf())
	var root := Transform3D(Basis(Vector3.UP, yaw), Vector3(x, h, z))
	var blobs := rng.randi_range(2, 4)
	for i in blobs:
		var r := rng.randf_range(0.35, 0.6)
		var off := Vector3(rng.randf_range(-0.4, 0.4), rng.randf_range(0.3, 0.6), rng.randf_range(-0.4, 0.4))
		s.bushes.append(root * Transform3D(Basis.from_scale(Vector3.ONE * r), off))
		s.bush_colors.append(green)
	s.note_y(h, h + 1.2)


# A Valais-style Swiss chalet (see chalet.jpg): dark weathered-timber walls on a
# stone base, under a steep GABLED roof of grey stone slates, with a stone
# chimney, shuttered windows over flower boxes, a flag, and a split-rail fence
# ringing the yard.
func _make_chalet(rng: RandomNumberGenerator) -> Node3D:
	var chalet := Node3D.new()
	chalet.name = "Chalet"

	# Weathered alpine palette, with a little per-chalet variation.
	var timber_mat := _solid_material(
		Color(0.34, 0.24, 0.16).lerp(Color(0.46, 0.33, 0.22), rng.randf()))   # sun-darkened logs
	var stone_mat := _solid_material(Color(0.54, 0.53, 0.50))                  # foundation / chimney
	var slate_mat := _solid_material(
		Color(0.38, 0.40, 0.43).lerp(Color(0.46, 0.46, 0.47), rng.randf()))   # grey stone-slab roof

	const W := 6.5    # width  (x)
	const D := 5.0    # depth  (z)
	const WALL_H := 3.0

	# Stone foundation the timber sits on — a touch wider so it reads as a plinth.
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(W + 0.3, 1.0, D + 0.3)
	var base := MeshInstance3D.new()
	base.mesh = base_mesh
	base.material_override = stone_mat
	base.position.y = 0.5
	chalet.add_child(base)

	# Timber walls (log-cabin body) standing on the plinth.
	var walls_mesh := BoxMesh.new()
	walls_mesh.size = Vector3(W, WALL_H, D)
	var walls := MeshInstance3D.new()
	walls.mesh = walls_mesh
	walls.material_override = timber_mat
	walls.position.y = 1.0 + WALL_H * 0.5
	chalet.add_child(walls)

	var eaves_y := 1.0 + WALL_H   # top of the walls / base of the roof

	# Gabled roof: a triangular prism. The PrismMesh extrudes its triangle along
	# Z, so we rotate it 90 deg to lay the ridge along X (the width). Generous
	# overhang on all sides, the way heavy alpine roofs hang over the walls.
	const ROOF_H := 2.4
	var roof_mesh := PrismMesh.new()
	roof_mesh.size = Vector3(D + 1.4, ROOF_H, W + 1.0)   # (base across eaves, height, ridge length)
	var roof := MeshInstance3D.new()
	roof.mesh = roof_mesh
	roof.material_override = slate_mat
	roof.position.y = eaves_y + ROOF_H * 0.5
	roof.rotation.y = PI / 2.0
	chalet.add_child(roof)

	# Triangular gable infill so the timber wall reaches the ridge on the end
	# faces (the prism alone would leave the gable ends open above the eaves).
	for sx in [-1.0, 1.0]:
		var gable_mesh := PrismMesh.new()
		gable_mesh.size = Vector3(D, ROOF_H, 0.25)
		var gable := MeshInstance3D.new()
		gable.mesh = gable_mesh
		gable.material_override = timber_mat
		gable.position = Vector3(sx * (W * 0.5 - 0.12), eaves_y + ROOF_H * 0.5, 0.0)
		gable.rotation.y = PI / 2.0
		chalet.add_child(gable)

	# Stone chimney rising past the ridge.
	var chimney_mesh := BoxMesh.new()
	chimney_mesh.size = Vector3(0.7, 2.0, 0.7)
	var chimney := MeshInstance3D.new()
	chimney.mesh = chimney_mesh
	chimney.material_override = stone_mat
	chimney.position = Vector3(W * 0.25, eaves_y + 1.4, 0.0)
	chalet.add_child(chimney)

	# A heavy plank door, centred on the front (+Z) face.
	var door_mesh := BoxMesh.new()
	door_mesh.size = Vector3(1.1, 2.0, 0.12)
	var door := MeshInstance3D.new()
	door.mesh = door_mesh
	door.material_override = _solid_material(Color(0.22, 0.15, 0.10))
	door.position = Vector3(0.0, 2.0, D * 0.5 + 0.02)
	chalet.add_child(door)

	# Shuttered windows with flower boxes, two on the front, one on each end.
	for wx in [-1.9, 1.9]:
		var win := _make_window(rng)
		win.position = Vector3(wx, 2.0, D * 0.5 + 0.02)
		chalet.add_child(win)
	for sx2 in [-1.0, 1.0]:
		var win_side := _make_window(rng)
		win_side.position = Vector3(sx2 * (W * 0.5 + 0.02), 2.0, 0.0)
		win_side.rotation.y = sx2 * PI / 2.0
		chalet.add_child(win_side)

	# The flag on its pole, planted just beside the cottage.
	var flag := _make_flag()
	flag.position = Vector3(W * 0.5 + 1.0, 0.0, 1.2)
	chalet.add_child(flag)

	# The split-rail fence is built separately, in world space, so it can hug the
	# terrain slope (see _build_fence at the chalet's call site).
	return chalet


# A small shuttered window (facing +Z) over a flower box, the way alpine chalets
# carry geraniums on every sill. Returned in its own frame so callers just
# position/rotate it onto a wall.
func _make_window(rng: RandomNumberGenerator) -> Node3D:
	var win := Node3D.new()
	win.name = "Window"

	# White-painted frame with a dark glass pane recessed into it.
	var frame := MeshInstance3D.new()
	var frame_mesh := BoxMesh.new()
	frame_mesh.size = Vector3(1.05, 1.2, 0.1)
	frame.mesh = frame_mesh
	frame.material_override = _solid_material(Color(0.90, 0.89, 0.85))
	win.add_child(frame)

	var pane := MeshInstance3D.new()
	var pane_mesh := BoxMesh.new()
	pane_mesh.size = Vector3(0.82, 0.96, 0.08)
	pane.mesh = pane_mesh
	pane.material_override = _solid_material(Color(0.20, 0.26, 0.30))
	pane.position.z = 0.04
	win.add_child(pane)

	# Open shutters flanking the frame.
	var shutter_mat := _solid_material(Color(0.45, 0.20, 0.16))   # weathered barn red
	for sx in [-1.0, 1.0]:
		var shutter := MeshInstance3D.new()
		var shutter_mesh := BoxMesh.new()
		shutter_mesh.size = Vector3(0.28, 1.2, 0.06)
		shutter.mesh = shutter_mesh
		shutter.material_override = shutter_mat
		shutter.position = Vector3(sx * 0.66, 0.0, 0.04)
		win.add_child(shutter)

	# Flower box on the sill with a few bright blooms.
	var box := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(1.1, 0.22, 0.26)
	box.mesh = box_mesh
	box.material_override = _solid_material(Color(0.30, 0.20, 0.13))
	box.position = Vector3(0.0, -0.74, 0.14)
	win.add_child(box)

	var blooms := [Color(0.86, 0.20, 0.28), Color(0.90, 0.36, 0.55), Color(0.80, 0.16, 0.20)]
	for i in 5:
		var petal := MeshInstance3D.new()
		var petal_mesh := SphereMesh.new()
		petal_mesh.radius = 0.11
		petal_mesh.height = 0.22
		petal.mesh = petal_mesh
		petal.material_override = _solid_material(blooms[rng.randi() % blooms.size()])
		petal.position = Vector3(-0.44 + i * 0.22, -0.60, 0.18)
		win.add_child(petal)

	return win


# A rustic split-rail fence enclosing the chalet's yard, with a gate gap at the
# front. Built in WORLD space (added to the chunk, not the chalet): every post is
# sampled against the terrain so the fence hugs the slope, and the rails tilt to
# join neighbouring post tops instead of floating flat. Purely cosmetic — props
# carry no collision. (ox, oz) is the chalet's world position; rot its yaw.
func _build_fence(s: _Scatter, ox: float, oz: float, rot: float, _rng: RandomNumberGenerator) -> void:
	const HX := 7.5    # half-extents of the yard (chalet-local)
	const HZ := 6.5
	const GATE := 1.4  # half-width of the front gate opening

	# Five straight runs in chalet-local XZ; the front (+Z) is split around the gate.
	_fence_run(s, ox, oz, rot, Vector2(-HX, HZ), Vector2(-GATE, HZ))   # front-left
	_fence_run(s, ox, oz, rot, Vector2(GATE, HZ), Vector2(HX, HZ))     # front-right
	_fence_run(s, ox, oz, rot, Vector2(-HX, -HZ), Vector2(HX, -HZ))    # back
	_fence_run(s, ox, oz, rot, Vector2(-HX, -HZ), Vector2(-HX, HZ))    # left
	_fence_run(s, ox, oz, rot, Vector2(HX, -HZ), Vector2(HX, HZ))      # right


# Turn a chalet-local XZ offset into a world XZ point (yaw rotation + translation).
func _fence_world(ox: float, oz: float, rot: float, local: Vector2) -> Vector2:
	var c := cos(rot)
	var s := sin(rot)
	return Vector2(ox + c * local.x + s * local.y, oz - s * local.x + c * local.y)


# Build one straight fence run between two chalet-local points: evenly spaced
# posts, each dropped onto the terrain, joined by two rails that tilt to follow
# the ground between consecutive posts.
func _fence_run(s: _Scatter, ox: float, oz: float, rot: float, a: Vector2, b: Vector2) -> void:
	var spans := int(max(1, round((b - a).length() / 2.4)))

	# Sample each post's world position + terrain height along the run.
	var pts: Array[Vector3] = []
	for i in spans + 1:
		var local := a.lerp(b, float(i) / float(spans))
		var w := _fence_world(ox, oz, rot, local)
		pts.append(Vector3(w.x, get_height(w.x, w.y), w.y))

	# Posts: stand each one at its sampled height, sunk a little into the ground.
	for p in pts:
		s.posts.append(Transform3D(Basis(Vector3.UP, rot), p + Vector3(0.0, 0.45, 0.0)))
		s.note_y(p.y, p.y + 1.2)   # top ~1.2 above ground, base sunk ~0.3

	# Rails: one segment per post gap, tilted to connect the two post tops so the
	# rail follows the slope instead of cutting through or floating over it. The
	# canonical rail mesh is unit-length in X, so we scale its X axis to the span.
	for ry in [0.55, 1.0]:
		for i in spans:
			var p0 := pts[i] + Vector3(0.0, ry, 0.0)
			var p1 := pts[i + 1] + Vector3(0.0, ry, 0.0)
			var seg := p1 - p0
			# Orient the rail's local +X axis along the segment (handles both the
			# horizontal heading and the up/down pitch of the slope).
			var x_axis := seg.normalized()
			var z_axis := x_axis.cross(Vector3.UP)
			if z_axis.length() < 0.001:
				z_axis = Vector3.FORWARD   # degenerate: perfectly vertical segment
			z_axis = z_axis.normalized()
			var y_axis := z_axis.cross(x_axis).normalized()
			s.rails.append(Transform3D(Basis(x_axis * seg.length(), y_axis, z_axis), (p0 + p1) * 0.5))


# A small Swiss flag (red field with a white cross) on a slim pole.
func _make_flag() -> Node3D:
	var flag := Node3D.new()
	flag.name = "Flag"

	# Pole: ~6.5 m tall, standing a bit taller than the cottage ridge.
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.06
	pole_mesh.bottom_radius = 0.08
	pole_mesh.height = 6.5
	var pole := MeshInstance3D.new()
	pole.mesh = pole_mesh
	pole.material_override = _solid_material(Color(0.72, 0.72, 0.74))
	pole.position.y = 3.25
	flag.add_child(pole)

	# Red field (~1.3 m square), hanging from near the top of the pole.
	var field_pos := Vector3(0.75, 5.3, 0.0)
	var red := MeshInstance3D.new()
	var red_mesh := BoxMesh.new()
	red_mesh.size = Vector3(1.3, 1.3, 0.05)
	red.mesh = red_mesh
	red.material_override = _solid_material(Color(0.83, 0.10, 0.13))
	red.position = field_pos
	flag.add_child(red)

	# White cross: arms ~1/5 of the field, poking through both faces so it reads
	# from either side.
	var white := _solid_material(Color(0.96, 0.96, 0.96))
	var bar_v := MeshInstance3D.new()
	var bar_v_mesh := BoxMesh.new()
	bar_v_mesh.size = Vector3(0.26, 0.78, 0.12)
	bar_v.mesh = bar_v_mesh
	bar_v.material_override = white
	bar_v.position = field_pos
	flag.add_child(bar_v)

	var bar_h := MeshInstance3D.new()
	var bar_h_mesh := BoxMesh.new()
	bar_h_mesh.size = Vector3(0.78, 0.26, 0.12)
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


# A material whose albedo comes from the per-instance MultiMesh colour. Albedo is
# left pure white (the instance colour MULTIPLIES it), and vertex_color_is_srgb
# makes those colours read identically to the old per-prop albedo_color path.
func _vertex_color_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
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

	// Multi-scale noise fields, all keyed to world position so regions blend
	// organically and never repeat or tile.
	float macro  = fbm(wp * 0.020);                         // grass tone variation
	float detail = fbm(wp * 0.220);                         // fine graining
	float region = fbm(wp * 0.0065 + vec2(19.0, 7.0));      // very large regions
	float patchN = fbm(wp * 0.050  + vec2(60.0, 5.0));      // medium ragged patches
	float slope  = 1.0 - clamp(world_normal.y, 0.0, 1.0);

	// Aridity: how dry/barren this stretch of ground is. Driven by the biome
	// field (sparse-tree regions read as dry) AND an independent large-scale
	// noise, so barren ground also crops up inside otherwise green country —
	// variety without any geometric boundary.
	float aridity = clamp(0.7 * (1.0 - v_lush) + 0.9 * region - 0.35, 0.0, 1.0);

	// Base grass, grained by the fine noise, with a subtle per-region hue drift
	// so even the lush pastures aren't one flat green.
	vec3 grass = mix(grass_low, grass_high, macro);
	grass = mix(grass, grass * vec3(0.96, 1.03, 0.90), region * 0.5);
	grass *= 0.82 + 0.36 * detail;

	// Arid stretches yellow toward dry-grass colour.
	grass = mix(grass, grass_dry, smoothstep(0.10, 0.70, aridity) * 0.8);

	// Barren exposed earth: grows with aridity, with ragged medium-noise edges
	// (noise pushed into the threshold input, not the output, so the boundary
	// stays soft and irregular instead of a clean contour).
	float barren = smoothstep(0.48, 0.86, aridity + (patchN - 0.5) * 0.55);
	// Bare earth on genuinely steep ground only. The threshold starts well above
	// flat (0.18) so tiny per-facet normal wobble on pasture does NOT trip it —
	// otherwise the low-poly mesh triangles outline themselves as a dirt grid.
	float slope_dirt = smoothstep(0.18, 0.42, slope);
	float dirt_amt = max(barren, slope_dirt * 0.85);
	dirt_amt *= 0.75 + 0.45 * detail;
	vec3 col = mix(grass, dirt_color, clamp(dirt_amt, 0.0, 1.0));

	// Scattered stones / scree: speckle grey rock into the ground, densest where
	// it is most barren so dry country reads as genuinely stony.
	float speck = fbm(wp * 0.7 + vec2(3.0, 9.0));
	float stones = smoothstep(0.58, 0.74, speck) * (0.18 + 0.82 * barren);
	col = mix(col, rock_color * (0.85 + 0.3 * detail), clamp(stones, 0.0, 1.0));

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
