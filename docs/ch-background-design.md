# Phase چ — a sealed letter seen with the app closed (design, 2026-10-11)

decision: BGTaskScheduler app-refresh only, behind the compile-time flag SEALED_BACKGROUND; the rig build alone carries the plist keys; iOS picks the wake time and the run records what it did, never an estimate.

## Goal and acceptance line

The phone is locked and the app has not been opened during the test window.
A text letter arrives over the TXT lane, a local notification is posted, and
the receipt returns to the Mac. If the line is not seen, the report gives a
one-line cause and keeps "iOS did not grant" apart from "the code did not".

## Wake source

- Only `BGTaskScheduler` + `BGAppRefreshTaskRequest` (`UIBackgroundModes` gets `fetch`).
- Not used: `performFetchWithCompletionHandler`, APNs, PushKit. A wake without a server is only the OS background task.
- `earliestBeginDate` is a floor, not a promise. The time is iOS's.
  `T+x = bg_turn.begin - mac tx.at`. With no `bg_turn` in the window, x = none.

## Flag and build split

- Dart: `const kSealedBackground = bool.fromEnvironment('SEALED_BACKGROUND')`.
  Every use is behind the const, so a normal build drops the code and its strings.
- The plist keys are static, so they live only in a rig-only plist variant:
  `fetch` and `BGTaskSchedulerPermittedIdentifiers = [<bundle>.sealed.refresh]`.
  The tracked `ios/Runner/Info.plist` stays `UIBackgroundModes [audio, voip]`.
- Swift registers the task only if `Bundle.main` lists the id in
  `BGTaskSchedulerPermittedIdentifiers`. Registering an id that is not in the
  plist crashes the app, so the normal build never registers.
- The flag build is a `--profile` build (a debug build is never woken without a
  debugger), TXT-only: `SEALED_TXT_ONLY=true`, `SEALED_TXT_PORT=5300`.
  HTTPS arrival never counts.

## Turn

1. Register before launch ends, in `application(_:didFinishLaunchingWithOptions:)`.
2. The handler first resubmits the next request, then sets the expiration handler, then runs the Dart turn over a background method channel / headless engine.
3. Budget: whole turn ≤ 25 s; lane drain inside the turn ≤ 15 s. Look, rx and receipt_tx happen inside it.
4. Expiration → journal `expired` and `setTaskCompleted(false)`.
5. `bg_until` is on disk, set by the rig. Past it: `setTaskCompleted(true)`, no resubmit, no network.
6. The local notification has no content: a fixed title, no sender, no text.

Two modes are covered: an engine that is suspended but alive, and a cold
background launch without a scene. The launch reason goes into the journal.

## Journal events

```
bg_registered(id, refresh_status, low_power, notif_auth)
bg_submitted(id, submitted_at, earliest)
bg_turn(id, launch_reason, app_state, protected_data, begin, end, expired, lane)
notify_local(letter_id, auth, add_err)
bg_cancelled(id)
```

## Files

- `apps/reference_app/lib/src/sealed/sealed_background.dart` (new): flag, turn runner, deadline, journal events, notification call.
- `apps/reference_app/lib/src/sealed/sealed_letter_service.dart`: ≤ 3 Edits, only a bounded one-shot drain entry for the turn.
- `apps/reference_app/ios/Runner/` Swift: guarded register, handler, channel. Rig-only plist variant.
- `tools/t2/sealed_ch_verdict.py` + `test_sealed_ch_verdict.py`, `tools/t2/sealed_ch_rig.sh`.

## Verdict exit codes

| rc | meaning |
|----|---------|
| 0  | PASS: tx(id).at = T < bg_turn.begin ≤ rx ≤ receipt_tx ok ≤ notify_local(authorized, no error) ≤ bg_turn.end; protected_data false; lane txt; no screen/foreground in the window; Mac receipt_rx; give.log PUT+GET within the turn ±5 s |
| 10 | iOS did not grant: bg_submitted present, no bg_turn, settings ok |
| 11 | owner setting: passcode, auto-lock, notif_auth, refresh_status, low_power |
| 12 | network: phone off the bridge, no give GET in the turn |
| 13 | code: bg_turn without rx / receipt_tx / notify_local, or expired |

## Rig (one 8 h window)

Run by a separate `nohup tools/t2/sealed_ch_rig.sh`. Install over the existing
app, never delete it first. Launch once via devicectl, see `bg_registered`,
then go to background without a kill (launch `com.apple.Preferences`) and let
auto-lock lock the phone. Prove 2 × BEAT_GAP_S of loop silence first, then the
Mac sends one text at T. Inside the window: no launch, no phone_on, no pf
whitelist; txt_give.py runs the whole window. Lock state is sampled every 60 s
into lock.tsv. A forced run via LLDB `_simulateLaunchForTaskWithIdentifier` is
labelled forced=true, never counts, and never sits in source.

## End (every termination path)

One launch with `SEALED_BG_CANCEL=1` → `cancelAllTaskRequests`, `bg_cancelled`,
delivered-notification list. Then phone off with the journal unchanged for
75 s, Mac app closed, pf off, txt_give stopped, normal profile build installed
over the flag build. No push.
