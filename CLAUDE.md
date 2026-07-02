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

- `"saucer"` — the player. Looked up via `get_first_node_in_group("saucer")` by
  the compass/altitude readouts; the minimap, audio and farmers instead receive
  the saucer by injection from `World` (cached — it's a session singleton — to
  avoid a per-frame group scan).
- `"cows"` — every cow. The saucer iterates this group each physics frame and
  calls `cow.set_pulled(grabbed, self)`; a grabbed cow then rides its own beam.
- `"farmers"` — herd guards. Each farmer, while the beam is firing within range,
  shoots at the (injected) saucer: a harmless recoil tilt + a metallic ding
  (`Saucer.register_hit`), never any damage.

Trees are no longer scene nodes (see Terrain below), so there is no `"trees"`
group: the minimap reads their world positions from
`Terrain.get_tree_position_chunks()` via an injected `terrain` reference.

The cows form a **follow-the-player herd**: `World._recycle_cows()` relocates any
cow that drifts past `cow_despawn_radius` to a ring around the saucer, so the
pasture is never empty no matter how far you fly. Farmers follow the same way
(`World._recycle_farmers`), but are relocated *beside a cow* so they always guard
the herd.

### Files

| File | Role |
| --- | --- |
| `scripts/World.gd` | Assembles sky/fog, sun, lighting, audio, saucer, herd, UI; registers input; sky shader; cow recycling. |
| `scripts/Terrain.gd` | Infinite streaming world: height/biome noise, chunk build/free, props, water. The height authority. Props (trees/rocks/bushes/fences) render as per-chunk **MultiMesh** instances off canonical shared meshes; chunk mesh normals come from one pre-sampled height grid. |
| `scripts/Saucer.gd` | Flight, orbit camera (mouse look), banking/yaw-to-travel, tractor beam; `register_hit` recoil + ding. |
| `scripts/Cow.gd` | Wander AI, slope orientation, water avoidance, getting abducted — a **spring-damper** beam ride (vertical lift + pendulum swing) ending in the `captured` signal. |
| `scripts/Farmer.gd` | Herd guard: tracks the saucer, fires an old rifle (muzzle flash + slow visible bullet) while it beams nearby cows. |
| `scripts/Minimap.gd` | Bottom-right radar; saucer-relative, redrawn every frame. |
| `scripts/HeadingTape.gd` | Top-of-screen semitransparent compass ribbon; reads heading from the saucer's planar facing. |
| `scripts/FlightReadouts.gd` | Light HUD speed (left) + altitude (right) readouts; reads `get_speed()` / `get_altitude()` off the saucer. |
| `scripts/Audio.gd` | Procedural audio: live-synthesized UFO whistle + baked moo/bell/bird/ding samples. |
| `scripts/SoundLab.gd` | Standalone synth-prototyping bench (`scenes/SoundLab.tscn`) — **not part of the game**; used to tune moo/bell recipes before baking them into `Audio.gd`. |

### Audio

`Audio.gd` mixes two techniques: the UFO whistle is **live-synthesized** every
frame into an `AudioStreamGenerator` (so it can react to the beam), while the moo,
cowbell, bird chirps and the farmer-hit ding are **baked once** into
`AudioStreamWAV` buffers from raw PCM. Cows share the single baked moo sample;
only some cows wear a bell (the shared baked `bell_stream`); the saucer holds the
shared `ding_stream` and plays it from `register_hit`.

New baked sounds are prototyped in `SoundLab.gd` (run `scenes/SoundLab.tscn`
on its own), which auditions code-synthesised recipes through the same 3D path a
cow uses; the chosen recipe is then locked into `Audio.gd`.
