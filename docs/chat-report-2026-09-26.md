# گزارش چت — نامه‌ی اضطراری، کاوشگر سه‌رزالوری و نردبان وضعیت

بازه‌ی زمانی:

```
2026-09-23 19:30 UTC  ->  2026-09-26 02:48
branch: plan-v4-waves-1-to-6
```

TL;DR — از یک پرسشِ پژوهشی درباره‌ی دسترسی به رزالورِ گوگل از ایران شروع شد و به یک کانالِ نامه‌ی اضطراری با کاوشگرِ سه‌رزالوری، نردبانِ شش‌پله‌ای وضعیت، خواندنِ رزالورِ سیستمی و ردیفِ موفق روی گوشیِ واقعی رسید؛ شاهدِ میدانی از سیمِ مصرفی هنوز اندازه‌گیری نشده است.

──────

## از کجا شروع شد

- وضعیتِ اول: یک گزارشِ موجود درباره‌ی دسترسی به رزالورِ گوگل از ایران وجود داشت و سامانه‌ی نامه آماده بود ولی کاوشگر نداشت.
- اولین پرسش: سامانه‌ی نامه هنگامِ قطعیِ اینترنتِ ایران به چه دردی می‌خورد؟
- پاسخ: یک کانالِ نامه‌ی اضطراری برای قطعیِ جزئی، نه تماسِ زنده.
- درخواستِ بعدی: مقایسه‌ی گزارش با داده‌های تازه‌ی چهار منبعِ عمومی، و سپس مطالبه‌ی داده‌ی خامِ اندازه‌گیری به‌جای گزارش‌های منتشرشده.

```
iran-8888-report.md
sources: ooni.org, filterwatch, IODA, ircf.space
```

──────

## خطِ زمانی

### روزِ ۲۳ سپتامبر — پژوهشِ داده‌ی خام

- ردیف‌های تازه‌ی خطِ زمانی برای ژوئن تا سپتامبر اضافه شد و یک ادعای نادرستِ افتِ ترافیک رد شد، چون منبعش توییتِ سالِ قبل بود.
- داده‌ی خامِ اونی برای دسترسی به رزالورِ گوگل از ایران خوانده شد و جمعِ جدول با داده‌ی خام برابر درآمد.

```
OONI DoH -> https://8.8.8.8/dns-query from IR, 2026-01-01..09-23
976 measurements: ok 777 / timeout 197 / refused 2
```

- نسخه‌ی دوم گزارش نوشته شد و چهار فایل در پوشه‌ی شواهد کپی و یکسانیِ بایتی‌شان تأیید شد.
- جدولِ روزانه‌ی مارس و آوریل ساخته شد؛ حکمِ اول اشتباه بود و پس از حذفِ شبکه‌های خارجیِ برچسب‌خورده به ایران اصلاح شد.

```
v1 verdict: 46 days total shutdown (wrong)
corrected : 61/61 days partial; 8.8.8.8 answered on 46/61 days (IR ASNs only)
min IR-ASN OONI uploads per day: 37
```

- تفکیکِ سه‌لایه‌ی شبکه‌ها با یک اسکریپتِ تک و نوارِ پیشرفت، بدونِ عامل، ساخته شد.
- کاوشگرِ نامه پیاده شد: سه رزالور، یک نانس برای هر کدام، اولین نانس در لاگِ سرورِ ما برنده است.

```
txt_letter_probe_test 5/5 · test_txt_probe.py 9/9 · letter_probe_e2e.sh PASS
```

### روزِ ۲۴ سپتامبر — سیم‌کشیِ کاوشگر و اجرای اول روی ریگ

- کاوشگر به ارسالِ نامه وصل شد و کلِ مجموعه‌ی تستِ اپ سبز شد.

```
reference_app full suite: 558 passed (06:20)
commit 21742a9  36 files +36796/-5
```

- اسکنِ آرشیوِ اطلس برای مارس و آوریل: پاسخِ مستقیم فقط از شبکه‌های دیتاسنتری دیده شد؛ سه اپراتورِ مصرفی بدونِ پروب ماندند.
- اجرای واقعی روی ریگ با گروه و نانسِ یکسان در گوشی و لاگِ پاسخ‌گو موفق بود.

```
LETTER_ONLY  group 73d781ddc7842940  winner a8cf06ac4f224273
letter P46NLS 1022 B, 277 ms after the nonce
commit d4cc8d2  6 files +177/-5
```

- بررسیِ نقاطِ دیدِ جایگزین: پروب‌های داخلِ ایران همه دیتاسنتری‌اند؛ پاسخِ اطلسِ ایرانسل برای گوگل جعلی بود.

```
Irancell Atlas 61627/1010502: 216.239.38.120 TTL 1 (forcesafesearch)
Globalping IR: 5 probes, all datacenter, 0 consumer
```

### ۲۴ تا ۲۵ سپتامبر — شکافِ اطلس و بدنه‌های اونی

- فقط نامِ گوگل جعل می‌شود؛ نامِ تصادفی و نامِ نمونه به خارج رسیدند.
- شکافِ اطلس: هیچ پروبِ ایرانسل یا همراه اول در این بازه وصل نبود.

```
gap: 2026-02-28 07:24 -> 06-08 10:13 UTC (101 days), 36 probes checked
id.server @1.1.1.1 from Irancell: 114/116 days reached abroad
```

- همه‌ی بدنه‌های وب‌کانکتیویتیِ اونی برای یکم مارس تا بیست‌وپنجم مه خوانده شد.

```
10521 unique: ok 4576 / anomaly 5380 / failed 565, 1492 destinations
outward evidence: 31/86 days (36%)
queue <=3 days 58%, <=7 days 73%; union A|H|D 66% same day, 86% <=3 days
```

- اسکریپتِ تشخیصِ نامِ تصادفی روی ریگ سبز شد؛ درخواستِ طراحیِ روش‌های دورزدنِ تازه رد شد.

### روزِ ۲۵ سپتامبر — مستندسازی، نردبانِ پله‌ها و هوشِ اپ

- بررسیِ لایه‌های هوشِ اپ: فقط مسیرهای موجود را رتبه می‌دهند و مسیرِ تازه نمی‌سازند.
- شواهد و صفحه‌ی مستندِ «شاهدِ میدانی اندازه‌گیری نشده» کامیت شد.

```
5c20bdb  9 files +739/-2
aa29814  docs/LETTER_FIELD_EVIDENCE.md
```

- نردبانِ پله‌های باز‌کردنِ نامه: برنده‌ی قبلی به‌علاوه‌ی یک رقیبِ وزن‌دار؛ تاریخچه‌ی خالی یعنی مسابقه‌ی سه‌طرفه.
- اندازه‌گیریِ نصبِ اول با رضایتِ جدا، دروازه‌ی دومِ ارتقا در تکاملِ شبانه، و کلیدِ رضایت در تنظیمات.
- نردبانِ شش‌پله‌ای وضعیت، جفتِ رزالورِ پشتیبان، بنرِ نامه و روایتِ مدیر ساخته شد.
- نقص‌های بازبینی بسته شد؛ یک کامیت وابستگی‌اش را جا گذاشته بود و اصلاح شد.
- رتبه‌بندیِ رزالورها با نرخِ برد، نامِ پله در صفحه‌ی گفت‌وگو، گسترشِ فهرستِ منتشرشده، و درزِ رزالورِ سیستمی.

### روزِ ۲۶ سپتامبر — بازنویسیِ مدرن، خواندنِ بومی و ریگ

- بازنویسیِ کدِ امروز به سبکِ دارت ۳ پس از ریبوتِ مک کامیت شد.
- خواندنِ بومیِ رزالورِ سیستمی برای آی‌اواس و اندروید اضافه شد؛ خطای کامپایلِ سویفت در کامیتِ بعدی رفع شد.
- ردیفِ نامه روی گوشیِ واقعی موفق بود.

```
FEOZN5  12 B  27.8 s  lane dns-valve  PASS  sha256 56494d92f8622950
```

- تستِ صفحه‌ی گفت‌وگو هر شش پله را از بالا تا پایین پیمود.

──────

## به کجا رسید

- وضعیتِ نهایی مخزن تمیز است و ریگ خاموش؛ هیچ چیزی پوش نشده است.
- آخرین کار، رویدادِ کارتِ نامه برای هر نامه، در کامیتِ بعدی انجام شد و یک ردیفِ واقعی روی گوشی گرفت.

```
HEAD 2b852ad  feat(letter): per-letter lab measurement card (jsonl telemetry)
tracked apps/ and packages/ clean
rig off · nothing pushed
letter_card jsonl event: done (2b852ad) · session 6VFT62 mac-source LETTER_ONLY PASS 1022 B 27.8 s lane resilient.dns-valve · rung null (peer has no ladder, by design)
```

──────

## موفقیت‌ها

- داده‌ی خامِ اونی برای رزالورِ گوگل با جدولِ گزارش تطبیق داده شد.

```
976 = 976
```

- حکمِ مارس و آوریل با حذفِ شبکه‌های خارجی اصلاح شد.

```
46/61 days answered, 61/61 partial
```

- کاوشگرِ سه‌رزالوری با تست‌های واحد، تستِ پایتون و آزمونِ سرتاسریِ روی سیمِ واقعی.

```
probe 5/5 -> 7/7 -> 8/8 · Python 9/9 · e2e 300 B + 4096 B sha match, 4097 B refused
```

- دو ارسالِ موفق روی ریگ با اپِ واقعی و گروهِ یکسان در دو سو.

```
UC3SLK 107 B · P46NLS 1022 B (group 73d781ddc7842940)
```

- اثباتِ جعلِ پاسخِ گوگل در شبکه‌های ایران و رسیدنِ نامِ تصادفی به خارج.

```
216.239.38.120 TTL 1 vs real Google on Dutch control probe 2047
```

- سنجشِ سقفِ دسترسی از بدنه‌های اونی.

```
31/86 days (36%) outward; 86% within 3 days with multi-lane queue
```

- نردبانِ پله‌ها، اندازه‌گیریِ با رضایت، نردبانِ شش‌پله‌ای وضعیت، روایتِ مدیر، و رتبه‌بندی با نرخِ برد؛ همه با تست.

```
reference_app 77 + connection_orchestrator 14 green (93fbe86)
84 tests across 7 letter/intelligence suites (25c6545)
10 suites 102/102 · ladder suites 78/78 · conversation 9/9 · peer 66/66
```

- خواندنِ بومیِ رزالورِ سیستمی و ردیفِ موفق روی گوشی.

```
99f4de1 20/20 · FEOZN5 PASS
```

──────

## شکست‌ها و گره‌ها

- حکمِ اولِ مارس و آوریل غلط بود، چون به پینگِ ورودی تکیه داشت و شبکه‌های خارجی را شمرده بود.
- برای سه اپراتورِ مصرفی هیچ پروبِ اطلس یا گلوبال‌پینگ وجود ندارد؛ بدونِ سیم‌کارت راهی برای سنجش نیست.
- شاهدِ میدانی از گوشیِ مصرفی با سیمِ واقعی صفر ردیف دارد.
- پاسخ‌گوی هلند به نسخه‌ی تازه‌ی سرور به‌روز نشد.
- چند منبع مسدود بود: رادار بدونِ توکن، سنسورد پلنت با خطای دسترسی، و ام‌لب با دسترسیِ رد‌شده.
- پنج تستِ از پیش شکسته در لاینِ پرس‌وجوی متنی دست‌نخورده ماند.
- دو اجرای هم‌زمانِ تستِ فلاتر مک را قفل کرد و ریبوت لازم شد.

```
load averages 68.94 179.13 100.43
```

- کدِ آی‌اواس در اولین ساخت کامپایل نشد و در کامیتِ بعدی رفع شد.
- برچسبِ رزالورِ سیستمی و بنرِ پله روی ریگ مشاهده نشد، چون ریگ همیشه رزالور را ثابت می‌کند.

```
journey_run.sh pins resolvers to 192.168.2.1:5300
dnsvalve.phone.jsonl has no rung/banner/history fields
```

- یک کامیت وابستگی‌اش را جا گذاشت و سه کامیت از نسخه‌ی تمیز نمی‌ساخت.
- فیلترِ ایمنی چند پاسخ را متوقف کرد، از جمله کارتِ نامه و اولین درخواستِ سنجش روی آیفون.
- هوک‌های محدودیتِ ویرایش و منعِ هیردوک چندین بار کار را کند کردند؛ یک‌بار با وجودِ «بدونِ عامل» یک ورک‌فلو اجرا شد و متوقف شد.

──────

## کامیت‌ها

```
21742a9  feat(letter): three-resolver probe before a door letter, and the Iran Mar-Apr evidence
d4cc8d2  feat(letter): the probe line in the phone event, and the LETTER_ONLY peer probes first
5c20bdb  evidence(iran-8888): the 2026-02-28 .. 06-08 gap, the rewrite-vs-forward rows, and the Mar-May OONI destinations
aa29814  docs(letter): field evidence page — the field witness is unmeasured
b9135c8  feat(letter): the letter keeps the previous winner and one weighted competitor on this phone; no new rung
e074394  feat(letter): first-install measurement with consent, and a second promotion gate keyed on the door's own win ratio
ecb1715  feat(letter): wire the letter into the existing intelligence — settings consent, call-history-shaped rows, and a score
d1f6537  feat(letter): a six-rung status ladder from the snapshot and the letter probe, and a fixed fallback pair
ff8594a  feat(letter): the status ladder now runs on every Send and shows on the letter banner
9a822b3  feat(director): narrate the letter's rung beside the door ladder
68c9b46  fix(letter): commit PersistedMeasurementConsent and its tests
935450a  fix(letter): stale rung on a drained letter, one narrowing rule, one banner vocabulary
93fbe86  fix(letter): one dead-line constant, one win-ratio helper, gate on the letters' network, rung on every banner
4b650cb  feat(letter): rank the door's own resolvers by win rate, keep close rivals
25c6545  feat(letter): the thread page names the letter's own rung, one word everywhere
5a1f572  feat(door): widen the door's fallback resolvers with the already-published list
758655d  feat(door): seam for this device's own DHCP-assigned DNS resolver
6d22499  refactor(letter): today's letter+door code in Dart 3 idiom, no behaviour change
99f4de1  feat(door): read this device's own DNS resolver from the platform's system API
43990ff  fix(ios): SystemDnsReader builds the resolver state struct, not the libresolv accessor
d50fa8a  feat(journey): the rig peer's valve takes this device's resolver when a job pins none
75bbd0b  test(letter): the thread page walks every rung, top to bottom
2b852ad  feat(letter): per-letter lab measurement card (jsonl telemetry)
```

──────

## فهرستِ فایل‌های تغییرکرده

```
# evidence (tools/dossier/evidence/iran-8888/)
iran-8888-report-v2.md
ooni_dnscheck_raw.py
g8888_a.txt
g8888_b.txt
atlas_8888.py
atlas_8888_sep16-23.txt
marapr_collect.py
marapr_show.py
marapr_8888.py
marapr_ooni_google.py
marapr_build.py
marapr_recheck.py
iran-marapr-2026.md
marapr_layers.py
iran-marapr-layers.md
vantage-2026-09-24.md
vantage-2026-09-24.json
four-sources-2026-09-24.md
rewrite-vs-forward-2026-09-24.md
irancell-probes-other-dns-2026-09-24.md
irancell-1111-idserver-2026.md
atlas-gap-2026-02-28-to-06-08.md
gap-other-sources-2026.md
ooni-floor-destinations-mar-may-2026.md

# tools/t2/
tools/t2/txt_query_server.py
tools/t2/test_txt_probe.py
tools/t2/letter_probe_e2e.sh
tools/t2/probe_check.sh
tools/t2/rand_name_check.py

# docs
docs/LETTER_FIELD_EVIDENCE.md

# packages/adaptive_transport
packages/adaptive_transport/lib/adaptive_transport.dart
packages/adaptive_transport/lib/src/resilient/txt_letter_probe.dart
packages/adaptive_transport/lib/src/resilient/txt_query_lane.dart
packages/adaptive_transport/lib/src/resilient/txt_query_transport.dart
packages/adaptive_transport/test/txt_letter_probe_test.dart
packages/adaptive_transport/tool/letter_probe_e2e.dart

# packages/connection_orchestrator
packages/connection_orchestrator/lib/src/call_history.dart
packages/connection_orchestrator/lib/src/brain_generations.dart
packages/connection_orchestrator/test/brain_generations_test.dart

# apps/reference_app lib
apps/reference_app/lib/main.dart
apps/reference_app/lib/src/call_session.dart
apps/reference_app/lib/src/letter_courier.dart
apps/reference_app/lib/src/letter_rung_ladder.dart
apps/reference_app/lib/src/letter_status_ladder.dart
apps/reference_app/lib/src/ui/settings_screen.dart
apps/reference_app/lib/src/ui/letter_thread.dart
apps/reference_app/lib/src/intelligence/intelligence_director.dart
apps/reference_app/lib/src/intelligence/intelligence_boot.dart
apps/reference_app/lib/src/intelligence/nightly_evolution.dart
apps/reference_app/lib/src/intelligence/device_bindings.dart
apps/reference_app/lib/src/intelligence/system_dns.dart

# apps/reference_app tests
apps/reference_app/test/letter_door_probe_test.dart
apps/reference_app/test/letter_courier_test.dart
apps/reference_app/test/letter_rung_ladder_test.dart
apps/reference_app/test/letter_status_ladder_test.dart
apps/reference_app/test/nightly_evolution_test.dart
apps/reference_app/test/intelligence_director_test.dart
apps/reference_app/test/device_bindings_test.dart
apps/reference_app/test/system_dns_test.dart
apps/reference_app/test/ui/letter_conversation_test.dart
apps/reference_app/integration_test/journey_peer_app.dart

# native
apps/reference_app/ios/Runner/AppDelegate.swift
apps/reference_app/ios/Runner/Runner-Bridging-Header.h
apps/reference_app/ios/Flutter/Debug.xcconfig
apps/reference_app/ios/Flutter/Release.xcconfig
apps/reference_app/android/app/src/main/AndroidManifest.xml
apps/reference_app/android/app/src/main/kotlin/com/voicecallkit/reference_app/MainActivity.kt
```

──────

## کارهای باز

- پر شدنِ فیلدِ پله روی کارتِ مسیرِ اپ روی گوشیِ واقعی دیده شود؛ در تستِ واحد پین شده است.
- به‌روزرسانیِ پاسخ‌گوی هلند به نسخه‌ی تازه‌ی سرور.
- سنجشِ شاهدِ میدانی از گوشیِ مصرفی با سیمِ واقعیِ ایرانسل یا همراه اول.
- اجرای ریگ بدونِ رزالورِ ثابت تا برچسبِ رزالورِ سیستمی و بنرِ پله روی گوشی دیده شود.
- آزمونِ روی‌دستگاهِ خواندنِ بومیِ اندروید.
- مهاجرتِ هش که عمداً باز ماند.
- پنج تستِ از پیش شکسته در لاینِ پرس‌وجوی متنی.
- شاخه جلوتر از مبدأ است و پوش نشده؛ فایل‌های ردیابی‌نشده‌ی کشِ لایه‌ها و فایل‌های هندآف هنوز در درخت هستند.

جمع‌بندی: قدمِ بعدیِ طبیعی سنجشِ میدانی از یک گوشیِ مصرفی است؛ بدونِ آن نرخِ رسیدنِ واقعیِ نامه نامعلوم می‌ماند.
