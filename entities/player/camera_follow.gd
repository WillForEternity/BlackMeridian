extends Camera3D

# Camera is parented under the player's CameraPitchPivot; positioning is driven
# by the scene tree and by direct writes from player.gd (view-mode toggle).
# This script only adds trauma-based screen shake as a per-frame delta on top
# of whatever transform anyone else has set.

@export var trauma_decay: float = 1.6
@export var max_shake_offset: float = 0.45
@export var max_shake_roll_deg: float = 5.0

var trauma: float = 0.0
var _noise := FastNoiseLite.new()
var _noise_t: float = 0.0
var _prev_shake_off: Vector3 = Vector3.ZERO
var _prev_shake_rz: float = 0.0

func _ready() -> void:
	_noise.frequency = 2.0
	_noise.seed = randi()

func add_trauma(amount: float) -> void:
	# Diminishing returns so rapid-fire weapons can't keep trauma pegged at 1.0.
	# Each add only fills (1 - trauma) of the remaining headroom — a single
	# heavy hit at low trauma still lands at near-full strength, but spammed
	# light hits settle to a calm steady state instead of sustained thrashing.
	trauma = clampf(trauma + amount * (1.0 - trauma), 0.0, 1.0)

func _process(delta: float) -> void:
	# Undo last frame's shake delta first so external position writes win.
	position -= _prev_shake_off
	rotation.z -= _prev_shake_rz
	_prev_shake_off = Vector3.ZERO
	_prev_shake_rz = 0.0
	if trauma <= 0.0:
		return
	trauma = maxf(trauma - trauma_decay * delta, 0.0)
	var shake := trauma * trauma
	_noise_t += delta * 30.0
	var ox := _noise.get_noise_2d(_noise_t, 0.0) * shake * max_shake_offset
	var oy := _noise.get_noise_2d(0.0, _noise_t) * shake * max_shake_offset
	var rz := deg_to_rad(_noise.get_noise_2d(_noise_t, _noise_t) * shake * max_shake_roll_deg)
	_prev_shake_off = Vector3(ox, oy, 0.0)
	_prev_shake_rz = rz
	position += _prev_shake_off
	rotation.z += _prev_shake_rz
