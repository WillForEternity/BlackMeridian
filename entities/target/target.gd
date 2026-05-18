extends AnimatableBody3D

@export var max_health: int = 6
@export var respawn_delay: float = 5.0
# Sinusoidal patrol — set move_radius > 0 to make the target oscillate along
# move_axis around its spawn position. Hit-punches and supers (which run a
# tween on `position`) temporarily suspend the patrol so they don't fight.
@export var move_radius: float = 0.0
@export var move_speed: float = 0.0  # cycles/sec ≈ how fast it slides side to side
@export var move_axis: Vector3 = Vector3(1, 0, 0)

var _move_t: float = 0.0

var health: int
var _orig_scale: Vector3
var _orig_position: Vector3
var _orig_rotation: Vector3
var _base_mat: StandardMaterial3D
var _flash_mat: StandardMaterial3D
var _dead: bool = false
var _active_tween: Tween
var _immobilized: bool = false

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

func _physics_process(delta: float) -> void:
	if _dead or _immobilized or move_radius <= 0.0 or move_speed <= 0.0:
		return
	# An active tween means a hit-punch is in progress and is animating
	# `position` directly — skip patrol updates until it finishes so we don't
	# stomp the tween.
	if _active_tween and _active_tween.is_valid():
		return
	_move_t += delta * move_speed * TAU
	var axis := move_axis
	if axis.length_squared() < 0.0001:
		axis = Vector3.RIGHT
	position = _orig_position + axis.normalized() * sin(_move_t) * move_radius

func take_damage(amount: int, dir: Vector3) -> void:
	if _dead:
		return
	health -= amount
	_flash()
	if not _immobilized:
		_punch(dir)
	if health <= 0:
		_die()

# Sword super: hoist the target into the air, spin it, then drop it back. While
# immobilized, normal hit-punch tweens are suppressed so the lift isn't fought.
func lift_immobilize(duration: float, height: float) -> void:
	if _dead:
		return
	_immobilized = true
	_kill_tween()
	var up_pos := _orig_position + Vector3(0, height, 0)
	# Rotation runs in parallel on its own tween; position uses the tracked
	# _active_tween so a later hit can _kill_tween() cleanly.
	var rot_tw := create_tween()
	rot_tw.tween_property(self, "rotation:y", _orig_rotation.y + TAU * 2.0, duration).set_trans(Tween.TRANS_LINEAR)
	_active_tween = create_tween()
	_active_tween.tween_property(self, "position", up_pos, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_active_tween.tween_interval(maxf(duration - 0.18 - 0.22, 0.0))
	_active_tween.tween_property(self, "position", _orig_position, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_active_tween.tween_callback(func():
		_immobilized = false
		if is_instance_valid(self):
			rotation = _orig_rotation
	)

# Sniper EMP super: instantaneous shove that *persists*. Target tweens out to
# the displaced spot and stays there — _orig_position is rewritten so future
# hit-punches return to the new rest. Only respawn restores the original spawn.
func push_back(dir: Vector3, distance: float, duration: float) -> void:
	if _dead:
		return
	_immobilized = true
	_kill_tween()
	var shove := dir
	shove.y = 0.0
	if shove.length() < 0.01:
		shove = Vector3.FORWARD
	shove = shove.normalized() * distance
	var new_rest := _orig_position + shove
	_active_tween = create_tween()
	_active_tween.tween_property(self, "position", new_rest, duration).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	_active_tween.tween_callback(func():
		_orig_position = new_rest
		_immobilized = false
	)

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
	# Patrolling targets must NOT have their position animated — the punch
	# would snap them from their current patrol offset back to the centre,
	# causing a visible jump. Squash/stretch alone is enough feedback.
	var patrolling: bool = move_radius > 0.0 and move_speed > 0.0
	if not patrolling:
		var nudge := dir.normalized() * 0.3
		nudge.y = 0.0
		_active_tween.tween_property(self, "position", _orig_position + nudge, 0.06)
	_active_tween.chain()
	_active_tween.tween_property(self, "scale", _orig_scale, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if not patrolling:
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
