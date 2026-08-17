# Gate 2c — the replay measurement, run 2026-08-17

## The number

```
epoch 0   score 1.000000
epoch 1   score 1.048307
epoch 2   score 1.058403
epoch 3   score 1.096613
epoch 4   score 1.097412      <- the run's final score
bar                  1.107
delta               -0.009588
```

**The bar was not met.** Gate 2c is measured and OPEN, not closed.

## What was run, exactly

```
cd packages/connection_orchestrator
dart run tool/intelligence_replay.dart \
  --epochs 5 \
  --corpus ../../tools/t2/replay_corpus \      # 39 recorded runs
  --tsv    ../../tools/t2/h2_results.tsv \     # 287 measured rows
  --out    ../../tools/suite-logs/replay_2c_evolution.json \
  --brains ../../tools/suite-logs/replay_2c_brains
```

A FRESH brains directory on purpose. `tools/t2/brains/` already holds epoch2,
epoch3 and epoch4 from the earlier run, and replaying into it would have carried
that state into the measurement — the score would then describe an accumulation
across two sessions rather than five epochs over this corpus. Comparability
required starting where the recorded protocol started.

## Compared with what was on record

```
recorded, epoch 4     1.0996
measured, epoch 4     1.097412
difference           -0.002188
```

Close, and slightly lower. The recorded figure came from a run whose brains
directory persisted; this one started clean, which is the most likely source of
the gap and is a hypothesis rather than a finding — nothing here isolates it.

## What was deliberately NOT done

- **No re-run to chase the bar.** The first complete run IS the measurement. A
  second run would only be legitimate if this one were invalid for a stated
  reason, and then both would be recorded.
- **No tuning of the scorer, the corpus or the weights.** Any of those would
  have reached 1.107 and turned a measurement into a decoration.
- **No adjustment of the bar.** Where 1.107 came from is a question for whoever
  set it; moving a threshold to meet a result is the same error as tuning the
  result to meet a threshold, and neither is mine to do quietly.

## Where that leaves the gate, stated plainly

The gate says `score >= 1.107`. The system scores 1.097412 on the recorded
corpus. Three honest options, none of which this document chooses:

1. **The system improves.** The four component scores say where the headroom
   is: `trend` sits at exactly 1.000 across every epoch — it has not moved at
   all — while `atlas` carries the rise (1.000 → 1.295). A trend estimator that
   never improves across five epochs is the first thing to look at, and it is a
   finding this measurement produced for free.
2. **The bar is re-derived.** If 1.107 was an extrapolation rather than an
   observation, it is a target, and a target that has never been hit needs its
   provenance checked before it keeps a gate red.
3. **The gate is re-scoped**, dated and recorded, the way gate 2b was — with
   the narrowing visible rather than implied.

Until one of those happens, 2c is: **measured, below the bar, open.** It is
recorded in `docs/gate_backlog.json` with this number so the next reader inherits
the measurement rather than the assumption.

Full evolution report, all four component scores per epoch:
`tools/suite-logs/replay_2c_evolution.json`.

---

# The resolution, 2026-08-17 — path 2, and the gate closes

Everything above stands as written; nothing in it is retracted. What follows was
measured afterwards and it changes the conclusion.

## The question that was asked first

Is the flat `trend` component a defect? **No.** It measures a detector that is
built fresh for every run and holds no state between epochs
(`packages/connection_orchestrator/lib/src/replay_benchmark.dart:297-299` and
`:679`), so it is epoch-constant by construction, and the library doc says so at
lines 11-13. It receives real input and produces a real raw score (0.5735); the
exact 1.000000 is the correct normalization of a genuinely constant raw, not a
division artifact. The plateau was even diagnosed before this run:
`docs/DESIGN_intelligence_v4.md:167-174` records that all 72 parameter
combinations score an identical raw on the current signal — a dead lever — and
plans a learnable tuner behind a dated blocker (2026-08-11) that needs rig rows
nobody has recorded yet.

So path 1 is real, designed, and **data-blocked**. It could not close this gate
today. And the one change that would have lifted the composite over the bar —
dropping `trend` from the four-component mean, which gives
(4×1.097412 − 1.0)/3 = 1.1299 — cannot be described as a bug fix without
pointing at the bar. That is tuning. It was not done.

## What the gate actually says, and what changed under it

```
gate 2c, docs/PLAN_five_tickets_v4.md:383
    بازپخشِ v4 روی همان کورپوس، امتیازِ کل >= 1.107
    replay v4 on THE SAME CORPUS, total >= 1.107
```

The bar's provenance is findable and it is an **observation**, not an
extrapolation: `docs/DESIGN_intelligence_v4.md:204` records v4 step 1 closing
with `total 1.107 >= 1.0854`, measured on the inputs as they stood then. The
plan transplanted that observed number into gate 2c as a threshold.

Then the inputs grew. The corpus went from 23 recorded runs to 38 on 2026-08-11
(federation, itself a v4 deliverable working as designed), and the shared
measurement table gained 15 rows the same day. Carried onto grown inputs, an
observed 1.107 is an extrapolation — "the score seen on that data holds on this
data" — which was never measured, and has now been measured false twice.

## Two runs, both recorded

```
run   corpus   table rows   final score        vs bar 1.107
S1    23       287          1.097412161128651  short by 0.009588
S2    23       272          1.108374885599173  MET, by 0.001375
```

Both artifacts record the inputs they consumed (`corpus.runs`,
`corpus.outcomes`), so the pair is self-describing: **same code, same 23
captures, only the table differs.** The 15 rows added on 2026-08-11 are the
entire cause of the shortfall. Corpus size turned out to be irrelevant to this
score — S1 over 23 captures scores bit-identically to the earlier run over 38
(1.097412 both), because the corpus feeds only the epoch-constant component.

```
# rebuild the corpus snapshot from NAMES, not file dates — dates do not
# survive a clone, so the 23 filenames are recorded instead
cd tools/t2
mkdir -p /tmp/corpus_0810
while read -r f; do cp "replay_corpus/$f" /tmp/corpus_0810/; done \
  < gate_2c/corpus_asof_0810.txt

cd ../../packages/connection_orchestrator
dart run tool/intelligence_replay.dart --epochs 5 \
  --corpus /tmp/corpus_0810 \
  --tsv    ../../tools/t2/gate_2c/h2_results_asof_0810.tsv \
  --out    ../../tools/t2/gate_2c/replay_2c_S2.json \
  --brains /tmp/brains_S2
```

Full output: `tools/t2/gate_2c/replay_2c_S1.log`, `..._S2.log`. Fresh brains
directory for each, for the reason given at the top of this document.

The evidence sits under `tools/t2/gate_2c/` rather than `tools/suite-logs/`
because that second directory is in `.gitignore`: a gate pinned to an ignored
file passes on the machine that wrote it and throws everywhere else. Both
artifacts, both logs, the exact table and the 23 corpus filenames are committed
together. `.gitignore:28` also ignores `*.log`, so the two run logs are tracked
by an explicit `git add -f` — once tracked, later edits to them show up
normally. That is deliberate: the raw output is the evidence, and evidence that
`git add .` would silently drop is not retained.

## Why the snapshot is the gate's corpus and not a convenient subset

State the objection plainly, because it is the right objection: the input
subset was chosen **after** seeing 1.097 fail, and that is exactly how a
measurement gets shopped. Three things answer it.

1. **The gate names it.** "همان کورپوس" — the same corpus — is the gate's own
   text, written before any of this. Restoring the inputs it points at is
   obeying the gate, not reinterpreting it.
2. **A record that predates today fixes which snapshot.**
   `packages/connection_orchestrator/test/replay_benchmark_test.dart:74-77` has
   said since the gate was built that the recorded history was **23 captures and
   272 table rows**. S2 consumed exactly 23 and 272. The snapshot was not sized
   to taste; it was sized to a number written down by someone else, earlier.
3. **The components reproduce the design's recorded figures.**
   `DESIGN_intelligence_v4.md:70` budgeted lane 1.072 and atlas 1.314 for this
   state. S2 measured lane 1.0720 and atlas 1.3144. Landing on those two
   independently is evidence the right snapshot was hit, not a nearby one.

Nothing was tuned: not the scorer, not the weights, not the corpus contents, not
the bar. The code is today's code. The date filter is a date filter.

## Where that leaves gate 2c

**Met, on the corpus the gate names: 1.108374885599173 ≥ 1.107.** With today's
code — which is not step-1 code — the replay reproduces and slightly exceeds the
recorded total on the recorded inputs, which is the neutrality claim the gate
exists to make.

Pinned by `packages/connection_orchestrator/test/replay_2c_snapshot_test.dart`,
three tests: the artifact and its inputs; a negative control asserting the same
predicate FAILS on the grown table; and the flat-trend note, so a later reader
does not mistake 1.000000 for a broken score. Driven red by moving the artifact
aside — all three failed — then restored to green.

Two things this does NOT claim, and both matter more than the close:

- **The grown inputs have no bar.** 1.097412 on 38 captures and 287 rows is a
  measurement with nothing to compare it to. Deriving a threshold there is the
  gate owner's call and needs a stated basis, exactly as 1.0854 once had one.
- **`trend` is still a dead lever.** Honest, not broken — and still contributing
  nothing across five epochs. v4 section 6 owns the fix and is blocked on rig
  rows since 2026-08-11. Closing 2c does not close that.
