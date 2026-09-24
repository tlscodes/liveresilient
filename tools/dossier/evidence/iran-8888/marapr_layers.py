"""Iran, 2026-03-01..04-30: which paths out were open, per ASN layer. No agents; reads existing files first.

Layers (never mixed):
  L1 consumer   : AS197207 MCI, AS44244 Irancell, AS58224 TCI
  L2 privileged : AS52140 UNHCR, AS49666 TIC-GW, AS12880 DCI, AS51074 Mabna, AS6736 IPM
  L3 other      : every other IR-registered ASN
  excluded      : ASNs not registered to IR (asn_country.json / RIPEstat) — never evidence
Paths:
  P1 Atlas UDP/53 -> 8.8.8.8   (marapr_8888.json from the running scan; unknown until it finishes)
  P2 Atlas UDP/53 -> 1.1.1.1   (not collected -> unknown)
  P3 OONI DoH -> 8.8.8.8/8.8.4.4        (marapr_ooni_google.json, existing)
  P4 OONI DoH -> Cloudflare IPs          (fetched: cloudflare-dns.com dnscheck, IR ASNs only, small)
  P5 operator resolver                   (dnscheck bootstrap of dns.google / cloudflare-dns.com: bogon = fake)
  P6 OONI upload received abroad <=1h after run (measurement_uid prefix = receive time)
  P7 Atlas controller session            (msm 7000 connected days, marapr_raw.json)
Output: iran-marapr-layers.md. Cache: layers_cache/. Usage: python3 marapr_layers.py
"""
import collections, concurrent.futures, datetime, json, os, re, subprocess, sys, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "layers_cache")
os.makedirs(CACHE, exist_ok=True)
OONI = "https://api.ooni.io/api/v1"
SINCE, UNTIL = "2026-03-01", "2026-05-01"
L1 = {"AS197207": "MCI", "AS44244": "Irancell", "AS58224": "TCI"}
L2 = {"AS52140": "UNHCR", "AS49666": "TIC-GW (national gateway)", "AS12880": "DCI (state IT / gateway)",
      "AS51074": "Mabna (datacenter)", "AS6736": "IPM (academic)"}
STEPS = 7


def bar(step, label, i, n):
    n = max(n, 1)
    w = 30
    fill = int(w * i / n)
    sys.stderr.write(f"\r[{step}/{STEPS}] {label:34s} [{'#' * fill}{'.' * (w - fill)}] {i}/{n} {100 * i // n:3d}%")
    if i >= n:
        sys.stderr.write("\n")
    sys.stderr.flush()


def get(url, cache_name=None):
    path = os.path.join(CACHE, cache_name) if cache_name else None
    if path and os.path.exists(path):
        return json.load(open(path))
    out = subprocess.run(["curl", "-s", "-m", "120", url], capture_output=True).stdout
    try:
        data = json.loads(out)
    except Exception:
        return None
    if path:
        json.dump(data, open(path, "w"))
    return data


def load(name):
    p = os.path.join(HERE, name)
    return json.load(open(p)) if os.path.exists(p) else None


asn_cc = load("asn_country.json") or {}


def norm(asn):
    return "AS" + str(asn).upper().replace("AS", "")


def country(asn):
    k = norm(asn)[2:]
    if k not in asn_cc:
        d = (get(f"https://stat.ripe.net/data/rir-stats-country/data.json?resource=AS{k}") or {}).get("data", {})
        res = d.get("located_resources") or []
        asn_cc[k] = res[0].get("location") if res else "?"
        json.dump(asn_cc, open(os.path.join(HERE, "asn_country.json"), "w"), indent=1)
    return asn_cc[k]


def layer(asn):
    a = norm(asn)
    if country(a) != "IR":
        return "excluded"
    return "L1" if a in L1 else "L2" if a in L2 else "L3"


def holder(asn):
    a = norm(asn)
    return L1.get(a) or L2.get(a) or ""


def is_bogon(ip):
    return bool(re.match(r"^(10\.|127\.|0\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|169\.254\.|fc|fd|::1)", ip or ""))


# table: (asn, path) -> {"ok": n, "fail": n, "ok_dates": set, "fail_dates": set, "ex": [], "note": str, "status": opt}
T = collections.defaultdict(lambda: {"ok": 0, "fail": 0, "ok_dates": set(), "fail_dates": set(), "ex": [], "note": "", "status": None})


def rec(asn, path, ok, day, ex=None):
    r = T[(norm(asn), path)]
    r["ok" if ok else "fail"] += 1
    r["ok_dates" if ok else "fail_dates"].add(day)
    if ex and len(r["ex"]) < 3 and (ok or not r["ok"]):
        r["ex"].append(ex)


def ooni_fetch(uid):
    b = get(f"{OONI}/measurement/{uid}", cache_name=f"m_{uid}.json") or {}
    b = b.get("raw_measurement") or b
    return json.loads(b) if isinstance(b, str) else b


def bootstrap_answers(tk):
    boot = tk.get("bootstrap") or {}
    return [a.get("ipv4") or a.get("ipv6") for q in (boot.get("queries") or []) for a in (q.get("answers") or [])]


# ---------- P3 OONI DoH -> Google (existing file) + P5 bogon evidence from it ----------
goog = load("marapr_ooni_google.json") or []
bar(1, "P3 OONI DoH -> 8.8.8.8 (file)", 0, len(goog))
for i, r in enumerate(goog, 1):
    if r["ip"] in ("8.8.8.8", "8.8.4.4"):
        rec(r["asn"], "OONI DoH -> 8.8.8.8/8.8.4.4", r["outcome"] == "answered", r["day"], r["uid"])
    elif r["ip"] == "-" and r["outcome"].startswith("bootstrap:dns_bogon"):
        rec(r["asn"], "operator resolver: dns.google", False, r["day"], r["uid"])
    if i % 200 == 0 or i == len(goog):
        bar(1, "P3 OONI DoH -> 8.8.8.8 (file)", i, len(goog))
# measurements whose bootstrap succeeded = resolver gave a non-bogon answer for dns.google
boot_ok = {}
for r in goog:
    if r["ip"] in ("8.8.8.8", "8.8.4.4"):
        boot_ok.setdefault(r["uid"], (r["asn"], r["day"]))
bogon_uids = {r["uid"] for r in goog if r["ip"] == "-" and r["outcome"].startswith("bootstrap:dns_bogon")}
for uid, (asn, day) in boot_ok.items():
    if uid not in bogon_uids:
        rec(asn, "operator resolver: dns.google", True, day, uid)

# ---------- P4 OONI DoH -> Cloudflare (fetch, IR ASNs only) ----------
agg = load("ooni_doh_agg_cf_asn.json") or get(
    f"{OONI}/aggregation?probe_cc=IR&test_name=dnscheck&input=https%3A%2F%2Fcloudflare-dns.com%2Fdns-query&since={SINCE}&until={UNTIL}&axis_x=probe_asn")
cf_asns = [norm(x["probe_asn"]) for x in (agg or {}).get("result", []) if country(x["probe_asn"]) == "IR"]
uids = []
for a in cf_asns:
    lst = get(f"{OONI}/measurements?probe_cc=IR&probe_asn={a}&test_name=dnscheck&input={urllib.parse.quote('https://cloudflare-dns.com/dns-query', safe='')}"
              f"&since={SINCE}&until={UNTIL}&limit=1000", cache_name=f"cf_list_{a}.json") or {}
    uids += [m["measurement_uid"] for m in lst.get("results", [])]
bar(2, "P4 OONI DoH -> Cloudflare (fetch)", 0, len(uids))
with concurrent.futures.ThreadPoolExecutor(12) as ex:
    for i, (uid, b) in enumerate(zip(uids, ex.map(ooni_fetch, uids)), 1):
        tk, asn, day = b.get("test_keys") or {}, b.get("probe_asn"), (b.get("measurement_start_time") or "")[:10]
        ans = bootstrap_answers(tk)
        if tk.get("bootstrap_failure"):
            fake = tk["bootstrap_failure"] == "dns_bogon_error" or any(is_bogon(x) for x in ans)
            rec(asn, "operator resolver: cloudflare-dns.com", False, day, uid)
            if fake:
                T[(norm(asn), "operator resolver: cloudflare-dns.com")]["note"] = "bogon answers seen"
        elif ans:
            rec(asn, "operator resolver: cloudflare-dns.com", not any(is_bogon(x) for x in ans), day, uid)
        for key, lk in (tk.get("lookups") or {}).items():
            rec(asn, "OONI DoH -> Cloudflare IP", not lk.get("failure"), day, uid)
        bar(2, "P4 OONI DoH -> Cloudflare (fetch)", i, len(uids))

# ---------- P6 OONI uploads with collector contact, L1 ASNs (list endpoint, paginated) ----------
up_days = collections.defaultdict(collections.Counter)
contact_days = collections.defaultdict(set)
lag = collections.defaultdict(list)
contemporaneous = collections.defaultdict(list)
late = collections.Counter()
pages = [(a, off) for a in L1 for off in range(0, 6000, 1000)]
bar(3, "P6 OONI uploads L1 (list)", 0, len(pages))
for i, (a, off) in enumerate(pages, 1):
    lst = get(f"{OONI}/measurements?probe_cc=IR&probe_asn={a}&since={SINCE}&until={UNTIL}&limit=1000&offset={off}",
              cache_name=f"up_{a}_{off}.json") or {}
    for m in lst.get("results", []):
        day = m["measurement_start_time"][:10]
        up_days[a][day] += 1
        # measurement_uid prefix = time OONI's collector abroad RECEIVED the upload.
        # Only an upload <= 1 h after the run counts: a late upload may come from another network.
        try:
            ut = datetime.datetime.strptime(m["measurement_uid"][:21], "%Y%m%d%H%M%S.%f")
            st = datetime.datetime.fromisoformat(m["measurement_start_time"].replace("Z", ""))
            d_s = (ut - st).total_seconds()
            lag[a].append(d_s)
            if 0 <= d_s <= 3600 and SINCE <= ut.strftime("%Y-%m-%d") < UNTIL:
                contact_days[a].add(ut.strftime("%Y-%m-%d"))
                contemporaneous[a].append(m["measurement_uid"])
                r = T[(a, "OONI upload received abroad <=1h after run")]
                if ut.strftime("%Y-%m-%d") not in r["ok_dates"]:
                    rec(a, "OONI upload received abroad <=1h after run", True, ut.strftime("%Y-%m-%d"), m["measurement_uid"])
            else:
                late[a] += 1
        except Exception:
            pass
    bar(3, "P6 OONI uploads L1 (list)", i, len(pages))

# proxy / tunnel check on a sample of the contemporaneous L1 uploads
proxy_seen = collections.Counter()
proxy_sampled = collections.Counter()
sample = [(a, u) for a in L1 for u in contemporaneous[a][:: max(1, len(contemporaneous[a]) // 20)][:20]]
bar(3, "P6b proxy/tunnel check (sample)", 0, len(sample))
with concurrent.futures.ThreadPoolExecutor(12) as ex:
    for i, ((a, u), b) in enumerate(zip(sample, ex.map(lambda x: ooni_fetch(x[1]), sample)), 1):
        blob = json.dumps({k: b.get(k) for k in ("annotations", "options", "probe_network_name", "resolver_asn")}).lower()
        proxy_sampled[a] += 1
        if re.search(r"\b(proxy|psiphon|tunnel|tor|socks5?)\b", blob):
            proxy_seen[a] += 1
        bar(3, "P6b proxy/tunnel check (sample)", i, len(sample))

# ---------- P5b operator resolver for L1: web_connectivity system-resolver answers (sample <=60 per ASN) ----------
wc = []
for a in L1:
    lst = get(f"{OONI}/measurements?probe_cc=IR&probe_asn={a}&test_name=web_connectivity&since={SINCE}&until={UNTIL}&limit=1000",
              cache_name=f"wc_list_{a}.json") or {}
    res = lst.get("results", [])
    step = max(1, len(res) // 60)
    wc += [(a, m["measurement_uid"]) for m in res[::step][:60]]
bar(4, "P5 L1 resolver (web_connectivity)", 0, len(wc))
with concurrent.futures.ThreadPoolExecutor(12) as ex:
    for i, ((a, uid), b) in enumerate(zip(wc, ex.map(lambda x: ooni_fetch(x[1]), wc)), 1):
        tk, day = b.get("test_keys") or {}, (b.get("measurement_start_time") or "")[:10]
        ips = [x.get("ipv4") or x.get("ipv6") for q in (tk.get("queries") or []) for x in (q.get("answers") or []) if x.get("ipv4") or x.get("ipv6")]
        dnsf = tk.get("dns_experiment_failure")
        if ips:
            rec(a, "operator resolver: foreign names (web_connectivity)", not any(is_bogon(x) for x in ips), day, uid)
        elif dnsf:
            rec(a, "operator resolver: foreign names (web_connectivity)", False, day, uid)
        bar(4, "P5 L1 resolver (web_connectivity)", i, len(wc))

# ---------- P7 Atlas controller sessions (existing marapr_raw.json) + probe ASN map ----------
raw = load("marapr_raw.json")
probe_asn = {}
url = "https://atlas.ripe.net/api/v2/probes/?country_code=IR&page_size=500&fields=id,asn_v4"
while url:
    page = get(url) or {}
    probe_asn.update({p["id"]: norm(p["asn_v4"]) for p in page.get("results", []) if p.get("asn_v4")})
    url = page.get("next")
days = sorted(raw["atlas"]["per_day"])
bar(5, "P7 Atlas controller sessions", 0, len(days))
for i, d in enumerate(days, 1):
    for p in raw["atlas"]["per_day"][d].get("probes", []):
        if p in probe_asn:
            rec(probe_asn[p], "Atlas probe session to RIPE controller (TCP)", True, d, f"probe {p}")
    bar(5, "P7 Atlas controller sessions", i, len(days))

# ---------- P1/P2 Atlas UDP/53 ----------
bar(6, "P1 Atlas UDP/53 -> 8.8.8.8", 0, 1)
scan = load("marapr_8888.json")
scan_note = ""
if scan:
    for r in scan["rows"]:
        if r["kind"].startswith("dns/udp") and r["probe"] in probe_asn:
            for _ in range(r["n"]):
                rec(probe_asn[r["probe"]], "Atlas UDP/53 -> 8.8.8.8", r["outcome"] == "answered", r["day"], f"probe {r['probe']}")
else:
    txt = open(os.path.join(HERE, "marapr_8888.txt")).read() if os.path.exists(os.path.join(HERE, "marapr_8888.txt")) else ""
    m = re.findall(r"scanned (\d+)/(\d+)", txt)
    scan_note = f"scan still running ({m[-1][0]}/{m[-1][1]} measurements); rerun this script when marapr_8888.json exists" if m else "scan output missing"
bar(6, "P1 Atlas UDP/53 -> 8.8.8.8", 1, 1)

# ---------- write report ----------
bar(7, "write iran-marapr-layers.md", 0, 1)
PATHS = ["Atlas UDP/53 -> 8.8.8.8", "Atlas UDP/53 -> 1.1.1.1", "OONI DoH -> 8.8.8.8/8.8.4.4", "OONI DoH -> Cloudflare IP",
         "operator resolver: dns.google", "operator resolver: cloudflare-dns.com", "operator resolver: foreign names (web_connectivity)",
         "OONI upload received abroad <=1h after run", "Atlas probe session to RIPE controller (TCP)"]
PROTO = {"Atlas UDP/53 -> 8.8.8.8": "DNS UDP/53", "Atlas UDP/53 -> 1.1.1.1": "DNS UDP/53", "OONI DoH -> 8.8.8.8/8.8.4.4": "DoH TCP/443",
         "OONI DoH -> Cloudflare IP": "DoH TCP/443", "OONI upload received abroad <=1h after run": "HTTPS TCP/443",
         "Atlas probe session to RIPE controller (TCP)": "SSH-over-TCP/443"}


def status(path, r):
    if path.startswith("operator resolver"):
        if not r["ok"] and not r["fail"]:
            return "نامشخص"
        return "جوابِ درست" if r["ok"] and not r["fail"] else "جوابِ جعلی" if r["fail"] and not r["ok"] else "هر دو دیده شد"
    if r["ok"]:
        return "باز"
    return "بسته" if r["fail"] else "نامشخص"


def dates(s, k=8):
    s = sorted(s)
    return ", ".join(s[:k]) + (f" (+{len(s) - k})" if len(s) > k else "") if s else "-"


asns_by_layer = collections.defaultdict(set)
for (a, p) in list(T):
    asns_by_layer[layer(a)].add(a)
for a in L1:
    asns_by_layer["L1"].add(a)

lines = []
l1_open = sorted(((a, p, r) for (a, p), r in T.items() if layer(a) == "L1" and r["ok"] and p in PROTO), key=lambda x: -x[2]["ok"])
for a, p, r in l1_open[:3]:
    lines.append(f"{p} | {dates(r['ok_dates'], 4)} | {a} {L1[a]} | {PROTO[p]}")
if not any(a in ("AS197207", "AS44244") for a, p, r in l1_open):
    lines.append("برای همراه اول و ایرانسل پیدا نشد.")
if not lines:
    lines.append("برای همراه اول و ایرانسل پیدا نشد.")

md = ["```"] + lines[:4] + ["```", "", "# ایران، مارس و آوریل ۲۰۲۶ — مسیرهای باز به تفکیکِ لایه", "",
      "ساخته‌شده با marapr_layers.py. فقط ASNهای ثبت‌شده در ایران شاهد حساب شده‌اند. گیت‌وی ملی (TIC، DCI) در لایهٔ ممتاز است، نه مصرف‌کننده.", ""]
TITLES = {"L1": "لایهٔ ۱ — مصرف‌کننده", "L2": "لایهٔ ۲ — ممتاز: UNHCR، دیتاسنتر، گیت‌وی، دانشگاهی", "L3": "لایهٔ ۳ — بقیه", "excluded": "حذف‌شده — ASNِ خارجی، هرگز شاهد نیست"}
for L in ("L1", "L2", "L3", "excluded"):
    md += [f"## {TITLES[L]}", "", "| ASN | holder | path | status | success | fail | dates (success, else fail) | examples |", "|---|---|---|---|---|---|---|---|"]
    for a in sorted(asns_by_layer[L]):
        for p in PATHS:
            r = T.get((a, p))
            if r is None:
                if L != "L1":
                    continue
                r = {"ok": 0, "fail": 0, "ok_dates": set(), "fail_dates": set(), "ex": [], "note": ""}
                if p == "Atlas UDP/53 -> 8.8.8.8":
                    r["note"] = scan_note or "no probe on this ASN in any of the scanned Atlas measurements"
                    r["status"] = "نامشخص — پروب نبود"
                if p == "Atlas UDP/53 -> 1.1.1.1":
                    r["note"] = "not collected"
                    r["status"] = "نامشخص — پروب نبود"
            st = r.get("status") or status(p, r)
            ds = dates(r["ok_dates"]) if r["ok"] else dates(r["fail_dates"])
            note = f" ({r['note']})" if r.get("note") else ""
            md.append(f"| {a} | {holder(a)} | {p}{note} | {st} | {r['ok']} | {r['fail']} | {ds} | {'; '.join(r['ex'])} |")
    md.append("")

md += ["## بارگذاری روزانهٔ OONI از لایهٔ مصرف‌کننده", "", "```", "day        | " + " | ".join(f"{a} {L1[a]}" for a in L1)]
for d in sorted({d for a in L1 for d in up_days[a]}):
    md.append(f"{d} | " + " | ".join(f"{up_days[a].get(d, 0):>6}" for a in L1))
md.append("```")
md.append("")
md.append("فاصلهٔ زمانِ اجرا تا رسیدنِ آپلود به collector در خارج، به ثانیه. فقط آپلودِ حداکثر یک ساعت بعد از اجرا شاهد حساب شده است:")
md.append("")
md.append("```")
for a in L1:
    v = sorted(lag[a])
    if v:
        md.append(f"{a} {L1[a]}: n={len(v)} median={v[len(v) // 2]:.0f}s p90={v[int(len(v) * 0.9)]:.0f}s "
                  f"within_1h={len(contemporaneous[a])} late_or_invalid={late[a]} days_with_upload_within_1h={len(contact_days[a])} "
                  f"proxy/tunnel_words_in_sample={proxy_seen[a]}/{proxy_sampled[a]}")
    else:
        md.append(f"{a} {L1[a]}: no measurements")
md.append("```")
md += ["", "## محدودیت‌ها", "",
       "- گزارشِ OONI وقتی باز می‌شود که پروب به collector در خارج رسیده باشد. ممکن است این اتصال از راهِ پراکسیِ خودِ OONI (Psiphon یا Tor) بوده باشد؛ این فایل آن را جدا نمی‌کند.",
       "- جوابِ درستِ رزالورِ اپراتور برای نامِ خارجی ثابت نمی‌کند که پرسش به بیرون رفته است. ممکن است از کش یا فهرستِ سفید آمده باشد.",
       "- ASNِ پروب‌های Atlas همان ASNِ امروزِ آن‌هاست. ممکن است در مارس و آوریل فرق داشته است.",
       f"- Atlas UDP/53 به ۸.۸.۸.۸: {scan_note or 'from marapr_8888.json'}. ۱.۱.۱.۱ از Atlas جمع نشده است.",
       "- نمونهٔ web_connectivity برای هر ASNِ لایهٔ ۱ حداکثر ۶۰ اندازه‌گیری است که یکنواخت در بازه پخش شده است."]
open(os.path.join(HERE, "iran-marapr-layers.md"), "w").write("\n".join(md) + "\n")
bar(7, "write iran-marapr-layers.md", 1, 1)
print("\n".join(lines[:4]))
