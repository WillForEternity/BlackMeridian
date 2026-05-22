extends Area3D

# Moving laser beam fired by the GhostLeviathan. Two modes:
#   - "long":   lifetime 5 s, deals long_dps to anyone it overlaps each frame,
#               wide glowing cylinder. Does NOT despawn on hit.
#   - "volley": lifetime ~1.5 s, deals volley_damage on first contact, then
#               despawns. Thinner cylinder.
# Both modes travel at BEAM_SPEED (3× the player's run speed).

const BEAM_SPEED: float = 39.0   # 3× player.gd::speed (13.0)
const LONG_LIFETIME: float = 5.0
const VOLLEY_LIFETIME: float = 1.5
const LONG_DPS: float = 2.5
const VOLLEY_DAMAGE: int = 2

var mode: String = "volley"   # "long" or "volley"
var direction: Vector3 = Vector3.FORWARD
var _age: float = 0.0
var _hit_targets: Array = []
var _mesh: MeshInstance3D
var _shape: CollisionShape3D

func _ready() -> void:
	collision_layer = 0
	collision_mask = 1   # detect player + remote puppets (layer 1)
	monitoring = true
	body_entered.connect(_on_body_entered)
	_build_visual()
	_build_collision()

func setup(at: Vector3, dir: Vector3, beam_mode: String) -> void:
	global_position = at
	mode = beam_mode
	if dir.length_squared() > 0.0:
		direction = dir.normalized()
		look_at(global_position + direction, Vector3.UP)

func _build_visual() -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.18
	cyl.bottom_radius = 0.18
	cyl.height = 2.4
	_mesh = MeshInstance3D.new()
	_mesh.mesh = cyl
	# Cylinder default axis is Y; rotate so it points along -Z (look_at forward).
	_mesh.rotation = Vector3(PI / 2.0, 0.0, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.95, 1.0, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.9, 1.0, 1.0)
	mat.emission_energy_multiplier = 9.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh.material_override = mat
	add_child(_mesh)
	# Long beams read as thicker, brighter than volley shots.
	if mode == "long":
		cyl.top_radius = 0.32
		cyl.bottom_radius = 0.32
		cyl.height = 3.2
		mat.emission_energy_multiplier = 14.0

func _build_collision() -> void:
	var cap := CapsuleShape3D.new()
	cap.radius = 0.32 if mode == "long" else 0.18
	cap.height = 3.2 if mode == "long" else 2.4
	_shape = CollisionShape3D.new()
	_shape.shape = cap
	_shape.rotation = Vector3(PI / 2.0, 0.0, 0.0)
	add_child(_shape)

func _physics_process(delta: float) -> void:
	global_position += direction * BEAM_SPEED * delta
	_age += delta
	# Long beams deal damage-over-time to everything they currently overlap.
	if mode == "long":
		for body in get_overlapping_bodies():
			if body.has_method("take_damage"):
				body.take_damage(int(ceil(LONG_DPS * delta)), direction)
	var lifetime: float = LONG_LIFETIME if mode == "long" else VOLLEY_LIFETIME
	if _age >= lifetime:
		queue_free()

func _on_body_entered(body: Node) -> void:
	if mode == "long":
		return   # long-beam damage handled in _physics_process
	if body in _hit_targets:
		return
	_hit_targets.append(body)
	if body.has_method("take_damage"):
		body.take_damage(VOLLEY_DAMAGE, direction)
	queue_free()
