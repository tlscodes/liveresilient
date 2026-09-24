"""Print one part of marapr_raw.json compactly. Usage: python3 marapr_show.py ooni|ioda|atlas"""
import json, os, sys

d = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), os.environ.get("MA_OUT", "marapr_raw.json"))))
part = sys.argv[1]
if part == "ooni":
    for day, tests in d["ooni"]["per_day"].items():
        total = sum(v["measurement_count"] for v in tests.values())
        detail = " ".join(f"{n}={v['measurement_count']}" for n, v in sorted(tests.items()))
        print(day, total, detail[:170])
elif part == "ioda":
    names = sorted(d["ioda"])
    print("day       ", " | ".join(names))
    days = sorted({day for n in names for day in d["ioda"][n]})
    for day in days:
        cells = []
        for n in names:
            c = d["ioda"][n].get(day)
            cells.append(f"{c['mean']:.0f} ({c['min']:.0f}-{c['max']:.0f})" if c else "-")
        print(day, " | ".join(cells))
elif part == "atlas":
    a = d["atlas"]
    print("probes", a.get("ir_probes"), "events", a.get("events"), a.get("error", ""))
    for day, v in (a.get("per_day") or {}).items():
        print(day, v["connected_any_time"], json.dumps(v["by_asn"])[:150])
