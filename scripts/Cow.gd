
# =============================================================================
# Cow.gd  (class_name Cow)
#
# A single cow. It has two jobs:
#   1. WANDER: lazily graze and walk around the pasture on its own.
#   2. GET ABDUCTED: when the saucer's beam is over it, rise up, spin, and
#      vanish into the saucer (emitting `captured` so the World can score it).
#
# If the beam moves away before the cow reaches the saucer, the cow gently
# falls back down and resumes wandering. The cow's body is built from
# primitives in _ready(), so no scene file is needed.
# =============================================================================
class_name Cow
extends Node3D

# Emitted the moment the cow is pulled fully into the saucer (just before it is
# freed). The World listens to this to update the score and respawn a cow.
signal captured

# --- Wandering tuning --------------------------------------------------------
@export var wander_speed: float = 2.2      # walking speed (m/s)
@export var turn_speed: float = 6.0        # how quickly it rotates to face travel
# Below this terrain height the ground is flooded; the cow turns away rather than
# wade in. Set by World from the Terrain (defaults to "no water").
var water_level: float = -1000.0

# --- Abduction tuning --------------------------------------------------------
@export var pull_rise: float = 6.0         # vertical lift speed inside the beam
@export var pull_lateral: float = 4.0      # how fast it centres under the saucer
@export var spin_speed: float = 8.0        # whirl while being lifted (rad/s)
@export var fall_speed: float = 12.0       # drop speed if the beam lets go
@export var capture_distance: float = 1.6  # close enough to the saucer = captured

# Beam state, refreshed every frame by the saucer via set_pulled().
var _pulled: bool = false
var _saucer: Node3D = null

# Supplied by the World: ground_sampler.call(x, z) -> terrain height. Lets the
# cow walk over hills and valleys and land back on the slope after a near-miss.
var ground_sampler: Callable

# Supplied by the World: a shared, baked moo sample. If set, the cow gets its
# own 3D audio player and moos occasionally (and panics when beamed).
var moo_stream: AudioStream
var _moo_player: AudioStreamPlayer3D
var _moo_timer: float = 0.0

# Supplied by the World: a shared, baked alpine cowbell. Only some cows end up
# wearing one; a belled cow clonks rhythmically while it walks (not while it
# stands grazing), each with its own fixed base pitch so the herd sounds varied.
var bell_stream: AudioStream
var _bell_player: AudioStreamPlayer3D
var _bell_timer: float = 0.0
var _bell_pitch: float = 1.0   # this bell's "note" (per-cow, constant)

# Wander state machine.
var _grazing: bool = true
var _heading: Vector3 = Vector3.FORWARD
var _wander_timer: float = 0.0
var _size: float = 1.0   # this cow's uniform scale (re-applied when we set the basis)


func _ready() -> void:
	# A little per-cow size variation so the herd doesn't look cloned. Scaling
	# about the origin keeps the hooves planted on the ground (lowest point y=0).
	_size = randf_range(0.88, 1.12)
	scale = Vector3.ONE * _size
	_build_body()
	_build_audio()
	_pick_new_action()
	_wander_timer = randf() * 3.0   # stagger cows so they don't all turn in sync


# Give the cow a 3D voice if the World provided a moo sample.
func _build_audio() -> void:
	if moo_stream == null:
		return
	_moo_player = AudioStreamPlayer3D.new()
	_moo_player.stream = moo_stream
	_moo_player.volume_db = -3.0
	_moo_player.max_distance = 80.0
	_moo_player.unit_size = 12.0
	_moo_player.position.y = 1.1   # roughly at the cow's head
	add_child(_moo_player)
	_moo_timer = randf_range(4.0, 18.0)   # first moo is staggered

	# Roughly two in five cows wear a bell, each tuned to its own note.
	if bell_stream != null and randf() < 0.4:
		_bell_pitch = randf_range(0.8, 1.25)
		_bell_player = AudioStreamPlayer3D.new()
		_bell_player.stream = bell_stream
		_bell_player.volume_db = -7.0          # frequent sound, kept gentle
		_bell_player.max_distance = 80.0
		_bell_player.unit_size = 12.0
		_bell_player.position.y = 1.0          # around the neck
		add_child(_bell_player)
		_bell_timer = randf_range(0.0, 0.6)


# Called by the saucer each frame: are we in the beam, and which saucer is it?
func set_pulled(pulled: bool, saucer: Node3D) -> void:
	if pulled and not _pulled:
		_moo(true)   # just got grabbed -> a startled, higher-pitched moo
		_clonk()     # and a jolt of the bell as it's yanked off its feet
	_pulled = pulled
	_saucer = saucer


# Play the moo. `panic` raises the pitch for the abduction yelp.
func _moo(panic: bool) -> void:
	if _moo_player == null:
		return
	_moo_player.pitch_scale = randf_range(1.3, 1.6) if panic else randf_range(0.85, 1.12)
	_moo_player.play()


# Strike the bell once, at this cow's fixed note with a touch of per-strike wobble.
func _clonk() -> void:
	if _bell_player == null:
		return
	_bell_player.pitch_scale = _bell_pitch * randf_range(0.97, 1.03)
	_bell_player.play()


func _physics_process(delta: float) -> void:
	if _pulled and _saucer != null:
		_ride_beam(delta)
		return

	var ground_y := _ground_y()
	if position.y > ground_y + 0.05:
		# Not in the beam but still airborne -> fall back down onto the terrain,
		# already easing toward the slope so it lands aligned.
		position.y = move_toward(position.y, ground_y, fall_speed * delta)
		_orient_on_slope(delta)
	else:
		_wander(delta)
		position.y = _ground_y()      # hug the terrain as it grazes / walks
		_orient_on_slope(delta)       # and tilt to match the slope underfoot
		_tick_moo(delta)              # occasional contented moo
		_tick_bell(delta)             # bell clonks in time with walking


# Count down to the next idle moo while grazing/walking.
func _tick_moo(delta: float) -> void:
	if _moo_player == null:
		return
	_moo_timer -= delta
	if _moo_timer <= 0.0:
		_moo(false)
		_moo_timer = randf_range(12.0, 28.0)


# Clonk the bell on a footstep-ish cadence, but only while actually walking —
# a grazing cow stands still, so its bell falls silent.
func _tick_bell(delta: float) -> void:
	if _bell_player == null or _grazing:
		return
	_bell_timer -= delta
	if _bell_timer <= 0.0:
		_clonk()
		_bell_timer = randf_range(0.45, 0.8)


# Terrain height under the cow right now (falls back to 0 if no sampler set).
func _ground_y() -> float:
	if ground_sampler.is_valid():
		return ground_sampler.call(position.x, position.z)
	return 0.0


# Approximate the ground's upward normal under the cow via central differences
# on the height sampler. Used to tilt the cow onto the slope.
func _ground_normal() -> Vector3:
	if not ground_sampler.is_valid():
		return Vector3.UP
	var e := 1.0
	var x := position.x
	var z := position.z
	var hl: float = ground_sampler.call(x - e, z)
	var hr: float = ground_sampler.call(x + e, z)
	var hd: float = ground_sampler.call(x, z - e)
	var hu: float = ground_sampler.call(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


# Smoothly orient the cow so its "up" matches the slope normal while it keeps
# facing its heading. We rebuild the rotation basis (up = normal, forward =
# heading flattened onto the slope) and slerp toward it, then re-apply the cow's
# uniform scale (setting basis directly would otherwise wipe it out).
func _orient_on_slope(delta: float) -> void:
	var n := _ground_normal()

	# Project the heading onto the slope plane so "forward" lies along the ground.
	var fwd := _heading - n * _heading.dot(n)
	if fwd.length() < 0.001:
		return
	fwd = fwd.normalized()

	var right := n.cross(fwd).normalized()      # right-handed: x = up x forward
	var target := Basis(right, n, fwd)          # columns map local X/Y/Z axes
	var current := transform.basis.orthonormalized()
	var blended := current.slerp(target, clampf(turn_speed * delta, 0.0, 1.0))
	transform.basis = blended.scaled(Vector3.ONE * _size)


# --- Being abducted ----------------------------------------------------------
func _ride_beam(delta: float) -> void:
	var target := _saucer.global_position

	# Slide horizontally toward the saucer's centre and rise toward it.
	global_position.x = lerp(global_position.x, target.x, clamp(pull_lateral * delta, 0.0, 1.0))
	global_position.z = lerp(global_position.z, target.z, clamp(pull_lateral * delta, 0.0, 1.0))
	global_position.y = move_toward(global_position.y, target.y, pull_rise * delta)

	# Helpless spinning + a little wobble for comedic effect.
	rotate_y(spin_speed * delta)
	rotation.z = lerp(rotation.z, 0.5, delta * 3.0)

	if global_position.distance_to(target) <= capture_distance:
		captured.emit()
		queue_free()


# --- Wandering ---------------------------------------------------------------
func _wander(delta: float) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_pick_new_action()

	if _grazing:
		return   # standing still, head down, eating grass

	# Step forward in the current heading. Facing/turning is handled by
	# _orient_on_slope, which also tilts the cow onto the terrain.
	var next := position + _heading * wander_speed * delta
	# If that step would walk into water, turn to a new heading and stay put this
	# frame rather than wading into a pond.
	if ground_sampler.is_valid() and ground_sampler.call(next.x, next.z) < water_level + 0.4:
		var angle := randf() * TAU
		_heading = Vector3(cos(angle), 0.0, sin(angle))
		return
	position = next


# Randomly decide whether to graze or stroll, and for how long.
func _pick_new_action() -> void:
	_grazing = randf() < 0.4
	_wander_timer = randf_range(2.0, 5.0)
	if not _grazing:
		var angle := randf() * TAU
		_heading = Vector3(cos(angle), 0.0, sin(angle))


# -----------------------------------------------------------------------------
# Visual construction.
#
# Built entirely from rounded primitives (capsules, spheres, cones) so the cow
# reads as a soft, cartoony animal rather than a stack of blocks — but it is
# still simple, low-part-count and clearly "game art".
#
# Convention: +Z is the cow's FORWARD (head end), -Z is the tail. The model's
# lowest point sits at y = 0 so the cow rests on the ground.
# -----------------------------------------------------------------------------
func _build_body() -> void:
	var coat := _solid_material(Color(0.94, 0.92, 0.88))   # creamy white coat
	var black := _solid_material(Color(0.12, 0.12, 0.13))  # spots, hooves
	var pink := _solid_material(Color(0.95, 0.62, 0.64))   # muzzle, ears, udder
	var horn := _solid_material(Color(0.85, 0.80, 0.68))   # pale horns

	# Barrel torso: a capsule laid horizontally along Z, slightly squashed.
	_add_part(_capsule(0.47, 1.7), coat, Vector3(0, 0.98, -0.05),
			Vector3(90, 0, 0), Vector3(1.05, 0.95, 1.0))

	# Spot patches: flattened spheres pressed into the coat so they bulge like
	# real markings instead of sitting flat. The squashed axis is the surface
	# normal, so each one hugs the rounded body.
	_add_part(_sphere(0.30), black, Vector3(0.40, 1.10, 0.20), Vector3.ZERO, Vector3(0.45, 1.1, 1.2))
	_add_part(_sphere(0.26), black, Vector3(-0.42, 0.95, -0.15), Vector3.ZERO, Vector3(0.45, 1.0, 1.0))
	_add_part(_sphere(0.24), black, Vector3(-0.10, 1.40, -0.30), Vector3.ZERO, Vector3(1.1, 0.45, 1.0))
	_add_part(_sphere(0.22), black, Vector3(0.30, 1.05, -0.55), Vector3.ZERO, Vector3(0.9, 0.9, 0.5))

	# Neck: a short capsule bridging the shoulders up to the head.
	_add_part(_capsule(0.27, 0.7), coat, Vector3(0, 1.12, 0.62), Vector3(58, 0, 0))

	# Head: an elongated sphere reaching forward.
	_add_part(_sphere(0.34), coat, Vector3(0, 1.34, 0.92), Vector3.ZERO, Vector3(0.88, 0.9, 1.1))

	# Muzzle: a soft pink snout at the very front.
	_add_part(_sphere(0.24), pink, Vector3(0, 1.22, 1.20), Vector3.ZERO, Vector3(1.0, 0.78, 0.7))

	# Eyes: little white eyeballs with dark pupils, set on the front of the face
	# just above the muzzle so the cow reads as friendly and wide-eyed.
	var eye_white := _solid_material(Color(0.97, 0.97, 0.95))
	for ex in [-0.165, 0.165]:
		_add_part(_sphere(0.09), eye_white, Vector3(ex, 1.47, 1.06), Vector3.ZERO, Vector3(0.9, 1.0, 0.7))
		_add_part(_sphere(0.05), black, Vector3(ex, 1.46, 1.15))

	# Ears: flattened spheres angled out from the sides of the head.
	_add_part(_sphere(0.14), coat, Vector3(0.30, 1.46, 0.86), Vector3(0, 0, -35), Vector3(1.5, 0.5, 0.9))
	_add_part(_sphere(0.14), coat, Vector3(-0.30, 1.46, 0.86), Vector3(0, 0, 35), Vector3(1.5, 0.5, 0.9))

	# Horns: little pale cones on top of the head, tilted outward.
	_add_part(_cone(0.06, 0.20), horn, Vector3(0.16, 1.62, 0.86), Vector3(0, 0, -25))
	_add_part(_cone(0.06, 0.20), horn, Vector3(-0.16, 1.62, 0.86), Vector3(0, 0, 25))

	# Four tapered legs, each capped with a dark hoof.
	for x in [-0.30, 0.30]:
		for z in [-0.45, 0.48]:
			_add_part(_cylinder(0.13, 0.09, 0.78), coat, Vector3(x, 0.42, z))
			_add_part(_cylinder(0.11, 0.11, 0.14), black, Vector3(x, 0.07, z))

	# Udder: a soft pink dome under the belly toward the back (flat side tucked up
	# into the belly, rounded side hanging down), finished with four little teats.
	_add_part(_dome(0.22), pink, Vector3(0, 0.62, -0.28), Vector3(180, 0, 0), Vector3(1.25, 1.0, 1.35))
	for tx in [-0.09, 0.09]:
		for tz in [-0.20, -0.36]:
			_add_part(_cylinder(0.028, 0.038, 0.13), pink, Vector3(tx, 0.45, tz))

	# Tail: a thin drooping cylinder off the rump with a dark tuft on the end.
	_add_part(_cylinder(0.05, 0.04, 0.6), coat, Vector3(0, 0.80, -0.92), Vector3(28, 0, 0))
	_add_part(_sphere(0.09), black, Vector3(0, 0.52, -1.08))


# --- Mesh + part helpers -----------------------------------------------------

# Add a mesh instance as a child with a full local transform.
func _add_part(mesh: Mesh, material: StandardMaterial3D, pos: Vector3,
		rot_deg: Vector3 = Vector3.ZERO, part_scale: Vector3 = Vector3.ONE) -> void:
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = material
	inst.position = pos
	inst.rotation_degrees = rot_deg
	inst.scale = part_scale
	add_child(inst)


func _capsule(radius: float, height: float) -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	return mesh


func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0   # a full sphere (not a half dome)
	return mesh


# A hemisphere (flat circle at the top, rounded below). Used for the udder.
func _dome(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius        # half as tall as a full sphere = a dome
	mesh.is_hemisphere = true
	return mesh


func _cylinder(top_radius: float, bottom_radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	return mesh


# A cone is just a cylinder whose top radius is zero.
func _cone(base_radius: float, height: float) -> CylinderMesh:
	return _cylinder(0.0, base_radius, height)


func _solid_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85   # soft, matte coat — no plastic shine
	return mat
