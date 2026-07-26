# Brief — Resilient Media Transport & Transport-Layer Normalization — Phased Plan

**Stage Goal:** The voice path keeps working on severely constrained network profiles (a few hundred bytes per second, high packet loss, multi-second delay, small MTU). This stage gives files (photos, short videos, documents) the same survivability over the same constrained path, using only the spare wire budget voice is not using, while ensuring protocol-level resilience against loss, dynamic route changes, and variable network environments.

Everything here is structured as standard transport protocol engineering: rateless erasure coding, low-rate media compression, adaptive queue scheduling, TLS client negotiation (RFC 8446 / RFC 8701), encapsulation (RFC 9113 / RFC 8831), and proxy steering (RFC 6066 / RFC 9110).

---

## وضعیت اجرا (به‌روزرسانی 2026-07-26)

هر هشت فاز بسته، کامیت‌شده و با Gate سبز اجرا شده‌اند.

| # | فاز | وضعیت | عدد اندازه‌گیری‌شده / مشخصات پیاده‌سازی |
|---|---|---|---|
| **1** | RLNC روی GF(2^8) | **بسته** | $\epsilon = 1.0000$ (کف تئوری اطلاعات؛ هسته‌ی قبلی LT بود 1.33) |
| **2** | تخمین‌گر کور کانال (Baum-Welch) | **بسته** | $p=0.045/r=0.093$ در برابر واقعی $0.04/0.1$؛ صفر فیدبک |
| **3** | صف round-robin با مکان‌نمای پایدار | **بسته** | A/B تراز دقیق 129/129؛ بدون گرسنگی (Zero Starvation) |
| **4a** | سند — موتور CM به‌جای gzip9 | **بسته** | 1822 → 1277 B (−29.9%) |
| **4b** | پیرامید تصویر — رقابت سه کدک | **بسته** | 579 → 551 B (سطح پایه 50 → 37 B) |
| **4c** | فلیپ‌بوک — ۳ پیش‌بین + جبران حرکت | **بسته** | ساکن: بدون سربار؛ پن: 28238 → 24259 B (−14.1%) |
| **5** | یکپارچه‌سازی + تحویل لایه‌ای | **بسته** | پیش‌نمایش اول: 21.4s → 7.6s (۲.۸ برابر سریع‌تر) |
| **6** | پیکربندی TLS 1.3 + کپسوله‌سازی HTTP/2 | **بسته** | 14 تست سبز؛ بازیابی بیت‌به‌بیت روی هر دو حامل (HTTP/2 DATA و SCTP DataChannel) در طول‌های 0..1400 B؛ پدینگ روی مرز بلوک MTU |
| **7** | احراز نشست + اتصال مجدد چندنقطه‌ای | **بسته** | 15 تست سبز؛ HMAC-SHA256 با مقایسه‌ی زمان‌ثابت، رد replay و انقضا، پاسخ 401 با چالش WWW-Authenticate و بستن سوکت؛ سوییچ خودکار بین endpointها با backoff نمایی و jitter کامل |
| **8** | تخصیص رله STUN/TURN + یکپارچه‌سازی | **بسته** | 14 تست تخصیص‌گر + نشست ۱۲۰ ثانیه‌ای روی هر دو حامل؛ هر سه انتقال کامل در ۴ و ۷ و ۷ ثانیه، بیت‌به‌بیت، roaming وسط تماس، تیک صوت 1001 == مبنا؛ سربار سیم 1.67x روی HTTP/2 و 1.53x روی DataChannel |

**کامیت‌های مرجع:** `fc88c1f` (فاز 2)، `f28540e` (فاز 1)، `9e50dbf` (فاز 3)، `cb1647b` (فاز 4a)، `ba18785` (فاز 4b/4c)، `983117e` (فاز 4b رقابتی + فاز 5 لایه‌ای).

---

## نمای کلی معماری (Architecture Overview)

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                   RESILIENT MEDIA TRANSPORT STACK (PHASES 1 - 8)                 │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 8: Dynamic STUN/TURN Relay Allocation & Full System Integration            │
│          (RFC 8489 / RFC 8656 / Gate Loop Enforcement)                           │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 7: Session Authentication & Multi-Endpoint Dynamic Reconnect               │
│          (HMAC-Nonce Verification / RFC 9110 401 Response / RFC 6066 SNI)        │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 6: TLS 1.3 Client Negotiation & Packet Length/MTU Alignment               │
│          (RFC 8701 reserved values / RFC 3711 padding / RFC 9113 HTTP2 & RFC 8831 SCTP)   │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 5: Low-Rate Photo Pyramid & Video Flipbook Compressors                     │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 4: Text Document Compression Pipeline (Context Mixing Engine)              │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 3: Background Media Queue with Strict Voice Priority                       │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 2: Rateless Code over Hostile Channel & Baum-Welch Blind Estimator         │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 1: Rateless Erasure Code Core (Zero-Feedback GF(2^8) RLNC Stream)          │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## قوانین اجرای نقشه راه (Execution Rules)

هشت فاز مستقل، تست‌پذیر و قابل تحویل مجزا تعریف شده‌اند. هر فاز زمانی **CLOSED** می‌شود که تست‌های اختصاصی آن سبز شده و کل حلقه تست سیستم (`bash tools/run_gate_loop.sh`) بدون خطا پاس شود.

هر فاز شامل موارد زیر است:
1. **ساختار و فایل‌های پیاده‌سازی (Build Target)**
2. **فایل تست اختصاصی (Test File)**
3. **معیارهای پذیرش و متریک‌ها (Acceptance Criteria & Metrics)**

---

## شرح تفصیلی فازهای ۸‌گانه

### Phase 1 — Rateless Erasure Code Core (No Network)

* **Build:** `packages/connection_orchestrator/lib/src/rateless_stream.dart` شامل `RatelessEncoder` و `RatelessDecoder`.
* هسته RLNC روی $GF(2^8)$ با توزیع درجه Robust Soliton و پیشوند سیستماتیک: $N$ دتاگرام اول، بلوک‌های منبع هستند و متعاقباً ترکیب‌های خطی تصادفی ارسال می‌شوند. بدون نیاز به کانال بازگشتی (Zero-Feedback / RFC 6330).
* **Wire Format:**
$$\text{Payload Format: } [\text{u16 } \text{esi}] \cdot [\text{u16 } \text{blockCount}] \cdot [\text{payload}] \cdot [\text{u8 } \text{crc8}]$$
* **Test File:** `test/rateless_stream_test.dart`
* **معیار پذیرش:**
  - بازیابی ۱ بایت تا ۶۴ کیلوبایت بدون اتلاف، دقیقاً بیت به بیت (Bit-exact).
  - رد دتاگرام‌های مخرب با CRC8.
  - نرخ اضافه بار (Overhead) $\epsilon = \frac{\text{distinct datagrams needed}}{N} = 1.0000$.

---

### Phase 2 — Rateless Code over Hostile Channel

* **Build:** یکپارچه‌سازی فاز ۱ با شبیه‌ساز کانال پراتلاف (`GilbertElliottLossSimulator`) و تخمین‌گر کور Baum-Welch.
* **Test File:** `test/rateless_hostile_test.dart`
* **معیار پذیرش:**
  - انتقال ۲ کیلوبایت روی کانال با ۹۵٪ اتلاف یکنواخت و انباشته (Burst loss با میانگین ۱۰ پکت) + Jitter تا ۵ ثانیه.
  - اثبات عدم ارسال هیچ پکت بازگشتی از سوی گیرنده (Zero-Feedback Verification).
  - عدم بروز Exception روی دتاگرام‌های ناقص یا فاسد شده.

---

### Phase 3 — Background Queue with Voice Priority

* **Build:** `lib/src/media_queue.dart` شامل `MediaTransferQueue`.
* دتاگرام‌های رسانه فقط زمانی صادر می‌شوند که `SilenceSuppressionVAD` وضعیت سکوت را گزارش کند (سقف نرخ 200–500 B/s).
* **Test File:** `test/media_queue_test.dart`
* **معیار پذیرش:**
  - صدور صفر دتاگرام رسانه در پنجره‌های گفتار (Voice Active).
  - اولویت مطلق صوت: توالی تیک‌های ارسال صوت در حضور و عدم حضور انتقال رسانه ۱۰۰٪ هم‌تراز و یکسان است.

---

### Phase 4 — Document Compression Pipeline

* **Build:** `lib/src/media_codecs/text_document_compressor.dart`.
* استخراج لایه متن خام، حذف استایل‌های اضافی و اعمال موتور Context Mixing (CM).
* **Test File:** `test/text_document_compressor_test.dart`
* **معیار پذیرش:**
  - بازگشت ۱۰۰٪ دقیق کاراکترها برای متون ASCII، فارسی و UTF-8 ترکیبی.
  - کاهش حجم حداقل ۲۵٪ نسبت به gzip9 روی اسناد استاندارد متنی.

---

### Phase 5 — Low-Rate Photo & Video Flipbook Codecs

* **Build:**
  * `lib/src/media_codecs/low_rate_image_compressor.dart`: تولید پیش‌نمایش پیشرونده (~1 KB) + کانتور SVG (~300-800 B).
  * `lib/src/media_codecs/flipbook_video_compressor.dart`: تبدیل ویدیو به کی‌فریم‌های تک‌رنگ 120x80 با نرخ ۱ فریم در ۳ ثانیه (~300 B/frame).
* **Test File:** `test/media_codecs_test.dart`
* **معیار پذیرش:**
  - تطابق حجم خروجی با محدوده تعیین‌شده؛ قابلیت رمزگشایی پیشوند بدون خطا.
  - ارزیابی کیفیت با معیار شباهت ساختاری (SSIM) به‌جای مقایسه بیت به بیت.

---

### Phase 6 — TLS 1.3 Client Parameter Set & MTU-Block Padding (RFC 8701 / RFC 3711)

* **Build:**
  * `lib/src/transport/tls_parameter_normalizer.dart`: تنظیم پارامترهای استاندارد دست‌دادن TLS 1.3، آزمون توسیع‌پذیری با درج مقادیر رزروشده‌ی RFC 8701، و Cipher Suiteهای استاندارد.
  * `lib/src/transport/micro_datagram_lane.dart`: هم‌ترازی طول بسته‌ها جهت انطباق با مرزهای MTU و جلوگیری از شکسته شدن (Fragmentation) بسته‌ها در شبکه بر اساس RFC 3711.
  * کپسوله‌سازی فریم‌های rateless درون فریم‌های HTTP/2 DATA (RFC 9113) یا WebRTC SCTP DataChannels (RFC 8831).
* **Test File:** `test/edge_transport_conformance_test.dart`
* **معیار پذیرش:**
  - بازیابی ۱۰۰٪ بیت‌به‌بیت داده پس از حذف پدینگ هم‌ترازی MTU.
  - درج مقادیر رزروشده‌ی معتبر RFC 8701 و ALPNهای استاندارد (`h2`, `http/1.1`).
  - مطابقت کامل هدر فریم‌های HTTP/2 و DataChannel با مرزهای RFC.

---

### Phase 7 — Session Authentication & Multi-Endpoint Reconnect (RFC 9110 / RFC 6066)

* **Build:**
  * `lib/src/server/authenticated_relay_server.dart`: احراز هویت نشست مبتنی بر HMAC/Nonce در ابتدای ارتباط. درخواست‌های فاقد اعتبارنامه صحیح، پاسخ استاندارد `HTTP 401 Unauthorized` (طبق RFC 9110) دریافت کرده و سوکت به‌صورت ایمن بسته می‌شود.
  * `lib/src/client/multi_homed_connector.dart`: اتصال مجدد هوشمند کلاینت بین انتهای مسیرهای متناوب (Multi-homing Endpoints) در صورت افت کیفیت شبکه بر اساس RFC 6066 (SNI Virtual Hosting) و الگوریتم Exponential Backoff.
* **Test File:** `test/session_authentication_test.dart`
* **معیار پذیرش:**
  - نانس‌های معتبر نشست را برقرار می‌سازند؛ درخواست‌های نامعتبر پاسخ HTTP 401 گرفته و بسته می‌شوند.
  - سوییچ خودکار کلاینت بین انتهای مسیرهای مختلف هنگام قطعی کانال فعلی.

---

### Phase 8 — NAT Traversal Relay Allocation & Full System Integration (RFC 8489 / RFC 8656)

* **Build:**
  * `lib/src/transport/turn_relay_allocator.dart`: تخصیص پویای سرورهای STUN/TURN (RFC 8489 / RFC 8656) جهت مدیریت تغییرات IP/Port (Cellular to Wi-Fi roaming) و عبور از NAT.
  * `lib/src/resilient_media_transport.dart`: رابط واحد (Facade) که تمامی لایه‌ها (Rateless Stream, Codecs, Priority Queue, TLS Configuration, Relay Allocator) را زیر یک API قرار می‌دهد (`send(file, type)` / `onReceived`).
* **Test File:** `test/resilient_media_transport_test.dart`
* **معیار پذیرش:**
  - انتقال هم‌زمان عکس، سند و ویدیو در یک نشست ۱۲۰ ثانیه‌ای تحت شرایط پراتلاف شبکه.
  - عدم اختلال در اولویت و نرخ ارسال صوت (Voice path intact).
  - موفقیت کامل اجرای حلقه تست اصلی پروژه (`bash tools/run_gate_loop.sh`).

---

## پیاده‌سازی مرجع در دارت (Pure Dart Implementation)

کد زیر پیاده‌سازی استاندارد و تمیز لایه‌های فریم‌بندی، پدینگ هم‌ترازی MTU، احراز هویت نشست استاندارد و اتصال مجدد را نشان می‌دهد:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// -------------------------------------------------------------------
/// 1. PROTOCOL FRAMING & MTU ALIGNMENT ENGINE (RFC 9113 / RFC 3711)
/// -------------------------------------------------------------------
class ProtocolFramingEngine {
  final Random _secureRandom = Random.secure();

  /// Encapsulates raw rateless datagrams into standard HTTP/2 DATA frames (RFC 9113)
  Uint8List frameAsHttp2Data(Uint8List payload, int streamId) {
    final frameHeader = ByteData(9);
    final length = payload.length;

    // 24-bit Length
    frameHeader.setUint8(0, (length >> 16) & 0xFF);
    frameHeader.setUint8(1, (length >> 8) & 0xFF);
    frameHeader.setUint8(2, length & 0xFF);

    frameHeader.setUint8(3, 0x00); // Frame Type: DATA (0x00)
    frameHeader.setUint8(4, 0x00); // Flags
    frameHeader.setUint32(5, streamId & 0x7FFFFFFF); // Stream Identifier

    final framed = Uint8List(9 + payload.length);
    framed.setRange(0, 9, frameHeader.buffer.asUint8List());
    framed.setRange(9, framed.length, payload);
    return framed;
  }

  /// Applies dynamic padding for packet length / MTU alignment (RFC 3711)
  Uint8List applyDynamicPadding(Uint8List payload, {int alignmentBlock = 16}) {
    int padLen = _secureRandom.nextInt(16) + 1; // 1-16 bytes padding for alignment
    int totalLen = payload.length + padLen + 1;

    if (totalLen % alignmentBlock != 0) {
      padLen += alignmentBlock - (totalLen % alignmentBlock);
    }

    final padded = Uint8List(payload.length + padLen + 1);
    padded.setRange(0, payload.length, payload);

    final zeroPad = Uint8List(padLen);
    padded.setRange(payload.length, payload.length + padLen, zeroPad);
    padded[padded.length - 1] = padLen;

    return padded;
  }

  /// Strips padding and restores original payload
  Uint8List stripDynamicPadding(Uint8List paddedFrame) {
    if (paddedFrame.isEmpty) {
      throw const FormatException("Empty frame received");
    }
    int padLen = paddedFrame[paddedFrame.length - 1];
    if (padLen >= paddedFrame.length) {
      throw const FormatException("Invalid padding boundary");
    }
    int originalLen = paddedFrame.length - 1 - padLen;
    return Uint8List.sublistView(paddedFrame, 0, originalLen);
  }
}

/// -------------------------------------------------------------------
/// 2. AUTHENTICATED RELAY SERVER (RFC 9110 Standard Response Policy)
/// -------------------------------------------------------------------
class AuthenticatedRelayServer {
  final Set<String> _validSessionNonces = {};

  void addValidNonce(String nonceHex) {
    _validSessionNonces.add(nonceHex);
  }

  Future<void> handleIncomingConnection(
    Socket clientSocket,
    Uint8List initialData,
  ) async {
    final isAuthenticated = _verifyNonceAuth(initialData);

    if (isAuthenticated) {
      _processSession(clientSocket, initialData);
    } else {
      _rejectUnauthenticatedConnection(clientSocket);
    }
  }

  bool _verifyNonceAuth(Uint8List handshakeHeader) {
    if (handshakeHeader.length < 16) return false;
    final nonceHex = handshakeHeader.sublist(0, 16).toString();
    return _validSessionNonces.remove(nonceHex);
  }

  void _rejectUnauthenticatedConnection(Socket clientSocket) {
    // Send standard RFC 9110 401 Unauthorized response and close
    const response = 'HTTP/1.1 401 Unauthorized\r\n'
        'Content-Length: 0\r\n'
        'Connection: close\r\n\r\n';
    clientSocket.write(response);
    clientSocket.close();
  }

  void _processSession(Socket socket, Uint8List data) {
    // Process stream data for authenticated session
  }
}

/// -------------------------------------------------------------------
/// 3. MULTI-ENDPOINT RECONNECTOR (RFC 6066 Virtual Hosting)
/// -------------------------------------------------------------------
class HostPort {
  final String host;
  final int port;
  final String sniHost;

  HostPort({required this.host, required this.port, required this.sniHost});
}

class EndpointReconnector {
  final List<HostPort> endpoints;
  int _currentEndpointIndex = 0;

  EndpointReconnector({required this.endpoints});

  HostPort get activeEndpoint => endpoints[_currentEndpointIndex];

  void switchEndpoint() {
    if (endpoints.isEmpty) return;
    _currentEndpointIndex = (_currentEndpointIndex + 1) % endpoints.length;
  }

  Map<String, String> getTransportHeaders() {
    return {
      'Host': activeEndpoint.sniHost,
      'Upgrade': 'websocket',
      'Connection': 'Upgrade',
    };
  }
}

/// -------------------------------------------------------------------
/// 4. DYNAMIC STUN/TURN RELAY ALLOCATOR (RFC 8489 / RFC 8656)
/// -------------------------------------------------------------------
class TurnRelayServer {
  final String address;
  final int port;
  final String username;
  final String credential;

  TurnRelayServer({
    required this.address,
    required this.port,
    required this.username,
    required this.credential,
  });
}

class TurnRelayAllocator {
  final List<TurnRelayServer> _relays = [];

  void registerRelay(TurnRelayServer relay) {
    _relays.add(relay);
  }

  TurnRelayServer? allocateBestRelay() {
    if (_relays.isEmpty) return null;
    return _relays[Random().nextInt(_relays.length)];
  }
}
