extends Control

@export var player_path: NodePath
@export var sword_slot_path: NodePath
@export var gun_slot_path: NodePath
@export var sniper_slot_path: NodePath
@export var portal_light_slot_path: NodePath
@export var charge_bar_path: NodePath
@export var charge_bar_bg_path: NodePath
@export var charge_overlay_path: NodePath
@export var guide_panel_path: NodePath
@export var guide_label_path: NodePath

@onready var sword_slot: Control = get_node(sword_slot_path)
@onready var gun_slot: Control = get_node(gun_slot_path)
@onready var sniper_slot: Control = get_node(sniper_slot_path)
@onready var portal_light_slot: Control = get_node(portal_light_slot_path)
@onready var charge_bar_fill: ColorRect = get_node(charge_bar_path)
@onready var charge_bar_bg: ColorRect = get_node(charge_bar_bg_path)
@onready var charge_overlay: ColorRect = get_node(charge_overlay_path)
@onready var guide_panel: Control = get_node_or_null(guide_panel_path)
@onready var guide_label: Label = get_node_or_null(guide_label_path)

const ACTIVE := Color(1, 1, 1, 1)
const INACTIVE := Color(0.55, 0.55, 0.6, 0.55)

func _ready() -> void:
	var player: Node = get_node(player_path)
	if player:
		player.weapon_changed.connect(_on_weapon_changed)
		player.charge_changed.connect(_on_charge_changed)
	_on_weapon_changed(0)
	_on_charge_changed(0.0)
	EventBus.weapon_guide_toggled.connect(_on_weapon_guide_toggled)
	if guide_panel:
		guide_panel.visible = false

# G toggles the guide. Re-pressing G with a different weapon equipped swaps the
# text in-place rather than hiding then reopening.
func _on_weapon_guide_toggled(text: String) -> void:
	if guide_panel == null or guide_label == null:
		return
	if guide_panel.visible and guide_label.text == text:
		guide_panel.visible = false
		return
	guide_label.text = text
	guide_panel.visible = true

func _on_weapon_changed(weapon: int) -> void:
	sword_slot.modulate = ACTIVE if weapon == 0 else INACTIVE
	gun_slot.modulate = ACTIVE if weapon == 1 else INACTIVE
	sniper_slot.modulate = ACTIVE if weapon == 2 else INACTIVE
	portal_light_slot.modulate = ACTIVE if weapon == 3 else INACTIVE

func _on_charge_changed(value: float) -> void:
	if value <= 0.001:
		charge_bar_bg.visible = false
		charge_overlay.color.a = 0.0
		return
	charge_bar_bg.visible = true
	var interior := maxf(charge_bar_bg.size.x - 4.0, 0.0)
	charge_bar_fill.offset_right = 2.0 + interior * value
	charge_overlay.color.a = value * 0.22
	var cool := Color(0.3, 0.95, 1.0, 1)
	var hot := Color(1.0, 0.95, 0.3, 1)
	charge_bar_fill.color = cool.lerp(hot, value)
