```
OONI upload received abroad <=1h after run | 2026-03-05, 2026-03-22, 2026-03-23, 2026-03-26 (+28) | AS197207 MCI | HTTPS TCP/443
OONI upload received abroad <=1h after run | 2026-03-04, 2026-03-06, 2026-03-24, 2026-03-27 (+6) | AS44244 Irancell | HTTPS TCP/443
OONI DoH -> Cloudflare IP | 2026-03-04 | AS44244 Irancell | DoH TCP/443
```

# ایران، مارس و آوریل ۲۰۲۶ — مسیرهای باز به تفکیکِ لایه

ساخته‌شده با marapr_layers.py. فقط ASNهای ثبت‌شده در ایران شاهد حساب شده‌اند. گیت‌وی ملی (TIC، DCI) در لایهٔ ممتاز است، نه مصرف‌کننده.

## لایهٔ ۱ — مصرف‌کننده

| ASN | holder | path | status | success | fail | dates (success, else fail) | examples |
|---|---|---|---|---|---|---|---|
| AS197207 | MCI | Atlas UDP/53 -> 8.8.8.8 (no probe on this ASN in any of the scanned Atlas measurements) | نامشخص — پروب نبود | 0 | 0 | - |  |
| AS197207 | MCI | Atlas UDP/53 -> 1.1.1.1 (not collected) | نامشخص — پروب نبود | 0 | 0 | - |  |
| AS197207 | MCI | OONI DoH -> 8.8.8.8/8.8.4.4 | نامشخص | 0 | 0 | - |  |
| AS197207 | MCI | OONI DoH -> Cloudflare IP | نامشخص | 0 | 0 | - |  |
| AS197207 | MCI | operator resolver: dns.google | نامشخص | 0 | 0 | - |  |
| AS197207 | MCI | operator resolver: cloudflare-dns.com | نامشخص | 0 | 0 | - |  |
| AS197207 | MCI | operator resolver: foreign names (web_connectivity) | هر دو دیده شد | 42 | 18 | 2026-04-23, 2026-04-24, 2026-04-25, 2026-04-26, 2026-04-28, 2026-04-29, 2026-04-30 | 20260430142717.397061_IR_webconnectivity_b7b93c292e9492f2; 20260430142418.289716_IR_webconnectivity_b925dd88aad670fe; 20260430142326.237757_IR_webconnectivity_aead03ec04a8ba99 |
| AS197207 | MCI | OONI upload received abroad <=1h after run | باز | 32 | 0 | 2026-03-05, 2026-03-22, 2026-03-23, 2026-03-26, 2026-03-27, 2026-03-28, 2026-03-29, 2026-03-30 (+24) | 20260430191157.838530_IR_httpinvalidrequestline_6326d524fddf2ba2; 20260429112535.184168_IR_httpinvalidrequestline_049f83c6aab40bd9; 20260428212246.912589_IR_httpheaderfieldmanipulation_409fcd5328e438c6 |
| AS197207 | MCI | Atlas probe session to RIPE controller (TCP) | نامشخص | 0 | 0 | - |  |
| AS44244 | Irancell | Atlas UDP/53 -> 8.8.8.8 (no probe on this ASN in any of the scanned Atlas measurements) | نامشخص — پروب نبود | 0 | 0 | - |  |
| AS44244 | Irancell | Atlas UDP/53 -> 1.1.1.1 (not collected) | نامشخص — پروب نبود | 0 | 0 | - |  |
| AS44244 | Irancell | OONI DoH -> 8.8.8.8/8.8.4.4 | باز | 4 | 0 | 2026-03-04 | 20260304132201.591273_IR_dnscheck_b45e358c8cc9ab92; 20260304132201.591273_IR_dnscheck_b45e358c8cc9ab92; 20260304132159.911734_IR_dnscheck_3eabde803166ca67 |
| AS44244 | Irancell | OONI DoH -> Cloudflare IP | باز | 8 | 0 | 2026-03-04 | 20260304132205.098961_IR_dnscheck_ac7ea90876380746; 20260304132205.098961_IR_dnscheck_ac7ea90876380746; 20260304132205.098961_IR_dnscheck_ac7ea90876380746 |
| AS44244 | Irancell | operator resolver: dns.google | جوابِ درست | 2 | 0 | 2026-03-04 | 20260304132201.591273_IR_dnscheck_b45e358c8cc9ab92; 20260304132159.911734_IR_dnscheck_3eabde803166ca67 |
| AS44244 | Irancell | operator resolver: cloudflare-dns.com | جوابِ درست | 2 | 0 | 2026-03-04 | 20260304132205.098961_IR_dnscheck_ac7ea90876380746; 20260304132202.802354_IR_dnscheck_d72a3c8135ebe231 |
| AS44244 | Irancell | operator resolver: foreign names (web_connectivity) | هر دو دیده شد | 40 | 20 | 2026-03-06, 2026-03-24, 2026-03-27, 2026-04-09 | 20260427083612.154406_IR_webconnectivity_ba091bf19384d67a; 20260420040003.601059_IR_webconnectivity_5a2565f57e2dbe49; 20260409041835.453626_IR_webconnectivity_45b0abd8810307f6 |
| AS44244 | Irancell | OONI upload received abroad <=1h after run | باز | 10 | 0 | 2026-03-04, 2026-03-06, 2026-03-24, 2026-03-27, 2026-04-09, 2026-04-20, 2026-04-23, 2026-04-24 (+2) | 20260430121726.341546_IR_stunreachability_14d44609214a3a71; 20260427083612.154406_IR_webconnectivity_ba091bf19384d67a; 20260424211610.190375_IR_httpheaderfieldmanipulation_c54c541d0330bd1d |
| AS44244 | Irancell | Atlas probe session to RIPE controller (TCP) | نامشخص | 0 | 0 | - |  |
| AS58224 | TCI | Atlas UDP/53 -> 8.8.8.8 (no probe on this ASN in any of the scanned Atlas measurements) | نامشخص — پروب نبود | 0 | 0 | - |  |
| AS58224 | TCI | Atlas UDP/53 -> 1.1.1.1 (not collected) | نامشخص — پروب نبود | 0 | 0 | - |  |
| AS58224 | TCI | OONI DoH -> 8.8.8.8/8.8.4.4 | باز | 2 | 2 | 2026-03-12 | 20260312151140.961468_IR_dnscheck_c8a66ddb9e262540; 20260312151043.890018_IR_dnscheck_ecf017d8fc319fd1 |
| AS58224 | TCI | OONI DoH -> Cloudflare IP | بسته | 0 | 10 | 2026-03-12 | 20260312151215.918115_IR_dnscheck_a7226ff9e8b12a2f; 20260312151215.918115_IR_dnscheck_a7226ff9e8b12a2f; 20260312151215.918115_IR_dnscheck_a7226ff9e8b12a2f |
| AS58224 | TCI | operator resolver: dns.google | جوابِ درست | 2 | 0 | 2026-03-12 | 20260312151140.961468_IR_dnscheck_c8a66ddb9e262540; 20260312151043.890018_IR_dnscheck_ecf017d8fc319fd1 |
| AS58224 | TCI | operator resolver: cloudflare-dns.com | جوابِ درست | 2 | 0 | 2026-03-12 | 20260312151215.918115_IR_dnscheck_a7226ff9e8b12a2f; 20260312151157.029052_IR_dnscheck_672e91ffbd80176d |
| AS58224 | TCI | operator resolver: foreign names (web_connectivity) | هر دو دیده شد | 2 | 1 | 2026-03-18, 2026-04-21 | 20260421091048.863126_IR_webconnectivity_1161fc48ee2e3937; 20260421090955.801676_IR_webconnectivity_a4685383c5cf1c99; 20260318195150.349458_IR_webconnectivity_2da048198b57b942 |
| AS58224 | TCI | OONI upload received abroad <=1h after run | باز | 5 | 0 | 2026-03-12, 2026-03-14, 2026-03-18, 2026-04-11, 2026-04-21 | 20260421091048.863126_IR_webconnectivity_1161fc48ee2e3937; 20260411151439.977999_IR_signal_d5a4f912d4b5cff0; 20260318195306.068291_IR_httpinvalidrequestline_3505b391188a03ea |
| AS58224 | TCI | Atlas probe session to RIPE controller (TCP) | باز | 3 | 0 | 2026-03-18 | probe 24845; probe 33714; probe 1008623 |

## لایهٔ ۲ — ممتاز: UNHCR، دیتاسنتر، گیت‌وی، دانشگاهی

| ASN | holder | path | status | success | fail | dates (success, else fail) | examples |
|---|---|---|---|---|---|---|---|
| AS12880 | DCI (state IT / gateway) | Atlas UDP/53 -> 8.8.8.8 | باز | 495 | 4 | 2026-03-01, 2026-03-02, 2026-03-03, 2026-03-04, 2026-03-05, 2026-03-06, 2026-03-07, 2026-03-08 (+49) | probe 1006478; probe 1006479; probe 1006480 |
| AS12880 | DCI (state IT / gateway) | Atlas probe session to RIPE controller (TCP) | باز | 174 | 0 | 2026-03-02, 2026-03-03, 2026-03-04, 2026-03-05, 2026-03-06, 2026-03-07, 2026-03-08, 2026-03-09 (+50) | probe 1006478; probe 1006479; probe 1006480 |
| AS49666 | TIC-GW (national gateway) | OONI DoH -> 8.8.8.8/8.8.4.4 | باز | 20 | 18 | 2026-04-17, 2026-04-18, 2026-04-24 | 20260429082450.916269_IR_dnscheck_67195cda405b4376; 20260429082450.916269_IR_dnscheck_67195cda405b4376; 20260429082449.536972_IR_dnscheck_1315722d59fef9a2 |
| AS49666 | TIC-GW (national gateway) | OONI DoH -> Cloudflare IP | باز | 44 | 28 | 2026-04-17, 2026-04-18, 2026-04-19, 2026-04-24, 2026-04-28 | 20260429082457.788877_IR_dnscheck_3a49cef10b38ab19; 20260429082457.788877_IR_dnscheck_3a49cef10b38ab19; 20260429082457.788877_IR_dnscheck_3a49cef10b38ab19 |
| AS49666 | TIC-GW (national gateway) | operator resolver: dns.google | هر دو دیده شد | 12 | 7 | 2026-04-17, 2026-04-18, 2026-04-19, 2026-04-24, 2026-04-29 | 20260428121633.047228_IR_dnscheck_dd4e5dd120e3b799; 20260427145828.038164_IR_dnscheck_a9c571e3c6eaec9d; 20260427145811.798588_IR_dnscheck_2cbe5fbada8197e8 |
| AS49666 | TIC-GW (national gateway) | operator resolver: cloudflare-dns.com (bogon answers seen) | هر دو دیده شد | 15 | 4 | 2026-04-17, 2026-04-18, 2026-04-19, 2026-04-24, 2026-04-28, 2026-04-29 | 20260429082457.788877_IR_dnscheck_3a49cef10b38ab19; 20260429082456.414174_IR_dnscheck_2c1e3f73b0ebcd97; 20260428121647.885812_IR_dnscheck_a6f96f2a4dfde418 |
| AS51074 | Mabna (datacenter) | OONI DoH -> 8.8.8.8/8.8.4.4 | باز | 58 | 4 | 2026-04-05, 2026-04-10, 2026-04-12, 2026-04-13, 2026-04-17, 2026-04-18, 2026-04-19, 2026-04-20 | 20260421093403.758636_IR_dnscheck_4c79212a4c128deb; 20260421093403.758636_IR_dnscheck_4c79212a4c128deb; 20260421093401.616270_IR_dnscheck_ae62ecf72ed6ef7a |
| AS51074 | Mabna (datacenter) | OONI DoH -> Cloudflare IP | باز | 65 | 31 | 2026-04-05, 2026-04-10, 2026-04-12, 2026-04-13, 2026-04-17, 2026-04-18, 2026-04-19, 2026-04-20 (+1) | 20260421093425.555662_IR_dnscheck_c96eaa5a7d517c59; 20260421093425.555662_IR_dnscheck_c96eaa5a7d517c59; 20260421093409.549996_IR_dnscheck_e3fbc7b6cd088f4a |
| AS51074 | Mabna (datacenter) | operator resolver: dns.google | هر دو دیده شد | 17 | 14 | 2026-04-10, 2026-04-12, 2026-04-17, 2026-04-18, 2026-04-20 | 20260421093403.758636_IR_dnscheck_4c79212a4c128deb; 20260421093401.616270_IR_dnscheck_ae62ecf72ed6ef7a; 20260419063730.393352_IR_dnscheck_fc7041fca841af70 |
| AS51074 | Mabna (datacenter) | operator resolver: cloudflare-dns.com (bogon answers seen) | هر دو دیده شد | 17 | 14 | 2026-04-10, 2026-04-12, 2026-04-17, 2026-04-18, 2026-04-20 | 20260421093425.555662_IR_dnscheck_c96eaa5a7d517c59; 20260421093409.549996_IR_dnscheck_e3fbc7b6cd088f4a; 20260420073802.746852_IR_dnscheck_f130b2445dff132d |
| AS52140 | UNHCR | OONI DoH -> 8.8.8.8/8.8.4.4 | باز | 154 | 44 | 2026-03-01, 2026-03-15, 2026-03-16, 2026-03-19, 2026-03-20, 2026-03-21, 2026-03-22, 2026-03-23 (+33) | 20260430023355.913395_IR_dnscheck_18375b9043485bff; 20260430023355.913395_IR_dnscheck_18375b9043485bff; 20260430023343.539111_IR_dnscheck_f6d792a7ab55b7c5 |
| AS52140 | UNHCR | OONI DoH -> Cloudflare IP | باز | 328 | 262 | 2026-03-01, 2026-03-02, 2026-03-15, 2026-03-19, 2026-03-20, 2026-03-21, 2026-03-22, 2026-03-23 (+33) | 20260430023419.240203_IR_dnscheck_02ea076e1ff37b9f; 20260430023419.240203_IR_dnscheck_02ea076e1ff37b9f; 20260430023419.240203_IR_dnscheck_02ea076e1ff37b9f |
| AS52140 | UNHCR | operator resolver: dns.google | جوابِ درست | 99 | 0 | 2026-03-01, 2026-03-02, 2026-03-06, 2026-03-07, 2026-03-08, 2026-03-10, 2026-03-11, 2026-03-12 (+42) | 20260430023355.913395_IR_dnscheck_18375b9043485bff; 20260430023343.539111_IR_dnscheck_f6d792a7ab55b7c5; 20260429011103.057142_IR_dnscheck_78cdf4ee6a3e5d98 |
| AS52140 | UNHCR | operator resolver: cloudflare-dns.com | هر دو دیده شد | 98 | 1 | 2026-03-01, 2026-03-02, 2026-03-06, 2026-03-07, 2026-03-08, 2026-03-10, 2026-03-11, 2026-03-12 (+41) | 20260430023419.240203_IR_dnscheck_02ea076e1ff37b9f; 20260430023409.265644_IR_dnscheck_82795012edb4c5b8; 20260429011104.865124_IR_dnscheck_a74503176681794d |
| AS6736 | IPM (academic) | Atlas UDP/53 -> 8.8.8.8 | باز | 80 | 0 | 2026-03-01, 2026-03-02, 2026-03-03, 2026-03-04, 2026-03-05, 2026-03-06, 2026-03-07, 2026-03-08 (+22) | probe 15535; probe 17437; probe 15535 |
| AS6736 | IPM (academic) | Atlas probe session to RIPE controller (TCP) | باز | 43 | 0 | 2026-03-02, 2026-03-03, 2026-03-04, 2026-03-05, 2026-03-06, 2026-03-07, 2026-03-08, 2026-03-09 (+21) | probe 15535; probe 17437; probe 15535 |

## لایهٔ ۳ — بقیه

| ASN | holder | path | status | success | fail | dates (success, else fail) | examples |
|---|---|---|---|---|---|---|---|
| AS24631 |  | OONI DoH -> 8.8.8.8/8.8.4.4 | باز | 12 | 4 | 2026-03-24, 2026-04-10, 2026-04-15 | 20260415011920.899249_IR_dnscheck_13f93ba2a93410e2; 20260415011920.899249_IR_dnscheck_13f93ba2a93410e2; 20260415011919.677375_IR_dnscheck_db6ecfbbe172e216 |
| AS24631 |  | OONI DoH -> Cloudflare IP | باز | 32 | 16 | 2026-03-05, 2026-03-24, 2026-04-10, 2026-04-15 | 20260415011922.635122_IR_dnscheck_a0af6deaf55de331; 20260415011922.635122_IR_dnscheck_a0af6deaf55de331; 20260415011922.635122_IR_dnscheck_a0af6deaf55de331 |
| AS24631 |  | operator resolver: dns.google | جوابِ درست | 8 | 0 | 2026-03-05, 2026-03-24, 2026-04-10, 2026-04-15 | 20260415011920.899249_IR_dnscheck_13f93ba2a93410e2; 20260415011919.677375_IR_dnscheck_db6ecfbbe172e216; 20260410012855.773548_IR_dnscheck_70b10a493da735df |
| AS24631 |  | operator resolver: cloudflare-dns.com | جوابِ درست | 8 | 0 | 2026-03-05, 2026-03-24, 2026-04-10, 2026-04-15 | 20260415011922.635122_IR_dnscheck_a0af6deaf55de331; 20260415011921.812168_IR_dnscheck_4a4741cf82c76c0b; 20260410012857.573195_IR_dnscheck_44dbbe0067e93cdf |
| AS31549 |  | OONI DoH -> 8.8.8.8/8.8.4.4 | باز | 4 | 0 | 2026-03-25 | 20260325163041.622724_IR_dnscheck_64e3ea19c7070541; 20260325163041.622724_IR_dnscheck_64e3ea19c7070541; 20260325163040.837994_IR_dnscheck_70da2193b3b477a0 |
| AS31549 |  | OONI DoH -> Cloudflare IP | باز | 4 | 4 | 2026-03-25 | 20260411093959.912007_IR_dnscheck_5362a137fe695bfb; 20260411093959.912007_IR_dnscheck_5362a137fe695bfb; 20260411093959.912007_IR_dnscheck_5362a137fe695bfb |
| AS31549 |  | operator resolver: dns.google | جوابِ جعلی | 0 | 2 | 2026-03-25 | 20260325163041.622724_IR_dnscheck_64e3ea19c7070541; 20260325163040.837994_IR_dnscheck_70da2193b3b477a0 |
| AS31549 |  | operator resolver: cloudflare-dns.com (bogon answers seen) | هر دو دیده شد | 1 | 2 | 2026-04-11 | 20260411093959.912007_IR_dnscheck_5362a137fe695bfb |
| AS39074 |  | Atlas UDP/53 -> 8.8.8.8 | باز | 1 | 0 | 2026-04-26 | probe 1001473 |
| AS39074 |  | Atlas probe session to RIPE controller (TCP) | باز | 2 | 0 | 2026-04-26, 2026-04-27 | probe 1001473; probe 1001473 |
| AS39308 |  | OONI DoH -> 8.8.8.8/8.8.4.4 | باز | 4 | 20 | 2026-03-18 | 20260409234315.350158_IR_dnscheck_29490e38e9d426f3; 20260409234315.350158_IR_dnscheck_29490e38e9d426f3; 20260409234314.429490_IR_dnscheck_401c0d2457871fac |
| AS39308 |  | OONI DoH -> Cloudflare IP | باز | 8 | 36 | 2026-03-18 | 20260409234321.543381_IR_dnscheck_7f4b95327eab0cac; 20260409234321.543381_IR_dnscheck_7f4b95327eab0cac; 20260409234321.543381_IR_dnscheck_7f4b95327eab0cac |
| AS39308 |  | operator resolver: dns.google | جوابِ درست | 12 | 0 | 2026-03-18, 2026-03-31, 2026-04-03, 2026-04-07, 2026-04-09 | 20260409234315.350158_IR_dnscheck_29490e38e9d426f3; 20260409234314.429490_IR_dnscheck_401c0d2457871fac; 20260409223713.656304_IR_dnscheck_3540309ed5b785c9 |
| AS39308 |  | operator resolver: cloudflare-dns.com | جوابِ درست | 11 | 0 | 2026-03-18, 2026-03-31, 2026-04-03, 2026-04-07, 2026-04-09 | 20260409234321.543381_IR_dnscheck_7f4b95327eab0cac; 20260409234320.614064_IR_dnscheck_5ca382a3c93e6dc3; 20260409223721.135903_IR_dnscheck_5effdbd7d5f152e2 |
| AS47262 |  | OONI DoH -> 8.8.8.8/8.8.4.4 | بسته | 0 | 280 | 2026-03-08, 2026-03-09, 2026-03-10, 2026-03-11, 2026-03-12, 2026-03-13, 2026-03-15 | 20260315165421.013020_IR_dnscheck_de844f6bec0d2024; 20260315165421.013020_IR_dnscheck_de844f6bec0d2024; 20260315165420.185560_IR_dnscheck_7ea197a86a807dd3 |
| AS47262 |  | OONI DoH -> Cloudflare IP | بسته | 0 | 560 | 2026-03-08, 2026-03-09, 2026-03-10, 2026-03-11, 2026-03-12, 2026-03-13, 2026-03-15 | 20260315165427.371911_IR_dnscheck_1faaeb6a8b4d8af5; 20260315165427.371911_IR_dnscheck_1faaeb6a8b4d8af5; 20260315165427.371911_IR_dnscheck_1faaeb6a8b4d8af5 |
| AS47262 |  | operator resolver: dns.google | جوابِ درست | 140 | 0 | 2026-03-08, 2026-03-09, 2026-03-10, 2026-03-11, 2026-03-12, 2026-03-13, 2026-03-15 | 20260315165421.013020_IR_dnscheck_de844f6bec0d2024; 20260315165420.185560_IR_dnscheck_7ea197a86a807dd3; 20260313185938.087223_IR_dnscheck_0d576723914a3743 |
| AS47262 |  | operator resolver: cloudflare-dns.com | جوابِ درست | 140 | 0 | 2026-03-08, 2026-03-09, 2026-03-10, 2026-03-11, 2026-03-12, 2026-03-13, 2026-03-15 | 20260315165427.371911_IR_dnscheck_1faaeb6a8b4d8af5; 20260315165426.344560_IR_dnscheck_5d7386a7c4bec87e; 20260313185944.351031_IR_dnscheck_c881e169b32e47f0 |
| AS58303 |  | Atlas UDP/53 -> 8.8.8.8 | باز | 127 | 5 | 2026-03-26, 2026-03-27, 2026-03-28, 2026-03-29, 2026-03-30, 2026-03-31, 2026-04-01, 2026-04-02 (+24) | probe 1012845; probe 1012845; probe 1012845 |
| AS58303 |  | Atlas probe session to RIPE controller (TCP) | باز | 38 | 0 | 2026-03-12, 2026-03-25, 2026-03-26, 2026-03-27, 2026-03-28, 2026-03-29, 2026-03-30, 2026-03-31 (+30) | probe 1012845; probe 1012845; probe 1012845 |
| AS9147 |  | Atlas UDP/53 -> 8.8.8.8 | باز | 19 | 0 | 2026-04-27, 2026-04-28, 2026-04-29, 2026-04-30 | probe 33233; probe 33233; probe 33233 |
| AS9147 |  | Atlas probe session to RIPE controller (TCP) | باز | 5 | 0 | 2026-04-26, 2026-04-27, 2026-04-28, 2026-04-29, 2026-04-30 | probe 33233; probe 33233; probe 33233 |

## حذف‌شده — ASNِ خارجی، هرگز شاهد نیست

| ASN | holder | path | status | success | fail | dates (success, else fail) | examples |
|---|---|---|---|---|---|---|---|
| AS142578 |  | OONI DoH -> 8.8.8.8/8.8.4.4 | باز | 434 | 692 | 2026-03-01, 2026-03-02, 2026-03-05, 2026-03-06, 2026-03-07, 2026-03-08, 2026-03-09, 2026-03-12 (+13) | 20260427190710.646423_IR_dnscheck_9ff7517e34e1d583; 20260427190710.646423_IR_dnscheck_9ff7517e34e1d583; 20260427190710.217976_IR_dnscheck_48e4fa9c65806baf |
| AS142578 |  | operator resolver: dns.google | هر دو دیده شد | 505 | 58 | 2026-03-01, 2026-03-02, 2026-03-03, 2026-03-04, 2026-03-05, 2026-03-06, 2026-03-07, 2026-03-08 (+18) | 20260427190710.646423_IR_dnscheck_9ff7517e34e1d583; 20260427190710.217976_IR_dnscheck_48e4fa9c65806baf; 20260426220812.295387_IR_dnscheck_45b38359ef84530f |
| AS197540 |  | Atlas UDP/53 -> 8.8.8.8 | باز | 1 | 1 | 2026-03-01 | probe 33013 |
| AS197540 |  | Atlas probe session to RIPE controller (TCP) | باز | 6 | 0 | 2026-03-01, 2026-03-03, 2026-03-08, 2026-03-09, 2026-04-22, 2026-04-24 | probe 33013; probe 33013; probe 33013 |
| AS203273 |  | Atlas UDP/53 -> 8.8.8.8 | باز | 160 | 0 | 2026-03-01, 2026-03-02, 2026-03-03, 2026-03-04, 2026-03-05, 2026-03-06, 2026-03-07, 2026-03-08 (+53) | probe 1009502; probe 1009502; probe 1009502 |
| AS203273 |  | Atlas probe session to RIPE controller (TCP) | باز | 60 | 0 | 2026-03-02, 2026-03-03, 2026-03-04, 2026-03-05, 2026-03-06, 2026-03-07, 2026-03-08, 2026-03-09 (+52) | probe 1009502; probe 1009502; probe 1009502 |
| AS57511 |  | Atlas UDP/53 -> 8.8.8.8 | باز | 22 | 0 | 2026-03-01, 2026-03-02, 2026-03-03, 2026-03-04, 2026-03-05, 2026-03-07, 2026-03-08, 2026-03-09 (+4) | probe 25407; probe 25407; probe 25407 |
| AS57511 |  | Atlas probe session to RIPE controller (TCP) | باز | 13 | 0 | 2026-03-02, 2026-03-03, 2026-03-04, 2026-03-05, 2026-03-06, 2026-03-07, 2026-03-08, 2026-03-09 (+5) | probe 25407; probe 25407; probe 25407 |

## بارگذاری روزانهٔ OONI از لایهٔ مصرف‌کننده

```
day        | AS197207 MCI | AS44244 Irancell | AS58224 TCI
2026-03-04 |      0 |     32 |      0
2026-03-05 |     10 |      0 |      0
2026-03-06 |      0 |    251 |      0
2026-03-12 |      0 |      0 |     24
2026-03-14 |      0 |      0 |      3
2026-03-18 |      0 |      0 |     28
2026-03-22 |    108 |      0 |      0
2026-03-23 |    108 |      0 |      0
2026-03-24 |      0 |    198 |      0
2026-03-26 |      4 |      0 |      0
2026-03-27 |    204 |     37 |      0
2026-03-28 |    219 |      0 |      0
2026-03-29 |    105 |      0 |      0
2026-03-30 |    215 |      0 |      0
2026-03-31 |     11 |      0 |      0
2026-04-03 |    108 |      0 |      0
2026-04-05 |    175 |      0 |      0
2026-04-06 |     40 |      0 |      0
2026-04-07 |    118 |      0 |      0
2026-04-09 |    338 |    360 |      0
2026-04-10 |    117 |      0 |      0
2026-04-11 |    117 |      0 |      4
2026-04-12 |    100 |      0 |      0
2026-04-13 |    111 |      0 |      0
2026-04-14 |      4 |      0 |      0
2026-04-15 |    323 |      0 |      0
2026-04-16 |    211 |      0 |      0
2026-04-17 |    108 |      0 |      0
2026-04-19 |    108 |      0 |      0
2026-04-20 |    319 |      6 |      0
2026-04-21 |    215 |      0 |      2
2026-04-23 |    227 |      6 |      0
2026-04-24 |    109 |      8 |      0
2026-04-25 |    108 |      0 |      0
2026-04-26 |    132 |      0 |      0
2026-04-27 |      7 |     10 |      0
2026-04-28 |    223 |      0 |      0
2026-04-29 |    106 |      0 |      0
2026-04-30 |    176 |     15 |      0
```

فاصلهٔ زمانِ اجرا تا رسیدنِ آپلود به collector در خارج، به ثانیه. فقط آپلودِ حداکثر یک ساعت بعد از اجرا شاهد حساب شده است:

```
AS197207 MCI: n=4584 median=14s p90=61s within_1h=4267 late_or_invalid=317 days_with_upload_within_1h=32 proxy/tunnel_words_in_sample=0/20
AS44244 Irancell: n=923 median=7s p90=33s within_1h=902 late_or_invalid=21 days_with_upload_within_1h=10 proxy/tunnel_words_in_sample=0/20
AS58224 TCI: n=61 median=28s p90=308s within_1h=58 late_or_invalid=3 days_with_upload_within_1h=5 proxy/tunnel_words_in_sample=0/20
```

## محدودیت‌ها

- گزارشِ OONI وقتی باز می‌شود که پروب به collector در خارج رسیده باشد. ممکن است این اتصال از راهِ پراکسیِ خودِ OONI (Psiphon یا Tor) بوده باشد؛ این فایل آن را جدا نمی‌کند.
- جوابِ درستِ رزالورِ اپراتور برای نامِ خارجی ثابت نمی‌کند که پرسش به بیرون رفته است. ممکن است از کش یا فهرستِ سفید آمده باشد.
- ASNِ پروب‌های Atlas همان ASNِ امروزِ آن‌هاست. ممکن است در مارس و آوریل فرق داشته است.
- Atlas UDP/53 به ۸.۸.۸.۸: from marapr_8888.json. ۱.۱.۱.۱ از Atlas جمع نشده است.
- نمونهٔ web_connectivity برای هر ASNِ لایهٔ ۱ حداکثر ۶۰ اندازه‌گیری است که یکنواخت در بازه پخش شده است.
