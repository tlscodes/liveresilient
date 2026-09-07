# Crossing a total blackout — what it was, what it became and how, what must follow

A record of the work of 2026-09-04/05 on one question: can two people who share a small code
keep talking when the link between them is thin, hostile, or absent for hours? Every number
here is a rig measurement with its run id; the rows live in tools/dossier/app_journey_results.tsv.

## 1. What it was (the morning of 2026-09-04)

- The app-journey rig sent placeholders: a noise JPEG, a voice note of zero bytes, a random
  blob labeled video. A row could PASS on a hash match alone; nobody could look at what crossed.
- Two rig defects hid results: the previous phone instance took the next run's job, and a
  Mac build longer than the 10-minute wait killed the bandwidth profile.
- On the 16 kbit/s profile the voice note failed: the text messenger resent a 16.6 KB chunk
  twelve times at a fixed 2 s window and gave up ten seconds before its first copy could have
  been acknowledged (run 13:30:18Z). Its "backed-off attempts" were not backed off.
- There was no profile for "no path at all". The call layer gives up after 2 minutes; a message
  with no link simply died.

## 2. What it became, and how

### 2.1 Real media, decoded on return (commits 23cd0f5 → 8827502)
The phone now posts every received item's bytes back to the hub; the runner checks
fixture == returned blob == the sha the app printed, decodes the returned file with Mac
tools against the fixture's own dimensions and duration, and a media row PASSes only with
`decoded=ok`. Fixtures are a real photograph (sized per link), a spoken voice note (`say`,
IMA-ADPCM ≤ 24 KB) and a one-minute clip with a spoken count (sized per link: 1.6 MB /
260 KB / 110 KB). Evidence: evidence/journey/media/<profile>-*, films in RECORDINGS.tsv.

### 2.2 The text messenger's window models the frame (23cd0f5)
window = serialization time at the lane's rate + rto, backed off from the first attempt,
seeded from the transport before any sample; a frame still in the transport buffer is never
resent; failure is a live-clock budget with pause/resume; every failure carries its numbers;
chunk size follows the rate. Tests: reliable_messenger_window_test.dart (7).

### 2.3 The lane budget follows measured delivery (feb17b8)
The cause of the 16 kbit/s failure was measured, not guessed: the lane governor floored its
budget on the transport's bandwidth estimate, which climbed to 4 MiB/s on a 2 KB/s pipe
(70 % loss, 14.6 s round trips). Now every acked chunk and frame reports its bytes; the
measured delivery rate is the floor and twice it the cap; 570 B/s is the start; the estimate
is only printed. Result: narrow (16 kbit/s) photo 122 s, voice 179 s, one-minute clip 150 s —
ALL PASS; extreme (16 kbit/s + 1 s + 15 % loss) ALL PASS. Eight profiles green (run stamps
2026-09-04 16:21Z–21:26Z; 43 rows, 0 FAIL). Price paid honestly: the unshaped photo went
from 3.6 s to 36.5 s (conservative start) — an open follow-up.

### 2.4 The blackout profile: 1 KB across a 54-minute total cut (e7018de, e47afab)
The phone signs a 1 KB payload with an Ed25519 key announced at boot, holds it in the durable
store-and-forward queue while every app path is dropped (UDP, ICMP, hub and relay TCP; the
shaper gained a positional scope argument because sudoers strips environment variables),
probes with one GET every 20 s, and flushes on the first window; the Mac verifies the
signature and records the latency in HOURS. Run 2026-09-04T23:36:50Z: 3,236 s cut, delivered
on the first 90 s window, signature intact, 0.9 h. (Self-test: 103 s cut, 0.029 h.)

### 2.5 The window became a gate (f365b24, b512976)
A signed queue of 20 real-sized bundles (411,600 B), a 2 s probe, continuous priority flush,
chunked resumable posts (hub /have + /chunk; the hub joins, checks the envelope sha, verifies
the signature, emits one event with chunks=n), windows SHAPED at 16 kbit/s. Self-test
(run 07:15:44Z): 20/20 in 0.221 h, utilization per window 34.0 / 59.8 / 44.3 / 67.5 %, the two
100 KB videos resumed across windows 3 and 4. Hours-scale run 07:29:41Z: window 1 after a
1,557 s cut reproduced 15 bundles, 76,600 B, 34.1 % (still running at the time of writing).

### 2.6 Around it
- tools/natprobe: a NAT-behavior probe (mapping, filtering, hairpin, mapping lifetime) that
  records no identity data, with a NAT simulator; classifier proven on 8 policy combinations.
- docs/outage-resilience-study-2026-09.md: the sourced study of the 2019, 2022, 2025 and
  2026 outages (2026: Jan 8 → May 26, three phases; 88 days near-total from Feb 28; filtering
  and whitelists, not route withdrawal; IPv6 zero; mobile still off after "restoration").
- What the shared code solves and what it cannot (identity and trust, not reachability);
  the minimum inside the country: one process with three small roles on any reachable
  domestic address, or the reachable friend's line itself.

## 3. What must follow (in this order; each is one rig run from a number)
1. docs/blackout-gate-plan-to-90.md — measure the waste (Step 0), HTTP/1.1 keep-alive on the
   hub (Step 1, +20-30 points, no phone rebuild), chunk size from the measured rate (Step 2),
   one streaming POST per window (Step 3, ≥ 90 %), beacon (Step 4), the gate under a live
   call (Step 5), the gate over a domestic host with both phones behind carrier NAT (Step 6).
2. The NAT probe's field form inside the app and the first public table (≥ 30 samples per
   operator; cells under 10 never published).
3. The unshaped photo's conservative start (36.5 s) — raise the initial floor when the round
   trip is tiny, with the 16 kbit/s rows as the regression gate.
4. Relay TCP shaping (every row so far says "relay TCP unshaped"); PAKE binding of the code to
   the session key and the DTLS fingerprint; a domestic-host build of the relay roles.

## Where the evidence is
```
tools/dossier/app_journey_results.tsv        every row with its run stamp (superseded runs kept)
tools/dossier/manifest.tsv                   sha256 of every evidence file
tools/dossier/evidence/journey/RECORDINGS.tsv  the screen films (sizes, sha256; files outside git)
tools/dossier/evidence/journey/media/        the media the phone returned, decoded on the Mac
tools/dossier/logs/journey/                  app, phone-event and hub logs per profile
HANDOFF-NOTES.md parts 4-12                   the session's decisions, traps and next actions
```
