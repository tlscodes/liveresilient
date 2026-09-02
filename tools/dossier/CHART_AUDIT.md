# Which visuals read a real counter, and which do not

Phase 6, step 5, first half. The plan's reason for it was blunt and correct:
*we do not know whether the current UI charts are wired to real counters or are
decorative — and that is exactly what an outside reviewer tests first.*

The answer, from the code today: mostly decorative, and one of them does not
say so.

## The doctrine this audits against

`apps/reference_app/lib/src/ui/network_truth.dart` opens with the project's own
rule:

> **UI state is derived from a real network signal, never invented.** Each value
> below names the signal that produces it; if no signal exists, the state does
> not exist either.

That rule is met by the message-status ladder, which is what it was written
for. It is not met by the quality visuals.

## The audit

```
visual                        fed by                          honest about it?

message status ticks          real delivery events            yes — the ladder
  (sending/sent/delivered)    from the messenger's stream          is the doctrine

diagnostics panel             DemoQualityFeed via              YES — displays a
  (Settings)                  seededDemoHistory()                  source chip
                                                                   reading
                                                                   "synthetic
                                                                   demo profile"

call-screen quality gauge     DemoQualityFeed                  NO — no source
  (rtt, loss, bitrate)        main.dart:157, 346                   label anywhere
                                                                   in the widget

adaptive ladder rung          DemoQualityFeed                  NO — same feed,
  indicator                   main.dart:184                        same silence

voice-note amplitude          syntheticAmplitudeSource()       NO — name says
                              main.dart:307                        synthetic, the
                                                                   screen does not
```

`DemoQualityFeed` is a scripted four-act sequence on a one-second timer:
`demo_feeds.dart` walks RTT from healthy through a degradation and back, with
loss and bitrate to match. It is a good demo. It is not a measurement.

## Why the unlabelled ones matter more than they look

A person on a real call, on a real bad link, looks at the gauge to decide
whether to keep talking. What they are shown is a script that will recover on
schedule whatever the network does. That is not a cosmetic problem: it is the
interface telling a confident lie about the one thing the user cannot check
themselves.

It is also the same defect class this repository spent today removing from its
documents — a number presented as measured that was not — except here it is in
the product, where the person harmed is a user rather than a reviewer.

The diagnostics panel shows how it should look. Its own header comment already
states the rule: *demo data never masquerades as radio*. It carries a chip, and
a reader knows what they are seeing.

## What to do, in order

```
1  label the three unlabelled visuals with the same source chip the
   diagnostics panel already has — one widget, already written, three call
   sites. This makes the app honest today, before any new plumbing.
2  build the real meter: rtt from the probe, datagrams sent and received,
   delivery ratio — counters that already exist in the transport layer.
3  switch the gauge and the rung to the real meter, and keep the chip: it
   then reads "live" instead of "synthetic demo profile", and the user can
   still tell which they are looking at.
```

Step one is small enough to do before anything else and removes the misleading
state immediately. Steps two and three are the rest of phase 6 step 5.

## Verification

The gate this audit belongs to has to check the property, not the intention:

```
every widget that displays a network figure resolves to either
  a counter in the transport layer, or
  a source label visible on the same screen
```

A test that walks the widget tree for figure-displaying widgets and asserts one
of those two is true would keep this honest without anyone remembering to. That
test does not exist yet; writing it is part of step three.
