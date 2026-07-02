# Plan 01 — Performance Optimization (cow-abductor)

Baseline: commit `a0404bf` ("fences, terrain and cow model improvements").
Goal: make the game render and stream dramatically cheaper, and make the tractor
beam feel physical — **without changing what the game looks like or does**.

## Ground rules (apply to every phase)

- **Production code only. No tests, no test scaffolding.** There are no tests,
  linters, or build steps in this repo; verification is careful reading plus
  running the game in Godot 4.7 (F5 on `scenes/Main.tscn`). No headless Godot
  binary is available in this environment.
- **Preserve behavior and visuals.** Every deviation this plan permits is
  called out explicitly; anything not called out must stay identical.
- **Preserve the two chunk invariants** (from CLAUDE.md):
  1. Deterministic per-chunk scatter via `_chunk_seed(coord)`-seeded
     `RandomNumberGenerator` — **never** global `randf()` in chunk generation.
  2. World-space chunk geometry (chunk root at origin; vertices/props in world
     coordinates) so adjacent chunks share exact edge values — no seams.
- **Match house style**: tabs for indentation, `snake_case`, section banner
  comments (`# --- Name ---…---`), comments explain *why*/constraints, typed
  GDScript (`:=`, explicit return types).
- Each phase is self-contained: read the cited file/lines before editing.
  Execute phases **in order**; commit (or at least run the game) after each.
- Code sketches below are the intended shape — transcribe real dimensions,
  offsets, and RNG usage from the current code where the sketch says so.
  **Never invent API parameters**; Phase 0 lists the verified APIs.

---

## Phase 0 — Verified facts & allowed APIs (read this, don't re-research)

### Verified against docs.godotengine.org (stable, 4.x)

**MultiMesh** (`class_multimesh.html`) — required setup order:

```gdscript
var mm := MultiMesh.new()
mm.transform_format = MultiMesh.TRANSFORM_3D  # 1) format first
mm.use_colors = true                          # 2) ONLY while instance_count == 0
mm.mesh = some_mesh                           # 3) the canonical mesh
mm.instance_count = n                         # 4) allocates & CLEARS the buffer
for i in n:
	mm.set_instance_transform(i, xf)          # 5) per-instance writes
	mm.set_instance_color(i, col)             #    (only if use_colors)
```

- `use_colors` / `use_custom_data` "can only be set when instance_count is 0
  or less" — set them **before** `instance_count`.
- Setting `instance_count` "clears and (re)sizes the buffers" — set it once
  per chunk build; never grow it incrementally.
- `set_instance_color` requires `use_colors = true` on the MultiMesh **and**
  `vertex_color_use_as_albedo = true` on the material. The instance color
  **multiplies** albedo — for an absolute color, the shared material's
  `albedo_color` must be pure white `Color(1, 1, 1)`.
- `MultiMesh.custom_aabb: AABB` exists in 4.x — "setting this manually
  prevents costly runtime AABB recalculations".
- Do **NOT** bulk-write the `buffer: PackedFloat32Array` property — its 4.x
  float layout is undocumented (the 12+4 layout you may remember is Godot 3.5).
  Per-instance setters are the docs-sanctioned path and are fine at
  chunk-build time.

**MultiMeshInstance3D** (`class_multimeshinstance3d.html`): one property,
`multimesh`. Inherits GeometryInstance3D → `cast_shadow` available. Culling is
all-or-nothing per MultiMesh ("no screen or frustum culling possible for
individual instances") — fine here because each MultiMesh is chunk-scoped and
the chunk is the natural culling unit.

**Primitive meshes**: `CylinderMesh` (`top_radius`, `bottom_radius`, `height`,
`radial_segments`, `rings`, `cap_top`, `cap_bottom`), `SphereMesh` (`radius`,
`height` — full height, 2×radius for a round sphere, `radial_segments`,
`rings`), `BoxMesh` (`size`), `PrismMesh` (`left_to_right`, `size`).
`StandardMaterial3D.vertex_color_use_as_albedo` is the exact property name
(on BaseMaterial3D).

### Verified facts about the current code (line numbers at `a0404bf`)

| Fact | Where |
| --- | --- |
| Chunk constants: `chunk_size=130.0`, `chunk_segments=36`, `view_radius=4`, `builds_per_frame=2` | `Terrain.gd:28-32` |
| `_chunks: Dictionary`, `_build_queue: Array` of `Vector2i` | `Terrain.gd:67-68` |
| `_refresh_desired` frees far chunks, filters queue, double-loop with linear `_build_queue.has(c)` | `Terrain.gd:181-203` |
| `_chunk_seed(coord)` hash | `Terrain.gd:372-375` |
| `_build_ground_mesh`: SurfaceTool, 37×37 verts, global-grid indexing `x=(coord.x*seg+i)*step`, per-vertex `get_biome` + `_ground_normal` + `get_height` | `Terrain.gd:246-281` |
| `_ground_normal`: central differences with `e=1.0`, 4× `get_height` | `Terrain.gd:134-138` |
| `get_height` = 2 noise samples (`_base`+`_mountain`); `get_biome` = 1 (`_biome`) → **11 noise calls/vertex, ~15k/chunk** | `Terrain.gd:117-130` |
| Ground material: one shared `ShaderMaterial` reading `COLOR.r` as lushness | `Terrain.gd:70,81,234,770-879` |
| `_scatter_props`: chunk-seeded RNG, tree clusters + lone trees + rocks + scree + bushes + rare chalet w/ fence | `Terrain.gd:288-349` |
| `_place_prop`: water cull, builds node, `add_to_group("trees")` for trees | `Terrain.gd:354-367` |
| Prop builders: `_make_tree` 381-407 (root+trunk+leaves, **per-tree leaf material**, scale 0.8–1.5, leaf green lerp), `_make_rock` 412-426 (2–3 sphere lumps, shared `_rock_mat`), `_make_bush` 430-445 (2–4 blobs, one material per bush), `_make_chalet` 452-548, `_make_window` 554-605, `_make_flag` 685-729, `_build_fence` 613-625 + `_fence_run` 638-681 (per-post/per-rail `BoxMesh.new()`, one material per fence) | `Terrain.gd` |
| Only shared prop materials today: `_trunk_mat`, `_rock_mat` (via `_solid_material`, `Terrain.gd:760-763`) | `Terrain.gd:73-83` |
| Props carry **no collision**; chunk root sits at origin, props positioned in world space | `Terrain.gd:223-240, 612` |
| Water: single shared plane, already efficient — don't touch | `Terrain.gd:736-754` |
| Minimap iterates `get_nodes_in_group("trees")` every `_draw` (every frame) reading `tree.global_position`; **sole consumer** of the group (birds no longer use trees, `World.gd:57`) | `Minimap.gd:52-55` |
| Cow extends `Node3D` (no physics body); motion = direct `global_position` writes | `Cow.gd:14-15` |
| `_ride_beam`: framerate-shaped `lerp`/`move_toward`, spin + wobble, capture = 3D `distance_to(saucer) <= capture_distance (1.6)` then `queue_free()` | `Cow.gd:208-223` |
| `set_pulled(pulled: bool, saucer: Node3D)`; rising edge plays moo+bell | `Cow.gd:101-107` |
| Grab test: flat horizontal cylinder, `beam_radius=6.0`, **altitude-independent**; every cow gets `set_pulled` each physics frame | `Saucer.gd:291-304` |
| Capture wiring: `World._spawn_one_cow` connects `captured` → `_on_cow_captured` (tally + `_update_hud` + respawn) | `World.gd:278-290, 322-325` |
| `fly_height` player-adjustable 9–90 m (Z/X) — beamed cows may rise a long way | `Saucer.gd:24-29` |
| `Farmer._physics_process` does `get_first_node_in_group("saucer")` **every physics frame per farmer** (6 farmers) | `Farmer.gd:56-83` |
| `Farmer._spawn_bullet` tween: `tw.tween_callback(saucer.register_hit.bind(global_position))` holds the saucer ref across the bullet's flight | `Farmer.gd:119-148` |
| `Audio._fill_whistle` does the same lookup **every frame** (reads only `saucer.beam_active`); `_tick_birds` looks up only on chirp (~1.5–4.5 s) | `Audio.gd:105-113, 87-101` |
| World already caches `_saucer` and injects `Callable(_terrain, "get_height")` into cow/farmer/saucer — the injection pattern to copy | `World.gd:278-290, 343-349, 393-403` |
| `_update_hud` rebuilds the whole label (incl. static help text) **every frame**; dynamic values change once/second at most | `World.gd:67-72, 462-465` |
| `_ready()` order: input → env → sun → terrain → audio → birds → **saucer** → `set_target` → cows → farmers → UI (audio exists *before* the saucer) | `World.gd:50-63` |

---

## Phase 1 — MultiMesh prop scatter (Terrain.gd) + minimap tree feed

**The big one.** A lush chunk today = 200+ `MeshInstance3D` nodes, a fresh
`Mesh` resource per part, and a fresh `StandardMaterial3D` per tree/bush/fence
— each unique mesh+material is its own draw call and none of it batches. With
81 chunks live that's thousands of nodes and draw calls. Convert scattered
props to **per-chunk, per-type MultiMeshes**: ~6 `MultiMeshInstance3D` per
chunk, one draw call each, and chunk builds stop allocating meshes/materials
entirely.

**Files:** `scripts/Terrain.gd`, `scripts/Minimap.gd`, `scripts/World.gd`
(one injection line), `CLAUDE.md` (defer doc edit to Phase 6).

### 1a. Canonical meshes + shared materials (build once in `_ready`)

First **read `_make_tree` (381-407), `_make_rock` (412-426), `_make_bush`
(430-445), `_fence_run` (638-681) and transcribe the exact mesh dimensions and
child local offsets** — the sketches below use placeholders on purpose.

Add fields + `_ready` construction next to the existing `_trunk_mat`/`_rock_mat`:

```gdscript
# Canonical prop meshes, shared by every chunk's MultiMeshes (built once so a
# chunk build allocates no mesh resources at all).
var _trunk_mesh: CylinderMesh
var _leaf_mesh: CylinderMesh        # the foliage cone (top_radius 0)
var _rock_lump_mesh: SphereMesh
var _bush_blob_mesh: SphereMesh
var _post_mesh: BoxMesh             # size Vector3(0.16, 1.5, 0.16) — from _fence_run
var _rail_mesh: BoxMesh             # size Vector3(1.0, 0.12, 0.08): unit length,
                                    # per-instance basis stretches x to the span
# Shared prop materials for per-instance-colored props: albedo stays pure white
# and the real color rides in the instance color (multiplies albedo).
var _leaf_mat: StandardMaterial3D
var _bush_mat: StandardMaterial3D
var _fence_mat: StandardMaterial3D  # constant brown — no instance colors needed
```

- Copy every dimension (`top_radius`, `bottom_radius`, `height`, segment
  counts if the current code sets them) verbatim from the existing builders so
  silhouettes don't change. Where a dimension is per-instance random (rock
  lump radius/squash, bush blob radius), keep the canonical mesh at the
  builder's base size and express the variation as per-instance basis scale.
- `_leaf_mat` / `_bush_mat`: `StandardMaterial3D.new()` with
  `albedo_color = Color(1, 1, 1)` and `vertex_color_use_as_albedo = true`
  (plus copy any flags `_solid_material` sets — currently only albedo).
- `_fence_mat = _solid_material(Color(0.40, 0.29, 0.19))` — the fence color is
  a constant today (allocated per chalet); hoist it to one shared instance.
- Chalet parts, windows, and flags **stay node-built** (`_make_chalet`
  unchanged) — they're rare (`chalet_chance`), and their per-instance material
  count is acceptable. Do not refactor them in this phase.

### 1b. Scatter collects transforms instead of nodes

Rework `_scatter_props`/`_place_prop` so a chunk build fills arrays, then one
flush creates the MultiMeshes. Keep the **exact same scatter logic, RNG
object, water cull, and `get_height` placement** — only the output changes.
(RNG call order may shift slightly; that's fine — determinism only requires
the same seed → same layout on every rebuild, and the world seed is
re-randomized each run anyway.)

```gdscript
# Per-chunk scatter accumulators (transforms are world-space; the chunk root
# sits at the origin so local == world).
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
```

- `_place_prop` becomes: sample `get_height`, water-cull (unchanged), build the
  prop's **base transform** `Transform3D(Basis(Vector3.UP, yaw) *
  Basis.from_scale(Vector3.ONE * s), Vector3(x, h, z))`, then append one
  instance transform per part: `base * Transform3D(Basis.from_scale(part_scale),
  part_offset)` — i.e. exactly the parent×child composition the old node
  hierarchy produced. Mirror the old builders' offsets/scales 1:1.
- Tree: push trunk transform (+ shared `_trunk_mat` color path — no instance
  color), leaf transform + the same green lerp
  `Color(0.16,0.42,0.18).lerp(Color(0.22,0.50,0.20), rng.randf())` into
  `leaf_colors`, and `Vector3(x, h, z)` into `tree_positions`.
- Rock: 2–3 lump transforms (same per-lump offset/radius/squash RNG), no color.
- Bush: 2–4 blob transforms, **one** color per bush pushed once per blob.
- Fence: `_fence_run` keeps its post-height sampling and rail-basis math
  verbatim, but appends transforms: posts as position+yaw; rails as
  `Transform3D(Basis(x_axis, y_axis, z_axis).scaled_local(Vector3(seg_len, 1, 1)), midpoint)`
  — the canonical rail mesh is unit-length in x, so scale x by the span length.
  (Equivalent formulation: build the same orthonormal basis as today, then
  multiply its x column by `seg_len`.) The degenerate-vertical guard stays.
- Track `min_y`/`max_y` from every placement for the AABB.

### 1c. Flush: one MultiMeshInstance3D per non-empty type

```gdscript
func _add_multimesh(parent: Node3D, mesh: Mesh, mat: Material,
		xforms: Array[Transform3D], colors: PackedColorArray, aabb: AABB) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	if not colors.is_empty():
		mm.use_colors = true          # must precede instance_count (docs)
	mm.mesh = mesh
	mm.instance_count = xforms.size() # allocates the buffer — set exactly once
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		if not colors.is_empty():
			mm.set_instance_color(i, colors[i])
	mm.custom_aabb = aabb             # skip the engine's AABB recalculation
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.material_override = mat
	parent.add_child(inst)
```

- AABB (world coords; chunk root at origin so they pass through unchanged):
  `AABB(Vector3(coord.x * chunk_size, s.min_y - 2.0, coord.y * chunk_size),
  Vector3(chunk_size, s.max_y - s.min_y + 20.0, chunk_size))` — the +20/-2
  margins cover the tallest scaled tree and sunk fence posts. Guard the empty
  case (`min_y == INF` → skip, every array is empty anyway).
- Call `_add_multimesh` six times from the end of `_scatter_props` (trunks/
  `_trunk_mat`, leaves/`_leaf_mat`, rocks/`_rock_mat`, bushes/`_bush_mat`,
  posts/`_fence_mat`, rails/`_fence_mat`).

### 1d. Tree positions for the minimap (the `"trees"` group goes away)

The minimap is the **only** consumer of the `"trees"` group and it will break
silently (empty group → no tree dots) unless replaced in the same phase.

- Terrain: `var _tree_positions: Dictionary = {}  # Vector2i -> PackedVector3Array`.
  Store each chunk's `s.tree_positions` when the chunk is built; **erase the
  entry in `_refresh_desired`'s free loop** (`Terrain.gd:186-189`) right where
  `_chunks.erase(coord)` happens.
- Terrain API for the minimap:

```gdscript
# World-space positions of every live tree, for the minimap radar.
func get_tree_position_chunks() -> Array:
	return _tree_positions.values()
```

- `Minimap.gd`: add `var terrain: Terrain = null`, injected from
  `World._build_ui()` (`minimap.terrain = _terrain` — same injection style as
  `ground_sampler`). Replace the `get_nodes_in_group("trees")` loop
  (`Minimap.gd:52-55`) with iteration over
  `terrain.get_tree_position_chunks()` → inner loop over each
  `PackedVector3Array`, feeding `_world_to_map(p, …)` exactly as before. Keep
  the same radius cull and `TREE_COLOR` dot. Null-guard `terrain`.
- Delete `node.add_to_group("trees")` (`Terrain.gd:366`) along with the node
  path it lived in.

### Verification (run the game)

- [ ] Pasture looks the same: tree clusters + lone trees, rocks/scree on
      barren ground, bushes, chalets with fences hugging slopes; per-tree size
      and green variation still visible; fence rails still tilt along slopes.
- [ ] Fly far away and back: **identical scenery regenerates** (determinism).
- [ ] No cracks/pops at chunk borders; props sit on the ground.
- [ ] Minimap still draws green tree dots that scroll with flight.
- [ ] Remote scene tree (editor, while running): a chunk node now has ~1 ground
      mesh + ≤6 MultiMeshInstance3D + the occasional chalet — not hundreds of
      nodes. Frame rate up; chunk-build hitches audibly reduced.
- [ ] Grep guards: `add_to_group("trees")` → 0 hits; `get_nodes_in_group("trees")`
      → 0 hits; no `randf()`/`randi()` (global, non-`rng.`) anywhere in
      Terrain chunk code; in `_add_multimesh`, `use_colors` is assigned before
      `instance_count` and `instance_count` assigned exactly once.

### Anti-pattern guards

- Don't write `mm.buffer` directly (undocumented layout in 4.x).
- Don't set `use_colors` after `instance_count`, don't resize `instance_count`.
- Don't tint via per-instance materials — that recreates the problem.
- Don't leave a stale `_tree_positions` entry when a chunk is freed (minimap
  would draw ghost trees).
- Don't touch water, the ground shader, or chalet internals in this phase.

---

## Phase 2 — Grid-based heights & normals in `_build_ground_mesh`

**Problem:** 11 noise calls per vertex (5× `get_height` × 2 samples + 1
biome) ≈ 15k noise calls per chunk, ×2 chunks/frame while streaming, ×25 at
startup. Height is re-sampled redundantly at overlapping offsets.

**Fix:** sample one height grid per chunk, derive vertex heights *and*
normals from it. **File:** `scripts/Terrain.gd` (only `_build_ground_mesh`,
`Terrain.gd:246-281`).

- Grid: `(seg + 3) × (seg + 3)` heights (one apron row/column on each side)
  in a `PackedFloat32Array`, row width `W := seg + 3`, grid index `gi` for
  vertex `(i, j)` is `(j + 1) * W + (i + 1)`. Sample with the **same
  global-grid coordinates** as today — `x := (coord.x * seg + gi_x) * step`
  for `gi_x in range(-1, seg + 2)` — this is what keeps edges seam-free
  (`Terrain.gd:250-260` comment explains why; keep that comment's guarantee).
- Vertex loop: `get_biome(x, z)` stays per-vertex (1 call); height comes from
  the grid; normal from grid neighbours:

```gdscript
var hl := heights[gi - 1]
var hr := heights[gi + 1]
var ht := heights[gi - W]
var hb := heights[gi + W]
st.set_normal(Vector3(hl - hr, 2.0 * step, ht - hb).normalized())
```

- **Permitted visual deviation (the only one in this plan):** central
  differences now use spacing `step ≈ 3.61 m` instead of `e = 1.0 m`, so
  shading is marginally smoother. It stays seam-safe (shared edge columns
  produce identical normals on both sides). If the ground looks noticeably
  softer in-game, this is the cause — flag it rather than reverting silently.
- Net cost: `39² = 1521` height samples + `1369` biome ≈ **4.4k noise calls
  per chunk, down from ~15k** (~70% cut).
- `_ground_normal` (`Terrain.gd:134-138`): grep for other callers; if
  `_build_ground_mesh` was the only one, delete it, otherwise leave it.
- Index/winding loop (`Terrain.gd:268-280`) is untouched — the shadow-bias
  winding comment must survive.

### Verification

- [ ] Terrain shape identical; biome coloring identical; chunk seams still
      invisible (fly along a border and look down).
- [ ] Shadows still land on the ground (winding preserved).
- [ ] Startup noticeably faster (25 synchronous chunk builds in `set_target`);
      streaming hitches further reduced.
- [ ] Grep guard: no call to `_ground_normal` remains inside
      `_build_ground_mesh`; `get_height` appears in the mesh function only for
      grid filling.

---

## Phase 3 — Spring-damper beam physics (`scripts/Cow.gd`)

**Problem:** `_ride_beam` (`Cow.gd:208-223`) is kinematic — constant-rate
lerp/`move_toward`, no momentum, no swing. For a game whose premise is the
beam, this is the feel-critical upgrade.

**Two known bugs in the previously-sketched patch — both must be avoided:**

- **(a) Dangle-forever:** a spring whose rest point sits `carry_gap` below the
  saucer while capture requires 3D distance ≤ 1.6 can settle outside the
  capture sphere. Fix: capture on a **rest test** (risen to the carry point
  AND roughly centered), with the old distance test kept as a fallback.
- **(b) Inverted heaviness:** deciding capture by overshoot makes heavy cows
  (which overshoot less) capture *worse*. The rest test above makes capture
  independent of overshoot, killing the bug; heaviness then only shapes how
  laggy/weighty the ride feels — the intent.

### Implementation

Replace the abduction tuning block (`Cow.gd:28-32`) — `pull_rise` and
`pull_lateral` are deleted (grep first: World never sets them); keep
`spin_speed`, `fall_speed`, `capture_distance`:

```gdscript
# --- Abduction tuning --------------------------------------------------------
@export var lift_stiffness: float = 14.0   # vertical spring toward the carry point
@export var lift_damping: float = 7.0      # near-critical (2*sqrt(14) ≈ 7.5): brisk rise, tiny bob
@export var swing_stiffness: float = 10.0  # horizontal pull toward the beam axis
@export var swing_damping: float = 1.8     # deliberately low so the cow pendulums when the saucer moves
@export var carry_gap: float = 1.2         # rest point this far below the saucer centre
@export var capture_height: float = 0.35   # risen to within this of the carry point…
@export var capture_radius: float = 1.0    # …and this close to the beam axis = captured
@export var beam_max_speed: float = 30.0   # cap so a 90 m lift doesn't turn ballistic
@export var spin_speed: float = 8.0        # (unchanged)
@export var fall_speed: float = 12.0       # (unchanged)
@export var capture_distance: float = 1.6  # legacy fallback capture sphere (kept)

var _beam_vel: Vector3 = Vector3.ZERO
var _heaviness: float = 1.0                # >1 = heavier: laggier lift, wider swing
```

- `_heaviness`: derive from the existing per-cow `_size` (assigned near
  `Cow.gd:61` — read the actual `randf_range` bounds there) via
  `remap(_size, SIZE_MIN, SIZE_MAX, 0.85, 1.3)` right after `_size` is set.
  If `_size` turns out constant, use `randf_range(0.85, 1.3)` instead (cows
  are not chunk-scattered; global RNG is fine here).
- `set_pulled` (`Cow.gd:101-107`): on the rising edge (inside the existing
  `if pulled and not _pulled:` branch, alongside the moo/clonk) add
  `_beam_vel = Vector3.ZERO` so a re-grab starts from rest.
- New `_ride_beam` (same call site; spin/wobble and capture side effects
  preserved):

```gdscript
func _ride_beam(delta: float) -> void:
	# Rest point sits a little below the saucer so the cow visually hangs in
	# the beam rather than clipping into the hull.
	var target := _saucer.global_position - Vector3(0.0, carry_gap, 0.0)
	var to_target := target - global_position

	# Spring-damper, heaviness as mass (a = F/m): heavy cows lift lazily and
	# swing wide, light ones zip up. Horizontal damping is low on purpose —
	# the pendulum wobble when the saucer moves IS the feature.
	var acc := Vector3(
		(swing_stiffness * to_target.x - swing_damping * _beam_vel.x) / _heaviness,
		(lift_stiffness * to_target.y - lift_damping * _beam_vel.y) / _heaviness,
		(swing_stiffness * to_target.z - swing_damping * _beam_vel.z) / _heaviness)
	_beam_vel = (_beam_vel + acc * delta).limit_length(beam_max_speed)
	global_position += _beam_vel * delta   # semi-implicit Euler: stable at 60 Hz

	# Helpless spinning + a little wobble for comedic effect. (unchanged)
	rotate_y(spin_speed * delta)
	rotation.z = lerp(rotation.z, 0.5, clampf(delta * 3.0, 0.0, 1.0))

	# Capture is a REST test — risen to the carry point and roughly centred —
	# not a raw distance test, so a settled cow can never dangle uncaptured.
	# The old capture sphere stays as a fallback for fast flybys.
	var horiz := Vector2(to_target.x, to_target.z).length()
	if (global_position.y >= target.y - capture_height and horiz <= capture_radius) \
			or global_position.distance_to(_saucer.global_position) <= capture_distance:
		captured.emit()
		queue_free()
```

- Release behavior (`Cow.gd:126-143` fall branch) is **unchanged** — the
  `move_toward` drop at `fall_speed` stays. Do not add gravity to grounded
  cows. Do not change `set_pulled`'s signature (soft-edge grab strength and
  audio coupling are explicitly deferred).
- Physics runs in `_physics_process` (fixed 60 Hz) — explicit/semi-implicit
  Euler at these constants is stable (verified analysis; `k/m ≤ 14/0.85 ≈ 16.5`,
  `ω·dt ≈ 0.07`).

### Verification (run the game — this phase is about feel)

- [ ] Grab a cow: it accelerates upward, settles just under the hull, gets
      captured — **every** cow, light and heavy, captures; nothing dangles.
- [ ] Fly horizontally while beaming: the cow trails behind and swings like a
      pendulum, then settles under the saucer when you stop.
- [ ] Release mid-lift (let go of the beam): the cow falls and lands as before.
- [ ] Beam from max altitude (raise with Z toward 90 m): the lift is long but
      capped-speed, not ballistic; capture still triggers.
- [ ] Rapid re-grab (beam off/on) doesn't inherit stale velocity.
- [ ] Startled moo + bell clonk still fire on grab; HUD tally + respawn still
      work (the `captured` wiring in World is untouched).
- [ ] Grep guards: no `pull_rise`/`pull_lateral` references remain anywhere.

---

## Phase 4 — Cache the saucer reference (Farmer, Audio, Minimap)

**Problem:** per-frame linear group scans that never change their answer —
`Farmer._physics_process` (`Farmer.gd:57`, ×6 farmers/physics frame),
`Audio._fill_whistle` (`Audio.gd:110`, every frame), `Audio._tick_birds`
(`Audio.gd:93`, on chirp), `Minimap._draw` saucer lookup (`Minimap.gd:44`).
World already owns `_saucer` and already injects references (the
`ground_sampler` pattern) — use it.

- `Farmer.gd`: add `var saucer: Saucer = null` next to `ground_sampler`.
  `_physics_process` drops the lookup; its guard becomes
  `if saucer == null or not is_instance_valid(saucer): return`. The rest of
  the function (and `_fire`, which already takes the reference as a
  parameter) is unchanged. World injects in `_spawn_one_farmer`
  (`World.gd:343-349`): `farmer.saucer = _saucer` — farmers spawn after the
  saucer (`_ready` order), so `_saucer` is live.
- `Audio.gd`: add `var saucer: Saucer = null`. `_fill_whistle` and
  `_tick_birds` use it with the same null guards they have today (whistle
  falls back to the idle 520 Hz when null — preserve that). Audio is built
  *before* the saucer, so inject from `World._build_saucer`
  (`World.gd:393-403`), after `_saucer` is created: `_audio.saucer = _saucer`.
- `Minimap.gd`: add `var saucer: Saucer = null`, injected in `World._build_ui`
  alongside the Phase 1 `terrain` injection; `_draw` keeps its existing
  early-return-if-null. The cow/farmer **group iterations stay** — their
  membership genuinely changes (capture/respawn), and a snapshot list would
  go stale.

### Verification

- [ ] Farmers still track, aim, and fire only while the beam is active in
      range; hit ding + recoil still work.
- [ ] Whistle still pitches up while beaming; birds still chirp around the
      saucer.
- [ ] Minimap unchanged.
- [ ] Grep guard: `get_first_node_in_group("saucer")` → 0 hits in
      `Farmer.gd`, `Audio.gd`, `Minimap.gd`.

---

## Phase 5 — Small wins

Three independent micro-fixes; all behavior-preserving.

1. **`Terrain._refresh_desired` O(n²) queue scan** (`Terrain.gd:196-200`):
   before the double loop, build a local set —
   `var queued := {}` / `for c in _build_queue: queued[c] = true` — and test
   `queued.has(c)` instead of `_build_queue.has(c)`. A local dict (rebuilt per
   call) is deliberate: `_refresh_desired` runs only on chunk-boundary
   crossings, and a persistent mirror of the queue is a desync bug waiting to
   happen. Everything else (filter, sort) stays.

2. **HUD rebuilds a static string every frame** (`World.gd:67-72, 462-465`):
   split the label. The static controls help ("WASD move … Esc free the
   mouse") becomes its own `Label` created once in `_build_ui`, positioned so
   the combined block looks identical. The dynamic label keeps
   "Cows abducted / Hits taken / Time". Add `var _last_hud_second := -1`; in
   `_process`, call `_update_hud()` only when `int(_elapsed) != _last_hud_second`
   (update the field inside `_update_hud`). Keep the direct `_update_hud()`
   calls in `_on_cow_captured` (`World.gd:322-325`) and `_on_saucer_hit`
   (`World.gd:329-331`) so counters refresh instantly.

3. **Farmer bullet tween vs. freed saucer** (`Farmer.gd:145-147`): the tween
   holds `saucer` for the bullet's whole flight. Replace
   `tw.tween_callback(saucer.register_hit.bind(global_position))` with a
   guarded lambda, capturing the muzzle-time position to preserve today's
   bind-at-spawn semantics:

```gdscript
	if hit:
		# Jolt the saucer at the instant of impact, not when the trigger is
		# pulled — and only if it still exists by then.
		var shot_from := global_position
		tw.tween_callback(func() -> void:
			if is_instance_valid(saucer):
				saucer.register_hit(shot_from))
```

### Verification

- [ ] World streams identically when flying across chunk borders (item 1).
- [ ] HUD looks pixel-identical; timer ticks once a second; abduction/hit
      counts update immediately (item 2).
- [ ] Farmer hits still ding + recoil at bullet impact time (item 3).

---

## Phase 6 — Final verification & docs

1. **Full play pass** (one session, Godot 4.7): fly several chunk radii in one
   direction and back (determinism + seams + minimap trees), abduct ≥5 cows of
   visibly different sizes (capture reliability + swing feel), take farmer
   fire (ding/recoil/HUD), raise altitude to max and beam (speed cap), idle
   near water and a chalet (fences, visuals). Watch the FPS counter and note
   the improvement vs. baseline if a baseline number exists.
2. **Grep sweep** (all must hold):
   - `add_to_group("trees")`, `get_nodes_in_group("trees")` → 0 hits.
   - `get_first_node_in_group("saucer")` → 0 hits in Farmer/Audio/Minimap.
   - `pull_rise`, `pull_lateral` → 0 hits.
   - No global `randf`/`randi` in Terrain chunk-generation code paths.
   - `_build_queue.has` → 0 hits.
3. **Update `CLAUDE.md`** to match reality: the Integration section's
   `"trees"` group bullet (trees are now MultiMesh instances; the minimap
   reads positions from `Terrain.get_tree_position_chunks()` via an injected
   reference), and the Files table row for `Terrain.gd` (mention MultiMesh
   scatter) and `Cow.gd` (spring-damper beam ride). Keep edits minimal and in
   the file's existing voice.
4. Do **not** run `deploy.sh` (hardcoded commit message); commit normally if
   asked.

---

## Execution notes

- **Order matters:** Phase 1 → 2 → 3 → 4 → 5 → 6. Phases 1–2 are both inside
  `Terrain.gd`; doing MultiMesh first means the grid change lands on already-
  reorganized scatter code rather than the other way around.
- **Model choice:** Phases 2, 4, 5 are mechanical given the line references —
  Sonnet 5 is enough. Phases 1 and 3 involve transform composition and feel
  tuning — Opus 4.8 recommended (Sonnet 5 workable if it follows the sketches
  strictly and transcribes dimensions rather than inventing them).
- **The one blessed visual deviation** is Phase 2's normal spacing. Anything
  else that looks different is a bug in the port — fix it, don't rationalize it.
