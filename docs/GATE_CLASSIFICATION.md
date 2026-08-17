# Gate classification — 2b, 2c, 5e, 5f

Run step 1. Four gates were carried as "unproven" without anyone saying WHY,
and "unknown" is not a scope a run can plan around: a missing test costs an
hour, a missing feature costs a day, and a measurement that has not been taken
may simply come back red. Each row below names the anchor that decided it, so
the verdict can be re-derived instead of remembered.

Read before believing: the classification is a reading of the code as it stands
on 2026-08-17, at the line numbers given. If a line moved, re-read it.

| gate | verdict | the anchor that decided it |
|---|---|---|
| 2b | MISSING FEATURE (partly wired) | `apps/reference_app/lib/src/call_session.dart:255` consumes the bound, but only as a boolean; no production code reads `maxStep`, and `FixedTickEmitter` is never constructed outside its own file |
| 2c | MISSING RUN (harness exists, bar not met) | `packages/connection_orchestrator/tool/intelligence_replay.dart` + 39 runs in `tools/t2/replay_corpus/`; last recorded score `1.0996` at epoch 4 in `tools/t2/intelligence_evolution.json`, against a bar of `1.107` |
| 5e | MISSING FEATURE (three parts) | `packages/signed_config/lib/src/manifest_cache.dart:168` relaxes only `expired`; the relaxation exists only in `initialize()`; and no in-binary floor constant exists anywhere in the repository |
| 5f | MISSING TEST | `packages/signed_config/lib/src/manifest_verifier.dart:373` already rejects `revision < lastAcceptedRevision`; an in-window document reaches that branch |

## 2b — the value is consumed, but not as a value

The gate asks for an integration test proving the scheduler bound is consumed by
the 1d emitter. The bound IS consumed today, at one site:

```
apps/reference_app/lib/src/call_session.dart:255
    connectionBudget.maxSchedulerStepFor(...) is SchedulerStepAdmissible
```

That is a type test. It answers "may this configuration be admitted", and
throws the number away. Two greps decide the rest:

```
maxStep                 no consumer outside connection_budget.dart
FixedTickEmitter(       one match, its own constructor at
                        packages/adaptive_transport/.../traffic_shaper.dart:457
```

So there is no production emitter whose tick could come from the bound, and an
integration test written today would have nothing to integrate. The feature is
one wire — derive the tick from `maxStep` at the emitter's production
construction site — plus the test.

A DECISION IS HIDING HERE, and it belongs to step 4 rather than to this
document. The emitter is off by default everywhere (`TickEmissionMode.off`), so
the gate could instead be re-read as "the bound decides admission", which is
already true and already testable. That re-reading may well be right — but it
narrows what the gate claims, so it has to be recorded as a decision with its
reason, not adopted quietly because it is the cheaper half.

## 2c — a measurement that has not been taken

Nothing is missing from the tooling. The replay tool, the corpus and the score
history all exist, and the history is the reason this row is not a test gap:

```
epoch 0  1.0000
epoch 1  1.0504
epoch 2  1.0614
epoch 3  1.0988
epoch 4  1.0996      <- last recorded
bar      1.1070
```

Epoch 4 is below the bar, and the ticket-2 change has not been replayed since.
So the honest statement is that the evidence has not been produced, and its
outcome is not known in advance: a replay can come back under 1.107, and that
is a result about the system, not a failure of the harness. Whoever runs it
records the number it produces.

## 5e — the largest of the four, in three parts

```
(i)   manifest_cache.dart:168      if (reason == ManifestRejection.expired)
                                   notYetValid is not relaxed
(ii)  the relaxation lives only in initialize(), the persisted path;
      the freshly-fetched document path has no equivalent
(iii) the gate row needs an in-binary floor for a fresh install, and the
      repository has no such constant — greps for builtIn / buildTimeFloor /
      minimumIssuedAt / shippedFloor / floorAtBuild all return nothing
```

Part (iii) is the one that makes this a feature and not a test: a fresh install
has no persisted floor by definition, so "reject a document older than the
in-binary floor" cannot be asserted until the floor is stamped into the build.

## 5f — the branch is there; nobody asked it this question

```
packages/signed_config/lib/src/manifest_verifier.dart:373
    if (manifest.revision < lastAcceptedRevision) -> ManifestRejection.rollback
```

A document signed more recently but carrying a lower revision is inside its
validity window, so it passes the time checks and reaches this branch. The
feature holds; only the test is absent.

One caveat the test should pin rather than leave implicit: the time checks run
BEFORE the rollback check (lines 359–371). A lower-revision document that is
also out of window is rejected as `expired` or `notYetValid`, not as
`rollback`. The gate demands rejection, which holds either way — but a test
that asserts the REASON for the in-window case keeps that ordering visible, so
a later reorder cannot silently change which rejection a caller sees.

## A discrepancy found while reading, recorded because it is real

Ticket 5's work list says to move the revision branch ahead of the time
branches. That was not done. The equivalent was achieved differently — the
persisted floor makes the rollback branch reachable across the whole clock-drift
sweep — and it is tested:

```
packages/signed_config/test/manifest_time_floor_test.dart:177
    5a-bis  with the floor applied the rollback branch is reachable across
            the whole drift sweep that previously skipped it
```

So gate 5a's proof is genuine and the mapping to that file is not a false link.
The plan's wording and the code differ, and the code's version is the better
one; this note exists so the next reader is not left reconciling them alone.

## What this document does not do

It writes no code and closes no gate. It converts four unknowns into two
missing tests' worth of work (5f, and half of 2b's), one measurement (2c) whose
result is not predetermined, and one genuine feature (5e). Steps 2 through 5 do
the work; step 4 owns the 2b decision named above.
