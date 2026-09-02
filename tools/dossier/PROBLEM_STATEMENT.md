# Problem statement

*Every figure on this page is attributed to the organisation that published it,
and every measurement names the file in this repository that produced it. Where
sources disagree, the disagreement is shown rather than resolved in our favour.
A reviewer will check, and a number we cannot defend costs more than it buys.*

## The condition this project is built for

Iran went almost completely offline in January 2026. ‹src:see the block below›
Access was partially
restored behind a whitelist at the end of that month, and a second, near-total
shutdown followed in February and held for months. Network measurement
organisations describe it as the longest nationwide shutdown they have recorded
in any country, in a country of over ninety million people.

```
2026-01-08   near-total shutdown begins            Wikipedia timeline; NetBlocks
2026-01-16   connectivity about 2% of ordinary     NetBlocks
2026-01-28   partial restore behind a whitelist    Wikipedia timeline
2026-02-28   second near-total shutdown begins     Al Jazeera, 5 April 2026
   day 45    1,056 hours counted                   IranWire (NetBlocks figure)
2026-04-21   day 53, over 1,248 hours              Wikipedia timeline
2026-05-26   partial restoration                   Wikipedia timeline
             a country of over 90 million people   NetBlocks, January update
```

Casualty figures for the period are disputed across more than an order of
magnitude and are documented elsewhere. This document relies on none of them.
The engineering case rests on the connectivity record, which is measured,
consistent, and published by organisations that do this for a living.

## Why existing tools fail in that condition

A shutdown is rarely total for everyone or forever. What people are left with
is a link that technically carries packets but cannot carry a conversation: a
few kilobits per second, heavy loss, and seconds of latency. Mainstream
messengers are not built for that floor. They assume a working congestion
control loop and enough bandwidth to complete a media upload.

We measured what that assumption costs. Carrying a four-megabyte video over a
sixty-percent-loss link on a reliability-managed data channel did not finish at
all. Both runs were abandoned at the time limit with most of the object still
undelivered and the recorded rate at zero.

```
src:tools/t2/h2_results.tsv

row 266  2026-08-10T01:38:29Z  loss60  FAIL   abandoned at 790s
                                              decoded 172 of 1,158 symbols, 0 kbps
row 267  2026-08-10T02:04:13Z  loss60  FAIL   abandoned at 790s
                                              decoded 587 of 2,814 symbols, 0 kbps
```

The result is the failure mode that matters: a person can see the connection
icon, and still cannot send a voice message, a photograph, or reach a call.

## What this project does about it

It removes both assumptions.

**The transport does not depend on a loss-reactive control loop.** Bulk content
is carried as rateless coded symbols over plain UDP, so loss costs proportional
extra symbols instead of a round trip. The same object, over the same loss
profile that produced the two failures above, was delivered and hash-verified.

```
src:tools/t2/h2_results.tsv

row 268  2026-08-10T07:18:32Z  loss60  PASS   4,194,304 B sha-verified
                                              303,564 ms, 111 kbps
row 269  2026-08-10T08:37:11Z  loss60  PASS   4,194,304 B sha-verified
                                              314,744 ms, 107 kbps
```

**The application layer is sized for the floor.** Every feature has a wire
budget proven by its own gate, and the transport and codecs carrying those six
features were then measured on a physical iPhone over a shaped link. Which of
those lanes is wired into the application today, and which is not yet, is in
`tools/dossier/LANE_TABLE.md` — the measurement characterises the transport,
not a finished product.

```
src:tools/phase5/h3_results.tsv and tools/dossier/e2e_ios_results.tsv

feature      wire bytes   budget    measured on device
text                 29     4.8 s              2.5 s
news page         1,160    52.3 s             17.0 s
voice, 10 s         879    42.3 s             13.9 s
photograph        2,682    49.6 s             23.2 s
video note        5,926    82.0 s             45.4 s
push-to-talk   5,220/60s    live              60.0 s   liveness only, see below
```

**The claims are reproducible, failures included.** The transport matrix is an
append-only log of every run this project has ever made, red rows and all;
a script reduces it to the latest verdict per cell, and those cells are green.

```
src:tools/t2/h2_results.tsv reduced by tools/t2/report_matrix.py

24 profile-by-scenario cells, latest verdict per cell, all green
 6 codec gates with their logs      src:tools/phase5/logs/gate_1..6.log
 6 end-to-end device rows           src:tools/dossier/e2e_ios_results.tsv
```

At two kilobits per second, those numbers mean a message arrives in a couple of
seconds and a photograph in around twenty — on a link where the alternatives
deliver nothing at all.

## The row that is weaker than it looks

We would rather say this than have it found. The push-to-talk row is judged on
liveness only: the stream stayed up, the decoder raised no fault, and at least
one bundle arrived. The rule is in the test, not paraphrased here.

```
src:tools/dossier/e2e_ios_results.tsv, row ptt
rule: apps/reference_app/integration_test/e2e_matrix_test.dart

sent 60 bundles, 10 arrived, longest gap 40.7 s, no decoder error
```

That demonstrates a live voice lane survives the profile. It does not yet
demonstrate usable continuity. Closing the gap is funded work, not a finished
claim, and it is named as such in the milestones rather than left in a table
where a green word does the arguing.

## Who this is for, given there are no users yet

This project has no users and no letters of support, and we are not asking a
reviewer to take demand on trust. The condition it is built for is documented
above by third parties. The people it is for are those left on a link that
carries packets but not a conversation.

The first funded milestone is therefore not a feature. It is end-to-end
encryption on the datagram lane, because no one should be pointed at this tool
before that gap closes — and the gap is stated plainly in `SECURITY.md` rather
than buried. The milestone after it is a supervised pilot whose acceptance
measure is the six end-to-end rows above, reproduced on testers' own devices,
so that "it works for people" becomes a measurement rather than an assertion.

## Sources

```
Wikipedia, "2026 Internet blackout in Iran" - timeline and source index
  https://en.wikipedia.org/wiki/2026_Internet_blackout_in_Iran
Al Jazeera, 5 April 2026 - NetBlocks: longest nationwide shutdown on record
  https://www.aljazeera.com/news/2026/4/5/
IranWire - the NetBlocks hour count
  https://iranwire.com/en/news/151163-netblocks-1056-hours-of-internet-shutdown-in-iran-officials-and-influencers-dominate/
Access Now / #KeepItOn - statement on the shutdown
  https://www.accessnow.org/press-release/iran-internet-shutdown-2026/
```

Every measurement file cited above is committed to this repository with its
size and hash recorded in `tools/dossier/manifest.tsv`, so a reviewer can check
that the file they are reading is the file that was measured.
