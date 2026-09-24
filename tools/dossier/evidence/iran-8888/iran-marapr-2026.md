# ایران، مارس و آوریل ۲۰۲۶ — جدولِ روزانه

ساخته‌شده با marapr_build.py از دادهٔ خامِ کنارِ این فایل. هیچ سلولی از حدس پر نشده است.

## پایهٔ مقایسه، ۲۰ تا ۲۷ فوریه ۲۰۲۶

```
IODA bgp           mean 41375
IODA ping-slash24  mean 11939
IODA merit-nt      mean 58.7
IODA gtr search    mean 3.055e+09
OONI uploads/day   mean 23121
Atlas IR connected mean 80.4
```

## قاعدهٔ حکم

```
قطع سراسری : NO outbound signal from any IR-registered ASN that day
             (0 OONI uploads, 0 Atlas probes connected, 0 answers from 8.8.8.8) AND ping-/24 < 10%
نیمه‌قطع    : outbound signal exists from some IR-registered ASN while ping-/24 < 80%
نامشخص      : IODA or the ASN recheck missing for that day
ASN filter  : only ASNs registered to IR (RIPEstat rir-stats-country) count; HK/DE/EE/AE ASNs
             geolocated as IR by OONI/Atlas are reported separately, never as evidence
column 8.8.8.8 : filled ONLY from a direct measurement on an IR-registered ASN
```

## چرا نسخهٔ اولِ این جدول غلط بود

نسخهٔ اول ۴۶ روز را «قطع سراسری» نشان می‌داد. دو خطا باعثش شد:

- قاعدهٔ حکم فقط به سیگنال‌های ورودیِ IODA نگاه می‌کرد، یعنی پینگ از بیرون، تلسکوپ و جست‌وجوی گوگل. این سیگنال‌ها ترافیکِ خروجیِ شبکه‌های سفید را نمی‌بینند.
- بخشی از ردیف‌هایی که «ایران» برچسب خورده بودند روی شبکه‌های خارجی بودند. بزرگ‌ترینشان AS142578 از هنگ‌کنگ بود، که ۱٬۴۹۸ ردیف از دادهٔ dns.google را داشت.

وقتی خطاها برطرف شدند، از شبکه‌های ثبت‌شده در ایران در همهٔ روزها ترافیکِ خروجی دیده شد. پس هیچ روزی در مارس و آوریل «قطع سراسری» به معنای دقیق نبود. کاربرِ عادی قطع بود و شبکه‌های ممتاز باز بودند.

یادداشتِ بازه‌ای: Cloudflare Q1 2026 summary — Feb 28 07:00 UTC traffic "well under 1%"; residual IP + DNS traffic Feb 28 - Apr 28 "supports reports that the shutdown was effectively achieved through aggressive filtering, with so-called 'whitelists' and 'white SIM cards'"

## جدول

| تاریخ | منبع | چه دیده شد | حکم همان روز | 8.8.8.8 |
|---|---|---|---|---|
| 2026-03-01 | IODA | BGP 98% / ping-/24 3.3% (max 415 vs ~11939) / telescope 1% / Google search 4% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-01 | OONI | 1852 uploads, all tests (8% of Feb 20-27): IR-registered ASNs 136, foreign ASNs geolocated IR 1716; top IR: AS52140 UNHCR=134, AS31549 Shatel=2 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-01 | RIPE Atlas | IR probes connected on IR-registered ASNs: 0 (~80 before); all 'IR' probes incl. foreign ASNs: 1 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-02 | IODA | BGP 99% / ping-/24 3.3% (max 415 vs ~11939) / telescope 1% / Google search 4% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-02 | OONI | 2806 uploads, all tests (12% of Feb 20-27): IR-registered ASNs 300, foreign ASNs geolocated IR 2506; top IR: AS31549 Shatel=166, AS52140 UNHCR=132, AS24631 FanAp=2 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-02 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-02 | Kentik blog (snippet) | traffic "less than 1% of normal ... drops on March 2, March 5, and March 15" | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-03 | IODA | BGP 99% / ping-/24 3.2% (max 404 vs ~11939) / telescope 1% / Google search 3% | نیمه‌قطع | نامشخص |
| 2026-03-03 | OONI | 2351 uploads, all tests (10% of Feb 20-27): IR-registered ASNs 105, foreign ASNs geolocated IR 2246; top IR: AS31549 Shatel=105 | نیمه‌قطع | نامشخص |
| 2026-03-03 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 8 | نیمه‌قطع | نامشخص |
| 2026-03-04 | IODA | BGP 99% / ping-/24 3.2% (max 398 vs ~11939) / telescope 0% / Google search 4% | نیمه‌قطع | OONI DoH 8.8.8.8 AS44244 Irancell: answered x2 |
| 2026-03-04 | OONI | 2565 uploads, all tests (11% of Feb 20-27): IR-registered ASNs 37, foreign ASNs geolocated IR 2528; top IR: AS44244 Irancell=32, AS31549 Shatel=5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS44244 Irancell: answered x2 |
| 2026-03-04 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS44244 Irancell: answered x2 |
| 2026-03-05 | IODA | BGP 99% / ping-/24 3.3% (max 406 vs ~11939) / telescope 1% / Google search 4% | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: timeout x2 |
| 2026-03-05 | OONI | 1148 uploads, all tests (5% of Feb 20-27): IR-registered ASNs 144, foreign ASNs geolocated IR 1004; top IR: AS52140 UNHCR=108, AS24631 FanAp=26, AS197207 MCI=10 | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: timeout x2 |
| 2026-03-05 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: timeout x2 |
| 2026-03-05 | Kentik blog (snippet) | drop named on March 5 (same sentence) | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: timeout x2 |
| 2026-03-06 | IODA | BGP 98% / ping-/24 3.2% (max 401 vs ~11939) / telescope 1% / Google search 4% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-06 | OONI | 3585 uploads, all tests (16% of Feb 20-27): IR-registered ASNs 494, foreign ASNs geolocated IR 3091; top IR: AS44244 Irancell=251, AS52140 UNHCR=134, AS31549 Shatel=109 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-06 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-07 | IODA | BGP 98% / ping-/24 3.2% (max 401 vs ~11939) / telescope 1% / Google search 4% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-07 | OONI | 2209 uploads, all tests (10% of Feb 20-27): IR-registered ASNs 134, foreign ASNs geolocated IR 2075; top IR: AS52140 UNHCR=134 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-07 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-08 | IODA | BGP 98% / ping-/24 3.2% (max 398 vs ~11939) / telescope 1% / Google search 4% | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x8; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-08 | OONI | 2919 uploads, all tests (13% of Feb 20-27): IR-registered ASNs 1183, foreign ASNs geolocated IR 1736; top IR: AS47262 Hamara=1049, AS52140 UNHCR=134 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x8; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-08 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 8 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x8; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-09 | IODA | BGP 98% / ping-/24 3.2% (max 401 vs ~11939) / telescope 1% / Google search 4% | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x32 |
| 2026-03-09 | OONI | 2792 uploads, all tests (12% of Feb 20-27): IR-registered ASNs 1848, foreign ASNs geolocated IR 944; top IR: AS47262 Hamara=1845, AS206065=3 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x32 |
| 2026-03-09 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 8 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x32 |
| 2026-03-10 | IODA | BGP 98% / ping-/24 3.2% (max 399 vs ~11939) / telescope 1% / Google search 4% | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x34; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-10 | OONI | 2119 uploads, all tests (9% of Feb 20-27): IR-registered ASNs 2119, foreign ASNs geolocated IR 0; top IR: AS47262 Hamara=1985, AS52140 UNHCR=134 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x34; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-10 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x34; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-11 | IODA | BGP 98% / ping-/24 3.2% (max 400 vs ~11939) / telescope 1% / Google search 3% | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x8; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-11 | OONI | 1481 uploads, all tests (6% of Feb 20-27): IR-registered ASNs 1345, foreign ASNs geolocated IR 136; top IR: AS47262 Hamara=1101, AS31549 Shatel=110, AS24631 FanAp=100, AS52140 UNHCR=34 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x8; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-11 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x8; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-12 | IODA | BGP 98% / ping-/24 3.2% (max 593 vs ~11939) / telescope 1% / Google search 2% | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x34; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2; OONI DoH 8.8.8.8 AS58224 TCI: timeout x2 |
| 2026-03-12 | OONI | 3399 uploads, all tests (15% of Feb 20-27): IR-registered ASNs 2203, foreign ASNs geolocated IR 1196; top IR: AS47262 Hamara=2045, AS52140 UNHCR=134, AS58224 TCI=24 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x34; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2; OONI DoH 8.8.8.8 AS58224 TCI: timeout x2 |
| 2026-03-12 | RIPE Atlas | IR probes connected on IR-registered ASNs: 6 (~80 before) — AS12880 DCI=3, AS6736 IPM=2, AS58303=1; all 'IR' probes incl. foreign ASNs: 8 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x34; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2; OONI DoH 8.8.8.8 AS58224 TCI: timeout x2 |
| 2026-03-12 | IODA Mastodon 116222156726557661 | "briefly recovered on March 12 6:35 PM - 6:55 PM local time ... AS58224 ... 32.9% of the population" | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x34; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2; OONI DoH 8.8.8.8 AS58224 TCI: timeout x2 |
| 2026-03-13 | IODA | BGP 98% / ping-/24 3.2% (max 395 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x22; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-13 | OONI | 2808 uploads, all tests (12% of Feb 20-27): IR-registered ASNs 1314, foreign ASNs geolocated IR 1494; top IR: AS47262 Hamara=1071, AS31549 Shatel=109, AS24631 FanAp=100, AS52140 UNHCR=34 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x22; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-13 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x22; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-13 | Filterwatch 2026-03-17 | "Since March 13, 2026 ... target even the 'white SIM cards'" | نیمه‌قطع | OONI DoH 8.8.8.8 AS47262 Hamara: timeout x22; OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-14 | IODA | BGP 98% / ping-/24 3.2% (max 498 vs ~11939) / telescope 1% / Google search 2% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-14 | OONI | 2989 uploads, all tests (13% of Feb 20-27): IR-registered ASNs 137, foreign ASNs geolocated IR 2852; top IR: AS52140 UNHCR=134, AS58224 TCI=3 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-14 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: timeout x2 |
| 2026-03-15 | IODA | BGP 99% / ping-/24 3.3% (max 428 vs ~11939) / telescope 1% / Google search 2% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS47262 Hamara: timeout x2 |
| 2026-03-15 | OONI | 2449 uploads, all tests (11% of Feb 20-27): IR-registered ASNs 275, foreign ASNs geolocated IR 2174; top IR: AS47262 Hamara=141, AS52140 UNHCR=130, AS24631 FanAp=4 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS47262 Hamara: timeout x2 |
| 2026-03-15 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=2; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS47262 Hamara: timeout x2 |
| 2026-03-15 | Filterwatch 2026-03-17 | "new large-scale disruption ... 12:00 UTC on March 15" | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS47262 Hamara: timeout x2 |
| 2026-03-15 | Kentik blog (snippet) | drop named on March 15 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS47262 Hamara: timeout x2 |
| 2026-03-16 | IODA | BGP 99% / ping-/24 3.1% (max 372 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x1 |
| 2026-03-16 | OONI | 952 uploads, all tests (4% of Feb 20-27): IR-registered ASNs 217, foreign ASNs geolocated IR 735; top IR: AS31549 Shatel=215, AS52140 UNHCR=2 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x1 |
| 2026-03-16 | RIPE Atlas | IR probes connected on IR-registered ASNs: 0 (~80 before); all 'IR' probes incl. foreign ASNs: 1 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x1 |
| 2026-03-17 | IODA | BGP 98% / ping-/24 3.0% (max 374 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | نامشخص |
| 2026-03-17 | OONI | 714 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 444, foreign ASNs geolocated IR 270; top IR: AS31549 Shatel=444 | نیمه‌قطع | نامشخص |
| 2026-03-17 | RIPE Atlas | IR probes connected on IR-registered ASNs: 0 (~80 before); all 'IR' probes incl. foreign ASNs: 1 | نیمه‌قطع | نامشخص |
| 2026-03-18 | IODA | BGP 96% / ping-/24 3.1% (max 818 vs ~11939) / telescope 2% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS39308 AndisheSabz: answered x2 |
| 2026-03-18 | OONI | 965 uploads, all tests (4% of Feb 20-27): IR-registered ASNs 566, foreign ASNs geolocated IR 399; top IR: AS31549 Shatel=406, AS39308 AndisheSabz=132, AS58224 TCI=28 | نیمه‌قطع | OONI DoH 8.8.8.8 AS39308 AndisheSabz: answered x2 |
| 2026-03-18 | RIPE Atlas | IR probes connected on IR-registered ASNs: 6 (~80 before) — AS58224 TCI=3, AS12880 DCI=3; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS39308 AndisheSabz: answered x2 |
| 2026-03-18 | arXiv 2605.00187 (Censys data) | "18 March, approximately 3,700 genuinely active hosts" | نیمه‌قطع | OONI DoH 8.8.8.8 AS39308 AndisheSabz: answered x2 |
| 2026-03-19 | IODA | BGP 98% / ping-/24 3.5% (max 447 vs ~11939) / telescope 2% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-19 | OONI | 252 uploads, all tests (1% of Feb 20-27): IR-registered ASNs 252, foreign ASNs geolocated IR 0; top IR: AS52140 UNHCR=134, AS31549 Shatel=118 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-19 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS6736 IPM=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-20 | IODA | BGP 99% / ping-/24 3.2% (max 388 vs ~11939) / telescope 1% / Google search 2% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-20 | OONI | 417 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 311, foreign ASNs geolocated IR 106; top IR: AS31549 Shatel=177, AS52140 UNHCR=134 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-20 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS6736 IPM=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-21 | IODA | BGP 99% / ping-/24 3.2% (max 396 vs ~11939) / telescope 2% / Google search 2% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-21 | OONI | 260 uploads, all tests (1% of Feb 20-27): IR-registered ASNs 233, foreign ASNs geolocated IR 27; top IR: AS52140 UNHCR=130, AS31549 Shatel=99, AS24631 FanAp=4 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-21 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS6736 IPM=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-22 | IODA | BGP 99% / ping-/24 3.3% (max 408 vs ~11939) / telescope 1% / Google search 2% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-22 | OONI | 1171 uploads, all tests (5% of Feb 20-27): IR-registered ASNs 243, foreign ASNs geolocated IR 928; top IR: AS52140 UNHCR=134, AS197207 MCI=108, AS31549 Shatel=1 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-22 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS6736 IPM=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-23 | IODA | BGP 99% / ping-/24 3.4% (max 425 vs ~11939) / telescope 1% / Google search 2% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-23 | OONI | 1154 uploads, all tests (5% of Feb 20-27): IR-registered ASNs 1119, foreign ASNs geolocated IR 35; top IR: AS31549 Shatel=872, AS52140 UNHCR=134, AS197207 MCI=108, AS42337=5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-23 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS6736 IPM=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-24 | IODA | BGP 99% / ping-/24 3.6% (max 442 vs ~11939) / telescope 1% / Google search 2% | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: answered x2 |
| 2026-03-24 | OONI | 926 uploads, all tests (4% of Feb 20-27): IR-registered ASNs 550, foreign ASNs geolocated IR 376; top IR: AS31549 Shatel=218, AS44244 Irancell=198, AS52140 UNHCR=108, AS24631 FanAp=26 | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: answered x2 |
| 2026-03-24 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS6736 IPM=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: answered x2 |
| 2026-03-25 | IODA | BGP 99% / ping-/24 3.7% (max 454 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS31549 Shatel: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-25 | OONI | 594 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 594, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=460, AS52140 UNHCR=132, AS24631 FanAp=2 | نیمه‌قطع | OONI DoH 8.8.8.8 AS31549 Shatel: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-25 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS31549 Shatel: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-26 | IODA | BGP 98% / ping-/24 3.5% (max 459 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-26 | OONI | 247 uploads, all tests (1% of Feb 20-27): IR-registered ASNs 247, foreign ASNs geolocated IR 0; top IR: AS52140 UNHCR=134, AS31549 Shatel=109, AS197207 MCI=4 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-26 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-27 | IODA | BGP 99% / ping-/24 3.3% (max 411 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-27 | OONI | 714 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 714, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=339, AS197207 MCI=204, AS52140 UNHCR=134, AS44244 Irancell=37 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-27 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-28 | IODA | BGP 99% / ping-/24 3.3% (max 412 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-28 | OONI | 353 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 353, foreign ASNs geolocated IR 0; top IR: AS197207 MCI=219, AS52140 UNHCR=134 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-28 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-29 | IODA | BGP 99% / ping-/24 3.3% (max 407 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-29 | OONI | 239 uploads, all tests (1% of Feb 20-27): IR-registered ASNs 239, foreign ASNs geolocated IR 0; top IR: AS52140 UNHCR=134, AS197207 MCI=105 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-29 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-30 | IODA | BGP 98% / ping-/24 3.3% (max 416 vs ~11939) / telescope 2% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-30 | OONI | 660 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 660, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=311, AS197207 MCI=215, AS52140 UNHCR=134 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-30 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-03-31 | IODA | BGP 98% / ping-/24 3.4% (max 410 vs ~11939) / telescope 2% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x2 |
| 2026-03-31 | OONI | 166 uploads, all tests (1% of Feb 20-27): IR-registered ASNs 166, foreign ASNs geolocated IR 0; top IR: AS24631 FanAp=100, AS52140 UNHCR=34, AS39308 AndisheSabz=16, AS197207 MCI=11 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x2 |
| 2026-03-31 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x2 |
| 2026-04-01 | IODA | BGP 98% / ping-/24 3.4% (max 411 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-01 | OONI | 226 uploads, all tests (1% of Feb 20-27): IR-registered ASNs 226, foreign ASNs geolocated IR 0; top IR: AS52140 UNHCR=134, AS31549 Shatel=85, AS39308 AndisheSabz=7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-01 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-01 | arXiv 2605.00187 (Censys data) | "floor of approximately 10-11K hosts, about 1%" (Apr 1-6) | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-02 | IODA | BGP 98% / ping-/24 3.3% (max 409 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-02 | OONI | 724 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 724, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=543, AS52140 UNHCR=134, AS51074 Mabna=47 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-02 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS6736 IPM=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-03 | IODA | BGP 98% / ping-/24 3.3% (max 408 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x2 |
| 2026-04-03 | OONI | 744 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 477, foreign ASNs geolocated IR 267; top IR: AS31549 Shatel=202, AS52140 UNHCR=134, AS197207 MCI=108, AS39308 AndisheSabz=33 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x2 |
| 2026-04-03 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x2 |
| 2026-04-04 | IODA | BGP 98% / ping-/24 3.3% (max 409 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-04 | OONI | 461 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 461, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=327, AS52140 UNHCR=134 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-04 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-05 | IODA | BGP 98% / ping-/24 3.4% (max 418 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-05 | OONI | 750 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 750, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=239, AS197207 MCI=175, AS52140 UNHCR=134, AS51074 Mabna=104 | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-05 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-06 | IODA | BGP 98% / ping-/24 3.4% (max 419 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-06 | OONI | 636 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 636, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=371, AS52140 UNHCR=134, AS39308 AndisheSabz=91, AS197207 MCI=40 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-06 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-07 | IODA | BGP 98% / ping-/24 3.5% (max 428 vs ~11939) / telescope 2% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x2 |
| 2026-04-07 | OONI | 533 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 533, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=242, AS197207 MCI=118, AS24631 FanAp=102, AS39308 AndisheSabz=39 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x2 |
| 2026-04-07 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x2 |
| 2026-04-08 | IODA | BGP 98% / ping-/24 3.4% (max 433 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | نامشخص |
| 2026-04-08 | OONI | 143 uploads, all tests (1% of Feb 20-27): IR-registered ASNs 143, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=141, AS39308 AndisheSabz=2 | نیمه‌قطع | نامشخص |
| 2026-04-08 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | نامشخص |
| 2026-04-09 | IODA | BGP 98% / ping-/24 3.5% (max 433 vs ~11939) / telescope 0% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x4 |
| 2026-04-09 | OONI | 1286 uploads, all tests (6% of Feb 20-27): IR-registered ASNs 1286, foreign ASNs geolocated IR 0; top IR: AS44244 Irancell=360, AS197207 MCI=338, AS39308 AndisheSabz=276, AS52140 UNHCR=134 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x4 |
| 2026-04-09 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS39308 AndisheSabz: timeout x4 |
| 2026-04-10 | IODA | BGP 98% / ping-/24 3.6% (max 435 vs ~11939) / telescope 0% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: answered x2; OONI DoH 8.8.8.8 AS51074 Mabna: answered x2 |
| 2026-04-10 | OONI | 908 uploads, all tests (4% of Feb 20-27): IR-registered ASNs 908, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=493, AS51074 Mabna=164, AS197207 MCI=117, AS52140 UNHCR=108 | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: answered x2; OONI DoH 8.8.8.8 AS51074 Mabna: answered x2 |
| 2026-04-10 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: answered x2; OONI DoH 8.8.8.8 AS51074 Mabna: answered x2 |
| 2026-04-11 | IODA | BGP 98% / ping-/24 3.6% (max 448 vs ~11939) / telescope 2% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-11 | OONI | 478 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 478, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=223, AS52140 UNHCR=132, AS197207 MCI=117, AS58224 TCI=4 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-11 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-12 | IODA | BGP 98% / ping-/24 3.6% (max 445 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x4; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-12 | OONI | 713 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 713, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=210, AS5627=196, AS52140 UNHCR=134, AS197207 MCI=100 | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x4; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-12 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x4; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-12 | Digiato | whitelist SIM for business staff, 50 GB, 2 million toman (Apr 12-13) | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x4; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-13 | IODA | BGP 98% / ping-/24 3.7% (max 455 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-13 | OONI | 424 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 424, foreign ASNs geolocated IR 0; top IR: AS51074 Mabna=143, AS52140 UNHCR=132, AS197207 MCI=111, AS49666 TIC-GW=23 | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-13 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-14 | IODA | BGP 98% / ping-/24 3.6% (max 449 vs ~11939) / telescope 1% / Google search 1% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-14 | OONI | 870 uploads, all tests (4% of Feb 20-27): IR-registered ASNs 870, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=516, AS49666 TIC-GW=216, AS52140 UNHCR=134, AS197207 MCI=4 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-14 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-14 | IODA + Ainita report | "Access to the global Internet is still largely shutdown ... ~3%"; "Internet Pro" unveiled Apr 14 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-15 | IODA | BGP 99% / ping-/24 3.7% (max 463 vs ~11939) / telescope 2% / Google search 2% | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: answered x2 |
| 2026-04-15 | OONI | 1641 uploads, all tests (7% of Feb 20-27): IR-registered ASNs 727, foreign ASNs geolocated IR 914; top IR: AS197207 MCI=323, AS52140 UNHCR=108, AS31549 Shatel=105, AS5627=98 | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: answered x2 |
| 2026-04-15 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS24631 FanAp: answered x2 |
| 2026-04-16 | IODA | BGP 99% / ping-/24 3.7% (max 462 vs ~11939) / telescope 6% / Google search 60% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-16 | OONI | 1469 uploads, all tests (6% of Feb 20-27): IR-registered ASNs 396, foreign ASNs geolocated IR 1073; top IR: AS197207 MCI=211, AS52140 UNHCR=134, AS31549 Shatel=41, AS49666 TIC-GW=8 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-16 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-17 | IODA | BGP 99% / ping-/24 3.7% (max 457 vs ~11939) / telescope 1% / Google search 80% | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: answered x2; OONI DoH 8.8.8.8 AS51074 Mabna: answered x13; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-17 | OONI | 2506 uploads, all tests (11% of Feb 20-27): IR-registered ASNs 1090, foreign ASNs geolocated IR 1416; top IR: AS51074 Mabna=757, AS49666 TIC-GW=139, AS197207 MCI=108, AS31549 Shatel=58 | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: answered x2; OONI DoH 8.8.8.8 AS51074 Mabna: answered x13; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-17 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: answered x2; OONI DoH 8.8.8.8 AS51074 Mabna: answered x13; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-18 | IODA | BGP 99% / ping-/24 3.7% (max 467 vs ~11939) / telescope 2% / Google search 93% | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: answered x4; OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-18 | OONI | 811 uploads, all tests (4% of Feb 20-27): IR-registered ASNs 811, foreign ASNs geolocated IR 0; top IR: AS49666 TIC-GW=506, AS31549 Shatel=208, AS52140 UNHCR=34, AS51074 Mabna=33 | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: answered x4; OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-18 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: answered x4; OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-19 | IODA | BGP 99% / ping-/24 3.8% (max 461 vs ~11939) / telescope 2% / Google search 91% | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-19 | OONI | 443 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 443, foreign ASNs geolocated IR 0; top IR: AS31549 Shatel=143, AS52140 UNHCR=134, AS197207 MCI=108, AS51074 Mabna=31 | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-19 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-20 | IODA | BGP 99% / ping-/24 3.8% (max 467 vs ~11939) / telescope 2% / Google search 85% | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-20 | OONI | 777 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 777, foreign ASNs geolocated IR 0; top IR: AS197207 MCI=319, AS51074 Mabna=134, AS52140 UNHCR=130, AS49666 TIC-GW=104 | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-20 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS51074 Mabna: answered x2; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-21 | IODA | BGP 99% / ping-/24 3.8% (max 475 vs ~11939) / telescope 2% / Google search 82% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS51074 Mabna: timeout x2 |
| 2026-04-21 | OONI | 562 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 529, foreign ASNs geolocated IR 33; top IR: AS197207 MCI=215, AS52140 UNHCR=130, AS42337=107, AS31549 Shatel=32 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS51074 Mabna: timeout x2 |
| 2026-04-21 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS51074 Mabna: timeout x2 |
| 2026-04-22 | IODA | BGP 98% / ping-/24 3.8% (max 468 vs ~11939) / telescope 2% / Google search 82% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-22 | OONI | 327 uploads, all tests (1% of Feb 20-27): IR-registered ASNs 189, foreign ASNs geolocated IR 138; top IR: AS49666 TIC-GW=123, AS31549 Shatel=34, AS52140 UNHCR=32 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-22 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-23 | IODA | BGP 98% / ping-/24 3.8% (max 467 vs ~11939) / telescope 1% / Google search 75% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-23 | OONI | 2431 uploads, all tests (11% of Feb 20-27): IR-registered ASNs 672, foreign ASNs geolocated IR 1759; top IR: AS49666 TIC-GW=286, AS197207 MCI=227, AS52140 UNHCR=134, AS31549 Shatel=19 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-23 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-24 | IODA | BGP 98% / ping-/24 3.7% (max 464 vs ~11939) / telescope 2% / Google search 75% | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: answered x4; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-24 | OONI | 990 uploads, all tests (4% of Feb 20-27): IR-registered ASNs 689, foreign ASNs geolocated IR 301; top IR: AS31549 Shatel=290, AS49666 TIC-GW=154, AS52140 UNHCR=128, AS197207 MCI=109 | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: answered x4; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-24 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: answered x4; OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-25 | IODA | BGP 99% / ping-/24 3.8% (max 466 vs ~11939) / telescope 3% / Google search 97% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-25 | OONI | 539 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 409, foreign ASNs geolocated IR 130; top IR: AS52140 UNHCR=130, AS49666 TIC-GW=111, AS197207 MCI=108, AS31549 Shatel=56 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-25 | RIPE Atlas | IR probes connected on IR-registered ASNs: 4 (~80 before) — AS12880 DCI=3, AS58303=1; all 'IR' probes incl. foreign ASNs: 5 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-26 | IODA | BGP 99% / ping-/24 3.8% (max 472 vs ~11939) / telescope 2% / Google search 97% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-26 | OONI | 1362 uploads, all tests (6% of Feb 20-27): IR-registered ASNs 611, foreign ASNs geolocated IR 751; top IR: AS49666 TIC-GW=308, AS197207 MCI=132, AS31549 Shatel=93, AS52140 UNHCR=72 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-26 | RIPE Atlas | IR probes connected on IR-registered ASNs: 6 (~80 before) — AS12880 DCI=3, AS9147 ?=1, AS39074 ?=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-27 | IODA | BGP 99% / ping-/24 3.8% (max 473 vs ~11939) / telescope 3% / Google search 90% | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-27 | OONI | 777 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 642, foreign ASNs geolocated IR 135; top IR: AS49666 TIC-GW=359, AS31549 Shatel=141, AS59441=115, AS44244 Irancell=10 | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-27 | RIPE Atlas | IR probes connected on IR-registered ASNs: 6 (~80 before) — AS12880 DCI=3, AS9147 ?=1, AS39074 ?=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 7 | نیمه‌قطع | OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-28 | IODA | BGP 99% / ping-/24 3.8% (max 476 vs ~11939) / telescope 2% / Google search 78% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x1 |
| 2026-04-28 | OONI | 807 uploads, all tests (3% of Feb 20-27): IR-registered ASNs 805, foreign ASNs geolocated IR 2; top IR: AS49666 TIC-GW=240, AS197207 MCI=223, AS52140 UNHCR=133, AS42337=105 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x1 |
| 2026-04-28 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS9147 ?=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x1 |
| 2026-04-29 | IODA | BGP 99% / ping-/24 3.8% (max 471 vs ~11939) / telescope 2% / Google search 51% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-29 | OONI | 428 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 428, foreign ASNs geolocated IR 0; top IR: AS197207 MCI=106, AS24631 FanAp=100, AS49666 TIC-GW=95, AS31549 Shatel=83 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-29 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS9147 ?=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2; OONI DoH 8.8.8.8 AS49666 TIC-GW: timeout x2 |
| 2026-04-30 | IODA | BGP 99% / ping-/24 3.8% (max 472 vs ~11939) / telescope 1% / Google search 40% | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-30 | OONI | 453 uploads, all tests (2% of Feb 20-27): IR-registered ASNs 453, foreign ASNs geolocated IR 0; top IR: AS197207 MCI=176, AS31549 Shatel=123, AS49666 TIC-GW=107, AS52140 UNHCR=32 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |
| 2026-04-30 | RIPE Atlas | IR probes connected on IR-registered ASNs: 5 (~80 before) — AS12880 DCI=3, AS9147 ?=1, AS58303=1; all 'IR' probes incl. foreign ASNs: 6 | نیمه‌قطع | OONI DoH 8.8.8.8 AS52140 UNHCR: answered x2 |

## جمعِ حکم‌ها

```
نیمه‌قطع: 61 days
days 8.8.8.8 ANSWERED on an IR-registered ASN (OONI DoH): 46 of 61
days with no such answer: 2026-03-02, 2026-03-03, 2026-03-05, 2026-03-06, 2026-03-07, 2026-03-08, 2026-03-09, 2026-03-10, 2026-03-11, 2026-03-12, 2026-03-13, 2026-03-14, 2026-03-17, 2026-04-08, 2026-04-27
min IR-ASN OONI uploads on any day: 37
sources: OONI google file=yes, Atlas 8.8.8.8 file=MISSING
```
