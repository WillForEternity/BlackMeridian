extends CharacterBody3D

enum WeaponSlot { SWORD, GUN, SNIPER }
enum ViewMode { THIRD_PERSON, FIRST_PERSON }

signal weapon_changed(weapon: int)
signal charge_changed(value: float)

@export var speed: float = 8.5
@export var jump_velocity: float = 5.5
@export var dash_speed: float = 44.0
@export var dash_duration: float = 0.18
@export var dash_cooldown: float = 0.9
# Forward reach of the sword swing hitbox (front face at z ≈ -1.45 in local space).
const SWORD_SLICE_DISTANCE: float = 1.45
@export var mouse_sensitivity: float = 0.0028
@export var pitch_min_deg: float = -85.0
@export var pitch_max_deg: float = 85.0

@export var sword_path: NodePath
@export var gun_path: NodePath
@export var sniper_path: NodePath

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var current_slot: WeaponSlot = WeaponSlot.SWORD
var current_weapon_node: Node = null
var view_mode: ViewMode = ViewMode.THIRD_PERSON
var dash_time_left: float = 0.0
var dash_cd_left: float = 0.0
var dash_dir: Vector3 = Vector3.ZERO
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
@onready var _weapons: Array[Node] = [_sword, _gun, _sniper]

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
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
	if Input.is_action_just_pressed("toggle_view"):
		_toggle_view()

	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if Input.is_action_just_pressed("attack"):
		if _consume_next_click:
			_consume_next_click = false
		else:
			current_weapon_node.on_attack_pressed()
	if Input.is_action_just_released("attack"):
		current_weapon_node.on_attack_released()

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	if Input.is_action_just_pressed("dash") and dash_cd_left <= 0.0:
		_start_dash()

	if dash_time_left > 0.0:
		dash_time_left -= delta
		velocity.x = dash_dir.x * dash_speed
		velocity.z = dash_dir.z * dash_speed
	else:
		var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var direction := transform.basis.x * input_dir.x + transform.basis.z * input_dir.y
		direction.y = 0.0
		if direction.length() > 0.0:
			direction = direction.normalized()
			velocity.x = direction.x * speed
			velocity.z = direction.z * speed
		else:
			velocity.x = move_toward(velocity.x, 0.0, speed)
			velocity.z = move_toward(velocity.z, 0.0, speed)

	move_and_slide()

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
	var space := get_world_3d().direct_space_state
	var from := global_position
	var query := PhysicsRayQueryParameters3D.create(from, from + dash_dir * (max_dist + SWORD_SLICE_DISTANCE))
	query.exclude = [self.get_rid()]
	query.collision_mask = 4  # enemies
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		var stop_dist := maxf((from.distance_to(hit.position)) - SWORD_SLICE_DISTANCE * 0.5, 0.0)
		duration = clampf(stop_dist / dash_speed, 0.0, dash_duration)

	dash_time_left = duration
	dash_cd_left = dash_cooldown

	_play_dash_animation(duration)

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

func _toggle_view() -> void:
	view_mode = ViewMode.FIRST_PERSON if view_mode == ViewMode.THIRD_PERSON else ViewMode.THIRD_PERSON
	_apply_view_mode()

func _apply_view_mode() -> void:
	var first := view_mode == ViewMode.FIRST_PERSON
	camera.position = CAM_POS_1P if first else CAM_POS_3P
	body_mesh.visible = not first
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
