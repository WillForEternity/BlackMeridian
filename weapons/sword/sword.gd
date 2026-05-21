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

const COMBO_WINDOW: float = 1.0
const COMBO_MIN_GAP: float = 0.5
const COMBO_COUNT: int = 3
const TRAIL_SAMPLES: int = 14

# Rest pose: blade tipped +45° up-forward at right hip (chudan-ish low guard).
# FPV uses the same pitch baseline so combo keyframes (which are offsets from
# rest) resolve to the same total rotation in both views — otherwise e.g. a
# mid-strike kf.rot.x of -30° produces a forward-up blade in TPV but a
# downward-pointing blade in FPV.
const REST_ROT_TPV := Vector3(PI / 4.0, 0.0, 0.0)
# Push the TPV rig forward + slightly right of the player so the sword is
# clearly "held out" rather than hugging the body.
const REST_POS_TPV := Vector3(0.05, 0.0, -0.15)
const REST_ROT_FPV := Vector3(PI / 4.0, 0.0, 0.0)
# FPV rest is offset down + forward in SwordRig local space so the hilt sits
# below the eye-line rather than right in front of the camera. Extra +X and
# more -Z compared to before pushes the sword further out from the camera.
# The 1.538× SwordRig scale (in scene) cancels FPVPivot's 0.65× shrink, so
# these offsets are in pre-FPVPivot-scale units.
const REST_POS_FPV := Vector3(0.15, -0.5, -0.65)

var _hits_this_swing: Array = []
var _combo_index: int = 0
var _combo_window_left: float = 0.0
var _super_active: bool = false

var _trail_active: bool = false
var _trail_sampling: bool = false
var _trail_points: Array[Vector3] = []
var _trail_t_left: float = 0.0
var _trail_decay_accum: float = 0.0
var _trail_mi: MeshInstance3D
var _trail_im: ImmediateMesh
var _trail_mat: StandardMaterial3D
var _trail_tint: Color = Color(0.55, 0.95, 1, 1)
var _active_swing_tween: Tween
# Sticky crit latch: set true any time is_crit() is observed during the strike
# window, so a slash that overlaps a dash at any point spawns the crit FX even
# if the dash expires before strike_end fires.
var _swing_was_crit: bool = false

const TRAIL_DECAY_INTERVAL: float = 1.0 / 33.0  # seconds between trail point drops

# ── Katana idle-sheathe ──────────────────────────────────────────────────────
# After IDLE_SHEATHE_TIME of no swings while equipped, the rig tweens onto
# the saya on the player's left hip. Any swing or super yanks it back out.
const IDLE_SHEATHE_TIME: float = 5.0
const SHEATHE_TWEEN_IN: float = 0.65
const SHEATHE_TWEEN_OUT: float = 0.0
# Quick-draw flourish: when the player clicks while sheathed, the click
# *draws* the blade (no attack). A follow-up click within the next moment
# performs the actual swing. The draw animation has to be short enough that
# the second click feels responsive.
const DRAW_DURATION: float = 0.12
# TPV sheathed pose — rig glides toward the saya on the left hip. The rig is
# hidden at the end of the sheathe (and re-shown on unsheathe), so this pose
# only needs to roughly aim at the saya — it doesn't have to match perfectly.
const SHEATHE_POS_TPV := Vector3(-0.78, 0.15, 0.35)
const SHEATHE_ROT_TPV := Vector3(deg_to_rad(-20.0), deg_to_rad(180.0), deg_to_rad(-10.0))

# Katana visual styling
const KATANA_BLADE_TINT := Color(0.92, 0.96, 1.0, 1.0)
const KATANA_EDGE_TINT := Color(1.0, 1.0, 1.0, 1.0)
const KATANA_HILT_DARK := Color(0.07, 0.05, 0.05, 1.0)
const KATANA_WRAP_TINT := Color(0.30, 0.08, 0.10, 1.0)
const KATANA_GOLD := Color(0.96, 0.78, 0.30, 1.0)
const SCABBARD_TINT := Color(0.05, 0.04, 0.07, 1.0)

var _idle_t: float = 0.0
# Default state at spawn: sword is in the saya. The player has to swing (or
# trigger a super) to draw it out.
var _sheathed: bool = true
var _sheathe_tween: Tween
var _scabbard: Node3D

# Captured at _ready from the editor-set rig transforms. All combat tweens
# read from these so the rest pose you tune in the .tscn is the rest pose
# the game uses (rather than the REST_* constants overriding it).
var _rest_rot_tpv: Vector3
var _rest_pos_tpv: Vector3
var _rest_rot_fpv: Vector3
var _rest_pos_fpv: Vector3

func _ready() -> void:
	super()
	hit_area.monitoring = false
	hit_area.body_entered.connect(_on_body_entered)
	_setup_trail()
	# Capture the editor-set rig pose as the rest pose. Combat tweens read
	# these vars instead of the REST_* constants, so editor tuning is honored.
	_rest_rot_tpv = rig_tpv.rotation
	_rest_pos_tpv = rig_tpv.position
	_rest_rot_fpv = rig_fpv.rotation
	_rest_pos_fpv = rig_fpv.position
	# Replace the scene's blocky sword visuals with a longer katana-shaped rig.
	# HitArea and TipMarker (Marker3D) are kept untouched so combat reach and
	# trail sampling don't change.
	_install_katana_visuals(rig_tpv, false)
	_install_katana_visuals(rig_fpv, true)
	# Reposition the TipMarker children to the actual blade tip of the
	# editor-instanced GLB so the trail tracks where the blade really is.
	_position_tip_marker(rig_tpv, tip_tpv)
	_position_tip_marker(rig_fpv, tip_fpv)

# Override setup() so the scabbard can be parented to the player as soon as
# the player ref is known (the base setup just stores `player`).
func setup(p: Node) -> void:
	super(p)
	_build_scabbard()

func cooldown() -> float:
	return data.cooldown if data else 0.42

# Katana quirk: while equipped, the player dashes twice as often.
func dash_cooldown_mult() -> float:
	return 0.5

func guide_text() -> String:
	return "KATANA\n\nATTACK (LMB)\n  Three-strike combo: rising-L, rising-R, horizontal cleave.\n  Chain between 0.5s and 1.0s after the previous slash to keep the combo alive.\n  Damage scales 1x -> 1.5x -> 2x across the combo.\n\nDASH SLASH (CRIT)\n  Attacking while dashing crits: +50% damage, green trail,\n  and a misty wake hangs along the cut.\n\nSUPER (Q, when bar is full)\n  Corkscrew spin (~0.5s) that lifts you AND any caught target\n  into the air. Continuous re-hits at 4 dmg each. Counts as a\n  crit the entire time.\n\nQUIRK\n  Dash cooldown is HALVED while katana is equipped, so you\n  can reposition (and dash-crit) twice as often as with the\n  other weapons.\n\n[G] toggles this guide."

func _damage() -> int:
	return data.damage if data else damage

func equip() -> void:
	_idle_t = 0.0
	_kill_sheathe_tween()
	if _scabbard != null:
		_scabbard.visible = true
	# Preserve the sheathed/drawn state across weapon swaps. On initial spawn
	# `_sheathed` defaults to true so the player sees just the saya on the hip.
	if _sheathed:
		rig_tpv.visible = false
		rig_fpv.visible = false
	else:
		rig_tpv.visible = true
		rig_fpv.visible = true
		rig_tpv.rotation = _rest_rot_tpv
		rig_tpv.position = _rest_pos_tpv
		rig_fpv.rotation = _rest_rot_fpv
		rig_fpv.position = _rest_pos_fpv

func unequip() -> void:
	# Kill any in-flight swing tween and force the hit area off, otherwise an
	# interrupted swing leaves the hitbox monitoring (invisible damage).
	if _active_swing_tween and _active_swing_tween.is_valid():
		_active_swing_tween.kill()
	_active_swing_tween = null
	_kill_sheathe_tween()
	hit_area.monitoring = false
	_trail_sampling = false
	rig_tpv.visible = false
	rig_fpv.visible = false
	if _scabbard != null:
		_scabbard.visible = false

func on_attack_pressed() -> void:
	if attack_cd > 0.0 or _super_active:
		return
	# Roll-dashes (X key) lock out swings — the body is mid-roll and a swing
	# tween would look pasted on. Normal C-dashes still allow dash-crit slashes.
	if player != null and player.dash_time_left > 0.0 and player.get("_dash_is_roll"):
		return
	# First click while sheathed = quick draw, NOT a swing. A second click
	# afterwards (immediately allowed — no cooldown set on the draw) performs
	# the actual attack.
	if _sheathed:
		_draw_quick()
		return
	_swing()

func locks_movement() -> bool:
	return _super_active

# Crit conditions for the katana: mid-dash (dash-slash) or mid-super.
# Scales the blade length (rig Z-axis). The HitArea and tip marker are rig
# children, so reach + trail sample point grow with the visual blade.
const CRIT_SLASH_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, depth_test_disabled;

uniform vec4 tint : source_color = vec4(0.35, 1.0, 0.55, 1.0);
uniform vec4 hot_tint : source_color = vec4(0.92, 1.0, 0.96, 1.0);
uniform float progress : hint_range(-0.6, 1.6) = -0.2;
uniform float intensity : hint_range(0.0, 25.0) = 9.0;
uniform float edge_softness : hint_range(0.5, 12.0) = 2.6;
uniform float dissolve : hint_range(0.0, 1.6) = 0.0;
uniform float head_glow : hint_range(0.0, 12.0) = 5.0;
uniform float reveal_width : hint_range(0.05, 1.0) = 0.55;

float hash21(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p){
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i),                 hash21(i + vec2(1.0, 0.0)), u.x),
	           mix(hash21(i + vec2(0.0,1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p){
	float a = 0.5;
	float v = 0.0;
	for (int k = 0; k < 4; k++){
		v += a * vnoise(p);
		p *= 2.07;
		a *= 0.5;
	}
	return v;
}

void fragment(){
	// UV.y = 0 is the cutting edge (sharpest/brightest); UV.y = 1 is the outer fringe.
	float edge = UV.y;
	float thickness = pow(1.0 - edge, edge_softness);
	// Taper at start/end of arc so it doesn't read as a chopped band.
	float arc_taper = smoothstep(0.0, 0.10, UV.x) * smoothstep(1.0, 0.86, UV.x);
	// Sweep reveal — bright wave moves along UV.x as progress goes 0 -> 1.
	float reveal = smoothstep(progress - reveal_width, progress, UV.x);
	// Bright leading edge streak that travels with progress.
	float hot = smoothstep(progress - 0.055, progress - 0.004, UV.x)
	          * (1.0 - smoothstep(progress - 0.004, progress + 0.020, UV.x));
	// Noise-erosion dissolve: outer fringe and high-noise regions disappear first.
	// At dissolve=0 the threshold sits well above the noise field so the whole
	// band is visible; as dissolve grows toward 1 the threshold drops and more
	// of the band gets carved away.
	float n = fbm(vec2(UV.x * 9.0, UV.y * 2.2));
	float erode_thresh = 1.25 - dissolve * 1.30;
	float erode = 1.0 - smoothstep(erode_thresh - 0.22, erode_thresh, n + edge * 0.45);
	erode = clamp(erode, 0.0, 1.0);
	// Subtle streak texture along the cut so it reads as wind, not a solid blob.
	float streaks = 0.55 + 0.45 * vnoise(vec2(UV.x * 28.0, UV.y * 1.5 + 3.1));
	float a = thickness * arc_taper * reveal * erode * streaks;
	vec3 col = mix(tint.rgb, hot_tint.rgb, pow(thickness, 2.2));
	col += hot_tint.rgb * hot * head_glow;
	ALBEDO = col * intensity;
	ALPHA = clamp(a, 0.0, 1.0);
}
"""

# Cached so we don't recompile the shader on every crit.
static var _crit_slash_shader: Shader = null

static func _get_crit_slash_shader() -> Shader:
	if _crit_slash_shader == null:
		_crit_slash_shader = Shader.new()
		_crit_slash_shader.code = CRIT_SLASH_SHADER_CODE
	return _crit_slash_shader

# Spawn a sharp crescent "wind-blade" slash using a ShaderMaterial:
#   * thin cutting edge along the actual sword path, extruded outward past the
#     tip along the blade axis so the slash reads as a wind extension.
#   * shader does soft-edge falloff, an animated reveal sweep with a hot
#     leading streak, fbm-based dissolve, and subtle wind streaking.
#   * a second wider, dimmer halo pass behind it for the bloom-haze look.
func _spawn_crit_slash(power: float = 1.0) -> void:
	if _trail_points.size() < 6:
		return
	# Lifetime + size both scale with power so the super reads as a far larger
	# event than the dash-combo crits without changing the underlying shader.
	var dur: float = lerpf(0.42, 0.85, clampf((power - 1.0) / 1.5, 0.0, 1.0))
	_spawn_crit_slash_layer(0.95 * power, 9.0 * power, 5.2, 0.55, dur)         # core: sharp, bright
	_spawn_crit_slash_layer(1.55 * power, 4.5 * power, 7.2, 0.70, dur * 1.10)  # halo: wider, softer
	if power >= 1.4:
		# Outer wind-shell for the super: huge, low-intensity, fades slow.
		_spawn_crit_slash_layer(2.25 * power, 2.6 * power, 8.0, 0.85, dur * 1.30)

func _spawn_crit_slash_layer(out_len: float, base_intensity: float, edge_soft: float, reveal_w: float, lifetime: float) -> void:
	var snap: Array[Vector3] = _trail_points.duplicate()
	var mi := MeshInstance3D.new()
	var arr_mesh := ArrayMesh.new()
	mi.mesh = arr_mesh
	var mat := ShaderMaterial.new()
	mat.shader = _get_crit_slash_shader()
	mat.set_shader_parameter("tint", CRIT_TINT)
	mat.set_shader_parameter("hot_tint", Color(0.92, 1.0, 0.96, 1.0))
	mat.set_shader_parameter("progress", -0.15)
	mat.set_shader_parameter("dissolve", 0.0)
	mat.set_shader_parameter("intensity", base_intensity)
	mat.set_shader_parameter("edge_softness", edge_soft)
	mat.set_shader_parameter("reveal_width", reveal_w)
	mat.set_shader_parameter("head_glow", 5.5)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Don't let the slash get backface-culled by view dependence — it's a thin band.
	mi.extra_cull_margin = 4.0
	get_tree().current_scene.add_child(mi)
	_build_crit_slash_mesh(arr_mesh, snap, out_len)
	var tw := create_tween().set_parallel(true)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("progress", v),
		-0.15, 1.25, lifetime * 0.88
	).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("dissolve", v),
		0.0, 1.35, lifetime
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("intensity", v),
		base_intensity * 1.1, 0.0, lifetime
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(mi.queue_free)

func _build_crit_slash_mesh(arr_mesh: ArrayMesh, pairs: Array, out_len: float) -> void:
	var n: int = pairs.size() / 2
	if n < 2:
		return
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	verts.resize(n * 2)
	uvs.resize(n * 2)
	for i in range(n):
		var tip: Vector3 = pairs[i * 2]
		var hilt: Vector3 = pairs[i * 2 + 1]
		var blade: Vector3 = tip - hilt
		if blade.length() < 0.001:
			blade = Vector3.UP
		blade = blade.normalized()
		var inner: Vector3 = tip - blade * 0.10
		var outer: Vector3 = tip + blade * out_len
		var u: float = float(i) / float(n - 1)
		verts[i * 2] = inner
		verts[i * 2 + 1] = outer
		uvs[i * 2] = Vector2(u, 0.0)
		uvs[i * 2 + 1] = Vector2(u, 1.0)
	for i in range(n - 1):
		var a: int = i * 2
		var b: int = i * 2 + 1
		var c: int = (i + 1) * 2
		var d: int = (i + 1) * 2 + 1
		# Two triangles, both winding orders so the band is visible from either side.
		indices.append(a); indices.append(b); indices.append(d)
		indices.append(a); indices.append(d); indices.append(c)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

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
	# Treat super as "using" the sword — refresh the idle clock and yank the
	# blade out if it was holstered.
	if _sheathed:
		_unsheathe(true)
	_idle_t = 0.0
	attack_cd = SUPER_DURATION + 0.2
	_hits_this_swing.clear()

	if _active_swing_tween and _active_swing_tween.is_valid():
		_active_swing_tween.kill()
	var rig: Node3D = rig_fpv if is_fpv() else rig_tpv
	var rest_rot: Vector3 = _rest_rot_fpv if is_fpv() else _rest_rot_tpv
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
	_trail_sampling = true
	_begin_trail(CRIT_TINT)
	_set_blade_length_scale(1.5)
	_active_swing_tween = create_tween()
	var rehits: int = int(floor(SUPER_DURATION / SUPER_REHIT_INTERVAL))
	for i in rehits:
		_active_swing_tween.tween_interval(SUPER_REHIT_INTERVAL)
		_active_swing_tween.tween_callback(func(): _hits_this_swing.clear())
	_active_swing_tween.tween_interval(maxf(SUPER_DURATION - rehits * SUPER_REHIT_INTERVAL, 0.0))
	_active_swing_tween.tween_callback(func():
		_spawn_crit_slash(1.0)
		hit_area.monitoring = false
		_trail_sampling = false
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
	# Idle-sheathe timing: counts only while equipped (tick runs only then).
	# Swings/supers reset _idle_t to 0, so this trips exactly when the player
	# hasn't swung for IDLE_SHEATHE_TIME seconds.
	_idle_t += delta
	var busy: bool = _super_active or (_active_swing_tween != null and _active_swing_tween.is_valid())
	if not _sheathed and not busy and _idle_t >= IDLE_SHEATHE_TIME:
		_sheathe()
	if not _trail_active:
		return
	var marker: Marker3D = tip_fpv if is_fpv() else tip_tpv
	if _trail_sampling:
		_sample_trail(marker)
		_trail_t_left = 0.18
		_trail_decay_accum = 0.0
		# Upgrade trail/latch to crit if a dash kicks in mid-swing.
		if hit_area.monitoring and not _swing_was_crit and is_crit():
			_swing_was_crit = true
			if _trail_mat:
				_trail_mat.emission = CRIT_TINT
			_trail_tint = CRIT_TINT
	# Dash-crit lingers: while the player is still dashing AND this swing was
	# a crit, keep the trail alive (no countdown, no decay) so the green slash
	# trail hangs in the air for the full dash. Once the dash ends, normal
	# fade behaviour resumes.
	var dash_holding: bool = _swing_was_crit \
		and player != null and "dash_time_left" in player and player.dash_time_left > 0.0
	if dash_holding:
		_trail_t_left = maxf(_trail_t_left, 0.18)
	else:
		_trail_t_left = maxf(_trail_t_left - delta, 0.0)
	if not _trail_sampling and not dash_holding and _trail_points.size() >= 4:
		# Frame-rate independent: drop one pair every TRAIL_DECAY_INTERVAL sec.
		_trail_decay_accum += delta
		while _trail_decay_accum >= TRAIL_DECAY_INTERVAL and _trail_points.size() >= 4:
			_trail_decay_accum -= TRAIL_DECAY_INTERVAL
			_trail_points.remove_at(0)
			_trail_points.remove_at(0)
	_rebuild_trail()
	if _trail_t_left <= 0.0 and not _trail_sampling:
		_trail_active = false
		_trail_points.clear()
		if _trail_im:
			_trail_im.clear_surfaces()

func _swing() -> void:
	# Drawing-from-sheathe is handled by `_draw_quick` on the prior click,
	# but if anything still has the saya-tween running (e.g. a draw mid-tween)
	# we kill it so the swing keyframes own the rig transform cleanly.
	_kill_sheathe_tween()
	_idle_t = 0.0
	attack_cd = cooldown()
	_hits_this_swing.clear()

	# Combo advances only when the next click lands inside the chain window
	# [COMBO_MIN_GAP, COMBO_WINDOW] since the previous slash; earlier or later
	# clicks restart the combo at strike 0.
	var elapsed: float = COMBO_WINDOW - _combo_window_left
	var in_window: bool = _combo_window_left > 0.0 and elapsed >= COMBO_MIN_GAP
	if in_window:
		_combo_index = (_combo_index + 1) % COMBO_COUNT
	else:
		_combo_index = 0
	_combo_window_left = COMBO_WINDOW

	var data := _combo_data(_combo_index)
	# Drive the character body's sword swing animation in parallel with the
	# weapon-rig tween. Lock is roughly the combo's total duration so the
	# locomotion picker doesn't stomp the swing mid-strike.
	if player and player.has_method("play_anim_locked"):
		var total: float = 0.0
		for kf in data.keyframes:
			total += float(kf.dur)
		player.play_anim_locked("Sword_Attack", total * 0.85, 1.1)
	# Both rigs run the full position+rotation animation so the swing reads
	# the same in third- and first-person. FPVPivot is already scaled down in
	# the scene, so the offsets shrink appropriately for the closer camera.
	_tween_keyframes(rig_tpv, data.keyframes, _rest_rot_tpv, _rest_pos_tpv, true)
	_tween_keyframes(rig_fpv, data.keyframes, _rest_rot_fpv, _rest_pos_fpv, true)

	var marker: Marker3D = tip_fpv if is_fpv() else tip_tpv
	var base_tint: Color = data.tint
	var strike_start: float = data.strike_start
	var strike_end: float = data.strike_end
	# Trail sampling spans a wider window than the hit-window: it starts at
	# chamber-end (when the blade visibly begins arcing forward) and ends at
	# follow-through-end. Falls back to the strike window if a combo doesn't
	# specify them.
	var trail_start: float = data.get("trail_start", strike_start)
	var trail_end: float = data.get("trail_end", strike_end)

	# Reset the sticky crit latch; tick() will set it true if a crit is
	# observed at any point during the strike window, and we also seed it from
	# the initial is_crit() at strike_start.
	_swing_was_crit = false
	if _active_swing_tween and _active_swing_tween.is_valid():
		_active_swing_tween.kill()
	_active_swing_tween = create_tween()
	_active_swing_tween.tween_interval(trail_start)
	_active_swing_tween.tween_callback(func():
		_trail_sampling = true
		_begin_trail(base_tint)
	)
	_active_swing_tween.tween_interval(maxf(strike_start - trail_start, 0.0))
	_active_swing_tween.tween_callback(func():
		hit_area.monitoring = true
		if is_crit():
			_swing_was_crit = true
			if _trail_mat:
				_trail_mat.emission = CRIT_TINT
			_trail_tint = CRIT_TINT
	)
	_active_swing_tween.tween_interval(strike_end - strike_start)
	_active_swing_tween.tween_callback(func():
		hit_area.monitoring = false
	)
	_active_swing_tween.tween_interval(maxf(trail_end - strike_end, 0.0))
	_active_swing_tween.tween_callback(func():
		_trail_sampling = false
		_trail_t_left = 0.18
		if _swing_was_crit:
			_spawn_crit_slash(0.5)
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
			# Rising-left slash. kf.rot.x values include the +45° that the old
			# box-sword rest pose used to bake in, so the blade trajectory
			# matches what it was before the rest pose was moved to identity.
			return {
				"tint": Color(0.55, 0.95, 1.0, 1.0),
				"strike_start": 0.20,
				"strike_end": 0.34,
				"trail_start": 0.16,
				"trail_end": 0.37,
				"keyframes": [
					# Chamber low-left: blade pitched down, tip yawed right, cocked across the body.
					{"rot": Vector3(deg_to_rad(-30.0), deg_to_rad(95.0), deg_to_rad(15.0)), "pos": Vector3(-0.65, -0.35, -0.20), "dur": 0.16, "trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT},
					# Tip-lag overextension just before release.
					{"rot": Vector3(deg_to_rad(-40.0), deg_to_rad(105.0), deg_to_rad(20.0)), "pos": Vector3(-0.70, -0.40, -0.22), "dur": 0.05, "trans": Tween.TRANS_LINEAR, "ease": Tween.EASE_OUT},
					# Mid-strike: blade extended forward at chest height, peak contact frame.
					{"rot": Vector3(deg_to_rad(15.0), 0.0, 0.0), "pos": Vector3(0.0, 0.15, -0.60), "dur": 0.06, "trans": Tween.TRANS_CUBIC, "ease": Tween.EASE_IN},
					# Follow-through high-right: blade pitched up, tip yawed past the shoulder.
					{"rot": Vector3(deg_to_rad(60.0), deg_to_rad(-105.0), deg_to_rad(-20.0)), "pos": Vector3(0.65, 0.55, -0.20), "dur": 0.10, "trans": Tween.TRANS_EXPO, "ease": Tween.EASE_OUT},
					{"rot": Vector3.ZERO, "pos": Vector3.ZERO, "dur": 0.32, "trans": Tween.TRANS_QUART, "ease": Tween.EASE_OUT},
				],
			}
		1:
			# Mirror of combo 0: X positions flipped, Y/Z rotations flipped, pitch sweep identical.
			return {
				"tint": Color(0.75, 0.85, 1.0, 1.0),
				"strike_start": 0.16,
				"strike_end": 0.30,
				"trail_start": 0.16,
				"trail_end": 0.37,
				"keyframes": [
					{"rot": Vector3(deg_to_rad(-30.0), deg_to_rad(-95.0), deg_to_rad(-15.0)), "pos": Vector3(0.65, -0.35, -0.20), "dur": 0.16, "trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(-40.0), deg_to_rad(-105.0), deg_to_rad(-20.0)), "pos": Vector3(0.70, -0.40, -0.22), "dur": 0.05, "trans": Tween.TRANS_LINEAR, "ease": Tween.EASE_OUT},
					{"rot": Vector3(deg_to_rad(15.0), 0.0, 0.0), "pos": Vector3(0.0, 0.15, -0.60), "dur": 0.06, "trans": Tween.TRANS_CUBIC, "ease": Tween.EASE_IN},
					{"rot": Vector3(deg_to_rad(60.0), deg_to_rad(105.0), deg_to_rad(20.0)), "pos": Vector3(-0.65, 0.55, -0.20), "dur": 0.10, "trans": Tween.TRANS_EXPO, "ease": Tween.EASE_OUT},
					{"rot": Vector3.ZERO, "pos": Vector3.ZERO, "dur": 0.32, "trans": Tween.TRANS_QUART, "ease": Tween.EASE_OUT},
				],
			}
		_:
			# Majestic left → right horizontal cleave. Keyframes hold pitch at
			# 0 (relative to rest) so the blade stays flat through the sweep
			# regardless of the editor-set rest tilt. Position stays out in
			# front (Z negative) so the cleave never carves the player.
			return {
				"tint": Color(1.0, 0.55, 0.75, 1.0),
				# Strike now lands on KF3 (the cleave forward, 0.37 → 0.52)
				# rather than the chamber pull-back that preceded it — the
				# trail was previously tracing the wind-up, not the slash.
				"strike_start": 0.37,
				"strike_end": 0.50,
				"trail_start": 0.24,
				"trail_end": 0.52,
				"keyframes": [
					{"rot": Vector3(0.0, deg_to_rad(95.0), deg_to_rad(15.0)), "pos": Vector3(-0.70, 0.35, -0.30), "dur": 0.24, "trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT},
					{"rot": Vector3(0.0, deg_to_rad(105.0), deg_to_rad(20.0)), "pos": Vector3(-0.75, 0.37, -0.32), "dur": 0.06, "trans": Tween.TRANS_LINEAR, "ease": Tween.EASE_OUT},
					{"rot": Vector3(0.0, 0.0, 0.0), "pos": Vector3(0.0, 0.35, -0.65), "dur": 0.07, "trans": Tween.TRANS_CUBIC, "ease": Tween.EASE_IN},
					{"rot": Vector3(0.0, deg_to_rad(-105.0), deg_to_rad(-20.0)), "pos": Vector3(0.75, 0.35, -0.30), "dur": 0.15, "trans": Tween.TRANS_EXPO, "ease": Tween.EASE_OUT},
					{"rot": Vector3.ZERO, "pos": Vector3.ZERO, "dur": 0.40, "trans": Tween.TRANS_QUART, "ease": Tween.EASE_OUT},
				],
			}

# ── Edge-aiming math ─────────────────────────────────────────────────────────
# The blade's length and sharp-edge directions in the RIG'S local frame (i.e.
# when rig.rotation = identity). With the amaryllis instanced under SwordRig
# in the editor at its current pose, the blade tip points roughly along -Z
# (rig forward) and the sharp edge points roughly along -Y (rig down).
# Tweak these if your editor pose puts them along different axes.
const BLADE_LENGTH_RIG_LOCAL := Vector3(0.0, 0.0, -1.0)
const BLADE_EDGE_RIG_LOCAL := Vector3(0.0, -1.0, 0.0)

# Take the authored rotation `base_rot` (rig-parent euler) and add a roll
# about the blade's length axis so the sharp edge points along
# `cut_dir_parent` (a direction in the rig's parent space — usually the
# velocity vector of the rig moving from the previous keyframe to this one).
# Preserves the authored pitch/yaw and only spins the blade about its own
# length, so different combo strikes coming in from different angles each
# get their edge re-aimed for that particular slice direction.
# Walk the rig's children, find the first one that contains visible geometry
# (i.e. the user-instanced amaryllis), measure its world AABB, and project the
# 8 AABB corners onto BLADE_LENGTH_RIG_LOCAL (transformed into world space).
# Whichever corner sits farthest along that axis from the rig origin is the
# blade tip — convert that point to rig-local and put the TipMarker there.
# This way the trail tracks the actual blade no matter how the user tuned the
# GLB transform in the editor.
func _position_tip_marker(rig: Node3D, tip_marker: Marker3D) -> void:
	if rig == null or tip_marker == null:
		return
	var model_geom: Array = []
	for c in rig.get_children():
		if c == tip_marker:
			continue
		if c is Area3D:
			continue
		# The placeholder Blade/Core/Guard/Pommel/Tip MeshInstances are hidden
		# by _install_katana_visuals; skip them so they don't bias the AABB.
		if c is MeshInstance3D and not (c as MeshInstance3D).visible:
			continue
		_collect_visible_geom(c, model_geom)
	if model_geom.is_empty():
		return
	var aabb := AABB()
	var any := false
	for g in model_geom:
		var vi := g as VisualInstance3D
		var world_aabb: AABB = vi.global_transform * vi.get_aabb()
		if not any:
			aabb = world_aabb
			any = true
		else:
			aabb = aabb.merge(world_aabb)
	var blade_axis_world: Vector3 = (rig.global_transform.basis * BLADE_LENGTH_RIG_LOCAL).normalized()
	var rig_origin: Vector3 = rig.global_position
	var best_d: float = -INF
	var best_corner: Vector3 = aabb.position
	for ix in 2:
		for iy in 2:
			for iz in 2:
				var corner: Vector3 = aabb.position + Vector3(
					aabb.size.x * float(ix),
					aabb.size.y * float(iy),
					aabb.size.z * float(iz)
				)
				var d: float = (corner - rig_origin).dot(blade_axis_world)
				if d > best_d:
					best_d = d
					best_corner = corner
	tip_marker.global_position = best_corner

func _collect_visible_geom(n: Node, out: Array) -> void:
	if n is VisualInstance3D:
		var vis := true
		if n is GeometryInstance3D:
			vis = (n as GeometryInstance3D).visible
		if vis:
			out.append(n)
	for c in n.get_children():
		_collect_visible_geom(c, out)

func _aim_edge(base_rot: Vector3, cut_dir_parent: Vector3) -> Vector3:
	if cut_dir_parent.length_squared() < 1.0e-6:
		return base_rot
	var base_basis := Basis.from_euler(base_rot)
	var blade_axis := (base_basis * BLADE_LENGTH_RIG_LOCAL).normalized()
	# Component of cut_dir perpendicular to the blade axis — only the
	# sideways component matters; motion along the blade is a stab, not a slice.
	var cut_perp: Vector3 = cut_dir_parent - blade_axis * cut_dir_parent.dot(blade_axis)
	if cut_perp.length_squared() < 1.0e-6:
		return base_rot
	cut_perp = cut_perp.normalized()
	# Current edge direction in parent space after the authored rotation.
	var edge_now := (base_basis * BLADE_EDGE_RIG_LOCAL).normalized()
	var edge_perp: Vector3 = edge_now - blade_axis * edge_now.dot(blade_axis)
	if edge_perp.length_squared() < 1.0e-6:
		return base_rot
	edge_perp = edge_perp.normalized()
	# Signed angle from current edge direction to the cut direction, measured
	# around the blade axis (right-hand rule). Roll the rig by that amount.
	var angle: float = edge_perp.signed_angle_to(cut_perp, blade_axis)
	var roll := Basis(blade_axis, angle)
	return (roll * base_basis).get_euler()

func _tween_keyframes(rig: Node3D, kfs: Array, rest_rot: Vector3, rest_pos: Vector3, animate_pos: bool) -> void:
	var tr := create_tween()
	var tp: Tween = create_tween() if animate_pos else null
	# Edge-aiming uses motion between keyframes as the cut direction. The
	# swing begins at rest_pos, so the first keyframe's cut vector is
	# (kf0.pos + rest_pos) - rest_pos = kf0.pos. After that, each kf's cut
	# vector is its target position minus the previous one.
	var prev_target_pos: Vector3 = rest_pos
	var last_idx: int = kfs.size() - 1
	for i in kfs.size():
		var kf = kfs[i]
		var dur: float = kf.dur
		var trans: int = kf.trans
		var ease: int = kf.ease
		var target_pos: Vector3 = rest_pos + kf.pos
		var base_rot: Vector3 = rest_rot + kf.rot
		# Skip edge-aiming on the final (recovery) keyframe so the blade snaps
		# back to its authored rest rotation — otherwise the roll computed for
		# the return motion lingers and the next swing starts twisted.
		var target_rot: Vector3
		if i == last_idx:
			target_rot = base_rot
		else:
			var cut_dir: Vector3 = target_pos - prev_target_pos
			target_rot = _aim_edge(base_rot, cut_dir)
		tr.tween_property(rig, "rotation", target_rot, dur).set_trans(trans).set_ease(ease)
		if tp:
			tp.tween_property(rig, "position", target_pos, dur).set_trans(trans).set_ease(ease)
		prev_target_pos = target_pos

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

# Smoothing factor: each raw sample segment is subdivided into this many
# sub-segments via Catmull-Rom interpolation, so the trail reads as a curve
# rather than a polyline. 6 is a good balance between smoothness and overhead.
const TRAIL_SUBDIVISIONS: int = 6

func _catmull_rom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	# Uniform Catmull-Rom — passes exactly through p1 and p2, with tangents
	# defined by the neighbors so consecutive segments join smoothly.
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)

func _rebuild_trail() -> void:
	if _trail_im == null:
		return
	_trail_im.clear_surfaces()
	var pair_count: int = _trail_points.size() / 2
	if pair_count < 2:
		return
	# Split the interleaved sample buffer into the tip and hilt curves so each
	# can be smoothed independently — the trail is the ribbon spanning the two.
	var tips: Array[Vector3] = []
	var hilts: Array[Vector3] = []
	tips.resize(pair_count)
	hilts.resize(pair_count)
	for i in pair_count:
		tips[i] = _trail_points[i * 2]
		hilts[i] = _trail_points[i * 2 + 1]
	# Build the subdivided ribbon. Each raw segment [i, i+1] becomes
	# TRAIL_SUBDIVISIONS interpolated sub-segments. Endpoints use reflected
	# control points so the first and last segments stay tangent-continuous.
	var smooth_tips: Array[Vector3] = []
	var smooth_hilts: Array[Vector3] = []
	for i in range(pair_count - 1):
		var p0t: Vector3 = tips[i - 1] if i > 0 else 2.0 * tips[i] - tips[i + 1]
		var p1t: Vector3 = tips[i]
		var p2t: Vector3 = tips[i + 1]
		var p3t: Vector3 = tips[i + 2] if i + 2 < pair_count else 2.0 * tips[i + 1] - tips[i]
		var p0h: Vector3 = hilts[i - 1] if i > 0 else 2.0 * hilts[i] - hilts[i + 1]
		var p1h: Vector3 = hilts[i]
		var p2h: Vector3 = hilts[i + 1]
		var p3h: Vector3 = hilts[i + 2] if i + 2 < pair_count else 2.0 * hilts[i + 1] - hilts[i]
		var sub_count: int = TRAIL_SUBDIVISIONS if i < pair_count - 2 else TRAIL_SUBDIVISIONS + 1
		for s in sub_count:
			var t: float = float(s) / float(TRAIL_SUBDIVISIONS)
			smooth_tips.append(_catmull_rom(p0t, p1t, p2t, p3t, t))
			smooth_hilts.append(_catmull_rom(p0h, p1h, p2h, p3h, t))
	var smooth_count: int = smooth_tips.size()
	if smooth_count < 2:
		return
	_trail_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var denom: float = float(smooth_count - 1)
	for i in range(smooth_count - 1):
		var t0: float = float(i) / denom
		var t1: float = float(i + 1) / denom
		var a0: float = pow(t0, 1.4)
		var a1: float = pow(t1, 1.4)
		var p0a: Vector3 = smooth_tips[i]
		var p0b: Vector3 = smooth_hilts[i]
		var p1a: Vector3 = smooth_tips[i + 1]
		var p1b: Vector3 = smooth_hilts[i + 1]
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

# ── Katana visuals & scabbard ────────────────────────────────────────────────

# Replace the scene's stubby box-sword children with the amaryllis GLB.
# HitArea and TipMarker (Marker3D) are left in place so combat reach is unchanged.
const AMARYLLIS_MODEL_PATH := "res://assets/models/weapons/amaryllis.glb"

# ── Manual amaryllis positioning ────────────────────────────────────────────
# TPV and FPV rigs live under completely different parent transforms (TPV under
# WeaponPivot at (0.35,-0.1,-0.25) on the 2x-scaled player; FPV under FPVPivot
# at (0.3,-0.22,-0.4) with a 0.65x scale, and the FPV SwordRig itself carries
# a 1.538x scale). The same offset/rotation values produce very different
# world-space results in each view, so each rig gets its own tunables.
#
# All values are in the holder's local space (i.e. inside the SwordRig).
# Tweak these freely until the sword sits where you want it.
const SWORD_TARGET_LEN_TPV: float = 4.1
const SWORD_TARGET_LEN_FPV: float = 3.9
const SWORD_HOLDER_POS_TPV := Vector3(0.0, 0.4, -0.2)   # (x, y, z) — +x = right, -z = forward, +y = up
const SWORD_HOLDER_POS_FPV := Vector3(0.4, 0.0, -3.9 * 0.334)
const SWORD_HOLDER_ROT_TPV := Vector3(0.0, 0.0, 0.0)            # extra euler (rad) on top of auto axis-align
const SWORD_HOLDER_ROT_FPV := Vector3(0.0, 0.0, 0.0)

func _install_katana_visuals(rig: Node3D, fpv: bool) -> void:
	# Runtime visual build disabled — sword model is instanced directly in the
	# scene (.tscn) under each SwordRig and positioned manually in the editor.
	if rig == null:
		return
	for n in ["Blade", "Core", "Guard", "Pommel", "Tip"]:
		var c := rig.get_node_or_null(n)
		if c is MeshInstance3D:
			(c as MeshInstance3D).visible = false
	return
	var packed: PackedScene = load(AMARYLLIS_MODEL_PATH) as PackedScene
	var model: Node3D = (packed.instantiate() as Node3D) if packed != null else null
	if model == null:
		push_warning("[Sword] amaryllis model failed to load at %s" % AMARYLLIS_MODEL_PATH)
		return
	var holder := Node3D.new()
	holder.name = "ModelHolder"
	holder.add_child(model)
	rig.add_child(holder)
	# Measure the raw model, then scale-to-fit a canonical blade length so the
	# katana combat constants (~1.6m tip reach) still apply visually.
	var raw: AABB = _world_aabb_sword(model)
	var longest: float = maxf(raw.size.x, maxf(raw.size.y, raw.size.z))
	var target_len: float = SWORD_TARGET_LEN_FPV if fpv else SWORD_TARGET_LEN_TPV
	var fit_scale: float = (target_len / longest) if longest > 0.0001 else 1.0
	model.scale = Vector3(fit_scale, fit_scale, fit_scale)
	var center: Vector3 = (raw.position + raw.size * 0.5) * fit_scale
	model.position = -center
	# Orient longest axis along -Z (forward).
	var axis_idx := 0
	if raw.size.y >= raw.size.x and raw.size.y >= raw.size.z:
		axis_idx = 1
	elif raw.size.z >= raw.size.x and raw.size.z >= raw.size.y:
		axis_idx = 2
	var auto_rot := Vector3.ZERO
	match axis_idx:
		0:
			auto_rot = Vector3(0, deg_to_rad(90.0), 0)
		1:
			auto_rot = Vector3(deg_to_rad(90.0), 0, 0)
		2:
			auto_rot = Vector3(0, deg_to_rad(180.0), 0)
	var manual_rot: Vector3 = SWORD_HOLDER_ROT_FPV if fpv else SWORD_HOLDER_ROT_TPV
	holder.rotation = auto_rot + manual_rot
	holder.position = SWORD_HOLDER_POS_FPV if fpv else SWORD_HOLDER_POS_TPV
	if fpv:
		for n in _gather_geom_sword(holder):
			if n is GeometryInstance3D:
				(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _world_aabb_sword(n: Node) -> AABB:
	var box := AABB()
	var any := false
	for c in _gather_geom_sword(n):
		var local: AABB = c.get_aabb()
		var world: AABB = c.global_transform * local
		if not any:
			box = world
			any = true
		else:
			box = box.merge(world)
	return box

func _gather_geom_sword(n: Node) -> Array:
	var out: Array = []
	if n is VisualInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_gather_geom_sword(c))
	return out

func _add_box(parent: Node3D, size: Vector3, pos: Vector3, rot: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.rotation = rot
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

func _add_cyl(parent: Node3D, radius: float, height: float, pos: Vector3, rot: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 20
	mi.mesh = cm
	mi.position = pos
	mi.rotation = rot
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

func _katana_blade_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = KATANA_BLADE_TINT
	m.metallic = 0.85
	m.roughness = 0.18
	m.emission_enabled = true
	m.emission = KATANA_BLADE_TINT
	m.emission_energy_multiplier = 0.45
	return m

func _katana_edge_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = KATANA_EDGE_TINT
	m.emission_enabled = true
	m.emission = KATANA_EDGE_TINT
	m.emission_energy_multiplier = 1.4
	return m

func _katana_hilt_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = KATANA_HILT_DARK
	m.roughness = 0.62
	return m

func _katana_wrap_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = KATANA_WRAP_TINT
	m.roughness = 0.55
	return m

func _katana_gold_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = KATANA_GOLD
	m.metallic = 0.9
	m.roughness = 0.28
	m.emission_enabled = true
	m.emission = KATANA_GOLD
	m.emission_energy_multiplier = 0.25
	return m

# Scabbard (saya) parented to the player's body so it stays on the left hip
# regardless of whether the katana is the active weapon. WeaponPivot sits on
# the right hip, so the saya is offset to the player's left and tipped back
# in the classic worn-katana angle.
func _build_scabbard() -> void:
	if _scabbard != null or player == null:
		return
	_scabbard = Node3D.new()
	_scabbard.name = "Scabbard"
	player.add_child(_scabbard)
	# Player-local: -X = left, +Y = up, -Z = forward. The saya is mounted on
	# the left hip and tilted forward + slightly horizontal like a worn
	# katana hanging from the obi.
	# Mouth (koiguchi) sits at the player's waist on the left hip. The saya
	# runs almost horizontal from there, dipping slightly toward the ground
	# as it extends behind the player.
	_scabbard.position = Vector3(-0.42, 0.05, 0.10)
	# Small X tilt = saya tip dips slightly toward the floor. No Y rotation
	# is needed — body extends along local +Z, which in player-local space
	# already points behind the player.
	_scabbard.rotation = Vector3(deg_to_rad(18.0), 0.0, deg_to_rad(-10.0))

	# Saya body now extends in +Z so the mouth (z≈0) stays at the waist and
	# the tip is the part that swings out behind — fixes the previous
	# upside-down orientation.
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = SCABBARD_TINT
	body_mat.roughness = 0.32
	body_mat.metallic = 0.1
	_add_box(_scabbard, Vector3(0.085, 0.045, 1.62), Vector3(0, 0, 0.82), Vector3.ZERO, body_mat)
	# Gold koiguchi (mouth) at the front/waist end.
	_add_box(_scabbard, Vector3(0.094, 0.052, 0.06), Vector3(0, 0, 0.04), Vector3.ZERO, _katana_gold_mat())
	# Gold kojiri (tip cap) at the far end.
	_add_box(_scabbard, Vector3(0.094, 0.052, 0.06), Vector3(0, 0, 1.60), Vector3.ZERO, _katana_gold_mat())
	# Gold sageo wrap band partway down.
	_add_box(_scabbard, Vector3(0.095, 0.053, 0.04), Vector3(0, 0, 0.32), Vector3.ZERO, _katana_gold_mat())

# ── Sheathe / unsheathe ──────────────────────────────────────────────────────

func _sheathe() -> void:
	if _sheathed:
		return
	_sheathed = true
	_kill_sheathe_tween()
	# TPV rig glides toward the saya, then hides — the visible saya does the
	# rest of the storytelling. FPV rig has no sensible in-frustum holster pose
	# so it just hides at the same time.
	_sheathe_tween = create_tween().set_parallel(true)
	_sheathe_tween.tween_property(rig_tpv, "position", SHEATHE_POS_TPV, SHEATHE_TWEEN_IN).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	_sheathe_tween.tween_property(rig_tpv, "rotation", SHEATHE_ROT_TPV, SHEATHE_TWEEN_IN).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	_sheathe_tween.tween_callback(func():
		if is_instance_valid(rig_tpv):
			rig_tpv.visible = false
		if is_instance_valid(rig_fpv):
			rig_fpv.visible = false
	).set_delay(SHEATHE_TWEEN_IN * 0.9)

func _unsheathe(immediate: bool = false) -> void:
	if not _sheathed and not immediate:
		return
	_sheathed = false
	_kill_sheathe_tween()
	if rig_tpv:
		rig_tpv.visible = true
	if rig_fpv:
		rig_fpv.visible = true
	if immediate:
		rig_tpv.rotation = _rest_rot_tpv
		rig_tpv.position = _rest_pos_tpv
		rig_fpv.rotation = _rest_rot_fpv
		rig_fpv.position = _rest_pos_fpv
		return
	# Start from the saya pose so the draw reads as "pulled out of the
	# scabbard," then tween back to ready stance.
	rig_tpv.position = SHEATHE_POS_TPV
	rig_tpv.rotation = SHEATHE_ROT_TPV
	_sheathe_tween = create_tween().set_parallel(true)
	_sheathe_tween.tween_property(rig_tpv, "position", _rest_pos_tpv, SHEATHE_TWEEN_OUT).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_sheathe_tween.tween_property(rig_tpv, "rotation", _rest_rot_tpv, SHEATHE_TWEEN_OUT).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _draw_quick() -> void:
	# Fast draw-from-saya. Sets attack_cd = 0 explicitly (in case some prior
	# state left it non-zero) so the player can chain a swing immediately.
	# Resets idle so the sword doesn't sheathe itself again right away.
	_sheathed = false
	_idle_t = 0.0
	_kill_sheathe_tween()
	rig_tpv.visible = true
	rig_fpv.visible = true
	rig_fpv.rotation = _rest_rot_fpv
	rig_fpv.position = _rest_pos_fpv
	# Start the TPV rig at the saya pose and tween it to ready, fast.
	rig_tpv.position = SHEATHE_POS_TPV
	rig_tpv.rotation = SHEATHE_ROT_TPV
	_sheathe_tween = create_tween().set_parallel(true)
	_sheathe_tween.tween_property(rig_tpv, "position", _rest_pos_tpv, DRAW_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_sheathe_tween.tween_property(rig_tpv, "rotation", _rest_rot_tpv, DRAW_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _kill_sheathe_tween() -> void:
	if _sheathe_tween and _sheathe_tween.is_valid():
		_sheathe_tween.kill()
	_sheathe_tween = null
