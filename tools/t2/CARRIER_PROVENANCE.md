# Which per-packet framing the measured rows were taken under

`tools/t2/h2_results.tsv` holds 287 measured rows from the shaped-network rig.
None of them records which per-packet framing the code priced the wire with,
and the open finding for run step 6 was that the 40-byte figure may under-count
authentication tags, negotiated header extensions and IPv6.

That finding is now addressed in the model — a third case, `srtpOverIpv6` at 86
bytes, was ADDED rather than substituted, so nothing changed underneath the rows
that already exist. This file records what those rows actually used, and why no
per-row correction is possible.

## The answer, from dates rather than from memory

```
rows in h2_results.tsv span      2026-08-03T06:36:02Z .. 2026-08-11T11:36:36Z
WireCarrier first committed      2026-08-15 10:34:55 +0200   (3704dd6)
```

Every row predates the carrier parameter by at least four days. So no row was
taken under `heavyFramed` or under any carrier choice at all: the code at the
time carried one hardcoded figure, `headerBitsPerPacket = 320` — 40 bytes —
recorded as the pre-ticket-1 anchor in `docs/PLAN_five_tickets_v4.md`. The test
suite states the same thing independently, in a comment written before this
question was asked:

```
packages/media_webrtc/test/opus_wire_budget_test.dart:5
    The measured T2 rows were captured over plain RTP/UDP/IP, so the
    assertions that reproduce them name that carrier explicitly.
```

Two independent records agreeing is as close to proof as this gets without a
capture from that week, which does not exist.

## What that means for the rows

They priced the wire OPTIMISTICALLY — at the floor of the model. A row that
passed under 40 bytes per packet is not evidence that the same configuration
passes under 66 or 86. Concretely, from `example/probe_admission.dart` on
today's code:

```
simplex, bw=16000     40 bytes -> rate 8000    66 bytes -> rate 6000
                      86 bytes -> refused, needs 16762
duplex,  bw=24000     40 bytes -> refused, needs 24763
                      86 bytes -> refused, needs 33523
```

So the admission table shifts by roughly one rate rung at 66 bytes and can
change the verdict outright at 86.

## Why the rows are not annotated per row

Adding a carrier column to 287 historical rows would mean writing a value into
each one that no run recorded. Every row would then look like a measurement of
something it never measured — the same class of error as editing the 40-byte
constant in place, just spread across a file instead of a line. The rows are
left exactly as captured, and this document is the annotation.

What would replace this document with something better: one packet capture on
this stack, taking the median on-wire packet size minus the payload size the
encoder reported. That yields the real framing figure for a real path, at which
point the estimate in `WireCarrier.srtpOverIpv6` can be replaced by a
measurement and the shaped matrix can be re-run with the carrier recorded in
every row.

## The decision that was deliberately NOT made

`WireCarrier.assumed` was left at `heavyFramed` (66 bytes) rather than promoted
to the new heaviest case. Promoting it would change which configurations are
admitted on every deployment and would invalidate the green rows measured under
the current default. That is a separate, dated decision requiring a re-run of
the matrix, not a one-word edit — stated in the enum's own documentation and
pinned by a test that fails if a heavier case is ever added without
reconsidering the default.
