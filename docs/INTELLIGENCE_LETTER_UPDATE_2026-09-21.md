# The offline intelligence must learn the letter — what to update, and with which numbers (2026-09-21)

A brief for the chat that owns `apps/reference_app/lib/src/intelligence/`.
It names what exists, what the letter added on 2026-09-20/21 that the
intelligence does not see, the decisions it should now make, the seams to
plug into, and the measured numbers it may reason from. Every number is
from a rig row or a command run on 2026-09-21; nothing here is a guess.

## 1. What the intelligence is today (read before touching)

`IntelligenceStack` (`intelligence_boot.dart`) = `IntelligenceHub` +
`ConnectionFabric` + `IntelligenceDirector`, booted before the first frame
from `main.dart` (`bootIntelligence(localLinkLane:, storageDirFactory:)`),
brains restored from `DiskJsonStorage`.

- `IntelligenceHub.recordObservation(quality, slope, nowMs)`,
  `recordDelivery(success, choice, …)`, `recordCallEnd(predictedConnectMs, …)`,
  `noteNetworkChange(fromLabel, toLabel)` — the inputs.
- `IntelligenceDirector` — advisories (`calm / caution / critical`) and
  three strategies: `refreshPaths` (reactive), `preWarmFallback`
  (pre-emptive), `holdAndObserve` (restraint); decisions carry an outcome
  (`pending / improved / noEffect`).
- `ConnectivityPlaybook` v1 — fixed knowledge (`voiceRttBudgetMs = 150`,
  `concealableLossPct = 3.0`, `liveHealthOverMemoryWeight = 0.8`) that the
  narration cites.
- In `packages/connection_orchestrator`: `MicroLearner`, `LaneExperience`
  (place-keyed lane memory → `forecastBias` in the fabric's ranking),
  `TrendMonitor`, `DeliveryPlanner` (`credibleFloor = 0.2`, urgent traffic
  replicates over live lanes, `deadLaneScore = −1 − penalty·rank`).
- `GemmaLlmEngine` — the optional on-device LLM (`flutter_gemma` / llama.cpp
  FFI, `modelPath`), used for narration, not for lane decisions.

Everything above sees the CALL: the call's fabric, its lanes, its quality.

## 2. What it does not see: the letter (built 2026-09-20/21)

A second, separate carrier now exists beside the call, with its own fabric
and its own decisions, and the intelligence has no input from it and no
say in it:

| piece | where | what it decides on its own today |
|-------|-------|----------------------------------|
| `LetterCourier` | `lib/src/letter_courier.dart` | its own `ConnectionFabric` from `defaultBorderRelayEndpoints()`; policy live lane → door → queue; select 60 s / carry 120 s budgets; liveness = eligible and score > −1.0 |
| parts | `lib/src/letter_parts.dart` | a payload over 4096 B goes as ≤ 10 letters of 4067 B; `partsInFlight = 3`; `partRetries = 2` per index; door drop parks the whole letter |
| photo ladder | `lib/src/photo_letter_picker.dart` | `photoLetterMaxBytes = 40000`; edges 640…48 px; qualities 75…20; takes the largest edge that fits |
| voice | `lib/src/voice_letter_recorder.dart` | `voiceLetterMaxLength = 30 s` (Codec2 700C ≈ 100 B/s) |
| queue / ledger | `letter_queue.dart`, `letter_ledger.dart` | a parked letter waits for a door-up tick (12 s cadence, one deliver per tick) |
| the door's own health | `TxtQueryLane` | probe per refresh; `isDown` after `failThreshold` (20) failures; `lastSessionId`, `attempts`, `replies` |

The rig peer (`integration_test/journey_peer_app.dart`) mirrors the courier
for measurements; it is not a product surface.

## 3. Decisions the intelligence should now make (in order of value)

1. **Carrier choice per message** — call channel (live, in-call chat) vs
   letter through the door vs park in the queue. Inputs: the call fabric's
   snapshot, the letter fabric's snapshot (`LetterCourier.laneSnapshot`),
   the WAN probe, the person's intent (a letter is deliberate). Output: a
   `LetterPolicy` (new, §4) that the courier consumes.
2. **Media shape for the budget** — given the ten-letter ceiling (40670 B)
   and the door's measured throughput, pick the photo rung (edge × quality)
   and the voice/video length, and SAY the cost before Send: "this is N
   letters, about T s". Today the ladder simply takes the largest that fits
   and says nothing about time.
3. **Parts window and retries** — `partsInFlight` 3 and `partRetries` 2 are
   constants. The intelligence has the signals to tune them: per-part
   outcome and latency (courier notes `carried letter i/N try k`), reply
   quiet time (`doorLine` uses 15 s), place memory. Rule of thumb from the
   rig: window 3 when replies come within ~1 s per chunk and no retries;
   drop to 1 when a retry appears; never above 5 (the responder's session
   table and the phone's UDP sockets).
4. **Park vs keep trying** — the courier parks on the first
   `queuedForLater`. With place memory ("this door came back within 2 min
   here before") the director can choose `holdAndObserve` with a short
   re-probe instead of a 12 s tick, or park at once when the place says
   the door stays down.
5. **Progressive delivery** — when the estimate says > 20 s, send a tiny
   preview letter first (not built yet; the parts format allows a separate
   letter id). The intelligence owns the threshold.
6. **Learning from outcomes** — feed the ledger and queue back:
   `recordDelivery(success, choice: 'door'|'live'|'parked', …)` per letter,
   plus a new per-place door record: bytes/s achieved, parts lost, time to
   `arrived`, time parked before door-up.

## 4. Seams to plug into (what to change, where)

- **New `LetterPolicy`** (value object) consumed by `LetterCourier`:
  `partsInFlight`, `partRetries`, `select`/`carry` budgets, `preferDoor`
  (skip the WAN select loop when the place says the WAN is dead), and
  `mediaBudgetBytes` for the picker/recorder. Constructor-injected with
  today's constants as the default, so nothing changes until the
  intelligence sets it.
- **`LetterCourier` → hub**: on every `_set(...)` transition, call
  `hub.recordDelivery(success: state == arrived, choice: 'door'|…)`; on
  every refresh, feed `laneSnapshot` into the same `recordObservation`
  path the call uses (quality = the door's score mapped to 0..1).
- **`photoLetterMaxBytes` / `voiceLetterMaxLength`** become inputs from the
  policy (the constants stay as defaults); the Send window shows the
  estimate "N letters · ~T s" from `bytes ÷ 4067` × measured
  seconds-per-letter.
- **`ConnectivityPlaybook` v2**: add the door's numbers (§5) as cited
  knowledge and bump `version`.
- **`IntelligenceDirector`**: a fourth strategy `carryAsLetter` (the call is
  gone or degraded beyond `voiceRttBudgetMs`/loss; offer the letter) with
  its own cooldown and outcome tracking.
- **`LaneExperience`**: key the door by place like the other lanes; record
  `arrived`/`parked` and bytes/s.
- **Foresight card**: one line for the letter: "door up · N letters ≈ T s"
  or "door down · parked, k waiting".

## 5. Numbers it may reason from (all measured)

| quantity | value | source |
|----------|------:|--------|
| cap per letter | 4096 B | `TxtQueryLane.maxPayloadBytes` |
| parts, max | 10 → 40670 B payload | `letter_parts.dart` |
| door liveness | eligible and score > −1.0 (fresh door sits at −0.14) | `e71a2d5`, measured on the phone |
| seconds per letter on the rig, LETTER_ONLY | ≈ 3.5 s (7 letters 29.6 s, 10 letters 35.5 s) | TSV rows F60FAE2F, 5EA44971 |
| one-letter runs | 25–27 s row time, ≈ 1 s carry | CWPVWY, PD5O4O, JRZTMU |
| text | ≤ 4096 B bare | — |
| voice, Codec2 700C | 30 s ≈ 2538–2626 B (~87 B/s + header) | PD5O4O, MDB52T |
| photo, JPEG ladder | 296×640 = 38045 B (10 letters); 480×640 = 26030 B (7); 92×200 = 3372 B (1) | 5EA44971, F60FAE2F, OEVTLL |
| video, SVT-AV1 preset 8 + 700C, 128×96@3fps crf 40 | 704–1185 B/s → 34–57 s in ten letters | `measure_video30.sh`, 2026-09-21 |
| video, 96×64@3fps crf 50 | 351–526 B/s → 77–115 s | same |
| video, 64×48@2fps crf 63 | 168 B/s → 241 s | same |
| door probe cadence | 12 s (select loop and queue watch) | courier |
| responder's part deadline | 600 s | `txt_query_server.py` |

## 6. Failure modes it should know (so it does not learn them the hard way)

- A freshly answering door scores −0.14; "score > 0" parked a good letter
  for 200 s (fixed in `e71a2d5`). Liveness is the fabric's dead-lane rule.
- The rig's arm-time gate refused a 26030 B Mac letter with "exceeds the
  lane limit 4096" until it learned about parts (`91fda95`).
- A part refused once is not a dead door: retry the index (3 tries), then
  give up on the letter; a `queuedForLater` IS a dead door: park.
- A letter parked and re-sent later gets a fresh id; the responder drops
  the stale half after 600 s. Do not try to resume an old id.
- Nothing in the letter path may open a new port, change the cap, or talk
  to a public domain; the door's zone and resolvers come from the build.

## 7. Not in scope for the intelligence chat

Video on the phone (no on-device encoder yet), a trim UI, HEIC/AVIF codecs
(measured only on the Mac so far), progressive preview. Those are product
work; the intelligence only needs the seams above so it can steer them
when they land.
