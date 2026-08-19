/// TLS 1.3 Client Hello parsing and fingerprinting.
///
/// Two jobs, both pure:
///
/// 1. **Parse** a Client Hello out of a TLS record without completing (or
///    even starting) a handshake, so a relay can decide what to do with a
///    connection while it still owns every byte the peer has sent.
/// 2. **Fingerprint** it — JA3 (MD5 over a fixed field order) and JA4
///    (the newer, ordering-stable form) — so both ends can assert that an
///    outgoing hello really carries the signature of the browser profile
///    it claims.
///
/// Extension *order* is preserved exactly as received: it is the single
/// most discriminating part of a TLS fingerprint, and a parser that sorted
/// it would silently destroy the thing being measured.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// TLS record content type for handshake records (RFC 8446 section 5.1).
const int tlsHandshakeContentType = 0x16;

/// Handshake message type for `client_hello` (RFC 8446 section 4).
const int tlsClientHelloType = 0x01;

/// Extension type codes this module needs by name.
class TlsExtensionType {
  const TlsExtensionType._();

  static const int serverName = 0x0000;
  static const int supportedGroups = 0x000A;
  static const int ecPointFormats = 0x000B;
  static const int signatureAlgorithms = 0x000D;
  static const int alpn = 0x0010;
  static const int recordSizeLimit = 0x001C;
  static const int preSharedKey = 0x0029;
  static const int supportedVersions = 0x002B;
  static const int keyShare = 0x0033;
  static const int encryptedClientHello = 0xFE0D;
  static const int padding = 0x0015;
}

/// The 16 reserved GREASE values (RFC 8701 section 2). They are excluded
/// from every fingerprint: a client that varies them per connection would
/// otherwise present a different fingerprint each time.
const List<int> greaseCodePoints = [
  0x0A0A, 0x1A1A, 0x2A2A, 0x3A3A, //
  0x4A4A, 0x5A5A, 0x6A6A, 0x7A7A,
  0x8A8A, 0x9A9A, 0xAAAA, 0xBABA,
  0xCACA, 0xDADA, 0xEAEA, 0xFAFA,
];

/// Whether [value] is one of the reserved GREASE code points.
bool isGreaseCodePoint(int value) => greaseCodePoints.contains(value);

/// One extension, as it appeared on the wire.
class TlsExtension {
  const TlsExtension(this.type, this.data);

  /// Extension type code (e.g. [TlsExtensionType.alpn]).
  final int type;

  /// The extension body, without the 4-byte type/length header.
  final Uint8List data;

  @override
  String toString() =>
      'TlsExtension(0x${type.toRadixString(16)}, '
      '${data.length}B)';
}

/// Raised when a byte sequence is not a well-formed Client Hello.
///
/// A relay treats this exactly like a failed authentication: something
/// that is not a parseable hello is, by definition, not one of ours.
class TlsParseException implements Exception {
  const TlsParseException(this.message);

  final String message;

  @override
  String toString() => 'TlsParseException: $message';
}

/// A parsed `client_hello`.
class TlsClientHello {
  TlsClientHello({
    required this.legacyVersion,
    required this.random,
    required this.sessionId,
    required this.cipherSuites,
    required this.compressionMethods,
    required this.extensions,
  });

  /// `legacy_version`, always 0x0303 for TLS 1.3 clients.
  final int legacyVersion;

  /// The 32-byte `random`.
  final Uint8List random;

  /// `legacy_session_id` — 0 or 32 bytes in practice.
  final Uint8List sessionId;

  /// Offered cipher suites, in wire order (GREASE included).
  final List<int> cipherSuites;

  /// `legacy_compression_methods`, always `[0]` for TLS 1.3.
  final List<int> compressionMethods;

  /// Extensions in wire order, GREASE included.
  final List<TlsExtension> extensions;

  /// The first extension with [type], or null.
  TlsExtension? extension(int type) {
    for (final ext in extensions) {
      if (ext.type == type) return ext;
    }
    return null;
  }

  /// The SNI host name per RFC 6066, or null when this hello carries no
  /// `server_name` extension — which is what an outer ClientHello looks like
  /// under Encrypted Client Hello (draft-ietf-tls-esni), where the real name
  /// travels in the encrypted inner hello instead.
  String? get serverName {
    final ext = extension(TlsExtensionType.serverName);
    if (ext == null || ext.data.length < 5) return null;
    final reader = _ByteReader(ext.data);
    reader.readUint16(); // server_name_list length
    final nameType = reader.readUint8();
    if (nameType != 0x00) return null; // only host_name is defined
    final host = reader.readVector16();
    return utf8.decode(host, allowMalformed: true);
  }

  /// Whether the hello carries an `encrypted_client_hello` extension.
  bool get hasEncryptedClientHello =>
      extension(TlsExtensionType.encryptedClientHello) != null;

  /// ALPN protocol identifiers in offer order, or an empty list.
  List<String> get alpnProtocols {
    final ext = extension(TlsExtensionType.alpn);
    if (ext == null) return const [];
    final reader = _ByteReader(ext.data);
    final listLength = reader.readUint16();
    final end = reader.offset + listLength;
    final out = <String>[];
    while (reader.offset < end && reader.remaining > 0) {
      out.add(utf8.decode(reader.readVector8(), allowMalformed: true));
    }
    return out;
  }

  /// `supported_groups` code points in wire order (GREASE included).
  List<int> get supportedGroups {
    final ext = extension(TlsExtensionType.supportedGroups);
    if (ext == null) return const [];
    final reader = _ByteReader(ext.data);
    return _readUint16List(reader, reader.readUint16());
  }

  /// `ec_point_formats` values, or an empty list.
  List<int> get ecPointFormats {
    final ext = extension(TlsExtensionType.ecPointFormats);
    if (ext == null) return const [];
    final reader = _ByteReader(ext.data);
    return List<int>.unmodifiable(reader.readVector8());
  }

  /// `signature_algorithms` code points in wire order.
  List<int> get signatureAlgorithms {
    final ext = extension(TlsExtensionType.signatureAlgorithms);
    if (ext == null) return const [];
    final reader = _ByteReader(ext.data);
    return _readUint16List(reader, reader.readUint16());
  }

  /// The `key_share` group code points offered, in wire order.
  List<int> get keyShareGroups {
    final ext = extension(TlsExtensionType.keyShare);
    if (ext == null) return const [];
    final reader = _ByteReader(ext.data);
    final listLength = reader.readUint16();
    final end = reader.offset + listLength;
    final out = <int>[];
    while (reader.offset + 4 <= end) {
      out.add(reader.readUint16());
      reader.skip(reader.readUint16());
    }
    return out;
  }

  /// The negotiated-version list from `supported_versions`, in wire order.
  List<int> get supportedVersions {
    final ext = extension(TlsExtensionType.supportedVersions);
    if (ext == null) return const [];
    final reader = _ByteReader(ext.data);
    return _readUint16List(reader, reader.readUint8());
  }

  /// Highest non-GREASE version the client offers: the `supported_versions`
  /// maximum when present, otherwise [legacyVersion].
  int get effectiveVersion {
    final offered = supportedVersions.where((v) => !isGreaseCodePoint(v));
    if (offered.isEmpty) return legacyVersion;
    return offered.reduce((a, b) => a > b ? a : b);
  }

  /// Parses one complete TLS handshake record carrying a Client Hello.
  ///
  /// [record] must start at the 5-byte record header. Throws
  /// [TlsParseException] on anything that is not a complete, well-formed
  /// hello — including a record that is merely truncated, since a decision
  /// must never be taken on half a message.
  factory TlsClientHello.parseRecord(List<int> record) {
    final bytes = Uint8List.fromList(record);
    if (bytes.length < 5) {
      throw const TlsParseException('record shorter than its 5-byte header');
    }
    if (bytes[0] != tlsHandshakeContentType) {
      throw TlsParseException(
        'content type 0x${bytes[0].toRadixString(16)} is not handshake',
      );
    }
    final recordLength = ByteData.sublistView(bytes).getUint16(3);
    if (bytes.length - 5 < recordLength) {
      throw TlsParseException(
        'record declares $recordLength bytes, ${bytes.length - 5} present',
      );
    }
    return TlsClientHello.parseHandshake(
      Uint8List.sublistView(bytes, 5, 5 + recordLength),
    );
  }

  /// Parses a bare handshake message (no record header).
  factory TlsClientHello.parseHandshake(List<int> handshake) {
    final reader = _ByteReader(Uint8List.fromList(handshake));
    try {
      final messageType = reader.readUint8();
      if (messageType != tlsClientHelloType) {
        throw TlsParseException(
          'handshake type $messageType is not client_hello',
        );
      }
      final bodyLength = reader.readUint24();
      if (reader.remaining < bodyLength) {
        throw TlsParseException(
          'client_hello declares $bodyLength bytes, ${reader.remaining} '
          'present',
        );
      }
      final legacyVersion = reader.readUint16();
      final random = reader.readBytes(32);
      final sessionId = reader.readVector8();
      final cipherSuites = _readUint16List(reader, reader.readUint16());
      final compressionMethods = reader.readVector8();

      final extensions = <TlsExtension>[];
      if (reader.remaining >= 2) {
        final extensionsLength = reader.readUint16();
        final end = reader.offset + extensionsLength;
        if (end > reader.length) {
          throw const TlsParseException('extensions block overruns the hello');
        }
        while (reader.offset + 4 <= end) {
          final type = reader.readUint16();
          extensions.add(TlsExtension(type, reader.readVector16()));
        }
        if (reader.offset != end) {
          throw const TlsParseException('extensions block ends mid-extension');
        }
      }

      return TlsClientHello(
        legacyVersion: legacyVersion,
        random: random,
        sessionId: sessionId,
        cipherSuites: List<int>.unmodifiable(cipherSuites),
        compressionMethods: List<int>.unmodifiable(compressionMethods),
        extensions: List<TlsExtension>.unmodifiable(extensions),
      );
    } on RangeError catch (error) {
      throw TlsParseException('client_hello truncated ($error)');
    }
  }

  /// The JA3 string: version, ciphers, extensions, curves and point
  /// formats, each `-`-joined and the five fields `,`-joined, with GREASE
  /// removed.
  String get ja3String {
    String join(Iterable<int> values) =>
        values.where((v) => !isGreaseCodePoint(v)).join('-');
    return [
      legacyVersion.toString(),
      join(cipherSuites),
      join(extensions.map((e) => e.type)),
      join(supportedGroups),
      ecPointFormats.join('-'),
    ].join(',');
  }

  /// The JA3 hash: MD5 of [ja3String].
  String get ja3 => md5.convert(utf8.encode(ja3String)).toString();

  /// The JA4 fingerprint (`ja4_a_ja4_b_ja4_c`) for a TLS-over-TCP hello.
  ///
  /// Set [overQuic] when the hello was carried in a QUIC CRYPTO frame,
  /// which changes only the leading protocol character.
  String ja4({bool overQuic = false}) {
    final ciphers = cipherSuites.where((c) => !isGreaseCodePoint(c)).toList();
    final extensionTypes = extensions
        .map((e) => e.type)
        .where((t) => !isGreaseCodePoint(t));

    final version = switch (effectiveVersion) {
      0x0304 => '13',
      0x0303 => '12',
      0x0302 => '11',
      0x0301 => '10',
      _ => '00',
    };
    final sni = serverName == null ? 'i' : 'd';
    final alpn = alpnProtocols.isEmpty
        ? '00'
        : _alpnMarker(alpnProtocols.first);
    final a =
        '${overQuic ? 'q' : 't'}$version$sni'
        '${_twoDigits(ciphers.length)}'
        '${_twoDigits(extensionTypes.length)}$alpn';

    // JA4_b and JA4_c hash *sorted* lists, which is exactly what makes JA4
    // stable against a peer that shuffles its extension order per
    // connection — unlike JA3, which such a peer defeats outright.
    final b = _truncatedSha256((ciphers.map(_hex4).toList()..sort()).join(','));
    final sortedExtensions =
        (extensionTypes
                .where(
                  (t) =>
                      t != TlsExtensionType.serverName &&
                      t != TlsExtensionType.alpn,
                )
                .map(_hex4)
                .toList()
              ..sort())
            .join(',');
    // Signature algorithms stay in wire ORDER — the JA4 spec keeps them
    // unsorted on purpose.
    final signatures = signatureAlgorithms
        .where((s) => !isGreaseCodePoint(s))
        .map(_hex4)
        .join(',');
    final c = _truncatedSha256(
      signatures.isEmpty ? sortedExtensions : '${sortedExtensions}_$signatures',
    );
    return '${a}_${b}_$c';
  }

  static String _alpnMarker(String protocol) {
    if (protocol.isEmpty) return '00';
    return '${protocol[0]}${protocol[protocol.length - 1]}';
  }

  static String _twoDigits(int value) =>
      (value > 99 ? 99 : value).toString().padLeft(2, '0');

  static String _hex4(int value) => value.toRadixString(16).padLeft(4, '0');

  /// First 12 hex characters of the SHA-256, or twelve zeroes for an empty
  /// list (the JA4 spec's sentinel for "nothing to hash").
  static String _truncatedSha256(String input) {
    if (input.isEmpty) return '000000000000';
    return sha256.convert(utf8.encode(input)).toString().substring(0, 12);
  }
}

List<int> _readUint16List(_ByteReader reader, int byteLength) {
  final out = <int>[];
  for (var i = 0; i + 1 < byteLength; i += 2) {
    out.add(reader.readUint16());
  }
  return out;
}

/// Minimal big-endian cursor over a byte buffer.
class _ByteReader {
  _ByteReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int offset = 0;

  int get length => _bytes.length;
  int get remaining => _bytes.length - offset;

  void _need(int count) {
    if (remaining < count) {
      throw RangeError('need $count bytes, $remaining remain');
    }
  }

  int readUint8() {
    _need(1);
    return _bytes[offset++];
  }

  int readUint16() {
    _need(2);
    final value = _view.getUint16(offset);
    offset += 2;
    return value;
  }

  int readUint24() {
    _need(3);
    final value =
        (_bytes[offset] << 16) | (_bytes[offset + 1] << 8) | _bytes[offset + 2];
    offset += 3;
    return value;
  }

  Uint8List readBytes(int count) {
    _need(count);
    final slice = Uint8List.sublistView(_bytes, offset, offset + count);
    offset += count;
    return slice;
  }

  void skip(int count) {
    _need(count);
    offset += count;
  }

  Uint8List readVector8() => readBytes(readUint8());

  Uint8List readVector16() => readBytes(readUint16());
}
