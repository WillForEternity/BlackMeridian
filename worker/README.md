# BlackMeridian Cloudflare Workers relay

Same wire protocol as `relay/server.py` and `relay/server.ts`. Holds every
active room inside a single Durable Object — fine for friend-group scale.

## Deploying (one-time, ~10 min)

1. `npm install` in this directory. (Pulls in `wrangler` and the Workers types.)
2. `npx wrangler login`. A browser tab opens — sign in to Cloudflare (free,
   no card). After you grant access, the terminal says "Successfully logged in."
3. (Optional) edit `wrangler.jsonc` and change `"name": "blackmeridian-relay"`
   to whatever you want; this becomes part of the deployed URL.
4. `npx wrangler deploy`. First deploy takes ~20 s. The terminal prints the
   final URL, something like:

   ```
   Published blackmeridian-relay (1.32 sec)
     https://blackmeridian-relay.<your-subdomain>.workers.dev
   ```

5. In Godot, edit `globals/network.gd` line 24 to:
   ```gdscript
   const RELAY_URL: String = "wss://blackmeridian-relay.<your-subdomain>.workers.dev"
   ```
   (Note `wss://`, not `https://`.)

That's it. The relay is now always-on, never hibernates while peers are
connected, and costs $0 within the free tier (100K Worker requests/day,
1M Durable Object requests/month — orders of magnitude over what you'll use).

## Updating the relay

After editing `src/index.ts`: `npx wrangler deploy`. Done.

## Local development

`npx wrangler dev` runs the Worker locally with a real Durable Object on
`http://localhost:8787`. Point Godot at `ws://localhost:8787` to test
end-to-end without deploying.

## Sanity check

```sh
npm install -g wscat   # one-time
wscat -c wss://blackmeridian-relay.<your-subdomain>.workers.dev
> {"type":"host"}
< {"type":"welcome","code":"ABC123","peer_id":1,"peers":[]}
```
