# LiveResilient

A calling and messaging kit that keeps working when the network barely does.
Voice, text, images, voice notes and short video notes are carried over
standard WebRTC media and a rateless transport lane, and every capability is
gated on a measured byte and time budget rather than on an opinion.

The design target is a link at **2 kbit/s with 60% packet loss and a 2-second
round trip** — conditions under which mainstream messengers do not complete a
single transfer.

## What is measured, and where the numbers come from

Every number below was produced by a script in this repository and is
reproducible with the command next to it. Nothing here is an estimate.

### Compression, measured on a fixed corpus (`tools/phase5/h3_results.tsv`)

| Feature    | Original   | On the wire | Wire time @2 kbit/s | Status |
|------------|-----------|-------------|---------------------|--------|
| Text       | 39 B      | **29 B**    | 0.1 s               | PASS |
| News page  | 3,330 B   | **1,160 B** | 4.6 s               | PASS |
| Photo      | 2,355,465 B | **2,682 B** | 10.7 s            | PASS |
| Voice note (10 s) | 320,078 B | **879 B** | 3.5 s        | PASS |
| Video note (5 s)  | 2,657,132 B | **5,926 B** | 23.7 s   | PASS |
| Push-to-talk (60 s) | 1,920,000 B | **5,220 B** | 20.9 s | PASS (codec2-450) |

```bash
bash tools/phase5/goal_verify.sh     # re-runs every gate; exit 0 means the table above still holds
```

### End-to-end on a physical iPhone (`tools/dossier/e2e_ios_results.tsv`)

Same six features, running on an iPhone over a shaped link, each inside a
budget derived from the link physics rather than chosen by hand:

| Feature    | Budget | Measured | Status |
|------------|--------|----------|--------|
| chat       | 4.8 s  | **2.5 s**  | PASS |
| news page  | 52.3 s | **17.0 s** | PASS |
| voice note | 42.3 s | **13.9 s** | PASS |
| photo      | 49.6 s | **23.2 s** | PASS |
| video note | 82.0 s | **45.4 s** | PASS |
| push-to-talk | live | 60 s session, 10 of 60 bundles | PASS (liveness only) |

These rows are **measured on a device, not on CI**. A CI runner cannot shape a
radio link, so the workflow does not pretend to reproduce them; the reproduction
script for a reviewer with their own hardware is
`tools/dossier/reproduce_conditions.sh`.

The push-to-talk row is judged differently from the five above it and we would
rather say so than have it found. Its rule is liveness — the lane stayed up, the
decoder raised no fault, at least one bundle arrived — and on the recorded run
10 of 60 bundles arrived with a 40.7-second gap. It shows a live voice lane
survives the profile; it does not yet show usable continuity. The rule is in
`apps/reference_app/integration_test/e2e_matrix_test.dart`, and the row is
labelled `PASS/LIVENESS` in `tools/dossier/e2e_ios_results.tsv` so the
distinction survives being copied out of this table.

### Transport survival (`tools/t2/h2_results.tsv`)

The transport layer is separately gated across a 24-row matrix of impairment
profiles — voice, messaging and video, each from a clean link down to 60% loss
and to a 2 kbit/s bandwidth ceiling. The file is append-only and keeps every
run this project has made, failures included; `tools/t2/report_matrix.py`
reduces it to the latest verdict per cell, and all 24 cells pass.

The clearest pair of rows in it is the 4 MiB video at 60% loss, before and
after the lane changed:

```
row 266-267   reliability-managed channel   abandoned at 790 s, 0 kbps,
                                            172 of 1,158 and 587 of 2,814 symbols
row 268-269   rateless lane over plain UDP  4,194,304 B hash-verified,
                                            303.6 s at 111 kbps · 314.7 s at 107 kbps
```

## How it works, briefly

- **Media**: standard WebRTC — ICE, STUN, TURN, DTLS-SRTP. No custom
  cryptography.
- **Bulk transfer on lossy links**: a rateless lane (systematic random linear
  network coding over GF(256)). Loss costs proportional extra symbols instead
  of a round trip, which is why a 60%-loss link still completes a transfer.
  It runs over plain UDP because a loss-reactive congestion controller
  underneath does not recover at that loss rate: the same transfer was
  abandoned twice at the time limit with the recorded rate at zero
  (`tools/t2/h2_results.tsv`, rows 266-267). That collapse is measured, not
  assumed.
- **Codecs**: purpose-built ultralight paths per medium — a dictionary-trained
  text codec, CBOR + Brotli for pages, AVIF for images, Codec2 for speech, and
  raw AV1 with a 12-byte header for video notes (no container: an MP4 header
  alone would exceed the whole budget).
- **Gates**: every claim in this repository is tied to a test. CI enforces that
  a declared gate reaches a real test, that the count of unproven gates never
  rises, and that verification commands do not truncate their own output.

## Repository layout

```
apps/reference_app/     Flutter app shell and the on-device test matrix
packages/               call core, media, signalling, transport, codecs
server/                 signalling server and the datagram forwarder (AGPL-3.0)
tools/phase5/           corpus, byte-budget gates, results table
tools/t2/               link-shaping rig and the transport matrix
tools/dossier/          evidence collection and reviewer reproduction scripts
docs/                   architecture, threat model, engineering handbooks
```

## Running it

```bash
dart pub get
dart analyze                          # infos are fatal
bash tools/run_suites.sh              # the full suite; logs under tools/suite-logs/
bash tools/phase5/goal_verify.sh      # the byte-budget gates
```

Building for a device needs the native codecs; see `tools/phase5/gates/` for
the build steps each gate expects.

## Status and honesty

- Phase 5 (the ultralight codec layer) is complete: 6 of 6 gates green.
- The transport matrix is complete: 24 of 24 rows green.
- The on-device matrix is complete: 6 of 6 features inside budget.
- **No independent security audit has been performed.** See `SECURITY.md`
  for the trust boundaries, including the two known gaps: the datagram lane
  has no end-to-end encryption layer of its own yet, and the prebuilt WebRTC
  binary is outside our audit surface.

## Licence

Apache-2.0 for the client and all reusable packages; AGPL-3.0 for `server/`.
Running a modified server as a network service means publishing those changes;
clients that merely talk to a server are unaffected. See `CONTRIBUTING.md`
for the DCO sign-off used on contributions.

One exception is worth stating rather than burying. `packages/pt_transport_darwin`
is Apache-2.0 for its own source, but it ships a prebuilt binary framework whose
engine is not yet published as source, as do the two committed Android
`libpt_transport.so` files. A reader cannot reproduce those binaries from this
repository today. Publishing that engine under the same licence is tracked work,
and until it lands the binaries carry the caveat set out in `SECURITY.md`.
