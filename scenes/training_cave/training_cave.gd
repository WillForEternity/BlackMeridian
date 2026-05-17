extends Node3D

@onready var _reset_button: Button = $UI/HotbarRoot/ResetButton

func _ready() -> void:
	_reset_button.pressed.connect(_reset)
	_reset_button.mouse_entered.connect(func() -> void: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		_reset()

func _reset() -> void:
	get_tree().reload_current_scene()
