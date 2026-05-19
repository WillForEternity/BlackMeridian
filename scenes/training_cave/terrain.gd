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

# --- Foliage ---
# Grass: procedural 7-segment tapered blade mesh, instanced via per-chunk
# MultiMeshInstance3D, animated by a world-space wind vertex shader (two-octave
# sin + slow gust envelope, tip-biased bend via pow(uv.y, 2)). Per-instance
# custom data carries (lean_x, lean_z, dryness, hue) so each blade has its own
# resting curve and color.
# Trees: scanned from TREE_DIR (Quaternius). Multi-part GLBs are walked
# recursively and one MultiMesh is emitted per (variant, sub-mesh) so
# trunk/leaves keep their separate materials.
# --- Grass: two systems ---
# 1) PATCH: a dense, camera-locked MultiMesh that follows the player. Fixed
#    instance count, never reallocated. Heights are resolved in the vertex
#    shader from a heightmap texture, so camera movement costs nothing on the
#    CPU. Blades fade to zero height at the patch edge so the seam disappears.
# 2) TILES: sparse far-field. A sliding disk of tiles around the camera,
#    rebuilt only when the camera crosses a threshold, and only a budgeted
#    number of tiles per frame — so dashing never stalls; the field fills in.
const GRASS_TILE_SIZE: float = 40.0
const GRASS_STREAM_RADIUS: float = 520.0   # patch covers ~106m; tiles must reach well past that
const GRASS_REBUILD_THRESHOLD: float = 8.0
const GRASS_TILE_SPAWN_BUDGET: int = 6     # tiles built per frame, max
const GRASS_SPACING: float = 0.55          # tile scatter spacing (tight = full field)
const GRASS_TALL_CHANCE: float = 0.28      # probability of an extra tall blade
const GRASS_TALL_HEIGHT_SCALE: float = 2.1
const GRASS_TALL_WIDTH_SCALE: float = 1.3
const GRASS_BLADE_HEIGHT: float = 0.58
const GRASS_BLADE_WIDTH: float = 0.05
const GRASS_BLADE_SEGMENTS: int = 7
const GRASS_MIN_NORMAL_Y: float = 0.78        # matches ground shader's rock_mask onset — no grass on stone
const GRASS_MAX_ELEV: float = 55.0
const GRASS_ELEV_FADE: float = 14.0

# Camera-locked patch: dense carpet at the player's feet.
# Two layers: SHORT is thick and static (no wind shader); TALL is sparse and
# animated. Together they read as "a lot of grass with occasional sway."
const PATCH_SIZE: float = 220.0            # full side length in meters
const PATCH_SHORT_GRID: int = 833          # ~15/m² (2/3 of prior density)
const PATCH_TALL_GRID: int = 277          # +1/3 density vs prior
# Inner "core" — a small ultra-dense patch right at the player's feet. Always
# inside FADE_INNER, so the shader's taper never culls it.
const PATCH_CORE_SIZE: float = 60.0
const PATCH_CORE_GRID: int = 820
const PATCH_CORE_FADE_INNER: float = 22.0
const PATCH_CORE_FADE_OUTER: float = 30.0
const PATCH_SNAP: float = 1.0              # snap follow to whole meters (no shimmer)
# Density profile: full inside FADE_INNER, tapers smoothly to zero at FADE_OUTER
# via per-blade probabilistic skip — no visible ring at the boundary.
const PATCH_FADE_INNER: float = 56.0
const PATCH_FADE_OUTER: float = 106.0
# Match the rock onset in the ground shader so patch grass discards on stone.
const PATCH_MIN_NORMAL_Y: float = 0.78

const TREE_DIR: String = "res://assets/quaternius/trees/"
const TREE_FALLBACK_PATHS := [
	"res://assets/kenney/nature-kit/Models/GLB format/tree_oak.glb",
	"res://assets/kenney/nature-kit/Models/GLB format/tree_tall.glb",
	"res://assets/kenney/nature-kit/Models/GLB format/tree_detailed.glb",
	"res://assets/kenney/nature-kit/Models/GLB format/tree_fat.glb",
]
const TREE_SPACING: float = 18.4
const TREE_MIN_NORMAL_Y: float = 0.78
const TREE_MIN_ELEV: float = -1.0
const TREE_MAX_ELEV: float = 48.0
const TREE_PLACEMENT_FREQ: float = 0.0055
const TREE_PLACEMENT_THRESHOLD: float = 0.56
const TREE_SCALE_BASE: float = 1.6        # Quaternius/Kenney are ~3m tall stock; bump for "mature oak"
const TREE_SCALE_JITTER: float = 0.6
# Trees stream identically to grass tiles: deterministic per-(tx,tz) seed so
# the world looks the same every visit; only nearby tiles are instantiated.
const TREE_TILE_SIZE: float = 50.0
const TREE_STREAM_RADIUS: float = 340.0
const TREE_REBUILD_THRESHOLD: float = 15.0
const TREE_TILE_SPAWN_BUDGET: int = 1

@export var noise_seed: int = 1337
@export var flatten_origin: bool = true

var _grass_mesh: ArrayMesh
var _grass_mesh_tall: ArrayMesh
var _grass_material_short: ShaderMaterial
var _grass_material_tall: ShaderMaterial
var _grass_material_patch_short: ShaderMaterial
var _grass_material_patch_tall: ShaderMaterial
var _grass_material_patch_core: ShaderMaterial
var _height_tex: ImageTexture
var _grass_patch_mmis: Array = []   # [short MMI, tall MMI]
# Each tree variant is Array of {"mesh": Mesh, "xform": Transform3D} — parts of a multi-mesh GLB.
var _tree_variants: Array = []
var _heights: PackedFloat32Array
# Streaming state: tile_coord (Vector2i) -> {"mmis": Array}
var _grass_tiles: Dictionary = {}
# FIFO of pending tile builds: [{"key": Vector2i, "tx": int, "tz": int}]
var _tile_spawn_queue: Array = []
var _last_stream_pos: Vector3 = Vector3.INF
# Tree streaming: same shape as grass, larger tiles + radius.
var _tree_tiles: Dictionary = {}
var _tree_spawn_queue: Array = []
var _last_tree_stream_pos: Vector3 = Vector3.INF
var _tree_placement_noise: FastNoiseLite

func _ready() -> void:
	_heights = _generate_heights()
	if flatten_origin:
		var center_h: float = _heights[(GRID / 2) * GRID + (GRID / 2)]
		for i in _heights.size():
			_heights[i] -= center_h
	# Shallower valleys: anything below the spawn plane is compressed by half.
	for i in _heights.size():
		if _heights[i] < 0.0:
			_heights[i] *= 0.5
	_build_chunks(_heights)
	_attach_collision(_heights)
	_build_height_texture()
	_init_foliage_resources()
	_build_grass_patch()
	_init_tree_placement_noise()

func _process(_dt: float) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	var pos: Vector3 = cam.global_position
	# Patch follows the camera every frame, snapped to whole meters so blades
	# don't crawl. Heights are resolved GPU-side — no rebuild cost.
	if not _grass_patch_mmis.is_empty():
		var sx: float = round(pos.x / PATCH_SNAP) * PATCH_SNAP
		var sz: float = round(pos.z / PATCH_SNAP) * PATCH_SNAP
		var origin := Vector3(sx, 0.0, sz)
		var center := Vector2(sx, sz)
		for mmi in _grass_patch_mmis:
			(mmi as MultiMeshInstance3D).global_position = origin
		_grass_material_patch_short.set_shader_parameter("patch_center", center)
		_grass_material_patch_tall.set_shader_parameter("patch_center", center)
		_grass_material_patch_core.set_shader_parameter("patch_center", center)
	# Tile streaming: only re-survey when the camera has moved enough, and
	# never build more than GRASS_TILE_SPAWN_BUDGET tiles per frame.
	if _last_stream_pos.x == INF or pos.distance_to(_last_stream_pos) >= GRASS_REBUILD_THRESHOLD:
		_last_stream_pos = pos
		_stream_grass(pos)
	if _last_tree_stream_pos.x == INF or pos.distance_to(_last_tree_stream_pos) >= TREE_REBUILD_THRESHOLD:
		_last_tree_stream_pos = pos
		_stream_trees(pos)
	_flush_tile_queue()
	_flush_tree_queue()

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
	var mat := _build_ground_material()
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

# --- Foliage --------------------------------------------------------------

func _init_foliage_resources() -> void:
	_grass_mesh = _build_grass_blade_mesh(1.0, 1.0)
	_grass_mesh_tall = _build_grass_blade_mesh(GRASS_TALL_HEIGHT_SCALE, GRASS_TALL_WIDTH_SCALE)
	_grass_material_short = _build_grass_material(false)
	_grass_material_tall = _build_grass_material(true)
	_grass_material_patch_short = _build_grass_patch_material(false)
	_grass_material_patch_tall = _build_grass_patch_material(true)
	_grass_material_patch_core = _build_grass_patch_material(false)
	_grass_material_patch_core.set_shader_parameter("fade_inner", PATCH_CORE_FADE_INNER)
	_grass_material_patch_core.set_shader_parameter("fade_outer", PATCH_CORE_FADE_OUTER)
	_tree_variants = _load_tree_variants()

func _build_height_texture() -> void:
	# Pack the heightmap into a 1-channel float texture so the patch vertex
	# shader can resolve terrain height per blade without any CPU work.
	var img := Image.create_from_data(
		GRID, GRID, false, Image.FORMAT_RF, _heights.to_byte_array()
	)
	_height_tex = ImageTexture.create_from_image(img)

func _build_grass_patch() -> void:
	# Two stacked grids in LOCAL space. The patch node follows the camera; the
	# vertex shader lifts each blade onto the terrain via _height_tex and
	# collapses blades to zero height past the patch fade radius. Short layer
	# is thick and static; tall layer is sparse and animated.
	_grass_patch_mmis.append(
		_make_patch_layer(PATCH_SIZE, PATCH_SHORT_GRID, _grass_mesh, _grass_material_patch_short, 0)
	)
	_grass_patch_mmis.append(
		_make_patch_layer(PATCH_SIZE, PATCH_TALL_GRID, _grass_mesh_tall, _grass_material_patch_tall, 1)
	)
	# Core: small + extremely dense. Sits fully inside FADE_INNER so the
	# shader's radial taper never culls any of these blades.
	_grass_patch_mmis.append(
		_make_patch_layer(PATCH_CORE_SIZE, PATCH_CORE_GRID, _grass_mesh, _grass_material_patch_core, 2)
	)
	for mmi in _grass_patch_mmis:
		add_child(mmi)

func _make_patch_layer(
	patch_size: float, grid: int, mesh: ArrayMesh, mat: ShaderMaterial, _salt: int
) -> MultiMeshInstance3D:
	# World-anchored grass. Bake identity-only instances on a regular grid; the
	# vertex shader snaps each blade's root to the nearest world-space cell and
	# derives jitter/yaw/scale/lean/dryness/hue from a hash of that cell. The
	# result: when the patch slides with the camera, instance N migrates to a
	# different world cell — but because the cell's content is deterministic,
	# the *visual* is rock-solid. No shimmer, no crawl.
	var step: float = patch_size / float(grid)
	var half: float = patch_size * 0.5
	var radius_sq: float = half * half
	var transforms: Array[Transform3D] = []
	for iz in grid:
		for ix in grid:
			var lx: float = -half + (float(ix) + 0.5) * step
			var lz: float = -half + (float(iz) + 0.5) * step
			if lx * lx + lz * lz > radius_sq:
				continue
			transforms.append(Transform3D(Basis.IDENTITY, Vector3(lx, 0.0, lz)))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = false
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(
		Vector3(-half, -200.0, -half),
		Vector3(patch_size, 400.0, patch_size)
	)
	mmi.set_meta("cell_step", step)
	mat.set_shader_parameter("cell_step", step)
	return mmi

func _init_tree_placement_noise() -> void:
	_tree_placement_noise = FastNoiseLite.new()
	_tree_placement_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_tree_placement_noise.seed = noise_seed + 91
	_tree_placement_noise.frequency = TREE_PLACEMENT_FREQ

# --- Grass streaming ----------------------------------------------------------
# Maintain a disk of grass tiles centered on the camera. Tile coords are
# Vector2i (tx, tz); a tile covers world x ∈ [tx*S, (tx+1)*S], same for z.
# We add tiles that entered the disk and free tiles that left. Tile scatter
# is deterministic from (noise_seed, tx, tz) so re-entering a tile reproduces
# the same blade layout.
func _stream_grass(pos: Vector3) -> void:
	var center_tx: int = int(floor(pos.x / GRASS_TILE_SIZE))
	var center_tz: int = int(floor(pos.z / GRASS_TILE_SIZE))
	var tile_radius: int = int(ceil(GRASS_STREAM_RADIUS / GRASS_TILE_SIZE)) + 1
	var radius_sq: float = GRASS_STREAM_RADIUS * GRASS_STREAM_RADIUS

	var needed: Dictionary = {}
	for dz in range(-tile_radius, tile_radius + 1):
		for dx in range(-tile_radius, tile_radius + 1):
			var tx: int = center_tx + dx
			var tz: int = center_tz + dz
			var cx: float = (float(tx) + 0.5) * GRASS_TILE_SIZE
			var cz: float = (float(tz) + 0.5) * GRASS_TILE_SIZE
			var ddx: float = cx - pos.x
			var ddz: float = cz - pos.z
			if ddx * ddx + ddz * ddz > radius_sq:
				continue
			var key := Vector2i(tx, tz)
			needed[key] = true
			if not _grass_tiles.has(key):
				_tile_spawn_queue.append({"key": key, "tx": tx, "tz": tz})

	# Free tiles that left the disk.
	var to_remove: Array = []
	for key in _grass_tiles.keys():
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		for mmi in (_grass_tiles[key] as Dictionary).mmis:
			(mmi as MultiMeshInstance3D).queue_free()
		_grass_tiles.erase(key)

	# Drop queued tiles no longer needed.
	var pruned: Array = []
	for entry in _tile_spawn_queue:
		if needed.has(entry.key) and not _grass_tiles.has(entry.key):
			pruned.append(entry)
	_tile_spawn_queue = pruned

func _flush_tile_queue() -> void:
	var budget: int = GRASS_TILE_SPAWN_BUDGET
	while budget > 0 and not _tile_spawn_queue.is_empty():
		var entry: Dictionary = _tile_spawn_queue.pop_front()
		if _grass_tiles.has(entry.key):
			continue
		_spawn_tile(entry.key, entry.tx, entry.tz)
		budget -= 1

func _spawn_tile(key: Vector2i, tx: int, tz: int) -> void:
	var mmis: Array = _build_grass_tile(tx, tz)
	for mmi in mmis:
		add_child(mmi)
	# Always record the tile, even if empty, so we don't re-queue it.
	_grass_tiles[key] = {"mmis": mmis}

func _build_grass_tile(tx: int, tz: int) -> Array:
	var x0: float = float(tx) * GRASS_TILE_SIZE
	var z0: float = float(tz) * GRASS_TILE_SIZE
	var half: float = SIZE * 0.5
	if x0 + GRASS_TILE_SIZE < -half or x0 > half or z0 + GRASS_TILE_SIZE < -half or z0 > half:
		return []
	var rng := RandomNumberGenerator.new()
	rng.seed = noise_seed * 7919 + tz * 100003 + tx
	var n_side: int = int(GRASS_TILE_SIZE / GRASS_SPACING)

	var short_t: Array[Transform3D] = []
	var short_c: Array[Color] = []
	var tall_t: Array[Transform3D] = []
	var tall_c: Array[Color] = []

	for iz in n_side:
		for ix in n_side:
			var wx: float = x0 + (float(ix) + rng.randf()) * GRASS_SPACING
			var wz: float = z0 + (float(iz) + rng.randf()) * GRASS_SPACING
			if wx < -half or wx > half or wz < -half or wz > half:
				continue
			var n: Vector3 = _sample_normal(_heights, wx, wz)
			if n.y < GRASS_MIN_NORMAL_Y:
				continue
			var h: float = _sample_height(_heights, wx, wz)
			var elev_fade: float = 1.0 - clampf((h - GRASS_MAX_ELEV) / GRASS_ELEV_FADE, 0.0, 1.0)
			if elev_fade <= 0.0 or rng.randf() > elev_fade:
				continue
			var slope_density: float = smoothstep(GRASS_MIN_NORMAL_Y, 0.95, n.y)
			if rng.randf() > slope_density:
				continue
			var up: Vector3 = n.lerp(Vector3.UP, 0.65).normalized()
			var align := Basis(Quaternion(Vector3.UP, up))
			var yaw := Basis(Vector3.UP, rng.randf() * TAU)
			var sy: float = 0.75 + rng.randf() * 0.55
			var sw: float = 0.85 + rng.randf() * 0.30
			var pos := Vector3(wx, h, wz)
			short_t.append(Transform3D(align * yaw * Basis().scaled(Vector3(sw, sy, sw)), pos))
			var dryness: float = clampf((h - 10.0) / 35.0, 0.0, 1.0) * 0.7 + rng.randf() * 0.2
			var col := Color(
				(rng.randf() * 2.0 - 1.0) * 0.7,
				(rng.randf() * 2.0 - 1.0) * 0.7,
				dryness,
				rng.randf()
			)
			short_c.append(col)
			if rng.randf() < GRASS_TALL_CHANCE:
				var sy2: float = 0.95 + rng.randf() * 0.55
				var sw2: float = 0.85 + rng.randf() * 0.30
				var yaw2 := Basis(Vector3.UP, rng.randf() * TAU)
				tall_t.append(Transform3D(align * yaw2 * Basis().scaled(Vector3(sw2, sy2, sw2)), pos))
				tall_c.append(col)

	var out: Array = []
	var aabb := AABB(
		Vector3(x0, -50.0, z0),
		Vector3(GRASS_TILE_SIZE, 400.0, GRASS_TILE_SIZE)
	)
	if not short_t.is_empty():
		out.append(_make_grass_mmi(short_t, short_c, _grass_mesh, _grass_material_short, aabb))
	if not tall_t.is_empty():
		out.append(_make_grass_mmi(tall_t, tall_c, _grass_mesh_tall, _grass_material_tall, aabb))
	return out

func _make_grass_mmi(
	tr: Array[Transform3D],
	cu: Array[Color],
	mesh: ArrayMesh,
	mat: ShaderMaterial,
	aabb: AABB
) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = tr.size()
	for i in tr.size():
		mm.set_instance_transform(i, tr[i])
		mm.set_instance_custom_data(i, cu[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = aabb
	return mmi

# --- Tree streaming -----------------------------------------------------------
# Mirrors grass streaming, just with bigger tiles + a longer view radius.
# Per-(tx,tz) seeding guarantees identical placement every visit.
func _stream_trees(pos: Vector3) -> void:
	if _tree_variants.is_empty():
		return
	var center_tx: int = int(floor(pos.x / TREE_TILE_SIZE))
	var center_tz: int = int(floor(pos.z / TREE_TILE_SIZE))
	var tile_radius: int = int(ceil(TREE_STREAM_RADIUS / TREE_TILE_SIZE)) + 1
	var radius_sq: float = TREE_STREAM_RADIUS * TREE_STREAM_RADIUS

	var needed: Dictionary = {}
	for dz in range(-tile_radius, tile_radius + 1):
		for dx in range(-tile_radius, tile_radius + 1):
			var tx: int = center_tx + dx
			var tz: int = center_tz + dz
			var cx: float = (float(tx) + 0.5) * TREE_TILE_SIZE
			var cz: float = (float(tz) + 0.5) * TREE_TILE_SIZE
			var ddx: float = cx - pos.x
			var ddz: float = cz - pos.z
			if ddx * ddx + ddz * ddz > radius_sq:
				continue
			var key := Vector2i(tx, tz)
			needed[key] = true
			if not _tree_tiles.has(key):
				_tree_spawn_queue.append({"key": key, "tx": tx, "tz": tz})

	var to_remove: Array = []
	for key in _tree_tiles.keys():
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		for mmi in (_tree_tiles[key] as Dictionary).mmis:
			(mmi as MultiMeshInstance3D).queue_free()
		_tree_tiles.erase(key)

	var pruned: Array = []
	for entry in _tree_spawn_queue:
		if needed.has(entry.key) and not _tree_tiles.has(entry.key):
			pruned.append(entry)
	_tree_spawn_queue = pruned

func _flush_tree_queue() -> void:
	var budget: int = TREE_TILE_SPAWN_BUDGET
	while budget > 0 and not _tree_spawn_queue.is_empty():
		var entry: Dictionary = _tree_spawn_queue.pop_front()
		if _tree_tiles.has(entry.key):
			continue
		var mmis: Array = _build_tree_tile(entry.tx, entry.tz)
		for mmi in mmis:
			add_child(mmi)
		_tree_tiles[entry.key] = {"mmis": mmis}
		budget -= 1

func _build_tree_tile(tx: int, tz: int) -> Array:
	var x0: float = float(tx) * TREE_TILE_SIZE
	var z0: float = float(tz) * TREE_TILE_SIZE
	var half: float = SIZE * 0.5
	if x0 + TREE_TILE_SIZE < -half or x0 > half or z0 + TREE_TILE_SIZE < -half or z0 > half:
		return []
	var rng := RandomNumberGenerator.new()
	rng.seed = noise_seed * 104729 + tz * 100003 + tx
	var n_side: int = int(TREE_TILE_SIZE / TREE_SPACING)

	var per_variant: Array = []
	per_variant.resize(_tree_variants.size())
	for i in _tree_variants.size():
		per_variant[i] = []

	for iz in n_side:
		for ix in n_side:
			var wx: float = x0 + (float(ix) + rng.randf()) * TREE_SPACING
			var wz: float = z0 + (float(iz) + rng.randf()) * TREE_SPACING
			if wx < -half or wx > half or wz < -half or wz > half:
				continue
			var p: float = (_tree_placement_noise.get_noise_2d(wx, wz) + 1.0) * 0.5
			if p < TREE_PLACEMENT_THRESHOLD:
				continue
			var n: Vector3 = _sample_normal(_heights, wx, wz)
			if n.y < TREE_MIN_NORMAL_Y:
				continue
			var h: float = _sample_height(_heights, wx, wz)
			if h < TREE_MIN_ELEV or h > TREE_MAX_ELEV:
				continue
			var variant: int = rng.randi() % _tree_variants.size()
			var up: Vector3 = n.lerp(Vector3.UP, 0.7).normalized()
			var align := Basis(Quaternion(Vector3.UP, up))
			var yaw := Basis(Vector3.UP, rng.randf() * TAU)
			var s: float = TREE_SCALE_BASE + rng.randf() * TREE_SCALE_JITTER
			var scale := Basis().scaled(Vector3(s, s + rng.randf() * 0.4, s))
			(per_variant[variant] as Array).append(
				Transform3D(align * yaw * scale, Vector3(wx, h - 0.1, wz))
			)

	var aabb := AABB(
		Vector3(x0, -10.0, z0),
		Vector3(TREE_TILE_SIZE, 400.0, TREE_TILE_SIZE)
	)
	var out: Array = []
	for i in _tree_variants.size():
		var ts: Array = per_variant[i]
		if ts.is_empty():
			continue
		var parts: Array = _tree_variants[i]
		# One MultiMesh per sub-part of the tree (trunk, leaves...) so each keeps
		# its imported material.
		for part in parts:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = part.mesh
			mm.instance_count = ts.size()
			for j in ts.size():
				mm.set_instance_transform(j, (ts[j] as Transform3D) * (part.xform as Transform3D))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.custom_aabb = aabb
			out.append(mmi)
	return out

# --- Procedural grass blade ---------------------------------------------------

func _build_grass_blade_mesh(height_scale: float, width_scale: float) -> ArrayMesh:
	# Tapered ribbon: GRASS_BLADE_SEGMENTS+1 vertex rows, 2 verts each (left/right
	# of midline), width tapering to 10% at tip. UV.y carries the bend factor.
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var segs: int = GRASS_BLADE_SEGMENTS
	var height: float = GRASS_BLADE_HEIGHT * height_scale
	var width: float = GRASS_BLADE_WIDTH * width_scale
	for i in segs + 1:
		var t: float = float(i) / float(segs)
		var y: float = t * height
		var w: float = width * (1.0 - t * 0.9) * 0.5
		verts.append(Vector3(-w, y, 0.0))
		verts.append(Vector3(w, y, 0.0))
		norms.append(Vector3(0.0, 0.0, 1.0))
		norms.append(Vector3(0.0, 0.0, 1.0))
		uvs.append(Vector2(0.0, t))
		uvs.append(Vector2(1.0, t))
	for i in segs:
		var base: int = i * 2
		indices.append_array([base, base + 2, base + 1, base + 1, base + 2, base + 3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am

func _build_grass_material(with_wind: bool) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

uniform vec3 base_color   : source_color = vec3(0.03, 0.10, 0.03);
uniform vec3 tip_lush     : source_color = vec3(0.30, 0.60, 0.16);
uniform vec3 tip_meadow   : source_color = vec3(0.42, 0.66, 0.22);
uniform vec3 tip_dry      : source_color = vec3(0.55, 0.88, 0.20);
uniform vec3 tip_yellow   : source_color = vec3(0.82, 0.74, 0.18);
uniform float yellow_chance = 0.18;
uniform float wind_speed     = 1.1;
uniform float wind_strength  = 0.55;
uniform vec2  wind_dir       = vec2(0.7, 0.7);
uniform float patch_scale    = 0.012;     // controls how big the color biomes are

// 2D value noise (cheap, sufficient for color patches)
float h21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	float a = h21(i);
	float b = h21(i + vec2(1.0, 0.0));
	float c = h21(i + vec2(0.0, 1.0));
	float d = h21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}
float fbm(vec2 p) {
	float v = 0.0; float a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * vnoise(p); p *= 2.0; a *= 0.5; }
	return v;
}

varying vec3 v_world_pos;
varying float v_patch;

void vertex() {
	vec3 wo = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_world_pos = wo;
	v_patch = fbm(wo.xz * patch_scale);

	float bend = UV.y;
	float bend2 = bend * bend;

	WIND_BLOCK
	vec2 lean = INSTANCE_CUSTOM.xy * bend2 * 0.35;

	VERTEX.x += sway.x + lean.x;
	VERTEX.z += sway.y + lean.y;
	VERTEX.y -= bend2 * (abs(sway.x) + abs(sway.y) + abs(lean.x) + abs(lean.y)) * 0.18;

	COLOR.r = bend;
	COLOR.g = INSTANCE_CUSTOM.z;
	COLOR.b = INSTANCE_CUSTOM.w;
}

void fragment() {
	float bend = COLOR.r;
	float dry  = COLOR.g;
	float hue  = COLOR.b;

	// Patch noise picks a biome tint for this region of the meadow.
	float patch = v_patch;
	vec3 tip = mix(tip_lush, tip_meadow, smoothstep(0.35, 0.65, patch));
	tip = mix(tip, tip_dry, smoothstep(0.65, 0.85, patch));
	// Minority yellow blades scattered across the field.
	tip = mix(tip, tip_yellow, step(1.0 - yellow_chance, hue));

	vec3 col = mix(base_color, tip, bend);
	// Per-instance dryness pulls toward dry tip color
	col = mix(col, mix(base_color * 0.85, tip_dry, bend), dry * 0.7);
	// Per-instance hue jitter
	col *= mix(0.85, 1.15, hue);
	// Base AO so root area reads dark
	col *= mix(0.55, 1.0, bend);

	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.05;
	// Backlit tip: lift emission when sun behind the blade (cheap SSS fake).
	EMISSION = tip * 0.06 * bend;
	// Normal soften toward up so the field reads as a mass.
	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), bend * 0.65));
}
"""
	var wind_block: String
	if with_wind:
		wind_block = """
	float t = TIME * wind_speed;
	float w1 = sin(wo.x * 0.18 + wo.z * 0.13 + t);
	float w2 = sin(wo.x * 0.55 - wo.z * 0.42 + t * 1.7);
	float gust = sin(wo.x * 0.04 + wo.z * 0.06 + t * 0.4) * 0.5 + 0.5;
	float w = (w1 * 0.7 + w2 * 0.3) * mix(0.4, 1.2, gust);
	vec2 sway = wind_dir * w * wind_strength * bend2;
"""
	else:
		wind_block = "\tvec2 sway = vec2(0.0);\n"
	sh.code = sh.code.replace("\tWIND_BLOCK", wind_block)
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

# Patch material: vertex shader samples _height_tex to lift each blade onto
# the terrain, and collapses blades to zero height past PATCH_FADE_OUTER so
# the seam to the sparse tile field is invisible. Same wind model as the
# tall-blade tile shader.
func _build_grass_patch_material(with_wind: bool) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled, world_vertex_coords;

uniform sampler2D heightmap : filter_linear, repeat_disable;
uniform float terrain_size = 1024.0;
uniform float terrain_cell = 1.0;
uniform vec2  patch_center = vec2(0.0);
uniform float fade_inner   = 5.5;
uniform float fade_outer   = 7.0;
uniform float min_normal_y = 0.72;
uniform float max_elev     = 55.0;
uniform float cell_step    = 0.21;

uniform vec3  base_color  : source_color = vec3(0.03, 0.10, 0.03);
uniform vec3  tip_meadow  : source_color = vec3(0.40, 0.66, 0.20);
uniform vec3  tip_dry     : source_color = vec3(0.55, 0.88, 0.20);
uniform vec3  tip_yellow  : source_color = vec3(0.82, 0.74, 0.18);
uniform float yellow_chance = 0.18;
uniform float wind_speed     = 1.1;
uniform float wind_strength  = 0.55;
uniform vec2  wind_dir       = vec2(0.7, 0.7);

float sample_h(vec2 wxz) {
	vec2 uv = (wxz + vec2(terrain_size * 0.5)) / terrain_size;
	return texture(heightmap, uv).r;
}

float h12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
vec2 h22(vec2 p) {
	return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453);
}

void vertex() {
	// World-anchored blade. The instance's world XZ is snapped to the nearest
	// fixed world cell, and all per-blade variation is hashed off that cell.
	// Patch slides → instances get reassigned to different cells, but each
	// cell always renders the same blade. Result: no shimmer.
	vec3 wo = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec2 cell = floor(wo.xz / cell_step + 0.5);
	vec2 cell_origin = cell * cell_step;
	vec2 jitter = (h22(cell + 13.7) - 0.5) * cell_step * 0.85;
	vec2 anchored = cell_origin + jitter;

	float yaw    = h12(cell + 1.3) * 6.2831853;
	float sw     = 0.85 + h12(cell + 7.9) * 0.30;
	float sy     = 0.75 + h12(cell + 3.1) * 0.55;
	float dry    = h12(cell + 5.5);
	float hue    = h12(cell + 9.2);
	vec2  lean_c = (h22(cell + 11.0) * 2.0 - 1.0) * 0.7;
	float surv   = h12(cell + 17.0);

	float h = sample_h(anchored);

	// Slope from heightmap (central differences) — discard on rocky terrain.
	float h_l = sample_h(anchored + vec2(-terrain_cell, 0.0));
	float h_r = sample_h(anchored + vec2( terrain_cell, 0.0));
	float h_d = sample_h(anchored + vec2(0.0, -terrain_cell));
	float h_u = sample_h(anchored + vec2(0.0,  terrain_cell));
	float dx = (h_r - h_l) / (2.0 * terrain_cell);
	float dz = (h_u - h_d) / (2.0 * terrain_cell);
	float ny = 1.0 / sqrt(dx*dx + dz*dz + 1.0);

	float r = length(anchored - patch_center);
	float density = 1.0 - smoothstep(fade_inner, fade_outer, r);
	float keep = step(surv, density);
	float elev = 1.0 - smoothstep(max_elev - 5.0, max_elev, h);
	float slope_keep = step(min_normal_y, ny);
	keep *= elev * slope_keep;

	// Strip baked world translation, apply blade-local width scale + yaw.
	vec2 local_xz = (VERTEX.xz - wo.xz) * sw;
	float c = cos(yaw); float s = sin(yaw);
	local_xz = vec2(local_xz.x * c - local_xz.y * s, local_xz.x * s + local_xz.y * c);
	float local_y = VERTEX.y * sy * keep;

	float bend  = UV.y;
	float bend2 = bend * bend;

	WIND_BLOCK
	vec2 lean = lean_c * bend2 * 0.35;

	VERTEX.x = anchored.x + local_xz.x + sway.x + lean.x;
	VERTEX.z = anchored.y + local_xz.y + sway.y + lean.y;
	VERTEX.y = h + local_y - bend2 * (abs(sway.x) + abs(sway.y) + abs(lean.x) + abs(lean.y)) * 0.18;

	COLOR.r = bend;
	COLOR.g = dry;
	COLOR.b = hue;
}

void fragment() {
	float bend = COLOR.r;
	float dry  = COLOR.g;
	float hue  = COLOR.b;
	// Minority of blades pick yellow instead of lime for their "dry" tone.
	vec3 dry_tip = mix(tip_dry, tip_yellow, step(1.0 - yellow_chance, hue));
	vec3 tip = mix(tip_meadow, dry_tip, dry);
	vec3 col = mix(base_color, tip, bend);
	col *= mix(0.85, 1.15, hue);
	col *= mix(0.55, 1.0, bend);
	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.05;
	EMISSION = tip * 0.06 * bend;
	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), bend * 0.65));
}
"""
	var wind_block: String
	if with_wind:
		wind_block = """
	float t = TIME * wind_speed;
	float w1 = sin(wo.x * 0.18 + wo.z * 0.13 + t);
	float w2 = sin(wo.x * 0.55 - wo.z * 0.42 + t * 1.7);
	float gust = sin(wo.x * 0.04 + wo.z * 0.06 + t * 0.4) * 0.5 + 0.5;
	float w = (w1 * 0.7 + w2 * 0.3) * mix(0.4, 1.2, gust);
	vec2 sway = wind_dir * w * wind_strength * bend2;
"""
	else:
		wind_block = "\tvec2 sway = vec2(0.0);\n"
	sh.code = sh.code.replace("\tWIND_BLOCK", wind_block)
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("heightmap", _height_tex)
	mat.set_shader_parameter("terrain_size", SIZE)
	mat.set_shader_parameter("terrain_cell", CELL)
	mat.set_shader_parameter("fade_inner", PATCH_FADE_INNER)
	mat.set_shader_parameter("fade_outer", PATCH_FADE_OUTER)
	mat.set_shader_parameter("min_normal_y", PATCH_MIN_NORMAL_Y)
	mat.set_shader_parameter("max_elev", GRASS_MAX_ELEV)
	return mat

# --- Ground material ----------------------------------------------------------

func _build_ground_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 grass_lush  : source_color = vec3(0.18, 0.30, 0.08);
uniform vec3 grass_dry   : source_color = vec3(0.42, 0.44, 0.18);
uniform vec3 dirt_dark   : source_color = vec3(0.20, 0.13, 0.07);
uniform vec3 dirt_light  : source_color = vec3(0.42, 0.30, 0.18);
uniform vec3 rock_dark   : source_color = vec3(0.22, 0.21, 0.20);
uniform vec3 rock_light  : source_color = vec3(0.55, 0.52, 0.48);
uniform vec3 snow_color  : source_color = vec3(0.93, 0.95, 0.97);
uniform float snowline       = 65.0;
uniform float snowline_fade  = 10.0;
uniform float grass_normal_y = 0.78;     // above this = considered "flat enough" for grass
uniform float rock_normal_y  = 0.55;     // below this = bare rock dominates
uniform float patch_scale    = 0.012;
uniform float detail_scale   = 0.18;

float h21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	float a = h21(i);
	float b = h21(i + vec2(1.0, 0.0));
	float c = h21(i + vec2(0.0, 1.0));
	float d = h21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}
float fbm(vec2 p) {
	float v = 0.0; float a = 0.5;
	for (int i = 0; i < 5; i++) { v += a * vnoise(p); p *= 2.05; a *= 0.5; }
	return v;
}

varying vec3 v_wpos;
varying vec3 v_wnrm;

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 wp = v_wpos;
	float slope = clamp(v_wnrm.y, 0.0, 1.0);
	float elev  = wp.y;

	// Multi-octave noise drives biome patches + small-detail breakup.
	float patch  = fbm(wp.xz * patch_scale);
	float detail = fbm(wp.xz * detail_scale);

	// Grass color varies across the meadow (lush in valleys → dry on shoulders).
	vec3 grass = mix(grass_lush, grass_dry, smoothstep(0.35, 0.75, patch));
	grass *= mix(0.85, 1.10, detail);

	// Dirt patches: appear where high-freq noise spikes, OR on moderate slopes.
	vec3 dirt = mix(dirt_dark, dirt_light, fbm(wp.xz * 0.4));
	float dirt_patch = smoothstep(0.62, 0.78, fbm(wp.xz * 0.08));
	float dirt_slope = smoothstep(grass_normal_y, grass_normal_y - 0.12, slope);
	float dirt_mask  = max(dirt_patch * 0.6, dirt_slope);

	vec3 ground = mix(grass, dirt, dirt_mask);

	// Rock dominates on steep faces.
	vec3 rock = mix(rock_dark, rock_light, fbm(wp.xz * 0.5));
	rock *= mix(0.9, 1.1, fbm(wp.xz * 2.0));
	float rock_mask = smoothstep(rock_normal_y + 0.20, rock_normal_y, slope);
	ground = mix(ground, rock, rock_mask);

	// Snow caps: high elevation + not-too-steep.
	float snow_mask = smoothstep(snowline - snowline_fade, snowline + snowline_fade, elev)
	                * smoothstep(0.55, 0.78, slope);
	snow_mask *= mix(0.85, 1.0, fbm(wp.xz * 0.6));
	ground = mix(ground, snow_color, snow_mask);

	ALBEDO = ground;
	ROUGHNESS = mix(0.95, mix(0.7, 0.5, rock_mask), max(rock_mask, snow_mask * 0.4));
	SPECULAR = mix(0.05, 0.35, snow_mask);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

# --- Tree loading -------------------------------------------------------------

func _load_tree_variants() -> Array:
	var paths := _discover_tree_paths()
	var out: Array = []
	for p in paths:
		var parts := _load_tree_parts(p)
		if not parts.is_empty():
			out.append(parts)
	return out

func _discover_tree_paths() -> Array:
	var paths: Array = []
	var dir := DirAccess.open(TREE_DIR)
	if dir != null:
		dir.list_dir_begin()
		var fname: String = dir.get_next()
		while fname != "":
			if not dir.current_is_dir() and (fname.ends_with(".glb") or fname.ends_with(".gltf")):
				paths.append(TREE_DIR + fname)
			fname = dir.get_next()
	if paths.is_empty():
		push_warning("[Terrain] No tree GLBs in %s — using Kenney fallback. Drop Quaternius .glb files into that folder for the mature look." % TREE_DIR)
		paths = TREE_FALLBACK_PATHS.duplicate()
	return paths

# Returns an Array of {"mesh": Mesh, "xform": Transform3D} for every
# MeshInstance3D in the GLB, with xforms baked relative to the scene root so
# they can be re-applied per-instance in a MultiMesh.
func _load_tree_parts(path: String) -> Array:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		return []
	var root: Node = scene.instantiate()
	var parts: Array = []
	var stack: Array = [{"node": root, "xform": Transform3D.IDENTITY}]
	while not stack.is_empty():
		var entry: Dictionary = stack.pop_back()
		var node: Node = entry.node
		var x: Transform3D = entry.xform
		if node is Node3D:
			x = x * (node as Node3D).transform
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			parts.append({"mesh": (node as MeshInstance3D).mesh, "xform": x})
		for c in node.get_children():
			stack.append({"node": c, "xform": x})
	root.free()
	return parts

# --- Sampling helpers ---------------------------------------------------------

# Bilinear height sample from the global heightmap at arbitrary world XZ.
func _sample_height(heights: PackedFloat32Array, wx: float, wz: float) -> float:
	var half: float = SIZE * 0.5
	var fx: float = clampf((wx + half) / CELL, 0.0, float(GRID - 1) - 0.001)
	var fz: float = clampf((wz + half) / CELL, 0.0, float(GRID - 1) - 0.001)
	var x0: int = int(fx)
	var z0: int = int(fz)
	var tx: float = fx - float(x0)
	var tz: float = fz - float(z0)
	var h00: float = heights[z0 * GRID + x0]
	var h10: float = heights[z0 * GRID + x0 + 1]
	var h01: float = heights[(z0 + 1) * GRID + x0]
	var h11: float = heights[(z0 + 1) * GRID + x0 + 1]
	return lerp(lerp(h00, h10, tx), lerp(h01, h11, tx), tz)

func _sample_normal(heights: PackedFloat32Array, wx: float, wz: float) -> Vector3:
	var half: float = SIZE * 0.5
	var gx: int = clampi(int((wx + half) / CELL), 0, GRID - 1)
	var gz: int = clampi(int((wz + half) / CELL), 0, GRID - 1)
	return _heightmap_normal(heights, gx, gz)

