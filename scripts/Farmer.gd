# =============================================================================
# Farmer.gd  (class_name Farmer)
#
# An angry farmer who guards the herd. He stands in the pasture near the cows
# and, when the saucer's tractor beam fires within range of him, shoulders an
# old bolt-action rifle and shoots at you. The shots do NO damage — they just
# jolt the saucer with a brief recoil tilt and a metallic "ding" off the hull
# (see Saucer.register_hit). Each shot shows a muzzle flash and a tracer streak.
#
# Like the cows, the farmer:
#   - is built entirely from primitives in _ready() (no scene file), sized to
#     read as a human (~1.9 units tall) beside the cows and trees
#   - is relocated around the player by World when he drifts too far, so the
#     guarded pasture follows you (see World._recycle_farmers)
#   - finds the saucer through the "saucer" group rather than a held reference
#
# Convention: +Z is the farmer's FORWARD (the way he faces / aims). His lowest
# point sits at y = 0 so he rests on the ground.
# =============================================================================
class_name Farmer
extends Node3D

# Emitted once this farmer has fully disintegrated under the death ray (see fry()).
# The World listens so it can send in a replacement and keep the guard count steady.
signal fried

# --- Behaviour tuning --------------------------------------------------------
@export var fire_range: float = 55.0        # only tracks/shoots a saucer within this
@export var fire_interval_min: float = 1.2  # seconds between shots (randomised)...
@export var fire_interval_max: float = 2.4  # ...so the volley sounds irregular
@export var turn_speed: float = 4.0         # how briskly he swings to aim
@export var hit_chance: float = 0.8         # the rest of the shots whistle wide
# Deliberately slow & cartoonish so you can actually SEE the bullet fly (a real
# rifle round would be invisible). Pair it with the exaggerated bullet size below.
@export var bullet_speed: float = 45.0      # metres/second the projectile travels

# Supplied by the World: ground_sampler.call(x, z) -> terrain height, and the
# water level, so the World can stand him on dry ground (he never moves himself).
var ground_sampler: Callable
var water_level: float = -1000.0
# Supplied by the World: the player saucer (session singleton), cached so the
# farmer doesn't scan the "saucer" group every physics frame.
var saucer: Saucer = null

# The shoulder pivot that the arms + rifle hang from; pitched up to aim.
var _aim: Node3D
var _muzzle: MeshInstance3D                 # tip of the barrel (tracer origin)
var _cooldown: float = 0.0                  # time until he may fire again
var _dying: bool = false                    # true once fried: stop tracking/shooting
var _base_pos: Vector3                       # spot he's standing on, for the electrocution jitter

const SHOULDER_HEIGHT: float = 1.4          # local height of the aim pivot
const REST_AIM: float = 0.35                # rifle angle (rad) when lowered/idle


func _ready() -> void:
	# A little per-farmer size variation (people vary less than the cows do).
	# Scaling about the origin keeps the boots planted (lowest point y = 0).
	scale = Vector3.ONE * randf_range(0.95, 1.08)
	_build_body()
	_aim.rotation.x = REST_AIM
	_cooldown = randf_range(0.5, 2.0)         # stagger the first shots across farmers


func _physics_process(delta: float) -> void:
	if _dying:
		return   # being fried — no more tracking or shooting
	if saucer == null or not is_instance_valid(saucer):
		return

	var d := saucer.global_position - global_position
	var horizontal := Vector2(d.x, d.z)
	var dist := horizontal.length()

	if dist > fire_range:
		# Out of range: lower the rifle and stand down.
		_aim.rotation.x = lerp_angle(_aim.rotation.x, REST_AIM, clampf(turn_speed * delta, 0.0, 1.0))
		return

	# In range: track the saucer (yaw the body, pitch the rifle to its elevation).
	# Pitch is measured from the aim pivot's actual world height so it stays right
	# under the per-farmer scaling.
	var target_yaw := atan2(d.x, d.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, clampf(turn_speed * delta, 0.0, 1.0))
	var elev := atan2(saucer.global_position.y - _aim.global_position.y, maxf(dist, 0.001))
	_aim.rotation.x = lerp_angle(_aim.rotation.x, -elev, clampf(turn_speed * delta, 0.0, 1.0))

	# He only opens fire while the beam is active near him — i.e. when you are
	# actually trying to abduct one of his cows.
	_cooldown -= delta
	if saucer.beam_active and _cooldown <= 0.0:
		_fire(saucer)
		_cooldown = randf_range(fire_interval_min, fire_interval_max)


# -----------------------------------------------------------------------------
# Getting fried by the saucer's death ray: char black for a beat, then vanish in
# a quick puff of smoke and emit `fried` so the World sends in a replacement.
# -----------------------------------------------------------------------------
func fry() -> void:
	if _dying:
		return
	_dying = true
	remove_from_group("farmers")   # no longer a live guard: skip recycling / re-targeting
	_base_pos = position
	var tw := create_tween()
	# 1) Struck by cartoon lightning: strobe bright electric white/blue with a
	#    fizzing jitter, like he's being electrocuted on the spot.
	for i in 8:
		tw.tween_callback(_flash.bind(true))
		tw.tween_interval(0.05)
		tw.tween_callback(_flash.bind(false))
		tw.tween_interval(0.05)
	# 2) Burnt to a crisp: settle to solid black and smoulder for a beat.
	tw.tween_callback(_char_black)
	tw.tween_interval(0.7)
	# 3) Crumble away in a puff of smoke.
	tw.tween_callback(_disintegrate)


# One frame of the electrocution strobe: blinding white or electric blue, glowing
# and unshaded, with a small jitter around the spot he's standing on.
func _flash(bright: bool) -> void:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 1.0, 1.0) if bright else Color(0.55, 0.8, 1.0)
	m.emission_enabled = true
	m.emission = m.albedo_color
	m.emission_energy_multiplier = 4.0
	_override_all(self, m)
	position = _base_pos + Vector3(randf_range(-0.07, 0.07), 0.0, randf_range(-0.07, 0.07))


# Swap every body part to a burnt-black material and settle back onto his spot.
func _char_black() -> void:
	position = _base_pos
	var burnt := StandardMaterial3D.new()
	burnt.albedo_color = Color(0.03, 0.03, 0.03)
	burnt.roughness = 1.0
	_override_all(self, burnt)


func _override_all(n: Node, mat: Material) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).material_override = mat
		_override_all(c, mat)


# A puff of smoke, then the charred body crumbles to nothing and is freed.
func _disintegrate() -> void:
	_spawn_smoke()
	var tw := create_tween()
	tw.tween_property(self, "scale", scale * 0.02, 0.3).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		fried.emit()
		queue_free())


# A little cloud of grey puffs that balloon, rise and fade — spawned into the
# World (our parent) so they outlive the farmer as it frees itself.
func _spawn_smoke() -> void:
	var base := global_position
	for i in 7:
		var puff := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = randf_range(0.35, 0.6)
		m.height = m.radius * 2.0
		puff.mesh = m
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.30, 0.29, 0.28, 0.7)
		mat.roughness = 1.0
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		puff.material_override = mat
		get_parent().add_child(puff)
		puff.global_position = base + Vector3(
			randf_range(-0.5, 0.5), randf_range(0.4, 1.5), randf_range(-0.5, 0.5))
		var life := randf_range(0.5, 0.9)
		var tw := puff.create_tween()
		tw.set_parallel(true)
		tw.tween_property(puff, "scale", Vector3.ONE * randf_range(2.0, 3.2), life)
		tw.tween_property(puff, "global_position:y", puff.global_position.y + randf_range(1.5, 2.6), life)
		tw.tween_property(mat, "albedo_color:a", 0.0, life)
		tw.chain().tween_callback(puff.queue_free)


# Take a shot: muzzle flash + a slow, visible bullet. On a hit the bullet jolts
# the saucer (the ding + recoil) the moment it arrives; a miss sails wide.
func _fire(saucer: Saucer) -> void:
	var muzzle_pos := _muzzle.global_position
	var hit := randf() < hit_chance
	var aim_point := saucer.global_position
	if not hit:
		# A miss: aim wide so the bullet sails past the saucer.
		aim_point += Vector3(randf_range(-6.0, 6.0), randf_range(-2.0, 7.0), randf_range(-6.0, 6.0))

	_spawn_muzzle_flash(muzzle_pos)
	_spawn_bullet(muzzle_pos, aim_point, hit, saucer)


# -----------------------------------------------------------------------------
# Shot visuals. Both are spawned into the World (our parent) in WORLD space so
# they stay put while the farmer keeps tracking, and self-destruct via a tween.
# -----------------------------------------------------------------------------
func _spawn_muzzle_flash(at: Vector3) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.22
	mesh.height = 0.44
	var mat := _glow_material(Color(1.0, 0.85, 0.45))
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	get_parent().add_child(inst)
	inst.global_position = at
	var tw := inst.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.08)
	tw.tween_callback(inst.queue_free)


func _spawn_bullet(from: Vector3, to: Vector3, hit: bool, saucer: Saucer) -> void:
	var distance := from.distance_to(to)
	if distance < 0.01:
		return
	# An exaggerated brass slug — chunky enough to follow with the eye.
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.16
	mesh.height = 0.7
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.6, 0.2)   # brass
	mat.metallic = 0.8
	mat.roughness = 0.3
	mat.emission_enabled = true                # a little glow so it reads in shadow
	mat.emission = Color(0.9, 0.7, 0.3)
	mat.emission_energy_multiplier = 0.4
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	get_parent().add_child(inst)
	# A capsule's long axis is local +Y, so point it along the line of flight and
	# start it at the muzzle; the tween then slides it to the target.
	var dir := (to - from).normalized()
	inst.global_transform = Transform3D(_basis_from_y(dir), from)
	var travel := distance / bullet_speed
	var tw := inst.create_tween()
	tw.tween_property(inst, "global_position", to, travel)
	if hit:
		# Jolt the saucer at the instant of impact, not when the trigger is pulled —
		# and only if it still exists by the time the slug arrives.
		var shot_from := global_position
		tw.tween_callback(func() -> void:
			if is_instance_valid(saucer):
				saucer.register_hit(shot_from))
	tw.tween_callback(inst.queue_free)


# An additive, unshaded glow material (reads as light, not a solid object).
func _glow_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


# An orthonormal basis whose +Y axis points along `y` (for orienting cylinders).
func _basis_from_y(y: Vector3) -> Basis:
	var up := y.normalized()
	var ref_axis := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.99 else Vector3.FORWARD
	var x := ref_axis.cross(up).normalized()
	var z := x.cross(up).normalized()
	return Basis(x, up, z)


# -----------------------------------------------------------------------------
# Visual construction: a stocky farmer in denim overalls and a straw hat,
# shouldering a long old rifle. Built from rounded primitives like the cow, and
# proportioned to ~1.9 units tall so he scales naturally with the herd.
# -----------------------------------------------------------------------------
func _build_body() -> void:
	var skin := _solid_material(Color(0.85, 0.66, 0.52))
	var shirt := _solid_material(Color(0.70, 0.16, 0.16))   # red plaid-ish shirt
	var denim := _solid_material(Color(0.24, 0.31, 0.48))   # blue overalls
	var boots := _solid_material(Color(0.17, 0.13, 0.10))
	var straw := _solid_material(Color(0.85, 0.72, 0.45))   # straw hat
	var metal := _solid_material(Color(0.18, 0.18, 0.20))   # gun barrel
	var wood := _solid_material(Color(0.45, 0.28, 0.15))    # gun stock

	# Legs + boots.
	for x in [-0.13, 0.13]:
		_add_part(self, _cylinder(0.12, 0.12, 0.8), denim, Vector3(x, 0.5, 0.0))
		_add_part(self, _cylinder(0.14, 0.14, 0.16), boots, Vector3(x, 0.08, 0.06))

	# Torso (shirt) with a denim overall bib over the front.
	_add_part(self, _capsule(0.30, 0.85), shirt, Vector3(0, 1.18, 0))
	_add_part(self, _box(Vector3(0.46, 0.55, 0.18)), denim, Vector3(0, 1.05, 0.16))

	# Head, with a straw hat (wide brim + short crown).
	_add_part(self, _sphere(0.21), skin, Vector3(0, 1.62, 0))
	_add_part(self, _cylinder(0.34, 0.34, 0.04), straw, Vector3(0, 1.74, 0))
	_add_part(self, _cylinder(0.20, 0.22, 0.18), straw, Vector3(0, 1.82, 0))

	# Aim pivot at the shoulder; the arms and rifle hang off it so the whole lot
	# swings up together when he raises the gun to fire.
	_aim = Node3D.new()
	_aim.name = "Aim"
	_aim.position = Vector3(0.0, SHOULDER_HEIGHT, 0.0)
	add_child(_aim)

	# Arms reaching forward to hold the rifle.
	for x in [-0.16, 0.16]:
		_add_part(_aim, _cylinder(0.07, 0.07, 0.5), shirt, Vector3(x, 0.02, 0.3), Vector3(90, 0, 0))

	# The rifle: a long thin barrel along +Z, a wooden stock at the shoulder, and
	# a small dark muzzle marker at the tip (also the tracer's origin).
	_add_part(_aim, _cylinder(0.03, 0.03, 1.1), metal, Vector3(0, 0.06, 0.62), Vector3(90, 0, 0))
	_add_part(_aim, _box(Vector3(0.07, 0.13, 0.42)), wood, Vector3(0, 0.0, 0.06))
	_muzzle = _add_part(_aim, _cylinder(0.045, 0.045, 0.08), metal, Vector3(0, 0.06, 1.16), Vector3(90, 0, 0))


# --- Mesh + part helpers (mirrors Cow.gd's primitive toolkit) ----------------
func _add_part(parent: Node, mesh: Mesh, material: StandardMaterial3D, pos: Vector3,
		rot_deg: Vector3 = Vector3.ZERO, part_scale: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = material
	inst.position = pos
	inst.rotation_degrees = rot_deg
	inst.scale = part_scale
	parent.add_child(inst)
	return inst


func _capsule(radius: float, height: float) -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	return mesh


func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	return mesh


func _cylinder(top_radius: float, bottom_radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	return mesh


func _box(s: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = s
	return mesh


func _solid_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	return mat
