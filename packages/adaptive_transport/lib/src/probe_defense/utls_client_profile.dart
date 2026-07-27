/// Browser Client Hello profiles and a byte-exact Client Hello builder.
///
/// The point of a profile is that our hello is *indistinguishable in shape*
/// from the browser it names: same cipher list, same extension set, same
/// GREASE habits, same key-exchange groups — including the hybrid
/// post-quantum groups that Chrome and Firefox now offer by default, whose
/// absence has itself become a distinguishing signal.
///
/// Honest scope note: `dart:io`'s `SecureSocket` owns its own handshake and
/// gives no hook to author a Client Hello, so this builder exists to drive a
/// raw-socket TLS path (or to be asserted against in tests) — importing it
/// does not retroactively change the fingerprint of a `SecureSocket`.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'tls_client_hello.dart';

/// Named key-exchange groups, including the hybrid post-quantum ones.
class TlsNamedGroup {
  const TlsNamedGroup._();

  static const int secp256r1 = 0x0017;
  static const int secp384r1 = 0x0018;
  static const int secp521r1 = 0x0019;
  static const int x25519 = 0x001D;

  /// Hybrid X25519 + ML-KEM-768, the group Chrome and Firefox ship on by
  /// default (RFC draft `X25519MLKEM768`).
  static const int x25519MlKem768 = 0x11EC;

  /// Hybrid P-256 + ML-KEM-768.
  static const int secp256r1MlKem768 = 0x11EB;

  /// The superseded pre-standard hybrid (`X25519Kyber768Draft00`). Kept
  /// only so a profile pinned to an older browser build stays accurate.
  static const int x25519Kyber768Draft00 = 0x6399;

  /// Whether [group] is one of the hybrid post-quantum groups.
  static bool isPostQuantum(int group) =>
      group == x25519MlKem768 ||
      group == secp256r1MlKem768 ||
      group == x25519Kyber768Draft00;

  /// Public-key size on the wire, used when a caller asks the builder to
  /// synthesize a placeholder key share of the right shape.
  static int keyShareLength(int group) => switch (group) {
        x25519 => 32,
        secp256r1 => 65,
        secp384r1 => 97,
        secp521r1 => 133,
        // 32-byte X25519 share concatenated with the 1184-byte ML-KEM-768
        // encapsulation key.
        x25519MlKem768 => 1216,
        x25519Kyber768Draft00 => 1216,
        // 65-byte P-256 point concatenated with the same ML-KEM-768 key.
        secp256r1MlKem768 => 1249,
        _ => 32,
      };
}

/// Which browser a hello should look like.
enum UtlsProfileId { chrome120, firefox120, safari17 }

/// A concrete browser Client Hello shape.
class UtlsClientProfile {
  const UtlsClientProfile({
    required this.id,
    required this.cipherSuites,
    required this.extensionOrder,
    required this.supportedGroups,
    required this.keyShareGroups,
    required this.signatureAlgorithms,
    required this.alpnProtocols,
    required this.usesGrease,
    required this.shufflesExtensions,
    required this.recordSizeLimit,
    required this.defaultTcpProfile,
  });

  final UtlsProfileId id;

  /// Cipher suites in offer order, GREASE excluded (the builder inserts it).
  final List<int> cipherSuites;

  /// Extension types in the order this browser emits them. When
  /// [shufflesExtensions] is set this is the *set*, not a promise of order.
  final List<int> extensionOrder;

  /// `supported_groups`, GREASE excluded.
  final List<int> supportedGroups;

  /// Groups for which a real `key_share` entry is sent (browsers send far
  /// fewer shares than they advertise groups).
  final List<int> keyShareGroups;

  final List<int> signatureAlgorithms;
  final List<String> alpnProtocols;

  /// Whether this browser sends RFC 8701 GREASE values. Firefox does not —
  /// adding GREASE to a Firefox profile would *create* an anomaly.
  final bool usesGrease;

  /// Chrome has permuted its extension order per connection since Chrome
  /// 110. A profile that claims Chrome and emits a fixed order is itself a
  /// signal; JA4 is unaffected because it sorts.
  final bool shufflesExtensions;

  /// `record_size_limit` value, or null when the browser omits it.
  final int? recordSizeLimit;

  /// The OS TCP stack that should accompany this profile — Safari implies
  /// an Apple stack, and a Safari hello over a Linux-default TTL is a
  /// contradiction a passive fingerprinter reads for free.
  final String defaultTcpProfile;

  /// Whether the profile offers a hybrid post-quantum key exchange.
  bool get offersPostQuantum =>
      keyShareGroups.any(TlsNamedGroup.isPostQuantum);

  static const UtlsClientProfile chrome120 = UtlsClientProfile(
    id: UtlsProfileId.chrome120,
    cipherSuites: [
      0x1301, 0x1302, 0x1303, //
      0xC02B, 0xC02F, 0xC02C, 0xC030,
      0xCCA9, 0xCCA8,
      0xC013, 0xC014, 0x009C, 0x009D, 0x002F, 0x0035,
    ],
    extensionOrder: [
      TlsExtensionType.serverName,
      0x0017, // extended_master_secret
      0xFF01, // renegotiation_info
      TlsExtensionType.supportedGroups,
      TlsExtensionType.ecPointFormats,
      0x0023, // session_ticket
      TlsExtensionType.alpn,
      0x0005, // status_request
      TlsExtensionType.signatureAlgorithms,
      0x0012, // signed_certificate_timestamp
      0x0033, // key_share
      0x002D, // psk_key_exchange_modes
      TlsExtensionType.supportedVersions,
      0x001B, // compress_certificate
      0x4469, // application_settings (ALPS)
    ],
    supportedGroups: [
      TlsNamedGroup.x25519MlKem768,
      TlsNamedGroup.x25519,
      TlsNamedGroup.secp256r1,
      TlsNamedGroup.secp384r1,
    ],
    keyShareGroups: [TlsNamedGroup.x25519MlKem768, TlsNamedGroup.x25519],
    signatureAlgorithms: [
      0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601,
    ],
    alpnProtocols: ['h2', 'http/1.1'],
    usesGrease: true,
    shufflesExtensions: true,
    recordSizeLimit: null,
    defaultTcpProfile: 'windows',
  );

  static const UtlsClientProfile firefox120 = UtlsClientProfile(
    id: UtlsProfileId.firefox120,
    cipherSuites: [
      0x1301, 0x1303, 0x1302, //
      0xC02B, 0xC02F, 0xCCA9, 0xCCA8, 0xC02C, 0xC030,
      0xC00A, 0xC009, 0xC013, 0xC014,
      0x009C, 0x009D, 0x002F, 0x0035,
    ],
    extensionOrder: [
      TlsExtensionType.serverName,
      0x0017,
      0xFF01,
      TlsExtensionType.supportedGroups,
      TlsExtensionType.ecPointFormats,
      0x0023,
      TlsExtensionType.alpn,
      0x0005,
      0x0022, // delegated_credentials
      0x0033,
      0x002D,
      TlsExtensionType.supportedVersions,
      TlsExtensionType.signatureAlgorithms,
      0x001C, // record_size_limit
    ],
    supportedGroups: [
      TlsNamedGroup.x25519MlKem768,
      TlsNamedGroup.x25519,
      TlsNamedGroup.secp256r1,
      TlsNamedGroup.secp384r1,
      TlsNamedGroup.secp521r1,
    ],
    keyShareGroups: [TlsNamedGroup.x25519MlKem768, TlsNamedGroup.x25519],
    signatureAlgorithms: [
      0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806, //
      0x0401, 0x0501, 0x0601, 0x0203, 0x0201,
    ],
    alpnProtocols: ['h2', 'http/1.1'],
    usesGrease: false,
    shufflesExtensions: false,
    recordSizeLimit: 0x4001,
    defaultTcpProfile: 'linux',
  );

  static const UtlsClientProfile safari17 = UtlsClientProfile(
    id: UtlsProfileId.safari17,
    cipherSuites: [
      0x1301, 0x1302, 0x1303, //
      0xC02C, 0xC02B, 0xCCA9, 0xC030, 0xC02F, 0xCCA8,
      0xC024, 0xC023, 0xC028, 0xC027, 0xC00A, 0xC009, 0xC014, 0xC013,
      0x009D, 0x009C, 0x003D, 0x003C, 0x0035, 0x002F,
    ],
    extensionOrder: [
      TlsExtensionType.serverName,
      0x0017,
      0xFF01,
      TlsExtensionType.supportedGroups,
      TlsExtensionType.ecPointFormats,
      TlsExtensionType.alpn,
      0x0005,
      TlsExtensionType.signatureAlgorithms,
      0x0012,
      0x0033,
      0x002D,
      TlsExtensionType.supportedVersions,
      0x001B,
    ],
    supportedGroups: [
      TlsNamedGroup.x25519,
      TlsNamedGroup.secp256r1,
      TlsNamedGroup.secp384r1,
      TlsNamedGroup.secp521r1,
    ],
    // Safari 17 ships no hybrid group; claiming Safari while offering
    // ML-KEM would be a self-inflicted anomaly.
    keyShareGroups: [TlsNamedGroup.x25519],
    signatureAlgorithms: [
      0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, //
      0x0806, 0x0601, 0x0201,
    ],
    alpnProtocols: ['h2', 'http/1.1'],
    usesGrease: true,
    shufflesExtensions: false,
    recordSizeLimit: null,
    defaultTcpProfile: 'ios',
  );

  /// Look-up by [UtlsProfileId].
  static UtlsClientProfile forId(UtlsProfileId id) => switch (id) {
        UtlsProfileId.chrome120 => chrome120,
        UtlsProfileId.firefox120 => firefox120,
        UtlsProfileId.safari17 => safari17,
      };

  static const List<UtlsClientProfile> all = [
    chrome120,
    firefox120,
    safari17,
  ];
}

/// Builds a byte-exact Client Hello for a [UtlsClientProfile].
class UtlsClientHelloBuilder {
  UtlsClientHelloBuilder({
    required this.profile,
    Random? random,
  }) : _random = random ?? Random.secure();

  final UtlsClientProfile profile;
  final Random _random;

  /// Serializes a Client Hello handshake message (no record header).
  ///
  /// [serverName] is omitted from the hello when null — which is what an
  /// ECH-enabled client does for the *inner* hello, since the real name
  /// travels encrypted.
  ///
  /// [keyShares] supplies real public keys per group. Groups without an
  /// entry get a correctly-sized placeholder so length-based analysis sees
  /// the right shape in tests; production must pass real shares.
  ///
  /// [echPayload] is the serialized `encrypted_client_hello` body. When
  /// [enableEch] is set without a payload, a GREASE ECH extension is
  /// emitted — the same thing Chrome sends when it has no ECH config, so
  /// its presence is not itself a tell.
  Uint8List build({
    String? serverName,
    Map<int, Uint8List> keyShares = const {},
    Uint8List? sessionId,
    Uint8List? clientRandom,
    bool enableEch = false,
    Uint8List? echPayload,
    int? padToLength,
  }) {
    final body = BytesBuilder(copy: false);
    body.add(_uint16(0x0303)); // legacy_version
    body.add(clientRandom ?? _randomBytes(32));
    final sid = sessionId ?? _randomBytes(32);
    body.add(_vector8(sid));
    body.add(_vector16(_uint16List(_cipherSuitesWithGrease())));
    body.add(_vector8(Uint8List.fromList(const [0x00]))); // no compression

    var extensions = _buildExtensions(
      serverName: serverName,
      keyShares: keyShares,
      enableEch: enableEch,
      echPayload: echPayload,
    );
    if (profile.shufflesExtensions) {
      extensions = _shufflePreservingAnchors(extensions);
    }

    var encodedExtensions = _encodeExtensions(extensions);
    if (padToLength != null) {
      // Header (4) + fixed body so far + the extensions block itself.
      final projected = 4 + body.length + 2 + encodedExtensions.length;
      if (projected < padToLength) {
        // The padding extension's own 4-byte header is part of the cost.
        final zeros = padToLength - projected - 4;
        if (zeros >= 0) {
          extensions.add(
            TlsExtension(TlsExtensionType.padding, Uint8List(zeros)),
          );
          encodedExtensions = _encodeExtensions(extensions);
        }
      }
    }
    body.add(_vector16(encodedExtensions));

    final bodyBytes = body.toBytes();
    final message = BytesBuilder(copy: false)
      ..addByte(tlsClientHelloType)
      ..add(_uint24(bodyBytes.length))
      ..add(bodyBytes);
    return message.toBytes();
  }

  /// Wraps [handshake] in a TLS handshake record header.
  static Uint8List wrapInRecord(Uint8List handshake) {
    final record = BytesBuilder(copy: false)
      ..addByte(tlsHandshakeContentType)
      ..add(_uint16(0x0301)) // legacy record version, per RFC 8446 5.1
      ..add(_uint16(handshake.length))
      ..add(handshake);
    return record.toBytes();
  }

  List<int> _cipherSuitesWithGrease() => [
        if (profile.usesGrease) _pickGrease(),
        ...profile.cipherSuites,
      ];

  List<TlsExtension> _buildExtensions({
    required String? serverName,
    required Map<int, Uint8List> keyShares,
    required bool enableEch,
    required Uint8List? echPayload,
  }) {
    final out = <TlsExtension>[];
    if (profile.usesGrease) {
      out.add(TlsExtension(_pickGrease(), Uint8List(0)));
    }
    for (final type in profile.extensionOrder) {
      if (type == TlsExtensionType.serverName && serverName == null) continue;
      final body = _extensionBody(type, serverName, keyShares);
      if (body == null) continue;
      out.add(TlsExtension(type, body));
    }
    if (enableEch) {
      out.add(TlsExtension(
        TlsExtensionType.encryptedClientHello,
        echPayload ?? _greaseEchPayload(),
      ));
    }
    if (profile.usesGrease) {
      // Chrome and Safari close with a second GREASE extension.
      out.add(TlsExtension(_pickGrease(), Uint8List(0)));
    }
    return out;
  }

  Uint8List? _extensionBody(
    int type,
    String? serverName,
    Map<int, Uint8List> keyShares,
  ) {
    switch (type) {
      case TlsExtensionType.serverName:
        final host = utf8.encode(serverName!);
        final entry = BytesBuilder(copy: false)
          ..addByte(0x00) // host_name
          ..add(_vector16(Uint8List.fromList(host)));
        return _vector16(entry.toBytes());
      case TlsExtensionType.supportedGroups:
        final groups = [
          if (profile.usesGrease) _pickGrease(),
          ...profile.supportedGroups,
        ];
        return _vector16(_uint16List(groups));
      case TlsExtensionType.ecPointFormats:
        return _vector8(Uint8List.fromList(const [0x00]));
      case TlsExtensionType.signatureAlgorithms:
        return _vector16(_uint16List(profile.signatureAlgorithms));
      case TlsExtensionType.alpn:
        final list = BytesBuilder(copy: false);
        for (final protocol in profile.alpnProtocols) {
          list.add(_vector8(Uint8List.fromList(utf8.encode(protocol))));
        }
        return _vector16(list.toBytes());
      case TlsExtensionType.supportedVersions:
        final versions = [
          if (profile.usesGrease) _pickGrease(),
          0x0304,
          0x0303,
        ];
        return _vector8(_uint16List(versions));
      case TlsExtensionType.keyShare:
        final entries = BytesBuilder(copy: false);
        if (profile.usesGrease) {
          entries
            ..add(_uint16(_pickGrease()))
            ..add(_vector16(Uint8List.fromList(const [0x00])));
        }
        for (final group in profile.keyShareGroups) {
          final key = keyShares[group] ??
              Uint8List(TlsNamedGroup.keyShareLength(group));
          entries
            ..add(_uint16(group))
            ..add(_vector16(key));
        }
        return _vector16(entries.toBytes());
      case 0x002D: // psk_key_exchange_modes
        return _vector8(Uint8List.fromList(const [0x01])); // psk_dhe_ke
      case 0x001B: // compress_certificate: brotli
        return _vector8(_uint16List(const [0x0002]));
      case TlsExtensionType.recordSizeLimit:
        final limit = profile.recordSizeLimit;
        return limit == null ? null : _uint16(limit);
      case 0x0005: // status_request
        return Uint8List.fromList(const [0x01, 0x00, 0x00, 0x00, 0x00]);
      case 0x0017: // extended_master_secret
      case 0x0023: // session_ticket
      case 0x0012: // signed_certificate_timestamp
      case 0x0022: // delegated_credentials
        return Uint8List(0);
      case 0xFF01: // renegotiation_info
        return Uint8List.fromList(const [0x00]);
      case 0x4469: // application_settings
        final list = BytesBuilder(copy: false)
          ..add(_vector8(Uint8List.fromList(utf8.encode('h2'))));
        return _vector16(list.toBytes());
      default:
        return Uint8List(0);
    }
  }

  /// A GREASE ECH extension body of the shape a real one has: config id,
  /// HPKE suite, a short `enc`, and an opaque payload.
  Uint8List _greaseEchPayload() {
    final builder = BytesBuilder(copy: false)
      ..addByte(0x00) // outer_client_hello
      ..add(_uint16(0x0001)) // HKDF-SHA256
      ..add(_uint16(0x0001)) // AES-128-GCM
      ..addByte(_random.nextInt(256)) // config id
      ..add(_vector16(_randomBytes(32))) // enc
      ..add(_vector16(_randomBytes(160))); // payload
    return builder.toBytes();
  }

  /// Permutes extensions the way Chrome does, keeping the anchors Chrome
  /// itself keeps in place: the leading GREASE, and `pre_shared_key` /
  /// `padding`, which RFC 8446 requires to come last.
  List<TlsExtension> _shufflePreservingAnchors(List<TlsExtension> input) {
    if (input.isEmpty) return input;
    final head = <TlsExtension>[];
    final tail = <TlsExtension>[];
    final middle = <TlsExtension>[];
    for (var i = 0; i < input.length; i++) {
      final ext = input[i];
      if (i == 0 && isGreaseCodePoint(ext.type)) {
        head.add(ext);
      } else if (ext.type == TlsExtensionType.preSharedKey ||
          ext.type == TlsExtensionType.padding ||
          (i == input.length - 1 && isGreaseCodePoint(ext.type))) {
        tail.add(ext);
      } else {
        middle.add(ext);
      }
    }
    for (var i = middle.length - 1; i > 0; i--) {
      final j = _random.nextInt(i + 1);
      final swap = middle[i];
      middle[i] = middle[j];
      middle[j] = swap;
    }
    return [...head, ...middle, ...tail];
  }

  int _pickGrease() =>
      greaseCodePoints[_random.nextInt(greaseCodePoints.length)];

  Uint8List _randomBytes(int count) {
    final bytes = Uint8List(count);
    for (var i = 0; i < count; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  static Uint8List _encodeExtensions(List<TlsExtension> extensions) {
    final builder = BytesBuilder(copy: false);
    for (final ext in extensions) {
      builder
        ..add(_uint16(ext.type))
        ..add(_vector16(ext.data));
    }
    return builder.toBytes();
  }

  static Uint8List _uint16(int value) =>
      Uint8List.fromList([(value >> 8) & 0xFF, value & 0xFF]);

  static Uint8List _uint24(int value) => Uint8List.fromList([
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ]);

  static Uint8List _uint16List(List<int> values) {
    final bytes = Uint8List(values.length * 2);
    for (var i = 0; i < values.length; i++) {
      bytes[i * 2] = (values[i] >> 8) & 0xFF;
      bytes[i * 2 + 1] = values[i] & 0xFF;
    }
    return bytes;
  }

  static Uint8List _vector8(Uint8List body) {
    final out = Uint8List(1 + body.length);
    out[0] = body.length;
    out.setRange(1, out.length, body);
    return out;
  }

  static Uint8List _vector16(Uint8List body) {
    final out = Uint8List(2 + body.length);
    out[0] = (body.length >> 8) & 0xFF;
    out[1] = body.length & 0xFF;
    out.setRange(2, out.length, body);
    return out;
  }
}
