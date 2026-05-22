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
const CHUNK_SIZE_M: float = CHUNK_CELLS * CELL          # chunk extent in world meters
# Chunks within this radius of the camera are kept resident; others are freed.
# Pick a value safely beyond the far cull/fog distance so chunks pop in before
# they're visible. Budget caps how many chunk meshes get built per frame.
const CHUNK_STREAM_RADIUS: float = 384.0
const CHUNK_SPAWN_BUDGET: int = 2
const CHUNK_REBUILD_THRESHOLD: float = 16.0
# Far-terrain "billboard floor": one low-poly mesh covering the full world,
# sampled every FAR_CELL meters from the heightmap. Sits FAR_Y_OFFSET below
# the streamed chunks so they hide it where they overlap, leaving only the
# distant background visible. No collision, no streaming, ~one chunk's worth
# of geometry total regardless of SIZE.
const FAR_CELL: float = 8.0
const FAR_Y_OFFSET: float = -0.5

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
const GRASS_TILE_SPAWN_BUDGET: int = 2     # tiles built per frame, max (was 6 — spiked frame time during movement)
const GRASS_SPACING: float = 0.55          # tile scatter spacing (tight = full field)
const GRASS_TALL_CHANCE: float = 0.28      # probability of an extra tall blade
const GRASS_TALL_HEIGHT_SCALE: float = 2.1
const GRASS_TALL_WIDTH_SCALE: float = 1.3
const GRASS_BLADE_HEIGHT: float = 0.58
const GRASS_BLADE_WIDTH: float = 0.05
const GRASS_BLADE_SEGMENTS: int = 3
const GRASS_MIN_NORMAL_Y: float = 0.78        # matches ground shader's rock_mask onset — no grass on stone
const GRASS_MAX_ELEV: float = 55.0
const GRASS_ELEV_FADE: float = 14.0

# Camera-locked patch: dense carpet at the player's feet.
# Two layers: SHORT is thick and static (no wind shader); TALL is sparse and
# animated. Together they read as "a lot of grass with occasional sway."
# Debug: skip ALL grass building/streaming. Useful to baseline non-grass cost.
const GRASS_DISABLED: bool = false
const PATCH_SIZE: float = 220.0            # full side length in meters
const PATCH_SHORT_GRID: int = 833          # ~15/m² (2/3 of prior density)
# TALL fades to zero by 106 m, so allocating blades past ~110 m radius is
# wasted vertex work. Use a smaller patch size + matching grid to drop ~15k
# unnecessary instances while keeping the same per-m² density.
const PATCH_TALL_SIZE: float = 212.0
const PATCH_TALL_GRID: int = 267           # 267²/212² ≈ 1.59 blades/m² (same as before)
# Inner "core" — a small ultra-dense patch right at the player's feet. Always
# inside FADE_INNER, so the shader's taper never culls it.
const PATCH_CORE_SIZE: float = 80.0
const PATCH_CORE_GRID: int = 820
const PATCH_CORE_FADE_INNER: float = 22.0
const PATCH_CORE_FADE_OUTER: float = 40.0
# SUPER_CORE — even smaller, even denser, layered on top of CORE. Adds blades
# in the few-meter region around the player so top-down views read as a solid
# carpet (CORE's ~105 blades/m² shows gaps when looking straight down). Static
# mesh, no wind shader; fades within its own patch boundary.
const PATCH_SUPER_CORE_SIZE: float = 14.0
const PATCH_SUPER_CORE_GRID: int = 275       # 275²/14² ≈ 386 blades/m² — dense but not saturated
const PATCH_SUPER_CORE_FADE_INNER: float = 5.0
const PATCH_SUPER_CORE_FADE_OUTER: float = 7.0
const PATCH_SNAP: float = 1.0              # snap follow to whole meters (no shimmer)

# --- Near-grass duck. In third-person, tilting the look way up swings the
# follow camera down close to the ground; while sprinting that puts grass
# blades directly between the camera and the player, covering the view. When
# both conditions hold — camera looking up at a steep angle (pitch ≥
# DUCK_PITCH_UP_DEG) AND horizontal speed ≥ DUCK_SPEED_THRESHOLD — we push
# CORE / SUPER_CORE patch grass's fade_in_inner/outer outward so a hole opens
# around the camera. The transition is smoothed over DUCK_SMOOTH_RATE so
# grass doesn't pop on/off.
const DUCK_RADIUS_INNER: float = 6.0         # m — full cull within this radius when active
const DUCK_RADIUS_OUTER: float = 8.5         # m — full density past this radius
const DUCK_PITCH_UP_DEG: float = 35.0        # pitch ≥ this (degrees above horizontal) triggers
const DUCK_SPEED_THRESHOLD: float = 5.0      # horiz m/s — matches player.gd JOG_THRESHOLD
const DUCK_SMOOTH_RATE: float = 9.0          # 1/s — exponential lerp toward target inner/outer
# Density profile: full inside FADE_INNER, tapers smoothly to zero at FADE_OUTER
# via per-blade probabilistic skip — no visible ring at the boundary.
const PATCH_FADE_INNER: float = 56.0
const PATCH_FADE_OUTER: float = 106.0
# Match the rock onset in the ground shader so patch grass discards on stone.
const PATCH_MIN_NORMAL_Y: float = 0.78

## Polyhaven photoreal scans, recursively scanned (one subfolder per asset).
## The big "real" Polyhaven trees ship as raw scan geometry (pine_tree_01 is
## a 948 MB .bin because every needle is individual polygons) so we only use
## their saplings / smaller trees / shrubs — still scanned PBR, but loadable.
const TREE_DIR: String = "res://assets/polyhaven/trees/"
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
const TREE_SCALE_BASE: float = 2.5        # Polyhaven ships at real meter scale; saplings ~1-2m natural → scale up for canopy presence
const TREE_SCALE_JITTER: float = 1.2
# Trees stream identically to grass tiles: deterministic per-(tx,tz) seed so
# the world looks the same every visit; only nearby tiles are instantiated.
const TREE_TILE_SIZE: float = 50.0
const TREE_STREAM_RADIUS: float = 340.0
const TREE_REBUILD_THRESHOLD: float = 15.0
const TREE_TILE_SPAWN_BUDGET: int = 1

# --- Stream ---
# A winding stream cut into the heightmap before chunk build, with the water
# ribbon tile-streamed around the camera (same architecture as grass/trees).
# Carve uses a Gaussian falloff (real "inverse bell" cross-section) and tracks
# the ORIGINAL terrain height at each centerline x, so the water surface rests
# just below the natural ground level rather than at a fixed Y.
## OLD river system disabled while the new flow-accumulation river is built.
## Setting this to false:
##  - skips the trench carving (no more 2.2 m bed + 4.8 m vertical banks)
##  - skips lake basin carving + the lake mesh build
##  - skips the water + brook stone tile streamers
##  - drops the grass/tree/stone/flower bank-exclusion masks so foliage fills in
const STREAM_ENABLED: bool = false
const STREAM_WATER_BELOW_ORIGINAL: float = 1.4   # deeper water — surface this far below original terrain
const STREAM_BED_BELOW_ORIGINAL: float = 2.2     # bed deeper than water surface so it doesn't read flat
const STREAM_HALF_WIDTH: float = 3.4             # water surface fills the flat bed (just inside FLAT_HALF_WIDTH)
const STREAM_FLAT_HALF_WIDTH: float = 3.6        # flat bed core fully covers water mesh + sub-cell misalignment
const STREAM_BANK_HALF_WIDTH: float = 4.8        # outer carve → steep banks
const STREAM_Z_AMP: float = 80.0
const STREAM_Z_FREQ: float = 0.0028
const SAND_HALF_WIDTH: float = 4.5               # outer edge of sandy ribbon (must be < STREAM_BANK_HALF_WIDTH, > STREAM_HALF_WIDTH)
const SAND_Y_OFFSET: float = 0.06                # tiny lift above ground to avoid z-fight
const GRASS_BANK_EXCLUSION: float = 5.2          # no grass within this radius of centerline (must exceed STREAM_BANK_HALF_WIDTH)
const TREE_BANK_INFLUENCE: float = 30.0          # within this distance from centerline, trees get a placement boost
const TREE_BANK_BOOST: float = 0.45              # max reduction to placement threshold at the bank
const TREE_BANK_EXCLUSION: float = 5.4           # don't place trees inside the water/sand

# --- Stream path tracing ---
# The centerline is *traced* through the heightmap by gradient descent rather
# than being a 1D sine wave: at each +x step, z drifts toward the local downhill
# (∂h/∂z) with a small noise jitter for meander. Path is monotonic in x so we
# can keep the existing z(x) lookup interface — every consumer (carve, water
# tiles, sand ribbon, brook stones) reads `_centerline_z(wx)` exactly like
# before. Slope along the path is baked into the water mesh's vertex color so
# the surface scroll speed reflects gravity (fast on steeps, slow on flats).
const STREAM_TRACE_MARGIN: int = 60              # grid cells of headroom from each edge
const STREAM_TRACE_STEP_DZ_MAX: float = 0.18     # max |dz| per 1m of dx — keeps the path nearly straight
const STREAM_TRACE_GRAD_GAIN: float = 1.2        # gentle bias toward lower terrain; no aggressive turning
const STREAM_TRACE_JITTER: float = 0.0           # no noise meander — straight downhill, not waddling
const STREAM_TRACE_PROBE: float = 6.0            # wide gradient sample so the path follows the broad slope, not local bumps
const STREAM_SLOPE_REF: float = 0.08             # slope (rise/run) that maps to "1.0" flow speed

# --- Lake ---
# A real basin carved into the heightmap at the downstream end of the traced
# centerline. The stream water meets the lake at its rim, and the lake has its
# own still-water surface, sand ring, and a multi-texture floor.
const LAKE_ENABLED: bool = true
const LAKE_RADIUS: float = 36.0                  # water surface radius
const LAKE_BANK_RADIUS: float = 44.0             # outer carve radius (graded shore)
const LAKE_SAND_INNER: float = 36.0              # sand ring matches water edge
const LAKE_SAND_OUTER: float = 43.0
const LAKE_DEPTH: float = 3.4                    # carved bed below the water surface
const LAKE_WATER_BELOW_ORIGINAL: float = 1.6     # surface this far below the centerline-endpoint terrain
const LAKE_FLOOR_LIFT: float = 0.05              # tiny lift above the carved bed (no z-fight)
const LAKE_RING_SEGMENTS: int = 64               # circumference subdivision for lake meshes
const LAKE_RADIAL_RINGS: int = 6                 # radial subdivision (more = smoother shading)
const LAKE_BUFFER: float = 2.0                   # stream water stops this far before lake center
# Basins below this cell count get carved but skip mesh generation — guards
# against thousands of micro-pits blowing past Godot's RID owner limit.
const MIN_BASIN_CELLS: int = 40
# Forced lake fallback: when the stream's natural endpoint isn't deep enough
# to flood into a basin >= MIN_BASIN_CELLS, carve a smooth bowl this big.
const FORCED_LAKE_RADIUS_CELLS: int = 14
const FORCED_LAKE_DEPTH: float = 4.0

# Water tile streaming
const WATER_TILE_SIZE: float = 60.0
const WATER_STREAM_RADIUS: float = 220.0
const WATER_REBUILD_THRESHOLD: float = 15.0
const WATER_TILE_SPAWN_BUDGET: int = 1
const WATER_SEG_PER_METER: float = 2.0    # segments along x per meter (0.5m apart) — needed for visible vertex waves
const WATER_CROSS_SEGS: int = 4            # subdivisions across the ribbon width (5 verts per row)

# --- Stones ---
# Two systems, both deterministic per-tile and streamed around the camera
# identically to trees: placement is pre-calculated from (seed, tx, tz), only
# nearby tiles instantiate a MultiMesh.
# 1) LAND stones: large + medium, scattered across the map driven by a
#    placement noise. Excluded from the streambed.
# 2) BROOK stones: medium + small, marched along the stream centerline so they
#    outline both banks. Stacking is allowed (probabilistic 2nd stone above).
## Land stones are kept to a small fixed roster so each tile only emits a few
## MultiMeshInstance3Ds. More variants = more draw calls + AABB cull tests per
## frame, with no visual win at this density.
## Polyhaven photoreal rocks (PBR scanned). Real-world meter scale, so scale
## constants below are ~1× instead of 5×.
const STONE_LARGE_PATHS := [
	"res://assets/polyhaven/rocks/boulder_01/boulder_01_2k.gltf",
	"res://assets/polyhaven/rocks/namaqualand_boulder_02/namaqualand_boulder_02_2k.gltf",
	"res://assets/polyhaven/rocks/namaqualand_boulder_03/namaqualand_boulder_03_2k.gltf",
]
const STONE_MEDIUM_PATHS := [
	"res://assets/polyhaven/rocks/rock_07/rock_07_2k.gltf",
	"res://assets/polyhaven/rocks/rock_09/rock_09_2k.gltf",
]
## Brook stones — small mossy river rocks, scanned PBR.
const BROOK_MEDIUM_PATHS := [
	"res://assets/polyhaven/rocks/rock_07/rock_07_2k.gltf",
	"res://assets/polyhaven/rocks/rock_09/rock_09_2k.gltf",
]
const BROOK_SMALL_PATHS := [
	"res://assets/polyhaven/rocks/rock_moss_set_01/rock_moss_set_01_2k.gltf",
]

## Larger tiles → fewer MMIs total across the streaming disk (~4× fewer tiles
## than before at the same radius).
const STONE_TILE_SIZE: float = 100.0
const STONE_STREAM_RADIUS: float = 240.0
const STONE_REBUILD_THRESHOLD: float = 20.0
const STONE_TILE_SPAWN_BUDGET: int = 1
## Land stones are now individual DestructibleStone bodies — spacing widened so
## the per-node cost stays modest across the streaming disk.
const STONE_LARGE_SPACING: float = 70.0
const STONE_MEDIUM_SPACING: float = 38.0
const STONE_PLACEMENT_FREQ: float = 0.012
const STONE_LARGE_THRESHOLD: float = 0.82
const STONE_MEDIUM_THRESHOLD: float = 0.74
const STONE_MIN_NORMAL_Y: float = 0.55
const STONE_MIN_ELEV: float = -2.0
const STONE_MAX_ELEV: float = 130.0
const STONE_BANK_EXCLUSION: float = 12.0
const STONE_LARGE_SCALE_BASE: float = 1.2     # Polyhaven boulders are ~1-3 m natural — light upscale for "feature boulder"
const STONE_LARGE_SCALE_JITTER: float = 0.7
const STONE_MEDIUM_SCALE_BASE: float = 0.7
const STONE_MEDIUM_SCALE_JITTER: float = 0.4
const STONE_SINK: float = 0.45

# Brook stones march along the centerline, anchored to the sandy edge so they
# read as "stones outlining the water."
## Brook stones are now individual DestructibleStone bodies — much heavier
## per-instance than MultiMesh, so density drops to roughly one stone every
## ~2 m of bank instead of multiple per meter.
const BROOK_TILE_SIZE: float = 100.0
const BROOK_STREAM_RADIUS: float = 160.0
const BROOK_REBUILD_THRESHOLD: float = 20.0
const BROOK_TILE_SPAWN_BUDGET: int = 1
const BROOK_STEP: float = 1.8               # one base stone every ~1.8 m along the centerline
const BROOK_BANK_OFFSET: float = 3.0        # center of the bank band (water edge ~2.2)
const BROOK_LATERAL_JITTER: float = 1.4
const BROOK_SKIP_CHANCE: float = 0.10
const BROOK_STACK_CHANCE: float = 0.25      # stacks are real bodies too, kept rare
const BROOK_MED_SCALE: float = 0.5
const BROOK_SMALL_SCALE: float = 0.35
const BROOK_MED_CHANCE: float = 0.7
const BROOK_SINK: float = 0.20

# --- Wildflowers ---
# Tile-streamed MultiMesh fields of Kenney flower GLBs. Per-tile RNG picks a
# "patch mode" (mono species / mono color family / mixed) so the map reads as a
# mosaic of wildflower carpets, not one uniform sprinkle.
const FLOWER_PATHS := [
	"res://assets/polyhaven/flowers/dandelion_01/dandelion_01_2k.gltf",
	"res://assets/polyhaven/flowers/flower_empodium/flower_empodium_2k.gltf",
	"res://assets/polyhaven/flowers/flower_gazania/flower_gazania_2k.gltf",
	"res://assets/polyhaven/flowers/flower_heliophila/flower_heliophila_2k.gltf",
	"res://assets/polyhaven/flowers/flower_ursinia/flower_ursinia_2k.gltf",
	"res://assets/polyhaven/flowers/flower_stinkkruid/flower_stinkkruid_2k.gltf",
]
const FLOWER_FAMILY_SIZE: int = 2            # Polyhaven flowers: 6 species grouped into 3 pairs for "mono-family" patch mode
const FLOWER_TILE_SIZE: float = 40.0
const FLOWER_STREAM_RADIUS: float = 220.0
const FLOWER_REBUILD_THRESHOLD: float = 12.0
const FLOWER_TILE_SPAWN_BUDGET: int = 1
const FLOWER_DENSITY_SPACING: float = 1.4
const FLOWER_PATCH_FREQ: float = 0.018
const FLOWER_PATCH_THRESHOLD: float = 0.60
const FLOWER_BANK_INFLUENCE: float = 28.0
const FLOWER_BANK_BOOST: float = 0.22
const FLOWER_BANK_EXCLUSION: float = 8.5
const FLOWER_MIN_NORMAL_Y: float = 0.85
const FLOWER_MIN_ELEV: float = -1.0
const FLOWER_MAX_ELEV: float = 50.0
const FLOWER_SCALE_BASE: float = 1.0     # Polyhaven flowers are real-size (~15-30 cm) — natural scale reads well in-game
const FLOWER_SCALE_JITTER: float = 0.4
const FLOWER_SINK: float = 0.05
# Per-tile density variation: each tile rolls a density multiplier in this range,
# applied as an offset to FLOWER_PATCH_THRESHOLD. Negative = denser carpet,
# positive = sparser scattering.
const FLOWER_DENSITY_VARIATION: float = 0.18

@export var noise_seed: int = 1337
@export var flatten_origin: bool = true

var _grass_mesh: ArrayMesh
var _grass_mesh_tall: ArrayMesh
var _grass_material_short: ShaderMaterial
var _grass_material_tall: ShaderMaterial
var _grass_material_patch_short: ShaderMaterial
var _grass_material_patch_tall: ShaderMaterial
var _grass_material_patch_core: ShaderMaterial
var _grass_material_patch_super_core: ShaderMaterial
var _last_sun_dir_world: Vector3 = Vector3.INF
var _last_patch_center: Vector2 = Vector2(INF, INF)
# Smoothed near-grass duck state. Defaults match the shader's no-op values
# (fade_in_inner ≤ fade_in_outer → smoothstep = 1 everywhere → no cull).
var _duck_inner: float = -1.0
var _duck_outer: float = 0.0
var _last_offset_short: Vector2 = Vector2(INF, INF)
var _last_offset_tall: Vector2 = Vector2(INF, INF)
var _last_offset_core: Vector2 = Vector2(INF, INF)
var _last_offset_super: Vector2 = Vector2(INF, INF)
var _sun_light: DirectionalLight3D
var _height_tex: ImageTexture
var _centerline_z_tex: ImageTexture
var _grass_patch_mmis: Array = []   # [short MMI, tall MMI]
# Each tree variant is Array of {"mesh": Mesh, "xform": Transform3D} — parts of a multi-mesh GLB.
var _tree_variants: Array = []
var _heights: PackedFloat32Array
# Terrain chunk streaming: Vector2i(cx,cz) -> MeshInstance3D.
var _chunk_tiles: Dictionary = {}
var _chunk_spawn_queue: Array = []
var _last_chunk_stream_pos: Vector3 = Vector3.INF
var _ground_material: Material
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
var _stream_noise: FastNoiseLite
var _centerline_heights: PackedFloat32Array  # original terrain h at centerline per grid x column
var _centerline_z_samples: PackedFloat32Array  # traced z per grid x column (INF outside [gx_start, gx_end])
var _centerline_slope: PackedFloat32Array      # |dh/ds| along the path per gx column
var _stream_gx_start: int = 0
var _stream_gx_end: int = -1
var _stream_x_start: float = 0.0
var _stream_x_end: float = 0.0
var _stream_x_water_end: float = 0.0           # where the stream ribbon stops (lake rim)
var _stream_z_min: float = 0.0
var _stream_z_max: float = 0.0
# Basins generated by `_flood_basin` (priority-flood). Currently we only fire
# one flood at the end of the monotonic stream tracer so the bottom-of-stream
# lake takes its natural shape, but the machinery handles any number.
var _basins: Array = []
# Union of every basin's cells_set, for O(1) keepout lookups.
var _all_basin_cells: Dictionary = {}
var _lake_water_material: ShaderMaterial
var _lake_floor_material: ShaderMaterial
var _lake_sand_material: StandardMaterial3D
var _water_normal_tex: NoiseTexture2D
var _water_foam_tex: NoiseTexture2D
var _water_material: ShaderMaterial
var _sand_material: StandardMaterial3D
var _water_tiles: Dictionary = {}
var _water_spawn_queue: Array = []
var _last_water_stream_pos: Vector3 = Vector3.INF
# Stones: same per-variant structure as trees (Array of {"mesh","xform"} parts).
var _stone_large_variants: Array = []
var _stone_medium_variants: Array = []
var _brook_medium_variants: Array = []
var _brook_small_variants: Array = []
var _stone_placement_noise: FastNoiseLite
var _stone_tiles: Dictionary = {}
var _stone_spawn_queue: Array = []
var _last_stone_stream_pos: Vector3 = Vector3.INF
var _brook_tiles: Dictionary = {}
var _brook_spawn_queue: Array = []
var _last_brook_stream_pos: Vector3 = Vector3.INF
# Wildflowers — same {parts, aabb} structure as trees/stones.
var _flower_variants: Array = []
var _flower_tiles: Dictionary = {}
var _flower_spawn_queue: Array = []
var _last_flower_stream_pos: Vector3 = Vector3.INF
var _flower_patch_noise: FastNoiseLite
# Grass occluders: stumps, fallen logs, placed wood. Rasterized into a small
# patch-centered mask texture each frame so the patch-grass vertex shader can
# discard blades inside them. Keys are instance IDs so callers can remove
# their entries without juggling indices.
const OCC_MASK_SIZE: int = 256
const OCC_MASK_EXTENT: float = 220.0       # matches PATCH_SIZE — covers full patch
var _occluders: Dictionary = {}            # int id -> {pos: Vector2, radius: float}
var _occ_dirty: bool = true
var _occ_mask_img: Image
var _occ_mask_tex: ImageTexture
var _occ_last_center: Vector2 = Vector2(INF, INF)

func _ready() -> void:
	# Startup timing instrumentation. _ready blocks the menu→world transition,
	# so anything slow here shows up as the "select solo and wait" delay. Each
	# tagged block prints its cost so the bottleneck is obvious next launch.
	var _t0: int = Time.get_ticks_msec()
	var _tt: int = _t0
	# Heightmap generation + carving costs ~1 s. Cache the final post-carve
	# heights to disk so subsequent launches load in tens of ms. Pass
	# --bake-heights to force regeneration (after changing noise_seed,
	# noise constants, or flatten_origin).
	var heights_cached: bool = _ensure_heights_bake()
	print("[startup] heights (cached=%s): %d ms" % [heights_cached, Time.get_ticks_msec() - _tt]); _tt = Time.get_ticks_msec()
	_compute_river_flow()
	print("[startup] compute_river_flow: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	_extract_river_network()
	_smooth_and_resample_polylines()
	print("[startup] river network+smooth: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	# Particle-descent water simulation, baked once to res://baked/water.bin
	# and loaded on subsequent launches. Decoding the bake takes ~7 s because
	# the file holds three 4097² float arrays (≈200 MB), so skip the load
	# entirely on casual launches — the only consumers are the mesh build
	# (gated below) and the user-alg viz, neither of which run without
	# --bake-water. Pass --bake-water to load + render water.
	if OS.get_cmdline_args().has("--bake-water"):
		_ensure_water_bake()
	print("[startup] ensure_water_bake: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	_ground_material = _build_ground_material()
	print("[startup] ground_material: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	_build_far_terrain()
	print("[startup] far_terrain: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	_attach_collision(_heights)
	print("[startup] attach_collision: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	_build_height_texture()
	print("[startup] build_height_texture: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	_init_foliage_resources()
	print("[startup] init_foliage: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	if not GRASS_DISABLED:
		_build_grass_patch()
	print("[startup] build_grass_patch: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	_init_tree_placement_noise()
	_init_stone_resources()
	_init_flower_resources()
	_init_occluder_mask()
	print("[startup] init_tree/stone/flower/occluder: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	if STREAM_ENABLED:
		_water_material = _build_water_material()
		_sand_material = _build_sand_material()
		_build_lake()
	print("[startup] water_material+lake: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	# Water mesh + grass cull mask are built from the bake (loaded or just
	# computed by _ensure_water_bake). The sparse mesh build still allocates
	# multi-MB index/byte arrays from a 4097² sim grid — heavy enough that
	# fast iteration is painful when you're not actually testing water. Gate
	# the whole pipeline on the same --bake-water flag the bake itself uses,
	# so casual launches skip both the sim and the mesh upload entirely.
	if OS.get_cmdline_args().has("--bake-water"):
		_build_baked_water()
		_build_water_grass_cull_mask_from_bake()
	else:
		print("[Bake] --bake-water not set; skipping water mesh + cull mask")
	print("[startup] water_mesh: %d ms" % (Time.get_ticks_msec() - _tt)); _tt = Time.get_ticks_msec()
	print("[startup] TOTAL _ready: %d ms" % (Time.get_ticks_msec() - _t0))
	var parent := get_parent()
	if parent:
		_sun_light = parent.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	_spawn_fps_overlay()
	# _spawn_tile_grass_controls()
	_spawn_loading_screen()

var _fps_label: Label
var _coord_label: Label
var _loading_overlay: ColorRect
var _loading_label: Label
var _loading_t: float = 0.0
var _loading_done: bool = false

func _spawn_loading_screen() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)
	_loading_overlay = ColorRect.new()
	_loading_overlay.color = Color(0.04, 0.05, 0.07, 1.0)
	_loading_overlay.anchor_right = 1.0
	_loading_overlay.anchor_bottom = 1.0
	canvas.add_child(_loading_overlay)
	_loading_label = Label.new()
	_loading_label.text = "Loading…"
	_loading_label.add_theme_font_size_override("font_size", 48)
	_loading_label.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95, 1.0))
	_loading_label.anchor_left = 0.5
	_loading_label.anchor_top = 0.5
	_loading_label.anchor_right = 0.5
	_loading_label.anchor_bottom = 0.5
	_loading_label.offset_left = -120
	_loading_label.offset_top = -32
	_loading_label.offset_right = 120
	_loading_label.offset_bottom = 32
	_loading_overlay.add_child(_loading_label)

func _streaming_queue_total() -> int:
	return _chunk_spawn_queue.size() + _tile_spawn_queue.size() + \
		_tree_spawn_queue.size() + _water_spawn_queue.size() + \
		_stone_spawn_queue.size() + _brook_spawn_queue.size() + \
		_flower_spawn_queue.size()

func _update_loading_screen(dt: float) -> void:
	if _loading_done or _loading_overlay == null:
		return
	_loading_t += dt
	# Wait until streaming has caught up, or 8s max so we never strand the player.
	var queue_total := _streaming_queue_total()
	var queue_quiet: bool = _loading_t > 1.0 and queue_total <= 4
	var timeout: bool = _loading_t > 8.0
	if queue_quiet or timeout:
		# Fade out over 0.6s.
		var fade_t: float = (_loading_t - max(1.0, _loading_t)) / 0.6
		_loading_overlay.color.a = max(0.0, 1.0 - _loading_t / 0.6 + (1.0 if _loading_t < 1.0 else 0.0))
		# Simpler: linear fade out 0.6s after we hit the "quiet" condition.
		if not _loading_overlay.has_meta("fade_start"):
			_loading_overlay.set_meta("fade_start", _loading_t)
		var fs: float = _loading_overlay.get_meta("fade_start")
		var alpha: float = 1.0 - clamp((_loading_t - fs) / 0.6, 0.0, 1.0)
		_loading_overlay.color.a = alpha
		_loading_label.modulate.a = alpha
		if alpha <= 0.0:
			_loading_done = true
			_loading_overlay.queue_free()
			_loading_overlay = null
			_loading_label = null
	else:
		_loading_label.text = "Loading…  (%d tiles)" % queue_total

func _spawn_fps_overlay() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_fps_label = Label.new()
	_fps_label.position = Vector2(12, 8)
	_fps_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_fps_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_fps_label.add_theme_constant_override("outline_size", 4)
	canvas.add_child(_fps_label)
	_coord_label = Label.new()
	_coord_label.position = Vector2(12, 28)
	_coord_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_coord_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_coord_label.add_theme_constant_override("outline_size", 4)
	canvas.add_child(_coord_label)

func _spawn_super_core_controls() -> void:
	if not _grass_material_patch_super_core:
		return
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 560)
	scroll.position = Vector2(20, 60)
	canvas.add_child(scroll)
	var panel := PanelContainer.new()
	scroll.add_child(panel)
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	var title := Label.new()
	title.text = "SUPER_CORE (14m dense patch)"
	vb.add_child(title)
	var mats: Array = [_grass_material_patch_super_core]
	_add_grass_slider(vb, mats, "albedo_boost", 0.2, 1.5, 0.75)
	_add_grass_slider(vb, mats, "ao_min", 0.0, 1.0, 0.30)
	_add_grass_slider(vb, mats, "flat_emission", 0.0, 0.30, 0.0)
	_add_grass_slider(vb, mats, "yellow_chance", 0.0, 0.6, 0.0)
	_add_grass_slider(vb, mats, "fade_inner", 0.0, 14.0, PATCH_SUPER_CORE_FADE_INNER)
	_add_grass_slider(vb, mats, "fade_outer", 0.0, 14.0, PATCH_SUPER_CORE_FADE_OUTER)
	_add_grass_color(vb, mats, "base_color", Color(0.05, 0.09, 0.05))
	_add_grass_color(vb, mats, "tip_meadow", Color(0.24, 0.36, 0.14))
	_add_grass_color(vb, mats, "tip_dry", Color(0.24, 0.36, 0.14))

func _spawn_tile_grass_controls() -> void:
	if not _grass_material_short:
		return
	var canvas := CanvasLayer.new()
	add_child(canvas)
	# Three side-by-side scrollable panels — CLOSE patch (inside fade_inner),
	# TAPER patch (between fade_inner and fade_outer), DISTANT tile grass.
	var hb := HBoxContainer.new()
	hb.position = Vector2(20, 40)
	canvas.add_child(hb)
	var patch_mats: Array = [
		_grass_material_patch_short,
		_grass_material_patch_tall,
		_grass_material_patch_core,
	]
	var tile_mats: Array = [_grass_material_short, _grass_material_tall]
	# Region 1 = CORE + SHORT/TALL inside 22m (no panel — fine as-is).
	# Region 2 = SHORT/TALL color override past color_zone_outer.
	_build_grass_panel_taper(hb, "REGION 2 (mid annulus)", patch_mats)
	# Region 3 = tile grass, fades in 56→106m.
	_build_grass_panel(hb, "REGION 3 (distant)", tile_mats, "")

func _build_grass_panel(parent: Node, title_text: String, materials: Array, suffix: String) -> void:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 560)
	parent.add_child(scroll)
	var panel := PanelContainer.new()
	scroll.add_child(panel)
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	var title := Label.new()
	title.text = title_text
	vb.add_child(title)
	_add_grass_slider(vb, materials, "albedo_boost" + suffix, 0.5, 3.0, 1.0)
	_add_grass_slider(vb, materials, "flat_emission" + suffix, 0.0, 0.30, 0.0)
	_add_grass_slider(vb, materials, "tile_fade_in_inner", 0.0, 200.0, 56.0)
	_add_grass_slider(vb, materials, "tile_fade_in_outer", 0.0, 200.0, 106.0)
	_add_grass_slider(vb, materials, "backlight_strength", 0.0, 3.0, 0.6)
	_add_grass_slider(vb, materials, "roughness_val", 0.05, 1.0, 0.60)
	_add_grass_slider(vb, materials, "specular_val", 0.0, 1.0, 0.10)
	_add_grass_slider(vb, materials, "normal_flatten", 0.0, 1.0, 0.30)
	_add_grass_slider(vb, materials, "hemi_tilt", 0.0, 1.2, 0.55)
	_add_grass_slider(vb, materials, "yellow_chance", 0.0, 0.6, 0.18)
	_add_grass_slider(vb, materials, "wind_strength", 0.0, 1.5, 0.55)
	_add_grass_slider(vb, materials, "wind_speed", 0.0, 4.0, 1.1)
	_add_grass_color(vb, materials, "base_color" + suffix, Color(0.05, 0.09, 0.05))
	_add_grass_color(vb, materials, "tip_lush", Color(0.18, 0.32, 0.10))
	_add_grass_color(vb, materials, "tip_meadow" + suffix, Color(0.24, 0.36, 0.14))
	_add_grass_color(vb, materials, "tip_dry" + suffix, Color(0.34, 0.40, 0.16))
	_add_grass_color(vb, materials, "tip_yellow" + suffix, Color(0.48, 0.42, 0.12))
	_add_grass_color(vb, materials, "sss_tint", Color(0.95, 1.0, 0.45))

func _build_grass_panel_taper(parent: Node, title_text: String, materials: Array) -> void:
	# Only the taper-affected params: colors + brightness. Material/geometry
	# params are shared with the CLOSE panel.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 560)
	parent.add_child(scroll)
	var panel := PanelContainer.new()
	scroll.add_child(panel)
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	var title := Label.new()
	title.text = title_text
	vb.add_child(title)
	# Radius sliders apply only to SHORT/TALL patch materials, not CORE
	# (CORE keeps color_zone at ∞ so it always reads as Region 1).
	var short_tall_only: Array = [_grass_material_patch_short, _grass_material_patch_tall]
	var core_only: Array = [_grass_material_patch_core]
	_add_grass_slider(vb, short_tall_only, "color_zone_inner", 0.0, 200.0, 22.0)
	_add_grass_slider(vb, short_tall_only, "color_zone_outer", 0.0, 200.0, 56.0)
	# SHORT/TALL fade-IN — they grow from 0 → full density across this range,
	# matching CORE's fade-out so combined density stays flat.
	_add_grass_slider(vb, short_tall_only, "fade_in_inner", 0.0, 200.0, 22.0)
	_add_grass_slider(vb, short_tall_only, "fade_in_outer", 0.0, 200.0, 56.0)
	_add_grass_slider(vb, short_tall_only, "fade_inner", 0.0, 200.0, 56.0)
	_add_grass_slider(vb, short_tall_only, "fade_outer", 0.0, 200.0, 106.0)
	# CORE fade controls — how dense-grass density tapers out. Wider = softer
	# transition between Region 1 and Region 2 (the visible "hard cutoff").
	_add_grass_slider(vb, core_only, "fade_inner", 0.0, 100.0, 22.0)
	_add_grass_slider(vb, core_only, "fade_outer", 0.0, 100.0, 56.0)
	_add_grass_slider(vb, materials, "albedo_boost_taper", 0.5, 3.0, 1.0)
	_add_grass_slider(vb, materials, "flat_emission_taper", 0.0, 0.30, 0.0)
	_add_grass_slider(vb, materials, "ao_min_taper", 0.0, 1.0, 0.45)
	_add_grass_color(vb, materials, "base_color_taper", Color(0.05, 0.09, 0.05))
	_add_grass_color(vb, materials, "tip_meadow_taper", Color(0.24, 0.36, 0.14))
	_add_grass_color(vb, materials, "tip_dry_taper", Color(0.34, 0.40, 0.16))
	_add_grass_color(vb, materials, "tip_yellow_taper", Color(0.48, 0.42, 0.12))

func _add_grass_slider(parent: Node, materials: Array, param: String, lo: float, hi: float, initial: float) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = param
	lbl.custom_minimum_size = Vector2(130, 0)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = (hi - lo) / 100.0
	slider.value = initial
	slider.custom_minimum_size = Vector2(120, 18)
	row.add_child(slider)
	var val := Label.new()
	val.text = "%.3f" % initial
	val.custom_minimum_size = Vector2(56, 0)
	row.add_child(val)
	slider.value_changed.connect(func(v: float) -> void:
		val.text = "%.3f" % v
		for mat in materials:
			if mat:
				(mat as ShaderMaterial).set_shader_parameter(param, v)
	)

func _add_grass_color(parent: Node, materials: Array, param: String, initial: Color) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = param
	lbl.custom_minimum_size = Vector2(130, 0)
	row.add_child(lbl)
	var btn := ColorPickerButton.new()
	btn.color = initial
	btn.custom_minimum_size = Vector2(120, 22)
	btn.edit_alpha = false
	row.add_child(btn)
	btn.color_changed.connect(func(c: Color) -> void:
		for mat in materials:
			if mat:
				(mat as ShaderMaterial).set_shader_parameter(param, c)
	)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_P:
			var cam: Camera3D = get_viewport().get_camera_3d()
			if cam != null:
				_start_user_alg_at(cam.global_position.x, cam.global_position.z)
		elif event.keycode == KEY_R:
			_clear_user_alg()

func _process(_dt: float) -> void:
	_update_loading_screen(_dt)
	if not _user_alg_autostart_done and USER_ALG_AUTOSTART != Vector2.INF and not _heights.is_empty():
		_user_alg_autostart_done = true
		# The user-algorithm autostart is a debug viz for the lake/river bake
		# pipeline — only relevant when iterating water with --bake-water.
		# Without that flag we skip both the bake load and the viz; press P
		# at runtime to trigger the visualisation manually.
		if OS.get_cmdline_args().has("--bake-water") and not _wsim_baked:
			_start_user_alg_at(USER_ALG_AUTOSTART.x, USER_ALG_AUTOSTART.y)
	if _user_alg_active and not _user_alg_done:
		_user_alg_cooldown -= _dt
		while _user_alg_cooldown <= 0.0 and not _user_alg_done:
			_user_alg_cooldown += USER_ALG_STEP_INTERVAL
			for _i in USER_ALG_STEPS_PER_TICK:
				if _user_alg_done:
					break
				_user_alg_done = _user_alg_step()
			_update_user_alg_visual()
		if _user_alg_label:
			var lake_n: int = _user_alg_total_lake_cells()
			_user_alg_label.text = "ALG  river=%d  lake=%d  %s" % [
				_user_alg_river.size(), lake_n,
				"[DONE]" if _user_alg_done else ("[LAKE]" if _user_alg_mode == 1 else "[DESCENT]"),
			]
	# Algorithm just finished — tear down the debug viz. The actual water
	# mesh comes from the BAKED particle sim, not the per-trace algorithm.
	if _user_alg_done and not _user_alg_water_built:
		_user_alg_water_built = true
		if _user_alg_river_mi:
			_user_alg_river_mi.queue_free(); _user_alg_river_mi = null
		if _user_alg_lake_mi:
			_user_alg_lake_mi.queue_free(); _user_alg_lake_mi = null
		if _user_alg_origin_mi:
			_user_alg_origin_mi.queue_free(); _user_alg_origin_mi = null
	if _fps_label:
		_fps_label.text = "%d fps" % Engine.get_frames_per_second()
	if _coord_label:
		var c: Camera3D = get_viewport().get_camera_3d()
		if c:
			var p: Vector3 = c.global_position
			_coord_label.text = "x %.1f  y %.1f  z %.1f  (r %.1f from origin)" % [p.x, p.y, p.z, Vector2(p.x, p.z).length()]
	if _sun_light:
		var sun_dir: Vector3 = _sun_light.global_basis.z.normalized()
		if _last_sun_dir_world == Vector3.INF or _last_sun_dir_world.distance_squared_to(sun_dir) > 0.000025:
			_last_sun_dir_world = sun_dir
			if _grass_material_short:
				_grass_material_short.set_shader_parameter("sun_dir_world", sun_dir)
			if _grass_material_tall:
				_grass_material_tall.set_shader_parameter("sun_dir_world", sun_dir)
			if _grass_material_patch_short:
				_grass_material_patch_short.set_shader_parameter("sun_dir_world", sun_dir)
			if _grass_material_patch_tall:
				_grass_material_patch_tall.set_shader_parameter("sun_dir_world", sun_dir)
			if _grass_material_patch_core:
				_grass_material_patch_core.set_shader_parameter("sun_dir_world", sun_dir)
			if _grass_material_patch_super_core:
				_grass_material_patch_super_core.set_shader_parameter("sun_dir_world", sun_dir)
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	_update_grass_near_cull(cam, _dt)
	var pos: Vector3 = cam.global_position
	# Patch follows the camera every frame, snapped to whole meters so blades
	# don't crawl. Heights are resolved GPU-side — no rebuild cost.
	if not _grass_patch_mmis.is_empty():
		# Move the patch MMI continuously with the player (no PATCH_SNAP). With
		# exact cell indexing via INSTANCE_CUSTOM + per-layer integer offset,
		# blades render at fixed world cells regardless of MMI position — so
		# snapping the MMI to 1m would only desync each layer's coverage with
		# the patch position (each layer's cell_step is different, none divides
		# 1m evenly). Continuous follow + per-layer offset = smooth.
		# Patches stay at world origin; the shader anchors blades to integer
		# world cells via wo + patch_cell_offset. Sliding patch_cell_offset
		# per frame moves the visible disc with the player without moving
		# the MMI (which would risk float-precision loss in wo extraction).
		var center := Vector2(pos.x, pos.z)
		var step_short: float = PATCH_SIZE / float(PATCH_SHORT_GRID)
		var step_tall: float = PATCH_SIZE / float(PATCH_TALL_GRID)
		var step_core: float = PATCH_CORE_SIZE / float(PATCH_CORE_GRID)
		var step_super: float = PATCH_SUPER_CORE_SIZE / float(PATCH_SUPER_CORE_GRID)
		if _last_patch_center.distance_squared_to(center) > 0.0001:
			_last_patch_center = center
			_grass_material_patch_short.set_shader_parameter("patch_center", center)
			_grass_material_patch_tall.set_shader_parameter("patch_center", center)
			_grass_material_patch_core.set_shader_parameter("patch_center", center)
			_grass_material_patch_super_core.set_shader_parameter("patch_center", center)
			_grass_material_short.set_shader_parameter("tile_cull_center", center)
			_grass_material_tall.set_shader_parameter("tile_cull_center", center)
		var off_short := Vector2(round(pos.x / step_short), round(pos.z / step_short))
		var off_tall := Vector2(round(pos.x / step_tall), round(pos.z / step_tall))
		var off_core := Vector2(round(pos.x / step_core), round(pos.z / step_core))
		var off_super := Vector2(round(pos.x / step_super), round(pos.z / step_super))
		if off_short != _last_offset_short:
			_last_offset_short = off_short
			_grass_material_patch_short.set_shader_parameter("patch_cell_offset", off_short)
		if off_tall != _last_offset_tall:
			_last_offset_tall = off_tall
			_grass_material_patch_tall.set_shader_parameter("patch_cell_offset", off_tall)
		if off_core != _last_offset_core:
			_last_offset_core = off_core
			_grass_material_patch_core.set_shader_parameter("patch_cell_offset", off_core)
		if off_super != _last_offset_super:
			_last_offset_super = off_super
			_grass_material_patch_super_core.set_shader_parameter("patch_cell_offset", off_super)
		# AABB tracks the player so Godot's frustum culling stays accurate even
		# though the MMI itself stays at world origin. Each MMI is now ONE
		# quadrant of a layer; its AABB covers only its quarter so Godot can
		# frustum-cull back-facing quadrants when the camera turns.
		for mmi in _grass_patch_mmis:
			var m := mmi as MultiMeshInstance3D
			var psize: float = float(m.get_meta("patch_size"))
			var phalf: float = psize * 0.5
			var qidx: int = int(m.get_meta("patch_quadrant"))
			# Quadrant offsets from player center (in world XZ).
			var dx_min: float = 0.0 if (qidx & 1) == 0 else -phalf
			var dz_min: float = 0.0 if (qidx & 2) == 0 else -phalf
			m.global_position = Vector3.ZERO
			m.custom_aabb = AABB(
				Vector3(pos.x + dx_min, -200.0, pos.z + dz_min),
				Vector3(phalf, 400.0, phalf)
			)
		_update_occluder_mask(center)
	# Tile streaming: only re-survey when the camera has moved enough, and
	# never build more than GRASS_TILE_SPAWN_BUDGET tiles per frame.
	if _last_chunk_stream_pos.x == INF or pos.distance_to(_last_chunk_stream_pos) >= CHUNK_REBUILD_THRESHOLD:
		_last_chunk_stream_pos = pos
		_stream_chunks(pos)
	if _last_stream_pos.x == INF or pos.distance_to(_last_stream_pos) >= GRASS_REBUILD_THRESHOLD:
		_last_stream_pos = pos
		if not GRASS_DISABLED:
			_stream_grass(pos)
	if _last_tree_stream_pos.x == INF or pos.distance_to(_last_tree_stream_pos) >= TREE_REBUILD_THRESHOLD:
		_last_tree_stream_pos = pos
		_stream_trees(pos)
	if STREAM_ENABLED and (_last_water_stream_pos.x == INF or pos.distance_to(_last_water_stream_pos) >= WATER_REBUILD_THRESHOLD):
		_last_water_stream_pos = pos
		_stream_water(pos)
	if _last_stone_stream_pos.x == INF or pos.distance_to(_last_stone_stream_pos) >= STONE_REBUILD_THRESHOLD:
		_last_stone_stream_pos = pos
		_stream_stones(pos)
	if STREAM_ENABLED and (_last_brook_stream_pos.x == INF or pos.distance_to(_last_brook_stream_pos) >= BROOK_REBUILD_THRESHOLD):
		_last_brook_stream_pos = pos
		_stream_brook(pos)
	if _last_flower_stream_pos.x == INF or pos.distance_to(_last_flower_stream_pos) >= FLOWER_REBUILD_THRESHOLD:
		_last_flower_stream_pos = pos
		_stream_flowers(pos)
	_flush_chunk_queue()
	_flush_tile_queue()
	_flush_tree_queue()
	_flush_water_queue()
	_flush_stone_queue()
	_flush_brook_queue()
	_flush_flower_queue()


# Near-grass duck. See DUCK_* constants header for the design rationale.
#   1) Pitch from horizontal — derived from camera forward, so it works
#      whether the pitch lives on the camera, on a parent pivot, or on
#      anything in between. fwd.y == sin(pitch); asin gives the angle.
#      Positive pitch = looking up.
#   2) Running — horizontal velocity of the local Player CharacterBody3D.
#      Falls back to "not running" if the player isn't in the scene yet.
#   3) Target inner/outer = DUCK_RADIUS_* when both conditions hold, else
#      the shader-default (-1, 0) no-op pair.
#   4) Exponential-lerp the smoothed values toward target so the cull
#      grows/relaxes over ~0.1 s instead of popping the same frame.
#   5) Push to CORE and SUPER_CORE patch grass materials (the layers that
#      cover the inner ~40 m around the camera). SHORT/TALL/tile grass
#      live farther out and aren't what's obstructing the view.
func _update_grass_near_cull(cam: Camera3D, dt: float) -> void:
	if _grass_material_patch_core == null and _grass_material_patch_super_core == null:
		return
	var target_inner: float = -1.0
	var target_outer: float = 0.0
	var fwd: Vector3 = -cam.global_basis.z
	var pitch: float = asin(clampf(fwd.y, -1.0, 1.0))
	var looking_up: bool = pitch >= deg_to_rad(DUCK_PITCH_UP_DEG)
	var running: bool = false
	if looking_up:
		var pl: Node = get_tree().current_scene.get_node_or_null("Player")
		if pl is CharacterBody3D:
			var v: Vector3 = (pl as CharacterBody3D).velocity
			running = Vector2(v.x, v.z).length() >= DUCK_SPEED_THRESHOLD
	if looking_up and running:
		target_inner = DUCK_RADIUS_INNER
		target_outer = DUCK_RADIUS_OUTER
	var alpha: float = 1.0 - exp(-DUCK_SMOOTH_RATE * dt)
	_duck_inner = lerpf(_duck_inner, target_inner, alpha)
	_duck_outer = lerpf(_duck_outer, target_outer, alpha)
	if _grass_material_patch_core:
		_grass_material_patch_core.set_shader_parameter("fade_in_inner", _duck_inner)
		_grass_material_patch_core.set_shader_parameter("fade_in_outer", _duck_outer)
	if _grass_material_patch_super_core:
		_grass_material_patch_super_core.set_shader_parameter("fade_in_inner", _duck_inner)
		_grass_material_patch_super_core.set_shader_parameter("fade_in_outer", _duck_outer)


func _build_far_terrain() -> void:
	var verts_side: int = int(SIZE / FAR_CELL) + 1
	var n_verts: int = verts_side * verts_side
	var verts := PackedVector3Array(); verts.resize(n_verts)
	var normals := PackedVector3Array(); normals.resize(n_verts)
	var uvs := PackedVector2Array(); uvs.resize(n_verts)
	var indices := PackedInt32Array()
	var half: float = SIZE * 0.5
	for z in verts_side:
		for x in verts_side:
			var wx: float = float(x) * FAR_CELL - half
			var wz: float = float(z) * FAR_CELL - half
			var gx: int = clampi(int(round((wx + half) / CELL)), 0, GRID - 1)
			var gz: int = clampi(int(round((wz + half) / CELL)), 0, GRID - 1)
			var i: int = z * verts_side + x
			# Min-pool over the FAR_CELL footprint so narrow features like the
			# carved river trench pull the far mesh down with them — otherwise
			# the 8m spacing skips over the ~5m trench and the far mesh hovers
			# above the water (no collision, looks like green lumps in the river).
			var radius_cells: int = int(ceil((FAR_CELL * 0.5) / CELL))
			var h_min: float = _heights[gz * GRID + gx]
			for dz in range(-radius_cells, radius_cells + 1):
				var sz: int = clampi(gz + dz, 0, GRID - 1)
				for dx in range(-radius_cells, radius_cells + 1):
					var sx: int = clampi(gx + dx, 0, GRID - 1)
					var hs: float = _heights[sz * GRID + sx]
					if hs < h_min:
						h_min = hs
			verts[i] = Vector3(wx, h_min + FAR_Y_OFFSET, wz)
			uvs[i] = Vector2(wx, wz) / SIZE
			normals[i] = _heightmap_normal(_heights, gx, gz)
	for z in verts_side - 1:
		for x in verts_side - 1:
			var tl: int = z * verts_side + x
			var tr: int = tl + 1
			var bl: int = tl + verts_side
			var br: int = bl + 1
			indices.append(tl); indices.append(tr); indices.append(bl)
			indices.append(tr); indices.append(br); indices.append(bl)
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var arr := ArrayMesh.new()
	arr.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = arr
	mi.material_override = _ground_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

# World position at the stream's source — the high-ground cell where the
# monotonic tracer begins. Returns Vector3.INF if the stream hasn't been
# traced (so callers can fall back to the scene's default spawn).
func get_source_spawn() -> Vector3:
	if _centerline_z_samples.is_empty() or _stream_gx_end < _stream_gx_start:
		return Vector3.INF
	var half: float = SIZE * 0.5
	var wx: float = float(_stream_gx_start) * CELL - half
	var wz: float = _centerline_z_samples[_stream_gx_start]
	var y: float = _sample_height(_heights, wx, wz) + 2.0
	return Vector3(wx, y, wz)

# Carve a smooth circular bowl into the heightmap centered on (cx, cz). The
# rim height is taken from the highest point on the bowl's perimeter, and the
# bowl floor sits FORCED_LAKE_DEPTH below the rim. Existing terrain that's
# already lower than the bowl profile is left alone (min, never raise).
func _carve_lake_bowl(heights: PackedFloat32Array, cx: int, cz: int) -> void:
	var r: int = FORCED_LAKE_RADIUS_CELLS
	var rim_h: float = -INF
	for k in 32:
		var a: float = float(k) / 32.0 * TAU
		var px: int = clampi(cx + int(round(cos(a) * float(r))), 0, GRID - 1)
		var pz: int = clampi(cz + int(round(sin(a) * float(r))), 0, GRID - 1)
		rim_h = maxf(rim_h, heights[pz * GRID + px])
	var floor_h: float = rim_h - FORCED_LAKE_DEPTH
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var d2: int = dx * dx + dz * dz
			if d2 > r * r:
				continue
			var gx: int = clampi(cx + dx, 0, GRID - 1)
			var gz: int = clampi(cz + dz, 0, GRID - 1)
			var t: float = sqrt(float(d2)) / float(r)
			var target: float = lerpf(floor_h, rim_h - 0.5, t)
			var idx: int = gz * GRID + gx
			heights[idx] = minf(heights[idx], target)

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

# Chunks are streamed lazily: only those within CHUNK_STREAM_RADIUS of the
# camera are resident. This keeps RID/vertex counts proportional to view
# distance, not world area, so SIZE can grow without exhausting RIDs.
# Per-vertex normals are still sampled from the global heightmap so chunk
# boundaries get matching normals (no visible seam shading).
func _stream_chunks(pos: Vector3) -> void:
	var half: float = SIZE * 0.5
	var center_cx: int = int(floor((pos.x + half) / CHUNK_SIZE_M))
	var center_cz: int = int(floor((pos.z + half) / CHUNK_SIZE_M))
	var chunk_radius: int = int(ceil(CHUNK_STREAM_RADIUS / CHUNK_SIZE_M)) + 1
	var radius_sq: float = CHUNK_STREAM_RADIUS * CHUNK_STREAM_RADIUS

	var needed: Dictionary = {}
	for dz in range(-chunk_radius, chunk_radius + 1):
		for dx in range(-chunk_radius, chunk_radius + 1):
			var cx: int = center_cx + dx
			var cz: int = center_cz + dz
			if cx < 0 or cz < 0 or cx >= CHUNKS_PER_SIDE or cz >= CHUNKS_PER_SIDE:
				continue
			var wcx: float = (float(cx) + 0.5) * CHUNK_SIZE_M - half
			var wcz: float = (float(cz) + 0.5) * CHUNK_SIZE_M - half
			var ddx: float = wcx - pos.x
			var ddz: float = wcz - pos.z
			if ddx * ddx + ddz * ddz > radius_sq:
				continue
			var key := Vector2i(cx, cz)
			needed[key] = true
			if not _chunk_tiles.has(key):
				_chunk_spawn_queue.append({"key": key, "cx": cx, "cz": cz})

	var to_remove: Array = []
	for key in _chunk_tiles.keys():
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		var mi: MeshInstance3D = _chunk_tiles[key]
		if is_instance_valid(mi):
			mi.queue_free()
		_chunk_tiles.erase(key)

	var pruned: Array = []
	for entry in _chunk_spawn_queue:
		if needed.has(entry.key) and not _chunk_tiles.has(entry.key):
			pruned.append(entry)
	_chunk_spawn_queue = pruned

func _flush_chunk_queue() -> void:
	var budget: int = CHUNK_SPAWN_BUDGET
	while budget > 0 and not _chunk_spawn_queue.is_empty():
		var entry: Dictionary = _chunk_spawn_queue.pop_front()
		if _chunk_tiles.has(entry.key):
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = _build_chunk_mesh(_heights, entry.cx, entry.cz)
		mi.material_override = _ground_material
		add_child(mi)
		_chunk_tiles[entry.key] = mi
		budget -= 1

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
	# Sparse tile grass reads dark against mountain backdrop; lift its
	# albedo a touch and give it a tiny flat emission so individual blades
	# pop. Tweakable via the runtime UI controls.
	_grass_material_short.set_shader_parameter("albedo_boost", 1.25)
	_grass_material_short.set_shader_parameter("flat_emission", 0.04)
	_grass_material_tall.set_shader_parameter("albedo_boost", 1.25)
	_grass_material_tall.set_shader_parameter("flat_emission", 0.04)
	# Tile blades fade in probabilistically from `tile_fade_in_inner` →
	# `tile_fade_in_outer`. Matches the SHORT/TALL patch fade-out range so
	# the two systems crossfade in the same 56→106m ring.
	_grass_material_short.set_shader_parameter("tile_fade_in_inner", PATCH_FADE_INNER)
	_grass_material_short.set_shader_parameter("tile_fade_in_outer", PATCH_FADE_OUTER)
	_grass_material_tall.set_shader_parameter("tile_fade_in_inner", PATCH_FADE_INNER)
	_grass_material_tall.set_shader_parameter("tile_fade_in_outer", PATCH_FADE_OUTER)
	_grass_material_patch_short = _build_grass_patch_material(false)
	_grass_material_patch_tall = _build_grass_patch_material(true)
	_grass_material_patch_core = _build_grass_patch_material(false)
	_grass_material_patch_core.set_shader_parameter("fade_inner", PATCH_CORE_FADE_INNER)
	_grass_material_patch_core.set_shader_parameter("fade_outer", PATCH_CORE_FADE_OUTER)
	# CORE always reads as REGION 1 — push the color zone far out so v_taper
	# stays 0 across CORE's visible range (0–30m).
	_grass_material_patch_core.set_shader_parameter("color_zone_inner", 1.0e6)
	_grass_material_patch_core.set_shader_parameter("color_zone_outer", 1.0e6 + 1.0)
	# SUPER_CORE: stays Region 1 like CORE, but with its own tight fade radii
	# that hold full density across the entire 14 m patch (no internal taper).
	# Albedo is knocked down to compensate for the denser blade overlap —
	# without real inter-blade AO, every extra blade adds a "tip" pixel and
	# the patch otherwise reads visibly brighter than CORE around it.
	_grass_material_patch_super_core = _build_grass_patch_material(false)
	_grass_material_patch_super_core.set_shader_parameter("fade_inner", PATCH_SUPER_CORE_FADE_INNER)
	_grass_material_patch_super_core.set_shader_parameter("fade_outer", PATCH_SUPER_CORE_FADE_OUTER)
	_grass_material_patch_super_core.set_shader_parameter("color_zone_inner", 1.0e6)
	_grass_material_patch_super_core.set_shader_parameter("color_zone_outer", 1.0e6 + 1.0)
	_grass_material_patch_super_core.set_shader_parameter("albedo_boost", 0.75)
	_grass_material_patch_super_core.set_shader_parameter("ao_min", 0.30)
	# At 6× CORE's density, most pixels in the patch are blade tips, so the
	# tip palette's yellow lean dominates the visual. Tips dialed in to match
	# CORE around the patch — no yellow blades, both tip colors hand-picked.
	_grass_material_patch_super_core.set_shader_parameter("yellow_chance", 0.0)
	_grass_material_patch_super_core.set_shader_parameter("tip_meadow", Color8(0x2b, 0x46, 0x17))
	_grass_material_patch_super_core.set_shader_parameter("tip_dry",    Color8(0x49, 0x5c, 0x24))
	# SHORT/TALL fade IN across the same range CORE fades OUT (22→30m now).
	# Together the combined density stays roughly flat across the handoff,
	# eliminating the geometric cliff. The magnitude mismatch (187 vs 16
	# blades/m²) still creates a visible thinning, but it's smooth, not a step.
	_grass_material_patch_short.set_shader_parameter("fade_in_inner", PATCH_CORE_FADE_INNER)
	_grass_material_patch_short.set_shader_parameter("fade_in_outer", PATCH_CORE_FADE_OUTER)
	# TALL patch: full density everywhere (fade_in_outer <= fade_in_inner
	# means smoothstep returns 1). Sparse 1.5 blades/m² so it doesn't stack
	# heavily with CORE, but tall blades visible right next to the player.
	_grass_material_patch_tall.set_shader_parameter("fade_in_inner", -1.0)
	_grass_material_patch_tall.set_shader_parameter("fade_in_outer", 0.0)
	# AND fade OUT past PATCH_FADE_OUTER — otherwise the shader's default
	# fade_inner=5.5/fade_outer=7.0 culls every SHORT/TALL blade past 7 m,
	# which made the patch's outer ring (and all the tall blades there)
	# invisible.
	_grass_material_patch_short.set_shader_parameter("fade_inner", PATCH_FADE_INNER)
	_grass_material_patch_short.set_shader_parameter("fade_outer", PATCH_FADE_OUTER)
	_grass_material_patch_tall.set_shader_parameter("fade_inner", PATCH_FADE_INNER)
	_grass_material_patch_tall.set_shader_parameter("fade_outer", PATCH_FADE_OUTER)
	# Clump-density modulation: SHORT/TALL patches use the fBm clump noise to
	# thin out dry-biome cells. CORE stays uniformly dense at the player's feet.
	_grass_material_patch_short.set_shader_parameter("clump_strength", 0.85)
	_grass_material_patch_tall.set_shader_parameter("clump_strength", 0.85)
	_tree_variants = _load_tree_variants()

func _build_height_texture() -> void:
	# Pack the heightmap into a 1-channel float texture so the patch vertex
	# shader can resolve terrain height per blade without any CPU work.
	var img := Image.create_from_data(
		GRID, GRID, false, Image.FORMAT_RF, _heights.to_byte_array()
	)
	_height_tex = ImageTexture.create_from_image(img)
	# 1-D centerline z(x) lookup: lets the patch-grass vertex shader discard
	# blades that fall inside the river/sand band.
	var cz_data := PackedFloat32Array()
	cz_data.resize(GRID)
	for gx in GRID:
		var wx: float = float(gx) * CELL - SIZE * 0.5
		cz_data[gx] = _centerline_z(wx) if STREAM_ENABLED else 1.0e9
	var cz_img := Image.create_from_data(GRID, 1, false, Image.FORMAT_RF, cz_data.to_byte_array())
	_centerline_z_tex = ImageTexture.create_from_image(cz_img)

func _build_grass_patch() -> void:
	# Each layer is now split into 4 quadrant MMIs (see _make_patch_layer
	# comments). Each layer's call returns up to 4 MMIs; we flatten them
	# into _grass_patch_mmis and add each as a child.
	var layers: Array = [
		_make_patch_layer(PATCH_SIZE, PATCH_SHORT_GRID, _grass_mesh, _grass_material_patch_short, 0),
		_make_patch_layer(PATCH_TALL_SIZE, PATCH_TALL_GRID, _grass_mesh_tall, _grass_material_patch_tall, 1),
		# CORE: dense close-up patch, fades 22→40 m.
		_make_patch_layer(PATCH_CORE_SIZE, PATCH_CORE_GRID, _grass_mesh, _grass_material_patch_core, 2),
		# SUPER_CORE: tiny 14 m patch on top of CORE so top-down looks solid.
		_make_patch_layer(PATCH_SUPER_CORE_SIZE, PATCH_SUPER_CORE_GRID, _grass_mesh, _grass_material_patch_super_core, 3),
	]
	for layer in layers:
		for mmi in (layer as Array):
			_grass_patch_mmis.append(mmi)
			add_child(mmi)

func _make_patch_layer(
	patch_size: float, grid: int, mesh: ArrayMesh, mat: ShaderMaterial, _salt: int
) -> Array:
	# World-anchored grass split into 4 QUADRANT MultiMeshInstance3Ds. Each
	# quadrant has its own AABB covering only its quarter of the patch, so
	# Godot's frustum culler can drop the back-facing quadrant when the
	# camera looks one way (~25% vertex-shader savings).
	#
	# Each instance still bakes its local cell index into the transform
	# translation (same scheme as before); the shader doesn't need to know
	# the patch was split — it sees the union of all quadrant instances.
	var step: float = patch_size / float(grid)
	var half: float = patch_size * 0.5
	var radius_sq: float = half * half
	var q_transforms: Array = [[], [], [], []]   # [NE +x+z, NW -x+z, SE +x-z, SW -x-z]
	for iz in grid:
		for ix in grid:
			var lx: float = -half + (float(ix) + 0.5) * step
			var lz: float = -half + (float(iz) + 0.5) * step
			if lx * lx + lz * lz > radius_sq:
				continue
			var local_cell_x: int = ix - grid / 2
			var local_cell_z: int = iz - grid / 2
			var qidx: int = 0
			if local_cell_x < 0:
				qidx |= 1
			if local_cell_z < 0:
				qidx |= 2
			(q_transforms[qidx] as Array).append(
				Transform3D(Basis.IDENTITY, Vector3(float(local_cell_x), 0.0, float(local_cell_z))))
	# Shared shader uniforms set once on the material (all 4 MMIs use it).
	mat.set_shader_parameter("cell_step", step)
	mat.set_shader_parameter("patch_size_i", int(round(patch_size)))
	mat.set_shader_parameter("grid_i", grid)
	mat.set_shader_parameter("patch_cell_offset", Vector2.ZERO)
	var out: Array = []
	for qidx in 4:
		var transforms: Array = q_transforms[qidx]
		if transforms.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.set_meta("cell_step", step)
		mmi.set_meta("patch_size", patch_size)
		mmi.set_meta("patch_quadrant", qidx)
		# AABB placeholder — repositioned per frame in the patch-follow loop.
		mmi.custom_aabb = AABB(Vector3(-half, -200.0, -half), Vector3(half, 400.0, half))
		out.append(mmi)
	return out

func _init_tree_placement_noise() -> void:
	_tree_placement_noise = FastNoiseLite.new()
	_tree_placement_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_tree_placement_noise.seed = noise_seed + 91
	_tree_placement_noise.frequency = TREE_PLACEMENT_FREQ

# --- Stream -------------------------------------------------------------------

func _init_stream_noise() -> void:
	_stream_noise = FastNoiseLite.new()
	_stream_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_stream_noise.seed = noise_seed + 67
	_stream_noise.frequency = STREAM_Z_FREQ
	_stream_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_stream_noise.fractal_octaves = 2

# Sentinel for "no stream at this column" — far enough that bank-distance checks
# (`absf(wz - cz) < r`) always fail, so the rest of the world ignores it.
const _NO_STREAM_Z: float = 1.0e9

# z(x) lookup with linear interpolation across grid columns. Outside the traced
# range, returns a sentinel so every consumer (carve, water builder, brook,
# grass/tree exclusion) skips that column without special-casing.
func _centerline_z(wx: float) -> float:
	if _stream_gx_end < _stream_gx_start:
		return _NO_STREAM_Z
	var half: float = SIZE * 0.5
	var fx: float = (wx + half) / CELL
	if fx < float(_stream_gx_start) or fx > float(_stream_gx_end):
		return _NO_STREAM_Z
	var x0: int = clampi(int(fx), _stream_gx_start, _stream_gx_end - 1)
	var t: float = clampf(fx - float(x0), 0.0, 1.0)
	return lerpf(_centerline_z_samples[x0], _centerline_z_samples[x0 + 1], t)

# True when a world point sits inside ANY simulated basin. Foliage / stones
# placed there would float on the lake surface, so suppress them.
func _in_lake_keepout(wx: float, wz: float, extra: float = 0.0) -> bool:
	if _all_basin_cells.is_empty():
		return false
	var half: float = SIZE * 0.5
	var fx: float = (wx + half) / CELL
	var fz: float = (wz + half) / CELL
	if fx < 0.0 or fx >= float(GRID) or fz < 0.0 or fz >= float(GRID):
		return false
	var gx: int = int(fx)
	var gz: int = int(fz)
	if _all_basin_cells.has(gz * GRID + gx):
		return true
	var r: int = maxi(0, int(ceil(extra)))
	if r == 0:
		return false
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dz * dz > r * r:
				continue
			var ngx: int = gx + dx
			var ngz: int = gz + dz
			if ngx < 0 or ngx >= GRID or ngz < 0 or ngz >= GRID:
				continue
			if _all_basin_cells.has(ngz * GRID + ngx):
				return true
	return false

# Average rise/run along the stream tangent at this wx. Used to scale the water
# shader's scroll speed so steep stretches read as rapids and flats as glassy.
func _centerline_slope_at(wx: float) -> float:
	if _stream_gx_end < _stream_gx_start:
		return 0.0
	var half: float = SIZE * 0.5
	var fx: float = (wx + half) / CELL
	if fx < float(_stream_gx_start) or fx > float(_stream_gx_end):
		return 0.0
	var x0: int = clampi(int(fx), _stream_gx_start, _stream_gx_end - 1)
	var t: float = clampf(fx - float(x0), 0.0, 1.0)
	return lerpf(_centerline_slope[x0], _centerline_slope[x0 + 1], t)

# Binary min-heap used by the priority-flood basin filler. GDScript has no
# built-in priority queue, so we keep a tiny one inline.
class _MinHeap:
	var data: Array = []   # entries: [priority: float, value]
	func push(v, p: float) -> void:
		data.append([p, v])
		var i: int = data.size() - 1
		while i > 0:
			var par: int = (i - 1) >> 1
			if data[par][0] > data[i][0]:
				var tmp = data[i]; data[i] = data[par]; data[par] = tmp
				i = par
			else:
				break
	func pop():
		var top = data[0]
		var n: int = data.size()
		if n == 1:
			data.clear()
		else:
			data[0] = data[n - 1]
			data.resize(n - 1)
			n -= 1
			var i: int = 0
			while true:
				var l: int = 2 * i + 1
				var r: int = 2 * i + 2
				var s: int = i
				if l < n and data[l][0] < data[s][0]: s = l
				if r < n and data[r][0] < data[s][0]: s = r
				if s == i: break
				var tmp = data[i]; data[i] = data[s]; data[s] = tmp
				i = s
		return top[1]
	func is_empty() -> bool:
		return data.is_empty()

const _FLOW_NEIGHBORS: Array = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1,  0),                  Vector2i(1,  0),
	Vector2i(-1,  1), Vector2i(0,  1), Vector2i(1,  1),
]

# Monotonic +x gradient-descent tracer. The centerline is a single-valued
# function of x: at every grid column we nudge z by -∂h/∂z (clamped) plus a
# small noise jitter. Result is a smooth winding stream from one map edge to
# the other. After the trace, fire one priority-flood from the endpoint cell
# so the bottom-of-stream lake takes whatever natural polygon shape the
# heightmap actually has.
func _trace_stream_path(heights: PackedFloat32Array) -> void:
	_centerline_z_samples = PackedFloat32Array()
	_centerline_z_samples.resize(GRID)
	_centerline_heights = PackedFloat32Array()
	_centerline_heights.resize(GRID)
	_centerline_slope = PackedFloat32Array()
	_centerline_slope.resize(GRID)
	for i in GRID:
		_centerline_z_samples[i] = _NO_STREAM_Z
		_centerline_heights[i] = 0.0
		_centerline_slope[i] = 0.0
	_basins = []
	_all_basin_cells = {}

	var half: float = SIZE * 0.5
	_stream_gx_start = STREAM_TRACE_MARGIN
	_stream_gx_end = GRID - 1 - STREAM_TRACE_MARGIN

	# Source z: scan the upstream-edge column for the locally-highest band —
	# gives the stream a "from the high ground" feel.
	var best_z: float = 0.0
	var best_h: float = -INF
	var scan_x: float = float(_stream_gx_start) * CELL - half
	var z_lo: float = -half + 40.0
	var z_hi: float = half - 40.0
	var samples: int = 48
	for i in samples + 1:
		var zt: float = lerpf(z_lo, z_hi, float(i) / float(samples))
		var h: float = _sample_height(heights, scan_x, zt)
		if h > best_h:
			best_h = h
			best_z = zt

	var z: float = best_z
	for gx in range(_stream_gx_start, _stream_gx_end + 1):
		var wx: float = float(gx) * CELL - half
		var h_plus: float = _sample_height(heights, wx, z + STREAM_TRACE_PROBE)
		var h_minus: float = _sample_height(heights, wx, z - STREAM_TRACE_PROBE)
		var dh_dz: float = (h_plus - h_minus) / (2.0 * STREAM_TRACE_PROBE)
		var jitter: float = _stream_noise.get_noise_1d(wx) * STREAM_TRACE_JITTER
		var dz: float = clampf(-dh_dz * STREAM_TRACE_GRAD_GAIN, -STREAM_TRACE_STEP_DZ_MAX, STREAM_TRACE_STEP_DZ_MAX) * CELL + jitter
		z = clampf(z + dz, -half + 30.0, half - 30.0)
		_centerline_z_samples[gx] = z
		_centerline_heights[gx] = _sample_height(heights, wx, z)

	# Heavy smoothing on the z path so consecutive segments agree on a
	# direction. Without this the per-vertex tangent flips bank-to-bank and
	# the surface flow looks like it's slooshing sideways instead of running
	# downhill.
	for _pass in 24:
		var prev_z: float = _centerline_z_samples[_stream_gx_start]
		for gx in range(_stream_gx_start + 1, _stream_gx_end):
			var z_l: float = prev_z
			var z_c: float = _centerline_z_samples[gx]
			var z_r: float = _centerline_z_samples[gx + 1]
			prev_z = z_c
			_centerline_z_samples[gx] = 0.25 * z_l + 0.5 * z_c + 0.25 * z_r

	# Resample heights along the smoothed path.
	for gx in range(_stream_gx_start, _stream_gx_end + 1):
		var wx_s: float = float(gx) * CELL - half
		_centerline_heights[gx] = _sample_height(heights, wx_s, _centerline_z_samples[gx])

	# Heavy low-pass on the height profile so the water surface and bed don't
	# inherit terrain bumps along the path. A gentle running-min nudge keeps
	# the profile from re-rising sharply (so flooding still flows downstream),
	# but isn't aggressive enough to leave the bed far below surrounding ground.
	for _hpass in 8:
		var prev_h: float = _centerline_heights[_stream_gx_start]
		for gx in range(_stream_gx_start + 1, _stream_gx_end):
			var h_l: float = prev_h
			var h_c: float = _centerline_heights[gx]
			var h_r: float = _centerline_heights[gx + 1]
			prev_h = h_c
			_centerline_heights[gx] = 0.25 * h_l + 0.5 * h_c + 0.25 * h_r
	# Strict monotonic decrease: water surface can never rise from one column
	# to the next. Anything else lets visible "uphill" segments slip in even
	# though each step is small.
	for gx in range(_stream_gx_start + 1, _stream_gx_end + 1):
		_centerline_heights[gx] = minf(_centerline_heights[gx], _centerline_heights[gx - 1])

	# z bounds for the tile-streamer's strip reject.
	_stream_z_min = INF
	_stream_z_max = -INF
	for gx in range(_stream_gx_start, _stream_gx_end + 1):
		var zs: float = _centerline_z_samples[gx]
		if zs < _stream_z_min: _stream_z_min = zs
		if zs > _stream_z_max: _stream_z_max = zs
	_stream_x_start = float(_stream_gx_start) * CELL - half
	_stream_x_end = float(_stream_gx_end) * CELL - half

	# Per-column along-path slope (drives the running-water shader's flow factor).
	# Use a wide window (not central diff) so slope varies gradually along the
	# river. Central diff produces high-frequency noise that the shader maps to
	# scroll speed AND foam density, which is visible as sharp bands across the
	# water surface where one row gets a much higher flow than its neighbour.
	const SLOPE_WINDOW_CELLS: int = 12
	var raw_slope := PackedFloat32Array()
	raw_slope.resize(GRID)
	for gx in range(_stream_gx_start, _stream_gx_end + 1):
		var gx_prev: int = maxi(gx - SLOPE_WINDOW_CELLS, _stream_gx_start)
		var gx_next: int = mini(gx + SLOPE_WINDOW_CELLS, _stream_gx_end)
		var dh: float = _centerline_heights[gx_prev] - _centerline_heights[gx_next]
		var dx_v: float = float(gx_next - gx_prev) * CELL
		var dz_v: float = _centerline_z_samples[gx_next] - _centerline_z_samples[gx_prev]
		var ds: float = maxf(0.001, sqrt(dx_v * dx_v + dz_v * dz_v))
		raw_slope[gx] = maxf(0.0, dh / ds)
	# Two passes of a 5-tap box filter — flatten any remaining bumps so adjacent
	# vertex rows can't differ by more than a hair in flow magnitude.
	for _pass in 2:
		var tmp := PackedFloat32Array()
		tmp.resize(GRID)
		for gx in range(_stream_gx_start, _stream_gx_end + 1):
			var g0: int = maxi(gx - 2, _stream_gx_start)
			var g1: int = maxi(gx - 1, _stream_gx_start)
			var g2: int = gx
			var g3: int = mini(gx + 1, _stream_gx_end)
			var g4: int = mini(gx + 2, _stream_gx_end)
			tmp[gx] = (raw_slope[g0] + raw_slope[g1] + raw_slope[g2] + raw_slope[g3] + raw_slope[g4]) * 0.2
		for gx in range(_stream_gx_start, _stream_gx_end + 1):
			raw_slope[gx] = tmp[gx]
	for gx in range(_stream_gx_start, _stream_gx_end + 1):
		_centerline_slope[gx] = raw_slope[gx]

	# Endpoint lake: priority-flood from the cell directly under the path's
	# downstream end. Whatever depression the terrain has there becomes the
	# lake — natural polygon, no hardcoded radius.
	var end_wx: float = float(_stream_gx_end) * CELL - half
	var end_wz: float = _centerline_z_samples[_stream_gx_end]
	var end_gx: int = clampi(int((end_wx + half) / CELL), 0, GRID - 1)
	var end_gz: int = clampi(int((end_wz + half) / CELL), 0, GRID - 1)
	var endpoint := Vector2i(end_gx, end_gz)
	var flood_visited: Dictionary = {}
	var basin: Dictionary = _flood_basin(heights, endpoint, flood_visited)
	# Guarantee a lake: if the natural endpoint depression is missing or too
	# small, carve a bowl in-place and re-flood. The bowl is sized so the
	# resulting basin is comfortably above MIN_BASIN_CELLS.
	if basin.is_empty() or (basin.cells as Array).size() < MIN_BASIN_CELLS:
		_carve_lake_bowl(heights, end_gx, end_gz)
		flood_visited = {}
		basin = _flood_basin(heights, endpoint, flood_visited)
	if not basin.is_empty() and (basin.cells as Array).size() >= MIN_BASIN_CELLS:
		_basins.append(basin)
		# Extend stream-z-bounds to include basin so the water-tile streamer
		# considers tiles overlapping the lake when meshing the bank ribbon.
		var lo: Vector2 = basin.aabb_lo
		var hi: Vector2 = basin.aabb_hi
		_stream_z_min = minf(_stream_z_min, lo.y)
		_stream_z_max = maxf(_stream_z_max, hi.y)
		for cidx in (basin.cells_set as Dictionary):
			_all_basin_cells[cidx] = true

	# Keep one stream-water-end value for older code paths; the stream ribbon
	# stops a little before the basin center (replaced by the lake mesh).
	if _basins.is_empty():
		_stream_x_water_end = _stream_x_end + CELL
	else:
		var bc: Vector2 = (_basins[0] as Dictionary).center
		_stream_x_water_end = bc.x - LAKE_BUFFER

# Write a visited cell into the centerline sample arrays (keyed by gx column).
# Non-monotonic paths simply overwrite, which is fine — those columns end up
# inside basins anyway, where the basin mesh covers everything.
func _write_path_cell(c: Vector2i, heights: PackedFloat32Array) -> void:
	var half: float = SIZE * 0.5
	_centerline_z_samples[c.x] = float(c.y) * CELL - half
	_centerline_heights[c.x] = heights[c.y * GRID + c.x]

# Priority-flood a depression starting from a pit cell. Pop boundary cells in
# order of terrain height; the first one with a strictly-lower neighbor
# outside the growing basin IS the spill saddle (water level = its terrain).
# Everything else gets absorbed into the basin.
func _flood_basin(heights: PackedFloat32Array, pit: Vector2i, visited: Dictionary) -> Dictionary:
	var basin_set: Dictionary = {pit.y * GRID + pit.x: true}
	var basin_cells: Array = [pit]
	var heap := _MinHeap.new()
	for off in _FLOW_NEIGHBORS:
		var n: Vector2i = pit + off
		if n.x < 0 or n.x >= GRID or n.y < 0 or n.y >= GRID:
			continue
		var nidx: int = n.y * GRID + n.x
		if not basin_set.has(nidx):
			heap.push(n, heights[nidx])

	var safety: int = 500000
	while not heap.is_empty() and safety > 0:
		safety -= 1
		var cell: Vector2i = heap.pop()
		var cidx: int = cell.y * GRID + cell.x
		if basin_set.has(cidx):
			continue
		var ch: float = heights[cidx]
		# Does `cell` have a strictly-lower neighbor outside the basin? If so
		# it's the spill saddle and the basin overflows.
		var spill: Vector2i = Vector2i(-1, -1)
		var spill_h: float = INF
		for off in _FLOW_NEIGHBORS:
			var n: Vector2i = cell + off
			if n.x < 0 or n.x >= GRID or n.y < 0 or n.y >= GRID:
				continue
			var nidx2: int = n.y * GRID + n.x
			if basin_set.has(nidx2):
				continue
			var nh: float = heights[nidx2]
			if nh < ch and nh < spill_h:
				spill_h = nh
				spill = n

		if spill.x >= 0:
			# Water level = ch; basin cells all have terrain ≤ ch by construction.
			var water_y: float = ch - LAKE_WATER_BELOW_ORIGINAL
			for bidx in basin_set:
				visited[bidx] = true
			var half: float = SIZE * 0.5
			var aabb_lo := Vector2(INF, INF)
			var aabb_hi := Vector2(-INF, -INF)
			var sum := Vector2.ZERO
			for bc in basin_cells:
				var px: float = float(bc.x) * CELL - half
				var pz: float = float(bc.y) * CELL - half
				aabb_lo.x = minf(aabb_lo.x, px); aabb_lo.y = minf(aabb_lo.y, pz)
				aabb_hi.x = maxf(aabb_hi.x, px); aabb_hi.y = maxf(aabb_hi.y, pz)
				sum += Vector2(px, pz)
			return {
				"cells": basin_cells,
				"cells_set": basin_set,
				"water_y": water_y,
				"terrain_y": ch,
				"spill": spill,
				"aabb_lo": aabb_lo,
				"aabb_hi": aabb_hi,
				"center": sum / float(basin_cells.size()),
			}

		# Otherwise: this cell is inside the basin (no outside-and-lower
		# escape). Absorb it and keep flooding.
		basin_set[cidx] = true
		basin_cells.append(cell)
		for off in _FLOW_NEIGHBORS:
			var n: Vector2i = cell + off
			if n.x < 0 or n.x >= GRID or n.y < 0 or n.y >= GRID:
				continue
			var nidx2: int = n.y * GRID + n.x
			if not basin_set.has(nidx2):
				heap.push(n, heights[nidx2])

	return {}

# Bilinear interp into the centerline-heights array. wx → grid x → linear blend.
func _centerline_height_at(wx: float) -> float:
	var half: float = SIZE * 0.5
	var fx: float = clampf((wx + half) / CELL, 0.0, float(GRID - 1) - 0.001)
	var x0: int = int(fx)
	var t: float = fx - float(x0)
	return lerpf(_centerline_heights[x0], _centerline_heights[x0 + 1], t)

func _centerline_water_y(wx: float) -> float:
	return _centerline_height_at(wx) - STREAM_WATER_BELOW_ORIGINAL

# Carve an inverse-bell (Gaussian) divot along the centerline. Depth is
# anchored to the ORIGINAL terrain at each centerline point, so the trench
# follows the lay of the land rather than dropping to a fixed Y. min() so we
# never raise terrain in already-low areas.
func _carve_stream(heights: PackedFloat32Array) -> void:
	if not STREAM_ENABLED:
		return
	_trace_stream_path(heights)
	var half: float = SIZE * 0.5
	var total_r: float = STREAM_BANK_HALF_WIDTH
	# March along the centerline, stamping the trench perpendicular to the
	# local tangent at each step. This makes the bed cross-section truly
	# horizontal across the river width even where the path turns — every
	# cell within the perpendicular band gets the same target Y, so the only
	# slope is along the flow direction.
	var perp_step: float = CELL * 0.4
	for gx in range(_stream_gx_start, _stream_gx_end + 1):
		var wx_col: float = float(gx) * CELL - half
		var cz_col: float = _centerline_z_samples[gx]
		var gx_prev: int = maxi(gx - 1, _stream_gx_start)
		var gx_next: int = mini(gx + 1, _stream_gx_end)
		var dcz_dx: float = (_centerline_z_samples[gx_next] - _centerline_z_samples[gx_prev]) / maxf(0.001, float(gx_next - gx_prev) * CELL)
		var tang: Vector2 = Vector2(1.0, dcz_dx).normalized()
		var perp: Vector2 = Vector2(-tang.y, tang.x)
		var base: float = _centerline_heights[gx]
		var water_y_col: float = base - STREAM_WATER_BELOW_ORIGINAL
		var target_bed: float = water_y_col - (STREAM_BED_BELOW_ORIGINAL - STREAM_WATER_BELOW_ORIGINAL)
		var n_perp: int = int(ceil(total_r / perp_step))
		for k in range(-n_perp, n_perp + 1):
			var d_signed: float = float(k) * perp_step
			var d: float = absf(d_signed)
			if d >= total_r:
				continue
			var falloff: float
			if d <= STREAM_FLAT_HALF_WIDTH:
				falloff = 1.0
			else:
				falloff = 1.0 - smoothstep(STREAM_FLAT_HALF_WIDTH, total_r, d)
			var sx: float = wx_col + perp.x * d_signed
			var sz: float = cz_col + perp.y * d_signed
			var cx: int = clampi(int(round((sx + half) / CELL)), 0, GRID - 1)
			var cz_cell: int = clampi(int(round((sz + half) / CELL)), 0, GRID - 1)
			var idx: int = cz_cell * GRID + cx
			var orig: float = heights[idx]
			var carved: float = lerpf(orig, target_bed, falloff)
			if carved < orig:
				heights[idx] = minf(heights[idx], carved)
	_carve_basins(heights)

# Carve each simulated basin: every cell in the basin drops to bed_y so the
# water surface sits above a real floor. Cells inherited at lower elevations
# stay where they are (minf), so a basin that fell on a pre-existing pit
# isn't artificially raised.
func _carve_basins(heights: PackedFloat32Array) -> void:
	for basin in _basins:
		var bed_y: float = (basin.water_y as float) - LAKE_DEPTH
		for c in basin.cells:
			var idx: int = (c as Vector2i).y * GRID + (c as Vector2i).x
			heights[idx] = minf(heights[idx], bed_y)

# --- Water streaming ----------------------------------------------------------
# Tile the world into WATER_TILE_SIZE cells. A tile builds a water ribbon only
# if the meandering centerline actually passes through its z range. The
# centerline is a 1D function of x, so most tiles will skip immediately.
func _stream_water(pos: Vector3) -> void:
	var center_tx: int = int(floor(pos.x / WATER_TILE_SIZE))
	var center_tz: int = int(floor(pos.z / WATER_TILE_SIZE))
	var tile_radius: int = int(ceil(WATER_STREAM_RADIUS / WATER_TILE_SIZE)) + 1
	var radius_sq: float = WATER_STREAM_RADIUS * WATER_STREAM_RADIUS
	var z_lo: float = _stream_z_min - STREAM_BANK_HALF_WIDTH
	var z_hi: float = _stream_z_max + STREAM_BANK_HALF_WIDTH

	var needed: Dictionary = {}
	for dz in range(-tile_radius, tile_radius + 1):
		for dx in range(-tile_radius, tile_radius + 1):
			var tx: int = center_tx + dx
			var tz: int = center_tz + dz
			var cx: float = (float(tx) + 0.5) * WATER_TILE_SIZE
			var cz: float = (float(tz) + 0.5) * WATER_TILE_SIZE
			var ddx: float = cx - pos.x
			var ddz: float = cz - pos.z
			if ddx * ddx + ddz * ddz > radius_sq:
				continue
			# Quick reject: tile's x band is outside the traced stream range,
			# or its z band can't possibly contain the path.
			var tile_x0: float = float(tx) * WATER_TILE_SIZE
			var tile_x1: float = float(tx + 1) * WATER_TILE_SIZE
			if tile_x1 < _stream_x_start or tile_x0 > _stream_x_water_end:
				continue
			var tile_z0: float = float(tz) * WATER_TILE_SIZE
			var tile_z1: float = float(tz + 1) * WATER_TILE_SIZE
			if tile_z1 < z_lo or tile_z0 > z_hi:
				continue
			var key := Vector2i(tx, tz)
			needed[key] = true
			if not _water_tiles.has(key):
				_water_spawn_queue.append({"key": key, "tx": tx, "tz": tz})

	var to_remove: Array = []
	for key in _water_tiles.keys():
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		(_water_tiles[key] as MeshInstance3D).queue_free()
		_water_tiles.erase(key)

	var pruned: Array = []
	for entry in _water_spawn_queue:
		if needed.has(entry.key) and not _water_tiles.has(entry.key):
			pruned.append(entry)
	_water_spawn_queue = pruned

func _flush_water_queue() -> void:
	var budget: int = WATER_TILE_SPAWN_BUDGET
	while budget > 0 and not _water_spawn_queue.is_empty():
		var entry: Dictionary = _water_spawn_queue.pop_front()
		if _water_tiles.has(entry.key):
			continue
		var mi: MeshInstance3D = _build_water_tile(entry.tx, entry.tz)
		if mi != null:
			add_child(mi)
			_water_tiles[entry.key] = mi
		budget -= 1

func _build_water_tile(tx: int, tz: int) -> MeshInstance3D:
	var half: float = SIZE * 0.5
	var x0: float = maxf(float(tx) * WATER_TILE_SIZE, _stream_x_start)
	var x1: float = minf(float(tx + 1) * WATER_TILE_SIZE, _stream_x_water_end)
	x0 = maxf(x0, -half)
	x1 = minf(x1, half)
	if x1 - x0 < 0.5:
		return null
	var tile_z0: float = float(tz) * WATER_TILE_SIZE
	var tile_z1: float = float(tz + 1) * WATER_TILE_SIZE

	var seg_count: int = maxi(4, int((x1 - x0) * WATER_SEG_PER_METER))
	# Reject tiles whose centerline z never enters tile z range.
	var any_in: bool = false
	for i in seg_count + 1:
		var t: float = float(i) / float(seg_count)
		var wx: float = lerpf(x0, x1, t)
		var cz: float = _centerline_z(wx)
		if cz >= tile_z0 and cz <= tile_z1:
			any_in = true
			break
	if not any_in:
		return null

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	# UV is the river-local frame in meters: UV.x = signed perpendicular distance
	# from the centerline, UV.y = world wx (along-river). Both are continuous
	# scalars (no per-vertex direction), so the shader can scroll along V and
	# the pattern follows the river through every meander with zero seams.
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()           # COLOR.r = flow magnitude only
	var indices := PackedInt32Array()
	# Sand ribbon (two strips, one per bank) — built alongside water using the
	# same centerline frame so it lines up perfectly with the water edge.
	var sand_verts := PackedVector3Array()
	var sand_norms := PackedVector3Array()
	var sand_uvs := PackedVector2Array()
	var sand_indices := PackedInt32Array()
	var cross_n: int = WATER_CROSS_SEGS + 1
	for i in seg_count + 1:
		var t: float = float(i) / float(seg_count)
		var wx: float = lerpf(x0, x1, t)
		var cz: float = _centerline_z(wx)
		# Central-difference tangent. Depends only on wx, so neighboring tiles
		# produce identical positions at their shared boundary (no seam).
		var eps: float = 0.5
		var dcz: float = _centerline_z(wx + eps) - _centerline_z(wx - eps)
		var tang: Vector2 = Vector2(2.0 * eps, dcz).normalized()
		var perp := Vector2(-tang.y, tang.x)
		var pos := Vector2(wx, cz)
		var water_y: float = _centerline_water_y(wx)
		# Flow magnitude only — no CPU lower clamp; the shader's flow_factor_bias
		# is the single place that decides baseline motion (lake sets it low).
		var slope: float = _centerline_slope_at(wx)
		var flow: float = clampf(slope / STREAM_SLOPE_REF, 0.0, 2.4)
		var c := Color(flow, 0.0, 0.0, 1.0)
		# Emit cross_n verts across the width so vertex waves have somewhere to
		# live (a 2-vert strip can't displace independently across the channel).
		for k in cross_n:
			var u: float = float(k) / float(WATER_CROSS_SEGS)       # 0..1 across
			var off: float = lerpf(STREAM_HALF_WIDTH, -STREAM_HALF_WIDTH, u)
			var p := pos + perp * off
			verts.append(Vector3(p.x, water_y, p.y))
			norms.append(Vector3.UP)
			uvs.append(Vector2(off, wx))                             # river-local (across_m, along_m)
			colors.append(c)

		# Sand strip vertices: outer_left, inner_left, inner_right, outer_right.
		# Y follows actual terrain so the bank hugs the ground.
		var left := pos + perp * STREAM_HALF_WIDTH
		var right := pos - perp * STREAM_HALF_WIDTH
		var outer_left := pos + perp * SAND_HALF_WIDTH
		var outer_right := pos - perp * SAND_HALF_WIDTH
		var inner_left_y: float = _sample_height(_heights, left.x, left.y) + SAND_Y_OFFSET
		var outer_left_y: float = _sample_height(_heights, outer_left.x, outer_left.y) + SAND_Y_OFFSET
		var inner_right_y: float = _sample_height(_heights, right.x, right.y) + SAND_Y_OFFSET
		var outer_right_y: float = _sample_height(_heights, outer_right.x, outer_right.y) + SAND_Y_OFFSET
		sand_verts.append(Vector3(outer_left.x, outer_left_y, outer_left.y))
		sand_verts.append(Vector3(left.x, inner_left_y, left.y))
		sand_verts.append(Vector3(right.x, inner_right_y, right.y))
		sand_verts.append(Vector3(outer_right.x, outer_right_y, outer_right.y))
		for _k in 4:
			sand_norms.append(Vector3.UP)
		var sv: float = wx * 0.18
		sand_uvs.append(Vector2(0.0, sv))
		sand_uvs.append(Vector2(1.0, sv))
		sand_uvs.append(Vector2(1.0, sv))
		sand_uvs.append(Vector2(0.0, sv))
	for i in seg_count:
		var row0: int = i * cross_n
		var row1: int = row0 + cross_n
		for k in WATER_CROSS_SEGS:
			var bl: int = row0 + k
			var br: int = bl + 1
			var tl: int = row1 + k
			var tr: int = tl + 1
			indices.append_array([bl, tl, br, br, tl, tr])
		# Left bank strip: outer_left(0), inner_left(1) → next row outer_left(4), inner_left(5)
		var s0: int = i * 4
		sand_indices.append_array([
			s0, s0 + 4, s0 + 1, s0 + 1, s0 + 4, s0 + 5,         # left bank
			s0 + 2, s0 + 6, s0 + 3, s0 + 3, s0 + 6, s0 + 7,     # right bank
		])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.material_override = _water_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Vertex shader displaces verts by ~wave_amplitude*2 in Y; AABB is computed
	# from undisplaced positions, so add margin to avoid culling close-up tiles
	# whose displaced surface still intrudes on the frustum.
	mi.extra_cull_margin = 1.0

	var sand_arr := []
	sand_arr.resize(Mesh.ARRAY_MAX)
	sand_arr[Mesh.ARRAY_VERTEX] = sand_verts
	sand_arr[Mesh.ARRAY_NORMAL] = sand_norms
	sand_arr[Mesh.ARRAY_TEX_UV] = sand_uvs
	sand_arr[Mesh.ARRAY_INDEX] = sand_indices
	var sand_am := ArrayMesh.new()
	sand_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sand_arr)
	var sand_mi := MeshInstance3D.new()
	sand_mi.mesh = sand_am
	sand_mi.material_override = _sand_material
	sand_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.add_child(sand_mi)
	return mi

## Procedurally generated tangent-space normal map: simplex FastNoiseLite fed
## into a seamless NoiseTexture2D with `as_normal_map=true`. Tiles cleanly,
## gives us proper bumped normals instead of GPU sin() ripples.
func _build_water_normal_tex() -> NoiseTexture2D:
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fn.seed = noise_seed + 211
	fn.frequency = 0.015
	fn.fractal_type = FastNoiseLite.FRACTAL_FBM
	fn.fractal_octaves = 3
	fn.fractal_lacunarity = 2.0
	fn.fractal_gain = 0.55
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 512
	tex.seamless = true
	tex.seamless_blend_skirt = 0.15
	tex.as_normal_map = true
	tex.bump_strength = 4.0
	tex.noise = fn
	return tex

## Cellular noise → makes natural-looking foam splotches.
func _build_water_foam_tex() -> NoiseTexture2D:
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_CELLULAR
	fn.seed = noise_seed + 311
	fn.frequency = 0.04
	fn.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	fn.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.seamless_blend_skirt = 0.1
	tex.as_normal_map = false
	tex.noise = fn
	return tex

# Running water. Ported from the CC0 "Absorption Based Stylized Water" shader
# on godotshaders.com — same architecture but trimmed to what we need and
# wired to our per-vertex flow factor (COLOR.r). Scrolling tangent-space
# normal-map waves drive the lighting, screen-space refraction wobbles the
# bed, Beer-Lambert absorption tints the bed by water-column depth, and edge
# foam appears where the column is thin. The same shader serves the lake —
# COLOR.r=0 + flow_factor_bias on that material kills the rapids motion.
func _build_water_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
// Transparent surface: no depth write (default for blend_mix without an
// explicit depth_draw_* token) — keeps shore foam from punching a hole in
// what's behind. cull_disabled is necessary because the camera can dip near
// water level and small vertex waves cause adjacent triangles to flip
// backfacing; without it the surface breaks into patches that vanish as you
// approach. The fragment-cost penalty is acceptable for the river.
render_mode blend_mix, specular_schlick_ggx, cull_disabled;

uniform vec3  absorption_color : source_color = vec3(0.55, 0.18, 0.04);
uniform vec3  shallow_tint     : source_color = vec3(0.50, 0.78, 0.78);
uniform vec3  fresnel_color    : source_color = vec3(0.55, 0.80, 0.85);
uniform vec3  foam_color       : source_color = vec3(0.97, 0.99, 1.0);
uniform float depth_distance   = 3.2;       // meters of water for full absorption
uniform float fresnel_power    = 4.0;
uniform float refraction       = 0.035;
uniform float scroll_speed     = 0.42;      // base scroll rate, multiplied by v_flow
uniform vec2  normal_scale     = vec2(0.26);
uniform float normal_strength  = 1.35;
uniform float roughness_base   = 0.06;
uniform float specular_base    = 0.70;
uniform float edge_foam_depth  = 0.80;      // foam where water column < this (m)
uniform float foam_intensity   = 1.35;
uniform vec2  foam_scale       = vec2(0.55);
uniform float foam_scroll      = 0.85;
// Single flow-gate (CPU writes 0..2.4 to COLOR.r; lake uses bias to add baseline).
uniform float flow_factor_scale = 1.0;
uniform float flow_factor_bias  = 0.45;
// Vertex waves.
uniform float wave_amplitude    = 0.07;
uniform float wave_freq         = 0.55;
uniform float wave_speed        = 0.9;

uniform sampler2D normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_tex   : filter_linear_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex  : hint_depth_texture, filter_linear;

varying float v_flow;
varying vec2  v_uv;           // river-local frame in meters: (across, along)
varying vec3  v_world;

void vertex() {
	v_flow = COLOR.r;
	v_uv = UV;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Three summed sin-waves with prime-ish frequencies — gives a non-tiling
	// surface that actually deforms the silhouette. Scaled by flow so flat
	// reaches stay glassy and rapids visibly chop. Analytic gradient → normal.
	float flow_w = clamp(0.4 + 0.8 * v_flow, 0.35, 1.6);
	float ta = TIME * wave_speed;
	vec2 d1 = vec2( 0.95,  0.31);   // already roughly unit
	vec2 d2 = vec2(-0.37,  0.93);
	vec2 d3 = vec2( 0.55, -0.83);
	float p1 = dot(d1, wp.xz) * wave_freq        + ta * 1.00;
	float p2 = dot(d2, wp.xz) * wave_freq * 1.43 + ta * 1.27;
	float p3 = dot(d3, wp.xz) * wave_freq * 0.78 + ta * 0.71;
	float a1 = wave_amplitude;
	float a2 = wave_amplitude * 0.55;
	float a3 = wave_amplitude * 0.35;
	float h = (a1 * sin(p1) + a2 * sin(p2) + a3 * sin(p3)) * flow_w;
	vec2 grad = ( a1 * wave_freq        * cos(p1) ) * d1
	          + ( a2 * wave_freq * 1.43 * cos(p2) ) * d2
	          + ( a3 * wave_freq * 0.78 * cos(p3) ) * d3;
	grad *= flow_w;
	// Water tiles are parented to the terrain root with identity transform, so
	// model space == world space — skip the inverse(MODEL_MATRIX) round-trip.
	VERTEX.y += h;
	wp.y += h;
	NORMAL = normalize(vec3(-grad.x, 1.0, -grad.y));
	v_world = wp;
}

void fragment() {
	float flow = max(0.0, v_flow * flow_factor_scale + flow_factor_bias);
	float t = TIME * scroll_speed * max(0.25, flow);

	// Two scrolling normal-map samples at different scales/directions — the
	// crossbeat kills the obvious tile and reads as living water. World-XZ
	// sampling means meanders in the ribbon don't distort the waves.
	vec2 flow_dir = length(v_dir) > 0.01 ? normalize(v_dir) : vec2(1.0, 0.0);
	// Valve flow-map trick: two phases offset by 0.5 with a sawtooth crossfade
	// (weight peaks at the seam, zero at mid-cycle) so the pattern never
	// "snaps back" to the start. Reads as continuous flowing motion.
	float phase0 = fract(t);
	float phase1 = fract(t + 0.5);
	float phase_w = abs(0.5 - phase0) * 2.0;  // 1 at the seam, 0 mid-cycle
	vec2 uv0 = v_world.xz * normal_scale;
	vec2 uv1 = v_world.xz * normal_scale * 1.7 + vec2(0.37, 0.19);
	// Layer A: low-freq, both phases — kills tiling.
	vec3 na0 = texture(normal_map, uv0 - flow_dir * phase0).xyz;
	vec3 na1 = texture(normal_map, uv0 - flow_dir * phase1).xyz;
	vec3 na  = mix(na0, na1, phase_w);
	// Layer B: high-freq, faster scroll, same phase trick.
	vec3 nb0 = texture(normal_map, uv1 - flow_dir * (phase0 * 1.35)).xyz;
	vec3 nb1 = texture(normal_map, uv1 - flow_dir * (phase1 * 1.35)).xyz;
	vec3 nb  = mix(nb0, nb1, phase_w);
	// UDN blend: add the xy detail from both layers, multiply z. Preserves
	// detail at any flow speed (Ben Cloward).
	vec3 ad = na * 2.0 - 1.0;
	vec3 bd = nb * 2.0 - 1.0;
	vec3 nrm_decoded = normalize(vec3(ad.xy + bd.xy, ad.z * bd.z));
	NORMAL_MAP = nrm_decoded * 0.5 + 0.5;
	// Flow speed shapes the normal: slow → lazy ripples, fast → choppier.
	float chop = clamp(flow, 0.0, 1.0);
	NORMAL_MAP_DEPTH = normal_strength * mix(0.45, 1.6, chop);

	// Water column = bed view-Z minus surface view-Z.
	float bed_d = texture(depth_tex, SCREEN_UV).r;
	vec4 bed_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, bed_d, 1.0);
	bed_view.xyz /= bed_view.w;
	vec4 surf_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, FRAGCOORD.z, 1.0);
	surf_view.xyz /= surf_view.w;
	float water_col = max(0.0, -bed_view.z + surf_view.z);

	// Screen-space refraction of the bed, depth-scaled so shallows stay sharp.
	vec2 ref_uv = SCREEN_UV + nrm_decoded.xy * refraction * clamp(water_col * 0.8 + 0.2, 0.2, 1.6);
	vec3 bed_col = texture(screen_tex, ref_uv).rgb;

	// Beer-Lambert, applied once: each wavelength attenuates as exp(-k*d).
	// `absorption_color` here is the per-meter absorption coefficient.
	vec3 transmittance = exp(-absorption_color * (water_col / max(0.05, depth_distance)));
	vec3 absorbed = bed_col * transmittance;
	float depth_t = clamp(1.0 - (transmittance.r + transmittance.g + transmittance.b) / 3.0, 0.0, 1.0);
	vec3 refracted = mix(absorbed, shallow_tint, clamp(depth_t * 0.35, 0.0, 0.35));

	// Fresnel reflectance.
	float f = pow(1.0 - clamp(dot(VIEW, NORMAL), 0.0, 1.0), fresnel_power);
	vec3 surface = mix(refracted, fresnel_color, f * 0.55);

	// Foam: shore mask + rapid mask, both gated by a stylized hard-edged
	// noise (step on the noise instead of smoothstep — Sea of Thieves'
	// signature crisp foam silhouettes).
	vec2 fuv0 = v_world.xz * foam_scale - flow_dir * (phase0 * foam_scroll);
	vec2 fuv1 = v_world.xz * foam_scale - flow_dir * (phase1 * foam_scroll);
	float fnoise = mix(texture(foam_tex, fuv0).r, texture(foam_tex, fuv1).r, phase_w);
	float edge_mask = 1.0 - smoothstep(0.0, edge_foam_depth, water_col);
	float edge_f = edge_mask * smoothstep(0.45, 0.55, fnoise);
	float rapid_f = smoothstep(0.55, 0.65, fnoise) * smoothstep(0.30, 0.9, chop);
	float foam = clamp((edge_f + rapid_f) * foam_intensity, 0.0, 1.0);

	vec3 final_rgb = mix(surface, foam_color, foam);

	// Shallows fade smoothly into the bed; foam is opaque.
	float alpha = clamp(max(foam, depth_t * 0.85 + 0.18), 0.0, 1.0);

	ALBEDO = final_rgb;
	ALPHA = alpha;
	// Faster water reads rougher (more chop scatters the highlight).
	ROUGHNESS = mix(mix(roughness_base, 0.22, chop), 0.55, foam);
	METALLIC = 0.0;
	SPECULAR = mix(specular_base, 0.2, foam);
	// Anisotropic highlight stretched along the flow direction — the signature
	// "moving water" sun-glare cue.
	ANISOTROPY = chop * 0.85;
	ANISOTROPY_FLOW = flow_dir;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	if _water_normal_tex == null:
		_water_normal_tex = _build_water_normal_tex()
	if _water_foam_tex == null:
		_water_foam_tex = _build_water_foam_tex()
	mat.set_shader_parameter("normal_map", _water_normal_tex)
	mat.set_shader_parameter("foam_tex", _water_foam_tex)
	return mat

func _build_sand_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.74, 0.64, 0.44)
	m.roughness = 0.95
	m.metallic = 0.0
	m.vertex_color_use_as_albedo = false
	return m

# --- Lake ---------------------------------------------------------------------
# A single fixed-location set of meshes built once at startup: a water disc
# (same shader as the stream but with the per-vertex flow factor pinned to 0
# so it reads as still), a procedurally-shaded floor disc just above the
# carved bed, and a sand ring matching the bank carve. No per-frame work.

func _build_lake_water_material() -> ShaderMaterial:
	# Same shader as the stream, retuned for still water: deeper greener
	# absorption tint, slow scroll, soft normal map, and no rapids foam (the
	# shallow-water edge foam still appears naturally where the lake meets
	# the carved shore).
	var mat: ShaderMaterial = _build_water_material()
	mat.set_shader_parameter("absorption_color", Color(0.45, 0.10, 0.02))
	mat.set_shader_parameter("shallow_tint", Color(0.40, 0.62, 0.60))
	mat.set_shader_parameter("fresnel_color", Color(0.55, 0.78, 0.82))
	mat.set_shader_parameter("depth_distance", 4.5)
	# Lake mesh writes COLOR.r=0; bias keeps a whisper of motion.
	# Calm lake → kill vertex waves so the surface stays glassy.
	mat.set_shader_parameter("wave_amplitude", 0.015)
	mat.set_shader_parameter("wave_speed", 0.25)
	mat.set_shader_parameter("flow_factor_scale", 1.0)
	mat.set_shader_parameter("flow_factor_bias", 0.18)
	mat.set_shader_parameter("scroll_speed", 0.04)
	mat.set_shader_parameter("normal_scale", Vector2(0.09, 0.09))
	mat.set_shader_parameter("normal_strength", 0.35)
	mat.set_shader_parameter("refraction", 0.012)
	# Edge foam stays on (nice shoreline), rapids foam off (no fast flow).
	mat.set_shader_parameter("edge_foam_depth", 0.35)
	mat.set_shader_parameter("foam_intensity", 0.6)
	return mat

func _build_lake_floor_material() -> ShaderMaterial:
	# Procedural floor: warm sand base, pebbled darker patches via one noise
	# threshold, mossy green where a second noise crosses, and a radial depth
	# tint (lighter at the rim, darker toward the deep center). All in one
	# fragment shader — no textures, ~free at this disc's tri count.
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_back, specular_disabled;

uniform vec4  sand_color   : source_color = vec4(0.78, 0.66, 0.46, 1.0);
uniform vec4  pebble_color : source_color = vec4(0.32, 0.28, 0.24, 1.0);
uniform vec4  moss_color   : source_color = vec4(0.20, 0.36, 0.22, 1.0);
uniform vec4  deep_tint    : source_color = vec4(0.05, 0.10, 0.12, 1.0);
uniform float pebble_freq  = 0.55;
uniform float moss_freq    = 0.22;

// Cheap value-noise (hash + bilinear). Plenty for a static floor.
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
	// UV.x = world x, UV.y = world z (set on the mesh). UV.z (stored in COLOR.r)
	// = radial 0..1 from rim → center.
	vec2 p = UV;
	float pebble = vnoise(p * pebble_freq) * 0.7 + vnoise(p * pebble_freq * 2.3) * 0.3;
	float moss   = vnoise(p * moss_freq + vec2(13.7, 4.2));
	float radial = clamp(COLOR.r, 0.0, 1.0);

	vec3 col = sand_color.rgb;
	col = mix(col, pebble_color.rgb, smoothstep(0.55, 0.78, pebble));
	col = mix(col, moss_color.rgb,   smoothstep(0.62, 0.78, moss) * (0.65 + 0.35 * radial));
	col = mix(col, deep_tint.rgb,    radial * 0.55);

	ALBEDO = col;
	ROUGHNESS = 0.92;
	METALLIC = 0.0;
	SPECULAR = 0.15;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

## Build a water surface + floor + sand ring for every basin produced by the
## priority-flood simulation. Cell-rasterized polygons mean the shapes are
## whatever the terrain actually produced — round, oblong, branching, whatever.
func _build_lake() -> void:
	if _basins.is_empty():
		return
	if _lake_water_material == null:
		_lake_water_material = _build_lake_water_material()
	if _lake_floor_material == null:
		_lake_floor_material = _build_lake_floor_material()
	if _lake_sand_material == null:
		_lake_sand_material = _build_sand_material()
	for basin in _basins:
		# Skip micro-basins (just 1-handful of cells). They've already been
		# carved by _carve_basins so the bed exists; the stream ribbon will
		# read as continuous water across them. Building a mesh per pit
		# blows past Godot's RID owner limit on noisy terrain.
		if (basin.cells as Array).size() < MIN_BASIN_CELLS:
			continue
		var basin_root := Node3D.new()
		add_child(basin_root)
		basin_root.add_child(_make_basin_water_mesh(basin))
		basin_root.add_child(_make_basin_floor_mesh(basin))
		basin_root.add_child(_make_basin_sand_ring(basin))

# Rasterize a basin's cells as a flat surface at the given y. Each cell becomes
# two triangles; vertices are deduplicated across shared cell corners so the
# mesh is a clean polygon (no z-fighting at quad seams).
func _make_basin_surface_mesh(
	basin: Dictionary,
	y_func: Callable,          # (wx, wz, radial01) -> y
	uv_func: Callable,          # (wx, wz, radial01) -> Vector2
	color_func: Callable,       # (wx, wz, radial01) -> Color
) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var vert_index: Dictionary = {}   # (gx + gz * (GRID + 1)) -> vert idx
	var half: float = SIZE * 0.5
	var cells_set: Dictionary = basin.cells_set
	var center: Vector2 = basin.center
	# Use the basin's diagonal as the "radius" denominator for the radial coord.
	var diag: Vector2 = (basin.aabb_hi as Vector2) - (basin.aabb_lo as Vector2)
	var max_r: float = maxf(1.0, 0.5 * diag.length())
	# Each cell occupies vertices at its 4 corners.
	for c_v in basin.cells:
		var c: Vector2i = c_v
		var corners := [
			Vector2i(c.x,     c.y),
			Vector2i(c.x + 1, c.y),
			Vector2i(c.x,     c.y + 1),
			Vector2i(c.x + 1, c.y + 1),
		]
		var local_idx: PackedInt32Array
		local_idx.resize(4)
		for i in 4:
			var v: Vector2i = corners[i]
			var key: int = v.x + v.y * (GRID + 1)
			if vert_index.has(key):
				local_idx[i] = vert_index[key]
				continue
			var wx: float = float(v.x) * CELL - half
			var wz: float = float(v.y) * CELL - half
			var dx_c: float = wx - center.x
			var dz_c: float = wz - center.y
			var radial: float = clampf(1.0 - sqrt(dx_c * dx_c + dz_c * dz_c) / max_r, 0.0, 1.0)
			var y: float = y_func.call(wx, wz, radial)
			verts.append(Vector3(wx, y, wz))
			norms.append(Vector3.UP)
			uvs.append(uv_func.call(wx, wz, radial))
			colors.append(color_func.call(wx, wz, radial))
			vert_index[key] = verts.size() - 1
			local_idx[i] = verts.size() - 1
		# Two triangles: (0,2,1) and (1,2,3). CCW from above.
		indices.append_array([local_idx[0], local_idx[2], local_idx[1],
							  local_idx[1], local_idx[2], local_idx[3]])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am

func _make_basin_water_mesh(basin: Dictionary) -> MeshInstance3D:
	var water_y: float = basin.water_y
	var y_func := func(_wx: float, _wz: float, _r: float) -> float:
		return water_y
	var uv_func := func(wx: float, wz: float, _r: float) -> Vector2:
		# UV in world meters so the shader's normal_scale acts as cycles/meter
		# uniformly across the river and the lake.
		return Vector2(wx, wz)
	var color_func := func(_wx: float, _wz: float, _r: float) -> Color:
		return Color(0.0, 0.0, 0.0, 1.0)   # COLOR.r = 0 → flow factor zeroed
	var am: ArrayMesh = _make_basin_surface_mesh(basin, y_func, uv_func, color_func)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.material_override = _lake_water_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _make_basin_floor_mesh(basin: Dictionary) -> MeshInstance3D:
	var y_func := func(wx: float, wz: float, _r: float) -> float:
		return _sample_height(_heights, wx, wz) + LAKE_FLOOR_LIFT
	var uv_func := func(wx: float, wz: float, _r: float) -> Vector2:
		return Vector2(wx, wz)
	var color_func := func(_wx: float, _wz: float, r: float) -> Color:
		return Color(r, 0.0, 0.0, 1.0)
	var am: ArrayMesh = _make_basin_surface_mesh(basin, y_func, uv_func, color_func)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.material_override = _lake_floor_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

# Sand ring = cells just outside the basin (dry cells whose 8-neighborhood
# contains at least one basin cell). Rasterized as flat quads at terrain h.
func _make_basin_sand_ring(basin: Dictionary) -> MeshInstance3D:
	var cells_set: Dictionary = basin.cells_set
	var ring_cells: Dictionary = {}
	for c_v in basin.cells:
		var c: Vector2i = c_v
		for off in _FLOW_NEIGHBORS:
			var n: Vector2i = c + off
			if n.x < 0 or n.x >= GRID or n.y < 0 or n.y >= GRID:
				continue
			var nidx: int = n.y * GRID + n.x
			if cells_set.has(nidx) or ring_cells.has(nidx):
				continue
			ring_cells[nidx] = n
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var vert_index: Dictionary = {}
	var half: float = SIZE * 0.5
	for nidx in ring_cells:
		var c: Vector2i = ring_cells[nidx]
		var corners := [
			Vector2i(c.x,     c.y),
			Vector2i(c.x + 1, c.y),
			Vector2i(c.x,     c.y + 1),
			Vector2i(c.x + 1, c.y + 1),
		]
		var li: PackedInt32Array
		li.resize(4)
		for i in 4:
			var v: Vector2i = corners[i]
			var key: int = v.x + v.y * (GRID + 1)
			if vert_index.has(key):
				li[i] = vert_index[key]; continue
			var wx: float = float(v.x) * CELL - half
			var wz: float = float(v.y) * CELL - half
			var y: float = _sample_height(_heights, wx, wz) + SAND_Y_OFFSET
			verts.append(Vector3(wx, y, wz))
			norms.append(Vector3.UP)
			uvs.append(Vector2(wx * 0.2, wz * 0.2))
			vert_index[key] = verts.size() - 1
			li[i] = verts.size() - 1
		indices.append_array([li[0], li[2], li[1], li[1], li[2], li[3]])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.material_override = _lake_sand_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

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
			# Keep grass out of the river/sand band so the sandy bank is visible
			# and water doesn't appear to float over hidden blades.
			if STREAM_ENABLED and absf(wz - _centerline_z(wx)) < GRASS_BANK_EXCLUSION:
				continue
			if _in_lake_keepout(wx, wz, -1.0):
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
		for b in (_tree_tiles[key] as Dictionary).bodies:
			if is_instance_valid(b):
				(b as Node).queue_free()
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
		var bodies: Array = _build_tree_tile(entry.tx, entry.tz)
		for b in bodies:
			add_child(b)
		_tree_tiles[entry.key] = {"bodies": bodies}
		budget -= 1

func _build_tree_tile(tx: int, tz: int) -> Array:
	var x0: float = float(tx) * TREE_TILE_SIZE
	var z0: float = float(tz) * TREE_TILE_SIZE
	var half: float = SIZE * 0.5
	if x0 + TREE_TILE_SIZE < -half or x0 > half or z0 + TREE_TILE_SIZE < -half or z0 > half:
		return []
	if _tree_variants.is_empty():
		return []
	var rng := RandomNumberGenerator.new()
	rng.seed = noise_seed * 104729 + tz * 100003 + tx
	var n_side: int = int(TREE_TILE_SIZE / TREE_SPACING)
	var tree_script: GDScript = preload("res://entities/tree/tree.gd")

	var out: Array = []
	for iz in n_side:
		for ix in n_side:
			var wx: float = x0 + (float(ix) + rng.randf()) * TREE_SPACING
			var wz: float = z0 + (float(iz) + rng.randf()) * TREE_SPACING
			if wx < -half or wx > half or wz < -half or wz > half:
				continue
			var p: float = (_tree_placement_noise.get_noise_2d(wx, wz) + 1.0) * 0.5
			var bank_boost: float = 0.0
			if STREAM_ENABLED:
				if _in_lake_keepout(wx, wz, -0.5):
					continue
				var dz_center: float = absf(wz - _centerline_z(wx))
				if dz_center < TREE_BANK_EXCLUSION:
					continue
				if dz_center < TREE_BANK_INFLUENCE:
					var falloff_t: float = (dz_center - TREE_BANK_EXCLUSION) / (TREE_BANK_INFLUENCE - TREE_BANK_EXCLUSION)
					bank_boost = TREE_BANK_BOOST * (1.0 - clampf(falloff_t, 0.0, 1.0))
			if p < TREE_PLACEMENT_THRESHOLD - bank_boost:
				continue
			var n: Vector3 = _sample_normal(_heights, wx, wz)
			if n.y < TREE_MIN_NORMAL_Y:
				continue
			var h: float = _sample_height(_heights, wx, wz)
			if h < TREE_MIN_ELEV or h > TREE_MAX_ELEV:
				continue
			var variant: int = rng.randi() % _tree_variants.size()
			var var_data: Dictionary = _tree_variants[variant]
			# Trees stand mostly upright (slight ground-align lean) so the fall
			# animation pivots around a near-vertical trunk. Yaw is per-instance.
			var up: Vector3 = n.lerp(Vector3.UP, 0.85).normalized()
			var align := Basis(Quaternion(Vector3.UP, up))
			var yaw := Basis(Vector3.UP, rng.randf() * TAU)
			var s: float = TREE_SCALE_BASE + rng.randf() * TREE_SCALE_JITTER
			var scale_vec := Vector3(s, s + rng.randf() * 0.4, s)
			# StaticBody3D stays unscaled — visual + collider take the scale.
			var tree := tree_script.new() as StaticBody3D
			tree.transform = Transform3D(align * yaw, Vector3(wx, h - 0.1, wz))
			tree.call("setup", var_data.parts, scale_vec, var_data.aabb as AABB)
			out.append(tree)
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

uniform vec3 base_color   : source_color = vec3(0.05, 0.09, 0.05);
uniform vec3 tip_lush     : source_color = vec3(0.18, 0.32, 0.10);
uniform vec3 tip_meadow   : source_color = vec3(0.24, 0.36, 0.14);
uniform vec3 tip_dry      : source_color = vec3(0.34, 0.40, 0.16);
uniform vec3 tip_yellow   : source_color = vec3(0.48, 0.42, 0.12);
uniform vec3 sss_tint     : source_color = vec3(0.95, 1.05, 0.45);
uniform float yellow_chance = 0.18;
uniform float backlight_strength = 0.6;
// Tweakable runtime params for sparse-tile-grass appearance.
uniform float albedo_boost = 1.0;
uniform float flat_emission = 0.0;
uniform float roughness_val = 0.60;
uniform float specular_val = 0.10;
uniform float normal_flatten = 0.30;
uniform float hemi_tilt = 0.55;
// Tile density fades in linearly across `tile_fade_in_inner..outer`. Inside
// `inner`, no tile blades. Past `outer`, full density. Default 0/0 = full.
uniform vec2  tile_cull_center = vec2(0.0);
uniform float tile_fade_in_inner = 0.0;
uniform float tile_fade_in_outer = 0.0;
uniform sampler2D water_mask_tex : filter_linear, repeat_disable;
uniform float water_mask_active = 0.0;
uniform float terrain_size_tile = 1024.0;
// Direction TOWARD the sun in world space, set per-frame from the
// DirectionalLight3D. Default = straight up so first frame isn't black.
uniform vec3  sun_dir_world = vec3(0.0, 1.0, 0.0);
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
// Hemisphere normal basis: pull world-space "across" and "out-of-blade"
// directions from the instance's MODEL_MATRIX columns (yaw is baked into
// the instance basis on the CPU side).
varying vec3 v_blade_x_world;
varying vec3 v_blade_n_world;

void vertex() {
	vec3 wo = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_world_pos = wo;
	v_patch = fbm(wo.xz * patch_scale);
	// Mesh-local +X = across the blade; +Z = blade normal (out of the plane).
	// Guard against a zero MODEL_MATRIX (briefly-uninit'd streaming instance)
	// producing NaN through normalize() — that NaN propagates to EMISSION and
	// becomes a giant one-frame bloom flash on screen.
	vec3 mx = (MODEL_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz;
	vec3 mn = (MODEL_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz;
	float lx = length(mx);
	float ln = length(mn);
	v_blade_x_world = lx > 0.0001 ? mx / lx : vec3(1.0, 0.0, 0.0);
	v_blade_n_world = ln > 0.0001 ? mn / ln : vec3(0.0, 0.0, 1.0);

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
	// Soft fade-in: tile blades are probabilistically discarded based on
	// their distance to `tile_cull_center`. Inside `tile_fade_in_inner` →
	// 100% culled. Past `tile_fade_in_outer` → 100% kept. Linear interp
	// in between, with the per-blade hash determining which side of the
	// threshold this blade lands on.
	if (tile_fade_in_outer > tile_fade_in_inner) {
		float r = length(v_world_pos.xz - tile_cull_center);
		float keep_p = smoothstep(tile_fade_in_inner, tile_fade_in_outer, r);
		// Per-blade deterministic hash from the instance's world origin
		// (v_world_pos.xz is constant across the blade since all the
		// blade's vertices share the same instance origin).
		vec2 p = floor(v_world_pos.xz * 7.13);
		float surv = fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
		if (surv > keep_p) discard;
	}
	// Water mask: drop blades whose world XZ falls inside a river/lake cell.
	// Per-blade dither threshold (deterministic from world XZ) so the cull
	// edge is dithered across a few cells instead of a hard grid line.
	if (water_mask_active > 0.5) {
		vec2 wu = (v_world_pos.xz + vec2(terrain_size_tile * 0.5)) / terrain_size_tile;
		float in_water = texture(water_mask_tex, wu).r;
		vec2 p = floor(v_world_pos.xz * 7.13);
		float threshold = fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453) * 0.5 + 0.25;
		if (in_water > threshold) discard;
	}
	float bend = COLOR.r;
	float dry  = COLOR.g;
	float hue  = COLOR.b;

	// Patch noise picks a biome tint for this region of the meadow.
	float patch = v_patch;
	vec3 tip = mix(tip_lush, tip_meadow, smoothstep(0.35, 0.65, patch));
	tip = mix(tip, tip_dry, smoothstep(0.65, 0.85, patch));
	// Minority yellow blades scattered across the field.
	tip = mix(tip, tip_yellow, step(1.0 - yellow_chance, hue));

	float t_bend = pow(max(bend, 0.0), 1.5);
	vec3 col = mix(base_color, tip, t_bend);
	col = mix(col, mix(base_color * 0.85, tip_dry, t_bend), dry * 0.7);
	col *= mix(0.92, 1.08, hue);
	// Stronger micro-AO at the base; real shadow pass handles patch occlusion.
	col *= mix(0.45, 1.0, bend);

	ALBEDO = col * albedo_boost;
	ROUGHNESS = roughness_val;
	SPECULAR = specular_val;
	// Hemisphere normal: tilt outward across the blade so the ribbon reads as
	// a curved cylinder. tilt at ~31° peak.
	float tilt = clamp((UV.x - 0.5) * 2.0, -1.0, 1.0) * hemi_tilt;
	vec3 hemi_world = normalize(v_blade_n_world * cos(tilt) + v_blade_x_world * sin(tilt));
	hemi_world = normalize(mix(hemi_world, vec3(0.0, 1.0, 0.0), bend * normal_flatten));
	// Distance-based normal flatten — kills specular aliasing on far blades.
	float view_dist = length(VERTEX);
	float far_flat = smoothstep(20.0, 60.0, view_dist);
	hemi_world = normalize(mix(hemi_world, vec3(0.0, 1.0, 0.0), far_flat * 0.6));
	NORMAL = normalize(mat3(VIEW_MATRIX) * hemi_world);
	// Backlit translucency (cheap SSS).
	vec3 view_dir_world = normalize(mat3(INV_VIEW_MATRIX) * VIEW);
	float back = max(0.0, -dot(view_dir_world, sun_dir_world));
	float sss = pow(max(back, 0.0), 4.0) * (0.3 + 0.7 * max(bend, 0.0)) * backlight_strength;
	EMISSION = sss_tint * tip * sss + tip * flat_emission;
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
uniform sampler2D centerline_z_tex : filter_linear, repeat_disable;
uniform sampler2D occluder_mask : filter_nearest, repeat_disable;
uniform sampler2D water_mask_tex : filter_linear, repeat_disable;
uniform float water_mask_active = 0.0;
uniform float occluder_extent = 220.0;  // world extent (m) covered by the mask
uniform float terrain_size = 1024.0;
uniform float terrain_cell = 1.0;
uniform float bank_exclusion = 0.0;   // 0 disables river-band discard
uniform vec2  patch_center = vec2(0.0);
uniform float fade_inner   = 5.5;
uniform float fade_outer   = 7.0;
uniform float min_normal_y = 0.72;
uniform float max_elev     = 55.0;
uniform float cell_step    = 0.21;
// Integer numerator/denominator for the cell→world rational. cell_step
// equals patch_size_i / grid_i, but we keep the integers so the
// multiplication stays exact (no float-roundoff accumulating in cell_step).
uniform int   patch_size_i = 60;
uniform int   grid_i       = 820;
// Integer cell offset for this layer based on the patch's snapped world
// position. World cell = INSTANCE_CUSTOM.xy + patch_cell_offset. CPU-computed
// with doubles so the world-cell mapping is exact and never collides.
uniform vec2  patch_cell_offset = vec2(0.0);
// 0 = no clump density modulation (CORE — full density right at player).
// 1 = full clump modulation (SHORT/TALL — dry patches sparser).
uniform float clump_strength = 0.0;

uniform vec3  base_color  : source_color = vec3(0.05, 0.09, 0.05);
uniform vec3  tip_meadow  : source_color = vec3(0.24, 0.36, 0.14);
uniform vec3  tip_dry     : source_color = vec3(0.34, 0.40, 0.16);
uniform vec3  tip_yellow  : source_color = vec3(0.48, 0.42, 0.12);
uniform vec3  sss_tint    : source_color = vec3(0.95, 1.05, 0.45);
uniform float yellow_chance = 0.18;
uniform float backlight_strength = 0.6;
// Tweakable runtime params for tile-grass-style controls on the patch.
uniform float albedo_boost = 1.0;
uniform float flat_emission = 0.0;
uniform float roughness_val = 0.60;
uniform float specular_val = 0.10;
uniform float normal_flatten = 0.30;
uniform float hemi_tilt = 0.55;
// REGION 2 uniforms — SHORT/TALL blades smoothly lerp from the primary
// (region 1) uniforms above to these across `color_zone_inner..outer`.
// On the CORE material we set the zone to ∞ so CORE stays in region 1.
uniform vec3  base_color_taper   : source_color = vec3(0.05, 0.09, 0.05);
uniform vec3  tip_meadow_taper   : source_color = vec3(0.24, 0.36, 0.14);
uniform vec3  tip_dry_taper      : source_color = vec3(0.34, 0.40, 0.16);
uniform vec3  tip_yellow_taper   : source_color = vec3(0.48, 0.42, 0.12);
uniform float albedo_boost_taper = 1.0;
uniform float flat_emission_taper = 0.0;
// AO floor — sets how dark blade bases get. 1.0 = no AO. Lerped between
// region 1 (ao_min) and region 2 (ao_min_taper) by v_taper.
uniform float ao_min = 0.45;
uniform float ao_min_taper = 0.45;
uniform float color_zone_inner = 22.0;
uniform float color_zone_outer = 56.0;
// Density fade-in: blades inside this range are probabilistically culled
// (smoothly grows from 0 → full density). Defaults make the formula a no-op
// (fade_in_outer ≤ fade_in_inner → smoothstep returns 1 everywhere). CORE
// uses defaults; SHORT/TALL sets fade_in to match CORE's fade-out range so
// total density stays roughly constant across the CORE→SHORT/TALL handoff.
uniform float fade_in_inner = -1.0;
uniform float fade_in_outer = 0.0;
// Direction TOWARD the sun in world space, set per-frame from the
// DirectionalLight3D. Default = straight up so first frame isn't black.
uniform vec3  sun_dir_world = vec3(0.0, 1.0, 0.0);
uniform float wind_speed     = 1.1;
uniform float wind_strength  = 0.55;
uniform vec2  wind_dir       = vec2(0.7, 0.7);

float sample_h(vec2 wxz) {
	vec2 uv = (wxz + vec2(terrain_size * 0.5)) / terrain_size;
	return texture(heightmap, uv).r;
}

// IQ hash (https://www.shadertoy.com/view/4djSRW) — sin-free. The sin-based
// version produced visible diagonal banding because sin loses precision at
// the dot-product magnitudes our cell indices reach.
float h12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
vec2 h22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract(vec2((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y));
}

// 2D value noise + 5-octave fBm for large-scale color clumping across the
// meadow. Same as the tile shader's noise.
float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = h12(i);
	float b = h12(i + vec2(1.0, 0.0));
	float c = h12(i + vec2(0.0, 1.0));
	float d = h12(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}
float fbm2(vec2 p) {
	float v = 0.0; float a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * vnoise2(p); p *= 2.05; a *= 0.5; }
	return v;
}

// Hemisphere normal: each fragment's UV.x tells us where across the blade
// we are; we tilt the world-space normal outward as if the blade were a
// curved cylinder rather than a flat ribbon.
varying vec3 v_blade_x_world;
varying vec3 v_blade_n_world;
varying float v_clump;   // large-scale color biome noise sampled per-instance
varying float v_slope_y; // smoothed terrain normal Y at the blade — feeds dryness shift
varying float v_taper;   // 0 inside fade_inner (close), 1 past fade_outer (no-grass land)

void vertex() {
	vec3 wo = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	ivec2 cell_i = ivec2(int(wo.x), int(wo.z)) + ivec2(patch_cell_offset);
	vec2 cell = vec2(cell_i);
	vec2 cell_origin = vec2(cell_i * patch_size_i) / float(grid_i);
	vec2 jitter = (h22(cell + 13.7) - 0.5) * cell_step * 0.85;
	vec2 anchored = cell_origin + jitter;

	// CHEAP density check FIRST. Survival hash + radial fade are all that's
	// needed to decide if this blade is doomed; clump modulation can only
	// DECREASE density, never raise it. (Godot doesn't allow `return` from
	// vertex(), so we use an if-block to wrap the expensive path.)
	float surv = h12(cell + 17.0);
	float r = length(anchored - patch_center);
	float fade_in_q = smoothstep(fade_in_inner, fade_in_outer, r);
	float density_no_clump = fade_in_q * (1.0 - smoothstep(fade_inner, fade_outer, r));
	if (density_no_clump < surv) {
		// Doomed. Collapse below terrain and skip all texture/fBm/wind work.
		VERTEX = vec3(anchored.x, -1000.0, anchored.y);
		v_blade_x_world = vec3(1.0, 0.0, 0.0);
		v_blade_n_world = vec3(0.0, 0.0, 1.0);
		v_clump = 0.0;
		v_slope_y = 1.0;
		v_taper = 0.0;
		COLOR = vec4(0.0);
	} else {

	float yaw    = h12(cell + 1.3) * 6.2831853;
	float sw     = 0.85 + h12(cell + 7.9) * 0.30;
	float sy     = 0.75 + h12(cell + 3.1) * 0.55;
	float dry    = h12(cell + 5.5);
	float hue    = h12(cell + 9.2);
	vec2  lean_c = (h22(cell + 11.0) * 2.0 - 1.0) * 0.7;

	float cy = cos(yaw);
	float sy_yaw = sin(yaw);
	v_blade_x_world = vec3(cy, 0.0, sy_yaw);
	v_blade_n_world = vec3(-sy_yaw, 0.0, cy);

	float h = sample_h(anchored);

	float h_l = sample_h(anchored + vec2(-terrain_cell, 0.0));
	float h_r = sample_h(anchored + vec2( terrain_cell, 0.0));
	float h_d = sample_h(anchored + vec2(0.0, -terrain_cell));
	float h_u = sample_h(anchored + vec2(0.0,  terrain_cell));
	float dx = (h_r - h_l) / (2.0 * terrain_cell);
	float dz = (h_u - h_d) / (2.0 * terrain_cell);
	float ny = 1.0 / sqrt(dx*dx + dz*dz + 1.0);
	v_slope_y = ny;
	v_clump = fbm2(anchored * 0.033);

	v_taper = smoothstep(color_zone_inner, color_zone_outer, r);
	float fade_in = fade_in_q;
	float density = density_no_clump;
	float clump_dense = mix(1.0, mix(0.3, 1.0, smoothstep(0.35, 0.65, v_clump)), clump_strength);
	density *= clump_dense;
	float keep = step(surv, density);
	float elev = 1.0 - smoothstep(max_elev - 5.0, max_elev, h);
	float slope_keep = step(min_normal_y, ny);
	keep *= elev * slope_keep;
	if (bank_exclusion > 0.0) {
		float u = (anchored.x + terrain_size * 0.5) / terrain_size;
		float cz_at = texture(centerline_z_tex, vec2(u, 0.5)).r;
		float dz_riv = abs(anchored.y - cz_at);
		keep *= step(bank_exclusion, dz_riv);
	}
	// Water mask: blades inside / near a river or lake cell get culled.
	// Bilinear sample + smoothstep gives a soft boundary instead of a
	// rectilinear 1 m grid edge.
	if (water_mask_active > 0.5) {
		vec2 wu = (anchored + vec2(terrain_size * 0.5)) / terrain_size;
		float in_water = texture(water_mask_tex, wu).r;
		keep *= 1.0 - smoothstep(0.25, 0.75, in_water);
	}
	// Occluder mask: stumps, fallen logs, placed wood. Anywhere the mask is
	// non-zero, this blade is inside an object — drop it (the trailing VERTEX
	// collapse below maps it to a degenerate triangle).
	vec2 occ_uv = (anchored - patch_center) / occluder_extent + vec2(0.5);
	float occluded = step(0.5, texture(occluder_mask, occ_uv).r);
	keep *= (1.0 - occluded);

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
	// Hard-collapse culled blades (rocky slope / river band / past fade) to a
	// single point — degenerate triangles aren't rasterized. Without this, a
	// keep=0 blade still spreads horizontally via local_xz/sway/lean and reads
	// as a sprout poking through the ground on rocky terrain or the bank.
	VERTEX = mix(vec3(anchored.x, h, anchored.y), VERTEX, keep);

	COLOR.r = bend;
	COLOR.g = dry;
	COLOR.b = hue;
	}  // end of else branch (density_no_clump >= surv)
}

void fragment() {
	float bend = COLOR.r;
	float dry  = COLOR.g;
	float hue  = COLOR.b;
	// Region blend: 0 at center (close, full density) → 1 at fade_outer
	// (taper, where patch fades to nothing). Each color/brightness param
	// lerps from its primary value to its `_taper` variant by v_taper.
	vec3 base_eff   = mix(base_color, base_color_taper, v_taper);
	vec3 tipM_eff   = mix(tip_meadow, tip_meadow_taper, v_taper);
	vec3 tipD_eff   = mix(tip_dry,    tip_dry_taper,    v_taper);
	vec3 tipY_eff   = mix(tip_yellow, tip_yellow_taper, v_taper);
	float boost_eff = mix(albedo_boost, albedo_boost_taper, v_taper);
	float fe_eff    = mix(flat_emission, flat_emission_taper, v_taper);
	float ao_eff    = mix(ao_min, ao_min_taper, v_taper);
	// Slope-based wetness shift: steep ground (lower ny) reads slightly
	// drier/yellower. v_slope_y is 1 on flat, dropping to ~0.7 on slopes.
	float slope_dry = clamp((1.0 - v_slope_y) * 2.0, 0.0, 1.0);
	float biome_dry = clamp(v_clump * 1.4 - 0.2, 0.0, 1.0);
	float combined_dry = clamp(dry * 0.5 + biome_dry * 0.6 + slope_dry * 0.4, 0.0, 1.0);
	vec3 dry_tip = mix(tipD_eff, tipY_eff, step(1.0 - yellow_chance, hue));
	vec3 tip = mix(tipM_eff, dry_tip, combined_dry);
	float t_bend = pow(max(bend, 0.0), 1.5);
	vec3 col = mix(base_eff, tip, t_bend);
	col *= mix(0.92, 1.08, hue);
	col *= mix(ao_eff, 1.0, bend);
	ALBEDO = col * boost_eff;
	ROUGHNESS = roughness_val;
	SPECULAR = specular_val;
	// Hemisphere normal: blade reads as curved cylinder, not flat ribbon.
	float tilt = clamp((UV.x - 0.5) * 2.0, -1.0, 1.0) * hemi_tilt;
	vec3 hemi_world = normalize(v_blade_n_world * cos(tilt) + v_blade_x_world * sin(tilt));
	hemi_world = normalize(mix(hemi_world, vec3(0.0, 1.0, 0.0), bend * normal_flatten));
	// Distance-based normal flatten: at far view distance, lerp toward up so
	// far blades read as a mass instead of producing specular aliasing.
	float view_dist = length(VERTEX);
	float far_flat = smoothstep(20.0, 60.0, view_dist);
	hemi_world = normalize(mix(hemi_world, vec3(0.0, 1.0, 0.0), far_flat * 0.6));
	NORMAL = normalize(mat3(VIEW_MATRIX) * hemi_world);
	vec3 view_dir_world = normalize(mat3(INV_VIEW_MATRIX) * VIEW);
	float back = max(0.0, -dot(view_dir_world, sun_dir_world));
	float sss = pow(max(back, 0.0), 4.0) * (0.3 + 0.7 * max(bend, 0.0)) * backlight_strength;
	EMISSION = sss_tint * tip * sss + tip * fe_eff;
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
	mat.set_shader_parameter("centerline_z_tex", _centerline_z_tex)
	mat.set_shader_parameter("bank_exclusion", GRASS_BANK_EXCLUSION if STREAM_ENABLED else 0.0)
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

uniform vec3 grass_lush  : source_color = vec3(0.180, 0.247, 0.063);
uniform vec3 grass_dry   : source_color = vec3(0.32, 0.36, 0.20);
uniform vec3 dirt_dark   : source_color = vec3(0.20, 0.13, 0.07);
uniform vec3 dirt_light  : source_color = vec3(0.42, 0.30, 0.18);
uniform vec3 rock_dark   : source_color = vec3(0.22, 0.21, 0.20);
uniform vec3 rock_light  : source_color = vec3(0.55, 0.52, 0.48);
uniform vec3 snow_color  : source_color = vec3(0.93, 0.95, 0.97);
// Riverbed / lakebed palette — shallow shoreline reads as wet sand, deep
// reads as muddy silt. The blend uses the same water mask as the grass cull
// (filter_linear) so the boundary anti-aliases naturally.
uniform vec3 bed_sand    : source_color = vec3(0.55, 0.46, 0.30);
uniform vec3 bed_silt    : source_color = vec3(0.22, 0.18, 0.13);
uniform sampler2D water_mask_tex : filter_linear, repeat_disable;
uniform float water_mask_active = 0.0;
uniform float terrain_size_ground = 1024.0;
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

	// Single flat grass color — earlier patch/detail mixing produced bright
	// spots that revealed where individual blades were sparse, defeating the
	// "ground matches grass" goal.
	vec3 grass = grass_lush;

	// "Where would the grass shader actually place blades?" — match the
	// grass placement test so we don't paint brown dirt under green grass.
	// Grass needs flat-ish ground (slope ≥ grass_normal_y) AND not-too-high
	// elevation (the grass shader culls past ~55m for elev fade).
	float grass_friendly = smoothstep(grass_normal_y - 0.05, grass_normal_y + 0.05, slope)
		* (1.0 - smoothstep(50.0, 55.0, elev));

	// Dirt: appears on slopes too steep for grass, AND in noise spikes when
	// the spot wasn't grass-friendly to begin with. In grass-friendly spots,
	// dirt patches are suppressed so the visible ground matches the blade
	// color all the way down to where sparse blades let the ground peek through.
	vec3 dirt = mix(dirt_dark, dirt_light, fbm(wp.xz * 0.4));
	float dirt_patch = smoothstep(0.62, 0.78, fbm(wp.xz * 0.08));
	float dirt_slope = smoothstep(grass_normal_y, grass_normal_y - 0.12, slope);
	dirt_patch *= (1.0 - grass_friendly * 0.9);
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

	// Riverbed / lakebed: replace surface materials with a sand→silt blend
	// where the water mask says we're under water. The water mask is the
	// same texture the grass shader uses (filter_linear so the bed→bank
	// transition anti-aliases). Sand on the rim, silt at the centre.
	if (water_mask_active > 0.5) {
		vec2 wu = (wp.xz + vec2(terrain_size_ground * 0.5)) / terrain_size_ground;
		float in_water = texture(water_mask_tex, wu).r;
		// Bed only paints STRICTLY inside the water mask — earlier 0.15
		// threshold leaked an orange halo 1 cell (~1 m) outside the actual
		// water shape. Pushing to 0.7 keeps the bed under the water plane.
		float bed_t = smoothstep(0.7, 0.95, in_water);
		vec3 bed = mix(bed_sand, bed_silt, smoothstep(0.8, 0.98, in_water));
		bed *= mix(0.85, 1.1, fbm(wp.xz * 0.7));
		ground = mix(ground, bed, bed_t);
	}

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
	# Same loader as stones: shifts each tree's parts so the trunk base is at
	# local y=0, and stores the unioned AABB on each variant for collision sizing.
	return _load_glb_variants(_discover_tree_paths())

func _discover_tree_paths() -> Array:
	# Polyhaven layout is `trees/<asset>/<asset>_2k.gltf` (one folder per asset
	# so textures stay grouped). Recurse one level so both flat and per-folder
	# layouts work.
	var paths: Array = []
	_scan_tree_dir(TREE_DIR, paths, 2)
	if paths.is_empty():
		push_warning("[Terrain] No tree GLBs in %s — using Kenney fallback. Drop .glb/.gltf files into that folder for the mature look." % TREE_DIR)
		paths = TREE_FALLBACK_PATHS.duplicate()
	return paths

# Polyhaven assets whose names look like trees but ship a horizontal-log mesh
# (e.g. fallen_log_5m_PROXY) instead of a standing trunk. They break the
# upright/fall math when treated as trees, so skip the whole folder.
const _TREE_DIR_SKIPLIST := ["dead_tree_trunk_02"]

func _scan_tree_dir(path: String, out: Array, depth_left: int) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if fname == "." or fname == "..":
			fname = dir.get_next()
			continue
		var full: String = path + fname
		if dir.current_is_dir():
			if depth_left > 0 and not _TREE_DIR_SKIPLIST.has(fname):
				_scan_tree_dir(full + "/", out, depth_left - 1)
		elif fname.ends_with(".glb") or fname.ends_with(".gltf"):
			out.append(full)
		fname = dir.get_next()

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
			var m: Mesh = (node as MeshInstance3D).mesh
			# Path-based dispatch: trees get green-leaf tint + matte; flowers
			# only get matte (keep natural petal color); stones get nothing.
			if path.contains("/trees/"):
				_tint_leaf_materials(m)
			elif path.contains("/flowers/"):
				_matte_flower_materials(m)
			parts.append({"mesh": m, "xform": x})
		for c in node.get_children():
			stack.append({"node": c, "xform": x})
	root.free()
	return parts

# --- River network: D8 flow accumulation (NEW) -------------------------------
# Replaces the old monotonic gradient-descent tracer with a real hydrology
# algorithm. Procedure:
#   1. Sample _heights into a 257×257 (4 m cells) low-res grid. Rivers don't
#      care about features below their own width, and a min-heap priority
#      flood at full 1025² would push 1 M items through GDScript — too slow.
#   2. Priority-flood-with-ε (Barnes 2014): pop cells from low to high,
#      assigning each unvisited neighbor a flow direction back to the popped
#      cell and "filling" depressions by clamping neighbor heights to
#      max(raw, popped + ε). Every cell ends up with a flow path that
#      eventually exits the map.
#   3. Walk the pop order in reverse (peaks → outlets) to accumulate
#      upstream contributing area per cell. Cells with high acc are rivers.
#   4. Above a threshold, trace centerlines from every "head" cell (river
#      cell with no upstream river cell) downstream until merging into a
#      bigger river or hitting the map edge / a basin.

const RIVER_GRID: int = 257
const RIVER_CELL: float = SIZE / float(RIVER_GRID - 1)
const RIVER_FILL_EPS: float = 0.001
# Cells with at least this many upstream cells are considered river cells.
# Higher → fewer / larger streams. 400 cells at low-res ≈ 6400 m² catchment,
# matches a small stream / brook in real hydrology.
const RIVER_ACC_THRESHOLD: float = 400.0
const RIVER_SMOOTH_PASSES: int = 8          # box-blur passes on XZ — kills stair-step zigzag
const RIVER_RESAMPLE_STEP: float = 0.25     # output vertex spacing in meters
# Keep ONLY the polyline that passes through the global max-accumulation cell
# (the trunk). All tributaries get discarded.
const RIVER_TRUNK_ONLY: bool = true

# Low-res buffers (sized RIVER_GRID * RIVER_GRID).
var _river_filled_h: PackedFloat32Array
var _river_flow_dir: PackedInt32Array       # 0-7 (per _FLOW_NEIGHBORS), -1 if uninitialized
var _river_accumulation: PackedFloat32Array

# Resolved river network — raw cell indices, head → mouth. Used internally as
# the input to the smoothing/resampling pass.
var _river_polylines: Array = []
# Smoothed & resampled polylines. Each entry is an Array of dicts:
#   { wpos: Vector2, h: float, acc: float }
# `h` is the FILLED elevation (monotonically non-increasing along the
# polyline), so the water surface never climbs.
var _river_polylines_smoothed: Array = []

# --- Per-trace river/lake finder ---------------------------------------------
# Press P to start (or R to reset) from the camera's current XZ.
# Algorithm:
#   1. Steepest descent on raw _heights, skipping cells already on the river
#      or in any lake.
#   2. When descent fails (no fresh downhill, or the steepest target is
#      already on the river / in a lake), start a lake at the current cell.
#   3. Lake pour-over: pop the lowest unvisited 8-neighbor of any lake cell.
#      - If it's already in another lake → merge the two lakes.
#      - Otherwise add it to the active lake. If the newly added cell's
#        steepest descent points to a cell OUTSIDE the lake, that's the
#        spillover — resume descent from there.
const USER_ALG_STEP_INTERVAL: float = 0.01    # seconds per render tick
const USER_ALG_STEPS_PER_TICK: int = 80       # algorithm steps per tick (fast)
const USER_ALG_AUTOSTART: Vector2 = Vector2(294.4, 426.4)
# Terminate once the active lake's vertical extent (max cell height − min
# cell height) exceeds this. Anything shallower is treated as a small dip
# that gets bridged; anything deeper is the "final" lake.
const USER_ALG_LAKE_DEPTH_TERMINATE: float = 5.0
var _user_alg_autostart_done: bool = false
var _user_alg_water_built: bool = false   # set once we replace debug viz with real water
var _user_alg_active: bool = false
var _user_alg_done: bool = false
var _user_alg_origin_world: Vector3 = Vector3.ZERO
var _user_alg_river: PackedInt32Array         # ordered river cell list
var _user_alg_river_set: Dictionary = {}      # cell idx -> true (fast lookup)
# Each lake: { cells: Dictionary (cell→true), heap: _MinHeap (height→cell),
#              pushed: Dictionary (cell→true, dedup heap pushes) }
# Merged-into-another lakes are set to null in this array (indices stay
# stable so cell_to_lake mappings don't have to renumber).
var _user_alg_lakes: Array = []
var _user_alg_cell_to_lake: Dictionary = {}   # cell idx -> lake index in _user_alg_lakes
var _user_alg_current: int = -1
var _user_alg_mode: int = 0                   # 0 = descent, 1 = lake pour-over
var _user_alg_active_lake_idx: int = -1
var _user_alg_cooldown: float = 0.0
var _user_alg_river_mi: MeshInstance3D
var _user_alg_lake_mi: MeshInstance3D
var _user_alg_origin_mi: MeshInstance3D
var _user_alg_label: Label
# Source spring-pond: a small basin carved at the trunk source so water visibly
# flows out of something rather than materializing at a point.
const RIVER_SOURCE_POND_RADIUS: float = 5.0
const RIVER_SOURCE_POND_DEPTH: float = 1.2
var _river_source_pond: Dictionary = {}    # {center: Vector2, water_y: float, radius: float}
# Mouth lake — the largest natural depression the trunk crosses. Already deep
# enough in the raw heightmap, just needs a water mesh. `cells` is a
# PackedInt32Array of FULL-RES heightmap indices (z*GRID + x) inside the lake.
var _river_mouth_lake: Dictionary = {}     # {center: Vector2, water_y: float, cells: PackedInt32Array, bounds: Rect2}
# Lake water surface height. Any heightmap cell below this, reachable by
# flood-fill from the lake seed, is underwater.
const RIVER_LAKE_WATER_Y: float = -50.0
const RIVER_LAKE_SEED_WORLD: Vector2 = Vector2(-296.0, 426.0)
# River surface mesh.
const RIVER_MAX_WIDTH: float = 5.0
const RIVER_MIN_WIDTH: float = 1.2
const RIVER_WATER_LIFT: float = 0.08            # surface sits this far above filled-h
var _river_water_mi: MeshInstance3D
var _river_water_material: ShaderMaterial

func _compute_river_flow() -> void:
	var t_start: int = Time.get_ticks_msec()
	var N: int = RIVER_GRID * RIVER_GRID
	var half: float = SIZE * 0.5

	# Step 1: sample full heightmap into low-res grid (bilinear).
	var raw := PackedFloat32Array()
	raw.resize(N)
	for gz in RIVER_GRID:
		for gx in RIVER_GRID:
			var wx: float = float(gx) * RIVER_CELL - half
			var wz: float = float(gz) * RIVER_CELL - half
			raw[gz * RIVER_GRID + gx] = _sample_height(_heights, wx, wz)

	_river_filled_h = raw.duplicate()
	_river_flow_dir = PackedInt32Array()
	_river_flow_dir.resize(N)
	for i in N:
		_river_flow_dir[i] = -1
	var visited := PackedByteArray()
	visited.resize(N)   # zero-initialized

	var pop_order := PackedInt32Array()
	pop_order.resize(N)
	var pop_count: int = 0

	var heap := _MinHeap.new()

	# Seed boundary cells (where water exits the map).
	for gx in RIVER_GRID:
		var idx_top: int = gx
		heap.push(idx_top, raw[idx_top])
		visited[idx_top] = 1
		var idx_bot: int = (RIVER_GRID - 1) * RIVER_GRID + gx
		heap.push(idx_bot, raw[idx_bot])
		visited[idx_bot] = 1
	for gz in range(1, RIVER_GRID - 1):
		var idx_l: int = gz * RIVER_GRID
		heap.push(idx_l, raw[idx_l])
		visited[idx_l] = 1
		var idx_r: int = gz * RIVER_GRID + (RIVER_GRID - 1)
		heap.push(idx_r, raw[idx_r])
		visited[idx_r] = 1

	# Step 2: priority-flood.
	while not heap.is_empty():
		var cell_idx: int = heap.pop()
		pop_order[pop_count] = cell_idx
		pop_count += 1
		var cell_h: float = _river_filled_h[cell_idx]
		var cgx: int = cell_idx % RIVER_GRID
		var cgz: int = cell_idx / RIVER_GRID
		for d in 8:
			var off: Vector2i = _FLOW_NEIGHBORS[d]
			var ngx: int = cgx + off.x
			var ngz: int = cgz + off.y
			if ngx < 0 or ngz < 0 or ngx >= RIVER_GRID or ngz >= RIVER_GRID:
				continue
			var n_idx: int = ngz * RIVER_GRID + ngx
			if visited[n_idx] == 1:
				continue
			visited[n_idx] = 1
			var raw_h: float = raw[n_idx]
			var filled: float = maxf(raw_h, cell_h + RIVER_FILL_EPS)
			_river_filled_h[n_idx] = filled
			# Neighbor flows back toward the cell we just popped. The offset
			# from neighbor→cell is the negation of cell→neighbor; in our
			# _FLOW_NEIGHBORS layout this is index (7 - d).
			_river_flow_dir[n_idx] = 7 - d
			heap.push(n_idx, filled)

	# Step 3: accumulation walk (reverse pop order = peaks first).
	_river_accumulation = PackedFloat32Array()
	_river_accumulation.resize(N)
	for i in N:
		_river_accumulation[i] = 1.0
	for i in range(pop_count - 1, -1, -1):
		var idx: int = pop_order[i]
		var d: int = _river_flow_dir[idx]
		if d < 0:
			continue
		var off: Vector2i = _FLOW_NEIGHBORS[d]
		var cgx: int = idx % RIVER_GRID
		var cgz: int = idx / RIVER_GRID
		var ngx: int = cgx + off.x
		var ngz: int = cgz + off.y
		if ngx < 0 or ngz < 0 or ngx >= RIVER_GRID or ngz >= RIVER_GRID:
			continue
		var n_idx: int = ngz * RIVER_GRID + ngx
		_river_accumulation[n_idx] += _river_accumulation[idx]

	var max_acc: float = 0.0
	var river_cells: int = 0
	for i in N:
		if _river_accumulation[i] > max_acc:
			max_acc = _river_accumulation[i]
		if _river_accumulation[i] >= RIVER_ACC_THRESHOLD:
			river_cells += 1
	var t_ms: int = Time.get_ticks_msec() - t_start
	print("[River] flow accumulation: %d×%d grid, max acc=%d, river cells=%d, %d ms" % [
		RIVER_GRID, RIVER_GRID, int(max_acc), river_cells, t_ms])

# Extract centerline polylines from the accumulation grid.
# A "head" is a river cell with no river cell flowing INTO it (i.e., a
# headwater). From each head, walk downstream along flow_dir until we either
# hit the map edge, a sink, or a cell already claimed by another polyline
# (a tributary merge). Each polyline is a sequence of low-res cell indices.
#
# Each cell index is a `gz * RIVER_GRID + gx` low-res index. Convert to world
# coords with `_river_cell_to_world(idx)`.
func _extract_river_network() -> void:
	var t_start: int = Time.get_ticks_msec()
	_river_polylines.clear()
	var N: int = RIVER_GRID * RIVER_GRID

	# Mark river cells.
	var is_river := PackedByteArray()
	is_river.resize(N)
	for i in N:
		is_river[i] = 1 if _river_accumulation[i] >= RIVER_ACC_THRESHOLD else 0

	# Count how many river cells flow INTO each cell.
	var inflow := PackedInt32Array()
	inflow.resize(N)
	for i in N:
		if is_river[i] == 0:
			continue
		var d: int = _river_flow_dir[i]
		if d < 0:
			continue
		var cgx: int = i % RIVER_GRID
		var cgz: int = i / RIVER_GRID
		var off: Vector2i = _FLOW_NEIGHBORS[d]
		var ngx: int = cgx + off.x
		var ngz: int = cgz + off.y
		if ngx < 0 or ngz < 0 or ngx >= RIVER_GRID or ngz >= RIVER_GRID:
			continue
		var n_idx: int = ngz * RIVER_GRID + ngx
		if is_river[n_idx] == 1:
			inflow[n_idx] += 1

	# Walk each head downhill. `visited` marks cells already claimed by a
	# polyline so tributaries terminate at the merge cell rather than
	# duplicating the trunk.
	var visited := PackedByteArray()
	visited.resize(N)
	var min_polyline_cells: int = 6   # ignore stubs shorter than ~24 m

	for head in N:
		if is_river[head] == 0:
			continue
		if inflow[head] != 0:
			continue
		var polyline := PackedInt32Array()
		var cur: int = head
		while cur >= 0 and is_river[cur] == 1:
			polyline.append(cur)
			if visited[cur] == 1:
				break
			visited[cur] = 1
			var d: int = _river_flow_dir[cur]
			if d < 0:
				break
			var cgx: int = cur % RIVER_GRID
			var cgz: int = cur / RIVER_GRID
			var off: Vector2i = _FLOW_NEIGHBORS[d]
			var ngx: int = cgx + off.x
			var ngz: int = cgz + off.y
			if ngx < 0 or ngz < 0 or ngx >= RIVER_GRID or ngz >= RIVER_GRID:
				break
			cur = ngz * RIVER_GRID + ngx
		if polyline.size() >= min_polyline_cells:
			_river_polylines.append(polyline)

	var total_v: int = 0
	for pl in _river_polylines:
		total_v += (pl as PackedInt32Array).size()
	var t_ms: int = Time.get_ticks_msec() - t_start
	print("[River] extracted %d polylines, %d total vertices, %d ms" % [
		_river_polylines.size(), total_v, t_ms])

	if RIVER_TRUNK_ONLY and not _river_polylines.is_empty():
		# Flood-fill the user-specified lake FIRST. The chosen river is then
		# whichever extracted polyline actually drains into that lake.
		_flood_fill_mouth_lake()
		_select_trunk_into_lake()
		# Extend the trunk SOURCE upstream past the river-threshold so it
		# starts at a true headwater (no inflow) rather than the arbitrary
		# spot where accumulation crossed 400 cells.
		_extend_trunk_source()
		_truncate_trunk_at_lake_edge()
		if not _river_polylines.is_empty():
			var t := _river_polylines[0] as PackedInt32Array
			var src_w := _river_cell_to_world(t[0])
			var src_h := _river_filled_h[t[0]]
			var mth_w := _river_cell_to_world(t[t.size() - 1])
			var mth_h := _river_filled_h[t[t.size() - 1]]
			print("[River] source: (%.1f, %.1f) elev %.1f → mouth: (%.1f, %.1f) elev %.1f" % [
				src_w.x, src_w.y, src_h, mth_w.x, mth_w.y, mth_h])
			_report_basins_on_trunk()

# 4-connected flood fill from RIVER_LAKE_SEED_WORLD across the full-res
# heightmap, collecting every cell with raw h < RIVER_LAKE_WATER_Y. Result is
# the lake's true (irregular) footprint — stored in _river_mouth_lake.
func _flood_fill_mouth_lake() -> void:
	var half: float = SIZE * 0.5
	var seed_gx: int = int((RIVER_LAKE_SEED_WORLD.x + half) / CELL)
	var seed_gz: int = int((RIVER_LAKE_SEED_WORLD.y + half) / CELL)
	seed_gx = clampi(seed_gx, 0, GRID - 1)
	seed_gz = clampi(seed_gz, 0, GRID - 1)
	var seed_idx: int = seed_gz * GRID + seed_gx
	if _heights[seed_idx] >= RIVER_LAKE_WATER_Y:
		print("[River] WARN: lake seed at (%.0f, %.0f) has h=%.1f (above water level %.1f)" % [
			RIVER_LAKE_SEED_WORLD.x, RIVER_LAKE_SEED_WORLD.y, _heights[seed_idx], RIVER_LAKE_WATER_Y])
		return
	var lake_cells := PackedInt32Array()
	var visited := PackedByteArray()
	visited.resize(GRID * GRID)
	var stack: Array = [seed_idx]
	visited[seed_idx] = 1
	var center_sum := Vector2.ZERO
	var min_x: int = GRID
	var max_x: int = -1
	var min_z: int = GRID
	var max_z: int = -1
	while not stack.is_empty():
		var idx: int = stack.pop_back()
		lake_cells.append(idx)
		var gx: int = idx % GRID
		var gz: int = idx / GRID
		center_sum += Vector2(float(gx) * CELL - half, float(gz) * CELL - half)
		min_x = mini(min_x, gx)
		max_x = maxi(max_x, gx)
		min_z = mini(min_z, gz)
		max_z = maxi(max_z, gz)
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var ngx: int = gx + off.x
			var ngz: int = gz + off.y
			if ngx < 0 or ngz < 0 or ngx >= GRID or ngz >= GRID:
				continue
			var n_idx: int = ngz * GRID + ngx
			if visited[n_idx] == 1:
				continue
			if _heights[n_idx] >= RIVER_LAKE_WATER_Y:
				continue
			visited[n_idx] = 1
			stack.append(n_idx)
	if lake_cells.is_empty():
		return
	var center: Vector2 = center_sum / float(lake_cells.size())
	var bounds := Rect2(
		Vector2(float(min_x) * CELL - half, float(min_z) * CELL - half),
		Vector2(float(max_x - min_x + 1) * CELL, float(max_z - min_z + 1) * CELL)
	)
	_river_mouth_lake = {
		"center": center,
		"water_y": RIVER_LAKE_WATER_Y,
		"cells": lake_cells,
		"bounds": bounds,
	}
	print("[River] flood-filled mouth lake: %d cells, center (%.1f, %.1f), bounds %s, water_y %.1f" % [
		lake_cells.size(), center.x, center.y, bounds, RIVER_LAKE_WATER_Y])

# Truncate the trunk to end at the entrance of the LARGEST natural basin it
# passes through. The basin then becomes a lake (water pools naturally because
# its raw terrain sits below the river's filled water level). Smaller pre-
# basin dips stay as part of the river — they're shallow and brief.
const RIVER_BASIN_MIN_DEPTH: float = 4.0     # ignore shallow dips
const RIVER_BASIN_MIN_LENGTH: int = 8        # ignore brief drops (cells)

# Among all extracted polylines, pick the one that drains into the user-
# specified lake. Score by the maximum accumulation along the polyline before
# (or at) its lake-entry cell — proxies "biggest stream feeding the lake."
func _select_trunk_into_lake() -> void:
	if _river_polylines.is_empty() or _river_mouth_lake.is_empty():
		return
	var lake_cells := _river_mouth_lake.cells as PackedInt32Array
	var lake_set := {}
	for c in lake_cells:
		lake_set[c] = true
	var half: float = SIZE * 0.5
	var best_pl: PackedInt32Array
	var best_score: float = -1.0
	for pl in _river_polylines:
		var poly := pl as PackedInt32Array
		var entry_acc: float = -1.0
		for cell in poly:
			var w := _river_cell_to_world(cell)
			var fgx: int = clampi(int((w.x + half) / CELL), 0, GRID - 1)
			var fgz: int = clampi(int((w.y + half) / CELL), 0, GRID - 1)
			if lake_set.has(fgz * GRID + fgx):
				entry_acc = _river_accumulation[cell]
				break
		if entry_acc > best_score:
			best_score = entry_acc
			best_pl = poly
	if best_score < 0.0:
		print("[River] WARN: no extracted polyline drains into the lake at seed (%.0f, %.0f)" % [
			RIVER_LAKE_SEED_WORLD.x, RIVER_LAKE_SEED_WORLD.y])
		# Fall back to the max-accumulation polyline (the global trunk).
		var max_acc_idx: int = 0
		var max_acc_val: float = -1.0
		for i in _river_accumulation.size():
			if _river_accumulation[i] > max_acc_val:
				max_acc_val = _river_accumulation[i]
				max_acc_idx = i
		for pl in _river_polylines:
			var poly := pl as PackedInt32Array
			for cell in poly:
				if cell == max_acc_idx:
					best_pl = poly
					break
			if not best_pl.is_empty():
				break
	_river_polylines = [best_pl]
	print("[River] selected polyline draining into lake (entry acc=%d, %d cells)" % [
		int(best_score), best_pl.size()])

# Walk the chosen trunk and cut it at the first cell whose corresponding
# full-res heightmap cell is INSIDE the flood-filled lake footprint. Records
# the source pond at the (possibly extended) head.
func _truncate_trunk_at_lake_edge() -> void:
	if _river_polylines.is_empty():
		return
	var trunk := _river_polylines[0] as PackedInt32Array
	if not _river_mouth_lake.is_empty():
		var lake_cells := _river_mouth_lake.cells as PackedInt32Array
		var lake_set := {}
		for c in lake_cells:
			lake_set[c] = true
		var half: float = SIZE * 0.5
		var truncate_at: int = -1
		for i in trunk.size():
			var lo: Vector2 = _river_cell_to_world(trunk[i])
			var fgx: int = clampi(int((lo.x + half) / CELL), 0, GRID - 1)
			var fgz: int = clampi(int((lo.y + half) / CELL), 0, GRID - 1)
			if lake_set.has(fgz * GRID + fgx):
				truncate_at = i
				break
		if truncate_at >= 0 and truncate_at > 0:
			var truncated := PackedInt32Array()
			for i in truncate_at:
				truncated.append(trunk[i])
			_river_polylines[0] = truncated
			var mw: Vector2 = _river_cell_to_world(truncated[truncated.size() - 1])
			print("[River] truncated trunk at lake edge: new mouth (%.1f, %.1f), kept %d cells" % [
				mw.x, mw.y, truncated.size()])
	# Source pond: small basin at the very first trunk vertex.
	var head_cell: int = (_river_polylines[0] as PackedInt32Array)[0]
	var src_w: Vector2 = _river_cell_to_world(head_cell)
	var src_h: float = _river_filled_h[head_cell]
	_river_source_pond = {
		"center": src_w,
		"water_y": src_h,
		"radius": RIVER_SOURCE_POND_RADIUS,
	}
	print("[River] source pond: center (%.1f, %.1f), radius %.1f m, water_y %.1f" % [
		src_w.x, src_w.y, RIVER_SOURCE_POND_RADIUS, src_h])

# --- User-algorithm implementation -------------------------------------------

func _start_user_alg_at(world_x: float, world_z: float) -> void:
	var half: float = SIZE * 0.5
	var gx: int = clampi(int((world_x + half) / CELL), 0, GRID - 1)
	var gz: int = clampi(int((world_z + half) / CELL), 0, GRID - 1)
	var seed_idx: int = gz * GRID + gx
	_user_alg_origin_world = Vector3(world_x, _heights[seed_idx], world_z)
	_user_alg_river = PackedInt32Array([seed_idx])
	_user_alg_river_set = {seed_idx: true}
	_user_alg_lakes = []
	_user_alg_cell_to_lake = {}
	_user_alg_current = seed_idx
	_user_alg_mode = 0
	_user_alg_active_lake_idx = -1
	_user_alg_cooldown = 0.0
	_user_alg_active = true
	_user_alg_done = false
	_ensure_user_alg_label()
	_update_user_alg_visual()
	print("[UserAlg] start at world (%.1f, %.1f) cell (%d, %d), h=%.1f" % [
		world_x, world_z, gx, gz, _heights[seed_idx]])

func _clear_user_alg() -> void:
	_user_alg_active = false
	_user_alg_done = false
	if _user_alg_river_mi:
		_user_alg_river_mi.queue_free(); _user_alg_river_mi = null
	if _user_alg_lake_mi:
		_user_alg_lake_mi.queue_free(); _user_alg_lake_mi = null
	if _user_alg_origin_mi:
		_user_alg_origin_mi.queue_free(); _user_alg_origin_mi = null
	if _user_alg_label:
		_user_alg_label.text = ""
	_user_alg_river = PackedInt32Array()
	_user_alg_river_set = {}
	_user_alg_lakes = []
	_user_alg_cell_to_lake = {}

func _ensure_user_alg_label() -> void:
	if _user_alg_label != null:
		return
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_user_alg_label = Label.new()
	_user_alg_label.position = Vector2(12, 50)
	_user_alg_label.add_theme_color_override("font_color", Color(0.4, 1.0, 1.0, 1))
	_user_alg_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_user_alg_label.add_theme_constant_override("outline_size", 4)
	canvas.add_child(_user_alg_label)

func _user_alg_total_lake_cells() -> int:
	var n: int = 0
	for L in _user_alg_lakes:
		if L != null:
			n += (L.cells as Dictionary).size()
	return n

func _user_alg_step() -> bool:
	if _user_alg_mode == 0:
		return _user_alg_descent_one()
	return _user_alg_lake_one()

func _user_alg_descent_one() -> bool:
	var cur: int = _user_alg_current
	var gx: int = cur % GRID
	var gz: int = cur / GRID
	var cur_h: float = _heights[cur]
	var best: int = -1
	var best_score: float = 0.0
	for d in 8:
		var off: Vector2i = _FLOW_NEIGHBORS[d]
		var ngx: int = gx + off.x
		var ngz: int = gz + off.y
		if ngx < 0 or ngz < 0 or ngx >= GRID or ngz >= GRID:
			continue
		var n_idx: int = ngz * GRID + ngx
		var dist: float = sqrt(float(off.x * off.x + off.y * off.y)) * CELL
		var slope: float = (cur_h - _heights[n_idx]) / dist
		if slope > best_score:
			best_score = slope
			best = n_idx
	if best < 0:
		_user_alg_start_lake_at(cur)
		return false
	if _user_alg_river_set.has(best) or _user_alg_cell_to_lake.has(best):
		_user_alg_start_lake_at(cur)
		return false
	_user_alg_river.append(best)
	_user_alg_river_set[best] = true
	_user_alg_current = best
	return false

func _user_alg_start_lake_at(seed_cell: int) -> void:
	if _user_alg_cell_to_lake.has(seed_cell):
		_user_alg_active_lake_idx = _user_alg_cell_to_lake[seed_cell]
	else:
		var lake := {
			"cells": {}, "heap": _MinHeap.new(), "pushed": {},
			"min_h": _heights[seed_cell], "max_h": _heights[seed_cell],
		}
		_user_alg_lakes.append(lake)
		_user_alg_active_lake_idx = _user_alg_lakes.size() - 1
		_user_alg_lake_add_cell(_user_alg_active_lake_idx, seed_cell)
	_user_alg_mode = 1

func _user_alg_lake_add_cell(lake_idx: int, cell: int) -> void:
	var lake = _user_alg_lakes[lake_idx]
	(lake.cells as Dictionary)[cell] = true
	_user_alg_cell_to_lake[cell] = lake_idx
	var h_c: float = _heights[cell]
	if h_c < (lake.min_h as float):
		lake.min_h = h_c
	if h_c > (lake.max_h as float):
		lake.max_h = h_c
	var gx: int = cell % GRID
	var gz: int = cell / GRID
	for d in 8:
		var off: Vector2i = _FLOW_NEIGHBORS[d]
		var ngx: int = gx + off.x
		var ngz: int = gz + off.y
		if ngx < 0 or ngz < 0 or ngx >= GRID or ngz >= GRID:
			continue
		var n_idx: int = ngz * GRID + ngx
		if (lake.cells as Dictionary).has(n_idx):
			continue
		if (lake.pushed as Dictionary).has(n_idx):
			continue
		(lake.heap as _MinHeap).push(n_idx, _heights[n_idx])
		(lake.pushed as Dictionary)[n_idx] = true

func _user_alg_lake_one() -> bool:
	var lake = _user_alg_lakes[_user_alg_active_lake_idx]
	var next_cell: int = -1
	while not (lake.heap as _MinHeap).is_empty():
		var c: int = (lake.heap as _MinHeap).pop()
		if (lake.cells as Dictionary).has(c):
			continue
		next_cell = c
		break
	if next_cell < 0:
		print("[UserAlg] lake landlocked at idx %d (%d cells); stopping" % [
			_user_alg_active_lake_idx, (lake.cells as Dictionary).size()])
		return true
	if _user_alg_cell_to_lake.has(next_cell) and _user_alg_cell_to_lake[next_cell] != _user_alg_active_lake_idx:
		_user_alg_merge_lakes(_user_alg_active_lake_idx, _user_alg_cell_to_lake[next_cell])
		return false
	_user_alg_lake_add_cell(_user_alg_active_lake_idx, next_cell)
	var lk = _user_alg_lakes[_user_alg_active_lake_idx]
	if (lk.max_h as float) - (lk.min_h as float) > USER_ALG_LAKE_DEPTH_TERMINATE:
		print("[UserAlg] lake %d depth %.1fm > %.1f — done (%d cells)" % [
			_user_alg_active_lake_idx,
			(lk.max_h as float) - (lk.min_h as float),
			USER_ALG_LAKE_DEPTH_TERMINATE,
			(lk.cells as Dictionary).size()])
		return true
	# Check the newly added cell's steepest descent.
	var gx: int = next_cell % GRID
	var gz: int = next_cell / GRID
	var cur_h: float = _heights[next_cell]
	var best: int = -1
	var best_score: float = 0.0
	for d in 8:
		var off: Vector2i = _FLOW_NEIGHBORS[d]
		var ngx: int = gx + off.x
		var ngz: int = gz + off.y
		if ngx < 0 or ngz < 0 or ngx >= GRID or ngz >= GRID:
			continue
		var n_idx: int = ngz * GRID + ngx
		var dist: float = sqrt(float(off.x * off.x + off.y * off.y)) * CELL
		var slope: float = (cur_h - _heights[n_idx]) / dist
		if slope > best_score:
			best_score = slope
			best = n_idx
	if best >= 0 and not (lake.cells as Dictionary).has(best):
		# Spillover.
		_user_alg_river.append(best)
		_user_alg_river_set[best] = true
		_user_alg_current = best
		_user_alg_mode = 0
		_user_alg_active_lake_idx = -1
		return false
	return false

func _user_alg_merge_lakes(into_idx: int, from_idx: int) -> void:
	var into = _user_alg_lakes[into_idx]
	var from = _user_alg_lakes[from_idx]
	for c in (from.cells as Dictionary):
		(into.cells as Dictionary)[c] = true
		_user_alg_cell_to_lake[c] = into_idx
	for c in (from.pushed as Dictionary):
		if not (into.pushed as Dictionary).has(c):
			(into.pushed as Dictionary)[c] = true
	for entry in (from.heap as _MinHeap).data:
		(into.heap as _MinHeap).push(entry[1], entry[0])
	_user_alg_lakes[from_idx] = null
	print("[UserAlg] merged lake %d into %d" % [from_idx, into_idx])

# --- User-algorithm visualization --------------------------------------------

func _update_user_alg_visual() -> void:
	if _user_alg_river_mi:
		_user_alg_river_mi.queue_free()
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES, _user_alg_color_material(Color(1.0, 0.85, 0.0)))
	var half: float = SIZE * 0.5
	for i in range(_user_alg_river.size() - 1):
		var ci: int = _user_alg_river[i]
		var ni: int = _user_alg_river[i + 1]
		var a_w := Vector3(float(ci % GRID) * CELL - half, _heights[ci] + 0.4, float(ci / GRID) * CELL - half)
		var b_w := Vector3(float(ni % GRID) * CELL - half, _heights[ni] + 0.4, float(ni / GRID) * CELL - half)
		im.surface_add_vertex(a_w)
		im.surface_add_vertex(b_w)
	im.surface_end()
	_user_alg_river_mi = MeshInstance3D.new()
	_user_alg_river_mi.mesh = im
	add_child(_user_alg_river_mi)
	# Lake cells — one flat quad per cell, slight Y lift.
	if _user_alg_lake_mi:
		_user_alg_lake_mi.queue_free()
	var lm := ImmediateMesh.new()
	lm.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _user_alg_color_material(Color(0.2, 0.6, 1.0)))
	var s: float = CELL * 0.5
	for L in _user_alg_lakes:
		if L == null:
			continue
		for c in (L.cells as Dictionary):
			var gx: int = c % GRID
			var gz: int = c / GRID
			var wx: float = float(gx) * CELL - half
			var wz: float = float(gz) * CELL - half
			var y: float = _heights[c] + 0.3
			var v00 := Vector3(wx - s, y, wz - s)
			var v10 := Vector3(wx + s, y, wz - s)
			var v01 := Vector3(wx - s, y, wz + s)
			var v11 := Vector3(wx + s, y, wz + s)
			lm.surface_add_vertex(v00); lm.surface_add_vertex(v10); lm.surface_add_vertex(v11)
			lm.surface_add_vertex(v00); lm.surface_add_vertex(v11); lm.surface_add_vertex(v01)
	lm.surface_end()
	_user_alg_lake_mi = MeshInstance3D.new()
	_user_alg_lake_mi.mesh = lm
	add_child(_user_alg_lake_mi)
	# Origin marker.
	if _user_alg_origin_mi == null:
		_user_alg_origin_mi = MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 1.0
		sm.height = 2.0
		_user_alg_origin_mi.mesh = sm
		_user_alg_origin_mi.material_override = _user_alg_color_material(Color(1.0, 0.0, 1.0))
		add_child(_user_alg_origin_mi)
	_user_alg_origin_mi.global_position = Vector3(
		_user_alg_origin_world.x,
		_sample_height(_heights, _user_alg_origin_world.x, _user_alg_origin_world.z) + 1.0,
		_user_alg_origin_world.z)

func _user_alg_color_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 2.0
	m.no_depth_test = true
	return m


# Walk the trunk and group consecutive vertices where filled height exceeds
# raw terrain height by > BASIN_MIN_DEPTH into contiguous "basin segments."
# Each segment is a natural depression the river crosses — a candidate lake.
func _report_basins_on_trunk() -> void:
	if _river_polylines.is_empty():
		return
	var trunk := _river_polylines[0] as PackedInt32Array
	var BASIN_MIN_DEPTH: float = 1.0
	var segments: Array = []   # array of {start_i, end_i, max_depth, center_world}
	var cur_start: int = -1
	var cur_max_depth: float = 0.0
	var cur_center_sum: Vector2 = Vector2.ZERO
	var cur_count: int = 0
	for i in trunk.size():
		var cell: int = trunk[i]
		var w: Vector2 = _river_cell_to_world(cell)
		var raw_h: float = _sample_height(_heights, w.x, w.y)
		var depth: float = _river_filled_h[cell] - raw_h
		var in_basin: bool = depth > BASIN_MIN_DEPTH
		if in_basin:
			if cur_start < 0:
				cur_start = i
				cur_max_depth = depth
				cur_center_sum = w
				cur_count = 1
			else:
				cur_max_depth = maxf(cur_max_depth, depth)
				cur_center_sum += w
				cur_count += 1
		elif cur_start >= 0:
			segments.append({
				"start_i": cur_start, "end_i": i - 1,
				"max_depth": cur_max_depth,
				"center": cur_center_sum / float(cur_count),
				"length": cur_count,
			})
			cur_start = -1
			cur_count = 0
	if cur_start >= 0:
		segments.append({
			"start_i": cur_start, "end_i": trunk.size() - 1,
			"max_depth": cur_max_depth,
			"center": cur_center_sum / float(cur_count),
			"length": cur_count,
		})
	if segments.is_empty():
		print("[River] no natural basins along trunk (would all need to be carved)")
		return
	print("[River] %d natural basin segment(s) along trunk:" % segments.size())
	for s in segments:
		print("   trunk[%d..%d] center=(%.0f, %.0f) max_depth=%.1f m length=%d cells" % [
			s.start_i, s.end_i, s.center.x, s.center.y, s.max_depth, s.length])

# Walk upstream from the current trunk head, following flow paths (sub-river-
# threshold cells included), until we reach a cell with no incoming flow. That
# point is a true headwater on a slope — a spring — rather than the arbitrary
# spot where accumulation crossed RIVER_ACC_THRESHOLD.
func _extend_trunk_source() -> void:
	if _river_polylines.is_empty():
		return
	var trunk := _river_polylines[0] as PackedInt32Array
	if trunk.is_empty():
		return
	var extension := PackedInt32Array()
	var cur: int = trunk[0]
	var visited_local: Dictionary = {cur: true}
	var max_iters: int = 2000
	while max_iters > 0:
		max_iters -= 1
		var cgx: int = cur % RIVER_GRID
		var cgz: int = cur / RIVER_GRID
		var best_in: int = -1
		var best_in_acc: float = 0.0
		for d in 8:
			var off: Vector2i = _FLOW_NEIGHBORS[d]
			var ngx: int = cgx + off.x
			var ngz: int = cgz + off.y
			if ngx < 0 or ngz < 0 or ngx >= RIVER_GRID or ngz >= RIVER_GRID:
				continue
			var n_idx: int = ngz * RIVER_GRID + ngx
			if visited_local.has(n_idx):
				continue
			var n_dir: int = _river_flow_dir[n_idx]
			if n_dir < 0:
				continue
			# Does this neighbor flow INTO cur?
			var n_off: Vector2i = _FLOW_NEIGHBORS[n_dir]
			if ngx + n_off.x != cgx or ngz + n_off.y != cgz:
				continue
			var n_acc: float = _river_accumulation[n_idx]
			if n_acc > best_in_acc:
				best_in_acc = n_acc
				best_in = n_idx
		if best_in < 0:
			break  # true source — no inflow
		extension.append(best_in)
		visited_local[best_in] = true
		cur = best_in
	if extension.is_empty():
		return
	extension.reverse()
	var new_trunk: PackedInt32Array = extension
	new_trunk.append_array(trunk)
	_river_polylines[0] = new_trunk
	print("[River] extended source by %d cells (now %d total)" % [
		extension.size(), new_trunk.size()])

# Convert a low-res river cell index to world XZ (the cell's center).
func _river_cell_to_world(idx: int) -> Vector2:
	var half: float = SIZE * 0.5
	var gx: int = idx % RIVER_GRID
	var gz: int = idx / RIVER_GRID
	return Vector2(float(gx) * RIVER_CELL - half, float(gz) * RIVER_CELL - half)

# For every extracted polyline, build a smoothed + resampled version with
# vertices at fixed RIVER_RESAMPLE_STEP spacing. Each vertex carries the
# filled (monotonically non-increasing) elevation so downstream consumers
# (carving, mesh, water-level) never have to deal with uphill segments.
func _smooth_and_resample_polylines() -> void:
	var t_start: int = Time.get_ticks_msec()
	_river_polylines_smoothed.clear()
	for raw_pl in _river_polylines:
		var raw := raw_pl as PackedInt32Array
		if raw.size() < 2:
			continue
		# Step 1: build a Vector3-ish list (XZ, filled-h, accumulation).
		var pts: Array = []
		for i in raw.size():
			var w: Vector2 = _river_cell_to_world(raw[i])
			pts.append({
				"wpos": w,
				"h": _river_filled_h[raw[i]],
				"acc": _river_accumulation[raw[i]],
			})
		# Step 2: box-blur smoothing on XZ only. Heights stay monotonic from
		# priority-flood, so we leave them alone.
		for _pass in RIVER_SMOOTH_PASSES:
			var copy: Array = []
			copy.resize(pts.size())
			copy[0] = pts[0]
			copy[pts.size() - 1] = pts[pts.size() - 1]
			for i in range(1, pts.size() - 1):
				var avg: Vector2 = (pts[i - 1].wpos as Vector2) * 0.25 + (pts[i].wpos as Vector2) * 0.5 + (pts[i + 1].wpos as Vector2) * 0.25
				copy[i] = {"wpos": avg, "h": pts[i].h, "acc": pts[i].acc}
			pts = copy
		# Step 3: resample at fixed step. Walks the polyline accumulating
		# distance, emits a vertex every RIVER_RESAMPLE_STEP meters.
		var out: Array = [pts[0]]
		var carry: float = 0.0
		for i in range(1, pts.size()):
			var prev = out[out.size() - 1]
			var cur = pts[i]
			var seg_d: float = (prev.wpos as Vector2).distance_to(cur.wpos)
			while carry + seg_d >= RIVER_RESAMPLE_STEP:
				var t: float = (RIVER_RESAMPLE_STEP - carry) / seg_d
				var new_w: Vector2 = (prev.wpos as Vector2).lerp(cur.wpos, t)
				var new_h: float = lerpf(prev.h, cur.h, t)
				var new_a: float = lerpf(prev.acc, cur.acc, t)
				out.append({"wpos": new_w, "h": new_h, "acc": new_a})
				carry = 0.0
				prev = out[out.size() - 1]
				seg_d = (prev.wpos as Vector2).distance_to(cur.wpos)
			carry += seg_d
		# Always include the mouth so meshes can terminate cleanly.
		if (out[out.size() - 1].wpos as Vector2).distance_to(pts[pts.size() - 1].wpos) > 0.01:
			out.append(pts[pts.size() - 1])
		_river_polylines_smoothed.append(out)
	var total_v: int = 0
	for pl in _river_polylines_smoothed:
		total_v += (pl as Array).size()
	var t_ms: int = Time.get_ticks_msec() - t_start
	print("[River] smoothed/resampled to %d polylines, %d vertices @ %.1f m, %d ms" % [
		_river_polylines_smoothed.size(), total_v, RIVER_RESAMPLE_STEP, t_ms])

# DEBUG: draw every smoothed polyline as a magenta line. Lifted 0.5 m above
# filled terrain so it's visible without poking through hills (filled heights
# never dip into depressions, so the visible line is always above ground).
func _draw_river_debug() -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	# Trunk centerline.
	for pl in _river_polylines_smoothed:
		var poly := pl as Array
		for i in range(poly.size() - 1):
			var a = poly[i]
			var b = poly[i + 1]
			im.surface_add_vertex(Vector3(a.wpos.x, a.h + 0.5, a.wpos.y))
			im.surface_add_vertex(Vector3(b.wpos.x, b.h + 0.5, b.wpos.y))
	# Source pond ring.
	if not _river_source_pond.is_empty():
		_add_debug_ring(im, _river_source_pond.center, _river_source_pond.water_y + 0.5,
			_river_source_pond.radius, 24)
	# Mouth lake boundary — draw the actual flood-fill outline by adding a
	# line segment for every lake cell that has a non-lake neighbor.
	if not _river_mouth_lake.is_empty():
		_add_lake_outline(im, _river_mouth_lake.cells as PackedInt32Array, _river_mouth_lake.water_y + 0.5)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0, 1)
	mat.emission_enabled = true
	mat.emission = Color(1, 0, 1)
	mat.emission_energy_multiplier = 4.0
	mat.no_depth_test = true   # debug — always visible
	mi.material_override = mat
	add_child(mi)

# Walk all lake cells; for each, emit short line segments on the edges that
# border a non-lake cell. The aggregate outlines the actual irregular shape.
func _add_lake_outline(im: ImmediateMesh, cells: PackedInt32Array, y: float) -> void:
	var lake_set := {}
	for c in cells:
		lake_set[c] = true
	var half: float = SIZE * 0.5
	for c in cells:
		var gx: int = c % GRID
		var gz: int = c / GRID
		var wx: float = float(gx) * CELL - half
		var wz: float = float(gz) * CELL - half
		# +x edge
		if gx + 1 >= GRID or not lake_set.has(gz * GRID + (gx + 1)):
			im.surface_add_vertex(Vector3(wx + CELL, y, wz))
			im.surface_add_vertex(Vector3(wx + CELL, y, wz + CELL))
		# -x edge
		if gx - 1 < 0 or not lake_set.has(gz * GRID + (gx - 1)):
			im.surface_add_vertex(Vector3(wx, y, wz))
			im.surface_add_vertex(Vector3(wx, y, wz + CELL))
		# +z edge
		if gz + 1 >= GRID or not lake_set.has((gz + 1) * GRID + gx):
			im.surface_add_vertex(Vector3(wx, y, wz + CELL))
			im.surface_add_vertex(Vector3(wx + CELL, y, wz + CELL))
		# -z edge
		if gz - 1 < 0 or not lake_set.has((gz - 1) * GRID + gx):
			im.surface_add_vertex(Vector3(wx, y, wz))
			im.surface_add_vertex(Vector3(wx + CELL, y, wz))

func _add_debug_ring(im: ImmediateMesh, center: Vector2, y: float, radius: float, segs: int) -> void:
	for i in segs:
		var a0: float = float(i) / float(segs) * TAU
		var a1: float = float(i + 1) / float(segs) * TAU
		var p0 := Vector3(center.x + cos(a0) * radius, y, center.y + sin(a0) * radius)
		var p1 := Vector3(center.x + cos(a1) * radius, y, center.y + sin(a1) * radius)
		im.surface_add_vertex(p0)
		im.surface_add_vertex(p1)

# --- Actual river water mesh + shader -----------------------------------------
# Builds a single ArrayMesh containing:
#   surface 0: the river — a triangle strip along the smoothed centerline, with
#              per-vertex flow tangent in COLOR.rg (encoded 0..1) and width
#              scaled by sqrt(accumulation/max_accumulation).
#   surface 1: the lake — one quad per flood-filled lake cell at the lake's
#              water_y. Lake has no flow direction (COLOR.rg = 0.5, 0.5).
# Both surfaces share a Godot 4 spatial shader adapted from Arnklit/Waterways:
# depth-based Beer-Lambert color, refraction via screen_texture, shoreline
# foam from depth_texture, edge-fade alpha so the water dissolves cleanly
# into wet ground rather than punching a hard outline.
func _build_river_water() -> void:
	print("[River] _build_river_water: trunk=%d smoothed polylines, lake=%s" % [
		_river_polylines_smoothed.size(),
		"yes" if not _river_mouth_lake.is_empty() else "no"])
	if _river_polylines_smoothed.is_empty() and _river_mouth_lake.is_empty():
		print("[River] no data; skipping water build")
		return
	_river_water_material = _build_river_water_material()
	var arr_mesh := ArrayMesh.new()
	_build_river_strip_surface(arr_mesh)
	_build_river_lake_surface(arr_mesh)
	print("[River] water mesh: %d surfaces" % arr_mesh.get_surface_count())
	if arr_mesh.get_surface_count() == 0:
		return
	_river_water_mi = MeshInstance3D.new()
	_river_water_mi.mesh = arr_mesh
	_river_water_mi.material_override = _river_water_material
	_river_water_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Loose AABB covering most of the map — the water sits across a big region
	# and we'd rather avoid frustum culling false-negatives.
	_river_water_mi.custom_aabb = AABB(Vector3(-SIZE * 0.5, -200.0, -SIZE * 0.5), Vector3(SIZE, 400.0, SIZE))
	add_child(_river_water_mi)

func _build_river_strip_surface(arr_mesh: ArrayMesh) -> void:
	if _river_polylines_smoothed.is_empty():
		return
	var poly: Array = _river_polylines_smoothed[0] as Array
	if poly.size() < 2:
		return
	var max_acc: float = 1.0
	for p in poly:
		var pa: float = p.acc as float
		if pa > max_acc:
			max_acc = pa
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for i in poly.size():
		var p = poly[i]
		var here: Vector2 = p.wpos as Vector2
		var tangent: Vector2
		if i == 0:
			tangent = ((poly[1].wpos as Vector2) - here)
		elif i == poly.size() - 1:
			tangent = (here - (poly[i - 1].wpos as Vector2))
		else:
			tangent = ((poly[i + 1].wpos as Vector2) - (poly[i - 1].wpos as Vector2))
		if tangent.length_squared() < 1e-6:
			tangent = Vector2(1, 0)
		tangent = tangent.normalized()
		var perp := Vector2(-tangent.y, tangent.x)
		var width: float = lerpf(RIVER_MIN_WIDTH, RIVER_MAX_WIDTH, sqrt((p.acc as float) / max_acc))
		var half_w: float = width * 0.5
		var left: Vector2 = here - perp * half_w
		var right: Vector2 = here + perp * half_w
		var y: float = (p.h as float) + RIVER_WATER_LIFT
		verts.append(Vector3(left.x, y, left.y))
		verts.append(Vector3(right.x, y, right.y))
		# UV: V along stream, U across (0 left, 1 right). Used by future
		# normal-map sampling; depth-based color doesn't need it.
		var v_along: float = float(i) * 0.5
		uvs.append(Vector2(0.0, v_along))
		uvs.append(Vector2(1.0, v_along))
		# COLOR.rg encodes flow tangent in XZ (mapped to 0..1).
		var flow_r: float = tangent.x * 0.5 + 0.5
		var flow_g: float = tangent.y * 0.5 + 0.5
		colors.append(Color(flow_r, flow_g, 1.0, 1.0))  # B=1 marks "river" (vs lake)
		colors.append(Color(flow_r, flow_g, 1.0, 1.0))
		if i > 0:
			var b: int = (i - 1) * 2
			indices.append_array([b, b + 1, b + 2, b + 1, b + 3, b + 2])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	arr_mesh.surface_set_name(arr_mesh.get_surface_count() - 1, "river_strip")

func _build_river_lake_surface(arr_mesh: ArrayMesh) -> void:
	if _river_mouth_lake.is_empty():
		return
	var cells: PackedInt32Array = _river_mouth_lake.cells as PackedInt32Array
	if cells.is_empty():
		return
	var water_y: float = (_river_mouth_lake.water_y as float) + RIVER_WATER_LIFT
	var half: float = SIZE * 0.5
	var s: float = CELL * 0.5
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for c in cells:
		var gx: int = c % GRID
		var gz: int = c / GRID
		var wx: float = float(gx) * CELL - half
		var wz: float = float(gz) * CELL - half
		var base: int = verts.size()
		verts.append(Vector3(wx - s, water_y, wz - s))
		verts.append(Vector3(wx + s, water_y, wz - s))
		verts.append(Vector3(wx - s, water_y, wz + s))
		verts.append(Vector3(wx + s, water_y, wz + s))
		for _i in 4:
			# Lake uses flow=(0,0) → encoded (0.5,0.5), B=0 marks "lake".
			colors.append(Color(0.5, 0.5, 0.0, 1.0))
			uvs.append(Vector2(0.0, 0.0))
		indices.append_array([base, base + 1, base + 3, base, base + 3, base + 2])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	arr_mesh.surface_set_name(arr_mesh.get_surface_count() - 1, "river_lake")

func _build_river_water_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, unshaded;

void fragment() {
	// COLOR.a is 1 only on cells where water_above_terrain > 0; discard
	// fragments whose interpolated alpha is below 0.5 so the mesh paints
	// only on actual water cells, not the dead vertices that sit on the
	// terrain to keep the grid contiguous.
	if (COLOR.a < 0.5) discard;
	// River (COLOR.b == 1) = magenta. Lake (COLOR.b == 0) = cyan.
	if (COLOR.b > 0.5) {
		ALBEDO = vec3(1.0, 0.0, 0.9);
	} else {
		ALBEDO = vec3(0.0, 0.8, 1.0);
	}
	ALPHA = 1.0;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

# Stub of the real shader, kept for when we re-enable the depth/foam/refraction
# look. For now we only use the debug material above.
func _build_river_water_material_real() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, depth_draw_always, blend_mix;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap, repeat_disable;

uniform vec3 shallow_color : source_color = vec3(0.36, 0.62, 0.55);
uniform vec3 deep_color    : source_color = vec3(0.02, 0.10, 0.13);
uniform vec4 foam_color    : source_color = vec4(0.96, 0.98, 1.00, 1.0);
uniform float depth_absorption = 5.0;   // Beer-Lambert distance for color
uniform float refraction = 0.04;
uniform float foam_distance = 0.5;
uniform float edge_fade = 0.35;
uniform float roughness_val = 0.06;
uniform float specular_val = 0.50;

void fragment() {
	// Depth of the geometry BEHIND the water at this fragment, linearised
	// to view-space Z (positive away from camera) via the projection matrix.
	float bg_depth_raw = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	float z_ndc = bg_depth_raw * 2.0 - 1.0;
	float bg_lin = -PROJECTION_MATRIX[3][2] / (z_ndc + PROJECTION_MATRIX[2][2]);
	// View-space depth of the water surface itself.
	float surf_lin = -VERTEX.z;
	// Thickness of water between camera-ray's water hit and the bed.
	float water_depth = max(0.0, bg_lin - surf_lin);

	// COLOR.b discriminates river (1) from lake (0). The river's ~8 cm
	// depth is too shallow for Beer-Lambert / depth-based foam to look
	// right — force a constant tint contribution and tight foam there.
	float is_river = step(0.5, COLOR.b);

	// Beer-Lambert color mix for lakes; constant 0.6 for river.
	float depth_t = 1.0 - exp(-water_depth / depth_absorption);
	depth_t = mix(depth_t, 0.6, is_river);

	// Refraction
	vec2 flow_xz = COLOR.rg * 2.0 - 1.0;
	vec2 refr_uv = SCREEN_UV + flow_xz * refraction * (1.0 - depth_t);
	refr_uv = clamp(refr_uv, vec2(0.001), vec2(0.999));
	vec3 behind = textureLod(screen_texture, refr_uv, 0.0).rgb;

	vec3 col = mix(shallow_color, deep_color, depth_t);
	col = mix(behind, col, depth_t);

	// Foam: lakes can foam where bed approaches surface; rivers only at the
	// very edge so the shallow centre doesn't go solid white.
	float foam_d_local = mix(foam_distance, 0.04, is_river);
	float foam_mask = smoothstep(foam_d_local, 0.0, water_depth);
	col = mix(col, foam_color.rgb, foam_mask * foam_color.a);

	ALBEDO = col;
	ROUGHNESS = roughness_val;
	SPECULAR = specular_val;
	METALLIC = 0.0;
	// Alpha — for the river (is_river already computed above), use the
	// shallow-water floor of 0.55 so it stays visible. Lakes use pure
	// depth-based fade so the bed slope alpha-ramps to zero at the shore.
	float a = clamp(water_depth / edge_fade, 0.0, 1.0);
	ALPHA = mix(a, max(a, 0.55), is_river);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

# Called once the user-algorithm finishes. Removes the debug yellow lines,
# cyan lake quads, and pink origin marker, then builds the actual water
# meshes from _user_alg_river (strip) and _user_alg_lakes (one quad per cell
# at that lake's max_h water level).
const RIVER_STRIP_WIDTH: float = 10.0
const LAKE_PLANE_MARGIN: float = 6.0
# How deep we carve the river centerline below the original terrain so the
# water surface (left at original level) gets real visible depth. Direct
# neighbours of each centerline cell carve a softer half-depth so the
# channel reads as a U-shape rather than a stepped trench.
const RIVER_CARVE_DEPTH: float = 0.35
# --- Baked water simulation ----------------------------------------------
# A particle-descent water sim (Nick McDonald / SimpleHydrology style) runs
# once on the dev machine, dumps two full-res Float32 arrays — discharge
# (per-cell volume that flowed through) and pool depth (per-cell water
# height above terrain in detected lakes) — to res://baked/water.bin.
# Subsequent launches load that file and skip the sim entirely.
const WATER_BAKE_PATH := "res://baked/water.bin"
const WATER_BAKE_VERSION := 3   # v3: SUB=4 (0.25m sim grid), longer particle age
# Particle sim tuning. More particles + larger per-particle volume gives
# fuller lakes (each particle can raise a basin by more before it runs out
# and dies). flood_max_pops is the per-stagnation safety cap on the local
# priority-flood; the largest natural basin is ~2k cells but the flood can
# explore much more terrain before locating its spillover.
const WSIM_PARTICLE_COUNT: int = 20000
# Step size in the particle sim is half a sim cell (= 0.5 / SUB metres). To
# traverse the full ~1.5 km river at SUB=4 (0.125 m per step) a particle
# needs ~12 k steps; safety = MAX_AGE × 4 gives the headroom.
const WSIM_MAX_AGE: int = 4000
const WSIM_GRAVITY: float = 1.4
const WSIM_DAMP: float = 0.85
const WSIM_EVAP_RATE: float = 0.0015
const WSIM_MIN_VOLUME: float = 0.01
const WSIM_PARTICLE_VOLUME: float = 3.0   # initial volume each particle carries
# Sim grid is finer than the heightmap. At SUB=4 the sim runs on 0.25 m
# cells (4097² for GRID=1025), so the discharge/pool fields have quarter-
# meter resolution. Heights for the sim are bilinear-interpolated from the
# heightmap.
const WATER_SIM_SUBDIV: int = 4
var _wsim_grid: int = 0                  # runtime: (GRID-1)*SUB + 1
var _wsim_cell: float = 0.0              # runtime: CELL / SUB
var _wsim_heights: PackedFloat32Array    # heights resampled to sim grid
var _wsim_discharge: PackedFloat32Array
var _wsim_pool_depth: PackedFloat32Array
var _wsim_baked: bool = false
# Lakes with fewer than this many cells are treated as bumps in the river
# rather than real lakes — they don't get rendered as lakes AND the river
# strip extends THROUGH them (instead of breaking at their cells).
const MIN_LAKE_CELLS_FOR_RENDER: int = 10
# Saved original heights at river cells. Water surface mesh uses these (the
# carve happens AFTER the mesh is built so the mesh stays at ground-level).
var _river_cell_surface_h: Dictionary = {}     # cell idx -> original h
# Cells claimed by lakes BIG ENOUGH to render. River strip breaks at these
# cells; smaller lakes get skipped and the river flows through.
var _user_alg_big_lake_cells: Dictionary = {}

# --- Baked heightmap -----------------------------------------------------

const HEIGHTS_BAKE_PATH := "res://baked/heights.bin"
# Bumped when the on-disk format changes incompatibly so stale caches are
# rejected rather than silently producing a broken terrain.
const HEIGHTS_BAKE_VERSION: int = 1

# Returns true if the post-carve heightmap was loaded from cache (fast path),
# false if it had to be regenerated. Pass --bake-heights to force regen.
func _ensure_heights_bake() -> bool:
	var force: bool = OS.get_cmdline_args().has("--bake-heights")
	if not force and FileAccess.file_exists(HEIGHTS_BAKE_PATH):
		if _load_heights_bake():
			return true
		push_warning("[Heights] cache load failed; regenerating")
	_heights = _generate_heights()
	if flatten_origin:
		var center_h: float = _heights[(GRID / 2) * GRID + (GRID / 2)]
		for i in _heights.size():
			_heights[i] -= center_h
	for i in _heights.size():
		if _heights[i] < 0.0:
			_heights[i] *= 0.5
	_init_stream_noise()
	_carve_stream(_heights)
	_save_heights_bake()
	return false

# Cache layout (little-endian):
#   u32 version
#   u32 grid (must equal GRID)
#   i32 noise_seed (sanity check — mismatched seed implies stale cache)
#   u8  flatten_origin (0 / 1)
#   pad to 16 bytes
#   GRID*GRID float32s — post-flatten, post-valley-halve, post-carve heights
func _load_heights_bake() -> bool:
	var f := FileAccess.open(HEIGHTS_BAKE_PATH, FileAccess.READ)
	if f == null:
		return false
	var ver: int = f.get_32()
	var grid: int = f.get_32()
	var seed: int = f.get_32()
	var flat: int = f.get_8()
	# Skip padding to 16-byte header.
	f.get_8(); f.get_8(); f.get_8()
	if ver != HEIGHTS_BAKE_VERSION or grid != GRID or seed != noise_seed or flat != int(flatten_origin):
		f.close()
		push_warning("[Heights] cache header mismatch (ver=%d grid=%d seed=%d flat=%d); rebake with --bake-heights" % [ver, grid, seed, flat])
		return false
	var n_bytes: int = GRID * GRID * 4
	var data := f.get_buffer(n_bytes)
	f.close()
	if data.size() != n_bytes:
		push_warning("[Heights] cache short read (got %d, want %d)" % [data.size(), n_bytes])
		return false
	_heights = data.to_float32_array()
	# Stream noise still has to be initialised — _carve_stream isn't being
	# re-run but downstream code (e.g. _heights_at, lake placement) uses the
	# same noise field.
	_init_stream_noise()
	print("[Heights] loaded cache from %s" % HEIGHTS_BAKE_PATH)
	return true

func _save_heights_bake() -> void:
	var dir := DirAccess.open("res://")
	if dir != null and not dir.dir_exists("baked"):
		dir.make_dir("baked")
	var f := FileAccess.open(HEIGHTS_BAKE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[Heights] failed to open %s for write" % HEIGHTS_BAKE_PATH)
		return
	f.store_32(HEIGHTS_BAKE_VERSION)
	f.store_32(GRID)
	f.store_32(noise_seed)
	f.store_8(int(flatten_origin))
	# Padding to 16-byte header.
	f.store_8(0); f.store_8(0); f.store_8(0)
	f.store_buffer(_heights.to_byte_array())
	f.close()
	print("[Heights] saved cache to %s (%d floats)" % [HEIGHTS_BAKE_PATH, _heights.size()])

# --- Baked water sim implementation --------------------------------------

# At startup: if res://baked/water.bin exists, load. Otherwise, run the sim
# synchronously (slow, ~10–30 s on first launch) and save the result.
func _ensure_water_bake() -> void:
	if FileAccess.file_exists(WATER_BAKE_PATH):
		if _load_water_bake():
			_wsim_baked = true
			print("[Bake] loaded water sim from %s" % WATER_BAKE_PATH)
			return
		push_warning("[Bake] failed to load %s" % WATER_BAKE_PATH)
	# No valid bake. Running the sim costs minutes — only do it when explicitly
	# asked via the --bake-water CLI flag. Otherwise just leave water off so
	# casual game launches stay fast.
	if not OS.get_cmdline_args().has("--bake-water"):
		push_warning("[Bake] no bake found and --bake-water not passed; skipping sim. Water will not render. Run `godot --path . -- --bake-water` to bake.")
		return
	print("[Bake] water bake missing — running sim (--bake-water set)...")
	var t0: int = Time.get_ticks_msec()
	_run_water_sim()
	_save_water_bake()
	_wsim_baked = true
	print("[Bake] done in %d ms, saved to %s" % [Time.get_ticks_msec() - t0, WATER_BAKE_PATH])

# Runs the full simulation. Drives the user-algorithm synchronously first to
# get source + sink-lake cells, then spawns WSIM_PARTICLE_COUNT particles at
# the source and lets them descend on the full-res _heights, terminating
# when they enter the sink lake / leave the map / age out / dry up.
func _run_water_sim() -> void:
	# 1) User-algorithm synchronously, no animation, just to identify
	# source + lake cells. Suppress its debug viz creation.
	_start_user_alg_at(USER_ALG_AUTOSTART.x, USER_ALG_AUTOSTART.y)
	var safety: int = 200000
	while not _user_alg_done and safety > 0:
		_user_alg_done = _user_alg_step()
		safety -= 1
	# Tear down any debug MIs the algorithm created — they're not part of
	# the bake output.
	if _user_alg_river_mi:
		_user_alg_river_mi.queue_free(); _user_alg_river_mi = null
	if _user_alg_lake_mi:
		_user_alg_lake_mi.queue_free(); _user_alg_lake_mi = null
	if _user_alg_origin_mi:
		_user_alg_origin_mi.queue_free(); _user_alg_origin_mi = null
	# 2) Build source + sink-cell set.
	var source_idx: int = -1
	if not _user_alg_river.is_empty():
		source_idx = _user_alg_river[0]
	if source_idx < 0:
		push_warning("[Bake] user_alg gave no river — can't bake")
		return
	var sink_cells := {}
	if not _user_alg_river.is_empty():
		var last_river_cell: int = _user_alg_river[_user_alg_river.size() - 1]
		if _user_alg_cell_to_lake.has(last_river_cell):
			var lake_idx: int = _user_alg_cell_to_lake[last_river_cell]
			if lake_idx < _user_alg_lakes.size():
				var L = _user_alg_lakes[lake_idx]
				if L != null:
					for c in (L.cells as Dictionary):
						sink_cells[c] = true
	# 3) Build the finer sim grid: heights, allocate output arrays.
	_wsim_grid = (GRID - 1) * WATER_SIM_SUBDIV + 1
	_wsim_cell = CELL / float(WATER_SIM_SUBDIV)
	_wsim_build_heights()
	var SG: int = _wsim_grid
	var N: int = SG * SG
	_wsim_discharge = PackedFloat32Array()
	_wsim_discharge.resize(N)
	_wsim_pool_depth = PackedFloat32Array()
	_wsim_pool_depth.resize(N)
	# Convert source + sinks from GRID coords to sim-grid coords. Each
	# heightmap cell maps to SUB² sim cells; we anchor sources at the
	# top-left sub-cell, and stamp all SUB² sub-cells as sinks.
	var src_gx_h: int = source_idx % GRID
	var src_gz_h: int = source_idx / GRID
	var src_sx: int = src_gx_h * WATER_SIM_SUBDIV
	var src_sz: int = src_gz_h * WATER_SIM_SUBDIV
	var sim_sink_cells: Dictionary = {}
	for c in sink_cells:
		var hgx: int = c % GRID
		var hgz: int = c / GRID
		for sz in WATER_SIM_SUBDIV:
			for sx in WATER_SIM_SUBDIV:
				var sx_idx: int = (hgz * WATER_SIM_SUBDIV + sz) * SG + (hgx * WATER_SIM_SUBDIV + sx)
				sim_sink_cells[sx_idx] = true
	# 4) Particle sim: spawn at source, descend on _wsim_heights. When a
	# particle stagnates, _wsim_local_flood raises the local water level
	# until the particle's remaining volume is consumed OR a spillover is
	# found. Discharge accumulates along descent; pool_depth accumulates in
	# basins. Sinks (terminal lake cells) absorb particles immediately.
	print("[Bake] sim source=(%d,%d) on %d² grid, %d sink cells, %d particles…" % [
		src_sx, src_sz, SG, sim_sink_cells.size(), WSIM_PARTICLE_COUNT])
	var t_sim: int = Time.get_ticks_msec()
	for p in WSIM_PARTICLE_COUNT:
		if (p % 1000) == 0:
			print("[Bake]   particle %d / %d  (%d ms)" % [p, WSIM_PARTICLE_COUNT, Time.get_ticks_msec() - t_sim])
		_wsim_simulate_one_particle(src_sx, src_sz, sim_sink_cells)
	# Stats so we know the sim worked.
	var max_d: float = 0.0
	var nonzero_d: int = 0
	var max_p: float = 0.0
	var nonzero_p: int = 0
	for i in N:
		if _wsim_discharge[i] > max_d: max_d = _wsim_discharge[i]
		if _wsim_discharge[i] > 0.0: nonzero_d += 1
		if _wsim_pool_depth[i] > max_p: max_p = _wsim_pool_depth[i]
		if _wsim_pool_depth[i] > 0.05: nonzero_p += 1
	print("[Bake] sim_grid=%d  discharge cells=%d max=%.2f  pool cells=%d max_depth=%.2f m" % [
		_wsim_grid, nonzero_d, max_d, nonzero_p, max_p])

# Bilinear-resample _heights (GRID×GRID at 1 m) to _wsim_heights
# (_wsim_grid² at _wsim_cell metres). This is what the particle sim and the
# local flood walk on.
func _wsim_build_heights() -> void:
	var SG: int = _wsim_grid
	_wsim_heights = PackedFloat32Array()
	_wsim_heights.resize(SG * SG)
	var SUB: int = WATER_SIM_SUBDIV
	var inv_sub: float = 1.0 / float(SUB)
	for sz in SG:
		for sx in SG:
			var fx: float = float(sx) * inv_sub
			var fz: float = float(sz) * inv_sub
			var gx0: int = int(fx)
			var gz0: int = int(fz)
			var gx1: int = mini(gx0 + 1, GRID - 1)
			var gz1: int = mini(gz0 + 1, GRID - 1)
			var tx: float = fx - float(gx0)
			var tz: float = fz - float(gz0)
			var h00: float = _heights[gz0 * GRID + gx0]
			var h10: float = _heights[gz0 * GRID + gx1]
			var h01: float = _heights[gz1 * GRID + gx0]
			var h11: float = _heights[gz1 * GRID + gx1]
			_wsim_heights[sz * SG + sx] = lerp(lerp(h00, h10, tx), lerp(h01, h11, tx), tz)

# One particle: spawn at (start_gx, start_gz), descend on the heightmap with
# gravity-along-gradient + damping + evaporation. When it stagnates inside a
# basin, run a LOCAL priority-flood from that cell to either (a) consume the
# particle's remaining volume by raising the basin's water level, or (b)
# discover a spillover and teleport the particle to the drain cell to
# continue descent. This is the Nick-McDonald-style flood-on-stagnation; it
# ensures lakes form only where particles actually pool, not at every
# noise-induced depression in the heightmap.
const WSIM_STAGNANT_SPEED: float = 0.05
const WSIM_FLOOD_MAX_POPS: int = 2000000   # safety cap on the per-stagnation flood

func _wsim_simulate_one_particle(start_gx: int, start_gz: int, sink_cells: Dictionary) -> void:
	var SG: int = _wsim_grid
	var pos := Vector2(float(start_gx) + 0.5, float(start_gz) + 0.5)
	var speed := Vector2.ZERO
	var volume: float = WSIM_PARTICLE_VOLUME
	var safety: int = WSIM_MAX_AGE * 4
	# Heightmap gradient is computed in WORLD units; on a finer grid we
	# divide by _wsim_cell so the gradient magnitude (m of rise per m of
	# horizontal distance) stays scale-invariant.
	var inv_2cell: float = 0.5 / _wsim_cell
	while volume >= WSIM_MIN_VOLUME and safety > 0:
		safety -= 1
		var gx: int = int(pos.x)
		var gz: int = int(pos.y)
		if gx < 1 or gz < 1 or gx >= SG - 1 or gz >= SG - 1:
			return
		var cell_idx: int = gz * SG + gx
		_wsim_discharge[cell_idx] += volume
		if sink_cells.has(cell_idx):
			return
		var h_l: float = _wsim_heights[cell_idx - 1]
		var h_r: float = _wsim_heights[cell_idx + 1]
		var h_u: float = _wsim_heights[cell_idx - SG]
		var h_d: float = _wsim_heights[cell_idx + SG]
		var grad := Vector2((h_r - h_l) * inv_2cell, (h_d - h_u) * inv_2cell)
		speed += -grad * WSIM_GRAVITY / maxf(volume, 0.05)
		speed *= WSIM_DAMP
		var s_len: float = speed.length()
		if s_len < WSIM_STAGNANT_SPEED:
			# Stagnant — run local flood from the current cell.
			var result := _wsim_local_flood(cell_idx, volume)
			if not result.get("spilled", false):
				return
			var drain: int = result["drain_cell"]
			pos = Vector2(float(drain % SG) + 0.5, float(drain / SG) + 0.5)
			speed = Vector2.ZERO
			volume = result["remaining_volume"]
			continue
		# Step in sim-cell units (a half cell per iter) so particles deposit
		# discharge on every sim cell they cross.
		pos += speed.normalized() * 0.5
		volume *= (1.0 - WSIM_EVAP_RATE)

# Local priority-flood from a stagnated particle. Pops cells in height order;
# as the popped height rises above the current water_level, particle volume
# is consumed at a rate of (cell_count) m³ per m of level rise (because each
# of those basin cells gains 1 m of water). Returns:
#   { spilled: bool, drain_cell: int, remaining_volume: float }
# spilled=true means we found a lower outside neighbour; the particle should
# teleport to drain_cell and continue with remaining_volume.
func _wsim_local_flood(seed: int, particle_volume: float) -> Dictionary:
	var SG: int = _wsim_grid
	var heap := _MinHeap.new()
	heap.push(seed, _wsim_heights[seed])
	var visited: Dictionary = {seed: true}
	var basin: PackedInt32Array = PackedInt32Array([seed])
	var water_level: float = _wsim_heights[seed]
	var remaining: float = particle_volume
	var pops: int = 0
	while not heap.is_empty() and pops < WSIM_FLOOD_MAX_POPS:
		pops += 1
		var c: int = heap.pop()
		var h_c: float = _wsim_heights[c]
		# Rising water past this cell costs volume proportional to the basin
		# area times the rise. Stop if the particle can't afford it.
		if h_c > water_level:
			var rise: float = h_c - water_level
			var cost: float = rise * float(basin.size())
			if remaining < cost:
				# Out of volume mid-rise; raise level by whatever volume can
				# fund, deposit, and end the particle. (Death = pool persists)
				var partial: float = remaining / float(basin.size())
				water_level += partial
				_wsim_deposit_basin(basin, water_level)
				return {"spilled": false, "drain_cell": -1, "remaining_volume": 0.0}
			remaining -= cost
			water_level = h_c
		# Look at c's neighbours for a spillover or to enqueue.
		var cgx: int = c % SG
		var cgz: int = c / SG
		for d in 8:
			var off: Vector2i = _FLOW_NEIGHBORS[d]
			var ngx: int = cgx + off.x
			var ngz: int = cgz + off.y
			if ngx < 0 or ngz < 0 or ngx >= SG or ngz >= SG:
				continue
			var n_idx: int = ngz * SG + ngx
			if visited.has(n_idx):
				continue
			var h_n: float = _wsim_heights[n_idx]
			if h_n < h_c:
				# Lower outside neighbour — water spills here. NO deposit on
				# spillover: the water flowed through, it didn't pool.
				return {"spilled": true, "drain_cell": n_idx, "remaining_volume": remaining}
			visited[n_idx] = true
			basin.append(n_idx)
			heap.push(n_idx, h_n)
	# Heap exhausted or pop cap — deposit what we have and finish.
	_wsim_deposit_basin(basin, water_level)
	return {"spilled": false, "drain_cell": -1, "remaining_volume": 0.0}

func _wsim_deposit_basin(basin: PackedInt32Array, water_level: float) -> void:
	for c in basin:
		var d: float = water_level - _wsim_heights[c]
		if d > _wsim_pool_depth[c]:
			_wsim_pool_depth[c] = d

func _save_water_bake() -> void:
	DirAccess.make_dir_recursive_absolute(WATER_BAKE_PATH.get_base_dir())
	var f := FileAccess.open(WATER_BAKE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[Bake] can't open %s for write — bake NOT saved" % WATER_BAKE_PATH)
		return
	f.store_32(WATER_BAKE_VERSION)
	f.store_32(GRID)
	f.store_32(_wsim_grid)
	f.store_buffer(_wsim_discharge.to_byte_array())
	f.store_buffer(_wsim_pool_depth.to_byte_array())
	f.close()

func _load_water_bake() -> bool:
	var f := FileAccess.open(WATER_BAKE_PATH, FileAccess.READ)
	if f == null:
		return false
	var version: int = f.get_32()
	var grid: int = f.get_32()
	var sg: int = f.get_32()
	var expected_sg: int = (GRID - 1) * WATER_SIM_SUBDIV + 1
	if version != WATER_BAKE_VERSION or grid != GRID or sg != expected_sg:
		f.close()
		return false
	var n: int = sg * sg
	var bytes_per_arr: int = n * 4
	var d_bytes := f.get_buffer(bytes_per_arr)
	var p_bytes := f.get_buffer(bytes_per_arr)
	f.close()
	if d_bytes.size() != bytes_per_arr or p_bytes.size() != bytes_per_arr:
		return false
	_wsim_grid = sg
	_wsim_cell = CELL / float(WATER_SIM_SUBDIV)
	_wsim_build_heights()
	_wsim_discharge = d_bytes.to_float32_array()
	_wsim_pool_depth = p_bytes.to_float32_array()
	return true

# Thresholds applied to the baked arrays when generating the visible mesh
# and the grass-cull mask. Pool depths from priority flood include tons of
# noise sub-meter "depressions" we don't want to render.
const WATER_POOL_MIN_DEPTH: float = 0.05      # any non-trivial depth from a real lake renders
const WATER_STREAM_MIN_DISCHARGE: float = 1.0 # cells with at least this much flow are stream
const WATER_STREAM_DEPTH: float = 0.45        # visible water thickness over a stream cell
# Only render user-algorithm lakes with at least this many cells. The
# algorithm already filters by depth (>5 m to commit) so this just kills
# tiny bridged intermediate basins.
const REAL_LAKE_MIN_CELLS: int = 100

# Build the visible water as a single full-res (1025²) grid mesh with
# vertex y = terrain + max(stream_thickness, pool_depth). The water shader's
# depth-alpha hides cells where water ≈ terrain so the visible silhouette
# emerges naturally from the bake without any per-cell quad work.
func _build_baked_water() -> void:
	if _wsim_discharge.is_empty() or _wsim_pool_depth.is_empty():
		return
	if _river_water_material == null:
		_river_water_material = _build_river_water_material()
	# Mesh resolution = sim grid. Vertex spacing = _wsim_cell metres.
	# Build sparse: only allocate vertices the triangle list actually
	# references. The previous dense build emitted SG×SG verts (4097² ≈ 17 M)
	# even when ~3.6 k triangles covered the wet area — that vertex upload
	# was the bulk of the startup wait.
	var SG: int = _wsim_grid
	var n_cells: int = SG * SG
	var half: float = SIZE * 0.5
	var inv_sg: float = 1.0 / float(SG - 1)
	# Pass 1: wet[] flag per cell.
	var wet := PackedByteArray()
	wet.resize(n_cells)
	for idx in n_cells:
		var pool: float = _wsim_pool_depth[idx]
		if pool < WATER_POOL_MIN_DEPTH:
			pool = 0.0
		var disch: float = _wsim_discharge[idx]
		var stream: float = WATER_STREAM_DEPTH if disch > WATER_STREAM_MIN_DISCHARGE else 0.0
		wet[idx] = 1 if maxf(pool, stream) > 0.01 else 0
	# Pass 2: dilate wet by 1 cell so the "any of 4 corners has a wet neighbour"
	# quad-emit test becomes a single O(1) array lookup per corner instead of
	# a 4×4 inner loop.
	var dilated := PackedByteArray()
	dilated.resize(n_cells)
	for sz in SG:
		var row_base: int = sz * SG
		for sx in SG:
			var idx: int = row_base + sx
			if wet[idx] != 0:
				dilated[idx] = 1
				continue
			var any_wet: bool = false
			for dz in [-1, 0, 1]:
				if any_wet:
					break
				var zz: int = sz + dz
				if zz < 0 or zz >= SG:
					continue
				for dx in [-1, 0, 1]:
					if dz == 0 and dx == 0:
						continue
					var xx: int = sx + dx
					if xx < 0 or xx >= SG:
						continue
					if wet[zz * SG + xx] != 0:
						any_wet = true
						break
			dilated[idx] = 1 if any_wet else 0
	# Pass 3: emit quads where any of their 4 corners' dilated mask is set,
	# allocating vertices on first reference via a sparse index map.
	var vert_index := PackedInt32Array()
	vert_index.resize(n_cells)
	for i in n_cells:
		vert_index[i] = -1
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for sz in SG - 1:
		var row_base_a: int = sz * SG
		var row_base_b: int = row_base_a + SG
		for sx in SG - 1:
			var c00: int = row_base_a + sx
			var c10: int = c00 + 1
			var c01: int = row_base_b + sx
			var c11: int = c01 + 1
			if dilated[c00] == 0 and dilated[c10] == 0 and dilated[c01] == 0 and dilated[c11] == 0:
				continue
			var v00: int = _emit_water_vert(c00, sx, sz, SG, half, inv_sg, vert_index, verts, uvs, colors)
			var v10: int = _emit_water_vert(c10, sx + 1, sz, SG, half, inv_sg, vert_index, verts, uvs, colors)
			var v01: int = _emit_water_vert(c01, sx, sz + 1, SG, half, inv_sg, vert_index, verts, uvs, colors)
			var v11: int = _emit_water_vert(c11, sx + 1, sz + 1, SG, half, inv_sg, vert_index, verts, uvs, colors)
			indices.append_array([v00, v01, v10, v01, v11, v10])
	var arr_mesh := ArrayMesh.new()
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if _river_water_mi:
		_river_water_mi.queue_free()
	_river_water_mi = MeshInstance3D.new()
	_river_water_mi.mesh = arr_mesh
	_river_water_mi.material_override = _river_water_material
	_river_water_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_river_water_mi.custom_aabb = AABB(Vector3(-half, -200.0, -half), Vector3(SIZE, 400.0, SIZE))
	add_child(_river_water_mi)
	print("[Water] baked-water mesh: %d verts, %d tris" % [verts.size(), indices.size() / 3])

# Helper: returns the sparse vertex index for sim cell `idx`, allocating + filling
# the vertex/uv/color arrays on first reference. -1 sentinel in vert_index means
# "not yet emitted." See _build_baked_water for context.
func _emit_water_vert(idx: int, sx: int, sz: int, SG: int, half: float, inv_sg: float,
	vert_index: PackedInt32Array, verts: PackedVector3Array,
	uvs: PackedVector2Array, colors: PackedColorArray) -> int:
	var existing: int = vert_index[idx]
	if existing >= 0:
		return existing
	var pool: float = _wsim_pool_depth[idx]
	if pool < WATER_POOL_MIN_DEPTH:
		pool = 0.0
	var disch: float = _wsim_discharge[idx]
	var stream: float = WATER_STREAM_DEPTH if disch > WATER_STREAM_MIN_DISCHARGE else 0.0
	var water_above: float = maxf(pool, stream)
	var h: float = _wsim_heights[idx]
	var wx: float = float(sx) * _wsim_cell - half
	var wz: float = float(sz) * _wsim_cell - half
	var v_idx: int = verts.size()
	verts.append(Vector3(wx, h + water_above, wz))
	uvs.append(Vector2(float(sx) * inv_sg, float(sz) * inv_sg))
	var is_river_cell: bool = stream > 0.0 and pool <= 0.1
	var a: float = 1.0 if water_above > 0.01 else 0.0
	colors.append(Color(0.5, 0.5, 1.0 if is_river_cell else 0.0, a))
	vert_index[idx] = v_idx
	return v_idx

# Build the grass cull mask from baked data (replaces the user-algorithm-
# based version). Cells that are river OR lake (same thresholds as the mesh)
# get marked; grass shaders sample bilinearly + smoothstep so the boundary
# anti-aliases.
func _build_water_grass_cull_mask_from_bake() -> void:
	if _wsim_discharge.is_empty():
		return
	# Mask is at heightmap resolution; mark any GRID cell whose corresponding
	# SUB² sim sub-cells contain water.
	var SG: int = _wsim_grid
	var SUB: int = WATER_SIM_SUBDIV
	var img := Image.create(GRID, GRID, false, Image.FORMAT_R8)
	img.fill(Color(0, 0, 0))
	for gz in GRID:
		for gx in GRID:
			var hit: bool = false
			var sz0: int = mini(gz * SUB, SG - 1)
			var sx0: int = mini(gx * SUB, SG - 1)
			for dz in SUB:
				if hit:
					break
				for dx in SUB:
					var s_idx: int = mini(sz0 + dz, SG - 1) * SG + mini(sx0 + dx, SG - 1)
					if _wsim_pool_depth[s_idx] >= WATER_POOL_MIN_DEPTH \
							or _wsim_discharge[s_idx] >= WATER_STREAM_MIN_DISCHARGE:
						hit = true
						break
			if hit:
				img.set_pixel(gx, gz, Color(1, 0, 0))
	var tex := ImageTexture.create_from_image(img)
	var mats: Array = [
		_grass_material_short, _grass_material_tall,
		_grass_material_patch_short, _grass_material_patch_tall,
		_grass_material_patch_core, _grass_material_patch_super_core,
		_ground_material,
	]
	for mat in mats:
		if mat != null:
			mat.set_shader_parameter("water_mask_tex", tex)
			mat.set_shader_parameter("water_mask_active", 1.0)
			mat.set_shader_parameter("terrain_size_tile", SIZE)
			mat.set_shader_parameter("terrain_size_ground", SIZE)

func _finalize_user_alg_water() -> void:
	# Tear down the algorithm's debug visualization.
	if _user_alg_river_mi:
		_user_alg_river_mi.queue_free()
		_user_alg_river_mi = null
	if _user_alg_lake_mi:
		_user_alg_lake_mi.queue_free()
		_user_alg_lake_mi = null
	if _user_alg_origin_mi:
		_user_alg_origin_mi.queue_free()
		_user_alg_origin_mi = null
	# Build real water from the algorithm output.
	if _river_water_material == null:
		_river_water_material = _build_river_water_material()
	# Pre-collect cells claimed by RENDERABLE lakes (>= MIN cells). Tiny
	# lakes are ignored so the river flows through them.
	_user_alg_big_lake_cells = {}
	for L in _user_alg_lakes:
		if L == null:
			continue
		var cd: Dictionary = L.cells as Dictionary
		if cd.size() < MIN_LAKE_CELLS_FOR_RENDER:
			continue
		for c in cd:
			_user_alg_big_lake_cells[c] = true
	var arr_mesh := ArrayMesh.new()
	_build_user_alg_river_strip(arr_mesh)
	_build_user_alg_lakes_surface(arr_mesh)
	if arr_mesh.get_surface_count() == 0:
		return
	if _river_water_mi:
		_river_water_mi.queue_free()
	_river_water_mi = MeshInstance3D.new()
	_river_water_mi.mesh = arr_mesh
	_river_water_mi.material_override = _river_water_material
	_river_water_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_river_water_mi.custom_aabb = AABB(Vector3(-SIZE * 0.5, -200.0, -SIZE * 0.5), Vector3(SIZE, 400.0, SIZE))
	add_child(_river_water_mi)
	print("[Water] built from user_alg: river %d cells, lakes %d cells" % [
		_user_alg_river.size(), _user_alg_total_lake_cells()])
	_build_water_grass_cull_mask()
	_carve_river_channel_into_heights()

# Lower _heights along the river so the water surface (already built at
# pre-carve heights in the mesh) gets a real visible depth. Centerline cells
# get the full RIVER_CARVE_DEPTH; their 8 neighbours get half. Then we
# rebuild the bits that bake heightmap state — collision, height texture,
# and the existing chunk meshes (cleared so the streamer recreates them).
func _carve_river_channel_into_heights() -> void:
	if _user_alg_river.is_empty():
		return
	# 1) full-depth carve at centerline cells.
	for c in _user_alg_river:
		_heights[c] = _heights[c] - RIVER_CARVE_DEPTH
	# 2) half-depth carve at 8-neighbours (skip cells already carved at
	#    full depth — we don't double-stamp).
	var carved: Dictionary = {}
	for c in _user_alg_river:
		carved[c] = true
	for c in _user_alg_river:
		var gx: int = c % GRID
		var gz: int = c / GRID
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var nx: int = gx + dx
				var nz: int = gz + dz
				if nx < 0 or nz < 0 or nx >= GRID or nz >= GRID:
					continue
				var n_idx: int = nz * GRID + nx
				if carved.has(n_idx):
					continue
				_heights[n_idx] = _heights[n_idx] - RIVER_CARVE_DEPTH * 0.5
				carved[n_idx] = true
	# Rebuild the cached state derived from _heights.
	_attach_collision(_heights)
	_build_height_texture()
	# Force visible chunks to rebuild. _chunk_tiles maps key→MeshInstance3D;
	# queue_free + clear, and _stream_chunks rebuilds the visible ones next
	# frame using the carved heights.
	for key in _chunk_tiles.keys():
		var mi: MeshInstance3D = _chunk_tiles[key]
		if is_instance_valid(mi):
			mi.queue_free()
	_chunk_tiles.clear()
	_last_chunk_stream_pos = Vector3.INF  # forces _stream_chunks to re-survey
	print("[Water] carved river channel: %d full + %d half-depth cells" % [
		_user_alg_river.size(), carved.size() - _user_alg_river.size()])

# Bake a GRID×GRID R8 mask marking every cell within 1 m of a river or lake
# cell. The grass shaders sample this at the blade's world position and
# discard inside the mask. 3×3 stamp per cell so "within 1 m" includes
# orthogonal neighbours; diagonals are also covered.
func _build_water_grass_cull_mask() -> void:
	var img := Image.create(GRID, GRID, false, Image.FORMAT_R8)
	img.fill(Color(0, 0, 0))
	var stamp := func(c: int) -> void:
		var gx: int = c % GRID
		var gz: int = c / GRID
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var nx: int = gx + dx
				var ny: int = gz + dz
				if nx >= 0 and ny >= 0 and nx < GRID and ny < GRID:
					img.set_pixel(nx, ny, Color(1, 0, 0))
	for c in _user_alg_river:
		stamp.call(c)
	for L in _user_alg_lakes:
		if L == null:
			continue
		for c in (L.cells as Dictionary):
			stamp.call(c)
	var tex := ImageTexture.create_from_image(img)
	var mats: Array = [
		_grass_material_short, _grass_material_tall,
		_grass_material_patch_short, _grass_material_patch_tall,
		_grass_material_patch_core, _grass_material_patch_super_core,
		_ground_material,
	]
	for mat in mats:
		if mat != null:
			mat.set_shader_parameter("water_mask_tex", tex)
			mat.set_shader_parameter("water_mask_active", 1.0)
			# Each shader has its own world-size uniform name (distinct
			# names avoid collisions across shaders that share a material
			# pool). Extra params on the wrong shader are harmless.
			mat.set_shader_parameter("terrain_size_tile", SIZE)
			mat.set_shader_parameter("terrain_size_ground", SIZE)

func _build_user_alg_river_strip(arr_mesh: ArrayMesh) -> void:
	var cells: PackedInt32Array = _user_alg_river
	if cells.size() < 2:
		return
	var half: float = SIZE * 0.5
	var half_w: float = RIVER_STRIP_WIDTH * 0.5
	# Pre-build smoothed centerline positions + heights. The raw cell list
	# can jump tangent direction sharply when the algorithm hooks around a
	# small obstacle, which produces a self-overlapping ribbon. Multi-pass
	# box-blur on both positions and heights gives a clean, smooth surface.
	var pts: Array = []
	var hs: Array = []
	for ci in cells.size():
		var c0: int = cells[ci]
		pts.append(Vector2(float(c0 % GRID) * CELL - half, float(c0 / GRID) * CELL - half))
		hs.append(_heights[c0])
	for _pass in 6:
		var snap_p: Array = pts.duplicate()
		var snap_h: Array = hs.duplicate()
		for i in range(1, pts.size() - 1):
			pts[i] = (snap_p[i - 1] as Vector2) * 0.25 + (snap_p[i] as Vector2) * 0.5 + (snap_p[i + 1] as Vector2) * 0.25
			hs[i] = snap_h[i - 1] * 0.25 + snap_h[i] * 0.5 + snap_h[i + 1] * 0.25
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	# Track each cell's vertex base index (or -1 if the cell was skipped
	# because it's inside a lake). Triangles only connect cells whose
	# IMMEDIATE neighbour is also non-lake — when the river crosses through
	# a lake, the strip breaks at the lake boundary and resumes after.
	var cell_base: Array = []  # parallel to cells; int or -1
	for i in cells.size():
		var c: int = cells[i]
		_river_cell_surface_h[c] = _heights[c]
		# Only break the strip at cells claimed by a renderable (big) lake.
		# Cells in tiny "almost a lake" segments stay on the river path.
		if _user_alg_big_lake_cells.has(c):
			cell_base.append(-1)
			continue
		var here: Vector2 = pts[i]
		var tangent: Vector2
		if i == 0:
			tangent = (pts[1] as Vector2) - here
		elif i == cells.size() - 1:
			tangent = here - (pts[i - 1] as Vector2)
		else:
			tangent = (pts[i + 1] as Vector2) - (pts[i - 1] as Vector2)
		if tangent.length_squared() < 1e-6:
			tangent = Vector2(1, 0)
		tangent = tangent.normalized()
		var perp := Vector2(-tangent.y, tangent.x)
		var left: Vector2 = here - perp * half_w
		var right: Vector2 = here + perp * half_w
		var y: float = hs[i] + RIVER_WATER_LIFT
		var by: float = y - 0.5
		var base: int = verts.size()
		cell_base.append(base)
		verts.append(Vector3(left.x, y, left.y))
		verts.append(Vector3(right.x, y, right.y))
		verts.append(Vector3(left.x, by, left.y))
		verts.append(Vector3(right.x, by, right.y))
		uvs.append(Vector2(0.0, float(i) * 0.5))
		uvs.append(Vector2(1.0, float(i) * 0.5))
		uvs.append(Vector2(0.0, float(i) * 0.5))
		uvs.append(Vector2(1.0, float(i) * 0.5))
		var flow_r: float = tangent.x * 0.5 + 0.5
		var flow_g: float = tangent.y * 0.5 + 0.5
		var col := Color(flow_r, flow_g, 1.0, 1.0)
		colors.append(col); colors.append(col); colors.append(col); colors.append(col)
		# Connect only when the previous cell ALSO emitted vertices (i.e.
		# wasn't a lake cell). Otherwise the strip breaks here.
		if i > 0 and (cell_base[i - 1] as int) >= 0:
			var p: int = cell_base[i - 1]
			var b: int = base
			# Layout: p+0..3 = prev TL,TR,BL,BR  /  b+0..3 = curr TL,TR,BL,BR
			indices.append_array([p, p + 1, b, p + 1, b + 1, b])           # top
			indices.append_array([p + 2, b + 2, p + 3, p + 3, b + 2, b + 3]) # bottom
			indices.append_array([p, b, p + 2, p + 2, b, b + 2])           # left wall
			indices.append_array([p + 1, p + 3, b + 1, p + 3, b + 3, b + 1]) # right wall
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

func _build_user_alg_lakes_surface(arr_mesh: ArrayMesh) -> void:
	# One BIG flat quad per lake, sized to the cells' bounding box + a margin.
	# The water shader's depth-based alpha hides pixels where the bed is
	# above the surface, so the visible water naturally extends until it
	# "hits land" rather than tracing the rectilinear 1 m cell outline.
	var any_lake: bool = false
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var half: float = SIZE * 0.5
	var lake_idx: int = -1
	for L in _user_alg_lakes:
		lake_idx += 1
		if L == null:
			continue
		var cells_dict: Dictionary = L.cells as Dictionary
		if cells_dict.size() < MIN_LAKE_CELLS_FOR_RENDER:
			# Tiny "lakes" — bumps in the river — don't render. The river
			# strip flows through them.
			continue
		any_lake = true
		var min_gx: int = GRID
		var max_gx: int = -1
		var min_gz: int = GRID
		var max_gz: int = -1
		for c in cells_dict:
			var ci: int = c
			var gx: int = ci % GRID
			var gz: int = ci / GRID
			min_gx = mini(min_gx, gx); max_gx = maxi(max_gx, gx)
			min_gz = mini(min_gz, gz); max_gz = maxi(max_gz, gz)
		var x0: float = float(min_gx) * CELL - half - LAKE_PLANE_MARGIN
		var x1: float = float(max_gx) * CELL - half + LAKE_PLANE_MARGIN
		var z0: float = float(min_gz) * CELL - half - LAKE_PLANE_MARGIN
		var z1: float = float(max_gz) * CELL - half + LAKE_PLANE_MARGIN
		var water_y: float = (L.max_h as float) + RIVER_WATER_LIFT
		print("[Lake %d] %d cells, x(%.0f..%.0f) z(%.0f..%.0f) water_y=%.1f min_h=%.1f max_h=%.1f" % [
			lake_idx, cells_dict.size(), x0, x1, z0, z1, water_y,
			L.min_h as float, L.max_h as float])
		# Extruded box: 4 top vertices at water_y + 4 bottom at water_y - 0.5
		# to give the lake VISIBLE THICKNESS so the user can see the volume
		# from any angle, not just a flat plane.
		var thickness: float = 0.5
		var by: float = water_y - thickness
		var base: int = verts.size()
		# Top quad (base + 0..3)
		verts.append(Vector3(x0, water_y, z0))
		verts.append(Vector3(x1, water_y, z0))
		verts.append(Vector3(x0, water_y, z1))
		verts.append(Vector3(x1, water_y, z1))
		# Bottom quad (base + 4..7)
		verts.append(Vector3(x0, by, z0))
		verts.append(Vector3(x1, by, z0))
		verts.append(Vector3(x0, by, z1))
		verts.append(Vector3(x1, by, z1))
		for _i in 8:
			colors.append(Color(0.5, 0.5, 0.0, 1.0))
			uvs.append(Vector2(0.0, 0.0))
		# Top (normal +Y)
		indices.append_array([base, base + 3, base + 1, base, base + 2, base + 3])
		# Bottom (normal -Y) — reverse winding so it faces down
		indices.append_array([base + 4, base + 5, base + 7, base + 4, base + 7, base + 6])
		# Side walls (cull_disabled means winding here only matters for
		# lighting which is unshaded — pick consistent CCW).
		# -Z wall (front): base, base+1, base+5, base+4
		indices.append_array([base, base + 1, base + 5, base, base + 5, base + 4])
		# +Z wall (back): base+2, base+6, base+7, base+3
		indices.append_array([base + 2, base + 7, base + 6, base + 2, base + 3, base + 7])
		# -X wall (left): base, base+4, base+6, base+2
		indices.append_array([base, base + 6, base + 4, base, base + 2, base + 6])
		# +X wall (right): base+1, base+3, base+7, base+5
		indices.append_array([base + 1, base + 7, base + 3, base + 1, base + 5, base + 7])
	if not any_lake:
		return
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

# Modulate leaf material albedo toward a healthy green AND kill the spec/metal
# response. Polyhaven leaf/petal materials ship with low roughness + glossy
# speculars that, combined with mipmap shrinkage of the alpha cutout, make
# distant foliage look chrome-white as only the highlights survive the alpha.
# Material names vary wildly (Polyhaven uses *_leaves, *_leaf, *_twigs,
# *_branches, or just the asset name for whole-plant flowers), so we blacklist
# trunk/bark/wood/stone instead of whitelisting leaf keywords.
const LEAF_TINT := Color(0.68, 0.78, 0.48)
# Green tint uses a STRICT whitelist — some Polyhaven trees name the trunk
# material just `island_tree_01` with no "trunk"/"bark" word, so a blacklist
# would tint the trunk green. Foliage names are predictable; trunk names aren't.
const FOLIAGE_KEYWORDS: PackedStringArray = [
	"leaf", "leaves", "twig", "twigs", "foliage", "canopy", "needle", "needles",
]
# Matte (kill spec) is broader: applied to everything except obviously woody/stone parts.
const WOODY_OR_STONE_KEYWORDS: PackedStringArray = [
	"trunk", "bark", "wood", "stump", "rock", "stone", "boulder", "ground",
]

func _tint_leaf_materials(m: Mesh) -> void:
	# Tree pipeline: tint foliage green, matte non-woody surfaces.
	_apply_material_pass(m, true, true)

func _matte_flower_materials(m: Mesh) -> void:
	# Flower pipeline: matte everything, no green tint (keep petal colors).
	_apply_material_pass(m, false, true)

func _apply_material_pass(m: Mesh, do_tint: bool, do_matte: bool) -> void:
	if m == null:
		return
	for i in m.get_surface_count():
		var mat: Material = m.surface_get_material(i)
		if mat == null or not (mat is BaseMaterial3D):
			continue
		var name_l: String = mat.resource_name.to_lower()
		var is_foliage: bool = false
		for kw in FOLIAGE_KEYWORDS:
			if name_l.contains(kw):
				is_foliage = true
				break
		var is_woody_or_stone: bool = false
		for kw in WOODY_OR_STONE_KEYWORDS:
			if name_l.contains(kw):
				is_woody_or_stone = true
				break
		var want_tint: bool = do_tint and is_foliage
		var want_matte: bool = do_matte and not is_woody_or_stone
		if not want_tint and not want_matte:
			continue
		var tuned: BaseMaterial3D = (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
		if want_tint:
			tuned.albedo_color = LEAF_TINT
		if want_matte:
			tuned.roughness = 1.0
			tuned.metallic = 0.0
			tuned.metallic_specular = 0.0
		# Foliage textures store black RGB in transparent texels; ALPHA blending
		# mixes that black with the background and produces a dark fringe around
		# every leaf. Scissor clips instead of blending, removing the border.
		if is_foliage and tuned.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			tuned.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			tuned.alpha_scissor_threshold = 0.5
			tuned.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
		m.surface_set_material(i, tuned)

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

# --- Stones -------------------------------------------------------------------

# --- Grass occluders ----------------------------------------------------------
# Public API used by stumps, fallen logs, and placed wood. Each occluder is a
# (world XZ, radius) disk. Inside the disk, patch grass blades are dropped.
# IDs are arbitrary — callers pass any int they can recall later (typically
# get_instance_id()) so they can remove their own entry on free.

func add_grass_occluder(id: int, world_xz: Vector2, radius: float) -> void:
	_occluders[id] = {"pos": world_xz, "radius": radius}
	_occ_dirty = true

func remove_grass_occluder(id: int) -> void:
	if _occluders.erase(id):
		_occ_dirty = true

func _init_occluder_mask() -> void:
	_occ_mask_img = Image.create(OCC_MASK_SIZE, OCC_MASK_SIZE, false, Image.FORMAT_R8)
	_occ_mask_img.fill(Color(0, 0, 0))
	_occ_mask_tex = ImageTexture.create_from_image(_occ_mask_img)
	# Wire into every patch-grass material so the vertex shader can sample it.
	for mat in [_grass_material_patch_short, _grass_material_patch_tall, _grass_material_patch_core, _grass_material_patch_super_core]:
		if mat != null:
			mat.set_shader_parameter("occluder_mask", _occ_mask_tex)
			mat.set_shader_parameter("occluder_extent", OCC_MASK_EXTENT)

# Re-rasterizes the visible occluder disks centered on `patch_center`. Cheap
# (each disk paints O(r²) texels, max ~50 disks within the patch) and only
# runs when either the set changed or the patch slid more than half a texel.
func _update_occluder_mask(patch_center: Vector2) -> void:
	var moved: bool = _occ_last_center.distance_to(patch_center) > (OCC_MASK_EXTENT / float(OCC_MASK_SIZE)) * 0.5
	if not _occ_dirty and not moved:
		return
	_occ_last_center = patch_center
	_occ_dirty = false
	_occ_mask_img.fill(Color(0, 0, 0))
	var half: float = OCC_MASK_EXTENT * 0.5
	var ppm: float = float(OCC_MASK_SIZE) / OCC_MASK_EXTENT
	for occ in _occluders.values():
		var local: Vector2 = (occ.pos as Vector2) - patch_center
		var r: float = occ.radius as float
		if absf(local.x) > half + r or absf(local.y) > half + r:
			continue
		var cu: int = int((local.x + half) * ppm)
		var cv: int = int((local.y + half) * ppm)
		var r_pix: int = int(ceil(r * ppm)) + 1   # +1 for safety against texel rounding
		var r_pix_sq: int = r_pix * r_pix
		for dv in range(-r_pix, r_pix + 1):
			for du in range(-r_pix, r_pix + 1):
				if du * du + dv * dv > r_pix_sq:
					continue
				var pu: int = cu + du
				var pv: int = cv + dv
				if pu < 0 or pu >= OCC_MASK_SIZE or pv < 0 or pv >= OCC_MASK_SIZE:
					continue
				_occ_mask_img.set_pixel(pu, pv, Color(1, 1, 1))
	_occ_mask_tex.update(_occ_mask_img)

func _init_stone_resources() -> void:
	_stone_large_variants = _load_glb_variants(STONE_LARGE_PATHS)
	_stone_medium_variants = _load_glb_variants(STONE_MEDIUM_PATHS)
	_brook_medium_variants = _load_glb_variants(BROOK_MEDIUM_PATHS)
	_brook_small_variants = _load_glb_variants(BROOK_SMALL_PATHS)
	_stone_placement_noise = FastNoiseLite.new()
	_stone_placement_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_stone_placement_noise.seed = noise_seed + 131
	_stone_placement_noise.frequency = STONE_PLACEMENT_FREQ

## Loads each GLB, finds the unioned mesh-space AABB, and shifts every part's
## xform down so the lowest point sits at local y=0. Placement code therefore
## just sets the body origin at ground height — no per-variant min_y math at
## placement time, and rotating around the body origin pivots cleanly around
## the mesh base (used for the tree fall animation).
func _load_glb_variants(paths: Array) -> Array:
	var out: Array = []
	for p in paths:
		if not ResourceLoader.exists(p):
			continue
		var parts: Array = _load_tree_parts(p)
		if parts.is_empty():
			continue
		# Pass 1: find min_y across the union.
		var min_y: float = INF
		for part in parts:
			var aabb: AABB = (part.mesh as Mesh).get_aabb()
			var xf: Transform3D = part.xform
			for i in 8:
				var c: Vector3 = xf * aabb.get_endpoint(i)
				if c.y < min_y:
					min_y = c.y
		# Pass 2: shift parts so union bottom is at y=0; compute the shifted
		# union AABB (used by destructible bodies to size their collider).
		var shifted: Array = []
		var union_aabb: AABB
		var first := true
		for part in parts:
			var xf: Transform3D = part.xform
			var new_xf := Transform3D(xf.basis, xf.origin - Vector3(0, min_y, 0))
			shifted.append({"mesh": part.mesh, "xform": new_xf})
			var aabb: AABB = (part.mesh as Mesh).get_aabb()
			for i in 8:
				var c: Vector3 = new_xf * aabb.get_endpoint(i)
				if first:
					union_aabb = AABB(c, Vector3.ZERO)
					first = false
				else:
					union_aabb = union_aabb.expand(c)
		out.append({"parts": shifted, "aabb": union_aabb})
	return out

# --- Land stones: streamed disk of tiles, deterministic per (seed,tx,tz) ------

func _stream_stones(pos: Vector3) -> void:
	if _stone_large_variants.is_empty() and _stone_medium_variants.is_empty():
		return
	var center_tx: int = int(floor(pos.x / STONE_TILE_SIZE))
	var center_tz: int = int(floor(pos.z / STONE_TILE_SIZE))
	var tile_radius: int = int(ceil(STONE_STREAM_RADIUS / STONE_TILE_SIZE)) + 1
	var radius_sq: float = STONE_STREAM_RADIUS * STONE_STREAM_RADIUS

	var needed: Dictionary = {}
	for dz in range(-tile_radius, tile_radius + 1):
		for dx in range(-tile_radius, tile_radius + 1):
			var tx: int = center_tx + dx
			var tz: int = center_tz + dz
			var cx: float = (float(tx) + 0.5) * STONE_TILE_SIZE
			var cz: float = (float(tz) + 0.5) * STONE_TILE_SIZE
			var ddx: float = cx - pos.x
			var ddz: float = cz - pos.z
			if ddx * ddx + ddz * ddz > radius_sq:
				continue
			var key := Vector2i(tx, tz)
			needed[key] = true
			if not _stone_tiles.has(key):
				_stone_spawn_queue.append({"key": key, "tx": tx, "tz": tz})

	var to_remove: Array = []
	for key in _stone_tiles.keys():
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		for b in (_stone_tiles[key] as Dictionary).bodies:
			if is_instance_valid(b):
				(b as Node).queue_free()
		_stone_tiles.erase(key)

	var pruned: Array = []
	for entry in _stone_spawn_queue:
		if needed.has(entry.key) and not _stone_tiles.has(entry.key):
			pruned.append(entry)
	_stone_spawn_queue = pruned

func _flush_stone_queue() -> void:
	var budget: int = STONE_TILE_SPAWN_BUDGET
	while budget > 0 and not _stone_spawn_queue.is_empty():
		var entry: Dictionary = _stone_spawn_queue.pop_front()
		if _stone_tiles.has(entry.key):
			continue
		var bodies: Array = _build_stone_tile(entry.tx, entry.tz)
		for b in bodies:
			add_child(b)
		_stone_tiles[entry.key] = {"bodies": bodies}
		budget -= 1

# Per-cell jittered grid: decide whether each cell hosts a large or medium
# stone via placement noise, then spawn a DestructibleStone body in-place.
func _build_stone_tile(tx: int, tz: int) -> Array:
	var x0: float = float(tx) * STONE_TILE_SIZE
	var z0: float = float(tz) * STONE_TILE_SIZE
	var half: float = SIZE * 0.5
	if x0 + STONE_TILE_SIZE < -half or x0 > half or z0 + STONE_TILE_SIZE < -half or z0 > half:
		return []
	var rng := RandomNumberGenerator.new()
	rng.seed = noise_seed * 13331 + tz * 100193 + tx
	var stone_script: GDScript = preload("res://entities/stone/stone.gd")
	var out: Array = []

	# Pass 1: large stones — coarse grid.
	if not _stone_large_variants.is_empty():
		var ln_side: int = maxi(1, int(STONE_TILE_SIZE / STONE_LARGE_SPACING))
		for iz in ln_side:
			for ix in ln_side:
				var wx: float = x0 + (float(ix) + rng.randf()) * STONE_LARGE_SPACING
				var wz: float = z0 + (float(iz) + rng.randf()) * STONE_LARGE_SPACING
				if wx < -half or wx > half or wz < -half or wz > half:
					continue
				if not _stone_placement_ok(wx, wz, rng, STONE_LARGE_THRESHOLD):
					continue
				var v: int = rng.randi() % _stone_large_variants.size()
				var var_data: Dictionary = _stone_large_variants[v]
				var xf: Transform3D = _stone_transform(
					wx, wz, rng,
					STONE_LARGE_SCALE_BASE, STONE_LARGE_SCALE_JITTER,
					STONE_SINK
				)
				out.append(_make_stone_body(stone_script, var_data, xf))

	# Pass 2: medium stones — finer grid.
	if not _stone_medium_variants.is_empty():
		var mn_side: int = maxi(1, int(STONE_TILE_SIZE / STONE_MEDIUM_SPACING))
		for iz in mn_side:
			for ix in mn_side:
				var wx2: float = x0 + (float(ix) + rng.randf()) * STONE_MEDIUM_SPACING
				var wz2: float = z0 + (float(iz) + rng.randf()) * STONE_MEDIUM_SPACING
				if wx2 < -half or wx2 > half or wz2 < -half or wz2 > half:
					continue
				if not _stone_placement_ok(wx2, wz2, rng, STONE_MEDIUM_THRESHOLD):
					continue
				var v2: int = rng.randi() % _stone_medium_variants.size()
				var var_data2: Dictionary = _stone_medium_variants[v2]
				var xf2: Transform3D = _stone_transform(
					wx2, wz2, rng,
					STONE_MEDIUM_SCALE_BASE, STONE_MEDIUM_SCALE_JITTER,
					STONE_SINK
				)
				out.append(_make_stone_body(stone_script, var_data2, xf2))
	return out

# Shared body-builder for brook + land stones: pulls the rotation out of the
# scale-bearing transform, hands the scale + shifted parts + AABB to the
# stone's setup() so the StaticBody3D itself stays unscaled.
func _make_stone_body(script: GDScript, var_data: Dictionary, xf: Transform3D) -> StaticBody3D:
	var stone := script.new() as StaticBody3D
	stone.transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
	var scale_vec := Vector3(
		xf.basis.x.length(),
		xf.basis.y.length(),
		xf.basis.z.length()
	)
	stone.call("setup", var_data.parts, scale_vec, var_data.aabb as AABB)
	return stone

func _stone_placement_ok(wx: float, wz: float, rng: RandomNumberGenerator, threshold: float) -> bool:
	# Keep land stones out of the stream/sand band and out of the lake.
	if _in_lake_keepout(wx, wz, 0.0):
		return false
	if STREAM_ENABLED and absf(wz - _centerline_z(wx)) < STONE_BANK_EXCLUSION:
		return false
	var p: float = (_stone_placement_noise.get_noise_2d(wx, wz) + 1.0) * 0.5
	# A small RNG hop breaks the noise grid — stones don't appear on tidy lines.
	p += (rng.randf() - 0.5) * 0.18
	if p < threshold:
		return false
	var n: Vector3 = _sample_normal(_heights, wx, wz)
	if n.y < STONE_MIN_NORMAL_Y:
		return false
	var h: float = _sample_height(_heights, wx, wz)
	if h < STONE_MIN_ELEV or h > STONE_MAX_ELEV:
		return false
	return true

func _stone_transform(
	wx: float, wz: float, rng: RandomNumberGenerator,
	scale_base: float, scale_jitter: float, sink: float
) -> Transform3D:
	var n: Vector3 = _sample_normal(_heights, wx, wz)
	var up: Vector3 = n.lerp(Vector3.UP, 0.35).normalized()
	var align := Basis(Quaternion(Vector3.UP, up))
	var yaw := Basis(Vector3.UP, rng.randf() * TAU)
	var s: float = scale_base + rng.randf() * scale_jitter
	var sxz: float = s * (0.88 + rng.randf() * 0.24)
	var sy: float = s * (0.85 + rng.randf() * 0.30)
	var scale_basis := Basis().scaled(Vector3(sxz, sy, sxz))
	# Parts are pre-shifted in _load_glb_variants so mesh-local y=0 is the
	# bottom — placement origin is just ground level minus sink.
	var h: float = _sample_height(_heights, wx, wz)
	return Transform3D(align * yaw * scale_basis, Vector3(wx, h - sink, wz))

# Bundle a per-variant transform list into one MultiMesh per sub-mesh part —
# mirrors how trees are emitted so each part keeps its imported material.
func _emit_variant_mmis(variants: Array, per_variant: Array, aabb: AABB, out: Array) -> void:
	for i in variants.size():
		var ts: Array = per_variant[i]
		if ts.is_empty():
			continue
		var parts: Array = (variants[i] as Dictionary).parts
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

# --- Brook stones: march along the centerline, outline both banks -------------
# Each tile owns the x range [tx*BROOK_TILE_SIZE, (tx+1)*BROOK_TILE_SIZE]. We
# only build tiles whose x range overlaps the world, and quickly skip tiles
# whose z range can't possibly intersect the meandering centerline.
func _stream_brook(pos: Vector3) -> void:
	if _brook_medium_variants.is_empty() and _brook_small_variants.is_empty():
		return
	var center_tx: int = int(floor(pos.x / BROOK_TILE_SIZE))
	var center_tz: int = int(floor(pos.z / BROOK_TILE_SIZE))
	var tile_radius: int = int(ceil(BROOK_STREAM_RADIUS / BROOK_TILE_SIZE)) + 1
	var radius_sq: float = BROOK_STREAM_RADIUS * BROOK_STREAM_RADIUS
	var z_lo: float = _stream_z_min - (BROOK_BANK_OFFSET + 2.0)
	var z_hi: float = _stream_z_max + (BROOK_BANK_OFFSET + 2.0)

	var needed: Dictionary = {}
	for dz in range(-tile_radius, tile_radius + 1):
		for dx in range(-tile_radius, tile_radius + 1):
			var tx: int = center_tx + dx
			var tz: int = center_tz + dz
			var cx: float = (float(tx) + 0.5) * BROOK_TILE_SIZE
			var cz: float = (float(tz) + 0.5) * BROOK_TILE_SIZE
			var ddx: float = cx - pos.x
			var ddz: float = cz - pos.z
			if ddx * ddx + ddz * ddz > radius_sq:
				continue
			var tile_z0: float = float(tz) * BROOK_TILE_SIZE
			var tile_z1: float = float(tz + 1) * BROOK_TILE_SIZE
			if tile_z1 < z_lo or tile_z0 > z_hi:
				continue
			var key := Vector2i(tx, tz)
			needed[key] = true
			if not _brook_tiles.has(key):
				_brook_spawn_queue.append({"key": key, "tx": tx, "tz": tz})

	var to_remove: Array = []
	for key in _brook_tiles.keys():
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		# Bodies may already be freed (player destroyed them). is_instance_valid
		# guards against double-free on the queue_free side too.
		for b in (_brook_tiles[key] as Dictionary).bodies:
			if is_instance_valid(b):
				(b as Node).queue_free()
		_brook_tiles.erase(key)

	var pruned: Array = []
	for entry in _brook_spawn_queue:
		if needed.has(entry.key) and not _brook_tiles.has(entry.key):
			pruned.append(entry)
	_brook_spawn_queue = pruned

func _flush_brook_queue() -> void:
	var budget: int = BROOK_TILE_SPAWN_BUDGET
	while budget > 0 and not _brook_spawn_queue.is_empty():
		var entry: Dictionary = _brook_spawn_queue.pop_front()
		if _brook_tiles.has(entry.key):
			continue
		var bodies: Array = _build_brook_tile(entry.tx, entry.tz)
		for b in bodies:
			add_child(b)
		_brook_tiles[entry.key] = {"bodies": bodies}
		budget -= 1

# March the centerline at BROOK_STEP intervals; at each step spawn at most one
# DestructibleStone per bank. Returns the list of bodies; the streaming layer
# adds them to the tree and tracks them per-tile for cleanup. Tile ownership of
# a step is decided by the centerline z at that wx falling in the tile's z
# range — exact same rule as the water mesh, so banks never duplicate at seams.
func _build_brook_tile(tx: int, tz: int) -> Array:
	if not STREAM_ENABLED:
		return []
	if _brook_medium_variants.is_empty() and _brook_small_variants.is_empty():
		return []
	var half: float = SIZE * 0.5
	var x0: float = maxf(float(tx) * BROOK_TILE_SIZE, -half)
	var x1: float = minf(float(tx + 1) * BROOK_TILE_SIZE, half)
	if x1 - x0 < BROOK_STEP:
		return []
	var tile_z0: float = float(tz) * BROOK_TILE_SIZE
	var tile_z1: float = float(tz + 1) * BROOK_TILE_SIZE
	var rng := RandomNumberGenerator.new()
	rng.seed = noise_seed * 7547 + tz * 100129 + tx

	var out: Array = []
	var steps: int = int(floor((x1 - x0) / BROOK_STEP))
	for i in steps:
		var wx: float = x0 + (float(i) + 0.5) * BROOK_STEP
		# Skip stones that would fall inside the lake — they'd float on water.
		if wx < _stream_x_start or wx > _stream_x_water_end:
			continue
		var cz: float = _centerline_z(wx)
		if cz < tile_z0 or cz >= tile_z1:
			continue
		var eps: float = 0.5
		var dcz: float = _centerline_z(wx + eps) - _centerline_z(wx - eps)
		var tang := Vector2(2.0 * eps, dcz).normalized()
		var perp := Vector2(-tang.y, tang.x)
		for side in [-1.0, 1.0]:
			if rng.randf() < BROOK_SKIP_CHANCE:
				continue
			var lateral: float = BROOK_BANK_OFFSET + (rng.randf() - 0.5) * BROOK_LATERAL_JITTER
			var sx: float = wx + perp.x * lateral * side + tang.x * (rng.randf() - 0.5) * BROOK_STEP * 0.5
			var sz: float = cz + perp.y * lateral * side + tang.y * (rng.randf() - 0.5) * BROOK_STEP * 0.5
			var use_med: bool = (rng.randf() < BROOK_MED_CHANCE) and not _brook_medium_variants.is_empty()
			var ground_h: float = _sample_height(_heights, sx, sz)
			var scale_base: float = BROOK_MED_SCALE if use_med else BROOK_SMALL_SCALE
			var variant_pool: Array = _brook_medium_variants if use_med else _brook_small_variants
			if variant_pool.is_empty():
				continue
			var base_v: int = rng.randi() % variant_pool.size()
			var base_var: Dictionary = variant_pool[base_v]
			var base_xform: Transform3D = _brook_stone_transform(sx, sz, ground_h, rng, scale_base, BROOK_SINK)
			var stone_script: GDScript = preload("res://entities/stone/stone.gd")
			out.append(_make_stone_body(stone_script, base_var, base_xform))

			# Stack: a smaller stone perched on top. Top-of-base ≈
			# body_y + aabb.size.y * scale.y; place the stack body there.
			if rng.randf() < BROOK_STACK_CHANCE and not _brook_small_variants.is_empty():
				var stack_v: int = rng.randi() % _brook_small_variants.size()
				var stack_var: Dictionary = _brook_small_variants[stack_v]
				var base_scale_y: float = base_xform.basis.y.length()
				var top_y: float = base_xform.origin.y + (base_var.aabb as AABB).size.y * base_scale_y * 0.95
				var stack_xform: Transform3D = _brook_stack_transform(
					sx + (rng.randf() - 0.5) * 0.5,
					sz + (rng.randf() - 0.5) * 0.5,
					top_y, rng, scale_base * 0.72
				)
				out.append(_make_stone_body(stone_script, stack_var, stack_xform))
	return out

func _brook_stone_transform(
	wx: float, wz: float, h: float, rng: RandomNumberGenerator,
	scale_base: float, sink: float
) -> Transform3D:
	var n: Vector3 = _sample_normal(_heights, wx, wz)
	var up: Vector3 = n.lerp(Vector3.UP, 0.45).normalized()
	var align := Basis(Quaternion(Vector3.UP, up))
	var yaw := Basis(Vector3.UP, rng.randf() * TAU)
	var sxz: float = scale_base * (0.85 + rng.randf() * 0.30)
	var sy: float = scale_base * (0.75 + rng.randf() * 0.30)
	var scale_basis := Basis().scaled(Vector3(sxz, sy, sxz))
	return Transform3D(align * yaw * scale_basis, Vector3(wx, h - sink, wz))

func _brook_stack_transform(
	wx: float, wz: float, y: float, rng: RandomNumberGenerator, scale_base: float
) -> Transform3D:
	var yaw := Basis(Vector3.UP, rng.randf() * TAU)
	var ang: float = rng.randf() * TAU
	var lean_axis := Vector3(cos(ang), 0.0, sin(ang))
	var lean := Basis(lean_axis, (rng.randf() * 0.18) + 0.04)
	var sxz: float = scale_base * (0.85 + rng.randf() * 0.30)
	var sy: float = scale_base * (0.75 + rng.randf() * 0.30)
	var scale_basis := Basis().scaled(Vector3(sxz, sy, sxz))
	return Transform3D(lean * yaw * scale_basis, Vector3(wx, y, wz))


# --- Wildflowers --------------------------------------------------------------
# MultiMesh-streamed flower fields. Each tile picks a "patch mode" from its
# seed: a single species, a single color family, or a mixed wild meadow. Inside
# the patch, a low-freq noise gates placement so flowers form irregular blobs
# rather than carpeting every tile. Bank-bonus mirrors trees — wildflowers
# crowd the riverbank.

func _init_flower_resources() -> void:
	_flower_variants = _load_glb_variants(FLOWER_PATHS)
	_flower_patch_noise = FastNoiseLite.new()
	_flower_patch_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_flower_patch_noise.seed = noise_seed + 173
	_flower_patch_noise.frequency = FLOWER_PATCH_FREQ
	_flower_patch_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_flower_patch_noise.fractal_octaves = 2

func _stream_flowers(pos: Vector3) -> void:
	if _flower_variants.is_empty():
		return
	var center_tx: int = int(floor(pos.x / FLOWER_TILE_SIZE))
	var center_tz: int = int(floor(pos.z / FLOWER_TILE_SIZE))
	var tile_radius: int = int(ceil(FLOWER_STREAM_RADIUS / FLOWER_TILE_SIZE)) + 1
	var radius_sq: float = FLOWER_STREAM_RADIUS * FLOWER_STREAM_RADIUS

	var needed: Dictionary = {}
	for dz in range(-tile_radius, tile_radius + 1):
		for dx in range(-tile_radius, tile_radius + 1):
			var tx: int = center_tx + dx
			var tz: int = center_tz + dz
			var cx: float = (float(tx) + 0.5) * FLOWER_TILE_SIZE
			var cz: float = (float(tz) + 0.5) * FLOWER_TILE_SIZE
			var ddx: float = cx - pos.x
			var ddz: float = cz - pos.z
			if ddx * ddx + ddz * ddz > radius_sq:
				continue
			var key := Vector2i(tx, tz)
			needed[key] = true
			if not _flower_tiles.has(key):
				_flower_spawn_queue.append({"key": key, "tx": tx, "tz": tz})

	var to_remove: Array = []
	for key in _flower_tiles.keys():
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		for mmi in (_flower_tiles[key] as Dictionary).mmis:
			(mmi as MultiMeshInstance3D).queue_free()
		_flower_tiles.erase(key)

	var pruned: Array = []
	for entry in _flower_spawn_queue:
		if needed.has(entry.key) and not _flower_tiles.has(entry.key):
			pruned.append(entry)
	_flower_spawn_queue = pruned

func _flush_flower_queue() -> void:
	var budget: int = FLOWER_TILE_SPAWN_BUDGET
	while budget > 0 and not _flower_spawn_queue.is_empty():
		var entry: Dictionary = _flower_spawn_queue.pop_front()
		if _flower_tiles.has(entry.key):
			continue
		var mmis: Array = _build_flower_tile(entry.tx, entry.tz)
		for mmi in mmis:
			add_child(mmi)
		_flower_tiles[entry.key] = {"mmis": mmis}
		budget -= 1

func _build_flower_tile(tx: int, tz: int) -> Array:
	var x0: float = float(tx) * FLOWER_TILE_SIZE
	var z0: float = float(tz) * FLOWER_TILE_SIZE
	var half: float = SIZE * 0.5
	if x0 + FLOWER_TILE_SIZE < -half or x0 > half or z0 + FLOWER_TILE_SIZE < -half or z0 > half:
		return []

	var rng := RandomNumberGenerator.new()
	rng.seed = noise_seed * 86413 + tz * 100069 + tx
	# Patch mode: 0 = single species, 1 = single color family, 2 = mixed.
	# Weights bias toward more visually-distinct mono patches.
	var roll: float = rng.randf()
	var mode: int = 0 if roll < 0.45 else (1 if roll < 0.80 else 2)
	var mode_variant: int = rng.randi() % _flower_variants.size()
	var mode_family: int = rng.randi() % 3   # 0=red, 1=yellow, 2=purple
	# Per-tile density offset. A symmetric range centered on 0 — half the tiles
	# end up denser than the mean threshold, half sparser. Skewed slightly
	# toward "denser" so the visual is more "fields" than "scattering".
	var density_offset: float = (rng.randf() - 0.35) * FLOWER_DENSITY_VARIATION * 2.0
	var tile_threshold: float = FLOWER_PATCH_THRESHOLD + density_offset

	var per_variant: Array = []
	per_variant.resize(_flower_variants.size())
	for i in _flower_variants.size():
		per_variant[i] = []

	var n_side: int = int(FLOWER_TILE_SIZE / FLOWER_DENSITY_SPACING)
	for iz in n_side:
		for ix in n_side:
			var wx: float = x0 + (float(ix) + rng.randf()) * FLOWER_DENSITY_SPACING
			var wz: float = z0 + (float(iz) + rng.randf()) * FLOWER_DENSITY_SPACING
			if wx < -half or wx > half or wz < -half or wz > half:
				continue
			var bank_boost: float = 0.0
			if STREAM_ENABLED:
				if _in_lake_keepout(wx, wz, 0.0):
					continue
				var dz_center: float = absf(wz - _centerline_z(wx))
				if dz_center < FLOWER_BANK_EXCLUSION:
					continue
				if dz_center < FLOWER_BANK_INFLUENCE:
					var ft: float = (dz_center - FLOWER_BANK_EXCLUSION) / (FLOWER_BANK_INFLUENCE - FLOWER_BANK_EXCLUSION)
					bank_boost = FLOWER_BANK_BOOST * (1.0 - clampf(ft, 0.0, 1.0))
			var p: float = (_flower_patch_noise.get_noise_2d(wx, wz) + 1.0) * 0.5
			if p < tile_threshold - bank_boost:
				continue
			var n: Vector3 = _sample_normal(_heights, wx, wz)
			if n.y < FLOWER_MIN_NORMAL_Y:
				continue
			var h: float = _sample_height(_heights, wx, wz)
			if h < FLOWER_MIN_ELEV or h > FLOWER_MAX_ELEV:
				continue
			var variant: int
			if mode == 0:
				variant = mode_variant
			elif mode == 1:
				variant = mode_family * FLOWER_FAMILY_SIZE + (rng.randi() % FLOWER_FAMILY_SIZE)
			else:
				variant = rng.randi() % _flower_variants.size()
			var up: Vector3 = n.lerp(Vector3.UP, 0.6).normalized()
			var align := Basis(Quaternion(Vector3.UP, up))
			var yaw := Basis(Vector3.UP, rng.randf() * TAU)
			var s: float = FLOWER_SCALE_BASE + rng.randf() * FLOWER_SCALE_JITTER
			# Stretch Y so flowers stand taller than they are wide — Polyhaven
			# species are mostly low spreaders at natural scale.
			var s_y: float = s * 1.8 + rng.randf() * 0.7
			var scale_basis := Basis().scaled(Vector3(s, s_y, s))
			(per_variant[variant] as Array).append(
				Transform3D(align * yaw * scale_basis, Vector3(wx, h - FLOWER_SINK, wz))
			)

	var aabb := AABB(
		Vector3(x0, -10.0, z0),
		Vector3(FLOWER_TILE_SIZE, 200.0, FLOWER_TILE_SIZE)
	)
	var out: Array = []
	for v in _flower_variants.size():
		var ts: Array = per_variant[v]
		if ts.is_empty():
			continue
		var parts: Array = (_flower_variants[v] as Dictionary).parts
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
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			out.append(mmi)
	return out
