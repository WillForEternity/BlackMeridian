# BlackMeridian relay

Tiny WebSocket relay that pairs game clients by 6-character code. Two
implementations of the **same wire protocol**:

- `server.ts` — TypeScript for **Deno Deploy** (free, no card)
- `server.py` — Python for **self-host / Docker / Fly / Render**

Pick one. You only deploy the relay once — bake its URL into the game and
share the game binary with friends.

## Deno Deploy (recommended — free, no card)

1. Push this repo to GitHub. The relay files (this directory) must be in it.
2. Sign in at <https://dash.deno.com> with GitHub (no credit card required).
3. Click **New Project** → **Link an existing GitHub repo**.
4. Pick your `BlackMeridian` repo, branch `main`.
5. **Entrypoint**: `relay/server.ts`.
6. Click **Deploy**. First build takes ~30 s.
7. The dashboard shows a URL like `https://blackmeridian-relay.deno.dev`.
8. In Godot, change `RELAY_URL` in `globals/network.gd` to
   `wss://blackmeridian-relay.deno.dev` (note `wss://`, not `https://`).

Free-tier limits: 1 M requests/month, 100 GB outbound — more than a small
group of friends will ever need.

## Self-host with Python

```sh
cd relay
python -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python server.py
# listens on ws://localhost:8080
```

In Godot, set `RELAY_URL = "ws://localhost:8080"` and launch two copies of
the game on the same machine for end-to-end testing.

## Self-host on Fly.io / Render

The `Dockerfile` and `fly.toml` deploy `server.py`. Both require a credit
card at signup as of 2025 (Render's free Web Service plan is still free
once you're past the card gate; Fly.io has a $5 hobby trial). Push the
repo, point the platform at `relay/`, deploy. The platform shows a URL —
use the `wss://...` form in Godot.

## Sanity check

```sh
# install: pipx install websockets  (or use a venv)
python -c "
import asyncio, json, websockets
async def t():
    async with websockets.connect('wss://YOUR-URL') as ws:
        await ws.send(json.dumps({'type': 'host'}))
        print(json.loads(await ws.recv()))
asyncio.run(t())
"
```

You should see a `welcome` message with a fresh code.
