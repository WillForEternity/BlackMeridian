extends CharacterBody3D

# Heavy destroyable "fish projectile" fired by GhostLeviathan once every two
# missile volleys — a homing chunk of bloggling. Uses the same APN-with-pursuit
# guidance as leviathan_missile.gd (refer to that file for the derivation).
# Differences from the missile:
#   - Much larger model and a correspondingly large "hittable hull" — the
#     CharacterBody3D's own collision shape — so player gun/sword aim feels
#     honest against the visible body.
#   - Subtle weave instead of the missile's braided Itano demand.
#   - Reduced loft so the trajectory is closer to a direct vector-on-target.
#   - Blackish-gray two-color trail in place of the per-crystal cyan/pink.
#   - HP — exposed take_damage so gun bullets and sword swings can destroy it
#     before it reaches the player.
#   - Body-vs-area split: the CharacterBody3D itself is the wide hittable hull;
#     a child Area3D with a MISSILE-sized sphere handles the player-damage
#     trigger, so the player only takes damage when they're actually close to
#     the fish's core (same distance the missile uses), not just brushing its
#     outer silhouette.

const BLOGGLING_MODEL_PATH: String = "res://assets/models/bloggling.glb"
const ExplosionScene := preload("res://entities/leviathan/leviathan_fish_explosion.gd")

# Same flight tuning as the missile so the algorithm is unchanged; only the
# weave and loft are dialed down for a straighter approach. Cruise and boost
# speeds are 1.5x the missile's tuning so the fish closes faster than a
# normal homing round once it commits.
const BOOST_SPEED: float = 16.0
const CRUISE_SPEED: float = 28.0
const N_NAV: float = 4.0
const MAX_LATERAL_ACCEL: float = 180.0
const BOOST_DURATION: float = 0.55
const LIFETIME: float = 14.0
const FISH_PROJECTILE_DAMAGE: int = 4

# Loft kept very low so the fish skims toward the target near the ground
# instead of climbing high and diving. The aim point sits only ~2 m above the
# target at long range and collapses to ground level as it closes.
const LOFT_ALTITUDE: float = 2.0
const LOFT_RANGE_FULL: float = 55.0
const LOFT_RANGE_ZERO: float = 12.0
const TERMINAL_RANGE: float = 9.0
const HOMING_CUTOFF: float = 9.0

const PURSUIT_ACCEL: float = 75.0
const V_C_FLOOR_FRAC: float = 0.5
const T_GO_FLOOR: float = 0.05
const T_GO_CEIL: float = 8.0
const TARGET_VEL_BANDWIDTH: float = 3.5
const TARGET_ACC_BANDWIDTH: float = 1.2

# Visible-but-not-frantic weave — about a third of the missile's amplitude
# and a calmer frequency, so the fish swings off-axis enough to read as a
# weaving animal without braiding like the missile salvo. Fades on the same
# t_go schedule.
const WEAVE_AMP: float = 48.0
const WEAVE_FREQ: float = 3.5
const WEAVE_TGO_FULL: float = 1.2
const WEAVE_TGO_FADE: float = 0.40

const OFF_MAP_RADIUS: float = 700.0
const OFF_MAP_Y_FLOOR: float = -200.0

# Fish sizing — large enough that the projectile reads as a destructible
# obstacle in the player's lane, not as another missile.
const CRYSTAL_LENGTH: float = 27.0
const GEM_EMISSION_SCALE: float = 0.20
const CRYSTAL_SPIN_RATE: float = 2.6
# Speed multiplier applied to the model's authored animation. The bloggling
# rig comes with a slow swim cycle that reads as inert at native speed; 3x
# makes its body visibly thrash so the projectile registers as alive on
# approach.
const FISH_ANIM_SPEED: float = 3.0

# Blackish-gray trail. Boost color is a slightly brighter charcoal so the
# launch ignition still reads; cruise color is deep near-black.
const BOOST_COLOR: Color = Color(0.42, 0.42, 0.44, 1.0)
const CRUISE_COLOR: Color = Color(0.08, 0.08, 0.10, 1.0)

const TRAIL_SAMPLES: int = 120
const TRAIL_SAMPLE_INTERVAL: float = 0.024
const TRAIL_WIDTH_CRUISE: float = 0.12
const TRAIL_WIDTH_BOOST: float = 0.20

const FLASH_DURATION: float = 0.15
const FLASH_ENERGY: float = 1.8
const FLASH_RANGE: float = 6.0
const CRUISE_LIGHT_ENERGY: float = 0.30
const CRUISE_LIGHT_RANGE: float = 3.2

# Player-destroyable. HP roughly: 6 gun shots (2 dmg each) or 2 strong sword
# hits — enough that it can't be no-sold, low enough that a coordinated player
# clears the pair before they arrive.
const MAX_HP: int = 12
const HIT_FLASH_DURATION: float = 0.10
const HIT_FLASH_COLOR: Color = Color(1.0, 0.85, 0.85, 1.0)

# Hittable hull radius (the CharacterBody3D's own shape) — what the player's
# gun and sword box-cast collide with. Sized to roughly match the visible
# bloggling silhouette so player aim reads as honest. Scales with CRYSTAL_LENGTH.
const HITTABLE_RADIUS: float = 9.0
# Player-damage trigger radius (the inner child Area3D). Deliberately matched
# to leviathan_missile.gd's collision sphere so a player only takes damage
# from this fish at the same proximity a missile would deal it — the giant
# visible hull is for shooting it down, not for being hit by it.
const PLAYER_HIT_RADIUS: float = 0.32

enum Phase { BOOST, HOMING }

var shooter: Node = null
var target: Node3D = null
var weave_phase: float = 0.0
var weave_spin: float = 1.0

var _velocity: Vector3 = Vector3.ZERO
var _phase: int = Phase.BOOST
var _age: float = 0.0
var _phase_age: float = 0.0
var _flash_age: float = 0.0
var _hp: int = MAX_HP
var _hit_flash_remaining: float = 0.0
var _hit_targets: Array = []

var _est_pos_prev: Vector3 = Vector3.ZERO
var _est_vel: Vector3 = Vector3.ZERO
var _est_acc: Vector3 = Vector3.ZERO
var _est_seeded: bool = false

var _gem_root: Node3D
var _gem_scale: Vector3 = Vector3.ONE
var _gem_spin_rate: float = 0.0
var _gem_spin_angle: float = 0.0
var _trail_root: Node3D
var _trail_mi: MeshInstance3D
var _trail_mesh: ImmediateMesh
var _trail_mat: StandardMaterial3D
var _trail_points: PackedVector3Array = PackedVector3Array()
var _trail_phase_at: PackedFloat32Array = PackedFloat32Array()
var _sample_cd: float = 0.0
var _light: OmniLight3D
var _player_detector: Area3D


func setup(at: Vector3, initial_dir: Vector3, src: Node, tgt: Node3D, phase: float = 0.0, spin: float = 1.0) -> void:
	global_position = at
	shooter = src
	target = tgt
	weave_phase = phase
	weave_spin = signf(spin) if spin != 0.0 else 1.0
	_gem_spin_rate = CRYSTAL_SPIN_RATE * weave_spin
	if initial_dir.length_squared() > 0.0:
		_velocity = initial_dir.normalized() * BOOST_SPEED
		look_at(global_position + _velocity, _safe_up(_velocity))
	_build_visual()
	_build_trail()
	_build_light()


func _ready() -> void:
	# Layer 4 = bit 2 (project's "layer 3" slot, same one the boss occupies in
	# addition to layer 1). Player gun's Area3D uses mask=5 (layers 1+3) and
	# its body_entered fires on PhysicsBody3D entrants — we're a CharacterBody3D
	# now, so it picks us up. Sword's shape-query (collide_with_bodies=true,
	# default all-layers mask) also picks us up. Leviathan beams/missiles only
	# mask layer 1, so they don't friendly-fire this fish.
	#
	# collision_mask = 0 because we don't want CharacterBody3D's own physics
	# resolution to fight the homing math — we set global_position directly
	# in _integrate and want to fly through terrain/players unimpeded.
	collision_layer = 4
	collision_mask = 0
	_build_hittable_hull()
	_build_player_detector()


func _physics_process(delta: float) -> void:
	_age += delta
	_phase_age += delta
	_flash_age += delta
	if _hit_flash_remaining > 0.0:
		_hit_flash_remaining = maxf(_hit_flash_remaining - delta, 0.0)

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


func _advance_phase() -> void:
	if _phase == Phase.BOOST and _age >= BOOST_DURATION:
		_phase = Phase.HOMING
		_phase_age = 0.0


func _compute_command() -> Vector3:
	match _phase:
		Phase.BOOST:
			var ramp_t: float = clampf(_age / BOOST_DURATION, 0.0, 1.0)
			var desired_speed: float = lerp(BOOST_SPEED, CRUISE_SPEED, ramp_t)
			var cur_speed: float = _velocity.length()
			if cur_speed > 1e-6:
				var dv: float = desired_speed - cur_speed
				return _velocity.normalized() * (dv * 12.0)
			return Vector3.ZERO
		Phase.HOMING:
			if target == null or not is_instance_valid(target):
				return Vector3.ZERO
			var range_to_target: float = (target.global_position - global_position).length()
			if range_to_target <= HOMING_CUTOFF:
				return Vector3.ZERO
			var loft_factor: float = smoothstep(LOFT_RANGE_ZERO, LOFT_RANGE_FULL, range_to_target)
			var aim_pos: Vector3 = target.global_position + Vector3.UP * (LOFT_ALTITUDE * loft_factor)
			var terminal: bool = range_to_target <= TERMINAL_RANGE
			return _apn_guidance(aim_pos, terminal)
	return Vector3.ZERO


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


func _apn_guidance(aim_pos: Vector3, terminal: bool) -> Vector3:
	var R: Vector3 = aim_pos - global_position
	var range_sq: float = R.length_squared()
	if range_sq < 1e-6:
		return Vector3.ZERO
	var range_m: float = sqrt(range_sq)
	var R_hat: Vector3 = R / range_m

	var V_r: Vector3 = _est_vel - _velocity
	var V_c: float = -R_hat.dot(V_r)
	var V_c_eff: float = maxf(V_c, CRUISE_SPEED * V_C_FLOOR_FRAC)
	var t_go: float = clampf(range_m / V_c_eff, T_GO_FLOOR, T_GO_CEIL)

	var ZEM: Vector3 = R + V_r * t_go
	var ZEM_perp: Vector3 = ZEM - ZEM.dot(R_hat) * R_hat
	var a_t_perp: Vector3 = _est_acc - _est_acc.dot(R_hat) * R_hat
	var a_pursuit: Vector3 = R_hat * PURSUIT_ACCEL
	var a_guidance: Vector3 = (N_NAV / (t_go * t_go)) * ZEM_perp + (0.5 * N_NAV) * a_t_perp + a_pursuit

	# Subtle sinusoidal lateral demand on top of guidance — same shape as the
	# missile's Itano weave but ~5x smaller amplitude, calmer frequency, and
	# forced off in terminal so the kill-arc reads as deliberate.
	var a_weave: Vector3 = Vector3.ZERO
	if not terminal and WEAVE_AMP > 0.0:
		var weave_fade: float = smoothstep(WEAVE_TGO_FADE, WEAVE_TGO_FULL, t_go)
		if weave_fade > 0.0:
			var fwd: Vector3 = _velocity.normalized()
			var up_ref: Vector3 = Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
			var right: Vector3 = fwd.cross(up_ref).normalized()
			var up: Vector3 = right.cross(fwd).normalized()
			var t_local: float = _age - BOOST_DURATION
			var angle: float = WEAVE_FREQ * weave_spin * t_local + weave_phase
			var weave_dir: Vector3 = cos(angle) * right + sin(angle) * up
			a_weave = (WEAVE_AMP * weave_fade) * weave_dir

	return _saturate(a_guidance, a_weave)


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


func _integrate(a_cmd: Vector3, delta: float) -> void:
	_velocity += a_cmd * delta
	if _velocity.length_squared() <= 1e-6:
		return
	if _phase != Phase.BOOST:
		_velocity = _velocity.normalized() * CRUISE_SPEED
	look_at(global_position + _velocity, _safe_up(_velocity))
	global_position += _velocity * delta


func _build_visual() -> void:
	var packed: PackedScene = load(BLOGGLING_MODEL_PATH) as PackedScene
	if packed == null:
		push_warning("[LeviathanFishProjectile] failed to load %s" % BLOGGLING_MODEL_PATH)
		return
	var instance: Node = packed.instantiate()
	if instance == null or not (instance is Node3D):
		push_warning("[LeviathanFishProjectile] fish scene did not instantiate as Node3D")
		return
	_gem_root = instance as Node3D
	add_child(_gem_root)
	_normalize_gem_size(_gem_root)
	_gem_scale = _gem_root.scale
	_start_fish_animation(_gem_root)
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


# Find the imported AnimationPlayer (if any) and play the first authored
# animation in a loop at FISH_ANIM_SPEED. Mirrors the same pattern the boss
# uses for its swim cycle in ghost_leviathan.gd.
func _start_fish_animation(model: Node3D) -> void:
	var ap: AnimationPlayer = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap == null:
		return
	var names: PackedStringArray = ap.get_animation_list()
	if names.size() == 0:
		return
	var pick: String = names[0]
	var anim: Animation = ap.get_animation(pick)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR
	ap.speed_scale = FISH_ANIM_SPEED
	ap.play(pick)


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


func _gather_mesh_instances(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_gather_mesh_instances(c))
	return out


func _gather_visual_instances(n: Node) -> Array:
	var out: Array = []
	if n is VisualInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_gather_visual_instances(c))
	return out


func _transform_to_ancestor(node: Node3D, ancestor: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != ancestor:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


# The CharacterBody3D's own collision shape — sized to the visible fish so
# player aim reads as honest. This is the volume the player's gun + sword
# detect as "the fish"; damage (take_damage) lands when their attack
# overlaps this hull.
func _build_hittable_hull() -> void:
	var sph := SphereShape3D.new()
	sph.radius = HITTABLE_RADIUS
	var cs := CollisionShape3D.new()
	cs.shape = sph
	add_child(cs)


# Child Area3D that detects the player at the same close radius the missile
# uses (PLAYER_HIT_RADIUS = 0.32). Keeping this separate from the wide
# hittable hull means the player can drift through the fish's silhouette
# without being hit — they only take damage when the small inner sphere
# actually touches them, matching leviathan_missile.gd's feel.
func _build_player_detector() -> void:
	_player_detector = Area3D.new()
	_player_detector.collision_layer = 0
	_player_detector.collision_mask = 1
	_player_detector.monitoring = true
	var sph := SphereShape3D.new()
	sph.radius = PLAYER_HIT_RADIUS
	var cs := CollisionShape3D.new()
	cs.shape = sph
	_player_detector.add_child(cs)
	add_child(_player_detector)
	_player_detector.body_entered.connect(_on_player_detected)


func _build_trail() -> void:
	_trail_root = Node3D.new()
	_trail_root.top_level = true
	add_child(_trail_root)
	_trail_mat = StandardMaterial3D.new()
	_trail_mat.albedo_color = CRUISE_COLOR
	_trail_mat.emission_enabled = true
	_trail_mat.emission = CRUISE_COLOR
	_trail_mat.emission_energy_multiplier = 0.9
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
	_light.light_color = BOOST_COLOR
	_light.light_energy = FLASH_ENERGY
	_light.omni_range = FLASH_RANGE
	add_child(_light)


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
	# The bloggling model is authored with its forward face on local +X (not
	# +Y like the missile gems). Build a right-handed basis with column.x =
	# aim_dir so the model's +X axis points at the target each frame. column.y
	# is a stable up-perpendicular; column.z = x × y closes the basis. Rifling
	# is still applied as a rotation around aim_dir (now the head→tail axis).
	var up_ref: Vector3 = Vector3.UP if absf(aim_dir.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	var y_axis: Vector3 = up_ref.cross(aim_dir).normalized()
	var z_axis: Vector3 = aim_dir.cross(y_axis).normalized()
	var oriented: Basis = Basis(aim_dir, y_axis, z_axis)
	var rifled: Basis = Basis(Quaternion(aim_dir, _gem_spin_angle)) * oriented
	rifled.x *= _gem_scale.x
	rifled.y *= _gem_scale.y
	rifled.z *= _gem_scale.z
	_gem_root.global_basis = rifled


func _update_light() -> void:
	if _light == null:
		return
	# Hit-flash overrides the normal light state for a brief moment so the
	# player gets clear feedback that a shot landed.
	if _hit_flash_remaining > 0.0:
		var f: float = _hit_flash_remaining / HIT_FLASH_DURATION
		_light.light_color = HIT_FLASH_COLOR
		_light.light_energy = FLASH_ENERGY * (0.6 + 0.4 * f)
		_light.omni_range = FLASH_RANGE
		return
	if _flash_age < FLASH_DURATION:
		var f2: float = 1.0 - (_flash_age / FLASH_DURATION)
		_light.light_color = BOOST_COLOR
		_light.light_energy = lerp(CRUISE_LIGHT_ENERGY, FLASH_ENERGY, f2 * f2)
		_light.omni_range = lerp(CRUISE_LIGHT_RANGE, FLASH_RANGE, f2)
		return
	if _phase == Phase.BOOST:
		_light.light_color = BOOST_COLOR
		_light.light_energy = CRUISE_LIGHT_ENERGY
		_light.omni_range = CRUISE_LIGHT_RANGE + 0.6
	else:
		_light.light_color = CRUISE_COLOR
		_light.light_energy = CRUISE_LIGHT_ENERGY * 0.75
		_light.omni_range = CRUISE_LIGHT_RANGE


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
		var seg_col: Color = BOOST_COLOR if is_boost else CRUISE_COLOR
		var seg_width: float = TRAIL_WIDTH_BOOST if is_boost else TRAIL_WIDTH_CRUISE
		var width: float = seg_width * t
		var alpha: float = 0.55 + 0.45 * t * t
		var col := Color(seg_col.r, seg_col.g, seg_col.b, alpha)
		_trail_mesh.surface_set_color(col)
		_trail_mesh.surface_add_vertex(p + side * width)
		_trail_mesh.surface_set_color(col)
		_trail_mesh.surface_add_vertex(p - side * width)
	_trail_mesh.surface_end()


# Player weapons call take_damage on whatever they hit. Subtract HP, flash,
# and self-destruct on zero — the fish is gone, no impact damage to the player.
func take_damage(amount: int, _direction: Vector3) -> void:
	_hp = maxi(_hp - amount, 0)
	_hit_flash_remaining = HIT_FLASH_DURATION
	if _hp <= 0:
		_spawn_explosion()
		queue_free()


func _on_player_detected(body: Node) -> void:
	if body == shooter:
		return
	if _age <= 0.0:
		return
	if body in _hit_targets:
		return
	_hit_targets.append(body)
	if body.has_method("take_damage"):
		body.take_damage(FISH_PROJECTILE_DAMAGE, _velocity.normalized())
	_spawn_explosion()
	queue_free()


# Detach the explosion from `self` (we're about to queue_free) by reparenting
# it to the current scene; otherwise the explosion's lifetime would be tied
# to this projectile and it would vanish on the same frame as the spawn.
# Random orientation is assigned inside ExplosionScene.setup so each blast
# reads as a different angle of the same authored sim.
func _spawn_explosion() -> void:
	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		return
	var fx: Node3D = ExplosionScene.new() as Node3D
	scene_root.add_child(fx)
	fx.setup(global_position)


func _safe_up(d: Vector3) -> Vector3:
	if absf(d.dot(Vector3.UP)) > 0.99:
		return Vector3.FORWARD
	return Vector3.UP
