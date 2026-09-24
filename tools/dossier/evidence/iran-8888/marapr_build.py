"""Build iran-marapr-2026.md: one daily table for 2026-03-01..04-30 from the collected raw files.

Inputs beside this file: marapr_raw.json, baseline_feb_raw.json, and when present
marapr_ooni_google.json (OONI DoH to dns.google, per Google IP) and marapr_8888.json (Atlas).
Usage: python3 marapr_build.py
"""
import collections, datetime, json, os

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    p = os.path.join(HERE, name)
    return json.load(open(p)) if os.path.exists(p) else None


raw, base = load("marapr_raw.json"), load("baseline_feb_raw.json")
goog, atl = load("marapr_ooni_google.json"), load("marapr_8888.json")


def mean_of(sig, src):
    return sum(v["mean"] for v in src["ioda"][sig].values()) / len(src["ioda"][sig])


B = {s: mean_of(s, base) for s in ("ping-slash24", "merit-nt", "gtr/WEB_SEARCH", "bgp")}
B_atlas = sum(v["connected_any_time"] for v in base["atlas"]["per_day"].values()) / len(base["atlas"]["per_day"])
B_ooni = sum(sum(t["measurement_count"] for t in v.values()) for d, v in raw["ooni"]["per_day"].items() if "2026-02-20" <= d <= "2026-02-27") / 8

# Dated statements from outside sources (verbatim fragments; see iran-8888-report-v2.md for URLs).
EVENTS = {
    "2026-03-02": [("Kentik blog (snippet)", 'traffic "less than 1% of normal ... drops on March 2, March 5, and March 15"')],
    "2026-03-05": [("Kentik blog (snippet)", "drop named on March 5 (same sentence)")],
    "2026-03-12": [("IODA Mastodon 116222156726557661", '"briefly recovered on March 12 6:35 PM - 6:55 PM local time ... AS58224 ... 32.9% of the population"')],
    "2026-03-13": [("Filterwatch 2026-03-17", '"Since March 13, 2026 ... target even the \'white SIM cards\'"')],
    "2026-03-15": [("Filterwatch 2026-03-17", '"new large-scale disruption ... 12:00 UTC on March 15"'), ("Kentik blog (snippet)", "drop named on March 15")],
    "2026-03-18": [("arXiv 2605.00187 (Censys data)", '"18 March, approximately 3,700 genuinely active hosts"')],
    "2026-04-01": [("arXiv 2605.00187 (Censys data)", '"floor of approximately 10-11K hosts, about 1%" (Apr 1-6)')],
    "2026-04-12": [("Digiato", "whitelist SIM for business staff, 50 GB, 2 million toman (Apr 12-13)")],
    "2026-04-14": [("IODA + Ainita report", '"Access to the global Internet is still largely shutdown ... ~3%"; "Internet Pro" unveiled Apr 14')],
}
RANGE_NOTE = ("Cloudflare Q1 2026 summary", 'Feb 28 07:00 UTC traffic "well under 1%"; residual IP + DNS traffic Feb 28 - Apr 28 '
              '"supports reports that the shutdown was effectively achieved through aggressive filtering, with so-called \'whitelists\' and \'white SIM cards\'"')

g8 = collections.defaultdict(collections.Counter)
if goog:
    for r in goog:
        if r["ip"] in ("8.8.8.8", "8.8.4.4"):
            g8[r["day"]][(r["ip"], "ok" if r["outcome"] == "answered" else r["outcome"].replace("fail:", ""), r["asn"])] += 1
a8 = collections.defaultdict(collections.Counter)
if atl:
    for r in atl["rows"]:
        a8[r["day"]][(r["kind"], r["outcome"], r["probe"])] += r["n"]


def pct(v, b):
    return 100.0 * v / b if b else 0.0


rc = load("marapr_recheck.json") or {}
asn_cc = load("asn_country.json") or {}
HOLDER = {"AS52140": "UNHCR", "AS49666": "TIC-GW", "AS12880": "DCI", "AS51074": "Mabna", "AS47262": "Hamara",
          "AS31549": "Shatel", "AS44244": "Irancell", "AS197207": "MCI", "AS58224": "TCI", "AS24631": "FanAp",
          "AS39308": "AndisheSabz", "AS6736": "IPM", "AS142578": "E-Large HK", "AS9147": "?", "AS39074": "?"}


def is_ir(asn):
    return asn_cc.get(str(asn).upper().replace("AS", "")) == "IR"


def name(asn):
    return f"{asn} {HOLDER[asn]}" if asn in HOLDER else asn


def cell_8888(day):
    v = rc.get(day)
    parts = []
    if v:
        for asn, n in sorted(v["g8888_ok_ir"].items()):
            parts.append(f"OONI DoH 8.8.8.8 {name(asn)}: answered x{n}")
        for asn, n in sorted(v["g8888_fail_ir"].items()):
            parts.append(f"OONI DoH 8.8.8.8 {name(asn)}: timeout x{n}")
    for (kind, out, prb), n in sorted(a8[day].items()):
        parts.append(f"Atlas {kind} probe {prb}: {out} x{n}")
    return "; ".join(parts) if parts else "نامشخص"


lines = []
day = datetime.date(2026, 3, 1)
while day <= datetime.date(2026, 4, 30):
    d = day.isoformat()
    io = {s: raw["ioda"].get(s, {}).get(d) for s in B}
    ping_p = pct(io["ping-slash24"]["mean"], B["ping-slash24"]) if io["ping-slash24"] else None
    gtr_p = pct(io["gtr/WEB_SEARCH"]["mean"], B["gtr/WEB_SEARCH"]) if io["gtr/WEB_SEARCH"] else None
    tel_p = pct(io["merit-nt"]["mean"], B["merit-nt"]) if io["merit-nt"] else None
    bgp_p = pct(io["bgp"]["mean"], B["bgp"]) if io["bgp"] else None
    v = rc.get(d, {})
    outbound = bool(v.get("ooni_ir_uploads") or v.get("atlas_ir") or v.get("g8888_ok_ir"))
    if ping_p is None or not rc:
        verdict = "نامشخص"
    elif not outbound and ping_p < 10:
        verdict = "قطع سراسری"
    elif ping_p < 80:
        verdict = "نیمه‌قطع"
    else:
        verdict = "باز"
    c8 = cell_8888(d)
    ioda_txt = (f"BGP {bgp_p:.0f}% / ping-/24 {ping_p:.1f}% (max {io['ping-slash24']['max']:.0f} vs ~{B['ping-slash24']:.0f}) / "
                f"telescope {tel_p:.0f}% / Google search {gtr_p:.0f}%") if ping_p is not None else "no data"
    lines.append((d, "IODA", ioda_txt, verdict, c8))
    ot = raw["ooni"]["per_day"].get(d, {})
    tot = sum(x["measurement_count"] for x in ot.values())
    top = ", ".join(f"{name(a)}={n}" for a, n in list(v.get("ooni_ir_asns", {}).items())[:4])
    lines.append((d, "OONI", f"{tot} uploads, all tests ({pct(tot, B_ooni):.0f}% of Feb 20-27): IR-registered ASNs {v.get('ooni_ir_uploads', 0)}, "
                             f"foreign ASNs geolocated IR {v.get('ooni_foreign_uploads', 0)}; top IR: {top or '-'}", verdict, c8))
    at = raw["atlas"]["per_day"].get(d, {})
    ir_at = ", ".join(f"{name(a)}={n}" for a, n in v.get("atlas_ir_asns", {}).items())
    lines.append((d, "RIPE Atlas", f"IR probes connected on IR-registered ASNs: {v.get('atlas_ir', 0)} (~{B_atlas:.0f} before){' — ' + ir_at if ir_at else ''}; "
                                   f"all 'IR' probes incl. foreign ASNs: {at.get('connected_any_time', 0)}", verdict, c8))
    for src, txt in EVENTS.get(d, []):
        lines.append((d, src, txt, verdict, c8))
    day += datetime.timedelta(days=1)

out = []
out.append("# ایران، مارس و آوریل ۲۰۲۶ — جدولِ روزانه")
out.append("")
out.append("ساخته‌شده با marapr_build.py از دادهٔ خامِ کنارِ این فایل. هیچ سلولی از حدس پر نشده است.")
out.append("")
out.append("## پایهٔ مقایسه، ۲۰ تا ۲۷ فوریه ۲۰۲۶")
out.append("")
out.append("```")
out.append(f"IODA bgp           mean {B['bgp']:.0f}")
out.append(f"IODA ping-slash24  mean {B['ping-slash24']:.0f}")
out.append(f"IODA merit-nt      mean {B['merit-nt']:.1f}")
out.append(f"IODA gtr search    mean {B['gtr/WEB_SEARCH']:.3e}")
out.append(f"OONI uploads/day   mean {B_ooni:.0f}")
out.append(f"Atlas IR connected mean {B_atlas:.1f}")
out.append("```")
out.append("")
out.append("## قاعدهٔ حکم")
out.append("")
out.append("```")
out.append("قطع سراسری : NO outbound signal from any IR-registered ASN that day")
out.append("             (0 OONI uploads, 0 Atlas probes connected, 0 answers from 8.8.8.8) AND ping-/24 < 10%")
out.append("نیمه‌قطع    : outbound signal exists from some IR-registered ASN while ping-/24 < 80%")
out.append("نامشخص      : IODA or the ASN recheck missing for that day")
out.append("ASN filter  : only ASNs registered to IR (RIPEstat rir-stats-country) count; HK/DE/EE/AE ASNs")
out.append("             geolocated as IR by OONI/Atlas are reported separately, never as evidence")
out.append("column 8.8.8.8 : filled ONLY from a direct measurement on an IR-registered ASN")
out.append("```")
out.append("")
out.append("## چرا نسخهٔ اولِ این جدول غلط بود")
out.append("")
out.append("نسخهٔ اول ۴۶ روز را «قطع سراسری» نشان می‌داد. دو خطا باعثش شد:")
out.append("")
out.append("- قاعدهٔ حکم فقط به سیگنال‌های ورودیِ IODA نگاه می‌کرد، یعنی پینگ از بیرون، تلسکوپ و جست‌وجوی گوگل. این سیگنال‌ها ترافیکِ خروجیِ شبکه‌های سفید را نمی‌بینند.")
out.append("- بخشی از ردیف‌هایی که «ایران» برچسب خورده بودند روی شبکه‌های خارجی بودند. بزرگ‌ترینشان AS142578 از هنگ‌کنگ بود، که ۱٬۴۹۸ ردیف از دادهٔ dns.google را داشت.")
out.append("")
out.append("وقتی خطاها برطرف شدند، از شبکه‌های ثبت‌شده در ایران در همهٔ روزها ترافیکِ خروجی دیده شد. پس هیچ روزی در مارس و آوریل «قطع سراسری» به معنای دقیق نبود. کاربرِ عادی قطع بود و شبکه‌های ممتاز باز بودند.")
out.append("")
out.append(f"یادداشتِ بازه‌ای: {RANGE_NOTE[0]} — {RANGE_NOTE[1]}")
out.append("")
out.append("## جدول")
out.append("")
out.append("| تاریخ | منبع | چه دیده شد | حکم همان روز | 8.8.8.8 |")
out.append("|---|---|---|---|---|")
for d, src, txt, v, c8 in lines:
    out.append(f"| {d} | {src} | {txt.replace('|', '/')} | {v} | {c8} |")
out.append("")
cnt = collections.Counter(v for d, s, t, v, c in lines if s == "IODA")
out.append("## جمعِ حکم‌ها")
out.append("")
out.append("```")
for k, n in cnt.items():
    out.append(f"{k}: {n} days")
out.append(f"days 8.8.8.8 ANSWERED on an IR-registered ASN (OONI DoH): {sum(1 for v in rc.values() if v['g8888_ok_ir'])} of {len(rc)}")
out.append(f"days with no such answer: {', '.join(d for d, v in sorted(rc.items()) if not v['g8888_ok_ir'])}")
out.append(f"min IR-ASN OONI uploads on any day: {min(v['ooni_ir_uploads'] for v in rc.values())}")
out.append(f"sources: OONI google file={'yes' if goog else 'MISSING'}, Atlas 8.8.8.8 file={'yes' if atl else 'MISSING'}")
out.append("```")
open(os.path.join(HERE, "iran-marapr-2026.md"), "w").write("\n".join(out) + "\n")
print("\n".join(out[-8:]))
