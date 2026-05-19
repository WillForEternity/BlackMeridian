extends Node

# Every weapon has this signal even if it never emits (sniper charge is the
# only consumer today). Putting it on the base means UI can connect without
# `has_signal()` guards.
signal charge_changed(value: float)
signal super_charge_changed(value: float)

@export var data: Resource  # WeaponData — typed loosely to avoid class-registry order issues

const SUPER_MAX: float = 12.0

# Shared "crit" visual: any weapon currently in a crit state recolors its
# damaging visuals (slash trail, projectile, etc.) to this tint. Subclasses
# decide *when* they crit by overriding is_crit(); the color stays unified.
const CRIT_TINT: Color = Color(0.55, 0.15, 0.85, 1.0)

# Override per weapon. Default: never crits. Examples:
#   sword → crits while player is dashing or mid-super
#   gun   → could crit on headshot streaks, etc.
func is_crit() -> bool:
	return false

var attack_cd: float = 0.0
var player: Node = null
var _is_fpv: bool = false
var super_charge: float = 0.0

func _ready() -> void:
	EventBus.player_view_mode_changed.connect(_on_view_mode_changed)

func setup(p: Node) -> void:
	player = p

func _process(delta: float) -> void:
	attack_cd = maxf(attack_cd - delta, 0.0)
	if is_equipped():
		tick(delta)

func is_equipped() -> bool:
	return player != null and player.current_weapon_node == self

func is_fpv() -> bool:
	return _is_fpv

func cooldown() -> float:
	return data.cooldown if data else 0.3

func add_super_charge(amount: float) -> void:
	if super_charge >= SUPER_MAX:
		return
	super_charge = minf(super_charge + amount, SUPER_MAX)
	super_charge_changed.emit(super_charge / SUPER_MAX)

func super_ready() -> bool:
	return super_charge >= SUPER_MAX

func consume_super() -> bool:
	if super_charge < SUPER_MAX:
		return false
	super_charge = 0.0
	super_charge_changed.emit(0.0)
	return true

func _on_view_mode_changed(mode: int) -> void:
	_is_fpv = mode == 1
	on_view_mode_changed(_is_fpv)

func on_view_mode_changed(_first_person: bool) -> void: pass
func tick(_delta: float) -> void: pass
func equip() -> void: pass
func unequip() -> void: pass
func on_attack_pressed() -> void: pass
func on_attack_released() -> void: pass
func on_super_pressed() -> void: pass

# Per-weapon multiplier applied to the player's dash cooldown when this weapon
# is equipped. Katana halves it (override below); others keep the default.
func dash_cooldown_mult() -> float:
	return 1.0

# G-key in-game guide. Subclasses describe attacks, crits, super, and any
# weapon-specific quirks. Plain text so the existing Label renders it without
# needing BBCode.
func guide_text() -> String:
	return "No guide available for this weapon."
