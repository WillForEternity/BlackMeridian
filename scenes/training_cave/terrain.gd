class_name Terrain
extends Node3D

# Procedural rocky terrain. Generates a 1 km × 1 km heightmap from layered
# noise on _ready, builds it as a grid of per-chunk meshes (so the renderer
# can frustum-cull off-screen chunks), and adds a single HeightMapShape3D for
# physics. Tweak `noise_seed` for a new shape, the AMP/FREQ constants for
# terrain character.

const SIZE: float = 1024.0          # extent in meters along X and Z
const GRID: int = 1025              # vertices per side (1024 cells × 1 m = 1024 m)
const CELL: float = SIZE / float(GRID - 1)
const CHUNKS_PER_SIDE: int = 8
const CHUNK_CELLS: int = (GRID - 1) / CHUNKS_PER_SIDE   # 128 cells per chunk
const CHUNK_VERTS: int = CHUNK_CELLS + 1                # 129 verts per chunk edge

# Base noise = gentle rolling terrain everywhere.
const BASE_FREQ: float = 0.003
const BASE_AMP: float = 6.0

# Placement noise = where mountains exist. Thresholded so most of the map
# outputs zero contribution.
const PLACEMENT_FREQ: float = 0.0008
const PLACEMENT_THRESHOLD: float = 0.48
const PLACEMENT_FADE: float = 0.65
const EDGE_BIAS_STRENGTH: float = 0.35

# Ridge noise = mountain shape. Gated by the placement mask.
const RIDGE_FREQ: float = 0.0006
const RIDGE_AMP: float = 180.0

const DETAIL_FREQ: float = 0.05
const DETAIL_AMP: float = 1.5

const WARP_FREQ: float = 0.0015
const WARP_AMP: float = 50.0

@export var noise_seed: int = 1337
@export var flatten_origin: bool = true

func _ready() -> void:
	var heights: PackedFloat32Array = _generate_heights()
	if flatten_origin:
		var center_h: float = heights[(GRID / 2) * GRID + (GRID / 2)]
		for i in heights.size():
			heights[i] -= center_h
	# Shallower valleys: anything below the spawn plane is compressed by half.
	for i in heights.size():
		if heights[i] < 0.0:
			heights[i] *= 0.5
	_build_chunks(heights)
	_attach_collision(heights)

func _generate_heights() -> PackedFloat32Array:
	var base := FastNoiseLite.new()
	base.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	base.seed = noise_seed
	base.frequency = BASE_FREQ
	base.fractal_type = FastNoiseLite.FRACTAL_FBM
	base.fractal_octaves = 4
	base.fractal_lacunarity = 2.1
	base.fractal_gain = 0.5

	var placement := FastNoiseLite.new()
	placement.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	placement.seed = noise_seed + 5
	placement.frequency = PLACEMENT_FREQ
	placement.fractal_type = FastNoiseLite.FRACTAL_FBM
	placement.fractal_octaves = 3

	var ridge := FastNoiseLite.new()
	ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ridge.seed = noise_seed + 11
	ridge.frequency = RIDGE_FREQ
	ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridge.fractal_octaves = 5
	ridge.fractal_lacunarity = 2.0
	ridge.fractal_gain = 0.5

	var detail := FastNoiseLite.new()
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail.seed = noise_seed + 23
	detail.frequency = DETAIL_FREQ
	detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail.fractal_octaves = 3

	var warp := FastNoiseLite.new()
	warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
	warp.seed = noise_seed + 37
	warp.frequency = WARP_FREQ

	var heights := PackedFloat32Array()
	heights.resize(GRID * GRID)
	var half: float = SIZE * 0.5
	for z in GRID:
		for x in GRID:
			var wx: float = float(x) * CELL - half
			var wz: float = float(z) * CELL - half
			var sx: float = wx + warp.get_noise_2d(wx, wz) * WARP_AMP
			var sz: float = wz + warp.get_noise_2d(wx + 999.0, wz + 999.0) * WARP_AMP
			var b: float = base.get_noise_2d(sx, sz)
			var p01: float = (placement.get_noise_2d(sx, sz) + 1.0) * 0.5
			var dist_norm: float = clampf(Vector2(wx, wz).length() / (SIZE * 0.5), 0.0, 1.0)
			p01 += dist_norm * dist_norm * EDGE_BIAS_STRENGTH
			var mask: float = smoothstep(PLACEMENT_THRESHOLD, PLACEMENT_THRESHOLD + PLACEMENT_FADE, p01)
			var r: float = ridge.get_noise_2d(sx, sz)
			var d: float = detail.get_noise_2d(sx, sz)
			heights[z * GRID + x] = b * BASE_AMP + mask * r * RIDGE_AMP + d * DETAIL_AMP
	return heights

# Build CHUNKS_PER_SIDE × CHUNKS_PER_SIDE MeshInstance3D children. Each chunk
# covers CHUNK_CELLS × CHUNK_CELLS cells of the global heightmap and shares
# its edge vertices with adjacent chunks (so no seam gaps). Per-vertex
# normals are computed analytically from the GLOBAL heights, which means
# chunk boundaries get matching normals — no visible seam shading.
func _build_chunks(heights: PackedFloat32Array) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.52, 0.46, 0.40, 1.0)
	mat.roughness = 0.95
	mat.metallic = 0.0
	for cz in CHUNKS_PER_SIDE:
		for cx in CHUNKS_PER_SIDE:
			var mi := MeshInstance3D.new()
			mi.mesh = _build_chunk_mesh(heights, cx, cz)
			mi.material_override = mat
			add_child(mi)

func _build_chunk_mesh(heights: PackedFloat32Array, cx: int, cz: int) -> ArrayMesh:
	var n_verts: int = CHUNK_VERTS * CHUNK_VERTS
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	verts.resize(n_verts)
	normals.resize(n_verts)
	uvs.resize(n_verts)

	var half: float = SIZE * 0.5
	var x_base: int = cx * CHUNK_CELLS
	var z_base: int = cz * CHUNK_CELLS
	for z in CHUNK_VERTS:
		for x in CHUNK_VERTS:
			var gx: int = x_base + x
			var gz: int = z_base + z
			var wx: float = float(gx) * CELL - half
			var wz: float = float(gz) * CELL - half
			var i: int = z * CHUNK_VERTS + x
			verts[i] = Vector3(wx, heights[gz * GRID + gx], wz)
			uvs[i] = Vector2(wx, wz) / SIZE
			normals[i] = _heightmap_normal(heights, gx, gz)

	for z in CHUNK_CELLS:
		for x in CHUNK_CELLS:
			var tl: int = z * CHUNK_VERTS + x
			var tr: int = tl + 1
			var bl: int = tl + CHUNK_VERTS
			var br: int = bl + 1
			indices.append(tl); indices.append(tr); indices.append(bl)
			indices.append(tr); indices.append(br); indices.append(bl)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var arr := ArrayMesh.new()
	arr.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return arr

# Analytical heightmap normal via central differences in X and Z. Sampled
# from the global heightmap so cross-chunk normals match exactly.
func _heightmap_normal(heights: PackedFloat32Array, gx: int, gz: int) -> Vector3:
	var x_l: int = max(gx - 1, 0)
	var x_r: int = min(gx + 1, GRID - 1)
	var z_u: int = max(gz - 1, 0)
	var z_d: int = min(gz + 1, GRID - 1)
	var dx: float = (heights[gz * GRID + x_r] - heights[gz * GRID + x_l]) / (float(x_r - x_l) * CELL)
	var dz: float = (heights[z_d * GRID + gx] - heights[z_u * GRID + gx]) / (float(z_d - z_u) * CELL)
	return Vector3(-dx, 1.0, -dz).normalized()

func _attach_collision(heights: PackedFloat32Array) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var col := CollisionShape3D.new()
	var shape := HeightMapShape3D.new()
	shape.map_width = GRID
	shape.map_depth = GRID
	shape.map_data = heights
	col.shape = shape
	col.scale = Vector3(CELL, 1.0, CELL)
	body.add_child(col)
	add_child(body)
