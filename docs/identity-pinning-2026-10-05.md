# Identity pinning and verification — state on 2026-10-05

What the app does about "who am I talking to", what was measured on real
devices, and what is not built. Lab rig only: one Mac and one iPhone on a
local bridge. Nothing here is a field result.

## The rule

Every install, with no switch and nothing to configure:

1. makes its own Ed25519 identity key once (the seed stays in the device
   keystore) and one random public install id;
2. in the first call that connects, sends `install id + public key +
   signature` over that call's own chat data channel, and pins the peer's
   key under the peer's install id;
3. reads **not yet verified** until the person compares the sixty-digit
   safety number on both screens and answers "They match";
4. stops the call when a different key arrives under a pinned install id.
   The pin and the confirmation of the pinned key stay: a confirmation is
   bound to its key, so a stranger's key can never read verified, and
   erasing it would let anyone who knows a public install id make the
   person verify again and again. Only the person's explicit "accept the
   new key" clears it, and the accepted key starts not verified.

Nothing in the app or the rig can produce "verified" except the person's
answer on the comparison sheet.

## Measured on the rig

Mac install `323c3ca6…`, phone install `da40df0b…`, the same two installs
throughout. Raw lines are in the run logs under `tools/dossier/logs/journey/`.

| Step | Mac | Phone |
| --- | --- | --- |
| First call | `check=pinnedFirstUse trust=unverified` | same |
| Second call | `check=match trust=unverified` | same |
| Safety number on screen | `67699 90978 49064 73094 71922 57345 44895 57618 26169 13277 01697 76645` | identical |
| After the owner's touch on each screen | `trust=verified` | `trust=verified` |
| Next call, no touch | `check=match trust=verified` | same |
| After hang-up, read by a fresh store | `verified_on_disk=true` | `verified_on_disk=true` |

The final run (commit `7fd89bd`) passed every row of the journey — call,
monitor bar, chat text, photo, voice note, video note — with the identity
exchange riding the same call.

## The Mac boot delay

The boot is timed in three parts. On an ad-hoc signed Debug build:

    keystore_ms=30373 pins_ms=35 other_ms=9

The thirty seconds were the login keychain's password prompt, which
returns on every rebuild because an ad-hoc signature makes each build a new
app. With one stable signature (`tools/t2/mac_local_signing.sh`, Debug only,
untracked, nothing committed about the certificate) and "Always Allow"
given once, a different binary booted in:

    keystore_ms=275 pins_ms=16 other_ms=16

Phones and properly signed releases never had this prompt.

## Built in code and unit tests only

No second install with the same install id exists on the rig, so these
were not seen on a device:

- **A changed key.** The call stops; the old key keeps its confirmation.
- **Accepting a legitimately new key.** The stopped call leaves a pending
  change; the person is asked twice; the new key replaces the pin and
  starts not verified; the old key then reads changed.
- **"Not the same" is remembered** for that key and shown on later calls
  until a match takes it back.

## Limits, stated plainly

- Trust on first use does not stop a signalling server that inserts itself
  into the very first call. Only the safety-number comparison does.
- Anyone who can present a pinned install id with another key can stop a
  call. They cannot become verified and cannot erase a confirmation.
- Identity keys sign; they do not seal. Letters are not locked with them,
  and the phone has no letter-receiving path yet.
- The rig peer shows the app's own comparison sheet, but it is a test
  entry point, not the shipped app screen.

## CI

The code this page describes is commit `d9b73e8` on
`plan-v4-waves-1-to-6`. Both workflows ran on that commit and finished
green on 2026-10-05:

| Workflow | CI run | Jobs |
| --- | --- | --- |
| CI | 37313336791 | Gate, Hygiene, Dependency audit, Packaging, Leak gate, Border relay — all success |
| Desktop | 37313341024 | Linux bundle, Windows bundle, Native core check — all success |

Before the push the full `reference_app` suite passed locally (721 of 721)
and so did the cheap gates. The last rig run was made at `7fd89bd`, one
rule change earlier: the changed-key rule in point 4 was changed after it
and is covered by unit tests only.

## Round two — the desktop start and the Mac's files

Commit `aac47c8`, same day. CI run 37320495408 and Desktop run 37320501665,
both green. Full `reference_app` suite locally: 730 of 730.

- **The window no longer waits for the keystore.** The identity boot is
  started and not awaited, and no call starts while it is in flight. One
  real run of the app through its own `main()` on the Mac:

      APP_START window_ms=1229 identity_pending_at_window=true identity=present identity_ready_ms=1452 keystore_ms=1335 pins_ms=99 other_ms=15

  The window was up while the identity was still pending. The keychain did
  not ask for its password in this run, so a window standing in front of an
  unanswered prompt was not observed — that case is unit-tested only.
- **A Mac keeps its parked letters and its card file in Application
  Support**, beside the identity file, carried over once from the temp
  folder. The real run reported `cards_dir=app_support queue_dir=app_support`.
  This Mac's old folder held no card file and no parked letter, so the
  carry-over itself ran only in unit tests.
- **Letter receive on the phone: there is no receive path.** Every letter
  lane (`HttpLongPollLane`, `WebSocketRelayLane`, `TxtQueryLane`) offers
  `probe()` and `send()` and nothing inbound; a letter ends as a file on the
  door's server, addressed to no install. The rig rows that decode a letter
  "on the phone" hand it to the phone inside the rig job. Nothing was built
  and nothing invented; sealing a letter to the pinned key was therefore not
  built either.

## Round three — sealed letters, both ways, on the rig

Commit `b306434`, same day, local only (not pushed). This replaces the
"there is no receive path" finding above: the path now exists.

**The design, in four sentences.** Each install has one mailbox, named by
its install id, on the border relay the letter lanes already use — the
relay's long-poll route with the install id where a call id would be, read
through a `receive` the lane always had on the server side and never on
the client. A letter is locked to the recipient's pinned identity key
itself (its X25519 twin; no second key to publish or pin), and the box
names nobody in the clear: sender id, sender key and signature are inside
the ciphertext, and everything is padded to 256-byte buckets so a receipt
and a short letter look the same. The recipient opens it, checks that the
key inside is the one it pinned, and puts a sealed receipt in the sender's
mailbox. The sender keeps the letter until that receipt and puts the box
in again until it comes.

**Both directions, same Mac and same phone** (run 2026-10-05T15:51:17Z,
all six journey rows PASS in the same run; the letters crossed the relay
over the internet, not the call):

    MAC   sealed_tx from=323c3ca6c1105f43449749bb8d799496 to=da40df0bd869287ecf8200228f302ed8 bytes=48 id=fdc83cc0… attempts=1 receipt_from_recipient=true opened_shown_on_screen=true waited_ms=862
    PHONE rx        from=323c3ca6c1105f43449749bb8d799496 to=da40df0bd869287ecf8200228f302ed8 bytes=48 box_bytes=313 opened=true verified=true
    PHONE tx        from=da40df0bd869287ecf8200228f302ed8 to=323c3ca6c1105f43449749bb8d799496 box_bytes=313 attempt=1 deposited=true
    MAC   sealed_rx from=da40df0bd869287ecf8200228f302ed8 to=323c3ca6c1105f43449749bb8d799496 bytes=45 id=e7b9b2d8… opened=true verified=true text_on_screen=true waited_ms=2002
    PHONE tx        id=e7b9b2d8… attempt=2 deposited=true
    PHONE receipt_rx id=e7b9b2d8… from=323c3ca6… attempts=2

The Mac side is the real app: the letter was typed into its panel and sent
with its button, and the phone's letter was read off its screen. The phone
side is the rig peer running the same service and the same panel; its
lines are the service's own events, and its screen was not read by a
machine. The phone's letter needed a second attempt before its receipt
came back — the retry rule doing its job on real devices.

**What the real relay does** (measured from the Mac): a frame for a side
that is not reading returned 200 after 2 s and 8 s, and 204 after 15 s and
30 s; a side already waiting got it at once. So the relay keeps a box for
seconds, not for an absent recipient. That is why an install announces "I
am reading my mailbox now" (one more sealed box, kind `here`) to its pinned
peers when it starts. Against the real relay with two throwaway installs:

    LIVE_RELAY away   away_s=30 relay_still_had_it=false opened_after_return=true receipt=true attempts=2 total_ms=33029
    LIVE_RELAY queued attempts_while_closed=1 delivered_after_open=true attempts=2

**Limits, stated plainly.**

- Both installs must be reading within the same few seconds for a letter
  to cross. A letter to someone who is away waits in the sender's queue,
  not on a server. True store-and-forward needs the relay to persist
  boxes, which is a change to the deployed relay and was not made.
- Anyone who knows a public install id can read — and so remove — that
  mailbox's boxes, or fill it. They cannot open or forge one. The relay
  has no way to tell the owner from anyone else.
- Not forward secret on the recipient's side: the recipient's half of the
  agreement is its identity key.
- A `here` tells a pinned peer who is listening that this install is
  online.
- "The path was closed" was shown by closing it at the client; the relay
  itself was never down during a run.

## Round four — one side off, and photo, voice, video

Local only (not pushed). Lab rig: the same Mac and the same phone.

**Read first: the pair shelf cannot be built on the deployed relay.** By
the repo's `broadcast.js`, `/o/<hash>` is write-once, needs no credential
(the body must hash to its name) and is kept 48 h, and `/a/<author>/<seq>`
is write-once, kept 48 h and refuses a write without a valid credential
(403). But the DEPLOYED relay is an older build with no broadcast routes
at all: every `/o/` and `/a/` request, read or write, answered 404, and
`GET /` answered 404 "not found" where the repo's code serves a page.
Deploying the repo's worker is changing the public relay, which this work
may not do. So no shelf; the existing mailbox was taken further instead.

**Media.** A photo, a voice note or a video is a letter that describes it
(kind, type, size, SHA-256, pieces, duration) plus the pieces, each its own
sealed box of at most 48 000 bytes, up to about 3 MB. The recipient gives
its receipt only when the whole matches the description, and asks for
exactly the pieces it lacks.

**One side off at the moment of sending, both directions.** "Off" means
the app's process was not running; the phone app was terminated and
launched with `devicectl`, never reinstalled. Times are UTC.

| Direction | Kind | Bytes | Sent | Opened on the other device | Receipt back |
| --- | --- | --- | --- | --- | --- |
| Mac → phone (phone off) | text | 69 | 16:57:29.4 | 16:58:04.0 | 16:58:05.1 |
| Mac → phone (phone off) | photo | 101 738 | 16:57:30.4 | 16:58:04.5 | 16:58:05.1 |
| Mac → phone (phone off) | voice, 30 s | 64 715 | 16:57:31.6 | 16:58:05.1 | 16:58:05.4 |
| Mac → phone (phone off) | video, 10 s | 38 103 | 16:57:32.1 | 16:58:05.4 | 16:58:05.5 |
| phone → Mac (Mac app off) | text | 51 | 16:59:04.1 | 17:01:51.0 | 17:01:52.2 |
| phone → Mac (Mac app off) | video, 10 s | 38 103 | 16:59:04.4 | 17:01:51.9 | 17:01:52.2 |
| phone → Mac (Mac app off) | voice, 30 s | 64 715 | 16:59:04.9 | 17:01:51.9 | 17:01:52.7 |
| phone → Mac (Mac app off) | photo | 101 738 | 16:59:05.3 | 17:01:53.5 | 17:01:53.7 |

The phone was switched on at 16:58:03 and had opened all four by 16:58:05.
The Mac app was started at 17:00:10 (its build takes most of two minutes)
and had opened all four by 17:01:53; in between the phone's journal shows
five attempts per letter with no receipt, then the Mac's "I am reading my
mailbox now", then the sixth attempt with every piece. The SHA-256 of each
file that opened on the Mac equals the file the Mac had sent
(`b7591bd9`, `a95fcc79`, `2c5eb559`).

What that table is and is not:

- "Opened" is the app's mailbox service opening and verifying the letter
  on that device, with the time it did so; on the phone it is read from
  the phone's own event journal, copied off the device.
- The phone wrote the text itself. The photo, voice note and video it sent
  were the ones it had just received — it has nothing to pick from
  unattended. The bytes crossed in both directions; nothing was recorded
  or photographed on the phone.
- The phone was asked to write by a line in the Mac's own sealed text
  (`#rig-reply-after=60`), a convention of the rig peer only. A launch-time
  switch was tried first and never reached the app.
- While the phone was off the Mac app's screen read, for the two rows in
  view, "in queue — put in their mailbox 2×, no receipt: they are not
  reading it · again in 8s", and afterwards "opened by them". The other
  two rows were outside the visible part of the list and were not read off
  the screen. The phone's screen was not read by a machine at all.
- The voice note and the video are shown as a line with their size and
  length; playing them from the panel is not built. The photo is drawn.

## Round five — the line: written, closed, and opened most of an hour later

Lab rig, the same Mac and the same phone. This replaces round four's "a
letter crosses only when both apps are running within the same few
seconds": that is no longer true.

**The relay.** The repo's relay was deployed to the same account on
2026-10-05 (version `40300297-2a59-4809-9b4c-1fa98a821ac0`; before it,
`2c33b6f2-9d11-4fe2-a2f2-2f064ea86d46` from 2026-07-27, which matched repo
commit `61c39e3`). A probe of the call lanes and the mailbox gave the same
answers before and after. The archive routes now exist: `PUT /o/<sha256>`
201, the same bytes again 204, other bytes 400, read back identical — and
still identical 2 h 15 min later; `PUT /a/<author>/<seq>` without a valid
credential 403. The two-day retention is the code's constant; it was not
waited out.

**The pair shelf.** One author feed of that archive, used by exactly two
installs. Its key is derived from the secret they already share — X25519
between their pinned identity keys — with the direction and the day, so
both can compute its address and nobody else can; and because the archive
is write-once nobody can take anything off it. The sender puts each sealed
box at `/o/<sha256>` and a pointer at the next number; the recipient reads
forward from where it stopped. Letters, pieces and receipts all go there;
the long-poll mailbox only rings.

**The run.** An app writes a text, a photo, a 30 s voice note and a 10 s
video and is closed. The other side's app is started at least 45 minutes
later, with the writer's app not running. UTC, 2026-10-05, code `b846f5e`:

| Direction | Kind | Bytes | Sent | Opened on the other device | After | Receipt read by the sender |
| --- | --- | --- | --- | --- | --- | --- |
| Mac → phone | text | 69 | 18:43:17 | 19:30:05 | 46 min 48 s | 20:20:45 |
| Mac → phone | photo | 101 738 | 18:43:19 | 19:30:07 | 46 min 48 s | 20:20:45 |
| Mac → phone | voice, 30 s | 64 715 | 18:43:21 | 19:30:07 | 46 min 46 s | 20:20:45 |
| Mac → phone | video, 10 s | 38 103 | 18:43:24 | 19:30:08 | 46 min 43 s | 20:20:46 |
| phone → Mac | text | 51 | 19:31:07 | 20:20:46 | 49 min 39 s | 20:21:10 |
| phone → Mac | video, 10 s | 38 103 | 19:31:08 | 20:20:47 | 49 min 39 s | 20:21:10 |
| phone → Mac | voice, 30 s | 64 715 | 19:31:10 | 20:20:47 | 49 min 37 s | 20:21:10 |
| phone → Mac | photo | 101 738 | 19:31:12 | 20:20:47 | 49 min 35 s | 20:21:10 |

The Mac app exited at 18:43:37 and was not started again until 20:18:52.
The phone app was launched at 19:29:59 and terminated at 19:32:37, then
launched once more at 20:21:07 for its receipts. Each side read its
receipts on its own next start, with the other side off. The SHA-256 of
each file that opened on the Mac equals the file the Mac had first sent
(`b7591bd9`, `a95fcc79`, `2c5eb559`).

What that table is and is not:

- "Off" means the app's process was not running; the devices themselves
  were on, awake and connected.
- Three times during the two gaps iOS listed a process for the phone app
  that this run had not launched (once before each planned launch, and once
  in between). The app's own event journal has no entry inside either gap
  — the service writes one the moment it starts — and the letters opened
  six seconds after the planned launch. Two of those processes were
  terminated by hand before the Mac came on. What started them was not
  established; a system that prepares an app's process ahead of time would
  look like this.
- The phone wrote its text itself; the photo, voice note and video it sent
  were the ones it had received. It was asked to write by a line in the
  Mac's own sealed text, a convention of the rig peer only.
- "Opened" on the phone is read from the phone's own journal, copied off
  the device; its screen was not read by a machine. On the Mac three of
  the four received rows were read off the screen; the text row was outside
  the visible part of the list.

Found on the way, not part of this work and not fixed: a BINARY frame sent
over the relay's WSS lane arrives at the other side as the text
"[object Blob]" (a text frame arrives intact). It behaved the same before
and after the deploy.

## Round six — nothing rings: letters are found by looking

What round five cost the relay was never measured, only computed, and the
computation was bad: one open install with one pinned peer held a 20 s
request open around the clock and asked four day shelves at the end of
each — about 21,600 requests and 10,400 GB-s of held connection a day, on
a relay every install shares. Two such installs were more than the relay's
free allowance of held time. Round six removes the held request and puts
every request under a count.

What is different (commits 78e2e77 … 4f8ed67, 2026-10-06):

- No request is held open and no letter goes through the long-poll
  mailbox; `mailbox_door.dart` is gone and the service has only the pair
  shelf. Nobody is told that an install came on: the "I am here" box is no
  longer sent, and one from an older install is opened and ignored.
- A reader looks: every 3 s for two minutes after a write, an opened
  screen or an arriving letter, then at twice the interval each time, down
  to once in 15 minutes. The look asks today's shelf, and yesterday's until
  ten minutes past UTC midnight; the other days are asked every half hour.
  A writer never goes back a day, so a day read to its end after its
  writer was seen on a later day is closed and never asked again.
- Every request is taken from a daily allowance before it leaves (3000 a
  day; looking stops at 2400 so writing keeps a share), timed, and cut off
  at 1.8 s — a request carrying a piece of media may stay open longer, in
  proportion to its size. The count is on the diagnostics screen and
  outlives a relaunch.
- "On" is a line in the app's journal: `start`, then `alive` every thirty
  seconds with the request count and the longest open request. The rig
  scripts read that, not a process list, and end by closing the phone app
  and waiting for its journal to fall silent.

Measured on the rig, same Mac and same iPhone, the relay over the internet:

```
warm, 10 texts each way, 12:56–13:00Z    10/10
  median written -> opened    Mac -> phone  <= 3792 ms   (raw 2708)
                              phone -> Mac  <= 3269 ms   (raw 2099)
  the two clocks differ by between -1085 and +1170 ms, bounded from
  the data alone; the line is 5000 ms

hour run, 13:01–14:45Z                    8/8
  Mac -> phone: text 69 B, photo 101738 B, voice 64715 B, video 38103 B
    written 13:03:55–13:04:01, opened on the phone 13:50:31–33 (46:31–46:36),
    receipts read by the Mac 14:41:56
  phone -> Mac: the same four, written 13:51:32–36, opened on the Mac
    14:41:56–57 (50:21–50:24), receipts read by the phone 14:42:19,
    SHA-256 b7591bd9 / a95fcc79 / 2c5eb559 as sent
  the phone's journal has no line between its two sessions

idle, both apps open, one pinned peer, 14:48–22:50Z (8 h)
                       Mac                 phone
  alive lines          961, gap 30 s       961, gap 30 s
  requests in 8 h      98  (x3 = 294/day)  98  (x3 = 294/day)
  looks                79 fast, 17 slow    79 fast, 17 slow
  anything else        none                none
  longest open         2832 ms             944 ms
```

The idle count is the one the lab predicted to the request (98 when the
peer wrote that day; `test/sealed_idle_cost_test.dart` gives 114 and 130
for a peer who wrote yesterday or never — at most 390 a day, under the
line of 400 in every state).

What was NOT seen: "no request open longer than two seconds", on the Mac.
Two of its 98 requests, at 22:15:37Z and 22:30:38Z, were open 2832 and
2491 ms before the app's own cut ended them — a cut set for 1800 ms that
ran about a second late, twice, in the same quarter-hour in which the
phone and a `curl` from the same Mac reached the relay in half a second.
The cause was not established. What it means: a cut inside the app cannot
promise "never above two seconds" on a Mac whose process can be held for
a second by something outside it; a hard ceiling has to be the relay's own
(phase j of the plan, not built). The phone kept every request under
944 ms for eight hours.

The suite ran three times through `tools/safe_flutter_test.sh` at 5bfd731
(817 of 817; 442, 433 and 424 s against a limit of 630) and the thirteen
cheap gates were green. The leak gate now reads a trace stamped by an
injected clock and gives the same number every run (7.756566). None of
this was pushed.

## Not built

- Playing a sealed voice note or video in the panel; recording or picking
  media on the phone without a person.
- The one-time key in a receipt (forward secrecy on the recipient's side).
- A letter that nobody opens within about two days is shelved again by the
  sender's app — which must be running then. Nothing keeps it longer.
- A ceiling on how long a request stays open that the relay itself
  enforces; the app's own cut ran late twice in eight hours on the Mac.
- Looking costs one request per pinned peer per look once that peer has
  written today (up to four before that); fine for tens of peers, not
  measured beyond two.
- A link on which connect, TLS and a request take longer than 1.8 s: every
  look is cut there and letters wait until it is faster (phase b of the
  plan is the answer).
- Any carrier for other people's boxes.
- A changed-key run on real devices.
