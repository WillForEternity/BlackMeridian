extends "res://weapons/weapon.gd"

# charge_changed is declared on the Weapon base class — no redeclare here.

@export var rig_tpv_path: NodePath
@export var rig_fpv_path: NodePath
@export var muzzle_tpv_path: NodePath
@export var muzzle_fpv_path: NodePath
@export var core_path: NodePath
@export var prong_l_tpv_path: NodePath
@export var prong_r_tpv_path: NodePath
@export var prong_l_fpv_path: NodePath
@export var prong_r_fpv_path: NodePath

@export var charge_time: float = 1.0
@export var damage: int = 12

@onready var rig_tpv: Node3D = get_node(rig_tpv_path)
@onready var rig_fpv: Node3D = get_node(rig_fpv_path)
@onready var muzzle_tpv: Marker3D = get_node(muzzle_tpv_path)
@onready var muzzle_fpv: Marker3D = get_node(muzzle_fpv_path)
@onready var core: MeshInstance3D = get_node(core_path)
@onready var prong_l_tpv: MeshInstance3D = get_node(prong_l_tpv_path)
@onready var prong_r_tpv: MeshInstance3D = get_node(prong_r_tpv_path)
@onready var prong_l_fpv: MeshInstance3D = get_node(prong_l_fpv_path)
@onready var prong_r_fpv: MeshInstance3D = get_node(prong_r_fpv_path)

const FOV_PUNCH := 14.0
const PRONG_REST_X := 0.07
const PRONG_CONVERGE_X := 0.012
const CORE_REST_EMISSION := 1.4
const CORE_PEAK_EMISSION := 12.0

var _charging: bool = false
var _charge_t: float = 0.0
# Seconds remaining while the railgun tracer is still visible after firing.
# Matches the longest beam-layer life in Vfx.tracer_beam (0.55s).
const TRAIL_LIFE: float = 0.55
var _trail_lock_left: float = 0.0
var _core_mat: StandardMaterial3D
var _laser_dot: MeshInstance3D

func _ready() -> void:
	super()
	_core_mat = core.get_surface_override_material(0) as StandardMaterial3D
	_create_laser_dot()

func cooldown() -> float:
	return data.cooldown if data else 0.65

func equip() -> void:
	rig_tpv.visible = true
	rig_fpv.visible = true

func unequip() -> void:
	cancel_charge()
	_trail_lock_left = 0.0
	rig_tpv.visible = false
	rig_fpv.visible = false
	rig_tpv.rotation = Vector3.ZERO
	rig_fpv.rotation = Vector3.ZERO

func tick(delta: float) -> void:
	if not _is_fpv and rig_tpv.visible:
		var aim: Vector3 = player.get_aim_point()
		var to_aim := aim - rig_tpv.global_position
		if to_aim.length_squared() > 0.04:
			var up := Vector3.UP
			if absf(to_aim.normalized().dot(up)) > 0.99:
				up = Vector3(0, 0, -1)
			rig_tpv.look_at(aim, up)
	if _charging:
		_charge_t = minf(_charge_t + delta, charge_time)
		_update_charge_visuals()
	if _trail_lock_left > 0.0:
		_trail_lock_left = maxf(_trail_lock_left - delta, 0.0)

# Player consults this to freeze movement while charging or while the tracer
# is still on-screen.
func locks_movement() -> bool:
	return _charging or _trail_lock_left > 0.0

func on_attack_pressed() -> void:
	if attack_cd > 0.0 or _charging:
		return
	_charging = true
	_charge_t = 0.0

func on_attack_released() -> void:
	if not _charging:
		return
	var c := _charge_t / charge_time
	_end_charge_visuals()
	_charging = false
	_charge_t = 0.0
	_fire(c)

func cancel_charge() -> void:
	if not _charging:
		return
	_charging = false
	_charge_t = 0.0
	_end_charge_visuals()

func _update_charge_visuals() -> void:
	var c := _charge_t / charge_time
	if _core_mat:
		_core_mat.emission_energy_multiplier = lerp(CORE_REST_EMISSION, CORE_PEAK_EMISSION, c)
	var px: float = lerpf(PRONG_REST_X, PRONG_CONVERGE_X, c)
	prong_l_tpv.position.x = -px
	prong_r_tpv.position.x = px
	prong_l_fpv.position.x = -px
	prong_r_fpv.position.x = px
	player.camera.fov = lerp(player.base_fov, player.base_fov - FOV_PUNCH, c)
	var aim: Vector3 = player.get_aim_point()
	if _laser_dot:
		_laser_dot.global_position = aim
		_laser_dot.scale = Vector3.ONE * (0.5 + c * 1.6)
		_laser_dot.visible = true
	if c > 0.3:
		var pl := prong_l_fpv if _is_fpv else prong_l_tpv
		var pr := prong_r_fpv if _is_fpv else prong_r_tpv
		var arc_chance := pow(c, 1.8) * 0.55
		if randf() < arc_chance:
			Vfx.arc_lightning(pl.global_position, pr.global_position, c)
	charge_changed.emit(c)

func _end_charge_visuals() -> void:
	if _core_mat:
		_core_mat.emission_energy_multiplier = CORE_REST_EMISSION
	prong_l_tpv.position.x = -PRONG_REST_X
	prong_r_tpv.position.x = PRONG_REST_X
	prong_l_fpv.position.x = -PRONG_REST_X
	prong_r_fpv.position.x = PRONG_REST_X
	player.camera.fov = player.base_fov
	if _laser_dot:
		_laser_dot.visible = false
	charge_changed.emit(0.0)

func _fire(charge01: float) -> void:
	attack_cd = cooldown()
	var spawn_marker: Marker3D = muzzle_fpv if _is_fpv else muzzle_tpv
	var hit := _hitscan()
	var aim: Vector3 = player.get_aim_point()
	var end: Vector3 = aim
	var hit_body: Node = null
	if not hit.is_empty():
		end = hit.position
		hit_body = hit.collider
	var dmg := int(round(float(damage) * lerp(0.35, 1.0, charge01)))
	var dir := (end - spawn_marker.global_position).normalized()
	if hit_body and hit_body.has_method("take_damage"):
		hit_body.take_damage(dmg, dir)
	Vfx.tracer_beam(spawn_marker.global_position, end, charge01)
	_trail_lock_left = TRAIL_LIFE
	Vfx.muzzle_flash(spawn_marker.global_position, 1.1 + charge01 * 0.4, Color(0.4, 0.95, 1, 1))
	Vfx.impact_burst(end, 1.0 + charge01 * 0.6, Color(0.4, 0.95, 1, 1))
	_recoil(rig_fpv)
	player.punch_fov(-6.0, 0.06, 0.28)
	if charge01 >= 0.95:
		player.register_hit_heavy()
	else:
		player.register_hit(0.5)

func _recoil(rig: Node3D) -> void:
	var t := create_tween()
	var base_pos := rig.position
	t.tween_property(rig, "position", base_pos + Vector3(0, 0.05, 0.42), 0.06).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(rig, "position", base_pos, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _hitscan() -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return {}
	var center := get_viewport().get_visible_rect().size * 0.5
	var from := cam.project_ray_origin(center)
	var dir := cam.project_ray_normal(center)
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 250.0)
	query.exclude = [player.get_rid()]
	# world (1) | enemies (4) — must hit both terrain and targets.
	query.collision_mask = 1 | 4
	return space.intersect_ray(query)

func _create_laser_dot() -> void:
	_laser_dot = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.045
	sm.height = 0.09
	sm.radial_segments = 10
	sm.rings = 5
	_laser_dot.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0.18, 0.18, 1)
	mat.emission_enabled = true
	mat.emission = Color(1, 0.2, 0.2, 1)
	mat.emission_energy_multiplier = 7.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_laser_dot.set_surface_override_material(0, mat)
	_laser_dot.visible = false
	get_tree().current_scene.add_child.call_deferred(_laser_dot)
