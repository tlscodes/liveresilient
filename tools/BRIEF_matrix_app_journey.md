# Brief — the app itself, across every impairment profile, on film

Paste the block below into a terminal session on Fable 5.1, from the repository
root. Every anchor was verified on 2026-09-03.

This is the hardest piece left that does not need grant money, and it is the one
that turns "the transport survives" into "a person can use this". Read the
warning at the end before starting.

---

```
Work in /Users/behnam/Downloads/voice_call_kit_v3 on branch plan-v4-waves-1-to-6.
Commit the live-call wiring first if it is still uncommitted; do not start on a
dirty tree.

GOAL
Drive the REFERENCE APP — its own screens, its own buttons — through every
impairment profile from an ordinary link down to the worst one, sending text,
a photograph, a video note and a voice note on each, while the live monitor bar
shows what the path is actually doing. Record all of it. Fix what breaks.

WHY THIS AND NOT MORE UNIT TESTS
tools/t2/h2_results.tsv already proves the TRANSPORT survives these profiles.
tools/dossier/LANE_TABLE.md records the uncomfortable corollary: those rows were
measured over a test-harness lane, and three of the six features have no
production wiring. Nobody has ever watched the app itself work at 16 kbit/s with
1000 ms of delay and 15% loss. That gap is what this closes.

THE PROFILES — exact shaping, from tools/t2/h2_run.sh:49
  name        bw          delay   loss    what it is
  normal      -           40 ms   0.0     an ordinary link, RTT ~80 ms
  latency     -           900 ms  0.0     RTT ~1800 ms
  loss10      -           -       0.10    packet loss, PLC and retransmit
  bandwidth   32Kbit/s    -       0.0     the live-audio floor
  narrow      16Kbit/s    -       0.0     the text and signalling floor
  loss60      -           -       0.60    heavy i.i.d. loss
  extreme     16Kbit/s    1000 ms 0.15    everything at once

Run them in that order — easiest first. A failure at `normal` means something is
wrong with the rig, not the app, and finding that out at `extreme` wastes hours.

THE SHAPER
  sudo tools/t2/net_shape.sh setup
  sudo tools/t2/net_shape.sh shape <bw> <delay> <plr>
  sudo tools/t2/net_shape.sh status        # ALWAYS confirm it took effect
  sudo tools/t2/net_shape.sh restore

net_shape.sh:338 records a run where shaping silently did not apply and the
numbers looked fine — a tooling failure wearing an app failure's label. Assert
the shaped RTT before every profile's run and abort the profile if it does not
match. A row measured under unverified shaping is worse than no row.

WHAT TO SEND ON EACH PROFILE
Through the app's own UI, not through a harness port:
  a text message
  a photograph
  a video note
  a voice note
For each: whether it arrived, whether it verified, and how long it took. If a
feature has no production wiring yet (LANE_TABLE.md says which), record it as
NOT WIRED rather than skipping it silently — the absence is the finding.

THE MONITOR BAR
The call screen now charts measured readings (apps/reference_app/lib/src/
live_quality_feed.dart, wired through CallSessionHandle.qualityReadings) with a
source chip reading "live path stats". On each profile, capture what the bar
shows and compare it against what the shaper was set to. They will not match
exactly — the bar reports the path, the shaper configures a pipe — but a bar
reading 40 ms under a 1000 ms profile is a defect, and it is exactly the kind
that only appears under load.

Extend the bar where it is thin. It should also show attempts and retries, not
only rate and round-trip time: on a bad link the question a person has is "is it
still trying", and a gauge that answers only "how fast" cannot answer it.
Whatever you add follows the existing rule — a figure with no live source gets a
visible label, never a comment.

EVIDENCE — this is a deliverable, not a by-product
Record the screen for every profile. On macOS:
  screencapture -v -V <seconds> <out.mov>     # no extra tooling needed
Save under tools/dossier/evidence/journey/<profile>.mov and write one TSV row
per profile-by-feature into tools/dossier/app_journey_results.tsv with the same
column discipline as e2e_ios_results.tsv: feature, profile, wire bytes, budget,
measured, status, note. Add every file to tools/dossier/manifest.tsv by running
tools/dossier/collect_evidence.sh, so the CI evidence gate covers them.

The recordings are for the funding dossier. Do not narrate them, do not edit
them, do not stage a retake because a run looked bad — a recording of a genuine
failure is worth more than a clean one, and this project's whole credibility
rests on that being true.

DIAGNOSE AND FIX AS YOU GO — full authority
When something breaks, fix it. The rules that bind you:
- Read the actual failure before designing the fix: the verbatim message, the
  stack, the elapsed time on the failing row. A handoff's stated cause is a
  hypothesis; the log is the evidence.
- Two failed attempts on the same thing means stop and say the approach is
  wrong. Do not spend a third.
- Back up each file to .backups/NNN-<path>.bak before editing.
- The pre-commit hook formats and analyses exactly what you stage. Do not
  bypass it.
- Never weaken a test, a threshold or a budget to make a row go green. If a
  budget is genuinely wrong, change it in a separate commit that says so and
  says why, with the measurement that justifies it.

VERIFY BEFORE YOU CALL IT DONE
  cd apps/reference_app && dart analyze --fatal-infos --fatal-warnings lib test
  cd apps/reference_app && flutter test              (319 passing today)
  dart format --output=none --set-exit-if-changed .
  bash tools/phase5/gates/gate_t5_docs.sh            (evidence hashes)
  tail -n +2 tools/dossier/manifest.tsv | awk -F'\t' '{print $3"  "$1}' | shasum -a 256 -c --strict

REPORT
One table: profile by feature, with the measured number and the verdict. Name
every profile that did not complete and why, in plain terms. A row you could not
produce is a finding — write it down rather than leaving the cell empty.
```

---

## The warning worth reading before you start

Two of these profiles are genuinely hard on the rig rather than on the app.
`net_shape.sh` documents a run at 32 kbit/s where the debugger's own traffic
starved the link and the failure was recorded as the app's. If a profile fails
in a way that implicates the harness, say so and move on rather than tuning the
app to satisfy a broken measurement.

And the honest expectation: some of these rows will not pass. Three features
have no production wiring, the datagram lane has no encryption, and nobody has
run this journey before. A report with red rows and their reasons is the
successful outcome here. A report with no red rows, produced in one pass, would
be the thing to distrust.
