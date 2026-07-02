# =============================================================================
# Saucer.gd  (class_name Saucer)
#
# The player-controlled flying saucer. It:
#   - flies at a CONSTANT height over the flat world
#   - moves with WASD, relative to where the camera is pointing
#   - carries a third-person ORBIT camera controlled with the mouse
#   - fires a downward TRACTOR BEAM (Space / left mouse button) that lifts any
#     cow standing underneath it up into the saucer
#
# All of the saucer's visuals (disc, dome, beam) and its camera rig are built
# from primitives in _ready(), so no scene file is required.
# =============================================================================
class_name Saucer
extends Node3D

# Emitted when a farmer's shot lands (cosmetic only). The World tallies these for the HUD.
signal hit

# --- Flight tuning -----------------------------------------------------------
@export var move_speed: float = 26.0       # top horizontal flight speed (m/s)
@export var acceleration: float = 25.0     # how briskly it builds up to move_speed (m/s^2)
@export var deceleration: float = 40.0     # how briskly it coasts to a stop (m/s^2, stronger = more responsive)
@export var fly_height: float = 15.0       # target clearance above the ground below
@export var min_clearance: float = 9.0     # never drop closer than this to the ground
@export var vertical_follow: float = 4.0   # how briskly altitude eases over hills
@export var altitude_speed: float = 14.0   # how fast Z (up) / X (down) change fly_height (m/s)
@export var fly_height_min: float = 9.0    # lowest hover clearance Z/X allow
@export var fly_height_max: float = 90.0   # highest hover clearance Z/X allow
@export var turn_rate: float = 5.0         # how briskly the body yaws to face travel
@export var bank_amount: float = 0.4       # max roll (rad) leaned into a hard turn
@export var pitch_amount: float = 0.16     # forward lean (rad) at full speed
@export var mouse_sensitivity: float = 0.005
@export var min_pitch: float = -1.3        # how far down the camera can look (rad)
@export var max_pitch: float = 0.52        # how far UP the camera can look (rad ~= 30 deg)

# --- Camera zoom (mouse wheel) -----------------------------------------------
@export var zoom_min: float = 6.0          # closest the camera can pull in
@export var zoom_max: float = 26.0         # furthest the camera can pull out
@export var zoom_step: float = 1.5         # distance changed per wheel notch
var _cam_distance: float = 14.0            # current camera boom length (starts at default)

# --- Tractor beam tuning -----------------------------------------------------
@export var beam_radius: float = 6.0       # ground radius the beam can grab within
@export var beam_ring_count: int = 6       # how many light rings travel down the beam at once
@export var beam_ring_speed: float = 0.4   # how fast a ring slides top->bottom (cycles/sec)
@export var beam_ring_color: Color = Color(0.5, 0.95, 1.0, 0.9)  # rgb tint; a = peak brightness

# --- Death ray (right mouse button: fries the nearest farmer in range) --------
@export var death_ray_range: float = 30.0   # horizontal reach to the nearest farmer
@export var death_ray_color: Color = Color(1.0, 0.12, 0.08)

# --- Rim running lights (two spots circle the rim in opposite directions) -----
@export var rim_runner_speed: float = 0.55      # laps per second each runner travels
@export var rim_base_brightness: float = 0.4    # how lit an idle rim light is
@export var rim_peak_brightness: float = 4.0    # extra brightness at a runner's centre

# Supplied by the World: ground_sampler.call(x, z) -> terrain height. Used to
# keep the saucer at a steady altitude above the ground directly beneath it.
var ground_sampler: Callable

# Camera rig nodes (built in _ready). The hierarchy is:
#   self -> _cam_yaw -> _cam_pitch -> _camera
# Rotating _cam_yaw orbits horizontally; rotating _cam_pitch tilts up/down.
var _cam_yaw: Node3D
var _cam_pitch: Node3D
var _camera: Camera3D
var _pitch: float = -0.6                    # current camera pitch angle (rad)

var _body: Node3D                           # the visible saucer mesh (banks when moving)
var _beam: Node3D                           # container for the travelling beam rings
var _rings: Array[MeshInstance3D] = []      # the pool of light rings cycled down the beam
var _ring_t: float = 0.0                    # shared phase [0,1); ring i is offset by i/count
var _rim_lights: Array[MeshInstance3D] = [] # the equatorial running lights (each has its own material)
var _rim_mats: Array[StandardMaterial3D] = []
var _rim_phase: float = 0.0                 # 0..1 position of the runners around the rim
var _rim_color: Color = Color.WHITE         # base colour of the rim lights (brightness is animated)
var beam_active: bool = false               # read by the minimap to draw the beam ring
var _speed: float = 0.0                      # current horizontal ground speed (m/s), for the HUD
var _velocity: Vector3 = Vector3.ZERO        # horizontal flight velocity, eased for accel/decel

# --- Hit reaction (farmers' rifle fire — purely cosmetic, does NO damage) -----
var ding_stream: AudioStream                # baked metallic "ding"; set by World
var _ding_player: AudioStreamPlayer3D
var zap_stream: AudioStream                 # baked death-ray "phaser"; set by World
var _zap_player: AudioStreamPlayer3D
# A damped-spring tilt added on top of the body's flight lean when a shot lands,
# so the disc lurches and settles. Only the visible body is affected — the camera
# rig and flight are untouched, which is what makes the hit harmless.
var _recoil: Vector2 = Vector2.ZERO         # extra (pitch, roll) tilt, radians
var _recoil_vel: Vector2 = Vector2.ZERO
const _RECOIL_STIFFNESS: float = 80.0       # how hard it springs back to level
const _RECOIL_DAMPING: float = 11.0         # how quickly the wobble dies out

# Base ring radius of the unscaled torus mesh; each ring is scaled in X/Z from this
# to match the cone's radius at its current height. Kept in sync with _build_beam().
const _RING_BASE_RADIUS: float = 0.94


func _ready() -> void:
	# Start hovering at the target clearance above the ground beneath the origin.
	position = Vector3(0.0, _terrain_y() + fly_height, 0.0)
	_build_body()
	_build_beam()
	_build_camera_rig()
	# Capture the mouse so motion drives the camera instead of a desktop cursor.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# A 3D voice for the hull "ding" when a farmer's shot lands (if World gave us
	# the baked sample). It sits right at the camera, so it always reads clearly.
	if ding_stream != null:
		_ding_player = AudioStreamPlayer3D.new()
		_ding_player.stream = ding_stream
		_ding_player.volume_db = -2.0
		_ding_player.max_distance = 140.0
		_ding_player.unit_size = 22.0
		add_child(_ding_player)

	# And a voice for the death-ray zap.
	if zap_stream != null:
		_zap_player = AudioStreamPlayer3D.new()
		_zap_player.stream = zap_stream
		_zap_player.volume_db = -11.0
		_zap_player.max_distance = 160.0
		_zap_player.unit_size = 22.0
		add_child(_zap_player)


# -----------------------------------------------------------------------------
# Per-frame logic: flight, banking and the tractor beam.
# -----------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	_handle_movement(delta)
	_apply_recoil(delta)
	_handle_beam()


# Visuals tick every rendered frame (not the fixed physics step) so the rings
# slide smoothly. They only move while the beam is firing.
func _process(delta: float) -> void:
	_animate_rim_lights(delta)   # the rim runners circle whether or not the beam is on
	if not beam_active:
		return
	# Advance the shared phase; each ring reads it with its own even offset so the
	# rings stay equally spaced as they march from the saucer down to the ground.
	_ring_t = fposmod(_ring_t + beam_ring_speed * delta, 1.0)
	for i in _rings.size():
		var t := fposmod(_ring_t + float(i) / float(_rings.size()), 1.0)
		_update_ring(_rings[i], t)


# Position, size and fade a single ring for phase t (0 = at the saucer, 1 = ground).
func _update_ring(ring: MeshInstance3D, t: float) -> void:
	ring.position.y = -t * fly_height
	# Match the (now invisible) cone: narrow at the saucer, wide at the ground.
	var radius := lerpf(0.6, beam_radius, t)
	var s := radius / _RING_BASE_RADIUS
	ring.scale = Vector3(s, 1.0, s)
	# Soft fade in as a ring is born at the top and out as it reaches the ground,
	# so rings never pop into or out of existence.
	var fade := clampf(minf(t / 0.15, (1.0 - t) / 0.15), 0.0, 1.0)
	var mat := ring.material_override as StandardMaterial3D
	mat.albedo_color.a = beam_ring_color.a * fade


# Sweep two bright spots around the rim — one clockwise, one counter-clockwise —
# by setting each light's emission energy from its angular distance to the two
# runners. They start together, drift apart, and flare at the two points where
# they cross (opposite sides of the rim), since overlapping runners add their glow.
func _animate_rim_lights(delta: float) -> void:
	if _rim_lights.is_empty():
		return
	_rim_phase = fposmod(_rim_phase + rim_runner_speed * delta, 1.0)
	var ang_cw := _rim_phase * TAU
	var ang_ccw := TAU - ang_cw                 # equal speed, opposite direction
	var sigma := TAU / float(_rim_lights.size()) * 0.9   # falloff ~one light wide
	var denom := 2.0 * sigma * sigma
	for i in _rim_lights.size():
		var a := TAU * float(i) / float(_rim_lights.size())
		var d_cw := _arc_dist(a, ang_cw)
		var d_ccw := _arc_dist(a, ang_ccw)
		var glow := exp(-d_cw * d_cw / denom) + exp(-d_ccw * d_ccw / denom)
		# Drive the ALBEDO (what unshaded actually renders); >1 saturates to white.
		_rim_mats[i].albedo_color = _rim_color * (rim_base_brightness + rim_peak_brightness * glow)


# Shortest angular distance between two angles, in [0, PI].
func _arc_dist(a: float, b: float) -> float:
	return absf(fposmod(a - b + PI, TAU) - PI)


func _handle_movement(delta: float) -> void:
	# get_vector returns x = right/left, y = back/forward (forward is negative).
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	# Flatten the camera's facing onto the ground plane so "forward" always
	# means "the way I'm looking", regardless of camera tilt.
	var cam_basis := _camera.global_transform.basis
	var forward := -cam_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := cam_basis.x
	right.y = 0.0
	right = right.normalized()

	# Combine inputs (input.y is negative when pressing W, hence the minus) into a
	# desired travel direction, then a desired velocity.
	var move := right * input.x + forward * (-input.y)
	if move.length() > 1.0:
		move = move.normalized()
	var desired := move * move_speed

	# Ease the actual velocity toward the desired one so the saucer accelerates
	# and coasts to a stop instead of snapping between 0 and full speed. Drag
	# (deceleration) is stronger than thrust so it stays quick to halt.
	var rate := acceleration if move.length() > 0.01 else deceleration
	_velocity = _velocity.move_toward(desired, rate * delta)
	position += _velocity * delta
	_speed = _velocity.length()   # now ramps smoothly 0..move_speed, read by the HUD

	# Terrain following: ease toward "ground below + fly_height" so the saucer
	# rides the hills smoothly rather than snapping. A hard floor guarantees it
	# never clips into a slope it is climbing.
	var ground := _terrain_y()

	# Player-controlled altitude: Z raises, X lowers the hover clearance. The
	# saucer still rides the hills — this only changes how high above them it sits.
	var altitude_input := Input.get_axis("altitude_down", "altitude_up")
	if altitude_input != 0.0:
		fly_height = clampf(fly_height + altitude_input * altitude_speed * delta, fly_height_min, fly_height_max)

	var target_y := ground + fly_height
	position.y = lerp(position.y, target_y, clampf(vertical_follow * delta, 0.0, 1.0))
	position.y = maxf(position.y, ground + min_clearance)

	# Orient the body toward where it is flying: yaw the disc so its leading edge
	# points along the travel direction, roll (bank) into turns, and lean forward
	# a touch with speed. The orbit camera is a separate child of the saucer root,
	# so it stays put; the tractor beam is a child of the body, so it tilts with
	# the hull (its axis stays perpendicular to the disc).
	var speed01 := clampf(_velocity.length() / move_speed, 0.0, 1.0)   # 0 (hover) .. 1 (full speed)
	if _velocity.length() > 0.3:
		# Smoothly yaw the body to face the ACTUAL travel direction (local +Z =
		# front), so it stays banked as it coasts and only levels once near stop.
		var target_yaw := atan2(_velocity.x, _velocity.z)
		var prev_yaw := _body.rotation.y
		var new_yaw := lerp_angle(prev_yaw, target_yaw, clampf(turn_rate * delta, 0.0, 1.0))
		_body.rotation.y = new_yaw

		# Bank into the turn, scaled by how fast the heading is swinging this frame.
		var turn_rate_now := angle_difference(prev_yaw, new_yaw) / maxf(delta, 0.0001)
		var roll := clampf(-turn_rate_now * 0.12, -bank_amount, bank_amount)
		_body.rotation.z = lerp(_body.rotation.z, roll, clampf(delta * 6.0, 0.0, 1.0))
		# Nose dips forward proportionally to speed.
		_body.rotation.x = lerp(_body.rotation.x, pitch_amount * speed01, clampf(delta * 6.0, 0.0, 1.0))
	else:
		# Level out to a flat hover when there is no input.
		_body.rotation.z = lerp(_body.rotation.z, 0.0, clampf(delta * 4.0, 0.0, 1.0))
		_body.rotation.x = lerp(_body.rotation.x, 0.0, clampf(delta * 4.0, 0.0, 1.0))


# Terrain height directly below the saucer (0 if no sampler has been provided).
func _terrain_y() -> float:
	if ground_sampler.is_valid():
		return ground_sampler.call(position.x, position.z)
	return 0.0


# -----------------------------------------------------------------------------
# Hit reaction: a farmer's rifle shot. No damage — just a brief recoil tilt of
# the visible disc and a metallic ding. register_hit() is called by the Farmer.
# -----------------------------------------------------------------------------
func register_hit(shooter_pos: Vector3) -> void:
	# Kick the disc away from the shooter, plus a small nose-up jolt. The impact
	# direction is taken in the body's own frame so the lurch always reads
	# relative to which way the saucer is currently facing.
	var dir := global_position - shooter_pos
	dir.y = 0.0
	if dir.length() < 0.01:
		dir = Vector3.FORWARD
	var local := _body.global_transform.basis.inverse() * dir.normalized()
	var kick := 0.5
	_recoil_vel.x += -local.z * kick - 0.35  # pitch: small lurch + nose-up jolt
	_recoil_vel.y += local.x * kick          # roll away from the shot
	_play_ding()
	hit.emit()


# Integrate the recoil spring and add it on top of the flight tilt set by
# _handle_movement (so a hit visibly jolts the disc, then it settles to level).
func _apply_recoil(delta: float) -> void:
	var accel := -_recoil * _RECOIL_STIFFNESS - _recoil_vel * _RECOIL_DAMPING
	_recoil_vel += accel * delta
	_recoil += _recoil_vel * delta
	_body.rotation.x += _recoil.x
	_body.rotation.z += _recoil.y


func _play_ding() -> void:
	if _ding_player == null:
		return
	_ding_player.pitch_scale = randf_range(0.95, 1.12)
	_ding_player.play()


func _handle_beam() -> void:
	beam_active = Input.is_action_pressed("beam")
	_beam.visible = beam_active

	# Each frame, tell every cow whether it is currently inside the beam.
	# A cow that is grabbed handles its own ride up to the saucer.
	for cow in get_tree().get_nodes_in_group("cows"):
		var horizontal := Vector2(
			cow.global_position.x - global_position.x,
			cow.global_position.z - global_position.z
		)
		var grabbed := beam_active and horizontal.length() <= beam_radius
		cow.set_pulled(grabbed, self)


# -----------------------------------------------------------------------------
# Death ray: right-click zaps the nearest farmer within range with a red bolt,
# which chars and disintegrates him (see Farmer.fry). Harmless theatre like the
# rest of the game — it just removes that guard (the World sends in a fresh one).
# -----------------------------------------------------------------------------
func _fire_death_ray() -> void:
	var best = null
	var best_d2 := death_ray_range * death_ray_range
	for f in get_tree().get_nodes_in_group("farmers"):
		var dx: float = f.global_position.x - global_position.x
		var dz: float = f.global_position.z - global_position.z
		var d2 := dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best = f
	if best == null:
		return   # no farmer close enough
	_play_zap()
	_spawn_death_ray(best.global_position + Vector3(0.0, 1.2, 0.0))
	best.fry()


func _play_zap() -> void:
	if _zap_player == null:
		return
	_zap_player.pitch_scale = randf_range(0.95, 1.1)
	_zap_player.play()


# A brief bright-red bolt from the saucer's underside to the target, spawned into
# the world (so it stays put as the saucer drifts) and fading out fast.
func _spawn_death_ray(target: Vector3) -> void:
	var from := global_position + Vector3(0.0, -0.8, 0.0)
	var seg := target - from
	var dist := seg.length()
	if dist < 0.01:
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.15
	mesh.bottom_radius = 0.15
	mesh.height = dist
	var mat := StandardMaterial3D.new()
	mat.albedo_color = death_ray_color
	mat.emission_enabled = true
	mat.emission = death_ray_color
	mat.emission_energy_multiplier = 6.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	get_parent().add_child(inst)
	# A cylinder's long axis is local +Y, so aim +Y along the bolt and centre it.
	inst.global_transform = Transform3D(_basis_from_y(seg / dist), (from + target) * 0.5)
	var tw := inst.create_tween()
	tw.tween_interval(0.06)                                # a beat of full-bright bolt
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.18)    # then fade the bolt away
	tw.parallel().tween_property(mat, "emission_energy_multiplier", 0.0, 0.18)
	tw.tween_callback(inst.queue_free)


# An orthonormal basis whose +Y axis points along `y` (for orienting the bolt).
func _basis_from_y(y: Vector3) -> Basis:
	var up := y.normalized()
	var ref_axis := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.99 else Vector3.FORWARD
	var x := ref_axis.cross(up).normalized()
	var z := x.cross(up).normalized()
	return Basis(x, up, z)


# -----------------------------------------------------------------------------
# Mouse look + Esc to release the cursor.
# -----------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_cam_yaw.rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, min_pitch, max_pitch)
		_cam_pitch.rotation.x = _pitch
	elif event is InputEventMouseButton and event.pressed:
		# Scroll wheel pulls the camera in (up) or out (down) along its boom.
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_distance = clampf(_cam_distance - zoom_step, zoom_min, zoom_max)
			_camera.position.z = _cam_distance
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_distance = clampf(_cam_distance + zoom_step, zoom_min, zoom_max)
			_camera.position.z = _cam_distance
		elif event.button_index == MOUSE_BUTTON_RIGHT and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_fire_death_ray()   # zap the nearest farmer in range
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		# Toggle the mouse between captured (look) and free (desktop cursor).
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# -----------------------------------------------------------------------------
# Queried by the minimap to orient its heading arrow: the saucer's forward
# direction on the ground plane, as a 2D (x, z) vector.
# -----------------------------------------------------------------------------
func get_planar_forward() -> Vector2:
	var forward := -_camera.global_transform.basis.z
	return Vector2(forward.x, forward.z).normalized()


# Read by the HUD readouts: current horizontal speed (m/s) and the clearance
# above the ground directly below (the height the player sets with Z / X).
func get_speed() -> float:
	return _speed


func get_altitude() -> float:
	return global_position.y - _terrain_y()


# -----------------------------------------------------------------------------
# Visual construction
# -----------------------------------------------------------------------------
func _build_body() -> void:
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)

	# --- Hull: a wide, polished-chrome lens. --------------------------------
	# Upper shell: a shallow, gently domed top.
	var top_mesh := SphereMesh.new()
	top_mesh.radius = 3.2
	top_mesh.height = 6.4
	var top := MeshInstance3D.new()
	top.mesh = top_mesh
	top.scale = Vector3(1.0, 0.17, 1.0)
	top.material_override = _chrome_material(Color(0.72, 0.76, 0.82))
	_body.add_child(top)

	# Lower shell: a narrower, slightly deeper belly that tucks in under the rim.
	var belly_mesh := SphereMesh.new()
	belly_mesh.radius = 2.9
	belly_mesh.height = 5.8
	var belly := MeshInstance3D.new()
	belly.mesh = belly_mesh
	belly.scale = Vector3(1.0, 0.30, 1.0)
	belly.position.y = -0.06
	belly.material_override = _chrome_material(Color(0.55, 0.58, 0.64))
	_body.add_child(belly)

	# Sharp equatorial lip: a thin, darker chrome ring jutting out at the widest
	# point — the hard knife edge where the top and bottom shells meet.
	var rim_mesh := TorusMesh.new()
	rim_mesh.inner_radius = 3.18
	rim_mesh.outer_radius = 3.40
	var rim := MeshInstance3D.new()
	rim.mesh = rim_mesh
	rim.scale = Vector3(1.0, 0.45, 1.0)   # flatten the lip so the edge is sharp
	rim.material_override = _chrome_material(Color(0.28, 0.30, 0.34))
	_body.add_child(rim)

	# The iconic ring of running lights around the equator — two spots sweep it in
	# opposite directions (animated; see _animate_rim_lights).
	_build_light_ring(36, 3.16, 0.06, Vector3(0.16, 0.12, 0.10), Color(0.85, 0.95, 1.0), true)
	# A smaller cluster of glowing lights on the underside.
	_build_light_ring(18, 1.6, -0.78, Vector3(0.12, 0.10, 0.10), Color(0.55, 0.9, 1.0))

	# --- Dark glass dome on top. --------------------------------------------
	var dome_mesh := SphereMesh.new()
	dome_mesh.radius = 1.5
	dome_mesh.height = 3.0
	var dome := MeshInstance3D.new()
	dome.mesh = dome_mesh
	dome.scale = Vector3(1.0, 0.58, 1.0)
	dome.position.y = 0.44
	var dome_mat := _chrome_material(Color(0.05, 0.09, 0.14))  # near-black blue glass
	dome_mat.roughness = 0.05
	dome_mat.emission_enabled = true
	dome_mat.emission = Color(0.10, 0.30, 0.45)
	dome_mat.emission_energy_multiplier = 0.25
	dome.material_override = dome_mat
	_body.add_child(dome)


func _build_beam() -> void:
	# The beam is no longer a solid cone. Instead a pool of thin glowing rings
	# slides down the (invisible) cone surface, from the saucer to the ground.
	_beam = Node3D.new()
	_beam.name = "Beam"
	_beam.visible = false
	# Parent the beam to the BODY (not the saucer root) so its axis stays
	# perpendicular to the disc: it tilts with the hull as it banks/pitches and
	# straightens back to vertical when the saucer levels out into a hover.
	_body.add_child(_beam)

	# One flat torus mesh, shared by every ring and scaled per-ring in _update_ring.
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.88
	ring_mesh.outer_radius = 1.0   # (inner+outer)/2 must equal _RING_BASE_RADIUS

	for i in beam_ring_count:
		# Additive blending makes the overlapping rings read as light, and each
		# ring gets its own material so it can fade independently of the others.
		var mat := StandardMaterial3D.new()
		mat.albedo_color = beam_ring_color
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # visible from inside and out

		var ring := MeshInstance3D.new()
		ring.mesh = ring_mesh
		ring.material_override = mat
		_beam.add_child(ring)
		_rings.append(ring)
		# Stagger the pool so the rings start out evenly spaced down the beam.
		_update_ring(ring, float(i) / float(beam_ring_count))


func _build_camera_rig() -> void:
	_cam_yaw = Node3D.new()
	_cam_yaw.name = "CamYaw"
	add_child(_cam_yaw)

	_cam_pitch = Node3D.new()
	_cam_pitch.name = "CamPitch"
	_cam_pitch.rotation.x = _pitch
	_cam_yaw.add_child(_cam_pitch)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	# Pull the camera back and slightly up for a classic over-the-shoulder view.
	_camera.position = Vector3(0.0, 2.0, 14.0)
	_camera.current = true
	_cam_pitch.add_child(_camera)


# A ring of small emissive boxes evenly spaced around the saucer, used for the
# equatorial running lights and the underside glow. A static ring shares one
# bright material; an `animated` ring gives each light its OWN material (and
# registers it) so the two runner spots can sweep around it per frame, starting
# dim (low energy + faint albedo) so an unlit bulb is just a faint dot.
func _build_light_ring(count: int, ring_radius: float, y: float, size: Vector3,
		color: Color, animated: bool = false) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var shared := _light_material(color, 3.0) if not animated else null
	if animated:
		_rim_color = color

	for i in count:
		var a := TAU * float(i) / float(count)
		var light := MeshInstance3D.new()
		light.mesh = mesh
		# Animated lights start at the idle brightness; _animate_rim_lights drives
		# their albedo from there each frame.
		var mat := shared if not animated else _light_material(color * rim_base_brightness, 0.0)
		light.material_override = mat
		light.position = Vector3(cos(a) * ring_radius, y, sin(a) * ring_radius)
		light.rotation.y = -a
		_body.add_child(light)
		if animated:
			_rim_lights.append(light)
			_rim_mats.append(mat)


# A small "bulb" material: unshaded so its ALBEDO renders directly as the light's
# colour/brightness (emission is unreliable in unshaded mode, so the animated rim
# drives albedo). Emission is still set for the static rings' glow.
func _light_material(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


# Polished chrome: fully metallic and nearly mirror-smooth so it reflects the
# sky and horizon (the scene's ambient light source), reading as bright metal.
func _chrome_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 1.0
	mat.roughness = 0.12
	return mat
