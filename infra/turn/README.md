# Local dev TURN server (coturn)

LOCAL DEV ONLY. Static credentials, no TLS, loopback-scoped relay range.
Production path (TLS TURN + short-lived `use-auth-secret` credentials) is
blueprint Phase 6 — see `turnserver.conf` header and "Production differences"
below before deploying anywhere reachable from the internet.

## Start / stop

```
cd infra/turn
docker compose up -d
docker compose down
```

## Verify: listeners bound

```
docker logs voice_call_kit_turn_dev 2>&1 | head -30
```

Expect lines showing the UDP/TCP listener on `0.0.0.0:3478` and the relay
port range `49160-49200` opened. If you instead see bind/permission errors,
check nothing else on the host holds port 3478 (`lsof -i :3478`).

## Verify: one allocation actually works

With the container running, use any STUN/TURN test client. `turnutils_uclient`
ships inside the coturn image itself, so no extra install is needed:

```
docker exec voice_call_kit_turn_dev turnutils_uclient -v -t -u dev -w devpass 127.0.0.1
```

A successful run prints an allocated relay address in the
`49160-49200` range and `total 0 lost` (or similarly zero-loss) at the end.
That's the allocation check — it proves the server issues relay candidates,
not just that the process is up.

## How the reference app uses this

Point the app's ICE server list at:

```
turn:localhost:3478?transport=udp
turn:localhost:3478?transport=tcp
```

with credentials `dev` / `devpass` (matches `turnserver.conf`).

To exercise the Phase-3 "TURN fallback proven" gate item specifically, force
every candidate through the relay instead of letting ICE prefer a direct
path — set the peer connection's ICE transport policy to relay-only
(`iceTransportPolicy: relay` in WebRTC config terms; the equivalent
`RTCConfiguration` field in `flutter_webrtc`/`WebRtcMediaAdapter`). With that
set, a successful call proves media actually traversed this coturn instance,
not a direct P2P path that happened to be available on loopback.

## Production differences (do not skip before any non-loopback deploy)

- [ ] Credentials: replace static `user=dev:devpass` with `use-auth-secret`
      and a shared secret held by the signaling server, minting short-lived
      per-call TURN credentials (blueprint Phase 6).
- [ ] Transport: add `listening-tls-port` + real cert/key — TURNS (TLS),
      not just plain UDP/TCP.
- [ ] Network: this compose file publishes ports assuming Docker Desktop on
      macOS (no host networking). A cloud deployment needs real public IP /
      `external-ip` config, not `0.0.0.0` loopback defaults.
- [ ] Cost: run the TURN cost pre-gate (`UPGRADE_BLUEPRINT_V3.md` line 817)
      before the first cloud/region deployment — budget alert configured,
      monthly cap written in `docs/OPERATIONS.md`, relayed-vs-direct ratio
      measured from real telemetry, not guessed.
- [ ] Quotas: `total-quota`/`user-quota` here (100/10) are dev-scale
      placeholders, not sized for production traffic.

## Cost note

This setup binds to loopback/localhost only — there is no egress traffic
leaving the dev machine, so it has **zero cloud egress cost**. The
blueprint's TURN cost pre-gate (line 817) is a Phase-6 concern that applies
once coturn is deployed to a real cloud region with real relayed media
traffic; it does not apply to this local container.

## Docker daemon status at time of writing

`docker compose config` was validated (exits 0) without the daemon running.
The daemon (`Docker Desktop`) was **not running** in this environment when
this infra was created, so `docker compose up -d` + `docker logs` listener
verification and the allocation check above were **not executed** — they
are pending a run in an environment with Docker Desktop started. Run the
two verify sections above once the daemon is available; do not treat this
README as proof the container was ever actually started.
