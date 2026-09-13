#!/usr/bin/env python3
"""Pin the dnsvalve row: the four facts, and every way the run can miss one.

Each test states one condition the design makes load-bearing, so a later edit
cannot turn a run green that never proved carriage by the valve — and cannot
turn a run red without saying which fact was missing.

  python3 tools/t2/test_journey_dnsvalve_rows.py
"""
import hashlib
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import journey_dnsvalve_rows as rows  # noqa: E402

RUN_EPOCH = 1_757_000_000.0  # a fixed second on the Mac's clock
SESSION = 'abc123'
PAYLOAD = b'hello dns valve'
SHA = hashlib.sha256(PAYLOAD).hexdigest()
OTHER_SHA = hashlib.sha256(b'a different payload').hexdigest()
LANE = rows.LANE_ID


def at(offset: float) -> str:
    from datetime import timezone

    return (
        datetime.fromtimestamp(RUN_EPOCH + offset, tz=timezone.utc)
        .isoformat()
        .replace('+00:00', 'Z')
    )


def log_line(session=SESSION, sha=SHA, offset=12.0, nbytes=len(PAYLOAD), stamped=True):
    """One responder line, in the exact text tools/t2/txt_query_server.py logs."""
    body = f'complete session={session} bytes={nbytes} sha256={sha}'
    if not stamped:
        return body
    stamp = datetime.fromtimestamp(RUN_EPOCH + offset).strftime('%Y-%m-%d %H:%M:%S,%f')[:-3]
    return f'{stamp} {body}'


# A line from an earlier run of the same fixture: same payload, different
# message. It must never satisfy this run's row.
STALE_LINE = log_line(session='zzz999', offset=-4000.0)
GREEN_LOG = '\n'.join(
    [
        '2026-09-13 19:00:00,000 udp/0.0.0.0:5300 tunnel.valve.test',
        STALE_LINE,
        log_line(),
    ]
)


def green_events() -> list[dict]:
    return [
        {'event': 'boot', 'at': at(0)},
        {
            'event': 'lane',
            'stage': 'registered',
            'at': at(2),
            'ids': ['resilient.wss', 'resilient.https', LANE],
        },
        {'event': 'lane', 'stage': 'wan_probe', 'at': at(3), 'reachable': False},
        {
            'event': 'lane',
            'stage': 'selected',
            'at': at(9),
            'best_lane_id': LANE,
            'mode': 'degraded',
            'valve_score': 0.3,
            'valve_down': False,
            'lanes': [
                {'id': 'resilient.wss', 'eligible': False, 'score': 0.9},
                {'id': 'resilient.https', 'eligible': True, 'score': 0.05},
                {'id': LANE, 'eligible': True, 'score': 0.3},
            ],
        },
        {
            'event': 'lane_chat',
            'at': at(10),
            'outcome': 'sentLive',
            'best_lane_at_send': LANE,
            'session_id': SESSION,
            'sha256': SHA,
            'bytes': len(PAYLOAD),
        },
        {'event': 'ended', 'at': at(30), 'reason': 'localHangUp'},
    ]


def build(events=None, log=GREEN_LOG, run_start_epoch=RUN_EPOCH, budget_s=120.0):
    return rows.build_row(
        green_events() if events is None else events,
        log,
        lane_id=LANE,
        profile=rows.PROFILE,
        budget_s=budget_s,
        run_start_epoch=run_start_epoch,
    )


def without(stage: str) -> list[dict]:
    return [
        e for e in green_events()
        if not (e.get('event') == 'lane' and e.get('stage') == stage)
    ]


def replace_stage(stage: str, patch: dict) -> list[dict]:
    events = []
    for event in green_events():
        if event.get('event') == 'lane' and event.get('stage') == stage:
            event = dict(event)
            event.update(patch)
        events.append(event)
    return events


class GreenRow(unittest.TestCase):
    def test_all_four_facts_make_the_row_pass(self):
        row = build()
        self.assertEqual(row[5], 'PASS', row[6])
        self.assertEqual(row[0], 'dns_valve_chat')
        self.assertEqual(row[1], 'dnsvalve')
        self.assertEqual(row[2], str(len(PAYLOAD)))
        self.assertEqual(row[3], '120')
        self.assertEqual(row[4], '12.0')
        self.assertNotIn('fail=', row[6])
        # A green row states the WAN lanes' scores, never a verdict token that
        # a reader could skim as a failure.
        self.assertNotIn('wan_alive(', row[6])

    def test_the_row_is_always_seven_cells(self):
        for events in (green_events(), [], without('selected'), without('registered')):
            row = build(events=events)
            self.assertEqual(len(row), 7, row)
            self.assertTrue(all('\t' not in cell for cell in row))

    def test_the_note_carries_the_evidence_a_reader_needs(self):
        note = build()[6]
        for fragment in (
            'wan_probe=False',
            f'registered=resilient.wss+resilient.https+{LANE}',
            'mode=degraded',
            f'best_lane={LANE}',
            'valve_score=0.3',
            'wan=wss=off,https=0.05',
            f'best_lane_at_send={LANE}',
            f'session={SESSION}',
            f'sha256={SHA[:16]}',
            'responder_lines=2',
            'measured_from=mac_run_start',
        ):
            self.assertIn(fragment, note)

    def test_other_event_kinds_and_extra_fields_are_ignored(self):
        events = green_events() + [
            {'event': 'blob', 'name': 'photo', 'bytes': 9},
            {'event': 'lane', 'stage': 'unknown_future_stage', 'whatever': 1},
        ]
        for event in events:
            event.setdefault('seq', 7)
        self.assertEqual(build(events=events)[5], 'PASS')

    def test_unparsable_lines_are_skipped_not_fatal(self):
        text = 'not json\n\n' + '\n'.join(json.dumps(e) for e in green_events())
        self.assertEqual(len(rows.load_events(text)), len(green_events()))


class MissingFacts(unittest.TestCase):
    def test_a_peer_without_the_branch_is_named_as_such(self):
        row = build(events=[{'event': 'boot', 'at': at(0)}, {'event': 'ended'}])
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('no_lane_events(peer_predates_dns_valve_branch)', row[6])
        self.assertEqual(row[2], '?')
        self.assertEqual(row[4], '-')

    def test_a_registration_without_the_valve_id_fails(self):
        events = replace_stage('registered', {'ids': ['resilient.wss', 'resilient.https']})
        row = build(events=events)
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('not_registered(ids=resilient.wss+resilient.https)', row[6])

    def test_a_live_wan_lane_fails_even_when_the_valve_ranks_first(self):
        events = replace_stage(
            'selected',
            {
                'lanes': [
                    {'id': 'resilient.wss', 'eligible': True, 'score': 0.9},
                    {'id': 'resilient.https', 'eligible': True, 'score': 0.05},
                    {'id': LANE, 'eligible': True, 'score': 0.3},
                ]
            },
        )
        row = build(events=events)
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('wan_alive(wss=0.9,https=0.05)', row[6])

    def test_an_unscored_eligible_wan_lane_is_not_proven_off(self):
        events = replace_stage(
            'selected',
            {
                'lanes': [
                    {'id': 'resilient.wss', 'eligible': True},
                    {'id': 'resilient.https', 'eligible': False, 'score': 0.05},
                    {'id': LANE, 'eligible': True, 'score': 0.3},
                ]
            },
        )
        row = build(events=events)
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('wan_alive(wss=?,https=off)', row[6])

    def test_a_reachable_border_relay_off_the_bridge_fails(self):
        events = replace_stage('wan_probe', {'reachable': True})
        row = build(events=events)
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('wan_reachable_off_bridge', row[6])

    def test_a_down_valve_is_named_even_when_it_was_selected(self):
        events = replace_stage('selected', {'valve_down': True})
        row = build(events=events)
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('valve_down', row[6])

    def test_carriage_without_selection_is_its_own_verdict(self):
        events = [
            e for e in green_events()
            if not (e.get('event') == 'lane' and e.get('stage') == 'selected')
        ]
        events.insert(
            3,
            {
                'event': 'lane',
                'stage': 'not_selected',
                'at': at(9),
                'best_lane_id': 'resilient.wss',
                'mode': 'normal',
                'valve_score': 0.1,
                'lanes': [
                    {'id': 'resilient.wss', 'eligible': True, 'score': 0.8},
                    {'id': 'resilient.https', 'eligible': True, 'score': 0.2},
                    {'id': LANE, 'eligible': True, 'score': 0.1},
                ],
            },
        )
        row = build(events=events)
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('never_selected', row[6])
        self.assertIn('carried_without_selection', row[6])
        self.assertIn('best_lane=resilient.wss', row[6])

    def test_selection_without_carriage_is_the_other_verdict(self):
        events = [e for e in green_events() if e.get('event') != 'lane_chat']
        events.append(
            {
                'event': 'lane_chat',
                'at': at(10),
                'outcome': 'queuedForLater',
                'session_id': SESSION,
                'sha256': SHA,
            }
        )
        row = build(events=events)
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('never_carried(outcome=queuedForLater)', row[6])
        self.assertNotIn('carried_without_selection', row[6])

    def test_no_chat_event_at_all_is_reported_as_absent(self):
        events = [e for e in green_events() if e.get('event') != 'lane_chat']
        row = build(events=events)
        self.assertIn('never_carried(outcome=absent)', row[6])

    def test_a_carriage_that_gave_up_fails(self):
        events = green_events() + [
            {'event': 'lane', 'stage': 'gave_up', 'at': at(40), 'mode': 'degraded'}
        ]
        row = build(events=events)
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('gave_up', row[6])

    def test_an_error_event_carries_its_text_into_the_note(self):
        events = green_events() + [
            {'event': 'lane', 'stage': 'error', 'at': at(11), 'error': 'SocketException'}
        ]
        row = build(events=events)
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('error(SocketException)', row[6])


class ResponderEvidence(unittest.TestCase):
    def test_an_empty_log_is_no_responder_line(self):
        row = build(log='')
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('no_responder_line', row[6])
        self.assertIn('responder_lines=0', row[6])
        # The phone's own byte count is still printed, marked by its source.
        self.assertEqual(row[2], str(len(PAYLOAD)))

    def test_the_same_digest_under_another_session_is_not_a_match(self):
        row = build(log=STALE_LINE)
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('no_responder_line', row[6])
        self.assertIn('responder_lines=1', row[6])

    def test_this_session_with_another_digest_is_not_a_match(self):
        row = build(log=log_line(sha=OTHER_SHA))
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('no_responder_line', row[6])

    def test_a_line_from_before_the_run_is_not_a_match(self):
        row = build(log=log_line(offset=-600.0))
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('no_responder_line', row[6])

    def test_an_unstamped_line_cannot_satisfy_a_run_scoped_row(self):
        row = build(log=log_line(stamped=False))
        self.assertEqual(row[5], 'FAIL')
        self.assertIn('no_responder_line', row[6])

    def test_without_a_run_start_the_phones_clock_anchors_the_number(self):
        row = build(run_start_epoch=None)
        self.assertEqual(row[5], 'PASS', row[6])
        self.assertIn('measured_from=phone_clock_first_lane_event', row[6])
        self.assertEqual(row[4], '10.0')  # first lane event at +2, line at +12

    def test_the_session_id_is_matched_case_insensitively(self):
        row = build(log=log_line(session=SESSION.upper()))
        self.assertEqual(row[5], 'PASS', row[6])

    def test_the_responder_byte_count_is_what_the_row_prints(self):
        row = build(log=log_line(nbytes=4096))
        self.assertEqual(row[2], '4096')

    def test_the_responders_own_line_is_what_this_parser_reads(self):
        """The two halves are pinned to ONE text, not to two copies of it.

        Every other case in this file writes the line itself; this one asks
        tools/t2/txt_query_server.py to render it, so a change to the
        responder's wording fails here instead of on the rig.
        """
        import txt_query_server

        stamp = datetime.fromtimestamp(RUN_EPOCH + 12.0).strftime('%Y-%m-%d %H:%M:%S,%f')[:-3]
        line = f'{stamp} {txt_query_server.complete_line(SESSION, PAYLOAD)}'
        parsed = rows.load_complete_lines(line)
        self.assertEqual(len(parsed), 1, line)
        self.assertEqual(parsed[0]['sha256'], SHA)
        self.assertEqual(parsed[0]['bytes'], len(PAYLOAD))
        row = build(log=line)
        self.assertEqual(row[5], 'PASS', row[6])

    def test_the_matched_line_is_parsed_field_by_field(self):
        parsed = rows.load_complete_lines(GREEN_LOG)
        self.assertEqual([p['session'] for p in parsed], ['zzz999', SESSION])
        self.assertEqual(parsed[1]['bytes'], len(PAYLOAD))
        self.assertAlmostEqual(parsed[1]['epoch'], RUN_EPOCH + 12.0, places=2)


class Cli(unittest.TestCase):
    def _files(self, tmp, events, log):
        events_path = os.path.join(tmp, 'phone_events.jsonl')
        log_path = os.path.join(tmp, 'dnsvalve.valve.log')
        with open(events_path, 'w', encoding='utf-8') as handle:
            handle.write('\n'.join(json.dumps(e) for e in events))
        with open(log_path, 'w', encoding='utf-8') as handle:
            handle.write(log)
        return events_path, log_path

    def _argv(self, events_path, log_path, tsv):
        return [
            'journey_dnsvalve_rows.py',
            '--events', events_path,
            '--valve-log', log_path,
            '--lane-id', LANE,
            '--profile', 'dnsvalve',
            '--budget-s', '120',
            '--run-start-epoch', str(RUN_EPOCH),
            '--tsv', tsv,
        ]

    def test_pass_exits_zero_and_writes_the_header_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            events_path, log_path = self._files(tmp, green_events(), GREEN_LOG)
            tsv = os.path.join(tmp, 'app_journey_results.tsv')
            self.assertEqual(rows.main(self._argv(events_path, log_path, tsv)), 0)
            self.assertEqual(rows.main(self._argv(events_path, log_path, tsv)), 0)
            lines = Path(tsv).read_text(encoding='utf-8').splitlines()
            self.assertEqual(lines[0], rows.HEADER.rstrip('\n'))
            self.assertEqual(len(lines), 3)
            for line in lines[1:]:
                cells = line.split('\t')
                self.assertEqual(len(cells), 7)
                self.assertEqual(cells[5], 'PASS')

    def test_a_failing_row_exits_one_and_is_still_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            events_path, log_path = self._files(tmp, green_events(), '')
            tsv = os.path.join(tmp, 'results.tsv')
            self.assertEqual(rows.main(self._argv(events_path, log_path, tsv)), 1)
            body = Path(tsv).read_text(encoding='utf-8')
            self.assertIn('no_responder_line', body)

    def test_an_unreadable_input_exits_two_and_still_leaves_a_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            events_path, log_path = self._files(tmp, green_events(), GREEN_LOG)
            tsv = os.path.join(tmp, 'results.tsv')
            argv = self._argv(os.path.join(tmp, 'absent.jsonl'), log_path, tsv)
            self.assertEqual(rows.main(argv), 2)
            body = Path(tsv).read_text(encoding='utf-8')
            self.assertIn('FAIL', body)
            self.assertIn('error(', body)


if __name__ == '__main__':
    unittest.main(verbosity=2)
