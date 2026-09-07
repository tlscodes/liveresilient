import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// Golden vectors printed by `tools/t2/txt_query_wire.py` itself, through
/// `scratchpad/gen_wire_vectors.py`. The far side of this lane is that
/// Python module, so a diff here is a diff on the wire — which is the only
/// place it would otherwise show up, in production, on someone's phone.
const String _payloadFramedHex =
    '0065000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f4041'
    '42434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60616263'
    '64';

const String _queryPacketHex =
    '123401000001000000000001017102414606414243323334043758595a0a33325733'
    '3533594141450674756e6e656c0576616c7665076578616d706c6500001000010000'
    '2904d0000000000000';

const String _answerPacketHex =
    '123484000001000100000001017102414606414243323334043758595a0a33325733'
    '3533594141450674756e6e656c0576616c7665076578616d706c6500001000010171'
    '02414606414243323334043758595a0a3332573335335941414506'
    '74756e6e656c'
    '0576616c7665076578616d706c650000100001000000000016150013706f6e672066'
    '726f6d207468652076616c766500002904d0000000000000';

const String _nxdomainPacketHex =
    '000784030001000000000001017102414106414243323334043758595a0130067475'
    '6e6e656c0576616c7665076578616d706c65000010000100002904d0000000000000';

final Uint8List _payload = Uint8List.fromList(
  List<int>.generate(101, (i) => i),
);

const String _domain = 'valve.example';
const String _session = 'ABC234';
const String _nonce = '7XYZ';
final Uint8List _chunk = Uint8List.fromList(const <int>[
  0xDE,
  0xAD,
  0xBE,
  0xEF,
  0x00,
  0x01,
]);

Uint8List _hex(String text) {
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(text.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Base32, RFC 4648 unpadded', () {
    test('matches the Python encoder on every vector', () {
      expect(TxtQueryWire.base32Encode(const <int>[]), '0');
      expect(
        TxtQueryWire.base32Encode(const <int>[0xDE, 0xAD, 0xBE, 0xEF]),
        '32W353Y',
      );
      expect(TxtQueryWire.base32Encode(const <int>[0x01]), 'AE');
      expect(
        TxtQueryWire.base32Encode('hello valve'.codeUnits),
        'NBSWY3DPEB3GC3DWMU',
      );
    });

    test('decodes back to the same bytes, case-insensitively', () {
      expect(TxtQueryWire.base32Decode('0'), isEmpty);
      expect(TxtQueryWire.base32Decode('32w353y'), <int>[
        0xDE,
        0xAD,
        0xBE,
        0xEF,
      ]);
      expect(
        TxtQueryWire.base32Decode('NBSWY3DPEB3GC3DWMU'),
        'hello valve'.codeUnits,
      );
    });

    test('round-trips every length from 0 to 39 bytes', () {
      for (var length = 0; length <= TxtQueryWire.rawPerLabel; length++) {
        final bytes = Uint8List.fromList(
          List<int>.generate(length, (i) => (i * 37 + length) & 0xFF),
        );
        final decoded = TxtQueryWire.base32Decode(
          TxtQueryWire.base32Encode(bytes),
        );
        expect(decoded, bytes, reason: 'length $length');
      }
    });

    test('refuses a label that lost characters in transit', () {
      expect(
        () => TxtQueryWire.base32Decode('ABC'),
        throwsA(isA<TxtQueryWireException>()),
      );
      expect(
        () => TxtQueryWire.base32Decode('AB!D'),
        throwsA(isA<TxtQueryWireException>()),
      );
    });
  });

  group('fixed-width integers', () {
    test('match the Python widths', () {
      expect(TxtQueryWire.encodeInt(0, 2), 'AA');
      expect(TxtQueryWire.encodeInt(1023, 2), '77');
      expect(TxtQueryWire.encodeInt(37, 2), 'BF');
    });

    test('round-trip every sequence number the label can hold', () {
      for (var seq = 0; seq <= TxtQueryWire.seqMax; seq++) {
        expect(TxtQueryWire.decodeSeq(TxtQueryWire.encodeSeq(seq)), seq);
      }
    });

    test('refuse a sequence number the label cannot hold', () {
      expect(
        () => TxtQueryWire.encodeSeq(TxtQueryWire.seqMax + 1),
        throwsA(isA<TxtQueryWireException>()),
      );
      expect(
        () => TxtQueryWire.encodeInt(32, 1),
        throwsA(isA<TxtQueryWireException>()),
      );
    });

    test('session ids and nonces keep their declared width', () {
      for (var i = 0; i < 200; i++) {
        expect(TxtQueryWire.newSessionId().length, TxtQueryWire.sessionChars);
        expect(TxtQueryWire.newNonce().length, TxtQueryWire.nonceChars);
      }
    });
  });

  group('framing and chunking', () {
    test('frames a payload exactly as Python does', () {
      expect(_hexOf(TxtQueryWire.frameUp(_payload)), _payloadFramedHex);
    });

    test('splits into the same 39/39/25 chunks', () {
      final chunks = TxtQueryWire.splitChunks(TxtQueryWire.frameUp(_payload));
      expect(chunks.map((c) => c.length), <int>[39, 39, 25]);
      expect(
        _hexOf(chunks.first),
        '0065000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e'
        '1f2021222324',
      );
      expect(
        _hexOf(chunks.last),
        '4c4d4e4f505152535455565758595a5b5c5d5e5f6061626364',
      );
    });

    test('an empty payload is still one query', () {
      // Its frame is the two-byte length header, so a poll carries a chunk
      // rather than an empty label — the same as the Python encoder.
      expect(TxtQueryWire.splitChunks(TxtQueryWire.frameUp(const <int>[])), [
        <int>[0, 0],
      ]);
      expect(TxtQueryWire.splitChunks(Uint8List(0)), [isEmpty]);
      expect(
        TxtQueryWire.encodeQueries(const <int>[], _domain).names,
        hasLength(1),
      );
    });

    test('unframing refuses a frame that arrived short', () {
      final framed = TxtQueryWire.frameUp(_payload);
      expect(
        () => TxtQueryWire.unframeUp(framed.sublist(0, framed.length - 1)),
        throwsA(isA<TxtQueryWireException>()),
      );
    });

    test('the downstream budget is enforced', () {
      expect(
        () => TxtQueryWire.frameDown(
          List<int>.filled(TxtQueryWire.downstreamBudget + 1, 0),
        ),
        throwsA(isA<TxtQueryWireException>()),
      );
    });
  });

  group('query names', () {
    test('build byte-identically to the Python builder', () {
      expect(
        TxtQueryWire.buildQueryName(_chunk, 5, _session, _nonce, _domain),
        'q.AF.ABC234.7XYZ.32W353YAAE.tunnel.valve.example',
      );
      expect(
        TxtQueryWire.buildQueryName(
          const <int>[],
          0,
          _session,
          _nonce,
          _domain,
        ),
        'q.AA.ABC234.7XYZ.0.tunnel.valve.example',
      );
    });

    test('parse back to the same fields', () {
      final parsed = TxtQueryWire.parseQueryName(
        TxtQueryWire.buildQueryName(_chunk, 5, _session, _nonce, _domain),
        _domain,
      );
      expect(parsed.seq, 5);
      expect(parsed.sessionId, 'abc234');
      expect(parsed.nonce, '7xyz');
      expect(parsed.chunk, _chunk);
      expect(parsed.domain, _domain);
    });

    test('refuse a name from another zone', () {
      expect(
        () => TxtQueryWire.parseQueryName(
          'q.AF.ABC234.7XYZ.32W353YAAE.tunnel.other.example',
          _domain,
        ),
        throwsA(isA<TxtQueryWireException>()),
      );
    });

    test('refuse a name whose head is the wrong shape', () {
      expect(
        () => TxtQueryWire.parseQueryName(
          'q.AF.ABC234.32W353YAAE.tunnel.valve.example',
          _domain,
        ),
        throwsA(isA<TxtQueryWireException>()),
      );
    });

    test('a chunk fills a label without overflowing it', () {
      final full = Uint8List(TxtQueryWire.rawPerLabel);
      final name = TxtQueryWire.buildQueryName(
        full,
        0,
        _session,
        _nonce,
        _domain,
      );
      expect(
        name.split('.')[4].length,
        lessThanOrEqualTo(TxtQueryWire.labelMax),
      );
      expect(name.length, lessThanOrEqualTo(TxtQueryWire.fqdnMax));
    });

    test('a payload survives encode, parse and reassemble', () {
      final encoded = TxtQueryWire.encodeQueries(
        _payload,
        _domain,
        sessionId: _session,
      );
      expect(encoded.names, hasLength(3));
      final parsed = <ParsedTxtQuery>[
        for (final name in encoded.names)
          TxtQueryWire.parseQueryName(name, _domain),
      ];
      expect(TxtQueryWire.reassemble(parsed), _payload);
    });

    test('reassembly refuses a gap rather than splicing', () {
      final encoded = TxtQueryWire.encodeQueries(
        _payload,
        _domain,
        sessionId: _session,
      );
      final parsed = <ParsedTxtQuery>[
        TxtQueryWire.parseQueryName(encoded.names[0], _domain),
        TxtQueryWire.parseQueryName(encoded.names[2], _domain),
      ];
      expect(
        () => TxtQueryWire.reassemble(parsed),
        throwsA(isA<TxtQueryWireException>()),
      );
    });
  });

  group('DNS packets', () {
    test('a query is byte-identical to the Python packet', () {
      final packet = TxtQueryWire.buildDnsQueryPacket(
        0x1234,
        TxtQueryWire.buildQueryName(_chunk, 5, _session, _nonce, _domain),
      );
      expect(_hexOf(packet), _queryPacketHex);
    });

    test('an answer is byte-identical to the Python packet', () {
      final packet = TxtQueryWire.buildDnsAnswerPacket(
        0x1234,
        TxtQueryWire.buildQueryName(_chunk, 5, _session, _nonce, _domain),
        TxtQueryWire.frameDown('pong from the valve'.codeUnits),
      );
      expect(_hexOf(packet), _answerPacketHex);
    });

    test('the Python answer parses to the payload it carried', () {
      final parsed = TxtQueryWire.parseDnsAnswerPacket(_hex(_answerPacketHex));
      expect(parsed.txid, 0x1234);
      expect(parsed.rcode, TxtQueryWire.rcodeNoError);
      expect(
        TxtQueryWire.unframeDown(parsed.payload!),
        'pong from the valve'.codeUnits,
      );
    });

    test('the Python query parses to the name it asked for', () {
      final parsed = TxtQueryWire.parseDnsQueryPacket(_hex(_queryPacketHex));
      expect(parsed.txid, 0x1234);
      expect(parsed.name, 'q.AF.ABC234.7XYZ.32W353YAAE.tunnel.valve.example');
    });

    test('an NXDOMAIN answer carries no payload', () {
      final parsed = TxtQueryWire.parseDnsAnswerPacket(
        _hex(_nxdomainPacketHex),
      );
      expect(parsed.rcode, TxtQueryWire.rcodeNxDomain);
      expect(parsed.payload, isNull);
    });

    test('a TXT record longer than 255 bytes rejoins its strings', () {
      final long = Uint8List.fromList(
        List<int>.generate(TxtQueryWire.downstreamBudget, (i) => i & 0xFF),
      );
      final packet = TxtQueryWire.buildDnsAnswerPacket(
        9,
        'q.AA.ABC234.7XYZ.0.tunnel.valve.example',
        TxtQueryWire.frameDown(long),
      );
      final parsed = TxtQueryWire.parseDnsAnswerPacket(packet);
      expect(TxtQueryWire.unframeDown(parsed.payload!), long);
    });

    test('a compressed answer name is followed, not mistaken for data', () {
      // What a real resolver sends: the answer's owner name is a pointer
      // back to the question at offset 12, not a second copy of the name.
      final name = TxtQueryWire.buildQueryName(
        _chunk,
        5,
        _session,
        _nonce,
        _domain,
      );
      final uncompressed = TxtQueryWire.buildDnsAnswerPacket(
        0x1234,
        name,
        TxtQueryWire.frameDown('compressed'.codeUnits),
      );
      final nameLength = _nameWireLength(name);
      final compressed = <int>[
        ...uncompressed.sublist(0, 12 + nameLength + 4),
        0xC0, 0x0C, // pointer to offset 12
        ...uncompressed.sublist(12 + nameLength + 4 + nameLength),
      ];
      final parsed = TxtQueryWire.parseDnsAnswerPacket(
        Uint8List.fromList(compressed),
      );
      expect(TxtQueryWire.unframeDown(parsed.payload!), 'compressed'.codeUnits);
    });

    test('a CNAME ahead of the TXT record is skipped', () {
      final name = 'q.AA.ABC234.7XYZ.0.tunnel.valve.example';
      final txtOnly = TxtQueryWire.buildDnsAnswerPacket(
        7,
        name,
        TxtQueryWire.frameDown('behind a cname'.codeUnits),
      );
      final nameLength = _nameWireLength(name);
      final headerEnd = 12 + nameLength + 4;
      final cname = <int>[
        0xC0, 0x0C, // owner: pointer to the question
        0x00, 0x05, // type CNAME
        0x00, 0x01, // class IN
        0x00, 0x00, 0x00, 0x00, // ttl
        0x00, 0x02, // rdlength
        0xC0, 0x0C, // rdata: pointer
      ];
      final packet = <int>[
        ...txtOnly.sublist(0, 6),
        0x00, 0x02, // ancount = 2
        ...txtOnly.sublist(8, headerEnd),
        ...cname,
        ...txtOnly.sublist(headerEnd),
      ];
      final parsed = TxtQueryWire.parseDnsAnswerPacket(
        Uint8List.fromList(packet),
      );
      expect(
        TxtQueryWire.unframeDown(parsed.payload!),
        'behind a cname'.codeUnits,
      );
    });

    test('a truncated packet is refused, not read past its end', () {
      final packet = _hex(_answerPacketHex);
      expect(
        () => TxtQueryWire.parseDnsAnswerPacket(packet.sublist(0, 30)),
        throwsA(isA<TxtQueryWireException>()),
      );
      expect(
        () => TxtQueryWire.parseDnsAnswerPacket(Uint8List(4)),
        throwsA(isA<TxtQueryWireException>()),
      );
    });
  });
}

/// Length of [name] once encoded as DNS labels, including the root byte.
int _nameWireLength(String name) =>
    name.split('.').fold<int>(1, (sum, label) => sum + 1 + label.length);
