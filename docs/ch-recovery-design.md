# ch recovery — letter survives phone off/on, no network, relay expiry, restarts

Owner ask 2026-10-12 ~00:50Z: even if the phone is off then on, or any other
plausible condition, the letter must be recovered. Research (read-only, Opus
agent, 2026-10-12) — file:line pointers, verify before editing.

## Facts today
- Relay pair shelf keeps 48 h (pair_shelf.dart:3-5, relay broadcast.js:63
  RETENTION_MS). The old "8-15 s box" note is stale. txt_give.py stores nothing.
- Sender re-shelves an un-receipted letter every 40 h (shelfRefresh,
  sealed_letter_service.dart:204,721,732); failed deposit backoff 5 s→5 min
  (:200-201,771-777). Only while the Mac app runs; on start, flush (:1265).
- Receive dedupe by id, _kept on disk, never pruned (:843,868-872).
- Foreground launch catches up: main.dart:375 load+start, :1247-1248
  retryWaiting + look(ShelfLook.all).
- BGTask registered in didFinishLaunching (AppDelegate.swift:18-21), submitted
  every launch (:690-716).

## Gaps → fixes (implement in this order, one file at a time, tests one at a time)
1. Swift runTurn (AppDelegate.swift ~:775-797, inside #if SEALED_BACKGROUND):
   resubmit only after Dart replies → expiry / 27 s backstop / no engine break
   the chain. Fix: submit() FIRST; on resubmit:false cancel the request; also
   submit on applicationDidEnterBackground.
2. Before first unlock (protected_data=false): DiskJsonStorage.load returns {}
   (disk_json_storage.dart:45-55), _loaded=true (:437), a later atomic _save can
   WIPE outbox/inbox/cursors. Fix in sealed_background.dart SealedBackgroundTurn.run:
   protectedData==false → journal bg_turn skipped:'locked', no service, resubmit:true;
   install() never caches `own` from such a turn; ShelfLook.fast after the first turn.
3. Receipt expired (Mac off >48 h): phone re-answers a duplicate only when
   !kept.receiptOk (:873-880) → Mac re-shelves forever. Fix: _Kept.receiptAt;
   re-answer a duplicate when receiptAt older than 24 h (≤1 extra PUT per 40 h).
   Old files without receipt_at must parse.
4. Resume from suspension waits up to coldEvery 15 min (main.dart:403-407).
   Fix: on resumed call _sealed?.touch('resume') → look within warmEvery 3 s.
5. Rig: sealed_ch_mac_test.dart matches by s.at.isAfter(started); add
   SEALED_CH_RESUME_ID define so a restarted Mac run waits on that id.
Normal build must stay clean (.autorun/ch_build_check.sh greps bg_turn,
SEALED_BG, sealed.refresh, SealedBackgroundTask).

## iOS limits (no code can beat them) → fallback
Force-quit, Low Power, Background App Refresh off, before first unlock: no bg
turn; fallback = catch-up on next open/unlock (fix 4) + sender re-shelve.
Turn timing is always iOS's choice. Pending BG request across reboot: unmeasured.

## Request budget (per install per day)
bg turn ShelfLook.all = 4 GET/peer; 15-min floor → 96 turns × 4 = 384 max;
with fast after first ≈ 96-192. Idle foreground measured 98 / 8 h.
Account quota 100 000/day (PLAN-LETTERS-2026-10-06.md:46); per-install cap 3000,
look stops at 80 % (relay_requests.dart:120-151).

## Tests (mock, no device)
sealed_background_test.dart: (a) protectedData:false → no service, no notify,
resubmit:true, skipped:'locked'; (b) relay down → looked:false resubmit:true;
(c) turn after a locked turn sees the real stored outbox; (d) same id two turns
→ one notify_local.
pair_shelf_test.dart (expireEverything pattern :494): (e) receipt expired, +41 h,
flush, phone re-answers duplicate, Mac delivered (fails today); (f) both off
50 h → inbox exactly 1; (g) Mac relaunch mid-wait → delivered.
sealed_schedule_test.dart: (h) touch('resume') cold → look within warmEvery.
sealed_letter_service_test.dart: (i) _Kept without receipt_at parses.
Device (owner, morning): power-cycle the phone after a letter is sent, locked;
expect bg_submitted before each bg_turn and after every bg_expired/bg_task_end.

## Rule while w2 runs
No flutter/dart test or build until .autorun/ch_device_done exists (8 GB iMac
hangs on concurrent flutter). Edits are fine; runs wait.
