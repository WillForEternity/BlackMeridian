// BlackMeridian WebSocket relay — Cloudflare Workers edition.
//
// Identical wire protocol to relay/server.py and relay/server.ts (see those
// for the spec). All connections route to a single Durable Object instance
// ("Relay") that holds every active room in memory. This is fine for the
// scale of a friend-group game — single-threaded, cheap, and DOs hibernate
// when idle so you pay nothing while no one is playing.

export interface Env {
  RELAY: DurableObjectNamespace;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.headers.get("Upgrade") !== "websocket") {
      return new Response(
        "BlackMeridian relay — connect with a WebSocket client.\n",
        { status: 200, headers: { "content-type": "text/plain" } },
      );
    }
    // One global Relay DO handles all rooms. idFromName("global") returns
    // a stable id, so every WebSocket lands at the same DO instance.
    const stub = env.RELAY.get(env.RELAY.idFromName("global"));
    return stub.fetch(req);
  },
};

type Room = {
  code: string;
  peers: Map<WebSocket, number>;
  nextPeerId: number;
};

const CODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const CODE_LEN = 6;
const MAX_ROOM_SIZE = 16;

export class Relay {
  state: DurableObjectState;
  rooms: Map<string, Room> = new Map();

  constructor(state: DurableObjectState, _env: Env) {
    this.state = state;
  }

  async fetch(req: Request): Promise<Response> {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
    server.accept();
    this.handleSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  makeCode(): string {
    let s = "";
    for (let i = 0; i < CODE_LEN; i++) {
      s += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
    }
    return s;
  }

  freshCode(): string {
    // eslint-disable-next-line no-constant-condition
    while (true) {
      const c = this.makeCode();
      if (!this.rooms.has(c)) return c;
    }
  }

  send(ws: WebSocket, payload: string | ArrayBuffer) {
    try {
      ws.send(payload);
    } catch {
      // peer is going away; ignore
    }
  }

  handleSocket(ws: WebSocket) {
    let room: Room | null = null;
    let myPeerId = 0;

    const cleanup = () => {
      if (room === null) return;
      room.peers.delete(ws);
      const leftMsg = JSON.stringify({ type: "peer_left", peer_id: myPeerId });
      for (const [w] of room.peers) this.send(w, leftMsg);
      if (room.peers.size === 0) {
        this.rooms.delete(room.code);
      }
      room = null;
    };

    ws.addEventListener("close", cleanup);
    ws.addEventListener("error", cleanup);

    ws.addEventListener("message", (event: MessageEvent) => {
      if (room === null) {
        // Handshake phase: {"type":"host"} or {"type":"join","code":"..."}.
        let msg: { type?: string; code?: string };
        try {
          msg = JSON.parse(
            typeof event.data === "string"
              ? event.data
              : new TextDecoder().decode(event.data as ArrayBuffer),
          );
        } catch {
          this.send(ws, JSON.stringify({ type: "error", reason: "Invalid handshake" }));
          try { ws.close(); } catch { /* */ }
          return;
        }

        if (msg.type === "host") {
          const code = this.freshCode();
          room = { code, peers: new Map(), nextPeerId: 1 };
          this.rooms.set(code, room);
          myPeerId = room.nextPeerId++;
          room.peers.set(ws, myPeerId);
          this.send(ws, JSON.stringify({
            type: "welcome",
            code,
            peer_id: myPeerId,
            peers: [],
          }));
        } else if (msg.type === "join") {
          const requested = (msg.code ?? "").toString().trim().toUpperCase();
          const r = this.rooms.get(requested);
          if (!r) {
            this.send(ws, JSON.stringify({ type: "error", reason: "Code not found" }));
            try { ws.close(); } catch { /* */ }
            return;
          }
          if (r.peers.size >= MAX_ROOM_SIZE) {
            this.send(ws, JSON.stringify({ type: "error", reason: "Room is full" }));
            try { ws.close(); } catch { /* */ }
            return;
          }
          room = r;
          myPeerId = room.nextPeerId++;
          const others: number[] = [];
          for (const [, id] of room.peers) others.push(id);
          room.peers.set(ws, myPeerId);
          this.send(ws, JSON.stringify({
            type: "welcome",
            code: room.code,
            peer_id: myPeerId,
            peers: others,
          }));
          const announce = JSON.stringify({ type: "peer_joined", peer_id: myPeerId });
          for (const [w] of room.peers) {
            if (w !== ws) this.send(w, announce);
          }
        } else {
          this.send(ws, JSON.stringify({ type: "error", reason: "Unknown handshake type" }));
          try { ws.close(); } catch { /* */ }
        }
        return;
      }

      // Forwarding phase: broadcast verbatim to every other peer in the room.
      for (const [w] of room.peers) {
        if (w !== ws) this.send(w, event.data as string | ArrayBuffer);
      }
    });
  }
}
