extends "res://weapons/weapon.gd"

const PortalDisc := preload("res://weapons/portal/portal_disc.gd")

# Light Portal: a passive double-jump aura plus a slow homing nested-disc
# attack. The disc damage and homing curve live in portal_disc.gd; this
# weapon just orchestrates the spawn pair and triggers a flash.

const HALO_TINT: Color = Color(1.0, 0.92, 0.55, 1.0)
const RING_TINT: Color = Color(1.0, 0.82, 0.40, 1.0)

var _rig_tpv: Node3D
var _rig_fpv: Node3D

func cooldown() -> float:
	return data.cooldown if data else 1.7

# Number of extra mid-air jumps this weapon grants — Light Portal allows
# triple jump (one ground jump + two air jumps).
func extra_air_jumps() -> int:
	return 2

func _ready() -> void:
	super()
	# Build rigs once the player tree is fully ready so WeaponPivot/FPVPivot exist.
	call_deferred("_build_rigs")

func _build_rigs() -> void:
	if player == null:
		return
	var weapon_pivot: Node3D = player.get_node_or_null("WeaponPivot")
	var fpv_pivot: Node3D = player.get_node_or_null("CameraPitchPivot/Camera3D/FPVPivot")
	if weapon_pivot:
		_rig_tpv = _make_portal_rig(false)
		weapon_pivot.add_child(_rig_tpv)
		_rig_tpv.position = Vector3(0.0, 0.05, -0.55)
	if fpv_pivot:
		_rig_fpv = _make_portal_rig(true)
		fpv_pivot.add_child(_rig_fpv)
		_rig_fpv.position = Vector3(0.35, -0.22, -0.55)
		_rig_fpv.rotation = Vector3(0.0, deg_to_rad(-10.0), deg_to_rad(-8.0))
	_apply_visibility()

func _make_portal_rig(fpv: bool) -> Node3D:
	var sf: float = 0.85 if fpv else 1.0
	var root := Node3D.new()
	root.name = "PortalLightRig"

	# Each ring lives under its own pivot so tick() can spin them at different
	# rates and directions. We store the pivots on the root via metadata so
	# tick() can fish them out without get_node string lookups.
	var pivots: Array[Node3D] = []

	# Three nested glowing rings at varied tilts — gives the swirling
	# "concentric runes" portal silhouette from any angle.
	pivots.append(_add_ring(root, sf, 0.42, 0.50, RING_TINT, 5.5, Vector3(deg_to_rad(90.0), 0.0, 0.0)))
	pivots.append(_add_ring(root, sf, 0.30, 0.36, Color(1.0, 0.88, 0.55, 1.0), 5.0, Vector3(deg_to_rad(90.0), deg_to_rad(20.0), deg_to_rad(15.0))))
	pivots.append(_add_ring(root, sf, 0.18, 0.22, Color(1.0, 1.0, 0.85, 1.0), 6.5, Vector3(deg_to_rad(90.0), deg_to_rad(-35.0), deg_to_rad(-25.0))))

	# Dark void core — a small opaque sphere behind the bright surfaces gives
	# the portal a real "hole through reality" feel rather than just a glow.
	var void_core := MeshInstance3D.new()
	var void_mesh := SphereMesh.new()
	void_mesh.radius = 0.16 * sf
	void_mesh.height = 0.32 * sf
	void_mesh.radial_segments = 24
	void_mesh.rings = 12
	void_core.mesh = void_mesh
	var void_mat := StandardMaterial3D.new()
	void_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	void_mat.albedo_color = Color(0.04, 0.02, 0.08, 1.0)
	void_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	void_core.material_override = void_mat
	void_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(void_core)

	# Bright pinpoint at the centre — additive sphere that reads as a star
	# burning at the heart of the void.
	var heart := MeshInstance3D.new()
	var heart_mesh := SphereMesh.new()
	heart_mesh.radius = 0.07 * sf
	heart_mesh.height = 0.14 * sf
	heart_mesh.radial_segments = 16
	heart_mesh.rings = 8
	heart.mesh = heart_mesh
	var heart_mat := StandardMaterial3D.new()
	heart_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	heart_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	heart_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	heart_mat.albedo_color = Color(1.0, 0.98, 0.85, 0.95)
	heart_mat.emission_enabled = true
	heart_mat.emission = Color(1.0, 0.97, 0.80, 1.0)
	heart_mat.emission_energy_multiplier = 9.0
	heart.material_override = heart_mat
	heart.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(heart)

	# Inner luminous disc surface — sits just in front of the void so the
	# portal mouth looks like a glowing membrane stretched across the rings.
	var disc := MeshInstance3D.new()
	var disc_mesh := SphereMesh.new()
	disc_mesh.radius = 0.34 * sf
	disc_mesh.height = 0.04 * sf
	disc_mesh.radial_segments = 32
	disc_mesh.rings = 2
	disc.mesh = disc_mesh
	var disc_mat := StandardMaterial3D.new()
	disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	disc_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	disc_mat.albedo_color = Color(1.0, 0.92, 0.65, 0.32)
	disc_mat.emission_enabled = true
	disc_mat.emission = Color(1.0, 0.90, 0.55, 1.0)
	disc_mat.emission_energy_multiplier = 2.6
	disc_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	disc.material_override = disc_mat
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(disc)

	# Soft halo — large faint additive sphere so the portal bleeds warm light.
	var halo := MeshInstance3D.new()
	var halo_mesh := SphereMesh.new()
	halo_mesh.radius = 0.75 * sf
	halo_mesh.height = 1.50 * sf
	halo_mesh.radial_segments = 20
	halo_mesh.rings = 10
	halo.mesh = halo_mesh
	var halo_mat := StandardMaterial3D.new()
	halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	halo_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	halo_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	halo_mat.albedo_color = Color(HALO_TINT.r, HALO_TINT.g, HALO_TINT.b, 0.08)
	halo_mat.emission_enabled = true
	halo_mat.emission = HALO_TINT
	halo_mat.emission_energy_multiplier = 0.8
	halo.material_override = halo_mat
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(halo)

	# Punchier light so the portal actually casts onto the player's arm.
	var light := OmniLight3D.new()
	light.light_color = HALO_TINT
	light.light_energy = 2.3
	light.omni_range = 4.5
	light.shadow_enabled = false
	root.add_child(light)

	# Stash ring pivots on the root so tick() can rotate them individually.
	root.set_meta("ring_pivots", pivots)
	return root

# Builds a single ring inside `parent`, returns its pivot so the caller can
# animate the ring independently. The torus is parented under the pivot at
# the supplied local rotation so spinning the pivot rotates the ring around
# its own ring-plane axis.
func _add_ring(parent: Node3D, sf: float, inner_r: float, outer_r: float, tint: Color, emission: float, ring_rot: Vector3) -> Node3D:
	var pivot := Node3D.new()
	parent.add_child(pivot)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = inner_r * sf
	torus.outer_radius = outer_r * sf
	torus.ring_segments = 48
	torus.rings = 12
	ring.mesh = torus
	ring.rotation = ring_rot
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = emission
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(ring)
	return pivot

func tick(_delta: float) -> void:
	# Each ring spins around its own pivot at a different rate (and direction
	# for the middle one), so the portal looks like a swirling rune-stack
	# rather than a single object rotating as a block.
	_spin_rig(_rig_tpv, _delta)
	_spin_rig(_rig_fpv, _delta)

const RING_SPIN_RATES: Array = [1.1, -1.7, 2.6]  # rad/sec, one per ring layer

func _spin_rig(rig: Node3D, delta: float) -> void:
	if rig == null or not rig.visible:
		return
	var pivots: Array = rig.get_meta("ring_pivots", [])
	for i in pivots.size():
		var p := pivots[i] as Node3D
		if p == null:
			continue
		var rate: float = RING_SPIN_RATES[i] if i < RING_SPIN_RATES.size() else 1.0
		# Spin around local Y — since each ring's MeshInstance3D is rotated by
		# `ring_rot`, this gives each ring its own apparent spin axis.
		p.rotate_y(rate * delta)

func equip() -> void:
	_apply_visibility()

func unequip() -> void:
	_apply_visibility()

func _apply_visibility() -> void:
	var equipped: bool = is_equipped()
	if _rig_tpv:
		_rig_tpv.visible = equipped
	if _rig_fpv:
		_rig_fpv.visible = equipped

func on_attack_pressed() -> void:
	if attack_cd > 0.0 or player == null:
		return
	attack_cd = cooldown()
	_fire()

func _fire() -> void:
	var aim: Vector3 = player.get_aim_point()
	var origin: Vector3 = player.global_position + Vector3(0, 0.6, 0) + (-player.transform.basis.z) * 0.6
	var dir := (aim - origin)
	if dir.length() < 0.001:
		dir = -player.transform.basis.z
	dir = dir.normalized()
	var target := _pick_target(origin, dir)
	_spawn_disc(origin, dir, target, true)
	_spawn_disc(origin, dir, target, false)
	Vfx.muzzle_flash(origin, 1.3, Color(1.0, 0.95, 0.55, 1))
	player.punch_fov(4.0, 0.06, 0.22)

func _spawn_disc(origin: Vector3, dir: Vector3, target: Node3D, outer: bool) -> void:
	var disc := PortalDisc.new()
	get_tree().current_scene.add_child(disc)
	disc.global_position = origin
	disc.setup(outer, dir, target, player, self)

func _pick_target(origin: Vector3, dir: Vector3) -> Node3D:
	# Forward cone pick: aim ray then nearest enemy on the enemy layer. Falls
	# back to whatever's closest if nothing's directly ahead.
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(origin, origin + dir * 200.0)
	ray.collision_mask = 4
	ray.exclude = [player.get_rid()]
	var hit: Dictionary = space.intersect_ray(ray)
	if not hit.is_empty():
		var col := hit.collider as Node3D
		if col != null:
			return col
	var shape := SphereShape3D.new()
	shape.radius = 80.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis.IDENTITY, origin)
	q.collision_mask = 4
	q.exclude = [player.get_rid()]
	var hits: Array = space.intersect_shape(q, 32)
	var best: Node3D = null
	var best_score := -INF
	for h in hits:
		var c := h.collider as Node3D
		if c == null:
			continue
		var to_c := (c.global_position - origin)
		if to_c.length() < 0.001:
			continue
		var ahead: float = to_c.normalized().dot(dir)
		# Prefer targets in front and closer.
		var score: float = ahead - to_c.length() * 0.01
		if score > best_score:
			best_score = score
			best = c
	return best
