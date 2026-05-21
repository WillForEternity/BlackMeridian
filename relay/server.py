"""
Tiny WebSocket relay for BlackMeridian's N-player coop.

Model: rooms keyed by a 6-character code. The first peer ("host") creates the
room; anyone else with the code joins. Each peer gets a stable peer_id within
the room (monotonic from 1). Messages from any peer are broadcast verbatim to
every OTHER peer in the same room — the relay does not parse game traffic.

Wire protocol (JSON text frames over WebSocket):

  client -> server, FIRST message after connecting:
    {"type": "host"}                       -> create a new room with a fresh code
    {"type": "join", "code": "ABC123"}     -> join an existing room

  server -> client, in response to handshake:
    {"type": "welcome", "code": "...", "peer_id": N, "peers": [list of OTHER peer_ids]}
    {"type": "error",   "reason": "..."}   -> connection then closes

  server -> existing peers when someone joins:
    {"type": "peer_joined", "peer_id": N}

  server -> remaining peers when someone leaves:
    {"type": "peer_left", "peer_id": N}

  After "welcome", peers send arbitrary application messages. Each one is
  broadcast unchanged to every other peer in the room. Senders include their
  own "from" field by convention; the relay does not enforce or rewrite it.

Free-tier friendly: ~30 MB RAM, no persistent storage, no DB.
"""

import asyncio
import json
import logging
import os
import secrets
import string
from typing import Dict, Optional, Set

import websockets
from websockets.asyncio.server import ServerConnection, serve

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("relay")

PORT: int = int(os.environ.get("PORT", "8080"))
HANDSHAKE_TIMEOUT_S: float = 30.0
CODE_ALPHABET: str = string.ascii_uppercase + string.digits
CODE_LEN: int = 6
MAX_ROOM_SIZE: int = 16  # hard cap so a runaway loop can't fill memory


class Peer:
    __slots__ = ("ws", "peer_id", "room")

    def __init__(self, ws: ServerConnection, peer_id: int, room: "Room") -> None:
        self.ws = ws
        self.peer_id = peer_id
        self.room = room


class Room:
    __slots__ = ("code", "peers", "next_peer_id")

    def __init__(self, code: str) -> None:
        self.code = code
        self.peers: Dict[ServerConnection, Peer] = {}
        self.next_peer_id = 1

    def add(self, ws: ServerConnection) -> Peer:
        pid = self.next_peer_id
        self.next_peer_id += 1
        peer = Peer(ws, pid, self)
        self.peers[ws] = peer
        return peer

    def remove(self, ws: ServerConnection) -> Optional[Peer]:
        return self.peers.pop(ws, None)

    def others(self, ws: ServerConnection) -> Set[ServerConnection]:
        return {w for w in self.peers if w is not ws}

    def other_ids(self, ws: ServerConnection) -> list[int]:
        return [p.peer_id for w, p in self.peers.items() if w is not ws]


rooms: Dict[str, Room] = {}


def make_code() -> str:
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LEN))


def fresh_code() -> str:
    while True:
        code = make_code()
        if code not in rooms:
            return code


async def send_json(ws: ServerConnection, obj: dict) -> None:
    try:
        await ws.send(json.dumps(obj))
    except websockets.ConnectionClosed:
        pass


async def broadcast(targets: Set[ServerConnection], payload: str) -> None:
    if not targets:
        return
    await asyncio.gather(
        *[_safe_send(w, payload) for w in targets],
        return_exceptions=True,
    )


async def _safe_send(ws: ServerConnection, payload: str) -> None:
    try:
        await ws.send(payload)
    except websockets.ConnectionClosed:
        pass


async def handle(ws: ServerConnection) -> None:
    peer: Optional[Peer] = None
    try:
        try:
            first_raw = await asyncio.wait_for(ws.recv(), timeout=HANDSHAKE_TIMEOUT_S)
        except asyncio.TimeoutError:
            await send_json(ws, {"type": "error", "reason": "Handshake timeout"})
            return

        try:
            msg = json.loads(first_raw)
        except json.JSONDecodeError:
            await send_json(ws, {"type": "error", "reason": "Invalid handshake"})
            return

        mtype = msg.get("type")
        if mtype == "host":
            code = fresh_code()
            room = Room(code)
            rooms[code] = room
            peer = room.add(ws)
            log.info("HOST created %s (peer_id=%d)", code, peer.peer_id)
        elif mtype == "join":
            requested = str(msg.get("code", "")).strip().upper()
            room = rooms.get(requested)
            if room is None:
                await send_json(ws, {"type": "error", "reason": "Code not found"})
                return
            if len(room.peers) >= MAX_ROOM_SIZE:
                await send_json(ws, {"type": "error", "reason": "Room is full"})
                return
            peer = room.add(ws)
            log.info("JOIN %s (peer_id=%d, room_size=%d)", requested, peer.peer_id, len(room.peers))
        else:
            await send_json(ws, {"type": "error", "reason": "Unknown handshake type"})
            return

        await send_json(ws, {
            "type": "welcome",
            "code": peer.room.code,
            "peer_id": peer.peer_id,
            "peers": peer.room.other_ids(ws),
        })
        await broadcast(peer.room.others(ws), json.dumps({
            "type": "peer_joined",
            "peer_id": peer.peer_id,
        }))

        # Forwarding loop. Every game message goes to every other peer in the
        # room, byte-for-byte (no parsing).
        async for payload in ws:
            others = peer.room.others(ws)
            if others:
                await broadcast(others, payload)
    except websockets.ConnectionClosed:
        pass
    except Exception:
        log.exception("handler crashed")
    finally:
        if peer is not None:
            peer.room.remove(ws)
            await broadcast(peer.room.others(ws), json.dumps({
                "type": "peer_left",
                "peer_id": peer.peer_id,
            }))
            if not peer.room.peers:
                rooms.pop(peer.room.code, None)
                log.info("ROOM %s closed (empty)", peer.room.code)


async def main() -> None:
    log.info("relay listening on 0.0.0.0:%d", PORT)
    async with serve(handle, "0.0.0.0", PORT, ping_interval=20, ping_timeout=20):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
