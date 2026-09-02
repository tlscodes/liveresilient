# دستور کار — نشست تازه (بعد از /clear)

پروژه: یک SDK/اپ Flutter برای تماس صوتی یک‌به‌یک با اجزای استاندارد WebRTC.
سیگنالینگ روی WSS احرازهویت‌شده، عبور از NAT با ICE و STUN/TURN، امنیتِ مدیا با
DTLS-SRTP. هدفِ مهندسی: پایداری و شنوایی خوبِ تماس روی شبکه‌های مصرفیِ متغیر —
packet loss، jitter، قطعی‌های کوتاه، و جابه‌جاییِ عادیِ Wi-Fi/Cellular.

مکانیزم‌های مورد انتظار (هرکدام یک استانداردِ نام‌بردنی):

- media: DTLS-SRTP طبق RFC 5764 (پیش‌فرضِ WebRTC)؛ صوتِ تماس سمتِ سرور ذخیره/لاگ نشود.
- reconnect: ICE restart هنگام تغییرِ interface طبق RFC 8445 (Wi-Fi↔Cellular)؛
  اتصالِ مجددِ سیگنالینگ روی WSS با exponential backoff.
- کیفیت زیر افت: Opus DTX/FEC + jitter buffer + packet-loss concealment؛
  تطبیقِ bitrate/codec زیر loss و jitter.
- NAT traversal: STUN + TURNِ خودِ پروژه (coturn) به‌عنوان fallbackِ استاندارد.
- گزارشِ شفافِ وضعیتِ اتصال (connection-state) به‌لایه‌ی اپ.

کد پایه از قبل ساخته شده در این مسیر (مونوریپوی melos، ۳۲ فایل Dart، ۸ پکیج):
$HOME/Downloads/VoiceCallKit_Enterprise_v1.0/voice_call_kit_v2

کارهای این نشست، به‌ترتیب:
۱. ساختار پروژه را بخوان و یک نقشهٔ معماری کوتاه بده (پکیج‌ها، جریان داده، پروتکل‌ها).
۲. سه ماژول هسته را مرور کن و باگ‌های صحت/امنیت را فهرست کن:
   packages/media_webrtc/lib/src/media_adaptation.dart
   packages/adaptive_transport/lib/src/path_selector.dart
   packages/device_link/lib/src/media_frame.dart
۳. برای هر باگ، یک patch کوچک و قابل‌بازبینی پیشنهاد بده (نه بازنویسی کامل).

قید: فقط اجزای استانداردِ WebRTC؛ هیچ لایهٔ حملِ غیراستاندارد یا سفارشی اضافه نشود
(فایل tool/architecture_guard.dart این را در CI بررسی و اجبار می‌کند).
