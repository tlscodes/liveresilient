"""RIPE Atlas: plain UDP/53 DNS from Iranian probes to 8.8.8.8 (and the probe's own resolver).

Usage: python3 atlas_8888.py [start_iso] [stop_iso]
Finds public DNS measurements whose target is 8.8.8.8, keeps those with Iranian
probes in their results, and tallies answered vs timeout per probe ASN and day.
"""
import collections, datetime, json, subprocess, sys

API = "https://atlas.ripe.net/api/v2"
START = sys.argv[1] if len(sys.argv) > 1 else "2026-09-16"
STOP = sys.argv[2] if len(sys.argv) > 2 else "2026-09-24"


def get(url):
    out = subprocess.run(["curl", "-s", "-m", "120", url], capture_output=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return None


def ts(s):
    return int(datetime.datetime.fromisoformat(s).replace(tzinfo=datetime.timezone.utc).timestamp())


probes = get(f"{API}/probes/?country_code=IR&page_size=500&fields=id,asn_v4")["results"]
ir = {p["id"]: p["asn_v4"] for p in probes}
ids = ",".join(str(i) for i in ir)

msms, url = [], f"{API}/measurements/?type=dns&target_ip=8.8.8.8&stop_time__gte={ts(START)}&page_size=500&fields=id,protocol,description,is_oneoff,participant_count"
while url and len(msms) < 3000:
    page = get(url) or {}
    msms += page.get("results", [])
    url = page.get("next")
print(f"DNS measurements targeting 8.8.8.8 active since {START}: {len(msms)}")

tally = collections.Counter()
hits = collections.defaultdict(set)
for m in msms:
    if (m.get("protocol") or "").upper() != "UDP":
        continue
    res = get(f"{API}/measurements/{m['id']}/results/?start={ts(START)}&stop={ts(STOP)}&probe_ids={ids}&format=json")
    if not isinstance(res, list) or not res:
        continue
    for r in res:
        asn = ir.get(r.get("prb_id"), "?")
        day = datetime.datetime.utcfromtimestamp(r["timestamp"]).strftime("%Y-%m-%d")
        if "result" in r:
            out = f"answered rcode={r['result'].get('ANCOUNT', '?')}ans rt={round(r['result'].get('rt', 0))}ms"
            out = "answered"
        else:
            err = r.get("error") or {}
            out = "error:" + (",".join(err.keys()) if isinstance(err, dict) else str(err))[:30]
        tally[(day, f"AS{asn}", out)] += 1
        hits[m["id"]].add(r.get("prb_id"))

print("measurements with Iranian probes:", {k: sorted(v) for k, v in hits.items()})
for (day, asn, out), n in sorted(tally.items()):
    print(f"{day} | {asn:9s} | {out:30s} | {n}")
