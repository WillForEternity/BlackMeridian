extends CharacterBody3D

enum WeaponSlot { SWORD, GUN, SNIPER, PORTAL_LIGHT, PORTAL_DARK }
enum ViewMode { THIRD_PERSON, FIRST_PERSON }

signal weapon_changed(weapon: int)
signal charge_changed(value: float)

@export var speed: float = 8.5
@export var jump_velocity: float = 5.5
# Jump feel — coyote grace after walking off a ledge, falling-gravity boost
# for a less floaty arc, and an early-release cut so tapping jump produces a
# shorter hop than holding it.
const COYOTE_TIME: float = 0.12
const FALL_GRAVITY_MULT: float = 1.65
const JUMP_CUT_FACTOR: float = 0.45
# Horizontal movement accel/decel (m/s²). Velocity isn't set instantly from
# input; it interpolates toward the input-derived target speed. Air values are
# lower so jumps preserve momentum (releasing keys mid-air doesn't kill speed)
# and a hard direction change in the air has visible inertia.
const GROUND_ACCEL: float = 80.0
const GROUND_DECEL: float = 80.0
const AIR_ACCEL: float = 25.0
const AIR_DECEL: float = 3.0
@export var dash_speed: float = 44.0
@export var dash_duration: float = 0.18
@export var dash_cooldown: float = 0.9
# Forward reach of the sword swing hitbox (front face at z ≈ -1.45 in local space).
const SWORD_SLICE_DISTANCE: float = 1.45
@export var mouse_sensitivity: float = 0.0028
@export var pitch_min_deg: float = -85.0
@export var pitch_max_deg: float = 85.0
# Third-person camera collision: leave this much air between camera and surface.
const CAM_COLLISION_MARGIN: float = 0.25

@export var sword_path: NodePath
@export var gun_path: NodePath
@export var sniper_path: NodePath
@export var portal_light_path: NodePath
@export var portal_dark_path: NodePath

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var current_slot: WeaponSlot = WeaponSlot.SWORD
var current_weapon_node: Node = null
var view_mode: ViewMode = ViewMode.THIRD_PERSON
var dash_time_left: float = 0.0
var dash_cd_left: float = 0.0
var dash_dir: Vector3 = Vector3.ZERO
var lift_time_left: float = 0.0
var lift_velocity_y: float = 0.0
var camera_pitch: float = 0.0
var base_fov: float = 75.0
var _consume_next_click: bool = false

const CAM_POS_3P := Vector3(0.5, 0.4, 4.5)
const CAM_POS_1P := Vector3(0.0, 0.0, 0.0)

@onready var body_mesh: MeshInstance3D = $Body
@onready var weapon_pivot: Node3D = $WeaponPivot
@onready var pitch_pivot: Node3D = $CameraPitchPivot
@onready var camera: Camera3D = $CameraPitchPivot/Camera3D
@onready var fpv_pivot: Node3D = $CameraPitchPivot/Camera3D/FPVPivot

@onready var _sword: Node = get_node(sword_path)
@onready var _gun: Node = get_node(gun_path)
@onready var _sniper: Node = get_node(sniper_path)
@onready var _portal_light: Node = get_node(portal_light_path)
@onready var _portal_dark: Node = get_node(portal_dark_path)
@onready var _weapons: Array[Node] = [_sword, _gun, _sniper, _portal_light, _portal_dark]

# Tracks extra mid-air jumps consumed since last ground contact. Weapons can
# report a higher allowance via `extra_air_jumps()`.
var _air_jumps_used: int = 0
var _coyote_left: float = 0.0
# Horizontal velocity inherited from a moving platform at the moment of takeoff.
# Added to input-driven velocity while airborne so jumping off a moving target
# carries its momentum across the jump arc.
var _air_carry_velocity: Vector3 = Vector3.ZERO
# Player-controlled horizontal velocity (the part that responds to WASD).
# Tracked separately from `velocity` so we can apply per-frame accel/decel
# rather than overwriting velocity from input each tick; this is what gives
# air movement weight and momentum.
var _controlled_velocity: Vector3 = Vector3.ZERO
# Replaces Godot's automatic moving-platform velocity (which leaks wall-body
# velocity onto the player). We read get_collider_velocity() on whichever
# slide collision is a true floor contact (normal within floor_max_angle of
# UP) and use it for both on-platform carry and jump-takeoff momentum.
var _floor_platform_velocity: Vector3 = Vector3.ZERO

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Generous so the player can walk up rocky ridge slopes. The cylinder
	# side-drag bug that previously needed a 30° cap is now handled by the
	# manual platform-velocity system below (which only fires on true floor
	# contacts), so we don't need this to also gate that out.
	floor_max_angle = deg_to_rad(55.0)
	# Disable Godot's built-in moving-platform velocity inheritance entirely.
	# Empirically the engine grabs the wall body's velocity even when wall
	# layers is 0, causing the player to be dragged sideways by a moving
	# target whose side they're merely touching. We handle the on-top carry
	# ourselves below by reading the floor collider's velocity each frame.
	platform_floor_layers = 0
	platform_wall_layers = 0
	base_fov = camera.fov
	for w in _weapons:
		w.setup(self)
		# Base Weapon declares charge_changed, so this connection is always safe.
		w.charge_changed.connect(_on_weapon_charge_changed)
	current_weapon_node = _weapons[int(current_slot)]
	_apply_view_mode()
	_apply_weapon_visibility()

func _on_weapon_charge_changed(v: float) -> void:
	charge_changed.emit(v)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_consume_next_click = true
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		rotate_y(-mm.relative.x * mouse_sensitivity)
		camera_pitch = clampf(camera_pitch - mm.relative.y * mouse_sensitivity, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))
		pitch_pivot.rotation.x = camera_pitch

func _process(delta: float) -> void:
	dash_cd_left = maxf(dash_cd_left - delta, 0.0)

	if Input.is_action_just_pressed("equip_sword"):
		_equip(WeaponSlot.SWORD)
	if Input.is_action_just_pressed("equip_gun"):
		_equip(WeaponSlot.GUN)
	if Input.is_action_just_pressed("equip_sniper"):
		_equip(WeaponSlot.SNIPER)
	if Input.is_action_just_pressed("equip_portal_light"):
		_equip(WeaponSlot.PORTAL_LIGHT)
	if Input.is_action_just_pressed("equip_portal_dark"):
		_equip(WeaponSlot.PORTAL_DARK)
	if Input.is_action_just_pressed("toggle_view"):
		_toggle_view()
	if Input.is_action_just_pressed("weapon_guide"):
		EventBus.weapon_guide_toggled.emit(current_weapon_node.guide_text() if current_weapon_node else "")

	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if Input.is_action_just_pressed("attack"):
		if _consume_next_click:
			_consume_next_click = false
		else:
			current_weapon_node.on_attack_pressed()
	if Input.is_action_just_released("attack"):
		current_weapon_node.on_attack_released()
	if Input.is_action_just_pressed("super"):
		current_weapon_node.on_super_pressed()

func _physics_process(delta: float) -> void:
	if lift_time_left > 0.0:
		lift_time_left -= delta
		velocity.y = lift_velocity_y
	elif not is_on_floor():
		# Heavier gravity on the way down — keeps the jump arc snappy rather
		# than floaty without hurting the rising height.
		var g_mult: float = FALL_GRAVITY_MULT if velocity.y < 0.0 else 1.0
		velocity.y -= gravity * g_mult * delta

	var movement_locked: bool = current_weapon_node != null \
		and current_weapon_node.has_method("locks_movement") \
		and current_weapon_node.locks_movement()

	if is_on_floor():
		_air_jumps_used = 0
		_coyote_left = COYOTE_TIME
		_air_carry_velocity = Vector3.ZERO
	else:
		_coyote_left = maxf(_coyote_left - delta, 0.0)

	if Input.is_action_just_pressed("jump") and not movement_locked:
		if is_on_floor() or _coyote_left > 0.0:
			# Capture the platform's velocity so the jump retains horizontal
			# momentum across the arc. Use our manual tracking (the engine's
			# get_platform_velocity is now zero because we disabled it).
			_air_carry_velocity = Vector3(_floor_platform_velocity.x, 0.0, _floor_platform_velocity.z)
			velocity.y = jump_velocity
			_coyote_left = 0.0
		elif _air_jumps_used < _max_air_jumps():
			# Reset rather than add so the second/third jump feels equally
			# strong even if the disc was already falling.
			velocity.y = jump_velocity
			_air_jumps_used += 1

	# Variable jump height: releasing jump early cuts upward momentum. Skip
	# while a super is forcing a lift so the cut doesn't fight it.
	if Input.is_action_just_released("jump") and velocity.y > 0.0 and lift_time_left <= 0.0:
		velocity.y *= JUMP_CUT_FACTOR

	if Input.is_action_just_pressed("dash") and dash_cd_left <= 0.0 and not movement_locked:
		_start_dash()

	if dash_time_left > 0.0:
		# Cancel the dash if we're about to plow into an enemy: keep at least
		# half a sword-slice of space between the player capsule and the target.
		var min_gap := SWORD_SLICE_DISTANCE * 0.5
		var lookahead := dash_speed * delta + min_gap
		var d := _dash_target_distance(lookahead)
		if d >= 0.0 and d <= min_gap:
			dash_time_left = 0.0
			velocity.x = 0.0
			velocity.z = 0.0
			_controlled_velocity = Vector3.ZERO
		else:
			dash_time_left -= delta
			velocity.x = dash_dir.x * dash_speed
			velocity.z = dash_dir.z * dash_speed
			# Sync controlled velocity so accel-based control resumes from the
			# dash's exit speed rather than snapping back to the pre-dash value.
			# Scaled to half so the post-dash skid is shorter.
			_controlled_velocity = Vector3(velocity.x * 0.5, 0.0, velocity.z * 0.5)
	else:
		# Modern-action movement: build a target velocity from input and lerp
		# the player-controlled velocity toward it with separate ground/air
		# accel and decel rates. Keeps mid-jump momentum and gives weight to
		# mid-air direction changes.
		var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		if movement_locked:
			input_dir = Vector2.ZERO
		var target: Vector3 = transform.basis.x * input_dir.x + transform.basis.z * input_dir.y
		target.y = 0.0
		if target.length() > 0.0:
			target = target.normalized() * speed * _speed_multiplier()
		var grounded: bool = is_on_floor()
		if input_dir.length() > 0.01:
			var accel: float = GROUND_ACCEL if grounded else AIR_ACCEL
			var to_target: Vector3 = target - _controlled_velocity
			var step: float = accel * delta
			if to_target.length() > step:
				_controlled_velocity += to_target.normalized() * step
			else:
				_controlled_velocity = target
		else:
			var decel: float = GROUND_DECEL if grounded else AIR_DECEL
			var v_len: float = _controlled_velocity.length()
			var d_step: float = decel * delta
			if v_len > d_step:
				_controlled_velocity -= _controlled_velocity.normalized() * d_step
			else:
				_controlled_velocity = Vector3.ZERO
		velocity.x = _controlled_velocity.x
		velocity.z = _controlled_velocity.z
		# Layer the jump's inherited platform velocity on top while airborne.
		if not grounded:
			velocity.x += _air_carry_velocity.x
			velocity.z += _air_carry_velocity.z

	# Apply the floor's velocity (computed from last frame's slide collisions)
	# so the player rides moving targets on top. Only the floor contact's
	# velocity is used — wall contacts contribute nothing, so a target merely
	# brushing the player's side won't drag them.
	velocity.x += _floor_platform_velocity.x
	velocity.z += _floor_platform_velocity.z

	move_and_slide()

	# Re-read the floor velocity from this frame's collisions for the next tick.
	_floor_platform_velocity = _detect_floor_platform_velocity()
	# Undo the carry so the input layer starts clean next frame.
	velocity.x -= _floor_platform_velocity.x
	velocity.z -= _floor_platform_velocity.z

	_update_camera_collision()

# Pulls the third-person camera in along the pivot→camera ray if any solid
# surface is between the player and the camera's resting position. Keeps the
# camera from clipping into terrain when the player tilts steeply.
func _update_camera_collision() -> void:
	if view_mode == ViewMode.FIRST_PERSON:
		return
	var pivot_pos: Vector3 = pitch_pivot.global_position
	var target_local: Vector3 = CAM_POS_3P
	var target_world: Vector3 = pitch_pivot.global_transform * target_local
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(pivot_pos, target_world)
	query.exclude = [self.get_rid()]
	query.collide_with_areas = false
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		camera.position = target_local
		return
	# Pull camera back along the same direction by COLLISION_MARGIN.
	var ray: Vector3 = target_world - pivot_pos
	var ray_len: float = ray.length()
	if ray_len < 0.0001:
		return
	var hit_dist: float = pivot_pos.distance_to(hit.position)
	var safe_dist: float = maxf(hit_dist - CAM_COLLISION_MARGIN, 0.0)
	var safe_world: Vector3 = pivot_pos + ray.normalized() * safe_dist
	camera.position = pitch_pivot.to_local(safe_world)

func _detect_floor_platform_velocity() -> Vector3:
	if not is_on_floor():
		return Vector3.ZERO
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var angle: float = c.get_normal().angle_to(Vector3.UP)
		if angle <= floor_max_angle:
			return c.get_collider_velocity()
	return Vector3.ZERO

func _start_dash() -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := transform.basis.x * input_dir.x + transform.basis.z * input_dir.y
	dir.y = 0.0
	if dir.length() < 0.1:
		dir = -transform.basis.z
		dir.y = 0.0
	dash_dir = dir.normalized()

	# Default to the full dash duration, then shorten it if an enemy obstructs
	# the dash path so the player halts half a sword-slice in front of them.
	var duration := dash_duration
	var max_dist := dash_speed * dash_duration
	var hit_dist := _dash_target_distance(max_dist + SWORD_SLICE_DISTANCE)
	if hit_dist >= 0.0:
		var stop_dist := maxf(hit_dist - SWORD_SLICE_DISTANCE * 0.5, 0.0)
		duration = clampf(stop_dist / dash_speed, 0.0, dash_duration)

	dash_time_left = duration
	var cd_mult: float = 1.0
	if current_weapon_node and current_weapon_node.has_method("dash_cooldown_mult"):
		cd_mult = current_weapon_node.dash_cooldown_mult()
	dash_cd_left = dash_cooldown * cd_mult

	_play_dash_animation(duration)

# Returns the distance from the player to the nearest enemy obstruction along
# the current dash direction, or -1.0 if the path is clear within max_dist.
func _dash_target_distance(max_dist: float) -> float:
	var space := get_world_3d().direct_space_state
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 1.6
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis.IDENTITY, global_position)
	q.motion = dash_dir * max_dist
	q.exclude = [self.get_rid()]
	q.collision_mask = 4  # enemies
	var res := space.cast_motion(q)
	if res.is_empty():
		return -1.0
	var unsafe_fraction: float = res[1]
	if unsafe_fraction >= 1.0:
		return -1.0
	return unsafe_fraction * max_dist

func _play_dash_animation(duration: float) -> void:
	# Squash & stretch the body along the dash direction.
	var base_scale := body_mesh.scale
	var stretch := Vector3(base_scale.x * 0.7, base_scale.y * 0.85, base_scale.z * 1.45)
	var t := create_tween().set_parallel(false)
	t.tween_property(body_mesh, "scale", stretch, 0.05)
	t.tween_property(body_mesh, "scale", base_scale, maxf(duration, 0.12) + 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# FOV punch for speed feel.
	punch_fov(12.0, 0.05, 0.22)

	# Camera shake trauma if available.
	if camera.has_method("add_trauma"):
		camera.add_trauma(0.35)

	# Afterimage trail: spawn ghost copies of the body mesh that fade out.
	var ghost_count := 4
	for i in ghost_count:
		var delay := float(i) * (maxf(duration, 0.06) / float(ghost_count))
		get_tree().create_timer(delay, true, false, false).timeout.connect(_spawn_dash_ghost)

func _spawn_dash_ghost() -> void:
	if body_mesh == null or body_mesh.mesh == null:
		return
	var ghost := MeshInstance3D.new()
	ghost.mesh = body_mesh.mesh
	ghost.scale = body_mesh.scale
	get_parent().add_child(ghost)
	ghost.global_transform = body_mesh.global_transform
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.55, 0.85, 1.0, 0.55)
	mat.emission_enabled = true
	mat.emission = Color(0.4, 0.8, 1.0)
	mat.emission_energy_multiplier = 2.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost.material_override = mat
	var tw := create_tween().set_parallel(true)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.28)
	tw.tween_property(ghost, "scale", ghost.scale * 0.6, 0.28)
	tw.chain().tween_callback(ghost.queue_free)

func _max_air_jumps() -> int:
	if current_weapon_node != null and current_weapon_node.has_method("extra_air_jumps"):
		return current_weapon_node.extra_air_jumps()
	return 0

func _speed_multiplier() -> float:
	if current_weapon_node != null and current_weapon_node.has_method("speed_multiplier"):
		return current_weapon_node.speed_multiplier()
	return 1.0

func _toggle_view() -> void:
	view_mode = ViewMode.FIRST_PERSON if view_mode == ViewMode.THIRD_PERSON else ViewMode.THIRD_PERSON
	_apply_view_mode()

func _apply_view_mode() -> void:
	var first := view_mode == ViewMode.FIRST_PERSON
	camera.position = CAM_POS_1P if first else CAM_POS_3P
	# In first person we still want the body to throw a shadow on the ground —
	# SHADOWS_ONLY keeps the mesh invisible to the camera but lets the directional
	# light treat it as a normal occluder.
	body_mesh.visible = true
	body_mesh.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if first
		else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	)
	weapon_pivot.visible = not first
	fpv_pivot.visible = first
	EventBus.player_view_mode_changed.emit(int(view_mode))

func _equip(s: WeaponSlot) -> void:
	if s == current_slot:
		return
	current_weapon_node.unequip()
	current_slot = s
	current_weapon_node = _weapons[int(s)]
	current_weapon_node.equip()
	_apply_weapon_visibility()
	weapon_changed.emit(int(s))

func _apply_weapon_visibility() -> void:
	for i in _weapons.size():
		if i == int(current_slot):
			_weapons[i].equip()
		else:
			_weapons[i].unequip()

# ── helpers consumed by weapons ──────────────────────────────────────────────

func get_aim_point() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return global_position + (-transform.basis.z) * 50.0
	var center := get_viewport().get_visible_rect().size * 0.5
	var from := cam.project_ray_origin(center)
	var dir := cam.project_ray_normal(center)
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 200.0)
	query.exclude = [self.get_rid()]
	# Aim ray hits world (1) and enemies (4) so the crosshair snaps to targets.
	query.collision_mask = 1 | 4
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return from + dir * 60.0
	return hit.position

func register_hit(shake: float) -> void:
	_apply_hitstop(shake, 0.08, 0.045)

func register_hit_heavy() -> void:
	_apply_hitstop(1.2, 0.05, 0.13)

# Use a SceneTreeTimer callback (real-time, ignore_time_scale) so the restore
# fires even if the caller frees mid-await. No try/finally in GDScript.
func _apply_hitstop(shake: float, scale: float, duration: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam and cam.has_method("add_trauma"):
		cam.add_trauma(shake)
	Engine.time_scale = scale
	get_tree().create_timer(duration, true, false, true).timeout.connect(_restore_time_scale)

func _restore_time_scale() -> void:
	Engine.time_scale = 1.0

func punch_fov(delta_fov: float, in_time: float, out_time: float) -> void:
	var t := create_tween()
	t.tween_property(camera, "fov", base_fov + delta_fov, in_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(camera, "fov", base_fov, out_time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
