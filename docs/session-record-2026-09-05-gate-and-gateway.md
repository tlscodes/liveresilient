# Session record — 2026-09-05: the window became a gate, and the gate became a gateway

Branch `plan-v4-waves-1-to-6`. This file records what was done, what was measured, what is
still open, and the direction that was decided at the end of the session. Every number here
came from a tool output in the session that produced it; nothing is estimated.

---

## Part 1 — where the session started

The blackout profile could already carry a signed queue across a total network cut: 20 bundles,
411,600 B, four windows shaped at 16 kbit/s, per-window utilization 34.0 / 59.8 / 44.3 / 67.5 %.
The open question was the one written into `docs/blackout-gate-plan-to-90.md`: how does that
become 90 % of the window, and what actually consumed the other two thirds.

## Part 2 — Step 0: where the window went (measured, not guessed)

From `tools/dossier/logs/journey/blackout.phone.jsonl` and `blackout.hub.log` of the self-test
run 2026-09-05T07:15:44Z. The table is under "Step 0" in the plan document.

```
of 412.4 s of open pipe:
  payload                205.8 s   49.9 %
  per-request idle       138.0 s   33.5 %   (89 requests, 1.55 s each at 2,000 B/s)
  envelope inflation      68.6 s   16.6 %   (wire = 1.345 x payload)
  probes                 <  8 s   < 2 %
```

Two findings decided the whole design:

1. **The envelope is a ceiling.** The signed bundle was JSON with a base64 payload, so the wire
   carried 1.345 bytes for every payload byte. The phone's own counters said the same
   (`wire_bytes` 553,764 against `bytes` 411,600). With that encoding, payload-basis utilization
   cannot exceed 74.3 % even if every request were free. No transport work could have reached 90.
2. **On a thin pipe the request is the cost, not the byte.** 1.55 s of idle per request means an
   8 KB chunk, which is 4 s of payload, pays about 40 % overhead. The answer is not a larger
   chunk; it is no per-record round trip at all.

Recorded as `knowledge/lessons/networking/base64-envelope-caps-shaped-link-utilization.md`.

## Part 3 — what was built: blackout v3, the stream lane

Commit `b888ea9`. One framed TCP stream per window instead of one HTTP request per record:

- The phone opens one connection to the hub's stream port and sends an ids-only hello; the hub
  answers with the prefix it already holds for each id and with the lane parameters, so the hub
  is the single source of piece size, ack policy, inflight cap and stall timeout, and the phone
  carries no numeric constant of its own.
- Each bundle is a JSON header line followed by raw payload bytes from the hub's offset. No
  base64 on the wire. Acks come every 8 KB or every 2 seconds; a `done` line per verified bundle.
- A cut mid-stream loses nothing: the next window's hello gets the offsets back and the phone
  resumes from there. A new hello preempts a stale session, checked at every append under the
  lock, so two sessions can never interleave into one partial file.
- The hub writes `stream_stats.json` on every append, so a window can be credited the partial
  bytes it carried, not only the bundles that happened to complete inside it (`util_carried`).
- The runner prints a per-window ceiling model next to the measurement, so a number above the
  model is visibly a measurement bug and a number below 90 has a bounded gap to explain.
- Step 1 of the plan also landed: HTTP/1.1 keep-alive on the hub, so the old protocol pays one
  TCP handshake per window instead of one per request.

Gates on the Mac, all green: the hub's bundle and stream test suites, the runner's accounting
test, `bash -n` and dry runs, `flutter analyze`, the Dart unit tests, and an end-to-end test that
drives the real hub over loopback with the full 60-bundle plan, cuts the socket at 150 KB acked,
reconnects and finishes 60 of 60 verified.

## Part 4 — what the rig measured

**Step 1, keep-alive, with the old phone build** (commit `47fe234`):

```
20 of 20 bundles in 0.209 h
window 1 utilization   34.1 %  ->  54.1 %
windows                54.1 / 20.1 / 64.5 / 64.0 %
bulk connections carried 6 to 13 requests each (was 1)
```

**v3 stream lane, first run**: 68.8 / 53.3 / 56.6 % carried against a per-window ceiling of
88 to 94 %. Red against the 90 gate. The run was stopped early and read rather than repeated.

**The cause, from the hub log**: every window lost its session to `closed silent 30s` or a reset.
The stall timeout was 15 s, but the inflight cap of 32,768 B creates 16.4 s of queue at
2,000 B/s — every packet the phone sends after filling that window, including its own TCP
acknowledgements and the next connection's handshake, waits behind its own bulk data. The
timeout was measuring the sender's own queue and firing on healthy windows. Both ends were also
writing small control lines with Nagle enabled, so each line waited for the acknowledgement of
the previous one, which sat behind the same queue.

**The fix** (commit `dcc55f6`): the stall timeout is now derived from the queue it must outlast,
with the derivation written at the constant and a test that recomputes the floor so a future
change to the inflight cap cannot silently reintroduce the fault; `TCP_NODELAY` on both ends.

```
stall >= inflight_bytes / rate_floor + 2 * ack_interval + margin  =  25 s
```

Recorded as `knowledge/lessons/networking/stall-timeout-must-exceed-the-queue-the-inflight-cap-creates.md`.

**OPEN — the next number:** the v3 rig run has not been repeated with the corrected values. It
needs one phone rebuild first, because the Nagle change is on the phone side.

## Part 5 — two rig traps found the hard way

1. A monitor pipeline with a `cut` stage buffered every event; the run finished at 10:01Z and the
   monitor reported nothing until it timed out at 10:29Z. Every stage of a pipeline must flush
   per line, not only the first.
2. `trap cleanup EXIT INT TERM` without an `exit` ran cleanup on TERM and then **resumed** the
   loop, re-shaping the link it had just torn down. Signals now exit and the EXIT trap cleans up
   once, in both runners. A printed "cleanup" line is a claim; the shaper's status is the evidence.

## Part 6 — the direction that was decided at the end

The user's correction, and it changes the target:

> The right path is not white phones. It is the gateway they pass through — the whitelist
> itself. That is where a kilobyte must open for us and then widen until our app connects.
> It is a new network over the same road. Nothing that resembles taking over someone's device
> without consent; engineering only.

So the subject is not a privileged handset and not a courier. It is the gateway: the
allow-listed door that ordinary permitted traffic already goes through. Our app has to be
ordinary traffic to that door, on the same host and the same port as a normal service, starting
from a single kilobyte and widening on the same path until a live call stands on it.

That reframes the three profiles into one line of work:

- the door opens — one kilobyte crosses through the permitted door, live, never queued;
- the door widens — the same host and the same port carry the rendezvous;
- the road becomes a network — the call stands up and audio flows on that same path.

The answer to the question the user asked at the end, plainly: yes. The main gateway — the
place the allow-list lets traffic through — is the target. One kilobyte first, then the same
path widened until the app is connected. The white-SIM handset is not the subject and the
courier design is set aside as a separate idea, because the user's requirement is that nothing
depend on anyone's device without their consent.

## Part 7 — the whitelist profile: what exists, and the constraint that shaped it

Design in the session scratchpad as `design_whitelist.md`. Built but **not yet gated or
committed** (files are in the working tree, listed below).

Shape of the filtered network, enforced with pf filter rules in the harness anchor:

```
pass  tcp {allowed ports} and udp 53   phone <-> the one allowed host, stateful
block return-rst  tcp port 443 to any other host      TLS elsewhere is reset, for real
block drop        everything else from the phone      QUIC, ICMP, every other port
```

One host serves both an ordinary HTTPS page and the rendezvous on the same address and the same
port. The phone runs an ordinary-traffic loop and the live call at the same time, so "the door
was open in that second" is a measurement, not an assumption. Media is forced relay-only over
TCP so the phone emits no UDP but 53, and the selected candidate pair and the received-packet
counters are recorded as the proof. Negative controls run in the same window: TLS to a
non-allowed host must be reset, and QUIC must get nothing. The store-and-forward path is off and
proven off — the phone's queue branch is never entered, and a non-zero queued-clip or
degraded-voice-notes count fails the row by rule rather than being footnoted.

Three numbers: the moment ordinary permitted traffic succeeded, the moment the rendezvous
completed, and the gap between them.

**The measured constraint, which the row must declare rather than hide:**

```
bind 192.168.2.1:443  ->  Permission denied      (ports below 1024 need root on this Mac)
bind 192.168.2.1:80   ->  Permission denied
/etc/pf.conf has dummynet-anchor and anchor for the harness, but no rdr-anchor
```

A redirect would need an `rdr-anchor` line, and installing it means a pf reload, which deletes
Internet Sharing's NAT and drops the phone off the network. That is a deliberate one-time step
with a manual toggle, not something a run does unattended. So the listeners sit on 4443 and
3478, and the row says in words that these stand in for 443 and 80 while the filter's shape —
one allowed host, three TCP ports, UDP 53 only, QUIC dead, TLS elsewhere reset — is unchanged.
The reset rule uses the real port 443 and needs no listener, so that part is fully faithful.

## Part 8 — state at the end of the session

Commits on the branch:

```
dcc55f6  fix(rig): stall timeout derived from its own queue; TCP_NODELAY; signal traps exit
47fe234  evidence(journey): Step 1 keep-alive — window 1 utilization 34.1 -> 54.1 %
b888ea9  feat(rig): blackout v3 stream lane
f3fcd63  evidence(journey): the hours-scale v2 run, 19 of 20, honestly annotated
```

**Update, same session, after this document was first written:** the whitelist build's Mac-only
gates were all run and all passed, the phone wiring patch was applied and the analyzer stayed
clean, and the whole profile was committed as `45d6e2f`. So the list below is now COMMITTED, not
pending. The gates that passed: `bash -n` on both shapers and runners; the rule-text and
rule-ORDER test for the whitelist subcommand; the door-probe and row-assembly tests;
`journey_report.py`; `flutter analyze` clean; 17 door tests, 4 selected-pair tests, 8 relay
tests, and 51 app tests across the four blackout and peer files; `dart analyze` clean on the
relay. What is left is the rig, and the rig needs one phone rebuild.

The files, all committed in `45d6e2f`:

```
tools/t2/net_shape.sh                      the whitelist subcommand and its print-only twin
tools/t2/journey_run.sh                    the whitelist profile
tools/t2/tcp_door_probe.py                 the TCP up-and-down check that replaces the ping
tools/t2/journey_whitelist_rows.py         row assembly for the three numbers
tools/t2/test_net_shape_whitelist.py       rule text and rule ORDER pinned without sudo
tools/t2/test_tcp_door_probe.py            probe behaviour
tools/t2/test_journey_whitelist_rows.py    row and PASS-rule behaviour
server/signaling_server/lib/src/relay_server.dart   ordinary page plus rendezvous on one port
server/signaling_server/test/domestic_host_test.dart
apps/reference_app/integration_test/whitelist_door.dart        door loop and negative controls
apps/reference_app/test/whitelist_door_test.dart
apps/reference_app/integration_test/support/e2e_support.dart   relay-only ICE seam
packages/media_webrtc_flutter/lib/src/flutter_webrtc_peer_connection_port.dart  selected pair
packages/media_webrtc_flutter/test/selected_ice_pair_test.dart
apps/reference_app/integration_test/journey_peer_app.dart        the phone wiring, applied
tools/dossier/journey_report.py            the new profile and row kinds
```

Rig at the end of the session: idle and clean, the shaper torn down, only the relay running on
4443. Numbered backups at 573. The working tree has nothing of this work outstanding. **The
phone still carries the build from before the Nagle fix and before the door loop** — that one
rebuild is the gate to everything below.

## Part 9 — the exact next actions, in order

1. **One phone rebuild and install** (`tools/t2/journey_peer_install.sh`). It carries two things
   at once: the Nagle fix that the 90 gate needs, and the door loop the whitelist profile needs.
   Answer the microphone prompt on the phone once if it is asked.
2. **Re-run the blackout gate on v3** with the corrected stall value — 60 bundles, eight windows,
   1-2 minute cuts — and record what `util_carried` does against the 90 gate and the printed
   per-window ceiling. This is the number the original goal is waiting on.
3. **Run the whitelist profile** and record its three numbers, with the negative controls and the
   queue-off proof in the row. Check first that the runner's dry mode prints what you expect.
4. **Then the widening**: start the permitted door at one kilobyte, grow it on the same path
   until the call stands, and record what each step buys. The profile built here is the
   instrument that measures each step.

Two things to know before touching the rig, both learned the hard way this session and both in
the knowledge tree: every stage of a monitor pipeline must flush per line or the events sit
invisible in a buffer, and a stopped runner is only stopped when `pgrep` shows nothing AND the
shaper's status shows no pipes — the printed cleanup line is a claim, not evidence.
