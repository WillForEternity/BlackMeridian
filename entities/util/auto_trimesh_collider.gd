# Auto-generates static collision for every MeshInstance3D under this node's
# parent.
#
# Preference order (fastest valid fit wins):
#   1) V-HACD convex decomposition (Mesh.convex_decompose) — N small convex
#      hulls that shrink-wrap concavities while staying cheap. Requires this
#      Godot build to include the V-HACD module (this one doesn't, so we
#      fall through).
#   2) Poor-man's spatial decomposition — bin triangles by centroid into an
#      NxNxN grid, build a simplified convex hull per non-empty cell. Gives
#      ~5–15 cheap hulls per statue, follows concavities reasonably well, and
#      every hull is convex so per-query cost is roughly constant.
#   3) Single simplified convex hull — last resort for tiny / degenerate
#      meshes the spatial split rejected.
#
# Trimesh (`create_trimesh_shape()`) is intentionally NOT in the chain: even
# though it gives a perfect shrink-wrap, querying it against a moving
# CharacterBody3D scales with triangle count and made jumping on the Polyhaven
# statues unplayably laggy.
extends Node

const SPATIAL_DIVISIONS: int = 3   # 3^3 = 27 cells max; humanoid statues land on ~6–10 occupied

func _ready() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for m in _collect_meshes(parent):
		_attach_collider(m)

func _collect_meshes(node: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is MeshInstance3D:
			out.append(c)
		out.append_array(_collect_meshes(c))
	return out

func _attach_collider(mi: MeshInstance3D) -> void:
	var mesh: Mesh = mi.mesh
	if mesh == null:
		return

	var shapes: Array = []

	# Tier 1: V-HACD.
	if mesh.has_method("convex_decompose") and ClassDB.class_exists("MeshConvexDecompositionSettings"):
		var settings: Variant = ClassDB.instantiate("MeshConvexDecompositionSettings")
		if settings != null:
			settings.max_convex_hulls = 16
			settings.resolution = 100000
			settings.convex_hull_approximation = true
			var decomposed: Variant = mesh.convex_decompose(settings)
			if decomposed is Array:
				shapes = decomposed

	# Tier 2: spatial bucket decomposition.
	if shapes.is_empty():
		shapes = _spatial_decompose(mesh)

	# Tier 3: single hull.
	if shapes.is_empty():
		var hull: ConvexPolygonShape3D = mesh.create_convex_shape(true, false)
		if hull != null:
			shapes = [hull]

	if shapes.is_empty():
		return

	var body := StaticBody3D.new()
	for s in shapes:
		var col := CollisionShape3D.new()
		col.shape = s
		body.add_child(col)
	mi.add_child(body)

# Bucket every triangle into one of SPATIAL_DIVISIONS^3 cells by centroid,
# then build a simplified convex hull from each cell's triangle vertices.
# Triangles that straddle a cell boundary still contribute ALL their vertices
# to the cell their centroid falls in, so adjacent hulls overlap at the seam
# and the player doesn't fall through the cracks.
func _spatial_decompose(mesh: Mesh) -> Array:
	var box := mesh.get_aabb()
	if box.size.x < 0.01 or box.size.y < 0.01 or box.size.z < 0.01:
		return []
	var cells: Dictionary = {}
	for si in mesh.get_surface_count():
		var arr: Array = mesh.surface_get_arrays(si)
		if arr.size() <= Mesh.ARRAY_VERTEX:
			continue
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var indices: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr.size() > Mesh.ARRAY_INDEX else PackedInt32Array()
		var tri_count: int = (indices.size() / 3) if not indices.is_empty() else (verts.size() / 3)
		for ti in tri_count:
			var a: Vector3
			var b: Vector3
			var c: Vector3
			if indices.is_empty():
				a = verts[ti * 3]
				b = verts[ti * 3 + 1]
				c = verts[ti * 3 + 2]
			else:
				a = verts[indices[ti * 3]]
				b = verts[indices[ti * 3 + 1]]
				c = verts[indices[ti * 3 + 2]]
			var centroid: Vector3 = (a + b + c) / 3.0
			var key: int = _cell_key(centroid, box)
			var bag: PackedVector3Array = cells.get(key, PackedVector3Array())
			bag.append(a)
			bag.append(b)
			bag.append(c)
			cells[key] = bag
	var hulls: Array = []
	for points in cells.values():
		var h: ConvexPolygonShape3D = _hull_from_points(points)
		if h != null:
			hulls.append(h)
	return hulls

func _cell_key(p: Vector3, box: AABB) -> int:
	var rel: Vector3 = p - box.position
	var cx: int = clampi(int(rel.x / box.size.x * SPATIAL_DIVISIONS), 0, SPATIAL_DIVISIONS - 1)
	var cy: int = clampi(int(rel.y / box.size.y * SPATIAL_DIVISIONS), 0, SPATIAL_DIVISIONS - 1)
	var cz: int = clampi(int(rel.z / box.size.z * SPATIAL_DIVISIONS), 0, SPATIAL_DIVISIONS - 1)
	return (cx * SPATIAL_DIVISIONS + cy) * SPATIAL_DIVISIONS + cz

# Wrap a point cloud in a simplified convex hull by funnelling it through a
# throwaway ArrayMesh — Godot's only public path to the hull builder. We use
# simplify=false because the simplify path internally calls convex_decompose,
# which this build is missing.
func _hull_from_points(points: PackedVector3Array) -> ConvexPolygonShape3D:
	if points.size() < 4:
		return null
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = points
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am.create_convex_shape(true, false)
