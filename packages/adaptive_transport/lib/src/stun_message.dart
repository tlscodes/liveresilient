import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'turn_relay_allocator.dart';

/// STUN message integrity + fingerprint (RFC 8489 sections 14.5-14.7),
/// implemented against the official RFC 5769 test vectors.
///
/// Attribute type registry values used here (RFC 8489 section 18.3).
const int stunAttrUsername = 0x0006;
const int stunAttrMessageIntegrity = 0x0008;
const int stunAttrMessageIntegritySha256 = 0x001C;
const int stunAttrFingerprint = 0x8028;
const int stunAttrSoftware = 0x8022;
const int stunAttrXorMappedAddress = 0x0020;

/// FINGERPRINT is CRC-32 of the message XOR-ed with this constant
/// (RFC 8489 section 14.7).
const int stunFingerprintXor = 0x5354554E;

/// One parsed attribute: its registry type and raw value bytes.
class StunAttribute {
  const StunAttribute(this.type, this.value, this.valueOffset);
  final int type;
  final Uint8List value;

  /// Offset of the attribute HEADER inside the message.
  final int valueOffset;
}

/// A parsed STUN message: header fields plus attributes in wire order.
class StunMessage {
  StunMessage._(this.type, this.transactionId, this.attributes, this.raw);

  final int type;
  final Uint8List transactionId;
  final List<StunAttribute> attributes;
  final Uint8List raw;

  StunAttribute? attribute(int attrType) {
    for (final a in attributes) {
      if (a.type == attrType) return a;
    }
    return null;
  }

  /// Parses and structurally validates a message (RFC 8489 section 5: magic
  /// cookie, 4-byte-aligned attributes, length agreement).
  static StunMessage parse(Uint8List bytes) {
    if (bytes.length < 20) {
      throw FormatException('STUN header needs 20 bytes, got ${bytes.length}');
    }
    final view = ByteData.sublistView(bytes);
    final type = view.getUint16(0);
    final length = view.getUint16(2);
    if (view.getUint32(4) != stunMagicCookie) {
      throw const FormatException('missing STUN magic cookie');
    }
    if (20 + length != bytes.length) {
      throw FormatException(
        'length field says ${20 + length}, buffer is ${bytes.length}',
      );
    }
    final transactionId = Uint8List.sublistView(bytes, 8, 20);
    final attributes = <StunAttribute>[];
    var offset = 20;
    while (offset < bytes.length) {
      if (offset + 4 > bytes.length) {
        throw const FormatException('truncated attribute header');
      }
      final attrType = view.getUint16(offset);
      final attrLen = view.getUint16(offset + 2);
      final valueEnd = offset + 4 + attrLen;
      if (valueEnd > bytes.length) {
        throw const FormatException('attribute value overruns the message');
      }
      attributes.add(
        StunAttribute(
          attrType,
          Uint8List.sublistView(bytes, offset + 4, valueEnd),
          offset,
        ),
      );
      offset = valueEnd + ((4 - attrLen % 4) % 4); // values pad to 32 bits
    }
    return StunMessage._(type, transactionId, attributes, bytes);
  }

  /// Short-term credential key (RFC 8489 section 9.1.1).
  static Uint8List shortTermKey(String password) =>
      Uint8List.fromList(utf8.encode(password));

  /// Long-term credential key = MD5(user ":" realm ":" password)
  /// (RFC 8489 section 9.2.2).
  static Uint8List longTermKey(
    String username,
    String realm,
    String password,
  ) => Uint8List.fromList(
    md5.convert(utf8.encode('$username:$realm:$password')).bytes,
  );

  /// Verifies MESSAGE-INTEGRITY (HMAC-SHA1, RFC 8489 section 14.5). The HMAC
  /// covers the message up to the attribute, with the header length rewritten
  /// as if MESSAGE-INTEGRITY were the final attribute.
  bool verifyMessageIntegrity(Uint8List key) => _verifyMac(
    stunAttrMessageIntegrity,
    20,
    (input) => Hmac(sha1, key).convert(input).bytes,
  );

  /// Verifies MESSAGE-INTEGRITY-SHA256 (RFC 8489 section 14.6).
  bool verifyMessageIntegritySha256(Uint8List key) => _verifyMac(
    stunAttrMessageIntegritySha256,
    32,
    (input) => Hmac(sha256, key).convert(input).bytes,
  );

  bool _verifyMac(int attrType, int macLen, List<int> Function(Uint8List) mac) {
    final attr = attribute(attrType);
    if (attr == null || attr.value.length != macLen) return false;
    final adjusted = Uint8List.fromList(
      Uint8List.sublistView(raw, 0, attr.valueOffset),
    );
    final asIfLast = attr.valueOffset + 4 + macLen - 20;
    adjusted[2] = (asIfLast >> 8) & 0xff;
    adjusted[3] = asIfLast & 0xff;
    final expected = mac(adjusted);
    var diff = 0;
    for (var i = 0; i < macLen; i++) {
      diff |= expected[i] ^ attr.value[i];
    }
    return diff == 0;
  }

  /// Verifies FINGERPRINT (RFC 8489 section 14.7): CRC-32 over everything
  /// before the attribute, XOR 0x5354554E. The transmitted length already
  /// includes FINGERPRINT, so the raw prefix is hashed unmodified.
  bool verifyFingerprint() {
    final attr = attribute(stunAttrFingerprint);
    if (attr == null || attr.value.length != 4) return false;
    final crc =
        crc32(Uint8List.sublistView(raw, 0, attr.valueOffset)) ^
        stunFingerprintXor;
    return ByteData.sublistView(attr.value).getUint32(0) == crc;
  }
}

/// Builds a STUN message with optional MESSAGE-INTEGRITY(-SHA256) and
/// FINGERPRINT, appended in that RFC-mandated order.
class StunMessageBuilder {
  StunMessageBuilder({required this.type, required Uint8List transactionId})
    : transactionId = Uint8List.fromList(transactionId) {
    if (transactionId.length != 12) {
      throw ArgumentError.value(
        transactionId.length,
        'transactionId',
        'must be 12 bytes',
      );
    }
  }

  final int type;
  final Uint8List transactionId;
  final List<(int, Uint8List)> _attrs = [];

  void addAttribute(int attrType, Uint8List value) =>
      _attrs.add((attrType, Uint8List.fromList(value)));

  void addUsername(String username) =>
      addAttribute(stunAttrUsername, Uint8List.fromList(utf8.encode(username)));

  Uint8List build({
    Uint8List? integrityKey,
    bool sha256Integrity = false,
    bool fingerprint = false,
  }) {
    var body = BytesBuilder(copy: false);
    for (final (t, v) in _attrs) {
      body.add(_tlv(t, v));
    }
    var bytes = _withHeader(body.toBytes());
    if (integrityKey != null) {
      final macLen = sha256Integrity ? 32 : 20;
      final attrType = sha256Integrity
          ? stunAttrMessageIntegritySha256
          : stunAttrMessageIntegrity;
      final grown = _resizeHeader(bytes, bytes.length - 20 + 4 + macLen);
      final digest = sha256Integrity
          ? Hmac(sha256, integrityKey).convert(grown)
          : Hmac(sha1, integrityKey).convert(grown);
      bytes = _withHeader(
        Uint8List.fromList([
          ...Uint8List.sublistView(bytes, 20),
          ..._tlv(attrType, Uint8List.fromList(digest.bytes)),
        ]),
      );
    }
    if (fingerprint) {
      final grown = _resizeHeader(bytes, bytes.length - 20 + 8);
      final crc = crc32(grown) ^ stunFingerprintXor;
      final value = Uint8List(4)..buffer.asByteData().setUint32(0, crc);
      bytes = _withHeader(
        Uint8List.fromList([
          ...Uint8List.sublistView(bytes, 20),
          ..._tlv(stunAttrFingerprint, value),
        ]),
      );
    }
    return bytes;
  }

  Uint8List _withHeader(Uint8List body) {
    final out = Uint8List(20 + body.length);
    final view = ByteData.sublistView(out);
    view.setUint16(0, type);
    view.setUint16(2, body.length);
    view.setUint32(4, stunMagicCookie);
    out.setRange(8, 20, transactionId);
    out.setRange(20, out.length, body);
    return out;
  }

  /// The message with its header length field set to [bodyLength] — the
  /// "as if this attribute were last" form both MACs are computed over.
  Uint8List _resizeHeader(Uint8List bytes, int bodyLength) {
    final adjusted = Uint8List.fromList(bytes);
    adjusted[2] = (bodyLength >> 8) & 0xff;
    adjusted[3] = bodyLength & 0xff;
    return adjusted;
  }

  static Uint8List _tlv(int type, Uint8List value) {
    final padded = (value.length + 3) & ~3;
    final out = Uint8List(4 + padded);
    final view = ByteData.sublistView(out);
    view.setUint16(0, type);
    view.setUint16(2, value.length);
    out.setRange(4, 4 + value.length, value);
    return out;
  }
}

List<int>? _crcTable;

/// CRC-32 (IEEE 802.3, the polynomial FINGERPRINT requires).
int crc32(Uint8List bytes) {
  final table = _crcTable ??= List<int>.generate(256, (i) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = table[(crc ^ b) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
