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

| File | Role |
| --- | --- |
| `scenes/Main.tscn` | Empty entry scene carrying `World.gd`. |
| `scripts/World.gd` | Builds the sky/fog, ground, lighting, props, saucer and UI. Registers the input actions. |
| `scripts/Saucer.gd` | Flight, orbit camera and tractor beam. |
| `scripts/Cow.gd` | Cow wandering AI + getting abducted. |
| `scripts/Minimap.gd` | The bottom-right radar. |

Handy things to tweak live in the **Inspector** (or at the top of each script):
saucer `move_speed` / `fly_height` / `beam_radius`, and World `cow_count` /
`tree_count` / `fog_density` / `area_half`.
