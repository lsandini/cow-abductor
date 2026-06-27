# Cow Abductor 🛸🐄

A relaxed little Godot 4.7 sandbox: pilot a flying saucer over an endless
pasture and beam up cows. No score to beat, no timer — just vibes.

## Controls

| Action | Key |
| --- | --- |
| Move | `W` `A` `S` `D` (relative to where you're looking) |
| Look around | Mouse |
| Tractor beam | `Space` or **Left mouse button** (hold) |
| Free the mouse cursor | `Esc` (press again to recapture) |

Hover over a cow, hold the beam, and it floats up into the saucer. The minimap
in the bottom-right shows nearby cows (white), trees (green), your heading
(yellow arrow) and the beam's reach (cyan ring) while firing.

## Running

Open the project in **Godot 4.7** and press **Play** (F5). The main scene is
`scenes/Main.tscn`.

## How it's built

Everything is generated procedurally from mesh primitives in code — there are
no imported art assets — so the project is tiny and easy to tinker with.

The world is **genuinely endless**: the ground is divided into square chunks
that are built and freed a couple at a time as you fly, all sampled from one
infinite noise field, so there is no edge to reach. Rolling pasture gives way to
occasional snow-capped mountains, lush green and dry savanna biomes, and ponds
in the valleys. Trees, rocks and bushes are scattered per-chunk from a seeded
RNG, so flying away and back finds the same scenery in the same place. The herd
of cows follows you, drifting back into view whenever it strays too far.

| File | Role |
| --- | --- |
| `scenes/Main.tscn` | Empty entry scene carrying `World.gd`. |
| `scripts/World.gd` | Assembles the sky/fog, lighting, audio, saucer, herd and UI. Registers the input actions. |
| `scripts/Terrain.gd` | The infinite world: height/biome noise, chunk streaming, props and water. |
| `scripts/Saucer.gd` | Flight, orbit camera and tractor beam. |
| `scripts/Cow.gd` | Cow wandering AI + getting abducted. |
| `scripts/Minimap.gd` | The bottom-right radar. |
| `scripts/Audio.gd` | Procedural sound: live UFO whistle + baked moo, bell and bird samples. |

Handy things to tweak live in the **Inspector** (or at the top of each script):
saucer `move_speed` / `fly_height` / `beam_radius`, World `cow_count` /
`fog_density`, and Terrain `chunk_size` / `view_radius` / `mountain_amplitude` /
`biome_frequency` / `water_level`.
