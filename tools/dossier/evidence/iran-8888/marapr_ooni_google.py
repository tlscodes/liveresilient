"""OONI dnscheck from IR, input https://dns.google/dns-query, 2026-03-01..04-30.

Per measurement: day, probe ASN, bootstrap failure (system resolver hijack of the name),
and per Google IP (8.8.8.8 / 8.8.4.4 / v6) whether the DoH query answered or failed.
Writes marapr_ooni_google.json. Usage: python3 marapr_ooni_google.py
"""
import collections, concurrent.futures, json, os, subprocess, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://api.ooni.io/api/v1"
INPUT = "https://dns.google/dns-query"


def get(url):
    out = subprocess.run(["curl", "-s", "-m", "90", url], capture_output=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return None


uids, url = [], (f"{API}/measurements?probe_cc=IR&test_name=dnscheck&since=2026-03-01&until=2026-05-01"
                 f"&input={urllib.parse.quote(INPUT, safe='')}&limit=1000")
page = get(url) or {}
uids = [m["measurement_uid"] for m in page.get("results", [])]
print("listed", len(uids), flush=True)


def one(uid):
    b = get(f"{API}/measurement/{uid}") or {}
    b = b.get("raw_measurement") or b
    if isinstance(b, str):
        b = json.loads(b)
    tk = b.get("test_keys") or {}
    rows = []
    base = {"day": (b.get("measurement_start_time") or "")[:10], "asn": b.get("probe_asn"), "uid": uid}
    if tk.get("bootstrap_failure"):
        rows.append({**base, "ip": "-", "outcome": "bootstrap:" + tk["bootstrap_failure"],
                     "bootstrap_answers": [a.get("ipv4") or a.get("ipv6") for q in ((tk.get("bootstrap") or {}).get("queries") or []) for a in (q.get("answers") or [])]})
    for key, lk in (tk.get("lookups") or {}).items():
        ip = urllib.parse.urlparse(key).hostname if "://" in key else key
        rows.append({**base, "ip": ip or key, "outcome": ("fail:" + lk["failure"]) if lk.get("failure") else "answered"})
    if not rows:
        rows.append({**base, "ip": "-", "outcome": "no-lookups"})
    return rows


allrows = []
with concurrent.futures.ThreadPoolExecutor(12) as ex:
    for rows in ex.map(one, uids):
        allrows += rows
json.dump(allrows, open(os.path.join(HERE, "marapr_ooni_google.json"), "w"), indent=1)

tally = collections.Counter((r["day"], r["asn"], r["ip"], r["outcome"]) for r in allrows)
for (d, a, ip, o), n in sorted(tally.items()):
    print(d, a, ip, o, n)
