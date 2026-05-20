class_name DestructibleStone
extends StaticBody3D

# Health matches the training-cave target's max_health, per the brief.
const MAX_HEALTH: int = 6

var health: int = MAX_HEALTH

func _ready() -> void:
	# Layers 1 + 3 (= bitmask 5). Layer 1 → CharacterBody3D player blocks
	# against us. Layer 3 → matches the sword HitArea's collision_mask=4 AND
	# the gun projectile's collision_mask=5, so both weapons can damage us.
	collision_layer = 5
	collision_mask = 0

# `parts` is the variant-loader's shifted parts list (Array of {mesh, xform})
# with the bottom of the unioned mesh already at local y=0. `union_aabb` is the
# matching mesh-local AABB (so size * scale gives a tight collision box).
# `scale_xyz` is the per-instance scale.
func setup(parts: Array, scale_xyz: Vector3, union_aabb: AABB) -> void:
	# Visual children sit under a Node3D that owns the scale, so the
	# StaticBody3D itself stays unscaled (Godot warns about scaled bodies, and
	# more importantly, scaled CollisionShape3Ds are unreliable).
	var visual := Node3D.new()
	visual.scale = scale_xyz
	add_child(visual)
	for part in parts:
		var mi := MeshInstance3D.new()
		mi.mesh = part.mesh
		mi.transform = part.xform
		visual.add_child(mi)

	# Single box collider sized to the scaled AABB. Good enough for the round
	# Kenney cobbles — overestimates slightly at the corners, but the alternative
	# (ConvexPolygonShape3D per mesh) is far more expensive at this density.
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = union_aabb.size * scale_xyz
	col.shape = box
	col.position = (union_aabb.position + union_aabb.size * 0.5) * scale_xyz
	add_child(col)

func take_damage(amount: int, _dir: Vector3) -> void:
	if health <= 0:
		return
	health -= amount
	if health <= 0:
		Vfx.impact_burst(global_position + Vector3(0, 0.4, 0), 1.0, Color(0.55, 0.55, 0.55, 1))
		queue_free()
