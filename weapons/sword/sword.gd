extends "res://weapons/weapon.gd"

@export var rig_tpv_path: NodePath
@export var rig_fpv_path: NodePath
@export var hit_area_path: NodePath
@export var tip_marker_tpv_path: NodePath
@export var tip_marker_fpv_path: NodePath
@export var damage: int = 2

@onready var rig_tpv: Node3D = get_node(rig_tpv_path)
@onready var rig_fpv: Node3D = get_node(rig_fpv_path)
@onready var hit_area: Area3D = get_node(hit_area_path)
@onready var tip_tpv: Marker3D = get_node(tip_marker_tpv_path)
@onready var tip_fpv: Marker3D = get_node(tip_marker_fpv_path)

const COMBO_WINDOW: float = 0.55
const COMBO_COUNT: int = 3
const TRAIL_SAMPLES: int = 14

# Rest pose: blade tipped +45° up-forward at right hip (chudan-ish low guard).
const REST_ROT_TPV := Vector3(PI / 4.0, 0.0, 0.0)
const REST_POS_TPV := Vector3.ZERO
const REST_ROT_FPV := Vector3.ZERO
const REST_POS_FPV := Vector3.ZERO

var _hits_this_swing: Array = []
var _combo_index: int = 0
var _combo_window_left: float = 0.0

var _trail_active: bool = false
var _trail_points: Array[Vector3] = []
var _trail_t_left: float = 0.0
var _trail_decay_accum: float = 0.0
var _trail_mi: MeshInstance3D
var _trail_im: ImmediateMesh
var _trail_mat: StandardMaterial3D
var _active_swing_tween: Tween

const TRAIL_DECAY_INTERVAL: float = 1.0 / 33.0  # seconds between trail point drops

func _ready() -> void:
	super()
	hit_area.monitoring = false
	hit_area.body_entered.connect(_on_body_entered)
	_setup_trail()
	rig_tpv.rotation = REST_ROT_TPV
	rig_tpv.position = REST_POS_TPV
	rig_fpv.rotation = REST_ROT_FPV
	rig_fpv.position = REST_POS_FPV

func cooldown() -> float:
	return data.cooldown if data else 0.42

func _damage() -> int:
	return data.damage if data else damage

func equip() -> void:
	rig_tpv.visible = true
	rig_fpv.visible = true

func unequip() -> void:
	# Kill any in-flight swing tween and force the hit area off, otherwise an
	# interrupted swing leaves the hitbox monitoring (invisible damage).
	if _active_swing_tween and _active_swing_tween.is_valid():
		_active_swing_tween.kill()
	_active_swing_tween = null
	hit_area.monitoring = false
	rig_tpv.visible = false
	rig_fpv.visible = false

func on_attack_pressed() -> void:
	if attack_cd > 0.0:
		return
	_swing()

func tick(delta: float) -> void:
	_combo_window_left = maxf(_combo_window_left - delta, 0.0)
	if not _trail_active:
		return
	var marker: Marker3D = tip_fpv if is_fpv() else tip_tpv
	if hit_area.monitoring:
		_sample_trail(marker)
		_trail_t_left = 0.18
		_trail_decay_accum = 0.0
	_trail_t_left = maxf(_trail_t_left - delta, 0.0)
	if not hit_area.monitoring and _trail_points.size() >= 4:
		# Frame-rate independent: drop one pair every TRAIL_DECAY_INTERVAL sec.
		_trail_decay_accum += delta
		while _trail_decay_accum >= TRAIL_DECAY_INTERVAL and _trail_points.size() >= 4:
			_trail_decay_accum -= TRAIL_DECAY_INTERVAL
			_trail_points.remove_at(0)
			_trail_points.remove_at(0)
	_rebuild_trail()
	if _trail_t_left <= 0.0 and not hit_area.monitoring:
		_trail_active = false
		_trail_points.clear()
		if _trail_im:
			_trail_im.clear_surfaces()

func _swing() -> void:
	attack_cd = cooldown()
	_hits_this_swing.clear()

	if _combo_window_left <= 0.0:
		_combo_index = 0
	else:
		_combo_index = (_combo_index + 1) % COMBO_COUNT
	_combo_window_left = COMBO_WINDOW

	var data := _combo_data(_combo_index)
	_tween_keyframes(rig_tpv, data.keyframes, REST_ROT_TPV, REST_POS_TPV, true)
	_tween_keyframes(rig_fpv, data.keyframes, REST_ROT_FPV, REST_POS_FPV, false)

	var marker: Marker3D = tip_fpv if is_fpv() else tip_tpv
	var tint: Color = data.tint
	var strike_start: float = data.strike_start
	var strike_end: float = data.strike_end

	if _active_swing_tween and _active_swing_tween.is_valid():
		_active_swing_tween.kill()
	_active_swing_tween = create_tween()
	_active_swing_tween.tween_interval(strike_start)
	_active_swing_tween.tween_callback(func():
		hit_area.monitoring = true
		_begin_trail(tint)
	)
	_active_swing_tween.tween_interval(strike_end - strike_start)
	_active_swing_tween.tween_callback(func():
		hit_area.monitoring = false
		_trail_t_left = 0.18
	)

# Three-strike combo; chains within COMBO_WINDOW. Each keyframe is a rot/pos
# offset from rest with its own dur/trans/ease. Phases: chamber → tip-lag →
# accelerate → cleave → settle. strike_start/strike_end mark the contact window.
#   0: rising diagonal — bottom-left → top-right
#   1: horizontal      — right → left (chest height)
#   2: falling diagonal — top-left → bottom-right
func _combo_data(idx: int) -> Dictionary:
	match idx:
		0:
			return {
				"tint": Color(0.55, 0.95, 1.0, 1.0),
				"strike_start": 0.20,
				"strike_end": 0.34,
				"keyframes": [
					{"rot": Vector3(deg_to_rad(-135.0), deg_to_rad(30.0), deg_to_rad(-25.0)), "pos": Vector3(-0.80, -0.25, 0.05), "dur": 0.16, "trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(-145.0), deg_to_rad(35.0), deg_to_rad(-30.0)), "pos": Vector3(-0.82, -0.27, 0.05), "dur": 0.05, "trans": Tween.TRANS_LINEAR, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(-30.0), 0.0, 0.0), "pos": Vector3(-0.15, 0.12, -0.15), "dur": 0.06, "trans": Tween.TRANS_CUBIC, "ease": Tween.EASE_IN},
					{"rot": Vector3(deg_to_rad(45.0), deg_to_rad(25.0), deg_to_rad(25.0)), "pos": Vector3(0.55, 0.50, -0.18), "dur": 0.10, "trans": Tween.TRANS_EXPO, "ease": Tween.EASE_OUT},
					{"rot": Vector3.ZERO, "pos": Vector3.ZERO, "dur": 0.32, "trans": Tween.TRANS_QUART, "ease": Tween.EASE_OUT},
				],
			}
		1:
			return {
				"tint": Color(0.75, 0.85, 1.0, 1.0),
				"strike_start": 0.16,
				"strike_end": 0.30,
				"keyframes": [
					{"rot": Vector3(deg_to_rad(-45.0), deg_to_rad(95.0), deg_to_rad(15.0)), "pos": Vector3(0.25, 0.25, 0.10), "dur": 0.13, "trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(-45.0), deg_to_rad(100.0), deg_to_rad(20.0)), "pos": Vector3(0.27, 0.25, 0.08), "dur": 0.04, "trans": Tween.TRANS_LINEAR, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(-45.0), 0.0, 0.0), "pos": Vector3(0.0, 0.25, -0.20), "dur": 0.05, "trans": Tween.TRANS_CUBIC, "ease": Tween.EASE_IN},
					{"rot": Vector3(deg_to_rad(-45.0), deg_to_rad(-105.0), deg_to_rad(-20.0)), "pos": Vector3(-0.55, 0.25, -0.10), "dur": 0.09, "trans": Tween.TRANS_EXPO, "ease": Tween.EASE_OUT},
					{"rot": Vector3.ZERO, "pos": Vector3.ZERO, "dur": 0.30, "trans": Tween.TRANS_QUART, "ease": Tween.EASE_OUT},
				],
			}
		_:
			return {
				"tint": Color(0.9, 0.7, 1.0, 1.0),
				"strike_start": 0.16,
				"strike_end": 0.30,
				"keyframes": [
					{"rot": Vector3(deg_to_rad(45.0), deg_to_rad(-25.0), deg_to_rad(-25.0)), "pos": Vector3(-0.75, 0.50, -0.05), "dur": 0.16, "trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(55.0), deg_to_rad(-30.0), deg_to_rad(-30.0)), "pos": Vector3(-0.78, 0.52, -0.05), "dur": 0.05, "trans": Tween.TRANS_LINEAR, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(-30.0), 0.0, 0.0), "pos": Vector3(-0.10, 0.12, -0.18), "dur": 0.06, "trans": Tween.TRANS_CUBIC, "ease": Tween.EASE_IN},
					{"rot": Vector3(deg_to_rad(-135.0), deg_to_rad(-30.0), deg_to_rad(25.0)), "pos": Vector3(0.55, -0.30, 0.05), "dur": 0.10, "trans": Tween.TRANS_EXPO, "ease": Tween.EASE_OUT},
					{"rot": Vector3.ZERO, "pos": Vector3.ZERO, "dur": 0.34, "trans": Tween.TRANS_QUART, "ease": Tween.EASE_OUT},
				],
			}

func _tween_keyframes(rig: Node3D, kfs: Array, rest_rot: Vector3, rest_pos: Vector3, animate_pos: bool) -> void:
	var tr := create_tween()
	var tp: Tween = create_tween() if animate_pos else null
	for kf in kfs:
		var dur: float = kf.dur
		var trans: int = kf.trans
		var ease: int = kf.ease
		tr.tween_property(rig, "rotation", rest_rot + kf.rot, dur).set_trans(trans).set_ease(ease)
		if tp:
			tp.tween_property(rig, "position", rest_pos + kf.pos, dur).set_trans(trans).set_ease(ease)

func _on_body_entered(body: Node) -> void:
	if body == player:
		return
	if body in _hits_this_swing:
		return
	_hits_this_swing.append(body)
	if not body.has_method("take_damage"):
		return
	var body3d := body as Node3D
	var dir: Vector3 = Vector3.ZERO
	if body3d != null:
		dir = (body3d.global_position - player.global_position).normalized()
	body.take_damage(_damage(), dir)
	if body3d != null:
		Vfx.impact_burst(body3d.global_position + Vector3(0, 0.4, 0), 0.7, Color(0.5, 0.95, 1, 1))
	player.register_hit(0.4)

func _setup_trail() -> void:
	_trail_mi = MeshInstance3D.new()
	_trail_im = ImmediateMesh.new()
	_trail_mi.mesh = _trail_im
	_trail_mat = StandardMaterial3D.new()
	_trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_trail_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_trail_mat.vertex_color_use_as_albedo = true
	_trail_mat.albedo_color = Color(1, 1, 1, 1)
	_trail_mat.emission_enabled = true
	_trail_mat.emission = Color(0.55, 0.95, 1, 1)
	_trail_mat.emission_energy_multiplier = 6.0
	_trail_mi.material_override = _trail_mat
	_trail_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child.call_deferred(_trail_mi)

func _begin_trail(tint: Color) -> void:
	_trail_points.clear()
	_trail_active = true
	_trail_t_left = 0.0
	if _trail_mat:
		_trail_mat.emission = tint

func _sample_trail(marker: Marker3D) -> void:
	if marker == null:
		return
	var tip: Vector3 = marker.global_position
	var rig: Node3D = rig_fpv if is_fpv() else rig_tpv
	var hilt: Vector3 = rig.global_position
	_trail_points.append(tip)
	_trail_points.append(hilt)
	while _trail_points.size() > TRAIL_SAMPLES * 2:
		_trail_points.remove_at(0)

func _rebuild_trail() -> void:
	if _trail_im == null:
		return
	_trail_im.clear_surfaces()
	var pair_count: int = _trail_points.size() / 2
	if pair_count < 2:
		return
	_trail_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(pair_count - 1):
		var t0: float = float(i) / float(pair_count - 1)
		var t1: float = float(i + 1) / float(pair_count - 1)
		var a0: float = pow(t0, 1.4)
		var a1: float = pow(t1, 1.4)
		var p0a: Vector3 = _trail_points[i * 2]
		var p0b: Vector3 = _trail_points[i * 2 + 1]
		var p1a: Vector3 = _trail_points[(i + 1) * 2]
		var p1b: Vector3 = _trail_points[(i + 1) * 2 + 1]
		_trail_im.surface_set_color(Color(1, 1, 1, a0))
		_trail_im.surface_add_vertex(p0a)
		_trail_im.surface_set_color(Color(1, 1, 1, a0))
		_trail_im.surface_add_vertex(p0b)
		_trail_im.surface_set_color(Color(1, 1, 1, a1))
		_trail_im.surface_add_vertex(p1b)

		_trail_im.surface_set_color(Color(1, 1, 1, a0))
		_trail_im.surface_add_vertex(p0a)
		_trail_im.surface_set_color(Color(1, 1, 1, a1))
		_trail_im.surface_add_vertex(p1b)
		_trail_im.surface_set_color(Color(1, 1, 1, a1))
		_trail_im.surface_add_vertex(p1a)
	_trail_im.surface_end()
