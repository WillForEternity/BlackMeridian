extends "res://weapons/weapon.gd"

@export var rig_tpv_path: NodePath
@export var rig_fpv_path: NodePath
@export var muzzle_tpv_path: NodePath
@export var muzzle_fpv_path: NodePath

@onready var rig_tpv: Node3D = get_node(rig_tpv_path)
@onready var rig_fpv: Node3D = get_node(rig_fpv_path)
@onready var muzzle_tpv: Marker3D = get_node(muzzle_tpv_path)
@onready var muzzle_fpv: Marker3D = get_node(muzzle_fpv_path)

const SUPER_MODE_DURATION: float = 6.0
const SUPER_SPREAD_DEG: float = 4.0

var _super_mode_left: float = 0.0

func _ready() -> void:
	super()

func cooldown() -> float:
	return (data.cooldown if data else 0.165) * 0.5

func guide_text() -> String:
	return "PLASMA\n\nATTACK (LMB)\n  Semi-auto projectile, ~0.165s between shots. 2 dmg per hit.\n  Bullets are pooled and travel along the camera ray.\n\nSUPER (Q, when bar is full)\n  Overdrive for 6 seconds: every trigger pull fires a 3-round\n  spread (center + two shots at ~4 degree offset). Muzzle\n  tint shifts from pink to a hotter orange while active.\n\nQUIRK\n  Each projectile feeds super charge equal to its damage, so\n  the plasma gun ramps its own super faster than weapons\n  that hit less often.\n\n[G] toggles this guide."

func equip() -> void:
	rig_tpv.visible = true
	rig_fpv.visible = true

func unequip() -> void:
	rig_tpv.visible = false
	rig_fpv.visible = false
	rig_tpv.rotation = Vector3.ZERO
	rig_fpv.rotation = Vector3.ZERO

func on_super_pressed() -> void:
	if not super_ready():
		return
	if not consume_super():
		return
	_super_mode_left = SUPER_MODE_DURATION
	player.punch_fov(8.0, 0.08, 0.3)

func tick(delta: float) -> void:
	if _super_mode_left > 0.0:
		_super_mode_left = maxf(_super_mode_left - delta, 0.0)
	# The TPV rig used to look_at(aim_point) every tick so the muzzle visually
	# tracked the crosshair, but with the rig now bone-attached to hand_r that
	# fought the body animation (gun rotation snapped to camera while the
	# hand swung naturally) and the calibration panel couldn't show a stable
	# pose. Bullets still fire toward the crosshair via player.get_aim_point()
	# in _fire(), so visually the muzzle leads from wherever the hand points
	# while the projectile lands where the camera is pointed.

func on_attack_pressed() -> void:
	if attack_cd > 0.0:
		return
	_fire()

func _fire() -> void:
	attack_cd = cooldown()
	var aim: Vector3 = player.get_aim_point()
	var spawn_marker: Marker3D = muzzle_fpv if _is_fpv else muzzle_tpv
	var fire_dir := (aim - spawn_marker.global_position).normalized()
	var super_mode := _super_mode_left > 0.0
	var tint := Color(1, 0.6, 0.2, 1) if super_mode else Color(1, 0.45, 0.95, 1)
	if super_mode:
		var spread := deg_to_rad(SUPER_SPREAD_DEG)
		_spawn_bullet(spawn_marker.global_position, fire_dir)
		_spawn_bullet(spawn_marker.global_position, _rotate_axis(fire_dir, Vector3.UP, spread))
		_spawn_bullet(spawn_marker.global_position, _rotate_axis(fire_dir, Vector3.UP, -spread))
	else:
		_spawn_bullet(spawn_marker.global_position, fire_dir)
	# Muzzle-flash sphere + brass-puff sphere removed — they read as floating
	# circles on every shot. Recoil + animation kick still convey the fire.
	_recoil(rig_fpv)
	# Gun fires too fast to add camera trauma per shot — even with the
	# diminishing-returns curve, sustained fire accumulates noticeable shake.
	# Pass 0 so hitstop still punches but the camera doesn't ramp up.
	player.register_hit(0.0)
	# Drive the body's Pistol_Shoot clip so the arms kick on each shot.
	# Locked at clip length × 0.6 so rapid-fire still gets a fresh kick.
	if player and player.has_method("play_anim_locked"):
		player.play_anim_locked("Pistol_Shoot", cooldown() * 0.9, 1.4)

func _spawn_bullet(at: Vector3, dir: Vector3) -> void:
	var bullet: Node = ProjectilePool.acquire(get_tree().current_scene)
	bullet.global_position = at
	bullet.set_direction(dir)
	bullet.shooter = player
	bullet.source_weapon = self

func _rotate_axis(v: Vector3, axis: Vector3, angle: float) -> Vector3:
	return v.rotated(axis.normalized(), angle)

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
