extends Node

# WebSocket client that talks to the BlackMeridian relay (see /relay).
#
# Flow:
#   Network.host()                 -> connects to the relay, requests a fresh
#                                     6-character code, emits `hosted(code)`
#                                     and then `joined` once welcomed.
#   Network.join("ABC123")         -> connects, requests that room, emits
#                                     `joined` on success or `join_failed`.
#   Network.send_message({...})    -> JSON dict, broadcast to every other
#                                     peer in the room. Adds {"from": my_id}.
#   Network.leave()                -> drops the connection.
#
# Signals:
#   hosted(code: String)           -> after the relay accepts a host request
#   joined                         -> in-room, ready to send/receive
#   join_failed(reason: String)
#   peer_joined(peer_id: int)      -> someone else entered the room
#   peer_left(peer_id: int)        -> someone else exited the room
#   message_received(msg: Dict)    -> a peer sent us a game message
#   disconnected                   -> connection dropped (intentional or not)
#
# The relay URL is set below. Change to your deployed instance — see
# /relay/README.md for deploy steps.

const RELAY_URL: String = "wss://blackmeridian-relay.simonmaclean6.workers.dev"

signal hosted(code: String)
signal joined
signal join_failed(reason: String)
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal message_received(msg: Dictionary)
signal disconnected

enum State { IDLE, CONNECTING, WAIT_WELCOME, IN_ROOM }

var my_peer_id: int = 0
var room_code: String = ""

var _state: int = State.IDLE
var _ws: WebSocketPeer
var _pending_handshake: Dictionary = {}
var _other_peer_ids: Array[int] = []

func _ready() -> void:
	set_process(false)

func host() -> void:
	_open({"type": "host"})

func join(code: String) -> void:
	var clean: String = code.strip_edges().to_upper()
	if clean.is_empty():
		join_failed.emit("Enter a code")
		return
	_open({"type": "join", "code": clean})

func leave() -> void:
	if _ws != null:
		_ws.close()
	_reset_state()
	disconnected.emit()

func is_in_room() -> bool:
	return _state == State.IN_ROOM

func send_message(msg: Dictionary) -> void:
	if _state != State.IN_ROOM or _ws == null:
		return
	# Authoritative-ish tag: every message carries the sender's peer_id so
	# receivers can route without parsing wire metadata. Trusts the client,
	# which is fine for coop with friends.
	msg["from"] = my_peer_id
	_ws.send_text(JSON.stringify(msg))

func get_known_peers() -> Array[int]:
	return _other_peer_ids.duplicate()

# ── internal ────────────────────────────────────────────────────────────────

func _open(handshake: Dictionary) -> void:
	leave()  # ensure clean slate
	_ws = WebSocketPeer.new()
	var err: int = _ws.connect_to_url(RELAY_URL)
	if err != OK:
		_reset_state()
		join_failed.emit("Bad relay URL: %s" % RELAY_URL)
		return
	_pending_handshake = handshake
	_state = State.CONNECTING
	set_process(true)

func _reset_state() -> void:
	_state = State.IDLE
	_ws = null
	_pending_handshake = {}
	my_peer_id = 0
	room_code = ""
	_other_peer_ids.clear()
	set_process(false)

func _process(_delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var ready_state: int = _ws.get_ready_state()
	match ready_state:
		WebSocketPeer.STATE_CONNECTING:
			pass
		WebSocketPeer.STATE_OPEN:
			if _state == State.CONNECTING:
				_ws.send_text(JSON.stringify(_pending_handshake))
				_state = State.WAIT_WELCOME
			while _ws.get_available_packet_count() > 0:
				var raw: PackedByteArray = _ws.get_packet()
				_handle_packet(raw.get_string_from_utf8())
		WebSocketPeer.STATE_CLOSING:
			pass
		WebSocketPeer.STATE_CLOSED:
			var was_in_room: bool = _state == State.IN_ROOM or _state == State.WAIT_WELCOME
			_reset_state()
			if was_in_room:
				disconnected.emit()

func _handle_packet(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Network: non-dict packet: %s" % text.substr(0, 80))
		return
	var msg: Dictionary = parsed
	var mtype: String = String(msg.get("type", ""))
	match mtype:
		"welcome":
			room_code = String(msg.get("code", ""))
			my_peer_id = int(msg.get("peer_id", 0))
			_other_peer_ids.clear()
			for id in msg.get("peers", []):
				_other_peer_ids.append(int(id))
			_state = State.IN_ROOM
			# host/joined are both "we're in" — but the host needs the code.
			if String(_pending_handshake.get("type", "")) == "host":
				hosted.emit(room_code)
			joined.emit()
		"error":
			var reason: String = String(msg.get("reason", "Unknown error"))
			leave()
			join_failed.emit(reason)
		"peer_joined":
			var pid: int = int(msg.get("peer_id", 0))
			if pid > 0 and not _other_peer_ids.has(pid):
				_other_peer_ids.append(pid)
			peer_joined.emit(pid)
		"peer_left":
			var lid: int = int(msg.get("peer_id", 0))
			_other_peer_ids.erase(lid)
			peer_left.emit(lid)
		_:
			# Game-level message from a peer. Pass it on.
			message_received.emit(msg)
