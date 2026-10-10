#!/usr/bin/env python3
"""The on-screen matcher of sealed_hour_verdict.py on synthetic journals.

  python3 -m unittest tools/t2/test_sealed_hour_verdict.py
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from datetime import timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sealed_hour_verdict import (  # noqa: E402
    Inputs, RigLine, Row, close, journal, mac_to_phone, phone_to_mac, screen_seen, sent_seen, sha8, when)

SENT = "2026-10-10T00:10:34.405Z"
BODY = "written on the phone at 2026-10-10T00:10:34.065991Z"


def rx(letter_id, kind="text", sent=SENT):
    return {"event": "rx", "id": letter_id, "kind": kind, "sent_at": sent}


def screen(letter_id, text, kind="text", sent=SENT):
    return {"event": "rig_screen", "dir": "in", "id": letter_id, "kind": kind,
            "sent_at": sent, "screen_text": text}


class ScreenSeen(unittest.TestCase):
    def test_drawn_text_with_the_rows_sha_matches(self):
        rows = [rx("b244"), screen("b244", BODY)]
        self.assertEqual(sha8(BODY), "edbea39d")
        self.assertTrue(screen_seen(rows, "text", when(SENT), "edbea39d"))

    def test_same_kind_and_time_but_other_body_does_not_match(self):
        # The old matcher (kind + 5 ms + "written on the phone" substring) took this.
        rows = [rx("b244"), screen("b244", "written on the phone at 2026-10-09T21:06:45.139666Z")]
        self.assertFalse(screen_seen(rows, "text", when(SENT), "edbea39d"))

    def test_screen_line_of_another_letter_does_not_match(self):
        rows = [rx("b244"), screen("ffff", BODY)]
        self.assertFalse(screen_seen(rows, "text", when(SENT), "edbea39d"))

    def test_row_id_narrows_twin_letters(self):
        rows = [rx("aaaa"), rx("b244"), screen("aaaa", BODY)]
        self.assertTrue(screen_seen(rows, "text", when(SENT), "edbea39d"))
        self.assertFalse(screen_seen(rows, "text", when(SENT), "edbea39d", letter_id="b244"))

    def test_sent_more_than_5ms_apart_does_not_match(self):
        rows = [rx("b244", sent="2026-10-10T00:10:34.411Z"), screen("b244", BODY)]
        self.assertFalse(screen_seen(rows, "text", when(SENT), "edbea39d"))

    def test_media_matches_its_kind_summary_only(self):
        rows = [rx("e2e6", "photo"), screen("e2e6", "photo · 17 KB", "photo")]
        self.assertTrue(screen_seen(rows, "photo", when(SENT)))
        self.assertFalse(screen_seen(rows, "voice", when(SENT)))

    def test_text_without_a_sha_never_matches(self):
        rows = [rx("b244"), screen("b244", BODY)]
        self.assertFalse(screen_seen(rows, "text", when(SENT), None))


# The sender's own clock (µs); the receiver's row says .405Z.
SENT_US = "2026-10-10T00:10:34.405122Z"


def tx(letter_id, kind="text", sent=SENT_US):
    return {"event": "tx", "id": letter_id, "kind": kind, "sent_at": sent}


def sent_screen(letter_id, text, kind="text", sent=SENT_US):
    return {"event": "rig_screen", "dir": "out", "id": letter_id, "kind": kind,
            "sent_at": sent, "screen_text": text}


class SentSeen(unittest.TestCase):
    def test_senders_own_row_for_the_id_matches(self):
        rows = [tx("b244"), sent_screen("b244", BODY)]
        self.assertTrue(sent_seen(rows, "text", when(SENT), "edbea39d"))
        self.assertTrue(sent_seen(rows, "text", when(SENT), "edbea39d", letter_id="b244"))

    def test_inbound_line_or_another_letter_does_not_match(self):
        # The receiver's dir=in line is not the sender's screen, and a twin
        # with another id is not this letter.
        rows = [tx("b244"), screen("b244", BODY), sent_screen("ffff", BODY)]
        self.assertFalse(sent_seen(rows, "text", when(SENT), "edbea39d"))
        rows = [tx("b244"), sent_screen("b244", BODY)]
        self.assertFalse(sent_seen(rows, "text", when(SENT), "edbea39d", letter_id="ffff"))


EVIDENCE = Path(__file__).resolve().parents[2] / ".autorun/evidence/p_real"
VERDICT = Path(__file__).resolve().with_name("sealed_hour_verdict.py")


def run_verdict(out, *extra):
    return subprocess.run([sys.executable, str(VERDICT), str(out), "46", *extra],
                          capture_output=True, text=True)


def with_ids(src, dst, wrong_text=False):
    """A copy of an old run whose written and row lines carry id= right after
    kind=, taken from the Mac journal (tx for its own letters, rx for the
    phone's): the print side of the 2026-10-10 contract."""
    dst.mkdir()
    for f in src.iterdir():
        if f.name in ("mac_lines.txt", "mac_journal.jsonl") or f.name.startswith("phone_events_"):
            shutil.copy(f, dst / f.name)
    mac = journal(dst / "mac_journal.jsonl")
    out = []
    for line in (dst / "mac_lines.txt").read_text().splitlines():
        rl = RigLine.parse(line)
        if rl.tag in ("written", "row") and rl.get("id") is None:
            event = "rx" if rl.get("dir") == "phone_to_mac" else "tx"
            hit = next((r["id"] for r in mac if r.get("event") == event and r.get("kind") == rl.get("kind")
                        and close(when(r.get("sent_at")), when(rl.get("sent_at")))), None)
            if hit and wrong_text and rl.tag == "written" and rl.get("kind") == "text":
                hit = "f" * 32
            if hit:
                line = re.sub(r"( kind=\S+)", rf"\1 id={hit}", line, count=1)
        out.append(line)
    (dst / "mac_lines.txt").write_text("\n".join(out) + "\n")


@unittest.skipUnless((EVIDENCE / "full4/mac_lines.txt").exists(), "full4 evidence is not on this machine")
class Full4(unittest.TestCase):
    GOLD = EVIDENCE / "full4_rederive/verdict.txt"

    def test_old_lines_rederive_byte_identical_and_json_agrees(self):
        with tempfile.TemporaryDirectory() as tmp:
            js = Path(tmp) / "verdict.json"
            run = run_verdict(EVIDENCE / "full4", "--json", str(js))
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout, self.GOLD.read_text())
            doc = json.loads(js.read_text())
            self.assertEqual((doc["verdict"], doc["passed"], doc["rows_total"]), ("PASS", 8, 8))
            self.assertEqual({r["id_from"] for r in doc["rows"]}, {"journal"})
            self.assertTrue(all(r["on_screen"] and r["out_seen"] for r in doc["rows"]))

    def test_lines_with_ids_join_by_id_and_a_wrong_id_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            good, bad, js = Path(tmp) / "good", Path(tmp) / "bad", Path(tmp) / "good.json"
            with_ids(EVIDENCE / "full4", good)
            with_ids(EVIDENCE / "full4", bad, wrong_text=True)
            run = run_verdict(good, "--json", str(js))
            # The ids join; they never reach the table.
            self.assertEqual(run.stdout, self.GOLD.read_text())
            self.assertEqual({r["id_from"] for r in json.loads(js.read_text())["rows"]}, {"line"})
            run = run_verdict(bad)
            self.assertEqual(run.returncode, 1)
            self.assertTrue(run.stdout.splitlines()[-1].startswith("VERDICT hour FAIL rows=7/8"))

    def test_a_letter_the_mac_never_drew_fails_its_row(self):
        # Opened, receipt read, gap kept: only the Mac's rig_screen dir=in for
        # the phone's text is gone. That alone turns the row red.
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp) / "run"
            with_ids(EVIDENCE / "full4", run)
            gone = dropped(run / "mac_journal.jsonl", lambda e: e.get("event") == "rig_screen"
                           and e.get("dir") == "in" and e.get("kind") == "text")
            self.assertGreater(gone, 0)
            out = run_verdict(run)
            self.assertEqual(out.returncode, 1)
            self.assertTrue(out.stdout.splitlines()[-1].startswith("VERDICT hour FAIL rows=7/8"))
            row = next(l for l in out.stdout.splitlines() if l.startswith("phone -> mac   text"))
            self.assertEqual(row.split()[-4:-1], ["FAIL", "sha=edbea39d", "on_screen=false"])

    def test_a_receipt_row_naming_another_id_does_not_join(self):
        # The Mac's receipt row for its own text names another letter. Kind and
        # sent_at still match, but ids decide: no receipt, the row goes red.
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp) / "run"
            with_ids(EVIDENCE / "full4", run)
            self.assertGreater(renamed(run, "row", "mac_to_phone", "text", "f" * 32), 0)
            out = run_verdict(run)
            self.assertEqual(out.returncode, 1)
            self.assertTrue(out.stdout.splitlines()[-1].startswith("VERDICT hour FAIL rows=7/8"))
            row = next(l for l in out.stdout.splitlines() if l.startswith("mac -> phone   text"))
            self.assertEqual(row.split()[-3:], ["-", "FAIL", "on_screen=true"])


def dropped(path, pick):
    """Rewrite a copied journal without the events pick() selects; how many went."""
    kept, gone = [], 0
    for line in path.read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            event = None
        if isinstance(event, dict) and pick(event):
            gone += 1
        else:
            kept.append(line)
    path.write_text("\n".join(kept) + "\n")
    return gone


def renamed(run, tag, direction, kind, new_id):
    """In a with_ids() copy, the `tag dir=direction kind=kind` lines that name
    an id name new_id instead; how many changed."""
    path = run / "mac_lines.txt"
    lines = path.read_text().splitlines()
    changed = 0
    for i, line in enumerate(lines):
        rl = RigLine.parse(line)
        if rl.tag == tag and rl.get("dir") == direction and rl.get("kind") == kind and rl.get("id"):
            lines[i] = re.sub(r" id=\S+", f" id={new_id}", line, count=1)
            changed += 1
    path.write_text("\n".join(lines) + "\n")
    return changed


class PassRule(unittest.TestCase):
    """Row.ok is the whole PASS rule: opened at least the gap after it was
    written, the receipt read by the writer, and the receiver's own panel drew
    it. Each fact alone turns a row red. The sender's own screen does not
    decide the row; .autorun/verify_p.py gates on it."""
    NEED = timedelta(minutes=45)
    GOOD = Row(direction="phone -> mac", kind="text", size="51", sent=when(SENT),
               opened=when("2026-10-10T01:10:01.631533Z"), receipt=when("2026-10-10T01:11:02Z"),
               seen=True, out_seen=True, letter_id="b244", id_from="line", sha="edbea39d",
               in_view="false", note="")

    def test_every_fact_in_place_passes(self):
        self.assertTrue(self.GOOD.ok(self.NEED))
        self.assertTrue(replace(self.GOOD, out_seen=False).ok(self.NEED))

    def test_a_row_the_receiver_never_drew_fails(self):
        self.assertFalse(replace(self.GOOD, seen=False).ok(self.NEED))

    def test_a_receipt_never_read_fails(self):
        self.assertFalse(replace(self.GOOD, receipt=None).ok(self.NEED))

    def test_opened_inside_the_gap_or_never_fails(self):
        early = when(SENT) + self.NEED - timedelta(seconds=1)
        self.assertFalse(replace(self.GOOD, opened=early).ok(self.NEED))
        self.assertFalse(replace(self.GOOD, opened=None).ok(self.NEED))


class RowJson(unittest.TestCase):
    def test_flags_are_json_booleans(self):
        # in_view arrives as the line's text; --json carries it as true, false
        # or null, like on_screen and out_seen.
        doc = PassRule.GOOD.as_json(PassRule.NEED)
        for key, want in (("on_screen", True), ("out_seen", True), ("in_view", False), ("pass", True)):
            self.assertIs(doc[key], want, key)
        self.assertIsNone(replace(PassRule.GOOD, in_view=None).as_json(PassRule.NEED)["in_view"])


class IdAndBody(unittest.TestCase):
    def test_a_line_id_needs_its_own_event_at_that_time(self):
        # The id a line names narrows the journal's candidates and never
        # replaces them: no rx (or tx) within 5 ms, no match.
        rows = [rx("b244", sent="2026-10-10T00:10:34.411Z"), screen("b244", BODY)]
        self.assertFalse(screen_seen(rows, "text", when(SENT), "edbea39d", letter_id="b244"))
        rows = [tx("b244", sent="2026-10-10T00:10:34.411Z"), sent_screen("b244", BODY)]
        self.assertFalse(sent_seen(rows, "text", when(SENT), "edbea39d", letter_id="b244"))

    def test_media_needs_its_own_kinds_summary(self):
        # The photo errorBuilder's line, an empty row, a bare kind and another
        # kind's summary are not "<kind> · <size>".
        for shown in ("photo received — this device cannot draw its format", "", "photo"):
            rows = [rx("e2e6", "photo"), screen("e2e6", shown, "photo")]
            self.assertFalse(screen_seen(rows, "photo", when(SENT)), shown)
        rows = [rx("e2e6", "voice"), screen("e2e6", "photo · 17 KB", "voice")]
        self.assertFalse(screen_seen(rows, "voice", when(SENT)))
        rows = [rx("e2e6", "voice"), screen("e2e6", "voice · 17 KB · 4.0 s", "voice")]
        self.assertTrue(screen_seen(rows, "voice", when(SENT)))

    def test_each_direction_narrows_its_screen_to_the_rows_own_id(self):
        # Twin letters (same kind, sent_at within 5 ms) are both in the journal.
        # When the panel drew only the twin, the row's own letter was not seen.
        own, twin = "b" * 32, "f" * 32
        written = RigLine.parse(f"SEALED_RIG written dir=mac_to_phone kind=text id={own} sent_at={SENT} on_relay=true")
        got = RigLine.parse(f"SEALED_RIG row dir=phone_to_mac kind=text id={own} sent_at={SENT} opened_at={SENT}"
                            " opened=true sha=edbea39d")
        for drew, seen in ((twin, False), (own, True)):
            events = [rx(own), rx(twin), screen(drew, BODY)]
            inp = Inputs(fixtures={"text": "edbea39d"}, written=[written], mac_rows=[got],
                         mac_journal=events, phone=events, phone_all=events)
            self.assertIs(mac_to_phone(inp, "text").seen, seen, drew)
            self.assertIs(phone_to_mac(inp, "text").seen, seen, drew)


if __name__ == "__main__":
    unittest.main()
