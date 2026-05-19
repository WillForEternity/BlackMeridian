extends "res://entities/target/target.gd"

# A target that wields one of the four player weapons and fires it forward on a
# fixed cadence. Each branch uses the same spawn primitive the player's weapon
# uses — no parallel implementation, no recolored stand-ins:
#   PLASMA       → ProjectilePool.acquire (same scene gun.gd fires)
#   RAILGUN      → hitscan ray + Vfx.tracer_beam (same as sniper.gd)
#   PORTAL_LIGHT → PortalDisc pair via PortalDisc.setup (same as portal_light.gd)
#   KATANA       → forward Area3D matching sword.gd's hit_area contract
#                  (katana_owner meta + get_swing_tier), so the player's parry
#                  detects and resolves clashes against it the same way it
#                  would against another player's katana.
# Body color is set per weapon as a visual cue; the actual fire mechanics
# come from the existing weapon code.

const PortalDisc := preload("res://weapons/portal/portal_disc.gd")

enum WeaponType { PLASMA, RAILGUN, PORTAL_LIGHT, KATANA }

const BODY_COLORS: Dictionary = {
	WeaponType.PLASMA:       Color(0.95, 0.35, 0.85, 1),
	WeaponType.RAILGUN:      Color(0.55, 0.9,  1.0,  1),
	WeaponType.PORTAL_LIGHT: Color(1.0,  0.85, 0.35, 1),
	WeaponType.KATANA:       Color(0.55, 0.85, 1.0,  1),
}

@export var weapon_type: WeaponType = WeaponType.PLASMA
@export var fire_interval: float = 0.6
@export var muzzle_offset: Vector3 = Vector3(0.0, 0.3, -0.75)
@export var fire_phase: float = 0.0
# When true, the shooter rotates through all four WeaponType values on
# `cycle_interval`, reapplying the body costume each time.
@export var cycle_weapons: bool = false
@export var cycle_interval: float = 10.0

var _cycle_t: float = 0.0

# Katana swing tuning — short reach in front of the shooter, brief active
# window so the player can read and parry it.
const KATANA_REACH: float = 1.6
const KATANA_WIDTH: float = 1.4
const KATANA_HEIGHT: float = 1.6
const KATANA_HIT_DURATION: float = 0.18
const KATANA_DAMAGE: int = 2

# Railgun tuning — full-charge enemy shot, fixed range.
const RAILGUN_RANGE: float = 60.0
const RAILGUN_DAMAGE: int = 6

var _fire_t: float = 0.0

func _ready() -> void:
	super()
	respawn_delay = 2.5
	_fire_t = -fire_phase
	_apply_body_costume()

func _apply_body_costume() -> void:
	var fresh := StandardMaterial3D.new()
	fresh.albedo_color = BODY_COLORS[weapon_type]
	fresh.roughness = 0.5
	fresh.emission_enabled = true
	fresh.emission = BODY_COLORS[weapon_type]
	fresh.emission_energy_multiplier = 0.7
	mesh.set_surface_override_material(0, fresh)
	_base_mat = fresh

func _physics_process(delta: float) -> void:
	super(delta)
	if _dead:
		return
	if cycle_weapons:
		_cycle_t += delta
		if _cycle_t >= cycle_interval:
			_cycle_t -= cycle_interval
			weapon_type = ((weapon_type + 1) % WeaponType.size()) as WeaponType
			_apply_body_costume()
	_fire_t += delta
	if _fire_t >= fire_interval:
		_fire_t -= fire_interval
		_fire()

func _fire() -> void:
	match weapon_type:
		WeaponType.PLASMA:
			_fire_plasma()
		WeaponType.RAILGUN:
			_fire_railgun()
		WeaponType.PORTAL_LIGHT:
			_fire_portal_light()
		WeaponType.KATANA:
			_swing_katana()

func _muzzle_position() -> Vector3:
	return global_position + global_transform.basis * muzzle_offset

func _forward() -> Vector3:
	return -global_transform.basis.z.normalized()

# --- PLASMA -------------------------------------------------------------------
# Same path as gun.gd._spawn_bullet — pulled straight from the pool.
func _fire_plasma() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var bullet: Node = ProjectilePool.acquire(scene)
	bullet.global_position = _muzzle_position()
	bullet.set_direction(_forward())
	bullet.shooter = self
	bullet.source_weapon = null
	Vfx.muzzle_flash(_muzzle_position(), 0.8, Color(1, 0.45, 0.95, 1))

# --- RAILGUN ------------------------------------------------------------------
# Same hitscan + Vfx.tracer_beam path as sniper.gd._fire / _hitscan.
func _fire_railgun() -> void:
	var from := _muzzle_position()
	var dir := _forward()
	var to := from + dir * RAILGUN_RANGE
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1 | 4  # world + enemies (matches sniper)
	query.exclude = [self.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	var end: Vector3 = to
	if not hit.is_empty():
		end = hit.position
		var body: Node = hit.collider
		if body != null and body.has_method("take_damage"):
			body.take_damage(RAILGUN_DAMAGE, dir)
	Vfx.tracer_beam(from, end, 1.0)  # full-charge feel
	Vfx.muzzle_flash(from, 1.1, Color(0.4, 0.95, 1, 1))
	Vfx.impact_burst(end, 0.9, Color(0.4, 0.95, 1, 1))

# --- PORTAL LIGHT -------------------------------------------------------------
# Same disc-pair spawn as portal_light.gd._fire / _spawn_disc.
func _fire_portal_light() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var origin := _muzzle_position()
	var dir := _forward()
	var target := _find_player()
	_spawn_disc(scene, origin, dir, target, true)
	_spawn_disc(scene, origin, dir, target, false)
	Vfx.muzzle_flash(origin, 1.0, Color(1.0, 0.85, 0.4, 1))

func _spawn_disc(scene: Node, origin: Vector3, dir: Vector3, target: Node3D, outer: bool) -> void:
	var disc := PortalDisc.new()
	scene.add_child(disc)
	disc.global_position = origin
	disc.setup(outer, dir, target, self, null)

func _find_player() -> Node3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return scene.find_child("Player", true, false) as Node3D

# --- KATANA -------------------------------------------------------------------
# Spawns a forward Area3D shaped like the player's katana hit_area, marked
# with the same katana_owner meta + get_swing_tier method so the player's
# katana parry resolves clashes against it identically to a real katana swing.
func _swing_katana() -> void:
	var area := Area3D.new()
	area.collision_layer = 32   # katana_blade layer (matches sword.gd)
	area.collision_mask = 2 | 32  # player bodies + other katana blades
	area.monitoring = true
	area.monitorable = true
	area.set_meta("katana_owner", self)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(KATANA_WIDTH, KATANA_HEIGHT, KATANA_REACH)
	shape.shape = box
	shape.position = Vector3(0, 0, -KATANA_REACH * 0.5)
	area.add_child(shape)

	# Parent to self so the swing inherits the shooter's transform.
	add_child(area)
	area.position = Vector3.ZERO

	area.set_meta("struck", [])
	area.body_entered.connect(_on_katana_body_entered.bind(area))
	Vfx.impact_burst(_muzzle_position(), 0.6, Color(0.55, 0.95, 1, 1))
	get_tree().create_timer(KATANA_HIT_DURATION, true, false, true).timeout.connect(_free_katana_area.bind(area))

func _on_katana_body_entered(body: Node, area: Area3D) -> void:
	if body == self:
		return
	var struck: Array = area.get_meta("struck", [])
	if body in struck:
		return
	struck.append(body)
	area.set_meta("struck", struck)
	if body.has_method("take_damage"):
		body.take_damage(KATANA_DAMAGE, _forward())

func _free_katana_area(area: Area3D) -> void:
	if is_instance_valid(area):
		area.queue_free()

# Stub matching sword.gd's swing-tier contract so the player's parry
# (_resolve_katana_clash) can interrogate this swing. Enemy swings are treated
# as "normal" tier with combo 0 — fully blockable by any player parry.
func get_swing_tier() -> Dictionary:
	return {"tier": "normal", "combo": 0}

# Counterpart to sword.gd._on_swing_parried — the player parried our swing.
# We currently just emit feedback; the swing area frees itself on its timer.
func _on_swing_parried() -> void:
	Vfx.impact_burst(_muzzle_position(), 0.7, Color(1.0, 0.95, 0.6, 1))
