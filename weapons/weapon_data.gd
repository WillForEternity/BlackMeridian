class_name WeaponData
extends Resource

# Shared, designer-tweakable stats. Per-weapon scripts pull numbers from here
# instead of hard-coding magic numbers in code.

@export var cooldown: float = 0.3
@export var damage: int = 1

# Gun-style recoil (rig kick on fire). Sword ignores these.
@export var recoil_pos_offset: Vector3 = Vector3(0, 0.015, 0.16)
@export var recoil_rot_offset_deg: Vector3 = Vector3(-9.0, 0, 0)
@export var recoil_in_time: float = 0.045
@export var recoil_out_time: float = 0.16

# Sniper charge.
@export var charge_time: float = 1.0
@export var min_charge_damage_mul: float = 0.35

# Sword combo.
@export var combo_window: float = 0.55
@export var combo_count: int = 3
