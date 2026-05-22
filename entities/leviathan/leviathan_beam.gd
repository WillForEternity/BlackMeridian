extends Area3D

# Single volley projectile fired by the GhostLeviathan. Travels along
# `direction` at BEAM_SPEED, despawns on first body contact or after
# VOLLEY_LIFETIME. Long beams are a separate class (leviathan_long_beam.gd).

const BEAM_SPEED: float = 39.0   # ~3× player base speed (13.0)
const VOLLEY_LIFETIME: float = 1.5
const VOLLEY_DAMAGE: int = 2

var direction: Vector3 = Vector3.FORWARD
var shooter: Node = null   # leviathan instance, ignored by hit-test so beams don't self-kill
var homing_target: Node3D = null   # gently steer toward this each frame if set
var _age: float = 0.0
var _hit_targets: Array = []
var _mesh: MeshInstance3D

# How fast (radians/sec) the beam can rotate its direction toward the target.
# 1.6 rad/s ≈ 92°/s — enough to read as "tracking" without becoming undodgeable
# at the 39 m/s beam speed.
const HOMING_TURN_RATE: float = 2.4

func _ready() -> void:
	collision_layer = 0
	collision_mask = 1   # player + remote puppets are on layer 1
	monitoring = true
	body_entered.connect(_on_body_entered)
	_build_visual()
	_build_collision()

func setup(at: Vector3, dir: Vector3, src: Node = null, homing: Node3D = null) -> void:
	global_position = at
	shooter = src
	homing_target = homing
	if dir.length_squared() > 0.0:
		direction = dir.normalized()
		look_at(global_position + direction, _safe_up(direction))

func _build_visual() -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.14
	cyl.bottom_radius = 0.14
	cyl.height = 2.4
	_mesh = MeshInstance3D.new()
	_mesh.mesh = cyl
	# Default cylinder is +Y; rotate so it extends along -Z (look_at forward).
	# Position the mesh -height/2 along Z so the cylinder body extends FROM
	# the spawn point forward — otherwise it'd be centered on the spawn
	# point with half the cylinder behind it.
	_mesh.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	_mesh.position = Vector3(0, 0, -cyl.height * 0.5)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.95, 1.0, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.9, 1.0, 1.0)
	mat.emission_energy_multiplier = 11.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh.material_override = mat
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)

func _build_collision() -> void:
	var cap := CapsuleShape3D.new()
	cap.radius = 0.22
	cap.height = 2.4
	var cs := CollisionShape3D.new()
	cs.shape = cap
	cs.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	cs.position = Vector3(0, 0, -1.2)
	add_child(cs)

func _physics_process(delta: float) -> void:
	if homing_target != null and is_instance_valid(homing_target):
		# Slight homing: rotate the velocity direction toward the target by
		# at most HOMING_TURN_RATE * delta radians per frame. Caps the turn
		# so the beam can still be sidestepped, just leads slightly.
		var to_t: Vector3 = homing_target.global_position - global_position
		if to_t.length_squared() > 1e-4:
			var desired := to_t.normalized()
			var max_step := HOMING_TURN_RATE * delta
			var angle: float = direction.angle_to(desired)
			if angle > max_step:
				var axis: Vector3 = direction.cross(desired)
				if axis.length_squared() > 1e-6:
					direction = direction.rotated(axis.normalized(), max_step).normalized()
			else:
				direction = desired
			look_at(global_position + direction, _safe_up(direction))
	global_position += direction * BEAM_SPEED * delta
	_age += delta
	if _age >= VOLLEY_LIFETIME:
		queue_free()

func _on_body_entered(body: Node) -> void:
	if body == shooter:
		# Beam spawns inside the leviathan's hurtbox (same layer 1) — without
		# this skip, the volley shot collides with its own shooter on the
		# spawn frame and despawns invisibly.
		return
	if body in _hit_targets:
		return
	_hit_targets.append(body)
	if body.has_method("take_damage"):
		body.take_damage(VOLLEY_DAMAGE, direction)
	queue_free()

func _safe_up(d: Vector3) -> Vector3:
	if absf(d.dot(Vector3.UP)) > 0.99:
		return Vector3.FORWARD
	return Vector3.UP
