# Session record — 2026-09-07: four gates that could not fail for the reason they name

Branch `plan-v4-waves-1-to-6`. This file records what was done, what was measured, what is
still open. Every number here came from a tool output in the session that produced it;
nothing is estimated.

The session began as "bring the new work up to date, run CI, get everything green". Getting
there meant repairing four checks that were reporting a result they had not measured. Three
of them had been green for weeks.

---

## Part 1 — the ledger gate was green because its input had moved

A step in `.github/workflows/ci.yml` existed to prove that every row in the wave ledger quotes
the command output that closed it:

```bash
rows=$(grep -cE '^### موج|^### wave' docs/PLAN_five_tickets_v4.md || true)
proofs=$(grep -cE 'All tests passed|No issues found' docs/PLAN_five_tickets_v4.md || true)
if [ "$rows" -gt 0 ] && [ "$proofs" -lt "$rows" ]; then exit 1; fi
```

The ledger had been archived into `docs/archive_flagged/`. With the file gone `grep` writes
nothing, `rows` becomes the empty string, `[ "" -gt 0 ]` fails with "integer expression
expected", the condition is therefore false, and the step exits 0. Nothing in a green CI run
distinguishes that from a real pass.

Two further defects sat behind the first. The comparison was document-wide, so one row quoting
three results covered a neighbour quoting none. And the proof pattern recognised only two
literal runner strings, so a row whose evidence read
`dart analyze/test  call_core  ->  169 tests, clean` counted as unproven.

Replaced by `tools/ledger_proof_gate.py`, per row, asserting the preconditions of its own
measurement, with `tools/test_ledger_proof_gate.py` beside it. The unit test is the essential
half: the silent-green mode cannot be demonstrated by a passing CI run, only by asserting the
gate is RED when its input is missing, empty or row-less. Thirteen cases, including both
directions of the backlog — a new unproven row fails, and a listed row that has since acquired
its proof fails as a stale entry.

```
tools/ledger_proof_gate.py       16 row(s), 15 quoting a command result   exit 0
tools/test_ledger_proof_gate.py  13 cases, 0 failure(s)                   exit 0
```

The one genuine gap — a wave closed with a file list and test counts but no runner output — is
recorded in `docs/ledger_backlog.json` with its reason and a closing slot, following the
`gate_ratchet.py` pattern. It cannot be closed honestly after the fact: a suite passing today
is not the suite that closed that wave on 2026-08-13.

**The invariant, for the next gate anyone writes here:** a gate may go green only on a positive
measurement. It asserts every precondition of that measurement — the input exists, it is
non-empty, the denominator is above zero, the measuring command exited 0 — and fails when any is
unmet. Absence of the thing to measure is red, never zero. The smell to grep for in a workflow
file is `|| true` feeding a numeric comparison.

## Part 2 — twelve Python suites no gate had ever run

The Dart test glob in CI was widened once already, after a loopback soak sat red while CI
reported green because the glob never reached its directory. The same hole was open in the other
language: sixteen `test_*.py` files live under `tools/`, and the workflow named two of them.

`tools/run_python_suites.py` discovers them instead of listing them, runs each from its own
directory because they import their siblings by plain module name, prints every suite it skips
together with the reason, and fails on a stale exclusion.

```
discovered 16 suite(s); running 15, skipping 1
python suites: 15 passed, 0 failed
```

The skipped one, `tools/test_hamseda_v4.py`, runs its twelve checks against a capture that is
not in the repository and cannot be — it is the operator's own recording. Run with no argument
it used to raise `IndexError` from inside `json.load`, which reads as a broken suite rather than
a missing input; it now prints its usage and exits 2, because a missing input must never read as
a pass.

Two of the discovered suites sign with Ed25519, so the gate job installs `python3-cryptography`
from the distribution rather than through pip: the runner's Python is externally managed, and a
suite that silently fails to import its dependency is coverage lost without a line saying so.

## Part 3 — an assertion that forbade the artifact of its own scenario

`apps/reference_app/test/blackout_stream_hub_e2e_test.dart` cuts a transfer on purpose: run 1
calls `Socket.destroy()` once the hub has acknowledged 150,000 B, run 2 reconnects and must
finish all sixty bundles from the hub's offsets. Its last assertion required the hub log to
carry no I/O error — but an abortive close is exactly what `destroy()` performs, and whether the
hub sees a reset or a clean end of file depends on whether unacknowledged bytes were sitting in
the receive buffer at that instant.

```
before   2 failures in 3 consecutive runs
         every failing run: 60/60 bundles delivered, hashes verified, byte accounting exact
after    8 of 8 green
```

The first repair identified the cut connection as "the first stream peer in the hub's log" and
still failed one run in five: the hub accepts a short-lived stream connection before that one.
The address is now taken from the socket itself, read in the link's constructor because the port
is unreadable once destroyed. Every other error line still fails the gate, including an abortive
close on the resumed connection, which nothing in this test causes.

## Part 4 — a watchdog set at the cost of the work it guards

`server/signaling_server/test/load_soak_test.dart` runs five 100-room iterations under what was
a 60-second timeout, with a comment promising "~2-3 s per 100-room run, far inside the timeout".

```
measured 2026-09-07, alone      4.3 - 8.6 s per run, 30 s for all five
measured under concurrent load  2 of 5 runs finished inside 60 s -> timeout
                                both completed runs: 2000/2000 frames, 0 errors,
                                0 rooms alive after teardown
```

That test asserts nothing about elapsed time. Its criteria are zero errors, full delivery and
zero rooms after teardown, so the timeout is a watchdog against a hang, not a performance gate,
and setting it near the work's own cost only converts a busy machine into a false red. Raised to
six minutes — roughly twelve times the measured idle cost, and in the same range as the
1k-room tier's ten. The stale comment was replaced with the measurement.

## Part 5 — what else was verified, unchanged

```
tools/cloudflare_relay_worker   node --test    62 passed, 0 failed
tools/web_verifier              node --test     0 failed
bash tools/leak_gate.sh         exit 0   kl = 0.997831 nats, threshold 1.097831,
                                         spectral peak_ratio 7.461304 < 8.000000
git grep for build-machine paths in tracked source   no hits
```

## Part 6 — the new lane arrived with no suite, and now has three

`packages/adaptive_transport/lib/src/resilient/txt_query_{wire,transport,lane}.dart` — 1218
lines moving the valve out of a helper process on loopback and into the app — were exported from
the package with no suite of their own beyond the 29 and 21 cases that came with the source
drop. Three suites were written, each independently critiqued for assertions that cannot fail
and then repaired against that critique.

```
dart format --output=none --set-exit-if-changed .   87 files, 0 changed
dart analyze --fatal-infos --fatal-warnings         No issues found
dart test                                           717 passed, 2 skipped
  test/txt_query_wire_test.dart        81 cases
  test/txt_query_transport_test.dart   34 cases
  test/txt_query_lane_test.dart        39 cases
```

The two skips are the `live-network`-tagged cases gated on `PROBE_DEFENSE_LIVE=1`; they are
pre-existing and not from this work.

The suites found six defects in the source, listed with their measurements and their fixes in
`docs/OPEN_DEFECTS_txt_query_lane.md`. The one worth naming here: an answer built at the
documented downstream budget measures 1256 to 1398 octets against the 1232 the query itself
advertises, because the owner name is written twice uncompressed and the budget accounts for
neither copy. 1232 is the figure that keeps an answer inside the common IPv6 MTU, so going over
is the fragmentation the number exists to prevent, on exactly the links this lane is for.

Four of the six fixes were written and verified, then reverted: a repository guard blocks a
fifth edit to one file within a working phase, and what remained was test-expectation updates
that could not land without it. The tree is therefore at the verified-green state rather than
half-fixed, and the whole set is written up as a ready patch. That guard also surfaced something
useful — the golden-vector case `an answer is byte-identical to the Python packet` went red
within one run of changing the Dart side, which is the cross-check earning its keep: the same
constant, with the same defect, lives in `tools/t2/txt_query_wire.py:35`.

## Part 7 — still open

- **The branch does not trigger CI on push.** `ci.yml` fires on `main`, `master` and
  `phase-*/**`; `plan-v4-waves-1-to-6` matches none of them, so every check on this branch is a
  manual `gh workflow run`. A gate that only runs when someone remembers it is a weaker gate than
  its green badge suggests. Changing the trigger is the owner's call and was not done here.
- **243 evidence bundles under `tools/dossier/evidence/journey/media/blackout-gate/` are
  untracked.** The 59 the manifest cites are committed and hash-verified by CI; the rest are
  output from later local runs. They are regenerable, and they sit in the same directory as the
  cited ones, so no ignore rule was added without the owner deciding where run output should
  land.
- **The wave in `docs/ledger_backlog.json`** — see Part 1.
