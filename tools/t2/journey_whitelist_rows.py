#!/usr/bin/env python3
"""Turn one whitelist run's evidence into the profile's two TSV rows.

The row logic lives here, not in journey_run.sh, because it is the part that
decides PASS and the part a unit test can pin without the rig (a shell version
would be judged only by a run that costs a phone, a filter and a call).

Inputs, all produced by the run itself:
  --events      the phone's hub event log (one JSON object per line)
  --relay-log   the signaling relay's log; the independent rendezvous witness
  --key         this run's join key, which is the relay's callId
  --run-epoch   the run's start, as UTC seconds
  --window-s    the budget both rows are judged against (also the gap budget)
  --summary     the Mac driver's `JOURNEY_APP summary ...` line
  --shaped      the run stamp block every row's note carries (`run=<id> ...`)
  --fidelity    the sentence naming the stand-in ports

Output: two TSV rows on stdout, whitelist_door then whitelist_rendezvous.

PASS, exactly as the design states it: the ordinary allowed traffic answered
200, the rendezvous completed, both inside one window with the gap inside the
budget, audio proven (a relay/tcp candidate pair AND strictly increasing
receive counters), both negative controls held, and the queue proof clean — no
`blackout*` event from the phone, queued_clips=0 and degraded_voice_notes=0 on
the Mac. A non-zero queued_clips or degraded_voice_notes is a FAIL, never a
footnote: a green row bought by the store-and-forward path is worthless.

A negative control is judged by ITS OWN verdict, never by the fact that it
reported a number. The phone emits `{rst_ms, outcome, pass}` for the reset
control and `{timeout_ms, outcome, pass}` for the QUIC one
(whitelist_door.dart `ResetProbeResult.toJson` / `QuicProbeResult.toJson`);
`pass` is true only for outcome `reset` and outcome `silent` respectively. A
control that timed out, errored, or answered — or one that reported no verdict
at all — is a FAIL on both rows, because the row's sentence ("TLS to a
non-allowed destination is RESET", "UDP 443 got nothing") was not proven. A
timer alone is satisfied by a host that is simply unreachable, which is the
same green the filter would produce switched off.

  python3 tools/t2/journey_whitelist_rows.py --events ... --relay-log ... >> results.tsv
"""
import argparse
import json
import re
import sys
from datetime import datetime, timezone

PROFILE = 'whitelist'


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


def last_event(events: list[dict], name: str) -> dict:
    for event in reversed(events):
        if event.get('event') == name:
            return event
    return {}


def field_anywhere(events: list[dict], key: str):
    """The last value any event reported for a key, whichever event carries it."""
    for event in reversed(events):
        if key in event:
            return event[key]
    return None


def has_blackout_event(events: list[dict]) -> bool:
    return any(str(e.get('event', '')).startswith('blackout') for e in events)


def iso_epoch(value) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None


def relay_rendezvous_epoch(relay_log: str, key: str) -> float | None:
    """The relay's own moment for THIS run's room, or nothing.

    Matching on the run's fresh key is deliberate: an unmatched line from an
    earlier run would put a fabricated number in the row.
    """
    found = None
    for line in relay_log.splitlines():
        if 'room_rendezvous_complete' not in line or f'callId={key}' not in line:
            continue
        stamp = re.search(r'at=(\S+)', line)
        if stamp:
            found = iso_epoch(stamp.group(1)) or found
    return found


def summary_number(summary: str, name: str) -> int | None:
    match = re.search(rf'\b{name}=(-?\d+)\b', summary or '')
    return int(match.group(1)) if match else None


def _seconds(value: float | None) -> str:
    return '-' if value is None else f'{round(value, 1)}'


def control_failure(event: dict, label: str, missing: str) -> str | None:
    """Judge one negative control, or say why it cannot be judged.

    Returns None only when the phone reported `pass: true`. Every other state —
    event absent, verdict absent, verdict false — is a reason string, because a
    control that did not prove its claim cannot make a row green. The `outcome`
    is carried into the reason so the note names WHAT happened (`timedOut`,
    `error`, `answered`), not merely that something did.
    """
    if not event:
        return missing
    verdict = event.get('pass')
    if verdict is True:
        return None
    if verdict is None:
        return f'{label}=verdict_absent'
    return f'{label}={event.get("outcome")}'


def _budget(window_s: float) -> str:
    """The budget column, printed the way the runner's other rows print it."""
    return str(int(window_s)) if float(window_s).is_integer() else str(window_s)


def build_rows(
    events: list[dict],
    relay_log: str,
    key: str,
    run_epoch: float,
    window_s: float,
    summary: str,
    shaped: str,
    fidelity: str,
) -> list[list[str]]:
    door = last_event(events, 'door_open')
    samples = last_event(events, 'door_samples')
    closed = last_event(events, 'door_closed_elsewhere')
    quic = last_event(events, 'quic_dead')
    connected = last_event(events, 'connected')

    # t_allowed: the phone's own instant is preferred over its elapsed
    # milliseconds, because the row's number is "seconds from run start" and
    # only the instant is comparable with the relay's clock.
    door_at = iso_epoch(door.get('at'))
    if door_at is not None:
        t_allowed = door_at - run_epoch
        door_source = 'door_open.at'
    elif isinstance(door.get('t_ms'), (int, float)):
        t_allowed = float(door['t_ms']) / 1000.0
        door_source = 'door_open.t_ms'
    else:
        t_allowed, door_source = None, 'none'

    relay_epoch = relay_rendezvous_epoch(relay_log, key)
    phone_epoch = iso_epoch(connected.get('at'))
    t_relay = None if relay_epoch is None else relay_epoch - run_epoch
    t_phone = None if phone_epoch is None else phone_epoch - run_epoch
    if t_relay is not None:
        t_rendezvous, rv_source = t_relay, 'relay_log.room_rendezvous_complete'
    elif t_phone is not None:
        t_rendezvous, rv_source = t_phone, 'phone.connected(relay line absent)'
    else:
        t_rendezvous, rv_source = None, 'none'
    other = (
        f'phone_connected={_seconds(t_phone)}s'
        if rv_source.startswith('relay_log')
        else f'relay_line=absent_for_callId_{key}'
    )
    gap = None if (t_rendezvous is None or t_allowed is None) else t_rendezvous - t_allowed

    ice_type = field_anywhere(events, 'ice_pair_type')
    ice_protocol = field_anywhere(events, 'ice_pair_protocol')
    rx_increasing = field_anywhere(events, 'rx_increasing')
    queued_clips = summary_number(summary, 'queued_clips')
    voice_notes = summary_number(summary, 'degraded_voice_notes')
    rst_ms = closed.get('rst_ms')
    quic_ms = quic.get('timeout_ms')
    reset_outcome = closed.get('outcome')
    quic_outcome = quic.get('outcome')

    # The queue proof and the two negative controls judge BOTH rows: either
    # one failing means the window was not what the rows would claim.
    shared_fail = []
    if has_blackout_event(events):
        shared_fail.append('blackout_event_present')
    if queued_clips != 0:
        shared_fail.append(f'queued_clips={queued_clips}')
    if voice_notes != 0:
        shared_fail.append(f'degraded_voice_notes={voice_notes}')
    reset_fail = control_failure(closed, 'reset_control', 'no_door_closed_elsewhere')
    if reset_fail:
        shared_fail.append(reset_fail)
    quic_fail = control_failure(quic, 'quic_control', 'no_quic_dead')
    if quic_fail:
        shared_fail.append(quic_fail)

    door_fail = list(shared_fail)
    if not door:
        door_fail.append('no_door_open_event')
    elif door.get('status') != 200:
        door_fail.append(f"door_status={door.get('status')}")
    if t_allowed is None:
        door_fail.append('no_t_allowed')
    elif t_allowed > window_s:
        door_fail.append(f't_allowed>{window_s}s')

    rv_fail = list(shared_fail)
    if t_rendezvous is None:
        rv_fail.append('no_t_rendezvous')
    if gap is None:
        rv_fail.append('no_gap')
    elif abs(gap) > window_s:
        rv_fail.append(f'gap>{window_s}s')
    if ice_type != 'relay' or ice_protocol != 'tcp':
        rv_fail.append(f'ice_pair={ice_type}/{ice_protocol}')
    if rx_increasing is not True:
        rv_fail.append(f'rx_increasing={rx_increasing}')

    common_note = (
        f'door_samples={samples.get("ok")}ok/{samples.get("fail")}fail '
        f'door_closed_elsewhere_rst_ms={rst_ms} '
        f'door_closed_elsewhere_outcome={reset_outcome} '
        f'reset_control={"held" if reset_fail is None else "FAILED"} '
        f'quic_dead_timeout_ms={quic_ms} quic_dead_outcome={quic_outcome} '
        f'quic_control={"held" if quic_fail is None else "FAILED"} '
        f'ice_pair={ice_type}/{ice_protocol} rx_increasing={rx_increasing} '
        f'queued_clips={queued_clips} degraded_voice_notes={voice_notes} '
        f'{fidelity} {shaped}'
    )
    door_note = (
        f'first ordinary HTTPS 200 t_allowed_source={door_source} '
        f'status={door.get("status")} bytes={door.get("bytes")} '
        f'{common_note}'
    )
    rv_note = (
        f'gap_s={_seconds(gap)} t_rendezvous_source={rv_source} {other} '
        f'{common_note}'
    )
    if door_fail:
        door_note += ' fail=' + ','.join(door_fail)
    if rv_fail:
        rv_note += ' fail=' + ','.join(rv_fail)

    door_bytes = door.get('bytes')
    return [
        [
            'whitelist_door',
            PROFILE,
            '?' if door_bytes is None else str(door_bytes),
            _budget(window_s),
            _seconds(t_allowed),
            'FAIL' if door_fail else 'PASS',
            door_note,
        ],
        [
            'whitelist_rendezvous',
            PROFILE,
            '0',
            _budget(window_s),
            _seconds(t_rendezvous),
            'FAIL' if rv_fail else 'PASS',
            rv_note,
        ],
    ]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--events', required=True)
    parser.add_argument('--relay-log', required=True)
    parser.add_argument('--key', required=True)
    parser.add_argument('--run-epoch', type=float, required=True)
    parser.add_argument('--window-s', type=float, required=True)
    parser.add_argument('--summary', default='')
    parser.add_argument('--shaped', default='')
    parser.add_argument('--fidelity', default='')
    args = parser.parse_args(argv[1:])

    def read(path: str) -> str:
        try:
            with open(path, encoding='utf-8', errors='replace') as handle:
                return handle.read()
        except OSError:
            return ''

    rows = build_rows(
        load_events(read(args.events)),
        read(args.relay_log),
        args.key,
        args.run_epoch,
        args.window_s,
        args.summary,
        args.shaped,
        args.fidelity,
    )
    for row in rows:
        print('\t'.join(cell.replace('\t', ' ') for cell in row))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
