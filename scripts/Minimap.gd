# =============================================================================
# Minimap.gd  (class_name Minimap)
#
# A circular radar in the bottom-right corner. Every frame it redraws:
#   - a dark translucent disc with a border
#   - green dots for nearby trees (context)
#   - white dots for cows (clamped to the rim so off-radar cows still show a
#     direction to fly toward)
#   - a yellow arrow at the centre = the saucer, pointing where it faces
#   - a cyan ring showing the tractor beam's reach while it is firing
#
# The map is "north-up": the world's -Z is always toward the top of the radar,
# and the saucer arrow rotates to indicate heading.
# =============================================================================
class_name Minimap
extends Control

@export var view_range: float = 110.0   # world metres from edge-to-centre of the radar

# Colours.
const BG_COLOR := Color(0.05, 0.08, 0.06, 0.55)
const BORDER_COLOR := Color(0.6, 1.0, 0.7, 0.8)
const COW_COLOR := Color(1.0, 1.0, 1.0)
const FARMER_COLOR := Color(0.95, 0.25, 0.2)
const TREE_COLOR := Color(0.3, 0.7, 0.35)
const SAUCER_COLOR := Color(1.0, 0.9, 0.2)
const BEAM_COLOR := Color(0.5, 0.9, 1.0, 0.9)


func _process(_delta: float) -> void:
	queue_redraw()   # the world moves constantly, so refresh every frame


func _draw() -> void:
	var center := size / 2.0
	var radius := size.x / 2.0 - 3.0

	# Radar background + border ring.
	draw_circle(center, radius, BG_COLOR)
	draw_arc(center, radius, 0.0, TAU, 48, BORDER_COLOR, 2.0)

	# Cast to Saucer so its properties (global_position, beam_active, beam_radius,
	# get_planar_forward) are statically typed and resolvable.
	var saucer := get_tree().get_first_node_in_group("saucer") as Saucer
	if saucer == null:
		return

	var origin := saucer.global_position
	var map_scale := radius / view_range   # world metres -> radar pixels

	# Trees first (so cows draw on top of them).
	for tree in get_tree().get_nodes_in_group("trees"):
		var p := _world_to_map(tree.global_position, origin, map_scale, center)
		if p.distance_to(center) <= radius:
			draw_circle(p, 1.5, TREE_COLOR)

	# Cows: clamp stragglers to the rim so the player always sees a bearing.
	for cow in get_tree().get_nodes_in_group("cows"):
		var p := _world_to_map(cow.global_position, origin, map_scale, center)
		var offset := p - center
		if offset.length() > radius:
			offset = offset.normalized() * radius
			p = center + offset
		draw_circle(p, 3.0, COW_COLOR)

	# Farmers: red dots, also clamped to the rim so you can see them coming.
	for farmer in get_tree().get_nodes_in_group("farmers"):
		var p := _world_to_map(farmer.global_position, origin, map_scale, center)
		var offset := p - center
		if offset.length() > radius:
			offset = offset.normalized() * radius
			p = center + offset
		draw_circle(p, 3.0, FARMER_COLOR)

	# Beam reach ring (only while the beam is active).
	if saucer.beam_active:
		draw_arc(center, saucer.beam_radius * map_scale, 0.0, TAU, 24, BEAM_COLOR, 1.5)

	# The saucer itself: a heading arrow at the centre.
	_draw_arrow(center, saucer.get_planar_forward(), SAUCER_COLOR)


# Convert a world position into a radar pixel position (north-up).
# World X maps to map X; world Z maps to map Y (down = +Z / south).
func _world_to_map(world_pos: Vector3, origin: Vector3, map_scale: float, center: Vector2) -> Vector2:
	var dx := world_pos.x - origin.x
	var dz := world_pos.z - origin.z
	return center + Vector2(dx, dz) * map_scale


# Draw a small triangle at `center` pointing along the 2D direction `dir`.
func _draw_arrow(center: Vector2, dir: Vector2, color: Color) -> void:
	if dir.length() < 0.001:
		dir = Vector2(0, -1)
	dir = dir.normalized()
	var perp := Vector2(-dir.y, dir.x)   # 90 degrees to the heading
	var tip := center + dir * 10.0
	var back_left := center - dir * 6.0 + perp * 6.0
	var back_right := center - dir * 6.0 - perp * 6.0
	draw_colored_polygon(PackedVector2Array([tip, back_left, back_right]), color)
