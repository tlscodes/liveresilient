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

## Result: NOT proven. One-line cause
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
