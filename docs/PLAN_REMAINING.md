# The remaining work — a plan that cannot lie about itself

This file is the design document for everything still open. It is written in a
form that a script can check, because a plan that records its own progress in
prose becomes a second, flattering source of truth beside the ledgers that
actually measure the repository. The rule this file obeys is therefore narrow and
mechanical: **it owns the definition of proof, and never proof itself.** There is
no status field anywhere below. Status is computed at read time from evidence
that lives outside this file, exactly as the evidence audit already computes it
from committed files rather than from anybody's memory of a green run.

Prose here is non-normative. Every identifier, command, date and file name lives
inside a fenced block, so there is nothing for the prose and the machine-readable
part to disagree about — a plan whose sentences repeat its own table is a plan
that will one day contradict itself, and the contradiction will be discovered by
a reader rather than by a test.

## What this file owns, and what it only points at

It owns the decomposition — the steps, their order, their dependency edges — and
for each step the exact command that would prove it, the names of the files that
would carry that proof, the verification class the step belongs to, and the
rollback for the one step that can leave the tree uncompilable. It owns the
reasoning: why a step exists and why its proof is shaped the way it is.

It points at everything else. Whether a step is done is derived from whether its
named evidence files exist. Whether an acceptance item is proven belongs to the
label scanner. Whether an item is blocked, and until when, belongs to the backlog
file. What a live unattended run is currently doing belongs to the runner's own
state file, and the two are kept honest by comparing command strings for equality
rather than by copying one into the other.

```text
owns:
  - step ids, titles, order, dependency edges
  - the verify_cmd string that defines each step's proof
  - the NAMES of evidence files (never their timestamps)
  - the verification class of each step
  - the rollback for the destructive step
  - the rationale prose
points_at:
  status:            derived by tools/plan_check.py from evidence existence
  item_proofs:       tools/label_gates.py --check
  item_blockers:     docs/gate_backlog.json
  live_run_state:    .autorun/run.json
banned_fields:       [status, done, passed, percent, mtime, relative_dates]
```

## The schema every step block obeys

```text
schema:
  step:          integer, unique, display order only
  id:            stable slug; what needs/, commits and the runner refer to
  title:         one line, human
  kind:          unattended | attended | atomic-migration
  needs:         ids that must be derived-done before this one starts
  verify_cmd:    the ONLY thing that may prove the step; run by the suite
                 machinery or by hand, never by plan_check.py
  attended_cmd:  attended steps only — the human-run command that PRODUCES
                 evidence; documentation, never executed by an agent
  evidence:      committed file names; all must exist for derived-done
  closes:        acceptance item ids this step closes, if any
  blocked_ref:   pointer into docs/gate_backlog.json when a blocker lives there
  blocked_by:    inline form, absolute ISO date, only when no backlog entry
  slot:          required if and only if blocked_by is present
  rollback:      required for kind atomic-migration
derived_states:
  done:              every evidence file exists AND every needs id is done
  awaiting_evidence:  kind attended, evidence missing — NOT a failure
  failing:           evidence present, verify_cmd exits non-zero
  blocked:           blocker present and not done
  next:              first not-done, not-blocked step in dependency order
```

`awaiting_evidence` is the field that keeps this honest. Two of the steps below
need a live process and a privileged command that an agent must not run, and a
plan whose only vocabulary is pass and fail would have to mark those as failing
or invent a status that means "somebody told me it worked". Instead the human
produces a committed artefact, and the step's verifier is an unattended check
over that artefact — deterministic, re-runnable on a clone, its exit code the
only thing that advances anything. What the checker proves is a property of the
artefact, not that a person was honest about where it came from; the provenance
header narrows that gap and does not close it, which is the same bargain the
evidence audit already makes.

## The one new script

```text
script: tools/plan_check.py
parses:   only fenced yaml blocks whose first key is `step`
executes: nothing, ever
checks:
  - every field against the schema, strictly
  - evidence files exist, by name
  - blocked_ref targets really exist in docs/gate_backlog.json
  - when .autorun/run.json exists, shared ids carry an IDENTICAL verify_cmd
reports:
  - "NEXT STEP: <id> — <title>" and the verify_cmd that would prove it
  - every missing evidence file, by name
  - every blocked step with its slot date
exit_codes:
  0: well formed; next step identified, or all steps done
  1: well formed but inconsistent — evidence present while needs unmet,
     dangling blocked_ref, or verify_cmd drift against the runner state
  2: parse or schema error — unknown field, missing required field,
     non-ISO date, blocked_by without slot, duplicate id, needs cycle
```

A loose parser is the failure mode worth naming: a Markdown checker that shrugs
at a malformed block reports a green plan for a plan it did not understand. Hence
schema violations exit 2 rather than warn.

## Step 1 — the dependency, built for this machine

The external library is not vendored here; it is a pinned clone, and the decision
that pinned it forbids copying it into this repository. So the proof of this step
cannot be a checked-in artefact — it is the pin recorded next to the tool the
build produced, which is what lets a later reader tell whether the thing that was
measured is the thing the decision names.

```yaml
step: 1
id: host-dependency-build
title: "Pinned dependency built for the host, including its command-line tool"
kind: unattended
needs: []
verify_cmd: 'SRC=${BORINGSSL_SRC:-$HOME/.cache/tlsapi/boringssl}; test -x "$SRC/build-host/bssl" && grep -q "$(git -C "$SRC" rev-parse HEAD)" docs/evidence/step1_host_build.txt'
evidence:
  - docs/evidence/step1_host_build.txt
```

## Step 2 — the same commit, built for the phone

The host is x86_64, which is the entire reason a written verdict elsewhere in
these documents says one architecture and not both. Building the same commit for
the phone is what makes a second measurement possible; it proves nothing by
itself, and the block below deliberately asserts the architecture of the produced
archives rather than the success of the build command, because a build that
silently produced host slices would otherwise pass.

```yaml
step: 2
id: phone-arch-dependency-build
title: "The same pinned commit built for the phone architecture"
kind: unattended
needs:
  - host-dependency-build
verify_cmd: 'SRC=${BORINGSSL_SRC:-$HOME/.cache/tlsapi/boringssl}; for a in libssl.a libcrypto.a; do lipo -info "$SRC/build-ios-arm64/$a" | grep -q arm64 || exit 1; done; grep -q arm64 docs/evidence/step2_phone_build.txt'
evidence:
  - docs/evidence/step2_phone_build.txt
```

## Step 3 — bindings that were generated, and a shim small enough to read

Hand-written bindings are forbidden, and the check for that is not a promise in a
document: it is the generator's own header in the generated file. The second half
of the verifier builds the phone application, because bindings that do not link
are bindings that do not exist.

```yaml
step: 3
id: generated-bindings-and-shim
title: "Generated FFI bindings plus the C shim in the phone app target"
kind: unattended
needs:
  - phone-arch-dependency-build
verify_cmd: 'grep -rqi "AUTO GENERATED FILE, DO NOT EDIT" packages/native_transport/lib/src/generated/ && (cd apps/reference_app && flutter build ios --debug --no-codesign)'
evidence:
  - docs/evidence/step3_bindings_manifest.txt
```

## Step 4 — the second architecture, and the predicate that earns the word "both"

An empty diff is the wrong test here. Two architectures may legitimately differ
in parts of the recorded output, and demanding byte equality would either fail
honestly-different runs or tempt somebody to loosen the comparison until it
passes. The predicate is two-sided: equality over a committed declaration of
which fields are architecture-independent, **and** a positive assertion that the
variant fields carry the phone's own markers — so a second run on the host cannot
be passed off as a run on the phone. A legitimate divergence that the declaration
does not cover is handled by amending the declaration in a reviewed change, never
by weakening the comparison.

```yaml
step: 4
id: second-architecture-record
title: "The instrument run on the phone, compared under the invariant projection"
kind: attended
needs:
  - generated-bindings-and-shim
attended_cmd: 'bash tools/capture_device_record.sh'
verify_cmd: 'python3 tools/compare_arch_records.py --projection docs/evidence/first_record_projection.json --baseline docs/evidence/first_record_x86_64.txt --candidate docs/evidence/first_record_arm64.txt --require-arch arm64'
evidence:
  - docs/evidence/first_record_projection.json
  - docs/evidence/first_record_x86_64.txt
  - docs/evidence/first_record_arm64.txt
```

## Step 5 — the helper process, in the configuration the question requires

The library's own command-line tool is the helper, which is why this step changes
no source: standing something up is configuration, and the evidence is a
transcript of the configuration that was actually served. The verifier's only
job is to assert that the two names in that transcript differ, since a transcript
where they are equal describes a setup that cannot answer the question the next
two steps ask.

```yaml
step: 5
id: local-helper-configured
title: "The dependency's own tool serving locally, reachable from the phone"
kind: attended
needs:
  - host-dependency-build
attended_cmd: 'bash tools/t2/step5_helper.sh'
verify_cmd: 'awk -F": " "/^public_name/{p=\$2} /^real_name/{r=\$2} END{exit !(p && r && p != r)}" docs/evidence/step5_helper_config.txt'
evidence:
  - docs/evidence/step5_helper_config.txt
```

## Step 6 — the status type gains its second member, in one commit

This is the only step that changes what the application does, and the only one
whose completion invalidates the green that preceded it. The sealed type has one
member today; adding the second breaks every consumer at compile time on purpose,
and that breakage is not an inconvenience to be worked around — the analyzer's
list of errors *is* the inventory of consumption sites that have not been
reviewed, so the analyze stage passing again is the mechanical form of "every
site reviewed". The verifier therefore measures the new world: the member must be
present in the source, the suite must be green **on the tree containing it**, and
the ledgers must be clean in the same change, which is what stops the backlog
from being updated a day late. The green that came before is recorded as a named
file so the baseline we left is a committed fact rather than a recollection.

```yaml
step: 6
id: status-type-second-member
title: "The run-time probe answers yes, and the sealed type gains its second member"
kind: atomic-migration
needs:
  - generated-bindings-and-shim
  - local-helper-configured
verify_cmd: 'grep -qE "final class NativeShapePresent" packages/adaptive_transport/lib/src/probe_defense/native_shape_availability.dart && bash tools/run_suites.sh && python3 tools/label_gates.py --check && python3 tools/gate_ratchet.py && python3 tools/test_gate_ratchet.py'
closes:
  - 4a
blocked_ref: "docs/gate_backlog.json#4a"
evidence:
  - docs/evidence/step6_probe_answer.txt
  - docs/evidence/step6_suites_before_migration.txt
  - docs/evidence/step6_suites_after_migration.txt
rollback: 'git revert the single migration commit; a probe answering no aborts before any commit and the working tree is discarded to the prior green'
```

The intermediate state — member added, consumers not yet updated — is never a
checkpoint and never committed. There is no partial credit in this step, which is
the point of writing it as one atomic commit rather than a series.

## Step 7 — the trace, and what absence can honestly mean

The trace is produced by an operating-system tool that requires elevated rights,
so a person runs it and an unattended checker reads what they committed. Absence
of a string in a capture is a weaker claim than it looks — a name can be absent
because it was protected, or absent because the connection never happened, or
absent because a scanner looked in the wrong encoding. So the check is two-sided
again: the artefact must be non-empty and carry a provenance header, the real
name must not appear, and the name that does appear in the clear must be the
public one. A capture of nothing passes the first half of that and fails the
second.

```yaml
step: 7
id: trace-absence-check
title: "A capture of the connection, checked for the real name in the clear"
kind: attended
needs:
  - status-type-second-member
attended_cmd: 'sudo rvictl -s "$(idevice_id -l | head -1)" && sudo tcpdump -i rvi0 -s 0 -w docs/evidence/step7_trace.pcap'
verify_cmd: 'test -s docs/evidence/step7_trace.pcap && grep -qE "^tool: " docs/evidence/step7_trace_provenance.txt && grep -qE "^date: 20[0-9]{2}-[0-9]{2}-[0-9]{2}" docs/evidence/step7_trace_provenance.txt && ! strings docs/evidence/step7_trace.pcap | grep -qiF "$(cat docs/evidence/step7_real_name.txt)" && strings docs/evidence/step7_trace.pcap | grep -qiF "$(cat docs/evidence/step7_public_name.txt)"'
closes:
  - 4b
blocked_ref: "docs/gate_backlog.json#4b"
evidence:
  - docs/evidence/step7_trace.pcap
  - docs/evidence/step7_trace_provenance.txt
  - docs/evidence/step7_real_name.txt
  - docs/evidence/step7_public_name.txt
```

## What this plan does not claim

It does not claim the seven steps can be finished on any particular evening. Two
of them need a person at the keyboard, one needs a phone attached, and the two
acceptance items they close already carry dated blockers with a scheduled slot in
the backlog — those dates stand until the evidence files named above exist, and a
step is not closed by the existence of this document describing it. It also does
not claim the trace check proves the protection works in general; it proves one
recorded connection did not carry one string, which is exactly as much as one
capture can support.

```text
authored: 2026-08-18
design_consult: "Fable 5, single-topic design consult; routed to fable, purity not measured"
supersedes: nothing — docs/TICKET4_INTEGRATION.md keeps the per-item status table
```
