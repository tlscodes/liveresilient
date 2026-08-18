# Session handoff — 2026-07-27

Everything this session produced, written down so the conversation itself is no
longer needed. Read this instead of scrolling back.

## Code audit (connection_orchestrator)

Seven defects found and fixed; `dart analyze` clean, tests 189/189 (was 171).
(Snapshot mid-session on 2026-07-27. The same package reads 207 in
`docs/PROJECT_HANDOFF_2026-07-27.md` — written at the end of the same day, after
18 more tests landed — and 248 in the 2026-07-29 gate. The three numbers are
time-ordered snapshots of one package, not a disagreement; 248 is current.
Contradiction 3, noted 2026-07-31.)
New `test/audit_hardening_test.dart` pins each fix with 18 tests. Backups
`.backups/197-202`.

1. `ChunkReassembler` let every incoming bundle overwrite the chunk count, so a
   forged smaller count spliced a truncated payload or crashed on a null
   assertion. The count is now fixed by the first bundle seen; disagreeing
   bundles are rejected.
2. Its four maps were keyed by a caller-supplied id with no cap. Added
   `maxOpenTransfers` (64) with oldest-first eviction, plus `forget()` and
   `openTransfers`.
3. `CarrierRelay.restore` skipped the capacity and hop checks that `accept`
   enforces, so a persisted or edited store could exceed its stated bounds
   permanently. Now gated; returns the restored count.
4. `CarrierRelay._seen` grew without limit. Capped by `maxSeenIds` (10000).
5. `assert()` is stripped in release builds, so `ResumableTransfer(chunkSize: 0)`
   and `RatelessEncoder`/`RlncEncoder(blockSize: 0)` would divide by zero in
   production. All three now throw `ArgumentError`.
6. `adoptWarmState` caught only `FormatException`; valid JSON of the wrong shape
   raised a `TypeError` that escaped a method documented to return false.
7. `SecureMediaLane`'s race-loser cleanup had no `catchError`, so a rejecting
   close surfaced as an unhandled zone error.

## Naming pass

Metaphor names replaced with names that state behaviour, via
`tools/rename_metaphor_identifiers.sh` (rollback tag
`pre-rename-metaphors-2026-07-27`): `SurvivalRung`→`OperatingRung`,
`SurvivalLadder`→`OperatingLadder`, `SurvivalModeDriver`→`DegradedModeDriver`,
`TrendSentinel`→`TrendMonitor`, `survivalMessenger`→`storeAndForwardMessenger`,
`survivalFallbackQueue`→`dtnFallbackQueue`, and the matching file renames.
Verified: four packages analyze clean, 139+189+114+117 tests green.

Left alone deliberately: runtime strings that would migrate stored data, the
user-facing UI string, and every protocol name — those are accurate.

## Tooling built

- `session-clarity-watch.py` — scores the live conversation, which nothing did
  before; the older scanner only ever looked at files.
- `clarity-guard-hook.py` — runs before each message, advisory by default,
  fail-open on any internal error, sliding dialogue window, content-hash cache.
  Tests: `test-clarity-guard.sh`, 7/7.
- `clarity-remediate.py` — carries a finding to its remedy; its selftest rejects
  any rule justified by a score instead of by accuracy.

## Settings changed

- Removed `CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK` from `~/.claude/settings.json`.
- Removed the hard model pin from `~/.claude/settings.local.json` so per-project
  routing works again; global default is now `claude-fable-5[1m]`.
- This repo's `.claude/settings.json` defaults to fable. See
  `docs/MODEL_ROUTING.md` for which two packages need `/model opus`.

## Still open

- ~~Nothing is committed yet. Two commits make sense: the audit fixes, then the
  naming pass.~~ **RESOLVED later the same day** — the work was committed;
  `docs/PROJECT_HANDOFF_2026-07-27.md` §4 lists the eleven commits. This file was
  written mid-session and the handoff was written at the end of it, so both were
  true when written. The handoff is the authoritative one for 2026-07-27 because
  it is the later snapshot and names the commits. (Contradiction 4, noted
  2026-07-31.)
- `flushWireTick` drops the untried remainder of a tick after the first
  undelivered frame. Documented behaviour, reasonable for droppable audio, but
  untested.
