extends CharacterBody3D

# Boss creature: tracks the closest player (local + remote puppets), hovers
# above them, and fires three attack patterns —
#   - LONG BEAM: a single 5-second laser aimed at the target. 2.5 dps.
#   - VOLLEY: a sporadic burst of small beams sprayed in a 1 m radius cone
#             around the target. Each shot deals gun-tier damage (2).
#   - MISSILE VOLLEY: a lock-on warning, then a VLS-style staggered salvo of
#             N homing missiles. Missiles launch with a heavy UP bias (VLS
#             fountain), pitch over to a lofted midcourse, climb above the
#             target, then plunge down in a terminal dive. See
#             leviathan_missile.gd for the three-phase BOOST/LOFT/TERMINAL
#             flight model and leviathan_lock_indicator.gd for the warning.
# Beams are CharacterBody3D-detectable (layer 1), so they hit player hurtboxes
# the same way bullets do.
# HP is local-per-client (no relay) so each client sees its own simulation.
# A polished MP version would centralize this on the host.

const BeamScene := preload("res://entities/leviathan/leviathan_beam.gd")
const LongBeamScene := preload("res://entities/leviathan/leviathan_long_beam.gd")
const MissileScene := preload("res://entities/leviathan/leviathan_missile.gd")
const FishProjectileScene := preload("res://entities/leviathan/leviathan_fish_projectile.gd")
const LockIndicatorScene := preload("res://entities/leviathan/leviathan_lock_indicator.gd")
const MODEL_PATH := "res://assets/models/ghost_leviathan.glb"

# Health bar (billboarded above the boss, like the remote-puppet bars).
const HP_BAR_WIDTH: float = 4.0
const HP_BAR_HEIGHT: float = 0.45
const HP_BAR_Y_OFFSET: float = 36.0
const SWIM_ANIM_SUBSTRING := "swimF"

const ALTITUDE_OVER_TARGET: float = 27.0
const TARGET_LENGTH: float = 84.0
const FOLLOW_SPEED: float = 9.33
# Don't get too close to the target — beams need flight time to read as dodgeable.
const MIN_DISTANCE: float = 42.0

const MAX_HEALTH: float = 500.0
var _health: float = MAX_HEALTH

# Attack timing.
# Attacks run as a cycle, not in parallel: LONG_BEAM → break → VOLLEY → break
# → MISSILE_VOLLEY → break → LONG_BEAM → … so only one attack pattern is
# active at a time. Earlier versions ran independent cooldowns for each, which
# could overlap the long beam and a volley salvo simultaneously and feel
# chaotic / unfair.
const LONG_BEAM_DURATION: float = 5.0       # matches LIFETIME in leviathan_long_beam.gd
const VOLLEY_DURATION: float = 6.0          # total length of a volley salvo
const ATTACK_BREAK: float = 13.0            # quiet pause between consecutive attacks — combined with the ~6–7 s attack durations this gives a cycle of roughly 20 s per scripted attack (missile salvo / fish-projectile / long beam)

# Passive background fire: independent of the attack-state cycle, the boss
# spits PASSIVE_MISSILE_COUNT gem missiles at the target every
# PASSIVE_FIRE_INTERVAL seconds. Runs in parallel with whatever discrete
# attack state is currently active (long beam, missile salvo, fish, idle),
# so the player never gets a fully quiet window between scripted attacks.
# Each missile is a normal homing crystal — same script as the salvo, just
# spawned in pairs at a slow cadence instead of as a 12+ ring volley.
const PASSIVE_FIRE_INTERVAL: float = 4.0
const PASSIVE_MISSILE_COUNT: int = 2
# Launch direction biases for passive missiles. Less UP than the main volley
# fountain (we don't need a tall VLS arc for a constant drip), more FORWARD
# so the pair lances straight toward the player and starts homing quickly.
const PASSIVE_MISSILE_UP_BIAS: float = 0.55
const PASSIVE_MISSILE_RADIAL_BIAS: float = 0.35
const PASSIVE_MISSILE_FORWARD_BIAS: float = 0.95
const PASSIVE_MISSILE_RING_RADIUS: float = 1.5
# Main-attack missiles join this group on spawn so _tick_passive_fire can
# hold its volley until the previous scripted salvo has fully resolved —
# passive trickle should never overlap a burst.
const MAIN_MISSILE_GROUP: StringName = &"main_attack_missile"
const VOLLEY_SHOT_MIN_GAP: float = 0.04     # minimum gap between successive volley shots
const VOLLEY_SHOT_MAX_GAP: float = 0.18     # maximum gap — randomized so it reads as sporadic
const VOLLEY_SPRAY_RADIUS: float = 1.0      # 1 m spread radius at target distance

# Missile volley: lock-on warning, then a VLS-style staggered salvo. The total
# state window is sized to cover the longest expected per-missile flight time
# (boost + loft + dive) plus the staggered launch sequence, so the screen has
# resolved by the time the next attack queues up.
#
# Sequence inside MISSILE_VOLLEY state:
#   t = 0                     state begins; lock indicator spawned on target
#   t = MISSILE_LOCK_DURATION first missile launches (lock indicator self-frees)
#   t = MISSILE_LOCK_DURATION + (i-1)·MISSILE_LAUNCH_STAGGER
#                             missile i launches (VLS hot-launch cadence)
#   t = MISSILE_VOLLEY_DURATION  state ends, ATTACK_BREAK begins
const MISSILE_VOLLEY_COUNT: int = 18            # ring petal count — keep even so spin-sign alternation is symmetric (~1.5x the previous 12)
const MISSILE_VOLLEY_DURATION: float = 6.0      # full window: lock + launch sequence + flight resolution
const MISSILE_LOCK_DURATION: float = 1.2        # pre-launch warning — gives the player time to spot the lock and reposition
const MISSILE_LAUNCH_STAGGER: float = 0.08      # per-missile launch gap; reads as VLS firing cadence rather than a single salvo
const MISSILE_RING_RADIUS: float = 5.0          # how wide the initial ring fans out from the boss head
# Launch direction = UP·MISSILE_UP_BIAS + radial·MISSILE_RADIAL_BIAS +
# forward·MISSILE_FORWARD_BIAS, then normalized. UP dominates so missiles climb
# vertically first (VLS fountain); radial gives a visible fan; forward leans
# them mildly toward the player. The pitch-over to target is handled by the
# missile's LOFT phase, not by the launch direction.
const MISSILE_UP_BIAS: float = 1.10             # dominant vertical component → VLS fountain
const MISSILE_RADIAL_BIAS: float = 0.45         # mild sideways fan around the ring
const MISSILE_FORWARD_BIAS: float = 0.20        # mild forward lean toward player

# Fish-projectile attack: same VLS-fountain structure as the missile volley
# but only TWO projectiles, fired from opposite sides of the head. The fish
# are destroyable (HP), much larger, and faster — the intent is for the
# player to choose between shooting them down or out-maneuvering.
# Cadence: one fish-projectile volley after every MISSILE_VOLLEYS_BEFORE_FISH
# missile volleys (so missile → missile → fish → missile → missile → fish …).
const FISH_COUNT: int = 2
const FISH_VOLLEY_DURATION: float = 7.5
const FISH_LOCK_DURATION: float = 1.4
const FISH_LAUNCH_STAGGER: float = 0.18
const FISH_RING_RADIUS: float = 4.0
# Heavy FORWARD bias (low UP) so the fish leaves the boss on a near-horizontal
# vector and skims toward the player at low altitude instead of climbing
# into a missile-style fountain first.
const FISH_UP_BIAS: float = 0.15
const FISH_RADIAL_BIAS: float = 0.50
const FISH_FORWARD_BIAS: float = 1.10
const MISSILE_VOLLEYS_BEFORE_FISH: int = 2

enum AttackState { IDLE, LONG_BEAM, VOLLEY, MISSILE_VOLLEY, FISH_PROJECTILE }

# Long beam is the most punishing pattern, so it should feel like a rare
# special — between long beams the boss alternates VOLLEY ↔ MISSILE_VOLLEY.
# A value of 5 means 1-in-5 attacks is a long beam (~one every 35-40 s given
# average attack duration + ATTACK_BREAK).
const LONG_BEAM_FREQUENCY: int = 5

var _anim_player: AnimationPlayer
var _model: Node3D
var _last_facing: Vector3 = Vector3.FORWARD
# Initial 10 s break before the first attack so the player has time to orient
# / fight other enemies before the leviathan opens fire.
var _attack_state: int = AttackState.IDLE
var _attack_state_timer: float = 10.0
# Counter for the LONG_BEAM_FREQUENCY rotation. Starts near the threshold so
# the first ~few attacks are short ones and the long beam shows up after the
# player has had a moment to settle in.
var _attacks_since_long_beam: int = 0
# Toggles VOLLEY ↔ MISSILE_VOLLEY for the in-between attacks so consecutive
# short attacks aren't always the same type.
var _next_short_attack: int = AttackState.VOLLEY
var _next_attack: int = AttackState.MISSILE_VOLLEY
var _volley_shot_cd: float = 0.0
# Initialized to PASSIVE_FIRE_INTERVAL so the first passive burst lands a
# beat after spawn, not on the spawn frame.
var _passive_fire_cd: float = 4.0
# Staggered missile launch state. _missile_queue holds pending launches as
# dicts { t, at, dir, phase, spin }; t is seconds-since-state-began. The queue
# is drained in _tick_attacks during the MISSILE_VOLLEY state, popping any
# entry whose t has been reached. _lock_indicator holds the lock-on warning
# instance so we can clean it up on respawn/death.
var _missile_queue: Array = []
var _missile_queue_time: float = 0.0
# Counts missile volleys fired since the last fish-projectile volley so we
# can trigger the fish attack every MISSILE_VOLLEYS_BEFORE_FISH volleys.
var _missile_volleys_since_fish: int = 0
var _lock_indicator: Node = null
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

# Scoreboard: { peer_id: int -> kill_count: int }. peer_id 0 represents the
# local player in single-player sessions; in MP each peer's kills are keyed
# by their Network.my_peer_id.
var _kills_by_peer: Dictionary = {}
var _score_label: Label3D

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
	cap.radius = 5.0
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

	# Scoreboard label sits above the HP bar. Billboard-on so it stays
	# readable from any angle, no_depth_test so it draws through terrain
	# (matches the HP bar's behavior).
	_score_label = Label3D.new()
	_score_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_score_label.no_depth_test = true
	_score_label.font_size = 36
	_score_label.outline_size = 8
	_score_label.modulate = Color(1.0, 1.0, 1.0)
	_score_label.position = Vector3(0, HP_BAR_HEIGHT * 0.5 + 0.6, 0)
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_root.add_child(_score_label)
	_refresh_score_label()

# Render the kill scoreboard. In solo: "Kills: N". In MP: one line per peer,
# top-down sorted by descending kills (then peer_id). The local player's row
# is bracketed "[Peer 5]" so you can tell yours apart at a glance.
func _refresh_score_label() -> void:
	if _score_label == null:
		return
	if not Network.is_in_room():
		var n: int = int(_kills_by_peer.get(0, 0))
		_score_label.text = "Kills: %d" % n
		return
	var rows: Array = []
	for pid in _kills_by_peer.keys():
		rows.append([int(pid), int(_kills_by_peer[pid])])
	rows.sort_custom(func(a, b):
		if a[1] != b[1]:
			return a[1] > b[1]
		return a[0] < b[0]
	)
	var lines: Array = []
	for r in rows:
		var pid: int = r[0]
		var k: int = r[1]
		if pid == Network.my_peer_id:
			lines.append("[You] %d" % k)
		else:
			lines.append("Peer %d: %d" % [pid, k])
	if lines.is_empty():
		lines.append("No kills yet")
	_score_label.text = "\n".join(lines)

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
	_tick_passive_fire(delta)
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

# Passive background fire: ticks independently of the attack-state machine
# so the boss always has trickle pressure on the player. Skips on respawn
# frames where _target hasn't been resolved yet, and holds firing while any
# main-attack salvo missile is still in the air so the passive pair never
# overlaps the burst.
func _tick_passive_fire(delta: float) -> void:
	if _target == null:
		return
	_passive_fire_cd -= delta
	if _passive_fire_cd > 0.0:
		return
	# Cooldown elapsed but a main salvo is still resolving — hold the shot
	# (cooldown stays at/under 0 so the moment the group clears, the next
	# tick fires immediately and the interval resets from there).
	if not get_tree().get_nodes_in_group(MAIN_MISSILE_GROUP).is_empty():
		return
	_passive_fire_cd = PASSIVE_FIRE_INTERVAL
	_fire_passive_missile_pair()


# Spawn PASSIVE_MISSILE_COUNT homing crystal missiles in a tight fan around
# the boss head — same MissileScene the main salvo uses, just with a much
# smaller ring and forward-leaning launch bias so the pair lances toward the
# player instead of climbing into a VLS arc first. Crystal type is randomized
# per missile so consecutive pairs aren't always the same color.
func _fire_passive_missile_pair() -> void:
	var spawn_pos: Vector3 = _head_position()
	var to_target: Vector3 = _target.global_position - spawn_pos
	if to_target.length_squared() < 1e-4:
		return
	var forward: Vector3 = to_target.normalized()
	var up_ref: Vector3 = Vector3.UP
	if absf(forward.dot(Vector3.UP)) > 0.95:
		up_ref = Vector3.FORWARD
	var right: Vector3 = forward.cross(up_ref).normalized()
	var up: Vector3 = right.cross(forward).normalized()
	for i in range(PASSIVE_MISSILE_COUNT):
		# Pair sits at opposing radial angles (0, π) → a left/right split.
		var ring_angle: float = TAU * float(i) / float(PASSIVE_MISSILE_COUNT)
		var radial: Vector3 = right * cos(ring_angle) + up * sin(ring_angle)
		var dir: Vector3 = (Vector3.UP * PASSIVE_MISSILE_UP_BIAS + radial * PASSIVE_MISSILE_RADIAL_BIAS + forward * PASSIVE_MISSILE_FORWARD_BIAS).normalized()
		var at: Vector3 = spawn_pos + radial * PASSIVE_MISSILE_RING_RADIUS
		var phase: float = ring_angle
		var spin: float = 1.0 if (i % 2 == 0) else -1.0
		var ctype: int = randi() % 3
		var m = MissileScene.new()
		get_tree().current_scene.add_child(m)
		m.setup(at, dir, self, _target, phase, spin, ctype)

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
	_attack_state_timer -= delta
	match _attack_state:
		AttackState.IDLE:
			if _attack_state_timer <= 0.0:
				_begin_attack(_next_attack)
		AttackState.LONG_BEAM:
			# Long beam is fire-and-forget — the LongBeamScene self-destructs
			# after its own LIFETIME. We just wait out LONG_BEAM_DURATION and
			# then cool down.
			if _attack_state_timer <= 0.0:
				_end_attack()
		AttackState.VOLLEY:
			_volley_shot_cd -= delta
			if _volley_shot_cd <= 0.0:
				_fire_volley_shot()
				_volley_shot_cd = randf_range(VOLLEY_SHOT_MIN_GAP, VOLLEY_SHOT_MAX_GAP)
			if _attack_state_timer <= 0.0:
				_end_attack()
		AttackState.MISSILE_VOLLEY:
			# Two-phase tick:
			#   1. While the lock warning plays + the salvo is launching, drain
			#      any queue entries whose scheduled launch time has been
			#      reached. Each pop spawns a missile with the precomputed
			#      launch vector and Itano phase/spin assigned at queue time.
			#   2. Once the queue is empty, the remaining window is just flight
			#      resolution — wait for the timer to expire.
			_missile_queue_time += delta
			while not _missile_queue.is_empty() and float(_missile_queue[0].get("t", 0.0)) <= _missile_queue_time:
				var d: Dictionary = _missile_queue.pop_front()
				var m = MissileScene.new()
				get_tree().current_scene.add_child(m)
				m.setup(d["at"], d["dir"], self, _target, d["phase"], d["spin"], int(d.get("type", 0)))
				m.add_to_group(MAIN_MISSILE_GROUP)
			if _attack_state_timer <= 0.0:
				_end_attack()
		AttackState.FISH_PROJECTILE:
			# Reuse the missile-volley queue/launch scaffolding — queue entries
			# omit "type" and we spawn FishProjectileScene instead.
			_missile_queue_time += delta
			while not _missile_queue.is_empty() and float(_missile_queue[0].get("t", 0.0)) <= _missile_queue_time:
				var d: Dictionary = _missile_queue.pop_front()
				var f = FishProjectileScene.new()
				get_tree().current_scene.add_child(f)
				f.setup(d["at"], d["dir"], self, _target, d["phase"], d["spin"])
			if _attack_state_timer <= 0.0:
				_end_attack()

func _begin_attack(which: int) -> void:
	_attack_state = which
	if which == AttackState.LONG_BEAM:
		_fire_long_beam()
		_attack_state_timer = LONG_BEAM_DURATION
	elif which == AttackState.VOLLEY:
		_attack_state_timer = VOLLEY_DURATION
		_volley_shot_cd = 0.0
	elif which == AttackState.FISH_PROJECTILE:
		_queue_fish_projectile_volley()
		_attack_state_timer = FISH_VOLLEY_DURATION
		_missile_volleys_since_fish = 0
	else:
		_queue_missile_volley()
		_attack_state_timer = MISSILE_VOLLEY_DURATION
		_missile_volleys_since_fish += 1
	_next_attack = _pick_next_attack()

# Picks the next attack. While the broader attack rotation is paused, the boss
# alternates between MISSILE_VOLLEY and FISH_PROJECTILE on a fixed cadence:
# after every MISSILE_VOLLEYS_BEFORE_FISH missile volleys, fire one fish-
# projectile volley. The fish pattern reads as a deliberate threat the
# player has to decide whether to shoot down or evade, which gives the
# missile cadence more texture without re-introducing the long beam yet.
# Original rotation (reinstate by restoring the older body):
#   - LONG_BEAM every LONG_BEAM_FREQUENCY attacks
#   - the rest alternate VOLLEY ↔ MISSILE_VOLLEY
func _pick_next_attack() -> int:
	if _missile_volleys_since_fish >= MISSILE_VOLLEYS_BEFORE_FISH:
		return AttackState.FISH_PROJECTILE
	return AttackState.MISSILE_VOLLEY

func _end_attack() -> void:
	_attack_state = AttackState.IDLE
	_attack_state_timer = ATTACK_BREAK

# Spawn origin for beams. The user preferred the chest-origin look (raw
# global_position) over the snout-tip, so HEAD_OFFSET is 0. Kept as a named
# helper so the long-beam script and volley both pull from the same place
# if we want to retune it later.
const HEAD_OFFSET: float = 0.0

func _head_position() -> Vector3:
	return global_position + global_transform.basis.z * HEAD_OFFSET

# How far off the target the chaser should sit when a long beam fires. The
# chaser tracks the player continuously, so by fire-time it's usually right on
# them — which makes the beam appear to spawn directly on the player. Nudging
# the chaser 5 m back along the target→leviathan line gives a brief visible
# "leadup" before the laser closes the gap and can still hit normally.
const LONG_BEAM_SPAWN_OFFSET: float = 5.0

func _fire_long_beam() -> void:
	# Continuous tracking beam anchored at the leviathan's HEAD (so it visibly
	# emanates from its mouth, not its belly). See leviathan_long_beam.gd.
	# Snap the chaser to LONG_BEAM_SPAWN_OFFSET m off the target toward the
	# leviathan first, so the beam doesn't visually spawn on the player. From
	# there the chaser resumes its normal CHASE_SPEED pursuit.
	if _target != null:
		var t_pos: Vector3 = _target.global_position
		var to_lev: Vector3 = _head_position() - t_pos
		if to_lev.length_squared() > 1e-4:
			_chaser_pos = t_pos + to_lev.normalized() * LONG_BEAM_SPAWN_OFFSET
			_chaser_seeded = true
	var beam = LongBeamScene.new()
	get_tree().current_scene.add_child(beam)
	beam.setup(self, _target)

func _fire_volley_shot() -> void:
	# Spawn from the leviathan's head and fly at the target. Earlier versions
	# spawned the beam a few meters off the player to give it a "pops in next
	# to you" threat feel, but that read as bullets teleporting on top of the
	# player. Real projectile flight from the boss is the fair-feeling version.
	var t_pos: Vector3 = _target.global_position
	var spawn_pos: Vector3 = _head_position()
	var aim_point: Vector3 = t_pos + Vector3(
		randf_range(-VOLLEY_SPRAY_RADIUS, VOLLEY_SPRAY_RADIUS),
		randf_range(-VOLLEY_SPRAY_RADIUS, VOLLEY_SPRAY_RADIUS) * 0.5,
		randf_range(-VOLLEY_SPRAY_RADIUS, VOLLEY_SPRAY_RADIUS)
	)
	var dir: Vector3 = (aim_point - spawn_pos).normalized()
	var beam = BeamScene.new()
	get_tree().current_scene.add_child(beam)
	beam.setup(spawn_pos, dir, self, _target)

func _queue_missile_volley() -> void:
	# Two-stage salvo: lock-on warning + VLS-style staggered launch with full
	# spatial and phase deconfliction. Three pieces of structure ensure the
	# salvo reads as a real missile-system engagement rather than a hose:
	#
	#   (a) Lock-on warning — a billboarded reticle and pulsing "MISSILE LOCK"
	#       text appear on the target for MISSILE_LOCK_DURATION before the
	#       first missile spawns. Real fighters get a radar-lock indication
	#       that precedes warhead arrival; the player gets the same lead time
	#       to spot the reticle and reposition.
	#
	#   (b) Staggered launches — missiles fire one at a time, MISSILE_LAUNCH
	#       _STAGGER seconds apart, not in a single frame. This matches the
	#       firing cadence of a real VLS (vertical-launch system) deck where
	#       cells fire in sequence. The launch direction is dominated by
	#       Vector3.UP, so the salvo reads as a fountain climbing out of the
	#       boss; pitch-over toward the player is handled by the missile's
	#       LOFT phase, not by the initial direction.
	#
	#   (c) Phase deconfliction — every missile is told its helix phase φ_i
	#       and a ±1 spin sign. Phase is offset by 2π·i/N around the ring so
	#       opposite missiles are at opposite phases; the spin sign alternates
	#       so adjacent missiles corkscrew in opposite directions. The result
	#       is a braided "Itano Circus" pattern where the trails interleave.
	_missile_queue.clear()
	_missile_queue_time = 0.0
	if _target == null:
		return
	_spawn_lock_indicator(_target)
	var spawn_pos: Vector3 = _head_position()
	var to_target: Vector3 = _target.global_position - spawn_pos
	if to_target.length_squared() < 1e-4:
		return
	var forward: Vector3 = to_target.normalized()
	# Stable basis perpendicular to `forward`. Cross with world up unless
	# forward is nearly vertical (then fall back to world forward).
	var up_ref: Vector3 = Vector3.UP
	if absf(forward.dot(Vector3.UP)) > 0.95:
		up_ref = Vector3.FORWARD
	var right: Vector3 = forward.cross(up_ref).normalized()
	var up: Vector3 = right.cross(forward).normalized()
	for i in range(MISSILE_VOLLEY_COUNT):
		var ring_angle: float = TAU * float(i) / float(MISSILE_VOLLEY_COUNT)
		var radial: Vector3 = right * cos(ring_angle) + up * sin(ring_angle)
		# Launch direction: dominant UP (VLS fountain) + mild radial fan +
		# mild forward lean. Normalized so the three biases give a unit vector
		# regardless of how the constants are retuned.
		var dir: Vector3 = (Vector3.UP * MISSILE_UP_BIAS + radial * MISSILE_RADIAL_BIAS + forward * MISSILE_FORWARD_BIAS).normalized()
		# Spawn point offset outward along the ring so missiles visibly emerge
		# from a circle around the head, not all from one point.
		var at: Vector3 = spawn_pos + radial * MISSILE_RING_RADIUS * 0.25
		# Phase = ring position; spin = alternating ±1 → braided helices.
		var phase: float = ring_angle
		var spin: float = 1.0 if (i % 2 == 0) else -1.0
		# Crystal type rotates 0,1,2,0,1,2,… across the ring so every salvo
		# mixes all three crystals (cyan / darker cyan / pink) regardless of
		# MISSILE_VOLLEY_COUNT.
		var ctype: int = i % 3
		# Launch time = lock duration + stagger·i, so launches begin AFTER the
		# warning indicator has played out.
		var t_launch: float = MISSILE_LOCK_DURATION + float(i) * MISSILE_LAUNCH_STAGGER
		_missile_queue.append({
			"t": t_launch,
			"at": at,
			"dir": dir,
			"phase": phase,
			"spin": spin,
			"type": ctype,
		})

# Fish-projectile volley: same lock-then-stagger pattern as the missile volley,
# but only FISH_COUNT (=2) projectiles fired from opposing points around the
# head. Reuses _missile_queue/_missile_queue_time/_lock_indicator so the
# FISH_PROJECTILE tick handler can share the missile-volley scaffolding.
func _queue_fish_projectile_volley() -> void:
	_missile_queue.clear()
	_missile_queue_time = 0.0
	if _target == null:
		return
	_spawn_lock_indicator(_target)
	var spawn_pos: Vector3 = _head_position()
	var to_target: Vector3 = _target.global_position - spawn_pos
	if to_target.length_squared() < 1e-4:
		return
	var forward: Vector3 = to_target.normalized()
	var up_ref: Vector3 = Vector3.UP
	if absf(forward.dot(Vector3.UP)) > 0.95:
		up_ref = Vector3.FORWARD
	var right: Vector3 = forward.cross(up_ref).normalized()
	var up: Vector3 = right.cross(forward).normalized()
	for i in range(FISH_COUNT):
		# Two fish → opposing radial directions (0, π) for a symmetric pair.
		var ring_angle: float = TAU * float(i) / float(FISH_COUNT)
		var radial: Vector3 = right * cos(ring_angle) + up * sin(ring_angle)
		var dir: Vector3 = (Vector3.UP * FISH_UP_BIAS + radial * FISH_RADIAL_BIAS + forward * FISH_FORWARD_BIAS).normalized()
		var at: Vector3 = spawn_pos + radial * FISH_RING_RADIUS * 0.5
		var phase: float = ring_angle
		var spin: float = 1.0 if (i % 2 == 0) else -1.0
		var t_launch: float = FISH_LOCK_DURATION + float(i) * FISH_LAUNCH_STAGGER
		_missile_queue.append({
			"t": t_launch,
			"at": at,
			"dir": dir,
			"phase": phase,
			"spin": spin,
		})

func _spawn_lock_indicator(tgt: Node3D) -> void:
	if _lock_indicator != null and is_instance_valid(_lock_indicator):
		_lock_indicator.queue_free()
	var ind = LockIndicatorScene.new()
	get_tree().current_scene.add_child(ind)
	ind.setup(tgt)
	_lock_indicator = ind

func take_damage(amount: int, _direction: Vector3) -> void:
	_health = maxf(_health - float(amount), 0.0)
	if _health <= 0.0:
		_on_killed_locally()

# Killed by the local player. Credit the local peer (or 0 in solo),
# broadcast to peers so their scoreboards update, then respawn.
func _on_killed_locally() -> void:
	var killer_id: int = Network.my_peer_id if Network.is_in_room() else 0
	_credit_kill(killer_id)
	if Network.is_in_room():
		Network.send_message({
			"type": "leviathan_killed",
			"peer_id": killer_id,
		})
	_respawn()

# Called by training_cave.gd when a "leviathan_killed" message arrives from
# another peer. Just bumps the scoreboard — does NOT respawn the local
# leviathan, since each client runs its own HP simulation.
func credit_remote_kill(peer_id: int) -> void:
	_credit_kill(peer_id)

func _credit_kill(peer_id: int) -> void:
	_kills_by_peer[peer_id] = int(_kills_by_peer.get(peer_id, 0)) + 1
	_refresh_score_label()

# Reset HP, position, attack cooldowns, and chaser so the leviathan is
# functionally a fresh spawn. Keeps the same model/anim_player instance.
func _respawn() -> void:
	_health = MAX_HEALTH
	_hp_ratio = 1.0
	# Defensive visibility reset — something in the death/respawn path was
	# leaving the boss invisible. Force the body, model, and HP bar back on
	# so respawn always produces a visible boss regardless of what cleared
	# them.
	visible = true
	if _model != null:
		_model.visible = true
	if _hp_root != null:
		_hp_root.visible = true
	# CharacterBody3D carries velocity across frames — zero it so a fresh
	# spawn doesn't inherit motion from before death.
	velocity = Vector3.ZERO
	# Reset orientation; _process re-applies look_at on the next frame.
	rotation = Vector3.ZERO
	scale = Vector3.ONE
	if _hp_fill != null:
		_hp_fill.scale = Vector3.ONE
		_hp_fill.position.x = 0.0
	if _hp_fill_mat != null:
		_hp_fill_mat.albedo_color = Color(0.95, 0.35, 0.95, 1.0)
	_attack_state = AttackState.IDLE
	_attack_state_timer = 5.0      # half the initial-spawn delay — fresh respawn cooldown
	_attacks_since_long_beam = 0
	_next_short_attack = AttackState.VOLLEY
	_next_attack = AttackState.MISSILE_VOLLEY
	_volley_shot_cd = 0.0
	_passive_fire_cd = PASSIVE_FIRE_INTERVAL
	# Drop any in-flight missile-volley state: pending launches and the
	# lock-on indicator. Without this, a death mid-MISSILE_VOLLEY would leave
	# the indicator pulsing on a stale target and queue ghosts of the salvo
	# into the next attack cycle.
	_missile_queue.clear()
	_missile_queue_time = 0.0
	_missile_volleys_since_fish = 0
	if _lock_indicator != null and is_instance_valid(_lock_indicator):
		_lock_indicator.queue_free()
	_lock_indicator = null
	# Clear every persistent fish explosion left in the world. Each one
	# adds itself to the "leviathan_explosion" group on _ready, so a
	# tree-wide group sweep catches them regardless of which scene root
	# they were parented to.
	for ex in get_tree().get_nodes_in_group(&"leviathan_explosion"):
		if is_instance_valid(ex):
			ex.queue_free()
	_chaser_seeded = false
	_target = null
	_last_facing = Vector3.FORWARD
	# Restart the swim animation in case it was paused/stopped at death.
	if _anim_player != null and _anim_player.has_animation(_anim_player.current_animation):
		_anim_player.play(_anim_player.current_animation)
	var local_player: Node3D = get_tree().current_scene.get_node_or_null("Player") as Node3D
	if local_player != null:
		var fwd: Vector3 = -local_player.global_transform.basis.z
		global_position = local_player.global_position + fwd * 50.0 + Vector3(0.0, 25.0, 0.0)
