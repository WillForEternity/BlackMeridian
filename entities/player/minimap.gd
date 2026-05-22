extends Control

# Top-down minimap rendered in the HUD. Shows the whole 1024×1024 m world
# centered on world origin (north-up: world +X is screen-right, world -Z is
# screen-up). The local player is drawn as a green wedge at its world
# position; every RemotePuppet under the scene's RemotePlayers root is drawn
# as a red wedge at its world position. Scale is fixed: the bar's radius
# covers MAP_HALF_EXTENT meters in each direction.

const SIZE: float = 180.0
# Half-extent of the playable world (terrain SIZE = 1024 m, so ±512). The map
# disc inscribes the square, so the corners are off-disc and any peer beyond
# the inscribed radius gets clamped to the rim — same as before.
const MAP_HALF_EXTENT: float = 512.0
const BG_COLOR: Color = Color(0.05, 0.06, 0.08, 0.7)
const BORDER_COLOR: Color = Color(0.9, 0.9, 0.95, 0.85)
const RING_COLOR: Color = Color(0.7, 0.75, 0.85, 0.3)
const LOCAL_COLOR: Color = Color(0.45, 0.95, 0.45, 1.0)
const REMOTE_COLOR: Color = Color(0.95, 0.35, 0.35, 1.0)
const WEDGE_RADIUS: float = 9.0

var _player: Node3D
var _remote_root: Node

func _ready() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	# Bottom-right anchored. UI parent is the scene's CanvasLayer.
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	offset_left = -SIZE - 24
	offset_top = -SIZE - 24
	offset_right = -24
	offset_bottom = -24
	_player = get_tree().current_scene.get_node_or_null("Player") as Node3D
	_remote_root = get_tree().current_scene.get_node_or_null("RemotePlayers")
	set_process(true)

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	var center := Vector2(SIZE, SIZE) * 0.5
	var radius := SIZE * 0.5
	# Backdrop disc + ring + border.
	draw_circle(center, radius, BG_COLOR)
	draw_arc(center, radius * 0.5, 0.0, TAU, 64, RING_COLOR, 1.0, true)
	draw_arc(center, radius - 1.0, 0.0, TAU, 96, BORDER_COLOR, 2.0, true)
	if _player == null:
		return
	# World-centered: every wedge is placed by its absolute world position
	# scaled by px_per_meter. World origin sits at the disc center.
	var px_per_meter: float = radius / MAP_HALF_EXTENT
	_draw_at_world(center, px_per_meter, radius, _player.global_position, _player.rotation.y, LOCAL_COLOR)
	if _remote_root == null:
		return
	for child in _remote_root.get_children():
		if not (child is Node3D):
			continue
		var n3d := child as Node3D
		_draw_at_world(center, px_per_meter, radius, n3d.global_position, n3d.rotation.y, REMOTE_COLOR)

func _draw_at_world(center: Vector2, px_per_meter: float, radius: float, world_pos: Vector3, yaw: float, color: Color) -> void:
	# World +X → screen +X, world +Z → screen +Y (so world -Z is up).
	var px: Vector2 = center + Vector2(world_pos.x, world_pos.z) * px_per_meter
	# Clamp to the rim so anyone outside the inscribed radius still indicates
	# a bearing instead of disappearing off the disc.
	var off: Vector2 = px - center
	var dist: float = off.length()
	if dist > radius - WEDGE_RADIUS:
		px = center + off.normalized() * (radius - WEDGE_RADIUS)
	_draw_wedge_at(px, yaw, color)

func _draw_wedge_at(at: Vector2, yaw: float, color: Color) -> void:
	# Yaw 0 in the player frame faces world -Z (up on the minimap). Rotating
	# the unit "up" vector by yaw around screen-Y gives us screen-space facing.
	var forward := Vector2(sin(yaw), -cos(yaw))
	var right := Vector2(-forward.y, forward.x)
	var tip := at + forward * WEDGE_RADIUS
	var tail_l := at - forward * (WEDGE_RADIUS * 0.4) + right * (WEDGE_RADIUS * 0.55)
	var tail_r := at - forward * (WEDGE_RADIUS * 0.4) - right * (WEDGE_RADIUS * 0.55)
	var pts := PackedVector2Array([tip, tail_l, tail_r])
	draw_colored_polygon(pts, color)
	# Outline so the wedge stays readable against varied backdrops.
	draw_polyline(PackedVector2Array([tip, tail_l, tail_r, tip]), Color(0, 0, 0, 0.85), 1.5)
