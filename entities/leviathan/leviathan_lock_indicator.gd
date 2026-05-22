extends Node3D

# Pre-launch warning indicator for the GhostLeviathan missile salvo. Real
# fighters announce a launch with a radar-lock indication that precedes
# warhead-on-target by a beat — long enough that the pilot can react, but
# committed enough that intercept is already inevitable. Same role here:
# the player gets ~1.2 s to spot the reticle and reposition before the salvo
# starts spawning.
#
# Two layered cues, both pulsing at ~18 rad/s (the standard "lock acquired"
# cadence used by air-to-air HUDs):
#   1. Two camera-billboarded ring outlines, the inner one closing inward.
#   2. Four L-shaped corner brackets converging onto the target.
#
# The reticle is drawn with ImmediateMesh line strips because the Mobile
# renderer doesn't support GPU particles on Godot 4.6.

const DURATION: float = 1.2
const RING_OUTER: float = 2.6
const RING_INNER_FINAL: float = 0.55
const COLOR_BASE := Color(1.0, 0.32, 0.55, 1.0)
const PULSE_RATE: float = 18.0

var _age: float = 0.0
var _target: Node3D
var _mesh: ImmediateMesh

func setup(tgt: Node3D) -> void:
	_target = tgt

func _ready() -> void:
	# top_level so we follow the target by global_position assignment, not
	# through a parent transform chain — keeps the indicator independent of
	# whatever the target's animation is doing.
	top_level = true
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh = ImmediateMesh.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _process(delta: float) -> void:
	_age += delta
	if _target == null or not is_instance_valid(_target) or _age >= DURATION:
		queue_free()
		return
	global_position = _target.global_position
	# Pulse accelerates as t→1 (sharper, more urgent in the last beat).
	var t: float = _age / DURATION
	var rate: float = PULSE_RATE * (1.0 + t)
	var pulse: float = 0.55 + 0.45 * sin(_age * rate)
	var col := Color(COLOR_BASE.r, COLOR_BASE.g, COLOR_BASE.b, pulse)
	_redraw(t, col)

func _redraw(t: float, col: Color) -> void:
	_mesh.clear_surfaces()
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	# Construct an in-plane basis perpendicular to the camera direction so the
	# reticle always faces the camera, regardless of viewing angle.
	var to_cam_v: Vector3 = cam.global_position - global_position
	if to_cam_v.length_squared() < 1e-6:
		return
	var to_cam: Vector3 = to_cam_v.normalized()
	var up_ref: Vector3 = Vector3.UP if absf(to_cam.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	var right: Vector3 = to_cam.cross(up_ref).normalized()
	var up: Vector3 = right.cross(to_cam).normalized()
	var ease_t: float = smoothstep(0.0, 1.0, t)
	var inner_r: float = lerp(RING_OUTER, RING_INNER_FINAL, ease_t)
	_draw_ring(right, up, RING_OUTER, col, 36)
	_draw_ring(right, up, inner_r, col, 36)
	var bracket_d: float = lerp(RING_OUTER * 1.18, RING_INNER_FINAL * 1.1, ease_t)
	for q in range(4):
		_draw_bracket(right, up, bracket_d, col, q)

func _draw_ring(right: Vector3, up: Vector3, r: float, col: Color, segs: int) -> void:
	_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(segs + 1):
		var a: float = TAU * float(i) / float(segs)
		var p: Vector3 = right * (cos(a) * r) + up * (sin(a) * r)
		_mesh.surface_set_color(col)
		_mesh.surface_add_vertex(p)
	_mesh.surface_end()

func _draw_bracket(right: Vector3, up: Vector3, d: float, col: Color, q: int) -> void:
	# Four L-shaped corner brackets at NE/NW/SW/SE quadrants. Each is two
	# perpendicular line segments meeting at the outer corner; the arms point
	# inward toward the reticle center so the eye reads "converging on lock".
	var sx: float = 1.0 if (q == 0 or q == 3) else -1.0
	var sy: float = 1.0 if (q == 0 or q == 1) else -1.0
	var arm: float = d * 0.28
	var corner: Vector3 = right * (sx * d) + up * (sy * d)
	var ext_x: Vector3 = corner - right * (sx * arm)
	var ext_y: Vector3 = corner - up * (sy * arm)
	_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(ext_x)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(corner)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(ext_y)
	_mesh.surface_end()
