# The emergency letter — from the rig peer into the reference app (2026-09-20)

What this records: the "letter" — one text, one Codec2 voice take of up to
about 30 s, or one thumbnail — carried through the DNS TXT-query lane when the
live call's own paths are gone, and how that letter moved from the rig's
phone-side test harness into the reference app itself on 2026-09-20. Every
claim below names its evidence: a commit, a rig session id, a line of
`tools/dossier/app_journey_results.tsv`, or a test file. Numbers are read from
tool output, not from memory.

## Terms, because two "doors" exist in this repo

- **The door** here is the DNS TXT-query valve lane
  (`packages/adaptive_transport/lib/src/resilient/txt_query_{wire,transport,lane}.dart`,
  lane id `resilient.dns-valve`): a payload split into TXT queries that an
  authoritative responder for a zone reassembles. It is the last WAN lane the
  fabric holds (`ResilientFallbackLanes`, cost rank 3). The rig's responder is
  `tools/t2/txt_query_server.py` on the Mac at `192.168.2.1:5300`; the app's
  client is Dart, no helper process (moved in `6e8c95c`, see
  `session-record-2026-09-07-gates-that-could-not-fail.md`, Part 6).
- The "door" of `session-record-2026-09-05-gate-and-gateway.md` is the
  whitelist's permitted host:port. Different thing; not used in this document.
- **The letter** is the one payload the person hands to that lane. Its cap is
  `TxtQueryLane.maxPayloadBytes` = 4096 B and is read from the lane by every
  caller, never restated.
- **The rig peer** is `apps/reference_app/integration_test/journey_peer_app.dart`,
  a plain Flutter app installed on the rig phone and driven by
  `tools/t2/journey_run.sh` through the hub. **The app** is
  `apps/reference_app/lib/`.

The security review of the lane, its open defects and its rig history up to
2026-09-14 are in `txt_query_lane_security_review_2026-09-12.md` and
`OPEN_DEFECTS_txt_query_lane.md`; nothing there is repeated here.

## What the rig proved before this day (rows of `tools/dossier/app_journey_results.tsv`)

All rows are feature `dns_valve_chat`, profile `dnsvalve` (pf whitelist: TCP
to the Mac's relay/TURN/hub and UDP to the responder's port pass, everything
else dropped, so `wan_probe=False` and `mode=degraded` on every row and the
valve ranks first at send). `wire_B` is the letter's length; `measured_s` is
from the Mac run start; the responder's `sha256` matches the phone's on every
row. Line numbers are of the file at `7d8cfe8`.

| line | session | letter | wire_B | measured_s | note |
|-----:|---------|--------|-------:|-----------:|------|
| 479 | 37NHE2 | voice, Codec2 700C, 30 s, Mac-authored | 3007 | 30.7 | the ~30 s voice cap is this row: 3007 B fits under 4096 |
| 480 | 7PFRIU | typed on the phone, Send tapped | 1539 | 50.8 | first live typed letter |
| 481 | HAQNPG | voice recorded on the phone, ~2.4 s | 211 | 89.0 | the timeout fallback carried it |
| 497 | ATSH3G | typed | 1022 | 25.1 | |
| 506 | Q4N53Q | thumbnail picked on the phone, 92×200 | 3372 | 97.0 | the picture opened on the Mac (`5dac489`, picker fix `d7e85ea`) |

Voice is "about 30 s" because Codec2 700C at 30 s is 3007 B (line 479), under
the 4096 B cap with the wire's own overhead; a longer take is refused before
the send by the over-cap path (the rig peer's "letter too long" event, the
app's *not delivered · too long*), never truncated.

## What changed on 2026-09-20 — five commits

| commit | scope | what it did |
|--------|-------|-------------|
| `618e990` | rig peer + its test | one banner with four explicit states on the phone's Send window: **live call unavailable**, **queued**, **arrived**, **not delivered**; the photo button says *Thumbnail (≤3.5 KB)*, the voice button says *Record voice (30 s cap)*. Written once per transition, so the 1 s door heartbeat can never revert *arrived* to *queued*. |
| `34fc5aa` | app library + screen | the letter's states, composer and widgets moved into `lib/src/letter_composer.dart` and `lib/src/ui/letter_widgets.dart`; the peer now `extends LetterComposer` and re-exports the names, so its 58 tests kept importing them. New `lib/src/letter_courier.dart` carries a letter over the fabric the call already builds from `defaultBorderRelayEndpoints()` in `call_session.dart` — relay, long-poll, and the valve when `DNS_VALVE_DOMAIN` names a zone. New `lib/src/ui/letter_sheet.dart` is the app's Send window, opened from a *Letter through the door* action on the Chats screen (`conversations_screen.dart`, `main.dart`). |
| `991b686` | app | after `DeliveryOutcome.sentLive` the same bytes become a record in `LetterLedger` and a row in Chats (`letter_ledger.dart`, `ui/letter_thread.dart`); a letter whose door is DOWN is parked in a durable `LetterQueue` (`letter_queue.dart`, `letter_queue.json` under Documents on the phone, the system temp directory elsewhere) and carried once by a watch when the door answers again; a late answer after a timed-out carry is settled rather than dropped. Also appended four TSV rows (lines 507–510). |
| `8d98d8a` | app | the parked letter has its own Chats row — its preview, "· queued, door down", its queued time, and **no** status badge, because the sending badge is a `CircularProgressIndicator` and a letter that waits for hours is not in flight. |
| `7d8cfe8` | app | the thread page lists parked letters after the delivered ones and prints the lanes as the fabric last saw them (`relay -1.05 down · long-poll -1.10 down · door 0.60 up · mode degraded · best door`) from `LetterCourier.laneSnapshot`, which is published after refreshes the courier already performs — it is not a probe of its own. |

The commits touch `apps/reference_app/` only, plus the TSV. `journey_hub.py`,
the wire, the 4096 cap, the datagram lane (port 3737) and every public domain
or port were left alone on purpose.

## The route policy, as built

1. A live lane that ranks first with a positive score carries the letter.
2. When every call lane scores negative, the door carries it. The select loop
   refreshes the fabric for at most 60 s (12 s apart); on the rig the two dead
   WAN lanes sit at −1.05 / −1.10 and the valve overtakes them after its first
   probe round.
3. When the door is DOWN as well, the letter is parked in the durable queue and
   the banner and the Chats row both say *queued*. The watch carries it exactly
   once when the door answers again (in-flight guard, remove-before-record).
4. A live call never rides the door: the courier is a separate fabric beside
   the call, and the call stack builds none of this.
5. Every phase is bounded (select 60 s, carry 120 s), so no state is a spinner.

Refusals happen before the wire: a payload over 4096 B, and a build with no
lane configured at all, both end on *not delivered* with the reason.

## Verification on 2026-09-20 (each suite run alone, `flutter test`, Flutter 3.44.8)

| suite | result | what it pins |
|-------|-------:|--------------|
| `test/journey_peer_app_test.dart` | 58/58 | the rig peer, including the moved labels and the four banner states |
| `test/letter_courier_test.dart` | 15/15 | over-cap refused before any lane is built; a no-lane build says so; all lanes dead → *live call unavailable* → *queued / parked* (real loopback-refused sockets); the durable queue behind a down door with scripted lanes, drained once; a timed-out carry whose late answer is `sentLive` still reaches the ledger; a second Send while one is in flight is ignored |
| `test/letter_queue_store_test.dart` | 6/6 | the file store: tmp + rename, bounded, restore on start |
| `test/ui/letter_conversation_test.dart` | 8/8 | the Chats row for a delivered letter and for a parked one (no spinner), the thread with records, a parked bubble, the lane line, and the bubble turning into a record once drained |
| `test/letter_sheet_test.dart` | 2/2 | Send with nothing in hand is refused with a hint; a typed line reaches the courier and ends on a verdict |
| `flutter analyze` (whole app) | clean | the pre-commit hook also runs it |

Two hands-free rig runs of the same day, `JOURNEY_VALVE_LETTER_ONLY=1
JOURNEY_VALVE_CHAT_SOURCE=phone JOURNEY_VALVE_PHONE_WAIT_S=0
tools/t2/journey_run.sh dnsvalve`, on the peer built from `34fc5aa` and later:

| line | session | wire_B | measured_s | letter |
|-----:|---------|-------:|-----------:|--------|
| 509 | L5AJDQ | 96 | 25.1 | the default text (the phone's own line naming the run) |
| 510 | K2CHFX | 96 | 26.4 | the default text |

Lines 507 (T4QCBH) and 508 (EFJXEM) are the same run with a 90 s and a 120 s
Send window that nobody tapped; the timeout fallback carried the default
letter both times. The responder's per-session letter files under
`tools/dossier/logs/journey/` are ignored by git (`*.log` rule), so the TSV
line is the citation; the manifest row for the TSV was refreshed with
`tools/dossier/refresh_manifest_rows.py` in the commit that added this file
(CI's `hygiene` job verifies it: `tail -n +2 tools/dossier/manifest.tsv | awk … | sha256sum -c --strict`).

## Security note — this changes T28 of `security/THREAT_MODEL.md`

Until `991b686` the threat model could say there was no persistent queue. There
is one now: `FileLetterQueueStore` writes the parked letters' bytes, kind and
time as plaintext JSON to `letter_queue.json` (Documents on iOS/Android; the
system temp directory on desktop, where it lasts only until the process ends).
It is bounded (`LetterQueue.maxLetters`) and cleared as letters are carried.
At-rest encryption of that file is **not built**; the threat-model row is
updated in the same commit as this document to say so.

## The real app on the phone, 2026-09-21 — Chats → Letter → Send → row → thread

Not the rig peer: `lib/main.dart`'s `MyApp`, built in profile mode from
`integration_test/letter_autopilot_app.dart` (`9cab181`, `ffaba95`), which
boots the app and taps through it with a live widget controller the way a
person would, with no debugger attached (devicectl install + launch, no
Xcode tunnel). Mac side exactly as the rig: responder on `192.168.2.1:5300`,
the dnsvalve whitelist on bridge100. Each step is a hub event
(`/report`), each screen a PNG of the live widget tree (`/blob`). Evidence
in `tools/dossier/evidence/journey/media/app-letter/`:

| file | what |
|------|------|
| `dy3kyi-app-events.jsonl` | the 14 app events of the run (boot → DONE 22:19:23Z, `wc -l`) |
| `dy3kyi-1-sheet-verdict.png` | the sheet: banner **Letter arrived · 107 B · through the door · session DY3KYI**, the courier's raw lines under it |
| `dy3kyi-2-chats-row.png` | Chats: row *Letter through the door* first, the letter's text, double tick |
| `dy3kyi-3-thread.png` | the thread: lane line `door -0.13 up · relay -1.05 down · long-poll -1.10 down · mode degraded · best door`, the bubble, *through the door · session DY3KYI* |
| `dy3kyi.letter` | the 107 B the responder assembled: `from the app on the phone, 2026-09-20T22:19:18.158623Z: Letter tapped in Chats, this went out the DNS door.` — sha256 `d4c7183c690063d7…`, the same digest the responder logged |
| `seygmc.letter` | the previous run (22:10Z), same flow, whose thread step the autopilot itself failed to read (fixed in `ffaba95`) |

Timeline of the run, from the events: sheet open with the probe's verdict
*Live call unavailable · dns-valve=-0.14 wss=-1.05 https=-1.10* at
22:19:18; Send; *arrived* at 22:19:19 — one second, three chunks, one
session.

### The bug the first on-device run exposed, and its fix (`e71a2d5`)

The first run of the same flow (22:53Z on 2026-09-20) ended *queued · door
down · parked in the queue* while the responder's log showed it answering
every 12 s probe (20 `complete session … bytes=0` lines). The courier's
"usable lane" test was `score > 0`. The fabric scores a live lane as
health − costRank × 0.05, so a door with one reply's health (0.01) sits at
−0.14 — and a dead lane at `deadLaneScore` = −1.0 − penalty
(`packages/connection_orchestrator/lib/src/connection_fabric.dart:58-76`,
which records the same trap from 2026-09-13). The courier had become a
third ranking disagreeing with the two the fabric already reconciled.
Liveness is now "eligible and above −1.0" in the courier and on the
thread's lane line, pinned by `ScriptedLanes.doorFresh` (−0.14 → carried,
one deliver, one record) and by the lane-line test. Lesson, the same one
the repo already holds: one invariant, every ranking.

### Two rig traps met on the way (no code change)

- Installing a build over an app installed from another build chain made
  iOS refuse the launch ("invalid code signature, inadequate entitlements
  or its profile has not been explicitly trusted"); a clean
  `devicectl device uninstall app` + install fixed it every time.
- The first launch after an install needs the WAN for iOS's developer-app
  verification; with the whitelist loaded it is refused. Lift the filter
  (`net_shape.sh teardown`), launch once, reload the filter, relaunch.
- `flutter drive` (debug attach) asked Xcode 26.3 to download the iOS 26.2
  platform (10.47 GB); the profile-build + devicectl path needs none of it.

## What is still not in the reference app

- The app's Chats screen is driven by the autopilot, not by the rig's
  `journey_run.sh`: no TSV row is written for it, the evidence is the
  `app-letter/` directory above.
- The banner's transitions are printed on the phone's screen and console
  (`JOURNEY_PEER letter state: …`) and are not posted to the hub, so a TSV row
  cannot prove the UI states.
- The typed letters of 2026-09-21 (`DY3KYI`, `SEYGMC`) were typed by the
  autopilot into the app's own composer, not by a thumb on the keyboard;
  the last thumb-typed one is line 480 (`7PFRIU`, 2026-09-14).
- The thumbnail bubble has no widget test (no decodable image fixture in the
  test tree).
- The queue's persistence on desktop lasts until process exit; adding
  `path_provider` was out of scope for this day.
- Multi-lane fan-out (`a13b5d4`, `291e318`) is chat over the live call in the
  rig only, and has no relation to the letter.
