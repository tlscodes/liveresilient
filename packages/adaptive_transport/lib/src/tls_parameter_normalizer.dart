import 'dart:math';

/// RFC 8701 GREASE value generation and cipher-suite list construction.
/// GREASE (Generate Random Extensions And Sustain Extensibility) values
/// are reserved values a TLS client sends to stop peers from ossifying
/// on today's fixed set of extension/cipher IDs.
class TlsParameterNormalizer {
  TlsParameterNormalizer({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  static const List<int> greaseValues = [
    0x0A0A, 0x1A1A, 0x2A2A, 0x3A3A,
    0x4A4A, 0x5A5A, 0x6A6A, 0x7A7A,
    0x8A8A, 0x9A9A, 0xAAAA, 0xBABA,
    0xCACA, 0xDADA, 0xEAEA, 0xFAFA,
  ];

  bool isGreaseValue(int value) => greaseValues.contains(value);

  int pickGreaseValue() => greaseValues[_random.nextInt(greaseValues.length)];

  /// Standard TLS 1.3 AEAD suites plus common ECDHE fallbacks, with one
  /// GREASE value prepended per RFC 8701 section 3.
  List<int> buildCipherSuites() {
    return [
      pickGreaseValue(),
      0x1301, // TLS_AES_128_GCM_SHA256
      0x1302, // TLS_AES_256_GCM_SHA384
      0x1303, // TLS_CHACHA20_POLY1305_SHA256
      0xC02B, // ECDHE-ECDSA-AES128-GCM-SHA256
      0xC02F, // ECDHE-RSA-AES128-GCM-SHA256
    ];
  }

  static const List<String> standardAlpnProtocols = ['h2', 'http/1.1'];
}
