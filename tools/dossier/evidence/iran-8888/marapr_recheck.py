"""Recheck Mar-Apr 2026 with ASN country filtering (RIPEstat rir-stats-country).

Why: OONI/Atlas label by IP geolocation; some "IR" rows sit on foreign ASNs (HK VPN exits,
German/Estonian hosters). Only ASNs registered to IR count as evidence from inside Iran.
Writes marapr_recheck.json. Usage: python3 marapr_recheck.py
"""
import collections, json, os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "asn_country.json")
cc = json.load(open(CACHE)) if os.path.exists(CACHE) else {}


def get(url):
    out = subprocess.run(["curl", "-s", "-m", "60", url], capture_output=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return {}


def country(asn):
    asn = str(asn).upper().replace("AS", "")
    if asn not in cc:
        d = get(f"https://stat.ripe.net/data/rir-stats-country/data.json?resource=AS{asn}").get("data", {})
        res = d.get("located_resources") or []
        cc[asn] = res[0].get("location") if res else "?"
        json.dump(cc, open(CACHE, "w"), indent=1)
    return cc[asn]


raw = json.load(open(os.path.join(HERE, "marapr_raw.json")))
goog = json.load(open(os.path.join(HERE, "marapr_ooni_google.json")))

# 1. OONI uploads per day split by ASN country
agg = get("https://api.ooni.io/api/v1/aggregation?probe_cc=IR&since=2026-03-01&until=2026-05-01&axis_x=measurement_start_day&axis_y=probe_asn")
ooni = collections.defaultdict(lambda: {"IR": 0, "foreign": 0, "ir_asns": collections.Counter(), "foreign_asns": collections.Counter()})
for r in agg.get("result", []):
    d, a, n = r["measurement_start_day"][:10], r["probe_asn"], r["measurement_count"]
    key = "IR" if country(a) == "IR" else "foreign"
    ooni[d][key] += n
    ooni[d]["ir_asns" if key == "IR" else "foreign_asns"][f"AS{a}"] += n

# 2. Direct Google DoH answers by day, IR-registered ASNs only
g = collections.defaultdict(lambda: collections.Counter())
for r in goog:
    if r["ip"] not in ("8.8.8.8", "8.8.4.4"):
        continue
    where = "IR" if country(r["asn"]) == "IR" else "foreign"
    g[r["day"]][(where, r["asn"], r["ip"], "ok" if r["outcome"] == "answered" else "fail")] += 1

# 3. Atlas connected probes by day, IR-registered ASNs only
atlas = {}
for d, v in raw["atlas"]["per_day"].items():
    ir = {a: n for a, n in v["by_asn"].items() if country(a) == "IR"}
    atlas[d] = {"IR": sum(ir.values()), "ir_asns": ir, "foreign": {a: n for a, n in v["by_asn"].items() if a not in ir}}

days = sorted(set(raw["ioda"]["ping-slash24"]))
out = {}
for d in days:
    gd = g[d]
    ok8 = {k[1]: n for k, n in gd.items() if k[0] == "IR" and k[2] == "8.8.8.8" and k[3] == "ok"}
    fail8 = {k[1]: n for k, n in gd.items() if k[0] == "IR" and k[2] == "8.8.8.8" and k[3] == "fail"}
    out[d] = {
        "ooni_ir_uploads": ooni[d]["IR"], "ooni_foreign_uploads": ooni[d]["foreign"],
        "ooni_ir_asns": dict(ooni[d]["ir_asns"].most_common(6)),
        "atlas_ir": atlas.get(d, {}).get("IR", 0), "atlas_ir_asns": atlas.get(d, {}).get("ir_asns", {}),
        "g8888_ok_ir": ok8, "g8888_fail_ir": fail8,
        "g8888_foreign_ok": sum(n for k, n in gd.items() if k[0] == "foreign" and k[2] == "8.8.8.8" and k[3] == "ok"),
    }
json.dump(out, open(os.path.join(HERE, "marapr_recheck.json"), "w"), indent=1)
print("asn countries:", {a: c for a, c in sorted(cc.items()) if c != "IR"}, "(non-IR only)")
for d, v in out.items():
    print(d, "ooniIR", v["ooni_ir_uploads"], "ooniForeign", v["ooni_foreign_uploads"], "atlasIR", v["atlas_ir"],
          "8888okIR", sum(v["g8888_ok_ir"].values()), json.dumps(v["g8888_ok_ir"]), "failIR", sum(v["g8888_fail_ir"].values()))
