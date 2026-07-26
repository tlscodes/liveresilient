این سند کامل، بازسازی‌شده و مدرن، به عنوان **نقشه راه مهندسی نهایی (Phased Plan)** برای ذخیره در فایل `docs/BRIEF_media_transport.md` یا استفاده مستقیم در پروژه تنظیم شده است. تمامی الگوهای پایداری لایه شبکه، فشرده‌سازی، نرمال‌سازی پارامترهای TLS 1.3 طبق RFC 8701، و تخصیص رله STUN/TURN طبق RFC 8489/8656 به‌صورت کاملاً استاندارد بر اساس RFCهای رسمی در قالب ۸ فاز مستقل و تست‌پذیر ادغام شده‌اند.

---

## وضعیت اجرا (به‌روزرسانی 2026-07-26)

فازهای ۱ تا ۵ بسته، کامیت‌شده و همه با gate سبز؛ فازهای ۶ تا ۸ هنوز پیاده‌سازی نشده‌اند.

| # | فاز | وضعیت | عدد اندازه‌گیری‌شده |
|---|---|---|---|
| 1 | RLNC روی GF(2^8) | بسته | epsilon = 1.0000 (کف تئوری اطلاعات؛ هسته‌ی قبلی LT بود 1.33) |
| 2 | تخمین‌گر کور کانال (Baum-Welch) | بسته | p=0.045/r=0.093 در برابر واقعی 0.04/0.1؛ صفر فیدبک |
| 3 | صف round-robin با مکان‌نمای پایدار | بسته | A/B تراز دقیق 129/129؛ بدون گرسنگی |
| 4a | سند — موتور CM به‌جای gzip9 | بسته | 1822 → 1277 B (−29.9%) |
| 4b | پیرامید تصویر — رقابت سه کدک در هر سطح | بسته | 579 → 551 B (سطح پایه 50 → 37 B) |
| 4c | فلیپ‌بوک — سه پیش‌بین رقیب + جبران حرکت | بسته | ساکن: بدون سربار؛ پن: 28238 → 24259 B (−14.1%) |
| 5 | یکپارچه‌سازی + تحویل لایه‌ای | بسته | پیش‌نمایش اول: 21.4s → 7.6s (۲.۸ برابر سریع‌تر) |
| 6 | نرمال‌سازی پارامترهای TLS 1.3 + هم‌ترازی طول بسته | باز | — |
| 7 | احراز نشست + اتصال مجدد چند-نقطه‌ای | باز | — |
| 8 | تخصیص رله STUN/TURN + یکپارچه‌سازی نهایی | باز | — |

کامیت‌های مرجع: `fc88c1f` (فاز 2 پایه)، `f28540e` (فاز 1)، `9e50dbf` (فاز 3)، `cb1647b` (فاز 4a)، `ba18785` (فاز 4b/4c اولیه)، `983117e` (فاز 4b رقابتی + فاز 5 لایه‌ای).

---

# Brief — Resilient Media Transport & Transport-Layer Normalization — Phased Plan

**Stage Goal:** The voice path already survives the measured hostile field profile (a few hundred bytes per second, 85–95% packet loss, multi-second delay, tens-of-bytes MTU). This stage gives files (photos, short videos, documents) the same survivability over the same constrained path, using only the spare wire budget voice is not using, while ensuring protocol-level resilience against active probing, TLS fingerprinting, and statistical traffic analysis.

Everything here is structured as standard transport protocol engineering: rateless erasure coding, low-rate media compression, adaptive queue scheduling, TLS fingerprint normalization (RFC 8446 / RFC 8701), encapsulation (RFC 9113 / RFC 8831), and proxy steering (RFC 6066 / RFC 9110).

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                   RESILIENT MEDIA TRANSPORT STACK (PHASES 1 - 8)                 │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 8: Full Integration, Ephemeral STUN/TURN Relays & Gate Loop                │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 7: Session Authentication & Multi-Endpoint Reconnect (RFC 9110 / RFC 6066) │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 6: TLS 1.3 Parameter Normalization & Packet-Length Alignment (RFC 8701)     │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 5: Low-Rate Photo & Video Flipbook Compressors                             │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 4: Text Document Compression Pipeline                                      │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 3: Background Media Queue with Strict Voice Priority                       │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 2: Rateless Code over Hostile Channel Simulator                            │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Phase 1: Rateless Erasure Code Core (Zero-Feedback LT Stream)                   │
└──────────────────────────────────────────────────────────────────────────────────┘

```

---

## How This Plan Runs

Eight phases, each independently testable and independently shippable. A phase is **CLOSED** only when its own tests are green AND the full gate loop is green (`bash tools/run_gate_loop.sh`), then committed. No phase starts before the previous one is closed.

Every phase below defines:

1. **What is built** (exact class/file paths).
2. **The test file**.
3. **Acceptance criteria and metrics** (numbers marked `measure` are recorded by the test's diagnostic output and pinned after the initial baseline run).

---

## Phase 1 — Rateless Erasure Code Core (No Network)

* **Build:** `packages/connection_orchestrator/lib/src/rateless_stream.dart` with `RatelessEncoder` and `RatelessDecoder`.
* An LT (Luby-Transform) core with robust soliton degree distribution plus a systematic prefix: the first $N$ datagrams are source blocks, followed by XOR parity over seeded pseudo-random block subsets. Zero-feedback family (RFC 6330 principles).


* **Wire Format:** Each datagram is 36–60 bytes carrying:

$$\text{Payload Format: } [\text{u16 } \text{esi}] \cdot [\text{u16 } \text{blockCount}] \cdot [\text{payload}] \cdot [\text{u8 } \text{crc8}]$$



Reuses the CRC-8 polynomial from `micro_datagram_lane.dart`.
* **Test File:** `test/rateless_stream_test.dart`
* Round-trip with zero loss is bit-exact for 1 B, 100 B, 2 KB, 64 KB.
* Decoding from a random subset in random order is bit-exact.
* A datagram with any single bit flipped is rejected via CRC validation.
* Overhead $\epsilon = \frac{\text{distinct datagrams needed}}{N}$: assert $\epsilon < 1.6$, measure and print actual ratio.
* Decoder memory stays bounded: feeding $20\times$ more datagrams than needed does not grow internal state past $N$ entries.


* **Closes when:** Tests green plus `bash tools/run_gate_loop.sh` green.

---

## Phase 2 — Rateless Code over Hostile Channel

* **Build:** Integration of Phase 1 into existing channel simulators (`GilbertElliottLossSimulator`).
* **Test File:** `test/rateless_hostile_test.dart`
* 2 KB file over 95% uniform loss layered with burst loss (mean 10-packet bursts) and up to 5s jitter with packet reordering.
* Assert reconstruction is bit-exact.
* Assert receiver sends exactly 0 packets (zero-feedback verification).
* Assert no unhandled exceptions on truncated/corrupted datagrams.
* `measure`: datagrams sent, delivered, $\epsilon$, wire time at 300 B/s.


* **Closes when:** Tests green plus gate loop green.

---

## Phase 3 — Background Queue with Voice Priority

* **Build:** `lib/src/media_queue.dart` with `MediaTransferQueue`.
* Emits media datagrams only while `SilenceSuppressionVAD` reports silence, up to a configured cap (200–500 B/s).
* Interrupted transfers resume seamlessly by emitting additional rateless parity frames (no session renegotiation required).


* **Test File:** `test/media_queue_test.dart`
* Emits 0 media datagrams during speech windows.
* Emits $\le \text{cap}$ during silence windows.
* Strict voice-priority assertion: Run identical voice schedules with and without media transfer active; assert voice datagram send ticks are identical sequences.
* Transfers spanning multiple speech/silence alternations complete bit-exact.


* **Closes when:** Tests green plus gate loop green.

---

## Phase 4 — Document Compression Pipeline

* **Build:** `lib/src/media_codecs/text_document_compressor.dart`.
* Extracts raw text layer, strips layout/embedded resources, and applies max-level in-process compression (gzip / Brotli binding).


* **Test File:** `test/text_document_compressor_test.dart`
* Round-trip is character-exact for ASCII, Persian, and mixed UTF-8 text.
* Compressed size on a representative 10 KB document is measured and pinned.
* Handles empty and 1-character inputs gracefully.


* **Closes when:** Tests green plus gate loop green.

---

## Phase 5 — Low-Rate Photo & Video Flipbook Codecs

* **Build:**
* `lib/src/media_codecs/low_rate_image_compressor.dart`: Progressive thumbnail generator (~1 KB target) + SVG contour tracing (300–800 B target).
* `lib/src/media_codecs/flipbook_video_compressor.dart`: Downsamples video to 120x80 monochrome keyframes at ~1 frame per 3 seconds (~300 B per keyframe).


* **Test File:** `test/media_codecs_test.dart`
* Image output size fits target band; progressive prefix decodes without error.
* Video keyframe count matches rate for input duration; frame order preserved.
* Lossy assertion: Structural similarity (SSIM) + size bounds (never bit-exactness).


* **Closes when:** Tests green plus gate loop green.

---

## Phase 6 — TLS 1.3 Parameter Normalization & Packet-Length Alignment

* **Build:**
* `lib/src/transport/malleable_tls.dart`: TLS 1.3 ClientHello extension ordering and cipher-suite list matched to a standard browser stack, with RFC 8701 GREASE values injected per spec.
* `lib/src/transport/micro_datagram_lane.dart`: RFC 3711 style packet padding so datagram length does not vary with payload content.
* Encapsulation of rateless frames inside HTTP/2 DATA frames (RFC 9113) or WebRTC SCTP DataChannels (RFC 8831).



### Reference Blueprint — Malleable TLS & Padding Core

```dart
import 'dart:typed_data';
import 'dart:math';

/// RFC 3711 / SRTP-style Packet Padding & Length Normalization
class MicroDatagramLane {
  final Random _cryptoRandom = Random.secure();

  /// Adds variable-length padding to normalize payload length distribution
  Uint8List encodeWithPadding(Uint8List payload, {int blockSize = 16}) {
    int currentLen = payload.length;
    int padLength = _cryptoRandom.nextInt(32) + 1; // 1 to 32 bytes random pad
    int totalLen = currentLen + padLength + 1;

    if (totalLen % blockSize != 0) {
      padLength += blockSize - (totalLen % blockSize);
    }

    final padded = Uint8List(currentLen + padLength + 1);
    padded.setRange(0, currentLen, payload);

    final padBytes = List<int>.generate(padLength, (_) => _cryptoRandom.nextInt(256));
    padded.setRange(currentLen, currentLen + padLength, padBytes);

    padded[padded.length - 1] = padLength;
    return padded;
  }

  /// Bit-exact payload restoration by stripping random padding
  Uint8List decodeAndStripPadding(Uint8List paddedFrame) {
    if (paddedFrame.isEmpty) throw FormatException("Empty frame received");

    int padLength = paddedFrame[paddedFrame.length - 1];
    if (padLength >= paddedFrame.length) {
      throw FormatException("Invalid padding boundary length: $padLength");
    }

    int originalLength = paddedFrame.length - 1 - padLength;
    return Uint8List.sublistView(paddedFrame, 0, originalLength);
  }
}

/// RFC 8701 GREASE & Malleable ClientHello Configuration
class MalleableTlsConfig {
  static const List<int> greaseValues = [
    0x0A0A, 0x1A1A, 0x2A2A, 0x3A3A,
    0x4A4A, 0x5A5A, 0x6A6A, 0x7A7A,
  ];

  int getGreaseValue() {
    final rng = Random.secure();
    return greaseValues[rng.nextInt(greaseValues.length)];
  }

  /// Synthesizes a Chrome-like cipher suite array with GREASE injected
  List<int> buildNormalizedCipherSuites() {
    final grease = getGreaseValue();
    return [
      grease,
      0x1301, // TLS_AES_128_GCM_SHA256
      0x1302, // TLS_AES_256_GCM_SHA384
      0x1303, // TLS_CHACHA20_POLY1305_SHA256
      0xC02B, // ECDHE-ECDSA-AES128-GCM-SHA256
      0xC02F, // ECDHE-RSA-AES128-GCM-SHA256
    ];
  }
}

```

* **Test File:** `test/edge_transport_conformance_test.dart`
* Assert padded payload restoration is bit-exact across variable length inputs.
* Assert TLS configuration emits valid GREASE values (RFC 8701) and standardized ALPNs.
* Assert HTTP/2 / WebRTC frame headers match RFC specification boundaries.


* **Closes when:** Tests green plus gate loop green.

---

## Phase 7 — Session Authentication & Multi-Endpoint Reconnect

* **Build:**
* `lib/src/server/authenticated_relay_server.dart`: Short-lived HMAC/nonce handshake authentication (RFC 9110 semantics). A connection that fails authentication is proxied to a fixed upstream host rather than reset, so a failed handshake produces standard HTTPS traffic instead of a distinguishable error response.
* `lib/src/client/multi_homed_connector.dart`: Client-side reconnect across a configured list of endpoints (RFC 6066 SNI virtual hosting) with backoff, so a single endpoint outage does not end the call.



### Reference Blueprint — Authenticated Relay & Multi-Endpoint Reconnect

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class AuthenticatedRelayServer {
  final String fallbackTargetHost = "www.microsoft.com";
  final int fallbackTargetPort = 443;
  final Set<String> _validSessionNonces = {};

  Future<void> handleIncomingConnection(Socket clientSocket, Uint8List initialData) async {
    bool isAuthenticated = _verifyNonceAuth(initialData);

    if (isAuthenticated) {
      _processOrchestratedSession(clientSocket, initialData);
    } else {
      // Unauthenticated connection: proxy to the fixed upstream host per RFC 9110
      await _transparentProxyFallback(clientSocket, initialData);
    }
  }

  bool _verifyNonceAuth(Uint8List handshakeHeader) {
    if (handshakeHeader.length < 16) return false;
    String nonceHex = handshakeHeader.sublist(0, 16).toString();
    return _validSessionNonces.remove(nonceHex);
  }

  Future<void> _transparentProxyFallback(Socket clientSocket, Uint8List initialData) async {
    try {
      final targetSocket = await Socket.connect(fallbackTargetHost, fallbackTargetPort);
      targetSocket.add(initialData);

      clientSocket.pipe(targetSocket);
      targetSocket.pipe(clientSocket);
    } catch (e) {
      clientSocket.destroy();
    }
  }

  void _processOrchestratedSession(Socket socket, Uint8List data) {}
}

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
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Upgrade': 'websocket',
      'Connection': 'Upgrade',
    };
  }
}

```

* **Test File:** `test/active_probing_defense_test.dart`
* Valid nonces pass to internal orchestrator; invalid/probe nonces initiate transparent fallback socket pipe.
* Edge connector reconnects to the next configured endpoint upon simulated connection loss.


* **Closes when:** Tests green plus gate loop green.

---

## Phase 8 — NAT Traversal Relay Allocation & Full System Integration

* **Build:**
* `lib/src/transport/turn_relay_allocator.dart`: Dynamic STUN/TURN allocation (RFC 8489 / RFC 8656) for mid-session transport migration.
* `lib/src/resilient_media_transport.dart`: Facade tying rateless stream, codecs, queue, malleable TLS, and probe defense behind unified API (`send(file, type)` / `onReceived`).



### Verification Suite — Phases 7 & 8 (`test/advanced_resilience_stack_test.dart`)

```dart
import 'dart:typed_data';
import 'package:test/test.dart';
import '../lib/transport/malleable_tls.dart';
import '../lib/client/ws_connector.dart';

void main() {
  group('Phase 7 & Phase 8 Advanced Network Resilience Stack', () {
    late MicroDatagramLane lane;

    setUp(() {
      lane = MicroDatagramLane();
    });

    test('Variable packet padding maintains bit-exact payload restoration', () {
      final originalPayload = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05, 0xAA, 0xBB]);
      
      final paddedFrame = lane.encodeWithPadding(originalPayload, blockSize: 16);
      expect(paddedFrame.length, greaterThan(originalPayload.length));

      final decodedPayload = lane.decodeAndStripPadding(paddedFrame);
      expect(decodedPayload, equals(originalPayload));
    });

    test('Multi-Homed Connector cycles through configured endpoints on connection loss', () {
      final bridges = [
        HostPort(host: '192.0.2.1', port: 443, sniHost: 'edge1.cdn.com'),
        HostPort(host: '192.0.2.2', port: 443, sniHost: 'edge2.cdn.com'),
      ];

      final connector = EndpointReconnector(endpoints: bridges);
      expect(connector.activeEndpoint.sniHost, equals('edge1.cdn.com'));

      connector.switchEndpoint();
      expect(connector.activeEndpoint.sniHost, equals('edge2.cdn.com'));

      connector.switchEndpoint();
      expect(connector.activeEndpoint.sniHost, equals('edge1.cdn.com'));
    });

    test('GREASE injection generates valid RFC 8701 values', () {
      final tlsConfig = MalleableTlsConfig();
      final cipherSuites = tlsConfig.buildNormalizedCipherSuites();

      expect(cipherSuites.length, greaterThan(5));
      expect(MalleableTlsConfig.greaseValues.contains(cipherSuites.first), isTrue);
    });
  });
}

```

* **Test File:** `test/resilient_media_transport_test.dart`
* Concurrent photo, document, and video flipbook transfer during a live 120-second hostile channel call.
* Voice coverage stays at Phase 5 baseline (proving media transfers never steal voice wire budget).
* Diagnostic line reports per-type compressed sizes, media wire B/s, transfer times, and full gate pass (`bash tools/run_gate_loop.sh`).


* **Closes when:** All tests green plus gate loop green.

---

## Working Rules

* **Commit Policy:** Implementation + tests + green `bash tools/run_gate_loop.sh` before each commit; strictly one commit per phase.
* **Technical Language:** Plain technical language in code, documentation, and comments; describe behavior precisely using standard RFC terms.
* **Empirical Validation:** Measured numbers only. Simulated channel results are explicitly labeled as simulated.
* **Lossy Boundaries:** Lossy codecs assert structural similarity and size bounds, never bit-exactness. Transport layers always assert bit-exactness.