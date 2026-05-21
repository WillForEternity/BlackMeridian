# Auto-generates static collision for every MeshInstance3D under this node's
# parent. Best-practice: one simplified convex hull per mesh part. Convex hulls
# wrap arbitrary geometry tightly with very few verts after simplify, and unlike
# concave trimesh they're cheap enough that we don't have to think about it for
# props with hundreds of thousands of triangles (e.g. character statues). For
# truly concave set-pieces where the gap matters (an archway you walk through),
# author authored colliders or split the mesh into multiple convex parts.
extends Node

func _ready() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for m in _collect_meshes(parent):
		_attach_convex(m)

func _collect_meshes(node: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is MeshInstance3D:
			out.append(c)
		out.append_array(_collect_meshes(c))
	return out

func _attach_convex(mi: MeshInstance3D) -> void:
	var mesh: Mesh = mi.mesh
	if mesh == null:
		return
	var hull: ConvexPolygonShape3D = mesh.create_convex_shape(true, true)
	if hull == null:
		return
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	col.shape = hull
	body.add_child(col)
	mi.add_child(body)
