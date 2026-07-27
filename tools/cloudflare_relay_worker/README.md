# Border relay (Cloudflare Worker)

**Deployed at `voice-call-relay.tlscodes-com.workers.dev`** — the app's
default for both WAN fallback lanes.


Terminates the WSS and HTTP long-poll fallback lanes. It pairs the two
peers of a call session and forwards bytes between them verbatim — no
parsing, no reframing, no reordering. The gRPC length-prefixed framing the
client uses is opaque to it.

## Protocol

| route | method | purpose |
|---|---|---|
| `/ws?session=<id>&role=<a\|b>` | GET + `Upgrade: websocket` | live bidirectional relay |
| `/http?session=<id>&role=<a\|b>` | POST | send frame bytes |
| `/http?session=<id>&role=<a\|b>&wait=<ms>` | GET | long-poll for frames (`204` when none) |
| `/health` | GET | liveness |

`session` is 1–128 characters of `[A-Za-z0-9._-]`. `role` is `a` for the
caller and `b` for the callee; each side reads what the other wrote.

A POST body may hold one frame or several back to back. A poll answers
with everything queued, concatenated in arrival order, so the client's
frame reader splits them exactly as it would off a socket.

## Deploy

Redeploying after a change to `src/worker.js` or `wrangler.toml`:

```
cd tools/cloudflare_relay_worker
npx wrangler login      # once per machine
npx wrangler deploy
```

Check the bundle without deploying — the same command CI runs, and it
needs no Cloudflare credentials:

```
npx wrangler deploy --dry-run --outdir=dist
```

Tail the live logs, and confirm the deployment answers:

```
npx wrangler tail
curl https://voice-call-relay.tlscodes-com.workers.dev/health
```

## Pointing the app at a relay

The app already defaults to the deployed host, keying the relay session on
the call id and the role on the call role. To use a different deployment,
name its host and let both lane URIs be derived:

```
export FALLBACK_RELAY_HOST="my-relay.<subdomain>.workers.dev"
```

Or override one lane with a full URI:

```
export FALLBACK_WS_ENDPOINT="wss://my-relay.<subdomain>.workers.dev/ws?session=<id>&role=a"
export FALLBACK_HTTP_ENDPOINT="https://my-relay.<subdomain>.workers.dev/http?session=<id>&role=a"
```

`ResilientLaneEndpoints.cloudflareWorker` builds both URIs from the
hostname, session and role, so an app does not assemble them by hand.

## Tests

The protocol is covered against a loopback server implementing these same
routes — no test reaches the deployed worker, which would measure
Cloudflare's uptime rather than this code:

```
cd packages/connection_orchestrator
dart test test/cloudflare_relay_protocol_test.dart
```

The failover behaviour that depends on it:

```
cd apps/reference_app
flutter test test/fallback_lane_failover_e2e_test.dart
```

CI additionally runs `node --check` on the source and the dry-run deploy
above, so a broken bundle or an invalid `wrangler.toml` fails the build.

## What this does and does not give you

It does forward real traffic between two peers, which is what the echo
services cannot do, and it rides Cloudflare's address space and TLS
profile, which is ordinary web traffic on the wire.

It is a relay, not a media server: it does not transcode, does not
authenticate peers, and does not persist anything. Anyone who guesses a
session id can attach as the missing role. Session ids must therefore be
unguessable — treat them as secrets, not as call numbers. The payloads
themselves are already sealed by the client's own session keys before they
reach this code, so the relay sees ciphertext either way.

## Bounds

Per direction, `MAX_QUEUED_FRAMES` (256) and `MAX_QUEUED_BYTES` (4 MiB)
cap what is held for a peer that has not attached. Past the cap the
**oldest** frame is dropped: this carries live media, so a receiver that
fell behind wants the newest frames. Long-polls are held at most 25
seconds. Sessions have no explicit expiry beyond the Durable Object's own
eviction when idle.

Free-plan limits at time of writing: 100,000 Worker requests per day, and
SQLite-backed Durable Objects included. Long-polling spends one request
per poll cycle, so a call that polls every 25 seconds costs roughly 144
requests per hour per peer. Check current limits before relying on this
for anything beyond development — they change.
