# CLAUDE.md

Guidance for working in this repository.

## What this is

**Cow Abductor** — a relaxed Godot 4.7 sandbox: pilot a flying saucer over an
endless procedural pasture and beam up cows. No win/lose conditions.

Everything is generated **procedurally from code** — there are no imported art,
mesh, texture, or audio assets. `scenes/Main.tscn` is an essentially empty node
carrying `scripts/World.gd`; that script builds the entire game at runtime.

## Running & tooling

- **Run:** open the project in **Godot 4.7** and press **F5** (main scene is
  `scenes/Main.tscn`). Headless/CI: `godot --path . --headless` (no Godot binary
  is bundled or on PATH in this environment).
- **There are no tests, linters, or a build step.** Verification is by running
  the game and observing behavior. There is no way to type-check or compile the
  GDScript outside the editor — read carefully instead.
- **Export:** a single "Windows Desktop" preset (`export_presets.cfg`) outputs
  `../cow-abductor.exe`.
- **Recording:** `project.godot` sets `movie_writer/movie_file=res://recording.avi`;
  launching with Movie Maker mode records gameplay to that file.
- **Deploy:** `deploy.sh` is just `git add . && git commit && git push` to
  `origin main` (with a hardcoded commit message — update it before running).

## Architecture

`World.gd` (`extends Node3D`, on the Main scene) is the assembler. Its `_ready()`
**call order encodes the dependency graph** — e.g. terrain must exist before the
saucer/cows can sample ground height, and audio before cows (they take a shared
moo sample). Reorder with care.

### Terrain is the single source of truth

`scripts/Terrain.gd` owns the world's SHAPE and CHARACTER and is the authority
for ground height. `get_height(x, z)` and `get_biome(x, z)` are sampled by the
ground mesh, props, cows, and the saucer — so nothing ever floats or sinks. The
height sampler is handed to other nodes as a `Callable(_terrain, "get_height")`
(see `World._spawn_one_cow` / `_build_saucer`), **not** a direct reference.

The world is genuinely infinite via **chunk streaming** (a square of chunks kept
loaded around the saucer, built/freed a couple per frame). Two invariants make
it work — preserve both when touching chunk or prop code:

1. **Deterministic per-chunk scatter.** Props (trees/rocks/bushes/chalets) are
   placed with an RNG seeded from the chunk coordinate (`_chunk_seed`), so flying
   away and back regenerates identical scenery. Never use global `randf()` in
   chunk generation.
2. **World-space chunk meshes.** Chunk vertices are built in world coordinates
   (chunk node sits at the origin) so adjacent chunks share identical edge
   vertices and normals — seamless, no cracks.

Distance fog (in `World`) + the matching `HORIZON_COLOR` hide the streaming edge;
the sky is a custom shader (`World._make_sky_material`) drawing a procedural
mountain backdrop and the sun disc. The sun direction is pushed into the sky
shader as the `sun_dir` uniform from the actual light's transform — it does *not*
rely on the renderer's `LIGHT0`.

### Integration is group-based, not reference-based

Nodes find each other through groups rather than holding references:

- `"saucer"` — the player. The minimap and audio look it up via
  `get_first_node_in_group("saucer")`.
- `"cows"` — every cow. The saucer iterates this group each physics frame and
  calls `cow.set_pulled(grabbed, self)`; a grabbed cow then rides its own beam.
- `"trees"` — used by the minimap (and historically birdsong).

The cows form a **follow-the-player herd**: `World._recycle_cows()` relocates any
cow that drifts past `cow_despawn_radius` to a ring around the saucer, so the
pasture is never empty no matter how far you fly.

### Files

| File | Role |
| --- | --- |
| `scripts/World.gd` | Assembles sky/fog, sun, lighting, audio, saucer, herd, UI; registers input; sky shader; cow recycling. |
| `scripts/Terrain.gd` | Infinite streaming world: height/biome noise, chunk build/free, props, water. The height authority. |
| `scripts/Saucer.gd` | Flight, orbit camera (mouse look), banking/yaw-to-travel, tractor beam. |
| `scripts/Cow.gd` | Wander AI, slope orientation, water avoidance, getting abducted (`captured` signal). |
| `scripts/Minimap.gd` | Bottom-right radar; saucer-relative, redrawn every frame. |
| `scripts/Audio.gd` | Procedural audio: live-synthesized UFO whistle + baked moo/bird samples. |

### Audio

`Audio.gd` mixes two techniques: the UFO whistle is **live-synthesized** every
frame into an `AudioStreamGenerator` (so it can react to the beam), while the moo
and bird chirps are **baked once** into `AudioStreamWAV` buffers from raw PCM.
Cows share the single baked moo sample.
