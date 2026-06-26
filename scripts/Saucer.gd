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

# --- Flight tuning -----------------------------------------------------------
@export var move_speed: float = 26.0       # horizontal flight speed (m/s)
@export var fly_height: float = 15.0       # target clearance above the ground below
@export var min_clearance: float = 9.0     # never drop closer than this to the ground
@export var vertical_follow: float = 4.0   # how briskly altitude eases over hills
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
var beam_active: bool = false               # read by the minimap to draw the beam ring

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


# -----------------------------------------------------------------------------
# Per-frame logic: flight, banking and the tractor beam.
# -----------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	_handle_movement(delta)
	_handle_beam()


# Visuals tick every rendered frame (not the fixed physics step) so the rings
# slide smoothly. They only move while the beam is firing.
func _process(delta: float) -> void:
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

	# Combine inputs (input.y is negative when pressing W, hence the minus).
	var move := right * input.x + forward * (-input.y)
	if move.length() > 1.0:
		move = move.normalized()

	position += move * move_speed * delta

	# Terrain following: ease toward "ground below + fly_height" so the saucer
	# rides the hills smoothly rather than snapping. A hard floor guarantees it
	# never clips into a slope it is climbing.
	var ground := _terrain_y()
	var target_y := ground + fly_height
	position.y = lerp(position.y, target_y, clampf(vertical_follow * delta, 0.0, 1.0))
	position.y = maxf(position.y, ground + min_clearance)

	# Orient the body toward where it is flying: yaw the disc so its leading edge
	# points along the travel direction, roll (bank) into turns, and lean forward
	# a touch with speed. Only the visible body turns — the orbit camera and the
	# downward beam are separate children of the saucer, so they stay put.
	var speed01 := move.length()   # 0 (hovering) .. 1 (full tilt of the stick)
	if speed01 > 0.05:
		# Smoothly yaw the body to face the travel direction (local +Z = front).
		var target_yaw := atan2(move.x, move.z)
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

	# The iconic ring of running lights around the equator.
	_build_light_ring(36, 3.16, 0.06, Vector3(0.16, 0.12, 0.10), Color(0.85, 0.95, 1.0))
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
	add_child(_beam)

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


# A shinier material for the saucer hull/dome.
# A ring of small emissive boxes evenly spaced around the saucer, used for the
# equatorial running lights and the underside glow. All boxes share one mesh and
# one material; each is rotated to sit flush against the hull.
func _build_light_ring(count: int, ring_radius: float, y: float, size: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	for i in count:
		var a := TAU * float(i) / float(count)
		var light := MeshInstance3D.new()
		light.mesh = mesh
		light.material_override = mat
		light.position = Vector3(cos(a) * ring_radius, y, sin(a) * ring_radius)
		light.rotation.y = -a
		_body.add_child(light)


# Polished chrome: fully metallic and nearly mirror-smooth so it reflects the
# sky and horizon (the scene's ambient light source), reading as bright metal.
func _chrome_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 1.0
	mat.roughness = 0.12
	return mat
