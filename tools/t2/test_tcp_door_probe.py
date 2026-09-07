#!/usr/bin/env python3
"""Pin the whitelist door probe's verdict table and its argument checking.

The probe's network behaviour needs the rig; its DECISION does not, and the
decision is the part a wrong edit would silently invert (a probe that passes
on two timeouts would call a dead link a whitelist).

  python3 tools/t2/test_tcp_door_probe.py
"""
import io
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tcp_door_probe as probe  # noqa: E402


class VerdictTable(unittest.TestCase):
    def test_definite_answer_on_allowed_and_silence_on_blocked_passes(self):
        self.assertEqual(probe.verdict('refused', 'timeout'), 'pass')
        self.assertEqual(probe.verdict('open', 'timeout'), 'pass')

    def test_open_network_fails(self):
        # Both ports answering means nothing is being blocked.
        self.assertEqual(probe.verdict('refused', 'refused'), 'fail')
        self.assertEqual(probe.verdict('open', 'open'), 'fail')

    def test_dead_link_fails(self):
        # Two timeouts is a dead link, not a whitelist.
        self.assertEqual(probe.verdict('timeout', 'timeout'), 'fail')

    def test_inverted_filter_fails(self):
        self.assertEqual(probe.verdict('timeout', 'refused'), 'fail')

    def test_error_on_allowed_fails(self):
        self.assertEqual(probe.verdict('error:65', 'timeout'), 'fail')


class Arguments(unittest.TestCase):
    def test_port_range_is_enforced(self):
        self.assertEqual(probe.parse_port('4443'), 4443)
        for bad in ('0', '65536', '-1', 'x'):
            with self.assertRaises(ValueError):
                probe.parse_port(bad)

    def test_wrong_argument_count_exits_two(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(probe.main(['tcp_door_probe.py']), 2)
            self.assertEqual(
                probe.main(['tcp_door_probe.py', 'h', '1', '2', '3', '4']), 2
            )

    def test_bad_port_exits_two_without_connecting(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(
                probe.main(['tcp_door_probe.py', '192.0.2.1', '99999', '12345']), 2
            )


if __name__ == '__main__':
    unittest.main(verbosity=2)
