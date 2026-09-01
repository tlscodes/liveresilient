# Contributing

Thank you for looking. One thing to know before anything else: **this project's
CI is unusual**, and a first pull request often fails for reasons no other
repository teaches. This file explains why, so you do not lose an afternoon to it.

## Licence and sign-off

- Everything except `server/` is **Apache-2.0**.
- `server/` is **AGPL-3.0** — running a modified copy as a network service means
  publishing those modifications. This does not affect clients that merely talk
  to a server over the network.
- Contributions are accepted under the **Developer Certificate of Origin**. Add
  `Signed-off-by: Your Name <you@example.com>` to each commit (`git commit -s`).
  There is no CLA and no copyright assignment.

## Build and test

```bash
dart pub get                     # workspace resolve from the repo root
dart format --output=none --set-exit-if-changed .
dart analyze                     # infos are fatal here, not advisory
cd packages/<name> && dart test  # one package
bash tools/run_suites.sh         # the full gate suite, logs under tools/suite-logs/
```

## The gate system, and why your PR may fail

A "gate" is a claim about behaviour that a specific test proves. The project
keeps a ledger of them, and CI enforces three rules that most repositories do
not have:

- **Traceability** — every declared gate must reach a real test. Adding a claim
  without a test fails the build.
- **Ratchet** — the number of unproven gates may not increase, and a stale
  ledger entry fails too. If you remove a test, remove or update its row.
- **Evidence survives the run** — verification commands must not truncate their
  own output (no `| head`, no `| tail -1` on a test command). A run whose log
  cannot be read afterwards is treated as a run that did not happen.

If CI fails on one of these, the message names the ledger row. Fix the row or
the test; do not weaken the check.

## What a good change looks like

- One concern per pull request, with the test that proves it in the same diff.
- Numbers in comments and docs cite the command that produced them. "About 2 ms"
  is not acceptable where a measurement exists; state the value, the operation
  measured, and where it came from.
- Public API changes need a note in the package's `CHANGELOG.md`.
- Names describe what the code does. A name that states an intent rather than a
  mechanism will be asked to change.

## Reporting a bug

Include the platform, and — for anything network related — the link conditions
you saw it under: bandwidth, packet loss, round-trip time. For this project
those three numbers are usually the whole diagnosis.

Security problems go through `SECURITY.md`, not the issue tracker.
