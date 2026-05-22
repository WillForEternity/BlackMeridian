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
	collision_layer = 1
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

# Polyhaven bark scan — matches the rest of the foliage style. The ARM map
# packs ambient occlusion (R), roughness (G), and metallic (B) into one image.
const _BARK_DIFF := preload("res://assets/polyhaven/textures/bark_brown_02/bark_brown_02_diff_1k.jpg")
const _BARK_NOR := preload("res://assets/polyhaven/textures/bark_brown_02/bark_brown_02_nor_gl_1k.jpg")
const _BARK_ARM := preload("res://assets/polyhaven/textures/bark_brown_02/bark_brown_02_arm_1k.jpg")

# Concentric-ring shader for the stump top — model-space radial distance feeds
# a noisy sinusoid so each stump shows wood-grain rings rather than a flat
# disc. Compiled once and reused across all stump instances.
static var _stump_top_shader_cache: Shader

static func _stump_top_shader() -> Shader:
	if _stump_top_shader_cache != null:
		return _stump_top_shader_cache
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform float seed = 0.0;
varying vec3 model_pos;

void vertex() {
	model_pos = VERTEX;
}

void fragment() {
	// Distance from the cylinder's Y axis = ring radius.
	float r = length(vec2(model_pos.x, model_pos.z));
	// Low-freq warp so the rings aren't perfect circles.
	float warp = sin(model_pos.x * 8.0 + seed) * 0.02 + cos(model_pos.z * 8.0 - seed * 0.7) * 0.02;
	float rings = sin((r + warp) * 80.0 + sin((r + warp) * 16.0) * 2.5);
	float ring_band = smoothstep(-0.3, 0.5, rings);
	vec3 dark = vec3(0.50, 0.36, 0.20);
	vec3 light = vec3(0.78, 0.61, 0.39);
	vec3 col = mix(dark, light, ring_band);
	// Heartwood darkens slightly toward the center.
	float heart = smoothstep(0.0, 0.10, r);
	col = mix(col * 0.78, col, heart);
	// Fine grain noise.
	float grain = sin(model_pos.x * 73.0 + model_pos.z * 53.0 + seed * 12.0);
	col += vec3(grain * 0.03);
	ALBEDO = col;
	ROUGHNESS = 0.78;
	METALLIC = 0.0;
}
"""
	_stump_top_shader_cache = sh
	return sh

func _spawn_stump() -> void:
	var stump_radius: float = maxf(_height * 0.05, 0.32)
	var stump_height: float = 0.55
	var stump_body := StaticBody3D.new()
	stump_body.collision_layer = 1
	stump_body.collision_mask = 0
	# Bark-textured trunk side with a slight root flare at the base.
	var side_mesh := CylinderMesh.new()
	side_mesh.top_radius = stump_radius * 0.88
	side_mesh.bottom_radius = stump_radius * 1.12
	side_mesh.height = stump_height
	side_mesh.radial_segments = 18
	side_mesh.rings = 1
	side_mesh.cap_top = false
	side_mesh.cap_bottom = false
	var side_mat := StandardMaterial3D.new()
	side_mat.albedo_texture = _BARK_DIFF
	side_mat.normal_enabled = true
	side_mat.normal_texture = _BARK_NOR
	side_mat.ao_enabled = true
	side_mat.ao_texture = _BARK_ARM
	side_mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	side_mat.roughness_texture = _BARK_ARM
	side_mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	side_mat.metallic_texture = _BARK_ARM
	side_mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	side_mat.uv1_scale = Vector3(2.0, 1.0, 1.0)
	side_mesh.material = side_mat
	var side_mi := MeshInstance3D.new()
	side_mi.mesh = side_mesh
	side_mi.position = Vector3(0, stump_height * 0.5, 0)
	stump_body.add_child(side_mi)
	# Cut top: thin lighter-wood disc with a procedural concentric-ring shader.
	# The rings are warped by low-freq noise so they don't read as a perfect
	# bullseye; a per-stump seed shifts the pattern between instances.
	var top_mesh := CylinderMesh.new()
	top_mesh.top_radius = stump_radius * 0.86
	top_mesh.bottom_radius = stump_radius * 0.86
	top_mesh.height = 0.04
	top_mesh.radial_segments = 24
	top_mesh.rings = 1
	var top_mat := ShaderMaterial.new()
	top_mat.shader = _stump_top_shader()
	top_mat.set_shader_parameter("seed", randf() * 100.0)
	top_mesh.material = top_mat
	var top_mi := MeshInstance3D.new()
	top_mi.mesh = top_mesh
	top_mi.position = Vector3(0, stump_height + 0.005, 0)
	stump_body.add_child(top_mi)
	var stump_col := CollisionShape3D.new()
	var stump_shape := CylinderShape3D.new()
	stump_shape.radius = stump_radius
	stump_shape.height = stump_height
	stump_col.shape = stump_shape
	stump_col.position = Vector3(0, stump_height * 0.5, 0)
	stump_body.add_child(stump_col)
	# Random yaw so the bark texture seam doesn't always face the same way.
	var rot := Basis(Vector3.UP, randf() * TAU)
	get_parent().add_child.call_deferred(stump_body)
	stump_body.set_deferred("global_transform", Transform3D(rot, global_position))
