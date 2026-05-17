extends Node

# Every weapon has this signal even if it never emits (sniper charge is the
# only consumer today). Putting it on the base means UI can connect without
# `has_signal()` guards.
signal charge_changed(value: float)

@export var data: Resource  # WeaponData — typed loosely to avoid class-registry order issues

var attack_cd: float = 0.0
var player: Node = null
var _is_fpv: bool = false

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

func _on_view_mode_changed(mode: int) -> void:
	_is_fpv = mode == 1
	on_view_mode_changed(_is_fpv)

func on_view_mode_changed(_first_person: bool) -> void: pass
func tick(_delta: float) -> void: pass
func equip() -> void: pass
func unequip() -> void: pass
func on_attack_pressed() -> void: pass
func on_attack_released() -> void: pass
