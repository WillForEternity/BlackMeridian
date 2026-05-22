extends Area3D

# Persistent explosion left behind when a fish projectile is destroyed (by
# the player or by impact). Loads the stylized explosion GLB, plays its first
# authored animation once, then holds the final pose forever as a charred-
# debris damage zone — players that walk into it take damage. The pile of
# debris stays in the world until the leviathan is killed; ghost_leviathan.gd
# clears every node in GROUP_NAME on respawn.
#
# A random 3D orientation is baked at spawn so consecutive explosions look
# novel instead of identical.

const EXPLOSION_MODEL_PATH: String = "res://assets/models/explosion.glb"

# Longest-axis target size for the spawned explosion mesh. Tuned to roughly
# match the fish's visible size so the explosion reads as "the fish came
# apart" rather than as a tiny puff or a screen-filling blob.
const EXPLOSION_LENGTH: float = 30.0

# Color override: dark gray/black smoke with a hot red light at the core. The
# authored materials (likely orange/yellow fire) get retinted to SHELL_ALBEDO;
# the red is added back as a bright OmniLight3D at the explosion's center
# that pulses hot for CORE_LIGHT_FADE_DURATION and then dies. Light spillage
# gives the "red near the middle" read without needing per-mesh color logic.
const SHELL_ALBEDO: Color = Color(0.13, 0.13, 0.14, 1.0)
const CORE_LIGHT_COLOR: Color = Color(1.0, 0.22, 0.07, 1.0)
const CORE_LIGHT_ENERGY: float = 16.0
const CORE_LIGHT_RANGE: float = 28.0
const CORE_LIGHT_FADE_DURATION: float = 0.9

# Damage-on-touch zone. Sized to roughly the inner ~70% of the explosion
# silhouette so the player only takes damage when they're actually inside
# the debris cloud, not when they brush its outer edge. Damage is high
# enough that touching the debris is a serious choice, not a tax.
const DAMAGE: int = 10
const DAMAGE_RADIUS: float = 11.0
# Visual hit feedback: when a body enters the damage zone we re-ignite the
# red core light for HIT_FLARE_DURATION so the player gets an unmistakable
# "you just got burned" pulse on top of the engine's normal damage tells.
const HIT_FLARE_ENERGY: float = 18.0
const HIT_FLARE_RANGE: float = 32.0
const HIT_FLARE_DURATION: float = 0.45

# Group tag used by ghost_leviathan.gd to find and free every active
# explosion on respawn.
const GROUP_NAME: StringName = &"leviathan_explosion"

var _anim_player: AnimationPlayer
var _age: float = 0.0
var _core_light: OmniLight3D
var _model: Node3D
var _collision_frozen: bool = false
var _hit_flare_remaining: float = 0.0


func setup(at: Vector3) -> void:
	global_position = at
	# Random orientation in all three axes so each explosion reads as a
	# different angle of the same authored simulation — cheap variety from
	# the same source asset.
	rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)


func _ready() -> void:
	add_to_group(GROUP_NAME)
	# Damage zone: monitor for player layer-1 bodies entering the sphere.
	# collision_layer = 0 because nothing needs to detect US — we only
	# trigger on contact.
	collision_layer = 0
	collision_mask = 1
	monitoring = true
	body_entered.connect(_on_body_entered)
	_build_damage_collision()
	var packed: PackedScene = load(EXPLOSION_MODEL_PATH) as PackedScene
	if packed == null:
		push_warning("[LeviathanFishExplosion] failed to load %s" % EXPLOSION_MODEL_PATH)
		queue_free()
		return
	var instance: Node = packed.instantiate()
	if instance == null or not (instance is Node3D):
		push_warning("[LeviathanFishExplosion] explosion scene did not instantiate as Node3D")
		queue_free()
		return
	_model = instance as Node3D
	add_child(_model)
	_normalize_model_size(_model)
	_recolor_shell(_model)
	_build_core_light()
	_anim_player = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim_player != null and _anim_player.get_animation_list().size() > 0:
		var pick: String = _anim_player.get_animation_list()[0]
		var anim: Animation = _anim_player.get_animation(pick)
		if anim != null:
			# One-shot: explicitly disable looping so the explosion plays its
			# arc and freezes on the last frame. We intentionally do NOT
			# queue_free here — animation_finished triggers _freeze_collision
			# instead, baking the final-pose mesh AABBs into a StaticBody3D
			# child so the debris becomes a real blocker the player can't walk
			# through.
			anim.loop_mode = Animation.LOOP_NONE
		_anim_player.animation_finished.connect(_on_anim_finished)
		_anim_player.play(pick)
	else:
		# No clip — the model is already in its "final" pose, so freeze
		# collision right away instead of waiting for an animation that
		# never plays.
		_freeze_collision()


func _process(delta: float) -> void:
	_age += delta
	_update_core_light(delta)


# Two-mode light driver:
#   - Spawn flash: quadratic decay over CORE_LIGHT_FADE_DURATION from
#     CORE_LIGHT_ENERGY → 0. Reads as the initial blast.
#   - Hit flare: while _hit_flare_remaining > 0, hold the light hot at
#     HIT_FLARE_ENERGY · f² where f decays linearly. Overrides the spawn
#     decay so a player walking into a long-dead explosion still gets a
#     red pulse keyed to the moment of contact.
func _update_core_light(delta: float) -> void:
	if _core_light == null:
		return
	if _hit_flare_remaining > 0.0:
		_hit_flare_remaining = maxf(_hit_flare_remaining - delta, 0.0)
		var f: float = _hit_flare_remaining / HIT_FLARE_DURATION
		_core_light.light_color = CORE_LIGHT_COLOR
		_core_light.light_energy = HIT_FLARE_ENERGY * f * f
		_core_light.omni_range = HIT_FLARE_RANGE
	elif _age < CORE_LIGHT_FADE_DURATION:
		var t: float = _age / CORE_LIGHT_FADE_DURATION
		var k: float = 1.0 - t
		_core_light.light_energy = CORE_LIGHT_ENERGY * k * k
		_core_light.omni_range = CORE_LIGHT_RANGE
	else:
		_core_light.light_energy = 0.0


func _on_body_entered(body: Node) -> void:
	# Persistent damage zone: any body that enters the sphere takes damage
	# once per entry (Godot only emits body_entered on the transition into
	# the area, so a body that stays inside isn't ticked).
	if body == null:
		return
	if not body.has_method("take_damage"):
		return
	body.take_damage(DAMAGE, Vector3.UP)
	# Visible "got burned" pulse keyed to the contact moment.
	_hit_flare_remaining = HIT_FLARE_DURATION


func _on_anim_finished(_anim_name: StringName) -> void:
	# Final-pose snapshot: now that every chunk has stopped moving we can
	# bake its AABB into a real physics blocker.
	_freeze_collision()


# Build rough box geometry around every MeshInstance3D in the explosion
# model at its current (final-pose) world transform. Each box is an axis-
# aligned bounding box in the explosion's local space, parented under a
# fresh StaticBody3D on layer 1 — same layer the terrain uses — so the
# player's normal move_and_slide treats the debris like a wall. The boxes
# are necessarily LARGER than the visual chunks they wrap (AABBs always
# are for non-axis-aligned geometry), which is the "rough" part: collision
# is conservative, never under-tight.
func _freeze_collision() -> void:
	if _collision_frozen or _model == null:
		return
	_collision_frozen = true
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	add_child(sb)
	var inv: Transform3D = global_transform.affine_inverse()
	for n in _gather_mesh_instances(_model):
		var mi: MeshInstance3D = n
		var local_aabb: AABB = mi.get_aabb()
		if local_aabb.size.length_squared() < 1e-4:
			continue
		# Transform from the mesh's own space into the explosion's local
		# space (the StaticBody3D inherits our transform, so collision
		# shapes live in explosion-local coords).
		var to_explosion_local: Transform3D = inv * mi.global_transform
		var ex_aabb: AABB = to_explosion_local * local_aabb
		var box := BoxShape3D.new()
		box.size = ex_aabb.size
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = ex_aabb.position + ex_aabb.size * 0.5
		sb.add_child(cs)


func _build_damage_collision() -> void:
	var sph := SphereShape3D.new()
	sph.radius = DAMAGE_RADIUS
	var cs := CollisionShape3D.new()
	cs.shape = sph
	add_child(cs)


# Override every mesh material with a dark-gray albedo and no emission so the
# explosion no longer reads as a colored fireball. Each material is duplicated
# first so the override is per-instance and doesn't leak back into the shared
# imported sub-resource. Original alpha is preserved so transparent layers
# (smoke wisps, etc.) stay transparent.
func _recolor_shell(model: Node3D) -> void:
	for n in _gather_mesh_instances(model):
		var mi: MeshInstance3D = n
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		for s in range(mesh.get_surface_count()):
			var src_mat: Material = mi.get_active_material(s)
			if not (src_mat is BaseMaterial3D):
				continue
			var dup: BaseMaterial3D = src_mat.duplicate() as BaseMaterial3D
			var orig_alpha: float = dup.albedo_color.a
			dup.albedo_color = Color(SHELL_ALBEDO.r, SHELL_ALBEDO.g, SHELL_ALBEDO.b, orig_alpha)
			dup.albedo_texture = null
			dup.emission_enabled = false
			mi.set_surface_override_material(s, dup)


func _build_core_light() -> void:
	_core_light = OmniLight3D.new()
	_core_light.light_color = CORE_LIGHT_COLOR
	_core_light.light_energy = CORE_LIGHT_ENERGY
	_core_light.omni_range = CORE_LIGHT_RANGE
	add_child(_core_light)


func _gather_mesh_instances(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_gather_mesh_instances(c))
	return out


# Same size-normalization helper used by the missile/fish — scale the model
# so its merged-world-AABB longest axis equals EXPLOSION_LENGTH, regardless
# of the source asset's authored scale.
func _normalize_model_size(model: Node3D) -> void:
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
		var s: float = EXPLOSION_LENGTH / longest
		model.scale = Vector3(s, s, s)


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
