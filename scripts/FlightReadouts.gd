# =============================================================================
# FlightReadouts.gd  (class_name FlightReadouts)
#
# The simplest possible cockpit readouts, in the same light style as the compass
# tape: SPEED just left of the heading tape, ALTITUDE just right of it, so the
# three instruments read as one group across the top. Each is just a small
# caption, a big white number, and a unit — drawn mostly-white with a soft drop
# shadow so they read against the blue sky, no heavy panel.
#
# Values come from the saucer (via the "saucer" group): get_speed() in m/s and
# get_altitude() = the clearance above the ground directly below (what Z / X set).
#
# This fills the screen but only PAINTS beside the centred compass; the layout
# knobs below must match the compass's placement in World._build_ui.
# =============================================================================
class_name FlightReadouts
extends Control

const VALUE_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const CAPTION_COLOR := Color(1.0, 1.0, 1.0, 0.65)
const UNIT_COLOR := Color(1.0, 1.0, 1.0, 0.55)
const SHADOW_COLOR := Color(0.0, 0.0, 0.0, 0.45)

# Layout — keep in step with the compass in World._build_ui (it is 520 wide and
# centred, with its band centred ~40 px down).
@export var compass_half_width: float = 260.0   # half the heading tape's width
@export var gap: float = 18.0                    # space between a readout and the tape
@export var band_center_y: float = 40.0          # vertical centre, aligned to the tape
@export var caption_size: int = 13
@export var value_size: int = 30
@export var unit_size: int = 12


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var saucer := get_tree().get_first_node_in_group("saucer") as Saucer
	if saucer == null:
		return
	var font := get_theme_default_font()
	var center_x := size.x * 0.5
	var cy := band_center_y

	# Speed sits just left of the tape (right-aligned up to that edge); altitude
	# just right of the tape (left-aligned from that edge).
	var speed_edge := center_x - compass_half_width - gap
	var alt_edge := center_x + compass_half_width + gap
	_readout(font, "SPD", "%d" % int(round(saucer.get_speed())), "m/s", speed_edge, cy, true)
	_readout(font, "ALT", "%d" % int(round(saucer.get_altitude())), "m", alt_edge, cy, false)


# A stacked caption / value / unit readout anchored to a vertical screen edge.
func _readout(font: Font, caption: String, value: String, unit: String,
		edge_x: float, cy: float, right: bool) -> void:
	_edge_text(font, caption_size, caption, edge_x, cy - 16.0, CAPTION_COLOR, right)
	_edge_text(font, value_size, value, edge_x, cy + 10.0, VALUE_COLOR, right)
	_edge_text(font, unit_size, unit, edge_x, cy + 26.0, UNIT_COLOR, right)


# Draw `text` flush to `edge_x` (its right edge if `right`, else its left edge),
# baseline at `baseline_y`, over a soft drop shadow.
func _edge_text(font: Font, font_size: int, text: String, edge_x: float,
		baseline_y: float, color: Color, right: bool) -> void:
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var x := (edge_x - tw) if right else edge_x
	draw_string(font, Vector2(x + 1.0, baseline_y + 1.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, SHADOW_COLOR)
	draw_string(font, Vector2(x, baseline_y), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
