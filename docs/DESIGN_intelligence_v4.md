# طراحی «هوشمندی v4 — موجود خودآموزِ بسته‌مدار»

ثبت ۲۰۲۶-۰۸-۱۱ — سند مشاوره‌ی معمار ارشد (کانداکتر Fable 5، مطابق قانون
کاربر ۲۰۲۶-۰۸-۰۸: بدون اعزام ایجنت مشاور). هر عدد این سند در همین نشست
اندازه‌گیری و بازتولید شده است؛ اسکریپت‌های اثبات در scratchpad نشست موجودند.

## ۰. پایه‌ی بازتولیدشده (امروز، قبل از هر ویرایش)

بازپخش v3 روی همان کورپوس (۲۳ ران + ۲۷۲ ردیف tsv که ۳۷تایش امتیازپذیر است):

```
epoch 0 score 1.000 (trend 1.000, lane 1.000, calib 1.000, atlas 1.000)
epoch 4 score 1.085 (trend 1.000, lane 1.072, calib 0.955, atlas 1.314)
```

مطابق `tools/t2/intelligence_evolution.json` — بازتولید بیت‌به‌بیت.

دروازه‌ی تست پایه: `tools/run_gate_loop.sh` امروز RED است — شکستِ
ازپیش‌موجود و مستقل از v4:

```
packages/call_media_adapter/test/webrtc_call_media_session_test.dart:8
_FakeMediaDataChannel missing: MediaDataChannel.bufferedAmount
(media_webrtc/lib/src/media_data_channel.dart:101)
```

اصلاح یک‌خطی (override بازگرداندن null) قدم صفر است؛ بدون آن GATE LOOP OK
هرگز ممکن نیست.

## ۱. ستون ۱ — کالیبراتور توزیعی (تنها مؤلفه‌ی افت‌کرده)

### تشخیص با عدد

سلول `l3|r0` در کورپوس واقعی نسبت‌های actual/predicted از ۰٫۶۶ تا ۶۹٫۹۶
دارد (دووجهی loss60). EWMA اسکالر با clamp=4x این توزیع را له می‌کند و
نوسان می‌کند (رکوردهای whatChanged: تصحیح یک سلول بین ۰٫۷۶ و ۱٫۸۵ رفت‌وبرگشتی).

### طرح انتخاب‌شده — با اندازه‌گیری، نه سلیقه

هیستوگرام ثابت-بینِ log2 برای هر سلول + یک هیستوگرام سراسری:

- بین‌ها: ربع-اکتاو (۴ بین در هر اکتاو)، بازه‌ی log2 از −۷ تا +۷
  (نسبت ۱/۱۲۸ تا ۱۲۸ — نسبت ۷۰x دیگر له نمی‌شود)؛ ذخیره‌سازی sparse.
- `correction()` = کمینه‌سازِ خطای نسبی میانگین = میانه‌ی وزنی نسبت‌ها با
  وزن 1/r (از جرم هیستوگرام، قطعی و بسته).
- shrinkage همان فلسفه‌ی v3: زیر ۳ نمونه سلول بی‌صداست (شکل سراسری یا
  ۱٫۰)؛ بالای آن جرم سلول + شکل سراسری با شبه-شمار ۳.
- `budgetQuantile(p)` (پیش‌فرض p80) برای نقش بودجه/مهلت — جدا از
  `correction()`. اندازه‌گیری قاطع: اگر p80 را در نقش تصحیح بگذاریم
  مؤلفه به ۰٫۵۴ سقوط می‌کند؛ p80 چندکِ بودجه است، نه تخمین‌گر نقطه‌ای.
- بدون فراموشی (decay=0): full-history برنده‌ی سنجش بود و ساده‌ترین است.

### جدول سنجش (شبیه‌ساز معتبرشده — v3-ewma را بیت‌به‌بیت بازتولید می‌کند)

```
design            raw e0..e4                          norm e0..e4
v3-ewma           0.6549 0.6256 0.6222 0.6252 0.6255  1.000 0.955 0.950 0.955 0.955
hist-wmed (v4)    0.7091 0.7154 0.7153 0.7184 0.7215  1.000 1.009 1.009 1.013 1.018
hist-p50          0.6942 ...                          1.000 1.009 1.008 1.001 1.001
hist-p80-as-corr  0.3815 0.2052 ...                   1.000 0.538 ... (رد شد)
```

### دروازه‌ی مکانیکی ستون ۱ (پیش‌بینی سنجیده: پاس می‌شود)

روی همان کورپوس v3: کالیبراتور نرمال‌شده در هر epoch پس از صفر ≥ ۱٫۰۰
(اندازه‌گیری آفلاین: ۱٫۰۰۹ تا ۱٫۰۱۸)؛ raw هم در همه‌ی epochها بالای raw
v3 است (+۸ تا +۱۵٪). lane و atlas دست نمی‌خورند؛ کل امتیاز پیش‌بینی‌شده:

```
(1.000 + 1.072 + 1.018 + 1.314) / 4 = 1.101 >= 1.0854
```

### سطح ویرایش

- `packages/connection_orchestrator/lib/src/budget_calibrator.dart` —
  بازنویسی داخلی؛ API بیرونی (observe/correction/toJson/fromJson) حفظ،
  `budgetQuantile(p)` اضافه. fromJson قدیمی (شکل v/w) → مهاجرت امن: جرم
  w در بینِ log2(v) کاشته می‌شود تا مغز قدیمی روی دیسک بی‌صدا صفر نشود.
- `packages/connection_orchestrator/test/budget_calibrator_test.dart` —
  پین‌ها: سلول دووجهی (نیمی ۱x نیمی ۷۰x → تصحیح نزدیک مود پایین، چندک
  p80 بالای مود بالا)، round-trip سریال‌سازی، فایل خراب → مغز تازه،
  مهاجرت فرمت v3.

## ۲. ستون ۲ — پیش‌بینِ بسته‌مدار (۰٫۵۷ آفلاین باید زنده شود)

### لنگرهای موجود

- شلیک از قبل هست: `connection_fabric.dart:419` روی failingSoon
  کال‌بک‌های `_onUnhealthy` را صدا می‌زند و همه‌ی کانال‌ها تغذیه می‌شوند
  (`connection_fabric.dart:404-416`).
- شواهد عددی هر شلیک: `TrendVerdictDetail.grounds` (trend_monitor.dart:260).
- لایه‌ی اپ: `apps/reference_app/lib/src/intelligence/intelligence_director.dart`
  و `connectivity_playbook.dart` و `degraded_mode_driver.dart`.

### طرح

1. در فابریک، رویداد failingSoon با nowMs و grounds ثبت شود (journal +
   استریم برای اپ) — نه فقط کال‌بک بی‌نام.
2. سه اقدام پیش‌دستانه، به ترتیب هزینه: کف بقا (نردبان یک پله پایین،
   همان مسیر degraded موجود)، پیش‌گرمی لاین جایگزین (dial/probe زودهنگام)،
   آماده‌سازی حالت ویس‌نوت (صف DTN آماده، بدون سویچ).
3. اندازه‌گیری در تستِ ریگ: دو فیلد نو در SLA_SUMMARY و VID_SUMMARY —
   `sentinelLeadMs` (فاصله‌ی اولین failingSoon تا اولین
   disconnected/failed پس از اتصال؛ منفی/غایب = شلیک نبود) و
   `preventedFreezes` (شمار فریزهایی که پس از اقدام پیش‌دستانه در پنجره‌ی
   ۳۰s رخ نداد ولی projection سقوط را نشان می‌داد — تعریف دقیق در تست،
   قابل‌مقایسه با ران مرجع همان پروفایل).
4. ردیف رسمی ریگ: یک ران با lead-time مثبتِ ثبت‌شده + freeze کمتر نسبت
   به ران مرجع همان پروفایل (دروازه‌ی ستون).

### سطح ویرایش

`connection_fabric.dart` (ثبت رویداد سنجیده)، `intelligence_director.dart`
و `connectivity_playbook.dart` (سه اقدام)، `integration_test/support/e2e_support.dart`
و تست‌های sla/video (دو فیلد نو)، `tools/t2/h2_run.sh` (عبور فیلدها به tsv).

## ۳. ستون ۳ — قهرمان/چالش‌گرِ روی-دستگاه

- حلقه‌ی epoch از ابزار توسعه (`tool/intelligence_replay.dart`) به سرویس
  خود اپ: ورودی، `call_history` + `journal` خود دستگاه؛ خروجی، نسل نو
  مغزها روی `Documents` (همان `disk_json_storage.dart`).
- ساختار دیسک: `brains/current/` (قهرمان)، `brains/candidate/` (چالش‌گر)،
  `brains/prev/` (نسل قبلی دست‌نخورده برای rollback) + `promotion_log.json`
  با امتیاز قبل/بعد و شناسه‌ی شواهد.
- PROMOTE فقط وقتی امتیاز چالش‌گر > قهرمان روی همان داده؛ وگرنه rollback
  بی‌قید. شرط اجرا: فقط روی برق/باتری بالا (seam موجود
  `device_bindings.dart`؛ پراب واقعی باتری همان پیش‌نیاز حمل‌شده از v2).
- تست پین (واحد، بدون دستگاه): promote-on-rise و rollback-on-drop با
  امتیازساز تزریقی.
- فایل نو: `packages/connection_orchestrator/lib/src/brain_generations.dart`
  + تست؛ سیم‌کشی اپ در `intelligence_boot.dart`.

## ۴. ستون ۴ — اطلس پیش‌نگر (ساعتِ هفته + مدل گذار)

- کلید سلول از hourOfDay به hourOfWeek (۰..۱۶۷) تعمیم می‌یابد؛ زنجیره‌ی
  fallback سخت‌گیرانه تا امتیاز اطلس روی کورپوس v3 پایین نیاید:
  سلول ساعتِ هفته (≥۳ نمونه) → سلول ساعتِ روز (رفتار v3 عیناً) → تجمیع
  هویت. سریال‌سازی v2 با خواندن سازگار فایل v1 (تست پین).
- مدل گذار شبکه‌به‌شبکه: شمارنده‌ی جفت (هشِ قبلی → هشِ بعدی) با سقف
  ثابت و eviction قدیمی‌ترین؛ خروجی `likelyNextNetwork()` برای پیش‌گرمی
  قبل از ترک شبکه. فقط هش — حریم مثل v3، پین تست حریم موجود می‌ماند.
- روی کورپوس v3 گذار قابل‌سنجش نیست (هویت‌ها پروفایل ریگ‌اند)؛ مؤلفه‌ی
  امتیاز تغییر نمی‌کند — گذار فیلد گزارشی نو می‌گیرد، نه جزء میانگین
  چهارتایی (تعریف score برای مقایسه‌پذیری v4≥v3 ثابت می‌ماند).

## ۵. ستون ۵ — راویِ پاسخ‌گو (سه intent قالبی، بدون LLM)

- `RuleBasedAssistant` (rule_based_assistant.dart) سه پرسش قالبی
  می‌گیرد: «چرا کند شد؟» / «امروز چه یاد گرفتی؟» / «چه عوض شد؟».
- پاسخ‌ساز قطعی: ورودی فقط `MeasurementJournal.recent()` و
  `CallHistoryStore.records`؛ هر جمله با ارجاع [mN] — همان قرارداد
  `_withCitations` موجود؛ بدون سنجه، جمله‌ای ادعا نمی‌شود.
- گلدن‌تست هر سه intent با journal/history ساختگی و خروجی کلمه‌به‌کلمه.
- منطق نگاشت: کندی → آخرین رکوردهای rtt/loss/backpressure؛ یادگیری →
  آخرین flip/correction/shift ژورنال (همان whatChanged)؛ تغییر →
  diff نسل مغزها از promotion_log ستون ۳.

## ۶. ستون ۶ — کورپوس فدرال ریگ (پایان تبخیر شواهد)

- `h2_run.sh` در انتهای هر ران (نقطه‌ی فعلی نوشتن tsv، خطوط ۱۱۶۴-۱۱۷۳)
  همان برداشت را مستقیم داخل repo می‌نویسد:
  `python3 tools/t2/build_replay_corpus.py --one "$TMP"` (پرچم نو؛ رفتار
  فعلی بدون پرچم دست‌نخورده می‌ماند). دیگر هیچ رانی تبخیر نمی‌شود.
- خط TREND ماشینی در test.log: هر ثانیه از داخل اپ
  `TREND {"t":N,"score":x,"loss":y,"rtt":z,"proj":p}` — پارس در
  build_replay_corpus.py به `trendSeries` کورپوس.
- چرا لازم است (اندازه‌گیری امروز): روی پراکسیِ بسته‌شمارِ فعلی، ۷۲ ترکیب
  window×horizon×floor همگی raw=0.5735 می‌دهند (۱۱ هیت، ۵ کاذب از ۱۷) —
  اهرم مرده. یادگیری slipSlope/floor فقط با سیگنال غنی‌ترِ TREND ممکن
  می‌شود؛ «ثابت→مدل» بدون این داده ادعای بی‌عدد می‌بود.
- `TrendTuner` (فایل نو): برازش floor/slipSlope از trendSeries کورپوسِ
  در حال رشد؛ تا رسیدن داده‌ی کافی، پیش‌فرض‌های v3 — گزارش صادقانه:
  «آموزش‌پذیر شد» فقط وقتی ردیف‌های TREND-دار امتیازش را بالا ببرند.
- هدف: کورپوس ۱۰۰+ ران قبل از بستن v4 (فعلی: ۲۳).

## ۷. پیش‌نیاز حمل‌شده از v2 + دروازه‌های سخت‌افزارخواه

- پراب‌های واقعی resolver (connectivity_plus / network_info_plus پشت
  seam موجود `device_bindings.dart` و `network_name_resolver.dart`) و
  اعتبار ماندگاری مغزها روی Documents در دو لانچ متوالی روی گوشی.
- بلاکر تاریخ‌دار (۲۰۲۶-۰۸-۱۱): ریگ USB/گوشی از این نشست در دسترس نیست؛
  ردیف رسمی ستون ۲، ران روی گوشی، و رشد کورپوس تا ۱۰۰+ به اولین پنجره‌ی
  ریگ موکول — همه‌ی کد و تست واحدش در همین فاز بسته می‌شود تا ران ریگ
  فقط «اجرا و ثبت» باشد.

## ۸. ترتیب اجرا و دروازه‌ی هر گام

```
0  fix baseline red (call_media_adapter fake)      gate: run_gate_loop.sh == GATE LOOP OK
1  budget_calibrator distributional + tests        gate: replay calib >= 1.00 all epochs, total >= 1.0854
2  atlas hour-of-week + transitions + tests        gate: atlas norm >= 1.314 on v3 corpus (no drop)
3  brain_generations promote/rollback + tests      gate: pin tests green
4  narrator 3 intents + golden tests               gate: goldens green
5  sentinel wiring + SLA fields + h2_run TREND     gate: unit tests + fields flow to tsv
6  corpus federation flag in h2_run + recorder     gate: one local dry-run writes a corpus row
7  rig window: official row + phone run + 100+     gate: sentinelLeadMs>0 row + preventedFreezes vs reference
```

### وضعیت اجرا (به‌روز ۲۰۲۶-۰۸-۱۱، حین اجرای شبانه)

```
0  DONE  two missing bufferedAmount overrides (backups 349, 350); GATE LOOP OK, 26 suites
1  DONE  center-aligned hist + wmed (review fix worth +3pp): calib 1.036/1.039/1.044/1.044,
         total 1.107 >= 1.0854, others bit-identical; 13/13 pins; 415/415 package
2  DONE  hour-of-week cells + transition model + resolver onLabelChange seam + hub wiring;
         18/18 atlas pins; replay bit-identical (neutrality proven)
3  DONE  CallHistoryReplay (2/3 -> 1.0 hand-checked) + decideGeneration + nightly runner +
         boot apply; 5/5 package + 5/5 app pins incl. promoted-brains-wake-up
4  DONE  answerIntent x3 with [mN] citations; 12/12 incl. six goldens
5  DONE  SentinelProbe in e2e_support + SLA fields sentinelLeadMs/sentinelWarns/
         preventedFreezes/sentinelFirstGrounds + TREND per-second machine line;
         live-path actions pre-existed (call_session:400 fabric.onUnhealthy->recovery,
         DegradedModeDriver voice-note foresight, playbook failingSoon)
6  DONE  h2_run.sh federates every run via build_replay_corpus.py --one + trendSeries
         parsing; single-run harvest verified idempotent, index stays complete (24 runs)
7  OPEN  tonight's rig runs on the cabled 11 ProMax; TrendTuner training waits for
         TREND-rich corpus rows (measured: packet-proxy corpus is a dead lever — 72
         param combos identical raw 0.5735)
```

هیچ صفتی بدون عدد: هر ادعای این سند یا اندازه‌گیری امروز است یا با
file:line لنگر دارد؛ ادعاهای آینده فقط با verifier همان گام ثبت می‌شوند.
