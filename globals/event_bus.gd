extends Node

signal target_hit(target: Node, damage: int)
signal target_destroyed(target: Node)
signal player_weapon_changed(weapon: int)
signal player_view_mode_changed(mode: int)
# Fired when the player presses [G]. Payload is the guide text for the
# currently equipped weapon; the HUD toggles its guide panel and shows it.
signal weapon_guide_toggled(text: String)
