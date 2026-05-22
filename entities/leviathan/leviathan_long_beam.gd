extends Node3D

# Constant 5-second laser fired by the GhostLeviathan. Visualized as a
# stretched cylinder anchored at the boss and reaching to a moving endpoint
# that chases the target at CHASE_SPEED (2× the player's base speed). The
# endpoint deals damage to whichever body it currently overlaps, ticking at
# DAMAGE_TICK_INTERVAL so a player standing in the beam takes sustained DPS
# but can break it by side-stepping outside DAMAGE_RADIUS.

const LIFETIME: float = 5.0
# Endpoint = the leviathan's persistent chaser_position(). The chaser is a
# long-lived invisible pursuer that has been tracking the player from the
# moment the leviathan spawned, at 1.5× the player's run speed — so by the
# time a long beam fires, the chaser is already on (or near) the player,
# never starting from origin. The leviathan nudges the chaser 2 m off the
# target at fire time (see ghost_leviathan.gd: _fire_long_beam) so the beam
# doesn't visually spawn on top of the player; from that 2 m offset it can
# then chase and hit normally.
const DAMAGE_RADIUS: float = 1.6
const DAMAGE_PER_TICK: int = 1
const DAMAGE_TICK_INTERVAL: float = 0.15
const BEAM_RADIUS: float = 0.30

var origin_node: Node3D
var target: Node3D

var _endpoint: Vector3
var _age: float = 0.0
var _damage_cd: float = 0.0
var _mesh: MeshInstance3D
var _cyl: CylinderMesh

func setup(o: Node3D, t: Node3D) -> void:
	origin_node = o
	target = t

func _ready() -> void:
	_cyl = CylinderMesh.new()
	_cyl.top_radius = BEAM_RADIUS
	_cyl.bottom_radius = BEAM_RADIUS
	_cyl.height = 1.0  # rescaled per-frame
	_mesh = MeshInstance3D.new()
	_mesh.mesh = _cyl
	# Default cylinder runs along +Y. Rotate so the long axis aligns with
	# parent's local -Z, then look_at(endpoint) on the parent points -Z at
	# the endpoint and the beam visually extends along it.
	_mesh.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.45, 0.95, 0.9)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.95, 1.0)
	mat.emission_energy_multiplier = 14.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh.material_override = mat
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)
	# Initial endpoint = wherever the leviathan's persistent chaser currently
	# is. _process pulls a fresh read each frame.
	_endpoint = _read_chaser()

func _process(delta: float) -> void:
	if origin_node == null or not is_instance_valid(origin_node) or target == null or not is_instance_valid(target):
		queue_free()
		return
	_age += delta
	if _age >= LIFETIME:
		queue_free()
		return
	# Endpoint follows the leviathan's persistent chaser. The leviathan owns
	# the chase logic (1.5× player speed, dash-freeze) so all beams share one
	# shared "imaginary pursuer" rather than each beam re-seeding its own.
	var t_pos: Vector3 = target.global_position
	_endpoint = _read_chaser()
	# Fallback: clamp to the live target position in case the chaser isn't
	# exposed (anchor node is something other than the leviathan).
	_update_visual()
	_damage_cd -= delta
	if _damage_cd <= 0.0:
		if _endpoint.distance_to(t_pos) < DAMAGE_RADIUS and target.has_method("take_damage"):
			var dir: Vector3 = (t_pos - _beam_origin()).normalized()
			target.take_damage(DAMAGE_PER_TICK, dir)
		_damage_cd = DAMAGE_TICK_INTERVAL

func _update_visual() -> void:
	var o: Vector3 = _beam_origin()
	var diff: Vector3 = _endpoint - o
	var dist: float = diff.length()
	if dist < 0.001:
		_mesh.visible = false
		return
	_mesh.visible = true
	# Anchor the parent at the midpoint so the mesh (centered on parent
	# origin and extending ±height/2 along local -Z) spans from boss to
	# endpoint exactly.
	global_position = (o + _endpoint) * 0.5
	look_at(_endpoint, _safe_up(diff.normalized()))
	# Cylinder local +Y was rotated to -Z; scaling local Y stretches it
	# along that -Z direction. dist is the full beam length; the mesh
	# extends ±dist/2 from its center (the parent's origin = midpoint).
	_mesh.scale = Vector3(1.0, dist, 1.0)

# Beam emanates from the leviathan's head (its has_method("_head_position")
# helper). Falls back to the node origin if the helper is missing — keeps
# this script working with any anchor node.
# Pulls the leviathan's persistent chaser_position() if available; otherwise
# falls back to the target's live position so the beam still tracks somehow.
func _read_chaser() -> Vector3:
	if origin_node != null and origin_node.has_method("chaser_position"):
		return origin_node.chaser_position()
	return target.global_position if target != null else _endpoint

func _beam_origin() -> Vector3:
	if origin_node != null and origin_node.has_method("_head_position"):
		return origin_node._head_position()
	return origin_node.global_position if origin_node != null else global_position

func _safe_up(d: Vector3) -> Vector3:
	if absf(d.dot(Vector3.UP)) > 0.99:
		return Vector3.FORWARD
	return Vector3.UP
