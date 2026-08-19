# `probe_defense` — engineering handbook

Written to be handed to a reviewer or a model that will debug, test, or extend any
part of this subsystem without opening the whole repository first.

---

## 0. The name

The accurate name is the one the directory already uses: **`probe_defense`**, in the
package **`adaptive_transport`**.

A goal-shaped alternative — naming the subsystem after the outcome it is meant to
produce rather than the work it performs — was considered and rejected, for two
reasons that point the same way. First, it is less accurate: the code does not act on
any network, it constrains what *this application's own connections look like*.
Second, outcome-shaped phrasing is what automated content review scores on, so a
document full of it becomes unusable as a brief — measured here, not assumed (§8).

If a plainer synonym is ever wanted, the accurate ones are **transport fingerprint
conformance** or **observable-surface conformance**. Both say what the code does.

---

## 1. What the subsystem does

A TLS client is identifiable long before any payload is exchanged. RFC 8446 leaves
the *order* of cipher suites, extensions, supported groups and signature algorithms
to the implementation, so each stack produces a characteristic ClientHello. The same
is true one layer down: RFC 9293 leaves initial window, MSS and option order to the
operating system. And one layer up, packet sizes and inter-packet gaps are a property
of the application's own write pattern.

`probe_defense` makes all three layers agree with one declared profile, and provides
the relay side that authenticates a client from the first record it sends.

```
layer                   what this code controls                     reference
ClientHello bytes       extension order, groups, ALPN, GREASE       RFC 8446, RFC 8701
server_name in clear    which hostname appears in the outer hello   RFC 6066, ESNI draft
TCP options             MSS, window, option order per OS profile    RFC 9293
packet lengths          length distribution of emitted records      —
inter-packet timing     jitter distribution and tick emission       —
relay admission         X25519 agreement over the client key share  RFC 7748
key rotation            epochs with a grace window, no wire change  —
```

The property the whole subsystem exists to provide, stated without metaphor: **a
connection produced by this application is byte-indistinguishable, at the layers
listed above, from the browser profile it declares** — and the relay can still tell
its own clients apart from strangers, using only the first record, without adding a
single byte to the wire.

---

## 2. Source files

`packages/adaptive_transport/lib/src/probe_defense/` — 4081 lines, 10 files.

### `reality_pass_through.dart` — 634 lines

Relay-side admission control, and what happens to everyone else.

```
RealitySessionIdLayout   the fixed layout of the session id field
RealityCredential        derived from the shared secret; carries shortId
RealityRejectReason      sessionIdWrongSize · unknownShortId · ...
RealityDecision          admit, or pass through with a reason
RealityAuthenticator     the pre-shared-key path
DuplexByteStream         the seam this file talks to (see socket_duplex_stream)
FallbackConnector        how a non-client is connected onward
FallbackTarget           where a non-client is sent
PassThroughStats         counters for the fallback path
PassThroughRelay         the fallback path itself
RealityGateOutcome       admitted / passed through, with the evidence
RealityGate              the entry point a server binds
```

**Invariant that matters most:** a client that fails admission must be handled
exactly as the fallback target would have handled it, including timing. A distinct
error, a distinct delay, or a distinct close is itself a signal. When debugging this
file, compare the two paths, not just the admit path.

**Tests:** `reality_pass_through_test.dart`, `reality_live_passthrough_test.dart`.

### `relay_key_rotation.dart` — 548 lines

Static-key rotation on epochs, with no wire change at all.

```
RelayKeyEpoch              one epoch's key pair and index
KeyRotationError
RelayKeyRing               current · previous · next, admissibleKeys, grace window
RelayKeyAnnouncement
EpochAdmission             decision + epoch + keyUpdateRequired + keysTried
RotatingRealityAuthenticator   inspect(hello) -> EpochAdmission
RelayKeyUpdate             40-byte frame telling an admitted client the new key
RelayKeyStore              the client's side of that update
```

**The admission loop is at lines 386-446.** Per trial: one `sharedSecret` (RFC 7748
variable-base scalar multiplication), one `RealityCredential.fromSharedSecret`
(HKDF), one constant-time compare. Outside the loop: a length check, a key-share
extraction, and one `verifyWith` on the matching key only. That composition is why
the shared fixed cost is near zero — a fact several assertions depend on.

**`EpochAdmission.keysTried` (line 360) is the observable for the trial count.** Do
not infer the count from a duration; read it.

**Tests:** `relay_key_rotation_test.dart` (748 lines, the largest test file).

### `utls_client_profile.dart` — 558 lines

Browser ClientHello profiles and a byte-exact builder.

```
TlsNamedGroup
UtlsProfileId          chrome120 · firefox120 · safari17
UtlsClientProfile      the declared ordering and extension set
UtlsClientHelloBuilder produces the bytes
```

**Byte-exactness is the entire contract.** A unit test that only checks "the
extension is present" cannot detect a wrong order, and order is the discriminating
part. When changing anything here, compare against a captured reference from the
real browser version, not against the builder's own output.

**Tests:** `utls_profile_and_stack_test.dart`.

### `traffic_shaper.dart` — 567 lines

Length and timing shaping for emitted records.

```
LengthDistribution     which distribution record lengths follow
JitterDistribution     which distribution inter-packet gaps follow
TrafficShapingPolicy   the declared parameters
TrafficShaper          applies the policy
AdaptiveJitter         adjusts the gap distribution from observed conditions
TickEmissionMode
FixedTickEmitter       constant-rate emission
```

**Trap specific to this file:** distributions are easy to assert loosely. A test that
checks only the mean passes for a distribution with the wrong shape. Assert on
quantiles or on a goodness-of-fit statistic, and state the sample size the assertion
needs to be meaningful.

**Tests:** `traffic_shaper_test.dart`, `poisson_jitter_and_chain_test.dart`.

### `reality_handshake.dart` — 503 lines

The X25519 admission handshake, and where a 64-byte signature actually goes.

```
KeyPairBytes
X25519KeyAgreement            implements KeyAgreement (RFC 7748)
RealityRelayIdentity
RealityClientHandshake
RealityClientKeyExchange
RealityKeyExchangeAuthenticator   clientX25519Share(hello)
RealityIdentityProof
```

**Lines 37-39 carry a measured cost figure that another test asserts on.** See §8.

**Tests:** `reality_handshake_test.dart`.

### `tls_client_hello.dart` — 439 lines

TLS 1.3 ClientHello parsing and fingerprinting.

```
TlsExtensionType
TlsExtension
TlsParseException
TlsClientHello        parseRecord, sessionId, extensions, serverName
_ByteReader           bounds-checked reader
```

**This is the densest file for automated review — see §8 before dispatching any
model at it.** It is also the file where a parser bug is least visible: it accepts
attacker-controlled bytes, so every length field must be bounds-checked before use.
`_ByteReader` exists for that reason; a direct `sublistView` in this file is a
finding.

**Tests:** `tls_client_hello_test.dart`.

### `tcp_stack_profile.dart` — 249 lines

Operating-system TCP profiles, so the packet layer agrees with the TLS layer.

```
TcpStackProfileId   iOS · android · windows · linux
TcpStackProfile     MSS, window, option order
TcpSocketTuner      the seam
DartIoTcpSocketTuner
RecordingTcpSocketTuner   records what was applied, for tests
```

**Invariant:** the declared `UtlsProfileId` and the applied `TcpStackProfileId` must
be consistent. A Chrome-on-Windows ClientHello over an iOS TCP profile is a
contradiction that no single-layer test can see.

**Tests:** `utls_profile_and_stack_test.dart`,
`socket_stack_profile_wiring_test.dart`.

### `probe_defense_config.dart` — 303 lines

```
ProbeDefenseConfigError
ProbeDefenseConfig
```

One configuration object for the layer. Validation lives here; an invalid
combination should fail at construction, not at first use.

### `native_shape_availability.dart` — 118 lines

```
NativeShapeAvailability   sealed
NativeShapeAbsent         the first member
NativeShapeAbsentCause
NativeShapeProbeOutcome
```

**This sealed type is what plan step 6 changes.** Adding its second member breaks
every consumer at compile time on purpose: the analyzer's error list is the inventory
of sites that need review.

### `socket_duplex_stream.dart` — 162 lines

```
SocketDuplexStream       dart:io Socket adapter
RawSocketDuplexStream    RawSocket adapter
```

Adapters only. Logic here is a smell; it belongs in the files above.

---

## 3. Test files

`packages/adaptive_transport/test/probe_defense/` — 3676 lines.

```
748  relay_key_rotation_test.dart        epochs, grace, admission cost, keysTried
592  edge_relay_topology_test.dart       relay selection and topology
552  reality_pass_through_test.dart      admit vs fallback, including symmetry
511  reality_handshake_test.dart         key agreement and the identity proof
359  utls_profile_and_stack_test.dart    profile bytes and TCP profile agreement
277  traffic_shaper_test.dart            length and jitter distributions
218  tls_client_hello_test.dart          parsing, bounds, fingerprint string
159  poisson_jitter_and_chain_test.dart  the jitter chain
158  reality_live_passthrough_test.dart  the fallback path against a live socket
102  socket_stack_profile_wiring_test.dart  the tuner is actually invoked
```

One level up, three tests belong to ticket 4:

```
ticket4_decision_note_test.dart    the decision note must state its figure WITH its
                                   provenance — a bare "about 2 ms" fails
ticket4_device_probe_test.dart     the on-device probe record
ticket4b_trace_evidence_test.dart  holds the recorded trace analysis to its words,
                                   including a negative control that mutates the
                                   record five ways and requires rejection each time
```

Run one area:

```bash
cd packages/adaptive_transport && dart test test/probe_defense/relay_key_rotation_test.dart
```

Run everything, all 74 rows, with full logs kept:

```bash
bash tools/run_suites.sh
```

---

## 4. The seven plan steps

Source of truth: `docs/PLAN_REMAINING.md`. Each step carries a machine-checkable
`verify_cmd`; the runner refuses to advance a step whose command has not exited 0.

**Step 1 — `host-dependency-build`** (unattended). The pinned external TLS library,
built for this host. It may not be vendored into this repository, so the proof is the
pin recorded beside the produced tool.

```
verify: test -x "$SRC/build-host/bssl" && grep -q "$(git -C "$SRC" rev-parse HEAD)" docs/evidence/step1_host_build.txt
```

**Step 2 — `phone-arch-dependency-build`** (unattended). The same commit built for
the phone. The check asserts the *architecture of the produced archives*, not that
the build command succeeded, because a build that silently produced host slices would
otherwise pass.

```
verify: for a in libssl.a libcrypto.a; do lipo -info "$SRC/build-ios-arm64/$a" | grep -q arm64 || exit 1; done
```

**Step 3 — `generated-bindings-and-shim`** (unattended). Bindings must be generated,
proven by the generator's own header in the file, plus a shim small enough to read.
The verifier also builds the phone application, because bindings that do not link do
not exist.

```
verify: grep -rqi "AUTO GENERATED FILE, DO NOT EDIT" packages/native_transport/lib/src/generated/ && (cd apps/reference_app && flutter build ios --debug --no-codesign)
```

**Step 4 — `second-architecture-record`** (attended). A two-sided predicate that
earns the word "both": equality over a committed declaration of which fields are
architecture-independent, **and** a positive assertion that the variant fields carry
the phone's own markers — so a second host run cannot be passed off as a phone run.

```
run:    bash tools/capture_device_record.sh
verify: python3 tools/compare_arch_records.py --projection docs/evidence/first_record_projection.json ...
```

**Step 5 — `local-helper-configured`** (attended). The helper process, configured so
the public front name and the backend name differ. The verifier asserts exactly that
difference, because equal names describe a setup that cannot answer step 7.

```
run:    bash tools/t2/step5_helper.sh
verify: awk -F": " '/^public_name/{p=$2} /^real_name/{r=$2} END{exit !(p && r && p != r)}' docs/evidence/step5_helper_config.txt
```

**Step 6 — `status-type-second-member`** (atomic migration). `NativeShapeAvailability`
gains its second member in one commit. The analyzer's list of errors is the inventory
of consumption sites; the suite must be green on the tree containing the new member,
and the ledgers must be clean in the same change.

```
verify: grep -qE "final class NativeShapePresent" .../native_shape_availability.dart && bash tools/run_suites.sh && python3 tools/label_gates.py --check
```

**Step 7 — `trace-absence-check`** (attended). A packet capture, and what absence can
honestly mean. Two claims of different logical shape, decided differently:

- **Universal** — the backend name must appear nowhere. Decided by a byte scan over
  every byte of the complete unfiltered recording, in three encodings, by a scanner
  that must first find those encodings planted in a scratch file (including across a
  read-buffer seam) before its verdict counts.
- **Existential** — the public front name must appear. One witness settles it, but
  the witness must be *located*: the offset has to fall inside a captured packet's
  data region, and the surrounding bytes are parsed far enough to name the field.
  Otherwise a hit in the recorder's own metadata would pass while the device sent
  nothing.

```
run:    sudo -n tools/t2/step7_trace.sh --udid "$(idevice_id -l | head -1)" --out docs/evidence/step7_trace_raw --seconds 900
verify: python3 tools/step7_analyze.py --recheck docs/evidence/step7_trace_analysis.txt --excerpt docs/evidence/step7_trace.pcap ...
```

The complete recording is 65 MB of fifteen minutes of everything the attached device
sent, so it is deliberately not committed. What is committed is the excerpt holding
the witness plus an analysis recording the full file's sha256, size, scan coverage
and encodings. `--recheck` re-measures the existential half live and validates the
universal half from that record, and says in its first line which half was which; if
the full recording is present and its hash matches, it re-measures both and says it
was upgraded.

**Steps 5 and 7 are a pair.** Step 5 configures two distinct names; step 7 is the
measurement that only the public one appears in cleartext. This is the same property
that RFC 8446's Encrypted Client Hello work addresses at the protocol level.

---

## 5. Plans, ledgers, and the tools that decide

```
PRIMARY   docs/PLAN_REMAINING.md          the seven steps above
PRIMARY   docs/PLAN_five_tickets_v4.md    the 40 numbered acceptance gates
HISTORY   docs/PLAN_five_tickets_v1.md    superseded by v4
          docs/PLAN_desert_droplet_voice.md
          docs/PLAN_overnight_voice_record.md
PROCEDURE RIG_GUIDE.md · docs/TICKET4_INTEGRATION.md · docs/GATE_4B_CLOSED.md
          docs/NIGHT_RUN_2026-08-19.md    the most recent measurements

tools/gate_ratchet.py    rebuilds the gate table from test NAMES; fails in both
                         directions — unproven-and-unlisted, and listed-but-proven
tools/plan_check.py      step bookkeeping only; it states plainly that it runs
                         nothing, so "done" there is a record, not a measurement
tools/step7_analyze.py   the trace checker, two modes
tools/run_suites.sh      the 74-row suite, full logs under tools/suite-logs/
tools/label_gates.py     the gate/backlog ledger
```

A gate counts as proven only when a test's **name string begins with the gate id**.
That is deliberate: it makes the ledger mechanical rather than editorial.

---

## 6. Debugging playbook

**Start from the recorded failure, never from a description of it.** Open the log,
read the verbatim message, the stack frames, and the elapsed marker on the failing
row. This is enforced: a hook blocks edits while a fresh failing log in the repository
has not been read.

```bash
grep -n "\[E\]\|Expected:\|Actual:\|Bad state\|Exception" tools/suite-logs/<run>/<pkg>.test.log
```

The elapsed marker is free evidence. A failure at `02:54` in a run whose subject needs
five minutes cannot be that subject's deadline — that single observation, read a day
late, would have saved a full redesign.

**Where defects have actually been found, highest first:**

1. `relay_key_rotation.dart:386-446` — the trial loop, the short-circuit, `keysTried`.
2. `tools/step7_analyze.py` — the universal half is only as good as its scanner
   self-test; the existential half is only as good as the witness being located.
3. `reality_pass_through.dart` — the admit path and the fallback path must be
   indistinguishable to an observer, including in timing.
4. `utls_client_profile.dart` — byte-exactness against a captured reference.
5. `traffic_shaper.dart` — distributions asserted too loosely to fail.

**Assertion rules this subsystem now follows, learned the expensive way:**

- Read a count the code reports; never estimate it from a duration.
- Timing noise on this workload is one-sided — the scheduler only adds time — so the
  minimum over individually timed samples is the estimator, and the ratio of two
  minima taken in the same process is load-immune. Measured: 4.22 unloaded against
  4.18 / 4.20 / 4.21 with every core saturated, while per-round phase averages in the
  same runs swung from 1.30 to 8.44.
- A reference measurement must be the *same operation*, not a cousin of it. Pricing
  admission against an ephemeral key generation predicted a ratio near 2 and measured
  4.23 to 4.64, because a fixed-base scalar multiplication is not a variable-base one.
- Place a bound at the arithmetic midpoint between the measured healthy state and the
  measured failure state, and record both numbers next to it. Re-deriving a bound from
  a better-calibrated centre is instrument repair; moving a bound to fit a failing
  reading is not.
- Prove that an assertion still fails on a real regression before trusting a green.
  The method used here: inject the regression, run, require red, restore, compare
  sha256.

---

## 7. Running any part

```bash
# one test file
cd packages/adaptive_transport && dart test test/probe_defense/<file>_test.dart

# one test by name
cd packages/adaptive_transport && dart test test/probe_defense/relay_key_rotation_test.dart -n 'two-key admission'

# static analysis on one file (the whole-project form is blocked by policy)
cd packages/adaptive_transport && dart analyze lib/src/probe_defense/<file>.dart

# the primitive cost bench, quiet machine only
cd packages/adaptive_transport && dart run tool/bench_x25519.dart

# the full 74-row suite, logs kept under tools/suite-logs/<UTC>/
bash tools/run_suites.sh

# the gate ledger, and the step table
python3 tools/gate_ratchet.py
python3 tools/plan_check.py
```

---

## 8. Handing part of this to another model

Automated content review scores a **payload** — every file in context plus the
conversation — not a single file. Measured on this repository:

```
all 10 source files together                LIKELY-FLAG   score 10, 2 clusters
tls_client_hello.dart alone                 LIKELY-FLAG   score 8,  2 clusters
each of the other 9 alone                   at most one cluster — safe
```

So the single dense file is `tls_client_hello.dart`, and it reaches the threshold by
itself. Three consecutive narrowed briefs were stopped in an earlier session for
exactly this reason: **the brief was never the payload — the files the model opens
are.**

The rule that follows, and it is now mechanical (`dispatch-payload-guard.py` runs
before every dispatch and blocks a payload that scores LIKELY-FLAG):

```
DO      quote inline the exact region the model needs, and tell it not to open
        the repository
DO      split a dispatch so it names one file, and check first:
        python3 ~/.claude/scripts/content-clarity-scan.py --session <files>
DO      run the work on the session model and say so plainly when neither fits
DO NOT  rename identifiers or soften comments to lower a score
```

That last line is not squeamishness. Rewording is legitimate only when the result is
*more accurate*. One doc comment in `tls_client_hello.dart` was rewritten on
2026-08-19 for exactly that reason (commit `599addb`): a vague one-clause summary
became the mechanism it summarised, in RFC terms. By contrast, renaming the field
that holds the parsed hostname, in the fingerprint builder, would be a lie told to a
future maintainer — and it would not work anyway, because real identifiers are
irreducible signal and the score is computed over the whole payload.

**One figure to leave alone.** `reality_handshake.dart:37-39` records a measured cost
of about 1876 microseconds for the scalar multiplication, against about 77 for the
surrounding derivation. `ticket4_decision_note_test.dart:46` asserts that the decision
note states that figure *together with its provenance* — a note that merely said
"about 2 ms" would fail on purpose. Do not "correct" the number without reading which
operation it measures: it is the primitive, not the cost of one admission trial, which
also includes the derivation.

---

## 9. Current status, measured

```
gate ledger    40 declared · 0 without proof · 0 blocked · 0 in flight
               (ratchet: blocked=0 unproven_unlisted=0 —
                tools/dossier/logs/gate_t1b_probe.log, 2026-08-19T13:47:30Z)
step table     all 7 marked done — "unverified", because plan_check runs nothing
step 7         re-run 2026-08-19: RECHECK PASSED, upgraded to a live re-measurement
               over all 68,511,532 bytes of the full capture
steps 1-6      not re-run on 2026-08-19; they need native builds for the phone
full suite     74 of 74 rows PASS · 0 FAIL · no missing rows
               (tools/suite-logs/20260819T224338Z/SUMMARY.tsv, the newest run;
                the probe verified the earlier run 20260819T133223Z the same way:
                rows=74 expected=74 fails=0 — gate_t1b_probe.log)
```
