# Consultation brief for Sol — voice_call_kit_v3: resilience stack + record-low-byte voice

Register: model-to-model, dense, no ceremony. Every number below is measured in-repo
(tools/*, 2026-07-24, Intel x86 mac, CI gate `tools/run_gate_loop.sh` green, fatal-infos).
Honesty flags inline. We want your independent critique + concrete upgrade moves per
section, with special weight on §6 (the record attempt).

## 1. Where we are — shipped deterministic stack (Dart monorepo, Flutter app)

- `ConnectionFabric`: owns every lane (internet/localPeer/carrier). Per delivery,
  `DeliveryPlanner.plan → {singleBest|raceFanout|replicate|queueOnly}` over blended
  score: `hW*liveEWMA + lW*UCB(place,daypart) − costPenalty*costRank −
  (lowBattery? energyPenalty*energyRank : 0)`.
- Foresight: `TrendSentinel` — least-squares slope over per-lane score samples →
  `steady|slipping|failingSoon`. Wired into: (a) planner: `bestLaneSliding →
  raceFanout` (dual-send opens BEFORE the predicted drop; bulk never duplicated);
  (b) `IntelligenceDirector` (ChangeNotifier): decision journal
  {strategy, reason, judged outcome}, strategies {refreshPaths, preWarmFallback,
  holdAndObserve}, exponential cooldown backoff ×2..×8 on judged-ineffective repairs;
  (c) `SurvivalModeDriver.pathFailingSoon` (see §5).
- DTN: durable `DtnBundleQueue`, `deliverChunked` = resumable chunked transfer
  (only missing chunks re-sent; XOR parity chunk per 4-group heals 1 loss/group
  w/o retransmit; exact tail length via `@bytes` in parity id; chunk size adaptive
  to best-lane score 2–64KB; `refresh()` self-resumes in-flight transfers).
- `CarrierRelay`: custody store-carry-forward with spray-and-wait (copy budget,
  binary split, wait-phase = destination-only), summary-vector dedup on repeat
  contact, per-peer custody quota, TTL prune, JSON persistence.
- `WeakLinkCodec`: varint coalescing (~1B/msg overhead), compress-only-if-smaller
  zlib flag byte, XOR `ParityGroup`.
- `DeliveryLedger`: bounded id set; receive-path dedup (dual-send/replicate/relay
  → one bubble). App wiring: chat text taps fabric.deliver; attachments tap
  fabric.deliverChunked (best-effort, never blocks the user send).
- On-device LLM lane: `IntelligenceHub.start` (static, hydrates 2 persisted brains:
  `LaneExperience`, `MicroLearner` place×network EWMA forecasts),
  `ConnectivityPlaybook` (versioned in-code expert insights, ONE matched insight per
  snapshot — measured: rulebook prompts DEGRADE small models). Model bake-off
  (5 hard app-domain tasks + 15-step crisis gauntlet): deterministic planner 29pts/0
  lost vs best LLM (qwen3:1.7b) 20/3 lost → judgment stays in code, LLM narrates.
  Bundled model choice: qwen3-0.6b int4 litertlm 475MB (fits 500MB install budget).
- Evolution bench (`tool/evolve_planner.dart`): random crisis timelines drive the
  REAL fabric; genome = 6 planner/sentinel constants; held-out validation +3.9%
  over defaults on 80 unseen scenarios (found: healthWeight↑0.8, raceMargin→~0
  once foresight dual-send exists). Not yet adopted into defaults (bench biased
  toward cold learner — short scenarios undervalue the UCB memory).

## 2. Where we are going

International consumer messenger + voice app whose brand promise is: the call
NEVER dies — it changes shape. Degradation ladder (all shipped except the last
rung): live Opus → adaptive bitrate ladder → low-rate voice → voice-note clips
over DTN (foresight-triggered pre-emptively) → [target rung] record-low-byte
live-ish voice. Remaining engineering debt, ranked: physical device bindings
(dated blocker: needs hardware), sealed relay payloads (e2e encryption of
custody bundles), causal ordering after partition merge (vector clocks).

## 3. HamSeda — the record lane, measured so far

Original layers (all LOSSLESS w.r.t. whatever backbone carries the audio):
1. Twin self-learning codebook: both ends append every full spectral vector that
   crossed the wire, same deterministic rule → zero sync bytes; novel sound paid
   once, then index-only.
2. Cross-call persistent memory: call 2 encoded with call 1's grown book:
   −21.1% bits, identical decode path (measured, real speech).
3. Personal Morse layer: Huffman over the speaker's sound-index stream:
   8 → 5.28 avg bits (entropy floor 5.24 — at the bound), −6.7% lossless.

Carrier today (prototype-grade quality): LPC-10 vocoder, 8kHz/40ms, VAD,
innovation gate, delta frames. Real user recording 13.6s: 936 wire bytes =
552bps avg (480 tail) = 21.1% under Codec2 700C. Audible quality: robotic
(spectral corr proxy 0.205 on real voice) — NOT public-app grade. HQ decoder
(continuous filter/pitch state, mixed excitation) helps clicks, not timbre.

Essence lane (restore-to-original): local ASR (whisper base) → gzip text+prosody
→ 135 wire bytes for the same 13.6s = 79bps = 89% under record; receiver
regenerates natural speech via local TTS. Demo ceiling: receiver voice engine
matched the speaker exactly in the synthetic demo; for real users needs cloned
voice signature (few MB, transferred once) + bigger ASR (base model misheard
words). Both sit behind the existing device_bindings seam.

## 4. The mature two-lane architecture (current thesis)

- Quality lane: neural codec backbone on-device (Lyra-class ~1–3kbps, public-app
  MOS) — NOT ours, downloaded like the LLM model.
- Record lane: our 3 lossless layers applied in the backbone's TOKEN domain
  (recurring token n-grams per speaker → growing shared dictionary → indexes;
  Huffman/arithmetic over indexes; persisted per-contact). Claim: same MOS as
  backbone, measured −21%+ bits and growing with relationship. Fallbacks down
  the ladder: vocoder lane (552bps, any language) → essence lane (79bps, needs
  ASR+TTS coverage; language-limited) — never silence.

## 5. Call-survival wiring (context for §6)

`SurvivalModeDriver`: ladder-floor → lowRateVoice mode; flapping (2 reconnect
episodes/60s) → voiceNotes mode (clips ride reliable outbox + durable per-call
DTN store, flushed on reconnect); `stableFor` 30s clears; NEW: foresight stream
(fabric trend failingSoon on live media lane) enters voiceNotes BEFORE the drop,
idempotent, connected-only. Tests: fakeAsync, deterministic.

## 6. THE ASK — questions for you, ranked (last section = the reason we consult)

A. Record lane, hard critique: is the twin-codebook + per-contact persistent
   dictionary + entropy layer stack sound against: codebook divergence under
   packet loss (we assume reliable-ordered control for full frames — is that
   assumption fatal on UDP-like lanes? design a loss-tolerant codebook-growth
   rule), replay/poisoning of the shared book, and memory growth bounds per
   contact?
B. Token-domain LZ over neural-codec tokens: prior art check — does anything
   ship per-speaker persistent token dictionaries across calls? If genuinely
   open, what's the strongest defensible formulation (n-gram dict vs online
   arithmetic coding with per-contact context model)? Estimate realistic % over
   a 1kbps backbone for 10-minute calls.
C. Quality floor with OUR vocoder (no neural backbone available offline): best
   known tricks to lift LPC-10-class intelligibility cheaply on CPU (mixed
   excitation params on the wire? postfilter? formant sharpening?) within
   ≤200bps overhead.
D. Essence lane: engineering the voice-signature transfer (size/one-shot
   protocol/consent UX) and the honesty question — should regenerated speech be
   audibly watermarked/labeled? Language coverage strategy when ASR/TTS is
   missing: is auto-fallback to vocoder lane the right UX?
E. The record CLAIM itself: what benchmark protocol would make "X% under
   Codec2 700C / under Lyra at equal quality" defensible publicly (test corpus,
   MOS methodology, bitrate accounting incl. dictionary amortization)? Design
   the exact experiment we should run before we announce anything.
F. Ladder policy: given measured planner-beats-LLM on routing, does voice-mode
   selection (which rung, when) also belong in deterministic code with the
   trend inputs, or is there a real role for the on-device LLM here beyond
   narration?

Constraints for all answers: on-device only (no server inference), Intel/ARM
phone CPUs, Dart-portable algorithms preferred, every identifier names its
literal function (architecture guard), standard transport stack (DTLS-SRTP /
WSS / DTN store-and-forward) is non-negotiable.
