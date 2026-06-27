# =============================================================================
# HeadingTape.gd  (class_name HeadingTape)
#
# A semitransparent compass ribbon across the top of the screen — a simple,
# flat take on an aircraft heading tape. It scrolls left/right as you turn:
#   - amber tick marks every few degrees (taller ones at the majors)
#   - cardinal/intercardinal letters (N, NE, E, SE, ...) at the 45° points and
#     numeric headings (30, 60, 120, ...) in between
#   - a fixed centre caret + a precise readout (e.g. 245°) for your heading
#
# Heading is read from the saucer's planar facing (the same source the minimap
# arrow uses, via the "saucer" group), so the two always agree. North is world
# -Z and headings increase clockwise (N=0, E=90, S=180, W=270).
# =============================================================================
class_name HeadingTape
extends Control

@export var visible_degrees: float = 120.0   # how wide a span of headings the tape shows
@export var minor_step: int = 5              # a tick every this many degrees
@export var major_step: int = 15            # taller ticks at multiples of this

# A light, mostly-white instrument look that reads against the blue sky: white
# marks over the faintest tint of a strip, with a soft drop shadow on the text.
const BG_COLOR := Color(0.08, 0.10, 0.14, 0.16)
const TICK_COLOR := Color(1.0, 1.0, 1.0, 0.80)
const LETTER_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const NUMBER_COLOR := Color(1.0, 1.0, 1.0, 0.60)
const READOUT_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const CARET_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const SHADOW_COLOR := Color(0.0, 0.0, 0.0, 0.45)

# The eight compass points, keyed by their heading in degrees.
const LETTERS := {0: "N", 45: "NE", 90: "E", 135: "SE", 180: "S", 225: "SW", 270: "W", 315: "NW"}


func _process(_delta: float) -> void:
	queue_redraw()   # heading changes constantly, so refresh every frame


func _draw() -> void:
	var saucer := get_tree().get_first_node_in_group("saucer") as Saucer
	if saucer == null:
		return

	# Planar facing -> compass heading. North is -Z; +X is east. atan2(east, north)
	# gives a clockwise heading where N=0, E=90, S=180, W=270.
	var fwd := saucer.get_planar_forward()
	var heading := fposmod(rad_to_deg(atan2(fwd.x, -fwd.y)), 360.0)

	var w := size.x
	var center_x := w * 0.5
	var ppd := w / visible_degrees          # pixels per degree
	var baseline := size.y - 6.0            # ticks sit on this line and rise upward

	var font := get_theme_default_font()

	# Translucent strip + a faint baseline to ground the ticks.
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR, true)
	draw_line(Vector2(0, baseline), Vector2(w, baseline),
			Color(TICK_COLOR.r, TICK_COLOR.g, TICK_COLOR.b, 0.4), 1.0)

	# Walk every marked degree across (a little past) the visible span and place
	# it relative to the centre using the shortest signed angle to the heading.
	var half := visible_degrees * 0.5 + float(major_step)
	for deg in range(int(floor(heading - half)), int(ceil(heading + half)) + 1):
		if deg % minor_step != 0:
			continue
		var d := wrapf(float(deg) - heading, -180.0, 180.0)
		var x := center_x + d * ppd
		if x < 1.0 or x > w - 1.0:
			continue
		var norm := ((deg % 360) + 360) % 360
		var is_major := norm % major_step == 0
		var tick_h := 12.0 if is_major else 6.0
		draw_line(Vector2(x, baseline), Vector2(x, baseline - tick_h),
				TICK_COLOR, 2.0 if is_major else 1.0)
		# Skip labels directly under the centre caret so they don't clash with it.
		if absf(x - center_x) < 12.0:
			continue
		if LETTERS.has(norm):
			_label(font, 15, LETTERS[norm], x, baseline - tick_h - 4.0, LETTER_COLOR)
		elif norm % 30 == 0:
			_label(font, 12, str(norm), x, baseline - tick_h - 4.0, NUMBER_COLOR)

	# Fixed centre caret (points down at the tape) + the precise heading readout.
	var apex := Vector2(center_x, baseline - 14.0)
	draw_colored_polygon(PackedVector2Array([apex, apex + Vector2(-6, -9), apex + Vector2(6, -9)]),
			CARET_COLOR)
	_label(font, 17, "%03d°" % int(round(heading)), center_x, 16.0, READOUT_COLOR)


# Draw `text` horizontally centred on `cx`, with its baseline at `baseline_y`,
# over a soft drop shadow so white stays legible against bright sky.
func _label(font: Font, font_size: int, text: String, cx: float, baseline_y: float, color: Color) -> void:
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var x := cx - tw * 0.5
	draw_string(font, Vector2(x + 1.0, baseline_y + 1.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, SHADOW_COLOR)
	draw_string(font, Vector2(x, baseline_y), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
