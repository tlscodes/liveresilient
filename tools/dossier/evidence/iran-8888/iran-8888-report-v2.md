# گزارش ۸.۸.۸.۸ در ایران — نسخهٔ ۲

نسخهٔ ۲ در تاریخ ۲۳ سپتامبر ۲۰۲۶ نوشته شد. نسخهٔ ۱ مربوط به ۱۴ سپتامبر است و بدون تغییر در پایین آمده است.

## خلاصهٔ نسخهٔ ۲

نسخهٔ ۱ گفته بود هیچ منبعی ۸.۸.۸.۸ را اندازه نگرفته است. این حرف فقط دربارهٔ گزارش‌های متنی درست بود. دادهٔ خامِ اندازه‌گیری وجود دارد و ستونِ ۸.۸.۸.۸ دیگر حدس نیست.

- پروبِ OONI در ایران آزمونی به نام dnscheck اجرا می‌کند. این آزمون دی‌ان‌اس را از راه اچ‌تی‌تی‌پی‌اس مستقیم به آی‌پیِ گوگل می‌فرستد.
- از اول ژانویه تا ۲۳ سپتامبر ۲۰۲۶، ۹۷۶ اندازه‌گیری از این آزمون ثبت شده و همه یک‌به‌یک خوانده و شمرده شد.
- روی مخابرات، ۸.۸.۸.۸ در ژانویه، فوریه، مه، ژوئن، ژوئیه، اوت و سپتامبر پاسخ داده است.
- در مارس و آوریل حتی یک اندازه‌گیری هم ثبت نشده است. این با قطعیِ ۲۸ فوریه تا ۲۵ مه جور درمی‌آید.
- امروز رزالورِ داخلی برای نامِ دی‌ان‌اسِ گوگل و هفت رزالورِ رمزشدهٔ دیگر آی‌پیِ جعلی برمی‌گرداند، ولی خودِ آی‌پیِ ۸.۸.۸.۸ باز است.

## دستاورد ۱ — اولین اندازه‌گیریِ مستقیمِ ۸.۸.۸.۸ در ۲۰۲۶

روش کار:

```
API      : https://api.ooni.io/api/v1
test     : dnscheck
input    : https://8.8.8.8/dns-query   (DoH to the bare IP, no hostname bootstrap)
windows  : 2026-01-01..2026-05-31 (640 listed) + 2026-06-01..2026-09-24 (336 listed)
script   : ooni_dnscheck_raw.py   (beside this file)
raw tally: g8888_a.txt, g8888_b.txt (beside this file; each row carries a measurement_uid)
```

نتیجه به تفکیکِ ماه و اپراتور:

```
month   | ASN                   | ok  | timeout | other
2026-01 | AS58224 TCI           | 155 | 3       | 2 connection_refused
2026-01 | AS197207 MCI          |  20 | 1       |
2026-01 | AS202468              |  12 | 9       |
2026-01 | AS48715               |  12 | 0       |
2026-01 | AS44244 Irancell      |   0 | 15      |
2026-01 | AS57218 Rightel       |   0 | 12      |
2026-02 | AS58224 TCI           | 158 | 29      |
2026-02 | AS202468              |  45 | 5       |
2026-02 | AS48715               |  27 | 0       |
2026-02 | AS197207 MCI          |  17 | 0       |
2026-02 | AS25124 Datak         |   0 | 43      |
2026-02 | AS44244 Irancell      |   0 | 19      |
2026-02 | AS57218 Rightel       |   0 | 13      |
2026-02 | AS50810 Mobinnet      |   0 | 3       |
2026-03 | (none uploaded)       |   - | -       |
2026-04 | (none uploaded)       |   - | -       |
2026-05 | AS58224 TCI           |  40 | 0       |
2026-06 | AS58224 TCI           | 117 | 1       |
2026-06 | AS48715               |   1 | 2       |
2026-06 | AS44244 Irancell      |   0 | 1       |
2026-06 | AS50810 Mobinnet      |   0 | 1       |
2026-07 | AS58224 TCI           |  38 | 11      |
2026-07 | AS48715               |   7 | 0       |
2026-07 | AS197207 MCI          |   2 | 0       |
2026-07 | AS31549               |   1 | 0       |
2026-07 | AS43754 Asiatech      |   0 | 4       |
2026-08 | AS58224 TCI           |  68 | 4       |
2026-08 | AS31549               |   3 | 0       |
2026-08 | AS197207 MCI          |   1 | 0       |
2026-08 | AS43754 Asiatech      |   0 | 3       |
2026-08 | AS57218 Rightel       |   0 | 1       |
2026-09 | AS58224 TCI           |  46 | 0       |
2026-09 | AS197207 MCI          |   3 | 0       |
2026-09 | AS50810 Mobinnet      |   2 | 6       |
2026-09 | AS31549               |   1 | 0       |
2026-09 | AS24631               |   1 | 0       |
2026-09 | AS43754 Asiatech      |   0 | 7       |
2026-09 | AS58262               |   0 | 4       |
```

برداشت از این جدول:

- مخابرات، یعنی AS58224، در هر ماهی که داده دارد اکثراً باز بوده است.
- ایرانسل، رایتل، داتک و آسیاتک در همهٔ ماه‌ها فقط تایم‌اوت داده‌اند. همراه اول هر بار که اندازه‌گیری شده باز بوده است.
- پس دسترسی به ۸.۸.۸.۸ به اپراتور بستگی دارد، نه به کلِ کشور.

## دستاورد ۲ — دستکاری در نامِ رزالورها، دادهٔ ۲۳ سپتامبر ۲۰۲۶

در ۱۵۰ اندازه‌گیریِ اخیرِ dnscheck، که همه در ۲۳ سپتامبر ثبت شده‌اند، رزالورِ سیستم برای نامِ همهٔ سرویس‌های دی‌ان‌اسِ رمزشده آی‌پیِ جعلی برگرداند. شمارش‌های زیر بر حسبِ تعدادِ lookup است:

```
resolver hostname                    | AS58224 bogon  | AS50810 bogon | AS58224 DoH timeout | AS58224 DoH ok
https://dns.google/dns-query         | 4              | 4             | 12                  | 8
https://cloudflare-dns.com/dns-query | 6              | 4             | 22                  | 10
https://dns.quad9.net/dns-query      | 4              | 4             | 14                  | 6
https://dns.adguard.com/dns-query    | 4 (+2 nxdomain)| 4             | 16                  | 0
https://dns.nextdns.io/dns-query     | 6              | 6             | 16                  | 0
https://dns.switch.ch/dns-query      | 6 (+2 nxdomain)| 6             | 12                  | 0
https://doh.opendns.com/dns-query    | 4              | 6             | 10                  | 0
https://dns.alidns.com/dns-query     | 4              | 4             | 16                  | 4
failure string: bootstrap:dns_bogon_error
```

یعنی سانسور در لایهٔ نام کار می‌کند. کلاینتی که آی‌پی را مستقیم صدا می‌زند، و نه نام را، از این لایه عبور می‌کند.

## دستاورد ۳ — رخدادهای بعد از ۳۰ ژوئن، ادامهٔ جدولِ زمانی

```
#  | date        | source                          | what it says
26 | 2026-06-08  | Filterwatch June report (07-08) | international traffic "peaked at approximately 60% of its pre-shutdown levels"
27 | 2026-06-24  | Filterwatch June report         | still "below normal baseline levels"
28 | 2026-07-08  | Filterwatch June report         | data centers "still not returned to pre-January 8 level"; authorities
   |             |                                 | "track the identity of every purchaser of a server ... and the IP addresses they use"
29 | 2026-08-14  | Filterwatch (title only)        | "Iranians Spend 39% Less Time Online Than the Global Average"
30 | 2026-08-26  | RFE/RL via GlobalSecurity       | Cyberspace Regulation bill: ISPs must authenticate users; gateways under the
   |             |                                 | Supreme Cyberspace Council; VPN criminalization dropped from the text
31 | 2026-09-09  | IODA via Voidly (single source) | 01:30-12:15 UTC, BGP + ping-slash24, Yazd/Qom/Markazi/Zanjan, 23.4% anomaly,
   |             |                                 | corroboration 0.6 - regional, not a national blackout
32 | 2026-09-14  | Filterwatch (title only)        | "From Mandatory Identity Verification to the Promise of Net Neutrality"
33 | 2026-09-23  | OONI raw (this report)          | 8.8.8.8 DoH open on AS58224; DoH hostnames bogon-hijacked on AS58224 + AS50810
```

## دستاورد ۴ — یک ادعای غلط که شناسایی و کنار گذاشته شد

موتورِ جست‌وجو ادعا کرد ترافیکِ ایران در اوت ۲۰۲۶ «۷۵٪ افت» کرده است. منبعِ آن ادعا توییتِ کلودفلر در ژوئن ۲۰۲۵ است، پس این ادعا وارد جدول نشد:

```
https://x.com/CloudflareRadar/status/1934988359400624264
```

## حکمِ تازه برای ستونِ ۸.۸.۸.۸

- ژانویه، فوریه و ژوئن تا سپتامبر: برای مخابرات و همراه اول، باز با شاهدِ OONI. برای ایرانسل، رایتل، داتک و آسیاتک، بسته.
- مارس و آوریل: نامشخص، چون هیچ اندازه‌گیری‌ای بارگذاری نشده است. حدس این است که قطع بوده، ولی شاهدی در دست نیست.
- فرضِ «فقط سیم سفید به ۸.۸.۸.۸ می‌رسد» با این داده نه تأیید می‌شود و نه رد. OONI نوعِ سیم‌کارت را ثبت نمی‌کند.

## چیزهایی که هنوز اندازه‌گیری نشده است

- دی‌ان‌اسِ ساده روی پورتِ ۵۳ به ۸.۸.۸.۸ در OONI ورودیِ ثبت‌شده‌ای ندارد و صفر اندازه‌گیری دارد:

```
udp://8.8.8.8:53   -> 0 measurements in 2026
udp://8.8.4.4:53   -> 0
dot://8.8.8.8:853  -> 0
```

- رسیدنِ پرسش از رزالورِ خودِ اپراتور به سرورِ معتبرِ ما، که مسیرِ اصلیِ اپ است، در هیچ منبعی نیست. منبعِ بعدی برای این دو، پروب‌های RIPE Atlas در ایران است.
- سوگیریِ نمونه: فقط کاربری که توانسته نتیجه را بفرستد دیده می‌شود. بیشترِ داده از مخابرات است.

## منابعِ تازهٔ نسخهٔ ۲

```
https://api.ooni.io/api/v1/measurements?probe_cc=IR&test_name=dnscheck&input=https%3A%2F%2F8.8.8.8%2Fdns-query
https://api.ooni.io/api/v1/aggregation?probe_cc=IR&test_name=dnscheck&axis_x=measurement_start_day
https://filter.watch/english/2026/07/08/network-monitoring-june-2026-from-partial-internet-restoration-to-increased-control-over-data-centers/
https://filter.watch/english/
https://www.globalsecurity.org/wmd/library/news/iran/2026/09/iran-260903-rferl02.htm
https://voidly.ai/incident/IR-2026-2429
https://ioda.inetintel.cc.gatech.edu/country/IR
https://ooni.org/post/2026-women-on-web-blocked/
https://ircf.space/   (landing page only: no dated report; clean-IP service retired)
```

نکتهٔ روش: شمارندهٔ تجمیعیِ OONI همهٔ اندازه‌گیری‌های dnscheck در ایران را «failure» نشان می‌دهد. خواندنِ دادهٔ خام نشان داد که بسیاری از همین اندازه‌گیری‌ها در واقع پاسخ گرفته‌اند، پس به این برچسب نمی‌شود تکیه کرد. هر پرس‌وجو در API هم به بازهٔ ۱۸۰ روز محدود است.

---

# نسخهٔ ۱ (۱۴ سپتامبر ۲۰۲۶)، بدون تغییر

هیچ منبع نهادی یا مقالهٔ پژوهشیِ سال ۲۰۲۶ خودِ دی‌ان‌اس عمومی گوگل را برای سیم عادی یا سیم سفید اندازه نگرفته و حتی نام نبرده؛ ستون‌های «۸.۸.۸.۸» در جدول شما استنتاج از ترافیک دی‌ان‌اس کلودفلر و سیگنال سرویس‌های گوگل است، نه گفتهٔ هیچ منبعی.

## چه چیزی واقعاً پیدا شد

- ورک‌فلو پیش از توقف، دو خانوادهٔ منبع را کامل کرده بود: کلودفلر و IODA؛ ۳۱ یافتهٔ تاریخ‌دار، صفر مورد با ذکر صریحِ ۸.۸.۸.۸.
- یک عاملِ هدفمند با سقف ۱۰ جست‌وجو و ۱۰ صفحه، فقط دنبال متنِ عینیِ ۸.۸.۸.۸ گشت: صفر مورد در ۲۰۲۶.
- صفحه‌هایی که باز شد و رشتهٔ ۸.۸.۸.۸ در آن‌ها نبود:

```
github.com/net4people/bbs/issues/561                     (2026-01-08 thread)
petsymposium.org/foci/2026/foci-2026-0016.pdf            (June 2025 shutdown, not 2026)
filter.watch/english/2026/01/16/investigative-report-technical-breakdown-of-the-january-2026-shutdown/
state-of-iranblackout.whisper.security                   (live tracker, 27 MB)
arxiv.org/html/2605.00187                                (Multi-Perspective Study, v2 2026-07-30)
arxiv.org/html/2603.28753v1                              (Aceto et al., 2026-03-30; only resolver named: 1.1.1.1)
censys.com/blog/irans-internet-a-censys-perspective      (2025-06-23, June 2025)
filter.watch/english/2026/03/17/network-monitoring-report-march-2026-...   ("DNS References: None found")
zoomit.ir/tech-iran/453550-iran-national-cyberspace-center/               (2025-12-10)
zoomit.ir/report/455804-blacklist-whitelist-shift-internet-control/       (2026-01-21)
```

- تنها اشارهٔ موتور جست‌وجو به «مسدودسازی DoH روی ۸.۸.۸.۸» به پستِ کلودفلر در سپتامبر ۲۰۲۲ برمی‌گردد، نه ۲۰۲۶.

## جدول زمانی: فقط آنچه منبع نوشته

ستونِ آخر یعنی: آیا منبع دربارهٔ ۸.۸.۸.۸ چیزی گفته؟ در همهٔ ردیف‌ها «نه».

```
#  | date                | source                        | measured                        | what the source wrote (shortened, verbatim)                                                  | status              | 8.8.8.8
1  | 2025-12-29..01-08   | IODA Mastodon 115860144646928443 | active probing / global       | "significant instability and disruption ... since nation-wide protests started Dec 29"       | partial             | no
2  | 2026-01-08          | Cloudflare blog (iran-protests) | HTTP+DNS traffic to Cloudflare | "Between 16:30-17:00 UTC, traffic volumes fell nearly 90% ... MCCI (AS197207), IranCell"     | closed              | no
3  | 2026-01-08          | IODA Mastodon 115860734641077656 | active probing               | "Iran is nearly completely offline from the global Internet"                                 | closed              | no
4  | 2026-01-08          | Filterwatch 2026-01-16 report   | NIN + privileged SIM + landline | "the state severed access to the NIN, privileged SIM cards, and even landline telephone networks" | closed (white too) | no
5  | 2026-01-08..01-18   | IODA comparative report         | active probing                 | "nominal amount of responsiveness to our active probing (~3%)"                               | closed (~3%)        | no
6  | 2026-01-09          | Cloudflare blog (iran-protests) | 1.1.1.1 resolver queries       | "access to Cloudflare's public DNS resolver, 1.1.1.1, also became available again around 10:00 UTC" | brief/partial  | no
7  | 2026-01-09          | IODA Mastodon 115865708380884966 | per-ASN probing              | "Specific networks, likely with permission ... whitelisting, show signs of connectivity since 11:30 UTC" | white: partial | no
8  | 2026-01-13..01-20   | Zoomit 455738 (Cloudflare per-ASN) | 1.1.1.1 queries per ASN     | «امکان ارسال درخواست DNS به خارج کشور شروع شده است ... شرکت ارتباطات زیرساخت (۴۷.۹ درصد)»    | partial             | no
9  | 2026-01-17          | IODA Mastodon 115908344729386809 | per-ASN (Rightel AS57218)    | "signs of recovery of Internet connectivity in Iran for ISP Rightel"                         | partial             | no
10 | 2026-01-18..01-21   | IODA Mastodon 115916584146434618 + report | Google product signal via NIN | "have not translated to meaningful connectivity with the global Internet"; whitelisted services via NIN recovered | global: closed; white services: partial | no
11 | 2026-01-21..01-22   | Cloudflare Q1 summary           | aggregate traffic              | "a small amount of traffic returned [Jan 21], only to disappear a little over 24 hours later" | brief               | no
12 | 2026-01-24..01-27   | IODA Mastodon 115962033907607978, 115967317577703407 | telescope + active probing | "sustained, partial recovery since ~7:30 PM Jan 24"; "sharp increase in Active Probing" Jan 27 | partial          | no
13 | ~2026-01-28         | NetBlocks X 2016555382320005410 (snippet) | ordinary vs whitelist | "20 full days after ... most ordinary users still face heavy filtering and intermittent service under a whitelist system" | ordinary: filtered; white: in force | no
14 | 2026-01-27..02-27   | IODA comparative report         | Google products (YouTube, Gmail, Maps) | "Iranian Internet users are not experiencing a return to the Internet they experienced" | partial          | no
15 | 2026-02-28          | Cloudflare Q1 summary           | HTTP + 1.1.1.1 traffic         | "sharp drop ... 07:00 UTC. Traffic levels fell to well under 1%"                             | closed              | no
16 | 2026-02-28          | IODA Mastodon 116148656276570120 | active probing + telescope    | "cutoff from the global Internet since ~7:00 AM UTC"                                         | closed              | no
17 | 2026-02-28..04-28   | Cloudflare Q1 summary           | residual IP + DNS traffic      | "supports reports that the shutdown was effectively achieved through aggressive filtering, with so-called 'whitelists' and 'white SIM cards'" | ordinary: closed; white: partial | no
18 | 2026-03-12          | IODA Mastodon 116222156726557661 | BGP + probing (AS58224)      | "briefly recovered on March 12 6:35 PM - 6:55 PM local time ... AS58224 ... 32.9% of the population" | brief         | no
19 | 2026-03-02..03-15   | Kentik blog (snippet)           | traffic volume                 | "less than 1% of normal ... drops on March 2, March 5, and March 15 ... crackdown on whitelisted users" | closed; white restricted Mar 15 | no
20 | 2026-03-13..03-15   | Filterwatch 2026-03-17 report   | white SIM policy               | "Since March 13, 2026 ... target even the 'white SIM cards'"; "new large-scale disruption ... 12:00 UTC on March 15" | white: partial->closed | no
21 | 2026-03-18; 04-01..04-06 | arXiv 2605.00187 (Censys data) | reachable hosts              | "18 March, approximately 3,700 genuinely active hosts"; "floor of approximately 10-11K hosts, about 1%" | closed        | no
22 | 2026-04-12..04-13   | Digiato                         | whitelist policy               | «اینترنت وایت‌لیست ... سیم‌کارتی که برای هر شخص (کارمند کسب‌وکار) با ۵۰ گیگابایت ... ۲ میلیون تومان» | white: open (paid) | no
23 | 2026-04-14..04-27   | IODA + Ainita report            | active probing + Google via NIN | "Access to the global Internet is still largely shutdown ... ~3%"; "Internet Pro" unveiled Apr 14 | ordinary: closed; Internet Pro: open | no
24 | 2026-05-26          | Cloudflare (partially-restored) | HTTP + 1.1.1.1 queries         | "around 11:00 UTC on May 26, 87 days after the second shutdown ... marked increase in both traffic and DNS queries" | partial (open) | no
25 | 2026-05-27..06-30   | Cloudflare Q2 summary           | HTTP bytes                     | "restored to 40% of its pre-outage levels ... as high as 90% before settling back"           | partial->open       | no
```

## حکم ردیف‌به‌ردیف جدول شما

```
row | verdict            | note
1   | confirmed          | IODA: instability since Dec 29 (row 1 above). 8.8.8.8 column: no source.
2   | partly-supported   | traffic ~0 = Cloudflare/IODA (rows 2,3). Filterwatch sentence exists (row 4) but it is about NIN, privileged SIMs, landlines - not about 8.8.8.8.
3   | partly-supported   | 1.1.1.1 spike = Cloudflare (row 6), correct. Whitelist column can be better than "unknown": IODA row 7 says whitelisted networks showed connectivity from 11:30 UTC.
4   | partly-supported   | "fraction of a percent" ~ IODA ~3% (row 5). But Zoomit/Cloudflare per-ASN show DNS to 1.1.1.1 resumed Jan 13-20 (row 8) and Rightel Jan 17 (row 9): whitelist was not "still dark".
5   | partly-supported   | IODA Google Search/Images via NIN = confirmed (row 10). Filterwatch "service whitelist" text not fetched (only the Jan 28 title seen).
6   | unsupported (attribution) | No Zoomit text saying "whites unfiltered after 20 days". The 20-day sentence is NetBlocks (row 13) and says ordinary users still filtered under a whitelist system.
7   | partly-supported   | Cloudflare "well under 1%" + continued IP/DNS traffic -> whitelists/white SIMs = confirmed (rows 15,17). "Filterwatch: white/editorial connected from hour one" not verified.
8   | contradicted (attribution+date) | Censys blog is June 2025. The ~1% floor is arXiv 2605.00187 using Censys data, dated Apr 1-6 2026; deepest day Mar 18 (row 21).
9   | partly-supported   | White-SIM restriction from Mar 13 = Filterwatch (row 20). "less than 1%" = Kentik, not Filterwatch/Zoomit/NetBlocks (row 19). "AS12880 collapse": no source; AS12880 is a former TIC ASN (now AS49666).
10  | confirmed          | Cloudflare <1% and residual DNS = whitelists (rows 15,17); IODA ~3% through Apr 27 (row 23). Your own note is right: chart is 1.1.1.1, not 8.8.8.8.
11  | confirmed          | Cloudflare May 26 11:00 UTC (row 24); 40% by May 27 (row 25).
```

## پاسخ به فرضِ شما

فرض شما این بود: اپراتور فقط شماره‌های سفید را به دی‌ان‌اس گوگل می‌رساند و بستهٔ سیم عادی همان‌جا دور ریخته می‌شود.

- هیچ منبعی این سازوکار را برای دی‌ان‌اس گوگل به‌صراحت ننوشته است.
- آنچه منابع می‌گویند: سفیدسازی بر پایهٔ سیم‌کارت و احراز هویت است (Filterwatch، کلودفلر، IODA، دیجیاتو)، و بر پایهٔ سرویس (جست‌وجو و تصاویر گوگل از طریق شبکهٔ ملی).
- تنها شاهدِ اندازه‌گیری‌شدهٔ «رسیدن خطوط سفید به یک resolver خارجی» مربوط به دی‌ان‌اس کلودفلر است، از دیدگاه خودِ کلودفلر، در بازهٔ ۲۸ فوریه تا ۲۸ آوریل (ردیف ۱۷).
- تعمیم این شاهد به دی‌ان‌اس گوگل حدس است؛ در جدول باید «نامشخص» بماند.
- دو مقالهٔ پژوهشی از دستکاری در سطح پروتکل دی‌ان‌اس می‌گویند، بدون نام‌بردن از هیچ resolver مشخصی.

## هزینه

- ورک‌فلو پس از تکمیل ۲ از ۱۶ جست‌وجوگر متوقف شد؛ رقم دقیق توکن آن اندازه‌گیری نشد.
- عاملِ هدفمند: ۱۱۹٬۲۰۴ توکن، ۲۴ فراخوانی ابزار.

## فهرست منابع

```
https://blog.cloudflare.com/iran-protests-internet-shutdown/
https://blog.cloudflare.com/q1-2026-internet-disruption-summary/
https://blog.cloudflare.com/iran-internet-partially-restored-may-2026/
https://blog.cloudflare.com/q2-2026-internet-disruption-summary/
https://mastodon.social/@IODA/115860144646928443
https://mastodon.social/@IODA/115860734641077656
https://mastodon.social/@IODA/115865688995797610
https://mastodon.social/@IODA/115865708380884966
https://mastodon.social/@IODA/115882311163099568
https://mastodon.social/@IODA/115901049920904720
https://mastodon.social/@IODA/115908344729386809
https://mastodon.social/@IODA/115916584146434618
https://mastodon.social/@IODA/115962033907607978
https://mastodon.social/@IODA/115967317577703407
https://mastodon.social/@IODA/116148656276570120
https://mastodon.social/@IODA/116166393189726166
https://mastodon.social/@IODA/116222156726557661
https://mastodon.social/@IODA/116255944342573551
https://mastodon.social/@IODA/116437593267656080
https://ioda.inetintel.cc.gatech.edu/reports/a-comparative-look-at-internet-shutdowns-in-iran-2019-2022-2026-and-2026/
https://ioda.inetintel.cc.gatech.edu/reports/from-war-to-sovereignty-the-normalization-of-tiered-internet-in-iran/
https://theconversation.com/irans-latest-internet-blackout-extends-to-phones-and-starlink-273439
https://filter.watch/english/2026/01/16/investigative-report-technical-breakdown-of-the-january-2026-shutdown/
https://filter.watch/english/2026/01/28/network-monitoring-january-2026-from-regional-disuptions-to-total-blackout-and-whitelisted-access/
https://filter.watch/english/2026/03/06/network-monitoring-february-2026-a-new-phase-of-selective-internet-in-iran/
https://filter.watch/english/2026/03/17/network-monitoring-report-march-2026-will-the-december-blackout-in-iran-happen-again/
https://x.com/netblocks/status/2016555382320005410
https://www.kentik.com/blog/internet-and-airstrikes-tracking-irans-extended-communication-blackout/
https://arxiv.org/html/2605.00187
https://arxiv.org/html/2603.28753v1
https://www.zoomit.ir/tech-iran/455738-summary-cloudflare-report/
https://www.zoomit.ir/report/455804-blacklist-whitelist-shift-internet-control/
https://digiato.com/tech/iran-internet-cloudflare-radar-whitelist-vpn-analysis
https://www.censys.com/blog/irans-internet-a-censys-perspective
```

صفحه‌هایی که با «snippet» علامت خورده‌اند فقط از خلاصهٔ موتور جست‌وجو دیده شده‌اند، نه از متن کامل.
