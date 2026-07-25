# Brief — ResilientMediaTransport (photo / video / document transfer)

Stage goal: the voice path already survives the measured field profile
(a few hundred bytes per second, 85-95% packet loss, multi-second delay,
tens-of-bytes MTU). This stage gives files the same property: a photo, a
short video, or a document must arrive intact over the same path, using
only the wire budget voice is not using.

Everything here is a normal file-transfer engineering problem: erasure
coding, image/video downsampling, text compression, and a background
queue with priority scheduling.

## 1. Rateless erasure coding (`RaptorQEncoder` / `RaptorQDecoder`)

A fountain code turns a file into an unlimited stream of parity
datagrams. Any sufficiently large subset reconstructs the file, so the
sender never needs to know which datagrams were lost.

- Datagram size 36-60 bytes, each with a 1-byte CRC-8 trailer, matching
  the existing `SlidingWindowPacker` wire discipline.
- Send-only: no acknowledgements, no retransmission requests, no round
  trips. The sender emits parity blocks until the caller stops it. This
  is required because the one-way delay of 3-5 seconds makes any
  request/response loop slower than the transfer itself.
- The decoder reconstructs the exact original bytes once it has received
  roughly N x (1 + epsilon) distinct datagrams, where N is the number of
  source blocks. Overhead epsilon is measured and reported by the test,
  not assumed.
- Implementation note: a full RaptorQ (RFC 6330) systematic code is a
  large piece of work. Start with an LT/Luby-transform core with a
  robust soliton degree distribution plus a systematic prefix, which is
  the same family and gives the same zero-feedback property. Name it for
  what it actually is.

## 2. Compression pipeline (make the file small before coding it)

At 300-600 bytes per second, a 2 MB photo is not a transfer, it is an
afternoon. Each media type gets an aggressive reducer:

- `VectorImageCompressor` — reduce a photo to a small set of traced
  contours serialized as SVG paths (target 300-800 bytes), or a roughly
  1 KB very-low-resolution thumbnail sent progressively so the receiver
  sees something immediately and detail improves as more arrives.
- `FlipbookVideoCompressor` — downsample video to 120x80 monochrome
  keyframes at about one frame every three seconds (target ~300 bytes
  per keyframe), played back as a flipbook. This is a deliberate quality
  floor, not a codec: motion is conveyed by the sequence of stills.
- `TextOnlyBrotliCompressor` — extract the text layer of a document,
  discard layout and embedded resources, then compress at the maximum
  Brotli/Zstandard level. A PDF's text is usually a small fraction of
  its bytes.

Each compressor is a pure function from input bytes to output bytes with
a declared, test-pinned size target, so the pipeline can be measured.

## 3. Background queue and voice priority (`DTNMediaQueue`)

Voice always wins. Media rides only the leftover budget.

- The queue emits media datagrams only during silence windows reported
  by `SilenceSuppressionVAD`, and only up to a configured spare-budget
  cap of 200-500 B/s.
- When the voice activity detector reports speech, media transmission
  stops on the same tick. The scheduler must never delay a voice
  datagram behind a queued media datagram — the test asserts that voice
  send timing is bit-identical with and without media streaming in the
  background.
- Progress survives interruption: because the code is rateless, a paused
  transfer resumes by simply emitting more parity, with no state
  negotiation between the two ends.

## 4. Tests (`test/resilient_media_transport_test.dart`)

- 2 KB file over a 95% uniform-loss channel combined with the existing
  `GilbertElliottLossSimulator` (mean 10-packet bursts) and up to 5 s of
  random jitter with reordering.
- Assert the reconstructed file is bit-exact, and that the receiver sent
  zero packets of any kind (a strict count, not an inspection).
- Assert every voice datagram keeps its exact send tick while media
  streams in the background.
- Report measured numbers: datagrams sent, epsilon overhead ratio,
  effective media throughput in B/s, and compressed size per media type.

## Working rules (same as the voice stages)

- Implementation plus tests plus a green `bash tools/run_gate_loop.sh`
  before each commit.
- Plain technical language in code and comments; describe behavior
  precisely, no metaphor.
- Measured numbers only. A simulated result is labeled as simulated.
- Out of scope, as in the voice stages: making the traffic resemble any
  other protocol. The transfer is what it is.
