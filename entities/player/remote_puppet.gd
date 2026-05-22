extends CharacterBody3D

# Lightweight visual + hurtbox stand-in for another player. Driven by pose
# RPCs from the owning peer — we lerp toward the target each frame so the
# 20 Hz network rate doesn't visibly snap. Carries a CharacterBody3D capsule
# so the local sword scan and bullet Area3D detect it; take_damage() forwards
# the hit back to the owning peer over the relay, which applies HP on their
# authoritative copy.

const SMOOTHING: float = 14.0
const BODY_HEIGHT: float = 2.0
const BODY_RADIUS: float = 0.4
const WEAPON_NAMES := ["Sword", "Gun", "Sniper", "Light Portal", "Dark Portal"]
# Preloaded (same import path the statues use in the .tscn via ExtResource),
# so the puppet GLB is bundled at compile time instead of going through a
# runtime load() that can return null.
const RANGER_SCENE := preload("res://assets/models/characters/quaternius/Male_Ranger.gltf")
const UALLoaderScript := preload("res://entities/util/ual_loader.gd")

var _peer_id: int = 0
var _body: Node3D
var _label: Label3D
var _target_position: Vector3
var _target_yaw: float = 0.0
var _current_slot: int = -1
var _has_first_pose: bool = false
# Floating health bar above the puppet. Two billboarded PlaneMesh layers — a
# dark backing and a green fill whose X-scale matches hp / hp_max.
var _hp_bg: MeshInstance3D
var _hp_fill: MeshInstance3D
var _hp_fill_mat: StandardMaterial3D
var _hp_ratio: float = 1.0
const HP_BAR_WIDTH: float = 1.2
const HP_BAR_HEIGHT: float = 0.12
const HP_BAR_Y_OFFSET: float = 2.45

# Mirrored from the owner's player.gd: name of the currently-playing clip on
# the remote, and the AnimationPlayer that drives the puppet's skeleton.
var _anim_player: AnimationPlayer
var _current_anim: String = ""

func setup(peer_id: int) -> void:
	_peer_id = peer_id
	name = "Puppet_%d" % peer_id

func _ready() -> void:
	# Hurtbox layer 1, mask 0: detectable by the local sword/bullets but
	# doesn't push the local player around physically.
	collision_layer = 1
	collision_mask = 0
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = BODY_RADIUS
	cap.height = BODY_HEIGHT
	shape.shape = cap
	shape.position = Vector3(0, BODY_HEIGHT * 0.5, 0)
	add_child(shape)

	# Instance the preloaded ranger PackedScene exactly like the .tscn does
	# for the local Character (and like the StoneLion/Lowe statues do). No
	# runtime load, no material override — the model renders with whatever
	# material the GLB ships with.
	_body = RANGER_SCENE.instantiate() as Node3D
	_body.position = Vector3.ZERO
	add_child(_body)
	# Same UAL clip library the local player uses, so anim names broadcast in
	# the pose RPC ("Jog_Fwd", "Sword_Attack", etc.) resolve correctly on the
	# puppet's skeleton.
	_anim_player = UALLoaderScript.install(_body)
	if _anim_player != null and _anim_player.has_animation("Idle"):
		_anim_player.play("Idle")
		_current_anim = "Idle"

	# Health bar: two billboarded planes. Backing reads damage taken (dark
	# behind the green fill); fill shrinks toward the left as HP drops.
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.05, 0.05, 0.06, 0.85)
	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.billboard_keep_scale = true
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg_mat.no_depth_test = true
	var bg_mesh := PlaneMesh.new()
	bg_mesh.size = Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT)
	bg_mesh.orientation = PlaneMesh.FACE_Z
	bg_mesh.material = bg_mat
	_hp_bg = MeshInstance3D.new()
	_hp_bg.mesh = bg_mesh
	_hp_bg.position = Vector3(0, HP_BAR_Y_OFFSET, 0)
	_hp_bg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_hp_bg)

	_hp_fill_mat = StandardMaterial3D.new()
	_hp_fill_mat.albedo_color = Color(0.35, 0.95, 0.35, 1.0)
	_hp_fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hp_fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_fill_mat.billboard_keep_scale = true
	_hp_fill_mat.no_depth_test = true
	var fill_mesh := PlaneMesh.new()
	# Slightly smaller than the backing so a thin dark border remains visible.
	fill_mesh.size = Vector2(HP_BAR_WIDTH - 0.04, HP_BAR_HEIGHT - 0.03)
	fill_mesh.orientation = PlaneMesh.FACE_Z
	fill_mesh.material = _hp_fill_mat
	_hp_fill = MeshInstance3D.new()
	_hp_fill.mesh = fill_mesh
	_hp_fill.position = Vector3(0, HP_BAR_Y_OFFSET, 0.001)
	_hp_fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_hp_fill)

	_label = Label3D.new()
	_label.position = Vector3(0, BODY_HEIGHT + 0.4, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.font_size = 28
	_label.outline_size = 8
	_label.modulate = Color(1.0, 0.85, 0.7)
	add_child(_label)
	_refresh_label()

# Sender broadcasts CharacterBody3D origin, which sits at the capsule CENTER
# (capsule height 1.0667 × player scale 2 → ~1.07 m above feet). Our puppet's
# pivot sits at FEET (body at y=0, capsule shifted up by BODY_HEIGHT/2), so we
# subtract the sender's half-capsule to plant the puppet on the ground.
const SENDER_CAPSULE_HALF: float = 1.0667

func set_pose(pos: Vector3, yaw: float, slot: int) -> void:
	# Sender broadcasts CharacterBody3D origin = capsule CENTER (height 1.0667
	# × player scale 2 → ~1.07 m above feet). Puppet pivots at its feet, so
	# subtract the sender's half-capsule to plant the puppet on the ground.
	var grounded := Vector3(pos.x, pos.y - SENDER_CAPSULE_HALF, pos.z)
	_target_position = grounded
	_target_yaw = yaw
	if not _has_first_pose:
		_has_first_pose = true
		global_position = grounded
		rotation.y = yaw
	if slot != _current_slot:
		_current_slot = slot
		_refresh_label()

func set_anim(anim_name: String, speed: float) -> void:
	if _anim_player == null or anim_name == "":
		return
	if anim_name != _current_anim and _anim_player.has_animation(anim_name):
		_current_anim = anim_name
		_anim_player.play(anim_name)
	# Double the broadcast playback speed so the puppet's locomotion reads
	# at the same cadence the sender sees on their own character.
	_anim_player.speed_scale = speed * 2.0

func set_health(hp: float, hp_max: float) -> void:
	if hp_max <= 0.0:
		return
	var new_ratio: float = clampf(hp / hp_max, 0.0, 1.0)
	if absf(new_ratio - _hp_ratio) < 0.001:
		return
	_hp_ratio = new_ratio
	if _hp_fill != null:
		# Billboards keep the mesh facing the camera; scaling along X anchors
		# at the center, so offset X by half the missing width to keep the
		# fill aligned to the bar's left edge.
		var max_w: float = HP_BAR_WIDTH - 0.04
		_hp_fill.scale = Vector3(maxf(_hp_ratio, 0.0001), 1.0, 1.0)
		_hp_fill.position.x = -(1.0 - _hp_ratio) * max_w * 0.5
	if _hp_fill_mat != null:
		# Tint shifts green → yellow → red as HP drops.
		var c := Color(0.35, 0.95, 0.35, 1.0)
		if _hp_ratio < 0.6:
			c = Color(0.95, 0.85, 0.25, 1.0)
		if _hp_ratio < 0.3:
			c = Color(0.95, 0.3, 0.25, 1.0)
		_hp_fill_mat.albedo_color = c

func _refresh_label() -> void:
	if _label == null:
		return
	var slot_name: String = ""
	if _current_slot >= 0 and _current_slot < WEAPON_NAMES.size():
		slot_name = " — " + WEAPON_NAMES[_current_slot]
	_label.text = "Peer %d%s" % [_peer_id, slot_name]

func _process(delta: float) -> void:
	if not _has_first_pose:
		return
	var t: float = clampf(SMOOTHING * delta, 0.0, 1.0)
	global_position = global_position.lerp(_target_position, t)
	var diff: float = wrapf(_target_yaw - rotation.y, -PI, PI)
	rotation.y += diff * t

# Hit from a local weapon (sword scan / projectile). Forward to the owning
# peer over the relay; their player.gd::take_damage applies HP + flinch
# authoritatively on their side. We don't decrement anything locally — the
# puppet has no HP of its own (HP lives on the owning peer's local player).
func take_damage(amount: int, direction: Vector3) -> void:
	Network.send_message({
		"type": "damage",
		"target": _peer_id,
		"amount": amount,
		"dir": [direction.x, direction.y, direction.z],
	})
