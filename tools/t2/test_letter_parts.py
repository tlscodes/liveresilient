#!/usr/bin/env python3
"""letter_parts.py without a network: ten parts back to the original bytes,
one missing part is incomplete and never an exception, the golden the Dart
side also pins, and the collector's deadline. Run: python3 tools/t2/test_letter_parts.py"""
import hashlib
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import letter_parts as lp  # noqa: E402

GOLDEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "goldens", "letter_parts_10.bin")


def golden_payload() -> bytes:
    return (bytes(range(256)) * 160)[:40000]


def read_golden() -> list[bytes]:
    data = open(GOLDEN, "rb").read()
    parts, at = [], 0
    while at < len(data):
        n = int.from_bytes(data[at:at + 2], "big")
        parts.append(data[at + 2:at + 2 + n])
        at += 2 + n
    return parts


class Parts(unittest.TestCase):
    def test_bare_under_cap(self):
        small = bytes(4096)
        self.assertEqual(lp.split_letter(small), [small])
        self.assertIsNone(lp.parse_part(small))

    def test_ten_parts_round_trip_any_order(self):
        payload = golden_payload()
        parts = lp.split_letter(payload, letter_id=0x0BADCAFE)
        self.assertEqual(len(parts), 10)
        self.assertTrue(all(len(p) <= 4096 for p in parts))
        asm = lp.LetterAssembler(0x0BADCAFE)
        order = list(range(10))
        random.Random(7).shuffle(order)
        for i in order:
            self.assertTrue(asm.add(lp.parse_part(parts[i])))
        self.assertTrue(asm.is_complete)
        self.assertEqual(asm.missing, [])
        self.assertEqual(asm.assemble(), payload)

    def test_one_missing_is_incomplete_not_a_crash(self):
        parts = lp.split_letter(golden_payload(), letter_id=1)
        asm = lp.LetterAssembler(1)
        for i, p in enumerate(parts):
            if i != 6:
                asm.add(lp.parse_part(p))
        self.assertFalse(asm.is_complete)
        self.assertEqual(asm.missing, [6])
        self.assertIsNone(asm.assemble())
        self.assertTrue(asm.add(lp.parse_part(parts[6])))
        self.assertEqual(asm.assemble(), golden_payload())

    def test_duplicate_foreign_and_lying_total_refused(self):
        parts = lp.split_letter(golden_payload(), letter_id=2)
        other = lp.split_letter(golden_payload(), letter_id=3)
        asm = lp.LetterAssembler(2)
        self.assertTrue(asm.add(lp.parse_part(parts[0])))
        self.assertFalse(asm.add(lp.parse_part(parts[0])))
        self.assertFalse(asm.add(lp.parse_part(other[1])))
        lying = bytearray(parts[1]); lying[9] = 4
        self.assertFalse(asm.add(lp.parse_part(bytes(lying))))
        self.assertEqual(len(asm.parts), 1)

    def test_corrupted_slice_is_digest_mismatch(self):
        parts = lp.split_letter(golden_payload(), letter_id=4)
        asm = lp.LetterAssembler(4)
        for i, p in enumerate(parts):
            b = bytearray(p)
            if i == 3:
                b[100] ^= 0xFF
            asm.add(lp.parse_part(bytes(b)))
        self.assertTrue(asm.is_complete)
        with self.assertRaises(lp.LetterDigestMismatch):
            asm.assemble()

    def test_more_than_ten_refused(self):
        with self.assertRaises(lp.LetterTooLong):
            lp.split_letter(bytes(lp.max_total_bytes() + 1))
        self.assertEqual(len(lp.split_letter(bytes(lp.max_total_bytes()), letter_id=5)), lp.MAX_PARTS)
        self.assertEqual(lp.MAX_PARTS, 100)

    def test_not_mistaken_for_picture_or_voice(self):
        self.assertIsNone(lp.parse_part(b"\xff\xd8\xff" + bytes(64)))
        self.assertIsNone(lp.parse_part(b"\x11\xd4\x02\x00" + bytes(64)))
        self.assertIsNone(lp.parse_part(bytes(5)))

    def test_golden_matches_this_splitter(self):
        golden = read_golden()
        ours = lp.split_letter(golden_payload(), letter_id=0x0BADCAFE)
        self.assertEqual(golden, ours)
        asm = lp.LetterAssembler(0x0BADCAFE)
        for g in golden:
            asm.add(lp.parse_part(g))
        self.assertEqual(hashlib.sha256(asm.assemble()).hexdigest()[:16], "93355f732da85531")

    def test_collector_completes_once_and_expires_the_rest(self):
        clock = [0.0]
        col = lp.LetterPartsCollector(deadline_s=100.0, now=lambda: clock[0])
        a = lp.split_letter(golden_payload(), letter_id=10)
        b = lp.split_letter(golden_payload(), letter_id=11)
        self.assertIsNone(col.observe(b"plain letter, not a part"))
        for p in a[:-1]:
            self.assertIsNone(col.observe(p))
        for p in b[:-1]:
            self.assertIsNone(col.observe(p))
        lid, whole = col.observe(a[-1])
        self.assertEqual((lid, whole), (10, golden_payload()))
        self.assertIsNone(col.observe(a[-1]))  # already delivered: no second whole
        clock[0] = 200.0
        expired = col.expired()
        self.assertEqual(expired, [(11, 9, 10, [9])])
        self.assertEqual(col.open_ids, [])


class ResponderDrain(unittest.TestCase):
    """txt_query_server.drain_complete with parts: the whole is logged like a
    session under the letter's id and written as <idhex>.letter; nine of ten
    parts leave no whole and no exception."""

    def _drain(self, payloads, letter_dir):
        import logging
        import tempfile
        import txt_query_server as srvmod
        srvmod._PARTS = None  # a fresh collector per test

        class Stub:
            def __init__(self, items):
                self.items = list(items)

            def take_complete(self):
                items, self.items = self.items, []
                return items

        records = []
        handler = logging.Handler()
        handler.emit = lambda r: records.append(r.getMessage())
        srvmod.log.addHandler(handler)
        level = srvmod.log.level
        srvmod.log.setLevel(logging.INFO)
        try:
            n = srvmod.drain_complete(Stub(payloads), letter_dir)
        finally:
            srvmod.log.removeHandler(handler)
            srvmod.log.setLevel(level)
        return n, records

    def test_ten_parts_become_one_whole_under_the_id(self):
        import tempfile
        payload = golden_payload()
        parts = lp.split_letter(payload, letter_id=0x0BADCAFE)
        with tempfile.TemporaryDirectory() as d:
            n, lines = self._drain([("s%02d" % i, p) for i, p in enumerate(parts)], d)
            self.assertEqual(n, 10)
            whole = os.path.join(d, "0badcafe.letter")
            self.assertTrue(os.path.exists(whole))
            self.assertEqual(open(whole, "rb").read(), payload)
        sha = hashlib.sha256(payload).hexdigest()
        self.assertIn("complete session=0badcafe bytes=40000 sha256=%s" % sha, lines)
        self.assertTrue(any(l.startswith("part id=0badcafe index=10/10") for l in lines))

    def test_nine_parts_no_whole_no_exception(self):
        import tempfile
        parts = lp.split_letter(golden_payload(), letter_id=0x0BADCAFE)
        with tempfile.TemporaryDirectory() as d:
            n, lines = self._drain([("s%02d" % i, p) for i, p in enumerate(parts[:-1])], d)
            self.assertEqual(n, 9)
            self.assertFalse(os.path.exists(os.path.join(d, "0badcafe.letter")))
            self.assertEqual(len([f for f in os.listdir(d) if f.endswith(".letter")]), 9)
        self.assertFalse(any("complete session=0badcafe" in l for l in lines))


if __name__ == "__main__":
    unittest.main(verbosity=2)
