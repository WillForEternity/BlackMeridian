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
const MODEL_PATH := "res://assets/models/ghost_leviathan.glb"
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
const VOLLEY_INTERVAL: float = 6.0          # seconds between volley salvos
const VOLLEY_DURATION: float = 2.0          # total length of a volley salvo
const VOLLEY_SHOT_MIN_GAP: float = 0.04     # minimum gap between successive volley shots
const VOLLEY_SHOT_MAX_GAP: float = 0.18     # maximum gap — randomized so it reads as sporadic
const VOLLEY_SPRAY_RADIUS: float = 1.0      # 1 m spread radius at target distance

var _anim_player: AnimationPlayer
var _model: Node3D
var _last_facing: Vector3 = Vector3.FORWARD
var _long_beam_cd: float = 3.0
var _volley_cd: float = 5.0
var _volley_remaining: float = 0.0
var _volley_shot_cd: float = 0.0
var _target: Node3D

func _ready() -> void:
	# Hurtbox layer 1 so player bullets/sword hit it. Mask 0 so we never
	# touch terrain or other physics — we manually fly via _process.
	collision_layer = 1
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
	global_position = Vector3(0.0, 60.0, 60.0)

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
	_tick_attacks(delta)

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

func _fire_long_beam() -> void:
	var dir: Vector3 = (_target.global_position - global_position).normalized()
	_spawn_beam(global_position + dir * 3.0, dir, "long")

func _fire_volley_shot() -> void:
	# Spray around the target with a 1 m radius spread at the target's
	# distance — pick a random offset in a sphere and aim through it.
	var to_target: Vector3 = _target.global_position - global_position
	var dist: float = maxf(to_target.length(), 1.0)
	var aim_point: Vector3 = _target.global_position + Vector3(
		randf_range(-VOLLEY_SPRAY_RADIUS, VOLLEY_SPRAY_RADIUS),
		randf_range(-VOLLEY_SPRAY_RADIUS, VOLLEY_SPRAY_RADIUS) * 0.5,
		randf_range(-VOLLEY_SPRAY_RADIUS, VOLLEY_SPRAY_RADIUS)
	)
	var dir: Vector3 = (aim_point - global_position).normalized()
	_spawn_beam(global_position + dir * 3.0, dir, "volley")

func _spawn_beam(at: Vector3, dir: Vector3, mode: String) -> void:
	var beam = BeamScene.new()
	get_tree().current_scene.add_child(beam)
	beam.setup(at, dir, mode)

func take_damage(amount: int, _direction: Vector3) -> void:
	_health = maxf(_health - float(amount), 0.0)
	if _health <= 0.0:
		queue_free()
