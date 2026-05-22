extends "res://weapons/weapon.gd"

# Spear weapon. Unlike sword/gun/sniper (whose rigs are authored into each
# level's .tscn), the spear builds its own rigs at runtime by parenting a
# SpearRig Node3D under the player's WeaponPivot (TPV) and FPVPivot (FPV).
# This keeps the per-level scene churn for adding the weapon to one ext_resource
# line + one Node entry.

const SPEAR_MODEL_PATH := "res://assets/models/weapons/ancient_spear.glb"

const REST_POS_TPV := Vector3(0.0, 0.0, 0.0)
const REST_ROT_TPV := Vector3(0.0, 0.0, 0.0)
const REST_POS_FPV := Vector3(0.18, -0.45, -0.55)
const REST_ROT_FPV := Vector3(0.0, 0.0, 0.0)

const MODEL_SCALE_TPV := 1.0
const MODEL_SCALE_FPV := 0.7
# The spear .glb's tip points along its local +Z; we orient the rig so the
# blade points forward (-Z in player space).
const MODEL_ROT := Vector3(0.0, PI, 0.0)

# ── Combat constants ─────────────────────────────────────────────────────────
# Spear thrust kinematics. A real martial-arts thrust accelerates the tip
# quickly to a peak velocity and then decelerates — modelled here as a TRANS_CIRC
# EASE_OUT out-stroke (peak acceleration at t=0, peak velocity at strike) and a
# TRANS_QUAD EASE_IN in-stroke. Peak tip speed for an out-stroke of reach D over
# duration t_out is approximately v_peak ≈ π·D / (2·t_out). With D=1.1m and
# t_out=0.10s this gives ~17 m/s at the tip — within the realistic range
# (~10–20 m/s) for trained spear thrusts.
const DAMAGE: int = 3
const COOLDOWN: float = 0.45

# Per-jab parameters. Jab 2 is slightly longer/sharper than jab 1, and lands
# harder so the combo has a damage ramp.
const JAB1_REACH: float = 1.1
const JAB1_OUT: float = 0.10
const JAB1_DWELL: float = 0.03
const JAB1_IN: float = 0.16
const JAB1_DMG_MULT: float = 1.0
# Note: JAB2_DMG_MULT and SPIN_DMG_MULT are forced to 1.0 below so every spear
# swing lands at the flat base damage (3). Re-introduce variance later if the
# combo wants a damage ramp again.

const JAB2_REACH: float = 1.35
const JAB2_OUT: float = 0.085
const JAB2_DWELL: float = 0.04
const JAB2_IN: float = 0.16
const JAB2_DMG_MULT: float = 1.0

# Damage window inside a jab is the time the tip is travelling near peak speed:
# from STRIKE_FRAC_START·t_out to (t_out + dwell). The early window opens just
# after acceleration ramp so the contact correlates with high tip momentum.
const STRIKE_FRAC_START: float = 0.45

# Spinning slash. The rig rotates about the player's vertical axis through a
# total sweep of SPIN_SWEEP radians over SPIN_DURATION seconds, with a smoothed
# angular profile. Tip path length s = r·θ, peak angular speed (sinusoidal
# easing) ω_peak ≈ π·θ_total / (2·T). With θ=3π (540°) and T=0.55s, ω_peak ≈
# 8.57 rad/s; at spear tip r ≈ target_len/2 ≈ 2.4m this gives v_tip ≈ 20.6 m/s.
const SPIN_SWEEP: float = TAU * 1.5    # 540° total
const SPIN_DURATION: float = 0.55
const SPIN_DMG_MULT: float = 2.0
# Periodic _hits_this_swing clear so the spin can re-hit the same enemy on each
# rotation pass instead of damaging once and then sliding through them.
const SPIN_REHIT_INTERVAL: float = 0.11
# Drop the spear from rest pitch to flat (parallel to the ground) for the spin
# so the tip sweeps a horizontal arc at hip height rather than chopping down.
const SPIN_PITCH_OFFSET: float = 0.0   # +X tilt; 0 keeps it horizontal forward

const COMBO_COUNT: int = 3
const COMBO_WINDOW: float = 0.85       # max time after a hit to chain the next
const COMBO_MIN_GAP: float = 0.10      # min time so spammed clicks don't auto-chain

# Super: a single long lunge that travels much further than a jab, deals heavy
# damage, and shakes the camera. Tip peak velocity ≈ π·2.6/(2·0.18) ≈ 22.7 m/s.
const SUPER_REACH: float = 2.6
const SUPER_OUT: float = 0.18
const SUPER_DWELL: float = 0.10
const SUPER_IN: float = 0.22
const SUPER_DAMAGE: int = 9

var rig_tpv: Node3D
var rig_fpv: Node3D
var hit_area: Area3D
var _hits_this_swing: Array = []
var _swing_tween: Tween
var _spin_clear_tween: Tween
var _super_active: bool = false
var _combo_index: int = -1
var _combo_window_left: float = 0.0
var _is_spinning: bool = false

func setup(p: Node) -> void:
	super(p)
	_build_rigs()
	rig_tpv.visible = false
	rig_fpv.visible = false

func cooldown() -> float:
	return data.cooldown if data else COOLDOWN

func _damage() -> int:
	return data.damage if data else DAMAGE

func equip() -> void:
	if rig_tpv == null:
		return
	rig_tpv.visible = true
	rig_fpv.visible = true
	rig_tpv.position = REST_POS_TPV
	rig_tpv.rotation = REST_ROT_TPV
	rig_fpv.position = REST_POS_FPV
	rig_fpv.rotation = REST_ROT_FPV

func unequip() -> void:
	if _swing_tween and _swing_tween.is_valid():
		_swing_tween.kill()
	_swing_tween = null
	if hit_area:
		hit_area.monitoring = false
	if rig_tpv:
		rig_tpv.visible = false
	if rig_fpv:
		rig_fpv.visible = false

func tick(delta: float) -> void:
	_combo_window_left = maxf(_combo_window_left - delta, 0.0)
	if _combo_window_left <= 0.0:
		_combo_index = -1

func on_attack_pressed() -> void:
	if attack_cd > 0.0 or _super_active or _is_spinning:
		return
	# Chain the combo if the previous strike landed inside the window (and not
	# so soon that the player is just mashing). Otherwise restart at jab 1.
	var elapsed: float = COMBO_WINDOW - _combo_window_left
	var in_window: bool = _combo_window_left > 0.0 and elapsed >= COMBO_MIN_GAP
	if in_window:
		_combo_index = (_combo_index + 1) % COMBO_COUNT
	else:
		_combo_index = 0
	_combo_window_left = COMBO_WINDOW
	if _combo_index == 2:
		_spin_slash()
	else:
		_jab(_combo_index)

func on_super_pressed() -> void:
	if _super_active or _is_spinning or not super_ready():
		return
	if not consume_super():
		return
	_super_active = true
	_jab_animate(SUPER_REACH, SUPER_OUT, SUPER_DWELL, SUPER_IN, SUPER_DAMAGE, true)
	if player and player.camera and player.camera.has_method("add_trauma"):
		player.camera.add_trauma(0.5)

func guide_text() -> String:
	return "ANCIENT SPEAR\n\nATTACK (LMB) — COMBO\n  1) Jab.\n  2) Faster, stronger jab.\n  3) Spinning slash — 540° sweep hitting any\n     enemy in a circle around you.\n  Chain within ~0.85s to advance.\n\nSUPER (Q, when bar is full)\n  Heavy long-reach lunge, one big hit.\n\n[G] toggles this guide."

func _jab(idx: int) -> void:
	var reach: float = JAB1_REACH if idx == 0 else JAB2_REACH
	var t_out: float = JAB1_OUT if idx == 0 else JAB2_OUT
	var dwell: float = JAB1_DWELL if idx == 0 else JAB2_DWELL
	var t_in: float = JAB1_IN if idx == 0 else JAB2_IN
	var mult: float = JAB1_DMG_MULT if idx == 0 else JAB2_DMG_MULT
	var dmg: int = int(round(_damage() * mult))
	_jab_animate(reach, t_out, dwell, t_in, dmg, false)

func _jab_animate(reach: float, t_out: float, dwell: float, t_in: float, dmg: int, is_super: bool) -> void:
	if _swing_tween and _swing_tween.is_valid():
		_swing_tween.kill()
	_hits_this_swing.clear()
	_current_hit_damage = dmg
	# Allow the next click before full recovery so the combo flows.
	attack_cd = t_out + dwell + t_in * 0.4
	var total: float = t_out + dwell + t_in
	var rig: Node3D = rig_fpv if is_fpv() else rig_tpv
	var rest_pos: Vector3 = REST_POS_FPV if is_fpv() else REST_POS_TPV
	var rest_rot: Vector3 = REST_ROT_FPV if is_fpv() else REST_ROT_TPV
	rig.rotation = rest_rot
	var fwd_pos: Vector3 = rest_pos + Vector3(0, 0, -reach)
	# TRANS_CIRC EASE_OUT: peak acceleration at t=0, decelerating tail — matches
	# the back hand snapping forward at the start of a thrust. Pull-back uses
	# TRANS_QUAD EASE_IN so the recovery decelerates smoothly into rest.
	_swing_tween = create_tween()
	_swing_tween.tween_property(rig, "position", fwd_pos, t_out).set_trans(Tween.TRANS_CIRC).set_ease(Tween.EASE_OUT)
	if dwell > 0.0:
		_swing_tween.tween_interval(dwell)
	_swing_tween.tween_property(rig, "position", rest_pos, t_in).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	# Damage window: tip near peak speed (after STRIKE_FRAC_START of out-stroke)
	# through the dwell.
	var strike_start: float = t_out * STRIKE_FRAC_START
	var strike_end: float = t_out + dwell + 0.02
	var dmg_tw := create_tween()
	dmg_tw.tween_interval(strike_start)
	dmg_tw.tween_callback(func(): hit_area.monitoring = true)
	dmg_tw.tween_interval(maxf(strike_end - strike_start, 0.0))
	dmg_tw.tween_callback(func(): hit_area.monitoring = false)
	if is_super:
		dmg_tw.tween_interval(maxf(total - strike_end, 0.0))
		dmg_tw.tween_callback(func(): _super_active = false)

func _spin_slash() -> void:
	# 540° horizontal sweep. SPIN_SWEEP=3π over SPIN_DURATION=0.55s gives peak
	# angular speed ω ≈ π·θ/(2T) ≈ 8.6 rad/s. At a tip radius r ≈ 2.4m (TPV
	# spear half-length) the tip travels ≈ 20.6 m/s at mid-arc — fast enough
	# to read as a single continuous slash sweeping the circle around the
	# player. _hits_this_swing clears every SPIN_REHIT_INTERVAL so an enemy
	# in the path gets struck once per revolution.
	_is_spinning = true
	_hits_this_swing.clear()
	_current_hit_damage = int(round(_damage() * SPIN_DMG_MULT))
	attack_cd = SPIN_DURATION + 0.18
	if _swing_tween and _swing_tween.is_valid():
		_swing_tween.kill()
	if _spin_clear_tween and _spin_clear_tween.is_valid():
		_spin_clear_tween.kill()
	var rig: Node3D = rig_fpv if is_fpv() else rig_tpv
	var rest_pos: Vector3 = REST_POS_FPV if is_fpv() else REST_POS_TPV
	var rest_rot: Vector3 = REST_ROT_FPV if is_fpv() else REST_ROT_TPV
	rig.position = rest_pos
	rig.rotation = Vector3(SPIN_PITCH_OFFSET, 0.0, 0.0)
	hit_area.monitoring = true
	# θ(t) ≈ SPIN_SWEEP · smoothstep(t/T); TRANS_SINE EASE_IN_OUT approximates
	# this with the angular-velocity peak at mid-arc.
	_swing_tween = create_tween()
	_swing_tween.tween_property(rig, "rotation:y", SPIN_SWEEP, SPIN_DURATION).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_swing_tween.tween_callback(func():
		hit_area.monitoring = false
		_is_spinning = false
		rig.rotation = rest_rot
	)
	_spin_clear_tween = create_tween()
	var clears: int = int(floor(SPIN_DURATION / SPIN_REHIT_INTERVAL))
	for i in clears:
		_spin_clear_tween.tween_interval(SPIN_REHIT_INTERVAL)
		_spin_clear_tween.tween_callback(func(): _hits_this_swing.clear())
	if player and player.camera and player.camera.has_method("add_trauma"):
		player.camera.add_trauma(0.35)

var _current_hit_damage: int = 1

func _on_body_entered(body: Node) -> void:
	if body == player or body in _hits_this_swing:
		return
	_hits_this_swing.append(body)
	if not body.has_method("take_damage"):
		return
	var dir: Vector3 = Vector3.ZERO
	var body3d := body as Node3D
	if body3d != null:
		dir = (body3d.global_position - player.global_position).normalized()
	body.take_damage(_current_hit_damage, dir)
	add_super_charge(float(_current_hit_damage))
	if body3d != null:
		Vfx.impact_burst(body3d.global_position + Vector3(0, 0.4, 0), 0.5, Color(1.0, 0.85, 0.4, 1))
	player.register_hit(0.3)

# ── rig construction ────────────────────────────────────────────────────────

func _build_rigs() -> void:
	if player == null:
		return
	var weapon_pivot: Node3D = player.get_node_or_null("WeaponPivot") as Node3D
	var fpv_pivot: Node3D = player.get_node_or_null("CameraPitchPivot/Camera3D/FPVPivot") as Node3D
	if weapon_pivot == null or fpv_pivot == null:
		push_warning("Spear: couldn't find WeaponPivot or FPVPivot")
		return
	rig_tpv = _make_rig(false)
	weapon_pivot.add_child(rig_tpv)
	rig_fpv = _make_rig(true)
	fpv_pivot.add_child(rig_fpv)
	# Hit area lives under the TPV rig so its world transform tracks the thrust.
	hit_area = Area3D.new()
	hit_area.name = "HitArea"
	hit_area.monitoring = false
	hit_area.collision_layer = 0
	hit_area.collision_mask = 4  # enemies
	# Hit volume covers the entire TPV spear mesh, not just the tip. The TPV
	# model is scaled to target_len = 4.8 m and offset so the rig origin sits
	# `grip_back_frac` (0.25) of the way back from the tip — i.e. the holder
	# center is at z = -4.8 * (0.5 - 0.25) = -1.2, with the spear extending
	# ±2.4 along its rotated axis from there (tip at z=-3.6, butt at z=+1.2).
	# Sizing the box 4.8 long, centered at z=-1.2, makes any contact along
	# the shaft register damage during a thrust or spin.
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.45, 0.45, 4.8)
	cs.shape = box
	cs.position = Vector3(0, 0, -1.2)
	hit_area.add_child(cs)
	rig_tpv.add_child(hit_area)
	hit_area.body_entered.connect(_on_body_entered)

func _make_rig(fpv: bool) -> Node3D:
	var rig := Node3D.new()
	rig.name = "SpearRigFPV" if fpv else "SpearRigTPV"
	rig.position = REST_POS_FPV if fpv else REST_POS_TPV
	rig.rotation = REST_ROT_FPV if fpv else REST_ROT_TPV
	# load() at runtime (not preload) so a not-yet-imported .glb only produces
	# a missing-visual, not a script parse failure that kills the whole weapon.
	var packed: PackedScene = load(SPEAR_MODEL_PATH) as PackedScene
	var model: Node3D = (packed.instantiate() as Node3D) if packed != null else null
	if model != null:
		# Wrap the .glb in a normalizer node so we can scale + recenter it to a
		# canonical size regardless of how it was authored.
		var holder := Node3D.new()
		holder.name = "ModelHolder"
		holder.add_child(model)
		rig.add_child(holder)
		# Measure the raw model in its instantiated transform.
		var raw: AABB = _world_aabb(model)
		print("[Spear] %s raw AABB size=%s center=%s" % ["FPV" if fpv else "TPV", raw.size, raw.position + raw.size * 0.5])
		var longest: float = maxf(raw.size.x, maxf(raw.size.y, raw.size.z))
		var target_len: float = (3.6 if fpv else 4.8)
		var fit_scale: float = (target_len / longest) if longest > 0.0001 else 1.0
		model.scale = Vector3(fit_scale, fit_scale, fit_scale)
		# Recenter so the model's midpoint sits at the rig origin, then push
		# forward so the rig origin is at the butt-end of the spear (so thrust
		# extends the tip outward along -Z).
		var center: Vector3 = (raw.position + raw.size * 0.5) * fit_scale
		model.position = -center
		# Apply user-set rotation around the spear's local axes. Orientation
		# heuristic: rotate so the longest axis points along -Z (forward).
		var axis_idx := 0
		if raw.size.y >= raw.size.x and raw.size.y >= raw.size.z:
			axis_idx = 1
		elif raw.size.z >= raw.size.x and raw.size.z >= raw.size.y:
			axis_idx = 2
		match axis_idx:
			0:
				holder.rotation = Vector3(0, deg_to_rad(-90.0), 0)
			1:
				holder.rotation = Vector3(deg_to_rad(-90.0), 0, 0)
			2:
				holder.rotation = Vector3(0, 0.0, 0)
		# Shift the holder so the tip points forward (-Z) and a portion of the
		# shaft extends behind the rig origin so the player has handle to grab.
		var grip_back_frac: float = 0.25
		holder.position = Vector3(0, 0, -target_len * (0.5 - grip_back_frac))
		if fpv:
			_disable_shadows(holder)
	else:
		push_warning("[Spear] model failed to load at %s" % SPEAR_MODEL_PATH)
	return rig

func _world_aabb(root: Node) -> AABB:
	# Sums each MeshInstance's local AABB transformed into `root`'s local space,
	# avoiding global_transform reads while the model isn't in the scene tree.
	var box := AABB()
	var any := false
	var root3d: Node3D = root as Node3D
	for c in _gather_geom(root):
		var local: AABB = c.get_aabb()
		var xform: Transform3D = _transform_to_ancestor(c, root3d)
		var world: AABB = xform * local
		if not any:
			box = world
			any = true
		else:
			box = box.merge(world)
	return box

func _transform_to_ancestor(node: Node3D, ancestor: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != ancestor:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t

func _gather_geom(n: Node) -> Array:
	var out: Array = []
	if n is VisualInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_gather_geom(c))
	return out

func _disable_shadows(n: Node) -> void:
	if n is GeometryInstance3D:
		(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_disable_shadows(c)
