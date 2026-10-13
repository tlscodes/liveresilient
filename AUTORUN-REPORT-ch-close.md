# AUTORUN REPORT — ch window close (2026-10-12)

## Night window 2026-10-12 21:29Z → 2026-10-13 06:29Z — NOT PASSED (rc=10)
Cause, one line: iOS granted no background launch in 9 h — the phone journal is
byte-identical (590521 B, last line 21:18:30Z) in a fresh copy taken after unlock at 06:35Z.

- Run dir `.autorun/evidence/ch/w_night_20261012T212438Z/`, same DoH build, no install,
  no launch (`CH_LOCKED_START=1`, new in `tools/t2/sealed_ch_rig.sh`), phone locked
  on the charger all night (`lock2.tsv`), letter `8eb2b926…` tx 21:29:56Z, receipt none.
- Fixed before the run: the phone held `sealed_bg_until=21:54Z` from the short window;
  any later turn would have been `past_until`, `resubmit=false`. Rewritten to 07:24Z.
- Verdict trap: the window-end copy is skipped while locked, so `verdict.txt` first
  judged a pre-window copy; re-checked by hand with a fresh copy (same bytes).

Short (15-min) locked-phone window for the sealed-letter ch path, DoH relay build.
Result: **window FAIL (rc=10)** — iOS granted no background refresh turn inside the
window, so the locked app never picked up the letter and no receipt returned. This is
the known iOS BGTaskScheduler blocker, not a code regression.

## Run
- Run dir: `.autorun/evidence/ch/w_short_20261012T205404Z/`
- Rig: `tools/t2/sealed_ch_rig.sh` (nohup, PID 98776), DoH build on HEAD inputs.
- Window: 900 s. Phone unlocked by owner → app installed, registered, backgrounded
  via Settings, then auto-locked (30 s) and stayed locked for the whole window.

## Verdict (verbatim, `verdict.txt`)
```
letter_id=3827521d72b61470b452d6e4a9673c3b
tx_at=2026-10-12T20:59:49.347367+00:00
window_end=2026-10-12T21:14:49.347367+00:00
earliest_floor=2026-10-12T21:10:17.896Z
x=none
cause: iOS did not grant — bg_submitted x25, no bg_turn in the window, settings ok
rc=10
```

## Evidence
- `bg_registered`: refresh available, notif authorized, launched_in_background.
- `bg_submitted`: 25 submissions; earliest floor 21:10:17Z (inside the window).
- `bg_turn` in-window: **0** (the 20 bg_turn lines in `phone_journal_last.jsonl` are
  cumulative from earlier sessions, all before this window's tx at 20:59:49Z).
- `lock2.tsv`: `open` through 20:57:37Z, then `locked` 21:13–21:15 — phone was locked
  across the send window, so the locked state was real.
- Letter tx at 20:59:49Z (`script.log`), window end 21:14:49Z, receipt **none**.
- Settings launched (app backgrounded): `script.log` "Launched application with
  com.apple.Preferences".

## Read
The ch path mechanics are proven (relay DoH responder live, build ships DoH, letter
sent, phone genuinely locked). The remaining gate is iOS itself: within this 15-min
window BGTaskScheduler never fired `sealed.refresh`, so the locked app got no CPU to
drain the mailbox. Short windows make a grant unlikely — iOS schedules bg refresh on
its own heuristics (hours, charging, usage), not on earliest-floor alone.

## Next
- Do NOT treat this as a code bug; the fix space is iOS scheduling, not the transport.
- Options to evaluate (consult Fable before editing): longer overnight window on
  charger; a silent-push wake path instead of pure BGAppRefresh; or widen the
  acceptance to count a bg_turn-triggered drain in a later window for the same letter.
