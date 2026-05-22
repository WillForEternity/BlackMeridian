extends CharacterBody3D

# Boss creature: tracks the closest player (local + remote puppets), hovers
# above them, and fires two attack patterns —
#   - LONG BEAM: a single 5-second laser aimed at the target. 2.5 dps.
#   - VOLLEY: a sporadic burst of small beams sprayed in a 1 m radius cone
#             around the target. Each shot deals gun-tier damage (2).
# Beams are CharacterBody3D-detectable (layer 1), so they hit player hurtboxes
# the same way bullets do.
# HP is local-per-client (no relay) so each client sees its own simulation.
# A polished MP version would centralize this on the host.

const BeamScene := preload("res://entities/leviathan/leviathan_beam.gd")
const LongBeamScene := preload("res://entities/leviathan/leviathan_long_beam.gd")
const MODEL_PATH := "res://assets/models/ghost_leviathan.glb"

# Health bar (billboarded above the boss, like the remote-puppet bars).
const HP_BAR_WIDTH: float = 4.0
const HP_BAR_HEIGHT: float = 0.45
const HP_BAR_Y_OFFSET: float = 18.0
const SWIM_ANIM_SUBSTRING := "swimF"

const ALTITUDE_OVER_TARGET: float = 18.0
const TARGET_LENGTH: float = 42.0
const FOLLOW_SPEED: float = 14.0
# Don't get too close to the target — beams need flight time to read as dodgeable.
const MIN_DISTANCE: float = 28.0

const MAX_HEALTH: float = 500.0
var _health: float = MAX_HEALTH

# Attack timing.
const LONG_BEAM_INTERVAL: float = 9.0       # seconds between long-beam casts
const VOLLEY_INTERVAL: float = 3.0          # seconds between volley salvos (2× as frequent)
const VOLLEY_DURATION: float = 6.0          # total length of a volley salvo
const VOLLEY_SHOT_MIN_GAP: float = 0.04     # minimum gap between successive volley shots
const VOLLEY_SHOT_MAX_GAP: float = 0.18     # maximum gap — randomized so it reads as sporadic
const VOLLEY_SPRAY_RADIUS: float = 1.0      # 1 m spread radius at target distance

var _anim_player: AnimationPlayer
var _model: Node3D
var _last_facing: Vector3 = Vector3.FORWARD
# Initial cooldowns delay the boss's first attack by 10 s so the player has
# time to orient / fight other enemies before the leviathan opens fire.
var _long_beam_cd: float = 10.0
var _volley_cd: float = 10.0
var _volley_remaining: float = 0.0
var _volley_shot_cd: float = 0.0
var _target: Node3D
var _hp_root: Node3D
var _hp_bg: MeshInstance3D
var _hp_fill: MeshInstance3D
var _hp_fill_mat: StandardMaterial3D
var _hp_ratio: float = 1.0
# Persistent invisible pursuer used as the long beam's endpoint. Updated
# every frame (in _process) toward the current target at PLAYER_BASE_SPEED ×
# CHASE_SPEED_MULT so its position is meaningful at the instant a long beam
# is cast — no "starting from origin" jolt. Frozen while the target is
# mid-dash so a well-timed dash leaves it behind.
const PLAYER_BASE_SPEED: float = 13.0
const CHASE_SPEED_MULT: float = 1.5
const CHASE_SPEED: float = PLAYER_BASE_SPEED * CHASE_SPEED_MULT
var _chaser_pos: Vector3 = Vector3.ZERO
var _chaser_seeded: bool = false

func chaser_position() -> Vector3:
	return _chaser_pos

func _ready() -> void:
	print("[GhostLeviathan] _ready start")
	# Hurtbox layer 1 so player bullets/sword hit it. Mask 0 so we never
	# touch terrain or other physics — we manually fly via _process.
	collision_layer = 1 | 4
	collision_mask = 0
	# Wrap-around collision capsule sized to the leviathan's visual.
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 2.5
	cap.height = TARGET_LENGTH * 0.7
	shape.shape = cap
	# Rotate capsule so its long axis matches the model's body (local +Z).
	shape.rotation = Vector3(PI / 2.0, 0.0, 0.0)
	add_child(shape)

	var packed: PackedScene = load(MODEL_PATH) as PackedScene
	if packed == null:
		push_warning("[GhostLeviathan] failed to load %s" % MODEL_PATH)
		return
	_model = packed.instantiate() as Node3D
	if _model == null:
		return
	add_child(_model)
	_normalize_size(_model)
	_anim_player = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim_player != null:
		var pick: String = _find_anim_containing(_anim_player, SWIM_ANIM_SUBSTRING)
		if pick == "" and _anim_player.get_animation_list().size() > 0:
			pick = _anim_player.get_animation_list()[0]
		if pick != "":
			var anim: Animation = _anim_player.get_animation(pick)
			anim.loop_mode = Animation.LOOP_LINEAR
			_anim_player.play(pick)
			_anim_player.speed_scale = 0.25
	_build_hp_bar()
	# Spawn directly in front of the player so they see it immediately on
	# game start. Player faces -Z, so -Z is "forward"; +Y is up.
	var local_player: Node3D = get_tree().current_scene.get_node_or_null("Player") as Node3D
	if local_player != null:
		var fwd: Vector3 = -local_player.global_transform.basis.z
		global_position = local_player.global_position + fwd * 35.0 + Vector3(0.0, 20.0, 0.0)
	else:
		global_position = Vector3(0.0, 20.0, -35.0)
	print("[GhostLeviathan] spawned at %s, model present=%s, anim_player=%s" % [global_position, _model != null, _anim_player != null])

func _build_hp_bar() -> void:
	# top_level so the bar's transform is independent of the leviathan's
	# look_at rotation — the bar always floats world-up over the boss and
	# both layers are camera-billboarded so they read from any angle.
	_hp_root = Node3D.new()
	_hp_root.top_level = true
	add_child(_hp_root)

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
	_hp_bg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hp_root.add_child(_hp_bg)

	_hp_fill_mat = StandardMaterial3D.new()
	_hp_fill_mat.albedo_color = Color(0.95, 0.35, 0.95, 1.0)
	_hp_fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hp_fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_fill_mat.billboard_keep_scale = true
	_hp_fill_mat.no_depth_test = true
	var fill_mesh := PlaneMesh.new()
	fill_mesh.size = Vector2(HP_BAR_WIDTH - 0.12, HP_BAR_HEIGHT - 0.08)
	fill_mesh.orientation = PlaneMesh.FACE_Z
	fill_mesh.material = _hp_fill_mat
	_hp_fill = MeshInstance3D.new()
	_hp_fill.mesh = fill_mesh
	_hp_fill.position = Vector3(0, 0, 0.001)
	_hp_fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hp_root.add_child(_hp_fill)

func _update_hp_bar() -> void:
	if _hp_root == null:
		return
	_hp_root.global_position = global_position + Vector3(0, HP_BAR_Y_OFFSET, 0)
	var new_ratio: float = clampf(_health / MAX_HEALTH, 0.0, 1.0)
	if absf(new_ratio - _hp_ratio) < 0.001:
		return
	_hp_ratio = new_ratio
	if _hp_fill != null:
		var max_w: float = HP_BAR_WIDTH - 0.12
		_hp_fill.scale = Vector3(maxf(_hp_ratio, 0.0001), 1.0, 1.0)
		# Anchor the fill to the left edge so it shrinks toward the right
		# as HP drops, instead of shrinking from both ends.
		_hp_fill.position.x = -(1.0 - _hp_ratio) * max_w * 0.5
	if _hp_fill_mat != null:
		var c := Color(0.95, 0.35, 0.95, 1.0)
		if _hp_ratio < 0.6:
			c = Color(0.95, 0.85, 0.25, 1.0)
		if _hp_ratio < 0.3:
			c = Color(0.95, 0.25, 0.25, 1.0)
		_hp_fill_mat.albedo_color = c
	print("[GhostLeviathan] spawned at ", global_position, ", model=", _model, ", anim_player=", _anim_player)

func _find_anim_containing(ap: AnimationPlayer, needle: String) -> String:
	for n in ap.get_animation_list():
		if String(n).findn(needle) >= 0:
			return n
	return ""

func _normalize_size(model: Node3D) -> void:
	var box := AABB()
	var any := false
	for n in _gather_visuals(model):
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
		var s: float = TARGET_LENGTH / longest
		model.scale = Vector3(s, s, s)

func _transform_to_ancestor(node: Node3D, ancestor: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != ancestor:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t

func _gather_visuals(n: Node) -> Array:
	var out: Array = []
	if n is VisualInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_gather_visuals(c))
	return out

# Each frame: re-pick the closest player, fly toward a point above them, and
# tick attack cooldowns.
func _process(delta: float) -> void:
	_target = _find_closest_player()
	if _target != null:
		var ideal := Vector3(_target.global_position.x, _target.global_position.y + ALTITUDE_OVER_TARGET, _target.global_position.z)
		var to_ideal: Vector3 = ideal - global_position
		# Maintain MIN_DISTANCE horizontally so the leviathan doesn't sit
		# directly on top of the target.
		var horiz: Vector2 = Vector2(to_ideal.x, to_ideal.z)
		if horiz.length() < MIN_DISTANCE:
			var pullback: Vector2 = horiz.normalized() * (horiz.length() - MIN_DISTANCE)
			to_ideal.x = pullback.x
			to_ideal.z = pullback.y
		var step := to_ideal
		var max_step: float = FOLLOW_SPEED * delta
		if step.length() > max_step:
			step = step.normalized() * max_step
		var prev := global_position
		global_position += step
		var face_step: Vector3 = global_position - prev
		face_step.y = 0.0
		if face_step.length_squared() > 1e-6:
			_last_facing = face_step.normalized()
		# Always orient toward the current target so beams aim correctly.
		var head_dir: Vector3 = (_target.global_position - global_position)
		head_dir.y = 0.0
		if head_dir.length_squared() > 1e-6:
			head_dir = head_dir.normalized()
			# Model's head is +Z; look_at aims local -Z. Negate so head leads.
			look_at(global_position - head_dir, Vector3.UP)
	_tick_chaser(delta)
	_tick_attacks(delta)
	_update_hp_bar()

func _tick_chaser(delta: float) -> void:
	if _target == null:
		return
	var t_pos: Vector3 = _target.global_position
	if not _chaser_seeded:
		# First sighting: snap the chaser onto the target so the very first
		# long beam doesn't have to traverse a stale origin position.
		_chaser_pos = t_pos
		_chaser_seeded = true
		return
	# Freeze while the target dashes — the dash window IS the player's escape
	# tool against the long beam, by design.
	var dashing: bool = "dash_time_left" in _target and float(_target.dash_time_left) > 0.0
	if dashing:
		return
	var diff: Vector3 = t_pos - _chaser_pos
	var step: float = CHASE_SPEED * delta
	if diff.length() > step:
		_chaser_pos += diff.normalized() * step
	else:
		_chaser_pos = t_pos

func _find_closest_player() -> Node3D:
	var scene: Node = get_tree().current_scene
	var best_d2: float = INF
	var best: Node3D = null
	var local_player: Node3D = scene.get_node_or_null("Player") as Node3D
	if local_player != null:
		var d2: float = local_player.global_position.distance_squared_to(global_position)
		if d2 < best_d2:
			best_d2 = d2
			best = local_player
	var remote_root: Node = scene.get_node_or_null("RemotePlayers")
	if remote_root != null:
		for child in remote_root.get_children():
			if child is Node3D:
				var d3: float = (child as Node3D).global_position.distance_squared_to(global_position)
				if d3 < best_d2:
					best_d2 = d3
					best = child as Node3D
	return best

func _tick_attacks(delta: float) -> void:
	if _target == null:
		return
	_long_beam_cd = maxf(_long_beam_cd - delta, 0.0)
	_volley_cd = maxf(_volley_cd - delta, 0.0)
	if _long_beam_cd <= 0.0:
		_fire_long_beam()
		_long_beam_cd = LONG_BEAM_INTERVAL
	if _volley_cd <= 0.0 and _volley_remaining <= 0.0:
		_volley_remaining = VOLLEY_DURATION
		_volley_shot_cd = 0.0
		_volley_cd = VOLLEY_INTERVAL + VOLLEY_DURATION
	if _volley_remaining > 0.0:
		_volley_remaining -= delta
		_volley_shot_cd -= delta
		if _volley_shot_cd <= 0.0:
			_fire_volley_shot()
			_volley_shot_cd = randf_range(VOLLEY_SHOT_MIN_GAP, VOLLEY_SHOT_MAX_GAP)

# Spawn origin for beams. The user preferred the chest-origin look (raw
# global_position) over the snout-tip, so HEAD_OFFSET is 0. Kept as a named
# helper so the long-beam script and volley both pull from the same place
# if we want to retune it later.
const HEAD_OFFSET: float = 0.0

func _head_position() -> Vector3:
	return global_position + global_transform.basis.z * HEAD_OFFSET

func _fire_long_beam() -> void:
	# Continuous tracking beam anchored at the leviathan's HEAD (so it visibly
	# emanates from its mouth, not its belly). See leviathan_long_beam.gd.
	var beam = LongBeamScene.new()
	get_tree().current_scene.add_child(beam)
	beam.setup(self, _target)

func _fire_volley_shot() -> void:
	# Spray around the target with a 1 m radius spread; spawn at the head so
	# the volley beam clears the leviathan's own hurtbox (otherwise the beam
	# would spawn inside the body capsule, detect the leviathan on layer 1,
	# and despawn instantly — which is why volley shots were invisible).
	var head: Vector3 = _head_position()
	var aim_point: Vector3 = _target.global_position + Vector3(
		randf_range(-VOLLEY_SPRAY_RADIUS, VOLLEY_SPRAY_RADIUS),
		randf_range(-VOLLEY_SPRAY_RADIUS, VOLLEY_SPRAY_RADIUS) * 0.5,
		randf_range(-VOLLEY_SPRAY_RADIUS, VOLLEY_SPRAY_RADIUS)
	)
	var dir: Vector3 = (aim_point - head).normalized()
	var beam = BeamScene.new()
	get_tree().current_scene.add_child(beam)
	beam.setup(head, dir, self, _target)

func take_damage(amount: int, _direction: Vector3) -> void:
	_health = maxf(_health - float(amount), 0.0)
	if _health <= 0.0:
		queue_free()
