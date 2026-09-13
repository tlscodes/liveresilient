#!/usr/bin/env python3
"""Turn one dnsvalve run's evidence into the profile's single TSV row.

The row logic lives here, not in journey_run.sh, because it is the part that
decides PASS and the part a unit test can pin without the rig (a shell version
would be judged only by a run that costs a phone, a filter and a call).

Inputs, both produced by the run itself:
  --events            the phone's hub event log (one JSON object per line)
  --valve-log         the Mac responder's log; the independent carriage witness
  --lane-id           the lane whose carriage is being proven
  --profile           the profile name the row is stamped with
  --budget-s          the budget column both this row and the runner print
  --run-start-epoch   this run's start as UTC seconds, on the MAC's clock
  --tsv               append the row there (writing the header if it is new)

Output: one 7-column TSV row, `dns_valve_chat`, on stdout and, when --tsv is
given, appended to that file. Exit 0 on PASS, 1 on FAIL, 2 when an input is
unusable (that last case still emits a FAIL row, because a missing row reads
as "the profile never ran" and this one did).

PASS NEEDS FOUR FACTS, AND THE FOURTH IS THE ONLY ONE THAT ATTRIBUTES A LANE.
  1. registration — a `lane` event with stage `registered` whose `ids` carries
     the lane id.
  2. selection — a `lane` event with stage `selected` whose `best_lane_id` is
     the lane id, and in the SAME event neither WAN lane is still eligible with
     a score that is not strictly below the valve's. Selection alone proves
     nothing about bytes: the fabric recomputes its ranking on read, so a
     best_lane_id is a post-hoc ranking, never the lane that carried.
  3. carriage as the phone reports it — a `lane_chat` event whose outcome is
     the fabric's delivered value, carrying the message's own `session_id` and
     `sha256`.
  4. carriage as the responder reports it — a `complete session=<id> bytes=<n>
     sha256=<hex>` line matching BOTH fields of fact 3. Only TXT-lane datagrams
     reach that responder, so this is the end-to-end half; the other three are
     the phone talking about itself.

A SHA ALONE IS NOT A MATCH. The valve log is appended across runs and the
fixtures repeat, so a digest can be satisfied by a line another run wrote. The
session id is per message (TxtQueryLane.lastSessionId), so both fields must
match, and when --run-start-epoch is given the line must also postdate the run.

THE TWO HALVES OF A DISAGREEMENT ARE DIFFERENT FAILURES. "Carried but never
selected" (`carried_without_selection`) and "selected but never carried"
(`never_carried`) are reported as themselves and never rounded to one verdict,
because they send the next hour of work to opposite places.

MEASURED ON ONE CLOCK. The responder's line is stamped by the Mac, so the
number is measured from the Mac's own run start. When that is not supplied the
phone's first `lane` event is used instead and the note says so — a number
made from two devices' clocks is a skew measurement wearing a latency label.

THE BUDGET COLUMN IS PRINTED, NOT JUDGED HERE. The carriage's own deadline is
the phone's (`carry_budget_s`), and its expiry arrives as a `gave_up` event,
which IS judged. A second, later budget applied to the same fact would fail
runs the phone already called finished.

  python3 tools/t2/journey_dnsvalve_rows.py --events phone_events.jsonl \\
      --valve-log dnsvalve.valve.log --lane-id resilient.dns-valve \\
      --profile dnsvalve --tsv tools/dossier/app_journey_results.tsv
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime

FEATURE = 'dns_valve_chat'
PROFILE = 'dnsvalve'
LANE_ID = 'resilient.dns-valve'

# The two lanes the filter is supposed to have taken away. Their ids are
# ResilientFallbackLanes.webSocketRelay / .httpLongPoll.
WAN_LANE_IDS = ('resilient.wss', 'resilient.https')

# DeliveryOutcome.sentLive is the fabric's only "a live lane carried it" value
# (connection_fabric.dart:29); queuedForLater and rejected are not carriage.
DELIVERED_OUTCOMES = ('sentLive',)

HEADER = 'feature\tprofile\twire_B\tbudget_s\tmeasured_s\tstatus\tnote\n'

COMPLETE_RE = re.compile(
    r'complete session=(?P<session>\S+) bytes=(?P<bytes>\d+) '
    r'sha256=(?P<sha>[0-9a-fA-F]{64})'
)
# logging's default asctime: "2026-09-13 20:15:33,123".
STAMP_RE = re.compile(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:,(\d{1,6}))?')


class InputError(Exception):
    """An input was named but cannot be read; the row is FAIL and the exit is 2."""


def load_events(text: str) -> list[dict]:
    events = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
        if isinstance(parsed, dict):
            events.append(parsed)
    return events


def lane_events(events: list[dict]) -> list[dict]:
    """Only this branch's events. Every other kind is ignored, never fatal."""
    return [e for e in events if e.get('event') == 'lane']


def stage_events(events: list[dict], stage: str) -> list[dict]:
    return [e for e in lane_events(events) if e.get('stage') == stage]


def last_stage(events: list[dict], stage: str) -> dict:
    found = stage_events(events, stage)
    return found[-1] if found else {}


def _number(value) -> float | None:
    """The value as a number, or None. `True` is not a score."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _seconds(value: float | None) -> str:
    return '-' if value is None else f'{round(value, 1)}'


def _budget(budget_s: float) -> str:
    """The budget column, printed the way the runner's other rows print it."""
    return str(int(budget_s)) if float(budget_s).is_integer() else str(budget_s)


def _short(lane_id: str) -> str:
    return lane_id.split('.', 1)[1] if lane_id.startswith('resilient.') else lane_id


def iso_epoch(value) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None


def line_epoch(line: str) -> float | None:
    """The responder line's own instant, or nothing when it carries no stamp."""
    match = STAMP_RE.match(line.strip())
    if not match:
        return None
    try:
        stamp = datetime.strptime(match.group(1), '%Y-%m-%d %H:%M:%S')
    except ValueError:
        return None
    fraction = match.group(2) or ''
    millis = int(fraction.ljust(3, '0')[:3]) / 1000.0 if fraction else 0.0
    return stamp.timestamp() + millis


def load_complete_lines(text: str) -> list[dict]:
    """Every `complete session=... bytes=... sha256=...` line the log carries."""
    out = []
    for line in text.splitlines():
        match = COMPLETE_RE.search(line)
        if not match:
            continue
        out.append(
            {
                'session': match.group('session').lower(),
                'bytes': int(match.group('bytes')),
                'sha256': match.group('sha').lower(),
                'epoch': line_epoch(line),
                'raw': line.strip(),
            }
        )
    return out


def match_responder(
    lines: list[dict],
    session_id: str,
    sha256: str,
    run_start_epoch: float | None,
) -> dict | None:
    """The responder's line for THIS message of THIS run, or nothing.

    Session ids travel as DNS labels, which are case-insensitive and which the
    responder lowercases, so both sides are compared lowered. When the run's
    start is known, a line that cannot be placed after it does not count: an
    unstamped or older line is exactly the stale evidence this match exists to
    refuse.
    """
    wanted_session = (session_id or '').lower()
    wanted_sha = (sha256 or '').lower()
    if not wanted_session or not wanted_sha:
        return None
    for entry in reversed(lines):
        if entry['session'] != wanted_session or entry['sha256'] != wanted_sha:
            continue
        if run_start_epoch is not None:
            if entry['epoch'] is None or entry['epoch'] < run_start_epoch:
                continue
        return entry
    return None


def lane_map(event: dict) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for lane in event.get('lanes') or []:
        if isinstance(lane, dict) and isinstance(lane.get('id'), str):
            out[lane['id']] = lane
    return out


def valve_score(event: dict, lane_id: str) -> float | None:
    score = _number(event.get('valve_score'))
    if score is not None:
        return score
    entry = lane_map(event).get(lane_id)
    return None if entry is None else _number(entry.get('score'))


def wan_verdict(
    event: dict,
    lane_id: str,
    wan_ids: tuple[str, ...] = WAN_LANE_IDS,
) -> tuple[bool, str]:
    """Whether the WAN lanes are off, and the token that prints their state.

    A lane the fabric marked ineligible is off whatever its last score was. An
    eligible one is off only when its score is strictly below the valve's — and
    when either number is missing the ordering is not proven, which is the same
    verdict as losing, because an unproven premise cannot make a row green.
    """
    lanes = lane_map(event)
    valve = valve_score(event, lane_id)
    alive = False
    shown = []
    for wan_id in wan_ids:
        entry = lanes.get(wan_id)
        if entry is None:
            shown.append(f'{_short(wan_id)}=absent')
            continue
        score = _number(entry.get('score'))
        if entry.get('eligible') is not True:
            shown.append(f'{_short(wan_id)}=off')
            continue
        shown.append(f'{_short(wan_id)}={"?" if score is None else round(score, 3)}')
        if valve is None or score is None or score >= valve:
            alive = True
    return alive, ','.join(shown)


def delivered_chat(events: list[dict]) -> dict:
    """The last `lane_chat` the phone called delivered, with both id fields."""
    for event in reversed(events):
        if event.get('event') != 'lane_chat':
            continue
        if event.get('outcome') not in DELIVERED_OUTCOMES:
            continue
        if event.get('session_id') and event.get('sha256'):
            return event
    return {}


def build_row(
    events: list[dict],
    valve_log: str,
    lane_id: str = LANE_ID,
    profile: str = PROFILE,
    budget_s: float = 120.0,
    run_start_epoch: float | None = None,
    input_error: str = '',
) -> list[str]:
    """The profile's one row: seven cells, PASS only on all four facts."""
    lanes = lane_events(events)
    lines = load_complete_lines(valve_log)
    fails: list[str] = []
    notes: list[str] = []

    if input_error:
        fails.append(f'error({input_error})')

    if not lanes:
        # The peer posts nothing about lanes only when it does not have this
        # branch. Naming that outright is the point: the alternative is an hour
        # spent debugging a filter that was never the problem.
        fails.append('no_lane_events(peer_predates_dns_valve_branch)')
        note = ' '.join(notes + ['fail=' + ','.join(fails)])
        return row_cells(profile, '?', budget_s, None, fails, note)

    error_event = last_stage(events, 'error')
    if error_event:
        fails.append('error(%s)' % str(error_event.get('error', 'unnamed')))
    if stage_events(events, 'gave_up'):
        fails.append('gave_up')

    probe = last_stage(events, 'wan_probe')
    if probe.get('reachable') is True:
        # The filter only shapes bridge100. A phone that reached the border
        # relay anyway was never in the condition the row claims to measure.
        fails.append('wan_reachable_off_bridge')
    notes.append('wan_probe=%s' % probe.get('reachable', 'absent'))

    registered = [
        e for e in stage_events(events, 'registered')
        if lane_id in (e.get('ids') or [])
    ]
    registered_ids = (last_stage(events, 'registered').get('ids') or [])
    notes.append('registered=%s' % ('+'.join(str(i) for i in registered_ids) or 'none'))
    if not registered:
        fails.append('not_registered(ids=%s)' % ('+'.join(str(i) for i in registered_ids) or 'none'))

    selected = [
        e for e in stage_events(events, 'selected')
        if e.get('best_lane_id') == lane_id
    ]
    last_rank = (
        selected[-1]
        if selected
        else (last_stage(events, 'not_selected') or last_stage(events, 'selected'))
    )
    notes.append('mode=%s' % last_rank.get('mode', 'absent'))
    notes.append('best_lane=%s' % last_rank.get('best_lane_id', 'absent'))
    ranked_valve = valve_score(last_rank, lane_id) if last_rank else None
    notes.append('valve_score=%s' % ('absent' if ranked_valve is None else ranked_valve))
    if any(e.get('valve_down') is True for e in lanes):
        fails.append('valve_down')
    selection_ok = False
    if not selected:
        fails.append('never_selected')
        if last_rank:
            notes.append('wan=%s' % wan_verdict(last_rank, lane_id)[1])
    else:
        alive, shown = wan_verdict(selected[-1], lane_id)
        notes.append('wan=%s' % shown)
        if alive:
            # The token names the state, not merely the verdict: a reader needs
            # to know WHICH lane was still up and by how much.
            fails.append('wan_alive(%s)' % shown)
        else:
            selection_ok = True

    chat = delivered_chat(events)
    if not chat:
        last_chat = next(
            (e for e in reversed(events) if e.get('event') == 'lane_chat'), {}
        )
        fails.append('never_carried(outcome=%s)' % last_chat.get('outcome', 'absent'))
    elif not selection_ok:
        # Carried, but the run never proved the valve was the chosen lane: the
        # bytes may have ridden a WAN lane in the same fan-out.
        fails.append('carried_without_selection')
    notes.append('best_lane_at_send=%s' % chat.get('best_lane_at_send', 'absent'))
    notes.append('session=%s' % chat.get('session_id', 'absent'))
    notes.append('sha256=%s' % str(chat.get('sha256', 'absent'))[:16])

    matched = (
        match_responder(lines, chat.get('session_id', ''), chat.get('sha256', ''), run_start_epoch)
        if chat
        else None
    )
    notes.append('responder_lines=%d' % len(lines))
    if chat and matched is None:
        fails.append('no_responder_line')

    anchor, anchor_name = run_anchor(lanes, run_start_epoch)
    measured = (
        None
        if (matched is None or matched['epoch'] is None or anchor is None)
        else matched['epoch'] - anchor
    )
    notes.append('measured_from=%s' % anchor_name)
    wire_b = '?'
    if matched is not None:
        wire_b = str(matched['bytes'])
    elif _number(chat.get('bytes')) is not None:
        wire_b = str(int(_number(chat.get('bytes'))))

    note = ' '.join(notes)
    if fails:
        note += ' fail=' + ','.join(fails)
    return row_cells(profile, wire_b, budget_s, measured, fails, note)


def run_anchor(lanes: list[dict], run_start_epoch: float | None) -> tuple[float | None, str]:
    """The instant the elapsed number is measured from, and its name."""
    if run_start_epoch is not None:
        return run_start_epoch, 'mac_run_start'
    first = next((iso_epoch(e.get('at')) for e in lanes if iso_epoch(e.get('at'))), None)
    return (first, 'phone_clock_first_lane_event') if first else (None, 'none')


def row_cells(
    profile: str,
    wire_b: str,
    budget_s: float,
    measured: float | None,
    fails: list[str],
    note: str,
) -> list[str]:
    cells = [
        FEATURE,
        profile,
        wire_b,
        _budget(budget_s),
        _seconds(measured),
        'FAIL' if fails else 'PASS',
        note,
    ]
    return [str(cell).replace('\t', ' ').replace('\n', ' ') for cell in cells]


def append_row(path: str, row: list[str]) -> None:
    """Append the row, writing the runner's header when the file is new."""
    try:
        with open(path, encoding='utf-8') as handle:
            needs_header = not handle.read(1)
    except OSError:
        needs_header = True
    with open(path, 'a', encoding='utf-8') as handle:
        if needs_header:
            handle.write(HEADER)
        handle.write('\t'.join(row) + '\n')


def read_input(path: str) -> str:
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            return handle.read()
    except OSError as exc:
        raise InputError(f'{path}:{exc.strerror or "unreadable"}') from exc


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--events', required=True)
    parser.add_argument('--valve-log', required=True)
    parser.add_argument('--lane-id', default=LANE_ID)
    parser.add_argument('--profile', default=PROFILE)
    parser.add_argument('--budget-s', type=float, default=120.0)
    parser.add_argument('--run-start-epoch', type=float, default=None)
    parser.add_argument('--tsv', default='')
    args = parser.parse_args(argv[1:])

    unusable = ''
    events_text = valve_text = ''
    try:
        events_text = read_input(args.events)
        valve_text = read_input(args.valve_log)
    except InputError as exc:
        unusable = str(exc)

    row = build_row(
        load_events(events_text),
        valve_text,
        lane_id=args.lane_id,
        profile=args.profile,
        budget_s=args.budget_s,
        run_start_epoch=args.run_start_epoch,
        input_error=unusable,
    )
    print('\t'.join(row))
    if args.tsv:
        append_row(args.tsv, row)
    if unusable:
        print(f'::error::unusable input {unusable}', file=sys.stderr)
        return 2
    return 1 if row[5] == 'FAIL' else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
