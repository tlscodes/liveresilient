#!/usr/bin/env python3
"""Render tools/dossier/app_journey_results.tsv as the brief's one table:
profile by feature, measured number and verdict, latest run per profile.

Earlier runs of a profile stay in the TSV (a failed rig run is evidence too);
this picks, per profile, the rows carrying the newest `run=` stamp and lists
the superseded runs underneath so nothing is hidden.

  python3 tools/dossier/journey_report.py [path/to/app_journey_results.tsv]
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

PROFILES = ['normal', 'latency', 'loss10', 'bandwidth', 'narrow', 'loss60', 'extreme', 'blackout']
FEATURES = ['call_connect', 'monitor_bar', 'chat_text', 'photo', 'video_note', 'voice_note', 'blackout_message']
RUN = re.compile(r'run=(\S+)')


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else 'tools/dossier/app_journey_results.tsv')
    rows = [line.rstrip('\n').split('\t') for line in path.read_text().splitlines()[1:] if line.strip()]
    by_profile: dict[str, list[list[str]]] = defaultdict(list)
    for row in rows:
        by_profile[row[1]].append(row)

    print('profile      feature       measured   status     decoded                      note')
    superseded: dict[str, list[str]] = {}
    for profile in PROFILES:
        prows = by_profile.get(profile, [])
        if not prows:
            print(f'{profile:<12} (no rows — profile did not run)')
            continue
        stamps = sorted({(RUN.search(r[6]) or [None, ''])[1] for r in prows})
        latest = stamps[-1]
        superseded[profile] = [s for s in stamps[:-1] if s]
        for feature in FEATURES:
            for r in prows:
                stamp = (RUN.search(r[6]) or [None, ''])[1]
                if r[0] == feature and stamp == latest:
                    measured = r[4] if r[4] != '-' else '-'
                    # call_connect and the chat features are measured in seconds
                    # (chat: send action to the phone's verified receipt).
                    unit = 'h' if feature == 'blackout_message' and measured != '-' else 's' if feature != 'monitor_bar' and measured != '-' else ('ms' if feature == 'monitor_bar' and measured != '-' else '')
                    note = re.sub(r'\s*run=\S+', '', r[6])
                    decoded = (re.search(r'decoded=\S+', r[6]) or [None, ''])[0] or ''
                    print(f'{profile:<12} {feature:<13} {measured + unit:<10} {r[5]:<10} {decoded:<28} {note[:150]}')
                    break
            else:
                # NOT_WIRED rows carry no run stamp; take the first one.
                for r in prows:
                    if r[0] == feature:
                        print(f'{profile:<12} {feature:<13} {"-":<10} {r[5]:<10} {r[6][:150]}')
                        break
    for profile, stamps in superseded.items():
        if stamps:
            print(f'\n{profile}: superseded runs kept in the TSV: {", ".join(stamps)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
