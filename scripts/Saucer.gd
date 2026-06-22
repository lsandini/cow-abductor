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
@export var mouse_sensitivity: float = 0.005
@export var min_pitch: float = -1.3        # how far down the camera can look (rad)
@export var max_pitch: float = -0.1        # how far up the camera can look (rad)

# --- Tractor beam tuning -----------------------------------------------------
@export var beam_radius: float = 6.0       # ground radius the beam can grab within

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
var _beam: MeshInstance3D                   # the cone of light, shown while beaming
var beam_active: bool = false               # read by the minimap to draw the beam ring


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

	# Cosmetic banking: tilt the disc so the leading edge dips in the direction
	# it is travelling (front dips going forward, right edge dips going right).
	var bank := move * 0.25
	_body.rotation.z = lerp(_body.rotation.z, -bank.dot(right), delta * 6.0)
	_body.rotation.x = lerp(_body.rotation.x, bank.dot(forward), delta * 6.0)


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

	# Lower disc: a squashed sphere.
	var disc_mesh := SphereMesh.new()
	disc_mesh.radius = 3.0
	disc_mesh.height = 6.0
	var disc := MeshInstance3D.new()
	disc.mesh = disc_mesh
	disc.scale = Vector3(1.0, 0.32, 1.0)   # flatten it into a saucer shape
	disc.material_override = _metal_material(Color(0.62, 0.65, 0.70))
	_body.add_child(disc)

	# Glass dome on top.
	var dome_mesh := SphereMesh.new()
	dome_mesh.radius = 1.4
	dome_mesh.height = 2.8
	var dome := MeshInstance3D.new()
	dome.mesh = dome_mesh
	dome.scale = Vector3(1.0, 0.7, 1.0)
	dome.position.y = 0.7
	var dome_mat := _metal_material(Color(0.45, 0.85, 0.95))
	dome_mat.emission_enabled = true
	dome_mat.emission = Color(0.30, 0.70, 0.85)
	dome_mat.emission_energy_multiplier = 0.6
	dome.material_override = dome_mat
	_body.add_child(dome)


func _build_beam() -> void:
	# A translucent cone widening from the saucer down to the ground.
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 0.6           # narrow at the saucer
	beam_mesh.bottom_radius = beam_radius  # wide where it hits the ground
	beam_mesh.height = fly_height

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.9, 1.0, 0.22)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # visible from inside and out
	mat.emission_enabled = true
	mat.emission = Color(0.5, 0.9, 1.0)

	_beam = MeshInstance3D.new()
	_beam.name = "Beam"
	_beam.mesh = beam_mesh
	_beam.material_override = mat
	# Place it so the top sits at the saucer and the base rests on the ground.
	_beam.position.y = -fly_height / 2.0
	_beam.visible = false
	add_child(_beam)


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
func _metal_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.6
	mat.roughness = 0.3
	return mat
