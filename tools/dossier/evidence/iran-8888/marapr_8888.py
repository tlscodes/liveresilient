"""RIPE Atlas: did any Iranian probe send DNS (UDP/53) or ping to 8.8.8.8 during 2026-03-01..04-30?

Scans every public DNS and ping measurement targeting 8.8.8.8 that overlapped the window,
asks each for results from the IR probes connected in that window, and tallies per day.
Writes marapr_8888.json. Usage: python3 marapr_8888.py
"""
import collections, concurrent.futures, datetime, json, os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://atlas.ripe.net/api/v2"
T0 = int(datetime.datetime(2026, 3, 1, tzinfo=datetime.timezone.utc).timestamp())
T1 = int(datetime.datetime(2026, 5, 1, tzinfo=datetime.timezone.utc).timestamp())
UTC = datetime.timezone.utc


def get(url):
    out = subprocess.run(["curl", "-s", "-m", "120", url], capture_output=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return None


raw = json.load(open(os.path.join(HERE, "marapr_raw.json")))["atlas"]["per_day"]
probe_ids = sorted({p for v in raw.values() for p in v["probes"]})
ids = ",".join(map(str, probe_ids))

msms = []
for typ in ("dns", "ping"):
    url = (f"{API}/measurements/?type={typ}&target_ip=8.8.8.8&start_time__lt={T1}&page_size=500"
           f"&fields=id,type,protocol,start_time,stop_time,status")
    while url:
        page = get(url) or {}
        for m in page.get("results", []):
            stop = m.get("stop_time")
            if stop is None or stop >= T0:
                msms.append(m)
        url = page.get("next")
print(f"candidate measurements overlapping window: {len(msms)} (dns {sum(m['type']=='dns' for m in msms)}, ping {sum(m['type']=='ping' for m in msms)})", flush=True)


def one(m):
    res = get(f"{API}/measurements/{m['id']}/results/?start={T0}&stop={T1}&probe_ids={ids}&format=json")
    return m, (res if isinstance(res, list) else [])


tally, hits = collections.Counter(), collections.defaultdict(set)
with concurrent.futures.ThreadPoolExecutor(16) as ex:
    for n, (m, res) in enumerate(ex.map(one, msms), 1):
        if n % 200 == 0:
            print(f"  scanned {n}/{len(msms)}", flush=True)
        for r in res:
            day = datetime.datetime.fromtimestamp(r["timestamp"], UTC).strftime("%Y-%m-%d")
            kind = f"{m['type']}/{(m.get('protocol') or 'icmp').lower()}"
            if m["type"] == "ping":
                ok = (r.get("rcvd") or 0) > 0
                out = f"reply rtt={round(r.get('avg') or 0)}ms" if ok else "no-reply"
                out = "reply" if ok else "no-reply"
            else:
                out = "answered" if "result" in r else "error:" + ",".join((r.get("error") or {}).keys()) if isinstance(r.get("error"), dict) else ("answered" if "result" in r else "error")
            tally[(day, r.get("prb_id"), kind, out)] += 1
            hits[m["id"]].add(r.get("prb_id"))

rows = [{"day": d, "probe": p, "kind": k, "outcome": o, "n": n} for (d, p, k, o), n in sorted(tally.items())]
json.dump({"probes": probe_ids, "measurements_scanned": len(msms), "measurements_with_ir": {str(k): sorted(v) for k, v in hits.items()}, "rows": rows},
          open(os.path.join(HERE, "marapr_8888.json"), "w"), indent=1)
print("measurements with IR probe results:", len(hits))
for r in rows:
    print(r["day"], r["probe"], r["kind"], r["outcome"], r["n"])
