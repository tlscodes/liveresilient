#!/usr/bin/env python3
"""Render h2_results.tsv as one self-contained HTML report.

The table is the truth; this is the truth made readable: latest verdict per
(profile, test), the full history count behind each cell, connect/delivery
timing bars, and every note verbatim. No dependencies beyond the stdlib, no
network, nothing fetched — the file works from disk forever.

Usage:
  python3 tools/t2/report_matrix.py [results.tsv] [out.html]
Defaults: tools/t2/h2_results.tsv -> tools/t2/h2_report.html
"""

from __future__ import annotations

import html
import json
import sys
from pathlib import Path

PROFILE_ORDER = [
    "clean", "normal", "latency", "bandwidth",
    "narrow", "loss10", "loss60", "extreme",
]

VERDICT_CLASS = {
    "PASS": "pass", "PASS/STRESS": "pass",
    "FAIL": "fail", "FAIL/STRESS": "fail",
}


def short_test(name: str) -> str:
    if "sla" in name:
        return "voice"
    if "messaging" in name:
        return "messaging"
    return name.replace("_test.dart", "")


def load(path: Path):
    rows = []
    lines = path.read_text().splitlines()
    if not lines:
        return rows
    header = lines[0].split("\t")
    for line in lines[1:]:
        if not line.strip():
            continue
        parts = line.split("\t")
        row = dict(zip(header, parts))
        if row.get("profile"):
            rows.append(row)
    return rows


def latest_per_cell(rows):
    cells = {}
    history = {}
    for row in rows:  # file order is chronological
        key = (row["profile"], short_test(row.get("test", "")))
        cells[key] = row
        history[key] = history.get(key, 0) + 1
    return cells, history


def bar(value_ms: str, max_ms: float) -> str:
    try:
        v = float(value_ms)
    except (TypeError, ValueError):
        return ""
    width = 2 if max_ms <= 0 else max(2, round(v / max_ms * 260))
    return (
        f'<div class="bar"><i style="width:{width}px"></i>'
        f"<span>{v / 1000:.1f}s</span></div>"
    )


def main() -> int:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        __file__).with_name("h2_results.tsv")
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(
        __file__).with_name("h2_report.html")
    rows = load(src)
    if not rows:
        print(f"no rows in {src}", file=sys.stderr)
        return 1
    cells, history = latest_per_cell(rows)
    tests = sorted({t for (_, t) in cells})
    # voice first, then messaging, then anything else
    tests.sort(key=lambda t: {"voice": 0, "messaging": 1}.get(t, 2))

    connect_values = []
    for p in PROFILE_ORDER:
        row = cells.get((p, "voice"))
        if row:
            try:
                connect_values.append(float(row.get("connect_ms", "")))
            except ValueError:
                pass
    max_connect = max(connect_values, default=0.0)

    body = []
    body.append(f"<h1>T2 matrix — {html.escape(src.name)}</h1>")
    body.append(
        f"<p class=meta>{len(rows)} rows total; latest row per cell shown; "
        f"generated from disk, no live data.</p>"
    )
    for test in tests:
        body.append(f"<h2>{html.escape(test)}</h2>")
        body.append(
            "<table><tr><th>profile</th><th>verdict</th><th>when (UTC)</th>"
            "<th>connect</th><th>runs</th><th>note</th></tr>"
        )
        for profile in PROFILE_ORDER:
            row = cells.get((profile, test))
            if row is None:
                body.append(
                    f"<tr><td>{profile}</td>"
                    '<td class="none">not&nbsp;run</td>'
                    "<td>-</td><td></td><td>0</td><td></td></tr>"
                )
                continue
            verdict = row.get("verdict", "?")
            cls = VERDICT_CLASS.get(verdict, "other")
            note = html.escape(row.get("note", ""))
            body.append(
                f"<tr><td>{profile}</td>"
                f'<td class="{cls}">{html.escape(verdict)}</td>'
                f"<td>{html.escape(row.get('date', '')[:16])}</td>"
                f"<td>{bar(row.get('connect_ms', ''), max_connect)}</td>"
                f"<td>{history.get((profile, test), 0)}</td>"
                f'<td class="note">{note}</td></tr>'
            )
        body.append("</table>")

    passes = sum(
        1
        for p in PROFILE_ORDER
        if VERDICT_CLASS.get(cells.get((p, "voice"), {}).get("verdict", ""))
        == "pass"
    )
    body.insert(1, f"<p class=score>voice: {passes}/8 green</p>")

    # Intelligence score — written by connection_orchestrator's replay
    # benchmark (tool/intelligence_replay.dart); absent file = section
    # skipped, never a crash.
    evo_path = Path(__file__).with_name("intelligence_evolution.json")
    if evo_path.exists():
        try:
            evo = json.loads(evo_path.read_text())
            epochs = evo.get("epochs", [])
        except (json.JSONDecodeError, OSError):
            epochs = []
        if epochs:
            final = epochs[-1]
            body.append("<h2>intelligence_score (replay benchmark)</h2>")
            body.append(
                f"<p class=score>epoch {final.get('epoch')}: "
                f"{final.get('score', 0):.3f} "
                f"(baseline epoch 0 = 1.000)</p>"
            )
            body.append(
                "<table><tr><th>epoch</th><th>score</th><th>trend</th>"
                "<th>lane</th><th>calibrator</th><th>atlas</th>"
                "<th>learned</th></tr>"
            )
            for e in epochs:
                def norm(key):
                    v = e.get(key, {})
                    return f"{v.get('normalized', 0):.3f}"
                changed = e.get("whatChanged", [])
                body.append(
                    f"<tr><td>{e.get('epoch')}</td>"
                    f"<td>{e.get('score', 0):.3f}</td>"
                    f"<td>{norm('trendLeadTime')}</td>"
                    f"<td>{norm('laneChoiceRegret')}</td>"
                    f"<td>{norm('calibrator')}</td>"
                    f"<td>{norm('atlas')}</td>"
                    f'<td class="note">{len(changed)} changes</td></tr>'
                )
            body.append("</table>")

    style = """
    body{font:14px -apple-system,sans-serif;margin:2em;max-width:1100px}
    h1{font-size:1.3em} h2{margin-top:1.5em}
    table{border-collapse:collapse;width:100%}
    td,th{border:1px solid #ccc;padding:4px 8px;text-align:left;
          vertical-align:top}
    .pass{background:#d7f5d7;font-weight:600}
    .fail{background:#f8d3d3;font-weight:600}
    .other{background:#f4e9c7} .none{color:#999}
    .note{font-size:12px;color:#444;max-width:480px}
    .meta,.score{color:#555} .score{font-size:1.1em;font-weight:600}
    .bar i{display:inline-block;height:10px;background:#4a90d9;
           vertical-align:middle;border-radius:2px}
    .bar span{font-size:11px;margin-left:4px;color:#333}
    """
    doc = (
        "<!doctype html><meta charset=utf-8>"
        f"<title>T2 matrix report</title><style>{style}</style>"
        + "".join(body)
    )
    out.write_text(doc)
    print(f"wrote {out} ({len(rows)} rows, voice {passes}/8 green)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
