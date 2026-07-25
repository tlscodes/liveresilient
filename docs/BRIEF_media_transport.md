# Brief — media transport (photo / video / document) — phased plan

Stage goal: the voice path already survives the measured field profile
(a few hundred bytes per second, 85-95% packet loss, multi-second delay,
tens-of-bytes MTU). This stage gives files the same property: a photo, a
short video, or a document must arrive intact over the same path, using
only the wire budget voice is not using.

Everything here is a normal file-transfer engineering problem: erasure
coding, image/video downsampling, text compression, and a background
queue with priority scheduling.

## How this plan runs

Six phases, each independently testable and independently shippable. A
phase is CLOSED only when its own tests are green AND the full gate is
green (`bash tools/run_gate_loop.sh`), then committed. No phase starts
before the previous one is closed. Phases 4a/4b/4c are the compression
pipeline and may run in any order once phase 3 is closed — they touch
disjoint files.

Every phase below names: what is built, the test file, and the exact
acceptance numbers the test asserts. Numbers marked `measure` are
recorded by the test's diagnostic line rather than pre-asserted; the
threshold is set from the first measured run and pinned afterwards.

---

## Phase 1 — Rateless code core (no network yet)

Build: `packages/connection_orchestrator/lib/src/rateless_stream.dart`
with `RatelessEncoder` / `RatelessDecoder`. An LT (Luby-transform) core
with a robust soliton degree distribution plus a systematic prefix: the
first N datagrams are the source blocks themselves, everything after is
XOR parity over a seeded pseudo-random block subset. Named for what it
is — full RaptorQ (RFC 6330) is a much larger piece of work and this is
the same zero-feedback family.

Wire: each datagram is 36-60 bytes, carrying `u16 esi · u16 blockCount ·
payload · u8 crc8`, reusing the CRC-8 polynomial already in
`micro_datagram_lane.dart`.

Test — `test/rateless_stream_test.dart`:
- round-trip with zero loss is bit-exact for 1 B, 100 B, 2 KB, 64 KB;
- decoding from a random subset in random order is bit-exact;
- a datagram with any single bit flipped is rejected, never decoded;
- overhead epsilon: distinct datagrams needed / N — assert `< 1.6`,
  measure and print the actual ratio;
- decoder memory stays bounded: feeding 20x more datagrams than needed
  does not grow its internal structures past N entries.

Closes when: the above are green plus gate loop green.

---

## Phase 2 — Rateless code over the hostile channel

Build: nothing new; wire phase 1 into the existing channel simulators.

Test — `test/rateless_hostile_test.dart`:
- 2 KB file over 95% uniform loss layered with `GilbertElliottLossSimulator`
  (mean 10-packet bursts) and up to 5 s jitter with reordering;
- assert the reconstruction is bit-exact;
- assert the receiver sent exactly 0 packets (a counter on the test's
  receiver, so zero-feedback is proven, not assumed);
- assert no unhandled exception on truncated/corrupted datagrams;
- measure and print: datagrams sent, delivered, epsilon, seconds of wire
  time at 300 B/s.

Closes when: green plus gate loop green.

---

## Phase 3 — Background queue with voice priority

Build: `lib/src/media_queue.dart` with `MediaTransferQueue` — emits
media datagrams only while `SilenceSuppressionVAD` reports silence, and
only up to a configured spare-budget cap (200-500 B/s). A transfer that
is interrupted resumes by emitting more parity; because the code is
rateless there is no state to renegotiate.

Test — `test/media_queue_test.dart`:
- during a speech window the queue emits 0 media datagrams;
- during silence it emits at or below the configured cap, never above;
- the voice-priority assertion, stated strictly: run the same voice
  schedule twice, once with a media transfer active and once without,
  and assert the voice datagram send ticks are IDENTICAL sequences;
- a transfer spanning many speech/silence alternations still completes
  bit-exact.

Closes when: green plus gate loop green.

---

## Phase 4a — Document compression

Build: `lib/src/media_codecs/text_document_compressor.dart` — extract
the text layer, discard layout and embedded resources, compress at the
maximum level available in-process (`dart:io` gzip today; a Brotli or
Zstandard binding is a dependency decision to make explicitly, not
silently).

Test — `test/text_document_compressor_test.dart`: round-trip is
character-exact for ASCII, Persian, and mixed text; compressed size on a
representative 10 KB text is measured and pinned; empty and 1-character
inputs are handled.

---

## Phase 4b — Photo compression

Build: `lib/src/media_codecs/low_rate_image_compressor.dart` — a very
low resolution progressive thumbnail (target ~1 KB, coarse levels first
so the receiver sees something after the first few datagrams), and a
contour-trace path serialized as SVG (target 300-800 B).

Test — `test/low_rate_image_compressor_test.dart`: output size is inside
the declared target band for several synthetic images; the progressive
form decodes at each prefix level without error; decoding is
deterministic. Note honestly in the test: this is lossy, so the
assertion is size plus structural similarity, never bit-exactness.

---

## Phase 4c — Video flipbook

Build: `lib/src/media_codecs/flipbook_video_compressor.dart` —
downsample to 120x80 monochrome keyframes at about one frame per three
seconds, target ~300 B per keyframe after compression.

Test — `test/flipbook_video_compressor_test.dart`: per-keyframe size
inside target; frame count matches the expected rate for a given input
duration; playback order is preserved through the rateless transport.

---

## Phase 5 — Full media integration

Build: `lib/src/resilient_media_transport.dart` — the facade tying
compression, the rateless code, and the queue together behind one API
(`send(file, type)` / `onReceived`).

Test — `test/resilient_media_transport_test.dart`: a photo, a flipbook,
and a document all transferred during a live 120-second call on the
hostile channel from the voice integration test, with voice unaffected.
Diagnostic line reports per-type compressed size, wire B/s used by
media, transfer completion time, and voice coverage — which must stay at
its phase-5 baseline, proving media never stole voice budget.

---

## Working rules (same as the voice stages)

- Implementation plus tests plus a green `bash tools/run_gate_loop.sh`
  before each commit; one commit per phase.
- Plain technical language in code and comments; describe behavior
  precisely, no metaphor.
- Measured numbers only. A simulated result is labeled as simulated.
- Lossy compressors never claim bit-exactness — that claim belongs only
  to the transport layer.
- Out of scope, as in the voice stages: making the traffic resemble any
  other protocol. The transfer is what it is.
