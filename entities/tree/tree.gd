class_name DestructibleTree
extends StaticBody3D

# 2 shots from the gun (damage 2 each) → MAX_HEALTH = 4.
const MAX_HEALTH: int = 4
const FALL_DURATION: float = 1.1
const LOG_LIFETIME: float = 30.0
const WOOD_PER_LOG: int = 2

var health: int = MAX_HEALTH
var _falling: bool = false
var _picked: bool = false
var _visual: Node3D
var _height: float = 1.0
# Cached terrain reference for grass-occluder calls. Trees are added as
# children of the terrain node, so get_parent() is the terrain at runtime.
var _terrain: Node
# After the fall finishes, the log becomes collectible: each frame we measure
# the player's distance to the log's midpoint and, if close enough, grant
# wood. Polling beats Area3D here because the player can already be inside
# the pickup volume when the area arms (the area's body_entered signal does
# not fire for bodies that were already inside on the first physics step).
const PICKUP_RADIUS: float = 1.8
var _collectible: bool = false
var _log_center: Vector3
var _log_axis: Vector3
var _half_len: float = 1.0

func _ready() -> void:
	# Layers 1 + 3: player blocks (layer 1), sword + gun can deal damage (layer 3).
	collision_layer = 5
	collision_mask = 0
	_terrain = get_parent()

func setup(parts: Array, scale_xyz: Vector3, union_aabb: AABB) -> void:
	_visual = Node3D.new()
	_visual.scale = scale_xyz
	add_child(_visual)
	for part in parts:
		var mi := MeshInstance3D.new()
		mi.mesh = part.mesh
		mi.transform = part.xform
		_visual.add_child(mi)

	_height = union_aabb.size.y * scale_xyz.y

	# Capsule at the trunk — standard for foliage. Polyhaven AABBs include the
	# canopy, so we use a fraction of the smaller horizontal dimension as a
	# trunk-radius estimate, then clamp to a sensible floor so saplings don't
	# get a giant invisible trunk and full-grown trees don't have a pencil-thin
	# one that the player can clip through.
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	var horiz_scale: float = maxf(scale_xyz.x, scale_xyz.z)
	var trunk_radius: float = minf(union_aabb.size.x, union_aabb.size.z) * horiz_scale * 0.12
	cap.radius = clampf(trunk_radius, 0.18, 0.55)
	cap.height = maxf(_height * 0.8, 1.0)
	col.shape = cap
	col.position = Vector3(0, cap.height * 0.5 + cap.radius, 0)
	add_child(col)

func take_damage(amount: int, dir: Vector3) -> void:
	if _falling or health <= 0:
		return
	health -= amount
	if health <= 0:
		_fall(dir)

# Topple the tree, spawn a stump, register grass occluders for both, and arm
# an Area3D so the player can walk into the fallen log for wood.
func _fall(dir: Vector3) -> void:
	_falling = true
	collision_layer = 0
	Vfx.impact_burst(global_position + Vector3(0, _height * 0.4, 0), 1.2, Color(0.45, 0.30, 0.18, 1))
	_spawn_stump()

	var horiz := Vector3(dir.x, 0.0, dir.z)
	if horiz.length() < 0.01:
		var a: float = randf() * TAU
		horiz = Vector3(cos(a), 0.0, sin(a))
	horiz = horiz.normalized()
	var fall_axis: Vector3 = Vector3.UP.cross(horiz).normalized()

	var target_basis: Basis = Basis(fall_axis, PI * 0.5) * _visual.basis
	var tw := create_tween()
	tw.tween_property(_visual, "basis", target_basis, FALL_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	var wobble_basis: Basis = Basis(fall_axis, PI * 0.5 - 0.08) * _visual.basis
	tw.tween_property(_visual, "basis", wobble_basis, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_visual, "basis", target_basis, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(_arm_pickup.bind(horiz))
	tw.tween_interval(LOG_LIFETIME)
	tw.tween_callback(_despawn)

func _arm_pickup(horiz: Vector3) -> void:
	if _picked or not is_instance_valid(self):
		return
	_log_axis = horiz.normalized()
	_log_center = global_position + _log_axis * _height * 0.5 + Vector3(0, 0.4, 0)
	_half_len = _height * 0.5
	_collectible = true
	# Player.gd scans this group each frame, picks the nearest log within
	# PICKUP_RADIUS, shows a "Press P to pick up" prompt, and calls
	# pick_up_by(self) when P is pressed.
	add_to_group("wood_pickup")

# Closest point on the log's centerline to `world_pos`, used by the player to
# rank nearby logs and decide which one the prompt should target.
func nearest_point(world_pos: Vector3) -> Vector3:
	var rel: Vector3 = world_pos - _log_center
	var t: float = clampf(rel.dot(_log_axis), -_half_len, _half_len)
	return _log_center + _log_axis * t

func is_collectible() -> bool:
	return _collectible and not _picked

func pick_up_by(player: Node) -> void:
	if _picked:
		return
	_picked = true
	remove_from_group("wood_pickup")
	if player.has_method("add_wood"):
		player.call("add_wood", WOOD_PER_LOG)
	_despawn()

func _despawn() -> void:
	queue_free()

func _spawn_stump() -> void:
	var stump_radius: float = maxf(_height * 0.05, 0.32)
	var stump_height: float = 0.55
	var stump_body := StaticBody3D.new()
	stump_body.collision_layer = 1
	stump_body.collision_mask = 0
	var cm := CylinderMesh.new()
	cm.top_radius = stump_radius * 0.9
	cm.bottom_radius = stump_radius
	cm.height = stump_height
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.22, 0.12)
	mat.roughness = 0.95
	cm.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.position = Vector3(0, stump_height * 0.5, 0)
	stump_body.add_child(mi)
	var stump_col := CollisionShape3D.new()
	var stump_shape := CylinderShape3D.new()
	stump_shape.radius = stump_radius
	stump_shape.height = stump_height
	stump_col.shape = stump_shape
	stump_col.position = Vector3(0, stump_height * 0.5, 0)
	stump_body.add_child(stump_col)
	get_parent().add_child.call_deferred(stump_body)
	stump_body.set_deferred("global_transform", Transform3D(Basis.IDENTITY, global_position))
