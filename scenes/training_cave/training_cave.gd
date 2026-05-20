extends Node3D

@onready var _reset_button: Button = $UI/HotbarRoot/ResetButton
@onready var _player: Node3D = $Player
@onready var _terrain: Node = $Terrain

func _ready() -> void:
	_reset_button.pressed.connect(_reset)
	_reset_button.mouse_entered.connect(func() -> void: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE)
	_apply_cmdline_spawn()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		_reset()

func _reset() -> void:
	get_tree().reload_current_scene()

# Honor `++ --spawn <name>` from the gametest shell wrapper. Unknown or missing
# values leave the player at its scene-default transform.
func _apply_cmdline_spawn() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var spawn: String = ""
	for i in args.size():
		if args[i] == "--spawn" and i + 1 < args.size():
			spawn = args[i + 1]
			break
	if spawn == "" or spawn == "training":
		return
	if spawn == "source" and _terrain.has_method("get_source_spawn"):
		var p: Vector3 = _terrain.call("get_source_spawn")
		if p.x != INF:
			_player.global_position = p
