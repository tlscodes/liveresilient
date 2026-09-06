#!/usr/bin/env python3
"""Pin the whitelist rows: the two numbers, the gap, and every FAIL rule.

Each test states one condition the design makes load-bearing, so a later edit
cannot quietly turn a queue-assisted or UDP-assisted run green.

  python3 tools/t2/test_journey_whitelist_rows.py
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import journey_whitelist_rows as rows  # noqa: E402

RUN_EPOCH = 1_757_000_000.0  # a fixed UTC second; the rows are relative to it


def at(offset: float) -> str:
    from datetime import datetime, timezone

    return (
        datetime.fromtimestamp(RUN_EPOCH + offset, tz=timezone.utc)
        .isoformat()
        .replace('+00:00', 'Z')
    )


def green_events() -> list[dict]:
    return [
        {'event': 'boot', 'at': at(1)},
        {'event': 'door_open', 'at': at(4), 't_ms': 4000, 'status': 200, 'bytes': 512},
        # The controls are emitted exactly as the phone emits them:
        # whitelist_door.dart ResetProbeResult.toJson -> {rst_ms, outcome, pass}
        # and QuicProbeResult.toJson -> {timeout_ms, outcome, pass}.
        {
            'event': 'door_closed_elsewhere',
            'at': at(5),
            'rst_ms': 12,
            'outcome': 'reset',
            'pass': True,
        },
        {
            'event': 'quic_dead',
            'at': at(6),
            'timeout_ms': 3000,
            'outcome': 'silent',
            'pass': True,
        },
        {
            'event': 'connected',
            'at': at(9),
            'connect_ms': 5000,
            'ice_pair_type': 'relay',
            'ice_pair_protocol': 'tcp',
            'rx_increasing': True,
        },
        # The shape the phone really posts: `door_samples` is a FIELD of the
        # `ended` report (journey_peer_app.dart:429), never an event of its own.
        {
            'event': 'ended',
            'at': at(60),
            'phase': 'ended',
            'reason': 'localHangUp',
            'door_samples': {'ok': 55, 'fail': 0},
        },
    ]


GREEN_RELAY = (
    '[signaling_server] at=%s room_member_joined callId=journeyKEY\n'
    '[signaling_server] at=%s room_rendezvous_complete callId=journeyKEY\n'
) % (at(7), at(8))
GREEN_SUMMARY = (
    'JOURNEY_APP summary outcome=Connected connect_ms=5000 '
    'queued_clips=0 degraded_voice_notes=0'
)


def build(
    events=None,
    relay=GREEN_RELAY,
    summary=GREEN_SUMMARY,
    window=120.0,
    run_epoch=RUN_EPOCH,
):
    return rows.build_rows(
        green_events() if events is None else events,
        relay,
        'journeyKEY',
        run_epoch,
        window,
        summary,
        'run=2026-09-05T00:00:00Z bw=- delay=- plr=0.0',
        'ports 4443/3478 stand in for 443/80',
    )


def with_event(name: str, fields: dict, replace: bool = False) -> list[dict]:
    """The green run with one event merged with — or replaced by — fields.

    `replace=True` drops every field the green event carried, which is how a
    pre-fix event shape (a timer and no verdict) is expressed.
    """
    events = []
    for event in green_events():
        if event['event'] != name:
            events.append(event)
        elif replace:
            events.append({'event': name, **fields})
        else:
            events.append({**event, **fields})
    return events


class GreenRun(unittest.TestCase):
    def test_two_rows_named_and_ordered(self):
        door, rendezvous = build()
        self.assertEqual(door[0], 'whitelist_door')
        self.assertEqual(rendezvous[0], 'whitelist_rendezvous')
        self.assertEqual(door[1], 'whitelist')
        self.assertEqual(len(door), 7)

    def test_numbers_are_seconds_from_run_start(self):
        door, rendezvous = build()
        self.assertEqual(door[4], '4.0')  # door_open.at
        self.assertEqual(rendezvous[4], '8.0')  # the relay's own line
        self.assertEqual(door[2], '512')  # the ordinary request's bytes
        self.assertEqual(rendezvous[2], '0')
        # The budget column prints like every other row's: a whole number.
        self.assertEqual(door[3], '120')
        self.assertEqual(rendezvous[3], '120')

    def test_gap_and_sources_are_in_the_note(self):
        _, rendezvous = build()
        self.assertIn('gap_s=4.0', rendezvous[6])
        self.assertIn('t_rendezvous_source=relay_log.room_rendezvous_complete', rendezvous[6])
        self.assertIn('phone_connected=9.0s', rendezvous[6])

    def test_both_pass(self):
        door, rendezvous = build()
        self.assertEqual(door[5], 'PASS')
        self.assertEqual(rendezvous[5], 'PASS')

    def test_note_carries_the_required_evidence(self):
        for row in build():
            for token in (
                'door_samples=55ok/0fail',
                'door_loop=held',
                'door_closed_elsewhere_rst_ms=12',
                'quic_dead_timeout_ms=3000',
                'ice_pair=relay/tcp',
                'rx_increasing=True',
                'queued_clips=0',
                'degraded_voice_notes=0',
                'stand in for 443/80',
                'run=2026-09-05T00:00:00Z',
            ):
                self.assertIn(token, row[6])

    def test_the_door_row_prints_its_own_elapsed_milliseconds(self):
        door, _ = build()
        self.assertIn('door_t_ms=4000', door[6])


class FailRules(unittest.TestCase):
    def test_queued_clips_fails_both_rows(self):
        door, rendezvous = build(summary=GREEN_SUMMARY.replace('queued_clips=0', 'queued_clips=3'))
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('queued_clips=3', rendezvous[6])

    def test_degraded_voice_notes_fails_both_rows(self):
        door, rendezvous = build(
            summary=GREEN_SUMMARY.replace('degraded_voice_notes=0', 'degraded_voice_notes=1')
        )
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')

    def test_missing_queue_proof_is_a_fail_not_an_unknown(self):
        door, rendezvous = build(summary='JOURNEY_APP summary outcome=Connected')
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')

    def test_a_blackout_event_fails_both_rows(self):
        events = green_events() + [{'event': 'blackout_bundle', 'at': at(20)}]
        door, rendezvous = build(events=events)
        self.assertIn('blackout_event_present', door[6])
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')

    def test_missing_negative_controls_fail(self):
        events = [e for e in green_events() if e['event'] != 'quic_dead']
        door, rendezvous = build(events=events)
        self.assertIn('no_quic_dead', door[6])
        self.assertEqual(rendezvous[5], 'FAIL')
        events = [e for e in green_events() if e['event'] != 'door_closed_elsewhere']
        self.assertIn('no_door_closed_elsewhere', build(events=events)[0][6])

    def test_a_non_relay_or_non_tcp_pair_fails_the_rendezvous_row(self):
        events = green_events()
        events[4] = dict(events[4], ice_pair_type='host', ice_pair_protocol='udp')
        door, rendezvous = build(events=events)
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('ice_pair=host/udp', rendezvous[6])
        self.assertEqual(door[5], 'PASS')  # the door row does not judge the media

    def test_counters_not_increasing_fails_the_rendezvous_row(self):
        events = green_events()
        events[4] = dict(events[4], rx_increasing=False)
        self.assertEqual(build(events=events)[1][5], 'FAIL')

    def test_a_gap_outside_the_budget_fails(self):
        door, rendezvous = build(window=2.0)
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('gap>2.0s', rendezvous[6])

    def test_a_non_200_door_fails_the_door_row(self):
        events = green_events()
        events[1] = dict(events[1], status=403)
        door, rendezvous = build(events=events)
        self.assertEqual(door[5], 'FAIL')
        self.assertIn('door_status=403', door[6])
        self.assertEqual(rendezvous[5], 'PASS')


class TheDoorIsJudgedOnItsOwnClock(unittest.TestCase):
    """The window judges `door_open.t_ms`, never seconds from the runner's start.

    journey_run.sh stamps RUN_EPOCH at line 77 and only posts the job after the
    macOS build (the runner waits up to 480 x 2.5 s for it, journey_run.sh:362),
    the phone launch and the stack wait. Seconds-from-run-start therefore
    measures the Mac's build; the loop's own elapsed milliseconds measure the
    door.
    """

    def test_a_cold_build_before_the_job_does_not_fail_the_door(self):
        # The phone gets the job at run+680 s; the very first GET answers 200
        # one second later. That is a door that opened immediately.
        events = green_events()
        events[1] = {
            'event': 'door_open',
            'at': at(681),
            't_ms': 1000,
            'status': 200,
            'bytes': 512,
        }
        events[4] = dict(events[4], at=at(683))
        relay = (
            '[signaling_server] at=%s room_rendezvous_complete callId=journeyKEY\n'
            % at(684)
        )
        door, rendezvous = build(events=events, relay=relay)
        self.assertEqual(door[4], '681.0')  # printed run-relative, as the row states
        self.assertEqual(door[5], 'PASS')
        self.assertEqual(rendezvous[5], 'PASS')
        self.assertIn('door_t_ms=1000', door[6])

    def test_a_slow_door_fails_on_its_own_milliseconds(self):
        events = green_events()
        events[1] = dict(events[1], t_ms=130_000)
        door, _ = build(events=events)
        self.assertEqual(door[5], 'FAIL')
        self.assertIn('door_t_ms>120.0s', door[6])

    def test_a_door_open_without_elapsed_milliseconds_is_a_fail(self):
        events = with_event(
            'door_open', {'at': at(4), 'status': 200, 'bytes': 512}, replace=True
        )
        door, _ = build(events=events)
        self.assertEqual(door[5], 'FAIL')
        self.assertIn('no_door_t_ms', door[6])


class TheLoopTotalsAreJudged(unittest.TestCase):
    """`door_samples` is read where the phone posts it, and it decides PASS."""

    def test_the_counts_are_read_from_the_ended_report(self):
        for row in build():
            self.assertIn('door_samples=55ok/0fail', row[6])

    def test_one_lucky_second_then_a_shut_door_fails_both_rows(self):
        events = with_event('ended', {'door_samples': {'ok': 1, 'fail': 298}})
        door, rendezvous = build(events=events)
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('door_samples=1ok<2ok', door[6])
        self.assertIn('door_loop=FAILED', rendezvous[6])

    def test_failures_outnumbering_successes_fail_both_rows(self):
        events = with_event('ended', {'door_samples': {'ok': 5, 'fail': 200}})
        door, rendezvous = build(events=events)
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('door_samples=5ok/200fail_majority_failed', door[6])

    def test_absent_counts_are_a_fail_not_an_unknown(self):
        events = [e for e in green_events() if e['event'] != 'ended']
        door, rendezvous = build(events=events)
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('door_samples_absent', door[6])

    def test_helper_reports_each_state_once(self):
        self.assertIsNone(rows.door_samples_failure({'ok': 2, 'fail': 0}))
        self.assertEqual(rows.door_samples_failure(None), 'door_samples_absent')
        self.assertEqual(rows.door_samples_failure({'fail': 0}), 'door_samples_absent')
        self.assertEqual(rows.door_samples_failure({'ok': 1, 'fail': 0}), 'door_samples=1ok<2ok')
        self.assertEqual(
            rows.door_samples_failure({'ok': 3, 'fail': 9}),
            'door_samples=3ok/9fail_majority_failed',
        )


class NegativeControlsAreJudgedNotCounted(unittest.TestCase):
    """A control that reported a number but not a pass must not make a row green.

    The reset control's number is the connect duration whatever the connect did.
    An unpopulated on-link blocked host answers no ARP, so no packet ever leaves
    the phone, pf's return-rst never fires, and the phone reports
    `{rst_ms: 1004, outcome: timedOut, pass: false}` — a number, and no proof.
    The same shape holds for QUIC with `outcome: error`.
    """

    def test_reset_control_that_timed_out_fails_both_rows(self):
        # The exact event an unpopulated on-link blocked host produces.
        events = with_event(
            'door_closed_elsewhere',
            {'rst_ms': 1004, 'outcome': 'timedOut', 'pass': False},
        )
        door, rendezvous = build(events=events)
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('reset_control=timedOut', door[6])
        self.assertIn('reset_control=timedOut', rendezvous[6])
        self.assertIn('reset_control=FAILED', door[6])

    def test_a_filter_that_never_loaded_fails_both_rows(self):
        # The connect SUCCEEDED to the host the filter must block, and the QUIC
        # datagram was answered: both report a number, neither reports a pass.
        events = with_event(
            'door_closed_elsewhere', {'rst_ms': 8, 'outcome': 'connected', 'pass': False}
        )
        events = [
            {'timeout_ms': 12, 'outcome': 'replied', 'pass': False, 'event': 'quic_dead', 'at': at(6)}
            if e['event'] == 'quic_dead'
            else e
            for e in events
        ]
        door, rendezvous = build(events=events)
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('reset_control=connected', door[6])
        self.assertIn('quic_control=replied', door[6])

    def test_quic_control_that_errored_fails_both_rows(self):
        events = with_event(
            'quic_dead', {'timeout_ms': 3000, 'outcome': 'error', 'pass': False}
        )
        door, rendezvous = build(events=events)
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('quic_control=error', door[6])

    def test_quic_control_that_got_an_answer_fails(self):
        events = with_event('quic_dead', {'outcome': 'answered', 'pass': False})
        self.assertIn('quic_control=answered', build(events=events)[0][6])
        self.assertEqual(build(events=events)[1][5], 'FAIL')

    def test_a_control_with_no_verdict_field_is_not_a_pass(self):
        # The pre-fix event shape: a timer and nothing else. It must not go green.
        events = with_event(
            'door_closed_elsewhere', {'at': at(5), 'rst_ms': 12}, replace=True
        )
        door, rendezvous = build(events=events)
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('reset_control=verdict_absent', door[6])

    def test_the_note_states_whether_each_control_held(self):
        for row in build():
            self.assertIn('reset_control=held', row[6])
            self.assertIn('quic_control=held', row[6])
            self.assertIn('door_closed_elsewhere_outcome=reset', row[6])
            self.assertIn('quic_dead_outcome=silent', row[6])

    def test_control_failure_helper_reports_each_state_once(self):
        self.assertIsNone(rows.control_failure({'pass': True}, 'reset_control', 'missing'))
        self.assertEqual(rows.control_failure({}, 'reset_control', 'missing'), 'missing')
        self.assertEqual(
            rows.control_failure({'pass': False, 'outcome': 'timedOut'}, 'reset_control', 'm'),
            'reset_control=timedOut',
        )
        self.assertEqual(
            rows.control_failure({'rst_ms': 1}, 'reset_control', 'm'),
            'reset_control=verdict_absent',
        )


class TheIndependentWitnessIsRequired(unittest.TestCase):
    """The relay's own line decides the rendezvous row; the phone corroborates."""

    def test_a_missing_relay_line_fails_the_rendezvous_row(self):
        # A relay started before the room_rendezvous_complete change, or one
        # whose log went somewhere else, leaves no line at all.
        door, rendezvous = build(relay='')
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('no_relay_rendezvous_line', rendezvous[6])
        self.assertIn('phone.connected(relay line absent)', rendezvous[6])
        self.assertEqual(rendezvous[4], '9.0')  # the phone's number, as a diagnostic
        self.assertEqual(door[5], 'PASS')  # the door row does not need the relay

    def test_a_relay_line_for_another_run_is_never_used(self):
        stale = '[signaling_server] at=%s room_rendezvous_complete callId=OTHERKEY\n' % at(3)
        _, rendezvous = build(relay=stale)
        self.assertEqual(rendezvous[4], '9.0')  # falls back to the phone
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('no_relay_rendezvous_line', rendezvous[6])
        self.assertIn('relay_line=absent_for_callId_journeyKEY', rendezvous[6])

    def test_a_relay_and_phone_that_disagree_fail_the_rendezvous_row(self):
        events = with_event('connected', {'at': at(400)})
        _, rendezvous = build(events=events)
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('relay_phone_skew=392.0s', rendezvous[6])

    def test_a_missing_phone_connected_fails_the_rendezvous_row(self):
        events = [e for e in green_events() if e['event'] != 'connected']
        _, rendezvous = build(events=events)
        self.assertEqual(rendezvous[5], 'FAIL')
        self.assertIn('no_phone_connected', rendezvous[6])


class Sources(unittest.TestCase):
    def test_elapsed_milliseconds_are_the_fallback_for_t_allowed(self):
        events = green_events()
        events[1] = {'event': 'door_open', 't_ms': 2500, 'status': 200, 'bytes': 64}
        door, rendezvous = build(events=events)
        self.assertEqual(door[4], '2.5')
        self.assertIn('t_allowed_source=door_open.t_ms', door[6])
        # Without a wall-clock instant for the door there is no comparable gap.
        self.assertIn('gap_s=-', rendezvous[6])
        self.assertIn('no_gap', rendezvous[6])
        self.assertEqual(rendezvous[5], 'FAIL')

    def test_no_evidence_at_all_is_a_fail_with_dashes(self):
        door, rendezvous = build(events=[], relay='')
        self.assertEqual(door[4], '-')
        self.assertEqual(rendezvous[4], '-')
        self.assertEqual(door[5], 'FAIL')
        self.assertEqual(rendezvous[5], 'FAIL')

    def test_unparsable_event_lines_are_skipped(self):
        text = 'not json\n' + '\n'.join(json.dumps(e) for e in green_events())
        parsed = rows.load_events(text)
        self.assertEqual(len(parsed), len(green_events()))


if __name__ == '__main__':
    unittest.main(verbosity=2)
