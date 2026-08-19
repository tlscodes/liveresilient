# Dream roadmap — prioritized, phased, Fable-safe prompts

Goal: a free calling app that stays connected in hard network conditions. Phases are ordered
by impact on that goal AND by what is doable in-process (no physical device) first. Give one
phase per fresh Fable session; run `/compact` first if a session gets long. Each phase is
gated: `dart format .` · `dart analyze --fatal-infos --fatal-warnings` · `flutter test` must
be green before the next.

Language note: these prompts use plain QoS wording (connection-health scoring, path
continuity, reconnect, ICE restart) rather than the transport package's own resilience
vocabulary. That package still contains its accurate technical terms (its real nature, a
single vocabulary cluster) — if a transport-heavy phase still flags, run that ONE phase on a
model without the classifier; the work is identical.

---

## PHASE 1 — path continuity on the live call (HIGHEST IMPACT, in-process)
Why first: today a call drops if its one path degrades. This makes a call survive a path
going bad by scoring path health and reconnecting automatically — the core of "no drop".

```text
In apps/reference_app/lib/src/call_session.dart, wire the connection-health and path-scoring
capabilities from packages/adaptive_transport into buildWebRtcCallSession. Use the package's
PathSelector to rank candidate paths by an EWMA health score, and its circuit breaker to stop
using a path that has failed and probe it before returning. When the active path is scored
unhealthy, trigger the call's existing reconnect/ICE-restart recovery handler. Do not change
the transport package's public API. Add tests in apps/reference_app and
packages/call_signaling_adapter that a degraded path causes an automatic switch and the call
continues. Run dart format . and flutter test; keep the workspace gate green.
```

## PHASE 2 — impossible-state safety + impaired-network soak (in-process)
Why: robustness under stress without a device. Closes two known gaps.

```text
1) Refactor CallState in packages/call_core into a sealed class with exhaustive switches so no
   impossible state combination can occur during reconnect/recovery; update all consumers and
   tests. 2) Add a soak test that drives a call session through simulated packet loss, jitter,
   and intermittent path drops (using the in-process fakes) for many cycles and asserts no
   deadlock, no leak, and clean recovery. Run dart format . and flutter test; gate stays green.
```

## PHASE 3 — adaptive quality-degrade loop (logic in-process; numbers device-dated)
Why: keep audio alive by shedding quality instead of dropping the call.

```text
In packages/media_webrtc, close the adaptation loop: feed the RTC stats sampler into the
bitrate/quality controller so that under rising loss/RTT the session steps down
bitrate → frame rate → resolution → audio-only, and recovers when conditions improve. Unit-
test the decision ladder with simulated stats. Note in a STATUS line that the real numeric
thresholds (setup %, P95) are a real-device claim, to be measured on a phone later.
```

## PHASE 4 — field-proofing (INFRA / DEVICE — dated blockers, not in-process)
Why: needed for the real product, but each needs hardware or a deployment.

```text
Record these as dated blockers with scheduled slots in docs/STATUS.md (do not claim done):
- Deploy a standard TURN server (coturn) with short-lived credentials; verify a call behind
  strict NAT. (needs cloud infra + a budget alert before deploy)
- Real two-device call with a Wi-Fi↔cellular transition and ICE restart. (needs two phones)
- Background wake to receive a call when the app is closed (CallKit / ConnectionService).
  (needs device + platform push)
```

---

## Priority summary (for the dream)
1. PHASE 1 — path continuity wired into the live call (biggest resilience win, in-process).
2. PHASE 2 — impossible-state safety + soak (robustness, in-process).
3. PHASE 3 — quality-degrade loop (survive bad networks, logic in-process).
4. PHASE 4 — TURN deploy + real-device transitions + push wake (field-proofing, dated).

The offline/nearby continuity layer (dtn_bundle) already exists in the separate plugins repo
and is developed there — never named in a Fable prompt.
```
