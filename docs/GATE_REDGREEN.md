# Red-green double runs

Run step 4. A test that has only ever been observed passing does not prove it
measures its gate: the same green appears when the test is watching the wrong
thing. So every gate closed in this run is driven twice — green on the healthy
tree, and RED with the gate's own subject disabled — and the mutation is named
here so the claim can be re-run rather than trusted.

The mutations are applied to the working file and reverted from a backup in the
same script. `git status` was checked afterwards each time: none of the mutated
files stayed modified.

| gate | healthy | subject disabled | the mutation that produced the red |
|---|---|---|---|
| 3c | green | red | the rig picks the policy string from the flag with a ternary, production rule bypassed |
| 3c | green | red | an early return on the flag, with the production call still present underneath |
| 5f | green | red | the rollback branch deleted from `manifest_verifier.dart` |
| 6f | green | red | the redirect removed, so one hop and one name — the world where every name IS boundary-known |
| 2b | green | red | `tickProbe:` removed from the admission call in `call_session.dart` |
| 2b | green | red | `maxSchedulerStepFor` stubbed to always return `SchedulerStepAdmissible` |
| 1f | green | red | the ptime dwell removed, so a disruption commits on the first disagreeing sample |

Verbatim output of the three probe runs, this date:

```
mutation A (ternary on the flag) is caught                    rc=1
mutation B (early return, mapper still present) is caught      rc=1
restored source is green                                       rc=0
3C RED-GREEN PROOF PASSED

PASS 5f  RED with the rollback branch removed (rc=1)
PASS 6f  RED when no name appears mid-flight (rc=1)
PASS both tests GREEN on the restored tree (rc=0)
RED-GREEN DOUBLE RUN PASSED

PASS 2b  RED with the production wiring removed (rc=1)
PASS 2b  RED when the bound is always admissible (rc=1)
PASS 2b GREEN on the restored tree (rc=0)
2B RED-GREEN DOUBLE RUN PASSED

PASS 1f  RED with the hysteresis removed (rc=1)
     failing tests it caught:
       1f  a sustained collapse from 64000 to 16000 changes the policy ...
       1f  flapping at a boundary never renegotiates, however long it goes on
       1f  hysteresis is symmetric: flapping back up after a commit ...
       1f  one recovering sample cancels a pending disruption outright
PASS 1f  GREEN on the restored tree (rc=0)
1F RED-GREEN DOUBLE RUN PASSED
```

## Why these mutations and not others

Each one disables the gate's SUBJECT, not something merely nearby. That
distinction is the whole point: deleting an unrelated line also turns a suite
red, and proves nothing.

`3c` needed two mutations because the first version of its predicate enumerated
syntax — it caught the ternary and would have missed the early return. The
predicate was rewritten to be positional (the flag may only appear inside the
feature-flag map; a policy string literal may only appear on the line that reads
the profile), and both shapes now fail. A guard that can be sidestepped by
rephrasing is a guard against one author's habits.

`6f`'s subject is a property of the protocol rather than of a code branch, so
there is nothing to delete. Its red direction is the counterfactual instead: in
a world where every name is known at the boundary — one hop, one name — the test
must fail. It does.

`2b` is the interesting one, because the optional parameter is the defect. The
production wiring passes `tickProbe:` to an OPTIONAL parameter; dropping it
compiles, every pre-existing suite stays green, and admission silently stops
consulting the delay bound. That mutation is not hypothetical — it is the exact
shape of the ticket-6 defect this repository already paid for once, in a
different file.

## What a red-green pair still does not prove

It shows the test responds to its subject. It does not show the test covers
every way the subject can break, and it does not make a vacuous guard
non-vacuous — see gate 2b's fourth test, which today guards zero production
sites and says so in its own failure message.
