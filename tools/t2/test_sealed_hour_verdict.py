#!/usr/bin/env python3
"""The on-screen matcher of sealed_hour_verdict.py on synthetic journals.

  python3 -m unittest tools/t2/test_sealed_hour_verdict.py
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sealed_hour_verdict import screen_seen, sha8, when  # noqa: E402

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


if __name__ == "__main__":
    unittest.main()
