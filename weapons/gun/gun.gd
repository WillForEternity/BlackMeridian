extends "res://weapons/weapon.gd"

@export var rig_tpv_path: NodePath
@export var rig_fpv_path: NodePath
@export var muzzle_tpv_path: NodePath
@export var muzzle_fpv_path: NodePath

@onready var rig_tpv: Node3D = get_node(rig_tpv_path)
@onready var rig_fpv: Node3D = get_node(rig_fpv_path)
@onready var muzzle_tpv: Marker3D = get_node(muzzle_tpv_path)
@onready var muzzle_fpv: Marker3D = get_node(muzzle_fpv_path)

func _ready() -> void:
	super()

func cooldown() -> float:
	return data.cooldown if data else 0.22

func equip() -> void:
	rig_tpv.visible = true
	rig_fpv.visible = true

func unequip() -> void:
	rig_tpv.visible = false
	rig_fpv.visible = false
	rig_tpv.rotation = Vector3.ZERO
	rig_fpv.rotation = Vector3.ZERO

func tick(_delta: float) -> void:
	# Only the third-person rig needs continuous aim-tracking; cached _is_fpv
	# is updated by the EventBus signal in the base class — no per-frame poll.
	if _is_fpv:
		return
	var aim: Vector3 = player.get_aim_point()
	var to_aim := aim - rig_tpv.global_position
	if to_aim.length_squared() <= 0.04:
		return
	var up := Vector3.UP
	if absf(to_aim.normalized().dot(up)) > 0.99:
		up = Vector3(0, 0, -1)
	rig_tpv.look_at(aim, up)

func on_attack_pressed() -> void:
	if attack_cd > 0.0:
		return
	_fire()

func _fire() -> void:
	attack_cd = cooldown()
	var aim: Vector3 = player.get_aim_point()
	var spawn_marker: Marker3D = muzzle_fpv if _is_fpv else muzzle_tpv
	var bullet: Node = ProjectilePool.acquire(get_tree().current_scene)
	bullet.global_position = spawn_marker.global_position
	bullet.set_direction(aim - spawn_marker.global_position)
	bullet.shooter = player
	var fire_dir := (aim - spawn_marker.global_position).normalized()
	Vfx.muzzle_flash_cross(spawn_marker.global_position, fire_dir, 0.9, Color(1, 0.45, 0.95, 1))
	Vfx.brass_puff(spawn_marker.global_position, fire_dir)
	_recoil(rig_fpv)
	player.register_hit(0.28)

func _recoil(rig: Node3D) -> void:
	var t := create_tween()
	t.set_parallel(true)
	var base_pos := rig.position
	var base_rot := rig.rotation
	t.tween_property(rig, "position", base_pos + Vector3(0, 0.015, 0.16), 0.045).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(rig, "rotation", base_rot + Vector3(deg_to_rad(-9.0), 0, 0), 0.045).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var t2 := create_tween()
	t2.tween_interval(0.05)
	t2.set_parallel(true)
	t2.tween_property(rig, "position", base_pos, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t2.tween_property(rig, "rotation", base_rot, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
