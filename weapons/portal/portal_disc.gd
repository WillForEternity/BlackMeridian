class_name PortalDisc
extends Area3D

# Slow-to-fast homing washer. Speed ramps with proximity to target: at >=
# FAR_DIST it crawls at SLOW_SPEED; within MAX_SPEED_DIST (two katana slices
# from the target) it matches a gun projectile. Initial launch is throttled
# to one third of whatever the curve calls for so the disc visibly emerges.
const SLOW_SPEED: float = 3.0
const MAX_SPEED: float = 44.0
const FAR_DIST: float = 30.0
const MAX_SPEED_DIST: float = 2.9  # 2 × Player.SWORD_SLICE_DISTANCE
const LAUNCH_THROTTLE: float = 1.0 / 3.0
const LAUNCH_RAMP_TIME: float = 0.45
# Two homing modes: a sloppy drift while the disc is still ramping (so it
# wanders rather than locking onto whatever happens to be nearest), and a
# tighter zoom turn rate once it commits to the final lunge. Zoom is exactly
# 2× the drift rate. Even at zoom it can still miss tight angles.
const TURN_RATE_DRIFT: float = 0.55  # rad/sec — non-zoom approximate homing
const TURN_RATE_ZOOM: float = 2.20   # rad/sec — zoom mode, 2× tighter than before
const ZOOM_RATIO_THRESHOLD: float = 0.55  # speed-ratio above which zoom homing kicks in
# After a miss the disc has overshot and is now slow + facing the wrong way.
# Drift homing is too weak to bend back in a reasonable time, so we grant a
# short window where the zoom turn rate applies regardless of current speed —
# enough for the disc to wheel around for another pass and naturally re-enter
# zoom mode as it closes on the target again.
const RECOVER_TIME: float = 1.4
const LIFETIME: float = 15.0
const RAMP_EXPONENT: float = 12.0  # higher = longer slow tail, sharper final lunge
const BASE_TINT: Color = Color(1.0, 0.95, 0.55, 1.0)
const MAX_TINT: Color = Color(0.35, 0.95, 1.0, 1.0)
const DAMAGE: int = 12  # railgun-level
const MAX_HEALTH: int = 2  # the only player projectile that can be shot down

var is_outer: bool = false
var direction: Vector3 = Vector3.FORWARD
var shooter: Node = null
var source_weapon: Node = null
var health: int = MAX_HEALTH
var _target: Node3D = null
var _age: float = 0.0
var _despawning: bool = false
var _split_offset: Vector3 = Vector3.ZERO
var _at_max: bool = false
# Tracks the closest we've ever been to the current target. When the gap
# starts growing again after a near pass, we treat it as a miss and reset to
# slow-search mode so the disc doesn't orbit forever at max speed.
var _min_target_dist: float = INF
var _recover_time_left: float = 0.0
# Counts completed zoom-homing attempts that ended in a miss. After the
# second miss the disc self-destructs instead of looping forever. Hits
# despawn the disc on contact, so this only governs misses.
const MAX_ZOOM_ATTEMPTS: int = 2
var _zoom_attempts: int = 0

var _ring_pivot: Node3D
var _ring: MeshInstance3D
var _light: OmniLight3D

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	_build_visuals()
	_build_collision()

func _build_collision() -> void:
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	# Sized to match the new ring radius so a target inside the ring still
	# registers a hit, but small enough that flybys can genuinely miss.
	sphere.radius = 0.85
	col.shape = sphere
	add_child(col)
	# layer 8 = projectiles, layer 16 = destructible_projectiles. The disc sits
	# on its own destructible layer (NOT the enemy layer) so the player's aim
	# ray and dash can't snap to their own shots, while a hostile attacker can
	# still hitscan/sphere-query for layer-5 bodies and call take_damage on
	# them. As an Area3D the disc is monitorable by default, so an enemy fire
	# Area3D can also catch it via area_entered.
	#
	# Destruction math (HP = 2):
	#   gun projectile  (dmg 2)  → 1 ring per shot, so 2 shots kill the pair
	#   katana strike   (dmg 2+) → 1 ring per body it touches in the swing
	#   railgun shot    (dmg 12) → obliterates any ring it hits
	collision_layer = 8 | 16
	# Mask = players (2) + enemies (4). World is deliberately excluded — the
	# disc passes through terrain and only terminates when it touches a real
	# target. Lifetime + miss-reset handle the "no target ever" case.
	collision_mask = 2 | 4

func _build_visuals() -> void:
	_ring_pivot = Node3D.new()
	add_child(_ring_pivot)
	# One extruded washer per disc — the inner/outer pair makes the "nested
	# discs" shape the weapon spec calls for.
	_ring = _make_ring()
	_ring_pivot.add_child(_ring)
	_light = OmniLight3D.new()
	_light.light_color = BASE_TINT
	_light.light_energy = 3.0
	_light.omni_range = 5.5
	add_child(_light)

func _make_ring() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var torus := TorusMesh.new()
	# Bigger radius, same band thickness (girth = outer - inner = 0.14 as
	# before).
	torus.inner_radius = 0.60
	torus.outer_radius = 0.90
	torus.rings = 28
	torus.ring_segments = 14
	mi.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.albedo_color = BASE_TINT
	mat.emission_enabled = true
	mat.emission = BASE_TINT
	mat.emission_energy_multiplier = 5.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.set_surface_override_material(0, mat)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func setup(outer: bool, dir: Vector3, target: Node3D, shooter_node: Node, weapon: Node) -> void:
	is_outer = outer
	direction = dir.normalized() if dir.length() > 0.001 else Vector3.FORWARD
	_target = target
	shooter = shooter_node
	source_weapon = weapon
	_apply_size()

func _apply_size() -> void:
	# Inner disc fits inside the outer's hole — scaled so the smaller ring sits
	# concentrically inside the larger one at spawn time.
	var s := 1.35 if is_outer else 0.78
	_ring_pivot.scale = Vector3.ONE * s

func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		_despawn()
		return

	_recover_time_left = maxf(_recover_time_left - delta, 0.0)
	var speed := _compute_speed()
	var ratio: float = clampf((speed - SLOW_SPEED) / (MAX_SPEED - SLOW_SPEED), 0.0, 1.0)
	_steer_toward_target(delta, ratio)
	_check_miss()
	global_position += direction * speed * delta + _split_offset * delta

	# The whole disc spins around its own face plus a slower tumble so it reads
	# as a 3D washer from any angle.
	_ring_pivot.rotate(Vector3(0, 0, 1), delta * (5.0 if is_outer else 7.5))
	_ring_pivot.rotate(Vector3(1, 0, 0), delta * (1.4 if is_outer else 2.1))

	_update_visuals(speed)

func _compute_speed() -> float:
	var dist := _distance_to_target()
	var base: float
	if dist <= MAX_SPEED_DIST:
		base = MAX_SPEED
	elif dist >= FAR_DIST:
		base = SLOW_SPEED
	else:
		var t := (FAR_DIST - dist) / (FAR_DIST - MAX_SPEED_DIST)
		# Higher exponent → longer near-stationary drift, sharper final lunge.
		t = pow(clampf(t, 0.0, 1.0), RAMP_EXPONENT)
		base = lerpf(SLOW_SPEED, MAX_SPEED, t)
	if is_outer:
		base *= 0.92  # outer ring trails behind inner at high end
	var throttle: float = lerpf(LAUNCH_THROTTLE, 1.0, clampf(_age / LAUNCH_RAMP_TIME, 0.0, 1.0))
	return base * throttle

func _distance_to_target() -> float:
	if _target == null or not is_instance_valid(_target):
		_target = _find_nearest_target()
		_min_target_dist = INF
	if _target == null:
		return FAR_DIST
	return global_position.distance_to(_target.global_position)

func _steer_toward_target(delta: float, speed_ratio: float) -> void:
	if _target == null or not is_instance_valid(_target):
		_target = _find_nearest_target()
		_min_target_dist = INF
	if _target == null:
		return
	var to_t := (_target.global_position - global_position)
	if to_t.length() < 0.001:
		return
	var desired := to_t.normalized()
	# Pick turn rate based on whether the disc has committed to its zoom.
	# Below the threshold it drifts approximately — it will not aggressively
	# vacuum onto whatever's nearby. Above it, it homes ~2× tighter, but the
	# rate is still capped so a sharply-angled flyby can miss.
	# Use zoom turn rate while actively zooming OR during the post-miss recovery
	# window — both situations need tighter homing than the lazy drift mode.
	var zooming: bool = speed_ratio >= ZOOM_RATIO_THRESHOLD or _recover_time_left > 0.0
	var turn_rate: float = TURN_RATE_ZOOM if zooming else TURN_RATE_DRIFT
	direction = direction.slerp(desired, clampf(turn_rate * delta, 0.0, 1.0)).normalized()

func _check_miss() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var d := global_position.distance_to(_target.global_position)
	if d < _min_target_dist:
		_min_target_dist = d
	# Miss = we got close enough to be in the "max speed" zone, then started
	# pulling away from the target. Drop the lock so the disc reverts to slow
	# drift and re-acquires whichever target is now nearest.
	var close_enough := _min_target_dist < MAX_SPEED_DIST * 1.8
	var pulling_away := d > _min_target_dist + 1.2
	if close_enough and pulling_away:
		_zoom_attempts += 1
		if _zoom_attempts >= MAX_ZOOM_ATTEMPTS:
			Vfx.impact_burst(global_position, 1.1, BASE_TINT)
			_despawn()
			return
		_target = null
		_min_target_dist = INF
		_at_max = false
		_split_offset = Vector3.ZERO
		_recover_time_left = RECOVER_TIME

func _find_nearest_target() -> Node3D:
	# Sphere-cast on the enemies physics layer (4). Discs are also on layer 4
	# now, so filter ourselves out below.
	var world := get_world_3d()
	if world == null:
		return null
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = 80.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis.IDENTITY, global_position)
	q.collision_mask = 4
	var excl: Array[RID] = [self.get_rid()]
	if shooter != null and shooter.has_method("get_rid"):
		excl.append(shooter.get_rid())
	q.exclude = excl
	var hits: Array = space.intersect_shape(q, 32)
	var best: Node3D = null
	var best_d := INF
	for h in hits:
		var col := h.collider as Node3D
		if col == null or col == shooter or col == self:
			continue
		# Skip other portal discs so they don't lock onto each other.
		if col is PortalDisc:
			continue
		var d := global_position.distance_squared_to(col.global_position)
		if d < best_d:
			best_d = d
			best = col
	return best

func _update_visuals(current_speed: float) -> void:
	var ratio: float = clampf((current_speed - SLOW_SPEED) / (MAX_SPEED - SLOW_SPEED), 0.0, 1.0)
	var thresh := 0.78 if is_outer else 0.92
	var at_max := ratio >= thresh
	if at_max and not _at_max:
		_at_max = true
		_on_reach_max()
	# After a reset (miss), drop back to base appearance even if the disc is
	# still moving fast for a frame.
	if not at_max and _at_max and _target == null:
		_at_max = false
		_split_offset = Vector3.ZERO
	var c: Color = BASE_TINT.lerp(MAX_TINT, ratio)
	_set_ring_color(c, 4.0 + ratio * 10.0)
	_light.light_color = c
	_light.light_energy = 2.5 + ratio * 6.0

func _on_reach_max() -> void:
	if is_outer:
		var lateral := Vector3(randf_range(-1, 1), randf_range(-0.4, 0.4), randf_range(-1, 1))
		if lateral.length() < 0.01:
			lateral = Vector3.RIGHT
		_split_offset = lateral.normalized() * 0.9
	else:
		_split_offset = direction * 0.6

func _set_ring_color(c: Color, emission_mult: float) -> void:
	var mat := _ring.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = Color(c.r, c.g, c.b, mat.albedo_color.a)
	mat.emission = c
	mat.emission_energy_multiplier = emission_mult

# Called by anything that can damage the disc (currently nothing fires at the
# player, but the API is wired up so the disc is the only player projectile
# with HP). `_dir` is unused but matches the take_damage(amount, dir) contract
# the rest of the codebase uses.
func take_damage(amount: int, _dir: Vector3) -> void:
	if _despawning:
		return
	health -= amount
	if health <= 0:
		Vfx.impact_burst(global_position, 1.1, BASE_TINT)
		_despawn()

func _on_body_entered(body: Node) -> void:
	if _despawning or body == shooter or body == self:
		return
	# Ignore other portal discs entirely — overlapping rings shouldn't pop
	# each other.
	if body is PortalDisc:
		return
	if body.has_method("take_damage"):
		body.take_damage(DAMAGE, direction)
		if source_weapon != null and is_instance_valid(source_weapon) and source_weapon.has_method("add_super_charge"):
			source_weapon.add_super_charge(float(DAMAGE))
	Vfx.impact_burst(global_position, 1.4, MAX_TINT)
	_despawn()

func _despawn() -> void:
	if _despawning:
		return
	_despawning = true
	set_deferred("monitoring", false)
	queue_free()
