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

## Not built

- Letter receive on the phone (a mailbox addressed to an install and a
  downlink on a lane), sealing letters to a pinned identity, and any
  carrier for them.
- A changed-key run on real devices.
