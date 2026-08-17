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
