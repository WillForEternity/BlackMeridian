extends Node3D

const RemotePuppet := preload("res://entities/player/remote_puppet.gd")

@onready var _reset_button: Button = $UI/HotbarRoot/ResetButton
@onready var _player: Node3D = $Player
@onready var _terrain: Node = $Terrain
@onready var _remote_root: Node3D = $RemotePlayers

func _ready() -> void:
	_reset_button.pressed.connect(_reset)
	_reset_button.mouse_entered.connect(func() -> void: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE)
	_apply_cmdline_spawn()

	# Multiplayer wiring. The Network autoload speaks to the relay; we just
	# react to its signals. Puppets are spawned lazily on first pose from a
	# peer (in case peer_joined ordering races with pose arrival) and cleaned
	# up on peer_left or disconnect.
	if Network.is_in_room():
		Network.message_received.connect(_on_network_message)
		Network.peer_left.connect(_on_peer_left)
		Network.disconnected.connect(_on_disconnected)
		# Offset non-first peers so multiple players don't all spawn on top of
		# each other. peer_id 1 is the host; everyone else gets a ring offset.
		if Network.my_peer_id > 1:
			var angle: float = float(Network.my_peer_id - 1) * (TAU / 6.0)
			var offset: Vector3 = Vector3(cos(angle), 0.0, sin(angle)) * 3.0
			_player.global_position += offset

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		_reset()

func _reset() -> void:
	# Just teleport the local player back to the map's spawn point. Reloading
	# the scene would tear down the multiplayer session for everyone in the
	# room and is heavier than needed for a respawn.
	if _player == null:
		return
	_player.global_position = Vector3(0.0, 2.0, 0.0)
	if _player is CharacterBody3D:
		(_player as CharacterBody3D).velocity = Vector3.ZERO

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

# ── Multiplayer ──────────────────────────────────────────────────────────────

func _on_network_message(msg: Dictionary) -> void:
	var mtype: String = String(msg.get("type", ""))
	match mtype:
		"pose":
			_handle_pose(msg)
		"damage":
			_handle_damage(msg)

func _handle_damage(msg: Dictionary) -> void:
	# Target-authoritative: only the peer whose puppet was hit applies the
	# damage to its local player. Everyone else ignores the broadcast.
	if int(msg.get("target", 0)) != Network.my_peer_id:
		return
	if _player == null or not _player.has_method("take_damage"):
		return
	var dir_arr: Array = msg.get("dir", [])
	var dir: Vector3 = Vector3.ZERO
	if dir_arr.size() == 3:
		dir = Vector3(float(dir_arr[0]), float(dir_arr[1]), float(dir_arr[2]))
	_player.take_damage(int(msg.get("amount", 0)), dir)

func _handle_pose(msg: Dictionary) -> void:
	var sender: int = int(msg.get("from", 0))
	if sender <= 0 or sender == Network.my_peer_id:
		return
	var puppet: Node = _remote_root.get_node_or_null("Puppet_%d" % sender)
	if puppet == null:
		puppet = _spawn_puppet(sender)
	var pos_arr: Array = msg.get("pos", [])
	if pos_arr.size() != 3:
		return
	var pos: Vector3 = Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))
	puppet.set_pose(pos, float(msg.get("yaw", 0.0)), int(msg.get("slot", -1)))
	if puppet.has_method("set_health"):
		puppet.set_health(float(msg.get("hp", 0.0)), float(msg.get("hp_max", 1.0)))
	# pitch is in msg["pitch"] — reserved for a future head/aim indicator.

func _spawn_puppet(peer_id: int) -> Node:
	var puppet := RemotePuppet.new()
	puppet.setup(peer_id)
	_remote_root.add_child(puppet)
	return puppet

func _on_peer_left(peer_id: int) -> void:
	var puppet: Node = _remote_root.get_node_or_null("Puppet_%d" % peer_id)
	if puppet != null:
		puppet.queue_free()

func _on_disconnected() -> void:
	# Relay link dropped — drop everyone and return to menu.
	for child in _remote_root.get_children():
		child.queue_free()
	get_tree().change_scene_to_file("res://scenes/menu/menu.tscn")
