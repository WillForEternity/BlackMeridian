extends Control

# Startup menu — three states:
#   IDLE     — show Host / Join / Solo buttons (and an IP-like Join field)
#   HOSTING  — waiting for joiners; show the room code + Cancel
#   JOINING  — entering or waiting for the relay to pair us; show status

const WORLD_SCENE: String = "res://scenes/training_cave/training_cave.tscn"

@onready var _code_input: LineEdit = $Panel/Margin/Box/CodeInput
@onready var _host_button: Button = $Panel/Margin/Box/HostButton
@onready var _join_button: Button = $Panel/Margin/Box/JoinButton
@onready var _solo_button: Button = $Panel/Margin/Box/SoloButton
@onready var _cancel_button: Button = $Panel/Margin/Box/CancelButton
@onready var _enter_world_button: Button = $Panel/Margin/Box/EnterWorldButton
@onready var _code_display: Label = $Panel/Margin/Box/CodeDisplay
@onready var _status: Label = $Panel/Margin/Box/Status

var _is_hosting: bool = false
var _is_joining: bool = false

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_host_button.pressed.connect(_on_host)
	_join_button.pressed.connect(_on_join)
	_solo_button.pressed.connect(_on_solo)
	_cancel_button.pressed.connect(_on_cancel)
	_enter_world_button.pressed.connect(_on_enter_world)
	_code_input.text_submitted.connect(func(_t: String) -> void: _on_join())

	Network.hosted.connect(_on_hosted)
	Network.joined.connect(_on_joined)
	Network.join_failed.connect(_on_join_failed)
	Network.peer_joined.connect(_on_peer_joined)

	_set_state_idle()

func _set_state_idle() -> void:
	_is_hosting = false
	_is_joining = false
	_host_button.visible = true
	_join_button.visible = true
	_solo_button.visible = true
	_code_input.visible = true
	_code_input.editable = true
	_cancel_button.visible = false
	_enter_world_button.visible = false
	_code_display.visible = false
	_status.text = ""

func _set_state_hosting(code: String) -> void:
	_is_hosting = true
	_host_button.visible = false
	_join_button.visible = false
	_solo_button.visible = false
	_code_input.visible = false
	_cancel_button.visible = true
	_enter_world_button.visible = true
	_code_display.visible = true
	_code_display.text = code
	_status.text = "Share this code. Click Enter World to start playing — others can join anytime."

func _set_state_joining() -> void:
	_is_joining = true
	_host_button.visible = false
	_join_button.visible = false
	_solo_button.visible = false
	_code_input.editable = false
	_cancel_button.visible = true
	_enter_world_button.visible = false
	_code_display.visible = false
	_status.text = "Connecting…"

func _on_host() -> void:
	_status.text = "Reaching relay…"
	_host_button.disabled = true
	Network.host()

func _on_join() -> void:
	var code: String = _code_input.text.strip_edges().to_upper()
	if code.is_empty():
		_status.text = "Enter a code"
		return
	_set_state_joining()
	Network.join(code)

func _on_solo() -> void:
	Network.leave()
	get_tree().change_scene_to_file(WORLD_SCENE)

func _on_cancel() -> void:
	Network.leave()
	_set_state_idle()

func _on_enter_world() -> void:
	# Host drops into the world without waiting for joiners. The network
	# session stays open, so anyone who later types the code will pop into
	# the same world.
	get_tree().change_scene_to_file(WORLD_SCENE)

func _on_hosted(code: String) -> void:
	_set_state_hosting(code)

func _on_joined() -> void:
	if _is_hosting:
		# Host gets `joined` immediately after `hosted`. Stay in the menu so
		# they can read their code and decide when to enter.
		# Auto-enter only if a real peer joins (see _on_peer_joined).
		return
	get_tree().change_scene_to_file(WORLD_SCENE)

func _on_peer_joined(_peer_id: int) -> void:
	# If we're the host sitting in the menu and someone joins, drop into
	# the world automatically. Joiners already entered above.
	if _is_hosting:
		get_tree().change_scene_to_file(WORLD_SCENE)

func _on_join_failed(reason: String) -> void:
	_status.text = reason
	_host_button.disabled = false
	_code_input.editable = true
	_set_state_idle()
