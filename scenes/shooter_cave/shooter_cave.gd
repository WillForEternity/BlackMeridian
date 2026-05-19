extends "res://scenes/training_cave/training_cave.gd"

# Shooter training cave: same room, hotbar, and player as the base training
# cave, but the static dummy targets are removed and replaced (in the inherited
# .tscn) with 8 forward-firing shooter enemies.

func _ready() -> void:
	super()
	var targets: Node = get_node_or_null("Targets")
	if targets:
		targets.queue_free()
