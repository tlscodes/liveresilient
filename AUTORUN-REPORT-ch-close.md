# AUTORUN report — phase چ close attempt (silent-push wake, locked phone)

_2026-10-13, device window on TLS's iPhone (iPhone 11 Pro Max, iOS 26.0)_

## Order
Build SEALED_BACKGROUND at HEAD (88280c4 content), install over the app (no delete),
wait for `push_token` with `shelves>=1`, then a 15-min locked window with `CH_WAKE=push`.
Accept only: letter arrives, silent push wakes the phone, receipt returns. No push to remote.

## What was done and verified
- Fresh rebuild at HEAD: empty marker commit `eb7ed51` opened the build-gate window;
  `.autorun/ch_build_check.sh` → **13/13 markers ok**, rig binary 14:47 now carries
  `push_token` / `push_register_err` (absent in the Oct-12 binary), `aps-environment`
  signed into `embedded.mobileprovision`, `codesign --verify` ok. Normal build is the
  negative control (no bg/push strings).
- Install + registration on the phone (never a delete):
  `bg_registered notif_auth=authorized registered=true`,
  `push_registered len=64 tail=fdc42529`,
  **`push_token len=64 tail=fdc42529 env=sandbox shelves=2`** — the token reached the
  relay (gate `shelves>=1` passed). Push Notifications is live on the App ID.
- Mac sent one letter `14caa4cfbb3cf83dd3467204b6e829de` at 2026-10-13T12:54:24Z;
  window 900 s to 13:09:24Z.

## Result (superseded 2026-10-13 by push_w4 below: PROVEN, rc=0): earlier NOT proven. One-line cause
**The phone was never locked during the window (owner setting: passcode or auto-lock
off) — `lock.tsv` recorded no locked sample, so the locked-push condition was never
exercised.** Verdict rc=11 (`.autorun/evidence/ch_real/push_w1/verdict.txt`).

Secondary: the only in-window `bg_turn` (13:04:37Z) DID find the letter
(`looked=true, fresh=1, resubmit=true`) but with `launch_reason=cold_bg`, not `push`.
So delivery on a backgrounded phone works; the silent-APNs-push wake on a *locked*
phone remains unproven because the phone stayed unlocked.

## Exact next action (owner-gated)
1. On the phone: set a passcode and a short Auto-Lock (Settings → Display & Brightness
   → Auto-Lock → 30 s) so the window actually locks.
2. Re-run, phone left to auto-lock, not touched:
   `CH_WAKE=push CH_WINDOW_S=900 bash tools/t2/sealed_ch_rig.sh .autorun/evidence/ch_real/push_w2`
3. Accept = a `bg_turn` with `launch_reason=push` inside the window while `lock.tsv`
   shows locked, letter `fresh=1`, receipt back. Unlock afterwards for the journal copy.

## Window w2 — 2026-10-13, phone locked (passcode + Auto-Lock 30 s)
- Run: `CH_LOCKED_START=1 CH_WAKE=push CH_WINDOW_S=900 sealed_ch_rig.sh .autorun/evidence/ch_real/push_w2`.
  LOCKED_START was added because the phone was already locked: same 14:47 binary,
  same registered token (`push_token_ack shelves=2`, tail fdc42529), no install,
  no launch, no unlock. `bg_until` refreshed while locked (copy accepted, to 16:03Z).
- Lock precondition met: `lock2.tsv` has 21 `locked` samples, first 14:03:53Z.
- Letter `08141e231ff16e9f0162142601be40de` sent 14:09:24Z, window to 14:24:24Z.
- Verdict, re-run on a fresh journal after the owner unlocked (16:27 local): **rc=10**.
  No `bg_turn` of any kind inside the window; the letter came in only after
  unlock, in the foreground (`start → rx → receipt_tx`), which is not accepted.
- Relay key check: `GET /p/probe` → `400 BadDeviceToken` (sandbox), so the APNs
  key and JWT are accepted (a bad key gives 403).

**Not proven. One-line cause: no push-woken turn reached the locked phone in the
window; the APNs key is proven, but there is no relay-side record showing that a
push was fired for this letter, so relay-side vs iOS-side cannot be told apart yet.**

Next step needed to tell them apart: the relay must log each fire result for
`/p/<author>` (status, apns_id). Then repeat w2 with `wrangler tail` open.
That is a worker deploy, so it needs owner approval.

## VCS
Local only, not pushed: `eb7ed51` (empty rebuild marker). No code change beyond the
already-committed `88280c4`. Evidence under `.autorun/evidence/ch_real/push_w1/`.

## push_w3 — headless-engine build (f2b1bcb + 25eeff1), 2026-10-13 15:25–15:46Z — rc=10, NOT accepted

Run: `CH_LOCKED_START=1 CH_WAKE=push CH_WINDOW_S=900 bash tools/t2/sealed_ch_rig.sh .autorun/evidence/ch_real/push_w3`
(previous window's markers archived in place to .autorun/archive/*.push_w2 first).

- Lock: lock2.tsv has 21 `locked` rows, 15:25:13Z → end; the phone stayed locked through the window.
- Letter 5c680312e9d1c7eb601e63d15b32157f sent 15:30:37Z; receipt: none. verdict.txt rc=10.
- Device syslog (push_w3_syslog.txt), 15:30:40–42Z: dasd opens com.tlscodes.referenceApp with
  UISHandleRemoteNotificationAction; Runner pid 26087 cold-launches, receives it in scene-create,
  `engine_attached headless=false`, Reply 66 ms later.
- Phone journal in the window: engine_attached, bg_registered, bg_submitted, push_registered (15:30:42Z).
  No push_rx, no bg_turn, no push_token, no ping_*/headless_* line.
- Acceptance line (bg_turn launch_reason=push, looked=true, fresh=1, receipt) NOT met. No cold_bg accepted.

**Cause, one line:** iOS delivered the push and the Dart engine was alive and journaling, but the Swift
push handler `didReceiveRemote` was never entered (no push_rx), so no turn ran.

Note: the verdict script's cause text "iOS did not deliver the push" is wrong for this run; delivery is
proven by the syslog. The headless fallback was not exercised (the scene engine was alive).

Next (not done): find why UIKit/Flutter does not route application(_:didReceiveRemoteNotification:
fetchCompletionHandler:) to the AppDelegate override on a scene cold launch — check the method in the
built binary (otool) and whether FlutterSceneDelegate/FlutterAppDelegate consumes it first.

Post-window, owner unlocked and opened the app (foreground, 15:49Z, outside the window): the letter 5c680312… arrived (rx) and its receipt went out (receipt_tx 15:49:24Z) over the TXT lane, plus two older letters. The letter path works in the foreground; this does NOT meet the acceptance line (no push turn while locked). Evidence: push_w3/phone_journal_after_open.jsonl.

## push_w4 — selector fix (51432dc), 2026-10-13 16:02–16:07Z — VERDICT ch PASS, rc=0

Times here are UTC (chat reports Netherlands local = UTC+2).

- Binary: 51432dc (`responds(to:)` claims the push-fetch selector), ch_build_check 13/13
  (build_check_w4.out). Installed OVER the locked phone at 15:56Z rc=0 (install_w4.log), no delete,
  no launch. Window: `CH_LOCKED_START=1 CH_WAKE=push CH_WINDOW_S=900`, dir
  .autorun/evidence/ch_real/push_w4 (+ push_w4_console.out, push_w4_syslog.txt).
- Lock: lock2.tsv locked throughout; the phone was never unlocked inside the window.
- 16:02:34Z Mac tx letter e79b407705e40623b0bd5d75e0b47052 (54 B).
- 16:02:38Z iOS delivered the content-available push; dasd cold-launched Runner (pid 26126).
- 16:02:41Z `push_rx` — the Swift handler ENTERED (w3's root cause closed); `engine_attached
  headless=false` (scene engine alive on the cold launch, the headless fallback was not needed).
- bg_turn launch_reason=push begin 16:02:41Z end 16:02:55Z, lane=txt, protected_data=false:
  relay_request PUT x4 (201) then GET over DoH; rx 16:02:48Z; receipt_tx 16:02:51Z deposited;
  notify_local 16:02:55Z authorized (syslog: notification 1D6E-ABD5 with alert content saved);
  app suspended 16:02:55Z.
- 16:02:53Z Mac receipt_rx for e79b4077 (mac.log `SEALED_CH receipt`); the window closed itself
  at 16:07:44Z on the receipt.
- Verdict: the first run read rc=12 "no give GET inside the turn" — a stale bridge-era rule:
  sealed_ch_verdict.py looked for GETs only in the Mac-side give.log, which a DoH run never has.
  Fixed (txt_gets: the phone's own `relay_request via=txt method=GET` rows are the witness, give.log
  kept for bridge runs; 15/15 unit tests incl. the two new DoH cases). Re-judged on the untouched
  evidence: `VERDICT ch PASS`, rc=0 (verdict.txt).

**Acceptance line met:** sealed text letter → locked, closed phone → push wake → TXT lane over DoH to
the existing relay → local notification → receipt back on the Mac, inside one window, app never opened.

- Push 2026-10-13 17:48:57Z (19:48 Amsterdam): plan-v4-waves-1-to-6 767afe1..c1b1a7a; CI run 38441795314 six of six jobs success. Runner pin b041b6f pushed after; CI run 38444591288 six of six success, zero annotations.
- 2026-10-13: phases Alef, Be, Pe and Che closed; Te, Se and Jim not started. Branch ready for continuation after resource confirmation. Tag: ch-phases-alef-to-che-closed
