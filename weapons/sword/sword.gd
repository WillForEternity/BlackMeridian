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
# FPV uses the same pitch baseline so combo keyframes (which are offsets from
# rest) resolve to the same total rotation in both views — otherwise e.g. a
# mid-strike kf.rot.x of -30° produces a forward-up blade in TPV but a
# downward-pointing blade in FPV.
const REST_ROT_TPV := Vector3(PI / 4.0, 0.0, 0.0)
const REST_POS_TPV := Vector3.ZERO
const REST_ROT_FPV := Vector3(PI / 4.0, 0.0, 0.0)
const REST_POS_FPV := Vector3.ZERO

var _hits_this_swing: Array = []
var _combo_index: int = 0
var _combo_window_left: float = 0.0
var _super_active: bool = false

var _trail_active: bool = false
var _trail_points: Array[Vector3] = []
var _trail_t_left: float = 0.0
var _trail_decay_accum: float = 0.0
var _trail_mi: MeshInstance3D
var _trail_im: ImmediateMesh
var _trail_mat: StandardMaterial3D
var _trail_tint: Color = Color(0.55, 0.95, 1, 1)
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

# Katana quirk: while equipped, the player dashes twice as often.
func dash_cooldown_mult() -> float:
	return 0.5

func guide_text() -> String:
	return "KATANA\n\nATTACK (LMB)\n  Three-strike combo: rising-L, rising-R, horizontal cleave.\n  Chain within 0.55s to keep the combo alive.\n  Damage scales 1x -> 1.5x -> 2x across the combo.\n\nDASH SLASH (CRIT)\n  Attacking while dashing crits: +50% damage, green trail,\n  and a misty wake hangs along the cut.\n\nSUPER (Q, when bar is full)\n  Corkscrew spin (~0.5s) that lifts you AND any caught target\n  into the air. Continuous re-hits at 4 dmg each. Counts as a\n  crit the entire time.\n\nQUIRK\n  Dash cooldown is HALVED while katana is equipped, so you\n  can reposition (and dash-crit) twice as often as with the\n  other weapons.\n\n[G] toggles this guide."

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
	if attack_cd > 0.0 or _super_active:
		return
	_swing()

func locks_movement() -> bool:
	return _super_active

# Crit conditions for the katana: mid-dash (dash-slash) or mid-super.
# Scales the blade length (rig Z-axis). The HitArea and tip marker are rig
# children, so reach + trail sample point grow with the visual blade.
# Spawns a soft, expanding, fading sphere at `at` to lay down a misty wake.
# Called each trail-sample tick during a crit slash so a trail of puffs hangs
# in the air along the cut.
func _emit_mist_puff(at: Vector3) -> void:
	var puff := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.32
	sphere.height = 0.64
	sphere.radial_segments = 14
	sphere.rings = 8
	puff.mesh = sphere
	puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(CRIT_TINT.r, CRIT_TINT.g, CRIT_TINT.b, 0.10)
	mat.emission_enabled = true
	mat.emission = CRIT_TINT
	mat.emission_energy_multiplier = 0.4
	# Soft edges: fade by view angle so spheres read as fog volumes, not solids.
	mat.rim_enabled = false
	puff.material_override = mat
	# Tiny jitter so successive puffs blend into a single continuous ribbon
	# of mist rather than visibly separate blobs.
	var jitter := Vector3(randf_range(-0.04, 0.04), randf_range(-0.03, 0.03), randf_range(-0.04, 0.04))
	get_tree().current_scene.add_child(puff)
	puff.global_position = at + jitter
	puff.scale = Vector3.ONE * 0.85
	var tw := create_tween().set_parallel(true)
	tw.tween_property(puff, "scale", Vector3.ONE * 1.8, 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(puff.queue_free)

func _set_blade_length_scale(z_scale: float) -> void:
	var s := Vector3(1.0, 1.0, z_scale)
	if rig_tpv:
		rig_tpv.scale = s
	if rig_fpv:
		rig_fpv.scale = s

func is_crit() -> bool:
	var dashing: bool = player != null and "dash_time_left" in player and player.dash_time_left > 0.0
	return dashing or _super_active

const SUPER_DURATION: float = 0.475
const SUPER_SPINS: float = 3.0
const SUPER_STRIKE_DAMAGE: int = 4
const SUPER_LIFT_HEIGHT: float = 1.2
const SUPER_REHIT_INTERVAL: float = 0.12

func on_super_pressed() -> void:
	if _super_active or not super_ready():
		return
	if not consume_super():
		return
	_do_super()

func _do_super() -> void:
	_super_active = true
	attack_cd = SUPER_DURATION + 0.2
	_hits_this_swing.clear()

	if _active_swing_tween and _active_swing_tween.is_valid():
		_active_swing_tween.kill()
	var rig: Node3D = rig_fpv if is_fpv() else rig_tpv
	var rest_rot: Vector3 = REST_ROT_FPV if is_fpv() else REST_ROT_TPV
	# Flatten the blade to horizontal (X=0) for the corkscrew so it sweeps
	# through targets sideways instead of tipped up.
	rig.rotation = Vector3.ZERO
	var spin := create_tween()
	spin.tween_property(rig, "rotation", Vector3(0, TAU * SUPER_SPINS, 0), SUPER_DURATION).set_trans(Tween.TRANS_LINEAR)
	spin.tween_callback(func(): rig.rotation = rest_rot)

	# Damage is dealt wherever the sword actually slashes: hit_area stays on
	# for the whole spin, and we periodically clear the hit list so the same
	# target can be struck once per rotation.
	hit_area.monitoring = true
	# Super counts as a crit (is_crit() returns true while _super_active).
	_begin_trail(CRIT_TINT)
	_set_blade_length_scale(1.5)
	_active_swing_tween = create_tween()
	var rehits: int = int(floor(SUPER_DURATION / SUPER_REHIT_INTERVAL))
	for i in rehits:
		_active_swing_tween.tween_interval(SUPER_REHIT_INTERVAL)
		_active_swing_tween.tween_callback(func(): _hits_this_swing.clear())
	_active_swing_tween.tween_interval(maxf(SUPER_DURATION - rehits * SUPER_REHIT_INTERVAL, 0.0))
	_active_swing_tween.tween_callback(func():
		hit_area.monitoring = false
		_trail_t_left = 0.18
		_super_active = false
		_set_blade_length_scale(1.0)
	)

	# Player rises through the duration.
	if player != null:
		player.lift_time_left = SUPER_DURATION
		player.lift_velocity_y = SUPER_LIFT_HEIGHT / SUPER_DURATION
		player.punch_fov(10.0, 0.12, SUPER_DURATION)
		if player.camera.has_method("add_trauma"):
			player.camera.add_trauma(0.6)

func tick(delta: float) -> void:
	_combo_window_left = maxf(_combo_window_left - delta, 0.0)
	if not _trail_active:
		return
	var marker: Marker3D = tip_fpv if is_fpv() else tip_tpv
	if hit_area.monitoring:
		_sample_trail(marker)
		_trail_t_left = 0.18
		_trail_decay_accum = 0.0
		if is_crit():
			_emit_mist_puff(marker.global_position)
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
	# Both rigs run the full position+rotation animation so the swing reads
	# the same in third- and first-person. FPVPivot is already scaled down in
	# the scene, so the offsets shrink appropriately for the closer camera.
	_tween_keyframes(rig_tpv, data.keyframes, REST_ROT_TPV, REST_POS_TPV, true)
	_tween_keyframes(rig_fpv, data.keyframes, REST_ROT_FPV, REST_POS_FPV, true)

	var marker: Marker3D = tip_fpv if is_fpv() else tip_tpv
	var base_tint: Color = data.tint
	var strike_start: float = data.strike_start
	var strike_end: float = data.strike_end

	if _active_swing_tween and _active_swing_tween.is_valid():
		_active_swing_tween.kill()
	_active_swing_tween = create_tween()
	_active_swing_tween.tween_interval(strike_start)
	_active_swing_tween.tween_callback(func():
		hit_area.monitoring = true
		# Tint is decided at strike-time: crit slashes (dash or super) all share
		# the unified crit color from the base weapon.
		var tint: Color = CRIT_TINT if is_crit() else base_tint
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
#   1: rising diagonal — bottom-right → top-left
#   2: powerful horizontal cleave — long left → right sweep at chest height
#
# Combos 0 and 1 mirror combo 2's broad-swing pacing (long chamber, fast
# extension, wide follow-through) but the rig position arcs diagonally and the
# blade pitches up as it sweeps, so the cut traces a true diagonal in screen
# space rather than reading as a vertical chop.
func _combo_data(idx: int) -> Dictionary:
	match idx:
		0:
			return {
				"tint": Color(0.55, 0.95, 1.0, 1.0),
				"strike_start": 0.20,
				"strike_end": 0.34,
				"keyframes": [
					# Chamber low-left: blade pitched down, tip yawed right, cocked across the body.
					{"rot": Vector3(deg_to_rad(-75.0), deg_to_rad(95.0), deg_to_rad(15.0)), "pos": Vector3(-0.65, -0.35, -0.20), "dur": 0.16, "trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT},
					# Tip-lag overextension just before release.
					{"rot": Vector3(deg_to_rad(-85.0), deg_to_rad(105.0), deg_to_rad(20.0)), "pos": Vector3(-0.70, -0.40, -0.22), "dur": 0.05, "trans": Tween.TRANS_LINEAR, "ease": Tween.EASE_OUT},
					# Mid-strike: blade extended forward at chest height, peak contact frame.
					{"rot": Vector3(deg_to_rad(-30.0), 0.0, 0.0), "pos": Vector3(0.0, 0.15, -0.60), "dur": 0.06, "trans": Tween.TRANS_CUBIC, "ease": Tween.EASE_IN},
					# Follow-through high-right: blade pitched up, tip yawed past the shoulder.
					{"rot": Vector3(deg_to_rad(15.0), deg_to_rad(-105.0), deg_to_rad(-20.0)), "pos": Vector3(0.65, 0.55, -0.20), "dur": 0.10, "trans": Tween.TRANS_EXPO, "ease": Tween.EASE_OUT},
					{"rot": Vector3.ZERO, "pos": Vector3.ZERO, "dur": 0.32, "trans": Tween.TRANS_QUART, "ease": Tween.EASE_OUT},
				],
			}
		1:
			# Mirror of combo 0: X positions flipped, Y/Z rotations flipped, pitch sweep identical.
			return {
				"tint": Color(0.75, 0.85, 1.0, 1.0),
				"strike_start": 0.16,
				"strike_end": 0.30,
				"keyframes": [
					{"rot": Vector3(deg_to_rad(-75.0), deg_to_rad(-95.0), deg_to_rad(-15.0)), "pos": Vector3(0.65, -0.35, -0.20), "dur": 0.16, "trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(-85.0), deg_to_rad(-105.0), deg_to_rad(-20.0)), "pos": Vector3(0.70, -0.40, -0.22), "dur": 0.05, "trans": Tween.TRANS_LINEAR, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(-30.0), 0.0, 0.0), "pos": Vector3(0.0, 0.15, -0.60), "dur": 0.06, "trans": Tween.TRANS_CUBIC, "ease": Tween.EASE_IN},
					{"rot": Vector3(deg_to_rad(15.0), deg_to_rad(105.0), deg_to_rad(20.0)), "pos": Vector3(-0.65, 0.55, -0.20), "dur": 0.10, "trans": Tween.TRANS_EXPO, "ease": Tween.EASE_OUT},
					{"rot": Vector3.ZERO, "pos": Vector3.ZERO, "dur": 0.32, "trans": Tween.TRANS_QUART, "ease": Tween.EASE_OUT},
				],
			}
		_:
			# Majestic left → right horizontal cleave. Blade stays flat (X = -45°
			# cancels rest tilt) and out in front of the player (Z always
			# negative) so it never carves through the player's torso.
			return {
				"tint": Color(1.0, 0.55, 0.75, 1.0),
				"strike_start": 0.26,
				"strike_end": 0.48,
				"keyframes": [
					{"rot": Vector3(deg_to_rad(-45.0), deg_to_rad(95.0), deg_to_rad(15.0)), "pos": Vector3(-0.70, 0.35, -0.30), "dur": 0.24, "trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(-45.0), deg_to_rad(105.0), deg_to_rad(20.0)), "pos": Vector3(-0.75, 0.37, -0.32), "dur": 0.06, "trans": Tween.TRANS_LINEAR, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(-45.0), 0.0, 0.0), "pos": Vector3(0.0, 0.35, -0.65), "dur": 0.07, "trans": Tween.TRANS_CUBIC, "ease": Tween.EASE_IN},
					{"rot": Vector3(deg_to_rad(-45.0), deg_to_rad(-105.0), deg_to_rad(-20.0)), "pos": Vector3(0.75, 0.35, -0.30), "dur": 0.15, "trans": Tween.TRANS_EXPO, "ease": Tween.EASE_OUT},
					{"rot": Vector3.ZERO, "pos": Vector3.ZERO, "dur": 0.40, "trans": Tween.TRANS_QUART, "ease": Tween.EASE_OUT},
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
	var dmg: int
	if _super_active:
		dmg = SUPER_STRIKE_DAMAGE
		if body.has_method("lift_immobilize"):
			body.lift_immobilize(SUPER_DURATION, SUPER_LIFT_HEIGHT)
	else:
		# Combo damage scaling: 1st = 1x, 2nd = 1.5x, 3rd = 2x (3x if dashing).
		var mult: float = 1.0
		if _combo_index == 1:
			mult = 1.5
		elif _combo_index == 2:
			mult = 2.0
		if player.dash_time_left > 0.0:
			mult *= 1.5
		dmg = int(round(float(_damage()) * mult))
	body.take_damage(dmg, dir)
	add_super_charge(float(dmg))
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
	_trail_tint = tint
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
		_trail_im.surface_set_color(Color(_trail_tint.r, _trail_tint.g, _trail_tint.b, a0))
		_trail_im.surface_add_vertex(p0a)
		_trail_im.surface_set_color(Color(_trail_tint.r, _trail_tint.g, _trail_tint.b, a0))
		_trail_im.surface_add_vertex(p0b)
		_trail_im.surface_set_color(Color(_trail_tint.r, _trail_tint.g, _trail_tint.b, a1))
		_trail_im.surface_add_vertex(p1b)

		_trail_im.surface_set_color(Color(_trail_tint.r, _trail_tint.g, _trail_tint.b, a0))
		_trail_im.surface_add_vertex(p0a)
		_trail_im.surface_set_color(Color(_trail_tint.r, _trail_tint.g, _trail_tint.b, a1))
		_trail_im.surface_add_vertex(p1b)
		_trail_im.surface_set_color(Color(_trail_tint.r, _trail_tint.g, _trail_tint.b, a1))
		_trail_im.surface_add_vertex(p1a)
	_trail_im.surface_end()
