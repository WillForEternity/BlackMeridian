extends Node

# Build mode. Owned by the player and only active when the player toggles it
# on (key "build_toggle", default B). While active:
#   - 1 = log (costs 2 wood), 2 = plank (costs 1 wood)
#   - mouse wheel = rotate ghost yaw in 15° steps
#   - left click = place (consumes wood)
#   - right click = cancel
# Placement uses a forward raycast from the camera. If the cast hits or comes
# near an existing placed_log, the ghost snaps to that log's nearest snap
# anchor (top-stack OR perpendicular at either end) so cabin walls line up.

const PLACE_RANGE: float = 6.0
const SNAP_RADIUS: float = 1.8

const LOG_SCRIPT := preload("res://entities/wood/placed_log.gd")
const PLANK_SCRIPT := preload("res://entities/wood/placed_plank.gd")

enum Kind { LOG, PLANK }

var active: bool = false
var kind: int = Kind.LOG
var yaw: float = 0.0   # ghost yaw in radians

var player: Node3D            # set by the Player on instantiation
var _camera: Camera3D
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _has_snap: bool = false

func _ready() -> void:
	set_process(true)
	set_process_unhandled_input(true)
	if player != null:
		_camera = player.get_node_or_null("CameraPitchPivot/Camera3D") as Camera3D
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.albedo_color = Color(0.4, 0.95, 0.4, 0.55)
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

func set_active(on: bool) -> void:
	active = on
	if active:
		_rebuild_ghost()
	else:
		if is_instance_valid(_ghost):
			_ghost.queue_free()
			_ghost = null

func _rebuild_ghost() -> void:
	if is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = MeshInstance3D.new()
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.material_override = _ghost_mat
	if kind == Kind.LOG:
		var cm := CylinderMesh.new()
		cm.top_radius = LOG_SCRIPT.RADIUS
		cm.bottom_radius = LOG_SCRIPT.RADIUS
		cm.height = LOG_SCRIPT.LENGTH
		# Pre-rotate so the cylinder lies along local +X (matches PlacedLog).
		var mw := MeshInstance3D.new()
		mw.mesh = cm
		mw.rotation = Vector3(0, 0, PI * 0.5)
		_ghost.add_child(mw)
	else:
		var bm := BoxMesh.new()
		bm.size = Vector3(PLANK_SCRIPT.LENGTH, PLANK_SCRIPT.THICKNESS, PLANK_SCRIPT.WIDTH)
		_ghost.mesh = bm
	get_tree().current_scene.add_child(_ghost)

func _process(_dt: float) -> void:
	if not active or _camera == null or _ghost == null:
		return
	var pose: Dictionary = _resolve_placement()
	if pose.is_empty():
		_ghost.visible = false
		return
	_ghost.visible = true
	_ghost.global_transform = pose.xform as Transform3D
	_has_snap = pose.snapped as bool
	_ghost_mat.albedo_color = Color(0.4, 0.95, 0.4, 0.55) if _can_afford() else Color(0.95, 0.4, 0.4, 0.55)

# Raycast forward; if we hit something, position the ghost at the hit. Then
# scan nearby placed_logs and, if any anchor is within SNAP_RADIUS of the hit,
# override with the snapped pose. Returns {} if the cast misses entirely.
func _resolve_placement() -> Dictionary:
	var from: Vector3 = _camera.global_position
	var to: Vector3 = from - _camera.global_transform.basis.z * PLACE_RANGE
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1
	# Don't let the cast hit the player's own body.
	if player is CollisionObject3D:
		q.exclude = [(player as CollisionObject3D).get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	var anchor: Vector3
	var hit_normal: Vector3 = Vector3.UP
	if hit.is_empty():
		anchor = to
	else:
		anchor = hit.position
		hit_normal = (hit.get("normal", Vector3.UP) as Vector3).normalized()
	# Try to snap to a nearby placed log's anchors.
	var snap: Dictionary = _find_snap(anchor)
	if not snap.is_empty():
		return {"xform": snap.xform as Transform3D, "snapped": true}
	# Free placement: align the log to the slope so its full length contacts
	# the ground (a flat-Y basis on a hillside leaves one end hovering). Yaw
	# still controls the heading around the surface normal.
	var yaw_dir: Vector3 = Vector3(cos(yaw), 0.0, sin(yaw))
	# Reject yaw_dir's component along the normal so the log's length axis
	# lies in the local tangent plane; degenerate fallback for vertical walls.
	var tangent_x: Vector3 = yaw_dir - hit_normal * yaw_dir.dot(hit_normal)
	if tangent_x.length() < 0.01:
		tangent_x = Vector3.RIGHT
	tangent_x = tangent_x.normalized()
	var tangent_z: Vector3 = hit_normal.cross(tangent_x).normalized()
	var basis := Basis(tangent_x, hit_normal, tangent_z)
	# Lift along the surface normal so the bias is "into the ground" on slopes,
	# not into the +Y axis. RADIUS*0.35 keeps the underside settled against the
	# surface without floating above it.
	var lift_mag: float
	if kind == Kind.LOG:
		lift_mag = LOG_SCRIPT.RADIUS * 0.35
	else:
		lift_mag = PLANK_SCRIPT.THICKNESS * 0.5
	return {
		"xform": Transform3D(basis, anchor + hit_normal * lift_mag),
		"snapped": false
	}

func _find_snap(near: Vector3) -> Dictionary:
	var best_d: float = SNAP_RADIUS
	var best: Dictionary = {}
	for n in get_tree().get_nodes_in_group("placed_log"):
		var placed := n as Node3D
		if placed == null or not is_instance_valid(placed):
			continue
		# Cheap cull: skip logs whose center is more than a full length away
		# from the cursor — none of their anchors could be in range.
		if placed.global_position.distance_to(near) > LOG_SCRIPT.LENGTH:
			continue
		for a in (placed.call("snap_anchors") as Array):
			var d: float = (a.pos as Vector3).distance_to(near)
			if d >= best_d:
				continue
			best_d = d
			best = _snap_xform(a, placed, near)
	return best

# Resolve a snap candidate into a placement transform.
#  - "top"  → new log stacks parallel above the target's midpoint.
#  - "end"  → new log extends OUT from the target's end. We pick from three
#             outward directions {straight, perp-left, perp-right} by taking
#             whichever the cursor is leaning toward (highest horizontal dot
#             product with `cursor - end`). The new log's NEAR END lands on
#             the target's end (end-to-end, not end-to-middle).
func _snap_xform(anchor: Dictionary, target_log: Node3D, cursor: Vector3) -> Dictionary:
	var axis: Vector3 = (anchor.axis as Vector3).normalized()
	var pos: Vector3 = anchor.pos as Vector3
	var t_xform: Transform3D
	if kind == Kind.LOG:
		if anchor.type == "top":
			t_xform = Transform3D(_basis_aligned_x(axis), pos)
		else:
			var outward: Vector3 = (anchor.outward as Vector3).normalized()
			var perp: Vector3 = Vector3.UP.cross(outward).normalized()
			var ext: Vector3 = _pick_end_extension(pos, cursor, outward, perp)
			# End-to-end: new log's near end lands on `pos`. Its center is one
			# half-length along the chosen extension direction.
			var new_center: Vector3 = pos + ext * (LOG_SCRIPT.LENGTH * 0.5)
			t_xform = Transform3D(_basis_aligned_x(ext), new_center)
	else:
		# Planks snap parallel to the target's axis; on "top" they ride one
		# log-radius higher so the underside sits flush with the log's top.
		var bx: Basis = _basis_aligned_x(axis)
		var lift: float = PLANK_SCRIPT.THICKNESS * 0.5
		if anchor.type == "top":
			lift += LOG_SCRIPT.RADIUS - PLANK_SCRIPT.THICKNESS * 0.5
		t_xform = Transform3D(bx, pos + Vector3(0, lift, 0))
	return {"xform": t_xform, "snapped": true, "target": target_log}

# Among {straight-out, perp-left, perp-right}, pick the one most aligned with
# the cursor's horizontal offset from the end. Ties resolve to "straight."
func _pick_end_extension(end_pos: Vector3, cursor: Vector3, outward: Vector3, perp: Vector3) -> Vector3:
	var to_cursor: Vector3 = cursor - end_pos
	to_cursor.y = 0.0
	if to_cursor.length() < 0.001:
		return outward
	var dot_out: float = to_cursor.dot(outward)
	var dot_perp_pos: float = to_cursor.dot(perp)
	var dot_perp_neg: float = to_cursor.dot(-perp)
	if dot_out >= dot_perp_pos and dot_out >= dot_perp_neg:
		return outward
	return perp if dot_perp_pos >= dot_perp_neg else -perp

# Build a basis whose +X points along `axis` (horizontal). Keeps Y as up so
# placed logs lie flat on a level world.
func _basis_aligned_x(axis: Vector3) -> Basis:
	var x: Vector3 = Vector3(axis.x, 0.0, axis.z).normalized()
	if x.length() < 0.01:
		x = Vector3.RIGHT
	var y: Vector3 = Vector3.UP
	var z: Vector3 = x.cross(y).normalized()
	return Basis(x, y, z)

func _can_afford() -> bool:
	if player == null or not player.has_method("get_wood"):
		return false
	var cost: int = 2 if kind == Kind.LOG else 1
	return (player.call("get_wood") as int) >= cost

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_try_place()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			set_active(false)
			if player.has_method("on_build_mode_exited"):
				player.call("on_build_mode_exited")
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			yaw = wrapf(yaw + deg_to_rad(15.0), -PI, PI)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			yaw = wrapf(yaw - deg_to_rad(15.0), -PI, PI)
	elif event is InputEventKey and event.pressed and not event.echo:
		var ek := event as InputEventKey
		if ek.keycode == KEY_1:
			kind = Kind.LOG
			_rebuild_ghost()
		elif ek.keycode == KEY_2:
			kind = Kind.PLANK
			_rebuild_ghost()

func _try_place() -> void:
	if _ghost == null or not _ghost.visible:
		return
	if not _can_afford():
		return
	var cost: int = 2 if kind == Kind.LOG else 1
	if player.has_method("spend_wood"):
		player.call("spend_wood", cost)
	var placed: StaticBody3D = (LOG_SCRIPT if kind == Kind.LOG else PLANK_SCRIPT).new()
	get_tree().current_scene.add_child(placed)
	placed.global_transform = _ghost.global_transform
