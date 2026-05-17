extends "res://weapons/weapon.gd"

# Dark Portal: placeholder. The only confirmed behaviour right now is the
# passive 1.25× movement speed while equipped — attacks and visuals will be
# fleshed out later.

const SPEED_MULT: float = 1.25

func speed_multiplier() -> float:
	return SPEED_MULT

func cooldown() -> float:
	return data.cooldown if data else 0.5

func equip() -> void:
	pass

func unequip() -> void:
	pass
