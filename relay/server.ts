// BlackMeridian WebSocket relay — Deno Deploy edition.
//
// Same wire protocol as server.py (see that file's header for the full spec).
// Lives in the same directory so we can keep one source of truth. Pick whichever
// runtime you want to deploy:
//
//   - Deno Deploy (free, no card):   deploy this file (server.ts)
//   - Self-hosted / Fly / Render:    deploy server.py via Dockerfile
//
// Local testing:
//   deno run --allow-net server.ts
//   # listens on ws://localhost:8080

const CODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const CODE_LEN = 6;
const MAX_ROOM_SIZE = 16;
const HANDSHAKE_TIMEOUT_MS = 30_000;

type Room = {
  code: string;
  peers: Map<WebSocket, number>;
  nextPeerId: number;
};

const rooms = new Map<string, Room>();

function makeCode(): string {
  let s = "";
  for (let i = 0; i < CODE_LEN; i++) {
    s += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
  }
  return s;
}

function freshCode(): string {
  while (true) {
    const code = makeCode();
    if (!rooms.has(code)) return code;
  }
}

function safeSend(ws: WebSocket, payload: string | ArrayBufferLike | Blob | ArrayBufferView) {
  if (ws.readyState !== WebSocket.OPEN) return;
  try {
    ws.send(payload);
  } catch {
    // peer is going away; ignore
  }
}

function broadcastExcept(room: Room, sender: WebSocket, payload: string | ArrayBufferLike) {
  for (const [w] of room.peers) {
    if (w !== sender) safeSend(w, payload);
  }
}

function otherIds(room: Room, self: WebSocket): number[] {
  const out: number[] = [];
  for (const [w, id] of room.peers) {
    if (w !== self) out.push(id);
  }
  return out;
}

function handleSocket(ws: WebSocket) {
  let room: Room | null = null;
  let myPeerId = 0;
  let handshakeTimer: number | null = null;

  const cleanup = () => {
    if (handshakeTimer !== null) {
      clearTimeout(handshakeTimer);
      handshakeTimer = null;
    }
    if (room === null) return;
    room.peers.delete(ws);
    const left = JSON.stringify({ type: "peer_left", peer_id: myPeerId });
    for (const [w] of room.peers) safeSend(w, left);
    if (room.peers.size === 0) {
      rooms.delete(room.code);
      console.log(`ROOM ${room.code} closed (empty)`);
    }
    room = null;
  };

  ws.addEventListener("open", () => {
    handshakeTimer = setTimeout(() => {
      if (room === null) {
        safeSend(ws, JSON.stringify({ type: "error", reason: "Handshake timeout" }));
        try { ws.close(); } catch { /* */ }
      }
    }, HANDSHAKE_TIMEOUT_MS);
  });

  ws.addEventListener("close", cleanup);
  ws.addEventListener("error", cleanup);

  ws.addEventListener("message", (event: MessageEvent) => {
    if (room === null) {
      // Handshake phase: expect {"type":"host"} or {"type":"join","code":"..."}.
      if (handshakeTimer !== null) {
        clearTimeout(handshakeTimer);
        handshakeTimer = null;
      }
      let msg: { type?: string; code?: string };
      try {
        msg = JSON.parse(typeof event.data === "string" ? event.data : new TextDecoder().decode(event.data as ArrayBuffer));
      } catch {
        safeSend(ws, JSON.stringify({ type: "error", reason: "Invalid handshake" }));
        try { ws.close(); } catch { /* */ }
        return;
      }

      if (msg.type === "host") {
        const code = freshCode();
        room = { code, peers: new Map(), nextPeerId: 1 };
        rooms.set(code, room);
        myPeerId = room.nextPeerId++;
        room.peers.set(ws, myPeerId);
        safeSend(ws, JSON.stringify({ type: "welcome", code, peer_id: myPeerId, peers: [] }));
        console.log(`HOST created ${code} (peer_id=${myPeerId})`);
      } else if (msg.type === "join") {
        const requested = (msg.code ?? "").toString().trim().toUpperCase();
        const r = rooms.get(requested);
        if (!r) {
          safeSend(ws, JSON.stringify({ type: "error", reason: "Code not found" }));
          try { ws.close(); } catch { /* */ }
          return;
        }
        if (r.peers.size >= MAX_ROOM_SIZE) {
          safeSend(ws, JSON.stringify({ type: "error", reason: "Room is full" }));
          try { ws.close(); } catch { /* */ }
          return;
        }
        room = r;
        myPeerId = room.nextPeerId++;
        room.peers.set(ws, myPeerId);
        safeSend(ws, JSON.stringify({ type: "welcome", code: room.code, peer_id: myPeerId, peers: otherIds(room, ws) }));
        const announce = JSON.stringify({ type: "peer_joined", peer_id: myPeerId });
        for (const [w] of room.peers) {
          if (w !== ws) safeSend(w, announce);
        }
        console.log(`JOIN ${room.code} (peer_id=${myPeerId}, room_size=${room.peers.size})`);
      } else {
        safeSend(ws, JSON.stringify({ type: "error", reason: "Unknown handshake type" }));
        try { ws.close(); } catch { /* */ }
      }
      return;
    }

    // Forwarding phase: broadcast verbatim to every other peer in the room.
    broadcastExcept(room, ws, event.data as string | ArrayBuffer);
  });
}

const port = Number(Deno.env.get("PORT") ?? 8080);
console.log(`relay listening on 0.0.0.0:${port}`);

Deno.serve({ port }, (req: Request) => {
  if (req.headers.get("upgrade") !== "websocket") {
    return new Response("BlackMeridian relay — connect with a WebSocket client.\n", {
      status: 200,
      headers: { "content-type": "text/plain" },
    });
  }
  const { socket, response } = Deno.upgradeWebSocket(req);
  handleSocket(socket);
  return response;
});
