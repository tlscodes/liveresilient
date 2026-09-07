# VoiceCallKit — وضعیت پروژه و پرونده‌ی پرسش برای مرور بعدی

تاریخ: ۲۰۲۶-۰۷-۲۷
شاخه: `main` · آخرین کامیت: `06a69c3`

این فایل دو کار می‌کند: وضعیتِ سنجیده‌ی پروژه را ثبت می‌کند، و پرسش‌هایی
را که باید از یک مرورگرِ تازه پرسیده شود جمع می‌کند. هر عددی که اینجا
آمده از خروجیِ یک ابزار گرفته شده، نه از حافظه؛ هرجا چیزی سنجیده نشده،
صریح گفته شده است.

---

## ۱. اپلیکیشن در یک نگاه

یک کیتِ تماسِ صوتی و تصویری برای شبکه‌های ضعیف، ناپایدار و مسدود.
رسانه روی WebRTC است، سیگنالینگ روی WSS، و پیکربندی یک مانیفستِ
امضاشده‌ی Ed25519. فقط پروتکل‌های استاندارد — این محدودیت با
`tool/architecture_guard.dart` در CI اجباری شده است.

ایده‌ی مرکزی: تماس نباید «قطع» شود، باید «تنزل» کند. وقتی مسیرِ زنده
می‌میرد، فابریکِ اتصال به لِین‌های پشتیبان سوییچ می‌کند و در بدترین حالت
تماس به حالتِ بقا می‌رود — پیامِ صوتیِ فشرده روی هر پهنای باندی که مانده.

```
scale:   658 tracked files · 387 Dart files · 18 packages + 1 app
```

---

## ۲. معماری، لایه به لایه

```
apps/reference_app          UI + wiring (Flutter)
  └─ call_session.dart      production composition root

packages/
  call_core                 call state machine, phases, recovery policy
  media_webrtc(+_flutter)   WebRTC media ports
  signaling / *_adapter     WSS signaling + adapters
  connection_orchestrator   ConnectionFabric: lane ranking, failover, DTN queue
  adaptive_transport        the lanes themselves + probe defense + framing
  device_link               DTN bundle queue, durable store, consent
  hamseda_codec             ultra-low-bitrate voice codec (31.8 bps warm floor)
  live_captions             on-device captions
  messaging(+adapter)       chat over the call's own data channel
  security / _keychain      identity keys, TOFU trust store, key storage
  signed_config             Ed25519-signed manifest verification
  privacy_telemetry         opt-in only telemetry
  on_device_assistant       local assistant surface

tools/cloudflare_relay_worker    border relay (deployed)
tools/workspace_gate.sh          local gate mirroring CI
```

### فابریکِ اتصال — قلبِ تابآوری

`ConnectionFabric` تنها مالکِ همه‌ی مسیرهاست. هر لِین ثبت می‌شود، امتیازِ
سلامتِ زنده می‌گیرد، و رتبه‌بندی می‌شود. تحویل به ترتیب: بهترین لِین، بعد
بقیه، بعد صفِ تحملِ تأخیر.

```
webrtc-media        the live path
resilient.udp       direct UDP
resilient.wss       WebSocket relay      (cost 1)
resilient.https     HTTP long-poll       (cost 2)
resilient.mesh      local peer link      (cost 3, consent-gated)
```

یک تصمیمِ طراحیِ کلیدی: لِینی که endpoint ندارد اصلاً ثبت نمی‌شود. لِینِ
بی‌مقصد از دیدِ رتبه‌بند سالم به نظر می‌رسد ولی رسانه را می‌بلعد — بدتر از
نبودنِ لِین.

### رله‌ی مرزی — مستقر و فعال

```
voice-call-relay.tlscodes-com.workers.dev
```

Cloudflare Worker با Durable Object. دو همتای یک نشست را جفت می‌کند و
بایت‌ها را بی‌کم‌وکاست عبور می‌دهد — نه پارس می‌کند، نه قاب‌بندی را عوض
می‌کند، نه ترتیب را. حالت در Durable Object است چون جفت‌کردنِ دو همتا یک
نقطه‌ی مشترک می‌خواهد که ورکرِ بدونِ حالت ندارد.

```
GET  /ws?session=<id>&role=<a|b>     websocket relay
POST /http?session=<id>&role=<a|b>   send frames
GET  /http?...&wait=<ms>             long-poll (204 when empty)
HEAD /http?...                       liveness (never consumes a frame)
GET  anything else                   plain HTML page, 200
```

مرزها: ۲۵۶ قاب و ۴ مگابایت در هر جهت؛ وقتی پر شد قدیمی‌ترین حذف می‌شود
چون این ترافیک رسانه‌ی زنده است. long-poll حداکثر ۲۵ ثانیه باز می‌ماند.

---

## ۳. وضعیت تست — سنجیده، نه تخمینی

خروجیِ `tools/workspace_gate.sh`، آخرین اجرا:

```
adaptive_transport             434 passed
call_core                      139 passed
call_media_adapter              10 passed
call_signaling_adapter          61 passed
connection_orchestrator        207 passed
device_link                    114 passed
hamseda_codec                   12 passed
live_captions                   31 passed
media_webrtc_flutter            11 passed
media_webrtc                    82 passed
messaging_webrtc_adapter        10 passed
messaging                       37 passed
on_device_assistant             12 passed
privacy_telemetry               23 passed
security_keychain               11 passed
security                        75 passed
signaling                       95 passed
signed_config                  133 passed
reference_app                  135 passed
---------------------------------------------
TOTAL PASSED: 1632          exit code 0, zero failures

repo-wide gates:
  dart format --set-exit-if-changed .          OK
  dart analyze --fatal-infos --fatal-warnings  OK
  dart run tool/architecture_guard.dart        OK  (186 files scanned)
  node --check + wrangler deploy --dry-run     OK  (bundle 6.95 KiB)
```

### CI

`.github/workflows/ci.yml` — چهار کار موازی:

- **gate**: format · analyze(infos fatal) · test با پوشش · architecture guard
- **hygiene**: اسکنِ کلیدهای لو رفته
- **deps**: ممیزیِ آسیب‌پذیری با OSV
- **relay**: `node --check` و dry-run دیپلویِ ورکر

مدارکِ ممیزی: نتیجه‌ی JSON هر بسته و یک `lcov.info` یکپارچه، ۹۰ روز
نگهداری، با `if-no-files-found: error` تا نبودِ مدرک بیلد را قرمز کند.

---

## ۴. کارِ این جلسه — یازده کامیت

```
7e443f8  gRPC receive cap + no overlapping wire flushes
cc3e50f  gRPC compression flag + platform-correct stack profiles
c3a8821  register the resilient fallback lanes with the live call
f98c98b  env-driven lane config + drain the backlog through every lane
8b935c0  the border relay worker
fdb187a  default the WAN lanes to the deployed relay
980b153  dart format across the workspace
e834737  CI gate for the relay worker
1448f9f  docs + fix the test counter
0fb3fa3  kill the flaky timing test, secure session ids, audit artifacts
06a69c3  mint the call id in the UI and present it as a secret
```

### نقص‌های واقعی که پیدا و رفع شدند

۱. **هدرِ طولِ gRPC بی‌سقف بود.** تا چهار گیگابایت پذیرفته می‌شد؛ یک طرفِ
مقابل می‌توانست خواننده را وادار کند بی‌نهایت بافر کند برای پیامی که هرگز
کامل نمی‌شود. سقفِ چهار مگابایتیِ خودِ gRPC اعمال شد.

۲. **`flushWireTick` نگهبانِ هم‌زمانی نداشت.** دو فراخوانِ روی‌هم‌افتاده
قاب‌هایشان را لای هم روی سیم می‌نوشتند. حالا خطا می‌دهد به‌جای به‌هم‌ریختنِ
ترتیب.

۳. **بایتِ فشرده‌سازی در مسیرِ زنده اصلاً خوانده نمی‌شد.** یک همتای
استانداردِ gRPC که فشرده بفرستد، بدنه‌اش به‌عنوانِ خام بالا می‌رفت.

۴. **ثابت‌های socket فقط لینوکسی بودند.** روی مک و ویندوز گزینه‌ی ۲ در
سطحِ IPv4 اصلاً TTL نیست. ضمناً تابعِ اعمال‌کننده هیچ فراخوانی نداشت و
خطاها بلعیده می‌شدند.

۵. **چهار لِینِ پشتیبان در اپ ثبت نمی‌شدند.** منطقشان تست‌شده بود ولی
هیچ فایلِ غیرتستی صدایشان نمی‌زد — یعنی در تماسِ واقعی failover وجود
نداشت.

۶. **`refresh()` صف را فقط از راهِ بهترین لِین تخلیه می‌کرد.** لِینی که
تازه مرده چند نوبت هنوز رتبه‌ی اول را دارد، پس صف پارک می‌ماند در حالی که
لِینِ سالم بی‌کار بود. این را تستِ E2E پیدا کرد.

۷. **تستِ ناپایدار.** علتش ریسِ کاندیشن نبود؛ یک بودجه‌ی زمانیِ ساعتِ
دیواری بود که زیرِ بار، زمان‌بندِ سیستم را می‌سنجید. حالا کم‌ترینِ پنج دور
گرفته می‌شود. قبل: چهار شکست از شش اجرا. بعد: شش از شش سبز.

### شناسه‌ی امنِ تماس

```
newSecureCallId()  ->  128 bits from Random.secure(), base64url, 22 chars
```

شناسه‌ی تماس همان شناسه‌ی نشستِ رله است، پس یک رمز است: هرکس آن را داشته
باشد می‌تواند به‌جای طرفِ غایب وصل شود. رابطِ کاربری آن را با برچسبِ
«Call key» و هشدارِ صریح نشان می‌دهد و در پایانِ تماس پنهانش می‌کند.

---

## ۵. کارهای باز — با دلیل، نه با سکوت

| # | مورد | چرا باز است |
|---|---|---|
| ۱ | تماسِ واقعیِ دو دستگاهه با قطعِ عمدیِ WebRTC | تنها راهِ اثباتِ عبورِ رسانه از رله‌ی واقعی؛ تست‌های loopback نمی‌توانند |
| ۲ | رسانه‌ی بومی (`flutter_webrtc`) | نیازمندِ Xcode کامل؛ فقط CommandLineTools نصب است |
| ۳ | ذخیره‌سازیِ کلید در Keychain/Keystore | وابسته به پوسته‌ی اپ |
| ۴ | لِینِ UDP بدونِ مقصد | رله فقط HTTP و WebSocket می‌فهمد؛ یک نقطه‌ی رسانه‌ی مستقل لازم است |
| ۵ | وضعیتِ فازها در README ریشه | تاریخِ ۲۰۲۶-۰۷-۱۶ دارد و از واقعیت عقب است |

---

## ۶. پرسش‌ها، پیشنهادها و ایده‌ها برای مرورِ بعدی

هر بند یک پرسشِ باز است که پاسخش معماری را تغییر می‌دهد. اینها برای پرسیدن
از یک مرورگرِ تازه نوشته شده‌اند.

### الف — رله و توپولوژی

۱. رله‌ی فعلی یک نقطه‌ی شکستِ واحد و یک نقطه‌ی مسدودسازیِ واحد است. اگر آن
   دامنه مسدود شود کلِ لِینِ WAN می‌میرد. آیا باید به چند رله با کشفِ پویا
   برویم، و آن فهرست چطور به دستگاهی می‌رسد که همین حالا مسدود است؟

۲. رله هویتِ کسی را تأیید نمی‌کند و شناسه‌ی نشست تنها کنترلِ دسترسی است.
   آیا احرازِ هویت در سطحِ رله ارزشش را دارد، با توجه به اینکه محموله
   پیش از رسیدن به رله مهر شده و رله فقط متنِ رمزشده می‌بیند؟

۳. صفحه‌ی ساده‌ی HTML برای مسیرهای ناشناخته کافی است یا باید رفتارِ
   زمانی و اندازه‌ی پاسخ هم شبیهِ یک میزبانِ معمولی باشد؟ پرسشِ دقیق‌تر:
   آیا الگوی زمانیِ long-poll به‌تنهایی قابلِ تشخیص است؟

۴. Durable Object در طرحِ رایگان محدودیت دارد و ۱۰۰ هزار درخواست در روز
   سقفِ ورکر است. با یک تماسِ فعال که هر ۲۵ ثانیه poll می‌کند، سقفِ
   واقعیِ تعدادِ کاربرِ هم‌زمان چقدر است و بعد از آن چه؟

### ب — نرخِ پایین و کدک

۵. یک قابِ چهاربایتی با هدرِ پنج‌بایتیِ gRPC نه بایت می‌شود — بیش از دو
   ثانیه از یک لینکِ ۳۱.۸ بیت بر ثانیه. آیا ارزشش را دارد که برای لِینِ
   long-poll چند قاب در یک بدنه دسته‌بندی شود، و اثرش بر تأخیرِ صدا چیست؟

۶. کدکِ hamseda در کفِ گرمِ ۳۱.۸ بیت بر ثانیه کار می‌کند. این عدد روی
   ضبطِ واقعی سنجیده شده ولی هنوز روی یک تماسِ زنده‌ی واقعی نه. آزمونِ
   درست برای اثباتش چیست؟

۷. در حالتِ بقا، کیفیتِ قابلِ فهم بودنِ صدا چطور سنجیده شود؟ عددی مثل
   نرخِ بیت چیزی درباره‌ی قابلِ فهم بودن نمی‌گوید.

### ج — امنیت و حریمِ خصوصی

۸. شناسه‌ی تماس یک رمزِ مشترک است که کاربر باید دستی منتقلش کند. آیا
   مکانیزمِ بهتری هست که هم امن باشد و هم برای کاربرِ غیرفنی قابلِ
   استفاده — مثلاً کدِ کوتاهِ زمان‌دار به‌جای رشته‌ی ۲۲ کاراکتری؟

۹. اگر کاربر گوشی‌اش را از دست بدهد، چه چیزی بازیابی‌پذیر است و چه چیزی
   برای همیشه رفته؟ این باید قبل از انتشار پاسخ داشته باشد.

۱۰. مدلِ تهدید فرض می‌کند ناظر می‌تواند ترافیک را ببیند و مسدود کند. آیا
    فرضِ «ناظر می‌تواند یک همتا را وادار به همکاری کند» هم باید در مدل
    باشد؟

### د — کیفیت و فرآیند

۱۱. پوشش تست الان اندازه‌گیری و در CI بارگذاری می‌شود ولی هیچ آستانه‌ای
    ندارد. آیا باید آستانه بگذاریم، و اگر بله روی کدام بسته‌ها؟

۱۲. یک تستِ ناپایدار در این جلسه پیدا شد که علتش بودجه‌ی زمانیِ
    ساعتِ دیواری بود. آیا تست‌های زمان‌محورِ دیگری هست که همان مشکل را
    داشته باشند و هنوز شکست نخورده‌اند؟

۱۳. `dart format` روی ۶۱ فایل قرمز بود، یعنی CI مدتی روی main قرمز
    می‌مانده. آیا کسی خروجیِ CI را می‌بیند؟ نوتیفیکیشن لازم است؟

### ه — محصول

۱۴. رابطِ کاربریِ فعلی یک نمایشِ ساده است و تماسِ واقعی فقط از مسیرِ
    توسعه در دسترس است. کوچک‌ترین محصولِ قابلِ استفاده از اینجا چیست:
    صفحه‌ی پیوستن با کلید، یا نمایشِ وضعیتِ زنده‌ی مسیرها؟

۱۵. آیا این کیت قرار است یک اپلیکیشنِ مستقل باشد یا کتابخانه‌ای که
    محصولاتِ دیگر آن را جاسازی می‌کنند؟ پاسخ، شکلِ لایه‌ی رابطِ کاربری را
    تعیین می‌کند.

---

## ۷. دستورهای بازتولید

```
bash tools/workspace_gate.sh                     # everything, one pass

cd apps/reference_app
flutter test test/fallback_lane_failover_e2e_test.dart
flutter test test/call_id_wiring_test.dart

cd packages/connection_orchestrator
dart test test/cloudflare_relay_protocol_test.dart
dart test test/resilient_fallback_lanes_test.dart

cd tools/cloudflare_relay_worker
npx wrangler deploy --dry-run --outdir=dist
curl https://voice-call-relay.tlscodes-com.workers.dev/health
```
