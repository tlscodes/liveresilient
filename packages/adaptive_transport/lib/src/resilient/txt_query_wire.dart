import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Wire format of the TXT query fallback path, in Dart.
///
/// This is a byte-for-byte port of `tools/t2/txt_query_wire.py`. The far
/// side of this lane is the Python responder (`tools/t2/txt_query_server.py`)
/// and stays Python, so the two implementations must agree on every byte;
/// `test/resilient/txt_query_wire_test.dart` pins that with golden vectors
/// generated from the Python module itself.
///
/// The port exists because the previous Dart lane spoke to a local Python
/// sidecar over loopback UDP, and a phone cannot spawn a Python process.
/// Everything here is pure computation over bytes — no `Platform`, no
/// `Process`, no file system — so it runs unchanged on iOS and Android.
///
/// Query name layout (design §2, §3):
///
///     q.<seq2>.<session6>.<nonce4>.<payload_b32>.tunnel.<domain>
///
/// Base32 is RFC 4648, unpadded and case-insensitive, because DNS labels
/// cannot carry `=`. The empty chunk encodes as the single character `0`,
/// which is outside the Base32 alphabet and therefore unambiguous.
abstract final class TxtQueryWire {
  /// RFC 1035 §2.3.4: one label is at most 63 octets.
  static const int labelMax = 63;

  /// RFC 1035 §2.3.4: a name is at most 255 octets on the wire, which is
  /// 253 characters in presentation form.
  static const int fqdnMax = 253;

  /// Raw bytes that fit in one label once Base32 expands them 8/5:
  /// `63 * 5 ~/ 8`.
  static const int rawPerLabel = 39;

  static const int seqChars = 2;
  static const int sessionChars = 6;
  static const int nonceChars = 4;
  static const int seqMax = 1023;

  static const String marker = 'q';
  static const String tunnel = 'tunnel';

  static const int qtypeTxt = 16;
  static const int qclassIn = 1;
  static const int optType = 41;

  /// RFC 9715 / DNS Flag Day 2020 advertise 1232, not 4096: 1232 is the
  /// largest EDNS0 payload that survives the common 1280-octet IPv6 MTU
  /// without fragmentation.
  static const int ednsUdpSize = 1232;

  static const int rcodeNoError = 0;
  static const int rcodeNxDomain = 3;

  /// Upstream frames are `u16 length` + payload.
  static const int frameHeader = 2;

  /// Octets of an answer that are not the TXT rdata:
  ///
  ///     12  the header
  ///      4  qtype and qclass, after the question's owner name
  ///     12  the answer record: a 2-octet compression pointer as its owner
  ///         name (RFC 1035 §4.1.4), then type, class, ttl and rdlength
  ///     11  the OPT record
  ///
  /// The question's owner name is counted apart, since its length is the
  /// caller's rather than a constant: a presentation name of L characters
  /// is L + 2 octets on the wire, one length octet per label plus the root.
  static const int _answerFixedOctets = 12 + 4 + 12 + 11;

  /// The TXT rdata room the longest legal question name leaves behind.
  static const int _worstCaseRdataRoom =
      ednsUdpSize - _answerFixedOctets - (fqdnMax + 2);

  /// The most one answer may carry when the question name is not known.
  ///
  /// Derived, not chosen. The rdata carries the framed payload split into
  /// 255-octet strings, each paying its own length octet, so R octets of
  /// rdata carry `R - ceil(R / 256)` framed octets and the frame header
  /// costs [frameHeader] more. Evaluated at [fqdnMax] this holds for every
  /// legal question name; [maxDownstreamPayloadFor] returns the octets a
  /// shorter name earns back.
  static const int downstreamBudget =
      _worstCaseRdataRoom - (_worstCaseRdataRoom + 255) ~/ 256 - frameHeader;

  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static final Random _random = Random.secure();

  /// Base32 with the padding stripped; the empty input encodes as `0`.
  static String base32Encode(List<int> data) {
    if (data.isEmpty) return '0';
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in data) {
      buffer = ((buffer << 8) | (byte & 0xFF)) & 0xFFFF;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_alphabet[(buffer >> bits) & 31]);
      }
    }
    if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
    return out.toString();
  }

  /// Inverse of [base32Encode]. Case-insensitive, padding optional.
  static Uint8List base32Decode(String text) {
    final upper = text.toUpperCase();
    if (upper == '0') return Uint8List(0);
    final body = upper.replaceAll('=', '');
    // Only these residues can come from a whole number of octets; the rest
    // mean the label lost or gained characters in transit.
    const validRemainders = <int>{0, 2, 4, 5, 7};
    if (!validRemainders.contains(body.length % 8)) {
      throw TxtQueryWireException('bad Base32 length ${body.length}');
    }
    final out = BytesBuilder(copy: false);
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < body.length; i++) {
      final index = _alphabet.indexOf(body[i]);
      if (index < 0) {
        throw TxtQueryWireException('illegal Base32 char ${body[i]}');
      }
      buffer = ((buffer << 5) | index) & 0xFFFF;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.addByte((buffer >> bits) & 0xFF);
      }
    }
    return out.takeBytes();
  }

  /// Big-endian Base32 digits, exactly [width] characters wide.
  static String encodeInt(int value, int width) {
    if (value < 0) throw TxtQueryWireException('negative value $value');
    final chars = List<String>.filled(width, _alphabet[0]);
    var rest = value;
    for (var i = width - 1; i >= 0; i--) {
      chars[i] = _alphabet[rest & 31];
      rest >>= 5;
    }
    if (rest != 0) {
      throw TxtQueryWireException('$value does not fit in $width chars');
    }
    return chars.join();
  }

  static int decodeInt(String label) {
    var value = 0;
    final upper = label.toUpperCase();
    for (var i = 0; i < upper.length; i++) {
      final index = _alphabet.indexOf(upper[i]);
      if (index < 0) {
        throw TxtQueryWireException('illegal Base32 char ${upper[i]}');
      }
      value = (value << 5) | index;
    }
    return value;
  }

  static String encodeSeq(int seq) {
    if (seq < 0 || seq > seqMax) {
      throw TxtQueryWireException('seq $seq out of 0..$seqMax');
    }
    return encodeInt(seq, seqChars);
  }

  static int decodeSeq(String label) {
    final seq = decodeInt(label);
    if (seq > seqMax) throw TxtQueryWireException('seq $seq out of range');
    return seq;
  }

  /// A fresh session id from the platform CSPRNG (30 bits of entropy).
  static String newSessionId() =>
      encodeInt(_randomBits(sessionChars * 5), sessionChars);

  /// A fresh per-query nonce (20 bits). Its only job is to keep an
  /// intermediate resolver from serving a cached answer for a repeated
  /// query name.
  static String newNonce() =>
      encodeInt(_randomBits(nonceChars * 5), nonceChars);

  static int _randomBits(int bits) {
    var value = 0;
    var remaining = bits;
    while (remaining > 0) {
      final take = remaining < 24 ? remaining : 24;
      value = (value << take) | _random.nextInt(1 << take);
      remaining -= take;
    }
    return value;
  }

  /// Prefixes [payload] with its `u16` length.
  static Uint8List frameUp(List<int> payload) {
    if (payload.length > 0xFFFF) {
      throw TxtQueryWireException('payload exceeds u16');
    }
    final framed = Uint8List(frameHeader + payload.length);
    framed[0] = (payload.length >> 8) & 0xFF;
    framed[1] = payload.length & 0xFF;
    framed.setRange(frameHeader, framed.length, payload);
    return framed;
  }

  /// Strips the `u16` length prefix, refusing a frame that arrived short.
  static Uint8List unframeUp(List<int> framed) {
    if (framed.length < frameHeader) {
      throw const TxtQueryWireException('truncated frame');
    }
    final want = (framed[0] << 8) | framed[1];
    final body = framed.length - frameHeader;
    if (body < want) {
      throw TxtQueryWireException('incomplete frame have=$body want=$want');
    }
    return Uint8List.fromList(framed.sublist(frameHeader, frameHeader + want));
  }

  /// Octets [name] occupies on the wire, the root label included.
  static int _nameWireLength(String name) {
    var total = 1; // the root label
    for (final label in name.split('.')) {
      if (label.isEmpty) continue;
      total += 1 + label.length;
    }
    return total;
  }

  /// The most an answer to [questionName] may carry inside [ednsUdpSize].
  ///
  /// Uses the real name where [downstreamBudget] assumes the [fqdnMax]
  /// worst case, which is worth several hundred octets on a short zone.
  static int maxDownstreamPayloadFor(String questionName) {
    final room =
        ednsUdpSize - _answerFixedOctets - _nameWireLength(questionName);
    if (room <= 0) return 0;
    final payload = room - (room + 255) ~/ 256 - frameHeader;
    return payload < 0 ? 0 : payload;
  }

  /// Same framing downstream, with the answer budget enforced.
  ///
  /// [questionName] narrows the budget to what that name actually leaves
  /// room for; without it the conservative [downstreamBudget] applies.
  static Uint8List frameDown(List<int> payload, {String? questionName}) {
    final budget = questionName == null
        ? downstreamBudget
        : maxDownstreamPayloadFor(questionName);
    if (payload.length > budget) {
      throw TxtQueryWireException('downstream ${payload.length} > $budget');
    }
    return frameUp(payload);
  }

  static Uint8List unframeDown(List<int> framed) => unframeUp(framed);

  /// Splits a framed payload into label-sized pieces. An empty input still
  /// yields one (empty) chunk, so a poll is a real query.
  static List<Uint8List> splitChunks(Uint8List framed) {
    if (framed.isEmpty) return <Uint8List>[Uint8List(0)];
    final chunks = <Uint8List>[];
    for (var i = 0; i < framed.length; i += rawPerLabel) {
      final end = i + rawPerLabel;
      chunks.add(
        Uint8List.sublistView(framed, i, end > framed.length ? null : end),
      );
    }
    return chunks;
  }

  static String buildQueryName(
    List<int> chunk,
    int seq,
    String sessionId,
    String nonce,
    String domain,
  ) {
    final payloadLabel = base32Encode(chunk);
    if (payloadLabel.length > labelMax) {
      throw TxtQueryWireException(
        'payload label ${payloadLabel.length} > $labelMax',
      );
    }
    // The parser refuses a session or nonce label of the wrong width, so a
    // builder that accepted one would emit a whole batch of names the far side
    // drops — and it would surface as silence rather than as an error. Check
    // here, with the same widths the parser pins, so the mistake is loud at
    // the sender. Measured before this check existed: a five-character session
    // id built a name that parseQueryName then rejected with 'session/nonce
    // width', and encodeQueries passes sessionId straight through.
    if (sessionId.length != sessionChars) {
      throw TxtQueryWireException(
        'session id "$sessionId" is ${sessionId.length} chars, want $sessionChars',
      );
    }
    if (nonce.length != nonceChars) {
      throw TxtQueryWireException(
        'nonce "$nonce" is ${nonce.length} chars, want $nonceChars',
      );
    }
    final zone = domain.replaceAll(RegExp(r'^\.+|\.+$'), '').toLowerCase();
    final labels = <String>[
      marker,
      encodeSeq(seq),
      sessionId,
      nonce,
      payloadLabel,
      tunnel,
      ...zone.split('.'),
    ];
    for (final label in labels) {
      if (label.isEmpty || label.length > labelMax) {
        throw TxtQueryWireException('bad label "$label"');
      }
    }
    final name = labels.join('.');
    if (name.length > fqdnMax) {
      throw TxtQueryWireException('FQDN ${name.length} > $fqdnMax');
    }
    return name;
  }

  static ParsedTxtQuery parseQueryName(String name, String expectedDomain) {
    final zone = expectedDomain
        .replaceAll(RegExp(r'^\.+|\.+$'), '')
        .toLowerCase();
    final lowered = name.replaceAll(RegExp(r'^\.+|\.+$'), '').toLowerCase();
    final parts = lowered.split('.');
    final zoneLabels = <String>[tunnel, ...zone.split('.')];
    if (parts.length <= zoneLabels.length || !_endsWith(parts, zoneLabels)) {
      throw TxtQueryWireException('not a valve query for "$zone": "$name"');
    }
    final head = parts.sublist(0, parts.length - zoneLabels.length);
    if (head.length != 5 || head[0] != marker) {
      throw TxtQueryWireException('bad head $head');
    }
    // The sequence label has a fixed width for the same reason the two beside
    // it do: without the pin, 'aab', 'b' and 'ab' all decode to sequence 1 and
    // '' decodes to 0, so two names can claim the same chunk of one payload and
    // reassembly either raises a conflict or silently accepts the wrong bytes.
    if (head[1].length != seqChars) {
      throw TxtQueryWireException(
        'seq label "${head[1]}" is ${head[1].length} chars, want $seqChars',
      );
    }
    if (head[2].length != sessionChars || head[3].length != nonceChars) {
      throw const TxtQueryWireException('session/nonce width');
    }
    return ParsedTxtQuery(
      seq: decodeSeq(head[1]),
      sessionId: head[2],
      nonce: head[3],
      chunk: base32Decode(head[4]),
      domain: zone,
      name: lowered,
    );
  }

  static bool _endsWith(List<String> parts, List<String> suffix) {
    final offset = parts.length - suffix.length;
    for (var i = 0; i < suffix.length; i++) {
      if (parts[offset + i] != suffix[i]) return false;
    }
    return true;
  }

  /// Every query name that carries [payload], in order.
  ///
  /// [sessionId] ties the chunks of one payload together; pass the value
  /// from a previous call to continue a session, or null for a fresh one.
  static EncodedQueries encodeQueries(
    List<int> payload,
    String domain, {
    String? sessionId,
  }) {
    final session = sessionId ?? newSessionId();
    final chunks = splitChunks(frameUp(payload));
    final names = <String>[
      for (var seq = 0; seq < chunks.length; seq++)
        buildQueryName(chunks[seq], seq, session, newNonce(), domain),
    ];
    return EncodedQueries(sessionId: session, names: names);
  }

  /// Rebuilds the payload from parsed queries, refusing a gap or a
  /// contradiction rather than handing up a plausible-looking splice.
  static Uint8List reassemble(List<ParsedTxtQuery> parsed) {
    if (parsed.isEmpty) throw const TxtQueryWireException('no chunks');
    final bySeq = <int, Uint8List>{};
    var highest = 0;
    for (final part in parsed) {
      final existing = bySeq[part.seq];
      if (existing != null && !_sameBytes(existing, part.chunk)) {
        throw TxtQueryWireException('conflict at seq ${part.seq}');
      }
      bySeq[part.seq] = part.chunk;
      if (part.seq > highest) highest = part.seq;
    }
    final missing = <int>[
      for (var i = 0; i <= highest; i++)
        if (!bySeq.containsKey(i)) i,
    ];
    if (missing.isNotEmpty) {
      throw TxtQueryWireException('missing seq $missing');
    }
    final joined = BytesBuilder(copy: false);
    for (var i = 0; i <= highest; i++) {
      joined.add(bySeq[i]!);
    }
    return unframeUp(joined.takeBytes());
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Uint8List _encodeName(String name) {
    final out = BytesBuilder(copy: false);
    for (final label in name.split('.')) {
      if (label.isEmpty) continue;
      final raw = ascii.encode(label);
      if (raw.length > labelMax) {
        throw TxtQueryWireException('label too long "$label"');
      }
      out.addByte(raw.length);
      out.add(raw);
    }
    out.addByte(0);
    return out.takeBytes();
  }

  /// Decodes a name at [offset], following compression pointers, and
  /// returns it with the offset just past the name in the containing
  /// record. Real resolvers compress the answer's name even though the
  /// Python builder does not, so pointer support is not optional here.
  static _DecodedName _decodeName(Uint8List buf, int offset, [int depth = 0]) {
    if (depth > 10) throw const TxtQueryWireException('compression loop');
    final labels = <String>[];
    var pos = offset;
    var jumped = false;
    var end = offset;
    while (true) {
      if (pos >= buf.length) {
        throw const TxtQueryWireException('name past end');
      }
      final length = buf[pos];
      if (length == 0) {
        if (!jumped) end = pos + 1;
        break;
      }
      if (length & 0xC0 == 0xC0) {
        if (pos + 1 >= buf.length) {
          throw const TxtQueryWireException('truncated pointer');
        }
        final target = ((length & 0x3F) << 8) | buf[pos + 1];
        if (!jumped) end = pos + 2;
        jumped = true;
        labels.add(_decodeName(buf, target, depth + 1).name);
        break;
      }
      if (length & 0xC0 != 0) {
        throw const TxtQueryWireException('bad label type');
      }
      pos += 1;
      if (pos + length > buf.length) {
        throw const TxtQueryWireException('label past end');
      }
      labels.add(ascii.decode(Uint8List.sublistView(buf, pos, pos + length)));
      pos += length;
      if (!jumped) end = pos;
    }
    return _DecodedName(labels.join('.'), end);
  }

  static Uint8List _optRecord([int udpPayloadSize = ednsUdpSize]) {
    final out = Uint8List(11);
    final view = ByteData.sublistView(out);
    out[0] = 0; // root name
    view.setUint16(1, optType);
    view.setUint16(3, udpPayloadSize);
    view.setUint32(5, 0); // extended rcode + version + flags
    view.setUint16(9, 0); // rdlength
    return out;
  }

  /// One standard recursive TXT/IN query with an EDNS0 OPT record.
  static Uint8List buildDnsQueryPacket(int txid, String name) {
    final question = _encodeName(name);
    final packet = BytesBuilder(copy: false);
    final header = ByteData(12);
    header.setUint16(0, txid & 0xFFFF);
    header.setUint16(2, 0x0100); // RD
    header.setUint16(4, 1); // qdcount
    header.setUint16(6, 0);
    header.setUint16(8, 0);
    header.setUint16(10, 1); // arcount: the OPT record
    packet.add(header.buffer.asUint8List());
    packet.add(question);
    final tail = ByteData(4);
    tail.setUint16(0, qtypeTxt);
    tail.setUint16(2, qclassIn);
    packet.add(tail.buffer.asUint8List());
    packet.add(_optRecord());
    return packet.takeBytes();
  }

  static ParsedDnsQuery parseDnsQueryPacket(Uint8List packet) {
    if (packet.length < 12) throw const TxtQueryWireException('short header');
    final view = ByteData.sublistView(packet);
    final txid = view.getUint16(0);
    final qdcount = view.getUint16(4);
    if (qdcount != 1) throw TxtQueryWireException('qdcount $qdcount');
    final decoded = _decodeName(packet, 12);
    if (decoded.end + 4 > packet.length) {
      throw const TxtQueryWireException('truncated question');
    }
    final qtype = view.getUint16(decoded.end);
    final qclass = view.getUint16(decoded.end + 2);
    if (qtype != qtypeTxt || qclass != qclassIn) {
      throw TxtQueryWireException('expected TXT/IN got $qtype/$qclass');
    }
    return ParsedDnsQuery(txid: txid, name: decoded.name);
  }

  static Uint8List _txtRdata(List<int> payload) {
    if (payload.isEmpty) return Uint8List.fromList(const <int>[0]);
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < payload.length; i += 255) {
      final end = i + 255 > payload.length ? payload.length : i + 255;
      out.addByte(end - i);
      out.add(payload.sublist(i, end));
    }
    return out.takeBytes();
  }

  static Uint8List _parseTxtRdata(Uint8List rdata) {
    final out = BytesBuilder(copy: false);
    var pos = 0;
    while (pos < rdata.length) {
      final length = rdata[pos];
      pos += 1;
      final end = pos + length > rdata.length ? rdata.length : pos + length;
      out.add(Uint8List.sublistView(rdata, pos, end));
      pos = end;
    }
    return out.takeBytes();
  }

  /// The authoritative-style answer the Python responder produces. Kept in
  /// Dart so tests can stand up a responder in the test process instead of
  /// shelling out to an interpreter the phone does not have.
  static Uint8List buildDnsAnswerPacket(
    int txid,
    String questionName,
    List<int>? payload, {
    int rcode = rcodeNoError,
  }) {
    final answers = payload != null && rcode == rcodeNoError ? 1 : 0;
    final name = _encodeName(questionName);
    final packet = BytesBuilder(copy: false);
    final header = ByteData(12);
    header.setUint16(0, txid & 0xFFFF);
    header.setUint16(2, 0x8400 | (rcode & 0x0F)); // QR + AA
    header.setUint16(4, 1);
    header.setUint16(6, answers);
    header.setUint16(8, 0);
    header.setUint16(10, 1);
    packet.add(header.buffer.asUint8List());
    packet.add(name);
    final question = ByteData(4);
    question.setUint16(0, qtypeTxt);
    question.setUint16(2, qclassIn);
    packet.add(question.buffer.asUint8List());
    if (answers == 1) {
      final rdata = _txtRdata(payload!);
      // RFC 1035 §4.1.4: the answer's owner name is a pointer back to the
      // question at offset 12, not a second uncompressed copy. The copy is
      // legal but costs the whole name again, which is what pushed answers
      // at the budget past the size the query itself advertised.
      packet.add(Uint8List.fromList(const <int>[0xC0, 0x0C]));
      final record = ByteData(10);
      record.setUint16(0, qtypeTxt);
      record.setUint16(2, qclassIn);
      record.setUint32(4, 0); // ttl: never cache a tunnel answer
      record.setUint16(8, rdata.length);
      packet.add(record.buffer.asUint8List());
      packet.add(rdata);
    }
    packet.add(_optRecord());
    return packet.takeBytes();
  }

  /// Reads an answer, skipping records that are not TXT/IN.
  ///
  /// A recursive resolver may put a CNAME ahead of the TXT record; the
  /// Python client sees only its own authoritative answers and so never
  /// had to. Skipping is why this lane can point at a carrier resolver.
  static ParsedDnsAnswer parseDnsAnswerPacket(Uint8List packet) {
    if (packet.length < 12) throw const TxtQueryWireException('short header');
    final view = ByteData.sublistView(packet);
    final txid = view.getUint16(0);
    final rcode = view.getUint16(2) & 0x0F;
    final qdcount = view.getUint16(4);
    final ancount = view.getUint16(6);
    var pos = 12;
    // The question name carries the session id and nonce a query-response
    // binding by txid alone cannot see. Kept so a caller can compare it
    // against the name it actually sent, instead of trusting a 16-bit
    // transaction id on its own.
    String? questionName;
    for (var i = 0; i < qdcount; i++) {
      final decoded = _decodeName(packet, pos);
      questionName ??= decoded.name;
      pos = decoded.end + 4;
    }
    for (var i = 0; i < ancount; i++) {
      pos = _decodeName(packet, pos).end;
      if (pos + 10 > packet.length) {
        throw const TxtQueryWireException('truncated answer');
      }
      final rtype = view.getUint16(pos);
      final rdlength = view.getUint16(pos + 8);
      pos += 10;
      if (pos + rdlength > packet.length) {
        throw const TxtQueryWireException('truncated rdata');
      }
      if (rtype == qtypeTxt) {
        return ParsedDnsAnswer(
          txid: txid,
          rcode: rcode,
          questionName: questionName,
          payload: _parseTxtRdata(
            Uint8List.sublistView(packet, pos, pos + rdlength),
          ),
        );
      }
      pos += rdlength;
    }
    return ParsedDnsAnswer(
      txid: txid,
      rcode: rcode,
      questionName: questionName,
      payload: null,
    );
  }
}

/// Thrown when bytes or labels do not match the valve wire format.
class TxtQueryWireException implements Exception {
  final String message;

  const TxtQueryWireException(this.message);

  @override
  String toString() => 'TxtQueryWireException: $message';
}

/// One decoded query name.
class ParsedTxtQuery {
  final int seq;
  final String sessionId;
  final String nonce;
  final Uint8List chunk;
  final String domain;
  final String name;

  const ParsedTxtQuery({
    required this.seq,
    required this.sessionId,
    required this.nonce,
    required this.chunk,
    required this.domain,
    required this.name,
  });
}

/// The query names one payload became, with the session that ties them.
class EncodedQueries {
  final String sessionId;
  final List<String> names;

  const EncodedQueries({required this.sessionId, required this.names});
}

/// A decoded DNS question.
class ParsedDnsQuery {
  final int txid;
  final String name;

  const ParsedDnsQuery({required this.txid, required this.name});
}

/// A decoded DNS answer; [payload] is null when the answer carried no TXT
/// record, which includes every non-zero [rcode]. [questionName] is the
/// name the answer's own question section named, so a caller can bind a
/// response to the request it sent by more than the 16-bit [txid] alone;
/// it is null only when the packet carried zero questions.
class ParsedDnsAnswer {
  final int txid;
  final int rcode;
  final String? questionName;
  final Uint8List? payload;

  const ParsedDnsAnswer({
    required this.txid,
    required this.rcode,
    required this.questionName,
    required this.payload,
  });
}

class _DecodedName {
  final String name;
  final int end;

  const _DecodedName(this.name, this.end);
}
