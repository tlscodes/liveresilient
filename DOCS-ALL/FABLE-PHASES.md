# FABLE-PHASES

خلاصه‌ی فازهای اجرایی بلوپرینت نسخه‌ی سه؛ برای هر فاز هدف و شرطِ خروجِ اندازه‌پذیر آورده شده است. این سند فقط تعریفِ فازهاست؛ هیچ فازی در خودِ بلوپرینت با تاریخ یا خروجی فرمان به‌عنوانِ بسته‌شده ثبت نشده است — همه تعریف‌شده ولی باز هستند.

## فاز صفر — فریز، بیس‌لاین و صداقت مستندات

هدف: ساختن نقطه‌ی شروعِ قابلِ بازگشت و حذف هر ادعای اثبات‌نشده از مستندات؛ ثبت وضعیت فعلی و اصلاح ریدمی.
شرط خروج: هر ادعای ریدمی به کد یا تست یا آرتیفکت واقعی متصل باشد؛ اسنپ‌شاتِ بازگشت‌پذیر وجود داشته باشد؛ هیچ قابلیتِ فرضی تحویل‌شده معرفی نشود.

## فاز یک — بنیانِ قابلِ ساخت و سی‌آی

هدف: تبدیل اسکلت فعلی به ورک‌اسپیسِ قابلِ کامپایل؛ تعریفِ واحد برای وضعیت تماس و سیاست اتصالِ مجدد، رفع اکسپورت‌های تکراری، پین‌کردن اس‌دی‌کی و راه‌اندازی سی‌آی.
شرط خروج به‌صورت مکانیکی:

```text
flutter pub get                        PASS
dart format --set-exit-if-changed .    PASS
dart analyze                           0 error
flutter test                           PASS
architecture_guard                     PASS
```

هیچ فاز بعدی پیش از سبزشدن این گیت شروع نمی‌شود.

## فاز دو — تست قطعی هسته و رفع باگ‌های هم‌زمانی

هدف: تثبیت الگوریتم‌ها پیش از اتصال به شبکه‌ی واقعی؛ ساعتِ تزریقی، تست کامل ماشین وضعیت، بازپخش، صف خروجی و کانفیگ امضاشده، به‌همراهِ پراپرتی‌تست‌ها.
شرط خروج:

```text
line coverage   >= 85%  (stateful modules)
branch coverage >= 75%  (state machine / outbox / signed config)
real timers in unit tests = 0
multi-seed runs without flake
```

## فاز سه — نخستین برشِ عمودی قابلِ اجرا

هدف: برقراری یک تماس صوتی واقعی میان دو دستگاه با اپ مرجع، سرور سیگنالینگ حداقلی و یک ریلی استاندارد، پیش از افزودن پیچیدگی.
شرط خروج:

```text
100 setup/teardown cycles, zero leak
10 calls x 30 min, no state lock
successful call on two real devices
TURN fallback proven
SDP/token/key in logs = 0
```

## فاز چهار — پایه‌ی امنیت و هویت

هدف: تبدیل واسط‌های امنیتی به کنترل واقعی و قابلِ ممیزی؛ نگه‌داری کلید در مخزن امن پلتفرم، چرخش کلید، ضدبازپخش و ضدبازگشت مانیفست؛ با مرزبندی صریح درباره‌ی ادعای رمزنگاریِ سرتاسری در تماس گروهی.
شرط خروج:

```text
tampered manifests rejected = 100%
tested replays rejected     = 100%
secrets in public storage or logs = 0
threat model + data-flow diagram complete
```

## فاز پنج — کیفیت و پایداری رسانه

هدف: افزایش کیفیت تماس با تکیه بر قابلیت‌های استاندارد وب‌آرتی‌سی نه بازسازی آن‌ها؛ سیاست صوتِ اولویت‌دار، تطبیق ویدئو و پرهیز از فعال‌سازی پیش‌فرضِ اف‌ای‌سی اختصاصی.
شرط خروج در شبکه‌ی آزمایشگاهی:

```text
normal network:      setup success >= 99%, setup P95 < 6s
10% loss / 80ms jitter / 300ms RTT: setup success >= 95%, degrade to audio-only, no crash
30-40% loss:         graceful degradation + recovery + accurate report; deadlock/crash = 0
```

## فاز شش — تداوم مسیر و تنوع ریلی

هدف: حفظ تماس هنگام خرابی یک مسیر یا یک منطقه‌ی زیرساختی؛ استخر ریلی چندمنطقه‌ای، امتیازدهی مسیر با هیسترزیس و ازسرگیری سیگنالینگ.
این فاز یک پیش‌گیتِ الزامی هزینه دارد: بدون سقف بودجه‌ی مکتوب و هشدارِ فعالِ هزینه نزد ارائه‌دهنده، شروعِ فاز ممنوع است.
شرط خروج:

```text
one signaling node removed  -> service continues
one TURN region removed     -> new calls shift region
Wi-Fi -> mobile recovery    P95 <= 8s
duplicate signaling does not corrupt call state
path oscillation controlled at boundaries
```

## فاز هفت — کشفِ امضاشده‌ی اندپوینت‌ها

هدف: به‌روزرسانی امن اندپوینت‌ها بدون وابستگی به یک مبدأ واحد؛ دستِ‌کم دو مبدأ استاندارد، مانیفست امضاشده با نسخه و انقضا و شناسه‌ی کلید، کشِ آخرین نسخه‌ی معتبر و بدون دانلود کد اجرایی.
شرط خروج:

```text
origin-1 failure covered by origin-2
offline: last-known-good works within validity
older or tampered manifest never accepted
key rotation tested without outage
```

## فاز هشت — بازگرداندن ارزش‌های مفید نسخه‌ی قدیم

هدف: بازگشتِ واقعی و محدودِ سه قابلیت پروتوتایپیِ قدیم — بیدارسازی با پوش، حمل‌ونقل نزدیک و انتشار محلی — به‌علاوه‌ی سیاست کیفیت شبکه؛ پوش هرگز منبع حقیقتِ وضعیت تماس نیست و لایه‌ی محلی ستون فقرات تماس جهانی معرفی نمی‌شود.
شرط خروج:

```text
duplicate push  -> no duplicate call
expired push rejected
duplicate local envelope not reprocessed
TTL + quota honored in 5/10/20-device tests
battery measured vs baseline
no gateway -> local-only mode explicit
```

## فاز نه — یکپارچگی واقعی موبایل و تجربه‌ی کاربر

هدف: اتصال درست به چرخه‌ی حیات اندروید و آی‌اواس — سرویس تماس، فوکوس صدا، مسیردهی بلوتوث، کال‌کیت و مدیریت وقفه — و رابطِ صادق درباره‌ی وضعیت اتصال و حریم خصوصی.
شرط خروج:

```text
tested on >= 2 major Android + >= 2 major iOS versions
wired headset / Bluetooth / speaker tested
background-foreground + lock screen tested
incoming call vs cellular call tested
permission loops = 0
```

## فاز ده — مشاهده‌پذیری، عملیات و کنترل سوءاستفاده

هدف: تله‌متریِ محدود و بدونِ داده‌ی حساس، داشبوردهای عملیاتی، ران‌بوک‌ها و کنترل‌های سوءاستفاده مانند محدودسازی نرخ و ابطال دستگاه.
شرط خروج:

```text
automated no-secret-in-log test
runbooks complete
test alert fired successfully
manifest rollback possible
cost dashboard active
```

## فاز یازده — آشوب، مقیاس، ممیزی و انتشار تدریجی

هدف: رشد پله‌ای بار، تست‌های آشوب زیرساختی، ممیزی امنیتی مستقل و انتشار مرحله‌ای با بازگشتِ خودکار.
شرط خروج به‌صورت پلکان انتشار است و هر پله یک بازه‌ی مشاهده‌ی کامل دارد:

```text
load: 100 -> 1,000 -> 10,000 signaling connections (higher only after bottleneck analysis)
release: internal dogfood -> 1% -> 5% -> 25% -> 50% -> 100%
auto-rollback on predefined criteria
```

---

## نردبان تست تدریجی

عبور از هر سطح فقط پس از سبزشدن سطح قبلی مجاز است.

```text
G0  static analysis        compile / lint / architecture / dependency
G1  unit deterministic     state machine, score, outbox, crypto wrapper
G2  simulated network      loss, jitter, reorder, timeout (fake clock)
G3  loopback               signaling + media on one machine
G4  two real devices       LAN, mobile, TURN
G5  impaired network       loss/jitter/RTT/bandwidth matrix
G6  infra failure          region outage, node restart, DNS failure
G7  local continuity       discovery, dedup, TTL, battery
G8  load/soak              100 / 1,000 / 10,000 sessions
G9  canary                 limited real users with rollback
G10 production             SLO, incident response, periodic audit
```

## اهداف سرویس اولیه

این اعداد پس از ساخت برش عمودی روی دستگاه واقعی بازتنظیم می‌شوند؛ عددی که فقط در شبیه‌ساز پاس شود هدفِ تولیدی نیست.

```text
crash-free call sessions        >= 99.9%
call setup success (normal)     >= 99%
call setup P95 (normal)         <= 6s
recovery after network switch   P95 <= 8s
one-way audio sessions          <  0.5%
tampered manifest accepted      =  0
known replay accepted           =  0
secret leaked in logs           =  0
total failure on one signaling node loss = 0
battery regression              <= 10% vs baseline
```

## خط برش منابع

بلوپرینت دو رژیم اجرایی دارد و صداقت درباره‌ی مرزشان بخشی از خودِ پلن است.
رژیم تک‌نفره فقط تا پایان نسخه‌ی دو-دو واقع‌بینانه است؛ فازهای شش به بعد در این رژیم صرفاً سندِ برنامه‌ریزی‌اند نه تعهد.
رژیم تیمی پیش‌نیازِ نسخه‌های بعدی است.

```text
v2.1.0  solo feasible, rough estimate 2-4 weeks full-time
v2.2.0  solo feasible, rough estimate 6-10 weeks full-time (minimal signaling + single-region coturn)
v2.3.0+ team regime: 3-5 people (mobile, backend/infra, security) + ongoing infra budget
v3.0.0  requires funded independent security audit + pentest before commitment
```

قاعده: هیچ نسخه‌ای وارد اجرا نمی‌شود مگر منابع همان نسخه صریحاً تأمین و ثبت شده باشد.

## نقشه‌ی نسخه‌ها

```text
v2.1.0  Foundation              green build, export conflicts fixed, CI, core tests, race/timeout bugs fixed
v2.2.0  Secure Audio Alpha      reference app, real signaling, coturn, two-device audio call, secure storage, signed manifest
v2.3.0  Network Resilience Beta multi-region relay, ICE restart, path scoring, impairment suite, telemetry privacy
v2.4.0  Local Continuity Beta   PushWakeup, NearbyTransport, local discovery, bounded dissemination, battery tests
v3.0.0  Audited Production      full mobile lifecycle, load+chaos, independent audit, runbooks, canary, SLO+rollback
```

## تعریف نهایی انجام‌شدن

نسخه‌ی نهایی فقط زمانی آماده‌ی انتشار است که همه‌ی موارد زیر برقرار باشند:

```text
all packages compile
real app makes a two-way call
at least one real signaling + TURN deployment exists
no critical security interface left unimplemented
unit / integration / device / impairment / chaos tests green
docs exactly match code state
threat model + privacy review complete
no E2EE claim for group calls without proper implementation
rollback + incident response actually exercised
independent security audit done, critical findings closed
```
