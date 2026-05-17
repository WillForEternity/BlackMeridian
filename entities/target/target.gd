extends StaticBody3D

@export var max_health: int = 6
@export var respawn_delay: float = 5.0

var health: int
var _orig_scale: Vector3
var _orig_position: Vector3
var _orig_rotation: Vector3
var _base_mat: StandardMaterial3D
var _flash_mat: StandardMaterial3D
var _dead: bool = false
var _active_tween: Tween

@onready var mesh: MeshInstance3D = $MeshInstance3D

func _ready() -> void:
	health = max_health
	_orig_scale = scale
	_orig_position = position
	_orig_rotation = rotation
	_base_mat = mesh.get_surface_override_material(0)
	_flash_mat = StandardMaterial3D.new()
	_flash_mat.albedo_color = Color(1, 1, 1, 1)
	_flash_mat.emission_enabled = true
	_flash_mat.emission = Color(1, 1, 1, 1)
	_flash_mat.emission_energy_multiplier = 2.0

func take_damage(amount: int, dir: Vector3) -> void:
	if _dead:
		return
	health -= amount
	_flash()
	_punch(dir)
	if health <= 0:
		_die()

func _flash() -> void:
	mesh.set_surface_override_material(0, _flash_mat)
	await get_tree().create_timer(0.07, true, false, true).timeout
	if is_instance_valid(self) and is_instance_valid(mesh) and not _dead:
		mesh.set_surface_override_material(0, _base_mat)

func _punch(dir: Vector3) -> void:
	_kill_tween()
	_active_tween = create_tween()
	_active_tween.set_parallel(true)
	_active_tween.tween_property(self, "scale", _orig_scale * Vector3(1.3, 0.8, 1.3), 0.06).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var nudge := dir.normalized() * 0.3
	nudge.y = 0.0
	_active_tween.tween_property(self, "position", _orig_position + nudge, 0.06)
	_active_tween.chain()
	_active_tween.tween_property(self, "scale", _orig_scale, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_active_tween.tween_property(self, "position", _orig_position, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

const _HIDDEN_SCALE := Vector3(0.001, 0.001, 0.001)

func _die() -> void:
	_dead = true
	collision_layer = 0
	_kill_tween()
	_active_tween = create_tween()
	_active_tween.tween_property(self, "scale", _HIDDEN_SCALE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	await _active_tween.finished
	if not is_instance_valid(self):
		return
	visible = false
	await get_tree().create_timer(respawn_delay, true, false, true).timeout
	if is_instance_valid(self):
		_respawn()

func _respawn() -> void:
	_kill_tween()
	position = _orig_position
	rotation = _orig_rotation
	scale = _HIDDEN_SCALE
	visible = true
	health = max_health
	collision_layer = 5
	mesh.set_surface_override_material(0, _base_mat)
	_dead = false
	_active_tween = create_tween()
	_active_tween.tween_property(self, "scale", _orig_scale, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _kill_tween() -> void:
	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()
