"""Unit tests for sealed_ch_verdict.py — one fixture per exit code."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sealed_ch_verdict as v  # noqa: E402

LID = "21748e16a7d898f489ce7034ce835ee4"
T = "2026-10-11T20:00:00+00:00"


def at(minute, sec=0):
    return f"2026-10-11T{20 + minute // 60:02d}:{minute % 60:02d}:{sec:02d}+00:00"


REG = {"at": "2026-10-11T19:50:00+00:00", "event": "bg_registered", "id": "x.sealed.refresh",
       "refresh_status": "available", "low_power": False, "notif_auth": "authorized"}
SUB = {"at": "2026-10-11T19:50:01+00:00", "event": "bg_submitted", "id": "x.sealed.refresh",
       "submitted_at": "2026-10-11T19:50:01Z", "earliest": "2026-10-11T20:05:00Z"}


def turn(**kw):
    t = {"at": at(40, 20), "event": "bg_turn", "id": "x.sealed.refresh", "launch_reason": "bg_refresh",
         "app_state": "background", "protected_data": False, "begin": at(40), "end": at(40, 20),
         "expired": False, "lane": "txt"}
    t.update(kw)
    return t


def chain():
    return [
        {"at": at(40, 5), "event": "rx", "id": LID, "kind": "text"},
        {"at": at(40, 7), "event": "receipt_tx", "id": LID, "deposited": True},
        {"at": at(40, 8), "event": "notify_local", "letter_id": LID, "auth": "authorized", "add_err": None},
    ]


def build(phone, mac=None, give=True, lock="locked"):
    d = Path(tempfile.mkdtemp())
    (d / "meta.json").write_text(json.dumps({"letter_id": LID, "tx_at": T, "give_utc_offset_s": 0}))
    (d / "phone_journal.jsonl").write_text("".join(json.dumps(r) + "\n" for r in phone))
    mac = [{"at": at(41), "event": "receipt_rx", "id": LID}] if mac is None else mac
    (d / "mac_journal.jsonl").write_text("".join(json.dumps(r) + "\n" for r in mac))
    (d / "give.log").write_text(
        "2026-10-11 20:40:03,100 give GET /a/abc/1 -> 200 (114 B)\n"
        "2026-10-11 20:40:06,200 give PUT /a/def/1 -> 200 (0 B)\n" if give else "")
    (d / "lock.tsv").write_text("".join(f"{at(m)}\t{lock}\n" for m in range(0, 120)))
    return d


class Verdict(unittest.TestCase):
    def rc(self, d):
        return v.judge(d)[0]

    def test_pass(self):
        rc, lines = v.judge(build([REG, SUB, turn(), *chain()]))
        self.assertEqual(rc, v.PASS, lines)
        self.assertIn("x=2400s", " ".join(lines))

    def test_ios_did_not_grant(self):
        rc, lines = v.judge(build([REG, SUB]))
        self.assertEqual(rc, v.NOT_GRANTED)
        self.assertIn("x=none", lines)

    def test_forced_turn_never_counts(self):
        self.assertEqual(self.rc(build([REG, SUB, turn(forced=True), *chain()])), v.NOT_GRANTED)

    def test_owner_setting(self):
        reg = dict(REG, low_power=True)
        self.assertEqual(self.rc(build([reg, SUB, turn(), *chain()])), v.SETTING)

    def test_never_locked_is_setting(self):
        self.assertEqual(self.rc(build([REG, SUB, turn(), *chain()], lock="unlocked")), v.SETTING)

    def test_network_no_give(self):
        self.assertEqual(self.rc(build([REG, SUB, turn(), *chain()], give=False)), v.NETWORK)

    def test_doh_run_without_give_log_passes_on_phone_get(self):
        # phase چ: no Mac-side give.log; the phone's own relay_request GET is the witness
        get = {"at": at(40, 4), "event": "relay_request", "via": "txt", "method": "GET", "status": 200}
        d = build([REG, SUB, turn(), get, *chain()], give=False)
        (d / "give.log").unlink()
        rc, lines = v.judge(d)
        self.assertEqual(rc, v.PASS, lines)

    def test_https_get_is_not_a_txt_witness(self):
        get = {"at": at(40, 4), "event": "relay_request", "via": "https", "method": "GET", "status": 200}
        self.assertEqual(self.rc(build([REG, SUB, turn(), get, *chain()], give=False)), v.NETWORK)

    def test_network_no_mac_receipt(self):
        self.assertEqual(self.rc(build([REG, SUB, turn(), *chain()], mac=[])), v.NETWORK)

    def test_code_missing_notify(self):
        self.assertEqual(self.rc(build([REG, SUB, turn(), *chain()[:2]])), v.CODE)

    def test_code_expired(self):
        self.assertEqual(self.rc(build([REG, SUB, turn(expired=True), *chain()])), v.CODE)

    def test_code_https_lane(self):
        self.assertEqual(self.rc(build([REG, SUB, turn(lane="https"), *chain()])), v.CODE)

    def test_code_no_submit(self):
        self.assertEqual(self.rc(build([REG])), v.CODE)

    def test_opened_app_fails(self):
        seen = {"at": at(10), "event": "rig_screen", "id": LID}
        self.assertEqual(self.rc(build([REG, SUB, seen, turn(), *chain()])), v.CODE)

    def test_unusable(self):
        self.assertEqual(self.rc(Path(tempfile.mkdtemp())), v.UNUSABLE)


if __name__ == "__main__":
    unittest.main()
