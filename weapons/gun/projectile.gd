class_name Projectile
extends Area3D

@export var speed: float = 66.0
@export var lifetime: float = 2.0
@export var damage: int = 2

var direction: Vector3 = Vector3.FORWARD
var shooter: Node = null
var source_weapon: Node = null
var pooled: bool = false
var _despawning: bool = false
var _age: float = 0.0
var _trail_points: PackedVector3Array = PackedVector3Array()
var _trail_mi: MeshInstance3D
var _trail_im: ImmediateMesh
var _trail_mat: StandardMaterial3D

const TRAIL_MAX_POINTS: int = 24
const TRAIL_TINT := Color(1, 0.45, 0.95, 0.85)

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	var light := OmniLight3D.new()
	light.light_color = Color(1, 0.45, 0.95, 1)
	light.light_energy = 3.0
	light.omni_range = 3.2
	add_child(light)
	_setup_trail()

func _setup_trail() -> void:
	_trail_mi = MeshInstance3D.new()
	_trail_im = ImmediateMesh.new()
	_trail_mi.mesh = _trail_im
	_trail_mat = StandardMaterial3D.new()
	_trail_mat.albedo_color = TRAIL_TINT
	_trail_mat.emission_enabled = true
	_trail_mat.emission = TRAIL_TINT
	_trail_mat.emission_energy_multiplier = 8.0
	_trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_trail_mat.vertex_color_use_as_albedo = true
	_trail_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_trail_mi.material_override = _trail_mat
	_trail_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail_mi.top_level = true  # ignore parent transform; positions are world-space
	add_child(_trail_mi)

func reset_for_reuse() -> void:
	_age = 0.0
	_despawning = false
	direction = Vector3.FORWARD
	shooter = null
	source_weapon = null
	_trail_points.clear()
	if _trail_im:
		_trail_im.clear_surfaces()
	monitoring = true

func set_direction(d: Vector3) -> void:
	if d.length() > 0.0:
		direction = d.normalized()
		look_at(global_position + direction, Vfx.safe_up(direction))

func _physics_process(delta: float) -> void:
	global_position += direction * speed * delta
	_age += delta
	_append_trail_point(global_position)
	_rebuild_trail()
	if _age >= lifetime:
		_despawn()

func _append_trail_point(p: Vector3) -> void:
	_trail_points.append(p)
	while _trail_points.size() > TRAIL_MAX_POINTS:
		_trail_points.remove_at(0)

func _rebuild_trail() -> void:
	_trail_im.clear_surfaces()
	if _trail_points.size() < 2:
		return
	_trail_im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	var n := _trail_points.size()
	for i in n:
		var t := float(i) / float(n - 1)
		var c := TRAIL_TINT
		c.a = TRAIL_TINT.a * t
		_trail_im.surface_set_color(c)
		_trail_im.surface_add_vertex(_trail_points[i])
	_trail_im.surface_end()

func _on_body_entered(body: Node) -> void:
	if _despawning or body == shooter:
		return
	if body.has_method("take_damage"):
		body.take_damage(damage, direction)
		if source_weapon != null and is_instance_valid(source_weapon) and source_weapon.has_method("add_super_charge"):
			source_weapon.add_super_charge(float(damage))
	Vfx.impact_burst(global_position, 0.9, Color(1, 0.45, 0.95, 1))
	_despawn()

func _despawn() -> void:
	if _despawning:
		return
	_despawning = true
	# Called from physics signals — must defer both monitoring change and
	# reparent/free, otherwise the physics server is mid-iteration.
	set_deferred("monitoring", false)
	if pooled:
		ProjectilePool.call_deferred("release", self)
	else:
		queue_free()
