extends Area3D

# Homing missile fired by GhostLeviathan. Implements a two-phase flight model
# with a range-faded loft offset — the same trajectory shape as modern
# top-attack PGMs (AMRAAM, METEOR), but with the loft baked into the aim point
# rather than expressed as a discrete LOFT→TERMINAL phase switch.
#
#   PHASE_BOOST    — Open-loop launch at building thrust. No lateral guidance;
#                    the missile flies in its launch direction (heavy UP bias
#                    set by the launcher → VLS fountain). Speed ramps from
#                    BOOST_SPEED toward CRUISE_SPEED across BOOST_DURATION.
#
#   PHASE_HOMING   — Augmented Proportional Navigation (APN) toward a virtual
#                    aim point that slides DOWN onto the target as range
#                    shrinks:
#                       loft  = LOFT_ALTITUDE · saturate((d − D₀) / (D₁ − D₀))
#                       aim   = target_pos + UP · loft
#                    At range ≥ LOFT_RANGE_FULL the missile chases a point
#                    LOFT_ALTITUDE m above the target (climb / coast at
#                    altitude). At range ≤ LOFT_RANGE_ZERO the aim point IS
#                    the target (clean dive). Between the two it converges
#                    smoothly — no 90° transition the autopilot can't fly.
#                    The discrete LOFT/TERMINAL switch was abandoned because
#                    at the switch instant the missile is moving horizontally
#                    while the target sits directly below: ZEM lies along the
#                    velocity axis, and PN can't redirect a constant-speed
#                    airframe 90° before the geometry stops paying out.
#
# GUIDANCE (HOMING) — APN in Zero-Effort-Miss form + pursuit augmentation
# along the line of sight. APN alone is purely lateral (perpendicular to
# LOS); combined with a constant-speed autopilot it cannot close range
# when V is roughly perpendicular to R (the missile orbits indefinitely).
# Adding a closing acceleration along R̂ rotates V toward the target in
# the degenerate geometry and is a no-op when V is already aligned with
# R̂. Standard fire-control mitigation for the PN orbital pathology:
#
#       R       = aim_pos − missile_pos               (relative position)
#       V_r     = aim_vel − missile_vel               (relative velocity)
#       V_c     = −R̂ · V_r                          (closing speed)
#       t_go    = |R| / max(V_c, V_c_floor)            (time-to-go)
#       ZEM     = R + V_r · t_go                      (predicted miss)
#       ZEM⊥    = ZEM − (ZEM · R̂) R̂                 (component ⊥ to LOS)
#       a_target⊥ = a_target − (a_target · R̂) R̂
#       a_cmd   = (N / t_go²) · ZEM⊥  +  (N/2) · a_target⊥
#
#   (N / t_go²)·ZEM⊥ is mathematically equivalent to N·V_c·Ω True PN but
#   numerically stable at small LOS rates. (N/2)·a_target⊥ is the APN
#   augmentation — without it, PN lags a maneuvering target.
#
# TARGET ESTIMATOR — alpha-beta filter (the recursive estimator used by real
# radar trackers). Position is measured each frame; velocity and acceleration
# come from smoothed finite differences. Smoothing is delta-rate consistent so
# the filter behaves the same at any framerate.
#
# AUTOPILOT SATURATION — total commanded accel is clamped to MAX_LATERAL_ACCEL.
# When clamping is required, weave is sacrificed first: a weaving missile that
# misses is worthless; a steady one that hits is the goal.
#
# WEAVE — sinusoidal lateral demand on top of guidance, with per-missile phase
# φ and ±1 spin sign so a salvo braids its trails instead of corkscrewing in
# sync. Forced off in TERMINAL so the run-in stays clean.

const BOOST_SPEED: float = 24.0              # launch speed; visibly building toward cruise
const CRUISE_SPEED: float = 42.0             # ~3.2× player base; faster than before but trim turn authority below
const N_NAV: float = 4.0                     # navigation constant; PN textbooks use 3–5
# Lateral cap intentionally LOW relative to speed so missiles are juke-dodgeable.
# Minimum turn radius = CRUISE_SPEED² / MAX_LATERAL_ACCEL = 42² / 220 ≈ 8 m.
# That's a wide enough arc that a perpendicular sprint at close range will
# slip outside the turn radius and let the missile sail past. Max angular
# rate is MAX_LATERAL_ACCEL / CRUISE_SPEED ≈ 5.2 rad/s ≈ 300 °/s — agile
# enough to track normal movement, sluggish enough that a sharp direction
# change at the right moment is a guaranteed miss.
const MAX_LATERAL_ACCEL: float = 220.0       # airframe lateral cap (~22 g) — tuned for dodgeable
const BOOST_DURATION: float = 0.55           # open-loop launch — gives the salvo its visible fan and a taller fountain
const LIFETIME: float = 12.0
const MISSILE_DAMAGE: int = 3

# Lofted attack profile (range-faded — see header).
#   - Aim altitude offset = LOFT_ALTITUDE · saturate((range − LOFT_RANGE_ZERO)
#     / (LOFT_RANGE_FULL − LOFT_RANGE_ZERO)). When far: full loft. When close:
#     loft collapses to 0 and the aim point IS the target.
#   - Below TERMINAL_RANGE the weave is also forced off so the run-in is
#     clean (no late-game sinusoidal jitter pulling the missile off-axis).
const LOFT_ALTITUDE: float = 26.0            # max virtual-aim-point offset above target at full loft — taller arcs read as more dramatic
const LOFT_RANGE_FULL: float = 55.0          # range to target ≥ this → full loft
const LOFT_RANGE_ZERO: float = 12.0          # range to target ≤ this → no loft (aim = target)
const TERMINAL_RANGE: float = 9.0            # range ≤ this → weave forced off for a clean kill arc
# Inner cutoff: inside this bubble around the target the missile drops all
# homing demand and coasts in its current velocity direction. The point is to
# give the player a generous last-instant dodge window — if they can sidestep
# into the bubble just before the missile arrives, the missile commits to
# where they WERE and flies past instead of snapping onto them. Raising it
# makes missiles easier to dodge, lowering it makes the dodge window
# vanishingly small.
const HOMING_CUTOFF: float = 9.0             # m — no guidance applied inside this radius
# Sizing: collision triggers when missile and player capsules touch, ~0.8 m
# center-to-center. So the missile coasts for (HOMING_CUTOFF − 0.8) m. At
# CRUISE_SPEED that's the dodge window in seconds:
#   2 m bubble → 0.028 s window — dash barely clears, walk fails
#   5 m bubble → 0.10 s window — walk just clears, dash slips clean
#   7 m bubble → 0.15 s window — generous, but the missile reads as "dumb"
#                                 from a long way out
# 5 m sits at the threshold where a deliberate juke is reliably rewarded
# without making the salvo trivially dodgeable when standing still.

# Pursuit augmentation. Pure APN gives only LATERAL correction — the command
# is perpendicular to LOS. Combined with a constant-speed autopilot
# (_velocity = _velocity.normalized() * CRUISE_SPEED in _integrate), this
# means the missile can only ROTATE velocity, never close range under its
# own command. When the launch direction is far from LOS (e.g., heavy UP
# bias with target below), V is roughly perpendicular to R, and PN's
# command resolves to "decelerate" — which the magnitude lock cancels. The
# missile orbits the target indefinitely. PURSUIT_ACCEL fixes this by
# adding a closing acceleration along R̂: when V is along R̂ (already
# closing), it's parallel and the magnitude lock no-ops it; when V is
# perpendicular to R̂ (orbiting), it's the only term that rotates V toward
# the target. Tuned high enough to dominate residual lateral demand near
# the kill so missiles don't drift wide in the last few meters.
const PURSUIT_ACCEL: float = 85.0

# t_go floor: when V_c is small (transient launch, target running with us), the
# raw t_go can blow up. Floor closing speed at a fraction of cruise speed so
# t_go stays meaningful — equivalent to assuming the missile will close range
# under its own thrust even if instantaneous V_c is low.
const V_C_FLOOR_FRAC: float = 0.5            # min V_c = CRUISE_SPEED · this
const T_GO_FLOOR: float = 0.05
const T_GO_CEIL: float = 8.0

# Alpha-beta tracking filter time constants (per-second decay rates).
# Both bandwidths are tuned LOW on purpose: the filter takes ~1/bw seconds to
# register a target maneuver, so a sharp dash by the player is invisible to
# the missile's lead estimate for a beat, and the missile commits to a stale
# aim point. That's the juke window. Raising either bandwidth above ~10 makes
# the missile essentially un-dodgeable; below ~3 it can't track a moving
# target at all.
const TARGET_VEL_BANDWIDTH: float = 3.5      # velocity tracker responsiveness — slow so a juke takes a beat to register
const TARGET_ACC_BANDWIDTH: float = 1.2      # acceleration tracker responsiveness (slow on purpose)

# Weave (Itano helix) decoration. Pushed up from a quiet 55 to a properly
# theatrical 210 once pursuit augmentation was in place — pursuit absorbs the
# closing demand so a large lateral weave can ride on top without sabotaging
# the kill. Helix radius from sinusoidal lateral demand = A/ω², so 210/5.5²
# ≈ 7 m of lateral excursion at mid-flight. Combined with the per-missile
# phase offset, alternating spin sign, and frequency jitter (below), the
# salvo's eight trails interleave through one another like an Itano Circus
# instead of marching in step.
const WEAVE_AMP: float = 130.0               # lateral accel demand at full strength — sized to fit under MAX_LATERAL_ACCEL with guidance + pursuit also live
const WEAVE_FREQ: float = 5.5                # rad/s nominal — actual per-missile freq is jittered ±18%
const WEAVE_FREQ_JITTER: float = 0.18        # per-missile fractional spread (±) on WEAVE_FREQ; desynchronizes the salvo
const WEAVE_TGO_FULL: float = 1.2            # t_go above this → full weave
const WEAVE_TGO_FADE: float = 0.40           # t_go below this → no weave

const OFF_MAP_RADIUS: float = 700.0
const OFF_MAP_Y_FLOOR: float = -200.0

# --- Crystal projectile mesh. The "missile head" is one of three imported
# crystal GLBs picked per-missile by the launcher (a salvo mixes all three so
# the screen reads as a hail of different shards, not eight identical ones).
# The gem's authored materials are left intact — colors and textures
# unchanged — but the imported emission_energy_multiplier is dialed WAY down
# at build time so each gem reads as a faceted crystal lit by the surrounding
# light rather than as a self-illuminated orb. Per-instance material
# duplication prevents the dimming from leaking back to the shared resource
# (would otherwise affect every missile already in flight).
#
# Orientation: each crystal is authored upright with its tip along +Y (think
# bullet standing on its base). Each frame we rebuild the gem's world basis
# so its local +Y axis points at the target, then add accumulated rifling
# spin around that same axis. Result: the warhead's tip is always trained on
# the player, and the gem visibly corkscrews around the tip→base axis.
#
# Per-type colors drive both the trail and the OmniLight tint; each crystal
# carries its own visual identity. The launcher picks crystal_type per
# missile (see _fire_missile_volley in ghost_leviathan.gd).
const CRYSTAL_TYPES: Array = [
	# 0 — glowing_gem: bright cyan (the project's current cyan trail).
	{
		"path": "res://assets/models/glowing_gem.glb",
		"boost_color": Color(0.75, 1.0, 1.0, 1.0),
		"cruise_color": Color(0.15, 0.85, 1.0, 1.0),
	},
	# 1 — enchanted_crystal: slightly darker / deeper cyan than #0.
	{
		"path": "res://assets/models/enchanted_crystal.glb",
		"boost_color": Color(0.55, 0.92, 1.0, 1.0),
		"cruise_color": Color(0.05, 0.55, 0.85, 1.0),
	},
	# 2 — stylized_crystal: pink (the original color this path used before
	#     the cyan switch — pale yellow-white ignition into pink cruise).
	{
		"path": "res://assets/models/stylized_crystal.glb",
		"boost_color": Color(1.0, 0.92, 0.55, 1.0),
		"cruise_color": Color(1.0, 0.55, 0.95, 1.0),
	},
]
const CRYSTAL_LENGTH: float = 0.95           # longest-axis target size for the normalized gem
const GEM_EMISSION_SCALE: float = 0.12       # multiplier applied to each material's imported emission_energy_multiplier — keeps color, kills the orb glow
# Per-missile rifling spin. Sign carries from weave_spin so half the salvo
# rifles left-handed and half right-handed; magnitude is jittered ±25 % per
# missile (derived deterministically from weave_phase) so adjacent missiles
# don't rifle in lockstep.
const CRYSTAL_SPIN_RATE: float = 14.0        # rad/s nominal (~2.2 rotations/s)
const CRYSTAL_SPIN_JITTER: float = 0.25      # ±25 % per-missile spread on CRYSTAL_SPIN_RATE

# --- Trail visuals (two-color: hot booster ignition → cool cruise streak).
# Mobile renderer can't run GPU particle trails on Godot 4.6, so we build the
# ribbon ourselves with an ImmediateMesh TRIANGLE_STRIP. Per-sample color is
# stored alongside each trail point so the boost→cruise handoff freezes a
# visible color gradient into the ribbon. The actual colors come from the
# per-missile crystal type (_boost_color / _cruise_color), not from constants.
const TRAIL_SAMPLES: int = 100
const TRAIL_SAMPLE_INTERVAL: float = 0.024
const TRAIL_WIDTH_CRUISE: float = 0.05           # narrow streak — reads as a sharp ribbon, not a smear
const TRAIL_WIDTH_BOOST: float = 0.08            # slightly fatter during boost ignition

# Launch flash: a single bright pulse at spawn that decays in FLASH_DURATION.
# Tuned LOWER than the original so the gem itself reads as a crystal lit by a
# modest emitter, not as a glowing core. Same for cruise — the trail is the
# headline visual, the gem just needs enough rim light to register.
const FLASH_DURATION: float = 0.15
const FLASH_ENERGY: float = 2.2
const FLASH_RANGE: float = 5.0
const CRUISE_LIGHT_ENERGY: float = 0.35
const CRUISE_LIGHT_RANGE: float = 2.6

enum Phase { BOOST, HOMING }

# --- Setup-time configuration (set by launcher).
var shooter: Node = null
var target: Node3D = null
var weave_phase: float = 0.0
var weave_spin: float = 1.0
var crystal_type: int = 0
# Resolved from CRYSTAL_TYPES[crystal_type] in setup() and used everywhere a
# color is needed (trail, light, etc.). Defaults match crystal #0 so a missile
# constructed without setup() still renders cleanly.
var _model_path: String = "res://assets/models/glowing_gem.glb"
var _boost_color: Color = Color(0.75, 1.0, 1.0, 1.0)
var _cruise_color: Color = Color(0.15, 0.85, 1.0, 1.0)

# --- Flight state.
var _velocity: Vector3 = Vector3.ZERO
var _phase: int = Phase.BOOST
var _age: float = 0.0
var _phase_age: float = 0.0
var _flash_age: float = 0.0
var _hit_targets: Array = []

# --- Target estimator (alpha-beta filter on target position → vel, acc).
var _est_pos_prev: Vector3 = Vector3.ZERO
var _est_vel: Vector3 = Vector3.ZERO
var _est_acc: Vector3 = Vector3.ZERO
var _est_seeded: bool = false

# --- Visuals.
# _gem_root holds the instantiated gem model. Its imported materials are left
# untouched — only orientation (per-frame) and rifling angle are driven from
# code.
var _gem_root: Node3D
var _gem_scale: Vector3 = Vector3.ONE   # captured after size normalization so per-frame global_basis writes don't lose scale
var _gem_spin_rate: float = 0.0         # rad/s around aim axis (signed)
var _gem_spin_angle: float = 0.0        # accumulated rifling angle (rad)
var _trail_root: Node3D
var _trail_mi: MeshInstance3D
var _trail_mesh: ImmediateMesh
var _trail_mat: StandardMaterial3D
var _trail_points: PackedVector3Array = PackedVector3Array()
# Phase tag stored alongside each trail sample (Phase enum cast to float) so
# the ribbon can be colored per-segment.
var _trail_phase_at: PackedFloat32Array = PackedFloat32Array()
var _sample_cd: float = 0.0
var _light: OmniLight3D
# Effective boost/cruise speeds for THIS missile. Default to the class
# constants; the launcher may override via setup()'s speed_scale arg so e.g.
# the passive trickle pair flies slower than the main salvo without needing
# a separate script.
var _boost_speed: float = BOOST_SPEED
var _cruise_speed: float = CRUISE_SPEED


# at: spawn position. initial_dir: unit launch direction (salvo fan).
# src: leviathan (ignored on contact). tgt: homing target.
# phase: weave angular offset (rad). spin: +1 or −1 swirl direction.
# type_id: index into CRYSTAL_TYPES (picks model + boost/cruise color).
# speed_scale: multiplier applied to BOOST_SPEED/CRUISE_SPEED for this
#   instance. 1.0 = salvo default; pass a smaller value (e.g. 0.667) from
#   the passive launcher to make those missiles drift slowly without
#   forking a second script.
#
# Note on construction order: the launcher does `MissileScene.new();
# add_child(m); m.setup(...)`. add_child fires _ready BEFORE setup runs, so
# the color- and model-dependent visual builds (gem, trail, light) live HERE
# in setup rather than in _ready — by the time we get here, crystal_type is
# known and the right model/colors can be picked.
func setup(at: Vector3, initial_dir: Vector3, src: Node, tgt: Node3D, phase: float = 0.0, spin: float = 1.0, type_id: int = 0, speed_scale: float = 1.0) -> void:
	global_position = at
	shooter = src
	target = tgt
	weave_phase = phase
	weave_spin = signf(spin) if spin != 0.0 else 1.0
	crystal_type = clampi(type_id, 0, CRYSTAL_TYPES.size() - 1)
	var spec: Dictionary = CRYSTAL_TYPES[crystal_type]
	_model_path = String(spec["path"])
	_boost_color = spec["boost_color"]
	_cruise_color = spec["cruise_color"]
	_boost_speed = BOOST_SPEED * speed_scale
	_cruise_speed = CRUISE_SPEED * speed_scale
	# Deterministic per-missile rifling rate derived from the weave phase so
	# adjacent missiles spin at slightly different speeds. Sign carries from
	# weave_spin so half the salvo rifles left-handed and half right-handed.
	var jitter: float = CRYSTAL_SPIN_JITTER * sin(weave_phase * 1.9)
	_gem_spin_rate = CRYSTAL_SPIN_RATE * (1.0 + jitter) * weave_spin
	if initial_dir.length_squared() > 0.0:
		_velocity = initial_dir.normalized() * _boost_speed
		look_at(global_position + _velocity, _safe_up(_velocity))
	# All color/model-dependent visuals built here (see note above).
	_build_visual()
	_build_trail()
	_build_light()


func _ready() -> void:
	collision_layer = 0
	collision_mask = 1   # player + remote puppets are on layer 1
	monitoring = true
	body_entered.connect(_on_body_entered)
	_build_collision()


func _physics_process(delta: float) -> void:
	_age += delta
	_phase_age += delta
	_flash_age += delta

	if target != null and is_instance_valid(target):
		_update_target_estimator(target.global_position, delta)

	_advance_phase()
	var a_cmd: Vector3 = _compute_command()
	_integrate(a_cmd, delta)
	_update_trail(delta)
	_update_light()
	_update_gem_orientation(delta)

	if global_position.y < OFF_MAP_Y_FLOOR or absf(global_position.x) > OFF_MAP_RADIUS or absf(global_position.z) > OFF_MAP_RADIUS:
		queue_free()
		return
	if _age >= LIFETIME:
		queue_free()


# Phase transition. Single boundary: BOOST → HOMING at BOOST_DURATION. From
# there the trajectory shape (climb high, sweep over, dive) emerges from the
# range-faded loft offset baked into _compute_command — no further switches.
func _advance_phase() -> void:
	if _phase == Phase.BOOST and _age >= BOOST_DURATION:
		_phase = Phase.HOMING
		_phase_age = 0.0


# Dispatch command computation by phase.
#   BOOST:  forward-axis speed ramp from BOOST_SPEED → CRUISE_SPEED. No lateral
#           guidance — open-loop launch.
#   HOMING: APN toward target + UP·loft, where loft fades from LOFT_ALTITUDE
#           down to 0 as range to the real target shrinks across the band
#           [LOFT_RANGE_ZERO, LOFT_RANGE_FULL]. Weave is forced off below
#           TERMINAL_RANGE for a clean kill arc.
func _compute_command() -> Vector3:
	match _phase:
		Phase.BOOST:
			var ramp_t: float = clampf(_age / BOOST_DURATION, 0.0, 1.0)
			var desired_speed: float = lerp(_boost_speed, _cruise_speed, ramp_t)
			var cur_speed: float = _velocity.length()
			if cur_speed > 1e-6:
				var dv: float = desired_speed - cur_speed
				# 12.0 is a per-second pull toward desired speed. Tuned so the
				# missile reaches CRUISE_SPEED a beat after BOOST ends rather
				# than snapping discontinuously at the phase boundary.
				return _velocity.normalized() * (dv * 12.0)
			return Vector3.ZERO
		Phase.HOMING:
			if target == null or not is_instance_valid(target):
				return Vector3.ZERO
			var range_to_target: float = (target.global_position - global_position).length()
			# Inner-cutoff coast: inside HOMING_CUTOFF the missile drops all
			# guidance, pursuit, and weave demand. It keeps its current
			# velocity vector unchanged, so if the player sidestepped at the
			# last beat the missile sails past instead of snapping on. This
			# is the player's final-instant dodge window.
			if range_to_target <= HOMING_CUTOFF:
				return Vector3.ZERO
			# Range-faded loft. Clamped to [0, 1]: full loft when far, zero
			# when close. Smoothstep gives a softer onset/offset than linear,
			# so the missile doesn't visibly snap as the loft begins to fade.
			var loft_factor: float = smoothstep(LOFT_RANGE_ZERO, LOFT_RANGE_FULL, range_to_target)
			var aim_pos: Vector3 = target.global_position + Vector3.UP * (LOFT_ALTITUDE * loft_factor)
			var terminal: bool = range_to_target <= TERMINAL_RANGE
			return _apn_guidance(aim_pos, terminal)
	return Vector3.ZERO


# Alpha-beta filter. New target position is folded into smoothed velocity and
# acceleration estimates. The formula `alpha = 1 - exp(-bw·dt)` gives
# framerate-independent exponential smoothing.
func _update_target_estimator(t_pos: Vector3, delta: float) -> void:
	if not _est_seeded:
		_est_pos_prev = t_pos
		_est_seeded = true
		return
	if delta <= 0.0:
		return
	var raw_vel: Vector3 = (t_pos - _est_pos_prev) / delta
	var alpha_v: float = 1.0 - exp(-TARGET_VEL_BANDWIDTH * delta)
	var new_vel: Vector3 = _est_vel.lerp(raw_vel, alpha_v)
	var raw_acc: Vector3 = (new_vel - _est_vel) / delta
	var alpha_a: float = 1.0 - exp(-TARGET_ACC_BANDWIDTH * delta)
	_est_acc = _est_acc.lerp(raw_acc, alpha_a)
	_est_vel = new_vel
	_est_pos_prev = t_pos


# APN command toward the given aim point. `terminal` suppresses the weave so
# the kill arc is uncluttered.
func _apn_guidance(aim_pos: Vector3, terminal: bool) -> Vector3:
	var R: Vector3 = aim_pos - global_position
	var range_sq: float = R.length_squared()
	if range_sq < 1e-6:
		return Vector3.ZERO
	var range_m: float = sqrt(range_sq)
	var R_hat: Vector3 = R / range_m

	# Closing speed and time-to-go.
	var V_r: Vector3 = _est_vel - _velocity
	var V_c: float = -R_hat.dot(V_r)
	var V_c_eff: float = maxf(V_c, _cruise_speed * V_C_FLOOR_FRAC)
	var t_go: float = clampf(range_m / V_c_eff, T_GO_FLOOR, T_GO_CEIL)

	# Zero-Effort-Miss: where R will be at intercept if neither party
	# accelerates further. The lateral (⊥ to LOS) component is what we must
	# null out — parallel component is just range we still need to close.
	var ZEM: Vector3 = R + V_r * t_go
	var ZEM_perp: Vector3 = ZEM - ZEM.dot(R_hat) * R_hat

	# APN augmentation: half of N times the perpendicular component of target
	# acceleration. This is what makes APN beat classical PN against a
	# maneuvering target — it predicts the target's curve and leads it.
	var a_t_perp: Vector3 = _est_acc - _est_acc.dot(R_hat) * R_hat
	# Pursuit augmentation along R̂. APN's lateral correction alone cannot
	# rotate velocity toward the target when V is roughly perpendicular to
	# R (the orbital pathology) — the command resolves anti-parallel to V
	# and the constant-speed autopilot cancels it. Adding a closing demand
	# along R̂ guarantees velocity rotates toward the LOS in that case;
	# when V is already aligned with R̂ the term is parallel to V and the
	# magnitude lock no-ops it (no spurious speed change). Net effect: PN
	# handles the lateral lead, pursuit handles range closure.
	var a_pursuit: Vector3 = R_hat * PURSUIT_ACCEL
	var a_guidance: Vector3 = (N_NAV / (t_go * t_go)) * ZEM_perp + (0.5 * N_NAV) * a_t_perp + a_pursuit

	# Weave: lateral sinusoidal decoration in the velocity frame, faded by
	# t_go so it tapers off as we close. In terminal we force it to zero —
	# the dive is intended to read as deliberate, not theatrical.
	var a_weave: Vector3 = Vector3.ZERO
	if not terminal:
		var weave_fade: float = smoothstep(WEAVE_TGO_FADE, WEAVE_TGO_FULL, t_go)
		if weave_fade > 0.0:
			var fwd: Vector3 = _velocity.normalized()
			var up_ref: Vector3 = Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
			var right: Vector3 = fwd.cross(up_ref).normalized()
			var up: Vector3 = right.cross(fwd).normalized()
			var t_local: float = _age - BOOST_DURATION
			# Per-missile frequency jitter, derived deterministically from
			# weave_phase (assigned at launch from the missile's ring index).
			# Eight phases evenly spaced around TAU map to eight distinct
			# jitter values in [1−JITTER, 1+JITTER], so the salvo's spirals
			# desynchronize over the flight and the trails braid through
			# one another instead of all spiraling at the same rate.
			var freq_jitter: float = 1.0 + WEAVE_FREQ_JITTER * sin(weave_phase * 2.73)
			var omega: float = WEAVE_FREQ * freq_jitter
			var angle: float = omega * weave_spin * t_local + weave_phase
			var weave_dir: Vector3 = cos(angle) * right + sin(angle) * up
			a_weave = (WEAVE_AMP * weave_fade) * weave_dir

	return _saturate(a_guidance, a_weave)


# Saturation policy: keep guidance command intact, eat into weave first. If
# guidance alone exceeds the cap, scale guidance down (last resort).
func _saturate(a_g: Vector3, a_w: Vector3) -> Vector3:
	var total: Vector3 = a_g + a_w
	var total_m: float = total.length()
	if total_m <= MAX_LATERAL_ACCEL:
		return total
	var g_mag: float = a_g.length()
	if g_mag >= MAX_LATERAL_ACCEL:
		return a_g * (MAX_LATERAL_ACCEL / maxf(g_mag, 1e-6))
	var spare: float = MAX_LATERAL_ACCEL - g_mag
	var w_mag: float = a_w.length()
	if w_mag <= 1e-6:
		return a_g
	return a_g + a_w * (spare / w_mag)


# Solid-rocket cruise integration. During BOOST: command is a forward-axis
# accel that nudges magnitude toward CRUISE_SPEED — magnitude is allowed to
# vary. After BOOST: lateral accel rotates velocity, then magnitude is locked
# at CRUISE_SPEED (constant-speed autopilot — standard PN textbook model).
func _integrate(a_cmd: Vector3, delta: float) -> void:
	_velocity += a_cmd * delta
	if _velocity.length_squared() <= 1e-6:
		return
	if _phase != Phase.BOOST:
		_velocity = _velocity.normalized() * _cruise_speed
	look_at(global_position + _velocity, _safe_up(_velocity))
	global_position += _velocity * delta


# --- Visuals ----------------------------------------------------------------

func _build_visual() -> void:
	# Load the gem GLB, instantiate it, and normalize its size so the longest
	# axis is CRYSTAL_LENGTH. The imported materials are left intact — we want
	# the asset's own look — and orientation is driven per-frame in
	# _update_gem_orientation.
	var packed: PackedScene = load(_model_path) as PackedScene
	if packed == null:
		push_warning("[LeviathanMissile] failed to load %s — falling back to no visual" % _model_path)
		return
	var instance: Node = packed.instantiate()
	if instance == null or not (instance is Node3D):
		push_warning("[LeviathanMissile] gem scene did not instantiate as Node3D")
		return
	_gem_root = instance as Node3D
	add_child(_gem_root)
	_normalize_gem_size(_gem_root)
	# Cache the post-normalization scale; _update_gem_orientation writes
	# global_basis each frame and we need to bake scale back into it so the
	# normalized size doesn't drift back to 1 across frames.
	_gem_scale = _gem_root.scale
	# Disable cast shadows on every mesh in the gem, and dim each material's
	# emission_energy_multiplier to GEM_EMISSION_SCALE × its imported value.
	# Color / albedo / textures are not touched — only the emission strength.
	# Each material is duplicated first so the dimming is per-instance and
	# doesn't leak back into the shared sub-resource.
	for n in _gather_mesh_instances(_gem_root):
		var mi: MeshInstance3D = n
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		for s in range(mesh.get_surface_count()):
			var src_mat: Material = mi.get_active_material(s)
			if src_mat is BaseMaterial3D:
				var dup: BaseMaterial3D = src_mat.duplicate() as BaseMaterial3D
				dup.emission_energy_multiplier = dup.emission_energy_multiplier * GEM_EMISSION_SCALE
				mi.set_surface_override_material(s, dup)


# Scale the gem so the longest world-axis dimension of its merged AABB equals
# CRYSTAL_LENGTH. Mirrors the size-normalization helper in ghost_leviathan.gd
# so a freshly downloaded asset of any source scale drops in without needing
# Inspector tweaks.
func _normalize_gem_size(model: Node3D) -> void:
	var box := AABB()
	var any := false
	for n in _gather_visual_instances(model):
		var local: AABB = n.get_aabb()
		var xform: Transform3D = _transform_to_ancestor(n, model)
		var world: AABB = xform * local
		if not any:
			box = world
			any = true
		else:
			box = box.merge(world)
	var longest: float = maxf(box.size.x, maxf(box.size.y, box.size.z))
	if longest > 0.0001:
		var s: float = CRYSTAL_LENGTH / longest
		model.scale = Vector3(s, s, s)


# Recursively gather all MeshInstance3D descendants of `n`.
func _gather_mesh_instances(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_gather_mesh_instances(c))
	return out


# Recursively gather all VisualInstance3D descendants of `n` (mesh, csg, etc.)
# — used by _normalize_gem_size to compute a tight bounding box.
func _gather_visual_instances(n: Node) -> Array:
	var out: Array = []
	if n is VisualInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_gather_visual_instances(c))
	return out


# Composed local-to-ancestor transform for AABB merging, copied from
# ghost_leviathan.gd's identical helper.
func _transform_to_ancestor(node: Node3D, ancestor: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != ancestor:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


func _build_collision() -> void:
	var sph := SphereShape3D.new()
	sph.radius = 0.32
	var cs := CollisionShape3D.new()
	cs.shape = sph
	add_child(cs)


func _build_trail() -> void:
	_trail_root = Node3D.new()
	_trail_root.top_level = true
	add_child(_trail_root)
	_trail_mat = StandardMaterial3D.new()
	_trail_mat.albedo_color = _cruise_color
	_trail_mat.emission_enabled = true
	_trail_mat.emission = _cruise_color
	_trail_mat.emission_energy_multiplier = 2.4
	_trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_trail_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_trail_mat.vertex_color_use_as_albedo = true
	_trail_mesh = ImmediateMesh.new()
	_trail_mi = MeshInstance3D.new()
	_trail_mi.mesh = _trail_mesh
	_trail_mi.material_override = _trail_mat
	_trail_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail_root.add_child(_trail_mi)


func _build_light() -> void:
	_light = OmniLight3D.new()
	_light.light_color = _boost_color
	_light.light_energy = FLASH_ENERGY
	_light.omni_range = FLASH_RANGE
	add_child(_light)


# Orient the gem so its authored local +Y (the bullet tip) points at the
# target, and rotate around that same axis at _gem_spin_rate to read as a
# rifled round. The gem's authored materials/transforms are otherwise left
# alone — only its world basis is driven here.
#
#   1) Build a right-handed world basis with Y = aim_dir:
#         X = up_ref × aim_dir          (perpendicular to aim_dir)
#         Z = X × aim_dir               (perpendicular to both; X×Y=Z, RH)
#      up_ref is world UP unless aim_dir is nearly vertical (gimbal-near),
#      in which case we fall back to world FORWARD.
#   2) Rotate that basis around aim_dir by _gem_spin_angle (the rifling).
#      Quaternion(axis, angle) is the cleanest way to express axis-angle
#      rotation; pre-multiplying applies it in world space.
#   3) Bake the cached normalization scale into each column of the basis so
#      writing global_basis doesn't reset the gem's normalized size.
#
# If the target is gone (boss kill, etc.), fall back to aiming along the
# current velocity so the gem still reads correctly.
func _update_gem_orientation(delta: float) -> void:
	if _gem_root == null:
		return
	_gem_spin_angle += _gem_spin_rate * delta
	var aim_dir: Vector3
	if target != null and is_instance_valid(target):
		aim_dir = target.global_position - global_position
	else:
		aim_dir = _velocity
	if aim_dir.length_squared() < 1e-6:
		return
	aim_dir = aim_dir.normalized()
	var up_ref: Vector3 = Vector3.UP if absf(aim_dir.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	var x_axis: Vector3 = up_ref.cross(aim_dir).normalized()
	var z_axis: Vector3 = x_axis.cross(aim_dir).normalized()
	var oriented: Basis = Basis(x_axis, aim_dir, z_axis)
	var rifled: Basis = Basis(Quaternion(aim_dir, _gem_spin_angle)) * oriented
	rifled.x *= _gem_scale.x
	rifled.y *= _gem_scale.y
	rifled.z *= _gem_scale.z
	_gem_root.global_basis = rifled


# Light behavior:
#   - First FLASH_DURATION s: bright booster-ignition flash that decays in
#     a quadratic falloff toward steady cruise.
#   - After: steady-state cruise glow tinted by phase color. The gem's own
#     materials are NOT modified — only the light around it changes.
func _update_light() -> void:
	if _light == null:
		return
	if _flash_age < FLASH_DURATION:
		var f: float = 1.0 - (_flash_age / FLASH_DURATION)
		_light.light_color = _boost_color
		_light.light_energy = lerp(CRUISE_LIGHT_ENERGY, FLASH_ENERGY, f * f)
		_light.omni_range = lerp(CRUISE_LIGHT_RANGE, FLASH_RANGE, f)
		return
	if _phase == Phase.BOOST:
		_light.light_color = _boost_color
		_light.light_energy = CRUISE_LIGHT_ENERGY
		_light.omni_range = CRUISE_LIGHT_RANGE + 0.6
	else:
		_light.light_color = _cruise_color
		_light.light_energy = CRUISE_LIGHT_ENERGY * 0.75
		_light.omni_range = CRUISE_LIGHT_RANGE


# Trail update: every TRAIL_SAMPLE_INTERVAL we append the current position
# AND a phase tag. The full strip is rebuilt each frame from the buffered
# samples. Width and color are chosen per-sample: BOOST samples are wider
# and yellow-white, CRUISE/TERMINAL samples are narrower and pink. The
# vertex-color interpolation along the strip blends the two colors at the
# phase boundary, so the boost→cruise handoff freezes as a visible gradient
# in the ribbon.
func _update_trail(delta: float) -> void:
	if _trail_mesh == null:
		return
	_sample_cd -= delta
	if _sample_cd <= 0.0:
		_trail_points.append(global_position)
		_trail_phase_at.append(float(_phase))
		if _trail_points.size() > TRAIL_SAMPLES:
			_trail_points.remove_at(0)
			_trail_phase_at.remove_at(0)
		_sample_cd = TRAIL_SAMPLE_INTERVAL
	_trail_mesh.clear_surfaces()
	var n: int = _trail_points.size()
	if n < 2:
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos: Vector3 = cam.global_position
	_trail_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var inv_n_1: float = 1.0 / float(n - 1)
	for i in range(n):
		var p: Vector3 = _trail_points[i]
		var tangent: Vector3
		if i == 0:
			tangent = _trail_points[1] - _trail_points[0]
		elif i == n - 1:
			tangent = _trail_points[n - 1] - _trail_points[n - 2]
		else:
			tangent = _trail_points[i + 1] - _trail_points[i - 1]
		if tangent.length_squared() < 1e-6:
			tangent = Vector3.FORWARD
		else:
			tangent = tangent.normalized()
		var to_cam: Vector3 = cam_pos - p
		if to_cam.length_squared() < 1e-6:
			to_cam = Vector3.UP
		var side: Vector3 = tangent.cross(to_cam).normalized()
		var t: float = float(i) * inv_n_1
		var ph: float = _trail_phase_at[i]
		var is_boost: bool = (ph == float(Phase.BOOST))
		var seg_col: Color = _boost_color if is_boost else _cruise_color
		var seg_width: float = TRAIL_WIDTH_BOOST if is_boost else TRAIL_WIDTH_CRUISE
		var width: float = seg_width * t
		var alpha: float = t * t
		var col := Color(seg_col.r, seg_col.g, seg_col.b, alpha)
		_trail_mesh.surface_set_color(col)
		_trail_mesh.surface_add_vertex(p + side * width)
		_trail_mesh.surface_set_color(col)
		_trail_mesh.surface_add_vertex(p - side * width)
	_trail_mesh.surface_end()


func _on_body_entered(body: Node) -> void:
	if body == shooter:
		return
	if _age <= 0.0:
		return
	if body in _hit_targets:
		return
	_hit_targets.append(body)
	if body.has_method("take_damage"):
		body.take_damage(MISSILE_DAMAGE, _velocity.normalized())
	queue_free()


func _safe_up(d: Vector3) -> Vector3:
	if absf(d.dot(Vector3.UP)) > 0.99:
		return Vector3.FORWARD
	return Vector3.UP
