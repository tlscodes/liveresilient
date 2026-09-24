"""Pull raw OONI dnscheck measurements from Iran and tally per resolver/ASN/outcome."""
import collections, json, sys, urllib.request

API = "https://api.ooni.io/api/v1"
SINCE = sys.argv[1] if len(sys.argv) > 1 else "2026-09-01"
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 else 150


def get(url):
    import subprocess
    out = subprocess.run(["curl", "-s", "-m", "60", url], capture_output=True, check=True).stdout
    return json.loads(out)


UNTIL = sys.argv[4] if len(sys.argv) > 4 else "2026-09-24"
INPUT = sys.argv[3] if len(sys.argv) > 3 else ""
q = f"&input={urllib.parse.quote(INPUT, safe='')}" if INPUT else ""
import urllib.parse
lst = get(f"{API}/measurements?probe_cc=IR&test_name=dnscheck&since={SINCE}&until={UNTIL}&limit={LIMIT}&order_by=measurement_start_time&order=desc{q}")
rows = lst.get("results", [])
print(f"listed {len(rows)} measurements since {SINCE}")
tally = collections.Counter()
examples = {}
for m in rows:
    uid = m.get("measurement_uid")
    try:
        full = get(f"{API}/measurement/{uid}")
    except Exception as e:
        tally[("fetch-error", "", "")] += 1
        continue
    body = full.get("raw_measurement") or full
    if isinstance(body, str):
        body = json.loads(body)
    tk = body.get("test_keys", {}) or {}
    asn = body.get("probe_asn", "?") + " " + body.get("measurement_start_time", "")[:7]
    day = body.get("measurement_start_time", "")[:10]
    resolver = body.get("input", "?")
    lookups = tk.get("lookups") or {}
    boot = tk.get("bootstrap_failure")
    if boot:
        key = (resolver, asn, f"bootstrap:{boot}")
        tally[key] += 1
        examples.setdefault(key, (day, uid))
        continue
    if not lookups:
        key = (resolver, asn, "no-lookups")
        tally[key] += 1
        examples.setdefault(key, (day, uid))
        continue
    for ip, lk in lookups.items():
        fail = lk.get("failure")
        answers = [q.get("ipv4") or q.get("ipv6") for q in (lk.get("queries") or []) for q in (q.get("answers") or [])]
        outcome = f"fail:{fail}" if fail else f"ok:{','.join(sorted(set(a for a in answers if a)))[:60]}"
        key = (resolver, asn, outcome)
        tally[key] += 1
        examples.setdefault(key, (day, uid))

for (res, asn, out), n in sorted(tally.items(), key=lambda kv: (kv[0][0], -kv[1])):
    d, uid = examples.get((res, asn, out), ("", ""))
    print(f"{n:4d} | {res[:40]:40s} | {asn:17s} | {out[:70]:70s} | {d} {uid}")
