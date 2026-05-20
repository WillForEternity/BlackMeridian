class_name PlacedLog
extends StaticBody3D

# Dimensions tuned so snapping (top-stack + perpendicular-end) lines up
# visually without needing per-asset offsets. Length along local +X.
const LENGTH: float = 2.6
const RADIUS: float = 0.22

# Player blocks (layer 1); damageable layer 3 is intentionally left off so
# weapons don't accidentally chip away at the player's own build.
func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	add_to_group("placed_log")
	_build()
	_register_occluder()

func _exit_tree() -> void:
	# Best-effort grass-occluder cleanup so removed logs stop hiding grass.
	var terrain := get_tree().current_scene.get_node_or_null("Terrain")
	if terrain != null and terrain.has_method("remove_grass_occluder"):
		terrain.remove_grass_occluder(get_instance_id())

func _build() -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = RADIUS
	cm.bottom_radius = RADIUS
	cm.height = LENGTH
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.27, 0.14)
	mat.roughness = 0.95
	cm.material = mat
	mi.mesh = cm
	# Cylinder is Y-up by default; rotate so its long axis lies along local +X.
	mi.rotation = Vector3(0, 0, PI * 0.5)
	add_child(mi)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Box collider keeps stacking math trivial (flat tops/sides), and is
	# cheaper than the cylinder shape for the player's slide checks.
	box.size = Vector3(LENGTH, RADIUS * 2.0, RADIUS * 2.0)
	col.shape = box
	add_child(col)

func _register_occluder() -> void:
	var terrain := get_tree().current_scene.get_node_or_null("Terrain")
	if terrain != null and terrain.has_method("add_grass_occluder"):
		var xz := Vector2(global_position.x, global_position.z)
		terrain.add_grass_occluder(get_instance_id(), xz, LENGTH * 0.5)

# World-space snap anchors offered to the build system. The build system picks
# the closest one to the cursor, then resolves a placement transform.
#   type == "top": new log stacks parallel above this log's midpoint.
#   type == "end": new log extends OUTWARD from this end (straight or one of
#                  two perpendiculars), with its NEAR END at this end. The
#                  `outward` vector points from the log's center toward this
#                  end so the build system can offer "continue straight" vs.
#                  the two perpendicular corners.
func snap_anchors() -> Array:
	var fwd: Vector3 = global_transform.basis.x.normalized()
	var up: Vector3 = Vector3.UP
	var half_len: Vector3 = fwd * LENGTH * 0.5
	var out: Array = []
	out.append({
		"pos": global_position + up * (RADIUS * 2.0),
		"type": "top",
		"axis": fwd,
		"outward": fwd,
	})
	out.append({
		"pos": global_position + half_len,
		"type": "end",
		"axis": fwd,
		"outward": fwd,
	})
	out.append({
		"pos": global_position - half_len,
		"type": "end",
		"axis": fwd,
		"outward": -fwd,
	})
	return out
