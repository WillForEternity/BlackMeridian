extends CharacterBody3D

# Lightweight visual + hurtbox stand-in for another player. Driven by pose
# RPCs from the owning peer — we lerp toward the target each frame so the
# 20 Hz network rate doesn't visibly snap. Carries a CharacterBody3D capsule
# so the local sword scan and bullet Area3D detect it; take_damage() forwards
# the hit back to the owning peer over the relay, which applies HP on their
# authoritative copy.

const SMOOTHING: float = 14.0
const BODY_HEIGHT: float = 2.0
const BODY_RADIUS: float = 0.4
const WEAPON_NAMES := ["Sword", "Gun", "Sniper", "Light Portal", "Dark Portal"]

var _peer_id: int = 0
var _body: MeshInstance3D
var _label: Label3D
var _target_position: Vector3
var _target_yaw: float = 0.0
var _current_slot: int = -1
var _has_first_pose: bool = false

func setup(peer_id: int) -> void:
	_peer_id = peer_id
	name = "Puppet_%d" % peer_id

func _ready() -> void:
	# Hurtbox layer 1, mask 0: detectable by the local sword/bullets but
	# doesn't push the local player around physically.
	collision_layer = 1
	collision_mask = 0
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = BODY_RADIUS
	cap.height = BODY_HEIGHT
	shape.shape = cap
	shape.position = Vector3(0, BODY_HEIGHT * 0.5, 0)
	add_child(shape)

	var capsule := CapsuleMesh.new()
	capsule.radius = BODY_RADIUS
	capsule.height = BODY_HEIGHT
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.55, 0.35)
	mat.emission_enabled = true
	mat.emission = Color(0.6, 0.3, 0.15)
	mat.emission_energy_multiplier = 0.25
	capsule.material = mat
	_body = MeshInstance3D.new()
	_body.mesh = capsule
	_body.position = Vector3(0, BODY_HEIGHT * 0.5, 0)
	add_child(_body)

	_label = Label3D.new()
	_label.position = Vector3(0, BODY_HEIGHT + 0.4, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.font_size = 28
	_label.outline_size = 8
	_label.modulate = Color(1.0, 0.85, 0.7)
	add_child(_label)
	_refresh_label()

func set_pose(pos: Vector3, yaw: float, slot: int) -> void:
	_target_position = pos
	_target_yaw = yaw
	if not _has_first_pose:
		_has_first_pose = true
		global_position = pos
		rotation.y = yaw
	if slot != _current_slot:
		_current_slot = slot
		_refresh_label()

func _refresh_label() -> void:
	if _label == null:
		return
	var slot_name: String = ""
	if _current_slot >= 0 and _current_slot < WEAPON_NAMES.size():
		slot_name = " — " + WEAPON_NAMES[_current_slot]
	_label.text = "Peer %d%s" % [_peer_id, slot_name]

func _process(delta: float) -> void:
	if not _has_first_pose:
		return
	var t: float = clampf(SMOOTHING * delta, 0.0, 1.0)
	global_position = global_position.lerp(_target_position, t)
	var diff: float = wrapf(_target_yaw - rotation.y, -PI, PI)
	rotation.y += diff * t

# Hit from a local weapon (sword scan / projectile). Forward to the owning
# peer over the relay; their player.gd::take_damage applies HP + flinch
# authoritatively on their side. We don't decrement anything locally — the
# puppet has no HP of its own (HP lives on the owning peer's local player).
func take_damage(amount: int, direction: Vector3) -> void:
	Network.send_message({
		"type": "damage",
		"target": _peer_id,
		"amount": amount,
		"dir": [direction.x, direction.y, direction.z],
	})
