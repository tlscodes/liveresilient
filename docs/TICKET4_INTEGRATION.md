# Ticket 4 — the integration, and what is still blocked · 2026-08-17

What this document is for: after 2026-08-17 the ticket splits cleanly into work
that is finished, work that is finishable in Dart alone, and work that needs a
machine or a server nobody has stood up. That split used to be implicit, which
is how "blocked" quietly covered gates that were simply not written yet. Here it
is explicit, per gate, with a date on everything that is waiting.

## Where the ticket stands, per gate

```
4a  CLOSED    2026-08-18 — the cabled phone reached a peer offering the
              extension and the peer HONOURED the configuration it was given.
              Module: the pinned commit cross-built for the device and reached
              through the shim in this pod, bindings generated, nothing
              vendored. Peer: the same library's own server, started locally
              with a public name different from the name asked for. Evidence:
              docs/evidence/step6_probe_answer.txt, held to its words by
              packages/adaptive_transport/test/ticket4_device_probe_test.dart
              (4 tests, including the negative control that rejects `ignored` —
              an exchange that finished while the peer did nothing with the
              configuration).
4b  BLOCKED   needs a packet capture of a live connection to that server
4c  CLOSED    2026-08-17 — the note, TICKET4_DECISION.md section 9, 4 tests
4d  CLOSED    2026-08-17 — one-member status value + exhaustiveness, 8 tests
4e  CLOSED    2026-08-17 — the panel row, rendered-output test, 7 tests with 4f
4f  CLOSED    2026-08-17 — architecture test on the presentation layer
4g  CLOSED    2026-08-17 — the resolver: a probe, never a build flag
```

Status words here mean what they say, and this table is edited when a gate's
evidence lands — not when the work is planned. CLOSED means a test named after
the gate passes; WRITTEN means the artefact the gate asks for exists but nothing
mechanical guards it yet; IN PROGRESS means it is being built in the current
session. A gate is never listed as closed on the strength of a document
describing it, including this one.

The choice itself is no longer provisional. The falsification test of section 5
ran on 2026-08-17 and configuration alone reproduced the target first-record
shape (`docs/TICKET4_FIRST_RECORD/RESULT.md`), so what is left is integration
work and two measurements — not a decision.

## The two blockers, dated

### BLOCKER 4a — CLOSED 2026-08-18

```
BLOCKER   2026-08-17   opened
CLOSED    2026-08-18   both halves ended the same night
NEEDED    (1) the native module built for the target and linked into the app
          (2) a reachable test server that offers the extension, with a
              public name that is not the real name
MET BY    (1) BoringSSL at b0760837 cross-built for the device; a C shim in
              this pod; ffigen bindings; the archives referenced where they
              were built, never copied into this repository
          (2) that same library's own command-line server, started by
              tools/t2/step5_helper.sh with two different names recorded
ANSWER    applied — the peer honoured the configuration, which is a different
          answer from `ignored`, the near-miss where the exchange finishes and
          the peer does nothing with it
ROUTE     the USB bridge (192.168.2.1). The first attempt answered
          `unreachable` against a wired LAN address the phone has no path to,
          which is why the evidence records the route as well as the outcome.
```

What is worth carrying forward from this: the capability measurement failed
once for a reason that had nothing to do with the capability. A gate that had
accepted "the exchange completed" would have been green on a peer that ignored
the configuration entirely; a gate that had not recorded the address would have
left a later reader unable to tell a working module from a working network.

Both halves are external to this repository. (1) is build-system work against a
pinned external clone — the decision explicitly forbids vendoring the library
here, so it is a toolchain change, not a source change. (2) is infrastructure:
a server, a certificate and a published configuration. Neither can be
manufactured by a test, and a gate that says "connect to a server" cannot be
honestly closed without one.

### BLOCKER 4b — no capture of a live connection

```
BLOCKER   2026-08-17   opened
NEEDS     4a first, then a packet capture of the connection it establishes,
          inspected for the real name in the clear
SLOT      the same 2026-09-12 review
```

Strictly downstream of 4a: there is nothing to capture until a connection
happens. Worth naming separately anyway, because the two failures are
different — 4a can pass while 4b fails, and that combination is precisely the
interesting one: a working connection that still leaks the name.

### Adjacent, and also dated: the second architecture

```
BLOCKER   2026-08-17   opened
NEEDS     an arm64 host to re-run tools/first_record_dump
CLAIM     section 5's verdict is currently proven on x86_64 only; the phrase
          "both architectures" is not yet earned
SLOT      the same 2026-09-12 review
```

The instrument is written and runs from one command
(`tools/first_record/first_record.c`, driven by `tools/first_record_dump`), so
this is a host, not a project. Until it runs there, the confirmation says
x86_64 and says so in `docs/TICKET4_FIRST_RECORD/RESULT.md`.

## The order the remaining work goes in

From `TICKET4_DECISION.md` section 8, unchanged, each step verified before the
next one starts:

```
1  build configuration for the pinned external clone
2  FFI bindings, generated, not hand-written
3  the Dart seam that hands the composed record to the library
4  the run-time probe that asks the linked module whether it can do it
5  the second member of the status type — LAST, and only after 4 answers yes
```

Step 5 is deliberately last and is the only step that changes app behaviour. It
also breaks every consumer at compile time, by design
(`packages/adaptive_transport/lib/src/probe_defense/native_shape_availability.dart`),
which is what forces the review of each consumption point instead of hoping for
one.

## Three rules for whoever does this work

**A green build is not a green gate.** Linking proves compilation. Each 4x gate
needs its own behavioural evidence, and the two that need a rig stay blocked
with a date rather than being closed on a build log.

**The library is not vendored here.** The decision names an external clone at a
pinned commit. Changing that is a separate decision with its own note, not a
convenience during integration.

**No hand-written TLS.** Recorded at `docs/PLAN_five_tickets_v4.md:723-726` and
restated in section 9 of the decision: no version of this ticket that
hand-writes a record layer, a key schedule or certificate verification is
acceptable, whatever the schedule pressure.

## What is proven, and by what

```
4d  packages/adaptive_transport/test/native_shape_availability_test.dart
    one member; the base sealed; the constructor private; predicates proven
    against a synthetic two-member source so they can demonstrably count to two
4g  the same file
    every probe outcome resolves to absent — including a probe reporting
    SUCCESS, which resolves to absent with a cause naming exactly why
    -> dart test test/native_shape_availability_test.dart  ->  8 tests, green
4c  docs/TICKET4_DECISION.md section 9 — the 2 ms figure with its measured
    provenance and both rejections
    packages/adaptive_transport/test/ticket4_decision_note_test.dart
    -> 4 tests, green. It checks the note CONTAINS the three things the gate
       asks for; it cannot check the reasoning is sound, and says so.
4e  apps/reference_app/lib/src/ui/diagnostics_panel.dart — one unconditional row
4f  apps/reference_app/lib/src/ui/network_truth.dart — one function owns the words
    apps/reference_app/test/native_shape_absent_surface_test.dart
    -> 7 tests, green. 4e asserts the panel renders EXACTLY what the value's own
       translator returns, rather than a sentence spelled out in the test — a
       test that spelled it out would become the definition of the claim, which
       is the reference shift the plan warned about. The wording is then checked
       separately for content, so deriving from the value cannot mean deriving
       a lie.
```

Three of those tests failed on their first run and each failure was the test's
own fault, which is the useful kind: a predicate that treated a destructuring
pattern as a construction, a prose check that read doc comments, and a widget
test that built a bare theme the app never renders. Recorded because all three
are one mistake wearing three hats — measuring a unit adjacent to the one the
gate names.

One of those eight tests failed on its first run, and the failure is worth
keeping: the predicate for "no compile-time flag" matched the library's own doc
comment, which names the mechanism in the sentence forbidding it. A gate that
fires on the documentation of a rule is not measuring the rule, so the predicate
now strips comments first.

Availability is a value, not an implementation, and the value has one possible
answer today. That is the part of ticket 4 that did not need a server, and it is
done.
