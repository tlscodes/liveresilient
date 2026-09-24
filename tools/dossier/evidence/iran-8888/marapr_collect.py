"""Collect raw, dated evidence for Iran 2026-03-01..2026-04-30, per day.

Sources (all public, no token):
  IODA   : bgp, ping-slash24, merit-nt, gtr signals for country IR (daily mean + min/max)
  OONI   : measurement count per day per test_name, probe_cc=IR (every test, not only dnscheck)
  Atlas  : msm 7000 (probe connect/disconnect events) for every IR probe -> connected probes per day
Writes marapr_raw.json beside this file. Usage: python3 marapr_collect.py [--part ioda|ooni|atlas]
"""
import collections, datetime, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, os.environ.get("MA_OUT", "marapr_raw.json"))
START = datetime.datetime.fromisoformat(os.environ.get("MA_START", "2026-03-01")).replace(tzinfo=datetime.timezone.utc)
STOP = datetime.datetime.fromisoformat(os.environ.get("MA_STOP", "2026-05-01")).replace(tzinfo=datetime.timezone.utc)
UTC = datetime.timezone.utc


def get(url):
    out = subprocess.run(["curl", "-s", "-m", "180", url], capture_output=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return {"_error": out[:300].decode("utf-8", "replace")}


def day_of(t):
    return datetime.datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%d")


def ioda():
    res = {}
    t0 = int(START.timestamp())
    while t0 < int(STOP.timestamp()):
        t1 = min(t0 + 10 * 86400, int(STOP.timestamp()))
        d = get(f"https://api.ioda.inetintel.cc.gatech.edu/v2/signals/raw/country/IR?from={t0}&until={t1}")
        data = d.get("data") or []
        series_list = data[0] if data and isinstance(data[0], list) else data
        for s in series_list:
            name = s.get("datasource") + ("/" + s["subtype"] if s.get("subtype") else "")
            step, frm = s.get("step"), s.get("from")
            for i, v in enumerate(s.get("values") or []):
                if isinstance(v, list):  # some signals (gtr) carry one value per product
                    v = sum(x for x in v if isinstance(x, (int, float))) if any(isinstance(x, (int, float)) for x in v) else None
                if v is None:
                    continue
                res.setdefault(name, {}).setdefault(day_of(frm + i * step), []).append(v)
        t0 = t1
    summary = {}
    for name, days in res.items():
        summary[name] = {d: {"mean": round(sum(v) / len(v), 1), "min": min(v), "max": max(v), "n": len(v)} for d, v in sorted(days.items())}
    return summary


def ooni():
    d = get("https://api.ooni.io/api/v1/aggregation?probe_cc=IR&since=2026-02-20&until=2026-05-05&axis_x=measurement_start_day&axis_y=test_name")
    rows = d.get("result") or []
    out = collections.defaultdict(dict)
    for r in rows:
        out[r["measurement_start_day"][:10]][r["test_name"]] = {k: r[k] for k in ("measurement_count", "ok_count", "anomaly_count", "confirmed_count", "failure_count")}
    return {"per_day": dict(sorted(out.items())), "raw_rows": len(rows), "error": d.get("detail") or d.get("_error")}


def atlas():
    probes, url = [], "https://atlas.ripe.net/api/v2/probes/?country_code=IR&page_size=500&fields=id,asn_v4"
    while url:
        page = get(url)
        probes += page.get("results", [])
        url = page.get("next")
    ir = {p["id"]: p["asn_v4"] for p in probes}
    ids = ",".join(str(i) for i in ir)
    # events from a month before, to know who was already connected on 03-01
    t0 = int((START - datetime.timedelta(days=45)).timestamp())
    ev = get(f"https://atlas.ripe.net/api/v2/measurements/7000/results/?start={t0}&stop={int(STOP.timestamp())}&probe_ids={ids}&format=json")
    if not isinstance(ev, list):
        return {"error": ev}
    ev.sort(key=lambda e: e["timestamp"])
    state, per_day = {}, {}
    day = START
    i = 0
    while day < STOP:
        end = int((day + datetime.timedelta(days=1)).timestamp())
        seen_up = set(p for p, s in state.items() if s == "connect")
        while i < len(ev) and ev[i]["timestamp"] < end:
            e = ev[i]
            state[e["prb_id"]] = e.get("event")
            if e.get("event") == "connect" and e["timestamp"] >= int(day.timestamp()):
                seen_up.add(e["prb_id"])
            i += 1
        up = sorted(seen_up)
        asns = collections.Counter(f"AS{ir.get(p)}" for p in up)
        per_day[day.strftime("%Y-%m-%d")] = {"connected_any_time": len(up), "by_asn": dict(asns.most_common()), "probes": up}
        day += datetime.timedelta(days=1)
    return {"ir_probes": len(ir), "events": len(ev), "per_day": per_day}


if __name__ == "__main__":
    part = sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == "--part" else None
    data = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for name, fn in (("ioda", ioda), ("ooni", ooni), ("atlas", atlas)):
        if part and part != name:
            continue
        data[name] = fn()
        json.dump(data, open(OUT, "w"), indent=1, ensure_ascii=False)
        print(name, "done:", json.dumps(data[name])[:400])
