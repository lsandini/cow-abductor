# Clouds — design notes & next steps

Working notes for the cloud feature. Picks up where we left off (2026-06-29).

## Where it stands now

**Nothing cloud-related is in the code right now** — both attempts below were
prototyped, judged, and reverted. Tomorrow we start fresh from these notes.

### Attempt B (reverted): real 3D puffs in `scripts/World.gd`
This is the one to rebuild from (with the Option-1 improvements below). What it did:

- `_build_clouds()` scattered `cloud_count` (~26) clusters across a disc high
  over the saucer (`cloud_height_min/max` ≈ 115–190 m, `cloud_field_radius` ≈ 540).
- `_make_cloud()` built each cluster from 5–9 overlapping, flattened white
  spheres (one shared unit-sphere mesh, scaled per puff). Soft matte-white
  material with a little emission; puffs didn't cast shadows.
- `_drift_clouds()` (called from `_process`) slid them on `cloud_wind` (~7,0,3 m/s)
  each frame and wrapped any that drifted too far back around the player (same
  idea as the cow-herd recycling), so the sky never emptied.
- Exports for tuning: `cloud_count`, `cloud_height_min/max`, `cloud_field_radius`,
  `cloud_wind`.

**Verdict:** no line/seam artifacts (unlike the sky-shader attempt), and the
forms/parallax were nice — but they read as **"drifting marshmallows"**: too
solid, too uniform, too fast. Reverted pending the improvements below.

### Attempt A (abandoned — don't revisit)
Painting clouds in the sky shader (`_make_sky_material`) by projecting the view
ray onto a virtual plane and sampling noise. **Always aliases** at grazing
angles: the projection stretches the noise and any coverage threshold turns grid
structure into hard streaks/lines across the sky. Tried value noise → quintic
smoothing → gradient (Perlin) noise + per-octave domain rotation; each reduced
but never eliminated the lines. Conclusion: a flat-plane projection on the dome
is the wrong tool. Use real geometry.

## Why the current puffs look like marshmallows
1. **Hard, opaque silhouettes.** Real clouds fade to nothing at the edges; ours
   have a crisp white outline against the sky. ~80% of the candy look.
2. **Uniform brightness.** Flat emissive white = one value everywhere, no density
   falloff, so it reads as a smooth surface, not vapor.
3. **Symmetric rounded blobs.** Cumulus have a flat base and a lumpy cauliflower
   top. Equal stacked spheres read as bubbly/balloon-y.

Drift speed matters less than edges + shading.

## Alternative directions (increasing effort / payoff)

**1. Soft-edge translucent shells — smallest change, best ratio.**
Keep the 3D sphere clusters, but a custom shader on the puffs with a
**fresnel/rim alpha fade** (silhouette edges go transparent, cores stay dense) +
**two-tone shading** (bright sunlit tops, cooler blue-grey undersides) + **flat
bottoms**. Keeps the honest 3D parallax, kills the marshmallow read. Directly
uses the "transparency + slower drift" instinct. Tradeoff: some transparency
sorting between overlapping puffs.

**2. Soft sprite/particle puffs — the classic stylized-game cloud.**
Each cloud = a cluster of camera-facing quads with a soft radial gradient
(generated procedurally, no assets). Overlapping soft sprites build density
naturally: dense core, wispy fringe. Looks genuinely fluffy. Tradeoff: billboards
can feel flat if you fly around/under them (we mostly look up, so fine).

**3. True volumetric via Godot `FogVolume` — the "wow" option.**
A few `FogVolume` boxes high up with a 3D-noise density material; the engine
raymarches them into soft, light-scattering clouds. Drift by animating the noise
offset. No hard edges ever, reacts to the sun. Tradeoff: heaviest (volumetric
pass) and most tuning to avoid washed-out haze — trivial for the 2080 Ti.

**4. Stylized flat "card" clouds — Wind Waker / cartoon route.**
Procedurally-shaped flat silhouettes with soft alpha and a subtle 2-tone. Leans
into cartoon charm (fits the cows-with-eyes / Swiss-chalet tone) instead of
chasing realism. Cheap. Tradeoff: deliberately flat.

## Cheap tweaks that help any approach
- **Slower drift** (~2–3 m/s, not 7) + a faint vertical bob — floating, not commuting.
- **Per-puff opacity variation** — dense cores, wispy outer puffs.
- **Flat-bottomed clusters** — instantly reads as "cloud," not "ball."
- **Size/type variety** — mix big cumulus, little wisps, a flat stratus streak or two.
- **Soft tonal gradient** — warm near the sun, blue-grey in shade.

## Recommendation / decision for tomorrow
Two finalists by vibe:
- **Stylized & cohesive with the game's tone → Option 1** (translucent soft-edge
  shells + flat bottoms + slower drift). Smallest leap from today, low risk,
  likely enough to reach "yes, that's a cloud."
- **Prettiest / most atmospheric → Option 3** (`FogVolume` volumetric).

Plan: **start with Option 1**; keep Option 3 in the back pocket if we want
photoreal softness.

## Verifying changes (handy for tomorrow)
Godot binary is at `G:\Downloads\Godot_v4.7-stable_win64\Godot_v4.7-stable_win64_console.exe`.
We verify visually with a throwaway harness scene that loads `Main.tscn`, drops a
camera at chosen angles, saves PNG screenshots to the scratchpad, and quits —
then read the PNGs. (Used this all session for terrain seams, the cow, and these
clouds.) Remember to delete the temp `.gd`/`.tscn`/`.uid` afterward.
