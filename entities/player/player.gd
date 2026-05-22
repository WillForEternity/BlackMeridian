extends CharacterBody3D

enum WeaponSlot { SWORD, GUN, SNIPER, PORTAL_LIGHT, PORTAL_DARK, SPEAR }
enum ViewMode { THIRD_PERSON, FIRST_PERSON }

signal weapon_changed(weapon: int)
signal charge_changed(value: float)

@export var speed: float = 13.0
@export var jump_velocity: float = 6.8
# Jump feel — coyote grace after walking off a ledge, falling-gravity boost
# for a less floaty arc, and an early-release cut so tapping jump produces a
# shorter hop than holding it.
const COYOTE_TIME: float = 0.12
const FALL_GRAVITY_MULT: float = 2.1
# Multiplier applied on top of the project's default gravity for the player
# only. Bumping this above 1.0 makes the jump arc snappier and the character
# feel heavier without affecting enemies or projectiles.
const PLAYER_GRAVITY_MULT: float = 1.6
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
@export var spear_path: NodePath

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var current_slot: WeaponSlot = WeaponSlot.SWORD
var current_weapon_node: Node = null
var view_mode: ViewMode = ViewMode.THIRD_PERSON
var dash_time_left: float = 0.0
var dash_cd_left: float = 0.0
var dash_dir: Vector3 = Vector3.ZERO
# Active dash speed — set in _start_dash so a boost-dash (Shift) can multiply
# the base dash speed without permanently mutating dash_speed.
var _current_dash_speed: float = 0.0
# When true, the active dash plays the Roll body animation (X key). When false
# (C key), the dash preserves whatever locomotion clip is playing and just
# spawns translucent ghost copies of the character behind us.
var _dash_is_roll: bool = false
# Edge-detect for the raw X key (project.godot has no "roll" input action and
# I'd rather not edit the input map for one key). True = X was down last tick.
var _x_was_down: bool = false
const BOOST_DASH_MULTIPLIER: float = 10.0
# Fraction of dash_duration used when Shift is held. With post-dash skid
# now clamped at DASH_EXIT_SKID_MAX m/s, a full-duration boost (1.0 frac)
# travels ~79 m and the player still stops cleanly afterward — true 10× burst.
const BOOST_DASH_DURATION_FRAC: float = 1.0
# Maximum residual horizontal velocity left over after a dash ends. The base
# 44 m/s × 0.5 = 22 m/s skid feels right for a normal dash; that's also the
# ceiling we apply to a boost dash so the post-dash slowdown isn't a multi-
# second slide.
const DASH_EXIT_SKID_MAX: float = 22.0
var lift_time_left: float = 0.0
var lift_velocity_y: float = 0.0
var camera_pitch: float = 0.0
var base_fov: float = 75.0
var _consume_next_click: bool = false

# Multiplayer pose broadcast. Each peer is the authority on their own player
# (no client/server prediction); we just push our transform to the others at
# a fixed rate so they can render a puppet for us. 20 Hz is plenty smooth
# for the puppet's interpolation step (see training_cave.gd::remote_pose).
const POSE_SEND_HZ: float = 20.0
var _pose_send_accum: float = 0.0

const CAM_POS_3P := Vector3(0.2, 0.15, 1.5)
# CAM_POS_1P starts at 0 and is overwritten in _ready once the Head bone's
# rest position relative to CameraPitchPivot is known, so first-person sits
# at eye level regardless of how the rig is scaled.
var CAM_POS_1P: Vector3 = Vector3(0.0, 0.5, -0.05)
# Filled in _ready: BoneAttachment3D on hand_r that the TPV SwordRig is moved
# under so the katana tracks the right hand across all animations.
var _hand_r_socket: BoneAttachment3D
# F2 calibration panel — lets the user drag the sword's grip-in-hand pose
# in real time. The position/rotation drive the reparented SwordRig (whose
# origin is the rotation pivot), and the model-offset drives the sword
# model *within* SwordRig so the user can park the grip onto that pivot.
var _calib_panel: Control
var _sword_calib_pos: Vector3 = Vector3(0.0, 0.09, 0.0)
var _sword_calib_rot: Vector3 = Vector3(deg_to_rad(125.0), 0.0, 0.0)
# Accumulated yaw offset on CameraPitchPivot used only while the calibration
# panel is open — rotates the camera around the frozen player instead of
# spinning the player body when the user holds RMB to look.
var _calib_yaw_offset: float = 0.0
# Default offset matches the scene-tuned Sketchfab_Scene origin from the
# .tscn so we don't immediately move the sword from where the user has been
# seeing it; they can drag the grip toward (0,0,0) to bring the rotation
# center onto the hand.
var _sword_model_offset: Vector3 = Vector3(0.0, 0.0, 0.05)
# Reference to the visible sword model node under the TPV SwordRig.
var _sword_model_node: Node3D
# F3 calibration panel — same idea as the sword's, but drives the gun's
# Model node (the sci-fi gun GLB instance) under GunRig. The rig itself is
# overwritten by gun.gd's look_at() every tick, so the Model child is the
# only stable handle for translate/rotate/scale tweaks.
var _gun_calib_panel: Control
var _gun_calib_pos: Vector3 = Vector3(-0.02, 0.215, -0.01)
var _gun_calib_rot: Vector3 = Vector3(deg_to_rad(9.0), deg_to_rad(93.0), deg_to_rad(76.0))
var _gun_calib_scale: float = 0.052
# Muzzle position in MODEL-local space. Reparented under Model so this
# offset rides whatever rotation/scale the gun model has — the barrel-tip
# stays at the barrel-tip even when the user retunes the rig pose.
var _gun_muzzle_offset: Vector3 = Vector3(7.0, 0.0, 0.0)
var _gun_model_node: Node3D
var _gun_muzzle_node: Marker3D

@onready var body_mesh: MeshInstance3D = get_node_or_null("Body") as MeshInstance3D
var _body_base_scale: Vector3 = Vector3.ONE
var _dash_anim_tween: Tween
@onready var weapon_pivot: Node3D = $WeaponPivot
@onready var pitch_pivot: Node3D = $CameraPitchPivot
@onready var camera: Camera3D = $CameraPitchPivot/Camera3D
@onready var fpv_pivot: Node3D = $CameraPitchPivot/Camera3D/FPVPivot

# Quaternius hooded ranger + Universal Animation Library. UAL1 and the
# Male_Ranger outfit share the EXACT same 65-bone skeleton (same names, same
# hierarchy), so no BoneMap/humanoid retargeting is needed — we just load the
# UAL animations and copy them onto the character's AnimationPlayer at _ready.
const UAL_SOURCE_PATH := "res://assets/models/characters/quaternius/UAL1_Standard.glb"
@onready var _character: Node3D = get_node_or_null("Character")
var _anim_player: AnimationPlayer
var _current_anim: String = ""
const ANIM_LIB_PREFIX: String = ""

func _import_ual_animations() -> void:
	# Create an AnimationPlayer on the Character, then copy every clip from
	# UAL1's AnimationPlayer into the default ("") library on our new player.
	# Same skeleton/bone names mean tracks bind without retargeting.
	if _character == null:
		return
	_anim_player = _character.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim_player == null:
		_anim_player = AnimationPlayer.new()
		_anim_player.name = "AnimationPlayer"
		_character.add_child(_anim_player)
		_anim_player.owner = _character
	# Resolve our AnimationPlayer's tracks against the Character node so the
	# remapped paths (rooted at Character) bind correctly regardless of where
	# the AnimationPlayer sits in the tree.
	_anim_player.root_node = _anim_player.get_path_to(_character)
	var packed: PackedScene = load(UAL_SOURCE_PATH) as PackedScene
	if packed == null:
		push_warning("UAL animations failed to load at %s" % UAL_SOURCE_PATH)
		return
	var inst: Node = packed.instantiate()
	var src_ap: AnimationPlayer = inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if src_ap == null:
		inst.queue_free()
		return
	# UAL tracks are authored against UAL's own Skeleton3D path; without
	# remapping they don't bind to Male_Ranger's skeleton (which is the same
	# bone set under a possibly-different parent path) and the character stays
	# in T-pose. Locate both skeletons and rewrite each bone-transform track to
	# target our Skeleton3D's relative path.
	var dst_skel: Skeleton3D = _find_skeleton(_character)
	var src_root: Node = src_ap.get_node_or_null(src_ap.root_node)
	if src_root == null:
		src_root = inst
	var src_skel: Skeleton3D = _find_skeleton(src_root)
	var dst_skel_path: NodePath = _character.get_path_to(dst_skel) if dst_skel else NodePath()
	var src_skel_path_str: String = String(src_root.get_path_to(src_skel)) if src_skel else ""
	# Copy into a fresh DEFAULT library (name = ""). Animation keys then have
	# no prefix — "Idle_Loop", "Jog_Fwd_Loop", etc. — so ANIM_LIB_PREFIX="" matches.
	var lib := AnimationLibrary.new()
	for src_lib_name in src_ap.get_animation_library_list():
		var src_lib := src_ap.get_animation_library(src_lib_name)
		for anim_name in src_lib.get_animation_list():
			var anim: Animation = (src_lib.get_animation(anim_name) as Animation).duplicate(true)
			if dst_skel != null:
				for ti in anim.get_track_count():
					var ttype := anim.track_get_type(ti)
					if ttype != Animation.TYPE_POSITION_3D \
						and ttype != Animation.TYPE_ROTATION_3D \
						and ttype != Animation.TYPE_SCALE_3D:
						continue
					var p_str := String(anim.track_get_path(ti))
					var colon := p_str.find(":")
					var node_part := p_str if colon < 0 else p_str.substr(0, colon)
					var sub: String = "" if colon < 0 else p_str.substr(colon)
					# Any source path that points at the source skeleton (or its
					# named variants) gets rewritten to our skeleton's path; the
					# bone subname after the colon is unchanged.
					if src_skel_path_str != "" and node_part == src_skel_path_str:
						anim.track_set_path(ti, NodePath(String(dst_skel_path) + sub))
					elif node_part == "Skeleton3D" or node_part == "Armature":
						anim.track_set_path(ti, NodePath(String(dst_skel_path) + sub))
			lib.add_animation(anim_name, anim)
	# A handful of UAL clips aren't named with a "_Loop" suffix even though
	# they're conceptually looping (e.g. Sword_Idle). Force the loop mode so
	# they don't end on their last frame when we want a continuous pose.
	for force_loop_name in ["Sword_Idle"]:
		if lib.has_animation(force_loop_name):
			var fa: Animation = lib.get_animation(force_loop_name)
			fa.loop_mode = Animation.LOOP_LINEAR
	# Replace any existing default library so we don't double-add.
	if _anim_player.has_animation_library(""):
		_anim_player.remove_animation_library("")
	_anim_player.add_animation_library("", lib)
	_anim_player.active = true
	# Crossfade between any two clips so transitions (Sword_Attack → Idle,
	# Jog → Idle, etc.) blend instead of snapping. Without this, every
	# play() call pops to the new clip's pose on a single frame.
	_anim_player.playback_default_blend_time = 0.15
	if not _anim_player.animation_finished.is_connected(_on_anim_finished):
		_anim_player.animation_finished.connect(_on_anim_finished)
	play_anim(ANIM_IDLE)
	inst.queue_free()

func _find_skeleton(root: Node) -> Skeleton3D:
	if root == null:
		return null
	if root is Skeleton3D:
		return root
	for c in root.get_children():
		var s := _find_skeleton(c)
		if s != null:
			return s
	return null

func _on_anim_finished(anim_name: String) -> void:
	# Godot's gltf importer strips "_Loop" from looping clips and sets loop_mode
	# instead. Restart by loop_mode, not by name suffix.
	if not _anim_player.has_animation(anim_name):
		return
	var a: Animation = _anim_player.get_animation(anim_name)
	if a != null and a.loop_mode != Animation.LOOP_NONE:
		_anim_player.play(anim_name)

func play_anim(name: String, custom_speed: float = 1.0, loop_override: bool = false) -> void:
	if _anim_player == null:
		return
	var full := ANIM_LIB_PREFIX + name
	if not _anim_player.has_animation(full):
		full = name
		if not _anim_player.has_animation(full):
			return
	# Only call play() on the FIRST tick we want this animation. Repeated
	# play() calls reset the playhead to 0 every frame and visually freeze
	# the character at the first pose. The animation_finished signal handler
	# restarts loop clips when they end.
	if _current_anim != full:
		_current_anim = full
		_anim_player.play(full)
	_anim_player.speed_scale = custom_speed

@onready var _sword: Node = get_node(sword_path)
@onready var _gun: Node = get_node(gun_path)
@onready var _sniper: Node = get_node(sniper_path)
@onready var _portal_light: Node = get_node(portal_light_path)
@onready var _portal_dark: Node = get_node(portal_dark_path)
@onready var _spear: Node = get_node(spear_path)
@onready var _weapons: Array[Node] = [_sword, _gun, _sniper, _portal_light, _portal_dark, _spear]

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

# Wood inventory + build mode wiring.
var wood: int = 30
var _build_mode: Node                # entities/player/build_mode.gd
var _wood_label: Label
# Interaction prompt: shown while the player stands near a fallen-log pickup.
# The pickup itself is keyed on `interact` (P) and resolved every frame in
# _process via the "wood_pickup" group.
var _prompt_label: Label
var _nearest_pickup: Node

func get_wood() -> int:
	return wood

func add_wood(amount: int) -> void:
	wood += amount
	_refresh_wood_label()

func spend_wood(amount: int) -> void:
	wood = maxi(wood - amount, 0)
	_refresh_wood_label()

func _refresh_wood_label() -> void:
	if _wood_label != null:
		_wood_label.text = "Wood: %d" % wood

func on_build_mode_exited() -> void:
	pass

# Scan the "wood_pickup" group every frame, find the closest collectible log
# within the log pickup radius (see tree.gd PICKUP_RADIUS), and show/hide the
# "[P] Pick up wood" prompt accordingly. A single prompt + single nearest
# target keeps the UI tidy when multiple logs are around.
func _update_wood_pickup_prompt() -> void:
	if _prompt_label == null:
		return
	# Matches PICKUP_RADIUS in tree.gd — duplicated to avoid coupling
	# player.gd's parse to the tree script's class_name registration order.
	var pickup_radius: float = 4.0
	var best_d2: float = pickup_radius * pickup_radius
	var best: Node = null
	var pp: Vector3 = global_position
	for n in get_tree().get_nodes_in_group("wood_pickup"):
		if not is_instance_valid(n) or not n.call("is_collectible"):
			continue
		var near: Vector3 = n.call("nearest_point", pp)
		var d2: float = near.distance_squared_to(pp)
		if d2 < best_d2:
			best_d2 = d2
			best = n
	_nearest_pickup = best
	_prompt_label.visible = best != null

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	add_to_group("player")
	_import_ual_animations()
	# Snapshot the body's resting scale so dash squash/stretch always tweens
	# back to it. Reading body_mesh.scale mid-dash would capture a stretched
	# value and the character would drift larger with every rapid dash.
	if body_mesh != null:
		_body_base_scale = body_mesh.scale
	# Build mode controller is a script-only Node child. We construct it here
	# (rather than putting it in the scene) so build-related state stays out of
	# the .tscn and travels with the player wherever they're placed.
	_build_mode = preload("res://entities/player/build_mode.gd").new()
	_build_mode.name = "BuildMode"
	_build_mode.player = self
	add_child(_build_mode)
	# Wood counter HUD: parent under the existing UI CanvasLayer so it draws
	# above the world. Top-left, simple text.
	var ui: CanvasLayer = get_tree().current_scene.get_node_or_null("UI") as CanvasLayer
	if ui != null:
		_wood_label = Label.new()
		_wood_label.name = "WoodCounter"
		_wood_label.position = Vector2(24, 24)
		ui.add_child(_wood_label)
		_refresh_wood_label()
		# Interact prompt: centered above the hotbar, hidden until needed.
		_prompt_label = Label.new()
		_prompt_label.name = "InteractPrompt"
		_prompt_label.text = "[P] Pick up wood"
		_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_prompt_label.anchor_left = 0.5
		_prompt_label.anchor_right = 0.5
		_prompt_label.anchor_top = 1.0
		_prompt_label.anchor_bottom = 1.0
		_prompt_label.offset_left = -120
		_prompt_label.offset_right = 120
		_prompt_label.offset_top = -120
		_prompt_label.offset_bottom = -90
		_prompt_label.visible = false
		ui.add_child(_prompt_label)
		# Health bar: top-center, beneath the screen edge. Drains on take_damage
		# and refills 10 HP/s after REGEN_DELAY of not being hit.
		_health_bar = ProgressBar.new()
		_health_bar.name = "HealthBar"
		_health_bar.min_value = 0.0
		_health_bar.max_value = MAX_HEALTH
		_health_bar.value = _health
		_health_bar.show_percentage = false
		_health_bar.custom_minimum_size = Vector2(280, 18)
		_health_bar.anchor_left = 0.5
		_health_bar.anchor_right = 0.5
		_health_bar.offset_left = -140
		_health_bar.offset_right = 140
		_health_bar.offset_top = 24
		_health_bar.offset_bottom = 42
		ui.add_child(_health_bar)
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
	_attach_sword_to_hand()
	_calibrate_fpv_eye_height()
	_apply_view_mode()
	_apply_weapon_visibility()
	_build_sword_calib_panel()
	_build_gun_calib_panel()

# Move the TPV SwordRig from WeaponPivot to a BoneAttachment3D on the
# right-hand bone so the katana stays in the hand during run/jump/swing.
# Weapons cache their rig pointers via @onready before this runs, so the
# pointer remains valid after the reparent — no NodePath fixups needed.
func _attach_sword_to_hand() -> void:
	if _character == null:
		return
	var skel: Skeleton3D = _find_skeleton(_character)
	if skel == null:
		return
	var hand_idx: int = skel.find_bone("hand_r")
	if hand_idx < 0:
		return
	var attach := BoneAttachment3D.new()
	attach.name = "HandRSocket"
	attach.bone_idx = hand_idx
	attach.bone_name = "hand_r"
	skel.add_child(attach)
	attach.add_to_group("weapon_attached")
	_hand_r_socket = attach
	var sword_rig: Node3D = weapon_pivot.get_node_or_null("SwordRig") as Node3D
	if sword_rig == null:
		return
	weapon_pivot.remove_child(sword_rig)
	attach.add_child(sword_rig)
	sword_rig.add_to_group("weapon_attached")
	# Quaternius UAL convention: hand_r's local +Y points down the bone (toward
	# fingertips). Start from a sensible default (90° X to map blade's -Z onto
	# the bone's +Y, with a small offset down the bone) and let the F2
	# calibration panel dial it in from there.
	sword_rig.transform = Transform3D.IDENTITY
	_sword_model_node = sword_rig.get_node_or_null("Sketchfab_Scene") as Node3D
	_apply_sword_calib_to(sword_rig)
	# Tell sword.gd to skip its rig_tpv keyframe tween — the body's Sword_Attack
	# clip drives the bone (and thus the sword) during swings now, and stacking
	# the legacy tween on top of that double-animates the rig.
	if _sword != null:
		_sword.set("_tpv_rig_follows_bone", true)
	# Move the gun rig onto the same hand socket. Pistol_Idle raises the right
	# arm to an aiming pose, so leaving the gun at the hip read as "huge gun
	# floating where the empty hand used to be." Reparent + reset transform —
	# gun.gd's per-tick look_at() will keep the muzzle on the crosshair.
	# The sci-fi gun GLB has a 100× scale on its internal GunMerged node and
	# the scene Model node compensated with scale 0.5; with Player.scale=2
	# the result was a ~10 m gun. Shrink the Model so it reads handheld.
	var gun_rig: Node3D = weapon_pivot.get_node_or_null("GunRig") as Node3D
	if gun_rig != null:
		weapon_pivot.remove_child(gun_rig)
		attach.add_child(gun_rig)
		gun_rig.add_to_group("weapon_attached")
		gun_rig.transform = Transform3D.IDENTITY
		_gun_model_node = gun_rig.get_node_or_null("Model") as Node3D
		# Reparent the muzzle marker under Model so its position is expressed
		# in model-local coords. Previously it sat at GunRig-local z=-0.72
		# which, with the rig now on the hand bone, pointed toward the floor
		# (hand-local -Z is roughly downward in Pistol_Idle), so bullets
		# spawned at the feet.
		var muzzle: Marker3D = gun_rig.get_node_or_null("Muzzle") as Marker3D
		if muzzle != null and _gun_model_node != null:
			gun_rig.remove_child(muzzle)
			_gun_model_node.add_child(muzzle)
			_gun_muzzle_node = muzzle
		_apply_gun_calib()

# Mirror _sword_calib_pos/_rot onto the reparented SwordRig and push the same
# values into sword.gd's rest-pose cache so equip() can't snap them back.
# Also reapply the model offset (Sketchfab_Scene local position) so the grip
# stays where the user parked it.
func _apply_sword_calib_to(sword_rig: Node3D) -> void:
	if sword_rig == null:
		return
	sword_rig.position = _sword_calib_pos
	sword_rig.rotation = _sword_calib_rot
	if _sword != null:
		_sword.set("_rest_pos_tpv", _sword_calib_pos)
		_sword.set("_rest_rot_tpv", _sword_calib_rot)
	if _sword_model_node != null and is_instance_valid(_sword_model_node):
		_sword_model_node.position = _sword_model_offset

func _build_sword_calib_panel() -> void:
	var ui: CanvasLayer = get_tree().current_scene.get_node_or_null("UI") as CanvasLayer
	if ui == null:
		return
	var panel := PanelContainer.new()
	panel.name = "SwordCalibPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(20, 60)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "Sword calibration  (F2 to toggle)"
	vb.add_child(title)
	# Each tuple: label, min, max, step, initial, idx
	var defs: Array = [
		["rig pos x", -2.0, 2.0, 0.005, _sword_calib_pos.x, 0],
		["rig pos y", -2.0, 2.0, 0.005, _sword_calib_pos.y, 1],
		["rig pos z", -2.0, 2.0, 0.005, _sword_calib_pos.z, 2],
		["rot x (deg)", -180.0, 180.0, 1.0, rad_to_deg(_sword_calib_rot.x), 3],
		["rot y (deg)", -180.0, 180.0, 1.0, rad_to_deg(_sword_calib_rot.y), 4],
		["rot z (deg)", -180.0, 180.0, 1.0, rad_to_deg(_sword_calib_rot.z), 5],
		# Move the visible sword model within SwordRig so the grip lands at the
		# rig origin (= rotation pivot). Once the grip is at (0,0,0), rotations
		# pivot around the hand instead of orbiting the sword around it.
		["model dx", -5.0, 5.0, 0.01, _sword_model_offset.x, 6],
		["model dy", -5.0, 5.0, 0.01, _sword_model_offset.y, 7],
		["model dz", -5.0, 5.0, 0.01, _sword_model_offset.z, 8],
	]
	for d in defs:
		_add_calib_row(vb, d)
	var swing_btn := Button.new()
	swing_btn.text = "Test swing"
	swing_btn.pressed.connect(_test_swing)
	vb.add_child(swing_btn)
	var btn := Button.new()
	btn.text = "Print to console"
	btn.pressed.connect(_print_sword_calib)
	vb.add_child(btn)
	ui.add_child(panel)
	panel.visible = false
	_calib_panel = panel

func _add_calib_row(vb: VBoxContainer, d: Array) -> void:
	var row := HBoxContainer.new()
	vb.add_child(row)
	var lbl := Label.new()
	lbl.text = String(d[0])
	lbl.custom_minimum_size = Vector2(86, 0)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = float(d[1])
	slider.max_value = float(d[2])
	slider.step = float(d[3])
	slider.value = float(d[4])
	slider.custom_minimum_size = Vector2(220, 0)
	row.add_child(slider)
	var vlbl := Label.new()
	vlbl.text = "%.3f" % float(d[4])
	vlbl.custom_minimum_size = Vector2(60, 0)
	row.add_child(vlbl)
	var idx: int = int(d[5])
	slider.value_changed.connect(func(v: float) -> void:
		vlbl.text = "%.3f" % v
		_on_calib_changed(idx, v)
	)

func _on_calib_changed(idx: int, v: float) -> void:
	match idx:
		0: _sword_calib_pos.x = v
		1: _sword_calib_pos.y = v
		2: _sword_calib_pos.z = v
		3: _sword_calib_rot.x = deg_to_rad(v)
		4: _sword_calib_rot.y = deg_to_rad(v)
		5: _sword_calib_rot.z = deg_to_rad(v)
		6: _sword_model_offset.x = v
		7: _sword_model_offset.y = v
		8: _sword_model_offset.z = v
	if _hand_r_socket != null:
		_apply_sword_calib_to(_hand_r_socket.get_node_or_null("SwordRig") as Node3D)

func _test_swing() -> void:
	if _sword == null:
		return
	# Bypass cooldown so the button can be spammed for back-to-back tests.
	_sword.set("attack_cd", 0.0)
	_sword.call("on_attack_pressed")

func _print_sword_calib() -> void:
	print("[Sword calib] sword_rig.position = ", _sword_calib_pos)
	print("[Sword calib] sword_rig.rotation_deg = (",
		rad_to_deg(_sword_calib_rot.x), ", ",
		rad_to_deg(_sword_calib_rot.y), ", ",
		rad_to_deg(_sword_calib_rot.z), ")")
	print("[Sword calib] sword_model_node.position = ", _sword_model_offset)

# True when either the sword or gun calibration panel is currently open. Used
# to gate input handling that needs to differ in inspection mode (mouse
# recapture, freeze, etc.).
func _is_calibrating() -> bool:
	if _calib_panel != null and _calib_panel.visible:
		return true
	if _gun_calib_panel != null and _gun_calib_panel.visible:
		return true
	return false

# Apply _gun_calib_pos/_rot/_scale to the GunRig's Model child. Safe to call
# before the rig is wired — it no-ops when the cached node ref is null.
func _apply_gun_calib() -> void:
	if _gun_model_node != null and is_instance_valid(_gun_model_node):
		_gun_model_node.position = _gun_calib_pos
		_gun_model_node.rotation = _gun_calib_rot
		_gun_model_node.scale = Vector3.ONE * _gun_calib_scale
	if _gun_muzzle_node != null and is_instance_valid(_gun_muzzle_node):
		_gun_muzzle_node.position = _gun_muzzle_offset

func _build_gun_calib_panel() -> void:
	var ui: CanvasLayer = get_tree().current_scene.get_node_or_null("UI") as CanvasLayer
	if ui == null:
		return
	var panel := PanelContainer.new()
	panel.name = "GunCalibPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(20, 60)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "Gun calibration  (F3 to toggle)"
	vb.add_child(title)
	var defs: Array = [
		["pos x", -1.0, 1.0, 0.005, _gun_calib_pos.x, 0],
		["pos y", -1.0, 1.0, 0.005, _gun_calib_pos.y, 1],
		["pos z", -1.0, 1.0, 0.005, _gun_calib_pos.z, 2],
		["rot x (deg)", -180.0, 180.0, 1.0, rad_to_deg(_gun_calib_rot.x), 3],
		["rot y (deg)", -180.0, 180.0, 1.0, rad_to_deg(_gun_calib_rot.y), 4],
		["rot z (deg)", -180.0, 180.0, 1.0, rad_to_deg(_gun_calib_rot.z), 5],
		["scale", 0.001, 0.2, 0.001, _gun_calib_scale, 6],
		# Muzzle in MODEL-local space — values in the bbox range (x: -7..7).
		["muzzle x", -10.0, 10.0, 0.05, _gun_muzzle_offset.x, 7],
		["muzzle y", -10.0, 10.0, 0.05, _gun_muzzle_offset.y, 8],
		["muzzle z", -10.0, 10.0, 0.05, _gun_muzzle_offset.z, 9],
	]
	for d in defs:
		_add_gun_calib_row(vb, d)
	var print_btn := Button.new()
	print_btn.text = "Print to console"
	print_btn.pressed.connect(_print_gun_calib)
	vb.add_child(print_btn)
	ui.add_child(panel)
	panel.visible = false
	_gun_calib_panel = panel

func _add_gun_calib_row(vb: VBoxContainer, d: Array) -> void:
	var row := HBoxContainer.new()
	vb.add_child(row)
	var lbl := Label.new()
	lbl.text = String(d[0])
	lbl.custom_minimum_size = Vector2(86, 0)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = float(d[1])
	slider.max_value = float(d[2])
	slider.step = float(d[3])
	slider.value = float(d[4])
	slider.custom_minimum_size = Vector2(220, 0)
	row.add_child(slider)
	var vlbl := Label.new()
	vlbl.text = "%.4f" % float(d[4])
	vlbl.custom_minimum_size = Vector2(60, 0)
	row.add_child(vlbl)
	var idx: int = int(d[5])
	slider.value_changed.connect(func(v: float) -> void:
		vlbl.text = "%.4f" % v
		_on_gun_calib_changed(idx, v)
	)

func _on_gun_calib_changed(idx: int, v: float) -> void:
	match idx:
		0: _gun_calib_pos.x = v
		1: _gun_calib_pos.y = v
		2: _gun_calib_pos.z = v
		3: _gun_calib_rot.x = deg_to_rad(v)
		4: _gun_calib_rot.y = deg_to_rad(v)
		5: _gun_calib_rot.z = deg_to_rad(v)
		6: _gun_calib_scale = v
		7: _gun_muzzle_offset.x = v
		8: _gun_muzzle_offset.y = v
		9: _gun_muzzle_offset.z = v
	_apply_gun_calib()

func _print_gun_calib() -> void:
	print("[Gun calib] model.position = ", _gun_calib_pos)
	print("[Gun calib] model.rotation_deg = (",
		rad_to_deg(_gun_calib_rot.x), ", ",
		rad_to_deg(_gun_calib_rot.y), ", ",
		rad_to_deg(_gun_calib_rot.z), ")")
	print("[Gun calib] model.scale = ", _gun_calib_scale)
	print("[Gun calib] muzzle.position = ", _gun_muzzle_offset)

func _toggle_gun_calib_panel() -> void:
	if _gun_calib_panel == null:
		return
	_gun_calib_panel.visible = not _gun_calib_panel.visible
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _gun_calib_panel.visible else Input.MOUSE_MODE_CAPTURED
	if _gun_calib_panel.visible:
		# Equip the gun so the calibrated weapon is the visible one.
		if current_slot != WeaponSlot.GUN:
			_equip(WeaponSlot.GUN)
	else:
		_calib_yaw_offset = 0.0
		pitch_pivot.rotation = Vector3(camera_pitch, 0.0, 0.0)

func _toggle_sword_calib_panel() -> void:
	if _calib_panel == null:
		return
	_calib_panel.visible = not _calib_panel.visible
	# Release mouse capture while the panel is open so sliders can be dragged.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _calib_panel.visible else Input.MOUSE_MODE_CAPTURED
	# Equip the sword and pin it drawn so the calibrated grip pose is visible
	# the entire time the panel is open — no auto-sheathe, no waiting on a
	# quick-draw tween.
	if _calib_panel.visible:
		if current_slot != WeaponSlot.SWORD:
			_equip(WeaponSlot.SWORD)
		if _sword != null and _sword.has_method("set_force_drawn"):
			_sword.call("set_force_drawn", true)
	else:
		if _sword != null and _sword.has_method("set_force_drawn"):
			_sword.call("set_force_drawn", false)
		# Snap the camera pivot back so the next mouse-look call doesn't start
		# from a 270° yaw offset accumulated during inspection.
		_calib_yaw_offset = 0.0
		pitch_pivot.rotation = Vector3(camera_pitch, 0.0, 0.0)

# Measure the Head bone's local-Y offset from CameraPitchPivot in the rest
# pose and use that as CAM_POS_1P.y so the FPV camera sits at eye level
# regardless of how the character mesh is scaled.
func _calibrate_fpv_eye_height() -> void:
	if _character == null:
		return
	var skel: Skeleton3D = _find_skeleton(_character)
	if skel == null:
		return
	var head_idx: int = skel.find_bone("Head")
	if head_idx < 0:
		return
	var head_global: Transform3D = skel.global_transform * skel.get_bone_global_pose(head_idx)
	var local_offset: Vector3 = pitch_pivot.global_transform.affine_inverse() * head_global.origin
	# Slight forward bias so the camera sits at the eyes, not the back of the head.
	CAM_POS_1P = Vector3(0.0, local_offset.y, -0.08)

func _on_weapon_charge_changed(v: float) -> void:
	charge_changed.emit(v)

func _unhandled_input(event: InputEvent) -> void:
	# B toggles build mode. While active, BuildMode owns left/right click and
	# 1/2 for log/plank — see entities/player/build_mode.gd.
	if event is InputEventKey and event.pressed and not event.echo:
		var ek := event as InputEventKey
		if ek.keycode == KEY_B:
			if _build_mode != null:
				_build_mode.call("set_active", not (_build_mode.get("active") as bool))
			return
		if ek.keycode == KEY_P:
			if _nearest_pickup != null and is_instance_valid(_nearest_pickup):
				# Play the bend-down Interact clip so the pickup reads as a
				# physical action instead of the log teleporting to inventory.
				if _anim_player != null and _anim_player.has_animation("Interact"):
					var ilen: float = _anim_player.get_animation("Interact").length
					play_anim_locked("Interact", minf(ilen, 0.6), 1.2)
				_nearest_pickup.call("pick_up_by", self)
				_nearest_pickup = null
				if _prompt_label != null:
					_prompt_label.visible = false
			return
		if ek.keycode == KEY_F2:
			_toggle_sword_calib_panel()
			return
		if ek.keycode == KEY_F3:
			_toggle_gun_calib_panel()
			return
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# Don't snap back to captured mouse while a calibration panel is open;
		# the user is dragging sliders.
		if _is_calibrating():
			return
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_consume_next_click = true
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var calib_look: bool = _is_calibrating() \
			and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			# Normal play: spin the player body for yaw, tilt the pivot for pitch.
			rotate_y(-mm.relative.x * mouse_sensitivity)
			camera_pitch = clampf(camera_pitch - mm.relative.y * mouse_sensitivity, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))
			pitch_pivot.rotation.x = camera_pitch
		elif calib_look:
			# Inspection mode: orbit the *camera pivot* around the frozen player
			# instead of rotating the body — the user wants the character to
			# stay put so the calibration grip pose isn't a moving target.
			_calib_yaw_offset -= mm.relative.x * mouse_sensitivity
			camera_pitch = clampf(camera_pitch - mm.relative.y * mouse_sensitivity, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))
			pitch_pivot.rotation = Vector3(camera_pitch, _calib_yaw_offset, 0.0)

func _process(delta: float) -> void:
	dash_cd_left = maxf(dash_cd_left - delta, 0.0)
	_tick_health(delta)
	_update_wood_pickup_prompt()

	# Build mode reuses 1/2 for log/plank selection, so we suppress the weapon-
	# slot hotkeys (which share those bindings) while building.
	var build_active: bool = _build_mode != null and (_build_mode.get("active") as bool)
	if not build_active:
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
		if Input.is_action_just_pressed("equip_spear"):
			_equip(WeaponSlot.SPEAR)
	if Input.is_action_just_pressed("toggle_view"):
		_toggle_view()
	if Input.is_action_just_pressed("weapon_guide"):
		EventBus.weapon_guide_toggled.emit(current_weapon_node.guide_text() if current_weapon_node else "")

	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	# Build mode owns click input — don't fire weapons or skills while placing.
	var building: bool = _build_mode != null and (_build_mode.get("active") as bool)
	if building:
		return
	if current_weapon_node == null:
		return
	if Input.is_action_just_pressed("attack"):
		if _consume_next_click:
			_consume_next_click = false
		else:
			current_weapon_node.on_attack_pressed()
			_aim_face_left = AIM_FACE_DURATION
	if Input.is_action_just_released("attack"):
		current_weapon_node.on_attack_released()
	if Input.is_action_just_pressed("super"):
		current_weapon_node.on_super_pressed()

func _physics_process(delta: float) -> void:
	# Calibration mode pins the player in place so the user can study the
	# sword/gun pose from any angle without drifting around. Kill velocity,
	# skip gravity, and bail before any input is read. AnimationPlayer keeps
	# running so the user can see the rig move through the locomotion +
	# attack clips while tweaking.
	if _is_calibrating():
		velocity = Vector3.ZERO
		_controlled_velocity = Vector3.ZERO
		return

	if lift_time_left > 0.0:
		lift_time_left -= delta
		velocity.y = lift_velocity_y
	elif not is_on_floor():
		# Heavier gravity on the way down — keeps the jump arc snappy rather
		# than floaty without hurting the rising height.
		var g_mult: float = FALL_GRAVITY_MULT if velocity.y < 0.0 else 1.0
		velocity.y -= gravity * PLAYER_GRAVITY_MULT * g_mult * delta

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
			_jump_anim_active = true
		elif _air_jumps_used < _max_air_jumps():
			# Reset rather than add so the second/third jump feels equally
			# strong even if the disc was already falling.
			velocity.y = jump_velocity
			_air_jumps_used += 1
			_jump_anim_active = true
			# Replay a takeoff animation for each multi-jump so it reads as a
			# distinct action mid-air. Alternate Jump_Start and Roll for variety
			# — Roll looks like a flip on the even-numbered air jumps. Cap the
			# lock so a long clip doesn't pin the pose past landing.
			if _anim_player != null:
				var ajump_anim: String = ANIM_ROLL if (_air_jumps_used % 2 == 0) else ANIM_JUMP_START
				if _anim_player.has_animation(ajump_anim):
					var ajump_dur: float = _anim_player.get_animation(ajump_anim).length
					play_anim_locked(ajump_anim, minf(ajump_dur, 0.5), 1.2)

	# Variable jump height: releasing jump early cuts upward momentum. Skip
	# while a super is forcing a lift so the cut doesn't fight it.
	if Input.is_action_just_released("jump") and velocity.y > 0.0 and lift_time_left <= 0.0:
		velocity.y *= JUMP_CUT_FACTOR

	if Input.is_action_just_pressed("dash") and dash_cd_left <= 0.0 and not movement_locked:
		_dash_is_roll = false
		_start_dash()
	elif Input.is_physical_key_pressed(KEY_X) and not _x_was_down \
			and dash_cd_left <= 0.0 and not movement_locked:
		_dash_is_roll = true
		_start_dash()
	_x_was_down = Input.is_physical_key_pressed(KEY_X)

	if dash_time_left > 0.0:
		# Cancel the dash if we're about to plow into an enemy: keep at least
		# half a sword-slice of space between the player capsule and the target.
		var min_gap := SWORD_SLICE_DISTANCE * 0.95
		var lookahead := _current_dash_speed * delta + min_gap
		var d := _dash_target_distance(lookahead)
		if d >= 0.0 and d <= min_gap:
			dash_time_left = 0.0
			velocity.x = 0.0
			velocity.z = 0.0
			_controlled_velocity = Vector3.ZERO
		else:
			dash_time_left -= delta
			velocity.x = dash_dir.x * _current_dash_speed
			velocity.z = dash_dir.z * _current_dash_speed
			# Sync controlled velocity so accel-based control resumes from the
			# dash's exit speed rather than snapping back to the pre-dash value.
			# Scaled to half AND capped at DASH_EXIT_SKID_MAX so a boost dash
			# doesn't leave us with 220 m/s of "controlled" velocity that takes
			# seconds for GROUND_DECEL to bleed off (the original cause of the
			# friction-feels-off post-dash skid across the map).
			var skid := Vector3(velocity.x * 0.5, 0.0, velocity.z * 0.5)
			if skid.length() > DASH_EXIT_SKID_MAX:
				skid = skid.normalized() * DASH_EXIT_SKID_MAX
			_controlled_velocity = skid
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

	_update_character_animation()
	_update_character_facing(delta)

	# Re-read the floor velocity from this frame's collisions for the next tick.
	_floor_platform_velocity = _detect_floor_platform_velocity()
	# Undo the carry so the input layer starts clean next frame.
	velocity.x -= _floor_platform_velocity.x
	velocity.z -= _floor_platform_velocity.z

	_update_camera_collision()

	# Broadcast pose to peers (no-op in single-player). The relay rebroadcasts
	# to everyone else in the room; the world scene routes by sender id.
	if Network.is_in_room():
		_pose_send_accum += delta
		var interval: float = 1.0 / POSE_SEND_HZ
		if _pose_send_accum >= interval:
			_pose_send_accum = 0.0
			Network.send_message({
				"type": "pose",
				"pos": [global_position.x, global_position.y, global_position.z],
				"yaw": rotation.y,
				"pitch": camera_pitch,
				"slot": int(current_slot),
				"hp": _health,
				"hp_max": MAX_HEALTH,
				"anim": _current_anim,
				"anim_speed": _anim_player.speed_scale if _anim_player else 1.0,
			})

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

	# Boost dash: holding Shift at dash start gives a SHORTER, SHARPER burst —
	# speed × BOOST_DASH_MULTIPLIER, duration cut to BOOST_DASH_DURATION_FRAC of
	# normal. Net travel is still longer than a base dash but bounded so the
	# player doesn't rocket across the map.
	var boost: bool = Input.is_key_pressed(KEY_SHIFT)
	_current_dash_speed = dash_speed * (BOOST_DASH_MULTIPLIER if boost else 1.0)
	var base_duration: float = dash_duration * (BOOST_DASH_DURATION_FRAC if boost else 1.0)

	# Default to the full (possibly boost-reduced) dash duration, then shorten
	# it if an enemy obstructs the dash path so the player halts half a sword-
	# slice in front of them.
	var duration := base_duration
	var max_dist := _current_dash_speed * base_duration
	var hit_dist := _dash_target_distance(max_dist + SWORD_SLICE_DISTANCE)
	if hit_dist >= 0.0:
		var stop_dist := maxf(hit_dist - SWORD_SLICE_DISTANCE * 0.95, 0.0)
		duration = clampf(stop_dist / _current_dash_speed, 0.0, base_duration)

	dash_time_left = duration
	var cd_mult: float = 1.0
	if current_weapon_node and current_weapon_node.has_method("dash_cooldown_mult"):
		cd_mult = current_weapon_node.dash_cooldown_mult()
	# Shift-boosted dash has zero cooldown — held-shift becomes a sprint-burst
	# you can spam. Normal dashes still cool down as usual.
	dash_cd_left = 0.0 if boost else dash_cooldown * cd_mult

	_play_dash_animation(duration)

	# Only the X-key roll plays the Roll body clip. A normal C-dash keeps the
	# locomotion animation running and relies on the ghost trail (below) to
	# convey the dash visually.
	if _dash_is_roll and _anim_player != null and _anim_player.has_animation(ANIM_ROLL):
		var clip_len: float = _anim_player.get_animation(ANIM_ROLL).length
		play_anim_locked(ANIM_ROLL, clip_len, 1.0)

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
	# Squash & stretch the body along the dash direction. Always tween from
	# wherever the body currently is (handles interrupted prior tweens) back
	# to the captured _body_base_scale, not whatever scale happens to be
	# active when this dash starts.
	if _dash_anim_tween and _dash_anim_tween.is_valid():
		_dash_anim_tween.kill()
	if body_mesh != null:
		var stretch := Vector3(_body_base_scale.x * 0.7, _body_base_scale.y * 0.85, _body_base_scale.z * 1.45)
		_dash_anim_tween = create_tween().set_parallel(false)
		_dash_anim_tween.tween_property(body_mesh, "scale", stretch, 0.05)
		_dash_anim_tween.tween_property(body_mesh, "scale", _body_base_scale, maxf(duration, 0.12) + 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# FOV punch for speed feel.
	punch_fov(12.0, 0.05, 0.22)

	# Camera shake trauma if available.
	if camera.has_method("add_trauma"):
		camera.add_trauma(0.35)

	# Afterimage trail. The roll variant has its own visual (the body animation),
	# so only the non-roll C-dash spawns character ghosts behind the player.
	if not _dash_is_roll:
		var ghost_count := 5
		for i in ghost_count:
			var delay := float(i) * (maxf(duration, 0.06) / float(ghost_count))
			get_tree().create_timer(delay, true, false, false).timeout.connect(_spawn_character_ghost)

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

# Freeze-frame ghost of the character mesh at its current pose. Used by the
# C-dash to leave a translucent keyframe trail behind the player without
# replacing the running locomotion animation.
const GHOST_LIFETIME: float = 0.38
const GHOST_TINT := Color(0.55, 0.85, 1.0, 1.0)
const GHOST_START_ALPHA: float = 0.5

func _spawn_character_ghost() -> void:
	if _character == null or not is_instance_valid(_character):
		return
	var ghost: Node3D = _character.duplicate(0) as Node3D
	if ghost == null:
		return
	# Strip any AnimationPlayer on the clone — we want the pose to freeze at
	# the moment the ghost was spawned, not continue tracking our live one.
	for ap in ghost.find_children("*", "AnimationPlayer", true, false):
		ap.queue_free()
	# Parent under the world so player movement doesn't drag the ghost along.
	get_parent().add_child(ghost)
	ghost.global_transform = _character.global_transform
	# Copy the current bone poses across so the clone holds the exact silhouette
	# the player has right now (otherwise the duplicated Skeleton3D would snap
	# back to its rest pose).
	var src_skel: Skeleton3D = _find_skeleton(_character)
	var dst_skel: Skeleton3D = _find_skeleton(ghost)
	if src_skel != null and dst_skel != null:
		for i in src_skel.get_bone_count():
			dst_skel.set_bone_pose_position(i, src_skel.get_bone_pose_position(i))
			dst_skel.set_bone_pose_rotation(i, src_skel.get_bone_pose_rotation(i))
			dst_skel.set_bone_pose_scale(i, src_skel.get_bone_pose_scale(i))
	# Override every mesh with a translucent unshaded material so the ghost
	# reads as an afterimage no matter what materials the character ships with.
	var meshes: Array = []
	_collect_mesh_instances(ghost, meshes)
	var mats: Array[StandardMaterial3D] = []
	for m in meshes:
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(GHOST_TINT.r, GHOST_TINT.g, GHOST_TINT.b, GHOST_START_ALPHA)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		(m as MeshInstance3D).material_override = mat
		(m as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mats.append(mat)
	# Single tween drives alpha on every override material in parallel.
	var tw := create_tween()
	tw.tween_method(
		func(a: float) -> void:
			for mat in mats:
				mat.albedo_color.a = a,
		GHOST_START_ALPHA, 0.0, GHOST_LIFETIME
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(ghost.queue_free)

func _collect_mesh_instances(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_mesh_instances(c, out)

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
	# FPV now is purely a camera relocation to the head — TPV character mesh,
	# weapon rigs, and shadow casting stay exactly as they are in third-person.
	var first := view_mode == ViewMode.FIRST_PERSON
	camera.position = CAM_POS_1P if first else CAM_POS_3P

func _is_under_weapon_socket(n: Node) -> bool:
	var p: Node = n
	while p != null and p != _character:
		if p.is_in_group("weapon_attached"):
			return true
		p = p.get_parent()
	return false

func _equip(s: WeaponSlot) -> void:
	if s == current_slot:
		return
	var next: Node = _weapons[int(s)]
	if next == null:
		push_warning("Weapon slot %d has no node; ignoring equip" % int(s))
		return
	if current_weapon_node != null:
		current_weapon_node.unequip()
	current_slot = s
	current_weapon_node = next
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

# Called by enemy projectiles (sniper / shooter_enemy / gun) via the shared
# take_damage(amount, direction) contract. No HP system yet — we just play a
# flinch clip and shake the camera so incoming fire registers. `direction` is
# the world-space ray of the hit, used to lightly tilt the recoil camera so
# the flinch reads as a direction (later when we have HP, the `amount` field
# can decrement it).
const MAX_HEALTH: float = 25.0
const REGEN_DELAY: float = 5.0
const REGEN_PER_SEC: float = 10.0
var _health: float = MAX_HEALTH
var _regen_cooldown: float = 0.0
var _health_bar: ProgressBar
# Captured the first time take_damage runs, so it's the player's actual
# spawn-in position regardless of cmdline --spawn overrides or scene tweaks.
var _spawn_position: Vector3 = Vector3.INF
var _spawn_yaw: float = 0.0

func take_damage(amount: int, _direction: Vector3) -> void:
	if _spawn_position == Vector3.INF:
		_spawn_position = global_position
		_spawn_yaw = rotation.y
	_health = maxf(_health - float(amount), 0.0)
	_regen_cooldown = REGEN_DELAY
	_refresh_health_bar()
	if _health <= 0.0:
		_respawn()
		return
	if _anim_player != null and _anim_player.has_animation("Hit_Chest"):
		var hl: float = _anim_player.get_animation("Hit_Chest").length
		play_anim_locked("Hit_Chest", minf(hl, 0.35), 1.3)
	_apply_hitstop(0.45, 0.08, 0.05)

func _respawn() -> void:
	global_position = _spawn_position
	rotation.y = _spawn_yaw
	velocity = Vector3.ZERO
	_health = MAX_HEALTH
	_regen_cooldown = 0.0
	_refresh_health_bar()

func _tick_health(delta: float) -> void:
	if _regen_cooldown > 0.0:
		_regen_cooldown = maxf(_regen_cooldown - delta, 0.0)
		return
	if _health < MAX_HEALTH:
		_health = minf(_health + REGEN_PER_SEC * delta, MAX_HEALTH)
		_refresh_health_bar()

func _refresh_health_bar() -> void:
	if _health_bar != null:
		_health_bar.value = _health

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

# ── Character animation state machine ────────────────────────────────────────
# Pick which UAL clip to play this tick based on movement & combat state.
# Names match Quaternius Universal Animation Library (UAL1_Standard).
# NOTE: Godot's gltf importer strips the "_Loop" suffix from looping clips and
# sets loop_mode on the animation instead. UAL's source clips named
# "Idle_Loop", "Jog_Fwd_Loop", etc. become "Idle", "Jog_Fwd", … after import.
# Non-looping clips ("Sword_Attack", "Roll", "Jump_Start", "Jump_Land") keep
# their original names. Use the post-import names here.
const ANIM_IDLE := "Idle"
const ANIM_WALK := "Walk"
const ANIM_JOG := "Jog_Fwd"
const ANIM_SPRINT := "Sprint"
const ANIM_JUMP_START := "Jump_Start"
const ANIM_JUMP_LOOP := "Jump"
const ANIM_JUMP_LAND := "Jump_Land"
const ANIM_ROLL := "Roll"
const ANIM_SWORD_ATTACK := "Sword_Attack"

# Speed thresholds (m/s) for picking between walk/jog/sprint. Speeds are
# measured on the horizontal plane only — vertical jump speed shouldn't
# upgrade walk → run.
const WALK_THRESHOLD: float = 0.35
const JOG_THRESHOLD: float = 5.0
const SPRINT_THRESHOLD: float = 11.0

# Brief lock so a deliberately-triggered animation (sword swing, roll, jump
# transition) isn't immediately stomped by the locomotion picker on the next
# tick. play_anim_locked(name, dur) sets this; locomotion respects it.
var _anim_lock_left: float = 0.0
var _was_grounded: bool = true
# True only between a deliberate jump key press and the next landing. The
# jump-anim state machine (Start → Loop → Land) keys off this so walking off
# a ledge, dashing, or super-lifting doesn't trigger the jump clip.
var _jump_anim_active: bool = false

func play_anim_locked(name: String, lock_duration: float, custom_speed: float = 1.0) -> void:
	_anim_lock_left = lock_duration
	# Force a restart even if `name` matches the currently-playing animation —
	# otherwise chaining the same one-shot (e.g. two sword swings back-to-back)
	# would silently no-op in play_anim() and the body wouldn't re-swing.
	_current_anim = ""
	play_anim(name, custom_speed)

var _anim_debug_accum: float = 0.0
const MOVE_THRESHOLD: float = 0.35   # horiz m/s above which we play the jog loop

# How fast the character model rotates to face its movement direction. The
# player body's yaw stays locked to mouse-look (so the camera + aim stay put),
# but the visual mesh spins so pressing S makes the character physically turn
# around and run that way instead of moonwalking backward.
const CHARACTER_TURN_RATE: float = 18.0

# How long after a ranged shot the character keeps facing the aim direction.
# The mesh snaps to face camera-forward on fire, holds for this many seconds,
# then the same CHARACTER_TURN_RATE lerp blends it back to whatever direction
# the locomotion picker wants (movement input, or stays put if idle).
const AIM_FACE_DURATION: float = 0.35
var _aim_face_left: float = 0.0

func _update_character_facing(delta: float) -> void:
	if _character == null:
		return
	_aim_face_left = maxf(_aim_face_left - delta, 0.0)
	var lerp_weight: float = clampf(CHARACTER_TURN_RATE * delta, 0.0, 1.0)
	if _aim_face_left > 0.0:
		# During an attack the character is hard-locked facing camera-forward —
		# no blend in, no per-frame turning from movement input. The blend
		# (lerp_angle elsewhere in this function) only applies on the way back
		# to neutral once _aim_face_left expires.
		_character.rotation.y = PI
		return
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if input_dir.length() < 0.2:
		return
	# The Quaternius character mesh's default facing is +Z (rig-forward), not
	# the player body's -Z. atan2(x, y) yields the yaw that points +Z toward
	# the input direction in player-local space.
	var target_yaw: float = atan2(input_dir.x, input_dir.y)
	_character.rotation.y = lerp_angle(_character.rotation.y, target_yaw, lerp_weight)

func _update_character_animation() -> void:
	if _anim_player == null:
		return
	var dt: float = get_physics_process_delta_time()
	_anim_lock_left = maxf(_anim_lock_left - dt, 0.0)
	# Jump phase transitions: edge-detect grounded↔airborne so Jump_Start fires
	# exactly once on takeoff and Jump_Land fires exactly once on landing. Both
	# are one-shots locked for their clip length; the airborne Jump loop in the
	# picker below fills the gap between them. The whole state machine is gated
	# on _jump_anim_active so walking off a ledge / dashing / super-lifting
	# never plays the jump clips — only an intentional jump key press does.
	var grounded_now: bool = is_on_floor()
	if _jump_anim_active and _was_grounded and not grounded_now:
		if _anim_player.has_animation(ANIM_JUMP_START):
			var sl: float = _anim_player.get_animation(ANIM_JUMP_START).length
			play_anim_locked(ANIM_JUMP_START, sl, 1.0)
	elif not _was_grounded and grounded_now:
		# Skip Jump_Land entirely when landing with horizontal momentum — locking
		# the full clip while velocity carries the player forward reads as a skid.
		# Idle landings still play the clip so the recovery isn't lost.
		# A lingering Jump_Start lock (set on takeoff for the full clip length)
		# would otherwise hold the airborne pose past touchdown, so always
		# release it here — the locomotion picker should take over immediately.
		var landing_horiz: float = Vector2(velocity.x, velocity.z).length()
		if landing_horiz < MOVE_THRESHOLD and _anim_player.has_animation(ANIM_JUMP_LAND):
			var ll: float = _anim_player.get_animation(ANIM_JUMP_LAND).length
			play_anim_locked(ANIM_JUMP_LAND, ll, 1.0)
		else:
			_anim_lock_left = 0.0
		_jump_anim_active = false
	_was_grounded = grounded_now
	if _anim_lock_left > 0.0:
		return
	var picked: String
	if dash_time_left > 0.0 and _dash_is_roll:
		picked = ANIM_ROLL
		play_anim(picked)
	elif not grounded_now and _jump_anim_active:
		picked = ANIM_JUMP_LOOP
		play_anim(picked)
	else:
		# Pick by input intent, not velocity. Velocity decays/builds gradually
		# via the accel/decel curve, so keying off `velocity.length()` made the
		# jog clip linger after the player let go of the key (and delay-start
		# after pressing it). Reading the input vector directly snaps the loop
		# to the frame the player commands it.
		var move_input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var input_active: bool = move_input.length() > 0.2
		var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
		if not input_active:
			# Pick a weapon-aware idle so the rest stance matches what's in hand:
			# Sword_Idle when the katana is drawn, Pistol_Idle when the gun is
			# equipped, otherwise the default Idle.
			var sword_drawn: bool = current_slot == WeaponSlot.SWORD \
				and _sword != null \
				and _sword.has_method("is_drawn") \
				and bool(_sword.call("is_drawn")) \
				and _anim_player.has_animation("Sword_Idle")
			var pistol_idle: bool = current_slot == WeaponSlot.GUN \
				and _anim_player.has_animation("Pistol_Idle")
			if sword_drawn:
				picked = "Sword_Idle"
			elif pistol_idle:
				picked = "Pistol_Idle"
			else:
				picked = ANIM_IDLE
			play_anim(picked)
		elif horiz_speed >= SPRINT_THRESHOLD and _anim_player.has_animation(ANIM_SPRINT):
			picked = ANIM_SPRINT
			# Speed-scale ramps from 1.0 at the threshold up to ~1.4 at full tilt
			# so the legs still keep visual pace with the world without looking
			# strobed.
			play_anim(picked, clampf(horiz_speed / 13.0, 0.95, 1.4))
		else:
			picked = ANIM_JOG
			play_anim(picked, clampf(horiz_speed / 7.0, 0.8, 1.3))
