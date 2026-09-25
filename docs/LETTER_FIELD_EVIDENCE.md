# Letter lane: what is proven, what is not, and the one field step left

Status 2026-09-25. Evidence commits: 21742a9, d4cc8d2, 5c20bdb (not pushed).

## Definition of success

A short letter, sent from a consumer phone (MCI AS197207 or Irancell AS44244, real SIM), arrives the same day on our zone. Nothing else counts:
- rig runs,
- datacenter probes,
- OONI volunteer days.

## What the disk holds for that definition

```
rows on disk that test our zone from a consumer phone:   0
```

The success rate is unmeasured, which is not the same as 0 %.

## The OONI ceiling: witness for someone, not for us

Window 2026-03-01 .. 2026-05-25 (86 days), MCI and Irancell, 10521 web_connectivity bodies, all read (`tools/dossier/evidence/iran-8888/ooni-floor-destinations-mar-may-2026.md`). An outward-evidence day is a day when at least one volunteer phone:
- used an Iranian resolver,
- asked for a foreign name,
- got an answer on a foreign ASN,
- and the page loaded ok.

```
days with outward evidence: 31 / 86
```

That is the ceiling of the public witness, and it has three limits:
- It says some volunteer phone had a path that day, not that ours did.
- Phones with no path never upload, so they are missing from the count (survivor bias).
- No row asked for our zone.

In the peak, 2026-02-28 07:24 .. 06-08 10:13, no MCI or Irancell RIPE Atlas probe was connected (`atlas-gap-2026-02-28-to-06-08.md`).

## What is proven: the letter probe on the rig

Three resolvers race, each with its own nonce. The winner is the nonce our responder logged first. If no nonce is logged, the letter is queued. The size cap is 4096 B. A forged reply cannot name a winner, because the group and nonce are known only to our responder.

```
UC3SLK   107 B    delivered   probe 1/3 nonces (rig filter admits one resolver)
P46NLS   1022 B   delivered   group 73d781ddc7842940, winner nonce a8cf06ac4f224273
                              identical in the phone event and in the responder log
```

## Field step: the only one left

The responder in NL must already run the current `tools/t2/txt_query_server.py`. No new server is set up for this.

```
1. Phone on the real SIM, Wi-Fi off: Chats -> Letter -> Send a short letter; read (or screenshot) the "probe group=<hex>" line in the letter sheet's notes (letter_sheet.dart, plain text, not selectable).
2. On the Mac: NL=<user@host> LOG=<responder log path> bash tools/t2/probe_check.sh <group>
3. Read it: "nonces_logged N/3  WINNER nonce=<hex>" = reached our zone that day; exit 2 "NO PROBE" = the letter stayed queued.
```

Each run is one row for the definition above. The percentage comes only from these rows.

## Two things this is not

- The app's intelligence (director, on-device Gemma narration, nightly champion/challenger) chooses among the paths the app already has. It does not create a new path, so it cannot raise the rate on a day when no path to our zone exists.
- A multi-day queue is delay, not success. Waiting days for a witness day changes when a letter might leave; it does not make the same-day rate 51 %.
