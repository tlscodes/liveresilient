# `UPGRADE_BLUEPRINT_V3.md`

# VoiceCallKit V3  

## بلوپرینت ارتقای تماس خصوصی، پایدار و چندمسیره در شبکه‌های ناپایدار

## ۱. مأموریت محصول

ساخت یک SDK و اپ تماس صوتی/تصویری که در شرایط زیر به‌صورت قابل‌اندازه‌گیری پایدار بماند:

- packet loss و burst loss؛

- jitter و RTT بالا؛

- جابه‌جایی میان Wi‑Fi و شبکه موبایل؛

- خرابی یک یا چند سرور signaling یا relay؛

- NAT و CGNAT پیچیده؛

- قطع موقت بخشی از زیرساخت؛

- نبود اینترنت عمومی، در صورتی که یک مسیر محلی واقعی مانند Wi‑Fi Direct یا شبکه محلی میان دستگاه‌ها وجود داشته باشد.

### تعریف صادقانه هدف

هدف، «ارتباط خصوصی و با دسترس‌پذیری بالا در شبکه‌های دشوار» است؛ نه وعده‌های غیرقابل‌اثباتی مانند:

- غیرقابل‌هک بودن؛

- غیرقابل‌مسدود شدن تحت هر شرایط؛

- تماس جهانی در زمان جدایی کامل فیزیکی دو شبکه؛

- کیفیت کامل در ۴۰٪ packet loss پایدار.

اگر دو ناحیه هیچ مسیر فیزیکی مشترکی نداشته باشند—اینترنت، gateway محلی، ماهواره، PSTN یا مسیر دیگری—هیچ نرم‌افزاری نمی‌تواند میان آن‌ها تماس جهانی برقرار کند. در چنین حالتی، `NearbyTransport` فقط ارتباط داخل همان جزیره شبکه‌ای را حفظ می‌کند.

### Non-goals صریح (خارج از دامنه v3.0.0)

موارد زیر عمداً ساخته نمی‌شوند و هیچ فاز، گیت یا ادعایی به آن‌ها متصل نیست:

- تماس گروهی و SFU: هیچ فازی SFU نمی‌سازد. تا زمان پیاده‌سازی و ممیزی SFrame/MLS یا معادل استاندارد (زودتر از v4 نخواهد بود)، هر ادعای E2EE گروهی ممنوع است؛

- اتصال PSTN و شماره تلفن؛

- پیام‌رسانی متنی کامل (chat product)؛ signaling پیام کوتاه حمل می‌کند، نه مکالمه متنی؛

- federation با شبکه‌ها یا سرورهای شخص ثالث؛

- ضبط تماس، voicemail و transcription؛

- کشف کاربر ناشناخته (public directory / جستجوی global)؛ آدرس‌دهی فقط طبق «مدل هویت و آدرس‌دهی کاربر» در §۵؛

- هر مکانیزم دورزدن مسدودسازی به‌عنوان قابلیت هسته (مطابق §۳: حذف domain fronting و موتورهای proxy غیراستاندارد از هسته).

هر قابلیتی که در این فهرست است و در آینده لازم شود، ابتدا باید به‌صورت RFC جدا با threat model و برآورد منابع خودش وارد بلوپرینت شود، نه به‌صورت خزش دامنه در میانه یک فاز.

---

## ۲. اصول غیرقابل‌مذاکره

### ۲.۱. شفافیت فنی

- نام هر کلاس و ماژول باید رفتار واقعی آن را بیان کند.

- مستندات نباید امکاناتی را که build و test نشده‌اند، «تحویل‌شده» معرفی کنند.

- عبارت‌های «آماده انتشار»، «Enterprise-Grade» یا «E2EE» فقط بعد از وجود شواهد اجرایی استفاده شوند.

- تغییر نام صرفاً برای تأثیرگذاری بر رفتار یک مدل یا بررسی خودکار، معیار معماری نیست.

### ۲.۲. استانداردها پیش از پروتکل اختصاصی

هسته محصول بر استانداردهای عمومی ساخته شود:

- WebRTC؛

- ICE؛

- STUN؛

- TURN روی UDP، TCP و TLS؛

- DTLS-SRTP؛

- WSS و HTTPS برای signaling و control plane؛

- Opus برای صوت؛

- codecهای ویدئویی پشتیبانی‌شده توسط پلتفرم؛

- FCM/APNs صرفاً برای wake-up و اعلان تماس.

### ۲.۳. عدم ساخت رمزنگاری اختصاصی

- الگوریتم رمزنگاری جدید طراحی نشود.

- از کتابخانه‌های ممیزی‌شده و primitiveهای استاندارد استفاده شود.

- کلیدها در Android Keystore و iOS Keychain نگه‌داری شوند.

- تفاوت «رمزنگاری مسیر» و «رمزنگاری سرتاسری» در docs روشن باشد.

### ۲.۴. قابلیت اندازه‌گیری

هر ادعای پایداری باید به موارد زیر متصل باشد:

- سناریوی تست؛

- نسخه کد؛

- دستگاه و سیستم‌عامل؛

- شرایط شبکه؛

- معیار قبولی؛

- خروجی CI یا گزارش آزمایش.

### ۲.۵. حفظ حریم خصوصی

- هیچ SDP کامل، access token، push token، کلید، آدرس تماس یا شناسه مخاطب در log ثبت نشود.

- telemetry به‌صورت opt-in، حداقلی و قابل خاموش‌کردن باشد.

- داده محتوای صوت و تصویر هرگز وارد telemetry نشود.

---

# ۳. اصلاح بلوپرینت قبلی

| ایده قبلی | تصمیم جدید | دلیل |

|---|---|---|

| EWMA، jitter smoothing و hysteresis | حفظ و تست شود | بخش ارزشمند طراحی موجود است |

| Fanout برای همه داده‌ها | برای signaling/config قابل استفاده؛ برای media محدود | ارسال چندنسخه‌ای media باعث مصرف پهنای‌باند، reordering و battery drain می‌شود |

| XOR FEC اختصاصی | فقط experimental | WebRTC و Opus امکانات استاندارد FEC، NACK، RTX و concealment دارند |

| JitterBuffer اختصاصی | فقط برای مسیر غیر-WebRTC | WebRTC خودش jitter buffer دارد؛ دو buffer پشت‌سرهم latency را بدتر می‌کند |

| Gossip محلی | محدود به discovery، signaling و داده کوچک | انتشار media روی gossip چندهاپی از نظر توان، حریم خصوصی و کیفیت پرریسک است |

| PushChannel | به `PushWakeup` تبدیل شود | push برای wake-up و invite مناسب است، نه حمل media |

| Dynamic provisioning | به signed multi-origin endpoint discovery تبدیل شود | پایدارتر، قابل ممیزی و مطابق استانداردهای CDN است |

| Domain fronting | از بلوپرینت حذف شود | شکننده، اغلب خلاف سیاست ارائه‌دهنده و از نظر عملیاتی نامطمئن است |

| موتورهای proxy غیر استاندارد در هسته | از هسته خارج شود | اگر نیاز تجاری مشروعی وجود دارد، باید افزونه‌ای مستقل با بررسی حقوقی و امنیتی باشد |

| صرف ۳۰٪ زمان برای بازنویسی روایت | به کمتر از ۵٪ کاهش یابد | مشکل اصلی پروژه build، wiring، implementation و test است |

| «قانونی بودن» در README | حفظ شود ولی کنترل امنیتی محسوب نشود | یک جمله در docs جای threat model، audit یا access control را نمی‌گیرد |

---

# ۴. وضعیت پایه فعلی

طبق بازبینی ارائه‌شده، نسخه فعلی این وضعیت را دارد:

- حدود ۶٬۴۴۸ خط Dart؛

- ۸ پکیج؛

- صفر تست واقعی؛

- نبود اپ reference؛

- نبود server و infra قابل اجرا؛

- نبود implementation واقعی برای چند interface امنیتی؛

- نبود dependency واقعی WebRTC و cryptography؛

- پکیج‌ها از نظر معماری جدا هستند ولی عملاً به هم سیم‌کشی نشده‌اند.

## Release Blockerهای شناخته‌شده

1. تعارض export در `call_core`:

   - دو تعریف برای `CallState`؛

   - دو تعریف برای `ReconnectPolicy`.

2. race در `rtc_stats_sampler.dart`:

   - `Timer.periodic` همراه callback asynchronous می‌تواند `_tick`های هم‌زمان ایجاد کند.

3. قفل دائمی negotiation:

   - `_negotiating` باید timeout، `try/finally` و recovery path داشته باشد.

4. Circuit breaker ناقص:

   - در حالت open نباید یک success تصادفی cooldown را دور بزند؛ باید half-open probe کنترل‌شده وجود داشته باشد.

5. خطای redaction:

   - تشخیص شماره تلفن و IPv4 نباید با ترتیب regexها باعث برچسب اشتباه شود.

6. `architecture_guard.dart`:

   - باید workspace root را مستقل از current working directory پیدا کند.

7. کدهای export‌شده ولی بی‌مصرف:

   - `AdaptiveJitterBuffer` و `XorFec` یا باید واقعاً یکپارچه شوند یا experimental/internal باقی بمانند.

---

# ۵. معماری هدف

```text

Flutter Reference App

│

├── CallCoordinator

│   ├── Call state machine

│   ├── Lifecycle management

│   ├── Reconnect policy

│   └── Cancellation and timeout control

│

├── MediaSession

│   ├── WebRtcMediaAdapter

│   ├── Audio adaptation

│   ├── Video adaptation

│   ├── RTC stats

│   └── Media security state

│

├── SignalingClient

│   ├── WSS primary path

│   ├── HTTPS fallback

│   ├── Reliable outbox

│   ├── ACK/idempotency

│   └── Reconnect and resume

│

├── PathManager

│   ├── Direct ICE candidates

│   ├── TURN relay pools

│   ├── Path health scoring

│   ├── ICE restart coordinator

│   └── Network transition monitor

│

├── Trust Layer

│   ├── Device identity

│   ├── Secure key storage

│   ├── Signed endpoint manifest

│   ├── Anti-replay

│   └── Anti-rollback

│

├── Continuity Extensions

│   ├── PushWakeup

│   └── NearbyTransport

│

└── Privacy-Preserving Telemetry

    ├── Local debug metrics

    ├── Redaction

    ├── Sampling

    └── Explicit user consent

```

## ساختار مخزن هدف

```text

apps/

  reference_app/

packages/

  call_core/

  media_webrtc/

  adaptive_transport/

  signaling/

  security/

  signed_config/

  device_link/

  telemetry/

server/

  signaling/

infra/

  turn/

  monitoring/

integration_test/

  device_pair/

  network_impairment/

  regional_failover/

tool/

  architecture_guard/

  network_lab/

  release_checks/

docs/

  ARCHITECTURE.md

  THREAT_MODEL.md

  SECURITY.md

  PRIVACY.md

  OPERATIONS.md

  NETWORK_TEST_MATRIX.md

  INCIDENT_RESPONSE.md

  LIMITATIONS.md

```

## مدل هویت و آدرس‌دهی کاربر (پیش‌نیاز فاز ۳)

بدون پاسخ به «دو کاربر چطور همدیگر را پیدا می‌کنند»، فاز ۳ فقط میان دو دستگاه ازپیش‌جفت‌شده کار می‌کند. مدل تدریجی و صادقانه:

### سطح ۱ — جفت‌سازی out-of-band (هدف v2.2)

- دعوت تماس از طریق QR یا لینک invite که فقط شامل call ID مبهم، آدرس signaling و fingerprint کلید دستگاه است؛

- بدون ثبت‌نام، بدون سرور دایرکتوری، بدون شماره تلفن یا ایمیل؛

- pinning کلید طرف مقابل با TOFU در همان لحظه جفت‌سازی.

### سطح ۲ — دفترچه مخاطب محلی (هدف v2.3)

- ذخیره محلی «نام نمایشی + fingerprint pin شده» برای تماس‌های بعدی بدون QR مجدد؛

- نمایش تغییر کلید مخاطب به‌صورت هشدار صریح (همان منطق `changed` در TOFU)؛

- هیچ داده مخاطب به سرور نمی‌رود.

### سطح ۳ — رجیستری حداقلی (هدف v3.0)

- نگاشت `opaque user ID → device public keys` روی سرور signaling؛

- شناسه‌ها opaque و انتخابی؛ شماره تلفن/ایمیل اجباری نیست؛

- راستی‌آزمایی هویت همچنان سمت کلاینت با safety number / QR verification انجام می‌شود؛ سرور فقط lookup است و trust anchor نیست؛

- threat model این رجیستری (enumeration، spam invite، metadata) باید قبل از ساخت آن تکمیل شود.

### قاعده

فاز ۳ فقط با سطح ۱ شروع می‌شود؛ سطح ۳ بدون threat model تکمیل‌شده شروع نمی‌شود؛ کشف کاربر ناشناخته طبق Non-goals خارج از دامنه است.

---

# ۶. فازهای اجرایی

## فاز ۰ — Freeze، Baseline و صداقت مستندات

### هدف

ایجاد نقطه شروع قابل بازگشت و حذف هر ادعایی که هنوز اثبات نشده است.

### کارها

- ایجاد tag یا snapshot از وضعیت فعلی؛

- تولید فهرست پکیج‌ها، APIها و dependencyها؛

- ثبت خروجی اولیه analyzer و test؛

- مشخص‌کردن APIهای public و experimental؛

- اصلاح README:

  - حذف ادعای وجود `apps/`، `server/` یا `integration_test/` تا زمان ایجاد واقعی آن‌ها؛

  - حذف عبارت «فایل‌ها آماده‌اند» مگر آنکه فایل‌ها واقعاً وجود داشته و CI سبز باشد؛

  - ایجاد بخش `Current Status` و `Known Limitations`.

### Gate خروج

- هر ادعای README به کد، تست یا artifact واقعی متصل باشد.

- snapshot بازگشت‌پذیر وجود داشته باشد.

- هیچ feature فرضی به‌عنوان feature تحویل‌شده معرفی نشود.

---

## فاز ۱ — Buildable Foundation و CI

### هدف

تبدیل اسکلت فعلی به workspace قابل compile.

### کارها

- انتخاب یک تعریف canonical برای:

  - `CallState`؛

  - `ReconnectPolicy`.

- حذف تعریف‌های تکراری از `call_controller.dart`.

- اصلاح barrel exportها.

- نصب و pin کردن Flutter/Dart SDK.

- افزودن dependencyهای واقعی پس از بررسی مجوز و امنیت:

  - WebRTC adapter؛

  - WebSocket/HTTP client؛

  - cryptography library؛

  - secure storage؛

  - test، fake clock و mocking.

- اصلاح `architecture_guard`.

- افزودن CI برای:

  - formatting؛

  - analyzer با `fatal-infos`؛

  - unit test؛

  - dependency audit؛

  - secret scan؛

  - license inventory.

### Gate خروج

```text

flutter pub get        PASS

dart format --set-exit-if-changed .   PASS

dart analyze           0 error

flutter test           PASS

architecture_guard     PASS

```

هیچ phase بعدی پیش از سبزشدن این Gate شروع نشود.

---

## فاز ۲ — تست قطعی هسته و رفع باگ‌های هم‌زمانی

### هدف

تثبیت الگوریتم‌ها قبل از اتصال به شبکه واقعی.

### کارها

- ایجاد abstraction برای `Clock`، `TimerFactory` و random source؛

- حذف وابستگی unit testها به زمان واقعی؛

- افزودن single-flight guard به `RtcStatsSampler`؛

- افزودن timeout و `try/finally` به negotiation؛

- پیاده‌سازی صحیح حالت‌های:

  - closed؛

  - open؛

  - half-open

  در circuit breaker؛

- تست کامل:

  - state machine؛

  - reconnect backoff؛

  - jittered retry؛

  - EWMA score؛

  - path ranking؛

  - reliable outbox؛

  - deduplication؛

  - signed manifest cache؛

  - expiry و rollback.

### Property Testهای ضروری

- score همیشه در بازه تعریف‌شده باقی بماند؛

- افزایش RTT یا loss نباید بدون دلیل score را بهتر کند؛

- outbox یک پیام ACK‌شده را دوباره تحویل ندهد؛

- پیام duplicate اثر دوم نداشته باشد؛

- manifest با نسخه قدیمی‌تر جای نسخه معتبر جدید را نگیرد؛

- retry delay از سقف تعریف‌شده عبور نکند؛

- cancel شدن call تمام timerها و streamها را آزاد کند.

### Gate خروج

- حداقل ۸۵٪ line coverage روی ماژول‌های stateful؛

- حداقل ۷۵٪ branch coverage روی state machine، outbox و signed config؛

- صفر timer واقعی در unit testها؛

- اجرای تست‌ها در چند seed تصادفی بدون flake.

---

## فاز ۳ — اولین Vertical Slice قابل اجرا

### هدف

برقراری یک تماس صوتی واقعی میان دو دستگاه، پیش از افزودن پیچیدگی‌های بیشتر.

### اجزا

- جفت‌سازی دو دستگاه با QR/لینک invite طبق سطح ۱ «مدل هویت و آدرس‌دهی کاربر» (§۵)؛

- `apps/reference_app`؛

- `WebRtcMediaAdapter` واقعی؛

- signaling server حداقلی؛

- یک coturn استاندارد؛

- call invite، accept، reject و hangup؛

- تبادل offer، answer و ICE candidates؛

- timeout و cancellation؛

- نمایش وضعیت تماس؛

- logهای redacted.

### ترتیب توسعه

1. تماس صوتی روی LAN؛

2. تماس صوتی روی اینترنت با direct ICE؛

3. تماس با TURN relay؛

4. جابه‌جایی Wi‑Fi به mobile data؛

5. بازیابی signaling پس از reconnect.

### Gate خروج

- ۱۰۰ چرخه setup/teardown بدون leak؛

- ۱۰ تماس ۳۰ دقیقه‌ای بدون قفل state؛

- تماس موفق روی دو دستگاه واقعی؛

- اثبات TURN fallback؛

- صفر SDP، token و key در logها.

---

## فاز ۴ — پایه امنیت و هویت

### هدف

تبدیل «interface امنیتی» به کنترل واقعی و قابل ممیزی.

### کارها

- پیاده‌سازی concrete برای interfaceهای:

  - verifier؛

  - signer؛

  - identity key engine؛

  - manifest verification.

- نگه‌داری کلید در Keystore/Keychain؛

- پشتیبانی از key ID و rotation؛

- anti-replay با nonce و window محدود؛

- anti-rollback برای manifest؛

- اعتبارسنجی زمان با tolerance کنترل‌شده؛

- credential کوتاه‌عمر برای TURN؛

- اتصال هویت تماس‌گیرنده به fingerprint نشست رسانه با روش استاندارد یا ممیزی‌شده؛

- ارائه safety number یا QR verification در نسخه‌های بعدی.

### مرزبندی مهم E2EE

- تماس P2P مبتنی بر WebRTC و DTLS-SRTP در برابر TURN relay محرمانه است؛ relay نباید محتوای media را ببیند.

- وجود signaling server می‌تواند خطر دست‌کاری negotiation ایجاد کند؛ identity binding باید بررسی شود.

- برای تماس گروهی با SFU، تا زمان پیاده‌سازی و ممیزی SFrame/MLS یا مکانیزم استاندارد معادل، نباید ادعای E2EE کامل شود.

### تست‌ها

- امضای خراب؛

- payload دست‌کاری‌شده؛

- nonce تکراری؛

- manifest منقضی؛

- rollback؛

- clock skew؛

- key rotation؛

- دستگاه با کلید حذف‌شده؛

- credential دزدیده‌شده یا منقضی.

### Gate خروج

- ۱۰۰٪ manifestهای دست‌کاری‌شده reject شوند؛

- ۱۰۰٪ replayهای تست‌شده reject شوند؛

- هیچ secret در storage عمومی یا log دیده نشود؛

- threat model و data-flow diagram تکمیل شود.

---

## فاز ۵ — کیفیت و پایداری Media

### هدف

افزایش کیفیت تماس با تکیه بر قابلیت‌های استاندارد WebRTC، نه ساخت مجدد آن‌ها.

### سیاست صوت

- Opus؛

- DTX در شرایط مناسب؛

- in-band FEC در صورت پشتیبانی؛

- packet loss concealment؛

- audio-first degradation؛

- کاهش bitrate پیش از قطع صدا؛

- خاموش‌شدن ویدئو پیش از نابودی کیفیت صوت.

### سیاست ویدئو

- adaptation بر اساس:

  - RTT؛

  - available outgoing bitrate؛

  - packet loss؛

  - frame drop؛

  - encode time؛

  - CPU و thermal state.

- کاهش به ترتیب:

  1. bitrate؛

  2. frame rate؛

  3. resolution؛

  4. audio-only.

### درباره JitterBuffer و FEC موجود

- اگر media از WebRTC عبور می‌کند، از jitter buffer داخلی استفاده شود.

- `AdaptiveJitterBuffer` اختصاصی فقط برای مسیرهای غیر-WebRTC یا آزمایشگاه باقی بماند.

- XOR FEC به‌صورت پیش‌فرض فعال نشود.

- ابتدا NACK/RTX، Opus FEC، RED یا امکانات خود stack بررسی شوند.

- هر FEC باید هزینه bandwidth و latency قابل‌اندازه‌گیری داشته باشد.

### Gate خروج

در شبکه آزمایشگاهی:

- روی شبکه عادی:

  - setup success حداقل ۹۹٪؛

  - setup time در P95 کمتر از ۶ ثانیه.

- روی ۱۰٪ loss، jitter برابر ۸۰ms و RTT برابر ۳۰۰ms:

  - setup success حداقل ۹۵٪؛

  - تماس به audio-only تنزل یابد ولی crash نکند.

- روی ۳۰ تا ۴۰٪ loss:

  - کیفیت تضمین نشود؛

  - سیستم باید graceful degradation، recovery و گزارش دقیق ارائه کند؛

  - هیچ deadlock یا crash پذیرفته نیست.

---

## فاز ۶ — Path Continuity و Relay Diversity

### هدف

حفظ تماس در زمان خرابی یک مسیر یا یک منطقه زیرساختی.

### پیش‌گیت هزینه TURN (قبل از هر deployment این فاز — الزامی)

egress ریلی هزینه اصلی و تکرارشونده این معماری است؛ گارد بودجه باید قبل از ایجاد هزینه فعال باشد، نه بعد از اولین صورتحساب.

- فرمول برآورد ماهانه:

```text

monthly_egress_GB ≈ relayed_minutes × MB_per_relayed_minute / 1024

MB_per_relayed_minute ≈ 0.75 (audio ~50kbps دوطرفه)
MB_per_relayed_minute ≈ 7-15 (video 1-2Mbps)

monthly_cost ≈ monthly_egress_GB × provider_egress_rate (+ هزینه ثابت VM/region)

```

- مثال مقیاس: ۱۰هزار دقیقه relayed صوتی در ماه ≈ ۷-۸ گیگابایت egress یعنی ناچیز؛ ۱میلیون دقیقه ≈ ~۷۵۰ گیگابایت که با نرخ‌های معمول cloud قابل‌توجه است؛ ویدئو این اعداد را ۱۰ تا ۲۰ برابر می‌کند؛

- سهم relayed را از telemetry فاز ۵ اندازه بگیر (نسبت واقعی direct به TURN)، حدس نزن؛

- Budget alert روی provider قبل از استقرار اولین coturn این فاز فعال شود؛ سقف ماهانه مکتوب در `docs/OPERATIONS.md` ثبت شود؛

- انتخاب region هم‌محل با کاربران برای حذف egress بین‌منطقه‌ای مضاعف؛

- گیت: بدون سقف بودجه ثبت‌شده و alert فعال، این فاز شروع نمی‌شود.

### کارها

- ایجاد `RelayPool` با چند region؛

- در صورت توجیه عملیاتی، استفاده از بیش از یک ارائه‌دهنده؛

- TURN روی مسیرهای استاندارد:

  - UDP؛

  - TCP؛

  - TLS.

- credential کوتاه‌عمر؛

- health check؛

- EWMA برای RTT، availability و failure rate؛

- hysteresis برای جلوگیری از path flapping؛

- ICE restart کنترل‌شده؛

- signaling resume با outbox؛

- cache آخرین manifest معتبر.

### سیاست Fanout

- signaling idempotent می‌تواند روی مسیر جایگزین retry شود.

- endpoint config می‌تواند از چند origin استاندارد fetch شود.

- media به‌صورت پیش‌فرض روی چند مسیر duplicate نشود.

- make-before-break یا warm standby فقط پس از سنجش مصرف CPU، battery و bandwidth فعال شود.

### Gate خروج

- حذف یک signaling node نباید کل سرویس را متوقف کند؛

- حذف یک TURN region باید تماس‌های جدید را به region دیگر منتقل کند؛

- تغییر Wi‑Fi به mobile data باید در P95 حداکثر طی ۸ ثانیه بازیابی شود؛

- duplicate signaling نباید call state را خراب کند؛

- path oscillation در شرایط مرزی کنترل شود.

---

## فاز ۷ — Signed Endpoint Discovery

### هدف

به‌روزرسانی امن endpointها بدون وابستگی به یک origin واحد.

### معماری

- حداقل دو HTTPS origin استاندارد؛

- Host و TLS SNI منطبق؛

- دامنه‌ها و زیرساخت متعلق به سازمان یا با مجوز روشن؛

- manifest امضاشده شامل:

  - version؛

  - issued-at؛

  - expires-at؛

  - key ID؛

  - relay regions؛

  - signaling endpoints؛

  - minimum client version؛

  - feature flags محدود.

- last-known-good cache؛

- grace window کنترل‌شده؛

- key rotation؛

- عدم دانلود یا اجرای runtime code.

### مواردی که وارد این فاز نمی‌شوند

- Host/SNI mismatch؛

- جعل origin؛

- دانلود کد اجرایی؛

- تغییر خاموش semantics امنیتی؛

- endpoint بدون هویت تأییدشده یا بدون مجوز.

### Gate خروج

- خرابی origin اول با origin دوم جبران شود؛

- در حالت offline، last-known-good در محدوده اعتبار کار کند؛

- manifest قدیمی‌تر یا دست‌کاری‌شده پذیرفته نشود؛

- rotation کلید بدون outage آزمایش شود.

---

## فاز ۸ — بازگرداندن ارزش‌های مفید نسخه قدیمی

سه قابلیت نسخه قدیمی ارزش معماری داشتند، اما implementation آن‌ها prototype بود. این بار باید به‌صورت واقعی و محدود بازگردند.

### ۸.۱. `PushWakeup`

کاربرد:

- بیدارکردن اپ؛

- اعلان تماس ورودی؛

- حمل یک call ID opaque و کم‌حجم.

محدودیت‌ها:

- SDP، key، contact information یا media در payload push قرار نگیرد؛

- push منبع حقیقت call state نباشد؛

- پیام تکراری idempotent باشد؛

- تحویل push تضمین‌شده فرض نشود.

### ۸.۲. `NearbyTransport`

کاربرد:

- discovery محلی با BLE؛

- انتقال واقعی با Wi‑Fi Direct، local Wi‑Fi یا قابلیت متناظر پلتفرم؛

- exchange محلی signaling و پیام‌های کوچک؛

- تماس صوتی فقط زمانی که لینک ظرفیت و latency کافی دارد.

نکته فنی:

- BLE برای discovery مناسب است، نه الزاماً media پیوسته؛

- برای صوت، Wi‑Fi Direct یا لینک محلی پرظرفیت اولویت دارد.

### ۸.۳. `LocalDissemination`

اگر store-and-forward یا چند hop لازم باشد:

- envelope امضاشده و رمزگذاری‌شده؛

- message ID؛

- TTL محدود؛

- duplicate suppression؛

- quota برای هر peer؛

- rate limit؛

- اولویت‌بندی پیام؛

- حد اندازه payload؛

- consent صریح کاربر؛

- امکان خاموش‌کردن کامل.

این لایه نباید به‌عنوان backbone تماس جهانی معرفی شود. کاربرد صحیح آن «تداوم محلی در یک شبکه یا اجتماع نزدیک» است.

### ۸.۴. `NetworkQualityPolicy`

profileهای پیشنهادی:

```dart

enum NetworkQualityProfile {

  healthy,

  constrained,

  degraded,

  locallyConnected,

}

```

این policy باید روی موارد زیر اثر بگذارد:

- تعداد retry؛

- timeout؛

- audio/video mode؛

- relay preference؛

- telemetry sampling؛

- battery budget.

### Gate خروج

- push duplicate باعث تماس duplicate نشود؛

- push منقضی رد شود؛

- local envelope تکراری دوباره پردازش نشود؛

- TTL و quota در تست ۵، ۱۰ و ۲۰ دستگاه رعایت شود؛

- مصرف باتری نسبت به baseline اندازه‌گیری شود؛

- نبود gateway به‌وضوح فقط حالت local را فعال کند.

---

## فاز ۹ — یکپارچگی واقعی موبایل و UX

### Android

- ConnectionService یا integration مناسب تماس؛

- foreground service؛

- notification channel؛

- microphone/camera permissions؛

- رفتار Doze و battery optimization؛

- audio focus؛

- Bluetooth routing.

### iOS

- CallKit؛

- AVAudioSession؛

- PushKit فقط در چارچوب مجاز پلتفرم؛

- background modeهای لازم؛

- route change؛

- interruption handling.

### UX ضروری

- وضعیت Connecting/Reconnecting روشن؛

- نشان‌دادن تنزل به audio-only؛

- نمایش وضعیت privacy به زبان ساده؛

- گزارش خطای قابل‌فهم؛

- accessibility؛

- low-data mode؛

- کنترل خاموش‌کردن telemetry.

### Gate خروج

- تست روی حداقل دو نسخه اصلی Android و دو نسخه اصلی iOS؛

- تست wired headset، Bluetooth و speaker؛

- تست background/foreground؛

- تست lock screen؛

- تست تماس ورودی هم‌زمان با تماس سلولی؛

- صفر permission loop.

---

## فاز ۱۰ — Observability، عملیات و کنترل سوءاستفاده

### Telemetry مجاز

- call setup duration؛

- ICE candidate type؛

- anonymized region؛

- RTT bucket؛

- jitter bucket؛

- packet loss bucket؛

- reconnect count؛

- codec و bitrate؛

- failure category؛

- app/OS version.

### داده‌های ممنوع در telemetry

- محتوای صوت/تصویر؛

- SDP کامل؛

- access token؛

- push token؛

- کلید؛

- شماره تلفن؛

- نام مخاطب؛

- IP خام، مگر در debug محلی و با رضایت روشن.

### عملیات زیرساخت

- داشبورد signaling؛

- داشبورد TURN bandwidth؛

- relay ratio؛

- region health؛

- cost per relayed minute؛

- alertهای SLO؛

- runbook خرابی region؛

- credential rotation؛

- incident response.

### کنترل‌های سوءاستفاده

- rate limit؛

- اعتبار کوتاه‌عمر TURN؛

- محدودیت ساخت session؛

- محافظت در برابر invite spam؛

- revoke device؛

- گزارش سوءاستفاده؛

- DDoS protection استاندارد؛

- audit trail حداقلی و privacy-aware.

### Gate خروج

- تست خودکار عدم نشت secret در log؛

- تکمیل runbookها؛

- alert آزمایشی موفق؛

- امکان rollback manifest؛

- cost dashboard فعال.

---

## فاز ۱۱ — Chaos، Scale، ممیزی و انتشار تدریجی

### تست رشد بار

بار به‌صورت مرحله‌ای افزایش یابد:

1. ۱۰۰ اتصال signaling هم‌زمان؛

2. ۱٬۰۰۰ اتصال؛

3. ۱۰٬۰۰۰ اتصال؛

4. ظرفیت بالاتر فقط بعد از تحلیل bottleneck.

برای TURN نیز به‌جای شمارش صرف session، موارد زیر اندازه‌گیری شوند:

- Mbps/Gbps واقعی؛

- packet rate؛

- CPU؛

- memory؛

- network egress cost؛

- packet loss داخلی؛

- latency بین regionها.

### Chaos Testها

- خاموش‌کردن یک signaling node؛

- خاموش‌کردن یک relay region؛

- DNS failure؛

- TLS certificate rotation؛

- clock skew؛

- packet reordering؛

- burst loss؛

- database restart؛

- app process kill؛

- Wi‑Fi/mobile transition؛

- background suspension؛

- partial manifest corruption.

### امنیت

- dependency audit؛

- SBOM؛

- fuzzing parserها؛

- fuzzing signaling messages؛

- تست replay و downgrade؛

- بررسی مستقل threat model؛

- penetration test توسط تیم مستقل؛

- مستندسازی یافته‌ها و remediation.

### انتشار تدریجی

```text

Internal dogfood

→ 1% canary

→ 5%

→ 25%

→ 50%

→ 100%

```

هر مرحله حداقل یک بازه مشاهده کامل داشته باشد و rollback خودکار بر اساس معیارهای از پیش تعیین‌شده فعال باشد.

---

# ۷. نردبان تست تدریجی

| سطح | محیط | هدف |

|---|---|---|

| G0 | Static analysis | compile، lint، architecture و dependency |

| G1 | Unit deterministic | state machine، score، outbox، crypto wrapper |

| G2 | Simulated network | loss، jitter، reorder، timeout با fake clock |

| G3 | Loopback | signaling و media روی یک ماشین |

| G4 | دو دستگاه واقعی | LAN، mobile، TURN |

| G5 | شبکه مختل | loss/jitter/RTT/bandwidth matrix |

| G6 | خرابی زیرساخت | region outage، node restart، DNS failure |

| G7 | local continuity | discovery، dedup، TTL و battery |

| G8 | load/soak | ۱۰۰، ۱٬۰۰۰، ۱۰٬۰۰۰ session |

| G9 | canary | کاربران واقعی محدود با rollback |

| G10 | production | SLO، incident response و audit دوره‌ای |

عبور از هر سطح فقط پس از سبزشدن سطح قبلی مجاز است.

---

# ۸. ماتریس شبکه آزمایشگاهی

حداقل شرایط زیر در CI شبانه یا آزمایشگاه شبکه اجرا شوند:

## Packet loss

```text

0% · 2% · 5% · 10% · 20% · 30% · 40%

```

## Jitter

```text

0ms · 20ms · 50ms · 100ms · 150ms

```

## RTT

```text

30ms · 100ms · 300ms · 600ms · 1000ms

```

## Reordering

```text

0% · 1% · 5% · 10%

```

## Bandwidth

```text

24kbps · 48kbps · 96kbps · 256kbps · 1Mbps · 2Mbps

```

## Network transitions

- Wi‑Fi → mobile؛

- mobile → Wi‑Fi؛

- IPv4 → IPv6؛

- direct → TURN؛

- TURN region A → region B؛

- online → local-only؛

- background → foreground.

تمام ترکیب‌ها لازم نیست در هر commit اجرا شوند. تقسیم پیشنهادی:

- smoke matrix در هر PR؛

- full matrix شبانه؛

- device farm هفتگی؛

- chaos و load پیش از release.

---

# ۹. SLOهای اولیه

| معیار | هدف اولیه |

|---|---|

| Crash-free call sessions | حداقل ۹۹٫۹٪ |

| Call setup success در شبکه عادی | حداقل ۹۹٪ |

| Call setup P95 در شبکه عادی | حداکثر ۶ ثانیه |

| Recovery پس از network switch، P95 | حداکثر ۸ ثانیه |

| One-way audio sessions | کمتر از ۰٫۵٪ |

| پذیرش manifest دست‌کاری‌شده | صفر |

| پذیرش replay شناخته‌شده | صفر |

| نشت secret در log | صفر |

| خرابی کامل با از دست رفتن یک signaling node | صفر |

| Battery regression | بیش از ۱۰٪ نسبت به baseline پذیرفته نیست |

این اعداد باید پس از ساخت vertical slice روی دستگاه‌های واقعی بازتنظیم شوند. عددی که فقط در simulator پاس شود، SLO تولیدی محسوب نمی‌شود.

---

# ۱۰. سیاست نام‌گذاری و مستندات

نام‌های پیشنهادی بر اساس رفتار واقعی:

- `PathSelector`

- `RelayPool`

- `NetworkQualityPolicy`

- `MediaAdaptationController`

- `PushWakeup`

- `NearbyTransport`

- `LocalDissemination`

- `SignedEndpointManifest`

- `CallRecoveryCoordinator`

- `RtcStatsSampler`

قواعد:

1. نام پروتکل واقعی را در config جعل یا تغییر ندهید.

2. رفتار فنی حساس را با عنوان بی‌ربط پنهان نکنید.

3. هر سند بخش‌های زیر را داشته باشد:

   - Scope؛

   - Assumptions؛

   - Non-goals؛

   - Security considerations؛

   - Tested scenarios؛

   - Known limitations.

4. واژه‌هایی مانند «unhackable»، «guaranteed» و «works everywhere» استفاده نشوند.

5. اگر بررسی خودکار روی محتوای سالم false positive داد، از feedback/support یا مدل مجاز دیگری استفاده شود؛ نه probing واژه‌ها و تغییر نام برای گمراه‌کردن بررسی.

---

# ۱۱. نقشه نسخه‌ها

## خط برش منابع (Resource Cut-Line)

این بلوپرینت دو رژیم اجرایی متفاوت دارد و صادق بودن درباره مرز آن‌ها بخشی از خود پلن است:

### رژیم تک‌نفره (وضعیت فعلی) — هدف واقع‌بینانه: تا پایان `v2.2.0`

- `v2.1.0` با تلاش تک‌نفره قابل‌دستیابی است (برآورد درشت: ۲ تا ۴ هفته تمام‌وقت)؛

- `v2.2.0` نیز تک‌نفره ممکن است (برآورد درشت: ۶ تا ۱۰ هفته تمام‌وقت، شامل یک signaling server حداقلی و یک coturn تک‌region)؛

- فازهای ۶ به بعد (multi-region relay، device farm، تست ۱۰هزار اتصال، chaos، pentest مستقل، canary) در رژیم تک‌نفره فقط سند برنامه‌ریزی‌اند، نه تعهد؛ شروع آن‌ها بدون تأمین منابع، فقط backlog تولید می‌کند و کیفیت v2.1/v2.2 را قربانی می‌کند.

### رژیم تیمی — پیش‌نیاز `v2.3.0` به بعد

- حداقل ۳ تا ۵ نفر (mobile، backend/infra، security) به‌علاوه بودجه زیرساخت مستمر (TURN egress طبق پیش‌گیت فاز ۶، device farm، monitoring)؛

- security audit مستقل و penetration test فاز ۱۱ هزینه بیرونی جداگانه دارند و باید قبل از تعهد به `v3.0.0` تأمین شده باشند.

### قاعده

هیچ نسخه‌ای وارد execution نمی‌شود مگر منابع همان نسخه صریحاً تأمین و ثبت شده باشد؛ برآوردهای بالا پس از پایان هر نسخه با زمان واقعی مصرف‌شده بازتنظیم شوند.

## `v2.1.0 — Foundation`

- build سبز؛

- export conflict رفع‌شده؛

- CI؛

- تست هسته؛

- باگ‌های race و timeout رفع‌شده.

## `v2.2.0 — Secure Audio Alpha`

- اپ reference؛

- signaling واقعی؛

- coturn؛

- تماس صوتی دو دستگاه؛

- secure storage؛

- signed manifest.

## `v2.3.0 — Network Resilience Beta`

- multi-region relay؛

- ICE restart؛

- path scoring؛

- network impairment suite؛

- telemetry privacy.

## `v2.4.0 — Local Continuity Beta`

- PushWakeup؛

- NearbyTransport؛

- local discovery؛

- bounded dissemination؛

- battery tests.

## `v3.0.0 — Audited Production Release`

- Android/iOS lifecycle کامل؛

- load و chaos test؛

- security audit مستقل؛

- incident runbook؛

- canary rollout؛

- SLO و rollback عملیاتی.

---

# ۱۲. Definition of Done نهایی

نسخه `v3.0.0` فقط زمانی آماده انتشار است که:

- تمام پکیج‌ها compile شوند؛

- app واقعی تماس دوطرفه برقرار کند؛

- حداقل یک deployment واقعی signaling و TURN وجود داشته باشد؛

- هیچ interface امنیتی حیاتی بدون implementation نمانده باشد؛

- تست unit، integration، device، impairment و chaos سبز باشد؛

- docs دقیقاً با وضعیت کد منطبق باشند؛

- threat model و privacy review تکمیل شده باشد؛

- تماس گروهی بدون implementation مناسب، E2EE معرفی نشود؛

- rollback و incident response عملاً آزمایش شده باشند؛

- audit امنیتی مستقل انجام شده و یافته‌های بحرانی بسته شده باشند.

---

## نتیجه نهایی

ارزش‌هایی که از نسخه قدیمی باید بازگردند این‌ها هستند:

1. **تنوع مسیر و انتخاب تطبیقی مسیر**؛

2. **Push برای بیدارکردن اپ و signaling اضطراری**؛

3. **ارتباط محلی هنگام نبود اینترنت عمومی**؛

4. **policy تطبیقی برای کیفیت و افزونگی**؛

5. **endpoint discovery امضاشده و cacheشونده**.

اما باید به شکل درست بازگردند:

- نه به‌عنوان چند کلاس mock؛

- نه با ادعای تضمین مطلق؛

- نه با پروتکل‌های شکننده در هسته؛

- نه با جایگزین‌کردن مستندسازی تبلیغاتی به‌جای implementation؛

- بلکه با استانداردهای WebRTC/TURN، رمزنگاری ممیزی‌شده، تست شبکه واقعی، زیرساخت چندمنطقه‌ای و انتشار تدریجی.

**اولین کار اجرایی صحیح، افزودن قابلیت جدید نیست.** ترتیب درست این است:

1. رفع export conflict؛

2. رفع پنج باگ شناخته‌شده؛

3. راه‌اندازی toolchain و CI؛

4. افزودن تست قطعی هسته؛

5. ساخت تماس صوتی واقعی بین دو دستگاه؛

6. سپس امنیت، media adaptation، relay diversity، push و ارتباط محلی.

این مسیر توان واقعی اپ را بیشتر می‌کند، نه فقط حجم کد یا جذابیت README را.

