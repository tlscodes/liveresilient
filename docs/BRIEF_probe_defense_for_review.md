# probe_defense — a brief for a review or debugging pass

Hand this to a reviewer instead of the repository. It says what the subsystem is,
which files hold what, which plan is authoritative, what the seven remaining steps
were, and which traps this code has already paid for.

## The name and the shape

The subsystem is **`probe_defense`**, inside the package **`adaptive_transport`**.

```
lib/src/probe_defense    4081 lines   10 files
test/probe_defense       3676 lines   10 files
```

Its job in one sentence: make a connection's *observable surface* — the Client
Hello bytes, the packet timing, the length distribution, the TCP stack
fingerprint, and the destination name that travels in the clear — indistinguishable
from ordinary traffic to a common front name, so the connection is not classified,
throttled, or blocked by an on-path observer.

## The Dart files, with each one's own first line

Source (`packages/adaptive_transport/lib/src/probe_defense/`):

```
634  reality_pass_through.dart      relay-side admission control: authenticate a
                                    client from its Client Hello, or pass it through
567  traffic_shaper.dart            behavioral shaping: length distribution and
                                    timing jitter
558  utls_client_profile.dart       browser Client Hello profiles and a byte-exact
                                    Client Hello builder
548  relay_key_rotation.dart        relay static-key rotation on epochs, with no
                                    wire change at all
503  reality_handshake.dart         X25519 admission handshake, and where a 64-byte
                                    signature actually goes
439  tls_client_hello.dart          TLS 1.3 Client Hello parsing and fingerprinting
303  probe_defense_config.dart      one configuration object for the layer
249  tcp_stack_profile.dart         OS TCP/IP stack profiles, so the packet layer
                                    agrees with the story the TLS layer tells
162  socket_duplex_stream.dart      dart:io adapters for the seams
118  native_shape_availability.dart whether the native first-record capability is
                                    available, as a value rather than a guess
```

Tests (`packages/adaptive_transport/test/probe_defense/`), plus three ticket-4
tests that live one level up:

```
748  relay_key_rotation_test.dart          epochs, grace, admission cost
592  edge_relay_topology_test.dart
552  reality_pass_through_test.dart
511  reality_handshake_test.dart
359  utls_profile_and_stack_test.dart
277  traffic_shaper_test.dart
218  tls_client_hello_test.dart
159  poisson_jitter_and_chain_test.dart
158  reality_live_passthrough_test.dart
102  socket_stack_profile_wiring_test.dart
     ../ticket4_decision_note_test.dart    asserts the decision note states its
                                           figure WITH its provenance
     ../ticket4_device_probe_test.dart
     ../ticket4b_trace_evidence_test.dart  holds the trace analysis to its words
```

## The plan files — which is which

```
PRIMARY (open work)     docs/PLAN_REMAINING.md
                        the seven steps below; each carries a machine-checkable
                        verify_cmd, and the runner refuses to advance without it
PRIMARY (the ledger)    docs/PLAN_five_tickets_v4.md
                        the 40 numbered acceptance gates; a gate is proven only by
                        a test whose NAME begins with the gate id
SECONDARY (history)     docs/PLAN_five_tickets_v1.md     superseded by v4
                        docs/PLAN_desert_droplet_voice.md
                        docs/PLAN_overnight_voice_record.md
SECONDARY (procedure)   RIG_GUIDE.md         how the hardware rig is driven
                        docs/TICKET4_INTEGRATION.md
                        docs/GATE_4B_CLOSED.md
                        docs/NIGHT_RUN_2026-08-19.md   the most recent findings
TOOLS THAT DECIDE       tools/gate_ratchet.py      rebuilds the gate table from
                                                   test names; fails both ways
                        tools/plan_check.py        step bookkeeping ONLY — it
                                                   states plainly that it runs
                                                   nothing
                        tools/step7_analyze.py     the trace checker, two modes
                        tools/run_suites.sh        the 74-row full suite
```

## The seven steps, one line each

```
1  host-dependency-build          the pinned external library built for this host;
                                  the proof is the pin recorded beside the tool,
                                  because the library may not be vendored here
2  phone-arch-dependency-build    the same commit built for the phone; the verifier
                                  asserts the ARCHITECTURE of the produced archives,
                                  not that the build command succeeded
3  generated-bindings-and-shim    bindings must be generated, proven by the
                                  generator's own header in the file; the verifier
                                  also builds the phone app, since bindings that do
                                  not link do not exist
4  second-architecture-record     a two-sided predicate that earns the word "both":
                                  equality over a committed declaration of the
                                  architecture-independent fields, AND a positive
                                  assertion that the variant fields carry the
                                  phone's own markers
5  local-helper-configured        the helper process stood up in the configuration
                                  the question requires; the verifier asserts the
                                  two names in the transcript DIFFER, because equal
                                  names describe a setup that cannot answer step 7
6  status-type-second-member      the sealed status type gains its second member in
                                  one commit; the analyzer's error list IS the
                                  inventory of consumption sites to review
7  trace-absence-check            the recorded trace must not contain the real
                                  destination name anywhere, and must contain the
                                  public one as a LOCATED witness
```

Steps 5 and 7 are a pair: step 5 configures the helper with a public front name
distinct from the backend name, and step 7 is the measurement that only the public
one appears in cleartext on the wire — the same SNI-in-cleartext property that TLS
1.3 Encrypted Client Hello (RFC 9180 / draft-ietf-tls-esni) addresses.

## Status, and the difference between recorded and measured

```
plan_check.py     all 7 steps "done (unverified — this tool runs nothing)"
gate_ratchet.py   40 declared · 0 without proof · 0 blocked · 0 in flight
step 7 verifier   RUN 2026-08-19 → STEP7 RECHECK PASSED, and upgraded to a live
                  re-measurement over all 68,511,532 bytes of the full capture
steps 1-6         NOT re-run on 2026-08-19; they need native builds for the phone
full suite        73 of 74 rows PASS · 0 FAIL · 1 row never run (stopped early)
```

`done` in the step table is a record. Only step 7 was re-measured on 2026-08-19.

## Traps this code has already paid for — do not re-derive them

**Absence and presence are not one claim.** "The real name does not appear" is
universal and is worth exactly as much as the scan behind it; "the public name
appears" is existential and one witness settles it — but the witness must be
LOCATED inside a packet's data region, or a hit in the recorder's own metadata
passes while the device sent nothing. `tools/step7_analyze.py` decides each half
in the form its logic requires, and its scanner must first find all three
encodings planted in a scratch file, including across a read seam, before its
"absent" verdict counts.

**A reference measurement must be the same operation.** Pricing admission against
`generateEphemeral()` predicted a ratio near 2 and measured 4.23-4.64, because a
fixed-base scalar multiply is not a variable-base one.

**Never estimate a count the code already reports.** `EpochAdmission.keysTried`
(relay_key_rotation.dart:360) states how many keys admission tried. That fact was
being inferred from a duration ratio whose band was narrower than its own noise.

**Timing noise here is one-sided.** The scheduler only ever adds time, so the
minimum over individually timed samples is the estimator, and the ratio of two
minima is load-immune: measured 4.22 unloaded and 4.18 / 4.20 / 4.21 with every
core saturated, while per-round phase averages in the same runs swung 1.30 to 8.44.

**Read the recorded failure before designing the fix.** Two flaky tests were
described in a handoff as one cause; the logs showed two different causes, and the
one that had been redesigned was never the one failing.

**The 1876 us figure is load-bearing.** `ticket4_decision_note_test.dart:46`
asserts the decision note contains it together with its provenance
(`reality_handshake.dart:37-39`). It measures the scalar multiply specifically —
not the cost of one admission trial, which also includes the credential
derivation. Do not "correct" it without reading what it measures.

## Suggested entry points for a review pass

Highest value first, by where defects have actually been found:

```
1  relay_key_rotation.dart:386-446   the admission loop: per-trial crypto, the
                                     short-circuit, and keysTried
2  tools/step7_analyze.py            the two-mode checker; the universal half is
                                     only as good as its scanner self-test
3  reality_pass_through.dart         the largest file, and the one that decides
                                     whether a stranger is passed through
4  utls_client_profile.dart          byte-exactness is the whole point; an off-by-
                                     one here is invisible to every unit test that
                                     does not compare against a captured reference
5  traffic_shaper.dart               distributions are easy to assert loosely
```
